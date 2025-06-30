#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

# https://github.com/blue-build/modules/blob/bc0cfd7381680dc8d4c60f551980c517abd7b71f/modules/rpm-ostree/rpm-ostree.sh#L16
echo "Creating symlinks to fix packages that install to /opt"
# Create symlink for /opt to /var/opt since it is not created in the image yet
mkdir -p "/var/opt"
ln -s "/var/opt"  "/opt"

dnf install -y 'dnf-command(config-manager)'

dnf config-manager --enable crb
dnf config-manager --add-repo https://pkgs.tailscale.com/stable/centos/10/tailscale.repo
dnf install -y https://dl.fedoraproject.org/pub/epel/10/Everything/x86_64/Packages/e/epel-release-10-6.el10_0.noarch.rpm
dnf upgrade -y

dnf install -y screen qemu-guest-agent wireguard-tools vim htop wget tree zsh git tailscale systemd-resolved ncdu

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
cat >/usr/lib/tmpfiles.d/cayo-resolved.conf <<'EOF'
L /etc/resolv.conf - - - - ../run/systemd/resolve/stub-resolv.conf
EOF

cat >/usr/lib/systemd/system-preset/99-homebrew-autoupdate.preset <<'EOF'
enable brew-upgrade.timer
EOF

systemctl preset brew-upgrade.timer

# Fix
systemctl disable rpm-ostree-countme.timer
