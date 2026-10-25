#!/usr/bin/env bash
# Claude Code WorktreeCreate hook. Creates worktrees at
# ~/.worktrees/<owner>/<repo>/<name> instead of <repo>/.claude/worktrees/<name>,
# so file watchers rooted at the checkout (Watchman, Metro, Jest) never crawl them.
# Claude Code reads the worktree path from stdout, so all other output goes to stderr.
set -euo pipefail

input=$(cat)
name=$(jq -r '.name // empty' <<<"$input")
cwd=$(jq -r '.cwd // empty' <<<"$input")

# A project that ships its own WorktreeCreate hook owns the location. Claude
# Code takes the first non-empty path, so print nothing.
project=${CLAUDE_PROJECT_DIR:-$(git -C "$cwd" rev-parse --show-toplevel)}
for settings in "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
  if [[ -f "$settings" ]] && jq -e '.hooks.WorktreeCreate' "$settings" >/dev/null 2>&1; then
    exit 0
  fi
done

if [[ -z "$name" || "$name" == *..* ]]; then
  echo "worktree-create: invalid worktree name '$name'" >&2
  exit 1
fi
flat=${name//\//+}

common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)
primary=$(dirname "$common")
rel=${primary#"$HOME/github.com/"}
if [[ "$rel" == "$primary" || "$rel" != */* || "$rel" == */*/* ]]; then
  echo "worktree-create: $primary is not a clone at ~/github.com/<owner>/<repo>" >&2
  exit 1
fi
target="$HOME/.worktrees/$rel/$flat"

if [[ -e "$target" ]]; then
  if git -C "$primary" worktree list --porcelain | grep -qxF "worktree $target"; then
    printf '%s\n' "$target"
    exit 0
  fi
  echo "worktree-create: $target exists and is not a worktree of $primary" >&2
  exit 1
fi

branch="worktree-$flat"
base_ref=$(jq -r '.worktree.baseRef // "fresh"' "$HOME/.claude/settings.json")
if [[ "$base_ref" == "head" ]]; then
  base=$(git -C "$cwd" rev-parse HEAD)
else
  if ! remote_head=$(git -C "$primary" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "worktree-create: origin/HEAD is not set; run 'git -C $primary remote set-head origin --auto'" >&2
    exit 1
  fi
  # A stale origin ref still gives a usable base for a new branch, so a failed
  # fetch (offline, VPN) is reported and the worktree is created anyway.
  git -C "$primary" fetch --quiet origin "${remote_head#origin/}" >&2 ||
    echo "worktree-create: fetch failed, branching from the local $remote_head" >&2
  # Branching from a commit instead of origin/<default> keeps git from making
  # the default branch the new branch's upstream.
  base=$(git -C "$primary" rev-parse --verify "$remote_head^{commit}")
fi

# Reusing a name after its worktree was removed finds the old branch. Drop it
# when it holds nothing beyond the base, and refuse when it does.
if git -C "$primary" show-ref --verify --quiet "refs/heads/$branch"; then
  unique=$(git -C "$primary" rev-list --count "$base..refs/heads/$branch")
  if [[ "$unique" != 0 ]]; then
    echo "worktree-create: branch $branch already exists with $unique commit(s) not in $base; delete it or pick another name" >&2
    exit 1
  fi
  git -C "$primary" branch -D "$branch" >&2
fi

mkdir -p "$(dirname "$target")"
worktree_add() {
  git -C "$primary" worktree add -b "$branch" "$target" "$base"
}
# A repository whose own tool adds a worktree (and bootstraps what it needs)
# is named in an unmanaged file beside this one, which redefines worktree_add
# for it with $primary, $target, $branch and $base in hand.
local_add="$HOME/.claude/hooks/worktree-create.local.sh"
if [[ -f "$local_add" ]]; then
  # shellcheck source=/dev/null
  source "$local_add"
fi
worktree_add >&2

printf '%s\n' "$target"
