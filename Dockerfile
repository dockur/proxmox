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
  gnupg \
  ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*

# Add Docker archive keyring
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

# Add Proxmox archive keyring
if [ "${TARGETARCH}" = "amd64" ]; then
  KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
  KEY_PATH="/usr/share/keyrings/proxmox-archive-keyring.gpg"
  URI="http://download.proxmox.com/debian/pve"
  SUITE="trixie"
  COMPONENT="pve-no-subscription"
elif [ "${TARGETARCH}" = "arm64" ]; then
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
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ifreload
chmod +x /usr/sbin/ifreload
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl
chmod +x /usr/local/sbin/systemctl

# pve-manager postinst copies this file — pre-create it so the cp doesn't fail
mkdir -p /usr/share/doc/pve-manager
touch /usr/share/doc/pve-manager/aplinfo.dat

# Pin ifupdown2 to the Proxmox repo — pve-manager checks for their patched version
if [ "${TARGETARCH}" = "arm64" ]; then
  PVE_PIN_ORIGIN="mirrors.lierfang.com"
else
  PVE_PIN_ORIGIN="download.proxmox.com"
fi
printf 'Package: ifupdown2\nPin: origin %s\nPin-Priority: 1001\n' "$PVE_PIN_ORIGIN" > /etc/apt/preferences.d/proxmox-ifupdown2

# Update system and install Proxmox VE
apt-get update
apt-get full-upgrade -y
apt-get install -y --no-install-recommends \
  nano \
  wget \
  procps \
  chrony \
  postfix \
  proxmox-ve \
  open-iscsi \
  ethtool \
  dnsmasq \
  iproute2 \
  net-tools \
  iputils-ping \
  docker-ce-cli

# Remove enterprise repo added by Proxmox packages — keep only no-subscription
rm -f /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/pve-enterprise.sources \
      /etc/apt/sources.list.d/ceph.list \
      /etc/apt/sources.list.d/ceph.sources

# Cleanup Find all installed packages starting with proxmox-kernel-
apt-get remove -y os-prober >/dev/null
apt-get autoremove -y
apt-get clean

# Mask unneeded services
systemctl mask systemd-networkd-wait-online.service watchdog-mux.service

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

# Remove kernel modules and boot files — useless in a container (~960 MB)
rm -rf /usr/lib/modules /boot

# Remove hardware firmware blobs — no physical hardware in a container (~520 MB)
rm -rf /usr/lib/firmware

# Remove GPU/display/media libs — no display server, no GPU passthrough needed
rm -f \
  /usr/lib/x86_64-linux-gnu/libLLVM*.so* \
  /usr/lib/x86_64-linux-gnu/libgallium*.so* \
  /usr/lib/x86_64-linux-gnu/libvulkan_*.so* \
  /usr/lib/x86_64-linux-gnu/libz3.so* \
  /usr/lib/x86_64-linux-gnu/libx265.so* \
  /usr/lib/x86_64-linux-gnu/libcodec2.so* \
  /usr/lib/x86_64-linux-gnu/libavcodec.so* \
  /usr/lib/x86_64-linux-gnu/libavfilter.so* \
  /usr/lib/x86_64-linux-gnu/libSvtAv1Enc.so* \
  /usr/lib/x86_64-linux-gnu/libplacebo.so*

rm -rf \
  /usr/lib/x86_64-linux-gnu/dri \
  /usr/lib/x86_64-linux-gnu/gstreamer-1.0

# Remove X11 client libs — no display server in a container
rm -f \
  /usr/lib/*/libX11.so* \
  /usr/lib/*/libXext.so* \
  /usr/lib/*/libXrender.so* \
  /usr/lib/*/libXrandr.so* \
  /usr/lib/*/libXi.so* \
  /usr/lib/*/libXfixes.so* \
  /usr/lib/*/libXcursor.so* \
  /usr/lib/*/libXcomposite.so* \
  /usr/lib/*/libXdamage.so*

# Remove OpenGL/EGL libs — no GPU rendering in a container
rm -f \
  /usr/lib/*/libGL.so* \
  /usr/lib/*/libEGL.so* \
  /usr/lib/*/libGLX.so* \
  /usr/lib/*/libGLESv2.so*

# Remove GTK/Cairo display-stack libs — no GUI toolkit needed in a container
rm -f \
  /usr/lib/*/libcairo*.so* \
  /usr/lib/*/libpango*.so* \
  /usr/lib/*/libgtk-3.so* \
  /usr/lib/*/libgdk-3.so*

# Remove audio libs — no sound output in a container
rm -f \
  /usr/lib/*/libasound.so* \
  /usr/lib/*/libpulse*.so*

# Remove C/C++ headers and static libraries — development artifacts, not needed at runtime
rm -rf /usr/include
find /usr/lib -name '*.a' -delete

# Remove Python bytecode — regenerated on demand, saves space
find /usr -name '*.pyc' -delete
find /usr -name '__pycache__' -type d -delete

# Remove share assets not needed at runtime
rm -rf \
  /usr/share/pocketsphinx \
  /usr/share/X11 \
  /usr/share/alsa \
  /usr/share/fonts \
  /usr/share/grub \
  /usr/share/groff \
  /usr/share/mime \
  /usr/share/doc \
  /usr/share/man \
  /usr/share/info \
  /usr/share/sounds \
  /usr/share/bug \
  /usr/share/lintian \
  /usr/share/common-licenses \
  /usr/share/locale

# Set username and password
echo "root:root" | chpasswd

# Store version number
echo "$VERSION_ARG" > /run/version

# Cleanup files
rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

EOF

COPY --chmod=755 ./entrypoint.sh /run/

ENV PASSWORD="root"

EXPOSE 8006
STOPSIGNAL SIGRTMIN+3

VOLUME /var/lib/vz
VOLUME /var/lib/pve-cluster

HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -kLfSs http://localhost:8006 >/dev/null || exit 1

ENTRYPOINT ["/run/entrypoint.sh"]
CMD ["/sbin/init", "--log-target=console", "--log-level=info"]
