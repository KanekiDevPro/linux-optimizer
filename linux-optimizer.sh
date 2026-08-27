#!/bin/bash


clear


# Green, Yellow & Red Messages.
green_msg() {
    tput setaf 2
    echo "[*] ----- $1"
    tput sgr0
}

yellow_msg() {
    tput setaf 3
    echo "[*] ----- $1"
    tput sgr0
}

red_msg() {
    tput setaf 1
    echo "[*] ----- $1"
    tput sgr0
}


# Paths
HOST_PATH="/etc/hosts"
DNS_PATH="/etc/resolv.conf"


# Intro
echo 
green_msg '================================================================='
green_msg 'This script will automatically Optimize your Linux Server.'
green_msg 'Tested on: Ubuntu 20+, Debian 11+, CentOS stream 8+, AlmaLinux 8+, Fedora 37+'
green_msg 'Root access is required.' 
green_msg 'Source is @ https://github.com/KanekiDevPro/linux-optimizer' 
green_msg '================================================================='
echo 


# Check Root Function
check_if_running_as_root() {
    # If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
      echo 
      red_msg 'Error: You must run this script as root!'
      echo 
      sleep 0.5
      exit 1
    fi
}


# Run Check Root
check_if_running_as_root
sleep 0.5


# Install dependencies
install_dependencies_debian_based() {
  echo 
  yellow_msg 'Installing Dependencies...'
  echo 
  sleep 0.5
  
  apt update -q
  apt install -yq wget curl sudo jq

  echo
  green_msg 'Dependencies Installed.'
  echo 
  sleep 0.5
}


# Install dependencies
install_dependencies_rhel_based() {
  echo 
  yellow_msg 'Installing Dependencies...'
  echo 
  sleep 0.5

  # dnf up -y
  dnf install -y wget curl sudo jq
  
  echo
  green_msg 'Dependencies Installed.'
  echo 
  sleep 0.5
}


# Fix Hosts file
fix_etc_hosts(){ 
  echo 
  yellow_msg "Fixing Hosts file."
  sleep 0.5

  cp $HOST_PATH /etc/hosts.bak
  yellow_msg "Default hosts file saved. Directory: /etc/hosts.bak"
  sleep 0.5

  if ! grep -q $(hostname) $HOST_PATH; then
    echo "127.0.1.1 $(hostname)" | sudo tee -a $HOST_PATH > /dev/null
    green_msg "Hosts Fixed."
    echo 
    sleep 0.5
  else
    green_msg "Hosts OK. No changes made."
    echo 
    sleep 0.5
  fi
}


# ------------------- DNS SECTION -------------------

TS=$(date +%Y%m%d-%H%M%S)

# DNS database: "IPv4_1 IPv4_2|IPv6_1 IPv6_2"
get_dns_list() {
    case "$1" in
        1)  echo "1.1.1.1 1.0.0.1|2606:4700:4700::1111 2606:4700:4700::1001" ;;     # Cloudflare
        2)  echo "1.1.1.2 1.0.0.2|2606:4700:4700::1112 2606:4700:4700::1002" ;;     # Cloudflare Anti-Malware
        3)  echo "1.1.1.3 1.0.0.3|2606:4700:4700::1113 2606:4700:4700::1003" ;;     # Cloudflare Family
        4)  echo "8.8.8.8 8.8.4.4|2001:4860:4860::8888 2001:4860:4860::8844" ;;     # Google
        5)  echo "9.9.9.9 149.112.112.112|2620:fe::fe 2620:fe::9" ;;                # Quad9
        6)  echo "94.140.14.14 94.140.15.15|2a10:50c0::ad1:ff 2a10:50c0::ad2:ff" ;; # AdGuard
        7)  echo "208.67.222.222 208.67.220.220|2620:119:35::35 2620:119:53::53" ;; # OpenDNS
        8)  echo "178.22.122.100 185.51.200.2|" ;;                                  # Shecan (IR)
        9)  echo "78.157.42.100 78.157.42.101|" ;;                                  # Electro (IR)
        10) echo "10.202.10.202 10.202.10.102|" ;;                                  # 403.online (IR)
        11) echo "185.55.226.26 185.55.225.25|" ;;                                  # Begzar (IR)
        12) echo "10.202.10.10 10.202.10.11|" ;;                                    # Radar Game (IR)
        13) echo "178.22.122.100 185.51.200.2 78.157.42.100 78.157.42.101|" ;;      # Mix: Shecan + Electro
        14) echo "1.1.1.2 8.8.8.8|2606:4700:4700::1112 2001:4860:4860::8888" ;;     # Mix: Cloudflare + Google
        15) echo "custom" ;;
    esac
}

get_dns_name() {
    case "$1" in
        1) echo "Cloudflare" ;;              2) echo "Cloudflare Anti-Malware" ;;
        3) echo "Cloudflare Family" ;;       4) echo "Google" ;;
        5) echo "Quad9" ;;                   6) echo "AdGuard" ;;
        7) echo "OpenDNS" ;;                 8) echo "Shecan (IR)" ;;
        9) echo "Electro (IR)" ;;            10) echo "403.online (IR)" ;;
        11) echo "Begzar (IR)" ;;            12) echo "Radar Game (IR)" ;;
        13) echo "Mix: Shecan + Electro" ;;  14) echo "Mix: Cloudflare + Google" ;;
        15) echo "Custom" ;;
    esac
}

choose_dns() {
    echo
    yellow_msg "Select a DNS configuration:"
    cat <<'EOF'
 1)  Cloudflare                 (1.1.1.1)
 2)  Cloudflare Anti-Malware    (1.1.1.2)  <- recommended
 3)  Cloudflare Family          (1.1.1.3)
 4)  Google                     (8.8.8.8)
 5)  Quad9                      (9.9.9.9)
 6)  AdGuard AdBlock            (94.140.14.14)
 7)  OpenDNS                    (208.67.222.222)
 8)  Shecan [IR]                (178.22.122.100)
 9)  Electro [IR]               (78.157.42.100)
 10) 403.online [IR]            (10.202.10.202)
 11) Begzar [IR]                (185.55.226.26)
 12) Radar Game [IR]            (10.202.10.10)
 13) Mix: Shecan + Electro [IR]
 14) Mix: Cloudflare + Google
 15) Custom (manual input)
EOF
    echo
    while true; do
        read -rp "[*] Select DNS [1-15]: " DNS_CHOICE
        DNS_LIST=$(get_dns_list "$DNS_CHOICE")
        [ -n "$DNS_LIST" ] && break
        red_msg "Invalid choice, try again."
    done
}

parse_dns_choice() {
    DNS_NAME=$(get_dns_name "$DNS_CHOICE")
    if [ "$DNS_LIST" = "custom" ]; then
        read -rp "[*] Enter IPv4 DNS servers (space separated): " DNS_V4
        read -rp "[*] Enter IPv6 DNS servers (optional): " DNS_V6
        [ -z "$DNS_V4" ] && { red_msg "No IPv4 DNS entered. Skipping DNS change."; return 1; }
    else
        DNS_V4="${DNS_LIST%%|*}"
        DNS_V6="${DNS_LIST#*|}"
        [ "$DNS_V6" = "$DNS_LIST" ] && DNS_V6=""
    fi
    DNS_ALL="$DNS_V4"
    [ -n "$DNS_V6" ] && DNS_ALL="$DNS_V4 $DNS_V6"
    green_msg "Selected: $DNS_NAME  ($DNS_ALL)"
    return 0
}

# Detect the ACTIVE DNS manager (more reliable than distro name)
detect_dns_method() {
    if systemctl is-active --quiet systemd-resolved 2>/dev/null && command -v resolvectl >/dev/null 2>&1; then
        echo "systemd-resolved"
    elif systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        echo "networkmanager"
    else
        echo "resolvconf"
    fi
}

apply_dns_systemd_resolved() {
    yellow_msg "Method: systemd-resolved (/etc/systemd/resolved.conf)"
    cp /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.bak.$TS" 2>/dev/null || touch /etc/systemd/resolved.conf

    # Clean old entries (commented or active) and inject ours
    sed -i -E '/^\s*#?\s*(DNS|FallbackDNS)\s*=/d' /etc/systemd/resolved.conf
    grep -q '^\s*\[Resolve\]' /etc/systemd/resolved.conf || echo '[Resolve]' >> /etc/systemd/resolved.conf
    sed -i "/^\[Resolve\]/a DNS=$DNS_ALL" /etc/systemd/resolved.conf

    # Optional encrypted DNS (safe "opportunistic" mode)
    read -rp "[*] Enable DNS-over-TLS? [y/N]: " DOT_ANS
    if [[ "$DOT_ANS" =~ ^[Yy]$ ]]; then
        sed -i -E '/^\s*#?\s*DNSOverTLS\s*=/d' /etc/systemd/resolved.conf
        sed -i '/^\[Resolve\]/a DNSOverTLS=opportunistic' /etc/systemd/resolved.conf
    fi

    systemctl restart systemd-resolved
}

apply_dns_networkmanager() {
    yellow_msg "Method: NetworkManager (nmcli)"
    local dev con applied=0

    while read -r dev; do
        [ -z "$dev" ] || [ "$dev" = "lo" ] && continue
        con=$(nmcli -t -f GENERAL.CONNECTION device show "$dev" 2>/dev/null | cut -d: -f2-)
        [ -z "$con" ] && continue

        nmcli connection modify "$con" ipv4.dns "$DNS_V4" ipv4.ignore-auto-dns yes || continue
        [ -n "$DNS_V6" ] && nmcli connection modify "$con" ipv6.dns "$DNS_V6" ipv6.ignore-auto-dns yes

        if nmcli device reapply "$dev" >/dev/null 2>&1; then
            applied=1
            green_msg "DNS applied to: $con ($dev)"
        fi
    done < <(nmcli -t -f DEVICE device status 2>/dev/null)

    # Fallback: write resolv.conf directly + stop NM from overwriting it
    local first_ns="${DNS_V4%% *}"
    if [ "$applied" -eq 0 ] || ! grep -q "nameserver $first_ns" /etc/resolv.conf 2>/dev/null; then
        yellow_msg "nmcli failed; writing /etc/resolv.conf directly."
        cp /etc/resolv.conf "/etc/resolv.conf.bak.$TS" 2>/dev/null
        write_resolvconf
        if [ -f /etc/NetworkManager/NetworkManager.conf ] && ! grep -q '^\s*dns=none' /etc/NetworkManager/NetworkManager.conf; then
            printf '\n[main]\ndns=none\n' >> /etc/NetworkManager/NetworkManager.conf
            systemctl restart NetworkManager 2>/dev/null || true
        fi
    fi
}

write_resolvconf() {
    # If it is a symlink into /run (managed), replace with a real file
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    {
        echo "# Generated by Linux-Optimizer ($TS)"
        for ns in $DNS_V4 $DNS_V6; do echo "nameserver $ns"; done
    } > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
}

apply_dns_resolvconf() {
    yellow_msg "Method: direct /etc/resolv.conf"
    cp /etc/resolv.conf "/etc/resolv.conf.bak.$TS" 2>/dev/null
    write_resolvconf
}

verify_dns() {
    sleep 1
    if getent hosts github.com >/dev/null 2>&1; then
        green_msg "DNS test OK: github.com -> $(getent hosts github.com | head -n1 | awk '{print $1}')"
        show_dns_status
        return 0
    fi
    red_msg "DNS test FAILED! Restoring backup..."
    [ -f "/etc/resolv.conf.bak.$TS" ] && cp "/etc/resolv.conf.bak.$TS" /etc/resolv.conf
    if [ -f "/etc/systemd/resolved.conf.bak.$TS" ]; then
        cp "/etc/systemd/resolved.conf.bak.$TS" /etc/systemd/resolved.conf
        systemctl restart systemd-resolved
    fi
    sleep 1
    getent hosts github.com >/dev/null 2>&1 && green_msg "Old DNS restored." || red_msg "Old DNS also failed. Check the network!"
    return 1
}

show_dns_status() {
    echo
    yellow_msg "Active nameservers:"
    grep nameserver /etc/resolv.conf 2>/dev/null
    systemctl is-active --quiet systemd-resolved 2>/dev/null && \
        resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers" | head -n 4
    echo
}

# ------------------- MAIN DNS FLOW -------------------
fix_dns() {
    echo
    yellow_msg "DNS Configuration."
    sleep 0.5

    choose_dns
    parse_dns_choice || { echo; return 1; }

    local method
    method=$(detect_dns_method)
    green_msg "Detected DNS manager: $method"

    case "$method" in
        systemd-resolved) apply_dns_systemd_resolved ;;
        networkmanager)   apply_dns_networkmanager ;;
        *)                apply_dns_resolvconf ;;
    esac

    verify_dns
    sleep 0.5
}


# Set the server TimeZone to the VPS IP address location.
set_timezone() {
    echo
    yellow_msg 'Setting TimeZone based on VPS IP address...'
    sleep 0.5

    get_location_info() {
        local ip_sources=("https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ipv4.ident.me/")
        local location_info

        for source in "${ip_sources[@]}"; do
            local ip=$(curl -s "$source")
            if [ -n "$ip" ]; then
                location_info=$(curl -s "http://ip-api.com/json/$ip")
                if [ -n "$location_info" ]; then
                    echo "$location_info"
                    return 0
                fi
            fi
        done

        red_msg "Error: Failed to fetch location information from known sources. Setting timezone to UTC."
        sudo timedatectl set-timezone "UTC"
        return 1
    }

    # Fetch location information from three sources
    location_info_1=$(get_location_info)
    location_info_2=$(get_location_info)
    location_info_3=$(get_location_info)

    # Extract timezones from the location information
    timezones=($(echo "$location_info_1 $location_info_2 $location_info_3" | jq -r '.timezone'))

    # Check if at least two timezones are equal
    if [[ "${timezones[0]}" == "${timezones[1]}" || "${timezones[0]}" == "${timezones[2]}" || "${timezones[1]}" == "${timezones[2]}" ]]; then
        # Set the timezone based on the first matching pair
        timezone="${timezones[0]}"
        sudo timedatectl set-timezone "$timezone"
        green_msg "Timezone set to $timezone"
    else
        red_msg "Error: Failed to fetch consistent location information from known sources. Setting timezone to UTC."
        sudo timedatectl set-timezone "UTC"
    fi

    echo
    sleep 0.5
}


# OS Detection
if [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "Ubuntu" ]]; then
    OS="ubuntu"
    echo 
    sleep 0.5
    yellow_msg "OS: Ubuntu"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "Debian GNU/Linux" ]]; then
    OS="debian"
    echo 
    sleep 0.5
    yellow_msg "OS: Debian"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "CentOS Stream" ]]; then
    OS="centos"
    echo 
    sleep 0.5
    yellow_msg "OS: Centos Stream"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "AlmaLinux" ]]; then
    OS="almalinux"
    echo 
    sleep 0.5
    yellow_msg "OS: AlmaLinux"
    echo 
    sleep 0.5
elif [[ $(grep -oP '(?<=^NAME=").*(?=")' /etc/os-release) == "Fedora Linux" ]]; then
    OS="fedora"
    echo 
    sleep 0.5
    yellow_msg "OS: Fedora"
    echo 
    sleep 0.5
else
    echo 
    sleep 0.5
    red_msg "Unknown OS, Create an issue here: https://github.com/KanekiDevPro/Linux-Optimizer"
    OS="unknown"
    echo 
    sleep 2
fi


## Run

# Install dependencies
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    install_dependencies_debian_based
elif [[ "$OS" == "centos" || "$OS" == "fedora" || "$OS" == "almalinux" ]]; then
    install_dependencies_rhel_based
fi


# Fix Hosts file
fix_etc_hosts
sleep 0.5

# Fix DNS
fix_dns
sleep 0.5

# Timezone
set_timezone
sleep 0.5


# Run Script based on Distros
case $OS in
ubuntu)
    # Ubuntu
    wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/ubuntu-optimizer.sh" -q -O ubuntu-optimizer.sh && chmod +x ubuntu-optimizer.sh && bash ubuntu-optimizer.sh 
    ;;
debian)
    # Debian
    wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/debian-optimizer.sh" -q -O debian-optimizer.sh && chmod +x debian-optimizer.sh && bash debian-optimizer.sh 
    ;;
centos)
    # CentOS
    wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/centos-optimizer.sh" -q -O centos-optimizer.sh && chmod +x centos-optimizer.sh && bash centos-optimizer.sh 
    ;;
almalinux)
    # AlmaLinux
    wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/centos-optimizer.sh" -q -O almalinux-optimizer.sh && chmod +x almalinux-optimizer.sh && bash almalinux-optimizer.sh 
    ;;
fedora)
    # Fedora
    wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/fedora-optimizer.sh" -q -O fedora-optimizer.sh && chmod +x fedora-optimizer.sh && bash fedora-optimizer.sh 
    ;;
unknown)
    # Unknown
    exit 
    ;;
esac
