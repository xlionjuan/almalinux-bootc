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

dnf install -y screen qemu-guest-agent vim htop wget tree git tailscale systemd-resolved ncdu

systemctl enable tailscaled
systemctl enable systemd-resolved

# Inject files
# ZRAM
mkdir -p /usr/local/lib/systemd/
echo '[zram0]
zram-fraction = 1.0
compression-algorithm = zstd' | tee /usr/local/lib/systemd/zram-generator.conf

# Tailscale
echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.d/99-tailscale.conf

# ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
