FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates

# Add Proxmox archive keyring
RUN wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
      -O /usr/share/keyrings/proxmox-archive-keyring.gpg && \
    echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" | sha256sum -c -

# Add Proxmox VE no-subscription repository (deb822 format required for Debian 13)
RUN printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n' \
    > /etc/apt/sources.list.d/pve-install-repo.sources

# Prevent services from starting during install
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

# Stub commands unavailable / problematic in Docker build:
#
# unshare: kernel postinst calls "/usr/bin/unshare --mount --propagation private -- cmd"
#   Strip everything up to and including "--", then exec the rest.
#   If no "--" present, consume all args and exit 0.
#
# update-initramfs: called via absolute path /usr/sbin/update-initramfs by kernel hooks.
#   Divert the real binary so the stub is used regardless of PATH.
#
# ifreload: ifupdown2 postinst calls it with unshare for netns reload.
#
# systemctl: silence daemon-reload/enable calls from postinst scripts.
RUN dpkg-divert --local --rename --add /usr/bin/unshare && \
    printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done\n[ "$1" = "--" ] && shift\n[ $# -gt 0 ] && exec "$@"\nexit 0\n' \
      > /usr/bin/unshare && chmod +x /usr/bin/unshare && \
    dpkg-divert --local --rename --add /usr/sbin/update-initramfs && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs && chmod +x /usr/sbin/update-initramfs && \
    dpkg-divert --local --rename --add /usr/sbin/ifreload && \
    printf '#!/bin/sh\nexit 0\n' > /usr/sbin/ifreload && chmod +x /usr/sbin/ifreload && \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/systemctl && chmod +x /usr/local/sbin/systemctl

# pve-manager postinst copies this file — pre-create it so the cp doesn't fail
RUN mkdir -p /usr/share/doc/pve-manager && touch /usr/share/doc/pve-manager/aplinfo.dat

# Pin ifupdown2 to the Proxmox repo — pve-manager checks for their patched version
RUN printf 'Package: ifupdown2\nPin: origin download.proxmox.com\nPin-Priority: 1001\n' \
    > /etc/apt/preferences.d/proxmox-ifupdown2

# Update system and install Proxmox VE
RUN apt-get update && \
    apt-get full-upgrade -y && \
    apt-get install -y \
      proxmox-ve \
      postfix \
      open-iscsi \
      chrony && \
    apt-get remove -y os-prober && \
    # Remove enterprise repo added by Proxmox packages — keep only no-subscription
    rm -f /etc/apt/sources.list.d/pve-enterprise.list \
          /etc/apt/sources.list.d/pve-enterprise.sources \
          /etc/apt/sources.list.d/ceph.list \
          /etc/apt/sources.list.d/ceph.sources && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    # Remove kernel modules and boot files — useless in a container (~960 MB)
    rm -rf /usr/lib/modules /boot && \
    # Remove hardware firmware blobs — no physical hardware in a container (~520 MB)
    rm -rf /usr/lib/firmware && \
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
      /usr/lib/x86_64-linux-gnu/libplacebo.so* && \
    rm -rf \
      /usr/lib/x86_64-linux-gnu/dri \
      /usr/lib/x86_64-linux-gnu/gstreamer-1.0 && \
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
      /usr/share/man

RUN echo 'root:root' | chpasswd

EXPOSE 8006

CMD ["/sbin/init"]
