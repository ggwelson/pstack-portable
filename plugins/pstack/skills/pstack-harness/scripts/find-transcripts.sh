#!/usr/bin/env bash
# List agent transcripts for one workspace across Claude Code, Codex, and Cursor,
# newest first. Prints "<epoch>\t<harness>\t<path>" per line.
set -euo pipefail

usage() {
	cat <<'EOF'
usage: find-transcripts.sh [--cwd DIR] [--days N] [--harness all|claude|codex|cursor] [--self | --roots]

--cwd DIR   workspace to scope to (default: the git toplevel, else $PWD)
--days N    only transcripts modified in the last N days (default: 30)
--self      only the current session's transcript (Claude Code or Codex)
--roots     only the existing Claude Code and Cursor directories for the workspace
EOF
}

cwd= days=30 which=all self=0 roots=0
while (($#)); do
	case $1 in
		--cwd) cwd=$2; shift 2 ;;
		--days) days=$2; shift 2 ;;
		--harness) which=$2; shift 2 ;;
		--self) self=1; shift ;;
		--roots) roots=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done
cwd=${cwd:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
# A harness records the path it was opened with. On macOS /tmp and /var are aliases
# of /private/tmp and /private/var, so try the path as given, its physical form, and
# the alias of each.
with_alias() {
	echo "$1"
	case $1 in
		/private/tmp/* | /private/var/*) echo "${1#/private}" ;;
		/tmp/* | /var/*) echo "/private$1" ;;
	esac
}
physical=$(cd "$cwd" 2>/dev/null && pwd -P) || physical=$cwd
paths=$({ with_alias "$cwd"; with_alias "$physical"; } | sort -u)

emit() { printf '%s\t%s\t%s\n' "$(date -r "$2" +%s)" "$1" "$2"; }

# Claude Code: /Users/a.b/.t3/x -> -Users-a-b--t3-x (every non-alphanumeric becomes -).
# Cursor:      /Users/a.b/.t3/x -> Users-a-b-t3-x   (leading / dropped, runs collapse to one -).
claude_dir() { printf '%s/.claude/projects/%s' "$HOME" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }
cursor_dir() { printf '%s/.cursor/projects/%s/agent-transcripts' "$HOME" "$(printf '%s' "${1#/}" | sed -E 's/[^A-Za-z0-9]+/-/g')"; }
codex_root=${CODEX_HOME:-$HOME/.codex}/sessions

if ((roots)); then
	while read -r p; do
		for d in "$(claude_dir "$p")" "$(cursor_dir "$p")"; do if [[ -d $d ]]; then echo "$d"; fi; done
	done <<<"$paths" | sort -u
	exit 0
fi

if ((self)); then
	if [[ -n ${CODEX_THREAD_ID:-} ]]; then
		f=$(find "$codex_root" -name "rollout-*${CODEX_THREAD_ID}.jsonl" 2>/dev/null | head -1)
		[[ -n $f ]] && { emit codex "$f"; exit 0; }
	fi
	if [[ -n ${CLAUDE_CODE_SESSION_ID:-} ]]; then
		f=$(find "$HOME/.claude/projects" -maxdepth 2 -name "${CLAUDE_CODE_SESSION_ID}.jsonl" 2>/dev/null | head -1)
		[[ -n $f ]] && { emit claude "$f"; exit 0; }
	fi
	echo "find-transcripts: cannot identify the current session. List the workspace and take the newest." >&2
	exit 1
fi

{
	while read -r p; do
		for h in claude cursor; do
			[[ $which == all || $which == "$h" ]] || continue
			d=$("${h}_dir" "$p")
			[[ -d $d ]] || continue
			find "$d" -name '*.jsonl' -mtime "-$days" 2>/dev/null | while read -r f; do emit "$h" "$f"; done
		done
	done <<<"$paths"
	if [[ $which == all || $which == codex ]] && [[ -d $codex_root ]]; then
		# Codex keeps every workspace in one tree. The session_meta line records cwd.
		find "$codex_root" -name 'rollout-*.jsonl' -mtime "-$days" 2>/dev/null | while read -r f; do
			first=$(head -n 1 "$f")
			while read -r p; do
				if [[ $first == *"\"cwd\":\"$p\""* ]]; then emit codex "$f"; break; fi
			done <<<"$paths"
		done
	fi
} | sort -u | sort -rn
