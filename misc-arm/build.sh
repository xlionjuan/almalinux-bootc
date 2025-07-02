#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

dnf group -y install 'Development Tools'
ln -sf /usr/bin/dnf /usr/bin/yum
curl -s https://install.crowdsec.net | sh

dnf -y install crowdsec-firewall-bouncer-nftables
