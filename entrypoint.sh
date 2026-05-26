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
info "❯ Starting Proxmox for Docker v$(</run/version)..."
info "❯ For support visit https://github.com/dockur/proxmox"
echo ""

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

# Get the capability bounding set
CAP_BND=$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')
CAP_BND=$(printf "%d" "0x${CAP_BND}")

# Get the last capability number
LAST_CAP=$(cat /proc/sys/kernel/cap_last_cap)

# Calculate the maximum capability value
MAX_CAP=$(((1 << (LAST_CAP + 1)) - 1))

# Check if container is privileged
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

# Modify setting for LXC containers
file="/lib/systemd/system/lxcfs.service"

if grep -qE '^[[:space:]]*ConditionVirtualization' "$file"; then

    # Comment the line if it is not already commented
    sed -i '/^[[:space:]]*ConditionVirtualization/ {
        /^[[:space:]]*#/! s/^[[:space:]]*/#/
    }' "$file"
fi

# Check if Docker socket is available
if [ ! -S /var/run/docker.sock ]; then

  error "Docker socket is missing? Please bind /var/run/docker.sock in your compose file." 
  warn "will skip networking configuration, as it requires the Docker socket to be available."

else

  # Create a bridge network called proxnet if not exist
  
  net="proxnet"
  docker network rm "$net" &>/dev/null || true
  
  if ! docker network inspect "$net" &>/dev/null; then
  
    if ! docker network create --driver=bridge "$net" >/dev/null; then
      error "Failed to create bridge network '$net'!" && exit 29
    fi
  
    if ! docker network inspect "$net" &>/dev/null; then
      error "Bridge network '$net' does not exist?" && exit 30
    fi
  fi
  
  # Determine container name
  target=$(hostname -s)
  target=$(
    docker ps -aq |
    xargs docker inspect -f '{{.Name}} {{.Config.Hostname}}' |
    awk -v t="$target" '$2 == t {print $1}' |
    tail -c +2
  )

  # Check if container name is valid
  if ! docker inspect "$target" &>/dev/null; then
    error "Failed to find a container with name: '$target'!" && exit 31
  fi
  
  resp=$(docker inspect "$target")
  network=$(echo "$resp" | jq -r ".[0].NetworkSettings.Networks[\"$net\"]")
  
  if [ -z "$network" ] || [[ "$network" == "null" ]]; then
    if ! docker network connect "$net" "$target"; then
      error "Failed to connect container to bridge network '$net'!" && exit 32
    fi
  fi
  
  # Determine subnet and gateway
  inspect=$(docker network inspect "$net")
  subnet=$(echo "$inspect" | jq -r '.[0].IPAM.Config[0].Subnet')
  gateway=$(echo "$inspect" | jq -r '.[0].IPAM.Config[0].Gateway')
  
  # Automaticly add all network interfaces
  file="/etc/network/interfaces.new"
  
  echo "auto lo" > "$file"
  echo "iface lo inet loopback" >> "$file"
  
  while IFS= read -r i; do
  
    echo "" >> "$file"
    echo "auto $i" >> "$file"
    echo "iface $i inet manual" >> "$file"

  # shellcheck disable=SC2046
  done <<< $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | sed 's/@.*//')
  
  echo "" >> "$file"
  
  # Determine which interface is our bridge network
  bridge=""
  base="${subnet%.*}."
  
  while read -r _ iface _ addr _; do
  
    # Check if IP belongs to our subnet
    if [[ "${addr%.*}.${subnet/$base/}" == "$subnet" ]]; then
  
      if [ -z "$bridge" ]; then
        bridge="$iface"
      else
        error "Found multiple interfaces to our bridge network?"
      fi
  
    fi

  # shellcheck disable=SC2046 
  done <<< $(ip -o -4 addr show)
  
  [ -z "$bridge" ] && error "Could not find interface of bridge?" && exit 35
  
  # Configure bridge
  echo "auto docker0" >> "$file"
  echo "iface docker0 inet static" >> "$file"
  echo "        address $subnet" >> "$file"
  echo "        gateway $gateway" >> "$file"
  echo "        bridge-ports $bridge" >> "$file"
  echo "        bridge-stp off" >> "$file"
  echo "        bridge-fd 0" >> "$file"
  echo "" >> "$file"

fi

# Boot systemd
exec /sbin/init 3
