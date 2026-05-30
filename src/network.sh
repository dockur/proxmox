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
#  Functions
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

  # Determine the sorted positions
  local low high
  if (( ip_last < gw_last )); then
    low=$ip_last; high=$gw_last
  else
    low=$gw_last; high=$ip_last
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
    address=/host.lan/$gateway

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

clearTables() {
  local table="" line rules

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
      local re="--comment[[:space:]]+\"?remove\"?([[:space:]]|\$)"
      if [[ "$line" =~ $re ]]; then
        read -ra args <<< "${line/-A /-D }"
        iptables -t "$table" "${args[@]}" &> /dev/null || :
      fi
    fi
  done <<< "$rules"

  return 0
}

configureNAT() {

  local tuntap="TUN device is missing. $ADD_ERR --device /dev/net/tun"
  local tables="the 'ip_tables' kernel module is not loaded. Try this command: sudo modprobe ip_tables iptable_nat"

  [[ "$DEBUG" == [Yy1]* ]] && echo "Configuring NAT networking..."

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

  local ip base gateway
  base=$(cut -d. -f3,4 <<< "$IP")

  if [[ "$IP" != "172.30."* ]]; then
    ip="172.30.$base"
  else
    ip="172.31.$base"
  fi

  if [[ "$ip" != *".1" ]]; then
    gateway="${ip%.*}.1"
  else
    gateway="${ip%.*}.2"
  fi

  local subnet="${ip%.*}.0/24"
  local broadcast="${ip%.*}.255"

  # Create a bridge with a static IP for the VM guests
  { ip link add dev "$BRIDGE" type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if ! ip address add "$gateway/24" broadcast "$broadcast" dev "$BRIDGE"; then
    error "failed to add IP address pool!" && return 1
  fi

  while ! ip link set "$BRIDGE" up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # Set tap to the bridge created
  if ! ip tuntap add dev "$TAP" mode tap; then
    error "$tuntap" && return 1
  fi

  if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
    if ! ip link set dev "$TAP" mtu "$MTU"; then
      warn "failed to set MTU size to $MTU."
    fi
  fi

  if ! ip link set dev "$TAP" address "$GATEWAY_MAC"; then
    warn "failed to set gateway MAC address."
  fi

  while ! ip link set "$TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  if ! ip link set dev "$TAP" master "$BRIDGE"; then
    error "failed to set master bridge!" && return 1
  fi

  # Flush existing tables
  clearTables

  # NAT traffic from bridge subnet to Docker uplink
  if ! iptables -t nat -A POSTROUTING -o "$DEV" -s "$subnet" ! -d "$subnet" -m comment --comment "remove" -j MASQUERADE; then
    error "$tables" && return 1
  fi

  # Allow forwarding from bridge -> dev
  if ! iptables -A FORWARD -i "$BRIDGE" -o "$DEV" -m comment --comment "remove" -j ACCEPT; then
    error "failed to configure IP tables!" && return 1
  fi

  # Allow return traffic
  if ! iptables -A FORWARD -i "$DEV" -o "$BRIDGE" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "remove" -j ACCEPT; then
    error "failed to configure IP tables!" && return 1
  fi

  setInterfaces "$BRIDGE" "$TAP" "$gateway" || return 1
  configureDNS "$BRIDGE" "$ip" "$MASK" "$gateway" || return 1

  return 0
}

blockLicense() {

  # Block connection attempts to license server
  sed -i -E '/^[[:space:]]*[^#]*[[:space:]]shop\.maurer-it\.com([[:space:]]|$)/d' /etc/hosts 2>/dev/null || true
  printf '%s\n' '127.0.0.1 shop.maurer-it.com' '::1 shop.maurer-it.com' >> /etc/hosts 2>/dev/null || true

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
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    { IP6=$(ip -6 addr show dev "$DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  local result bus
  result=$(ethtool -i "$DEV")
  bus=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $2}')

  if [[ "${bus,,}" != "" && "${bus,,}" != "n/a" && "${bus,,}" != "tap" ]]; then
    [[ "$DEBUG" == [Yy1]* ]] && info "Detected BUS: $bus"
    error "This container does not support host mode networking!"
    exit 29
  fi

  local mac mtu=""

  if [ -f "/sys/class/net/$DEV/mtu" ]; then
    mtu=$(< "/sys/class/net/$DEV/mtu")
  fi

  [ -z "$MTU" ] && MTU="$mtu"
  [ -z "$MTU" ] && MTU="0"

  # Generate MAC address based on Docker container ID in hostname
  HOST="$(hostname -s)"
  mac=$(echo "$HOST" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
  GATEWAY_MAC=$(echo "${mac^^}" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')

  if [[ "$DEBUG" == [Yy1]* ]]; then
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

# ######################################
#  Configure Network
# ######################################

blockLicense

[[ "$NETWORK" == [Nn]* ]] && return 0

msg="Initializing network..."
[[ "$DEBUG" == [Yy1]* ]] && info "$msg"

getInfo
closeBridge

# Configure NAT networking
if ! configureNAT; then

  closeBridge
  error "failed to setup NAT networking!"
  [[ "$DEBUG" != [Yy1]* ]] && exit 48

else

  [[ "$DEBUG" == [Yy1]* ]] && info "Initialized network successfully..."

fi

return 0
