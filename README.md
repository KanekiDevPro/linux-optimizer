Linux Optimizer
This Bash script automates the optimization of your Linux server.
Notes:
This script is designed for execution on Linux server environments, including VPS, VDS, Dedicated, and Bare Metal systems. It is not recommended for use on Linux desktop environments.
Modifying the kernel (options 1 and 2) may result in removing or resetting some GPU drivers.
Some VMs do not support kernel changes (options 1 and 2). Installing XanMod could cause the VM to break. Please be cautious and test beforehand.
It performs the following tasks:
Fix hosts file and DNS (temporarily):

Check and add 127.0.1.1 and server hostname to /etc/hosts.
Original hosts file is backed up at /etc/hosts.bak.

Add Cloudflare-Security DNS servers (1.1.1.2, 1.0.0.2) nameservers to /etc/resolv.conf.
Original dns file is backed up at /etc/resolv.conf.bak.

Update, Upgrade, and Clean the server:

Update
Upgrade
Full-Upgrade
AutoRemove
AutoClean
Clean
Disable Terminal Ads (Only on Ubuntu).

Install XanMod Kernel (Only on Ubuntu & Debian):

Enable BBRv3.
CloudFlare TCP Optimizations.
More Details: https://xanmod.org
Install Useful Packages:

apt-transport-https apt-utils autoconf automake bash-completion bc binutils binutils-common binutils-x86-64-linux-gnu build-essential busybox ca-certificates cron curl dialog epel-release gnupg2 git haveged htop jq keyring libssl-dev libsqlite3-dev libtool locales lsb-release make nano net-tools packagekit preload python3 python3-pip qrencode socat screen software-properties-common ufw unzip vim wget zip

Enable Packages at Server Boot.

Set the server TimeZone to the VPS IP address location.

Create & Enable SWAP File:

Swap Path: "/swapfile"
Swap Size: 2Gb
Optimize the SYSCTL Configs:

Optimize File System Settings.
Optimize Network Core Settings.
Optimize SWAP.
Optimize TCP and UDP Settings.
Optimize UNIX Domain Sockets Settings.
Optimize Virtual memory (VM) Settings.
Optimize Network Configuration Settings.
Optimize the Kernel.
Activate BBR (BBRv3 with XanMod).
Original file is backed up at /etc/sysctl.conf.bak.

Optimize SSH:

Disable DNS lookups for connecting clients.
Remove less efficient encryption ciphers.
Enable and Configure TCP keep-alive messages.
Allow TCP forwarding.
Enable gateway ports, Tunneling and compression.
Enable X11 Forwarding.
Original file is backed up at /etc/ssh/sshd_config.bak.

Optimize the System Limits:

Soft and Hard ulimit -c -d -f -i -l -n -q -s -u -v -x optimizations.
Optimize UFW and open Common Ports:

Open Ports SSH, 80, 443.
With IPv6, TCP & UDP.
Reboot at the end is recommended.

Prerequisites
Ensure that the sudo and wget packages are installed on your system:
Ubuntu & Debian:
sudo apt update -q && sudo apt install -y sudo wget
CentOS & Fedora:
sudo dnf up -y && sudo dnf install -y sudo wget
Run
Tested on: Ubuntu 20+, Debian 11+, CentOS Stream 8+, AlmaLinux 8+, Fedora 37+
Root Access is Required. If the user is not root, first run:
sudo -i
Then:
wget "https://raw.githubusercontent.com/KanekiDevPro/Linux-Optimizer/main/linux-optimizer.sh" -O linux-optimizer.sh && chmod +x linux-optimizer.sh && bash linux-optimizer.sh 
Menu Image
Debian & Ubuntu:
debian-based-menu

CentOS, AlmaLinux & Fedora:
rhel-based-menu

Disclaimer
This script is provided as-is, without any warranty or guarantee. Use it at your own risk.

License
This script is licensed under the MIT License.
