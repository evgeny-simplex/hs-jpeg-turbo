#!/usr/bin/env bash

set -euo pipefail

nix_ver=nix-2.22.0
nix_hash=4fed7db867186c01ce2a2077da4a6950ed16232efbf78d0cd19700cff80559f9
tmp=$(mktemp -d)
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/install" "https://releases.nixos.org/nix/$nix_ver/install"
echo "$nix_hash  $tmp/install" | shasum -a 256 -c
cat > "$tmp/nix.conf" <<EOF
max-jobs = auto
cores = 0
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://cache.zw3rk.com https://cache.iog.io
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= loony-tools:pr9m4BkM/5/eSTZlkQyRt57Jz7OMBxNSUiMC4FkcNfk= hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=
EOF
if [ "$(uname)" = Darwin ]; then
  echo "Users with UIDs from 300 to 399:"
  dscl . -list /Users UniqueID | awk '$2 >= 300 && $2 < 400'
  NIX_FIRST_BUILD_UID=351 sh "$tmp/install" --daemon --yes --nix-extra-conf-file "$tmp/nix.conf"
  echo /nix/var/nix/profiles/default/bin >> "$GITHUB_PATH"
else
  sudo mkdir -p /nix
  sudo chown "$USER" /nix
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  mkdir -p ~/.config/nix
  cp "$tmp/nix.conf" ~/.config/nix/nix.conf
  echo "sandbox = true" >> ~/.config/nix/nix.conf
  sh "$tmp/install" --no-daemon
  echo "$HOME/.nix-profile/bin" >> "$GITHUB_PATH"
fi
