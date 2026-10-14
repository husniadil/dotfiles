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

# Agamemnon's linux-x64 package, which ~/.claude/hooks/agamemnon-serve.sh
# serves from every session. It comes from the Agamemnon VM over the tailnet
# (the repository is private, and the GitHub proxy reaches a session's own
# repositories alone), at about 0.4 MB/s through the egress proxy's DERP
# relay: two to three minutes for its 63 MB (measured 2026-10-14). Fetched
# here, it is in the environment's cache and a new session serves within a
# minute. The hook fetches it itself when this did not run or finish, or when
# the VM has built another version since.
#
# A node of its own joins for the fetch, its state in a directory deleted
# before the snapshot is taken, and logs out after, which removes it, since
# the key's nodes are ephemeral. It runs beside the rest of the setup and is
# cut off at 200 s, so the setup stays inside the cache's five minutes.
agamemnon_prefetch=""
if [ -n "${TS_AUTHKEY:-}" ]; then
  timeout -k 10 200 bash -s >"$HOME/agamemnon-prefetch.log" 2>&1 <<'PREFETCH' &
set -euo pipefail
dir="$(mktemp -d)"
sock="$dir/tailscaled.sock"
pid=""
ts() { tailscale --socket="$sock" "$@"; }
finish() {
  ts logout >/dev/null 2>&1 || true
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  rm -rf "$dir"
}
trap finish EXIT
trap 'exit 1' TERM
tailscaled --tun=userspace-networking --statedir="$dir/state" --socket="$sock" \
  --socks5-server=127.0.0.1:1056 >"$dir/tailscaled.log" 2>&1 &
pid=$!
for _ in $(seq 50); do ts status >/dev/null 2>&1 && break; [ "$(ts status --json 2>/dev/null | jq -r '.BackendState // empty')" = NeedsLogin ] && break; sleep 0.2; done
ts up --auth-key="$TS_AUTHKEY" --hostname=claude-setup --timeout=90s
dist="https://agamemnon.$(ts status --json | jq -r .MagicDNSSuffix):8443"
fetch() { curl -fsS --retry 3 --retry-delay 2 -m 180 -x socks5h://127.0.0.1:1056 "$dist/$1"; }
version=$(fetch VERSION)
fetch agamemnon-linux-x64.tar.gz >"$dir/package.tar.gz"
echo "$(fetch agamemnon-linux-x64.tar.gz.sha256 | awk '{print $1}')  $dir/package.tar.gz" | sha256sum -c --quiet -
lib="$HOME/.local/lib/agamemnon"
rm -rf "$lib"
mkdir -p "$lib"
tar -C "$lib" -xzf "$dir/package.tar.gz"
echo "agamemnon $version in $lib"
PREFETCH
  agamemnon_prefetch=$!
else
  echo "agamemnon: no TS_AUTHKEY in the setup, so each session's hook fetches the package"
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
fi
chezmoi apply
echo "dotfiles at $(chezmoi git -- rev-parse --short HEAD) applied for $(chezmoi data --format json | jq -r .machine)"

# claude-mem, the fork build the Mac runs (husniadil/claude-mem, husni/main),
# against the worker on proxenos. A cloud session loads no plugin installed on
# the Mac, so it is installed here. The worker is reached through the
# forwarder that ~/.claude/hooks/tailscale-up.sh starts on 127.0.0.1:37701,
# and WORKER_AUTOSTART=false keeps the hooks from starting a worker of their
# own when it does not answer.
plugins="$HOME/.claude/plugins"
if ! jq -e '.thedotmack' "$plugins/known_marketplaces.json" >/dev/null 2>&1; then
  claude plugin marketplace add https://github.com/husniadil/claude-mem.git#husni/main
fi
if ! jq -e '.plugins["claude-mem@thedotmack"]' "$plugins/installed_plugins.json" >/dev/null 2>&1; then
  claude plugin install claude-mem@thedotmack
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

if [ -n "$agamemnon_prefetch" ]; then
  if wait "$agamemnon_prefetch"; then
    tail -n 1 "$HOME/agamemnon-prefetch.log"
  else
    echo "agamemnon: the prefetch did not finish, so each session's hook fetches the package"
    tail -n 3 "$HOME/agamemnon-prefetch.log"
  fi
  rm -f "$HOME/agamemnon-prefetch.log"
fi
