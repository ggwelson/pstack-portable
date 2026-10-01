#!/usr/bin/env bash
# Rebuild plugins/pstack from upstream cursor/plugins and re-apply the portability layer.
#
#   ./sync.sh                  re-import the ref pinned in UPSTREAM
#   ./sync.sh --ref main       import a newer upstream ref and pin it
#   ./sync.sh --into DIR       build into DIR instead (tests/check.sh uses this)
#
# The layer is small on purpose. Upstream files stay verbatim except for:
#   1. patches/*.patch, applied in order
#   2. one adapter pointer line under the H1 of each SKILL.md that names Cursor things
#   3. agents/openai.yaml next to each skill marked disable-model-invocation, because
#      Codex ignores that flag and would load every hidden skill into context
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
repo=https://github.com/cursor/plugins.git
ref=$(awk '$1 == "ref" {print $2}' "$root/UPSTREAM" 2>/dev/null || true)
into=$root/plugins/pstack
pin=1

while (($#)); do
	case $1 in
		--ref) ref=$2; shift 2 ;;
		--into) into=$2; pin=0; shift 2 ;;
		*) echo "usage: sync.sh [--ref REF] [--into DIR]" >&2; exit 2 ;;
	esac
done
ref=${ref:-main}

# Paths under plugins/pstack that this repo owns. Upstream never writes them.
owned=(.claude-plugin .codex-plugin skills/pstack-harness)
team_kit=(deslop control-cli control-ui)

# Matches the Cursor-specific names that pstack-harness translates.
cursor_terms='\bTask\b|subagent_type|AskQuestion|TodoWrite|todolist|run_in_background|generalPurpose|inherit-parent|pstack-models|agent-transcripts|\.cursor/|[Cc]ursor|grok-|claude-opus|gpt-5|/loop|[Bb]ugbot|create-skill|\bOrigin\b'
pointer='> Outside Cursor, read `../pstack-harness/SKILL.md` once per session first. It maps the Cursor tools, model slugs, and paths in this skill to your harness.'

cache=${TMPDIR:-/tmp}/pstack-upstream
if [[ ! -d $cache/.git ]]; then
	git init -q "$cache"
	git -C "$cache" remote add origin "$repo"
	git -C "$cache" sparse-checkout set pstack cursor-team-kit
fi
git -C "$cache" fetch -q --depth 1 origin "$ref"
git -C "$cache" checkout -q --force FETCH_HEAD
sha=$(git -C "$cache" rev-parse HEAD)
echo "sync: upstream $ref is $sha"

mkdir -p "$into"
if [[ $into != "$root/plugins/pstack" ]]; then
	for p in "${owned[@]}"; do
		mkdir -p "$into/$(dirname "$p")"
		rm -rf "${into:?}/$p"
		cp -R "$root/plugins/pstack/$p" "$into/$p"
	done
fi

excludes=()
for p in "${owned[@]}"; do excludes+=(--exclude "/$p/"); done
rsync -a --delete "${excludes[@]}" "$cache/pstack/" "$into/"
for s in "${team_kit[@]}"; do
	rm -rf "${into:?}/skills/$s"
	cp -R "$cache/cursor-team-kit/skills/$s" "$into/skills/$s"
done
cp "$cache/cursor-team-kit/LICENSE" "$into/LICENSE.cursor-team-kit"

# 1. Patch paths start with a/plugins/pstack/, so strip three components.
for patch in "$root"/patches/*.patch; do
	[[ -e $patch ]] || continue
	if ! patch -s -p3 -N -d "$into" <"$patch"; then
		echo "sync: $(basename "$patch") no longer applies to upstream $sha. Refresh it, then rerun." >&2
		exit 1
	fi
done

# 2 and 3 run on every upstream skill, including new ones.
for dir in "$into"/skills/*/; do
	dir=${dir%/}
	name=$(basename "$dir")
	[[ $name == pstack-harness ]] && continue
	skill=$dir/SKILL.md
	[[ -f $skill ]] || continue

	if grep -rqE "$cursor_terms" "$dir" && ! grep -qF '../pstack-harness/SKILL.md' "$skill"; then
		awk -v line="$pointer" '
			!done && /^# / { print; print ""; print line; done = 1; next }
			{ print }
		' "$skill" >"$skill.tmp" && mv "$skill.tmp" "$skill"
	fi

	if awk '/^---$/ {n++; next} n == 1' "$skill" | grep -qE '^disable-model-invocation: *true'; then
		mkdir -p "$dir/agents"
		printf 'interface:\n  display_name: "%s"\n  short_description: "Part of pstack. Invoke it explicitly."\npolicy:\n  allow_implicit_invocation: false\n' \
			"$name" >"$dir/agents/openai.yaml"
	fi
done

if ((pin)); then
	printf 'repo %s\nref %s\n' "$repo" "$sha" >"$root/UPSTREAM"
	echo "sync: pinned $sha in UPSTREAM. Review with git diff, then run tests/check.sh."
fi
