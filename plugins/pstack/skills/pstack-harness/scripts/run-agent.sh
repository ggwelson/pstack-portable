#!/usr/bin/env bash
# Resolve a pstack model value for the current harness, or run one brief on it
# headless through the claude, codex, or cursor-agent CLI.
set -euo pipefail

usage() {
	cat <<'EOF'
usage:
  run-agent.sh --resolve MODEL [--harness H]
  run-agent.sh --list-models
  run-agent.sh --model MODEL --prompt-file FILE --out FILE
               [--harness H] [--read-only] [--cwd DIR] [--timeout SECONDS]

MODEL is a Cursor slug (claude-opus-5-5-max, gpt-5.6-sol-max, grok-4.7-xhigh-fast),
a runner spec (claude/opus@high, codex/gpt-6-astra@xhigh, codex/, cursor/<slug>),
or inherit | inherit-parent | auto.
H is claude, codex, cursor, or none. Default comes from the environment.

--resolve prints one line: native [MODEL] | cli SPEC | unavailable REASON.
A run writes the final message to --out and the CLI log to OUT.log.
Exit codes: 0 ok, 2 usage, 3 resolves to native, 4 unavailable, 5 network blocked, 6 no output.
EOF
}

die() { echo "run-agent: $2" >&2; exit "$1"; }

detect_harness() {
	if [[ -n ${PSTACK_HARNESS:-} ]]; then echo "$PSTACK_HARNESS"
	elif [[ -n ${CODEX_THREAD_ID:-} ]]; then echo codex
	elif [[ -n ${CLAUDECODE:-} ]]; then echo claude
	elif [[ -n ${CURSOR_AGENT:-} ]]; then echo cursor
	else echo none; fi
}

efforts="low medium high xhigh max"

# Last effort token in a Cursor slug, ignoring a trailing -fast.
slug_effort() {
	local tok out=
	for tok in ${1//-/ }; do
		[[ " $efforts " == *" $tok "* ]] && out=$tok
	done
	echo "$out"
}

# A Cursor slug with its effort and -fast tokens removed: gpt-5.6-sol-max -> gpt-5.6-sol.
slug_base() {
	local tok out=
	for tok in ${1//-/ }; do
		[[ " $efforts fast thinking " == *" $tok "* ]] && continue
		out=${out:+$out-}$tok
	done
	echo "$out"
}

claude_alias() {
	case $1 in
		*opus*) echo opus ;; *sonnet*) echo sonnet ;; *haiku*) echo haiku ;; *fable*) echo fable ;;
		*) echo "$1" ;;
	esac
}

family() {
	case $1 in
		claude-*) echo claude ;;
		gpt-* | codex* | o[0-9]*) echo codex ;;
		*) echo other ;;
	esac
}

# Sandboxes can make TMPDIR read-only and block network. The resolver then works
# from whatever cache exists and trusts slugs it cannot check.
cache_dir=${TMPDIR:-/tmp}/pstack-cache
mkdir -p "$cache_dir" 2>/dev/null || cache_dir=$(mktemp -d 2>/dev/null || echo /dev/null)

# Cached for a day. cursor-agent takes a few seconds to list.
cursor_models() {
	local f=$cache_dir/cursor-models.txt
	if [[ ! -s $f || -n $(find "$f" -mmin +1440 2>/dev/null) ]]; then
		{ cursor-agent models 2>/dev/null | awk '/ - /{print $1}' >"$f.tmp" && [[ -s $f.tmp ]] && mv "$f.tmp" "$f"; } 2>/dev/null || true
	fi
	cat "$f" 2>/dev/null || true
}

codex_models() {
	local f=$cache_dir/codex-models.txt
	if [[ ! -s $f || -n $(find "$f" -mmin +1440 2>/dev/null) ]]; then
		{ codex debug models 2>/dev/null | jq -r '.models[].slug' >"$f.tmp" && [[ -s $f.tmp ]] && mv "$f.tmp" "$f"; } 2>/dev/null || true
	fi
	cat "$f" 2>/dev/null || true
}

# Upstream's setup rule: the same family's slug with the highest effort at or below the target.
cursor_nearest() {
	local slug=$1 list effort lower e
	list=$(cursor_models)
	[[ -z $list ]] && { echo "$slug"; return; }
	grep -qxF "$slug" <<<"$list" && { echo "$slug"; return; }
	effort=$(slug_effort "$slug")
	[[ -z $effort ]] && return 1
	lower=${efforts%%"$effort"*}
	for e in $(echo "$lower" | awk '{for (i = NF; i > 0; i--) print $i}'); do
		local candidate=${slug/-$effort/-$e}
		grep -qxF "$candidate" <<<"$list" && { echo "$candidate"; return; }
	done
	return 1
}

has() { command -v "$1" >/dev/null 2>&1; }

resolve() {
	local v=$1 h=$2 vendor rest model effort=
	case $v in
		"" | inherit | inherit-parent | auto) echo native; return ;;
	esac

	if [[ $v == */* ]]; then
		vendor=${v%%/*}
		rest=${v#*/}
		[[ $rest == *@* ]] && { effort=${rest##*@}; rest=${rest%@*}; }
		model=$rest
		case $vendor in
			claude)
				[[ $h == claude ]] && { echo "native $(claude_alias "${model:-opus}")"; return; }
				has claude && { echo "cli $v"; return; }
				echo "unavailable claude CLI not installed" ;;
			codex)
				[[ $h == codex ]] && { echo "native${model:+ $model}"; return; }
				has codex && { echo "cli $v"; return; }
				echo "unavailable codex CLI not installed" ;;
			cursor)
				[[ $h == cursor ]] && { echo "native $model"; return; }
				has cursor-agent || { echo "unavailable cursor-agent not installed"; return; }
				local near
				near=$(cursor_nearest "$model") || { echo "unavailable cursor-agent has no $model"; return; }
				echo "cli cursor/$near" ;;
			*) echo "unavailable unknown vendor $vendor" ;;
		esac
		return
	fi

	local fam
	fam=$(family "$v")
	effort=$(slug_effort "$v")
	[[ $h == cursor ]] && { echo "native $v"; return; }
	[[ $fam == claude && $h == claude ]] && { echo "native $(claude_alias "$v")"; return; }
	if [[ $fam == codex && $h == codex ]]; then
		local base
		base=$(slug_base "$v")
		codex_models | grep -qxF "$base" && { echo "native $base"; return; }
		echo native
		return
	fi
	if has cursor-agent; then
		local near
		near=$(cursor_nearest "$v") && { echo "cli cursor/$near"; return; }
	fi
	case $fam in
		claude) has claude && { echo "cli claude/$(claude_alias "$v")${effort:+@$effort}"; return; } ;;
		codex)
			if has codex; then
				local base
				base=$(slug_base "$v")
				codex_models | grep -qxF "$base" || base=
				echo "cli codex/$base${effort:+@$effort}"
				return
			fi ;;
	esac
	echo "unavailable no CLI can run $v (install cursor-agent, or set a runner spec in ~/.config/pstack/models.md)"
}

list_models() {
	echo "# claude (native in Claude Code, else claude -p)"
	has claude && echo "claude/opus claude/sonnet claude/haiku claude/fable" || echo "(claude CLI not installed)"
	echo "# codex (native in Codex, else codex exec)"
	if has codex; then codex_models | sed 's#^#codex/#'; else echo "(codex CLI not installed)"; fi
	echo "# cursor-agent (accepts upstream's Cursor slugs)"
	if has cursor-agent; then cursor_models; else echo "(cursor-agent not installed)"; fi
}

mode=run model= prompt_file= out= harness= read_only=0 cwd=$PWD timeout=0
while (($#)); do
	case $1 in
		--resolve) mode=resolve; model=${2-}; shift 2 ;;
		--list-models) mode=list; shift ;;
		--model) model=$2; shift 2 ;;
		--prompt-file) prompt_file=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		--harness) harness=$2; shift 2 ;;
		--read-only) read_only=1; shift ;;
		--cwd) cwd=$2; shift 2 ;;
		--timeout) timeout=$2; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die 2 "unknown argument $1" ;;
	esac
done
harness=${harness:-$(detect_harness)}

case $mode in
	list) list_models; exit 0 ;;
	resolve) resolve "$model" "$harness"; exit 0 ;;
esac

[[ -n $prompt_file && -n $out ]] || { usage >&2; die 2 "--prompt-file and --out are required"; }
[[ -r $prompt_file ]] || die 2 "cannot read $prompt_file"
[[ ${CODEX_SANDBOX_NETWORK_DISABLED:-} == 1 ]] && die 5 "the Codex sandbox blocks network. Rerun this command with escalated permissions."

resolved=$(resolve "$model" "$harness")
case $resolved in
	native*) die 3 "$model resolves to '$resolved' in $harness. Spawn a native subagent instead." ;;
	unavailable*) die 4 "${resolved#unavailable }" ;;
esac
spec=${resolved#cli }
vendor=${spec%%/*}
rest=${spec#*/}
effort=
[[ $rest == *@* ]] && { effort=${rest##*@}; rest=${rest%@*}; }
m=$rest

mkdir -p "$(dirname "$out")"
log=$out.log
: >"$out"

with_timeout() {
	if ((timeout > 0)); then perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$timeout" "$@"
	else "$@"; fi
}

status=0
case $vendor in
	claude)
		args=(-p --output-format text)
		[[ -n $m ]] && args+=(--model "$m")
		[[ -n $effort ]] && args+=(--effort "$effort")
		# plan allows read-only shell (git diff, rg) and refuses writes. acceptEdits allows
		# file edits but no shell. Set PSTACK_CLAUDE_PERMISSION_MODE=bypassPermissions for
		# a writing seat that must run tests, and only in its own worktree.
		if ((read_only)); then args+=(--permission-mode plan)
		else args+=(--permission-mode "${PSTACK_CLAUDE_PERMISSION_MODE:-acceptEdits}"); fi
		(cd "$cwd" && with_timeout claude "${args[@]}" <"$prompt_file") >"$out" 2>"$log" || status=$?
		;;
	codex)
		args=(exec --skip-git-repo-check --color never -C "$cwd" -o "$out")
		[[ -n $m ]] && args+=(-m "$m")
		[[ -n $effort ]] && args+=(-c "model_reasoning_effort=\"$effort\"")
		if ((read_only)); then args+=(-s read-only)
		else args+=(-s "${PSTACK_CODEX_SANDBOX:-workspace-write}"); fi
		with_timeout codex "${args[@]}" - <"$prompt_file" >"$log" 2>&1 || status=$?
		;;
	cursor)
		args=(-p --output-format text --trust --workspace "$cwd")
		[[ -n $m ]] && args+=(--model "$m")
		if ((read_only)); then args+=(--mode ask); else args+=(--force); fi
		with_timeout cursor-agent "${args[@]}" "$(cat "$prompt_file")" >"$out" 2>"$log" || status=$?
		;;
	*) die 4 "unknown vendor $vendor" ;;
esac

if ((status != 0)); then
	echo "run-agent: $spec exited $status. Last log lines:" >&2
	tail -n 20 "$log" >&2
	exit "$status"
fi
[[ -s $out ]] || die 6 "$spec produced no output. See $log"
echo "run-agent: $spec wrote $out" >&2
