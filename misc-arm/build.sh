#!/bin/bash

set -ouex pipefail

RELEASE="$(rpm -E %almalinux)"

dnf group -y install 'Development Tools'

dnf -y install conntrack-tools

# resticprofile
curl -LO https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh
chmod +x install.sh
./install.sh -b /usr/local/bin

# restic
RESTIC_RELEASE_DATA=$(curl --retry 12 --retry-all-errors -s "https://api.github.com/repos/restic/restic/releases/latest")
wait
if ! echo "$RESTIC_RELEASE_DATA" | jq -e '.assets[]? | select(.browser_download_url? != null)' > /dev/null; then
    echo "'browser_download_url' not found in release data. Please check the repository/tag name or API response."
    exit 1
fi
RESTIC_PACK_URL=$(echo "$RESTIC_RELEASE_DATA" | jq -r '.assets[] | select(.name | contains("linux_arm64") and endswith(".bz2")) | .browser_download_url' | head -n 1)
wget "$RESTIC_PACK_URL"
bunzip2 *.bz2
mv restic* /usr/local/bin/restic
chmod +x /usr/local/bin/restic
