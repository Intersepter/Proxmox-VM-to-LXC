#!/bin/bash

checkList()
{
    # Check if running as root
    if [ "$(whoami)" != "root" ]; then
        echo -e "\e[96mNot running as root. Re-launching with sudo...\e[39m"
        sudo -E bash "$0" "$@"
        exit $?
    fi

    # Must run on the Proxmox host
    if ! command -v pct &> /dev/null; then
        whiptail --title "Error" --msgbox \
            "The 'pct' command could not be found.\nThis script must be run on the Proxmox host machine." \
            10 60
        exit 1
    fi

    # Install sshpass if missing
    if ! command -v sshpass &> /dev/null; then
        echo "Installing sshpass..."
        apt-get install -y sshpass
        if [ $? -ne 0 ]; then
            whiptail --title "Error" --msgbox "Failed to install 'sshpass'. Exiting." 10 60
            exit 1
        fi
    fi

    # iproute2 required (replaces deprecated brctl)
    if ! command -v ip &> /dev/null; then
        whiptail --title "Error" --msgbox \
            "The 'ip' command could not be found. Please install iproute2." \
            10 60
        exit 1
    fi
}

welcome()
{
    whiptail --title "GNU/Linux Machine to Proxmox LXC Container Converter" --msgbox \
"This script converts a running Linux machine into a Proxmox LXC container
by pulling its filesystem over SSH and importing it with 'pct create'.

Requirements:
  - Must run on the Proxmox host (requires 'pct')
  - Root SSH access to the target machine
  - sshpass (auto-installed if missing)
  - iproute2 (standard on Proxmox)

For non-interactive use: ./bashconvert -h

Repository: https://github.com/my5t3ry/machine-to-proxmox-lxc-ct-converter" \
    20 70
}

# Generic text input with optional default
createMenu()
{
    local title=$1
    local prompt=$2
    local default=${3:-""}
    local input

    input=$(whiptail --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        whiptail --title "Cancelled" --msgbox "Operation cancelled. Exiting." 8 40
        exit 1
    fi
    echo "$input"
}

# List vmbr* bridges using 'ip link' (brctl removed from Proxmox 8)
selectBridge()
{
    local bridges=()
    while IFS= read -r line; do
        bridges+=("$line")
    done < <(ip link show type bridge | awk -F': ' '/^[0-9]+:/{print $2}' | grep '^vmbr')

    if [ ${#bridges[@]} -eq 0 ]; then
        whiptail --title "Error" --msgbox \
            "No Proxmox bridge interfaces (vmbr*) found." 8 50
        exit 1
    fi

    local options=()
    for bridge in "${bridges[@]}"; do
        options+=("$bridge" "")
    done

    local choice
    choice=$(whiptail --title "Bridge Selection" \
        --menu "Select a Proxmox bridge interface:" \
        15 60 6 "${options[@]}" 3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        whiptail --title "Cancelled" --msgbox "Operation cancelled. Exiting." 8 40
        exit 1
    fi
    echo "$choice"
}

selectIPConfig()
{
    local choice
    choice=$(whiptail --title "IP Configuration" \
        --menu "Select network configuration:" 12 60 2 \
        "1" "DHCP (automatic)" \
        "2" "Static IP" \
        3>&1 1>&2 2>&3)

    case "$choice" in
        1)
            ip="dhcp"
            cidr=""
            gateway=""
            ;;
        2)
            ip=$(createMenu      "Container IP"   "Container IP address (e.g. 192.168.1.100):" "192.168.1.100")
            cidr=$(createMenu    "Subnet Prefix"  "Subnet prefix length:" "24")
            gateway=$(createMenu "Gateway"        "Gateway IP address:" "192.168.1.1")
            ;;
        *)
            whiptail --title "Cancelled" --msgbox "Operation cancelled. Exiting." 8 40
            exit 1
            ;;
    esac
}

selectPrivilege()
{
    if (whiptail --title "Container Privilege" \
        --yesno "Create as an UNPRIVILEGED container? (recommended)" 10 60); then
        privilege="--unprivileged 1"
    else
        privilege="--unprivileged 0"
    fi
}

selectOstype()
{
    local choice
    choice=$(whiptail --title "OS Type" \
        --menu "Select the OS type of the source machine:" 18 60 8 \
        "unmanaged" "Unknown / custom (safe default)" \
        "debian"    "Debian" \
        "ubuntu"    "Ubuntu" \
        "centos"    "CentOS / RHEL / Rocky / Alma" \
        "fedora"    "Fedora" \
        "opensuse"  "openSUSE" \
        "archlinux" "Arch Linux" \
        "alpine"    "Alpine Linux" \
        3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        choice="unmanaged"
    fi
    echo "$choice"
}

userInput()
{
    id=$(createMenu         "Container ID"      "Proxmox container ID (e.g. 200):" "200")
    name=$(createMenu       "Hostname"          "Hostname for the LXC container:")
    target=$(createMenu     "Target Machine"    "Target machine SSH address (e.g. 192.168.1.50):")
    port=$(createMenu       "SSH Port"          "SSH port on target machine:" "22")
    passwordSSH=$(whiptail  --title "SSH Password" \
        --passwordbox "Root SSH password for $target:" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1

    bridge=$(selectBridge)
    selectIPConfig
    ostype=$(selectOstype)

    rootsize=$(createMenu   "RootFS Size"   "Root filesystem size in GB:" "8")
    memory=$(createMenu     "Memory"        "Memory allocation in MB:" "512")
    cores=$(createMenu      "CPU Cores"     "Number of CPU cores:" "1")
    storage=$(createMenu    "Storage Pool"  "Proxmox storage pool (e.g. local-lvm):" "local-lvm")
    nameserver=$(createMenu "Nameserver"    "DNS nameserver for container:" "1.1.1.1")
    passwordCT=$(whiptail   --title "Container Root Password" \
        --passwordbox "Root password for the new container (min. 5 chars):" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1

    selectPrivilege
}

# -------------------------------------------------------------------------
# Filesystem collection — runs on the *target* machine via SSH
# Excludes volatile, device-heavy, and unnecessary paths so that pct
# can unpack the archive cleanly in an unprivileged container namespace.
# -------------------------------------------------------------------------
collectFS()
{
    tar -czf - -C / \
        --ignore-failed-read \
        --warning=no-file-ignored \
        --exclude="./sys" \
        --exclude="./dev" \
        --exclude="./run" \
        --exclude="./proc" \
        --exclude="./tmp" \
        --exclude="./mnt" \
        --exclude="./media" \
        --exclude="./lost+found" \
        --exclude="./var/tmp" \
        --exclude="./var/cache/apt/archives" \
        --exclude="./var/lib/docker" \
        --exclude="./var/lib/containerd" \
        --exclude="./var/lib/containers" \
        --exclude="./var/lib/lxc" \
        --exclude="./var/lib/lxd" \
        --exclude="./var/lib/cni" \
        --exclude="./var/snap" \
        --exclude="./snap" \
        --exclude="./run/docker" \
        --exclude="./run/containerd" \
        --exclude="*.log" \
        --exclude="*.log.*" \
        --exclude="*.gz" \
        --exclude="*.sql" \
        --exclude="./swap.img" \
        --exclude="./swapfile" \
        .
}

validateParameters()
{
    local missing=()
    [ -z "$id" ]          && missing+=("id")
    [ -z "$name" ]        && missing+=("hostname")
    [ -z "$target" ]      && missing+=("target")
    [ -z "$port" ]        && missing+=("port")
    [ -z "$passwordSSH" ] && missing+=("SSH password")
    [ -z "$bridge" ]      && missing+=("bridge")
    [ -z "$ip" ]          && missing+=("IP config")
    [ -z "$rootsize" ]    && missing+=("rootfs size")
    [ -z "$memory" ]      && missing+=("memory")
    [ -z "$cores" ]       && missing+=("cores")
    [ -z "$storage" ]     && missing+=("storage pool")
    [ -z "$passwordCT" ]  && missing+=("container password")

    if [ ${#missing[@]} -gt 0 ]; then
        whiptail --title "Error" --msgbox \
            "Missing required parameters:\n  ${missing[*]}" 10 70
        exit 1
    fi

    if [ "${#passwordCT}" -lt 5 ]; then
        whiptail --title "Error" --msgbox \
            "Container root password must be at least 5 characters." 8 60
        exit 1
    fi
}

convert()
{
    local tmpfile
    tmpfile=$(mktemp /tmp/lxc-convert-XXXXXX.tar.gz)

    # Build net0 string
    local net_param
    if [ "$ip" = "dhcp" ]; then
        net_param="name=eth0,bridge=${bridge},ip=dhcp"
    else
        net_param="name=eth0,bridge=${bridge},ip=${ip}/${cidr},gw=${gateway}"
    fi

    whiptail --title "Step 1/2 — Collecting Filesystem" --infobox \
        "Pulling filesystem from root@$target via SSH...\nThis may take several minutes depending on disk size." \
        10 65

    # Pull the filesystem — avoid eval by calling sshpass/ssh directly
    sshpass -p "$passwordSSH" ssh \
        -p "$port" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "root@$target" \
        "$(declare -f collectFS); collectFS" > "$tmpfile"

    if [ $? -ne 0 ] || [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        whiptail --title "Error" --msgbox \
            "Failed to pull filesystem from $target.\nCheck SSH credentials, connectivity, and that PermitRootLogin is enabled." \
            12 65
        exit 1
    fi

    local size_human
    size_human=$(du -sh "$tmpfile" 2>/dev/null | cut -f1)
    whiptail --title "Step 2/2 — Creating Container" --infobox \
        "Archive collected: ${size_human}.\nCreating LXC container $id ($name) on Proxmox..." \
        10 65

    # pct create — Proxmox 7/8 syntax
    # --rootfs storage:sizeGB  allocates a new volume on the given pool
    # --ostype tells Proxmox how to configure the container internals
    pct create "$id" "$tmpfile" \
        --description "Converted LXC — source: $target" \
        --hostname "$name" \
        --ostype "$ostype" \
        --features nesting=1 \
        --memory "$memory" \
        --cores "$cores" \
        --nameserver "$nameserver" \
        --net0 "$net_param" \
        $privilege \
        --rootfs "${storage}:${rootsize}" \
        --password "$passwordCT" \
        --start 1

    local rc=$?
    rm -f "$tmpfile"

    if [ $rc -eq 0 ]; then
        whiptail --title "Done" --msgbox \
            "Container $id ($name) created and started successfully!\n\nConnect: pct enter $id" \
            12 60
    else
        whiptail --title "Error" --msgbox \
            "pct create failed (exit code $rc).\nCheck the Proxmox task log: journalctl -u pvedaemon or the web UI Tasks tab." \
            12 70
        exit $rc
    fi
}

main()
{
    welcome
    checkList "$@"
    userInput
    validateParameters
    convert
}
main "$@"
