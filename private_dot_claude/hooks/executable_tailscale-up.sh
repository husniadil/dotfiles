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
#
# claude-mem's worker is on the tailnet too (tag:proxenos, port 37701), so
# once the node is up this hook forwards 127.0.0.1:37701 to it, the address
# ~/.claude-mem/settings.json names. Claude Code runs a session's
# SessionStart hooks side by side, and claude-mem's own gives up on a worker
# that does not answer within a second, while a new node takes about 30
# seconds to join. So when the worker did not answer as this hook began, the
# hook runs claude-mem's context hook itself once the worker answers. What
# that prints is the only thing this hook prints, since a SessionStart
# hook's stdout is the session's context.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -n "${TS_AUTHKEY:-}" ] || exit 0

# What Claude Code passed this hook, for claude-mem's context hook.
input=$(cat)

# curl is kept off the egress proxy, which cannot reach this machine's loopback.
worker_up() { curl --noproxy '*' -fsS -m 2 -o /dev/null http://127.0.0.1:37701/api/health 2>/dev/null; }
up_at_start=false
worker_up && up_at_start=true

log="$HOME/.local/state/tailscale"
mkdir -p "$log" /var/lib/tailscale

# What the daemon says it is doing, or nothing when no daemon answers.
backend() { tailscale status --json 2>/dev/null | jq -r '.BackendState // empty'; }

# The join, in a subshell whose output goes to stderr, so that its exits end
# the join rather than the hook.
(
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
) >&2

# The forwarder outlives the hook, as tailscaled does. Each connection is
# dialed with tailscale nc, through tailscaled, by the MagicDNS short name, so
# the tailnet's own name stays out of this public repository.
if ! pgrep -f 'socat TCP-LISTEN:37701' >/dev/null; then
  setsid nohup socat TCP-LISTEN:37701,bind=127.0.0.1,reuseaddr,fork \
    'EXEC:tailscale nc proxenos 37701' >>"$log/claude-mem-forward.log" 2>&1 </dev/null &
fi

# claude-mem's own SessionStart hook found the worker, and added its context.
[ "$up_at_start" = true ] && exit 0

tries=0
until worker_up; do
  tries=$((tries + 1))
  if [ "$tries" -ge 15 ]; then
    echo "claude-mem: the worker on proxenos did not answer through 127.0.0.1:37701, so this session has no memory context ($log/claude-mem-forward.log)" >&2
    exit 1
  fi
  sleep 1
done

# claude-mem's context hook, run the way its hooks/hooks.json runs it.
root=$(jq -r '.plugins["claude-mem@thedotmack"] // [] | map(select(.scope == "user"))[0].installPath // empty' \
  "$HOME/.claude/plugins/installed_plugins.json")
if [ -z "$root" ]; then
  echo "claude-mem: no user install in ~/.claude/plugins/installed_plugins.json, so this session has no memory context" >&2
  exit 1
fi
printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$root" node "$root/scripts/bun-runner.js" "$root/scripts/worker-service.cjs" hook claude-code context
