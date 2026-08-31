#!/bin/bash

clear

# Green, Yellow & Red Messages.
green_msg() {
    tput setaf 2 2>/dev/null
    echo "[*] ----- $1"
    tput sgr0 2>/dev/null
}

yellow_msg() {
    tput setaf 3 2>/dev/null
    echo "[*] ----- $1"
    tput sgr0 2>/dev/null
}

red_msg() {
    tput setaf 1 2>/dev/null
    echo "[*] ----- $1"
    tput sgr0 2>/dev/null
}

# Paths
HOST_PATH="/etc/hosts"

# Intro
echo 
green_msg '================================================================='
green_msg 'This script will automatically Optimize your Linux Server.'
green_msg 'Tested on: Ubuntu 20+, Debian 11+, CentOS 8+, AlmaLinux, Rocky, Fedora'
green_msg 'Root access is required.' 
green_msg '================================================================='
echo 

# Check Root Function
check_if_running_as_root() {
    if [[ "$EUID" -ne 0 ]]; then
      echo 
      red_msg 'Error: You must run this script as root!'
      echo 
      sleep 0.5
      exit 1
    fi
}

check_if_running_as_root
sleep 0.5

# Install dependencies (Debian/Ubuntu)
install_dependencies_debian_based() {
  echo 
  yellow_msg 'Installing Dependencies...'
  echo 
  sleep 0.5
  
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q -y
  apt-get install -yq wget curl sudo jq net-tools
  
  echo
  green_msg 'Dependencies Installed.'
  echo 
  sleep 0.5
}

# Install dependencies (RHEL/CentOS/Alma/Rocky/Fedora)
install_dependencies_rhel_based() {
  echo 
  yellow_msg 'Installing Dependencies...'
  echo 
  sleep 0.5

  if command -v dnf >/dev/null 2>&1; then
      dnf install -y wget curl sudo jq net-tools
  else
      yum install -y wget curl sudo jq net-tools
  fi
  
  echo
  green_msg 'Dependencies Installed.'
  echo 
  sleep 0.5
}

# Fix Hosts file
fix_etc_hosts(){
  echo
  yellow_msg "Fixing Hosts file..."
  sleep 0.5

  if [ ! -f /etc/hosts.bak ]; then
    cp "$HOST_PATH" /etc/hosts.bak
    yellow_msg "Default hosts file saved to /etc/hosts.bak"
  fi

  local hname
  hname=$(hostname)

  if ! grep -qw "$hname" "$HOST_PATH" 2>/dev/null; then
    echo "127.0.1.1 $hname" >> "$HOST_PATH"
    green_msg "Hosts Fixed (Added 127.0.1.1 $hname)."
  else
    green_msg "Hosts OK. No changes made."
  fi
  echo
  sleep 0.5
}

# =====================================================================
# DNS SECTION (hardened: validation, manager-aware, rollback, idempotent)
# =====================================================================

TS=$(date +%Y%m%d-%H%M%S)

DNS_NAME=""; DNS_V4=""; DNS_V6=""; DOT_PAIRS=""
DOT_MODE="disabled"
METHOD="direct"

RESOLV_SNAPSHOT_DONE=0
RESOLV_WAS_SYMLINK=0
RESOLV_SYMLINK_TARGET=""
RESOLV_BAK_FILE="/etc/resolv.conf.bak.$TS"
RESOLV_MODIFIED=0

RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-linux-optimizer-dns.conf"
RESOLVED_DROPIN_WRITTEN=0
RESOLVED_DROPIN_EXISTED=0
RESOLVED_MAIN_CLEANED=0

NM_CHANGES=()
NM_APPLIED=0
NM_DNSNONE_DROPIN="/etc/NetworkManager/conf.d/99-linux-optimizer-dnsnone.conf"
NM_DNSNONE_CREATED=0

DNS_STATE_DIR="/var/lib/linux-optimizer"
DNS_STATE_FILE="$DNS_STATE_DIR/dns.env"
NETWORKD_DISPATCHER_HOOK="/etc/networkd-dispatcher/routable.d/70-linux-optimizer-dns"
DNS_STATE_WRITTEN=0
DNS_HOOK_CREATED=0

NETPLAN_DNS_FILE="/etc/netplan/99-linux-optimizer-dns.yaml"
NETPLAN_FILE_CREATED=0
NETPLAN_APPLIED=0

get_dns_list() {
    case "$1" in
        1)  echo "1.1.1.1 1.0.0.1|2606:4700:4700::1111 2606:4700:4700::1001|1.1.1.1=1dot1dot1dot1.cloudflare-dns.com 1.0.0.1=1dot1dot1dot1.cloudflare-dns.com 2606:4700:4700::1111=1dot1dot1dot1.cloudflare-dns.com 2606:4700:4700::1001=1dot1dot1dot1.cloudflare-dns.com" ;;
        2)  echo "1.1.1.2 1.0.0.2|2606:4700:4700::1112 2606:4700:4700::1002|1.1.1.2=security.cloudflare-dns.com 1.0.0.2=security.cloudflare-dns.com 2606:4700:4700::1112=security.cloudflare-dns.com 2606:4700:4700::1002=security.cloudflare-dns.com" ;;
        3)  echo "1.1.1.3 1.0.0.3|2606:4700:4700::1113 2606:4700:4700::1003|1.1.1.3=family.cloudflare-dns.com 1.0.0.3=family.cloudflare-dns.com 2606:4700:4700::1113=family.cloudflare-dns.com 2606:4700:4700::1003=family.cloudflare-dns.com" ;;
        4)  echo "8.8.8.8 8.8.4.4|2001:4860:4860::8888 2001:4860:4860::8844|8.8.8.8=dns.google 8.8.4.4=dns.google 2001:4860:4860::8888=dns.google 2001:4860:4860::8844=dns.google" ;;
        5)  echo "9.9.9.9 149.112.112.112|2620:fe::fe 2620:fe::9|9.9.9.9=dns.quad9.net 149.112.112.112=dns.quad9.net 2620:fe::fe=dns.quad9.net 2620:fe::9=dns.quad9.net" ;;
        6)  echo "94.140.14.14 94.140.15.15|2a10:50c0::ad1:ff 2a10:50c0::ad2:ff|94.140.14.14=dns.adguard-dns.com 94.140.15.15=dns.adguard-dns.com 2a10:50c0::ad1:ff=dns.adguard-dns.com 2a10:50c0::ad2:ff=dns.adguard-dns.com" ;;
        7)  echo "208.67.222.222 208.67.220.220|2620:119:35::35 2620:119:53::53|208.67.222.222=dot.opendns.com 208.67.220.220=dot.opendns.com 2620:119:35::35=dot.opendns.com 2620:119:53::53=dot.opendns.com" ;;
        8)  echo "178.22.122.100 185.51.200.2||" ;;
        9)  echo "78.157.42.100 78.157.42.101||" ;;
        10) echo "10.202.10.202 10.202.10.102||" ;;
        11) echo "185.55.226.26 185.55.225.25||" ;;
        12) echo "10.202.10.10 10.202.10.11||" ;;
        13) echo "178.22.122.100 185.51.200.2 78.157.42.100 78.157.42.101||" ;;
        14) echo "1.1.1.1 8.8.8.8|2606:4700:4700::1111 2001:4860:4860::8888|1.1.1.1=1dot1dot1dot1.cloudflare-dns.com 8.8.8.8=dns.google 2606:4700:4700::1111=1dot1dot1dot1.cloudflare-dns.com 2001:4860:4860::8888=dns.google" ;;
        15) echo "custom||" ;;
        *)  echo "" ;;
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

dedup_list() {
    local seen=" " out="" tok
    for tok in $1; do
        [[ "$seen" == *" $tok "* ]] && continue
        seen+="$tok "
        out+="${out:+ }$tok"
    done
    echo "$out"
}

_ipv4_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
_ipv6_regex='^(([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,7}:|([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,5}(:[0-9A-Fa-f]{1,4}){1,2}|([0-9A-Fa-f]{1,4}:){1,4}(:[0-9A-Fa-f]{1,4}){1,3}|([0-9A-Fa-f]{1,4}:){1,3}(:[0-9A-Fa-f]{1,4}){1,4}|([0-9A-Fa-f]{1,4}:){1,2}(:[0-9A-Fa-f]{1,4}){1,5}|[0-9A-Fa-f]{1,4}:((:[0-9A-Fa-f]{1,4}){1,6})|:((:[0-9A-Fa-f]{1,4}){1,7}|:))$'

valid_ipv4() {
    local ip="$1" oct
    [[ "$ip" =~ $_ipv4_regex ]] || return 1
    for oct in ${ip//./ }; do
        (( 10#$oct <= 255 )) || return 1
    done
    return 0
}

valid_ip() {
    local fam="$1" ip="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$fam" "$ip" <<'PYEOF' >/dev/null 2>&1
import sys, ipaddress
fam, ip = sys.argv[1], sys.argv[2]
try:
    ipaddress.IPv4Address(ip) if fam == "4" else ipaddress.IPv6Address(ip)
except Exception:
    sys.exit(1)
sys.exit(0)
PYEOF
        return $?
    fi
    if [ "$fam" = "4" ]; then
        valid_ipv4 "$ip"
    else
        [[ "$ip" =~ $_ipv6_regex ]]
    fi
}

read_validated_dns() {
    local fam="$1" prompt="$2" required="$3"
    local input ip bad valid
    while true; do
        read -r -p "$prompt" input </dev/tty || return 1
        valid=""
        bad=""
        for ip in $input; do
            if valid_ip "$fam" "$ip" && [ "$ip" != "0.0.0.0" ] && [ "$ip" != "::" ]; then
                case "$ip" in
                    127.*|::1) yellow_msg "Warning: $ip is loopback - only valid if a local DNS service is running." >&2 ;;
                esac
                valid="$valid $ip"
            else
                bad="$bad $ip"
            fi
        done
        [ -n "$bad" ] && red_msg "Rejected invalid IPv$fam address(es):$bad" >&2
        valid=$(dedup_list "$valid")
        if [ -n "$valid" ]; then
            echo "$valid"
            return 0
        fi
        [ "$required" = "0" ] && return 0
        red_msg "At least one valid IPv$fam DNS server is required." >&2
    done
}

build_resolved_dns_value() {
    local pairs="$1" ip sni p out=""
    for ip in $2; do
        sni=""
        for p in $pairs; do
            if [ "${p%%=*}" = "$ip" ]; then sni="${p#*=}"; break; fi
        done
        if [ -n "$sni" ]; then out+="$ip#$sni "; else out+="$ip "; fi
    done
    echo "${out% }"
}

systemd_major_version() {
    local v
    v=$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')
    [ -n "$v" ] && echo "$v" || echo 0
}

dot_mode_desc() {
    case "$DOT_MODE" in
        disabled)              echo "Disabled" ;;
        opportunistic)         echo "Opportunistic (DoT used when the server supports it; SNI configured)" ;;
        opportunistic-unknown) echo "Opportunistic (no verified DoT hostname - may remain unencrypted)" ;;
        *)                     echo "Unknown" ;;
    esac
}

print_server_list() {
    local list="$1" i=0 srv
    for srv in $list; do
        i=$((i+1))
        case $i in
            1) echo "  Primary:   $srv" ;;
            2) echo "  Secondary: $srv" ;;
            *) echo "  Extra $((i-2)):  $srv" ;;
        esac
    done
}

print_selection_summary() {
    echo
    echo "Selected:"
    echo "  $DNS_NAME"
    if [ -n "$DNS_V4" ]; then
        echo "IPv4:"
        print_server_list "$DNS_V4"
    fi
    if [ -n "$DNS_V6" ]; then
        echo "IPv6:"
        print_server_list "$DNS_V6"
    else
        echo "IPv6:"
        echo "  (none - IPv4 only; existing IPv6 DNS will be left untouched)"
    fi
    echo "DNS manager:"
    echo "  $(detect_dns_method)"
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
        read -r -p "[*] Select DNS [1-15]: " DNS_CHOICE </dev/tty || return 1
        DNS_LIST=$(get_dns_list "$DNS_CHOICE")
        [ -n "$DNS_LIST" ] && return 0
        red_msg "Invalid choice, try again."
    done
}

parse_dns_choice() {
    DNS_NAME=$(get_dns_name "$DNS_CHOICE")
    if [ "$DNS_LIST" = "custom" ]; then
        DNS_V4=$(read_validated_dns 4 "[*] Enter IPv4 DNS servers (space separated): " 1) \
            || { red_msg "DNS input aborted. Skipping DNS change."; return 1; }
        DNS_V6=$(read_validated_dns 6 "[*] Enter IPv6 DNS servers (optional, blank to skip): " 0)
        DOT_PAIRS=""
        local CUSTOM_DOT
        read -r -p "[*] DoT hostname(s) for these servers (optional, blank = no DoT): " CUSTOM_DOT </dev/tty || CUSTOM_DOT=""
        CUSTOM_DOT=${CUSTOM_DOT//,/ }
        if [ -n "$CUSTOM_DOT" ]; then
            local -a allsrv
            allsrv=($DNS_V4 $DNS_V6)
            local sni idx=0
            for sni in $CUSTOM_DOT; do
                if [[ ! "$sni" =~ ^[A-Za-z0-9.-]+$ ]]; then
                    red_msg "Ignoring invalid DoT hostname: $sni"
                elif [ -n "${allsrv[$idx]}" ]; then
                    DOT_PAIRS+="${allsrv[$idx]}=$sni "
                fi
                idx=$((idx+1))
            done
            DOT_PAIRS=${DOT_PAIRS% }
        fi
    else
        DNS_V4="${DNS_LIST%%|*}"
        local rest="${DNS_LIST#*|}"
        if [[ "$rest" == *"|"* ]]; then
            DNS_V6="${rest%%|*}"
            DOT_PAIRS="${rest#*|}"
        else
            DNS_V6="$rest"
            DOT_PAIRS=""
        fi
    fi
    return 0
}

resolv_conf_is_resolved_stub() {
    if [ -L /etc/resolv.conf ]; then
        [[ "$(readlink /etc/resolv.conf)" == *"systemd/resolve"* ]] && return 0
    fi
    grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null && return 0
    return 1
}

resolvconf_is_managed() {
    [ -L /etc/resolv.conf ] || return 1
    [[ "$(readlink /etc/resolv.conf)" == *"resolvconf"* ]]
}

detect_dns_method() {
    local resolved_active=0 nm_active=0
    if systemctl is-active --quiet systemd-resolved 2>/dev/null && command -v resolvectl >/dev/null 2>&1; then
        resolved_active=1
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        nm_active=1
    fi
    if [ "$resolved_active" = "1" ]; then
        if [ "$nm_active" = "1" ] && [ -L /etc/resolv.conf ] && [[ "$(readlink /etc/resolv.conf)" == *"NetworkManager"* ]]; then
            echo "networkmanager"
        else
            echo "systemd-resolved"
        fi
        return 0
    fi
    if [ "$nm_active" = "1" ]; then
        echo "networkmanager"
        return 0
    fi
    if command -v resolvconf >/dev/null 2>&1 && resolvconf_is_managed; then
        echo "resolvconf"
        return 0
    fi
    echo "direct"
}

snapshot_resolvconf() {
    [ "$RESOLV_SNAPSHOT_DONE" = "1" ] && return 0
    RESOLV_SNAPSHOT_DONE=1
    if [ -L /etc/resolv.conf ]; then
        RESOLV_WAS_SYMLINK=1
        RESOLV_SYMLINK_TARGET=$(readlink /etc/resolv.conf)
        cp -L /etc/resolv.conf "$RESOLV_BAK_FILE" 2>/dev/null
    elif [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$RESOLV_BAK_FILE" 2>/dev/null
    fi
    return 0
}

restore_resolvconf() {
    rm -f /etc/resolv.conf
    if [ "$RESOLV_WAS_SYMLINK" = "1" ] && [ -n "$RESOLV_SYMLINK_TARGET" ]; then
        ln -s "$RESOLV_SYMLINK_TARGET" /etc/resolv.conf
    elif [ -f "$RESOLV_BAK_FILE" ]; then
        cp "$RESOLV_BAK_FILE" /etc/resolv.conf
    fi
    return 0
}

write_resolvconf_direct() {
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    {
        echo "# Generated by Linux-Optimizer ($TS)"
        for ns in $DNS_V4; do echo "nameserver $ns"; done
        if [ -n "$DNS_V6" ]; then
            for ns in $DNS_V6; do echo "nameserver $ns"; done
        fi
    } > /etc/resolv.conf || { red_msg "Failed to write /etc/resolv.conf."; return 1; }
    chmod 644 /etc/resolv.conf
    return 0
}

clean_legacy_resolved_conf() {
    local f="/etc/systemd/resolved.conf"
    [ -f "$f" ] || return 0
    if grep -Eq '^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS)=' "$f" 2>/dev/null; then
        cp "$f" "$f.bak.$TS" || { red_msg "Backup of resolved.conf failed."; return 1; }
        sed -i -E '/^[[:space:]]*(DNS|FallbackDNS|DNSOverTLS)=/d' "$f"
        RESOLVED_MAIN_CLEANED=1
        yellow_msg "Removed legacy optimizer DNS directives from $f."
    fi
    return 0
}

ensure_resolved_stub() {
    if [ -L /etc/resolv.conf ] && [[ "$(readlink /etc/resolv.conf)" == *"systemd/resolve"* ]]; then
        return 0
    fi
    if [ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] && grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        return 0
    fi
    snapshot_resolvconf
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || { red_msg "Failed to create stub symlink."; return 1; }
    RESOLV_MODIFIED=1
    yellow_msg "/etc/resolv.conf repointed to the systemd-resolved stub."
    return 0
}

override_link_dns_runtime() {
    command -v resolvectl >/dev/null 2>&1 || return 0
    resolvectl flush-caches >/dev/null 2>&1 || true
    local link
    while read -r link; do
        [ -z "$link" ] || [ "$link" = "lo" ] && continue
        resolvectl dns "$link" $1 >/dev/null 2>&1 || \
            resolvectl dns "$link" $DNS_V4 $DNS_V6 >/dev/null 2>&1 || true
    done < <(resolvectl status 2>/dev/null | awk '/^Link [0-9]+ \(/ {gsub(/[()]/,"",$3); sub(/:$/,"",$3); print $3}')
    return 0
}

networkd_active() {
    systemctl is-active --quiet systemd-networkd 2>/dev/null
}

persist_dns_state() {
    [ -n "$DNS_V4" ] || return 0
    mkdir -p "$DNS_STATE_DIR" 2>/dev/null || return 0

    local all="$DNS_V4"
    [ -n "$DNS_V6" ] && all="$DNS_V4 $DNS_V6"
    printf 'OPT_DNS_ALL="%s"\n' "$all" > "$DNS_STATE_FILE"
    chmod 644 "$DNS_STATE_FILE"
    DNS_STATE_WRITTEN=1

    if networkd_active; then
        if command -v networkd-dispatcher >/dev/null 2>&1; then
            mkdir -p "$(dirname "$NETWORKD_DISPATCHER_HOOK")" 2>/dev/null
            if [ ! -f "$NETWORKD_DISPATCHER_HOOK" ]; then
                cat > "$NETWORKD_DISPATCHER_HOOK" <<'EOF'
#!/bin/sh
[ -r /var/lib/linux-optimizer/dns.env ] || exit 0
command -v resolvectl >/dev/null 2>&1 || exit 0
[ -n "$DEVICE" ] || exit 0
[ "$DEVICE" = "lo" ] && exit 0
. /var/lib/linux-optimizer/dns.env
[ -n "$OPT_DNS_ALL" ] || exit 0
resolvectl dns "$DEVICE" $OPT_DNS_ALL >/dev/null 2>&1 || true
exit 0
EOF
                chmod 755 "$NETWORKD_DISPATCHER_HOOK"
                DNS_HOOK_CREATED=1
                green_msg "networkd-dispatcher hook installed."
            fi
            systemctl try-restart networkd-dispatcher >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

configure_netplan_dns() {
    command -v netplan >/dev/null 2>&1 || return 0
    networkd_active || return 0
    [ -d /etc/netplan ] || return 0

    if grep -rqsE 'renderer:[[:space:]]*NetworkManager' /etc/netplan /run/netplan /usr/lib/netplan 2>/dev/null; then
        return 0
    fi

    local -a links=()
    local l
    while read -r l; do
        [ -z "$l" ] || [ "$l" = "lo" ] && continue
        if ls /run/systemd/network/ 2>/dev/null | grep -qE "^[0-9]+-netplan-${l}\.network$"; then
            links+=("$l")
        fi
    done < <(resolvectl status 2>/dev/null | awk '/^Link [0-9]+ \(/ {gsub(/[()]/,"",$3); sub(/:$/,"",$3); print $3}')

    [ "${#links[@]}" -gt 0 ] || return 0

    local body="" i ip
    for i in "${links[@]}"; do
        body+="    ${i}:"$'\n'
        body+="      dhcp4-overrides:"$'\n'"        use-dns: false"$'\n'
        body+="      dhcp6-overrides:"$'\n'"        use-dns: false"$'\n'
        if [ -n "$DNS_V4" ] || [ -n "$DNS_V6" ]; then
            body+="      nameservers:"$'\n'"        addresses:"$'\n'
            for ip in $DNS_V4 $DNS_V6; do
                body+="          - $ip"$'\n'
            done
        fi
    done
    body=${body%$'\n'}

    local new_content="network:"$'\n'"  version: 2"$'\n'"  ethernets:"$'\n'"$body"

    if [ -f "$NETPLAN_DNS_FILE" ] && [ "$(cat "$NETPLAN_DNS_FILE" 2>/dev/null)" = "$new_content" ]; then
        return 0
    fi

    [ -f "$NETPLAN_DNS_FILE" ] && cp "$NETPLAN_DNS_FILE" "${NETPLAN_DNS_FILE}.bak.$TS"

    printf '%s\n' "$new_content" > "$NETPLAN_DNS_FILE" || return 1
    chmod 600 "$NETPLAN_DNS_FILE"
    NETPLAN_FILE_CREATED=1

    if ! netplan generate >/dev/null 2>&1; then
        if [ -f "${NETPLAN_DNS_FILE}.bak.$TS" ]; then
            mv "${NETPLAN_DNS_FILE}.bak.$TS" "$NETPLAN_DNS_FILE"
        else
            rm -f "$NETPLAN_DNS_FILE"
        fi
        NETPLAN_FILE_CREATED=0
        return 0
    fi
    green_msg "Netplan DNS override created: $NETPLAN_DNS_FILE (active on next reboot or manual apply)."
    return 0
}

apply_dns_systemd_resolved() {
    yellow_msg "Method: systemd-resolved"

    local dns_value DOT_ANS cont sv
    dns_value="$DNS_V4"
    [ -n "$DNS_V6" ] && dns_value="$DNS_V4 $DNS_V6"

    # Write the drop-in
    local new_content
    new_content="[Resolve]"$'\n'"DNS=$dns_value"$'\n'

    mkdir -p "$(dirname "$RESOLVED_DROPIN")" || return 1
    if [ -f "$RESOLVED_DROPIN" ]; then
        if [ "$(cat "$RESOLVED_DROPIN" 2>/dev/null)" != "${new_content%$'\n'}" ]; then
            cp "$RESOLVED_DROPIN" "${RESOLVED_DROPIN}.bak.$TS" 2>/dev/null
            RESOLVED_DROPIN_EXISTED=1
            printf '%s' "$new_content" > "$RESOLVED_DROPIN"
            RESOLVED_DROPIN_WRITTEN=1
        fi
    else
        printf '%s' "$new_content" > "$RESOLVED_DROPIN"
        RESOLVED_DROPIN_WRITTEN=1
    fi

    clean_legacy_resolved_conf || return 1

    if [ "$RESOLVED_DROPIN_WRITTEN" = "1" ] || [ "$RESOLVED_MAIN_CLEANED" = "1" ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart systemd-resolved || { red_msg "systemd-resolved failed to restart."; return 1; }
        green_msg "systemd-resolved restarted with the new configuration."
    fi

    ensure_resolved_stub || return 1

    if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
        nm_apply_dns_to_profiles
    fi

    override_link_dns_runtime "$dns_value"
    persist_dns_state
    configure_netplan_dns
    return 0
}

nm_apply_dns_to_profiles() {
    local line name dev old idx od4 oi4 od6 oi6
    local -a parts
    NM_APPLIED=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        IFS=':' read -ra parts <<< "$line"
        [ "${#parts[@]}" -lt 2 ] && continue
        dev="${parts[${#parts[@]}-1]}"
        name="${parts[0]}"
        for ((idx=1; idx<${#parts[@]}-1; idx++)); do
            name+=":${parts[$idx]}"
        done
        name=${name//\\:/:}

        [ "$dev" = "lo" ] || [ "$dev" = "--" ] || [ -z "$dev" ] && continue
        [ "$name" = "lo" ] && continue

        od4=$(nmcli -g ipv4.dns connection show "$name" 2>/dev/null)
        oi4=$(nmcli -g ipv4.ignore-auto-dns connection show "$name" 2>/dev/null)
        od6=$(nmcli -g ipv6.dns connection show "$name" 2>/dev/null)
        oi6=$(nmcli -g ipv6.ignore-auto-dns connection show "$name" 2>/dev/null)
        old="$od4|$oi4|$od6|$oi6"

        if ! nmcli connection modify "$name" ipv4.dns "$DNS_V4" ipv4.ignore-auto-dns yes >/dev/null 2>&1; then
            continue
        fi
        if [ -n "$DNS_V6" ]; then
            nmcli connection modify "$name" ipv6.dns "$DNS_V6" ipv6.ignore-auto-dns yes >/dev/null 2>&1 || true
        fi

        NM_CHANGES+=("$name|$dev|$old")
        nmcli device reapply "$dev" >/dev/null 2>&1 && NM_APPLIED=1
    done < <(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null)
}

apply_dns_networkmanager() {
    yellow_msg "Method: NetworkManager"
    NM_APPLIED=0
    nm_apply_dns_to_profiles

    if [ "$NM_APPLIED" = "1" ]; then
        if grep -q "nameserver ${DNS_V4%% *}" /etc/resolv.conf 2>/dev/null || resolv_conf_is_resolved_stub; then
            return 0
        fi
    fi

    write_resolvconf_direct || return 1
    RESOLV_MODIFIED=1

    if systemctl is-active --quiet NetworkManager 2>/dev/null && [ ! -f "$NM_DNSNONE_DROPIN" ]; then
        mkdir -p "$(dirname "$NM_DNSNONE_DROPIN")" 2>/dev/null
        if printf '[main]\ndns=none\n' > "$NM_DNSNONE_DROPIN" 2>/dev/null; then
            NM_DNSNONE_CREATED=1
            nmcli general reload >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

apply_dns_resolvconf() {
    yellow_msg "Method: resolvconf"
    if command -v resolvconf >/dev/null 2>&1 && resolvconf_is_managed; then
        resolvconf -d LinuxOptimizer >/dev/null 2>&1 || true
        {
            for ns in $DNS_V4; do echo "nameserver $ns"; done
            if [ -n "$DNS_V6" ]; then
                for ns in $DNS_V6; do echo "nameserver $ns"; done
            fi
        } | resolvconf -a LinuxOptimizer >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            RESOLV_MODIFIED=1
            return 0
        fi
    fi
    write_resolvconf_direct || return 1
    RESOLV_MODIFIED=1
    return 0
}

apply_dns_direct() {
    yellow_msg "Method: direct /etc/resolv.conf"
    write_resolvconf_direct || return 1
    RESOLV_MODIFIED=1
    return 0
}

get_effective_dns() {
    case "$METHOD" in
        systemd-resolved)
            resolvectl status 2>/dev/null | grep -E '(Current DNS Server|DNS Servers):' | sed -E 's/^[^:]*:[[:space:]]*//' | tr ' ' '\n'
            ;;
        networkmanager)
            nmcli -f IP4.DNS,IP6.DNS device show 2>/dev/null | sed -nE 's/.*DNS\[[0-9]+\]:[[:space:]]*//p'
            ;;
        *)
            awk '/^nameserver[[:space:]]/ {print $2}' /etc/resolv.conf 2>/dev/null
            ;;
    esac
}

dns_query_ok() {
    timeout 6 getent hosts "$1" >/dev/null 2>&1
}

verify_dns() {
    sleep 1
    echo
    yellow_msg "DNS verification..."

    local effective
    effective=$(dedup_list "$(get_effective_dns 2>/dev/null | tr '\n' ' ')")
    echo "Effective DNS: ${effective:-(none visible yet)}"

    if dns_query_ok github.com || dns_query_ok google.com || dns_query_ok cloudflare.com; then
        green_msg "DNS test: PASS"
        return 0
    fi
    red_msg "DNS test: FAIL"
    return 1
}

rollback_dns() {
    echo
    red_msg "Rolling back to previous DNS configuration..."
    local item name dev o4 i4 o6 i6

    if [ "${#NM_CHANGES[@]}" -gt 0 ]; then
        for item in "${NM_CHANGES[@]}"; do
            IFS='|' read -r name dev o4 i4 o6 i6 <<< "$item"
            nmcli connection modify "$name" ipv4.dns "$o4" ipv4.ignore-auto-dns "${i4:-no}" >/dev/null 2>&1 || true
            nmcli connection modify "$name" ipv6.dns "$o6" ipv6.ignore-auto-dns "${i6:-no}" >/dev/null 2>&1 || true
            nmcli device reapply "$dev" >/dev/null 2>&1 || true
        done
    fi

    [ "$DNS_HOOK_CREATED" = "1" ] && rm -f "$NETWORKD_DISPATCHER_HOOK"
    [ "$DNS_STATE_WRITTEN" = "1" ] && rm -f "$DNS_STATE_FILE"
    
    if [ "$RESOLVED_DROPIN_WRITTEN" = "1" ]; then
        rm -f "$RESOLVED_DROPIN"
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
    fi

    if [ "$RESOLV_MODIFIED" = "1" ]; then
        restore_resolvconf
    fi

    resolvectl flush-caches >/dev/null 2>&1 || true
    green_msg "Rollback completed."
}

has_ipv6() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 route show default 2>/dev/null | grep -q '^default'
}

fix_dns() {
    echo
    yellow_msg "DNS Configuration."
    sleep 0.5

    choose_dns || { echo; return 1; }
    parse_dns_choice || { echo; return 1; }

    if [ -n "$DNS_V6" ] && ! has_ipv6; then
        yellow_msg "No IPv6 connectivity detected - IPv6 DNS servers skipped."
        DNS_V6=""
    fi

    print_selection_summary

    METHOD=$(detect_dns_method)
    green_msg "Active DNS manager: $METHOD"

    snapshot_resolvconf

    local applied=0
    case "$METHOD" in
        systemd-resolved) if apply_dns_systemd_resolved; then applied=1; fi ;;
        networkmanager)   if apply_dns_networkmanager;   then applied=1; fi ;;
        resolvconf)       if apply_dns_resolvconf;       then applied=1; fi ;;
        *)                if apply_dns_direct;           then applied=1; fi ;;
    esac

    if [ "$applied" != "1" ]; then
        red_msg "Failed to apply the selected DNS configuration."
        rollback_dns
        return 1
    fi

    if verify_dns; then
        return 0
    fi

    rollback_dns
    return 1
}

# ===================== END OF DNS SECTION =====================

# Set Timezone
set_timezone() {
    echo
    yellow_msg 'Setting TimeZone based on VPS IP address...'
    sleep 0.5

    local ip tz src
    ip=""
    for src in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ipv4.ident.me/"; do
        ip=$(curl -s --max-time 6 "$src" 2>/dev/null | tr -d '[:space:]')
        if valid_ipv4 "$ip"; then
            break
        else
            ip=""
        fi
    done

    if [ -z "$ip" ]; then
        red_msg "Could not detect public IP. Setting timezone to UTC."
        timedatectl set-timezone "UTC" 2>/dev/null || true
        return 0
    fi

    tz=$(curl -s --max-time 6 "http://ip-api.com/json/$ip" 2>/dev/null | jq -r '.timezone // empty' 2>/dev/null | tr -d '[:space:]')

    if [ -n "$tz" ] && timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz"; then
        timedatectl set-timezone "$tz" 2>/dev/null && green_msg "Timezone set to $tz"
    else
        yellow_msg "Could not determine exact timezone location. Defaulting to UTC."
        timedatectl set-timezone "UTC" 2>/dev/null || true
    fi
    echo
    sleep 0.5
}

# Standard OS Detection
detect_os() {
    OS="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            ubuntu) OS="ubuntu" ;;
            debian) OS="debian" ;;
            centos) OS="centos" ;;
            almalinux|rocky|rhel|ol) OS="almalinux" ;;
            fedora) OS="fedora" ;;
            *)
                case "$ID_LIKE" in
                    *debian*|*ubuntu*) OS="debian" ;;
                    *rhel*|*fedora*|*centos*) OS="centos" ;;
                    *) OS="unknown" ;;
                esac
                ;;
        esac
    fi

    case "$OS" in
        ubuntu)    yellow_msg "Detected OS: Ubuntu ($VERSION_ID)" ;;
        debian)    yellow_msg "Detected OS: Debian ($VERSION_ID)" ;;
        centos)    yellow_msg "Detected OS: CentOS ($VERSION_ID)" ;;
        almalinux) yellow_msg "Detected OS: AlmaLinux/RHEL-compatible ($VERSION_ID)" ;;
        fedora)    yellow_msg "Detected OS: Fedora ($VERSION_ID)" ;;
        *)
            red_msg "Unsupported or unknown OS."
            exit 1
            ;;
    esac
}

detect_os
sleep 0.5

# Install dependencies based on OS
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    install_dependencies_debian_based
elif [[ "$OS" == "centos" || "$OS" == "fedora" || "$OS" == "almalinux" ]]; then
    install_dependencies_rhel_based
fi

fix_etc_hosts
sleep 0.5

fix_dns
sleep 0.5

set_timezone
sleep 0.5

# Run Optimizer Script
run_distro_optimizer() {
    local file=""
    
    # Check if a local optimizer script is already present in current directory
    if [ -f "optimizer.sh" ]; then
        file="optimizer.sh"
    elif [ -f "${OS}-optimizer.sh" ]; then
        file="${OS}-optimizer.sh"
    fi

    if [ -n "$file" ] && [ -s "$file" ]; then
        green_msg "Found local optimizer script ($file). Executing..."
        chmod +x "$file"
        bash "$file"
        return 0
    fi

    # Fallback to download if local file not found
    local url=""
    case "$OS" in
        ubuntu)    url="https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/ubuntu-optimizer.sh"; file="ubuntu-optimizer.sh" ;;
        debian)    url="https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/debian-optimizer.sh"; file="debian-optimizer.sh" ;;
        centos)    url="https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/centos-optimizer.sh"; file="centos-optimizer.sh" ;;
        almalinux) url="https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/centos-optimizer.sh"; file="almalinux-optimizer.sh" ;;
        fedora)    url="https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/scripts/fedora-optimizer.sh"; file="fedora-optimizer.sh" ;;
    esac

    yellow_msg "Downloading optimizer script from GitHub..."
    if ! curl -fsSL "$url" -o "$file" 2>/dev/null && ! wget -q "$url" -O "$file" 2>/dev/null; then
        red_msg "Download failed: $url"
        red_msg "Please put your optimizer.sh script alongside this launcher and re-run."
        exit 1
    fi

    chmod +x "$file"
    mkdir -p /run/sshd && chmod 0755 /run/sshd
    bash "$file"
}

run_distro_optimizer
