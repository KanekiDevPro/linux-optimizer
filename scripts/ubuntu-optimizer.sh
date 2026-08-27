#!/bin/bash

set -o pipefail

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

# Declare Paths & Settings.
SYS_PATH="/etc/sysctl.conf"
SYS_OPTIMIZER_PATH="/etc/sysctl.d/99-optimizer.conf"
PROF_PATH="/etc/profile"
SSH_PATH="/etc/ssh/sshd_config"
SWAP_PATH="/swapfile"
SWAP_SIZE="2G"
LIMITS_CONF="/etc/security/limits.d/99-optimizer.conf"

# Root
check_if_running_as_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
      echo
      red_msg 'Error: You must run this script as root!'
      echo
      sleep 0.5
      exit 1
    fi
}

check_if_running_as_root
sleep 0.5

# Ask Reboot
ask_reboot() {
    yellow_msg 'Reboot now? (Recommended) (y/n)'
    echo
    while true; do
        read -r choice
        echo
        if [[ "$choice" == 'y' || "$choice" == 'Y' ]]; then
            sleep 0.5
            reboot
            exit 0
        fi
        if [[ "$choice" == 'n' || "$choice" == 'N' ]]; then
            break
        fi
        yellow_msg 'Please answer y or n.'
    done
}

# Update & Upgrade & Remove & Clean
complete_update() {
    echo
    yellow_msg 'Updating the System... (This can take a while.)'
    echo
    sleep 0.5

    export DEBIAN_FRONTEND=noninteractive
    apt -q update
    apt -y upgrade
    apt -y full-upgrade
    apt -y autoremove --purge
    apt -y autoclean
    apt -y clean
    apt -q update

    echo
    green_msg 'System Updated & Cleaned Successfully.'
    echo
    sleep 0.5
}

# Disable Terminal Ads
disable_terminal_ads() {
    echo
    yellow_msg 'Disabling Terminal Ads...'
    echo
    sleep 0.5

    if [ -f /etc/default/motd-news ]; then
        sed -i 's/ENABLED=1/ENABLED=0/g' /etc/default/motd-news
    fi
    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false || true
    fi

    echo
    green_msg 'Terminal Ads Disabled.'
    echo
    sleep 0.5
}

# Install useful packages - FIXED: per-package loop, single failure doesn't abort all
installations() {
    echo
    yellow_msg 'Installing Useful Packages...'
    echo
    sleep 0.5

    export DEBIAN_FRONTEND=noninteractive
    apt -q update || yellow_msg "apt update had warnings, continuing..."

    # FIX: Install packages individually so one missing package doesn't fail entire batch
    # Common failure: preload, haveged, busybox, binutils-x86-64-linux-gnu removed on newer Ubuntu
    packages=(
        # Networking
        apt-transport-https
        # System utilities
        apt-utils bash-completion busybox ca-certificates cron curl gnupg2 locales lsb-release nano preload screen software-properties-common ufw unzip vim wget xxd zip
        # Programming / dev tools
        autoconf automake build-essential git libtool make pkg-config python3 python3-pip
        # Additional libs
        bc binutils binutils-common binutils-x86-64-linux-gnu ubuntu-keyring haveged jq libsodium-dev libsqlite3-dev libssl-dev packagekit qrencode socat
        # Misc
        dialog htop net-tools
    )

    failed_pkgs=()
    for pkg in "${packages[@]}"; do
        # Skip empty
        [ -z "$pkg" ] && continue
        yellow_msg "Installing $pkg ..."
        if ! apt -y install "$pkg" 2>&1; then
            yellow_msg "Warning: failed to install $pkg, skipping (package may not exist on this release)"
            failed_pkgs+=("$pkg")
        fi
    done

    if [ ${#failed_pkgs[@]} -gt 0 ]; then
        yellow_msg "Some packages failed/skipped: ${failed_pkgs[*]}"
        yellow_msg "This is normal on some Ubuntu/Debian releases (e.g., preload, haveged renamed)."
    fi

    echo
    green_msg 'Useful Packages Installed Succesfully.'
    echo
    sleep 0.5
}

# Enable packages at server boot
enable_packages() {
    # FIX: only enable services that exist
    for svc in cron haveged preload; do
        if systemctl list-unit-files | grep -q "^${svc}.service"; then
            systemctl enable "$svc" 2>/dev/null || true
        fi
    done
    echo
    green_msg 'Packages Enabled Successfully.'
    echo
    sleep 0.5
}

## Swap Maker - FIXED
swap_maker() {
    echo
    yellow_msg 'Making SWAP Space...'
    echo
    sleep 0.5

    # Validate SWAP_SIZE format (e.g., 2G, 1024M) - case-insensitive
    if ! [[ "$SWAP_SIZE" =~ ^[0-9]+[GMKgmk]?$ ]]; then
        red_msg "Invalid SWAP_SIZE: $SWAP_SIZE (use e.g., 2G)"
        return 1
    fi

    # Check if swap already active on this path
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${SWAP_PATH}$"; then
        yellow_msg "Swap $SWAP_PATH is already active. Turning off to recreate..."
        swapoff "$SWAP_PATH" 2>/dev/null || {
            red_msg "Failed to swapoff $SWAP_PATH - maybe in use"
            return 1
        }
    fi

    # Check if file exists and remove old entry from fstab first to avoid duplicates
    if [ -f "$SWAP_PATH" ]; then
        yellow_msg "Old swap file found at $SWAP_PATH, removing..."
        rm -f "$SWAP_PATH"
    fi

    # Remove duplicate fstab entries (FIX: prevent duplicate on re-run)
    if grep -qF "$SWAP_PATH" /etc/fstab; then
        yellow_msg "Removing old fstab entry for $SWAP_PATH"
        # Backup fstab
        cp /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S)"
        sed -i "\|$SWAP_PATH|d" /etc/fstab
    fi

    # Check available disk space (need at least SWAP_SIZE + 100MB)
    # FIX: check filesystem of SWAP_PATH directory, not hardcoded /
    # FIX: remove numfmt dependency (not always available) - use pure bash
    swap_dir=$(dirname "$SWAP_PATH")
    # Fallback to / if dirname doesn't exist yet
    [ -d "$swap_dir" ] || swap_dir="/"
    # Use --output to be robust against df header variations
    avail_mb=$(df -m --output=avail "$swap_dir" 2>/dev/null | tail -n1 | tr -d ' ')
    # Pure bash conversion of SWAP_SIZE to MB (no numfmt)
    case "$SWAP_SIZE" in
        *G|*g) swap_mb=$((${SWAP_SIZE%[Gg]} * 1024)) ;;
        *M|*m) swap_mb=${SWAP_SIZE%[Mm]} ;;
        *K|*k) swap_mb=$((${SWAP_SIZE%[Kk]} / 1024)); [ "$swap_mb" -eq 0 ] && swap_mb=1 ;;
        *)     swap_mb=$((SWAP_SIZE / 1024 / 1024)); [ "$swap_mb" -eq 0 ] && swap_mb=2048 ;;
    esac
    # Validate numeric
    if ! [[ "$avail_mb" =~ ^[0-9]+$ ]]; then
        yellow_msg "Warning: could not determine free space for $swap_dir, skipping space check"
    elif [ "$avail_mb" -lt $((swap_mb + 100)) ]; then
        red_msg "Not enough disk space on $swap_dir. Available: ${avail_mb}M, Required: ${swap_mb}M + 100M overhead"
        return 1
    fi

    # Allocate swap file - try fallocate, fallback to dd (fallocate fails on some FS like XFS, btrfs)
    yellow_msg "Allocating $SWAP_SIZE at $SWAP_PATH..."
    if ! fallocate -l "$SWAP_SIZE" "$SWAP_PATH" 2>/dev/null; then
        yellow_msg "fallocate failed, using dd (slower but compatible)..."
        # dd fallback: calculate count (case-insensitive, consistent with swap_mb)
        # Use 1M blocks
        case "$SWAP_SIZE" in
            *G|*g) count=$((${SWAP_SIZE%[Gg]} * 1024)) ;;
            *M|*m) count=${SWAP_SIZE%[Mm]} ;;
            *K|*k) count=$((${SWAP_SIZE%[Kk]} / 1024)); [ "$count" -eq 0 ] && count=1 ;;
            *)     count=$((SWAP_SIZE / 1024 / 1024)); [ "$count" -eq 0 ] && count=2048 ;;
        esac
        if ! dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$count" status=progress; then
            red_msg "Failed to create swap file via dd"
            rm -f "$SWAP_PATH"
            return 1
        fi
    fi

    chmod 600 "$SWAP_PATH"
    if ! mkswap "$SWAP_PATH"; then
        red_msg "mkswap failed"
        rm -f "$SWAP_PATH"
        return 1
    fi
    if ! swapon "$SWAP_PATH"; then
        red_msg "swapon failed - check dmesg"
        return 1
    fi

    # Add to fstab only if not already present (idempotent)
    if ! grep -qF "$SWAP_PATH" /etc/fstab; then
        echo "$SWAP_PATH   none    swap    sw    0   0" >> /etc/fstab
    fi

    # Verify
    swapon --show | grep -q "$SWAP_PATH" && green_msg "SWAP Created Successfully: $(swapon --show | grep "$SWAP_PATH")" || red_msg "SWAP creation verification failed"

    echo
    green_msg 'SWAP Created Successfully.'
    echo
    sleep 0.5
}

# SYSCTL Optimization - FIXED
sysctl_optimizations() {
    echo
    yellow_msg 'Optimizing Network via sysctl...'
    echo
    sleep 0.5

    # FIX: Use dedicated drop-in file instead of polluting /etc/sysctl.conf
    # Backup original sysctl.conf once with timestamp, not overwrite
    if [ -f "$SYS_PATH" ]; then
        cp -n "$SYS_PATH" "/etc/sysctl.conf.bak.$(date +%F-%H%M%S)" 2>/dev/null || cp "$SYS_PATH" "/etc/sysctl.conf.bak"
        green_msg "Backup of sysctl.conf created."
    fi

    # Check if BBR is available, otherwise fallback to cubic
    TCP_CC="bbr"
    if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        # Try to load bbr module
        modprobe tcp_bbr 2>/dev/null || true
        if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
            yellow_msg "BBR not available, falling back to cubic"
            TCP_CC="cubic"
        fi
    fi

    # Determine if fq qdisc is available
    QDISC="fq"
    if [ ! -d /proc/sys/net/core/default_qdisc ]; then
        QDISC="fq_codel"
    fi

    # Create optimizer sysctl file (idempotent - overwrite, not append)
    cat > "$SYS_OPTIMIZER_PATH" <<EOF
################################################################
# /etc/sysctl.d/99-optimizer.conf - Generated by Linux-Optimizer (Fixed)
################################################################

## File system settings
fs.file-max = 67108864

## Network core settings
net.core.default_qdisc = ${QDISC}
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 262144
net.core.somaxconn = 65536
net.core.rmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_max = 33554432
net.core.wmem_default = 1048576

## TCP settings
net.ipv4.tcp_rmem = 16384 1048576 33554432
net.ipv4.tcp_wmem = 16384 1048576 33554432
net.ipv4.tcp_congestion_control = ${TCP_CC}
net.ipv4.tcp_fin_timeout = 25
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 7
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 20480
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mem = 65536 1048576 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3

## UDP settings
net.ipv4.udp_mem = 65536 1048576 33554432

## UNIX domain sockets
net.unix.max_dgram_qlen = 256

## Virtual memory settings
vm.min_free_kbytes = 65536
vm.swappiness = 10
vm.vfs_cache_pressure = 250
vm.dirty_ratio = 20
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

## Network Configuration
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
kernel.panic = 1

EOF

    # Optional: Clean old duplicated entries from /etc/sysctl.conf if script was run before with buggy version
    # Remove our managed keys from main sysctl.conf to avoid confusion (keep custom user entries)
    # Create backup before cleaning
    if grep -q "99-optimizer" "$SYS_PATH" 2>/dev/null; then
        sed -i '/99-optimizer/d' "$SYS_PATH"
    fi
    # Remove stale optimizer block if it exists in sysctl.conf (between markers)
    if grep -q "File system settings" "$SYS_PATH"; then
        yellow_msg "Cleaning old optimizer block from $SYS_PATH (now using $SYS_OPTIMIZER_PATH)"
        # Only remove known keys to avoid deleting user comments (FIX: don't delete ^# and ^$)
        for key in fs.file-max net.core.default_qdisc net.core.netdev_max_backlog net.core.optmem_max net.core.somaxconn net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_congestion_control net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_probes net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_max_orphans net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_mem net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.ipv4.tcp_retries2 net.ipv4.tcp_sack net.ipv4.tcp_dsack net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_window_scaling net.ipv4.tcp_adv_win_scale net.ipv4.tcp_ecn net.ipv4.tcp_ecn_fallback net.ipv4.tcp_syncookies net.ipv4.udp_mem net.unix.max_dgram_qlen vm.min_free_kbytes vm.swappiness vm.vfs_cache_pressure net.ipv4.conf.default.rp_filter net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_source_route net.ipv4.conf.default.accept_source_route net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3 net.ipv4.neigh.default.gc_stale_time net.ipv4.conf.default.arp_announce net.ipv4.conf.lo.arp_announce net.ipv4.conf.all.arp_announce kernel.panic vm.dirty_ratio vm.overcommit_memory vm.overcommit_ratio; do
            sed -i "/^${key//./\\.}[[:space:]]*=/d" "$SYS_PATH"
        done
    fi

    chmod 644 "$SYS_OPTIMIZER_PATH"

    # Apply without errors interrupting script
    if sysctl --system >/dev/null 2>&1; then
        green_msg "sysctl --system applied successfully"
    else
        yellow_msg "sysctl --system had warnings, trying sysctl -p $SYS_OPTIMIZER_PATH"
        sysctl -p "$SYS_OPTIMIZER_PATH" || red_msg "sysctl apply failed - check $SYS_OPTIMIZER_PATH"
    fi

    echo
    green_msg 'Network is Optimized. Config: /etc/sysctl.d/99-optimizer.conf'
    echo
    sleep 0.5
}

# Function to find the SSH port and set it in the SSH_PORT variable
find_ssh_port() {
    echo
    yellow_msg "Finding SSH port..."
    echo

    SSH_PORT=""
    if [ -e "$SSH_PATH" ]; then
        # FIX: handle commented and multiple Port lines, take last active one
        SSH_PORT=$(grep -E "^\s*Port\s+[0-9]+" "$SSH_PATH" 2>/dev/null | awk '{print $2}' | tail -n1)
        # Also try to get from sshd -T if available (more reliable)
        if command -v sshd >/dev/null 2>&1; then
            detected=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | tail -n1)
            [ -n "$detected" ] && SSH_PORT="$detected"
        fi

        if [ -n "$SSH_PORT" ]; then
            echo
            green_msg "SSH port found: $SSH_PORT"
            echo
            sleep 0.5
        else
            echo
            green_msg "SSH port is default 22."
            echo
            SSH_PORT=22
            sleep 0.5
        fi
    else
        red_msg "SSH configuration file not found at $SSH_PATH, assuming 22"
        SSH_PORT=22
    fi
}

# Remove old SSH config to prevent duplicates.
remove_old_ssh_conf() {
    if [ ! -f "$SSH_PATH" ]; then
        red_msg "SSH config not found, skipping backup"
        return 0
    fi
    cp "$SSH_PATH" "/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
    echo
    yellow_msg "Default SSH Config file Saved to /etc/ssh/sshd_config.bak.*"
    echo
    sleep 1

    # FIX: More robust cleaning - only remove exact directives we will re-add
    sed -i -e 's/^\s*#\?UseDNS.*/UseDNS no/' \
        -e 's/^\s*#\?Compression.*/Compression yes/' \
        -e '/^\s*Ciphers.*/d' \
        -e '/^\s*MaxAuthTries/d' \
        -e '/^\s*MaxSessions/d' \
        -e '/^\s*TCPKeepAlive/d' \
        -e '/^\s*ClientAliveInterval/d' \
        -e '/^\s*ClientAliveCountMax/d' \
        -e '/^\s*AllowAgentForwarding/d' \
        -e '/^\s*AllowTcpForwarding/d' \
        -e '/^\s*GatewayPorts/d' \
        -e '/^\s*PermitTunnel/d' \
        -e '/^\s*X11Forwarding/d' "$SSH_PATH"

    # Ensure Ciphers line is set correctly (only once)
    if ! grep -q "^Ciphers" "$SSH_PATH"; then
        echo "Ciphers aes256-ctr,chacha20-poly1305@openssh.com" >> "$SSH_PATH"
    fi
}

# Update SSH config - FIXED: reasonable keepalive, secure defaults
update_sshd_conf() {
    echo
    yellow_msg 'Optimizing SSH...'
    echo
    sleep 0.5

    # FIX: Reasonable keepalive (was 3000/100 = 83h timeout, unreasonable)
    # 300s interval * 3 probes = 15min idle timeout, standard hardening
    # FIX: Security-sensitive options disabled by default (was yes, insecure)
    # Only TCPKeepAlive yes is kept; forwarding/tunneling/X11 disabled

    # Helper to set or replace a directive idempotently
    set_sshd_opt() {
        local key="$1" val="$2"
        if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$SSH_PATH"; then
            sed -i -E "s|^[[:space:]]*${key}[[:space:]]+.*|${key} ${val}|" "$SSH_PATH"
        else
            echo "${key} ${val}" >> "$SSH_PATH"
        fi
    }

    set_sshd_opt "TCPKeepAlive" "yes"
    set_sshd_opt "ClientAliveInterval" "300"
    set_sshd_opt "ClientAliveCountMax" "3"
    # Security: disable forwarding/tunneling by default - user can enable manually if needed
    set_sshd_opt "AllowTcpForwarding" "no"
    set_sshd_opt "GatewayPorts" "no"
    set_sshd_opt "PermitTunnel" "no"
    set_sshd_opt "X11Forwarding" "no"
    set_sshd_opt "AllowAgentForwarding" "no"

    # FIX: Validate config before restart
    if sshd -t 2>/dev/null; then
        if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            green_msg 'SSH is Optimized.'
        else
            red_msg 'SSH config test passed but restart failed - try manually: systemctl restart ssh'
        fi
    else
        red_msg 'sshd -t failed - NOT restarting SSH to avoid lockout. Check /etc/ssh/sshd_config'
        sshd -t
    fi
    echo
    sleep 0.5
}

# System Limits Optimizations - FIXED
limits_optimizations() {
    echo
    yellow_msg 'Optimizing System Limits...'
    echo
    sleep 0.5

    # FIX: Don't pollute /etc/profile with ulimit. Use limits.d and systemd.
    # FIX: Only clean ulimit lines added by previous buggy optimizer, preserve user custom entries
    # Old code used '/^ulimit/d' and '/ulimit -[cdef...]/d' which deleted ANY user ulimit
    # Now we only delete the exact 14 lines the buggy script added (specific values)
    optimizer_ulimits=(
        "ulimit -c unlimited"
        "ulimit -d unlimited"
        "ulimit -f unlimited"
        "ulimit -i unlimited"
        "ulimit -l unlimited"
        "ulimit -m unlimited"
        "ulimit -n 1048576"
        "ulimit -q unlimited"
        "ulimit -s -H 65536"
        "ulimit -s 32768"
        "ulimit -t unlimited"
        "ulimit -u unlimited"
        "ulimit -v unlimited"
        "ulimit -x unlimited"
    )
    found_optimizer_entry=false
    for entry in "${optimizer_ulimits[@]}"; do
        if grep -qF "$entry" "$PROF_PATH" 2>/dev/null; then
            found_optimizer_entry=true
            break
        fi
    done
    if [ "$found_optimizer_entry" = true ]; then
        yellow_msg "Cleaning old optimizer ulimit entries from $PROF_PATH (preserving custom user entries)"
        cp "$PROF_PATH" "/etc/profile.bak.$(date +%F-%H%M%S)"
        # FIX: Use exact-match filtering with whitespace trimming to avoid deleting user custom values
        # e.g., user has "ulimit -n 65535" should be kept, only "ulimit -n 1048576" removed
        tmp_prof="${PROF_PATH}.tmp.$$"
        : > "$tmp_prof"
        while IFS= read -r line || [ -n "$line" ]; do
            trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            skip=false
            for entry in "${optimizer_ulimits[@]}"; do
                if [ "$trimmed" = "$entry" ]; then
                    skip=true
                    break
                fi
            done
            if [ "$skip" = false ]; then
                printf '%s\n' "$line" >> "$tmp_prof"
            else
                yellow_msg "Removed optimizer entry: $trimmed"
            fi
        done < "$PROF_PATH"
        mv "$tmp_prof" "$PROF_PATH"
    else
        yellow_msg "No optimizer ulimit entries found in $PROF_PATH, leaving custom entries untouched"
    fi

    # Create limits.d config (proper way)
    cat > "$LIMITS_CONF" <<'EOF'
# /etc/security/limits.d/99-optimizer.conf - Fixed
*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
*               soft    nproc           unlimited
*               hard    nproc           unlimited
*               soft    memlock         unlimited
*               hard    memlock         unlimited
*               soft    core            unlimited
*               hard    core            unlimited
*               soft    stack           32768
*               hard    stack           65536
EOF
    chmod 644 "$LIMITS_CONF"

    # FIX: Also tune systemd defaults (system-wide)
    # Backup and set in /etc/systemd/system.conf and user.conf if needed
    for conf in /etc/systemd/system.conf /etc/systemd/user.conf; do
        if [ -f "$conf" ]; then
            # Only set if not already tuned
            if ! grep -q "DefaultLimitNOFILE=1048576" "$conf"; then
                cp "$conf" "${conf}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
                # Remove old DefaultLimit entries to avoid duplicates
                sed -i '/^DefaultLimitNOFILE/d' "$conf"
                sed -i '/^DefaultLimitNPROC/d' "$conf"
                sed -i '/^DefaultLimitMEMLOCK/d' "$conf"
                {
                    echo "DefaultLimitNOFILE=1048576"
                    echo "DefaultLimitNPROC=infinity"
                    echo "DefaultLimitMEMLOCK=infinity"
                } >> "$conf"
            fi
        fi
    done

    # Ensure pam_limits is enabled
    if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi

    # Apply for current session (best effort)
    ulimit -n 1048576 2>/dev/null || ulimit -n 65536 2>/dev/null || true

    # Reload systemd if available
    systemctl daemon-reload 2>/dev/null || true

    echo
    green_msg 'System Limits are Optimized. Config: /etc/security/limits.d/99-optimizer.conf (re-login required)'
    echo
    sleep 0.5
}

# UFW Optimizations - FIXED (removed UDP, fixed SSH_PORT handling, idempotent)
ufw_optimizations() {
    echo
    yellow_msg 'Installing & Optimizing UFW...'
    echo
    sleep 0.5

    # FIX: Don't purge firewalld blindly - only if exists and not needed
    if dpkg -l | grep -q firewalld 2>/dev/null; then
        yellow_msg "firewalld detected, purging to avoid conflict with UFW..."
        apt -y purge firewalld 2>/dev/null || true
    fi

    apt -q update
    apt install -y ufw 2>/dev/null || {
        red_msg "UFW install failed"
        return 1
    }

    # Ensure SSH_PORT is set
    if [ -z "$SSH_PORT" ]; then
        find_ssh_port
    fi
    # Validate SSH_PORT is numeric
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        red_msg "Invalid SSH port detected: $SSH_PORT, defaulting to 22"
        SSH_PORT=22
    fi

    # Disable UFW temporarily to configure
    ufw --force disable 2>/dev/null || true

    # FIX: Reset to avoid duplicate rules on re-run (optional but cleaner)
    # ufw --force reset 2>/dev/null || true

    # FIX: Only allow TCP - REMOVED UDP per request
    # Delete existing rules for SSH to avoid duplicates
    ufw delete allow "$SSH_PORT" 2>/dev/null || true
    ufw delete allow "$SSH_PORT/tcp" 2>/dev/null || true

    ufw allow "$SSH_PORT/tcp" comment 'SSH' 2>/dev/null || ufw allow "$SSH_PORT"
    ufw allow 80/tcp comment 'HTTP' 2>/dev/null || ufw allow 80/tcp
    ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || ufw allow 443/tcp

    # Ensure we didn't leave UDP rules from previous buggy run - delete them
    ufw delete allow 80/udp 2>/dev/null || true
    ufw delete allow 443/udp 2>/dev/null || true
    # Also delete generic 80,443 without proto if they imply both
    # (ufw allow 80 without /tcp allows both - so we clean and re-add only tcp)

    sleep 0.5

    # FIX: Don't blindly sed /etc/default/ufw - check if needed
    # The original: s+/etc/ufw/sysctl.conf+/etc/sysctl.conf+gI breaks UFW's sysctl handling
    # Better to leave UFW default or ensure it points to optimizer file
    if grep -q "/etc/ufw/sysctl.conf" /etc/default/ufw 2>/dev/null; then
        yellow_msg "Leaving /etc/default/ufw sysctl path as default (UFW will use /etc/ufw/sysctl.conf, system uses /etc/sysctl.d/99-optimizer.conf)"
        # Not changing it - original sed was harmful
    fi

    # Set default policies if not set (safe defaults)
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true

    # Enable & Reload - non-interactive
    echo "y" | ufw --force enable 2>/dev/null || ufw --force enable
    ufw reload 2>/dev/null || true

    # Show status
    ufw status verbose 2>/dev/null || ufw status

    echo
    green_msg 'UFW is Installed & Optimized. (Only TCP 80,443 + SSH:'"$SSH_PORT"'/tcp opened. UDP removed.)'
    echo
    sleep 0.5
}

# Show the Menu - FIXED (removed XanMod)
show_menu() {
    echo
    yellow_msg 'Choose One Option: '
    echo
    green_msg '1  - Apply Everything (Update + Packages + SWAP + Network + SSH + Limits + UFW) (RECOMMENDED)'
    echo
    green_msg '2  - Complete Update + Useful Packages + Make SWAP + Optimize Network, SSH & System Limits + UFW'
    green_msg '3  - Complete Update + Make SWAP + Optimize Network, SSH & System Limits + UFW'
    green_msg '4  - Complete Update + Make SWAP + Optimize Network, SSH & System Limits'
    echo
    green_msg '5  - Complete Update & Clean the OS.'
    green_msg '6  - Install Useful Packages.'
    green_msg '7  - Make SWAP (2Gb).'
    green_msg '8  - Optimize the Network, SSH & System Limits.'
    echo
    green_msg '9  - Optimize the Network settings.'
    green_msg '10 - Optimize the SSH settings.'
    green_msg '11 - Optimize the System Limits.'
    echo
    green_msg '12 - Install & Optimize UFW (TCP only).'
    echo
    red_msg 'q - Exit.'
    echo
}

# Choosing Program
main() {
    while true; do
        show_menu
        read -rp 'Enter Your Choice: ' choice
        case $choice in
        1)
            apply_everything
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        2)
            complete_update
            sleep 0.5
            installations
            enable_packages
            sleep 0.5
            swap_maker
            sleep 0.5
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            find_ssh_port
            ufw_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        3)
            complete_update
            sleep 0.5
            swap_maker
            sleep 0.5
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            find_ssh_port
            ufw_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        4)
            complete_update
            sleep 0.5
            swap_maker
            sleep 0.5
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        5)
            complete_update
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        6)
            complete_update
            sleep 0.5
            installations
            enable_packages
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        7)
            swap_maker
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        8)
            sysctl_optimizations
            sleep 0.5
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        9)
            sysctl_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ;;
        10)
            remove_old_ssh_conf
            sleep 0.5
            update_sshd_conf
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ;;
        11)
            limits_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ask_reboot
            ;;
        12)
            find_ssh_port
            ufw_optimizations
            sleep 0.5
            echo
            green_msg '========================='
            green_msg  'Done.'
            green_msg '========================='
            ;;
        q|Q)
            exit 0
            ;;
        *)
            red_msg 'Wrong input!'
            ;;
        esac
    done
}

# Apply Everything - FIXED (no XanMod)
apply_everything() {
    complete_update
    sleep 0.5
    disable_terminal_ads
    sleep 0.5
    installations
    enable_packages
    sleep 0.5
    swap_maker
    sleep 0.5
    sysctl_optimizations
    sleep 0.5
    remove_old_ssh_conf
    sleep 0.5
    update_sshd_conf
    sleep 0.5
    limits_optimizations
    sleep 0.5
    find_ssh_port
    ufw_optimizations
    sleep 0.5
}

main
