#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${NETWORK:="Y"}"

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Functions
# ######################################

configureDNS() {

  local fa="$1"
  local ip="$2"
  local mask="$3"
  local gateway="$4"

  cat >"/etc/dnsmasq.d/$fa.conf" <<EOF

  # Listen only on bridge
  interface=$fa
  bind-interfaces
  except-interface=lo

  # IPv4 DHCP range
  dhcp-range=set:$fa,$ip,${ip%.*}.255

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

  if ! systemctl enable dnsmasq; then
    error "Failed to enable dnsmasq!" && return 1
  fi

  return 0
}

setInterfaces() {

  local fa="$1"
  local tap="$2"
  local subnet="$3"
  local gateway="$4"

  # Add all available network interfaces
  local file="/etc/network/interfaces.new"

  echo "auto lo" > "$file"
  echo "iface lo inet loopback" >> "$file"

  while IFS= read -r i; do

    [[ "${i,,}" == "${fa,,}" ]] && continue

    echo "" >> "$file"
    echo "auto $i" >> "$file"
    echo "iface $i inet manual" >> "$file"

  done <<< $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sed 's/@.*//')

  echo "" >> "$file"

  # Configure bridge
  echo "auto $fa" >> "$file"
  echo "iface $fa inet static" >> "$file"
  echo "        address $subnet" >> "$file"
  echo "        bridge-ports $tap" >> "$file"
  echo "        bridge-stp off" >> "$file"
  echo "        bridge-fd 0" >> "$file"
  echo "" >> "$file"

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

  local ip base
  local tap="tap0"
  local gateway=""
  local bridge="docker0"
  local mask="255.255.255.0"

  base=$(echo "$IP" | sed -r 's/([^.]*.){2}//')

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

  local subnet="$gateway/24"
  local broadcast="${ip%.*}.255"

  # Create a bridge with a static IP for the VM guests
  { ip link add dev "$bridge" type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    error "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if ! ip address add "$subnet" broadcast "$broadcast" dev "$bridge"; then
    error "failed to add IP address pool!" && return 1
  fi

  while ! ip link set "$bridge" up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # Set tap to the bridge created
  if ! ip tuntap add dev "$tap" mode tap; then
    error "$tuntap" && return 1
  fi

  #if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
  #  if ! ip link set dev "$tap" mtu "$MTU"; then
  #    warn "failed to set MTU size to $MTU."
  #  fi
  #fi

  #if ! ip link set dev "$tap" address "$GATEWAY_MAC"; then
  #  warn "failed to set gateway MAC address.."
  #fi

  while ! ip link set "$tap" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  if ! ip link set dev "$tap" master "$bridge"; then
    error "failed to set master bridge!" && return 1
  fi

  # Choose between iptables or nftables
  if command -v iptables-nft >/dev/null 2>&1 && iptables-nft -V >/dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-nft > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft > /dev/null
  else
    update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null
  fi

  # NAT traffic from bridge subnet to Docker uplink
  if ! iptables -t nat -A POSTROUTING -o "$DEV" -s "$subnet" ! -d "$subnet" -j MASQUERADE; then
    error "$tables" && return 1
  fi

  # Allow forwarding from bridge -> dev
  if ! iptables -A FORWARD -i "$bridge" -o "$DEV" -j ACCEPT; then
    error "$tables" && return 1
  fi

  # Allow return traffic
  if ! iptables -A FORWARD -i "$DEV" -o "$bridge" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; then
    error "$tables" && return 1
  fi

  configureDNS "$bridge" "$ip" "$mask" "$gateway" || return 1
  setInterfaces "$bridge" "$tap" "$subnet" "$gateway" || return 1

  return 0
}

getInfo() {

  DEV=""

  if [ -z "$DEV" ]; then
    # Give Kubernetes priority over the default interface
    [ -d "/sys/class/net/net0" ] && DEV="net0"
    [ -d "/sys/class/net/net1" ] && DEV="net1"
    [ -d "/sys/class/net/net2" ] && DEV="net2"
    [ -d "/sys/class/net/net3" ] && DEV="net3"
    # Automatically detect the default network interface
    [ -z "$DEV" ] && DEV=$(awk '$2 == 00000000 { print $1 }' /proc/net/route)
    [ -z "$DEV" ] && DEV="eth0"
  fi

  if [ ! -d "/sys/class/net/$DEV" ]; then
    error "Network interface '$DEV' does not exist inside the container!"
    error "$ADD_ERR -e \"DEV=NAME\" to specify another interface name." && exit 26
  fi

  GATEWAY=$(ip route list dev "$DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { IP=$(ip address show dev "$DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); rc=$?; } 2>/dev/null || :

  if (( rc != 0 )); then
    error "Could not determine container IP address!" && exit 26
  fi

  IP6=""
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    { IP6=$(ip -6 addr show dev "$DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  local result nic bus
  result=$(ethtool -i "$DEV")
  nic=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $(2)}')
  bus=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $(2)}')

  if [[ "${bus,,}" != "" && "${bus,,}" != "n/a" && "${bus,,}" != "tap" ]]; then
    [[ "$DEBUG" == [Yy1]* ]] && info "Detected BUS: $bus"
    error "This container does not support host mode networking!"
    exit 29
  fi

  if [[ "$DEBUG" == [Yy1]* ]]; then
    HOST="$(hostname -s)"
    info "Host: $HOST  IP: $IP  Gateway: $GATEWAY  Interface: $DEV"
    if [ -f /etc/resolv.conf ]; then
      nameservers=$(grep '^nameserver*' /etc/resolv.conf | head -c -1 | sed 's/nameserver //g;' | sed -z 's/\n/, /g')
      [ -n "$nameservers" ] && info "Nameservers: $nameservers"
    fi
    echo
  fi

  return 0
}

# ######################################
#  Configure Network
# ######################################

[[ "$NETWORK" == [Nn]* ]] && return 0

msg="Initializing network..."
[[ "$DEBUG" == [Yy1]* ]] && info "$msg"

getInfo

# Configure NAT networking
if ! configureNAT; then

  error "failed to setup NAT networking!"
  [[ "$DEBUG" != [Yy1]* ]] && exit 48

else

  [[ "$DEBUG" == [Yy1]* ]] && info "Initialized network successfully..."

fi

return 0
