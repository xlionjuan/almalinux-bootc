#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd docker

systemctl enable docker
