#!/usr/bin/env bash
# Read-only worktree prune audit. Classifies every git worktree by size, merge
# state, uncommitted work, remote/PR state, and the most recent chat that
# operated in it. Emits a table sorted by size with a suggested bucket. Never
# deletes anything; deletion stays a human-gated step in the playbook.
#
# Usage: worktree-audit.sh [repo-path]   (defaults to the current repo)
set -u
script_dir=$(cd "$(dirname "$0")" && pwd)

repo="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -z "$repo" ] && { echo "not in a git repo; pass a repo path" >&2; exit 1; }
cd "$repo" || exit 1

# Main worktree is the first entry; everything else is a candidate.
main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')

# origin/main drives the merge check. Best-effort; stale is fine for a first pass.
git fetch origin main --quiet 2>/dev/null || echo "warn: could not fetch origin/main; merged column may be stale" >&2

# PR state by branch, fetched once. Empty if gh is unavailable.
prs=$(mktemp)
gh pr list --author "@me" --state all --limit 1000 \
	--json number,state,headRefName 2>/dev/null > "$prs" || echo "[]" > "$prs"

# Transcripts from every harness. pstack-harness knows how Claude Code and Cursor
# name their per-workspace directories. Codex keeps one tree for all workspaces, so
# search only rollouts from the last 5 days. Older ones cannot make a worktree recent.
# Without rg or the helper the scan cannot prove a worktree idle, so every worktree
# is held.
find_transcripts="$script_dir/../../pstack-harness/scripts/find-transcripts.sh"
scan=yes
command -v rg >/dev/null 2>&1 || { scan=no; echo "warn: rg not found; holding every worktree as verify-recent-chat" >&2; }
[ -x "$find_transcripts" ] || { scan=no; echo "warn: $find_transcripts missing; holding every worktree as verify-recent-chat" >&2; }
codex_recent=$(mktemp)
find "${CODEX_HOME:-$HOME/.codex}/sessions" -name 'rollout-*.jsonl' -mtime -5 2>/dev/null > "$codex_recent"
now=$(date +%s)

printf "SIZE\tAGE\tMERGED\tDIRTY\tREMOTE\tPR\tLAST_CHAT\tBUCKET\tWORKTREE\n"

git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r wt; do
	[ "$wt" = "$main_wt" ] && continue

	size=$(du -sh "$wt" 2>/dev/null | awk '{print $1}')
	head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
	head_ts=$(git -C "$wt" log -1 --format='%ct' HEAD 2>/dev/null || echo 0)
	age=$([ "$head_ts" -gt 0 ] 2>/dev/null && echo "$(( (now - head_ts) / 86400 ))d" || echo "?")

	# Squash-merged branches are not ancestors of main, so PR state is the
	# real signal; merge-base only catches fast-forward/rebase merges.
	git merge-base --is-ancestor "$head" origin/main 2>/dev/null && merged=YES || merged=no

	# Distinguish real WIP (tracked edits) from disposable untracked scratch.
	porcelain=$(git -C "$wt" status --porcelain 2>/dev/null)
	if [ -z "$porcelain" ]; then dirty=clean
	elif printf '%s\n' "$porcelain" | grep -qv '^??'; then
		dirty="wip:$(printf '%s\n' "$porcelain" | grep -cv '^??')"
	else dirty="scratch:$(printf '%s\n' "$porcelain" | grep -c '^??')"; fi

	branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "")
	if [ -z "$branch" ]; then remote=detached
	elif git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
		[ "$(git -C "$wt" rev-parse "origin/$branch" 2>/dev/null)" = "$head" ] \
			&& remote=pushed \
			|| remote="ahead$(git -C "$wt" rev-list --count "origin/$branch..HEAD" 2>/dev/null)"
	else remote=no-remote; fi

	pr=$([ -n "$branch" ] && jq -r --arg b "$branch" \
		'.[] | select(.headRefName==$b) | "#\(.number)/\(.state)"' "$prs" 2>/dev/null | head -1)
	[ -z "$pr" ] && pr="-"

	# Most recent chat whose transcript operated in this worktree. Match the literal
	# path followed by "/" or a quote so glint-482 does not match glint-482-r37.
	# Git reports /private/tmp/x where a chat opened in /tmp/x records /tmp/x.
	alias=$wt
	case $wt in /private/tmp/* | /private/var/*) alias=${wt#/private} ;; esac
	# A helper that fails cannot prove the worktree idle, so it holds the worktree.
	last="-"; last_ts=0
	if [ "$scan" = yes ] && roots=$( { "$find_transcripts" --roots --cwd "$main_wt" &&
		"$find_transcripts" --roots --cwd "$wt"; } 2>/dev/null ); then
		f=$( {
			[ -n "$roots" ] && printf '%s\n' "$roots" | sort -u | tr '\n' '\0' \
				| xargs -0 rg -l -F -e "${wt}/" -e "${wt}\"" -e "${alias}/" -e "${alias}\"" 2>/dev/null
			tr '\n' '\0' < "$codex_recent" | xargs -0 rg -l -F -e "${wt}/" -e "${wt}\"" -e "${alias}/" -e "${alias}\"" 2>/dev/null
		} | tr '\n' '\0' | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -1)
		if [ -n "$f" ]; then last_ts=$(echo "$f" | awk '{print $1}')
			last=$(date -r "$last_ts" '+%Y-%m-%d' 2>/dev/null); fi
		recent=$([ "$last_ts" -gt 0 ] 2>/dev/null && [ $(( (now - last_ts) / 86400 )) -le 4 ] && echo yes || echo no)
	else
		last="?"; recent=yes
	fi

	case "$dirty" in wip:*) bucket=hold-wip ;; *)
		case "$pr" in *OPEN*) bucket=hold-open-pr ;; *)
			if [ "$recent" = yes ]; then bucket=verify-recent-chat
			elif [ "$merged" = YES ] || [ "$pr" != "-" ]; then bucket=safe
			else bucket=review; fi ;;
		esac ;;
	esac

	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$size" "$age" "$merged" "$dirty" "$remote" "$pr" "$last" "$bucket" "$wt"
done | sort -t$'\t' -k1,1 -rh

rm -f "$prs" "$codex_recent"
