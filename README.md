# Linux-Optimizer

A robust, idempotent system optimizer script for Debian/Ubuntu servers with a focus on VPN performance, stability, and security.

This script safely applies a set of best-practice system tweaks:
- System updates and cleanup
- Useful package installation
- Swap file creation
- Network (sysctl) tuning with selectable profiles
- SSH hardening
- System limits optimization
- UFW firewall setup (TCP-only)

> **Note:** This tool does **not** create tunnels. It prepares the server for high-performance VPN workloads (WireGuard, OpenVPN, etc.) by optimizing kernel parameters and system settings.

---

## Features

- ✅ **Idempotent** – Safe to run multiple times without duplicating entries or breaking configuration.
- 🧠 **Profile-based sysctl tuning** – Choose from 5 profiles tailored to different use cases.
- ⚡ **Automatic detection** – Auto profile selects the best settings based on RAM, CPU cores, and link speed.
- 🔒 **SSH hardening** – Reasonable keepalive values and secure defaults (no risky forwarding).
- 🛡️ **UFW firewall** – Opens only necessary TCP ports (SSH, 80, 443); UDP rules removed.
- 💾 **Swap creation** – Creates and mounts a 2G swap file with filesystem-aware checks.
- 📦 **Package installation** – Installs useful packages individually, so a missing package won’t abort the whole process.
- 🔁 **Single APT update** – Centralised guard ensures only one `apt update` per run (even in Option 1).
- 🧹 **Legacy cleanup** – Removes old optimizer entries from `/etc/sysctl.conf` and `/etc/profile` without touching user customizations.

---

## Requirements

- **Operating System:** Debian or Ubuntu (including derivatives).
- **Privileges:** Must be run as `root` (or with `sudo`).
- **Shell:** Bash.
- **Network:** Internet access for package installation and updates.

> ⚠️ The script should be run on a fresh or minimal server. Always test in a non‑production environment first.

---

## Installation

1. Download the script:
   ```bash
   wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/linux-optimizer.sh" -O linux-optimizer.sh && chmod +x linux-optimizer.sh && bash linux-optimizer.sh


What the Script Does

1. System Update & Cleanup
Runs apt update, apt upgrade, apt full-upgrade, apt autoremove, apt autoclean, and apt clean.

Only one apt update is performed per script run (central flag).

2. Package Installation
Installs a set of useful packages (networking, system utilities, development tools, etc.).

Packages are installed individually, so failure of one does not affect the rest.

Enables essential services (cron, haveged, preload) if they exist.

3. Swap Creation
Creates a 2GB swap file at /swapfile.

Checks existing swap, filesystem support, and available disk space.

Adds entry to /etc/fstab only if not already present.

4. Network Optimization (sysctl)
Detects BBR support and uses it if available; otherwise falls back to cubic.

Detects fq qdisc support and uses it; otherwise falls back to fq_codel.

Applies RAM‑aware TCP/UDP memory settings to avoid excessive memory usage on small VPS.

Writes all settings to /etc/sysctl.d/99-optimizer.conf (overwrites cleanly).

Cleans up any old optimizer entries from /etc/sysctl.conf without touching user comments.

Reports any unsupported sysctl keys.

5. SSH Hardening
Sets reasonable keepalive values (ClientAliveInterval 300, ClientAliveCountMax 3).

Disables risky forwarding/tunneling options by default (AllowTcpForwarding no, GatewayPorts no, PermitTunnel no, X11Forwarding no).

Validates the SSH configuration with sshd -t before restarting the service.

6. System Limits
Creates /etc/security/limits.d/99-optimizer.conf with high file descriptor and process limits.

Also sets DefaultLimitNOFILE, DefaultLimitNPROC, and DefaultLimitMEMLOCK in systemd configuration.

Removes only old optimizer‑added ulimit lines from /etc/profile, preserving user custom entries.

7. UFW Firewall
Installs UFW if not present.

Removes any conflicting firewalld.

Opens only TCP ports: SSH (detected port), 80, and 443.

Deletes any UDP rules that may have been added by older versions.

Sets default policies: deny incoming, allow outgoing.

Enables UFW non‑interactively.

Safety & Backups
Before modifying critical files, the script creates timestamped backups:

/etc/sysctl.conf.bak.*

/etc/ssh/sshd_config.bak.*

/etc/fstab.bak.*

/etc/profile.bak.*

The script is designed to be idempotent: running it multiple times will not duplicate entries or corrupt settings.

If the script encounters a missing package or unsupported kernel parameter, it logs a warning and continues.

Verification
After running the script, you can verify the applied settings with:

bash
# Check congestion control (should be bbr or cubic)
sysctl net.ipv4.tcp_congestion_control

# Check qdisc
sysctl net.core.default_qdisc

# Check TCP/UDP memory
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
sysctl net.ipv4.udp_mem

# Check swap
swapon --show
free -h

# Check SSH settings
sudo sshd -T | grep -E 'clientaliveinterval|clientalivecountmax|allowtcpforwarding|gatewayports|permittunnel|x11forwarding'

# Check UFW status
sudo ufw status verbose
Disclaimer
This script modifies system configuration files and kernel parameters. While it aims to be safe and idempotent, use it at your own risk. Always test on a non‑production environment and keep backups. The author is not responsible for any data loss or system instability.
