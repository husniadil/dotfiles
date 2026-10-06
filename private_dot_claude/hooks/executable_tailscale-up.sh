#!/bin/bash
# Join this cloud session to the tailnet when the environment carries
# TS_AUTHKEY, and do nothing without it. The key is reusable, ephemeral,
# pre-approved and tagged tag:claude-cloud, so the node is a tagged device
# that the tag's grants limit, and it leaves the tailnet 30 to 60 minutes
# after the session ends.
#
# The sandbox has no systemd and no UDP out. tailscaled runs in userspace
# networking and reaches the control plane and the DERP relays through the
# egress proxy in HTTPS_PROXY. Nothing on the machine routes to the tailnet
# by itself: a command reaches it through the SOCKS5 proxy on
# 127.0.0.1:1055, as in `curl -x socks5h://127.0.0.1:1055 https://<host>`.
#
# Its state is kept on the session's disk, so a session whose processes
# ended while its files stayed comes back as the node it was. With the state
# in memory it registered a second node, which Tailscale named
# claude-<id>-1 while the first waited out its removal (2026-10-05). The
# node is ephemeral because the key is.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -n "${TS_AUTHKEY:-}" ] || exit 0

log="$HOME/.local/state/tailscale"
mkdir -p "$log" /var/lib/tailscale

# What the daemon says it is doing, or nothing when no daemon answers.
backend() { tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'; }

# A session resumed on a VM that kept running still has its daemon.
if [ -z "$(backend)" ]; then
  setsid nohup tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale \
    --socks5-server=127.0.0.1:1055 >>"$log/tailscaled.log" 2>&1 </dev/null &
fi
# A daemon started from a saved node says Starting until the control plane
# answers whether that node is still there, so wait for a state that decides.
for _ in $(seq 150); do
  case "$(backend)" in Running | NeedsLogin | NeedsMachineAuth | Stopped) break ;; esac
  sleep 0.2
done

# Sessions run side by side, so each node is named after its own session.
id="${CLAUDE_CODE_REMOTE_SESSION_ID:-$(hostname)}"
name="claude-$(printf '%s' "${id: -8}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"

# Running is not enough. A node the control plane has removed (the key's
# nodes are ephemeral) still says Running from its saved state, offline,
# with no peers and an AuthURL to log in again: a session resumed after a
# night sat off the tailnet that way (2026-10-06). So wait for the node to
# be online, or to be asked to log in, and then log the saved node in with
# the key. One that is neither by the end of the wait is left as it is.
if [ "$(backend)" = "Running" ]; then
  for _ in $(seq 150); do
    state=$(tailscale status --json 2>/dev/null || echo '{}')
    [ "$(jq -r '.Self.Online // false' <<<"$state")" = true ] && exit 0
    if [ -n "$(jq -r '.AuthURL // empty' <<<"$state")" ]; then
      exec tailscale login --auth-key="$TS_AUTHKEY" --hostname="$name" --timeout=120s
    fi
    sleep 0.2
  done
  exit 0
fi

# Registering through the egress proxy took about 30 seconds (measured
# 2026-10-05), so the wait is longer than that.
tailscale up --auth-key="$TS_AUTHKEY" --hostname="$name" --timeout=120s
