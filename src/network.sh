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

: "${ENGINE:=""}"
: "${ROOTLESS:="N"}"

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

detectEngine() {

  if [ -f "/run/.containerenv" ]; then
    ENGINE="${container:-}"

    if [[ "${ENGINE,,}" == *"podman"* ]]; then
      ENGINE="Podman"
    else
      [ -z "$ENGINE" ] && ENGINE="Kubernetes"
    fi
  elif [ -f "/.dockerenv" ]; then
    ENGINE="Docker"
  fi

  return 0
}

detectRootless() {

  local uid_map=""

  uid_map=$(awk '{$1=$1; print}' /proc/self/uid_map 2>/dev/null || true)

  if [[ "$uid_map" == "0 0 4294967295" ]]; then
    ROOTLESS="N"
  else
    ROOTLESS="Y"
  fi

  return 0
}

detectInterface() {

  if [ -n "$DEV" ]; then
    return 0
  fi

  # Give Kubernetes priority over the default interface
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

  NIC=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{ print $2 }')
  BUS=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{ print $2 }')

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

subnetBase() {

  local ip="$1"
  local third=""
  local second=""
  local base=""
  local subnet=""

  third=$(cut -d. -f3 <<< "$ip")

  for second in {30..254}; do
    base="172.$second.$third"
    subnet="$base.0/$PREFIX"

    if ! ip route show "$subnet" 2>/dev/null | grep -q .; then
      echo "$base"
      return 0
    fi
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

  if ! sed 's/^    //' > "$file" <<EOF

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
EOF
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

  if ! sed 's/^    //' > "$file" <<EOF
    auto lo
    iface lo inet loopback
EOF
  then
    error "Failed to write network interface config file: $file"
    return 1
  fi

  while IFS= read -r i; do

    [[ "${i,,}" == "${fa,,}" ]] && continue

    if ! sed 's/^        //' >> "$file" <<EOF

        auto $i
        iface $i inet manual
EOF
    then
      error "Failed to append interface $i to config file: $file"
      return 1
    fi

  done < <(ip -o link show | awk -F': ' '{ print $2 }' | grep -v lo | sed 's/@.*//')

  # Configure bridge
  if ! sed 's/^    //' >> "$file" <<EOF

    auto $fa
    iface $fa inet static
        address $gateway/$PREFIX
        bridge-ports $tap
        bridge-stp off
        bridge-fd 0

    source /etc/network/interfaces.d/*
EOF
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
    error "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN"
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

checkExistingTables() {

  local rules=""
  local conflicts=""

  rules=$(iptables -t filter -S FORWARD 2>/dev/null || true)
  conflicts=$(grep -E -- \
    '^-A FORWARD .*(-j DROP|-j REJECT)( |$)' \
    <<< "$rules" || true)

  if [ -n "$conflicts" ]; then
    local msg="existing firewall rules may block traffic forwarded to or from the VM subnet"

    if enabled "$DEBUG"; then
      warn "${msg}."
    else
      warn "${msg}; enable DEBUG=Y to inspect them."
    fi
  fi

  if enabled "$DEBUG" && [ -n "$rules" ]; then
    printf "Existing filter FORWARD rules:\n\n%s\n\n" "$rules"
  fi

  if enabled "$DEBUG"; then

    rules=$(iptables -t nat -S POSTROUTING 2>/dev/null || true)

    if [ -n "$rules" ]; then
      printf "Existing NAT POSTROUTING rules:\n\n%s\n\n" "$rules"
    fi

  fi

  return 0
}

configureTables() {

  local subnet="$1"
  local rule_tag="remove"
  local tables_err="failed to configure IP tables!"
  local tables="the 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"

  if ! clearTables; then
    error "failed to select a working IP tables backend!"
    return 1
  fi

  checkExistingTables

  # NAT traffic from the VM subnet leaving through any external interface.
  if ! iptables -t nat -A POSTROUTING \
    ! -o "$BRIDGE" \
    -s "$subnet" \
    ! -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j MASQUERADE; then
    error "$tables"
    return 1
  fi

  # Allow traffic from the VM bridge to any external interface.
  if ! iptables -A FORWARD \
    -i "$BRIDGE" \
    ! -o "$BRIDGE" \
    -s "$subnet" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    error "$tables_err"
    return 1
  fi

  # Allow traffic from any external interface to the VM subnet.
  if ! iptables -A FORWARD \
    ! -i "$BRIDGE" \
    -o "$BRIDGE" \
    -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    error "$tables_err"
    return 1
  fi

  return 0
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

    if (( rc != 0 )) ||
      [[ ! -r /proc/sys/net/ipv4/ip_forward ]] ||
      [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      error "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  base=$(subnetBase "$UPLINK") || return 1
  gateway="$base.1"
  subnet=$(networkCIDR "$gateway") || return 1

  if ip route show "$subnet" 2>/dev/null | grep -q .; then
    error "VM subnet $subnet conflicts with an existing route inside the container."
    return 1
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
#  IP tables
# ######################################

setTables() {

  local mode="$1"
  local path=""

  path=$(command -v "iptables-$mode" 2>/dev/null || true)
  [ -z "$path" ] && return 1

  update-alternatives --set iptables "$path" > /dev/null 2>&1
}

testTables() {

  local table=""

  # Test every table required by the networking rules.
  for table in nat filter; do
    iptables -w -t "$table" -S > /dev/null 2>&1 || return 1
    iptables-save -t "$table" > /dev/null 2>&1 || return 1
  done

  return 0
}

selectTables() {

  local mode=""
  local current=""
  local modes=()

  # Keep the currently selected backend when it is fully functional.
  if testTables; then
    return 0
  fi

  current=$(iptables --version 2>/dev/null || true)

  if [[ "$current" == *"nf_tables"* ]]; then
    modes=( "legacy" )
  elif [[ "$current" == *"legacy"* ]]; then
    modes=( "nft" )
  elif [[ "${ENGINE,,}" == "docker" ]]; then
    modes=( "legacy" "nft" )
  else
    modes=( "nft" "legacy" )
  fi

  for mode in "${modes[@]}"; do

    command -v "iptables-$mode" > /dev/null 2>&1 || continue
    setTables "$mode" && testTables && return 0

  done

  return 1
}

clearTables() {

  local table=""
  local line=""
  local rules=""
  local failed="N"
  local rule_tag="remove"
  local re="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  selectTables || return 1

  # Store the current iptables ruleset.
  ! rules=$(iptables-save 2>/dev/null) && return 1

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

      if [[ "$line" == -A* ]] && [[ "$line" =~ $re ]]; then
        line="${line/-A /-D }"

        # Parse the quoting produced by iptables-save before deleting the rule.
        if ! printf '%s\n' "$line" |
          xargs -r iptables -t "$table" > /dev/null 2>&1; then
          failed="Y"
        fi
      fi

    done <<< "$rules"

  fi

  enabled "$failed" && return 1
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

  local mtu=""
  local host=""
  local uplink=""

  uplink=$(formatAddress "$UPLINK" "$PREFIX" || true)
  [ -z "$uplink" ] && uplink="(none)"

  local line="❯ Host: $uplink"

  host=$(containerID)
  [ -n "$host" ] && line+=" ($host)"

  local obvious=""
  if [[ "$uplink" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.[0-9]+$ ]]; then
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
    nameservers=$(grep '^nameserver ' "$file" |
      sed 's/^nameserver //' |
      paste -sd ',' |
      sed 's/,/, /g')
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

prepareNetwork() {

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

detectEngine
detectRootless

disabled "$NETWORK" && return 0

if ! isNAT; then
  error "Unrecognized NETWORK value: \"$NETWORK\""
  exit 48
fi

msg="Initializing network..."
enabled "$DEBUG" && info "$msg"

prepareNetwork
closeInterfaces

# Configure NAT networking
if ! configureNAT; then

  closeInterfaces
  error "failed to setup NAT networking!"
  [[ "$DEBUG" != [Yy1]* ]] && exit 48

else

  enabled "$DEBUG" && info "Initialized network successfully..."

fi

return 0
