<h1 align="center">Proxmox<br />
<div align="center">
<a href="https://github.com/dockur/proxmox/"><img src="https://github.com/dockur/proxmox/raw/master/.github/logo.png" title="Logo" style="max-width:100%;" width="128" /></a>
</div>
<div align="center">

[![Build]][build_url]
[![Version]][tag_url]
[![Size]][tag_url]
[![Pulls]][hub_url]

</div></h1>

Proxmox inside a Docker container.

## Features ✨

 - Fast virtual machines
 - Isolated LXC containers
 - Web-based management interface

## Usage  🐳

##### Via Docker Compose:

```yaml
services:
  proxmox:
    hostname: pve
    image: dockurr/proxmox
    container_name: proxmox
    environment:
      USERNAME: "root"
      PASSWORD: "root"
    ports:
      - 8006:8006
    restart: always
    privileged: true
    stop_grace_period: 1m
```

##### Via Docker CLI:

```bash
docker run -it --rm --name proxmox --hostname pve -e "USERNAME=root" -e "PASSWORD=root" -p 8006:8006 --privileged --stop-timeout 60 docker.io/dockurr/proxmox
```

##### Via Github Codespaces:

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dockur/proxmox)

## Screenshot 📸

<div align="center">
<a href="https://github.com/dockur/proxmox"><img src="https://raw.githubusercontent.com/dockur/proxmox/master/.github/screenshot.png" title="Screenshot" style="max-width:100%;" width="256" /></a>
</div>

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8006](http://127.0.0.1:8006/) using your web browser.

  - Login using the credentials you specified in the `USERNAME` and `PASSWORD` environment variables.
  
  Enjoy your time with your brand new Proxmox installation, and don't forget to star this repo!

### How can I setup networking for the virtual machines?

  - Go to `System` -> `Network` --> `Create` in the Proxmox web-interface. 
  
  - Create a new `Linux Bridge` called `vmbr0` and set its `IPv4/CIDR` field to the same subnet as your Docker container's bridge network (`172.0.11.0/24` for example).

  - Set the `Gateway` to its `.1` counterpart (`172.0.11.1`), and create the bridge.

  - Create a new virtual machine and assign it a static IP in the range of that subnet, starting from a value of `.100`.

    For example `192.168.2.100`, `192.168.2.101`, etc. as DHCP is not supported.

  - The virtual machine should now be connected to the internet!

### How do I verify if my system supports the KVM virtualization used by Proxmox?

  First check if your software is compatible using this chart:

  | **Product**  | **Linux** | **Win11** | **Win10** | **macOS** |
  |---|---|---|---|---|
  | Docker CLI        | ✅   | ✅       | ❌        | ❌ |
  | Docker Desktop    | ❌   | ✅       | ❌        | ❌ | 
  | Podman CLI        | ✅   | ✅       | ❌        | ❌ | 
  | Podman Desktop    | ✅   | ✅       | ❌        | ❌ | 

  After that you can run the following commands in Linux to check your system:

  ```bash
  sudo apt install cpu-checker
  sudo kvm-ok
  ```

  If you receive an error from `kvm-ok` indicating that KVM cannot be used, please check whether:

  - the virtualization extensions (`Intel VT-x` or `AMD SVM`) are enabled in your BIOS.

  - you enabled "nested virtualization" if you are running the container inside a virtual machine.

  - you are not using a cloud provider, as most of them do not allow nested virtualization for their VPS's.

## Acknowledgements 🙏

Special thanks to [rtedpro-cpu](https://github.com/rtedpro-cpu), this project would not exist without his invaluable work.

## Stars 🌟
[![Stars](https://starchart.cc/dockur/proxmox.svg?variant=adaptive)](https://starchart.cc/dockur/proxmox)

[build_url]: https://github.com/dockur/proxmox/
[hub_url]: https://hub.docker.com/r/dockurr/proxmox/
[tag_url]: https://hub.docker.com/r/dockurr/proxmox/tags
[pkg_url]: https://github.com/dockur/proxmox/pkgs/container/proxmox

[Build]: https://github.com/dockur/proxmox/actions/workflows/build.yml/badge.svg
[Size]: https://img.shields.io/docker/image-size/dockurr/proxmox/latest?color=066da5&label=size
[Pulls]: https://img.shields.io/docker/pulls/dockurr/proxmox.svg?style=flat&label=pulls&logo=docker
[Version]: https://img.shields.io/docker/v/dockurr/proxmox/latest?arch=amd64&sort=semver&color=066da5
[Package]: https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fipitio.github.io%2Fbackage%2Fdockur%2Fproxmox%2Fproxmox.json&query=%24.downloads&logo=github&style=flat&color=066da5&label=pulls
