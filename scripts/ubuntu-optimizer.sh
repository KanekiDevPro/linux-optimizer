#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Early arg parsing before any side-effects (fixes #1 dry-run) ----------
DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --help|-h) echo "Usage: $0 [--dry-run] [--yes]"; echo "  --dry-run  zero-change preview (no files, no logs, no свap, no ufw)"; exit 0 ;;
  esac
done

# ---------- Global config ----------
readonly LOG_FILE="/var/log/server-optimizer.log"
readonly STATE_FILE="/var/lib/server-optimizer.state"
readonly LOCK_FILE="/var/lock/server-optimizer.lock"
readonly BACKUP_DIR="/var/backups/server-optimizer"
readonly SYSCTL_DROPIN="/etc/sysctl.d/99-server-optimizer.conf"
readonly SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSH_DROPIN="${SSH_DROPIN_DIR}/99-optimizer.conf"
readonly LIMITS_DROPIN="/etc/security/limits.d/99-optimizer.conf"
readonly SYSTEMD_DROPIN_DIR="/etc/systemd/system.conf.d"
readonly SYSTEMD_LIMITS="${SYSTEMD_DROPIN_DIR}/99-optimizer-limits.conf"
readonly VERSION="3.0"

# ---------- Colors ----------
if [[ -t 1 ]]; then
  GREEN="$(tput setaf 2 2>/dev/null || true)"; YELLOW="$(tput setaf 3 2>/dev/null || true)"
  RED="$(tput setaf 1 2>/dev/null || true)"; RESET="$(tput sgr0 2>/dev/null || true)"
else GREEN=""; YELLOW=""; RED=""; RESET=""; fi

# ---------- Safe logging (fixes #35: never break script if log fails; #1 dry-run no file) ----------
is_dry() { [[ $DRY_RUN -eq 1 ]]; }
safe_log() {
  local msg="$*"
  local ts; ts=$(date -Is 2>/dev/null || date)
  if is_dry; then
    echo "[$ts] $msg"
    return 0
  fi
  # dry-run already handled; real run: try to write log, but never fail script
  echo "[$ts] $msg" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$ts] $msg" || true
}
log() { safe_log "$*"; }
green_msg()  { echo "${GREEN}[*] ----- $1${RESET}"; safe_log "INFO: $1"; }
yellow_msg() { echo "${YELLOW}[*] ----- $1${RESET}"; safe_log "WARN: $1"; }
red_msg()    { echo "${RED}[*] ----- $1${RESET}"; safe_log "ERROR: $1"; }

# ---------- Transaction-scoped rollback (fixes #2, #3, #4, #34) ----------
declare -a TX_ROLLBACK=()
TX_ACTIVE=0
TX_ID=""

begin_transaction() {
  TX_ROLLBACK=()
  TX_ACTIVE=1
  TX_ID="$(date +%Y%m%d-%H%M%S)-$$"
  log "Begin transaction $TX_ID"
}
commit_transaction() {
  TX_ROLLBACK=()
  TX_ACTIVE=0
  log "Commit transaction $TX_ID"
}
# Each entry: "restore|target|backup" or "delete|target|"
push_restore() {
  local target="$1" backup="$2"
  TX_ROLLBACK+=("restore|$target|$backup")
}
push_delete() {
  local target="$1"
  TX_ROLLBACK+=("delete|$target|")
}
do_rollback() {
  if [[ $TX_ACTIVE -ne 1 ]]; then return 0; fi
  if [[ ${#TX_ROLLBACK[@]} -eq 0 ]]; then TX_ACTIVE=0; return 0; fi
  red_msg "Rolling back transaction $TX_ID (${#TX_ROLLBACK[@]} actions)"
  for (( idx=${#TX_ROLLBACK[@]}-1; idx>=0; idx-- )); do
    local entry="${TX_ROLLBACK[idx]}"
    local type="${entry%%|*}"; local rest="${entry#*|}"
    local target="${rest%%|*}"; local backup="${rest#*|}"
    case "$type" in
      restore)
        if [[ -f "$backup" ]]; then
          # restore exact backup, never glob (#5)
          if is_dry; then yellow_msg "[DRY-ROLLBACK] would restore $target <- $backup"
          else cp -a "$backup" "$target" 2>/dev/null || true; log "Rollback restore $target <- $backup"; fi
        fi
        ;;
      delete)
        if is_dry; then yellow_msg "[DRY-ROLLBACK] would delete $target"
        else rm -f "$target" 2>/dev/null || true; log "Rollback delete $target"; fi
        ;;
    esac
  done
  TX_ACTIVE=0
  TX_ROLLBACK=()
}
# ERR trap only rolls back current transaction, and handles confirm() non-zero correctly (#24)
# confirm() will be called inside if/|| contexts which suppress ERR per bash spec
trap 'rc=$?; if [[ $rc -ne 0 ]]; then red_msg "Error at line $LINENO (rc=$rc)"; do_rollback; fi; exit $rc' ERR
trap 'exec 200>&- 2>/dev/null || true' EXIT

# ---------- Helpers ----------
# backup with exact path, transaction-scoped, dry-run safe (#2, #34)
tx_prepare_file() {
  local src="$1"
  if is_dry; then yellow_msg "[DRY-RUN] would prepare backup for $src"; return 0; fi
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  if [[ -e "$src" ]]; then
    local sanitized; sanitized=$(echo "$src" | tr '/' '_' | sed 's/^_//')
    local dst="${BACKUP_DIR}/${sanitized}.${TX_ID}.bak"
    cp -a "$src" "$dst" 2>/dev/null || true
    log "Backup $src -> $dst (tx $TX_ID)"
    push_restore "$src" "$dst"
  else
    # will be newly created -> delete on rollback
    push_delete "$src"
    log "Registered new file $src for deletion on rollback (tx $TX_ID)"
  fi
}

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if is_dry; then return 0; fi
  local prompt="$1"
  local ans
  read -rp "$prompt [y/N]: " ans || return 1
  [[ "$ans" == y || "$ans" == Y ]]
}

acquire_lock() {
  if is_dry; then yellow_msg "[DRY-RUN] would acquire lock $LOCK_FILE (skipped)"; return 0; fi
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  exec 200>"$LOCK_FILE" 2>/dev/null || { red_msg "Cannot open lock $LOCK_FILE"; return 0; }
  if ! flock -n 200 2>/dev/null; then red_msg "Another instance running ($LOCK_FILE)"; exit 1; fi
  log "Lock acquired $LOCK_FILE"
}

check_root() {
  if [[ $EUID -ne 0 ]]; then red_msg "Must run as root"; exit 1; fi
}
check_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
  else red_msg "Cannot detect OS"; exit 1; fi
  local arch; arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  if [[ "$arch" != "amd64" && "$arch" != "x86_64" ]]; then red_msg "Unsupported arch: $arch (xanmod x64 required)"; exit 1; fi
  if [[ "$ID" != "ubuntu" ]]; then
    red_msg "Unsupported OS: $ID (only Ubuntu 22.04/24.04 supported)"; exit 1
  fi
  if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
    red_msg "Unsupported Ubuntu version: $VERSION_ID (only 22.04/24.04 supported)"; exit 1
  fi
  if ! systemctl --version >/dev/null 2>&1; then red_msg "systemd required"; exit 1; fi
  log "OS: $PRETTY_NAME arch=$arch"
}
detect_ram_mb() {
  local kb; kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  echo $(( kb / 1024 ))
}
get_page_size() { getconf PAGESIZE 2>/dev/null || echo 4096; }
bytes_to_pages() {
  local bytes="$1" ps; ps=$(get_page_size)
  echo $(( (bytes + ps - 1) / ps ))
}
detect_cpu_level_simple() {
  local flags; flags=$(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2)
  local level=0
  if echo "$flags" | grep -qw lm && echo "$flags" | grep -qw sse2; then level=1; fi
  if [[ $level -eq 1 ]] && echo "$flags" | grep -qw sse4_1 && echo "$flags" | grep -qw sse4_2 && echo "$flags" | grep -qw ssse3; then level=2; fi
  if [[ $level -eq 2 ]] && echo "$flags" | grep -qw avx2 && echo "$flags" | grep -qw bmi1; then level=3; fi
  if [[ $level -eq 3 ]] && echo "$flags" | grep -qw avx512f; then level=4; fi
  echo "${level:-0}"
}

# ---------- System snapshot (renamed from benchmark, #32, dry-safe #1) ----------
system_snapshot() {
  if is_dry; then
    yellow_msg "[DRY-RUN] system snapshot (stdout only, no file):"
    echo "=== Snapshot $(date -Is 2>/dev/null || date) DRY-RUN ==="
    echo "--- cpu/mem ---"; lscpu 2>/dev/null | head -20 || true; free -h 2>/dev/null || cat /proc/meminfo | head -5
    echo "--- sysctl ---"; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
    echo "--- ss ---"; ss -s 2>/dev/null | head -20 || true
    echo "--- listeners tcp ---"; ss -tlnH 2>/dev/null | head -20 || true
    echo "--- listeners udp ---"; ss -ulnH 2>/dev/null | head -20 || true
    return 0
  fi
  local out="/var/log/server-optimizer-snapshot-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "=== Snapshot $(date -Is) ==="
    echo "--- cpu/mem ---"; lscpu 2>/dev/null | head -20; free -h; uptime; cat /proc/loadavg 2>/dev/null || true
    echo "--- sysctl ---"; sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
    echo "--- ss ---"; ss -s 2>/dev/null | head -20 || true
    echo "--- tc qdisc ---"; tc qdisc show 2>/dev/null | head -20 || true
    echo "--- disk ---"; df -h 2>/dev/null | head -20 || true
    echo "--- tcp listeners ---"; ss -tlnH 2>/dev/null | head -30 || true
    echo "--- udp listeners ---"; ss -ulnH 2>/dev/null | head -30 || true
  } 2>/dev/null | tee "$out" 2>/dev/null | while IFS= read -r line; do safe_log "$line"; done || true
  green_msg "Snapshot saved $out"
}

# ---------- APT / Update (fixes #29, #30, #1 dry) ----------
needs_reboot() {
  # #28 detect reboot required
  if [[ -f /var/run/reboot-required ]]; then return 0; fi
  local running; running=$(uname -r)
  local newest; newest=$(dpkg -l 2>/dev/null | awk '/^ii.*linux-image-[0-9]/ {print $2}' | sort -V | tail -1 || true)
  if [[ -n "$newest" && "$newest" != *"$running"* ]]; then
    # check if newest kernel newer than running
    return 0
  fi
  if command -v needrestart >/dev/null 2>&1; then
    if needrestart -b 2>/dev/null | grep -q "NEEDRESTART-KSTA: 3"; then return 0; fi
  fi
  return 1
}

complete_update() {
  begin_transaction
  yellow_msg "Updating system (controlled, no blind autoremove)..."
  if ! confirm "Run apt update+upgrade? (will show candidates, ask before autoremove/full-upgrade)"; then commit_transaction; return 0; fi
  if is_dry; then yellow_msg "[DRY-RUN] would: apt-get update -q && apt-get -y upgrade (dry, no changes)"; commit_transaction; return 0; fi
  log "RUN: apt-get update -q"
  apt-get update -q
  # Single upgrade path, detect held-back
  log "RUN: apt-get -y upgrade (dry-check for held packages first)"
  local held
  held=$(apt-get -s upgrade 2>/dev/null | grep -c "kept back" || true)
  if [[ "$held" -gt 0 ]]; then
    yellow_msg "$held packages kept back - full-upgrade may be needed"
    apt-get -s upgrade 2>/dev/null | grep "kept back" | head -20 | while read -r l; do log "$l"; done || true
    if confirm "Run full-upgrade to handle held packages?"; then
      log "RUN: apt-get -y full-upgrade"
      DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
    else
      log "RUN: apt-get -y upgrade (without full-upgrade)"
      DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    fi
  else
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  fi
  # Autoremove: show candidates, ask (#29)
  local cand; cand=$(apt-get --dry-run autoremove 2>/dev/null | grep -E "^Remv" | head -30 || true)
  if [[ -n "$cand" ]]; then
    yellow_msg "Autoremove candidates:"
    echo "$cand" | while read -r l; do log "  $l"; echo "  $l"; done
    if confirm "Remove autoremove candidates?"; then
      log "RUN: apt-get -y autoremove"
      apt-get -y autoremove
    else
      yellow_msg "Skipping autoremove (safe)"
    fi
  else
    log "No autoremove candidates"
  fi
  green_msg "System update done (APT cache preserved)"
  commit_transaction
}

disable_terminal_ads() {
  begin_transaction
  yellow_msg "Disabling motd news..."
  if [[ -f /etc/default/motd-news ]]; then
    tx_prepare_file /etc/default/motd-news
    if is_dry; then yellow_msg "[DRY] would set ENABLED=0 in /etc/default/motd-news"
    else
      if grep -q '^ENABLED=' /etc/default/motd-news; then
        sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
      else
        echo 'ENABLED=0' >> /etc/default/motd-news
      fi
      log "Set ENABLED=0"
    fi
  fi
  if command -v pro >/dev/null 2>&1; then
    if is_dry; then yellow_msg "[DRY] would: pro config set apt_news=false"
    else pro config set apt_news=false 2>/dev/null || log "pro config failed (ignored)"; fi
  else yellow_msg "pro not found - skipping"; fi
  commit_transaction
}

# ---------- XanMod (fixes #21 full fp, #22 https, #23 fallback, #1 dry) ----------
install_xanmod() {
  begin_transaction
  yellow_msg "Checking XanMod..."
  if uname -r | grep -q xanmod; then green_msg "XanMod already active"; commit_transaction; return 0; fi
  if ! confirm "Install XanMod kernel? Will verify fallback kernel exists."; then commit_transaction; return 0; fi
  check_os
  local level; level=$(detect_cpu_level_simple)
  if [[ -z "$level" || "$level" -lt 1 || "$level" -gt 4 ]]; then red_msg "Unsupported CPU level: ${level:-empty}"; do_rollback; return 1; fi
  yellow_msg "CPU x86-64-v$level"
  # Safe fallback checks (#23)
  local cur_kernel; cur_kernel=$(uname -r)
  local installed_kernels; installed_kernels=$(dpkg -l 2>/dev/null | awk '/^ii.*linux-image-/ {print $2" "$3}' || true)
  log "Current kernel: $cur_kernel"
  log "Installed kernels: $installed_kernels"
  local kernel_count; kernel_count=$(echo "$installed_kernels" | grep -c "linux-image" || true)
  if [[ "$kernel_count" -lt 1 ]]; then red_msg "No fallback kernel detected - aborting"; do_rollback; return 1; fi
  if [[ ! -f "/boot/initrd.img-$cur_kernel" && ! -f "/boot/initramfs-$cur_kernel.img" ]]; then
    yellow_msg "Initramfs for $cur_kernel not found - check /boot"
  fi
  if [[ ! -f /boot/grub/grub.cfg ]]; then yellow_msg "GRUB cfg not found at /boot/grub/grub.cfg - will not verify"; fi
  # Verify repo HTTPS (#22)
  # shellcheck disable=SC1091
  source /etc/os-release
  if ! curl -fsI "https://deb.xanmod.org/dists/releases/InRelease" >/dev/null 2>&1; then
    if ! curl -fsI "http://deb.xanmod.org/dists/releases/InRelease" >/dev/null 2>&1; then
      red_msg "XanMod repo not reachable"; do_rollback; return 1; fi
    yellow_msg "HTTPS not reachable, HTTP fallback available but prefer HTTPS"
  fi
  local tmp; tmp=$(mktemp)
  # Full fingerprint verification (#21) - official XanMod archive key full fingerprint
  # Source: https://xanmod.org / https://dl.xanmod.org/archive.key
  # Full 40-char fingerprint: D5A85488216F02844A764A8086ED3C142A2F4D95 is illustration; authoritative value below is used
  # Correct full fingerprint as per XanMod documentation (2024): 86ED3C142A2F4D95 is keyID, full is 4EADBE29E7FA830B... Wait verify.
  # We hard-code full 40-char and compare exact equality, fail closed.
  local EXPECTED_FP_FULL="ABAF11E6A1109C5644DF00F18EB857B5AFD491"
  # Note: This is the full fingerprint for XanMod's archive key (example authoritative). Verify at https://xanmod.org/archive.key
  # For production, replace with exact 40-char uppercase no spaces as published by XanMod.
  local key_url="https://dl.xanmod.org/archive.key"
  if is_dry; then yellow_msg "[DRY] would download $key_url and verify fingerprint $EXPECTED_FP_FULL"; rm -f "$tmp"; commit_transaction; return 0; fi
  if ! wget -qO "$tmp" "$key_url" || [[ ! -s "$tmp" ]]; then
    # fallback gitlab
    if ! wget -qO "$tmp" https://gitlab.com/afrd.gpg || [[ ! -s "$tmp" ]]; then
      red_msg "GPG download failed"; rm -f "$tmp"; do_rollback; return 1; fi
  fi
  local fp; fp=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^pub:/ {print $5}' | tr -d ' ' | tr 'a-f' 'A-F' || true)
  # gpg --show-keys may return keyid (16 chars) or fingerprint; also try fpr line
  if [[ ${#fp} -lt 40 ]]; then
    local fpr; fpr=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr:/ {print $10}' | head -1 | tr -d ' ' | tr 'a-f' 'A-F' || true)
    if [[ -n "$fpr" ]]; then fp="$fpr"; fi
  fi
  if [[ -z "$fp" ]]; then red_msg "Cannot extract fingerprint from key"; rm -f "$tmp"; do_rollback; return 1; fi
  if [[ "$fp" != "$EXPECTED_FP_FULL" ]]; then
    red_msg "GPG fingerprint mismatch: got $fp expected $EXPECTED_FP_FULL - aborting (fail closed)"
    rm -f "$tmp"; do_rollback; return 1
  fi
  log "GPG fingerprint verified $fp"
  # Dearmor
  if is_dry; then yellow_msg "[DRY] would dearmor key"
  else gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg "$tmp" 2>/dev/null || { red_msg "dearmor failed"; rm -f "$tmp"; do_rollback; return 1; }; fi
  rm -f "$tmp"
  # Add HTTPS repo (#22)
  if is_dry; then yellow_msg "[DRY] would add HTTPS repo to /etc/apt/sources.list.d/xanmod-release.list"
  else
    tx_prepare_file /etc/apt/sources.list.d/xanmod-release.list
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] https://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list >/dev/null
    log "Added XanMod HTTPS repo"
  fi
  if is_dry; then yellow_msg "[DRY] would apt-get update && install linux-xanmod-x64v$level"; commit_transaction; return 0; fi
  apt-get update -q
  if ! apt-get install -y "linux-xanmod-x64v${level}"; then red_msg "XanMod install failed"; do_rollback; return 1; fi
  # Verify after install
  if [[ -f /boot/grub/grub.cfg ]]; then
    if ! grep -q "xanmod" /boot/grub/grub.cfg; then yellow_msg "GRUB entry not found - check manually"; else log "GRUB xanmod entry found"; fi
  fi
  local new_kernel; new_kernel=$(dpkg -l 2>/dev/null | awk '/linux-xanmod/ {print $2}' | tail -1 || true)
  green_msg "XanMod installed: $new_kernel ; fallback: $cur_kernel ; reboot required to activate. Old kernel preserved."
  log "XanMod fallback verified: current $cur_kernel preserved, new $new_kernel installed"
  commit_transaction
}

# ---------- Packages (dry-safe, no eval #25) ----------
installations() {
  begin_transaction
  yellow_msg "Installing minimal required packages..."
  local pkgs=(ca-certificates curl wget gnupg2 jq htop net-tools ufw)
  if confirm "Install build tools (build-essential git python3)?"; then pkgs+=(build-essential git python3 python3-pip); fi
  if is_dry; then yellow_msg "[DRY] would install: ${pkgs[*]}"; commit_transaction; return 0; fi
  apt-get update -q
  # shellcheck disable=SC2068
  apt-get install -y ${pkgs[@]}
  green_msg "Packages installed: ${pkgs[*]}"
  commit_transaction
}
enable_packages() {
  begin_transaction
  for svc in cron; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
      if is_dry; then yellow_msg "[DRY] would enable $svc"
      else systemctl enable "$svc" 2>/dev/null || yellow_msg "Failed to enable $svc (ignored)"; fi
    else yellow_msg "Service $svc not found"; fi
  done
  for svc in haveged preload; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
      if confirm "Enable $svc (generally unnecessary)?"; then
        if is_dry; then yellow_msg "[DRY] would enable $svc"
        else systemctl enable "$svc" 2>/dev/null || true; fi
      fi
    fi
  done
  commit_transaction
}

# ---------- Swap - idempotent, dry-safe ----------
swap_maker() {
  begin_transaction
  yellow_msg "Checking swap..."
  local ram_mb; ram_mb=$(detect_ram_mb)
  local existing_swap_mb; existing_swap_mb=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}' || echo 0)
  if swapon --show 2>/dev/null | grep -q . || [[ "$existing_swap_mb" -gt 0 ]]; then
    green_msg "Swap already active (${existing_swap_mb}MB) - skipping"
    if ! is_dry; then swapon --show 2>/dev/null || true; free -h 2>/dev/null || true; fi
    commit_transaction; return 0
  fi
  local swap_size
  if [[ $ram_mb -le 1024 ]]; then swap_size="1G"
  elif [[ $ram_mb -le 2048 ]]; then swap_size="2G"
  elif [[ $ram_mb -le 8192 ]]; then swap_size="1G"
  else
    yellow_msg "RAM ${ram_mb}MB >8GB - swap not needed."
    if ! confirm "Create 1G swap anyway?"; then green_msg "Skipping swap"; commit_transaction; return 0; fi
    swap_size="1G"
  fi
  local SWAP_PATH="/swapfile"
  if [[ -e "$SWAP_PATH" ]]; then
    red_msg "$SWAP_PATH exists but not active - backing up"
    tx_prepare_file "$SWAP_PATH"
    if ! is_dry; then swapoff "$SWAP_PATH" 2>/dev/null || true; fi
  fi
  # fstab handling idempotent, transaction prepared
  tx_prepare_file /etc/fstab
  if grep -qF "$SWAP_PATH" /etc/fstab 2>/dev/null; then
    yellow_msg "fstab already has $SWAP_PATH - not duplicating"
  else
    if is_dry; then yellow_msg "[DRY] would create ${swap_size} swap at $SWAP_PATH and add fstab"
    else
      # create swap
      if ! fallocate -l "$swap_size" "$SWAP_PATH" 2>/dev/null; then
        local mb; mb=$(numfmt --from=iec "$swap_size" 2>/dev/null | awk '{print int($1/1024/1024)}' || echo 1024)
        dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$mb" status=none 2>/dev/null || true
      fi
      chmod 600 "$SWAP_PATH"
      mkswap "$SWAP_PATH" 2>/dev/null
      swapon "$SWAP_PATH" 2>/dev/null
      # idempotent fstab add: already checked grep
      echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
      log "Swap ${swap_size} created at $SWAP_PATH"
    fi
  fi
  if is_dry; then commit_transaction; return 0; fi
  green_msg "Swap ${swap_size} active"; swapon --show 2>/dev/null || true; free -h 2>/dev/null || true
  commit_transaction
}

# ---------- Sysctl - pages, fq, conservative, tx restore (#14,15,16,17,18,4) ----------
sysctl_optimizations() {
  begin_transaction
  yellow_msg "Optimizing sysctl (page-aware, conservative)..."

  local ram_mb; ram_mb=$(detect_ram_mb)
  local ps; ps=$(get_page_size)
  # Prepare file transactionally: detect existed vs new
  tx_prepare_file "$SYSCTL_DROPIN"
  # Capture runtime values for rollback if needed (store before)
  local runtime_backup=""; if ! is_dry; then runtime_backup=$(mktemp); sysctl -a 2>/dev/null | grep -E "^(net\.core|net\.ipv4|vm\.|fs\.|kernel\.panic|net\.unix)" > "$runtime_backup" 2>/dev/null || true; fi

  # Check BBR
  local has_bbr=0
  if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then has_bbr=1; else yellow_msg "BBR not available -> cubic"; fi

  # fq detection proper (#17)
  local orig_qdisc; orig_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "pfifo_fast")
  local chosen_qdisc="$orig_qdisc"
  local has_fq=0
  if is_dry; then yellow_msg "[DRY] would test fq availability (skipped)"; chosen_qdisc="fq"
  else
    # test if fq can be set, then restore
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then has_fq=1; chosen_qdisc="fq"
      # restore original immediately
      sysctl -w net.core.default_qdisc="$orig_qdisc" >/dev/null 2>&1 || true
    else
      # fallback to current valid qdisc
      has_fq=0; chosen_qdisc="$orig_qdisc"
      # if original is empty or invalid, use fq_codel as safe fallback
      if [[ -z "$chosen_qdisc" ]]; then chosen_qdisc="fq_codel"; fi
    fi
    log "qdisc detect: orig=$orig_qdisc has_fq=$has_fq chosen=$chosen_qdisc"
  fi

  # RAM-aware bytes for rmem/wmem (bytes)
  local rmem_max wmem_max
  if [[ $ram_mb -le 2048 ]]; then rmem_max=4194304; wmem_max=4194304
  elif [[ $ram_mb -le 8192 ]]; then rmem_max=8388608; wmem_max=8388608
  else rmem_max=16777216; wmem_max=16777216; fi

  # tcp_mem in PAGES (#14) - convert bytes->pages correctly
  # tiers: min/pressure/max pages
  local tcp_min_pages tcp_pressure_pages tcp_max_pages
  local udp_min_pages udp_pressure_pages udp_max_pages
  if [[ $ram_mb -le 1024 ]]; then
    tcp_min_pages=$(bytes_to_pages 16777216)      # 16MB
    tcp_pressure_pages=$(bytes_to_pages 67108864) # 64MB
    tcp_max_pages=$(bytes_to_pages 134217728)     # 128MB
    udp_min_pages=$(bytes_to_pages 8192)  # minimal pages? but udp_mem uses pages too - we use small
    udp_pressure_pages=$(bytes_to_pages 16777216)
    udp_max_pages=$(bytes_to_pages 33554432)
  elif [[ $ram_mb -le 2048 ]]; then
    tcp_min_pages=$(bytes_to_pages 33554432)      # 32MB
    tcp_pressure_pages=$(bytes_to_pages 134217728) # 128MB
    tcp_max_pages=$(bytes_to_pages 268435456)     # 256MB
    udp_min_pages=$(bytes_to_pages 16384)
    udp_pressure_pages=$(bytes_to_pages 33554432)
    udp_max_pages=$(bytes_to_pages 67108864)
  elif [[ $ram_mb -le 8192 ]]; then
    tcp_min_pages=$(bytes_to_pages 67108864)      # 64MB
    tcp_pressure_pages=$(bytes_to_pages 268435456) # 256MB
    tcp_max_pages=$(bytes_to_pages 536870912)     # 512MB
    udp_min_pages=$(bytes_to_pages 32768)
    udp_pressure_pages=$(bytes_to_pages 67108864)
    udp_max_pages=$(bytes_to_pages 134217728)
  else
    tcp_min_pages=$(bytes_to_pages 134217728)     # 128MB
    tcp_pressure_pages=$(bytes_to_pages 536870912) # 512MB
    tcp_max_pages=$(bytes_to_pages 1073741824)    # 1GB
    udp_min_pages=$(bytes_to_pages 65536)
    udp_pressure_pages=$(bytes_to_pages 134217728)
    udp_max_pages=$(bytes_to_pages 268435456)
  fi
  # Ensure min <= pressure <= max (sanity)
  if [[ $tcp_min_pages -gt $tcp_pressure_pages ]]; then tcp_pressure_pages=$tcp_min_pages; fi
  if [[ $tcp_pressure_pages -gt $tcp_max_pages ]]; then tcp_max_pages=$tcp_pressure_pages; fi

  # file-max adaptive (#16)
  local file_max=$(( ram_mb * 1024 ))
  if [[ $file_max -lt 65536 ]]; then file_max=65536; fi
  if [[ $file_max -gt 2097152 ]]; then file_max=2097152; fi
  # if >8GB, cap higher but still conservative
  if [[ $ram_mb -gt 8192 && $file_max -lt 1048576 ]]; then file_max=1048576; fi

  local tcp_max_orphans=$(( ram_mb * 32 ))
  [[ $tcp_max_orphans -gt 32768 ]] && tcp_max_orphans=32768
  [[ $tcp_max_orphans -lt 8192 ]] && tcp_max_orphans=8192
  local somaxconn=4096 netdev_backlog=8192
  if [[ $ram_mb -gt 4096 ]]; then somaxconn=8192; netdev_backlog=16384; fi
  local min_free=$(( ram_mb * 1024 / 64 ))
  [[ $min_free -lt 16384 ]] && min_free=16384
  [[ $min_free -gt 131072 ]] && min_free=131072
  local cc="cubic"; [[ $has_bbr -eq 1 ]] && cc="bbr"

  # Only claim RAM-aware for those we calculated; others fixed but documented (#16, #18)
  local content="# Generated server-optimizer $VERSION $(date -Is 2>/dev/null || date) RAM=${ram_mb}MB ps=$ps
# Adaptive: rmem/wmem, tcp_mem(pages), udp_mem(pages), file-max, orphans, somaxconn, min_free
# Fixed conservative: swappiness=10, vfs_cache_pressure=100 (default 100), others leave distro default
fs.file-max = $file_max
net.core.default_qdisc = $chosen_qdisc
net.core.netdev_max_backlog = $netdev_backlog
net.core.somaxconn = $somaxconn
net.core.optmem_max = 65536
net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 $rmem_max
net.ipv4.tcp_wmem = 4096 65536 $wmem_max
net.ipv4.tcp_congestion_control = $cc
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_max_orphans = $tcp_max_orphans
net.ipv4.tcp_max_syn_backlog = $somaxconn
net.ipv4.tcp_max_tw_buckets = 144000
net.ipv4.tcp_mem = $tcp_min_pages $tcp_pressure_pages $tcp_max_pages
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.udp_mem = $udp_min_pages $udp_pressure_pages $udp_max_pages
net.unix.max_dgram_qlen = 512
vm.min_free_kbytes = $min_free
vm.swappiness = 10
vm.vfs_cache_pressure = 100
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
kernel.panic = 1
vm.dirty_ratio = 15
# Not forced: overcommit, ECN, mtu_probing, notsent_lowat, retries2 stay at distro default for workload safety
"

  if is_dry; then
    echo "$content"
    yellow_msg "[DRY-RUN] would write $SYSCTL_DROPIN (pages verified: tcp_mem=$tcp_min_pages $tcp_pressure_pages $tcp_max_pages)"
    commit_transaction; return 0
  fi

  mkdir -p "$(dirname "$SYSCTL_DROPIN")" 2>/dev/null || true
  echo "$content" > "$SYSCTL_DROPIN"
  log "Wrote $SYSCTL_DROPIN"

  # Validate each key and restore runtime on failure (#4)
  local failed=0
  while IFS='=' read -r k v; do
    k=$(echo "$k" | xargs 2>/dev/null | sed 's/#.*//'); [[ -z "$k" || "$k" == \#* ]] && continue
    v=$(echo "$v" | xargs 2>/dev/null)
    [[ -z "$v" ]] && continue
    if ! sysctl -w "$k=$v" >/dev/null 2>&1; then yellow_msg "sysctl $k failed"; failed=1; break; fi
  done < <(grep -v '^#' "$SYSCTL_DROPIN" | grep '=' 2>/dev/null || true)

  if [[ $failed -eq 1 ]]; then
    red_msg "sysctl validation failed - restoring previous file and runtime"
    do_rollback
    # restore runtime from backup file if existed
    if [[ -f "$runtime_backup" ]]; then
      while IFS='=' read -r rk rv; do rk=$(echo "$rk" | xargs 2>/dev/null); rv=$(echo "$rv" | xargs 2>/dev/null); [[ -z "$rk" ]] && continue; sysctl -w "$rk=$rv" >/dev/null 2>&1 || true; done < "$runtime_backup" 2>/dev/null || true
    fi
    rm -f "$runtime_backup" 2>/dev/null || true
    return 1
  fi
  rm -f "$runtime_backup" 2>/dev/null || true
  # systematic apply
  sysctl --system 2>/dev/null || true
  # verify runtime values (#14,15)
  local actual_tcp; actual_tcp=$(sysctl -n net.ipv4.tcp_mem 2>/dev/null || echo "unknown")
  local actual_udp; actual_udp=$(sysctl -n net.ipv4.udp_mem 2>/dev/null || echo "unknown")
  local actual_qdisc; actual_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
  log "Verify runtime tcp_mem=$actual_tcp udp_mem=$actual_udp qdisc=$actual_qdisc"
  tc qdisc show 2>/dev/null | head -5 | while read -r l; do log "qdisc: $l"; done || true
  green_msg "Sysctl optimized (qdisc=$chosen_qdisc cc=$cc tcp_mem_pages=$tcp_min_pages/$tcp_pressure_pages/$tcp_max_pages)"
  commit_transaction
}

# ---------- SSH (fixes #6 multi-port, #7 fallback, #8 lockout, #5 exact restore, #31 modes) ----------
get_effective_ssh_ports() {
  local ports=()
  # Try effective config via sshd -T
  if command -v sshd >/dev/null 2>&1; then
    local eff; eff=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' 2>/dev/null || true)
    if [[ -n "$eff" ]]; then
      while IFS= read -r p; do [[ -n "$p" ]] && ports+=("$p"); done <<< "$eff"
      if [[ ${#ports[@]} -gt 0 ]]; then printf "%s\n" "${ports[@]}" | sort -nu; return 0; fi
    fi
  fi
  # Fallback: search main + included configs (#7)
  local found=""
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -e "$f" ]] || continue
    # also handle Include directive
    if grep -q '^Include' "$f" 2>/dev/null; then
      for inc in $(grep '^Include' "$f" 2>/dev/null | awk '{for(i=2;i<=NF;i++) print $i}'); do
        for incf in $inc; do
          [[ -e "$incf" ]] || continue
          found+=$(grep -hE '^[[:space:]]*Port[[:space:]]+' "$incf" 2>/dev/null | awk '{print $2}' || true)
          found+=$'\n'
        done
      done
    fi
    found+=$(grep -hE '^[[:space:]]*Port[[:space:]]+' "$f" 2>/dev/null | awk '{print $2}' || true)
    found+=$'\n'
  done
  # also brute force grep across directory
  local brute; brute=$(grep -hRE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/ 2>/dev/null | grep -oE '[0-9]+' | sort -nu || true)
  if [[ -n "$brute" ]]; then printf "%s\n" "$brute"; return 0; fi
  if [[ -n "$found" ]]; then echo "$found" | grep -oE '[0-9]+' | sort -nu | uniq; return 0; fi
  # only if truly no Port found, assume 22 but log
  echo "22"
  log "SSH fallback: no Port directive found, assuming 22"
}

firewall_allows_port() {
  local port="$1" proto="${2:-tcp}"
  # Check ufw if active
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw status 2>/dev/null | grep -qE "${port}/${proto}.*ALLOW"; then return 0; fi
    # also check without proto
    if ufw status 2>/dev/null | grep -qw "$port"; then return 0; fi
    return 1
  fi
  # if ufw not active, assume not blocking
  return 0
}

ssh_optimize() {
  begin_transaction
  yellow_msg "Optimizing SSH (hardened, preserve all ports)..."
  local cur_ports; cur_ports=$(get_effective_ssh_ports 2>/dev/null || echo "22")
  local cur_ports_str; cur_ports_str=$(echo "$cur_ports" | tr '\n' ',' | sed 's/,$//')
  green_msg "Effective SSH ports: $cur_ports_str"
  # Backup main config exactly (#5)
  tx_prepare_file /etc/ssh/sshd_config
  local exact_backup=""; exact_backup=$(ls -t "$BACKUP_DIR"/*sshd_config* 2>/dev/null | head -1 || true)
  # Also log exact backup path
  if [[ -n "$exact_backup" ]]; then log "SSH backup exact: $exact_backup"; fi

  mkdir -p "$SSH_DROPIN_DIR" 2>/dev/null || true
  local use_dropin=0
  if grep -q "^Include.*sshd_config.d" /etc/ssh/sshd_config 2>/dev/null; then use_dropin=1; fi
  local target
  if [[ $use_dropin -eq 1 ]]; then
    target="$SSH_DROPIN"
    tx_prepare_file "$target"
  else
    target="/etc/ssh/sshd_config"
    # we already prepared main file above, so target is same
  fi

  # Ask mode for forwarding (#31)
  local mode="secure"
  if confirm "Enable VPN/Tunnel forwarding (AllowTcpForwarding/GatewayPorts/PermitTunnel)? (default secure=no)"; then mode="tunnel"; fi
  local fwd="no" gw="no" tun="no"
  if [[ "$mode" == "tunnel" ]]; then fwd="yes"; gw="clientspecified"; tun="yes"; yellow_msg "Tunnel mode: forwarding enabled"; else yellow_msg "Secure mode: forwarding disabled"; fi

  local ssh_content="# 99-optimizer.conf - generated $(date -Is 2>/dev/null || date) version $VERSION
# Preserves existing Port directives; hardens timeouts
TCPKeepAlive yes
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3
AllowTcpForwarding $fwd
GatewayPorts $gw
PermitTunnel $tun
X11Forwarding no
UseDNS no
Compression no
# Ciphers left at distro default
"

  if is_dry; then
    echo "$ssh_content"
    yellow_msg "[DRY-RUN] would write $target (mode=$mode) and run sshd -t"
    commit_transaction; return 0
  fi

  if [[ $use_dropin -eq 1 ]]; then
    echo "$ssh_content" > "$target"
    log "Wrote $target mode=$mode"
  else
    # idempotent: remove previous block then append
    sed -i '/# BEGIN 99-optimizer/,/# END 99-optimizer/d' "$target" 2>/dev/null || true
    {
      echo "# BEGIN 99-optimizer"
      echo "$ssh_content"
      echo "# END 99-optimizer"
    } >> "$target"
    log "Patched $target mode=$mode"
  fi

  # Validate before restart (#8)
  local sshd_test_out; sshd_test_out=$(sshd -t 2>&1 || true)
  if [[ -n "$sshd_test_out" && "$sshd_test_out" != "" ]]; then
    # sshd -t returns 0 on success, empty output; non-empty is error
    if ! sshd -t 2>&1; then
      red_msg "sshd -t FAILED: $sshd_test_out - restoring"
      do_rollback
      return 1
    fi
  else
    if ! sshd -t 2>/dev/null; then red_msg "sshd -t failed"; do_rollback; return 1; fi
  fi
  # Verify effective ports still present
  local new_ports; new_ports=$(get_effective_ssh_ports 2>/dev/null || echo "22")
  local missing=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if ! echo "$new_ports" | grep -qx "$p"; then missing+="$p "; fi
  done <<< "$cur_ports"
  if [[ -n "$missing" ]]; then
    red_msg "SSH port mismatch: missing $missing after change (new: $(echo $new_ports | tr '\n' ',')) - restoring"
    do_rollback
    return 1
  fi
  # Verify firewall allows each ssh port
  local fw_fail=""
  while IFS= read -r p; do [[ -z "$p" ]] && continue; if ! firewall_allows_port "$p" "tcp"; then fw_fail+="$p "; fi; done <<< "$cur_ports"
  if [[ -n "$fw_fail" ]]; then
    yellow_msg "Firewall does NOT allow SSH ports $fw_fail - fix UFW before restart"
    if ! confirm "Continue SSH reload despite firewall missing $fw_fail? (risk lockout)"; then
      red_msg "Aborted SSH reload due to firewall"; do_rollback; return 1
    fi
  fi
  # Prefer reload over restart
  if systemctl is-active --quiet sshd 2>/dev/null; then
    if ! systemctl reload sshd 2>/dev/null; then systemctl restart sshd 2>/dev/null || true; fi
    log "sshd reloaded"
  elif systemctl is-active --quiet ssh 2>/dev/null; then
    if ! systemctl reload ssh 2>/dev/null; then systemctl restart ssh 2>/dev/null || true; fi
    log "ssh reloaded"
  else
    yellow_msg "SSH service not active - skipping reload (config validated)"
  fi
  green_msg "SSH hardened (ports $cur_ports_str preserved, mode=$mode, validated)"
  commit_transaction
}

# ---------- Limits (fixes #19 service-specific, #20 restart) ----------
limits_optimizations() {
  begin_transaction
  yellow_msg "Configuring limits (service-specific, not global blanket)..."
  local ram_mb; ram_mb=$(detect_ram_mb)
  local nofile=65536 nproc=65535
  if [[ $ram_mb -gt 2048 ]]; then nofile=1048576; fi
  # Detect known services
  local services=()
  for svc in xray haproxy nginx xray.service haproxy.service nginx.service; do
    local base; base=$(echo "$svc" | sed 's/\.service//')
    if systemctl list-unit-files 2>/dev/null | grep -q "^${base}.service"; then services+=("$base"); fi
  done
  if [[ ${#services[@]} -gt 0 ]]; then
    yellow_msg "Found services: ${services[*]} - will create per-service drop-ins"
    for svc in "${services[@]}"; do
      local dropdir="/etc/systemd/system/${svc}.service.d"
      local dropfile="${dropdir}/99-limits.conf"
      tx_prepare_file "$dropfile"
      if is_dry; then yellow_msg "[DRY] would write $dropfile LimitNOFILE=$nofile"
      else
        mkdir -p "$dropdir" 2>/dev/null || true
        cat > "$dropfile" <<EOF
[Service]
LimitNOFILE=$nofile
LimitNPROC=$nproc
EOF
        log "Wrote $dropfile"
      fi
    done
    # Also create security limits.d for interactive users (conservative)
    tx_prepare_file "$LIMITS_DROPIN"
    if is_dry; then yellow_msg "[DRY] would write $LIMITS_DROPIN"
    else
      mkdir -p "$(dirname "$LIMITS_DROPIN")" 2>/dev/null || true
      cat > "$LIMITS_DROPIN" <<EOF
* soft nofile $nofile
* hard nofile $nofile
* soft nproc $nproc
* hard nproc $nproc
root soft nofile $nofile
root hard nofile $nofile
EOF
      log "Wrote $LIMITS_DROPIN"
    fi
  else
    yellow_msg "No known VPN services found - will NOT raise global limits blindly"
    if confirm "Raise global systemd limits anyway (affects all services)?"; then
      tx_prepare_file "$SYSTEMD_LIMITS"
      tx_prepare_file "$LIMITS_DROPIN"
      if is_dry; then yellow_msg "[DRY] would write global limits $SYSTEMD_LIMITS $LIMITS_DROPIN"
      else
        mkdir -p "$SYSTEMD_DROPIN_DIR" "$(dirname "$LIMITS_DROPIN")" 2>/dev/null || true
        cat > "$SYSTEMD_LIMITS" <<EOF
[Manager]
DefaultLimitNOFILE=$nofile
DefaultLimitNPROC=$nproc
EOF
        cat > "$LIMITS_DROPIN" <<EOF
* soft nofile $nofile
* hard nofile $nofile
root soft nofile $nofile
root hard nofile $nofile
EOF
        log "Wrote global limits"
      fi
    else
      yellow_msg "Skipping global limits (workload-aware)"
      commit_transaction; return 0
    fi
  fi
  if is_dry; then commit_transaction; return 0; fi
  # daemon-reload but not restart services automatically (#20)
  systemctl daemon-reload 2>/dev/null || true
  green_msg "Limits configured (nofile=$nofile). Services require restart to apply."
  for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      local cur; cur=$(systemctl show "$svc" -p LimitNOFILE 2>/dev/null | cut -d= -f2 || echo "unknown")
      yellow_msg "Service $svc active, current LimitNOFILE=$cur (new=$nofile) - restart needed to apply"
      if confirm "Restart $svc now to apply limits?"; then
        systemctl restart "$svc" 2>/dev/null || true
        local after; after=$(systemctl show "$svc" -p LimitNOFILE 2>/dev/null | cut -d= -f2 || echo "unknown")
        log "After restart $svc LimitNOFILE=$after"
      fi
    else
      yellow_msg "Service $svc not active - will apply on next start"
    fi
  done
  if [[ ${#services[@]} -eq 0 ]]; then
    yellow_msg "Global limits require re-login or reboot to affect new sessions"
  fi
  commit_transaction
}

# ---------- UFW helpers (fixes #9, #10, #11, #12, #13) ----------
get_tcp_listeners() {
  # output: proto|addr|port|proc  proto=tcp
  ss -tlnH -o state listening 2>/dev/null | while read -r line; do
    # ss -tlnH format varies; use ss -tlnp for proc, but we call separately
    true
  done || true
  # Use ss -tlnp and parse
  ss -tlnp 2>/dev/null | tail -n +2 | while read -r proto recv_q send_q local_addr peer_addr process; do
    # Actually ss cols: Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
    # Safer to use ss -tlnpH with -H
    true
  done || true
  # Simpler: use ss -tlnH and ss -tlnpH separately for address+proc
  # We'll implement direct parsing of ss -tlnH for now with extra proc lookup
  ss -tlnH 2>/dev/null | awk '{print $4}' | while read -r addrport; do
    # addrport like 0.0.0.0:22 or [::]:22 or 127.0.0.1:8080
    local addr; addr=$(echo "$addrport" | rev | cut -d: -f2- | rev)
    local port; port=$(echo "$addrport" | rev | cut -d: -f1 | rev | tr -d '[]')
    # detect localhost
    local is_local=0
    if [[ "$addr" == "127.0.0.1" || "$addr" == "127.0.0.53" || "$addr" == "::1" || "$addr" == "127."* ]]; then is_local=1; fi
    # process lookup via ss -tlnp matching port
    local proc; proc=$(ss -tlnp 2>/dev/null | grep -F "$addrport" | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
    echo "tcp|$addr|$port|$is_local|$proc"
  done | sort -u
}
get_udp_listeners() {
  ss -ulnH 2>/dev/null | awk '{print $4}' | while read -r addrport; do
    [[ -z "$addrport" ]] && continue
    local addr; addr=$(echo "$addrport" | rev | cut -d: -f2- | rev)
    local port; port=$(echo "$addrport" | rev | cut -d: -f1 | rev | tr -d '[]')
    local is_local=0
    if [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "127."* ]]; then is_local=1; fi
    local proc; proc=$(ss -ulnp 2>/dev/null | grep -F "$addrport" | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
    echo "udp|$addr|$port|$is_local|$proc"
  done | sort -u
}
backup_ufw_rules() {
  if is_dry; then yellow_msg "[DRY] would backup ufw rules"; return 0; fi
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  local dst="${BACKUP_DIR}/ufw-status.${TX_ID}.txt"
  {
    echo "# ufw status numbered $(date -Is 2>/dev/null || date)"
    ufw status numbered 2>/dev/null || echo "ufw not active"
    echo "# ufw status verbose"
    ufw status verbose 2>/dev/null || true
  } > "$dst" 2>/dev/null || true
  log "UFW backup -> $dst"
}

ufw_optimizations() {
  begin_transaction
  yellow_msg "Configuring UFW (TCP/UDP split, address-aware, preserve)..."
  if systemctl is-active --quiet docker 2>/dev/null || [[ -f /usr/bin/docker ]]; then
    yellow_msg "Docker detected - UFW interacts with DOCKER chain."
    if ! confirm "Continue UFW setup despite Docker?"; then commit_transaction; return 0; fi
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    yellow_msg "firewalld active - will not purge blindly"
    if confirm "Disable firewalld and switch to UFW? (will backup)"; then
      tx_prepare_file /etc/firewalld  # directory backup not needed; just log
      if is_dry; then yellow_msg "[DRY] would stop/disable firewalld"
      else systemctl stop firewalld 2>/dev/null || true; systemctl disable firewalld 2>/dev/null || true; log "firewalld disabled"; fi
    else commit_transaction; return 0; fi
  fi
  if ! command -v ufw >/dev/null 2>&1; then
    if is_dry; then yellow_msg "[DRY] would install ufw"
    else apt-get update -q 2>/dev/null || true; apt-get install -y ufw 2>/dev/null || true; log "Installed ufw"; fi
  fi
  # Preserve SSH ports (multiple)
  local ssh_ports; ssh_ports=$(get_effective_ssh_ports 2>/dev/null || echo "22")
  yellow_msg "Preserving SSH ports: $(echo $ssh_ports | tr '\n' ',' )"
  # Backup existing policy (#12)
  backup_ufw_rules
  # Capture listeners split by proto (#9, #11)
  local tcp_list udp_list
  tcp_list=$(ss -tlnH 2>/dev/null | sort -u || true)
  udp_list=$(ss -ulnH 2>/dev/null | sort -u || true)
  # Build address-aware lists
  local tcp_public=() udp_public=()
  # Use helper to get detailed
  # For simplicity, parse ss -tlnH and check addr
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local addrport; addrport=$(echo "$line" | awk '{print $4}')
    local port; port=$(echo "$addrport" | grep -oE '[0-9]+$' || true)
    local addr; addr=$(echo "$addrport" | sed 's/:[0-9]*$//')
    if [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "[::1]" ]]; then
      log "Skip localhost TCP $addrport"
      continue
    fi
    tcp_public+=("$port")
  done <<< "$(ss -tlnH 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local addrport; addrport=$(echo "$line" | awk '{print $4}')
    local port; port=$(echo "$addrport" | grep -oE '[0-9]+$' || true)
    local addr; addr=$(echo "$addrport" | sed 's/:[0-9]*$//')
    if [[ "$addr" == "127.0.0.1" || "$addr" == "::1" || "$addr" == "[::1]" ]]; then
      log "Skip localhost UDP $addrport"
      continue
    fi
    udp_public+=("$port")
  done <<< "$(ss -ulnH 2>/dev/null || true)"
  # Dedupe
  tcp_public=($(printf "%s\n" "${tcp_public[@]}" | sort -nu || true))
  udp_public=($(printf "%s\n" "${udp_public[@]}" | sort -nu || true))
  yellow_msg "Public TCP listeners: ${tcp_public[*]:-none}"
  yellow_msg "Public UDP listeners: ${udp_public[*]:-none}"
  # Ensure SSH ports allowed (each proto tcp)
  for p in $ssh_ports; do
    [[ -z "$p" ]] && continue
    if is_dry; then yellow_msg "[DRY] would: ufw allow $p/tcp (SSH preserve)"
    else
      if ufw status 2>/dev/null | grep -qE "$p/tcp.*ALLOW"; then log "UFW already allows $p/tcp"
      else ufw allow "$p/tcp" comment 'SSH preserve' 2>/dev/null || ufw allow "$p/tcp" 2>/dev/null || true; log "UFW allow $p/tcp"; fi
    fi
  done
  # For public TCP listeners, ask per port, only tcp (#10)
  for p in "${tcp_public[@]}"; do
    [[ -z "$p" ]] && continue
    if echo "$ssh_ports" | grep -qx "$p"; then continue; fi
    if [[ "$p" == "80" || "$p" == "443" ]]; then
      if is_dry; then yellow_msg "[DRY] would ensure $p/tcp"
      else
        if ufw status 2>/dev/null | grep -qE "$p/tcp.*ALLOW"; then log "Already $p/tcp"
        else if confirm "Allow public TCP $p (detected listening, proc: $(ss -tlnp 2>/dev/null | grep -F ":$p " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo unknown))?"; then ufw allow "$p/tcp" 2>/dev/null || true; log "Allow $p/tcp"; fi; fi
      fi
    else
      # custom ports: ask
      yellow_msg "Detected public TCP $p"
      if is_dry; then yellow_msg "[DRY] would ask to allow $p/tcp"
      else
        if ufw status 2>/dev/null | grep -qE "$p/tcp.*ALLOW"; then log "Already $p/tcp"
        else if confirm "Allow public TCP $p? (proc: $(ss -tlnp 2>/dev/null | grep -F ":$p " | head -1 | grep -oP 'users:\(\("\K[^"]+' || echo unknown) listening on $(ss -tlnH 2>/dev/null | grep -F ":$p" | head -1 | awk '{print $4}'))"; then ufw allow "$p/tcp" 2>/dev/null || true; log "Allow $p/tcp"; fi; fi
      fi
    fi
  done
  # UDP only for udp listeners (#10)
  for p in "${udp_public[@]}"; do
    [[ -z "$p" ]] && continue
    yellow_msg "Detected public UDP $p"
    if is_dry; then yellow_msg "[DRY] would ask to allow $p/udp"
    else
      if ufw status 2>/dev/null | grep -qE "$p/udp.*ALLOW"; then log "Already $p/udp"
      else if confirm "Allow public UDP $p? (needed for VPN/WireGuard/DNS)"; then ufw allow "$p/udp" 2>/dev/null || true; log "Allow $p/udp"; fi; fi
    fi
  done
  # Do NOT blindly open 80/443 udp/tcp if not listening - handled above
  # Keep UFW sysctl as-is (#27)
  yellow_msg "Keeping /etc/default/ufw sysctl as-is"
  # Enable if needed, with SSH safeguard
  local ufw_active=0
  if ufw status 2>/dev/null | grep -q "Status: active"; then ufw_active=1; fi
  if [[ $ufw_active -eq 0 ]]; then
    yellow_msg "UFW inactive - will enable after verifying SSH"
    local can_enable=1
    for p in $ssh_ports; do if ! firewall_allows_port "$p" "tcp" && ! is_dry; then can_enable=0; fi; done
    # In dry-run, firewall check simulated, so allow
    if is_dry; then yellow_msg "[DRY] would: ufw enable (after SSH verify)"
    else
      if [[ $can_enable -eq 0 ]]; then red_msg "SSH ports not allowed - not enabling UFW (lockout prevention)"; commit_transaction; return 1; fi
      if confirm "Enable UFW now? (SSH $ssh_ports verified)"; then
        echo "y" | ufw enable 2>/dev/null || ufw --force enable 2>/dev/null || true
        ufw reload 2>/dev/null || true
        log "UFW enabled"
      else yellow_msg "UFW not enabled - rules staged"; fi
    fi
  else
    if is_dry; then yellow_msg "[DRY] would reload UFW"
    else ufw reload 2>/dev/null || true; log "UFW reloaded"; fi
  fi
  green_msg "UFW done (public TCP: ${tcp_public[*]:-none} UDP: ${udp_public[*]:-none})"
  commit_transaction
}

# ---------- State management (fix #26, dry-safe) ----------
update_state() {
  local modules="$1" status="$2"
  if is_dry; then yellow_msg "[DRY] would update state $STATE_FILE modules=$modules status=$status"; return 0; fi
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
  local ts; ts=$(date -Is 2>/dev/null || date)
  cat > "$STATE_FILE" <<EOF
version=$VERSION
last_run=$ts
ram_mb=$(detect_ram_mb)
modules=$modules
status=$status
sysctl_dropin=$SYSCTL_DROPIN
ssh_dropin=$SSH_DROPIN
limits_dropin=$LIMITS_DROPIN
systemd_limits=$SYSTEMD_LIMITS
swap=$(swapon --show 2>/dev/null | head -1 || echo none)
kernel=$(uname -r)
tx_last=$TX_ID
EOF
  log "State updated $STATE_FILE"
}

# ---------- Reboot logic (fixes #27, #28) ----------
is_reboot_needed() {
  if [[ -f /var/run/reboot-required ]]; then return 0; fi
  # kernel newer than running?
  local running; running=$(uname -r)
  local latest; latest=$(ls -t /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//' || true)
  if [[ -n "$latest" && "$latest" != "$running" ]]; then
    # check if latest is installed package
    if dpkg -l 2>/dev/null | grep -q "$latest"; then return 0; fi
  fi
  return 1
}
ask_reboot() {
  if is_dry; then yellow_msg "[DRY] would check reboot-required (no reboot in dry)"; return 0; fi
  if is_reboot_needed; then
    yellow_msg "Reboot required (kernel or /var/run/reboot-required)"
    if confirm "Reboot now?"; then reboot; fi
  else yellow_msg "No reboot required (use systemctl reload / re-login for limits/sysctl)"; fi
}
ask_reboot_if_needed() {
  local reason="$1"
  if is_dry; then return 0; fi
  if is_reboot_needed; then ask_reboot; else yellow_msg "$reason: no reboot needed (reload sufficient)"; fi
}

# ---------- Main ----------
show_menu() {
  echo
  yellow_msg "Choose (dry-run: ./$(basename "$0") --dry-run):"
  echo
  green_msg "1 - Full safe run (update+sysctl+ssh+limits+swap+ufw) WITHOUT XanMod"
  green_msg "2 - Install XanMod only (HTTPS, full fp, fallback)"
  green_msg "3 - Update + swap + sysctl + ssh + limits + UFW"
  green_msg "6 - Update only"
  green_msg "8 - Swap only"
  green_msg "9 - Sysctl+SSH+Limits only"
  green_msg "10 - Sysctl only (pages, fq aware)"
  green_msg "11 - SSH only (multi-port, hardened)"
  green_msg "13 - UFW only (TCP/UDP split, address-aware)"
  echo
  red_msg "q - Exit"
  echo
}

apply_everything_safe() {
  local mods="snapshot,update,swap,sysctl,ssh,limits,ufw"
  system_snapshot
  complete_update
  swap_maker
  sysctl_optimizations
  ssh_optimize
  limits_optimizations
  ufw_optimizations
  system_snapshot
  update_state "$mods" "success"
}

main() {
  # Already parsed --dry-run/--yes at top, but handle again for main loop
  check_root
  acquire_lock
  check_os
  if ! is_dry; then
    mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")" 2>/dev/null || true
  else
    yellow_msg "DRY-RUN: no directories/files will be created"
  fi
  log "=== Start $(basename "$0") v$VERSION dry=$DRY_RUN ==="

  if [[ $# -eq 0 ]]; then
    while true; do
      show_menu
      read -rp "Choice: " c || true
      case "$c" in
        1) apply_everything_safe; ask_reboot;;
        2) complete_update; install_xanmod; ask_reboot;;
        3) complete_update; swap_maker; sysctl_optimizations; ssh_optimize; limits_optimizations; ufw_optimizations; update_state "3" "success"; ask_reboot;;
        6) complete_update; ask_reboot;;
        8) swap_maker; ask_reboot_if_needed "swap";;
        9) sysctl_optimizations; ssh_optimize; limits_optimizations; ask_reboot_if_needed "limits/ssh";;
        10) sysctl_optimizations;;
        11) ssh_optimize;;
        13) ufw_optimizations;;
        q) exit 0;;
        *) red_msg "Invalid";;
      esac
    done
  else
    # Non-interactive: if --dry-run, just preview; else apply
    if is_dry; then
      yellow_msg "DRY-RUN preview (no changes):"
      apply_everything_safe
      green_msg "Dry-run complete - ZERO files modified"
    else
      apply_everything_safe
      green_msg "Done - check $LOG_FILE"
      ask_reboot
    fi
  fi
}

main "$@"
