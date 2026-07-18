#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${DEV:=""}"
: "${MTU:=""}"
: "${MAC:=""}"
: "${TAP:="tap0"}"
: "${NETWORK:="Y"}"
: "${BRIDGE:="vmbr0"}"
: "${MASK:="255.255.255.0"}"


# Sanitize variables
DEV=$(strip "$DEV")
MTU=$(strip "$MTU")
TAP=$(strip "$TAP")
MAC=$(strip "$MAC")
MASK=$(strip "$MASK")
BRIDGE=$(strip "$BRIDGE")
NETWORK=$(strip "$NETWORK")

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Generic helpers
# ######################################

isNAT() {

  case "${NETWORK,,}" in
    "nat" | "tap" | "tun" | "tuntap" | "y" | "" )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

getMTU() {

  local dev="$1"

  if [ -r "/sys/class/net/$dev/mtu" ]; then
    cat "/sys/class/net/$dev/mtu"
  else
    echo "0"
  fi

  return 0
}

minMTU() {

  local mtu=""
  local min=""

  for mtu in "$@"; do
    [[ -z "$mtu" || "$mtu" == "0" ]] && continue

    if [[ -z "$min" || "$mtu" -lt "$min" ]]; then
      min="$mtu"
    fi
  done

  echo "${min:-0}"
  return 0
}

setMTU() {

  local dev="$1"
  local mtu="$2"

  # MTU 0 means "do not set"; MTU 1500 is the normal default and does not need setting.
  [[ "$mtu" == "0" || "$mtu" == "1500" ]] && return 0

  if ! ip link set dev "$dev" mtu "$mtu"; then
    warn "failed to set MTU size of $dev to $mtu."
  fi

  return 0
}

gatewayMAC() {

  local mac="$1"

  echo "$mac" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/'
}

maskToCIDR() {

  local mask="$1"
  local prefix=""

  if ! command -v ipcalc > /dev/null 2>&1; then
    error "Required command 'ipcalc' is not installed!"
    return 1
  fi

  prefix=$(ipcalc -n -b "0.0.0.0/$mask" 2>/dev/null | awk '
    /^Netmask:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "=") {
          print $(i + 1)
          exit
        }
      }
    }
  ')

  if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
    error "Invalid MASK: '$mask'"
    return 1
  fi

  echo "$prefix"
  return 0
}

networkCIDR() {

  local ip="$1"
  local network=""

  network=$(ipcalc -n -b "$ip/$MASK" 2>/dev/null | awk '
    /^Network:/ {
      print $2
      exit
    }
  ')

  if [[ ! "$network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]]; then
    error "Failed to calculate network address from IP '$ip' and netmask '$MASK'."
    return 1
  fi

  echo "$network"
  return 0
}


detectInterface() {

  if [ -n "$DEV" ]; then
    return 0
  fi

  # Prefer the last attached Kubernetes network
  [ -d "/sys/class/net/net0" ] && DEV="net0"
  [ -d "/sys/class/net/net1" ] && DEV="net1"
  [ -d "/sys/class/net/net2" ] && DEV="net2"
  [ -d "/sys/class/net/net3" ] && DEV="net3"

  # Automatically detect the default network interface
  [ -z "$DEV" ] && DEV=$(awk '$2 == 00000000 { print $1; exit }' /proc/net/route)
  [ -z "$DEV" ] && DEV="eth0"

  return 0
}

detectAddresses() {

  local rc=0

  GATEWAY=$(ip route list dev "$DEV" | awk '/^default/ { print $3 }' | head -n 1)
  { UPLINK=$(ip address show dev "$DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); } 2>/dev/null || :

  IP6=""

  if [ -f /proc/net/if_inet6 ] &&
    [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then

    { IP6=$(ip -6 addr show dev "$DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""

    [ -n "$IP6" ] &&
      IP6=$(echo "$IP6" | sed -e 's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  return 0
}

detectAdapter() {

  local result=""

  NIC=""
  BUS=""

  result=$(ethtool -i "$DEV" 2>/dev/null || :)

  NIC=$(awk -F':[[:space:]]*' '
    tolower($1) == "driver" {
      print $2
      exit
    }
  ' <<< "$result")

  BUS=$(awk -F':[[:space:]]*' '
    tolower($1) == "bus-info" {
      print $2
      exit
    }
  ' <<< "$result")

  return 0
}

containerID() {

  local id=""

  id=$(hostname -s 2>/dev/null || true)

  if [ -z "$id" ] && [ -s /etc/machine-id ]; then
    id=$(< /etc/machine-id)
  fi

  if [ -z "$id" ] && [ -s /proc/sys/kernel/random/boot_id ]; then
    id=$(< /proc/sys/kernel/random/boot_id)
  fi

  [ -z "$id" ] && id="unknown"

  echo "$id"
  return 0
}

disableIPv6() {

  local dev="$1"

  [ -d "/proc/sys/net/ipv6/conf/$dev" ] || return 0

  # Best-effort only: container sysctl writes can fail.
  sysctl -w "net.ipv6.conf.$dev.disable_ipv6=1" > /dev/null 2>&1 || :
  sysctl -w "net.ipv6.conf.$dev.accept_ra=0" > /dev/null 2>&1 || :

  return 0
}

subnetInUse() {

  local subnet="$1"
  local broader="" narrower="" routes=""

  if ! broader=$(ip -4 route show table all match "$subnet" 2>/dev/null); then
    error "Failed to inspect existing routes for subnet $subnet."
    return 2
  fi

  if ! narrower=$(ip -4 route show table all root "$subnet" 2>/dev/null); then
    error "Failed to inspect existing routes for subnet $subnet."
    return 2
  fi

  routes=$(
    printf '%s\n%s\n' "$broader" "$narrower" |
      grep -Ev '(^|[[:space:]])default([[:space:]]|$)' |
      sort -u || true
  )

  [ -n "$routes" ]
}

subnetBase() {

  local ip="$1"
  local third=""
  local second=""
  local base=""
  local subnet=""
  local rc=0

  third=$(cut -d. -f3 <<< "$ip")

  for second in {30..254}; do
    base="172.$second.$third"
    subnet="$base.0/$PREFIX"

    if subnetInUse "$subnet"; then
      continue
    else
      rc=$?
      (( rc == 1 )) || return 1
    fi

    echo "$base"
    return 0
  done

  error "No available VM subnet found in 172.30.$third.0/$PREFIX through 172.254.$third.0/$PREFIX."
  return 1
}

# ######################################
#  DNS / interface helpers
# ######################################

configureDNS() {

  local fa="$1"
  local mask="$2"
  local gateway="$3"
  local base="${gateway%.*}"
  local file="/etc/dnsmasq.d/$fa.conf"
  local mtu_option=""
  local filter_dns=""

  if [[ "$LAN_MTU" != "0" && "$LAN_MTU" != "1500" ]]; then
    mtu_option="dhcp-option=option:interface-mtu,$LAN_MTU"
  fi

  # Avoid returning IPv6 records when the active network mode is IPv4-only.
  if isNAT || [ -z "$IP6" ]; then
    filter_dns="filter-AAAA"
  fi

  if ! sed 's/^    //' > "$file" <<EOF2

    # Listen only on bridge
    interface=$fa
    bind-interfaces
    except-interface=lo

    # IPv4 DHCP range
    dhcp-range=set:${fa},${base}.2,${base}.254

    # Set gateway address
    dhcp-option=option:netmask,$mask
    dhcp-option=option:router,$gateway
    dhcp-option=option:dns-server,$gateway
    $mtu_option

    address=/host.lan/$gateway
    $filter_dns

    # DHCP settings
    dhcp-authoritative

    # Windows compatibility
    dhcp-option=252,"\n"
    dhcp-option=vendor:MSFT,2,1i
EOF2
  then
    error "Failed to write dnsmasq config file: $file"
    return 1
  fi

  return 0
}

setInterfaces() {

  local fa="$1"
  local tap="$2"
  local gateway="$3"

  # Add all available network interfaces
  local file="/etc/network/interfaces.new"

  if ! sed 's/^    //' > "$file" <<EOF2
    auto lo
    iface lo inet loopback
EOF2
  then
    error "Failed to write network interface config file: $file"
    return 1
  fi

  while IFS= read -r i; do

    [[ "${i,,}" == "${fa,,}" ]] && continue

    if ! sed 's/^        //' >> "$file" <<EOF2

        auto $i
        iface $i inet manual
EOF2
    then
      error "Failed to append interface $i to config file: $file"
      return 1
    fi

  done < <(ip -o link show | awk -F': ' '{ print $2 }' | grep -v lo | sed 's/@.*//')

  # Configure bridge
  if ! sed 's/^    //' >> "$file" <<EOF2

    auto $fa
    iface $fa inet static
        address $gateway/$PREFIX
        bridge-ports $tap
        bridge-stp off
        bridge-fd 0

    source /etc/network/interfaces.d/*
EOF2
  then
    error "Failed to append bridge config to file: $file"
    return 1
  fi

  return 0
}

# ######################################
#  Network mode setup
# ######################################

createBridge() {

  local gateway="$1"
  local rc msg=""

  # Create a bridge with a static IP for the VM LAN
  { msg=$(ip link add dev "$BRIDGE" type bridge 2>&1); rc=$?; } || :

  if (( rc != 0 )); then
    [ -n "$msg" ] && echo "$msg" >&2

    case "${msg,,}" in
      *"operation not permitted"* | *"permission denied"* )
        error "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" ;;
      * )
        error "failed to create bridge." ;;
    esac

    return 1
  fi

  if [[ "$LAN_MTU" != "0" ]]; then
    setMTU "$BRIDGE" "$LAN_MTU"
  fi

  if ! ip address add "$gateway/$PREFIX" dev "$BRIDGE"; then
    error "failed to add IP address pool!"
    return 1
  fi

  while ! ip link set "$BRIDGE" up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # NAT networking is IPv4-only; disable IPv6 on the VM bridge if possible.
  disableIPv6 "$BRIDGE"

  return 0
}

createTap() {

  local tuntap="$1"
  local rc msg=""

  # Set tap to the bridge created
  { msg=$(ip tuntap add dev "$TAP" mode tap 2>&1); rc=$?; } || :

  if (( rc != 0 )); then
    [ -n "$msg" ] && echo "$msg" >&2
    error "$tuntap"
    return 1
  fi

  if [[ "$LAN_MTU" != "0" ]]; then
    setMTU "$TAP" "$LAN_MTU"
  fi

  if ! ip link set dev "$TAP" address "$GATEWAY_MAC"; then
    warn "failed to set gateway MAC address."
  fi

  while ! ip link set "$TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  # NAT networking is IPv4-only; disable IPv6 on the VM tap if possible.
  disableIPv6 "$TAP"

  if ! ip link set dev "$TAP" master "$BRIDGE"; then
    error "failed to set master bridge!"
    return 1
  fi

  return 0
}

# ######################################
#  IP tables
# ######################################

getTablesBackend() {

  local version=""
  version=$(iptables --version 2>/dev/null || true)

  case "$version" in
    *nf_tables* ) echo "nft" ;;
    *legacy* ) echo "legacy" ;;
    * ) return 1 ;;
  esac
}

setTables() {

  local mode="$1"
  local path=""

  path=$(command -v "iptables-$mode" 2>/dev/null || true)
  [ -z "$path" ] && return 1

  update-alternatives --set iptables "$path" > /dev/null 2>&1
}

showRules() {

  local table="$1"
  local chain="$2"
  local label="$3"
  local rule_tag="$4"
  local rules=""
  local own_rule="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  enabled "$DEBUG" || return 0

  rules=$(
    iptables -t "$table" -S "$chain" 2>/dev/null |
      awk '$1 == "-A"' |
      grep -Ev -- "$own_rule" || true
  )

  [ -n "$rules" ] || return 0

  printf "Existing %s rules:\n\n%s\n\n" "$label" "$rules"
  return 0
}

checkExistingTables() {

  local msg="" rules="" conflicts=""
  local rule_tag="PROXMOX_NAT"
  local own_rule="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  rules=$(
    iptables -t filter -S FORWARD 2>/dev/null |
      awk '$1 == "-A"' |
      grep -Ev -- "$own_rule" || true
  )

  conflicts=$(grep -E -- \
    '^-A FORWARD .*(-j DROP|-j REJECT)( |$)' \
    <<< "$rules" || true)

  if [ -n "$conflicts" ]; then
    msg="your existing firewall rules may block traffic forwarded to or from the VM subnet"

    if enabled "$DEBUG"; then
      warn "${msg}."
    else
      warn "${msg}; enable DEBUG=Y to inspect them."
    fi
  fi

  showRules filter FORWARD "filter FORWARD" "$rule_tag"
  showRules nat POSTROUTING "NAT POSTROUTING" "$rule_tag"

  return 0
}

runTableRule() {

  local silent="$1"
  local result="$2"
  local rc msg=""

  shift 2

  printf -v "$result" '%s' ""

  { msg=$("$@" 2>&1); rc=$?; } || :
  (( rc == 0 )) && return 0

  printf -v "$result" '%s' "$msg"

  if ! enabled "$silent" || enabled "$DEBUG"; then
    [ -n "$msg" ] && echo "$msg" >&2
  fi

  return 1
}

tableError() {

  local silent="$1"
  local message="${2,,}"

  if enabled "$silent" && ! enabled "$DEBUG"; then
    return 1
  fi

  case "$message" in
    *"permission denied"* | *"operation not permitted"* )
      warn "IP tables access was denied. Add the NET_ADMIN capability."
      ;;
    *"table does not exist"* | *"can't initialize iptables table"* )
      warn "The required IP tables kernel modules may be unavailable. Try: sudo modprobe ip_tables iptable_nat"
      ;;
    *"no chain/target/match by that name"* )
      warn "A required IP tables target or match is unavailable in the host kernel."
      ;;
    *"could not fetch rule set generation id"* )
      warn "The nftables backend is unavailable or inaccessible in this container."
      ;;
    * )
      warn "Failed to configure IP tables. Verify NET_ADMIN access and host IP tables support."
      ;;
  esac

  return 1
}

showTableCleanupError() {

  local command="$1"
  local message="$2"

  enabled "$DEBUG" || return 0

  printf "Failed IP tables cleanup command:\n\n%s\n\n" "$command" >&2
  [ -n "$message" ] && printf "%s\n\n" "$message" >&2

  return 0
}

applyTables() {

  local subnet="$1"
  local silent="${2:-N}"
  local table_error=""
  local rule_tag="PROXMOX_NAT"

  # NAT traffic from the VM subnet leaving through any external interface.
  if ! runTableRule "$silent" table_error \
    iptables -t nat -A POSTROUTING \
    ! -o "$BRIDGE" \
    -s "$subnet" \
    ! -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j MASQUERADE; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Allow traffic from the VM bridge to any external interface.
  if ! runTableRule "$silent" table_error \
    iptables -A FORWARD \
    -i "$BRIDGE" \
    ! -o "$BRIDGE" \
    -s "$subnet" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    tableError "$silent" "$table_error"
    return 1
  fi

  # Allow traffic from any external interface to the VM subnet.
  if ! runTableRule "$silent" table_error \
    iptables -A FORWARD \
    ! -i "$BRIDGE" \
    -o "$BRIDGE" \
    -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    tableError "$silent" "$table_error"
    return 1
  fi

  return 0
}

clearTables() {

  local table="" line=""
  local rules="" remaining="" message=""
  local rule_tag="PROXMOX_NAT"
  local own_rule="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  # Return 2 when the currently selected backend cannot be accessed.
  # This lets configureTables() distinguish it from an actual rule-cleanup failure.
  if ! rules=$(iptables-save 2> /dev/null); then

    if enabled "$DEBUG"; then
      message=$(iptables-save 2>&1 > /dev/null || true)
      showTableCleanupError "iptables-save" "$message"
    fi

    return 2
  fi

  if [ -n "$rules" ]; then

    # Delete every rule tagged with our unique identifier,
    # leaving all other rules intact.
    while IFS= read -r line; do

      case "$line" in
        \*nat ) table="nat" ;;
        \*filter ) table="filter" ;;
        \*mangle ) table="mangle" ;;
        \*raw ) table="raw" ;;
      esac

      if [[ "$line" == -A* ]] && [[ "$line" =~ $own_rule ]]; then
        line="${line/-A /-D }"

        # Parse the quoting produced by iptables-save before deleting the rule.
        if ! message=$(
          printf '%s\n' "$line" |
            xargs -r iptables -t "$table" 2>&1
        ); then
          showTableCleanupError "iptables -t $table $line" "$message"
        fi
      fi

    done <<< "$rules"

  fi

  # Base the result on the final ruleset instead of intermediate errors.
  if ! rules=$(iptables-save 2> /dev/null); then

    if enabled "$DEBUG"; then
      message=$(iptables-save 2>&1 > /dev/null || true)
      showTableCleanupError "iptables-save" "$message"
    fi

    return 1
  fi

  remaining=$(grep -E -- "$own_rule" <<< "$rules" || true)

  if [ -n "$remaining" ]; then

    if enabled "$DEBUG"; then
      warn "IP tables cleanup left the following rules behind:"
      echo "$remaining" >&2
    fi

    return 1
  fi

  return 0
}

configureTables() {

  local subnet="$1"
  local preferred=""
  local alternate="" rc=0
  local preferred_clean="N"
  local alternate_dirty="N"

  preferred=$(getTablesBackend) || {
    error "failed to determine the active IP tables backend!"
    return 1
  }

  case "$preferred" in
    "nft" ) alternate="legacy" ;;
    "legacy" ) alternate="nft" ;;
    * )
      error "unsupported IP tables backend: $preferred"
      return 1 ;;
  esac

  # Try the preferred backend first.
  if clearTables; then

    preferred_clean="Y"

    # Try the preferred backend without reporting provisional failures.
    if applyTables "$subnet" "Y"; then
      checkExistingTables
      return 0
    fi

    # Never switch backends while partial rules remain in the preferred backend.
    if ! clearTables; then
      error "failed to clean up the partial $preferred IP tables configuration!"
      return 1
    fi

  else

    rc=$?

    # The preferred backend was accessible, but its rules could not be removed.
    # Do not switch while partial or stale rules may still be active.
    if (( rc == 1 )); then
      error "failed to clean up the existing $preferred IP tables configuration!"
      return 1
    fi

    # Return code 2 means the preferred backend itself could not be accessed,
    # so it is safe to try the alternate backend.
    if (( rc != 2 )); then
      error "failed to access the $preferred IP tables backend!"
      return 1
    fi

    enabled "$DEBUG" && warn "failed to access the $preferred IP tables backend!"

  fi

  # Try the alternate backend when the preferred backend failed.
  if setTables "$alternate"; then

    # Remove rules left by a previous run from the alternate backend.
    if clearTables; then

      if applyTables "$subnet" "Y"; then
        checkExistingTables
        return 0
      fi

      if ! clearTables; then
        alternate_dirty="Y"
        error "failed to clean up the partial $alternate IP tables configuration!"
      fi

    else

      rc=$?

      # Only mark the alternate backend dirty when it was accessible but cleanup failed.
      if (( rc == 1 )); then
        alternate_dirty="Y"
        error "failed to clean up the existing $alternate IP tables configuration!"
      elif (( rc != 2 )); then
        alternate_dirty="Y"
        error "failed to inspect the existing $alternate IP tables configuration!"
      elif enabled "$DEBUG"; then
        warn "failed to access the $alternate IP tables backend!"
      fi

    fi

  fi

  # Restore the preferred backend after the alternate attempt failed.
  if ! setTables "$preferred"; then
    error "failed to restore the preferred $preferred IP tables backend!"
    return 1
  fi

  # Do not continue while partial rules remain in the alternate backend.
  enabled "$alternate_dirty" && return 1

  # Both backend failures were already shown in debug mode.
  enabled "$DEBUG" && return 1

  # An inaccessible preferred backend cannot be retried diagnostically.
  if ! enabled "$preferred_clean"; then
    error "failed to access both IP tables backends!"
    return 1
  fi

  # Verify that no rules remain before the diagnostic attempt.
  if ! clearTables; then
    error "failed to clean up the existing $preferred IP tables configuration!"
    return 1
  fi

  # Repeat the preferred backend once to show its actual failure.
  if applyTables "$subnet" "N"; then
    checkExistingTables
    return 0
  fi

  # Do not leave a partial ruleset after the final failed attempt.
  if ! clearTables; then
    error "failed to clean up the partial $preferred IP tables configuration!"
  fi

  return 1
}

configureNAT() {

  local base=""
  local rc msg=""
  local subnet=""
  local gateway=""
  local forwarding=""
  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"

  enabled "$DEBUG" && echo "Configuring NAT networking..."

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net > /dev/null 2>&1 || :

    { msg=$(mknod /dev/net/tun c 10 200 2>&1); rc=$?; } || :

    if (( rc == 0 )); then
      chmod 666 /dev/net/tun
    elif [ -n "$msg" ]; then
      echo "$msg" >&2
    fi
  fi

  if [ ! -c /dev/net/tun ]; then
    error "$tuntap"
    return 1
  fi

  # Check IPv4 port forwarding flag
  [ -r /proc/sys/net/ipv4/ip_forward ] &&
    forwarding=$(< /proc/sys/net/ipv4/ip_forward)

  if [[ "$forwarding" != "1" ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :

    forwarding=""
    [ -r /proc/sys/net/ipv4/ip_forward ] &&
      forwarding=$(< /proc/sys/net/ipv4/ip_forward)

    if (( rc != 0 )) || [[ "$forwarding" != "1" ]]; then
      error "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  base=$(subnetBase "$UPLINK") || return 1
  gateway="$base.1"
  subnet=$(networkCIDR "$gateway") || return 1

  if subnetInUse "$subnet"; then
    error "VM subnet $subnet conflicts with an existing route inside the container."
    return 1
  else
    rc=$?
    (( rc == 1 )) || return 1
  fi

  createBridge "$gateway" || return 1
  createTap "$tuntap" || return 1

  # Use the lowest effective VM-LAN MTU, without mutating the uplink MTU.
  if [[ "$LAN_MTU" != "0" ]]; then
    LAN_MTU=$(minMTU "$LAN_MTU" "$(getMTU "$BRIDGE")" "$(getMTU "$TAP")")
  fi

  configureTables "$subnet" || return 1

  setInterfaces "$BRIDGE" "$TAP" "$gateway" || return 1
  configureDNS "$BRIDGE" "$MASK" "$gateway" || return 1

  showBridgeInfo "$subnet" "$gateway"

  return 0
}

# ######################################
#  Cleanup
# ######################################

closeInterfaces() {

  ip link set "$TAP" down promisc off &> /dev/null || :
  ip link delete "$TAP" &> /dev/null || :

  ip link set "$BRIDGE" down &> /dev/null || :
  ip link delete "$BRIDGE" &> /dev/null || :

  clearTables || :
  return 0
}

# ######################################
#  Detection
# ######################################

validateInterface() {

  if [ ! -d "/sys/class/net/$DEV" ]; then
    error "Network interface '$DEV' does not exist inside the container!"
    error "$ADD_ERR -e \"DEV=NAME\" to specify another interface name."
    exit 26
  fi

  return 0
}

validateMask() {

  PREFIX=$(maskToCIDR "$MASK") || exit 28

  if [[ "$PREFIX" != "24" ]]; then
    error "MASK values other than 255.255.255.0 are not supported by this network layout."
    exit 28
  fi

  return 0
}

validateAddresses() {

  [ -z "$UPLINK" ] && error "Could not determine container IPv4 address!" && exit 26

  return 0
}

validateAdapter() {

  if [[ -n "$BUS" && "${BUS,,}" != "n/a" && "${BUS,,}" != "tap" ]]; then
    enabled "$DEBUG" && info "Detected NIC: ${NIC:-unknown}  BUS: $BUS"
    error "This container does not support host mode networking!"
    exit 29
  fi

  return 0
}

configureMTU() {

  local mtu=""
  local mtu_custom="N"

  if [ -f "/sys/class/net/$DEV/mtu" ]; then
    mtu=$(< "/sys/class/net/$DEV/mtu")
  fi

  [ -n "$MTU" ] && mtu_custom="Y"
  [ -z "$MTU" ] && MTU="$mtu"
  [ -z "$MTU" ] && MTU="0"

  LAN_MTU="$MTU"

  # Automatically propagate smaller-than-standard MTUs, but do not automatically
  # advertise jumbo frames unless the user explicitly requested MTU.
  if [[ "$LAN_MTU" != "0" && "$LAN_MTU" -gt "1500" ]] &&
    ! enabled "$mtu_custom"; then
    LAN_MTU="1500"
  fi

  return 0
}

configureMAC() {

  local container=""

  container=$(containerID)

  if [ -z "$MAC" ]; then
    # Generate a MAC address based on a stable container identifier when possible.
    MAC=$(echo "$container" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
  fi

  MAC="${MAC,,}"
  MAC="${MAC//-/:}"

  if [[ ${#MAC} == 12 ]]; then
    local m="$MAC"
    MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#MAC} != 17 ]]; then
    error "Invalid MAC address: '$MAC', should be 12 or 17 digits long!"
    exit 28
  fi

  # Keep the guest-facing gateway MAC stable across runs, otherwise guests may
  # detect a new network every boot.
  GATEWAY_MAC=$(gatewayMAC "$MAC")

  return 0
}

formatAddress() {

  local ip="${1:-}"
  local prefix="${2:-}"
  local result="$ip"

  [ -z "$result" ] && return 1

  if [ -n "$prefix" ] && [[ "$prefix" != "24" ]]; then
    result+="/$prefix"
  fi

  echo "$result"
  return 0
}

showHostInfo() {

  local mtu="" host="" uplink="" prefix=""

  prefix=$(ip -4 -o address show dev "$DEV" scope global 2>/dev/null |
    awk -v ip="$UPLINK" '
      {
        split($4, address, "/")
        if (address[1] == ip) {
          print address[2]
          exit
        }
      }
    ')

  uplink=$(formatAddress "$UPLINK" "$prefix" || true)
  [ -z "$uplink" ] && uplink="(none)"

  local line="❯ Host: $uplink"

  host=$(containerID)
  [ -n "$host" ] && line+=" ($host)"

  local obvious=""
  if [[ "$UPLINK" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
    obvious="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.1"
  fi

  local gateway="${GATEWAY:-}"
  if [ -z "$gateway" ]; then
    line+="  |  Gateway: (none)"
  elif [[ "$gateway" != "$obvious" ]]; then
    line+="  |  Gateway: $gateway"
  fi

  local iface="$DEV"
  if [ -n "$NIC" ] && [[ "${NIC,,}" != "veth" ]]; then
    iface+="/$NIC"
  fi

  [ -z "$iface" ] && iface="(none)"
  [[ "$iface" != "eth0" ]] && line+="  |  Interface: $iface"

  mtu=$(getMTU "$DEV")
  if [ -n "$mtu" ] && [[ "$mtu" != "0" && "$mtu" != "1500" ]]; then
    line+="  |  MTU: $mtu"
  fi

  local nameservers=""
  local file="/etc/resolv.dnsmasq"
  [ ! -f "$file" ] && file="/etc/resolv.conf"

  if [ -f "$file" ]; then
    nameservers=$(awk '$1 == "nameserver" { print $2 }' "$file" |
      paste -sd ',' |
      sed 's/,/, /g' || true)
  fi

  [ -z "$nameservers" ] && nameservers="(none)"
  [[ "$nameservers" == "127.0.0.1"* ]] && nameservers=""

  echo

  if (( ${#nameservers} <= 40 )); then
    [ -n "$nameservers" ] && line+="  |  DNS: $nameservers"
    echo "$line"
  else
    echo "$line"
    echo "❯ DNS: $nameservers"
  fi

  return 0
}

showBridgeInfo() {

  local subnet="$1"
  local gateway="$2"
  local mtu=""
  local base=""
  local dhcp=""
  local display=""

  display=$(formatAddress "$gateway" "$PREFIX" || true)

  base="${gateway%.*}"
  dhcp="$base.2-$base.254"

  local line="❯ Bridge: $BRIDGE  |  Gateway: $display  |  DHCP: $dhcp"

  if [[ "$PREFIX" != "24" ]]; then
    line+="  |  Subnet: $subnet"
  fi

  mtu=$(getMTU "$BRIDGE")
  if [ -n "$mtu" ] && [[ "$mtu" != "0" && "$mtu" != "1500" ]]; then
    line+="  |  MTU: $mtu"
  fi

  echo "$line"
  echo
  return 0
}

initializeNetwork() {

  detectInterface
  validateInterface

  validateMask

  detectAddresses
  validateAddresses

  detectAdapter
  validateAdapter

  configureMTU
  configureMAC

  showHostInfo
  closeInterfaces

  return 0
}

blockLicense() {

  # Block connection attempts to license server
  sed -i -E \
    '/^[[:space:]]*[^#]*[[:space:]]shop\.maurer-it\.com([[:space:]]|$)/d' \
    /etc/hosts 2>/dev/null || true

  printf '%s\n' \
    '127.0.0.1 shop.maurer-it.com' \
    '::1 shop.maurer-it.com' >> /etc/hosts 2>/dev/null || true

  return 0
}

# ######################################
#  Configure Network
# ######################################

blockLicense

disabled "$NETWORK" && return 0

if ! isNAT; then
  error "Unrecognized NETWORK value: \"$NETWORK\""
  exit 48
fi

msg="Initializing network..."
enabled "$DEBUG" && info "$msg"

initializeNetwork

# Configure NAT networking
if ! configureNAT; then

  closeInterfaces
  error "failed to setup NAT networking!"
  [[ "$DEBUG" != [Yy1]* ]] && exit 48

else

  enabled "$DEBUG" && info "Initialized network successfully..."

fi

return 0
