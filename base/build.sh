#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

# https://github.com/blue-build/modules/blob/bc0cfd7381680dc8d4c60f551980c517abd7b71f/modules/rpm-ostree/rpm-ostree.sh#L16
echo "Creating symlinks to fix packages that install to /opt"
# Create symlink for /opt to /var/opt since it is not created in the image yet
mkdir -p "/var/opt"
ln -s "/var/opt" "/opt"

# Force full update
#dnf -y upgrade

dnf -y install 'dnf-command(config-manager)'
ln -sf /usr/bin/dnf /usr/bin/yum
curl -s https://install.crowdsec.net | sh

dnf config-manager --enable crb
dnf config-manager --add-repo https://pkgs.tailscale.com/stable/centos/10/tailscale.repo
dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
dnf -y upgrade

dnf -y install crowdsec-firewall-bouncer-nftables
dnf -y install screen tmux setroubleshoot audit fail2ban qemu-guest-agent wireguard-tools vim htop wget tree zsh git tailscale systemd-resolved ncdu

dnf -y install tcpdump wireshark-cli

# Don't enable Tailscale by default since it is not used on every node
# systemctl enable tailscaled

# Inject files
## ZRAM
mkdir -p /usr/local/lib/systemd/resolved.conf.d
echo '[zram0]
zram-size = ram
compression-algorithm = zstd' | tee /usr/local/lib/systemd/zram-generator.conf
## Resolved
echo '[Resolve]
DNSSEC=true
DNSOverTLS=opportunistic
FallbackDNS=9.9.9.9#dns.quad9.net
FallbackDNS=149.112.112.112#dns.quad9.net
FallbackDNS=2620:fe::fe#dns.quad9.net
FallbackDNS=2620:fe::9#dns.quad9.net
' | tee /usr/local/lib/systemd/resolved.conf.d/default-resolved-settings.conf

# KVM PTP setup
echo "ptp_kvm" | tee /usr/lib/modules-load.d/ptp_kvm.conf

# journalctl

mkdir -p /usr/local/lib/systemd/journald.conf.d
echo '[Journal]
SystemMaxUse=50M
' | tee /usr/local/lib/systemd/journald.conf.d/00-journal-size.conf

# Sysctl.d
mkdir -p /usr/local/lib/sysctl.d

## Kernel hardening (40-*: universal base — safe for all production servers)
tee /usr/local/lib/sysctl.d/40-kernel-hardening.conf <<'EOF'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
# Restrict perf events to root only — prevent side-channel observation
kernel.perf_event_paranoid = 3
# Disable Magic SysRq — prevent console-level kernel commands
kernel.sysrq = 0
# Disable kexec — prevent loading a replacement kernel at runtime
kernel.kexec_load_disabled = 1
# No core dumps for setuid programs — avoid sensitive memory leak
fs.suid_dumpable = 0
EOF

## Network security (50-*: anti-spoofing, redirect protection, queue tuning)
tee /usr/local/lib/sysctl.d/50-network-security.conf <<'EOF'
# Loose reverse path filtering — safe for multi-homing / VPN / Tailscale
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Disable ICMP redirects (both accept and send)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# TCP connection queue
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
EOF

## VM memory (50-*: ZRAM, overcommit, dirty page tuning)
printf '%s\n' \
    'vm.swappiness = 180' \
    'vm.overcommit_memory = 1' \
    'vm.dirty_background_ratio = 5' |
    tee /usr/local/lib/sysctl.d/50-vm-memory.conf

rm -f /usr/local/lib/sysctl.d/50-zram.conf

## Routing (60-*: only for Tailscale subnet router / exit node / VM host)
printf '%s\n' \
    'net.ipv4.ip_forward = 1' \
    'net.ipv6.conf.all.forwarding = 1' |
    tee /usr/local/lib/sysctl.d/60-routing.conf

## BBR with proper pacing (60-*)
printf '%s\n' \
    'net.core.default_qdisc = fq' \
    'net.ipv4.tcp_congestion_control = bbr' |
    tee /usr/local/lib/sysctl.d/60-bbr.conf

## Network optimization (70-*: socket buffer tuning)
tee /usr/local/lib/sysctl.d/70-net-optimize.conf <<'EOF'
# Global socket buffer (default and max receive/send buffer size for all sockets)
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 4194304

# TCP auto-tuning buffer limits (min, default, max)
net.ipv4.tcp_rmem = 4096 131072 4194304
net.ipv4.tcp_wmem = 4096 131072 4194304

# UDP minimum buffer size (per UDP socket)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Network device packet backlog queue
net.core.netdev_max_backlog = 8192

# PMTU probing for VPN/tunnel path MTU issues
net.ipv4.tcp_mtu_probing = 1
# ECN — passive accept (environment verified compatible)
net.ipv4.tcp_ecn = 1
# TFO — client+server (Caddy + AdGuard both benefit, TLS replay-safe)
net.ipv4.tcp_fastopen = 3
# RFC 1337 — prevent TIME-WAIT assassination
net.ipv4.tcp_rfc1337 = 1

# TCP keepalive — faster dead connection detection
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# Disable slow start after idle — better burst traffic with BBR
net.ipv4.tcp_slow_start_after_idle = 0

# Socket ancillary data memory
net.core.optmem_max = 262144
EOF

# Fail2ban SSH

restorecon -v /var/lib/fail2ban/fail2ban.sqlite3

rm -f /etc/fail2ban/jail.d/00-firewalld.conf

tee /etc/fail2ban/jail.d/00-use-nftables.conf <<EOF
[DEFAULT]
banaction = nftables-multiport
EOF

tee /etc/fail2ban/jail.d/50-sshd-preset.conf <<EOF
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
tee /usr/lib/systemd/system/brew-upgrade.service <<EOF
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

tee /usr/lib/systemd/system/brew-upgrade.timer <<EOF
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

# NetworkManager
## IPv6 tempaddr
cat >/usr/lib/NetworkManager/conf.d/50-ipv6-tempaddr.conf <<'EOF'
[connection]
ipv6.ip6-privacy=2
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
