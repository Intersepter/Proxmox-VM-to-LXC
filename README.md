# VMs to Proxmox LXC Container Converter

Converts a running GNU/Linux machine or VM into a Proxmox LXC container by pulling its filesystem over SSH and importing it with `pct create`. Works with Proxmox VE 7 and 8.

## Prerequisites

- Must be run on the Proxmox host machine (requires `pct`)
- SSH root access to the target machine
- `sshpass` (auto-installed if missing via `apt-get`)
- `iproute2` (`ip` command) — standard on Proxmox

## Installation

```bash
git clone https://github.com/Intersepter/Proxmox-VM-to-LXC
cd Proxmox-VM-to-LXC
chmod +x convert.sh bashconvert
```

## Usage

### Interactive (whiptail TUI)

```bash
./convert.sh
```

Follow the on-screen prompts. You will be asked for:

- Container ID, hostname
- Target machine SSH address, port, and password
- Bridge interface, IP configuration (DHCP or static IP/CIDR/gateway)
- RootFS size (GB), memory (MB), CPU cores, storage pool
- Container root password
- Privileged vs. unprivileged

### Non-interactive (CLI)

```bash
./bashconvert -h
```

```
Options:
  -h|--help                         Show this help message
  -n|--name         <name>          LXC container hostname
  -t|--target       <ssh_uri>       Target machine SSH address (e.g. 192.168.1.50)
  -P|--port         <port>          Target SSH port (default: 22)
  -i|--id           <id>            Proxmox container ID
  -s|--root-size    <size_gb>       Root filesystem size in GB (e.g. 8)
  -a|--ip           <ip|dhcp>       Container IP address or 'dhcp'
  -c|--cidr         <prefix>        Subnet prefix length (default: 24, ignored if dhcp)
  -b|--bridge       <bridge>        Proxmox bridge interface (e.g. vmbr0)
  -g|--gateway      <gateway_ip>    Gateway IP (ignored if dhcp)
  -m|--memory       <mb>            Memory in MB (e.g. 512)
  -C|--cores        <cores>         Number of CPU cores (default: 1)
  -d|--disk-storage <pool>          Proxmox storage pool (e.g. local-lvm)
  -p|--password     <password>      Container root password (min. 5 chars)
  -S|--ssh-password <password>      Target machine SSH password
  -N|--nameserver   <ip>            DNS nameserver (default: 1.1.1.1)
  -u|--unprivileged                 Create as unprivileged container (recommended)
```

**Example — DHCP, unprivileged:**
```bash
./bashconvert -n myserver -t 192.168.1.50 -P 22 -i 200 -s 8 \
  -a dhcp -b vmbr0 -m 512 -C 2 -d local-lvm \
  -p mypassword -S sshpassword -u
```

**Example — static IP:**
```bash
./bashconvert -n myserver -t 192.168.1.50 -P 22 -i 200 -s 8 \
  -a 192.168.9.100 -c 24 -b vmbr0 -g 192.168.9.1 -m 512 -C 2 \
  -d local-lvm -p mypassword -S sshpassword -u
```

## Notes

- The container is **started automatically** after creation (`--start 1`).
- The following paths are excluded from the filesystem capture: `sys`, `dev`, `run`, `proc`, `tmp`, `lost+found`, `*.log`, `*.gz`, `*.sql`, `swap.img`.
- Unprivileged containers (`-u`) are recommended for security. Some workloads (e.g. Docker-in-LXC) may require a privileged container.
- The `--rootfs` parameter uses Proxmox 7+ syntax: `storage:sizeGB`. Ensure your storage pool supports the size you request.
- If you use SSH key authentication instead of a password, omit `-S` and ensure your Proxmox host's root key is authorised on the target.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `pct` not found | Run on the Proxmox host, not inside a VM/LXC |
| SSH connection refused | Check port, firewall, and that `PermitRootLogin yes` is set on target |
| `pct create` fails | Check storage pool name and available space; review Proxmox task log |
| Empty tar archive | SSH connected but `collectFS` failed — check disk space on target |
| Container won't start | Check `pct log <id>` and ensure the storage pool is online |
