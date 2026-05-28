#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${NETWORK:="Y"}"

: "${DNSMASQ_OPTS:=""}"
: "${DNSMASQ_DEBUG:=""}"
: "${DNSMASQ:="/usr/sbin/dnsmasq"}"
: "${DNSMASQ_PID:="/var/run/dnsmasq.pid"}"
: "${DNSMASQ_CONF_DIR:="/etc/dnsmasq.d"}"

ADD_ERR="Please add the following setting to your container:"

# ######################################
#  Functions
# ######################################

configureDNS() {

  local fa="$1"
  local ip="$2"
  local mac="$3"
  local host="$4"
  local mask="$5"
  local gateway="$6"
  local arguments="$DNSMASQ_OPTS"

  [[ "${DNSMASQ_DISABLE:-}" == [Yy1]* ]] && return 0
  [[ "$DEBUG" == [Yy1]* ]] && echo "Starting dnsmasq daemon..."

  [ -s "$DNSMASQ_PID" ] && pKill "$(<"$DNSMASQ_PID")"
  rm -f "$DNSMASQ_PID"

  case "${NETWORK,,}" in
    "tap" | "tun" | "tuntap" | "y" )

      # Create lease file for faster resolve
      echo "0 $mac $ip $host 01:$mac" > /var/lib/misc/dnsmasq.leases
      chmod 644 /var/lib/misc/dnsmasq.leases

      # dnsmasq configuration:
      arguments+=" --dhcp-authoritative"

      # Set DHCP range and host
      arguments+=" --dhcp-range=$ip,$ip"
      arguments+=" --dhcp-host=$mac,,$ip,$host,infinite"

      # Set DNS server and gateway
      arguments+=" --dhcp-option=option:netmask,$mask"
      arguments+=" --dhcp-option=option:router,$gateway"
      arguments+=" --dhcp-option=option:dns-server,$gateway"

  esac

  # Set interfaces
  arguments+=" --interface=$fa"
  arguments+=" --bind-interfaces"

  # Workaround NET_RAW capability
  arguments+=" --no-ping"

  # Add DNS entry for container
  arguments+=" --address=/host.lan/$gateway"

  # Set local dns resolver to dnsmasq when needed
  [ -f /etc/resolv.dnsmasq ] && arguments+=" --resolv-file=/etc/resolv.dnsmasq"

  # Enable logging to file
  local log="/var/log/dnsmasq.log"
  rm -f "$log"
  arguments+=" --log-facility=$log"

  arguments=$(echo "$arguments" | sed 's/\t/ /g' | tr -s ' ' | sed 's/^ *//')
  [[ "$DEBUG" == [Yy1]* ]] && printf "Dnsmasq arguments:\n\n%s\n\n" "${arguments// -/$'\n-'}"

  { $DNSMASQ ${arguments:+ $arguments}; rc=$?; } || :

  if (( rc != 0 )); then

    local msg="Failed to start Dnsmasq, reason: $rc"

    if [[ "${NETWORK,,}" == "slirp" || "${NETWORK,,}" == "passt" || "$ROOTLESS" != [Yy1]* || "$DEBUG" == [Yy1]* ]]; then
      [ -f "$log" ] && [ -s "$log" ] && cat "$log"
      error "$msg"
    fi

    return 1
  fi

  if [[ "$DNSMASQ_DEBUG" == [Yy1]* ]]; then
    tail -fn +0 "$log" --pid=$$ &
  fi

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

  if [ ! -c /dev/net/tun ]; then
    warn "$tuntap" && return 1
  fi

  # Check port forwarding flag
  if [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
    { sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; rc=$?; } || :
    if (( rc != 0 )) || [[ $(< /proc/sys/net/ipv4/ip_forward) -eq 0 ]]; then
      warn "IP forwarding is disabled. $ADD_ERR --sysctl net.ipv4.ip_forward=1"
      return 1
    fi
  fi

  local ip base
  base=$(echo "$IP" | sed -r 's/([^.]*.){2}//')
  if [[ "$IP" != "172.30."* ]]; then
    ip="172.30.$base"
  else
    ip="172.31.$base"
  fi

  [ -n "$VM_NET_IP" ] && ip="$VM_NET_IP"

  local gateway=""
  if [[ "$ip" != *".1" ]]; then
    gateway="${ip%.*}.1"
  else
    gateway="${ip%.*}.2"
  fi

  # Create a bridge with a static IP for the VM guest
  { ip link add dev "$VM_NET_BRIDGE" type bridge ; rc=$?; } || :

  if (( rc != 0 )); then
    warn "failed to create bridge. $ADD_ERR --cap-add NET_ADMIN" && return 1
  fi

  if ! ip address add "$gateway/24" broadcast "${ip%.*}.255" dev "$VM_NET_BRIDGE"; then
    warn "failed to add IP address pool!" && return 1
  fi

  # Backwards compatibility
  compat "$gateway" "$VM_NET_BRIDGE" || :

  while ! ip link set "$VM_NET_BRIDGE" up; do
    info "Waiting for IP address to become available..."
    sleep 2
  done

  # QEMU Works with taps, set tap to the bridge created
  if ! ip tuntap add dev "$VM_NET_TAP" mode tap; then
    warn "$tuntap" && return 1
  fi

  if [[ "$MTU" != "0" && "$MTU" != "1500" ]]; then
    if ! ip link set dev "$VM_NET_TAP" mtu "$MTU"; then
      warn "failed to set MTU size to $MTU."
    fi
  fi

  if ! ip link set dev "$VM_NET_TAP" address "$GATEWAY_MAC"; then
    warn "failed to set gateway MAC address.."
  fi

  while ! ip link set "$VM_NET_TAP" up promisc on; do
    info "Waiting for TAP to become available..."
    sleep 2
  done

  if ! ip link set dev "$VM_NET_TAP" master "$VM_NET_BRIDGE"; then
    warn "failed to set master bridge!" && return 1
  fi

  if command -v iptables-nft >/dev/null 2>&1 && iptables-nft -V >/dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-nft > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft > /dev/null
  else
    update-alternatives --set iptables /usr/sbin/iptables-legacy > /dev/null
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy > /dev/null
  fi

  if ! iptables -t nat -A POSTROUTING -o "$VM_NET_DEV" -j MASQUERADE > /dev/null 2>&1; then
    if ! iptables -t nat -A POSTROUTING -o "$VM_NET_DEV" -j MASQUERADE; then
      warn "$tables" && return 1
    fi
  fi

  # shellcheck disable=SC2086
  if ! iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p tcp${exclude} -j DNAT --to "$ip"; then
    warn "failed to configure IP tables!" && return 1
  fi

  if ! iptables -t nat -A PREROUTING -i "$VM_NET_DEV" -d "$IP" -p udp -j DNAT --to "$ip"; then
    warn "failed to configure IP tables!" && return 1
  fi

  if (( KERNEL > 4 )); then
    # Hack for guest VMs complaining about "bad udp checksums in 5 packets"
    iptables -A POSTROUTING -t mangle -p udp --dport bootpc -j CHECKSUM --checksum-fill > /dev/null 2>&1 || true
  fi

  NET_OPTS="-netdev tap,id=hostnet0,ifname=$VM_NET_TAP"

  if [ -c /dev/vhost-net ]; then
    { exec 40>>/dev/vhost-net; rc=$?; } 2>/dev/null || :
    (( rc == 0 )) && NET_OPTS+=",vhost=on,vhostfd=40"
  fi

  NET_OPTS+=",script=no,downscript=no"

  configureDNS "$VM_NET_BRIDGE" "$ip" "$VM_NET_MAC" "$VM_NET_HOST" "$VM_NET_MASK" "$gateway" || return 1

  VM_NET_IP="$ip"
  return 0
}

closeNetwork() {

  [[ "$NETWORK" == [Nn]* ]] && return 0

  [ -s "$DNSMASQ_PID" ] && pKill "$(<"$DNSMASQ_PID")"
  rm -f "$DNSMASQ_PID"

  return 0
}

cleanUp() {

  # Clean up old files
  rm -f "$DNSMASQ_PID"
  rm -f /etc/resolv.dnsmasq

  return 0
}

getInfo() {

  if [ -z "$VM_NET_DEV" ]; then
    # Give Kubernetes priority over the default interface
    [ -d "/sys/class/net/net0" ] && VM_NET_DEV="net0"
    [ -d "/sys/class/net/net1" ] && VM_NET_DEV="net1"
    [ -d "/sys/class/net/net2" ] && VM_NET_DEV="net2"
    [ -d "/sys/class/net/net3" ] && VM_NET_DEV="net3"
    # Automatically detect the default network interface
    [ -z "$VM_NET_DEV" ] && VM_NET_DEV=$(awk '$2 == 00000000 { print $1 }' /proc/net/route)
    [ -z "$VM_NET_DEV" ] && VM_NET_DEV="eth0"
  fi

  if [ ! -d "/sys/class/net/$VM_NET_DEV" ]; then
    error "Network interface '$VM_NET_DEV' does not exist inside the container!"
    error "$ADD_ERR -e \"VM_NET_DEV=NAME\" to specify another interface name." && exit 26
  fi

  GATEWAY=$(ip route list dev "$VM_NET_DEV" | awk ' /^default/ {print $3}' | head -n 1)
  { IP=$(ip address show dev "$VM_NET_DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); rc=$?; } 2>/dev/null || :

  if (( rc != 0 )) && [[ "$DHCP" != [Yy1]* ]]; then
    error "Could not determine container IP address!" && exit 26
  fi

  IP6=""
  # shellcheck disable=SC2143
  if [ -f /proc/net/if_inet6 ] && [ -n "$(ifconfig -a | grep inet6)" ]; then
    { IP6=$(ip -6 addr show dev "$VM_NET_DEV" scope global up); rc=$?; } 2>/dev/null || :
    (( rc != 0 )) && IP6=""
    [ -n "$IP6" ] && IP6=$(echo "$IP6" | sed -e's/^.*inet6 \([^ ]*\)\/.*$/\1/;t;d' | head -n 1)
  fi

  local result nic bus
  result=$(ethtool -i "$VM_NET_DEV")
  nic=$(grep -m 1 -i 'driver:' <<< "$result" | awk '{print $(2)}')
  bus=$(grep -m 1 -i 'bus-info:' <<< "$result" | awk '{print $(2)}')

  if [[ "${bus,,}" != "" && "${bus,,}" != "n/a" && "${bus,,}" != "tap" ]]; then
    [[ "$DEBUG" == [Yy1]* ]] && info "Detected BUS: $bus"
    error "This container does not support host mode networking!"
    exit 29
  fi

  local mtu=""

  if [ -f "/sys/class/net/$VM_NET_DEV/mtu" ]; then
    mtu=$(< "/sys/class/net/$VM_NET_DEV/mtu")
  fi

  [ -z "$MTU" ] && MTU="$mtu"
  [ -z "$MTU" ] && MTU="0"

  if [[ "${ADAPTER,,}" != "virtio-net-pci" ]]; then
    if [[ "$MTU" != "0" ]] && [ "$MTU" -lt "1500" ]; then
      warn "MTU size is $MTU, but cannot be set for $ADAPTER adapters!" && MTU="0"
    fi
  fi

  if [[ "${BOOT_MODE:-}" == "windows_legacy" ]]; then
    if [[ "$MTU" != "0" ]] && [ "$MTU" -lt "1500" ]; then
      warn "MTU size is $MTU, but cannot be set for legacy Windows versions!" && MTU="0"
    fi
  fi

  if [ -z "$MAC" ]; then
    local file="$STORAGE/$PROCESS.mac"
    [ -s "$file" ] && MAC=$(<"$file")
    MAC="${MAC//[![:print:]]/}"
    if [ -z "$MAC" ]; then
      # Generate MAC address based on Docker container ID in hostname
      MAC=$(echo "$HOST" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
      echo "${MAC^^}" > "$file"
      ! setOwner "$file" && error "Failed to set the owner for \"$file\" !"
    fi
  fi

  VM_NET_MAC="${MAC^^}"
  VM_NET_MAC="${VM_NET_MAC//-/:}"

  if [[ ${#VM_NET_MAC} == 12 ]]; then
    m="$VM_NET_MAC"
    VM_NET_MAC="${m:0:2}:${m:2:2}:${m:4:2}:${m:6:2}:${m:8:2}:${m:10:2}"
  fi

  if [[ ${#VM_NET_MAC} != 17 ]]; then
    error "Invalid MAC address: '$VM_NET_MAC', should be 12 or 17 digits long!" && exit 28
  fi

  GATEWAY_MAC=$(echo "$VM_NET_MAC" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')

  if [[ "$DEBUG" == [Yy1]* ]]; then
    line="Host: $HOST  IP: $IP  Gateway: $GATEWAY  Interface: $VM_NET_DEV  MAC: $VM_NET_MAC  MTU: $mtu"
    [[ "$MTU" != "0" && "$MTU" != "$mtu" ]] && line+=" ($MTU)"
    info "$line"
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
cleanUp

# Configure tap interface
if ! configureNAT; then

  closeNetwork

  msg="failed to setup NAT networking!"
  error "$msg" && exit 48

fi

[[ "$DEBUG" == [Yy1]* ]] && info "Initialized network successfully..."
return 0
