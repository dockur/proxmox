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
    "tap" | "tun" | "tuntap" | "y" | "" )
      return 0 ;;
    *)
      return 1 ;;
  esac
}

maskToCIDR() {

  local mask="$1"
  local prefix=""

  prefix=$(ipcalc -p 0.0.0.0 "$mask" | awk -F= '/^PREFIX=/ { print $2 }')

  if [[ ! "$prefix" =~ ^[0-9]+$ ]] || (( prefix < 1 || prefix > 30 )); then
    error "Invalid MASK: '$mask'"
    return 1
  fi

  echo "$prefix"
  return 0
}

networkCIDR() {

  local ip="$1"
  local network=""

  network=$(ipcalc -n "$ip" "$MASK" | awk -F= '/^NETWORK=/ { print $2 }')

  if [ -z "$network" ]; then
    error "Failed to calculate network address from IP '$ip' and netmask '$MASK'."
    return 1
  fi

  echo "$network/$PREFIX"
  return 0
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

  GATEWAY=$(ip route list dev "$DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { UPLINK=$(ip address show dev "$DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); } 2>/dev/null || :

  IP6=""

  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then
    { IP6=$(ip -6 addr show dev "$DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  return 0
}

detectAdapter() {

  local result=""

  NIC=""
  BUS=""

  result=$(ethtool -i "$DEV" 2>/dev/null || :)

  NIC=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $2}')
  BUS=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $2}')

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

  # Best-effort only: Docker/rootless/container sysctl writes can fail.
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

  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sed 's/@.*//')

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
  local rc

  # Create a bridge with a static IP for the VM LAN
  { ip link add dev "$BRIDGE" type bridge; rc=$?; } || :

  if (( rc != 0 )); then
    error "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if [[ "$LAN_MTU" != "0" ]]; then
    setMTU "$BRIDGE" "$LAN_MTU"
  fi

  if ! ip address add "$gateway/$PREFIX" dev "$BRIDGE"; then
    error "failed to add IP address pool!" && return 1
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

  # Set tap to the bridge created
  if ! ip tuntap add dev "$TAP" mode tap; then
    error "$tuntap" && return 1
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
    error "failed to set master bridge!" && return 1
  fi

  return 0
}

configureTables() {

  local subnet="$1"
  local rule_tag="remove"
  local tables_err="failed to configure IP tables!"
  local tables="the 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"

  clearTables

  # NAT traffic from bridge subnet to Docker uplink
  if ! iptables -t nat -A POSTROUTING \
    -o "$DEV" \
    -s "$subnet" \
    ! -d "$subnet" \
    -m comment --comment "$rule_tag" \
    -j MASQUERADE; then
    error "$tables" && return 1
  fi

  # Clamp TCP MSS to avoid subtle MTU blackholes when the outer path has a smaller MTU.
  iptables -t mangle -A FORWARD \
    -s "$subnet" \
    -p tcp \
    --tcp-flags SYN,RST SYN \
    -m comment --comment "$rule_tag" \
    -j TCPMSS --clamp-mss-to-pmtu > /dev/null 2>&1 || true

  # Allow outbound traffic from the Proxmox VM subnet to the Docker uplink.
  if ! iptables -A FORWARD \
    -s "$subnet" \
    -o "$DEV" \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    error "$tables_err" && return 1
  fi

  # Allow return traffic from the Docker uplink back to the Proxmox VM subnet.
  if ! iptables -A FORWARD \
    -d "$subnet" \
    -i "$DEV" \
    -m conntrack --ctstate RELATED,ESTABLISHED \
    -m comment --comment "$rule_tag" \
    -j ACCEPT; then
    error "$tables_err" && return 1
  fi

  return 0
}

configureNAT() {

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"
  local rc

  enabled "$DEBUG" && echo "Configuring NAT networking..."

  # Create the necessary file structure for /dev/net/tun
  if [ ! -c /dev/net/tun ]; then
    [ ! -d /dev/net ] && mkdir -m 755 /dev/net
    if mknod /dev/net/tun c 10 200; then
      chmod 666 /dev/net/tun
    fi
  fi

  [ ! -c /dev/net/tun ] && error "$tuntap" && return 1

  # Check IPv4 port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :
    if (( rc != 0 )) || [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      error "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  local base gateway subnet

  base=$(subnetBase "$UPLINK") || return 1
  gateway="$base.1"
  subnet=$(networkCIDR "$gateway") || return 1

  if ip route show "$subnet" 2>/dev/null | grep -q .; then
    error "VM subnet $subnet conflicts with an existing route inside the container."
    return 1
  fi

  createBridge "$gateway" || return 1
  createTap "$tuntap" || return 1

  # Use the lowest effective VM-LAN MTU, without mutating the parent/uplink MTU.
  if [[ "$LAN_MTU" != "0" ]]; then
    LAN_MTU=$(minMTU "$LAN_MTU" "$(getMTU "$BRIDGE")" "$(getMTU "$TAP")")
  fi

  configureTables "$subnet" || return 1

  setInterfaces "$BRIDGE" "$TAP" "$gateway" || return 1
  configureDNS "$BRIDGE" "$MASK" "$gateway" || return 1

  return 0
}

# ######################################
#  Cleanup
# ######################################

clearTables() {

  local table="" line rules
  local rule_tag="remove"
  local re="--comment[[:space:]]+\"?$rule_tag\"?([[:space:]]|\$)"

  # Choose between iptables or nftables
  if command -v iptables-nft >/dev/null 2>&1 && iptables-nft -V >/dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-nft > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft > /dev/null
  else
    update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null
  fi

  # Store the current iptables ruleset
  ! rules=$(iptables-save 2> /dev/null) && return 0
  [ -z "$rules" ] && return 0

  # Delete every rule tagged with our unique identifier, leaving all other rules intact.
  while IFS= read -r line; do
    case "$line" in
      \*nat)    table="nat" ;;
      \*filter) table="filter" ;;
      \*mangle) table="mangle" ;;
      \*raw)    table="raw" ;;
    esac
    if [[ "$line" == -A* ]]; then
      if [[ "$line" =~ $re ]]; then
        read -ra args <<< "${line/-A /-D }"
        iptables -t "$table" "${args[@]}" &> /dev/null || :
      fi
    fi
  done <<< "$rules"

  return 0
}

closeBridge() {

  ip link set "$TAP" down promisc off &> /dev/null || :
  ip link delete "$TAP" &> /dev/null || :

  ip link set "$BRIDGE" down &> /dev/null || :
  ip link delete "$BRIDGE" &> /dev/null || :

  clearTables
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
  if [[ "$LAN_MTU" != "0" && "$LAN_MTU" -gt "1500" ]] && ! enabled "$mtu_custom"; then
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

  # Keep the guest-facing gateway MAC stable across runs, otherwise Windows guests
  # may detect a new network every boot.
  GATEWAY_MAC=$(gatewayMAC "$MAC")

  return 0
}

printNetworkDebug() {

  local line=""
  local host=""
  local nameservers=""

  enabled "$DEBUG" || return 0

  host=$(hostname -s 2>/dev/null || true)
  [ -z "$host" ] && host="unknown"

  line="Host: $host  IP: $UPLINK  Gateway: $GATEWAY  Interface: $DEV  MAC: $MAC  MTU: $MTU  Mask: $MASK/$PREFIX"
  info "$line"

  if [ -f /etc/resolv.conf ]; then
    nameservers=$(grep '^nameserver ' /etc/resolv.conf | sed 's/^nameserver //' | paste -sd ',' | sed 's/,/, /g')
    [ -n "$nameservers" ] && info "Nameservers: $nameservers"
  fi

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

  printNetworkDebug

  return 0
}

blockLicense() {

  # Block connection attempts to license server
  sed -i -E '/^[[:space:]]*[^#]*[[:space:]]shop\.maurer-it\.com([[:space:]]|$)/d' /etc/hosts 2>/dev/null || true
  printf '%s\n' '127.0.0.1 shop.maurer-it.com' '::1 shop.maurer-it.com' >> /etc/hosts 2>/dev/null || true

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

prepareNetwork
closeBridge

# Configure NAT networking
if ! configureNAT; then

  closeBridge
  error "failed to setup NAT networking!"
  [[ "$DEBUG" != [Yy1]* ]] && exit 48

else

  enabled "$DEBUG" && info "Initialized network successfully..."

fi

return 0
