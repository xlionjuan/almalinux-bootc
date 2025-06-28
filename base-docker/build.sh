#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

tee /usr/lib/sysusers.d/docker.conf <<<'g docker - -'

systemctl enable docker
