#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${DEV:=""}"
: "${MTU:=""}"
: "${TAP:="tap0"}"
: "${NETWORK:="Y"}"
: "${BRIDGE:="vmbr0"}"
: "${MASK:="255.255.255.0"}"

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Generic helpers
# ######################################

enabled() {
  case "$(strip "${1:-}")" in
    Y|y|YES|Yes|yes|TRUE|True|true|1|ON|On|on) return 0 ;;
    *) return 1 ;;
  esac
}

disabled() {
  case "$(strip "${1:-}")" in
    N|n|NO|No|no|FALSE|False|false|0|OFF|Off|off) return 0 ;;
    *) return 1 ;;
  esac
}

isNAT() {

  case "${NETWORK,,}" in
    "tap" | "tun" | "tuntap" | "y" | "" )
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

disableIPv6() {

  local dev="$1"

  [ -d "/proc/sys/net/ipv6/conf/$dev" ] || return 0

  # Best-effort only: Docker/rootless/container sysctl writes can fail.
  sysctl -w "net.ipv6.conf.$dev.disable_ipv6=1" > /dev/null 2>&1 || :
  sysctl -w "net.ipv6.conf.$dev.accept_ra=0" > /dev/null 2>&1 || :

  return 0
}

# ######################################
#  DNS / interface helpers
# ######################################

configureDNS() {

  local fa="$1"
  local ip="$2"
  local mask="$3"
  local gateway="$4"
  local base="${ip%.*}"
  local ip_last="${ip##*.}"
  local gw_last="${gateway##*.}"
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

  # Reserve both the bridge gateway address and the translated container address.
  # The translated address is intentionally excluded from DHCP so it can be used
  # later as a stable container/host identity inside the VM subnet.

  # Determine the sorted positions
  local low high
  if (( ip_last < gw_last )); then
    low=$ip_last
    high=$gw_last
  else
    low=$gw_last
    high=$ip_last
  fi

  # Build dhcp-range lines
  local ranges=""
  (( low > 1 )) && ranges+="dhcp-range=set:${fa},${base}.1,${base}.$((low - 1))"$'\n'
  (( high - low > 1 )) && ranges+="dhcp-range=set:${fa},${base}.$((low + 1)),${base}.$((high - 1))"$'\n'
  (( high < 254 )) && ranges+="dhcp-range=set:${fa},${base}.$((high + 1)),${base}.254"$'\n'
  ranges="${ranges%$'\n'}"  # strip trailing newline

  sed 's/^    //' > "$file" <<EOF

    # Listen only on bridge
    interface=$fa
    bind-interfaces
    except-interface=lo

    # IPv4 DHCP ranges
    $ranges

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

  return 0
}

setInterfaces() {

  local fa="$1"
  local tap="$2"
  local gateway="$3"

  # Add all available network interfaces
  local file="/etc/network/interfaces.new"

  sed 's/^    //' > "$file" <<EOF
    auto lo
    iface lo inet loopback
EOF

  while IFS= read -r i; do

    [[ "${i,,}" == "${fa,,}" ]] && continue

    sed 's/^        //' >> "$file" <<EOF

        auto $i
        iface $i inet manual
EOF

  done < <(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sed 's/@.*//')

  # Configure bridge
  sed 's/^    //' >> "$file" <<EOF

    auto $fa
    iface $fa inet static
        address $gateway/24
        bridge-ports $tap
        bridge-stp off
        bridge-fd 0

    source /etc/network/interfaces.d/*
EOF

  return 0
}

# ######################################
#  Network mode setup
# ######################################

createBridge() {

  local gateway="$1"
  local broadcast="$2"
  local rc

  # Create a bridge with a static IP for the VM LAN
  { ip link add dev "$BRIDGE" type bridge; rc=$?; } || :

  if (( rc != 0 )); then
    error "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if [[ "$LAN_MTU" != "0" ]]; then
    setMTU "$BRIDGE" "$LAN_MTU"
  fi

  if ! ip address add "$gateway/24" broadcast "$broadcast" dev "$BRIDGE"; then
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

  if (( KERNEL > 4 )); then
    # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
    iptables -t mangle -A POSTROUTING \
      -s "$subnet" \
      -p udp \
      --dport bootpc \
      -m comment --comment "$rule_tag" \
      -j CHECKSUM --checksum-fill > /dev/null 2>&1 || true
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

  local ip base
  base=$(cut -d. -f3,4 <<< "$IP")

  if [[ "$IP" != "172.30."* ]]; then
    ip="172.30.$base"
  else
    ip="172.31.$base"
  fi

  local last="${ip##*.}"

  if [[ ! "$last" =~ ^[0-9]+$ ]] || (( last < 2 || last > 254 )); then
    ip="${ip%.*}.4"
  fi

  local gateway="${ip%.*}.1"
  local subnet="${ip%.*}.0/24"
  local broadcast="${ip%.*}.255"

  createBridge "$gateway" "$broadcast" || return 1
  createTap "$tuntap" || return 1

  # Use the lowest effective VM-LAN MTU, without mutating the parent/uplink MTU.
  if [[ "$LAN_MTU" != "0" ]]; then
    LAN_MTU=$(minMTU "$LAN_MTU" "$(getMTU "$BRIDGE")" "$(getMTU "$TAP")")
  fi

  configureTables "$subnet" || return 1

  setInterfaces "$BRIDGE" "$TAP" "$gateway" || return 1
  configureDNS "$BRIDGE" "$ip" "$MASK" "$gateway" || return 1

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

getInfo() {

  if [ -z "$DEV" ]; then
    # Give Kubernetes priority over the default interface
    [ -d "/sys/class/net/net0" ] && DEV="net0"
    [ -d "/sys/class/net/net1" ] && DEV="net1"
    [ -d "/sys/class/net/net2" ] && DEV="net2"
    [ -d "/sys/class/net/net3" ] && DEV="net3"
    # Automatically detect the default network interface
    [ -z "$DEV" ] && DEV=$(awk '$2 == 00000000 { print $1; exit }' /proc/net/route)
    [ -z "$DEV" ] && DEV="eth0"
  fi

  if [ ! -d "/sys/class/net/$DEV" ]; then
    error "Network interface '$DEV' does not exist inside the container!"
    error "$ADD_ERR -e \"DEV=NAME\" to specify another interface name." && exit 26
  fi

  GATEWAY=$(ip route list dev "$DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { IP=$(ip address show dev "$DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); } 2>/dev/null || :
  [ -z "$IP" ] && error "Could not determine container IPv4 address!" && exit 26

  IP6=""
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    { IP6=$(ip -6 addr show dev "$DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  local nic="" bus="" result=""
  result=$(ethtool -i "$DEV" 2>/dev/null || :)

  nic=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $2}')
  bus=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $2}')

  if [[ -n "$bus" && "${bus,,}" != "n/a" && "${bus,,}" != "tap" ]]; then
    enabled "$DEBUG" && info "Detected NIC: ${nic:-unknown}  BUS: $bus"
    error "This container does not support host mode networking!"
    exit 29
  fi

  local mac mtu="" mtu_custom="N"

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

  # Generate MAC address based on Docker container ID in hostname
  HOST="$(hostname -s)"
  mac=$(echo "$HOST" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
  GATEWAY_MAC=$(echo "${mac^^}" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')

  if enabled "$DEBUG"; then
    line="Host: $HOST  IP: $IP  Gateway: $GATEWAY  Interface: $DEV  MTU: $mtu"
    [[ "$MTU" != "0" && "$MTU" != "$mtu" ]] && line+=" ($MTU)"
    info "$line"
    if [ -f /etc/resolv.conf ]; then
      nameservers=$(grep '^nameserver ' /etc/resolv.conf | sed 's/^nameserver //' | paste -sd ',' | sed 's/,/, /g')
      [ -n "$nameservers" ] && info "Nameservers: $nameservers"
    fi
    echo
  fi

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

msg="Initializing network..."
enabled "$DEBUG" && info "$msg"

getInfo
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
