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
      PASSWORD: "root"
    ports:
      - 8006:8006
    volumes:
      - ./storage:/var/lib/vz
      - ./config:/var/lib/pve-cluster
      - /var/run/docker.sock:/var/run/docker.sock
    restart: always
    privileged: true
    stop_grace_period: 1m
```

##### Via Docker CLI:

```bash
docker run -it --rm --name proxmox --hostname pve --privileged -e "PASSWORD=root" -p 8006:8006 -v "${PWD:-.}/storage:/var/lib/vz" -v "${PWD:-.}/config:/var/lib/pve-cluster" -v "/var/run/docker.sock:/var/run/docker.sock" --stop-timeout 60 docker.io/dockurr/proxmox
```

##### Via Github Codespaces:

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/dockur/proxmox)

## Screenshots 📸

<div align="center">
<a href="https://github.com/dockur/proxmox"><img src="https://raw.githubusercontent.com/dockur/proxmox/master/.github/screenshot.png" title="Screenshot" style="max-width:100%;" width="256" /></a>
</div>

<div align="center">
<a href="https://github.com/dockur/proxmox"><img src="https://raw.githubusercontent.com/dockur/proxmox/master/.github/screenshot2.png" title="Screenshot" style="max-width:100%;" width="256" /></a>
</div>

## FAQ 💬

### How do I use it?

  Very simple! These are the steps:
  
  - Start the container and connect to [port 8006](http://127.0.0.1:8006/) using your web browser.

  - Login using the username `root` and the password you specified in the `PASSWORD` environment variable.
  
  Enjoy your time with your brand new Proxmox installation, and don't forget to star this repo!

### How do I change the location of the storage pool?

  To change the storage location for the `local` storage pool used by Proxmox, include the following bind mount in your compose file:

  ```yaml
  volumes:
    - ./storage:/var/lib/vz
  ```

  Replace the example path `./storage` with the desired storage folder or named volume. All large objects (like disk files and .iso images) will be stored here.

### How do I change the location of the configuration database?

  To change the location for the Proxmox VE configuration database, include the following bind mount in your compose file:
  
  ```yaml
  volumes:
    - ./config:/var/lib/pve-cluster
  ```

  Replace the example path `./config` with the desired storage folder or named volume.

### How can I setup networking for the virtual machines?

  - In the Proxmox web-interface, go to `Datacenter` -> `pve` --> `System` -> `Network`.
  
  - There is a `Linux Bridge` called `docker0`, look at the `IPv4/CIDR` column and remember its subnet, for example `172.20.0.0/16`

  - Attach the `docker0` bridge network to your virtual machine, start that machine and view its screen.
 
  - Configure the OS for a static IP instead of DHCP, and give it a fixed address inside the subnet of the `docker0` bridge.

    Always start from a value of `.100`, so for example pick `172.20.0.100` for the first machine if the subnet was `172.20.0.0/16`.

    Set the gateway address to the first address within the subnet, so for example set it to `172.20.0.0` if the subnet was `172.20.0.0/16`.

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
