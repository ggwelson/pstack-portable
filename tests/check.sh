#!/usr/bin/env bash
# Checks that plugins/pstack is upstream plus the layer and nothing else, that the
# manifests validate, and that the layer's scripts behave. Needs network for the
# upstream fetch. Run from anywhere: tests/check.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
plugin=$root/plugins/pstack
harness=$plugin/skills/pstack-harness/scripts
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { printf 'ok    %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
expect() { [[ $2 == "$3" ]] && pass "$1" || fail "$1: expected '$3', got '$2'"; }

# The tree must equal what sync.sh builds from the pinned upstream ref.
if "$root/sync.sh" --into "$tmp/rebuilt" >"$tmp/sync.log" 2>&1; then
	if diff -r -x .DS_Store "$plugin" "$tmp/rebuilt" >"$tmp/drift"; then
		pass "plugins/pstack equals upstream $(awk '$1 == "ref" {print substr($2, 1, 12)}' "$root/UPSTREAM") plus the layer"
	else
		fail "plugins/pstack differs from sync.sh output. Edit upstream files through patches/ only."
		head -40 "$tmp/drift"
	fi
else
	fail "sync.sh --into failed"
	cat "$tmp/sync.log"
fi

for script in "$root"/sync.sh "$root"/tests/*.sh "$plugin"/skills/*/scripts/*.sh; do
	bash -n "$script" || fail "bash -n $script"
done
pass "shell scripts parse"

# Codex keys plugin skills by the front matter name, and a $mention cannot match a name with spaces.
for skill in "$plugin"/skills/*/SKILL.md; do
	folder=$(basename "$(dirname "$skill")")
	name=$(awk '/^---$/ {n++; next} n == 1 && /^name:/ {sub(/^name: */, ""); print; exit}' "$skill")
	[[ $name == "$folder" ]] || fail "$folder/SKILL.md has name '$name'. Codex cannot invoke it."
done
pass "every skill name matches its folder"

grep -oE '\.\./[A-Za-z0-9./_-]+' "$plugin/skills/pstack-harness/SKILL.md" | sort -u | while read -r rel; do
	[[ -e $plugin/skills/pstack-harness/$rel ]] || echo "$rel"
done >"$tmp/dangling"
[[ -s $tmp/dangling ]] && fail "pstack-harness links to missing paths: $(tr '\n' ' ' <"$tmp/dangling")" || pass "pstack-harness relative paths resolve"

if command -v claude >/dev/null; then
	claude plugin validate "$plugin" >"$tmp/v1" 2>&1 && pass "claude plugin validate (plugin)" || { fail "claude plugin validate (plugin)"; cat "$tmp/v1"; }
	claude plugin validate "$root" >"$tmp/v2" 2>&1 && pass "claude plugin validate (marketplace)" || { fail "claude plugin validate (marketplace)"; cat "$tmp/v2"; }
fi

# Codex's validator rejects disable-model-invocation: true, yet codex plugin add accepts
# it and the sidecars hide those skills. Fail only on other errors.
validator=$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py
if [[ -f $validator ]] && python3 -c 'import yaml' 2>/dev/null; then
	python3 "$validator" "$plugin" 2>&1 | grep '^- ' | grep -v 'disable-model-invocation' >"$tmp/v3"
	[[ -s $tmp/v3 ]] && { fail "codex validate_plugin.py"; cat "$tmp/v3"; } || pass "codex validate_plugin.py (ignoring disable-model-invocation)"
fi

# Resolver cases run against stub CLIs so the answers do not depend on this machine.
stubs=$tmp/stubs
mkdir -p "$stubs" "$tmp/cache"
ln -s "$(command -v jq)" "$stubs/jq"
cat >"$stubs/cursor-agent" <<'EOF'
#!/bin/sh
printf 'Available models\n\nclaude-opus-5-5-max - Opus\ngpt-5.6-sol-max - Sol\ngrok-4.7-high-fast - Grok\n'
EOF
cat >"$stubs/codex" <<'EOF'
#!/bin/sh
printf '{"models":[{"slug":"gpt-6-astra"},{"slug":"gpt-5.6-sol"}]}\n'
EOF
printf '#!/bin/sh\nexit 0\n' >"$stubs/claude"
chmod +x "$stubs"/*

resolve() {
	local path=$stubs:/usr/bin:/bin
	[[ $1 == no-cursor ]] && { path=$tmp/nocursor:/usr/bin:/bin; shift; }
	TMPDIR=$tmp/cache/$RANDOM PATH=$path "$harness/run-agent.sh" --harness "$1" --resolve "$2"
}
mkdir -p "$tmp/nocursor"
cp "$stubs/codex" "$stubs/claude" "$tmp/nocursor/"
ln -s "$(command -v jq)" "$tmp/nocursor/jq"

expect "resolve inherit-parent in claude" "$(resolve claude inherit-parent)" "native"
expect "resolve a Claude slug in claude" "$(resolve claude claude-opus-5-5-max)" "native opus"
expect "resolve a GPT slug in claude" "$(resolve claude gpt-5.6-sol-max)" "cli cursor/gpt-5.6-sol-max"
expect "resolve an unlisted effort steps down" "$(resolve claude grok-4.7-xhigh-fast)" "cli cursor/grok-4.7-high-fast"
expect "resolve a GPT slug in codex" "$(resolve codex gpt-5.6-sol-max)" "native gpt-5.6-sol"
expect "resolve a Claude slug in codex" "$(resolve codex claude-opus-5-5-max)" "cli cursor/claude-opus-5-5-max"
expect "resolve a claude spec in codex" "$(resolve codex claude/sonnet@high)" "cli claude/sonnet@high"
expect "resolve a codex spec in claude" "$(resolve claude codex/@xhigh)" "cli codex/@xhigh"
expect "resolve a GPT slug without cursor-agent" "$(resolve no-cursor claude gpt-5.6-sol-max)" "cli codex/gpt-5.6-sol@max"
expect "resolve Grok without cursor-agent" "$(resolve no-cursor claude grok-4.7-xhigh-fast | cut -d' ' -f1)" "unavailable"

# find-transcripts stays inside one workspace and reads all three harnesses. The
# directory names are literal copies of what each harness wrote for /Users/a.b/.t3/repo.
fake=$tmp/home
mkdir -p "$fake/.claude/projects/-Users-a-b--t3-repo" "$fake/.claude/projects/-Users-a-b--t3-other" \
	"$fake/.codex/sessions/2026/10/01" "$fake/.cursor/projects/Users-a-b-t3-repo/agent-transcripts/a"
echo '{}' >"$fake/.claude/projects/-Users-a-b--t3-repo/s1.jsonl"
echo '{}' >"$fake/.claude/projects/-Users-a-b--t3-other/s2.jsonl"
echo '{"type":"session_meta","payload":{"cwd":"/Users/a.b/.t3/repo"}}' >"$fake/.codex/sessions/2026/10/01/rollout-x-1.jsonl"
echo '{"type":"session_meta","payload":{"cwd":"/Users/a.b/.t3/other"}}' >"$fake/.codex/sessions/2026/10/01/rollout-x-2.jsonl"
echo '{}' >"$fake/.cursor/projects/Users-a-b-t3-repo/agent-transcripts/a/a.jsonl"
found=$(HOME=$fake CODEX_HOME=$fake/.codex "$harness/find-transcripts.sh" --cwd /Users/a.b/.t3/repo | cut -f3 | sed "s#^$fake/##" | sort | tr '\n' ' ')
expect "find-transcripts lists one workspace across harnesses" "$found" \
	".claude/projects/-Users-a-b--t3-repo/s1.jsonl .codex/sessions/2026/10/01/rollout-x-1.jsonl .cursor/projects/Users-a-b-t3-repo/agent-transcripts/a/a.jsonl "

# The patched audit holds a worktree that a recent chat touched, in any harness.
mkdir -p "$tmp/re.po"
(
	cd "$tmp/re.po" && git init -q main && cd main &&
		git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init &&
		git worktree add -q ../wt-busy -b busy && git worktree add -q ../wt.cursor -b cursor &&
		git worktree add -q ../wt-idle -b idle && git worktree add -q ../glint.482 -b dot
) >/dev/null 2>&1
main=$(cd "$tmp/re.po/main" && pwd -P)
busy=$(cd "$tmp/re.po/wt-busy" && pwd -P)
wtcursor=$(cd "$tmp/re.po/wt.cursor" && pwd -P)
claude_slug=$(printf '%s' "$busy" | sed 's/[^A-Za-z0-9]/-/g')
cursor_slug=$(printf '%s' "${wtcursor#/}" | sed -E 's/[^A-Za-z0-9]+/-/g')
mkdir -p "$fake/.claude/projects/$claude_slug" "$fake/.cursor/projects/$cursor_slug/agent-transcripts/c"
echo "{\"cwd\":\"$busy\"}" >"$fake/.claude/projects/$claude_slug/s.jsonl"
echo "{\"cwd\":\"$wtcursor\"}" >"$fake/.cursor/projects/$cursor_slug/agent-transcripts/c/c.jsonl"
# A chat opened through the /var alias records /var/..., while git reports /private/var/....
git -C "$main" worktree add -q ../wt-alias -b alias >/dev/null 2>&1
wtalias=$(cd "$tmp/re.po/wt-alias" && pwd -P)
logical=${wtalias#/private}
alias_slug=$(printf '%s' "$logical" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$fake/.claude/projects/$alias_slug"
echo "{\"cwd\":\"$logical\"}" >"$fake/.claude/projects/$alias_slug/s.jsonl"
# glintX482 must not count as a chat in glint.482.
echo "{\"cwd\":\"${main%/main}/glintX482\"}" >"$fake/.claude/projects/$claude_slug/decoy.jsonl"
rgdir=$(dirname "$(command -v rg)")
audit=$(cd "$main" && HOME=$fake CODEX_HOME=$fake/.codex PATH=/usr/bin:/bin:$rgdir \
	bash "$plugin/skills/poteto-mode/scripts/worktree-audit.sh" 2>/dev/null)
bucket() { awk -F'\t' -v w="$1" '$9 ~ ("/" w "$") {print $8}' <<<"$audit"; }
expect "worktree-audit holds a worktree with a recent Claude chat" "$(bucket wt-busy)" "verify-recent-chat"
expect "worktree-audit holds a worktree with a recent Cursor chat" "$(bucket 'wt.cursor')" "verify-recent-chat"
expect "worktree-audit leaves an idle worktree for review" "$(bucket wt-idle)" "review"
[[ $wtalias == /private/* ]] && expect "worktree-audit sees a chat recorded under the /var alias" "$(bucket wt-alias)" "verify-recent-chat"
expect "worktree-audit matches paths literally, not as regex" "$(bucket 'glint.482')" "review"
audit_norg=$(cd "$main" && HOME=$fake PATH=/usr/bin:/bin bash "$plugin/skills/poteto-mode/scripts/worktree-audit.sh" 2>/dev/null)
expect "worktree-audit holds everything when rg is missing" \
	"$(awk -F'\t' 'NR > 1 {print $8}' <<<"$audit_norg" | sort -u | tr '\n' ' ')" "verify-recent-chat "

# A helper that crashes must hold every worktree, not report them idle.
mkdir -p "$tmp/broken/skills/poteto-mode/scripts" "$tmp/broken/skills/pstack-harness/scripts"
cp "$plugin/skills/poteto-mode/scripts/worktree-audit.sh" "$tmp/broken/skills/poteto-mode/scripts/"
printf '#!/bin/sh\nexit 1\n' >"$tmp/broken/skills/pstack-harness/scripts/find-transcripts.sh"
chmod +x "$tmp/broken/skills/pstack-harness/scripts/find-transcripts.sh"
audit_broken=$(cd "$main" && HOME=$fake PATH=/usr/bin:/bin:$rgdir bash "$tmp/broken/skills/poteto-mode/scripts/worktree-audit.sh" 2>/dev/null)
expect "worktree-audit holds everything when the transcript helper fails" \
	"$(awk -F'\t' 'NR > 1 {print $8}' <<<"$audit_broken" | sort -u | tr '\n' ' ')" "verify-recent-chat "

((failures == 0)) && echo "all checks passed" || { echo "$failures check(s) failed"; exit 1; }
