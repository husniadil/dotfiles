#!/bin/bash
# Join this cloud session to the tailnet when the environment carries
# TS_AUTHKEY, and do nothing without it. The key is reusable, ephemeral,
# pre-approved and tagged tag:claude-cloud, so the node is a tagged device
# that the tag's grants limit, and it leaves the tailnet 30 to 60 minutes
# after the session ends.
#
# The sandbox has no systemd and no UDP out. tailscaled runs in userspace
# networking with its state in memory, which registers the node as
# ephemeral, and reaches the control plane and the DERP relays through the
# egress proxy in HTTPS_PROXY. Nothing on the machine routes to the tailnet
# by itself: a command reaches it through the SOCKS5 proxy on
# 127.0.0.1:1055, as in `curl -x socks5h://127.0.0.1:1055 https://<host>`.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -n "${TS_AUTHKEY:-}" ] || exit 0

log="$HOME/.local/state/tailscale"
mkdir -p "$log" /var/lib/tailscale

# What the daemon says it is doing, or nothing when no daemon answers.
backend() { tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'; }

# A session resumed on a VM that kept running still has its daemon.
if [ -z "$(backend)" ]; then
  setsid nohup tailscaled --tun=userspace-networking --state=mem: \
    --statedir=/var/lib/tailscale --socks5-server=127.0.0.1:1055 \
    >>"$log/tailscaled.log" 2>&1 </dev/null &
  for _ in $(seq 50); do
    [ -n "$(backend)" ] && break
    sleep 0.2
  done
fi
[ "$(backend)" = "Running" ] && exit 0

# Sessions run side by side, so each node is named after its own session.
id="${CLAUDE_CODE_REMOTE_SESSION_ID:-$(hostname)}"
name="claude-$(printf '%s' "${id: -8}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
# Registering through the egress proxy took about 30 seconds (measured
# 2026-10-05), so the wait is longer than that.
tailscale up --auth-key="$TS_AUTHKEY" --hostname="$name" --timeout=120s
