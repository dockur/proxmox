# syntax=docker/dockerfile:1

FROM --platform=linux/amd64 debian:trixie-slim AS base-amd64
FROM --platform=linux/arm64 debian:trixie-slim AS base-arm64

FROM base-${TARGETARCH} AS base

ARG TARGETARCH
ARG VERSION_ARG="0.0"

ARG DEBCONF_NOWARNINGS="yes"
ARG DEBIAN_FRONTEND="noninteractive"
ARG DEBCONF_NONINTERACTIVE_SEEN="true"

SHELL ["/bin/bash", "-c"]

RUN <<EOF

# Break on errors
set -Eeuo pipefail
apt-get update

# Install prerequisites
apt-get --no-install-recommends -y install \
  jq \
  curl \
  ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*

# Add Proxmox archive keyring
if [[ "$TARGETARCH" == "amd64" ]]; then
  KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
  KEY_PATH="/usr/share/keyrings/proxmox-archive-keyring.gpg"
  URI="http://download.proxmox.com/debian/pve"
  SUITE="trixie"
  COMPONENT="pve-no-subscription"
elif [[ "$TARGETARCH" == "arm64" ]]; then
  KEY_URL="https://mirrors.lierfang.com/pxcloud/lierfang.gpg"
  KEY_PATH="/etc/apt/trusted.gpg.d/lierfang.gpg"
  URI="https://mirrors.lierfang.com/pxcloud/pxvirt"
  SUITE="trixie"
  COMPONENT="main"
fi

curl -fsSL "${KEY_URL}" -o "${KEY_PATH}"

cat > /etc/apt/sources.list.d/pve.sources <<SOURCES
Types: deb
URIs: ${URI}
Suites: ${SUITE}
Components: ${COMPONENT}
Signed-By: ${KEY_PATH}
SOURCES

# Prevent services from starting during install
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Stub commands unavailable / problematic in a Docker build
dpkg-divert --local --rename --add /usr/bin/unshare
printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\n[ "$1" = "--" ] && \
shift\n[ $# -gt 0 ] && exec "$@"\nexit 0\n' > /usr/bin/unshare
chmod +x /usr/bin/unshare
dpkg-divert --local --rename --add /usr/sbin/update-initramfs
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs
chmod +x /usr/sbin/update-initramfs
dpkg-divert --local --rename --add /usr/sbin/ifreload
printf '#!/bin/sh\n[ "$1" = "-V" ] && printf "%%s\n" "ifupdown2:3.3.0-1+pmx12"\nexit 0\n' > /usr/sbin/ifreload
chmod +x /usr/sbin/ifreload
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl
chmod +x /usr/local/sbin/systemctl

# pve-manager postinst copies this file — pre-create it so the cp doesn't fail
mkdir -p /usr/share/doc/pve-manager
touch /usr/share/doc/pve-manager/aplinfo.dat

# Update system and install Proxmox VE
apt-get update
apt-get full-upgrade -y
apt-get install -y --no-install-recommends \
  dbus \
  nano \
  wget \
  sudo \
  htop \
  less \
  iotop \
  gnupg \
  procps \
  chrony \
  postfix \
  ethtool \
  dnsmasq \
  dnsutils \
  sysstat \
  locales \
  iptables \
  iproute2 \
  ifupdown2 \
  net-tools \
  nfs-common \
  cifs-utils \
  proxmox-ve \
  open-iscsi \
  bridge-utils \
  iputils-ping \
  isc-dhcp-client

# Generate locale
locale-gen en_US.UTF-8

# Remove enterprise repo added by Proxmox packages — keep only no-subscription
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/pve-enterprise.sources \
      /etc/apt/sources.list.d/ceph.list \
      /etc/apt/sources.list.d/ceph.sources

# Disable subscription nag popup
if [[ "$TARGETARCH" == "amd64" ]]; then
  wget https://github.com/Jamesits/pve-fake-subscription/releases/download/v0.0.11/pve-fake-subscription_0.0.11+git-1_all.deb -O /tmp/sub.deb -q --timeout=10
  apt-get install -y --no-install-recommends ./tmp/sub.deb && rm -f /tmp/sub.deb
fi

# Prevent system updates
apt-mark hold proxmox-ve

# Cleanup
apt-get remove -y os-prober >/dev/null
SUDO_FORCE_REMOVE=yes apt-get remove -y sudo
apt-get autoremove -y
apt-get clean

# Mask unneeded services
ln -sf /dev/null /etc/systemd/system/watchdog-mux.service
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service

# Disable keyboard request target (for Docker TTY)
cat >/etc/systemd/system/kbrequest.target <<KBR
[Unit]
Description=Keyboard Request Target

[Target]
KBR

# Fix ifupdown2-pre.service for container (no udev)
mkdir -p /etc/systemd/system/ifupdown2-pre.service.d
cat >/etc/systemd/system/ifupdown2-pre.service.d/override.conf << IUD
[Service]
ExecStart=
ExecStart=/bin/true
IUD

# Add keyring for pveam
gpg --keyserver keyserver.ubuntu.com --recv-keys \
    A7BCD1420BFE778E \
    85C25E95A16EB94D \
    39DE63C7D57A32124785E63DB859507D6B1F46D3

gpg --export \
    A7BCD1420BFE778E \
    85C25E95A16EB94D \
    39DE63C7D57A32124785E63DB859507D6B1F46D3 \
    > /usr/share/doc/pve-manager/trustedkeys.gpg

rm -rf /root/.gnupg

# Configure LXC
sed -i 's/^ConditionVirtualization=!container/#&/' /lib/systemd/system/lxcfs.service

# Set listening socket to IPv4 instead of IPv6
echo "LISTEN_IP=\"0.0.0.0\"" >> /etc/default/pveproxy

# Update PVE banner to display the IPv4 address
sed -i "s|https://\${urlip}:8006/|http://localhost:8006|g" /usr/bin/pvebanner
sed -i "s|https://\${localip}:8006/|http://localhost:8006|g" /usr/bin/pvebanner
sed -i "s|the Proxmox Virtual Environment\.|Proxmox for Docker v${VERSION_ARG}.|g" /usr/bin/pvebanner
sed -i "s|the Pxvirt Powered by Lierfang\.|Proxmox for Docker v${VERSION_ARG}.|g" /usr/bin/pvebanner

# Remove kernel modules and boot files — useless in a container (~960 MB)
rm -rf /usr/lib/modules /boot

# Remove hardware firmware blobs — no physical hardware in a container (~520 MB)
rm -rf /usr/lib/firmware

# Remove GPU/display/media libs — no display server, no GPU passthrough needed
rm -f \
  /usr/lib/*/libLLVM*.so* \
  /usr/lib/*/libgallium*.so* \
  /usr/lib/*/libvulkan_*.so* \
  /usr/lib/*/libz3.so* \
  /usr/lib/*/libx265.so* \
  /usr/lib/*/libcodec2.so* \
  /usr/lib/*/libavcodec.so* \
  /usr/lib/*/libavfilter.so* \
  /usr/lib/*/libSvtAv1Enc.so* \
  /usr/lib/*/libplacebo.so*

rm -rf \
  /usr/lib/*/dri \
  /usr/lib/*/gstreamer-1.0

# Remove share assets not needed at runtime
rm -rf \
  /usr/share/pocketsphinx \
  /usr/share/X11 \
  /usr/share/alsa \
  /usr/share/fonts \
  /usr/share/grub \
  /usr/share/groff \
  /usr/share/mime \
  /usr/share/man

# Set username and password
echo "root:root" | chpasswd

# Store version number
echo "$VERSION_ARG" > /etc/version

# Remove stub
rm /usr/local/sbin/systemctl

# Cleanup files
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

EOF

WORKDIR /usr/local/bin
COPY --chmod=755 ./src /usr/local/bin/

ENV PASSWORD="root"

EXPOSE 8006

VOLUME /var/lib/vz
VOLUME /var/lib/pve-cluster

STOPSIGNAL SIGRTMIN+3
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -kLfSs http://localhost:8006 >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/sbin/init", "--log-target=console", "--log-level=notice"]
