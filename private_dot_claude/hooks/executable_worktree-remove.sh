#!/usr/bin/env bash
# Claude Code WorktreeRemove hook, paired with worktree-create.sh.
# Removes without --force: a worktree with uncommitted changes fails loudly and stays.
# The worktree-<name> branch goes too when every commit on it is already in
# origin/HEAD; a branch holding other commits is kept.
set -euo pipefail

input=$(cat)
worktree=$(jq -r '.worktree_path // empty' <<<"$input")
if [[ -z "$worktree" ]]; then
  echo "worktree-remove: missing worktree_path" >&2
  exit 1
fi

project=${CLAUDE_PROJECT_DIR:-$(git -C "$worktree" rev-parse --show-toplevel)}
for settings in "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
  if [[ -f "$settings" ]] && jq -e '.hooks.WorktreeRemove' "$settings" >/dev/null 2>&1; then
    exit 0
  fi
done

common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir)
primary=$(dirname "$common")
branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD || true)
git -C "$primary" worktree remove -- "$worktree" >&2

if [[ "$branch" == worktree-* ]]; then
  if remote_head=$(git -C "$primary" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) &&
    unique=$(git -C "$primary" rev-list --count "$remote_head..$branch"); then
    if [[ "$unique" == 0 ]]; then
      git -C "$primary" branch -D "$branch" >&2 || echo "worktree-remove: could not delete branch $branch" >&2
    else
      echo "worktree-remove: kept branch $branch; it has $unique commit(s) not in $remote_head" >&2
    fi
  else
    echo "worktree-remove: kept branch $branch; could not compare it with origin/HEAD" >&2
  fi
fi
