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
