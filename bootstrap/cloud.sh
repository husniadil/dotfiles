#!/bin/bash
# Bootstrap a Claude Code cloud session from the environment's setup script.
#
#   curl -fsSL https://raw.githubusercontent.com/husniadil/dotfiles/<sha>/bootstrap/cloud.sh | DOTFILES_REF=<sha> bash
#
# It runs as root before Claude Code starts. GitHub release downloads are
# blocked there, so chezmoi comes from its Homebrew bottle on ghcr.io, pinned
# by digest. The bottle's ELF interpreter is a Homebrew placeholder, so
# patchelf points it at the system loader. DOTFILES_REF pins the dotfiles to
# the same commit as this script.
set -euo pipefail

# chezmoi 2.73.0, x86_64_linux bottle
bottle_digest=18156ad7ff8f9c8c6246cb894d890795c1fcc2b1a5d98ee089798dbc4118e531
repo=https://github.com/husniadil/dotfiles.git

if ! command -v patchelf >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq patchelf
fi

work="$(mktemp -d)"
curl -fsSL -H 'Authorization: Bearer QQ==' -o "$work/chezmoi.tar.gz" \
  "https://ghcr.io/v2/homebrew/core/chezmoi/blobs/sha256:$bottle_digest"
echo "$bottle_digest  $work/chezmoi.tar.gz" | sha256sum -c --quiet -
tar -xzf "$work/chezmoi.tar.gz" -C "$work"
install -m 0755 "$(find "$work" -path '*/bin/chezmoi' -type f)" /usr/local/bin/chezmoi
patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 /usr/local/bin/chezmoi
rm -rf "$work"
chezmoi --version

# What the media skills run (analyzing-video, transcribe-audio,
# youtube-transcript). yt-dlp comes from PyPI and deno from npm, since
# GitHub release downloads are blocked here. deno 2.9.6 matches exe.sh.
if ! command -v ffmpeg >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg
fi
command -v yt-dlp >/dev/null || UV_TOOL_BIN_DIR=/usr/local/bin uv tool install --quiet yt-dlp
command -v deno >/dev/null || npm install -g --silent deno@2.9.6

CHEZMOI_MACHINE=cloud chezmoi init "$repo"
if [ -n "${DOTFILES_REF:-}" ]; then
  chezmoi git -- checkout --quiet "$DOTFILES_REF"
fi
chezmoi apply
echo "dotfiles at $(chezmoi git -- rev-parse --short HEAD) applied for $(chezmoi data --format json | jq -r .machine)"
