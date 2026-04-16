# GNU/Linux Machine → Proxmox LXC Container Converter

Converts a running GNU/Linux machine or VM into a Proxmox LXC container by
pulling its filesystem over SSH and importing it with `pct create`.

Tested on **Proxmox VE 7 and 8**.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Run on Proxmox host | Requires the `pct` command |
| Root SSH access to target | `PermitRootLogin yes` in sshd_config |
| `sshpass` | Auto-installed if missing (password auth only) |
| `iproute2` (`ip`) | Standard on Proxmox; replaces deprecated `brctl` |

---

## Installation

```bash
git clone https://github.com/my5t3ry/machine-to-proxmox-lxc-ct-converter.git
cd machine-to-proxmox-lxc-ct-converter
chmod +x convert.sh bashconvert
```

---

## Usage

### Interactive (whiptail TUI)

```bash
./convert.sh
```

You will be prompted for:
- Container ID and hostname
- Target machine SSH address, port, and password
- Bridge interface, IP config (DHCP or static IP/CIDR/gateway)
- OS type (debian, ubuntu, centos, unmanaged, …)
- RootFS size (GB), memory (MB), CPU cores, storage pool
- Container root password
- Privileged vs. unprivileged

### Non-interactive (CLI)

```
./bashconvert --help

Required:
  -n|--name         <hostname>      LXC container hostname
  -t|--target       <address>       Target machine SSH address
  -i|--id           <vmid>          Proxmox container ID
  -s|--root-size    <GB>            Root filesystem size in GB
  -a|--ip           <ip|dhcp>       Container IP or 'dhcp'
  -b|--bridge       <bridge>        Proxmox bridge (e.g. vmbr0)
  -m|--memory       <MB>            Memory in MB
  -d|--disk-storage <pool>          Proxmox storage pool
  -p|--password     <password>      Container root password (min. 5 chars)

Optional:
  -P|--port         <port>          SSH port (default: 22)
  -S|--ssh-password <password>      SSH password (omit for key-based auth)
  -c|--cidr         <prefix>        Subnet prefix (default: 24)
  -g|--gateway      <ip>            Gateway (required for static IP)
  -C|--cores        <n>             CPU cores (default: 1)
  -N|--nameserver   <ip>            DNS nameserver (default: 1.1.1.1)
  -o|--ostype       <type>          debian|ubuntu|centos|fedora|opensuse|
                                    archlinux|alpine|unmanaged (default: unmanaged)
  -u|--unprivileged                 Unprivileged container (recommended)
```

**DHCP, unprivileged, SSH key auth:**
```bash
./bashconvert -n myserver -t 192.168.1.50 -i 200 -s 8 \
  -a dhcp -b vmbr0 -m 512 -C 2 -d local-lvm \
  -p mypassword -o ubuntu -u
```

**Static IP, SSH password auth:**
```bash
./bashconvert -n myserver -t 192.168.1.50 -i 200 -s 8 \
  -a 192.168.9.100 -c 24 -g 192.168.9.1 -b vmbr0 \
  -m 512 -C 2 -d local-lvm -p mypassword -S sshpassword \
  -o debian -u
```

---

## What gets excluded from the archive

The following paths are excluded during the SSH filesystem capture to avoid
special device files (which cause `Cannot mknod` errors in unprivileged
containers) and unnecessary bulk:

| Excluded path | Reason |
|---|---|
| `./sys`, `./dev`, `./proc`, `./run` | Virtual/kernel filesystems |
| `./tmp`, `./var/tmp` | Temporary files |
| `./mnt`, `./media` | External mounts |
| `./lost+found` | fsck artefacts |
| `./var/lib/docker` | Contains block device files (`backingFsBlockDev`) that cannot be `mknod`-ed in an unprivileged namespace |
| `./var/lib/containerd`, `./var/lib/containers` | Same reason as Docker |
| `./var/lib/lxc`, `./var/lib/lxd` | Nested container storage |
| `./var/lib/cni` | Container network interfaces |
| `./var/snap`, `./snap` | Snap loop-mount artefacts |
| `./run/docker`, `./run/containerd` | Runtime sockets/devices |
| `./var/cache/apt/archives` | Apt package cache |
| `./swap.img`, `./swapfile` | Swap files |
| `*.log`, `*.log.*`, `*.gz`, `*.sql` | Logs, compressed files, DB dumps |

---

## Notes

- The container **starts automatically** after creation (`--start 1`).
- **Unprivileged containers** (`-u`) are strongly recommended. Use a privileged container only when the workload specifically requires it (e.g. Docker-in-LXC, some NFS setups).
- **`--rootfs`** uses Proxmox 7/8 syntax: `storage:sizeGB` (e.g. `local-lvm:8`).
- **`--ostype unmanaged`** (default) tells Proxmox not to attempt OS-specific post-setup. Set the correct OS type for better integration (network config, hostname, etc.).
- If the source machine runs Docker and you need to keep `/var/lib/docker`, you must use a **privileged** container — unprivileged containers cannot create block device nodes.
- SSH key auth is supported: omit `-S`/`--ssh-password` and ensure the Proxmox host's root SSH key is authorised on the target.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `pct` not found | Run on the Proxmox host, not inside a VM or LXC |
| `Cannot mknod` / tar exit 2 | Source has Docker/containerd data — already excluded by default. If you added them back, remove them. |
| SSH connection refused | Check port, firewall, `PermitRootLogin yes` in target's `/etc/ssh/sshd_config` |
| `pct create` fails | Check storage pool name and free space; review task log: `journalctl -u pvedaemon` or Proxmox web UI Tasks tab |
| Empty tar archive | SSH connected but `collectFS` failed — check disk space on target with `df -h` |
| Container won't start | Run `pct log <id>` and verify the storage pool is online |
| Network not working in container | Try setting `--ostype` to the correct distro instead of `unmanaged` |
