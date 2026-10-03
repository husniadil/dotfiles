#!/bin/bash
# Bootstrap an exe.dev VM (Ubuntu) with these dotfiles.
#
#   bash exe.sh [--apply] [repo]
#
# Without --apply it installs the tools, initializes chezmoi and shows what
# would change, so a VM that already has its own files can be reviewed first.
# repo defaults to the GitHub repository; a path to a git bundle works too.
set -euo pipefail

apply=0
if [ "${1:-}" = "--apply" ]; then
  apply=1
  shift
fi
repo="${1:-https://github.com/husniadil/dotfiles.git}"
export PATH="$HOME/.local/bin:$PATH"

if ! command -v zsh >/dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh
fi
command -v chezmoi >/dev/null || sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" -t v2.73.0
command -v mise >/dev/null || curl -fsSL https://mise.run | MISE_VERSION=v2026.9.18 sh

# What the media skills run (analyzing-video, transcribe-audio,
# youtube-transcript). System-wide, since a sandboxed agent cannot read ~/.
if ! command -v ffmpeg >/dev/null || ! command -v pipx >/dev/null || ! command -v unzip >/dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg pipx unzip
fi
command -v yt-dlp >/dev/null || sudo PIPX_HOME=/usr/local/pipx PIPX_BIN_DIR=/usr/local/bin pipx install yt-dlp
if ! command -v deno >/dev/null; then
  # deno 2.9.6, x86_64 Linux. yt-dlp solves YouTube's JS challenge with it.
  deno_digest=394f07f4da2bebe6ce6f1e7ce0fa16429b29b08c35e3fac3fe25972676dff4b2
  work="$(mktemp -d)"
  curl -fsSL -o "$work/deno.zip" https://github.com/denoland/deno/releases/download/v2.9.6/deno-x86_64-unknown-linux-gnu.zip
  echo "$deno_digest  $work/deno.zip" | sha256sum -c --quiet -
  unzip -q "$work/deno.zip" -d "$work"
  sudo install -m 0755 "$work/deno" /usr/local/bin/deno
  rm -rf "$work"
fi

if [ ! -d "$HOME/.local/share/chezmoi/.git" ]; then
  chezmoi init "$repo"
else
  chezmoi git pull -- --ff-only
fi
if [ ! -f "$(chezmoi source-path)/.chezmoi.toml.tmpl" ]; then
  echo "chezmoi source at $(chezmoi source-path) is empty; the clone did not check out a branch" >&2
  exit 1
fi

if [ "$apply" -eq 0 ]; then
  echo "Files chezmoi would add (A) or modify (M):"
  chezmoi status
  echo "Review with 'chezmoi diff', then run this script again with --apply."
  exit 0
fi

chezmoi apply
zsh_path="$(command -v zsh)"
if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$zsh_path" ]; then
  sudo chsh -s "$zsh_path" "$USER"
fi
echo "Done. Log in again to start zsh."
