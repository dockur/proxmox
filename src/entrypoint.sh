#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables
: "${DEBUG:="N"}"            # Enable debugging
: "${PASSWORD:="root"}"      # Default password
: "${REQUIRE_KVM:="Y"}"      # Require /dev/kvm by default
: "${REQUIRE_FUSE:="Y"}"     # Require /dev/fuse by default
: "${SHM_SIZE:="1G"}"        # Remount /dev/shm to this size

# Helper functions
info () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
error () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; }
warn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }

is_enabled() {
  case "${1:-}" in
    Y|y|YES|yes|TRUE|true|1|ON|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    error "Required command not found: $1"
    exit 21
  }
}

require_file() {
  [ -f "$1" ] || {
    error "Required file not found: $1"
    exit 22
  }
}

continue_or_exit() {
  local code="$1"

  if is_enabled "$DEBUG"; then
    warn "DEBUG is enabled (DEBUG=${DEBUG}), continuing despite previous error."
    return 0
  fi

  exit "$code"
}

check_privileged() {
  local cap_bnd
  local last_cap
  local max_cap

  cap_bnd="$(grep '^CapBnd:' /proc/$$/status | awk '{print $2}')"
  cap_bnd="$(printf "%d" "0x${cap_bnd}")"

  last_cap="$(cat /proc/sys/kernel/cap_last_cap)"
  max_cap="$(((1 << (last_cap + 1)) - 1))"

  if [ "$cap_bnd" -ne "$max_cap" ]; then
    error "Please start the container with the --privileged flag!"
    continue_or_exit 14
  fi
}

check_fuse() {
  if ! is_enabled "$REQUIRE_FUSE"; then
    return 0
  fi

  if [ ! -c /dev/fuse ]; then
    error "Could not access /dev/fuse. Make sure the fuse kernel module is loaded and /dev/fuse is passed into the container."
    continue_or_exit 16
  fi

  if [ ! -r /dev/fuse ] || [ ! -w /dev/fuse ]; then
    error "/dev/fuse exists but is not readable/writable."
    continue_or_exit 17
  fi
}

check_kvm() {
  local kvm_err=""
  local flags=""

  if ! is_enabled "$REQUIRE_KVM"; then
    return 0
  fi

  if [ ! -e /dev/kvm ]; then
    kvm_err="(/dev/kvm is missing)"
  elif [ ! -c /dev/kvm ]; then
    kvm_err="(/dev/kvm is not a character device)"
  elif [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    kvm_err="(/dev/kvm is not readable/writable)"
  elif ! sh -c 'echo -n > /dev/kvm' >/dev/null 2>&1; then
    kvm_err="(/dev/kvm is not usable from inside the container)"
  elif [ "$(uname -m)" = "x86_64" ]; then
    flags="$(sed -ne '/^flags/s/^.*: //p' /proc/cpuinfo | head -n1 || true)"

    if ! grep -Eqw 'vmx|svm' <<< "$flags"; then
      kvm_err="(hardware virtualization flag vmx/svm is missing)"
    fi
  fi

  if [ -n "$kvm_err" ]; then
    error "KVM acceleration is not available $kvm_err."
    continue_or_exit 19
  fi
}

check_cgroups() {
  if [ ! -d /sys/fs/cgroup ]; then
    error "/sys/fs/cgroup is missing. systemd inside the container will not work correctly."
    continue_or_exit 25
  fi

  if [ ! -w /sys/fs/cgroup ]; then
    warn "/sys/fs/cgroup is not writable. systemd or nested services may fail unless the container is configured with writable cgroups."
  fi

  if [ ! -f /sys/fs/cgroup/cgroup.controllers ] && [ ! -d /sys/fs/cgroup/system.slice ]; then
    warn "Could not clearly detect cgroup v2 or a systemd cgroup hierarchy."
  fi
}

check_systemd_command() {
  if [ "$#" -eq 0 ]; then
    error "No command specified. This image should normally be started with systemd as PID 1."
    exit 26
  fi

  case "$1" in
    /sbin/init|/lib/systemd/systemd|/usr/lib/systemd/systemd|systemd|init)
      return 0
      ;;
    *)
      warn "Container command is '$*'. For Proxmox VE this should usually be systemd, for example: /sbin/init"
      ;;
  esac
}

remount_shm() {
  if [ ! -d /dev/shm ]; then
    warn "/dev/shm does not exist."
    return 0
  fi

  if ! mountpoint -q /dev/shm; then
    warn "/dev/shm is not a mountpoint."
    return 0
  fi

  if ! mount -o "remount,size=${SHM_SIZE}" /dev/shm; then
    warn "Could not remount /dev/shm with size=${SHM_SIZE}."
  fi
}

set_timezone() {
  local zone="$1"

  if [ ! -f "/usr/share/zoneinfo/$zone" ]; then
    echo "Invalid timezone: $zone" >&2
    exit 18
  fi

  ln -snf "/usr/share/zoneinfo/$zone" /etc/localtime
  echo "$zone" > /etc/timezone
}

check_localtime() {
  if [ ! -e /etc/localtime ] && [ ! -L /etc/localtime ]; then
    return 1
  fi

  local target
  target="$(readlink -f /etc/localtime 2>/dev/null || true)"

  if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -s "$target" ]; then
    echo "Invalid TZ value." >&2
    exit 1
  fi

  return 0
}

prepare_directory() {
  local path="$1"
  local owner="$2"
  local mode="${3:-}"

  mkdir -p "$path"
  chown "$owner" "$path" || :

  if [ -n "$mode" ]; then
    chmod "$mode" "$path" || :
  fi
}

cleanup_stale_runtime_files() {
  rm -f \
    /run/pveproxy/pveproxy.pid \
    /run/pvedaemon/pvedaemon.pid \
    /run/pvestatd.pid \
    /run/qmeventd.pid \
    /run/pve-cluster.pid \
    /run/pmxcfs.pid \
    /run/corosync.pid \
    /run/rrdcached.pid \
    /run/watchdog-mux.pid \
    /run/pve-firewall.pid \
    /run/lxcfs.pid \
    /run/postfix/master.pid \
    /var/spool/postfix/pid/master.pid \
    /proxmox.end 2>/dev/null || :
}

# Check environment
[ "$(id -u)" -ne "0" ] && error "Script must be executed with root privileges." && exit 11
[ ! -f "/usr/local/bin/entrypoint.sh" ] && error "Script must be run inside the container!" && exit 12

# Check basic required commands.
require_cmd awk
require_cmd grep
require_cmd mount
require_cmd mountpoint
require_cmd chpasswd

# Display version number
info "Starting Proxmox for Docker v$(</etc/version)..."
info "For support visit https://github.com/dockur/proxmox"
echo ""

# Check command before doing one-time setup.
check_systemd_command "$@"

# Update password for root
printf 'root:%s\n' "$PASSWORD" | chpasswd

# Runtime checks
check_privileged
check_cgroups
check_fuse
check_kvm

# Set shm size to prevent cluster joining issues.
remount_shm

# If missing timezone and localtime set them.
if [ -n "${TZ:-}" ]; then
  set_timezone "$TZ"
elif ! check_localtime; then
  set_timezone "UTC"
fi

# Initialize network
# shellcheck source=src/network.sh
. /usr/local/bin/network.sh

# Ensure directory permissions.
prepare_directory "/var/lib/vz" "root:root" "0755"
prepare_directory "/var/lib/pve-cluster" "root:root" "0755"
prepare_directory "/var/log/pveproxy" "www-data:www-data" "0750"

# Common runtime directories used by PVE services.
prepare_directory "/run/pveproxy" "www-data:www-data" "0755"
prepare_directory "/run/pvedaemon" "root:root" "0755"
prepare_directory "/run/pve-cluster" "root:root" "0755"
prepare_directory "/run/lock" "root:root" "1777"
prepare_directory "/run/lock/lxc" "root:root" "0755"

# Remove stale runtime files from unclean container stops.
cleanup_stale_runtime_files

echo "Booting Proxmox VE..."
exec "$@"
