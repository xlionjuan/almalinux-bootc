#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

# https://github.com/blue-build/modules/blob/bc0cfd7381680dc8d4c60f551980c517abd7b71f/modules/rpm-ostree/rpm-ostree.sh#L16
echo "Creating symlinks to fix packages that install to /opt"
# Create symlink for /opt to /var/opt since it is not created in the image yet
mkdir -p "/var/opt"
ln -s "/var/opt"  "/opt"

dnf -y install 'dnf-command(config-manager)'
ln -sf /usr/bin/dnf /usr/bin/yum
curl -s https://install.crowdsec.net | sh

dnf config-manager --enable crb
dnf config-manager --add-repo https://pkgs.tailscale.com/stable/centos/10/tailscale.repo
dnf -y install https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/Packages/e/epel-release-10-6.el10_0.noarch.rpm
dnf -y upgrade

dnf -y install crowdsec-firewall-bouncer-nftables
dnf -y install screen setroubleshoot audit fail2ban qemu-guest-agent wireguard-tools vim htop wget tree zsh git tailscale systemd-resolved ncdu

# Don't enable Tailscale by default since it is not used on every node
# systemctl enable tailscaled

# Inject files
# ZRAM
mkdir -p /usr/local/lib/systemd/
echo '[zram0]
zram-fraction = 1.0
compression-algorithm = zstd' | tee /usr/local/lib/systemd/zram-generator.conf

# KVM PTP setup
echo "ptp_kvm" | tee /etc/modules-load.d/ptp_kvm.conf

# Sysctl.d
## Tailscale
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf

## ZRAM Related
echo 'vm.swappiness=180' | tee -a /etc/sysctl.d/99-zram.conf
echo 'vm.overcommit_memory = 1' | tee -a /etc/sysctl.d/99-zram.conf

## BBR
echo 'net.core.default_qdisc=fq_codel' | tee -a /etc/sysctl.d/99-bbr-network.conf
echo 'net.ipv4.tcp_congestion_control=bbr' | tee -a /etc/sysctl.d/99-bbr-network.conf

tee /etc/sysctl.d/99-net-opti.conf << EOF
# Global socket buffer (default and max receive/send buffer size for all sockets)
net.core.rmem_default = 524288         # Default receive buffer: 512 KB
net.core.rmem_max = 16777216           # Max receive buffer: 16 MB
net.core.wmem_default = 524288         # Default send buffer: 512 KB
net.core.wmem_max = 16777216           # Max send buffer: 16 MB

# TCP auto-tuning buffer limits (min, default, max)
net.ipv4.tcp_rmem = 8192 262144 16777216    # TCP receive buffer: 8 KB / 256 KB / 16 MB
net.ipv4.tcp_wmem = 8192 262144 16777216    # TCP send buffer: 8 KB / 256 KB / 16 MB

# UDP minimum buffer size (per UDP socket)
net.ipv4.udp_rmem_min = 16384          # Minimum UDP receive buffer: 16 KB (was 8 KB)
net.ipv4.udp_wmem_min = 16384          # Minimum UDP send buffer: 16 KB (was 8 KB)

# Network device packet backlog queue
net.core.netdev_max_backlog = 8192     # Max number of packets allowed in the backlog queue (was 1024)
EOF

# Fail2ban SSH

restorecon -v /var/lib/fail2ban/fail2ban.sqlite3

rm -f /etc/fail2ban/jail.d/00-firewalld.conf

tee /etc/fail2ban/jail.d/00-use-nftables.conf  << EOF
[DEFAULT]
banaction = nftables-multiport
EOF

tee /etc/fail2ban/jail.d/50-sshd-preset.conf  << EOF
[sshd]
enabled = true

bantime = 7d
bantime.increment = true
bantime.maxtime = 365d
 
findtime = 1d
	 
maxretry = 3
EOF

# Unit
## Homebrew
tee /usr/lib/systemd/system/brew-upgrade.service << EOF
[Unit]
Description=Upgrade Brew packages
After=local-fs.target
After=network-online.target
ConditionPathIsSymbolicLink=/home/linuxbrew/.linuxbrew/bin/brew

[Service]
# Override the user if different UID/User
User=1000
Type=oneshot
Environment=HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar
Environment=HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
Environment=HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
ExecStart=/usr/bin/bash -c "/home/linuxbrew/.linuxbrew/bin/brew upgrade"
EOF

tee /usr/lib/systemd/system/brew-upgrade.timer << EOF
[Unit]
Description=Timer for brew upgrade for on image brew
Wants=network-online.target

[Timer]
OnBootSec=30min
OnUnitInactiveSec=8h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# system-preset
## systemd-resolved 
## https://github.com/ublue-os/cayo/pull/90
## /*
## Ensure systemd-resolved is enabled
## If don't want, sudo touch /etc/tmpfiles.d/cayo-resolved.conf
## */
cat >/usr/lib/systemd/system-preset/91-cayo-resolved.preset <<'EOF'
enable systemd-resolved.service
EOF
systemctl preset systemd-resolved.service
## Link
cat >/usr/lib/tmpfiles.d/cayo-resolved.conf <<'EOF'
L /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf
EOF

cat >/usr/lib/systemd/system-preset/91-homebrew-autoupdate.preset <<'EOF'
enable brew-upgrade.timer
EOF

cat >/usr/lib/systemd/system-preset/91-fail2ban.preset <<'EOF'
enable fail2ban.service
EOF

cat >/usr/lib/systemd/system-preset/10-no-firewalld.preset <<'EOF'
disable firewalld.service
EOF

systemctl preset brew-upgrade.timer
systemctl preset fail2ban.service
systemctl preset firewalld.service

# Fix
systemctl disable rpm-ostree-countme.timer

mkdir -p /var/lib/setroubleshoot
chown setroubleshoot:setroubleshoot /var/lib/setroubleshoot
chmod 700 /var/lib/setroubleshoot
tee /usr/lib/tmpfiles.d/50-fail2ban-selinux.conf <<'EOF'
d /var/lib/fail2ban 0750 root root -
C /var/lib/fail2ban/fail2ban.sqlite3 0600 root root -
Z /var/lib/fail2ban/fail2ban.sqlite3 0600 root root -
EOF

