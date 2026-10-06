#!/bin/bash
# Run the agamemnon checkout's own session-start hook in a cloud session that
# carries several repositories. Claude Code reads project hooks from the
# project directory alone, and with several repositories that is their
# parent (/home/user), so agamemnon/.claude/settings.json was never read: no
# Agamemnon served on the tailnet, and the laptop's `hosts auto` rule had
# nothing to pair with (2026-10-06). A session opened on the checkout itself
# runs that hook on its own, and this does nothing there.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-}/agamemnon"
hook="$dir/.claude/hooks/session-start.sh"
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$hook" ] || exit 0

# What the hook prints tells the agent to run its scripts by a path relative
# to the checkout, so the agent is told where that is.
echo "Agamemnon's session hook, run from $dir:"
CLAUDE_PROJECT_DIR="$dir" CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-/dev/null}" bash "$hook"
