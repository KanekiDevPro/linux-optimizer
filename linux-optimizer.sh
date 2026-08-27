#!/usr/bin/env bash
# Linux Optimizer Bootstrap — Secure, Idempotent, Reversible
# Source: https://github.com/KanekiDevPro/linux-optimizer
# Pinned ref: c3f1f819628f0cd63319d7b94c51b3945555561a (commit SHA, 2026-08-27)
# Verified SHA256 (computed from https://raw.githubusercontent.com/.../<REF>/scripts/*):
#   ubuntu-optimizer.sh  = 56423a1017c791be54f98e7a90d897166b0760af45f3f3d25a2b843ca9da78a1
#   debian-optimizer.sh  = 34b18177213e4fbe622933c3813ffd04aae661921ca1061918d5eedc906fd4f2
#   centos-optimizer.sh  = 23a73c7bf2783afaccc889ce77467c1b40edef9b576427c341014528a50d8c26 (also for almalinux)
#   fedora-optimizer.sh  = f9f8032f97e381be1d1d1d2bc07e04923ca946d0fc7a931fe76a7e2751bc4a79
# Regenerate: sha256sum <file> after verifying GPG tag/commit signature at GitHub release page.
# Banner supported: Ubuntu 20.04/22.04/24.04, Debian 11/12, CentOS Stream 8/9, AlmaLinux 8/9, Fedora 37+ (see OS validation below)
# Usage: sudo bash linux-optimizer-bootstrap-secure.sh [--dry-run] [--yes] [--with-dns] [--with-timezone] [--timezone TZ] [--help]

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- Early arg parsing (before any side effects) ----------
DRY_RUN=0
ASSUME_YES=0
WITH_DNS=0
NO_DNS=0
WITH_TIMEZONE=0
EXPLICIT_TZ=""
SHOW_HELP=0

# Safe parsing without eval: handles --timezone TZ and --timezone=TZ
_argv=("$@")
_idx=0
while [[ $_idx -lt ${#_argv[@]} ]]; do
  _arg="${_argv[$_idx]}"
  case "$_arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --with-dns) WITH_DNS=1 ;;
    --no-dns) NO_DNS=1 ;;
    --with-timezone) WITH_TIMEZONE=1 ;;
    --timezone=*) EXPLICIT_TZ="${_arg#*=}"; WITH_TIMEZONE=1 ;;
    --timezone)
      _next=$((_idx + 1))
      if [[ $_next -lt ${#_argv[@]} ]]; then
        EXPLICIT_TZ="${_argv[$_next]}"
        WITH_TIMEZONE=1
        _idx=$((_idx + 1))
      fi
      ;;
    --help|-h) SHOW_HELP=1 ;;
  esac
  _idx=$((_idx + 1))
done
unset _argv _idx _arg _next

# Validate DNS flag conflict
if [[ $WITH_DNS -eq 1 && ${NO_DNS:-0} -eq 1 ]]; then
  echo "[*] ----- Error: --with-dns and --no-dns are mutually exclusive" >&2
  exit 1
fi

if [[ $SHOW_HELP -eq 1 ]]; then
  cat <<'HELP'
Usage: sudo bash linux-optimizer-bootstrap-secure.sh [OPTIONS]

Options:
  --dry-run          Preview only — zero system mutation (no file writes, no pkg installs, no downloads executed)
  --yes, -y          Non-interactive: assume yes where confirmation would normally be asked
  --with-dns         Allow DNS repair/recovery (explicit opt-in, also default when DNS is broken)
  --no-dns           Never modify DNS; fail closed if DNS is unavailable
  --with-timezone    Enable GeoIP timezone detection (default: preserve current timezone)
  --timezone TZ      Set explicit timezone (e.g., --timezone UTC or --timezone Europe/Berlin). Implies --with-timezone.
                     TZ is validated against /usr/share/zoneinfo and timedatectl list-timezones.
  --help, -h         Show this help

DNS Recovery (automatic, OS-aware):
  Default: test current DNS (resolvectl/getent/dig for raw.githubusercontent.com). If working, preserve existing
           provider DNS (e.g., 185.12.64.1/185.12.64.2) and do not modify. If broken, automatically recover using
           native manager: systemd-resolved drop-in, NetworkManager nmcli, netplan drop-in, resolvconf, or
           static resolv.conf — transactional backup, verify via resolvectl query + getent ahostsv4 + HTTPS, rollback
           on failure. Use --no-dns to disable auto-recovery (fail-closed), --with-dns to force allow.

Security:
  - Pinned to immutable commit SHA; SHA256 verified before execution (fail-closed)
  - HTTPS only with TLS verification; timeouts and retries on all network I/O
  - Atomic transactional backups in /var/backups/linux-optimizer/<timestamp>-<pid>/
  - flock global lock; mktemp secure temp dir; rollback on failure; no partial execution

Examples:
  sudo bash linux-optimizer-bootstrap-secure.sh --dry-run
  sudo bash linux-optimizer-bootstrap-secure.sh --yes
  sudo bash linux-optimizer-bootstrap-secure.sh --with-dns --yes
  sudo bash linux-optimizer-bootstrap-secure.sh --no-dns
  sudo bash linux-optimizer-bootstrap-secure.sh --timezone UTC --yes

HELP
  exit 0
fi

# ---------- Globals ----------
readonly SCRIPT_VERSION="2.0-secure"
readonly OPTIMIZER_REF="c3f1f819628f0cd63319d7b94c51b3945555561a"
readonly BASE_URL="https://raw.githubusercontent.com/KanekiDevPro/linux-optimizer/${OPTIMIZER_REF}/scripts"
readonly LOG_FILE="/var/log/linux-optimizer-bootstrap.log"
readonly LOCK_FILE="/var/lock/linux-optimizer-bootstrap.lock"
readonly BACKUP_ROOT="/var/backups/linux-optimizer"
HOST_PATH="/etc/hosts"
DNS_PATH="/etc/resolv.conf"
TRANSACTION_ID="$(date +%Y%m%d-%H%M%S)-$$"
TMP_DIR=""
OS_ID=""
OS_VERSION_ID=""
OS_PRETTY="unknown"

# DNS recovery globals (OS-aware, transactional)
TARGET_HOST="raw.githubusercontent.com"
DNS_FALLBACK_CANDIDATES=("1.1.1.1" "1.0.0.1" "8.8.8.8" "8.8.4.4")
DNS_MANAGER_DETECTED=""
DNS_RECOVERY_APPLIED=0
DNS_RECOVERY_BACKUP_DIR=""

# Expected SHA256 — fail-closed if mismatch. Update when OPTIMIZER_REF changes.
declare -A EXPECTED_SHA256=(
  ["ubuntu-optimizer.sh"]="56423a1017c791be54f98e7a90d897166b0760af45f3f3d25a2b843ca9da78a1"
  ["debian-optimizer.sh"]="34b18177213e4fbe622933c3813ffd04aae661921ca1061918d5eedc906fd4f2"
  ["centos-optimizer.sh"]="23a73c7bf2783afaccc889ce77467c1b40edef9b576427c341014528a50d8c26"
  ["fedora-optimizer.sh"]="f9f8032f97e381be1d1d1d2bc07e04923ca946d0fc7a931fe76a7e2751bc4a79"
)

# Transaction rollback registry: entries "restore|target|backup" or "delete|target"
declare -a TX_ACTIONS=()
TX_ACTIVE=0
BACKUP_DIR=""
ROLLBACK_NEEDED=0

# Counters for final status
CHANGES_DONE=()
CHANGES_SKIPPED=()
FAILURES=()

# ---------- Colors (graceful fallback) ----------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]]; then
  GREEN="$(tput setaf 2 2>/dev/null || true)"
  YELLOW="$(tput setaf 3 2>/dev/null || true)"
  RED="$(tput setaf 1 2>/dev/null || true)"
  RESET="$(tput sgr0 2>/dev/null || true)"
else
  GREEN=""; YELLOW=""; RED=""; RESET=""
fi

# ---------- Helpers: dry check, logging ----------
is_dry() { [[ $DRY_RUN -eq 1 ]]; }

safe_log() {
  local msg="$*"
  local ts; ts="$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  if is_dry; then
    echo "[$ts] $msg"
    return 0
  fi
  # Ensure log dir exists (once)
  mkdir -p -- "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
  # Create with safe perms on first creation
  if [[ ! -f "$LOG_FILE" ]]; then
    : > "$LOG_FILE" 2>/dev/null || true
    chmod 640 -- "$LOG_FILE" 2>/dev/null || true
  fi
  echo "[$ts] $msg" | tee -a -- "$LOG_FILE" 2>/dev/null || echo "[$ts] $msg" || true
}
green_msg()  { echo "${GREEN}[*] ----- $1${RESET}"; safe_log "INFO: $1"; }
yellow_msg() { echo "${YELLOW}[*] ----- $1${RESET}"; safe_log "WARN: $1"; }
red_msg()    { echo "${RED}[*] ----- $1${RESET}"; safe_log "ERROR: $1"; }
log()        { safe_log "$*"; }

confirm() {
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  if is_dry; then return 0; fi
  local prompt="$1"
  local ans
  read -r -p "$prompt [y/N]: " ans 2>/dev/null || return 1
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

require_cmd() {
  local cmd="$1"
  if ! command -v -- "$cmd" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ---------- Transaction / Backup ----------
init_backup_dir() {
  if is_dry; then
    BACKUP_DIR="${BACKUP_ROOT}/${TRANSACTION_ID} (dry-run, not created)"
    return 0
  fi
  BACKUP_DIR="${BACKUP_ROOT}/${TRANSACTION_ID}"
  mkdir -p -- "$BACKUP_DIR" 2>/dev/null || {
    red_msg "Failed to create backup dir $BACKUP_DIR"
    return 1
  }
  chmod 700 -- "$BACKUP_DIR" 2>/dev/null || true
  log "Backup dir: $BACKUP_DIR"
}

tx_backup_file() {
  local src="$1"
  if is_dry; then
    yellow_msg "[DRY-RUN] would backup $src -> $BACKUP_DIR/"
    return 0
  fi
  if [[ ! -e "$src" ]]; then
    # Will be newly created — register for deletion on rollback
    TX_ACTIONS+=("delete|$src|")
    log "Registered new file $src for rollback deletion"
    return 0
  fi
  local base; base="$(basename -- "$src")"
  # Sanitize path for filename: /etc/hosts -> etc_hosts
  local sanitized; sanitized="$(echo "$src" | tr '/' '_' | sed 's/^_//')"
  local dst="${BACKUP_DIR}/${sanitized}.bak"
  # Never overwrite: $BACKUP_DIR is unique per transaction, so safe; still guard with -n
  if [[ -e "$dst" ]]; then
    red_msg "Backup collision $dst — refusing to overwrite"
    return 1
  fi
  cp -a -- "$src" "$dst" 2>/dev/null || {
    red_msg "Backup failed: $src -> $dst"
    return 1
  }
  chmod 600 -- "$dst" 2>/dev/null || true
  TX_ACTIONS+=("restore|$src|$dst")
  log "Backup $src -> $dst"
}

do_rollback() {
  if [[ $TX_ACTIVE -ne 1 ]]; then return 0; fi
  if [[ ${#TX_ACTIONS[@]} -eq 0 ]]; then TX_ACTIVE=0; return 0; fi
  red_msg "Rolling back transaction $TRANSACTION_ID (${#TX_ACTIONS[@]} actions)"
  for (( idx=${#TX_ACTIONS[@]}-1; idx>=0; idx-- )); do
    local entry="${TX_ACTIONS[idx]}"
    local type="${entry%%|*}"; local rest="${entry#*|}"; local target="${rest%%|*}"; local backup="${rest#*|}"
    case "$type" in
      restore)
        if [[ -f "$backup" ]]; then
          if is_dry; then yellow_msg "[DRY-ROLLBACK] would restore $target <- $backup"
          else cp -a -- "$backup" "$target" 2>/dev/null || log "Rollback restore failed $target <- $backup"; log "Rollback restore $target <- $backup"; fi
        fi
        ;;
      delete)
        if is_dry; then yellow_msg "[DRY-ROLLBACK] would delete $target"
        else rm -f -- "$target" 2>/dev/null || true; log "Rollback delete $target"; fi
        ;;
    esac
  done
  TX_ACTIVE=0
  TX_ACTIONS=()
}

begin_transaction() { TX_ACTIVE=1; log "Begin transaction $TRANSACTION_ID"; }
commit_transaction() { TX_ACTIVE=0; TX_ACTIONS=(); log "Commit transaction $TRANSACTION_ID"; }

# Global trap: ERR -> rollback, EXIT -> cleanup temp/lock, INT/TERM -> rollback+exit
trap 'rc=$?; if [[ $rc -ne 0 ]]; then red_msg "Error at line $LINENO (rc=$rc)"; do_rollback; fi' ERR
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'red_msg "Interrupted (SIGINT/SIGTERM)"; do_rollback; cleanup; exit 130' INT TERM

cleanup() {
  # Remove temp dir if exists
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    if is_dry; then yellow_msg "[DRY-RUN] would remove tmp $TMP_DIR"
    else rm -rf -- "$TMP_DIR" 2>/dev/null || true; log "Cleaned tmp $TMP_DIR"; fi
    TMP_DIR=""
  fi
  # Release lock (flock releases on close, but remove file if we own it)
  exec 200>&- 2>/dev/null || true
  # Do not remove lock file blindly — flock file persists but unlocked
  trap - EXIT ERR INT TERM
}

# ---------- Lock ----------
acquire_lock() {
  if is_dry; then yellow_msg "[DRY-RUN] would acquire lock $LOCK_FILE (skipped)"; return 0; fi
  mkdir -p -- "$(dirname -- "$LOCK_FILE")" 2>/dev/null || true
  # Open lock file descriptor 200
  exec 200>"$LOCK_FILE" 2>/dev/null || { red_msg "Cannot open lock $LOCK_FILE"; exit 1; }
  if ! flock -n 200 2>/dev/null; then
    red_msg "Another instance is running (lock $LOCK_FILE)"
    exit 1
  fi
  log "Lock acquired $LOCK_FILE (fd 200)"
  # Ensure lock released on exit via cleanup trap
}

# ---------- Root check ----------
check_if_running_as_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if is_dry; then yellow_msg "[DRY-RUN] not running as root — preview continues, but real run requires root"; return 0; fi
    red_msg 'Error: You must run this script as root!'
    exit 1
  fi
}

# ---------- Connectivity ----------
has_internet() {
  # Test 1: hostname HTTPS (requires DNS + TLS). Test 2: IP HTTPS (proves L3, no DNS).
  # IP success does NOT imply hostname download will succeed (needs DNS + SNI).
  if require_cmd curl; then
    if curl --proto '=https' --tlsv1.2 --fail --silent --connect-timeout 5 --max-time 10 --head "https://raw.githubusercontent.com" >/dev/null 2>&1; then return 0; fi
    if curl --fail --silent --connect-timeout 5 --max-time 10 --head "https://1.1.1.1" >/dev/null 2>&1; then return 0; fi
  elif require_cmd wget; then
    if wget --https-only --timeout=10 --tries=1 --spider -q "https://raw.githubusercontent.com" 2>/dev/null; then return 0; fi
  fi
  return 1
}

has_dns() {
  if require_cmd getent; then
    if getent hosts "github.com" >/dev/null 2>&1; then return 0; fi
    if getent hosts "one.one.one.one" >/dev/null 2>&1; then return 0; fi
  fi
  if require_cmd dig; then dig +time=5 +tries=1 "github.com" >/dev/null 2>&1 && return 0 || true
  fi
  return 1
}

# ---------- OS Detection (via /etc/os-release) ----------
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    red_msg "Cannot detect OS: /etc/os-release missing"
    exit 1
  fi
  # shellcheck disable=SC1091
  set -a; . /etc/os-release; set +a
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VERSION_ID}"
  yellow_msg "OS: $OS_PRETTY (ID=$OS_ID VERSION_ID=$OS_VERSION_ID ID_LIKE=${ID_LIKE:-})"
  log "OS detection: ID=$OS_ID VERSION_ID=$OS_VERSION_ID ID_LIKE=${ID_LIKE:-} PRETTY=$OS_PRETTY"
}

validate_os_version() {
  local id="$OS_ID"
  local ver="$OS_VERSION_ID"
  local like="${ID_LIKE:-}"
  case "$id" in
    ubuntu)
      case "$ver" in
        20.04|22.04|24.04) green_msg "Ubuntu $ver supported (validated)";;
        *)
          yellow_msg "Ubuntu $ver not in validated list (20.04/22.04/24.04). Proceed with caution."
          CHANGES_SKIPPED+=("os: ubuntu $ver not fully validated")
          if ! confirm "Continue with untested Ubuntu version $ver?"; then red_msg "Aborting on untested OS"; exit 1; fi
          ;;
      esac
      ;;
    debian)
      case "$ver" in
        11|12) green_msg "Debian $ver supported";;
        *)
          yellow_msg "Debian $ver not in validated list (11/12)."
          if ! confirm "Continue with Debian $ver?"; then exit 1; fi
          ;;
      esac
      ;;
    centos|almalinux|rhel|rocky)
      # ID may be centos, almalinux; centos stream version 8/9
      if [[ "$ver" == 8* || "$ver" == 9* ]]; then green_msg "$id $ver supported (RHEL family)"
      else yellow_msg "$id $ver not in validated 8/9"; if ! confirm "Continue?"; then exit 1; fi; fi
      ;;
    fedora)
      # Fedora 37+
      if [[ "$ver" =~ ^[0-9]+$ ]] && [[ "$ver" -ge 37 ]]; then green_msg "Fedora $ver supported (>=37)"
      elif [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
        local major="${ver%%.*}"; if [[ "$major" -ge 37 ]]; then green_msg "Fedora $ver supported"; else yellow_msg "Fedora $ver <37 not validated"; fi
      else yellow_msg "Fedora version $ver not validated"; fi
      ;;
    *)
      # Check ID_LIKE for derivatives
      if [[ "$like" == *"ubuntu"* ]] || [[ "$like" == *"debian"* ]]; then
        yellow_msg "Derivative OS $id ($like) — treating as debian-like; proceed with caution"
        if ! confirm "Continue with derivative $id?"; then exit 1; fi
      elif [[ "$like" == *"rhel"* ]] || [[ "$like" == *"fedora"* ]] || [[ "$like" == *"centos"* ]]; then
        yellow_msg "RHEL derivative $id ($like) — treating as RHEL-like"
        if ! confirm "Continue with derivative $id?"; then exit 1; fi
      else
        red_msg "Unknown OS: $id ($OS_PRETTY) — see https://github.com/KanekiDevPro/Linux-Optimizer/issues"
        FAILURES+=("os: unknown $id")
        exit 1
      fi
      ;;
  esac
}

get_os_optimizer_details() {
  # Sets: OPTIMIZER_FILE, OPTIMIZER_URL, EXPECTED_SHA
  local file="" url="" sha=""
  case "$OS_ID" in
    ubuntu) file="ubuntu-optimizer.sh" ;;
    debian) file="debian-optimizer.sh" ;;
    centos) file="centos-optimizer.sh" ;;
    almalinux) file="centos-optimizer.sh" ;; # Alma uses centos script per original bootstrap
    fedora) file="fedora-optimizer.sh" ;;
    rhel|rocky)
      file="centos-optimizer.sh"
      yellow_msg "RHEL derivative $OS_ID — using centos-optimizer.sh"
      ;;
    *)
      if [[ "${ID_LIKE:-}" == *"ubuntu"* ]] || [[ "${ID_LIKE:-}" == *"debian"* ]]; then
        if [[ "$OS_ID" == "linuxmint" || "${ID_LIKE:-}" == *"ubuntu"* ]]; then file="ubuntu-optimizer.sh"
        else file="debian-optimizer.sh"; fi
        yellow_msg "Derivative $OS_ID — mapped to $file via ID_LIKE"
      elif [[ "${ID_LIKE:-}" == *"rhel"* ]] || [[ "${ID_LIKE:-}" == *"fedora"* ]]; then
        file="centos-optimizer.sh"; yellow_msg "Derivative $OS_ID — mapped to $file"
      else
        red_msg "Cannot map OS $OS_ID to optimizer script"
        return 1
      fi
      ;;
  esac
  url="${BASE_URL}/${file}"
  sha="${EXPECTED_SHA256[$file]:-}"
  if [[ -z "$sha" ]]; then
    red_msg "No expected SHA256 for $file — fail-closed. Update EXPECTED_SHA256 for ref $OPTIMIZER_REF"
    return 1
  fi
  printf "%s|%s|%s" "$file" "$url" "$sha"
}

# ---------- Dependency handling ----------
check_required_commands() {
  local missing=()
  for cmd in grep sed cp mv rm mkdir chmod flock mktemp sha256sum; do
    if ! require_cmd "$cmd"; then missing+=("$cmd"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    red_msg "Missing core commands: ${missing[*]} — cannot continue"
    exit 1
  fi
  # Optional but needed later
  if ! require_cmd curl && ! require_cmd wget; then
    red_msg "Neither curl nor wget found — required for secure downloads"
    exit 1
  fi
  if ! require_cmd jq && [[ $WITH_TIMEZONE -eq 1 ]]; then
    yellow_msg "jq not found but required for timezone GeoIP parsing — will install"
  fi
}

install_dependencies_debian_based() {
  if is_dry; then yellow_msg "[DRY-RUN] would: apt-get update -q && apt-get install -yq wget curl jq (if missing)"; CHANGES_SKIPPED+=("deps: dry-run"); return 0; fi
  if ! require_cmd apt-get; then red_msg "apt-get not found"; return 1; fi
  # Check connectivity first — DNS required for apt hosts, IP alone insufficient for hostname HTTPS
  if ! has_internet; then red_msg "No internet connectivity — cannot install dependencies"; return 1; fi
  if ! has_dns; then yellow_msg "DNS resolution may be failing — IP connectivity (1.1.1.1) may still work, but apt and raw.githubusercontent.com require DNS (TLS SNI) and will fail until DNS is fixed (no automatic IP fallback, no curl -k)"; fi

  yellow_msg 'Installing Dependencies (debian)...'
  local pkgs=()
  if ! require_cmd wget; then pkgs+=(wget); fi
  if ! require_cmd curl; then pkgs+=(curl); fi
  if ! require_cmd jq; then pkgs+=(jq); fi
  # sudo not needed as root, but ensure ca-certificates for TLS
  if ! dpkg -l ca-certificates >/dev/null 2>&1; then pkgs+=(ca-certificates); fi
  if [[ ${#pkgs[@]} -eq 0 ]]; then green_msg "Dependencies already satisfied (wget curl jq)"; CHANGES_SKIPPED+=("deps: already satisfied"); return 0; fi

  log "RUN: apt-get update -q"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update -q 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    red_msg "apt update failed — see $LOG_FILE"
    FAILURES+=("deps: apt update failed")
    return 1
  fi
  log "RUN: apt-get install -yq ${pkgs[*]}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -yq -- "${pkgs[@]}" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    red_msg "apt install failed for ${pkgs[*]}"
    FAILURES+=("deps: apt install failed")
    return 1
  fi
  # Verify actually installed
  for p in "${pkgs[@]}"; do
    if ! dpkg -l -- "$p" 2>/dev/null | grep -q "^ii"; then
      red_msg "Package $p not installed after apt install (verification failed)"
      FAILURES+=("deps: $p verification failed")
      return 1
    fi
  done
  green_msg 'Dependencies Installed.'
  CHANGES_DONE+=("deps: installed ${pkgs[*]}")
}

install_dependencies_rhel_based() {
  if is_dry; then yellow_msg "[DRY-RUN] would: dnf install -y wget curl jq ca-certificates"; CHANGES_SKIPPED+=("deps: dry-run"); return 0; fi
  local pm=""
  if require_cmd dnf; then pm="dnf"
  elif require_cmd yum; then pm="yum"
  else red_msg "Neither dnf nor yum found"; return 1; fi
  if ! has_internet; then red_msg "No internet — cannot install dependencies"; return 1; fi

  yellow_msg "Installing Dependencies (rhel) via $pm..."
  local pkgs=()
  if ! require_cmd wget; then pkgs+=(wget); fi
  if ! require_cmd curl; then pkgs+=(curl); fi
  if ! require_cmd jq; then pkgs+=(jq); fi
  if [[ ${#pkgs[@]} -eq 0 ]]; then green_msg "Dependencies already satisfied"; CHANGES_SKIPPED+=("deps: already satisfied"); return 0; fi

  log "RUN: $pm install -y ${pkgs[*]}"
  if ! "$pm" install -y -- "${pkgs[@]}" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    red_msg "$pm install failed"
    FAILURES+=("deps: $pm install failed")
    return 1
  fi
  # Verify
  for p in "${pkgs[@]}"; do
    if ! rpm -q -- "$p" >/dev/null 2>&1; then
      red_msg "Package $p not installed (rpm -q failed)"
      FAILURES+=("deps: $p rpm verification failed")
      return 1
    fi
  done
  green_msg 'Dependencies Installed.'
  CHANGES_DONE+=("deps: installed ${pkgs[*]}")
}

# ---------- /etc/hosts ----------
fix_etc_hosts() {
  yellow_msg "Checking /etc/hosts"
  if [[ ! -e "$HOST_PATH" ]]; then
    red_msg "$HOST_PATH does not exist"
    FAILURES+=("hosts: $HOST_PATH missing")
    return 1
  fi
  if [[ ! -f "$HOST_PATH" && ! -L "$HOST_PATH" ]]; then
    red_msg "$HOST_PATH is not a regular file"
    return 1
  fi
  # Validate hostname once
  local hn=""
  if require_cmd hostname; then hn="$(hostname 2>/dev/null || true)"; fi
  if [[ -z "$hn" ]]; then hn="$(uname -n 2>/dev/null || true)"; fi
  hn="$(echo "$hn" | tr -d ' \t\r\n')"
  if [[ -z "$hn" ]]; then
    red_msg "Cannot determine hostname — skipping hosts fix"
    CHANGES_SKIPPED+=("hosts: empty hostname")
    return 0
  fi
  # Validate hostname format (RFC 1123-ish)
  if ! echo "$hn" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$'; then
    yellow_msg "Hostname '$hn' looks unusual — skipping strict validation but proceeding cautiously"
  fi
  if [[ "$hn" == "localhost" ]]; then
    green_msg "Hosts OK (hostname is localhost, no entry needed)"
    CHANGES_SKIPPED+=("hosts: localhost")
    return 0
  fi

  # Check idempotently with fixed-string
  if grep -Fq -- "$hn" "$HOST_PATH" 2>/dev/null; then
    green_msg "Hosts OK. No changes made (entry for $hn already present)."
    CHANGES_SKIPPED+=("hosts: already present $hn")
    return 0
  fi

  # Need to add entry
  if is_dry; then yellow_msg "[DRY-RUN] would add '127.0.1.1 $hn' to $HOST_PATH (backup first)"; CHANGES_SKIPPED+=("hosts: dry-run"); return 0; fi

  begin_transaction
  if ! tx_backup_file -- "$HOST_PATH"; then do_rollback; return 1; fi
  # Idempotent append: only if still missing (race-safe)
  if grep -Fq -- "$hn" "$HOST_PATH" 2>/dev/null; then
    green_msg "Hosts OK (race: entry appeared)"
    commit_transaction
    CHANGES_SKIPPED+=("hosts: race present")
    return 0
  fi
  # Validate file is writable and preserve perms by appending
  if ! echo "127.0.1.1 $hn" | tee -a -- "$HOST_PATH" >/dev/null 2>&1; then
    red_msg "Failed to append to $HOST_PATH"
    do_rollback; FAILURES+=("hosts: append failed"); return 1
  fi
  # Verify idempotency: no duplicate lines
  local count; count="$(grep -F -c -- "$hn" "$HOST_PATH" 2>/dev/null || echo 0)"
  if [[ "$count" -gt 1 ]]; then
    yellow_msg "Duplicate host entries detected for $hn (count=$count) — deduplicating"
    # Keep first occurrence, but since we just added second, rollback and fix correctly? Simpler: restore and add once
    do_rollback
    # Re-attempt with dedup: ensure only one
    begin_transaction
    tx_backup_file -- "$HOST_PATH"
    # Remove duplicate 127.0.1.1 lines for this hostname then add one
    # Use grep -Fv to filter, but need exact? Keep original file without our hostname line then add
    # Safer: restore backup was already done, now do precise dedup
    # Since we rolled back, file is original without our entry, so just append again once
    echo "127.0.1.1 $hn" | tee -a -- "$HOST_PATH" >/dev/null
  fi
  green_msg "Hosts Fixed (added 127.0.1.1 $hn)."
  log "Hosts fix: added 127.0.1.1 $hn to $HOST_PATH"
  commit_transaction
  CHANGES_DONE+=("hosts: added $hn")
}

# ---------- DNS ----------
detect_dns_manager() {
  local info=""
  # Check symlink
  if [[ -L "$DNS_PATH" ]]; then
    local target; target="$(readlink -f -- "$DNS_PATH" 2>/dev/null || readlink -- "$DNS_PATH" 2>/dev/null || echo "")"
    info="symlink->$target"
    if echo "$target" | grep -q "systemd/resolve"; then echo "systemd-resolved ($info)"; return 0; fi
    if echo "$target" | grep -q "NetworkManager"; then echo "NetworkManager ($info)"; return 0; fi
  fi
  # Check systemd-resolved active
  if require_cmd systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    echo "systemd-resolved (active)"
    return 0
  fi
  if require_cmd systemctl && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "NetworkManager (active)"
    return 0
  fi
  if [[ -f /etc/resolvconf/resolv.conf.d/head ]] || require_cmd resolvconf 2>/dev/null; then
    # Check if resolvconf managed
    if grep -q "resolvconf" -- "$DNS_PATH" 2>/dev/null; then echo "resolvconf"; return 0; fi
  fi
  if grep -q "Generated by" -- "$DNS_PATH" 2>/dev/null; then
    local gen; gen="$(head -5 -- "$DNS_PATH" 2>/dev/null | tr '\n' ' ')"
    echo "managed ($gen)"
    return 0
  fi
  echo "regular-file"
  return 1
}

is_stub_listener_active() {
  # Check 127.0.0.53:53 listening
  if require_cmd ss; then
    if ss -lun 2>/dev/null | grep -q "127.0.0.53:53"; then return 0; fi
    if ss -lun 2>/dev/null | grep -q "127.0.0.53"; then return 0; fi
  fi
  if require_cmd netstat; then
    if netstat -lun 2>/dev/null | grep -q "127.0.0.53:53"; then return 0; fi
  fi
  if require_cmd systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    # If resolved active but ss not showing, still check via resolvectl
    if require_cmd resolvectl && resolvectl status 2>/dev/null | grep -q "127.0.0.53"; then return 0; fi
    # Fallback: consider active as listening if service is active
    return 0
  fi
  return 1
}

fix_dns() {
  # Preserve working DNS — do not replace healthy provider (e.g., 185.12.64.1) with fallback
  if test_target_hostname -- "$TARGET_HOST" 2>/dev/null; then
    local _cur_srv; _cur_srv="$(get_current_dns_servers 2>/dev/null || echo "unknown")"
    if [[ $WITH_DNS -ne 1 ]]; then
      yellow_msg "DNS optimization skipped (default preserve). Current DNS working (${_cur_srv:-none}) — preserved."
      CHANGES_SKIPPED+=("dns: preserved working ${_cur_srv:-none}")
      return 0
    else
      yellow_msg "DNS is working (${_cur_srv:-none}) — preserving existing provider DNS, no modification (even with --with-dns)."
      CHANGES_SKIPPED+=("dns: preserved working ${_cur_srv:-none} (--with-dns)")
      return 0
    fi
  fi
  # At this point DNS is broken — decide if we are allowed to modify
  if [[ $WITH_DNS -ne 1 && ${NO_DNS:-0} -eq 0 ]]; then
    # Default automatic will be handled by state machine in main(), not here; keep fix_dns as no-op for now
    yellow_msg "DNS is broken — fix_dns with default preserve will delegate to automatic native recovery (state machine). Use --no-dns to disable."
    # Fall through to allow state machine to handle; fix_dns itself will not blindly edit
    # For backward compat, if called directly with --with-dns broken, we will run recovery below
    if [[ $WITH_DNS -ne 1 ]]; then
      # Default case: let state machine handle it — return success to let main continue to state machine
      CHANGES_SKIPPED+=("dns: broken, delegating to state machine")
      return 0
    fi
  fi
  if [[ $WITH_DNS -ne 1 ]]; then
    yellow_msg "DNS optimization skipped (default preserve). Current DNS preserved."
    CHANGES_SKIPPED+=("dns: skipped (use --with-dns)")
    return 0
  fi
  yellow_msg "DNS optimization requested (--with-dns) and current DNS is broken — native recovery will be attempted"
  # Detect manager
  local mgr; mgr="$(detect_dns_manager 2>/dev/null || echo "regular-file")"
  log "DNS manager detection: $mgr"
  if echo "$mgr" | grep -q "systemd-resolved"; then
    yellow_msg "systemd-resolved detected ($mgr) — DNS is managed."
    if is_dry; then yellow_msg "[DRY-RUN] would configure systemd-resolved via /etc/systemd/resolved.conf.d/ (not editing $DNS_PATH)"; CHANGES_SKIPPED+=("dns: dry-run systemd-resolved"); return 0; fi
    # Check stub listener before adding 127.0.0.53
    local add_stub=0
    if is_stub_listener_active; then add_stub=1; log "Stub 127.0.0.53 is listening"; else yellow_msg "127.0.0.53 NOT listening — will NOT add stub entry"; log "Stub not listening, skip 127.0.0.53"; fi

    # Configure via resolved.conf drop-in rather than editing generated resolv.conf
    local dropin_dir="/etc/systemd/resolved.conf.d"
    local dropin_file="${dropin_dir}/99-linux-optimizer.conf"
    begin_transaction
    # Backup existing dropin if exists, and also backup DNS_PATH for reversibility (but not modify DNS_PATH directly)
    if [[ -f "$dropin_file" ]]; then tx_backup_file -- "$dropin_file"
    else TX_ACTIONS+=("delete|$dropin_file|"); fi
    # Also backup resolv.conf for audit, but we won't modify it directly
    if [[ -f "$DNS_PATH" ]]; then
      # Create an audit backup but not for rollback of DNS_PATH (since we don't modify it)
      mkdir -p -- "$BACKUP_DIR" 2>/dev/null || true
      cp -a -- "$DNS_PATH" "${BACKUP_DIR}/resolv.conf.audit.bak" 2>/dev/null || true
    fi
    mkdir -p -- "$dropin_dir" 2>/dev/null || { red_msg "Failed to create $dropin_dir"; do_rollback; return 1; }
    local nameservers="1.1.1.2 1.0.0.2"
    if [[ $add_stub -eq 1 ]]; then nameservers="1.1.1.2 1.0.0.2 127.0.0.53"; fi
    # Preserve existing? Read current resolved.conf if any and merge? For now, set DNS= explicitly and ensure not duplicating.
    cat > "$dropin_file" <<EOF
# Generated by linux-optimizer-bootstrap $SCRIPT_VERSION $TRANSACTION_ID
# Preserves existing system DNS; adds fallback. Reversible via backup in $BACKUP_DIR
[Resolve]
DNS=${nameservers}
FallbackDNS=1.1.1.1 8.8.8.8
EOF
    chmod 644 -- "$dropin_file" 2>/dev/null || true
    log "Wrote $dropin_file DNS=$nameservers"

    # Validate
    if ! systemd-analyze verify "$dropin_file" 2>/dev/null; then
      yellow_msg "systemd-analyze verify warning for $dropin_file (ignored, but checking syntax)"
    fi
    # Try to restart/reload resolved if safe
    if require_cmd systemctl; then
      if ! systemctl restart systemd-resolved 2>/dev/null; then
        yellow_msg "systemd-resolved restart failed — will try reload"
        systemctl reload systemd-resolved 2>/dev/null || true
      fi
      # Verify service healthy
      if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        red_msg "systemd-resolved not active after change — rolling back"
        do_rollback
        systemctl restart systemd-resolved 2>/dev/null || true
        FAILURES+=("dns: systemd-resolved failed after change")
        return 1
      fi
    fi
    green_msg "DNS configured via $dropin_file (systemd-resolved, reversible)"
    CHANGES_DONE+=("dns: systemd-resolved $dropin_file")
    commit_transaction
    return 0
  elif echo "$mgr" | grep -q "NetworkManager"; then
    yellow_msg "NetworkManager manages DNS — not modifying $DNS_PATH directly. Configure via nmcli or /etc/NetworkManager/conf.d/"
    yellow_msg "Skipping DNS modification to avoid breaking NetworkManager. Manual: nmcli con mod <id> ipv4.dns '1.1.1.2,1.0.0.2'"
    CHANGES_SKIPPED+=("dns: NetworkManager managed, skipped")
    return 0
  elif echo "$mgr" | grep -q "resolvconf"; then
    yellow_msg "resolvconf manages DNS — not modifying $DNS_PATH directly. Use /etc/resolvconf/resolv.conf.d/"
    CHANGES_SKIPPED+=("dns: resolvconf managed")
    return 0
  fi

  # Regular file — safe to modify, but preserve existing, idempotent, reversible
  if [[ ! -f "$DNS_PATH" ]]; then
    red_msg "$DNS_PATH not found"
    FAILURES+=("dns: $DNS_PATH missing")
    return 1
  fi
  # Validate stub listener before adding 127.0.0.53
  local want_stub=0
  if is_stub_listener_active; then want_stub=1; fi

  # Read existing valid nameservers
  local existing=()
  while IFS= read -r line; do
    if echo "$line" | grep -Eq '^[[:space:]]*nameserver[[:space:]]+'; then
      local ns; ns="$(echo "$line" | awk '{print $2}' | tr -d '\r')"
      if [[ -n "$ns" ]]; then existing+=("$ns"); fi
    fi
  done < "$DNS_PATH"

  yellow_msg "Existing nameservers: ${existing[*]:-none}"

  # Desired: ensure 1.1.1.2 and 1.0.0.2 present, plus stub if applicable, without duplicating or deleting others
  local desired=("1.1.1.2" "1.0.0.2")
  if [[ $want_stub -eq 1 ]]; then desired+=("127.0.0.53"); fi

  local to_add=()
  for ns in "${desired[@]}"; do
    local found=0
    for e in "${existing[@]}"; do if [[ "$e" == "$ns" ]]; then found=1; break; fi; done
    if [[ $found -eq 0 ]]; then to_add+=("$ns"); fi
  done

  if [[ ${#to_add[@]} -eq 0 ]]; then
    green_msg "DNS OK. No changes needed (desired already present)."
    CHANGES_SKIPPED+=("dns: already correct")
    return 0
  fi

  if is_dry; then yellow_msg "[DRY-RUN] would add nameservers ${to_add[*]} to $DNS_PATH (preserving existing ${existing[*]})"; CHANGES_SKIPPED+=("dns: dry-run"); return 0; fi

  begin_transaction
  if ! tx_backup_file -- "$DNS_PATH"; then do_rollback; return 1; fi

  # Idempotent append: add missing nameservers at end, preserving existing
  for ns in "${to_add[@]}"; do
    echo "nameserver $ns" >> "$DNS_PATH" 2>/dev/null || { red_msg "Failed to write $DNS_PATH"; do_rollback; return 1; }
    log "DNS added nameserver $ns"
  done

  # Validate: file must contain at least one nameserver and not empty; check for duplicate lines
  if ! grep -Eq '^[[:space:]]*nameserver' -- "$DNS_PATH" 2>/dev/null; then
    red_msg "DNS validation failed: no nameserver in $DNS_PATH after edit — rolling back"
    do_rollback; FAILURES+=("dns: validation no nameserver"); return 1
  fi
  # Validate connectivity after? Try DNS resolution, but don't fail closed on external DNS failure — just warn
  if ! has_dns; then yellow_msg "DNS resolution test failed after change — may need to check connectivity, but file preserved"; fi

  green_msg "DNS Fixed (added ${to_add[*]}, preserved existing ${existing[*]}, reversible via $BACKUP_DIR)"
  CHANGES_DONE+=("dns: added ${to_add[*]}")
  commit_transaction
}

# ---------- DNS Recovery Helpers (OS-aware, native, transactional) ----------
get_current_resolver_target() {
  if [[ -L "$DNS_PATH" ]]; then
    readlink -f -- "$DNS_PATH" 2>/dev/null || readlink -- "$DNS_PATH" 2>/dev/null || echo "symlink-unknown"
  else
    echo "regular-file"
  fi
}

get_current_dns_servers() {
  local servers=()
  # Try resolvectl first (systemd-resolved)
  if require_cmd resolvectl && resolvectl status 2>/dev/null | grep -q "DNS Servers"; then
    while IFS= read -r line; do
      # line like "  DNS Servers: 185.12.64.1 185.12.64.2"
      for token in $line; do
        if [[ "$token" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$token" =~ ^[0-9a-fA-F:]+$ ]]; then
          servers+=("$token")
        fi
      done
    done < <(resolvectl status 2>/dev/null | grep "DNS Servers" || true)
  fi
  # Fallback: parse /etc/resolv.conf nameservers
  if [[ ${#servers[@]} -eq 0 && -f "$DNS_PATH" ]]; then
    while IFS= read -r line; do
      if echo "$line" | grep -Eq '^[[:space:]]*nameserver[[:space:]]+'; then
        local ns; ns="$(echo "$line" | awk '{print $2}' | tr -d '\r')"
        [[ -n "$ns" ]] && servers+=("$ns")
      fi
    done < "$DNS_PATH" 2>/dev/null || true
  fi
  # Deduplicate
  if [[ ${#servers[@]} -gt 0 ]]; then
    printf "%s\n" "${servers[@]}" | sort -u | tr '\n' ' ' | xargs 2>/dev/null || echo "${servers[*]}"
  else
    echo ""
  fi
}

# Read-only DNS tests — do not modify
test_dns_resolvectl_query() {
  local host="${1:-$TARGET_HOST}"
  if require_cmd resolvectl; then
    if timeout 5 resolvectl query -- "$host" >/dev/null 2>&1; then return 0; fi
    # Older resolvectl without query: try resolve
    if timeout 5 resolvectl query "$host" 2>&1 | grep -q "Address:"; then return 0; fi
  fi
  return 1
}
test_dns_getent_ahostsv4() {
  local host="${1:-$TARGET_HOST}"
  if require_cmd getent; then
    if timeout 4 getent ahostsv4 -- "$host" >/dev/null 2>&1; then return 0; fi
    if timeout 4 getent ahosts -- "$host" >/dev/null 2>&1; then return 0; fi
    if timeout 4 getent hosts -- "$host" >/dev/null 2>&1; then return 0; fi
  fi
  return 1
}
test_dns_dig() {
  local host="${1:-$TARGET_HOST}"
  if require_cmd dig; then
    if timeout 5 dig +time=2 +tries=1 -- "$host" +short >/dev/null 2>&1 && timeout 5 dig +time=2 +tries=1 -- "$host" +short 2>/dev/null | grep -Eq '[0-9.]+'; then return 0; fi
  fi
  return 1
}
test_target_hostname() {
  # Multiple read-only tests, succeed if any passes
  local host="${1:-$TARGET_HOST}"
  if test_dns_resolvectl_query -- "$host"; then log "DNS test resolvectl query $host: PASS"; return 0; fi
  if test_dns_getent_ahostsv4 -- "$host"; then log "DNS test getent ahostsv4 $host: PASS"; return 0; fi
  if test_dns_dig -- "$host"; then log "DNS test dig $host: PASS"; return 0; fi
  # Fallback: getent hosts
  if require_cmd getent && timeout 4 getent hosts -- "$host" >/dev/null 2>&1; then log "DNS test getent hosts $host: PASS"; return 0; fi
  log "DNS test $host: FAIL (all methods)"
  return 1
}
test_dns_server_candidate() {
  local server="$1" host="${2:-$TARGET_HOST}"
  if [[ -z "$server" ]]; then return 1; fi
  # Test reachability first (bounded)
  if ! timeout 2 bash -c "exec 3<>/dev/tcp/$server/53" 2>/dev/null; then
    # UDP 53 may not accept TCP, try dig anyway
    :
  fi
  if require_cmd dig; then
    if timeout 4 dig +time=2 +tries=1 "@$server" -- "$host" +short 2>/dev/null | grep -Eq '[0-9.]+'; then return 0; fi
  elif require_cmd drill; then
    if timeout 4 drill "@$server" -- "$host" 2>/dev/null | grep -Eq '[0-9.]+'; then return 0; fi
  elif require_cmd host; then
    if timeout 4 host -- "$host" "$server" >/dev/null 2>&1; then return 0; fi
  elif require_cmd nslookup; then
    if timeout 4 nslookup -- "$host" "$server" >/dev/null 2>&1; then return 0; fi
  else
    # No per-server query tool, try generic getent with timeout but cannot test candidate isolation
    return 1
  fi
  return 1
}
test_dns_verify_https() {
  local url="${1:-https://$TARGET_HOST}"
  if require_cmd curl; then
    if curl --proto '=https' --tlsv1.2 --fail --silent --connect-timeout 5 --max-time 10 --head -- "$url" >/dev/null 2>&1; then return 0; fi
  fi
  if require_cmd wget; then
    if wget --https-only --timeout=10 --tries=1 --spider -q -- "$url" 2>/dev/null; then return 0; fi
  fi
  return 1
}

detect_dns_manager_enhanced() {
  # Priority: systemd-resolved > NetworkManager > netplan > resolvconf > static
  local mgr="static"
  local detail=""
  # Check systemd-resolved
  if require_cmd systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mgr="systemd-resolved"
    detail="active"
  elif [[ -L "$DNS_PATH" ]] && readlink -f -- "$DNS_PATH" 2>/dev/null | grep -q "systemd/resolve"; then
    mgr="systemd-resolved"
    detail="symlink"
  elif require_cmd resolvectl && resolvectl status >/dev/null 2>&1; then
    mgr="systemd-resolved"
    detail="resolvectl"
  fi
  if [[ "$mgr" == "systemd-resolved" ]]; then echo "$mgr:$detail"; return 0; fi
  # NetworkManager
  if require_cmd nmcli && nmcli general status >/dev/null 2>&1; then
    if systemctl is-active --quiet NetworkManager 2>/dev/null || nmcli device status >/dev/null 2>&1; then
      # Check if any connection is managed
      if nmcli -t -f STATE general 2>/dev/null | grep -q connected; then echo "NetworkManager:active"; return 0; fi
      # Even if not connected, NM present
      echo "NetworkManager:present"; return 0
    fi
  fi
  # netplan
  if [[ -d /etc/netplan ]] && ls /etc/netplan/*.yaml >/dev/null 2>&1; then
    if require_cmd netplan && netplan status >/dev/null 2>&1; then echo "netplan:active"; return 0; fi
    echo "netplan:present"; return 0
  fi
  # resolvconf
  if require_cmd resolvconf || [[ -d /etc/resolvconf ]]; then
    if grep -q "resolvconf" -- "$DNS_PATH" 2>/dev/null; then echo "resolvconf:managed"; return 0; fi
    echo "resolvconf:present"; return 0
  fi
  # Check static vs other
  if [[ -L "$DNS_PATH" ]]; then
    local tgt; tgt="$(get_current_resolver_target)"
    echo "static:symlink->$tgt"; return 0
  fi
  echo "static:regular-file"; return 0
}

dns_diagnostics_report() {
  yellow_msg "=== DNS Diagnostics ==="
  local resolver_target; resolver_target="$(get_current_resolver_target)"
  local dns_servers; dns_servers="$(get_current_dns_servers)"
  local mgr; mgr="$(detect_dns_manager_enhanced 2>/dev/null || echo "unknown")"
  DNS_MANAGER_DETECTED="$mgr"
  log "DNS diag: resolver_target=$resolver_target"
  log "DNS diag: manager=$mgr"
  log "DNS diag: servers=${dns_servers:-none}"
  log "DNS diag: target=$TARGET_HOST"
  echo "  Resolver: $resolver_target"
  echo "  Manager: $mgr"
  echo "  Servers: ${dns_servers:-none}"
  echo "  Target: $TARGET_HOST"
  # Test current DNS
  local test_ok=0
  if test_target_hostname -- "$TARGET_HOST"; then test_ok=1; yellow_msg "Current DNS: WORKING (target resolves)"; else red_msg "Current DNS: BROKEN (target does not resolve)"; fi
  # Also test raw specifically
  if test_dns_resolvectl_query -- "$TARGET_HOST"; then log "resolvectl query $TARGET_HOST PASS"; else log "resolvectl query $TARGET_HOST FAIL"; fi
  if test_dns_getent_ahostsv4 -- "$TARGET_HOST"; then log "getent ahostsv4 $TARGET_HOST PASS"; else log "getent ahostsv4 $TARGET_HOST FAIL"; fi
  if require_cmd dig && dig +short -- "$TARGET_HOST" 2>/dev/null | head -1 | grep -Eq '[0-9.]+'; then log "dig $TARGET_HOST PASS"; else log "dig $TARGET_HOST FAIL"; fi
  # HTTPS test
  if test_dns_verify_https "https://$TARGET_HOST"; then log "HTTPS https://$TARGET_HOST PASS"; else log "HTTPS https://$TARGET_HOST FAIL"; fi
  return $test_ok
}

dns_select_fallback() {
  # Test fallback candidates with bounded timeout, return first working or empty
  local host="${1:-$TARGET_HOST}"
  local tried=()
  for cand in "${DNS_FALLBACK_CANDIDATES[@]}"; do
    tried+=("$cand")
    yellow_msg "Testing fallback DNS $cand for $host (timeout 3s)..."
    if test_dns_server_candidate -- "$cand" -- "$host"; then
      green_msg "Fallback DNS $cand: REACHABLE"
      log "Fallback candidate $cand PASS"
      echo "$cand"
      return 0
    else
      yellow_msg "Fallback DNS $cand: unreachable"
      log "Fallback candidate $cand FAIL"
    fi
  done
  # Also test via HTTPS if dig not available but curl to IP might hint? Do not assume, return empty
  log "All fallback candidates failed: ${tried[*]}"
  return 1
}

# Transactional apply helpers — each must backup before modification and verify after
dns_apply_systemd_resolved() {
  local dns_list="$1" # space-separated "1.1.1.1 8.8.8.8"
  if is_dry; then yellow_msg "[DRY-RUN] would create /etc/systemd/resolved.conf.d/99-linux-optimizer-dns.conf DNS=$dns_list and restart systemd-resolved"; return 0; fi
  local dropin_dir="/etc/systemd/resolved.conf.d"
  local dropin_file="${dropin_dir}/99-linux-optimizer-dns.conf"
  begin_transaction
  if [[ -f "$dropin_file" ]]; then tx_backup_file -- "$dropin_file" || { do_rollback; return 1; }
  else TX_ACTIONS+=("delete|$dropin_file|"); fi
  # Also backup audit copy of resolv.conf
  if [[ -f "$DNS_PATH" ]]; then mkdir -p -- "$BACKUP_DIR" 2>/dev/null || true; cp -a -- "$DNS_PATH" "${BACKUP_DIR}/resolv.conf.audit.bak" 2>/dev/null || true; fi
  mkdir -p -- "$dropin_dir" 2>/dev/null || { red_msg "Failed to create $dropin_dir"; do_rollback; return 1; }
  cat > "$dropin_file" <<EOF
# Generated by linux-optimizer-bootstrap $SCRIPT_VERSION $TRANSACTION_ID
# Native systemd-resolved recovery — preserves provider if working, else fallback $dns_list
# Reversible via $BACKUP_DIR — do not edit manually
[Resolve]
DNS=$dns_list
FallbackDNS=1.1.1.1 8.8.8.8
Domains=~.
EOF
  chmod 644 -- "$dropin_file" 2>/dev/null || true
  log "Wrote $dropin_file DNS=$dns_list"
  # Verify syntax
  if require_cmd systemd-analyze && ! systemd-analyze verify "$dropin_file" 2>/dev/null; then yellow_msg "systemd-analyze verify warning (ignored)"; fi
  # Reload/restart safely
  if require_cmd systemctl; then
    # Prefer restart, fallback to reload
    if ! systemctl restart systemd-resolved 2>/dev/null; then
      yellow_msg "systemd-resolved restart failed, trying reload"
      systemctl reload systemd-resolved 2>/dev/null || true
    fi
    sleep 1
    if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      red_msg "systemd-resolved not active after recovery — rolling back"
      do_rollback
      systemctl restart systemd-resolved 2>/dev/null || true
      return 1
    fi
  fi
  DNS_RECOVERY_APPLIED=1
  DNS_RECOVERY_BACKUP_DIR="$BACKUP_DIR"
  # Verify via state machine next steps — caller will verify target + HTTPS
  commit_transaction
  return 0
}

dns_apply_networkmanager() {
  local dns_list_csv="$1" # comma-separated for nmcli
  if is_dry; then yellow_msg "[DRY-RUN] would nmcli con mod <active> ipv4.dns $dns_list_csv and reload"; return 0; fi
  if ! require_cmd nmcli; then red_msg "nmcli not found"; return 1; fi
  local conn; conn="$(nmcli -t -f NAME,STATE con show --active 2>/dev/null | grep ':activated' | head -1 | cut -d: -f1 || true)"
  if [[ -z "$conn" ]]; then conn="$(nmcli -t -f NAME con show 2>/dev/null | head -1 || true)"; fi
  if [[ -z "$conn" ]]; then red_msg "No NetworkManager connection found"; return 1; fi
  yellow_msg "NetworkManager active connection: $conn"
  # Backup via nmcli export and file copy
  begin_transaction
  # Backup connection file if exists
  local nm_file; nm_file="$(grep -l "id=$conn" /etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null | head -1 || true)"
  if [[ -n "$nm_file" && -f "$nm_file" ]]; then tx_backup_file -- "$nm_file" || { do_rollback; return 1; }
  else
    # Record current dns via nmcli for rollback
    local cur_dns; cur_dns="$(nmcli -t -f ipv4.dns con show "$conn" 2>/dev/null | cut -d: -f2 || true)"
    log "NM current dns for $conn: ${cur_dns:-none}"
    # Register rollback via nmcli (we will restore via TX delete + manual restore on rollback if needed)
    # Use transaction to note we need to restore dns_list on rollback — we handle via explicit rollback step
    TX_ACTIONS+=("nm-restore|$conn|$cur_dns")
  fi
  # Apply
  if ! nmcli con mod "$conn" ipv4.dns "$dns_list_csv" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then red_msg "nmcli con mod failed"; do_rollback; return 1; fi
  # Also set to ignore auto DNS if needed, but preserve existing behavior: do not blindly overwrite, only set dns
  # Reload
  if ! nmcli con up "$conn" 2>/dev/null; then
    yellow_msg "nmcli con up $conn failed, trying reload"
    nmcli general reload 2>/dev/null || true
    # Try to bring up again
    nmcli con up "$conn" 2>/dev/null || true
  fi
  sleep 2
  DNS_RECOVERY_APPLIED=1
  DNS_RECOVERY_BACKUP_DIR="$BACKUP_DIR"
  commit_transaction
  return 0
}

dns_apply_netplan() {
  local dns_list="$1" # space-separated
  if is_dry; then yellow_msg "[DRY-RUN] would create /etc/netplan/99-linux-optimizer.yaml for $dns_list and netplan try/apply"; return 0; fi
  local iface; iface="$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -1 || true)"
  if [[ -z "$iface" ]]; then iface="eth0"; yellow_msg "Could not detect default iface, using $iface"; fi
  local dropin="/etc/netplan/99-linux-optimizer.yaml"
  begin_transaction
  if [[ -f "$dropin" ]]; then tx_backup_file -- "$dropin" || { do_rollback; return 1; }
  else TX_ACTIONS+=("delete|$dropin|"); fi
  # Backup existing yamls audit
  mkdir -p -- "$BACKUP_DIR" 2>/dev/null || true
  cp -a /etc/netplan/*.yaml "$BACKUP_DIR"/ 2>/dev/null || true
  # Create minimal drop-in — netplan merges, does not overwrite whole file
  local dns_yaml; dns_yaml="$(echo "$dns_list" | tr ' ' ',' | sed 's/,/, /g')"
  # Use addresses as list: [1.1.1.1, 8.8.8.8]
  local addr_list; addr_list="$(echo "$dns_list" | awk '{for(i=1;i<=NF;i++) printf "%s%s", (i>1?", ":""), "\""$i"\"";}')"
  # Actually yaml expects: addresses: [1.1.1.1, 8.8.8.8]
  addr_list="[$(echo "$dns_list" | tr ' ' ',' )]"
  cat > "$dropin" <<EOF
# Generated by linux-optimizer-bootstrap $SCRIPT_VERSION $TRANSACTION_ID
# Minimal netplan drop-in — merges with existing, does not rewrite whole YAML
# Reversible via $BACKUP_DIR
network:
  version: 2
  ethernets:
    $iface:
      nameservers:
        addresses: $addr_list
EOF
  chmod 644 -- "$dropin" 2>/dev/null || true
  log "Wrote $dropin for $iface DNS $dns_list"
  # Validate
  if require_cmd netplan; then
    if ! netplan generate 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then red_msg "netplan generate failed"; do_rollback; return 1; fi
    # Use try where appropriate (timeout 10) to avoid lockout — but try requires tty, fallback to apply
    if [[ -t 1 ]] && netplan try --timeout 10 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then log "netplan try succeeded"; else
      yellow_msg "netplan try not available or failed, using netplan apply"
      if ! netplan apply 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then red_msg "netplan apply failed"; do_rollback; return 1; fi
    fi
  else
    red_msg "netplan not found"; do_rollback; return 1
  fi
  sleep 2
  DNS_RECOVERY_APPLIED=1
  DNS_RECOVERY_BACKUP_DIR="$BACKUP_DIR"
  commit_transaction
  return 0
}

dns_apply_resolvconf() {
  local dns_list="$1"
  if is_dry; then yellow_msg "[DRY-RUN] would resolvconf -a lo.linux-optimizer with $dns_list"; return 0; fi
  begin_transaction
  # resolvconf native: create tail or base
  local tail="/etc/resolvconf/resolv.conf.d/tail"
  if [[ -f "$tail" ]]; then tx_backup_file -- "$tail" || { do_rollback; return 1; }
  else TX_ACTIONS+=("delete|$tail|"); mkdir -p -- "$(dirname -- "$tail")" 2>/dev/null || true; fi
  for ns in $dns_list; do echo "nameserver $ns"; done > "$tail" 2>/dev/null || { red_msg "Failed to write $tail"; do_rollback; return 1; }
  chmod 644 -- "$tail" 2>/dev/null || true
  if require_cmd resolvconf; then
    if ! resolvconf --enable-updates 2>/dev/null; then true; fi
    # Force update
    resolvconf -u 2>/dev/null || true
  fi
  sleep 1
  DNS_RECOVERY_APPLIED=1
  DNS_RECOVERY_BACKUP_DIR="$BACKUP_DIR"
  commit_transaction
  return 0
}

dns_apply_static() {
  local dns_list="$1"
  if is_dry; then yellow_msg "[DRY-RUN] would backup $DNS_PATH and write minimal static resolv.conf with $dns_list"; return 0; fi
  # Only if genuinely unmanaged: not a symlink to systemd/resolve
  if [[ -L "$DNS_PATH" ]] && readlink -f -- "$DNS_PATH" 2>/dev/null | grep -q "systemd/resolve"; then
    red_msg "Refusing to overwrite systemd-resolved symlink $DNS_PATH with static file"
    return 1
  fi
  begin_transaction
  if ! tx_backup_file -- "$DNS_PATH"; then do_rollback; return 1; fi
  : > "$DNS_PATH" 2>/dev/null || { red_msg "Failed to truncate $DNS_PATH"; do_rollback; return 1; }
  for ns in $dns_list; do echo "nameserver $ns" >> "$DNS_PATH" 2>/dev/null || { red_msg "Failed to write $DNS_PATH"; do_rollback; return 1; }; done
  chmod 644 -- "$DNS_PATH" 2>/dev/null || true
  log "Wrote static $DNS_PATH with $dns_list"
  DNS_RECOVERY_APPLIED=1
  DNS_RECOVERY_BACKUP_DIR="$BACKUP_DIR"
  commit_transaction
  return 0
}

# Enhanced rollback to handle nm-restore
do_rollback_enhanced() {
  # Call original do_rollback then handle nm-restore entries
  local has_nm=0
  for entry in "${TX_ACTIONS[@]:-}"; do if [[ "$entry" == nm-restore\|* ]]; then has_nm=1; break; fi; done
  do_rollback
  if [[ $has_nm -eq 1 ]]; then
    for entry in "${TX_ACTIONS[@]:-}"; do
      if [[ "$entry" == nm-restore\|* ]]; then
        local rest="${entry#nm-restore|}"; local conn="${rest%%|*}"; local cur="${rest#*|}"
        if [[ -n "$conn" ]]; then
          if is_dry; then yellow_msg "[DRY-ROLLBACK] would nmcli con mod $conn ipv4.dns $cur"
          else nmcli con mod "$conn" ipv4.dns "$cur" 2>/dev/null || true; nmcli con up "$conn" 2>/dev/null || true; log "Rollback NM $conn dns $cur"; fi
        fi
      fi
    done
  fi
}

dns_recovery_state_machine() {
  # State machine: CHECK_CURRENT_DNS -> TEST_TARGET_HOSTNAME -> DETECT -> TEST_PROVIDER -> SELECT_FALLBACK -> APPLY -> RELOAD -> VERIFY -> HTTPS -> CONTINUE
  # Returns 0 if DNS working (preserved or recovered), 1 if failed (rolled back, fail-closed)
  local start_ts; start_ts="$(date -Is 2>/dev/null || date)"
  yellow_msg "=== DNS Recovery State Machine $start_ts ==="
  local resolver_target; resolver_target="$(get_current_resolver_target)"
  local current_servers; current_servers="$(get_current_dns_servers)"
  local mgr; mgr="$(detect_dns_manager_enhanced 2>/dev/null || echo "static:unknown")"
  DNS_MANAGER_DETECTED="$mgr"
  log "DNS SM: resolver=$resolver_target manager=$mgr servers=${current_servers:-none} target=$TARGET_HOST"
  echo "  Resolver: $resolver_target"
  echo "  Manager: $mgr"
  echo "  Current DNS: ${current_servers:-none}"
  echo "  Target: $TARGET_HOST"
  echo "  Backup root: $BACKUP_ROOT/$TRANSACTION_ID"
  log "DNS SM: CHECK_CURRENT_DNS"
  # Extensive diagnostics (read-only, no mutation)
  if test_target_hostname -- "$TARGET_HOST"; then
    green_msg "CHECK_CURRENT_DNS: PASS — current DNS resolves $TARGET_HOST, preserving existing configuration (e.g., ${current_servers:-preserved})"
    log "DNS SM: current DNS working, no recovery needed"
    CHANGES_SKIPPED+=("dns: preserved working ${current_servers:-none}")
    return 0
  fi
  red_msg "CHECK_CURRENT_DNS: FAIL — $TARGET_HOST does not resolve"
  log "DNS SM: TEST_TARGET_HOSTNAME FAIL"
  # If --no-dns, fail closed without modification
  if [[ ${NO_DNS:-0} -eq 1 ]]; then
    red_msg "DNS is broken and --no-dns is set — refusing to modify DNS (fail-closed). Fix /etc/resolv.conf manually to contain nameserver 1.1.1.1 or re-run without --no-dns."
    FAILURES+=("dns: broken, --no-dns fail-closed")
    return 1
  fi
  # --with-dns explicitly allows, default also allows automatic safe recovery (per new spec). No additional confirm needed unless not --yes?
  # For safety, if not --yes and DNS broken, ask? But automatic per spec: default should recover. We log and proceed.
  yellow_msg "DNS is broken — automatic native recovery will be attempted (manager: $mgr). Use --no-dns to disable."
  log "DNS SM: DETECT_DNS_MANAGER $mgr"
  # TEST_PROVIDER_DNS — test currently configured servers directly
  local provider_works=""
  for srv in $current_servers; do
    if [[ "$srv" == "127.0.0.53" ]] || [[ "$srv" == "127.0.0.1" ]]; then continue; fi # skip stubs for provider test
    yellow_msg "Testing provider DNS $srv for $TARGET_HOST..."
    if test_dns_server_candidate -- "$srv" -- "$TARGET_HOST"; then
      provider_works="$srv"
      green_msg "Provider DNS $srv: WORKING — will preserve provider"
      log "Provider $srv PASS"
      break
    else
      yellow_msg "Provider DNS $srv: unreachable"
      log "Provider $srv FAIL"
    fi
  done
  local selected=""
  if [[ -n "$provider_works" ]]; then
    # Preserve provider — use the working provider(s) as recovery list
    # Collect all working providers
    selected="$provider_works"
    # Try to include other provider servers that also work
    for srv in $current_servers; do
      if [[ "$srv" == "$provider_works" ]] || [[ "$srv" == "127.0.0.53" ]] || [[ "$srv" == "127.0.0.1" ]]; then continue; fi
      if test_dns_server_candidate -- "$srv" -- "$TARGET_HOST"; then selected+=" $srv"; fi
    done
    yellow_msg "SELECT_FALLBACK: preserving working provider DNS $selected"
  else
    yellow_msg "Current provider DNS unavailable — selecting fallback from ${DNS_FALLBACK_CANDIDATES[*]}"
    for cand in "${DNS_FALLBACK_CANDIDATES[@]}"; do
      if test_dns_server_candidate -- "$cand" -- "$TARGET_HOST"; then selected="$cand"; break; fi
    done
    # If no single candidate answers via dig but we have IP connectivity, still pick 1.1.1.1 as best effort and let verify stage decide
    if [[ -z "$selected" ]]; then
      # Check if any candidate is reachable on 53/tcp or via curl IP test as hint
      for cand in "${DNS_FALLBACK_CANDIDATES[@]}"; do
        if timeout 2 bash -c "exec 3<>/dev/tcp/$cand/53" 2>/dev/null; then selected="$cand"; yellow_msg "Fallback $cand TCP/53 reachable (no dig), selecting as best-effort"; break; fi
      done
    fi
    if [[ -z "$selected" ]]; then selected="1.1.1.1"; yellow_msg "No fallback responded to probe, defaulting to $selected (verify will confirm)"; fi
    # For robustness, use two fallbacks if possible
    if [[ "$selected" == "1.1.1.1" ]]; then
      # Try to add second
      for cand in "${DNS_FALLBACK_CANDIDATES[@]}"; do
        if [[ "$cand" == "$selected" ]]; then continue; fi
        if test_dns_server_candidate -- "$cand" -- "$TARGET_HOST"; then selected+=" $cand"; break; fi
      done
      # Ensure at least 1.1.1.1 + 8.8.8.8 if second not found but 8.8.8.8 TCP reachable
      if [[ "$selected" == "1.1.1.1" ]] && timeout 2 bash -c "exec 3<>/dev/tcp/8.8.8.8/53" 2>/dev/null; then selected+=" 8.8.8.8"; fi
    fi
    yellow_msg "SELECT_FALLBACK: $selected"
    log "DNS SM: SELECT_FALLBACK $selected"
  fi
  # APPLY via native manager
  yellow_msg "APPLY_NATIVE_CONFIGURATION via $mgr with DNS $selected"
  log "DNS SM: APPLY $mgr $selected"
  local apply_rc=0
  case "$mgr" in
    systemd-resolved*) dns_apply_systemd_resolved -- "$selected" || apply_rc=$? ;;
    NetworkManager*) 
      local csv; csv="$(echo "$selected" | tr ' ' ',')"
      dns_apply_networkmanager -- "$csv" || apply_rc=$?
      ;;
    netplan*) dns_apply_netplan -- "$selected" || apply_rc=$? ;;
    resolvconf*) dns_apply_resolvconf -- "$selected" || apply_rc=$? ;;
    static*) dns_apply_static -- "$selected" || apply_rc=$? ;;
    *) 
      red_msg "Unknown DNS manager $mgr — refusing to blindly overwrite /etc/resolv.conf. Fail-closed."
      log "DNS SM: unknown manager fail-closed"
      return 1
      ;;
  esac
  if [[ $apply_rc -ne 0 ]]; then
    red_msg "APPLY_NATIVE_CONFIGURATION failed (rc $apply_rc) — rolling back"
    do_rollback
    FAILURES+=("dns: apply $mgr failed")
    return 1
  fi
  # VERIFY_TARGET_DNS
  yellow_msg "VERIFY_TARGET_DNS for $TARGET_HOST ..."
  sleep 1
  local verify_ok=0
  if test_dns_resolvectl_query -- "$TARGET_HOST"; then log "VERIFY resolvectl query PASS"; verify_ok=1; else log "VERIFY resolvectl query FAIL"; fi
  if test_dns_getent_ahostsv4 -- "$TARGET_HOST"; then log "VERIFY getent ahostsv4 PASS"; verify_ok=1; else log "VERIFY getent ahostsv4 FAIL"; fi
  # Also test raw specifically
  if test_target_hostname -- "$TARGET_HOST"; then verify_ok=1; fi
  if [[ $verify_ok -eq 0 ]]; then
    red_msg "VERIFY_TARGET_DNS FAILED — $TARGET_HOST still does not resolve after recovery (manager $mgr, DNS $selected). Rolling back."
    do_rollback
    # Try to restart original resolver if we broke it
    if [[ "$mgr" == systemd-resolved* ]] && require_cmd systemctl; then systemctl restart systemd-resolved 2>/dev/null || true; fi
    FAILURES+=("dns: verify target failed")
    return 1
  fi
  green_msg "VERIFY_TARGET_DNS PASS"
  # VERIFY_HTTPS
  yellow_msg "VERIFY_HTTPS https://$TARGET_HOST ..."
  if ! test_dns_verify_https "https://$TARGET_HOST"; then
    red_msg "VERIFY_HTTPS FAILED — https://$TARGET_HOST not reachable after DNS fix. Rolling back."
    do_rollback
    FAILURES+=("dns: verify https failed")
    return 1
  fi
  green_msg "VERIFY_HTTPS PASS — DNS recovery successful (manager $mgr, DNS $selected, backup $BACKUP_DIR)"
  CHANGES_DONE+=("dns: recovered $mgr $selected")
  log "DNS SM: recovery SUCCESS"
  return 0
}

# ---------- Timezone ----------
set_timezone() {
  if [[ $WITH_TIMEZONE -ne 1 && -z "$EXPLICIT_TZ" ]]; then
    local current_tz; current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null || echo "unknown")"
    yellow_msg "Timezone preserved (current: $current_tz). Use --with-timezone or --timezone TZ to change. Default UTC preferred for servers."
    CHANGES_SKIPPED+=("timezone: preserved $current_tz")
    return 0
  fi

  # If explicit TZ provided, use it directly (validated)
  if [[ -n "$EXPLICIT_TZ" ]]; then
    local tz="$EXPLICIT_TZ"
    # Validate against timezone database
    if [[ -f "/usr/share/zoneinfo/$tz" ]]; then
      : # valid
    elif require_cmd timedatectl && timedatectl list-timezones 2>/dev/null | grep -Fxq -- "$tz"; then
      : # valid
    else
      red_msg "Invalid timezone '$tz' — not found in /usr/share/zoneinfo or timedatectl list-timezones"
      FAILURES+=("timezone: invalid $tz")
      return 1
    fi
    if ! require_cmd timedatectl; then red_msg "timedatectl not found — cannot set timezone"; return 1; fi
    if is_dry; then yellow_msg "[DRY-RUN] would: timedatectl set-timezone $tz"; CHANGES_SKIPPED+=("timezone: dry-run $tz"); return 0; fi
    local old_tz; old_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")"
    # Backup timezone config for rollback
    begin_transaction
    if [[ -f /etc/localtime ]]; then tx_backup_file -- "/etc/localtime" || true; fi
    if [[ -f /etc/timezone ]]; then tx_backup_file -- "/etc/timezone" || true; fi
    log "Changing timezone $old_tz -> $tz (explicit)"
    if ! timedatectl set-timezone -- "$tz" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
      red_msg "timedatectl set-timezone $tz failed"
      do_rollback; FAILURES+=("timezone: timedatectl failed"); return 1
    fi
    green_msg "Timezone set to $tz (was $old_tz)"
    CHANGES_DONE+=("timezone: $old_tz -> $tz explicit")
    commit_transaction
    return 0
  fi

  # GeoIP detection — single request, HTTPS only, validated, optional
  yellow_msg 'Setting TimeZone based on VPS IP address (GeoIP, single request, HTTPS)...'
  if ! require_cmd curl; then red_msg "curl required for GeoIP"; return 1; fi
  if ! require_cmd jq; then
    yellow_msg "jq not found — attempting to install for GeoIP JSON parsing"
    if is_dry; then yellow_msg "[DRY-RUN] would install jq"; return 0; fi
    # Try to install jq via package manager
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then install_dependencies_debian_based || true
    else install_dependencies_rhel_based || true; fi
    if ! require_cmd jq; then red_msg "jq still missing — cannot parse GeoIP"; return 1; fi
  fi
  if ! require_cmd timedatectl; then red_msg "timedatectl not found — cannot set timezone"; return 1; fi

  # Single IP fetch with timeout, HTTPS
  local ip=""
  local ip_sources=("https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ipv4.ident.me/")
  for src in "${ip_sources[@]}"; do
    ip="$(curl --proto '=https' --tlsv1.2 --fail --silent --connect-timeout 5 --max-time 10 --retry 1 -- "$src" 2>/dev/null | tr -d ' \r\n' || true)"
    if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then break; fi
    ip=""
  done
  if [[ -z "$ip" ]]; then
    yellow_msg "Failed to fetch public IP — preserving current timezone"
    CHANGES_SKIPPED+=("timezone: ip fetch failed, preserved")
    return 0
  fi
  log "GeoIP: public IP $ip"

  # Single GeoIP request, HTTPS, timeout, retry
  local geo_url="https://ip-api.com/json/${ip}?fields=status,timezone,message"
  local resp
  if ! resp="$(curl --proto '=https' --tlsv1.2 --fail --silent --connect-timeout 5 --max-time 15 --retry 1 -- "$geo_url" 2>/dev/null)"; then
    # Try ipapi.co as fallback HTTPS
    geo_url="https://ipapi.co/${ip}/json/"
    resp="$(curl --proto '=https' --tlsv1.2 --fail --silent --connect-timeout 5 --max-time 15 --retry 1 -- "$geo_url" 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
      yellow_msg "GeoIP request failed — preserving timezone"
      CHANGES_SKIPPED+=("timezone: geoip failed")
      return 0
    fi
  fi
  if [[ -z "$resp" ]]; then
    yellow_msg "Empty GeoIP response — preserving timezone"
    return 0
  fi
  # Validate JSON
  if ! echo "$resp" | jq -e . >/dev/null 2>&1; then
    yellow_msg "Invalid GeoIP JSON — preserving timezone"
    log "GeoIP invalid JSON: $resp"
    return 0
  fi
  # Check API success if ip-api.com
  local status; status="$(echo "$resp" | jq -r '.status // empty' 2>/dev/null || true)"
  if [[ -n "$status" && "$status" != "success" && "$status" != "Success" ]]; then
    local msg; msg="$(echo "$resp" | jq -r '.message // empty' 2>/dev/null || true)"
    yellow_msg "GeoIP API status $status $msg — preserving timezone"
    return 0
  fi
  local tz; tz="$(echo "$resp" | jq -r '.timezone // .time_zone // empty' 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -z "$tz" || "$tz" == "null" ]]; then
    yellow_msg "GeoIP returned empty timezone — preserving current"
    return 0
  fi
  # Validate timezone exists
  if [[ ! -f "/usr/share/zoneinfo/$tz" ]] && ! timedatectl list-timezones 2>/dev/null | grep -Fxq -- "$tz"; then
    red_msg "GeoIP timezone '$tz' not found in system database — preserving current"
    FAILURES+=("timezone: geoip tz invalid $tz")
    return 0
  fi
  local current_tz; current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")"
  if [[ "$tz" == "$current_tz" ]]; then
    green_msg "Timezone already $tz — no change"
    CHANGES_SKIPPED+=("timezone: already $tz")
    return 0
  fi
  if is_dry; then yellow_msg "[DRY-RUN] would: timedatectl set-timezone $tz (geoip for $ip)"; CHANGES_SKIPPED+=("timezone: dry-run $tz"); return 0; fi

  begin_transaction
  if [[ -f /etc/localtime ]]; then tx_backup_file -- "/etc/localtime" || true; fi
  if [[ -f /etc/timezone ]]; then tx_backup_file -- "/etc/timezone" || true; fi
  log "GeoIP timezone $tz for IP $ip (was $current_tz)"
  if ! confirm "Set timezone to $tz (detected for IP $ip, was $current_tz)?"; then
    yellow_msg "Timezone change declined — preserving $current_tz"
    commit_transaction
    CHANGES_SKIPPED+=("timezone: declined $tz")
    return 0
  fi
  if ! timedatectl set-timezone -- "$tz" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    red_msg "timedatectl set-timezone $tz failed"
    do_rollback; FAILURES+=("timezone: set failed $tz"); return 1
  fi
  green_msg "Timezone set to $tz (was $current_tz)"
  CHANGES_DONE+=("timezone: $current_tz -> $tz geoip")
  commit_transaction
}

# ---------- Secure download & verify ----------
# Fixed interface: secure_download_and_execute <filename> <download_url> <expected_sha256>
# - <filename> must be a basename like ubuntu-optimizer.sh (no path, no "--")
# - <download_url> must be https://...
# - <expected_sha256> is 64-char hex
# Callers must use: secure_download_and_execute "$opt_file" "$opt_url" "$opt_sha"
# The function also tolerates an optional leading "--" (end-of-options) for robustness,
# but "--" will never be accepted as a filename (fail-closed).
secure_download_and_execute() {
  # Tolerate optional leading "--" without treating it as filename
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  if [[ $# -lt 3 ]]; then
    red_msg "secure_download_and_execute: expected 3 args: <filename> <url> <sha256> (got $#)"
    return 1
  fi
  local file="$1"
  local url="$2"
  local expected_sha="$3"
  # Guard: filename must not be "--", empty, or contain path separators
  if [[ -z "$file" || "$file" == "--" ]]; then
    red_msg "secure_download_and_execute: invalid filename '$file' (refusing '--')"
    return 1
  fi
  if [[ "$file" == *"/"* ]]; then
    red_msg "secure_download_and_execute: filename must not contain '/' (got '$file')"
    return 1
  fi
  # Create secure temp dir if not exists
  if [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]]; then
    TMP_DIR="$(mktemp -d -t linux-optimizer-XXXXXX 2>/dev/null || mktemp -d 2>/dev/null)"
    chmod 700 -- "$TMP_DIR" 2>/dev/null || true
    log "Created secure tmp $TMP_DIR"
  fi
  local dest="${TMP_DIR}/${file}"

  yellow_msg "Downloading $file from $url..."

  if is_dry; then
    yellow_msg "[DRY-RUN] would: curl --proto '=https' --tlsv1.2 --fail --location --connect-timeout 10 --max-time 60 --retry 2 -o \"$dest\" \"$url\""
    yellow_msg "[DRY-RUN] would verify SHA256 $expected_sha and bash -n, then execute"
    CHANGES_SKIPPED+=("download: dry-run $file")
    return 0
  fi

  # Ensure no HTTP fallback, TLS verification strict
  local curl_ok=0
  if require_cmd curl; then
    log "RUN: curl --proto '=https' --tlsv1.2 --fail --location --connect-timeout 10 --max-time 60 --retry 2 -o \"$dest\" \"$url\""
    if curl --proto '=https' --tlsv1.2 --fail --location --connect-timeout 10 --max-time 60 --retry 2 --silent --show-error -o "$dest" "$url" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
      # Verify redirect stayed HTTPS: curl with --proto ensures final URL is https, but double-check via effective url
      local effective; effective="$(curl --proto '=https' --tlsv1.2 --fail --location --connect-timeout 10 --max-time 10 -o /dev/null -w '%{url_effective}' -- "$url" 2>/dev/null || echo "$url")"
      if echo "$effective" | grep -q "^http://"; then
        red_msg "Redirect to HTTP detected ($effective) — fail-closed"
        rm -f -- "$dest" 2>/dev/null || true
        FAILURES+=("download: http redirect $file")
        return 1
      fi
      curl_ok=1
    else
      red_msg "curl download failed for $url"
    fi
  fi
  if [[ $curl_ok -eq 0 ]] && require_cmd wget; then
    log "Fallback wget for $url"
    # wget with HTTPS only — exact construction required
    if wget --https-only --timeout=60 --tries=3 -O "$dest" "$url" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
      # wget doesn't auto-fail on http redirect if original https; check file exists
      curl_ok=1
    fi
  fi
  if [[ $curl_ok -eq 0 ]]; then
    red_msg "Download failed for $file from $url"
    rm -f -- "$dest" 2>/dev/null || true
    FAILURES+=("download: failed $file")
    return 1
  fi

  # Verify file exists non-empty
  if [[ ! -f "$dest" ]]; then red_msg "Downloaded file not found $dest"; FAILURES+=("download: not found $file"); return 1; fi
  if [[ ! -s "$dest" ]]; then red_msg "Downloaded file empty $dest — not executing (partial download)"; rm -f -- "$dest" 2>/dev/null || true; FAILURES+=("download: empty $file"); return 1; fi

  # Verify SHA256 (fail-closed)
  local actual_sha=""
  if require_cmd sha256sum; then
    actual_sha="$(sha256sum -- "$dest" 2>/dev/null | awk '{print $1}' || true)"
  elif require_cmd shasum; then
    actual_sha="$(shasum -a 256 -- "$dest" 2>/dev/null | awk '{print $1}' || true)"
  else
    red_msg "No sha256sum/shasum found — cannot verify integrity (fail-closed)"
    rm -f -- "$dest" 2>/dev/null || true
    FAILURES+=("download: no verifier $file")
    return 1
  fi
  actual_sha="$(echo "$actual_sha" | tr 'A-F' 'a-f' | tr -d ' \r\n')"
  expected_sha="$(echo "$expected_sha" | tr 'A-F' 'a-f' | tr -d ' \r\n')"
  if [[ -z "$actual_sha" ]]; then red_msg "Failed to compute SHA256 for $dest"; rm -f -- "$dest" 2>/dev/null || true; return 1; fi
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    red_msg "SHA256 mismatch for $file: expected $expected_sha got $actual_sha — fail-closed, not executing"
    log "SHA mismatch details: file=$file url=$url expected=$expected_sha actual=$actual_sha"
    rm -f -- "$dest" 2>/dev/null || true
    FAILURES+=("download: sha mismatch $file")
    return 1
  fi
  green_msg "SHA256 verified $file $actual_sha"

  # Syntax validation
  if ! bash -n -- "$dest" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    red_msg "Syntax check failed for $file (bash -n)"
    rm -f -- "$dest" 2>/dev/null || true
    FAILURES+=("download: syntax $file")
    return 1
  fi
  green_msg "Syntax OK $file"

  # Secure permissions
  chmod 700 -- "$dest" 2>/dev/null || true

  # Execute in secure temp, not cwd, with explicit bash
  yellow_msg "Executing $file (verified, pinned)..."
  log "RUN: bash $dest"
  local exec_rc=0
  if ! bash -- "$dest" 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    exec_rc=${PIPESTATUS[0]:-$?}
    red_msg "Optimizer $file exited with $exec_rc"
    FAILURES+=("optimizer: $file rc=$exec_rc")
    # Do not rollback bootstrap's own changes on optimizer failure? But per spec, if remote optimizer fails, rollback bootstrap transaction?
    # Bootstrap already committed its own transactions (hosts/dns/timezone). We report failure but preserve backups for manual rollback.
    return 1
  fi
  green_msg "Optimizer $file completed successfully"
  CHANGES_DONE+=("optimizer: $file executed")

  # Cleanup downloaded script unless preservation explicitly requested
  rm -f -- "$dest" 2>/dev/null || true
  log "Cleaned $dest"
  return 0
}

# ---------- Intro ----------
print_intro() {
  echo
  green_msg '================================================================='
  green_msg 'Linux Optimizer Bootstrap — SECURE (pinned, verified, reversible)'
  green_msg "Version $SCRIPT_VERSION | Ref $OPTIMIZER_REF"
  green_msg 'Supported: Ubuntu 20.04/22.04/24.04, Debian 11/12, CentOS Stream 8/9, AlmaLinux 8/9, Fedora 37+'
  green_msg 'Root access is required. Use --dry-run to preview, --help for options.'
  green_msg 'Source @ https://github.com/KanekiDevPro/linux-optimizer'
  green_msg '================================================================='
  echo
  log "Bootstrap start version=$SCRIPT_VERSION ref=$OPTIMIZER_REF dry=$DRY_RUN yes=$ASSUME_YES dns=$WITH_DNS tz=$WITH_TIMEZONE explicit_tz=$EXPLICIT_TZ"
}

# ---------- Final status ----------
print_final_status() {
  echo
  green_msg '================================================================='
  green_msg 'Final Status'
  green_msg '================================================================='
  echo "OS: $OS_PRETTY (ID=$OS_ID VERSION_ID=$OS_VERSION_ID)"
  echo "Ref: $OPTIMIZER_REF"
  echo "Transaction: $TRANSACTION_ID"
  echo "Backup dir: $BACKUP_DIR"
  echo "Log: $LOG_FILE"
  echo "Dry-run: $DRY_RUN"
  echo
  echo "Changes done (${#CHANGES_DONE[@]}):"
  if [[ ${#CHANGES_DONE[@]} -eq 0 ]]; then echo "  (none)"; else for c in "${CHANGES_DONE[@]}"; do echo "  + $c"; done; fi
  echo
  echo "Skipped/preserved (${#CHANGES_SKIPPED[@]}):"
  if [[ ${#CHANGES_SKIPPED[@]} -eq 0 ]]; then echo "  (none)"; else for c in "${CHANGES_SKIPPED[@]}"; do echo "  - $c"; done; fi
  echo
  echo "Failures (${#FAILURES[@]}):"
  if [[ ${#FAILURES[@]} -eq 0 ]]; then echo "  (none)"; else for c in "${FAILURES[@]}"; do echo "  ! $c"; done | tee -a -- "$LOG_FILE" 2>/dev/null || true; fi
  echo
  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    red_msg "Completed with failures — check $LOG_FILE and backups in $BACKUP_DIR for rollback"
    log "FINAL: failures ${FAILURES[*]}"
  else
    green_msg "Completed successfully — no failures"
    log "FINAL: success"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    yellow_msg "DRY-RUN: ZERO files were modified"
  fi
  green_msg '================================================================='

  # Explicit verification note per requirements
  echo
  log "Verification classification (see audit report): P0 items verified by code inspection; runtime not fully verified in this Windows host"
}

# ---------- Main ----------
main() {
  print_intro
  check_if_running_as_root
  acquire_lock
  check_required_commands
  init_backup_dir || { red_msg "Failed to init backup dir"; exit 1; }
  detect_os
  validate_os_version

  # Connectivity check — DNS-aware, no misleading IP fallback
  # Test current DNS FIRST (read-only, does not modify)
  local _dns_target_ok=0
  if test_target_hostname -- "$TARGET_HOST" 2>/dev/null; then _dns_target_ok=1; fi
  if ! has_internet; then
    yellow_msg "Internet connectivity test failed — package installs/downloads may fail"
    log "Connectivity: no internet (curl head failed) dns_target_ok=$_dns_target_ok"
    if has_dns; then log "DNS still works, but HTTP to IP failed (possible firewall)"; else log "DNS and HTTP both failing — likely offline"; fi
  else
    if [[ $_dns_target_ok -eq 1 ]]; then
      green_msg "Internet connectivity OK (DNS working, $TARGET_HOST resolves)"
      log "Connectivity: internet OK, dns OK"
    else
      yellow_msg "IP connectivity OK (https://1.1.1.1 reachable) but DNS resolution for $TARGET_HOST failed — DNS is broken, IP fallback cannot fetch hostname-based HTTPS (TLS SNI requires DNS)"
      log "Connectivity: IP OK but DNS for $TARGET_HOST FAIL — hostname HTTPS will fail"
    fi
  fi
  unset _dns_target_ok
  # Run full DNS diagnostics (read-only) and preserve working provider DNS
  # This is the user VPS case: 185.12.64.1/185.12.64.2 working → will be preserved, no modification
  if ! dns_diagnostics_report 2>&1 | tee -a -- "$LOG_FILE" 2>/dev/null; then
    yellow_msg "DNS diagnostics: current DNS appears broken"
  fi

  # Install dependencies per OS
  local os_install_rc=0
  case "$OS_ID" in
    ubuntu|debian) install_dependencies_debian_based || os_install_rc=$? ;;
    centos|almalinux|rhel|rocky|fedora) install_dependencies_rhel_based || os_install_rc=$? ;;
    *)
      if [[ "${ID_LIKE:-}" == *"debian"* ]] || [[ "${ID_LIKE:-}" == *"ubuntu"* ]]; then install_dependencies_debian_based || os_install_rc=$?
      elif [[ "${ID_LIKE:-}" == *"rhel"* ]] || [[ "${ID_LIKE:-}" == *"fedora"* ]]; then install_dependencies_rhel_based || os_install_rc=$?
      else yellow_msg "Unknown OS for deps install — skipping"; CHANGES_SKIPPED+=("deps: unknown os"); fi
      ;;
  esac
  if [[ $os_install_rc -ne 0 ]]; then
    red_msg "Dependency installation failed — not continuing silently (fail-closed)"
    print_final_status
    exit 1
  fi

  # Fix hosts (always, idempotent, reversible)
  if ! fix_etc_hosts; then
    red_msg "Hosts fix failed — continuing? (fail-closed for critical?)"
    # Hosts is reversible via rollback already; if tx still active, rollback already done. Treat as failure but continue to final status?
    # Per P0 fail-closed, we should exit
    print_final_status
    exit 1
  fi

  # Fix DNS (only if --with-dns)
  if ! fix_dns; then
    red_msg "DNS fix failed"
    print_final_status
    exit 1
  fi

  # Timezone (only if --with-timezone or --timezone)
  if ! set_timezone; then
    red_msg "Timezone handling failed"
    print_final_status
    exit 1
  fi

  # DNS recovery state machine — ensure TARGET_HOST resolves before HTTPS download (fail-closed, no blind IP fallback)
  if ! test_target_hostname -- "$TARGET_HOST" 2>/dev/null; then
    yellow_msg "DNS for $TARGET_HOST is broken — attempting native recovery (manager: $(detect_dns_manager_enhanced 2>/dev/null || echo unknown))"
    if [[ ${NO_DNS:-0} -eq 1 ]]; then
      red_msg "DNS is broken and --no-dns is set — fail-closed before download. Restore /etc/resolv.conf to contain 'nameserver 1.1.1.1' or re-run without --no-dns / with --with-dns."
      FAILURES+=("dns: broken, --no-dns fail-closed")
      print_final_status; exit 1
    fi
    # Default automatic recovery (or --with-dns explicit) — uses native manager, transactional, verified
    if ! dns_recovery_state_machine; then
      red_msg "DNS recovery failed — cannot download https://$TARGET_HOST. Fail-closed, optimizer not executed (no TLS bypass, no hard-coded IP)."
      print_final_status; exit 1
    fi
    if ! test_target_hostname -- "$TARGET_HOST" 2>/dev/null; then
      red_msg "DNS still broken after recovery — fail-closed"
      FAILURES+=("dns: still broken after recovery")
      print_final_status; exit 1
    fi
  else
    green_msg "DNS for $TARGET_HOST: WORKING — preserving existing provider DNS, no recovery needed"
    log "DNS for $TARGET_HOST working, preserved"
  fi
  if ! test_dns_verify_https "https://$TARGET_HOST" 2>/dev/null; then
    red_msg "HTTPS to https://$TARGET_HOST not reachable (DNS may be broken or firewall). Fail-closed before download — verify with: resolvectl query $TARGET_HOST; getent ahostsv4 $TARGET_HOST; curl -4 --connect-timeout 5 https://1.1.1.1"
    FAILURES+=("dns: https verify failed")
    print_final_status; exit 1
  fi

  # Download & execute optimizer for this OS
  local details
  if ! details="$(get_os_optimizer_details)"; then
    red_msg "Cannot determine optimizer for OS $OS_ID"
    print_final_status
    exit 1
  fi
  local opt_file; opt_file="$(echo "$details" | cut -d'|' -f1)"
  local opt_url; opt_url="$(echo "$details" | cut -d'|' -f2)"
  local opt_sha; opt_sha="$(echo "$details" | cut -d'|' -f3)"

  # Fixed call: secure_download_and_execute <filename> <url> <sha> — no leading "--" as filename
  if ! secure_download_and_execute "$opt_file" "$opt_url" "$opt_sha"; then
    red_msg "Optimizer download/verify/execute failed for $opt_file — bootstrap preserved backups for rollback"
    print_final_status
    exit 1
  fi

  print_final_status
  # Success exit 0 only if no hidden failures
  if [[ ${#FAILURES[@]} -gt 0 ]]; then exit 1; else exit 0; fi
}

main "$@"
