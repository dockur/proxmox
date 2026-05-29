#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${DEBUG:="N"}"         # Disable debugging
: "${PASSWORD:="root"}"   # Default password

# Helper functions

info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

# Check environment
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 11
[ ! -f "/usr/local/bin/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 12

# Display version number
info "Starting Proxmox for Docker v$(</usr/local/bin/version)..."
info "For support visit https://github.com/dockur/proxmox"
echo ""

# Set shm size to 1G to prevent cluster joining issue
mount -o remount,size=1G /dev/shm

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
    if [ "$(uname -m)" = "x86_64" ]; then
      flags=$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo)
      if ! grep -qw "vmx\|svm" <<< "$flags"; then
        KVM_ERR="(not enabled in BIOS)"
      fi
    fi
  fi
fi

if [ -n "$KVM_ERR" ]; then
  error "KVM acceleration is not available $KVM_ERR, see the FAQ for possible causes."
  [[ "${DEBUG:-}" != [Yy1]* ]] && exit 19
fi

# Initialize network
. network.sh

exec "$@"
