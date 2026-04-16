#!/bin/bash

checkList()
{
    # Check if running as root
    if [ "$(whoami)" != "root" ]; then
        echo -e "\e[96mLog in as a superuser...\e[39m"
        sudo -E bash "$0" "$@"
        exit $?
    fi

    # Check if the 'pct' command is available on the host machine (Proxmox)
    if ! command -v pct &> /dev/null; then
        whiptail --title "Error" --msgbox "The 'pct' command could not be found. This script must be run on the Proxmox host machine." 10 60
        exit 1
    fi

    # Check if 'sshpass' is available; install if missing
    if ! command -v sshpass &> /dev/null; then
        apt-get install -y sshpass
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install 'sshpass'. Exiting."
            exit 1
        fi
    fi

    # Check if 'ip' is available (replaces deprecated brctl)
    if ! command -v ip &> /dev/null; then
        whiptail --title "Error" --msgbox "The 'ip' command could not be found. Please install iproute2." 10 60
        exit 1
    fi
}

# Function to display welcome message
welcome()
{
    whiptail --title "GNU/Linux Machine to Proxmox LXC Container Converter" --msgbox \
    "This script simplifies converting a Linux machine to a Proxmox LXC container.
Follow the prompts to provide details, and the script will handle the conversion.

Please note:
  - This script must be run on the Proxmox host machine.
  - Requires: pct, sshpass, ip (iproute2). sshpass will be auto-installed.
  - SSH access to the target machine as root is required.
  - For CLI usage: ./bashconvert -h

Repository: https://github.com/my5t3ry/machine-to-proxmox-lxc-ct-converter

Let's get started!" 23 70
}

# Generic input menu
createMenu()
{
    local title=$1
    local prompt=$2
    local default=${3:-""}

    local input
    input=$(whiptail --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ]; then
        echo "$input"
    else
        whiptail --title "Canceled" --msgbox "Operation canceled. Exiting." 10 60
        exit 1
    fi
}

# Select a Proxmox bridge interface using 'ip link' (brctl is deprecated)
selectBridge()
{
    local bridges=()
    while IFS= read -r line; do
        bridges+=("$line")
    done < <(ip link show type bridge | awk -F': ' '/^[0-9]+:/{print $2}' | grep '^vmbr')

    if [ ${#bridges[@]} -eq 0 ]; then
        whiptail --title "Error" --msgbox "No Proxmox bridge interfaces (vmbr*) found." 10 60
        exit 1
    fi

    local options=()
    for bridge in "${bridges[@]}"; do
        options+=("$bridge" "")
    done

    local choice
    choice=$(whiptail --title "Bridge Selection" --menu "Choose a Proxmox bridge interface:" 15 60 6 "${options[@]}" 3>&1 1>&2 2>&3)

    if [ $? -eq 0 ]; then
        echo "$choice"
    else
        whiptail --title "Canceled" --msgbox "Operation canceled. Exiting." 10 60
        exit 1
    fi
}

# Select IP configuration: DHCP or manual
selectIPConfig()
{
    local choice
    choice=$(whiptail --title "IP Configuration" --menu "Choose network configuration:" 15 60 6 \
        "1" "Use DHCP" \
        "2" "Manual IP Configuration" 3>&1 1>&2 2>&3)

    case "$choice" in
        "1")
            ip="dhcp"
            cidr=""
            gateway=""
            ;;
        "2")
            ip=$(createMenu "Container IP" "Enter the container IP address (without prefix):" "192.168.1.100")
            cidr=$(createMenu "CIDR Prefix" "Enter the subnet prefix length:" "24")
            gateway=$(createMenu "Gateway IP" "Enter the gateway IP:" "192.168.1.1")
            ;;
        *)
            whiptail --title "Error" --msgbox "Invalid choice. Exiting." 10 60
            exit 1
            ;;
    esac
}

# Select privileged or unprivileged container
selectPrivilege()
{
    if (whiptail --title "Container Privilege" --yesno "Create as an UNPRIVILEGED container? (recommended)" 10 60); then
        privilege="--unprivileged 1"
    else
        privilege="--unprivileged 0"
    fi
}

# Gather all user input interactively
userInput()
{
    id=$(createMenu "Proxmox Container ID" "Enter the Proxmox container ID:" "200")
    name=$(createMenu "Container Name" "Enter a hostname for the LXC container:")
    target=$(createMenu "Target Machine" "Enter the target machine SSH URI (e.g. 192.168.1.50):")
    port=$(createMenu "SSH Port" "Enter the SSH port of the target machine:" "22")
    passwordSSH=$(whiptail --title "SSH Password" --passwordbox "Enter the SSH password for root@$target:" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1

    bridge=$(selectBridge)
    selectIPConfig

    rootsize=$(createMenu "RootFS Size" "Enter the rootfs size in GB (e.g. 8):" "8")
    memory=$(createMenu "Memory" "Enter the memory allocation in MB:" "512")
    cores=$(createMenu "CPU Cores" "Enter the number of CPU cores:" "1")
    storage=$(createMenu "Storage Pool" "Enter the target Proxmox storage pool:" "local-lvm")
    nameserver=$(createMenu "Nameserver" "Enter the DNS nameserver for the container:" "1.1.1.1")
    passwordCT=$(whiptail --title "Container Root Password" --passwordbox "Enter the root password for the container (min. 5 chars):" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && exit 1

    selectPrivilege
}

# Collect filesystem from target via SSH, excluding volatile/unnecessary paths
collectFS()
{
    tar -czf - -C / \
        --exclude="sys" \
        --exclude="dev" \
        --exclude="run" \
        --exclude="proc" \
        --exclude="tmp" \
        --exclude="lost+found" \
        --exclude="*.log" \
        --exclude="*.log.*" \
        --exclude="*.gz" \
        --exclude="*.sql" \
        --exclude="swap.img" \
        .
}

# Validate all required parameters are set
validateParameters()
{
    local missing=()
    [ -z "$id" ]          && missing+=("id")
    [ -z "$name" ]        && missing+=("name")
    [ -z "$target" ]      && missing+=("target")
    [ -z "$port" ]        && missing+=("port")
    [ -z "$passwordSSH" ] && missing+=("SSH password")
    [ -z "$bridge" ]      && missing+=("bridge")
    [ -z "$ip" ]          && missing+=("ip")
    [ -z "$rootsize" ]    && missing+=("rootfs size")
    [ -z "$memory" ]      && missing+=("memory")
    [ -z "$cores" ]       && missing+=("cores")
    [ -z "$storage" ]     && missing+=("storage")
    [ -z "$passwordCT" ]  && missing+=("container password")

    if [ ${#missing[@]} -gt 0 ]; then
        whiptail --title "Error" --msgbox "Missing required parameters: ${missing[*]}" 10 70
        exit 1
    fi

    if [ "${#passwordCT}" -lt 5 ]; then
        whiptail --title "Error" --msgbox "Container password must be at least 5 characters." 10 60
        exit 1
    fi
}

# Perform the conversion: pull FS via SSH, create LXC, start it
convert()
{
    local tmpfile
    tmpfile=$(mktemp /tmp/lxc-convert-XXXXXX.tar.gz)

    # Build the network parameter
    local net_param
    if [ "$ip" = "dhcp" ]; then
        net_param="name=eth0,bridge=${bridge},ip=dhcp"
    else
        net_param="name=eth0,bridge=${bridge},ip=${ip}/${cidr},gw=${gateway}"
    fi

    # Pull filesystem from target machine
    whiptail --title "Converting" --infobox "Pulling filesystem from $target via SSH...\nThis may take several minutes." 10 60
    sshpass -p "$passwordSSH" ssh \
        -p "$port" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        "root@$target" \
        "$(declare -f collectFS); collectFS" > "$tmpfile"

    if [ $? -ne 0 ] || [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        whiptail --title "Error" --msgbox "Failed to pull filesystem from target machine. Check SSH credentials and connectivity." 12 60
        exit 1
    fi

    # Create the Proxmox LXC container
    # rootfs format for Proxmox 7+: storage:sizeGB
    if pct create "$id" "$tmpfile" \
        --description "Converted LXC - source: $target" \
        --hostname "$name" \
        --features nesting=1 \
        --memory "$memory" \
        --cores "$cores" \
        --nameserver "$nameserver" \
        --net0 "$net_param" \
        $privilege \
        --rootfs "${storage}:${rootsize}" \
        --password "$passwordCT" \
        --start 1; then
        whiptail --title "Success" --msgbox "Container $id ($name) created and started successfully!" 10 60
    else
        whiptail --title "Error" --msgbox "Failed to create Proxmox container. Check 'pct create' output above for details." 10 60
    fi

    rm -f "$tmpfile"
}

# Entry point
main()
{
    welcome
    checkList
    userInput
    validateParameters
    convert
}
main "$@"
