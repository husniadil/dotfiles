#!/bin/bash
# Serve an Agamemnon on the tailnet from every cloud session, whatever its
# repositories, so the `hosts auto tag:claude-cloud` rule on the laptop and on
# the Agamemnon VM pairs with it and the session shows in their sidebars. A
# session that carries the agamemnon checkout serves that checkout instead
# (its own session hook, or agamemnon-up.sh with several repositories), so
# this leaves such a session alone.
#
# The repository is private, nothing is on npm, and a cloud session's GitHub
# proxy reaches only the session's own repositories. So the linux-x64 package
# comes from the Agamemnon VM over the tailnet: `tailscale serve` of its
# ~/agm-dist on port 8443, repacked there whenever that VM's build changes,
# and the one port tag:claude-cloud may reach on it. It is unpacked under
# ~/.local/lib/agamemnon, which a resumed session keeps, and fetched again
# only when the VM serves another version. A new session served 3.5 and 4.5
# minutes after its node came online in two runs (2026-10-14). Most of that is
# the fetch, 50 MB over the DERP relay, which ran at 0.42 MB/s in the one
# measurement. The certificate, about 35 s on a new node, is asked for while
# the package downloads. Fetching it in the environment's setup instead, into
# the cached snapshot, did not run: no node from the setup joined the tailnet,
# where the same fetch run in a session did, so the setup script appears not
# to see TS_AUTHKEY.
#
# The node takes about 30 seconds to join (tailscale-up.sh, side by side with
# this) and the package minutes more to fetch, so the work runs in the
# background and the hook returns at once. It prints nothing, since a
# SessionStart hook's stdout is the session's context. What it did is in
# ~/.local/state/agamemnon-serve/serve.log, each step stamped in UTC, and the
# server's own output beside it.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -n "${TS_AUTHKEY:-}" ] && [ -n "${AGM_TAILNET_TOKEN:-}" ] || exit 0

project="${CLAUDE_PROJECT_DIR:-}"
if [ -n "$project" ] && { [ -f "$project/apps/agamemnon/src/server.ts" ] || [ -f "$project/agamemnon/.claude/hooks/session-start.sh" ]; }; then
  exit 0
fi

port=4600
state="$HOME/.local/state/agamemnon-serve"
lib="$HOME/.local/lib/agamemnon"
tls="$state/tls"
mkdir -p "$state"

answers() { curl -sk -o /dev/null -m 2 --noproxy '*' "https://127.0.0.1:$port/api/build"; }
say() { echo "$(date -u +%FT%TZ) $*"; }

serve() {
  exec >>"$state/serve.log" 2>&1
  echo "== $(date -u +%FT%TZ) session ${CLAUDE_CODE_REMOTE_SESSION_ID:-?}"
  # A compaction, or a resume that kept the container, finds it serving.
  if answers; then
    say "already serving"
    return 0
  fi
  exec 9>"$state/lock"
  flock -n 9 || { say "another start is running"; return 0; }
  local began=$SECONDS

  # Online, not just Running: a node Tailscale removed while the session slept
  # says Running from its saved state until tailscale-up.sh logs it in again,
  # and a certificate asked for before then is refused.
  st='{}'
  for _ in $(seq 180); do
    st=$(tailscale status --json 2>/dev/null || echo '{}')
    [ "$(jq -r '.Self.Online // false' <<<"$st")" = true ] && break
    sleep 1
  done
  if [ "$(jq -r '.Self.Online // false' <<<"$st")" != true ]; then
    say "the node is not online after 180 s; nothing served"
    return 1
  fi
  name=$(jq -r '.Self.DNSName // empty' <<<"$st")
  name=${name%.}
  say "online as $name after $((SECONDS - began)) s"

  # The certificate is asked for beside the package's download.
  mkdir -p "$tls"
  (
    for _ in 1 2 3; do
      tailscale cert --cert-file "$tls/cert.pem" --key-file "$tls/key.pem" "$name" && exit 0
      sleep 5
    done
    exit 1
  ) &
  local cert=$!
  # The tailnet's name comes from tailscaled, so it stays out of this public
  # repository. tailscaled's SOCKS5 proxy is the only way onto the tailnet here.
  dist="https://agamemnon.$(jq -r '.MagicDNSSuffix' <<<"$st"):8443"
  fetch() { curl -fsS --retry 3 --retry-delay 2 -m 300 -x socks5h://127.0.0.1:1055 "$dist/$1"; }

  want=$(fetch VERSION)
  have=$("$lib/agamemnon" --version 2>/dev/null | awk '{print $2}' || true)
  if [ "$have" != "$want" ]; then
    tmp=$(mktemp -d)
    local fetched=$SECONDS
    fetch agamemnon-linux-x64.tar.zst >"$tmp/package.tar.zst"
    say "fetched $(stat -c %s "$tmp/package.tar.zst") bytes in $((SECONDS - fetched)) s"
    sum=$(fetch agamemnon-linux-x64.tar.zst.sha256 | awk '{print $1}')
    echo "$sum  $tmp/package.tar.zst" | sha256sum -c --quiet -
    mkdir "$tmp/package"
    # Packed with a 128 MB window, which zstd reads only when told to.
    zstd -dc --long=27 "$tmp/package.tar.zst" | tar -C "$tmp/package" -xf -
    mkdir -p "$(dirname "$lib")"
    rm -rf "$lib.old"
    [ ! -d "$lib" ] || mv "$lib" "$lib.old"
    mv "$tmp/package" "$lib"
    rm -rf "$tmp" "$lib.old"
    say "installed $want (had ${have:-none})"
  else
    say "package $want already here"
  fi

  "$lib/agamemnon" name "${name%%.*}" >/dev/null
  # The rule's hosts pair with this machine by this token, so it is made this
  # host's own. jq reads it from the environment, never from an argument.
  cfg="$HOME/.config/agamemnon/config.json"
  mkdir -p "$(dirname "$cfg")"
  (
    umask 077
    next=$(mktemp "$cfg.XXXXXX")
    { [ -f "$cfg" ] && cat "$cfg" || echo '{}'; } | jq '.token = env.AGM_TAILNET_TOKEN' >"$next"
    mv "$next" "$cfg"
  )

  if ! wait "$cert" || [ ! -s "$tls/cert.pem" ]; then
    say "no certificate for $name"
    return 1
  fi
  say "certificate ready"

  AGM_HOST=0.0.0.0 AGM_PORT=$port AGM_PUBLIC_URL="https://$name:$port" \
    AGM_TLS_CERT="$tls/cert.pem" AGM_TLS_KEY="$tls/key.pem" \
    setsid nohup "$lib/agamemnon" >>"$state/server.log" 2>&1 </dev/null 9>&- &
  for _ in $(seq 60); do
    answers && { say "serving $want as https://$name:$port, $((SECONDS - began)) s after the start"; return 0; }
    sleep 1
  done
  say "the server did not answer within 60 s; see $state/server.log"
  return 1
}

if [ "${1:-}" = serve ]; then
  serve
else
  setsid nohup bash "${BASH_SOURCE[0]}" serve >/dev/null 2>&1 </dev/null &
fi
