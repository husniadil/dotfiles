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

# Tailscale, which ~/.claude/hooks/tailscale-up.sh joins the session to the
# tailnet with. pkgs.tailscale.com answers here where GitHub releases do not.
# 1.102.4, the amd64 static tarball, pinned by the digest it publishes.
if ! command -v tailscaled >/dev/null; then
  tailscale_digest=50748df1045e60b5b695f19f4c56b0da36c019948b440fb456b6584a50f0d8b9
  work="$(mktemp -d)"
  curl -fsSL -o "$work/tailscale.tgz" https://pkgs.tailscale.com/stable/tailscale_1.102.4_amd64.tgz
  echo "$tailscale_digest  $work/tailscale.tgz" | sha256sum -c --quiet -
  tar -xzf "$work/tailscale.tgz" -C "$work" --strip-components=1
  install -m 0755 "$work/tailscale" "$work/tailscaled" /usr/local/bin/
  rm -rf "$work"
fi

# zstd, which ~/.claude/hooks/agamemnon-serve.sh unpacks Agamemnon's package
# with.
if ! command -v zstd >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zstd
fi

# socat, which ~/.claude/hooks/tailscale-up.sh forwards claude-mem's worker
# port with.
if ! command -v socat >/dev/null; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq socat
fi

CHEZMOI_MACHINE=cloud chezmoi init "$repo"
if [ -n "${DOTFILES_REF:-}" ]; then
  chezmoi git -- checkout --quiet "$DOTFILES_REF"
  # The config was rendered from the default branch's template, so it is
  # rendered again from the ref's.
  CHEZMOI_MACHINE=cloud chezmoi init
fi
chezmoi apply
echo "dotfiles at $(chezmoi git -- rev-parse --short HEAD) applied for $(chezmoi data --format json | jq -r .machine)"

# claude-mem, the fork build the Mac runs (husniadil/claude-mem, husni/main),
# against the worker on proxenos. A cloud session loads no plugin installed on
# the Mac, so it is installed here. The worker is reached through the
# forwarder that ~/.claude/hooks/tailscale-up.sh starts on 127.0.0.1:37701,
# and WORKER_AUTOSTART=false keeps the hooks from starting a worker of their
# own when it does not answer.
# A container that already has the plugin is updated to husni/main as well: a
# cloud session on an older build than the worker's can lose what it captures,
# as 13.39.2 did, so an update that fails fails the session.
plugins="$HOME/.claude/plugins"
fork=https://github.com/husniadil/claude-mem.git
# Checked by its source, since a marketplace of the same name from anywhere
# else (upstream's) updates to that source and never to husni/main.
if jq -e --arg fork "$fork" '.thedotmack.source | .url == $fork and .ref == "husni/main"' \
  "$plugins/known_marketplaces.json" >/dev/null 2>&1; then
  claude plugin marketplace update thedotmack
else
  if jq -e '.thedotmack' "$plugins/known_marketplaces.json" >/dev/null 2>&1; then
    claude plugin marketplace remove thedotmack
  fi
  claude plugin marketplace add "$fork#husni/main"
fi
if ! jq -e '.plugins["claude-mem@thedotmack"]' "$plugins/installed_plugins.json" >/dev/null 2>&1; then
  claude plugin install claude-mem@thedotmack
else
  claude plugin update claude-mem@thedotmack
fi
mkdir -p "$HOME/.claude-mem"
cat >"$HOME/.claude-mem/settings.json" <<'EOF'
{
  "CLAUDE_MEM_WORKER_HOST": "127.0.0.1",
  "CLAUDE_MEM_WORKER_PORT": "37701",
  "CLAUDE_MEM_WORKER_AUTOSTART": "false",
  "CLAUDE_MEM_MODE": "code"
}
EOF
