#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

dnf group -y install 'Development Tools'
