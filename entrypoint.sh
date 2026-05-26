#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${PASSWORD:="root"}"

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

# Check environment
[ ! -f "/run/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 11
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 12

# Display version number
echo "❯ Starting Proxmox for Docker v$(</run/version)..."
echo "❯ For support visit https://github.com/dockur/proxmox"

# Get the capability bounding set
CAP_BND=$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')
CAP_BND=$(printf "%d" "0x${CAP_BND}")

# Get the last capability number
LAST_CAP=$(cat /proc/sys/kernel/cap_last_cap)

# Calculate the maximum capability value
MAX_CAP=$(((1 << (LAST_CAP + 1)) - 1))

if [ "${CAP_BND}" -ne "${MAX_CAP}" ]; then
  error "Please start the container with the --privileged flag!"
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 14
fi

# Check if /dev/fuse is available
if [ ! -c /dev/fuse ]; then
  error "Could not access /dev/fuse, make sure this kernel module is loaded!"
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 16
fi

# Check KVM support
KVM_ERR=""

if [ ! -e /dev/kvm ]; then
  KVM_ERR="(/dev/kvm is missing)"
else
  if ! sh -c 'echo -n > /dev/kvm' &> /dev/null; then
    KVM_ERR="(/dev/kvm is unwriteable)"
  else
    flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
    if ! grep -qw "vmx\|svm" <<< "$flags"; then
      KVM_ERR="(not enabled in BIOS)"
    fi
  fi
fi

if [ -n "$KVM_ERR" ]; then
  error "KVM acceleration is not available $KVM_ERR, see the FAQ for possible causes."
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 19
fi

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

# Modify setting for LXC containers
file="/lib/systemd/system/lxcfs.service"

if grep -qE '^[[:space:]]*ConditionVirtualization' "$file"; then

    # Comment the line if it is not already commented
    sed -i '/^[[:space:]]*ConditionVirtualization/ {
        /^[[:space:]]*#/! s/^[[:space:]]*/#/
    }' "$file"

fi

# Automaticly add network interfaces
file="/tmp/interfaces.tmp"

echo "auto lo" > "$file"
echo "iface lo inet loopback" >> "$file"
echo "" >> "$file"

ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sed 's/@.*//' | while IFS= read -r i; do
  
  printf 'auto %s\niface %s inet manual\n\n' "$i" "$i" >> "$file"

done

NET_DEV=""

# Give Kubernetes priority over the default interface
[ -d "/sys/class/net/net0" ] && NET_DEV="net0"
[ -d "/sys/class/net/net1" ] && NET_DEV="net1"
[ -d "/sys/class/net/net2" ] && NET_DEV="net2"
[ -d "/sys/class/net/net3" ] && NET_DEV="net3"

# Automatically detect the default network interface
[ -z "$NET_DEV" ] && NET_DEV=$(awk '$2 == 00000000 { print $1 }' /proc/net/route)
[ -z "$NET_DEV" ] && NET_DEV="eth0"

if [ ! -d "/sys/class/net/$NET_DEV" ]; then
  error "Network interface '$NET_DEV' does not exist inside the container!" && exit 26
fi

# Detect IP address
{ IP=$(ip address show dev "$NET_DEV" | grep inet | awk '/inet / { print $2 }' | cut -f1 -d/ | head -n 1); rc=$?; } 2>/dev/null || :

if (( rc != 0 )); then
  error "Could not determine container IP address!" && exit 27
fi

# Create bridge 
echo "auto docker0" >> "$file"
echo "iface docker0 inet static" >> "$file"
echo "        address ${IP%.*}.0/24" >> "$file"
echo "        gateway ${IP%.*}.1" >> "$file"
echo "        bridge-ports $NET_DEV" >> "$file"
echo "        bridge-stp off" >> "$file"
echo "        bridge-fd 0" >> "$file"

ifdown --all --allow auto
ifdown --all --allow hotplug

# Apply configuration
cp "$file" /etc/network/interfaces

ifup --all --allow auto
ifup --all --allow hotplug

exec /sbin/init 3
