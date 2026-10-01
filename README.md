# pstack-portable

> Copied from [pstack](https://github.com/cursor/plugins/tree/main/pstack) by [poteto](https://x.com/poteto) (Lauren Tan), which lives in [cursor/plugins](https://github.com/cursor/plugins). All skills, playbooks, and principles are poteto's work. This repo only repackages them to run outside Cursor.

pstack is poteto's set of rigorous agent workflows for Cursor. This repo packages it for Claude Code, Codex, and apps built on them such as T3 Code.

The skills are upstream's, unchanged. A small layer maps the Cursor tools, model slugs, and paths they name to the harness that runs them. `sync.sh` re-imports upstream and re-applies the layer, so you track poteto's releases instead of maintaining a diverging copy.

## Install

Clone this repo somewhere it will stay. Both harnesses install from the clone.

```bash
git clone https://github.com/ggwelson/pstack-portable.git
```

**Claude Code**

```bash
claude plugin marketplace add <path-to>/pstack-portable
claude plugin install pstack@pstack-portable
```

Skills are namespaced: `/pstack:poteto-mode`, `/pstack:how`, `/pstack:interrogate`.

**Codex**

```bash
codex plugin marketplace add <path-to>/pstack-portable
codex plugin add pstack@pstack-portable
```

Mention skills with `$`: `$pstack:poteto-mode`, `$pstack:how`, `$pstack:interrogate`.

**T3 Code** runs Claude Code and Codex underneath, so it uses whichever of the two installs matches the thread's provider.

**Other harnesses** that read `~/.agents/skills` or `~/.claude/skills` can take the skills as symlinks. This loop skips any name you already have, such as your own `unslop`:

```bash
for d in <path-to>/pstack-portable/plugins/pstack/skills/*/; do
  n=$(basename "$d"); [ -e ~/.agents/skills/"$n" ] || ln -s "${d%/}" ~/.agents/skills/"$n"
done
```

**Cursor** has pstack natively. Use `/add-plugin pstack` there, not this repo.

## How it works outside Cursor

Start with `/pstack:poteto-mode` (or `$pstack:poteto-mode`) exactly as upstream's README describes. Every skill that names a Cursor tool has one added line pointing at `skills/pstack-harness/SKILL.md`. The agent reads that file once per session. It translates the following:

| Upstream says | Claude Code | Codex |
|---|---|---|
| `Task`, `subagent_type: generalPurpose` | `Agent`, `general-purpose` | `spawn_agent` |
| `subagent_type: "poteto-agent"` | `pstack:poteto-agent` | default agent with a "read poteto-mode first" brief |
| `AskQuestion` | `AskUserQuestion` | `request_user_input`, or ask in the reply |
| `TodoWrite` | the todo or task tool | `update_plan` |
| `/loop` | `/loop` | `/goal` |
| `~/.cursor/projects/*/agent-transcripts` | `find-transcripts.sh` | `find-transcripts.sh` |
| `~/.cursor/rules/pstack-models.mdc` | read as-is, or `~/.config/pstack/models.md` | same |

### Multi-model panels

`interrogate`, `arena`, `architect`, and `reflect` get their value from several model families reviewing the same work. Claude Code's subagents only run Claude models, and Codex's only run OpenAI models. `run-agent.sh` bridges the gap.

- A model from your harness's family runs as a native subagent. `claude-opus-5-5-max` in Claude Code becomes `Agent` with `model: opus`.
- Any other model runs headless through `cursor-agent`, which accepts upstream's exact slugs (`grok-4.7-xhigh-fast`, `gpt-5.6-sol-max`). An effort the account lacks steps down, so `-max` falls back to `-xhigh`. This is upstream's own `/setup-pstack` rule.
- Without `cursor-agent`, Claude models go through `claude -p` and GPT models through `codex exec`. Anything else falls back to your own model, and the reply says so.

If you already ran `/setup-pstack` in Cursor, your `~/.cursor/rules/pstack-models.mdc` drives every harness with no changes. To pick models per harness, write `~/.config/pstack/models.md` in the same format. That file wins, and its values may be runner specs as well as slugs:

```
interrogate reviewers: claude/opus@max, codex/gpt-6-astra@xhigh, cursor/grok-4.7-xhigh-fast
how explorer: claude/sonnet
swarm workers: inherit
```

`run-agent.sh --list-models` shows what each CLI on your machine can run.

## What differs from upstream

| Change | Why |
|---|---|
| `skills/pstack-harness/` (new) | The translation table, `run-agent.sh`, and `find-transcripts.sh`. |
| One pointer line under the H1 of 17 skills | Without it, Codex read the model config, decided the configured Opus explainer was unavailable, and ran that seat on its own model. |
| `agents/openai.yaml` next to 47 skills | Codex ignores `disable-model-invocation`, so every hidden skill would load into each Codex session. The sidecar is Codex's own way to hide a skill. |
| `patches/0001`, `worktree-audit.sh` | Upstream's prune audit only reads Cursor transcripts. It also builds the wrong Cursor directory name for paths with dots, so on a `/Users/first.last` machine it never finds recent chats. On one real repo it marked four worktrees safe to prune that agents had used in the last three days. The patch reads all three harnesses, matches paths literally, and holds everything when it cannot scan. |
| `patches/0002`, two skill names | `name: Poteto Mode` has a space, which a Codex `$` mention cannot match, so Codex could not invoke the main skill. Now `poteto-mode` and `make-bot-ui` match their folders. |
| `deslop`, `control-cli`, `control-ui` | Upstream points at these in `cursor-team-kit`. They are copied in unchanged. |
| Plugin manifests | `.claude-plugin/` and `.codex-plugin/` sit next to upstream's `.cursor-plugin/`. |

`make-bot-ui` and the benny automations drive Cursor automations, so they still need a Cursor account.

## Staying current

```bash
./sync.sh --ref main   # import upstream main and pin its commit in UPSTREAM
git diff               # review what poteto changed
tests/check.sh         # verify the layer still holds
```

If a patch no longer applies, `sync.sh` names it and stops. Refresh the patch against the new upstream file and rerun. Change upstream files only through `patches/`. `tests/check.sh` fails when the tree differs from what `sync.sh` builds.

`tests/check.sh` also validates both plugin manifests and runs the resolver against stub CLIs. It checks transcript scoping against literal directory names from each harness, and runs the patched audit against a throwaway repo.

## Limits

- Native Claude Code subagents cannot set reasoning effort. `@effort` applies to CLI seats only.
- Codex's sandbox blocks network for CLI seats, so Codex asks to escalate those commands.
- A Claude CLI seat that writes can edit files but cannot run shell commands unless `PSTACK_CLAUDE_PERMISSION_MODE=bypassPermissions` is set. Read-only seats use plan mode and can run `git diff`.
- In headless runs (`claude -p`, `codex exec`) the lead has to wait for panel seats in the foreground. The process exits when its turn ends.
- `worktree-audit.sh` stays macOS-only (`stat -f`), as upstream.

## License

MIT. pstack is © 2026 Lauren Tan (`plugins/pstack/LICENSE`). The three `cursor-team-kit` skills are © 2026 Cursor (`plugins/pstack/LICENSE.cursor-team-kit`). See `LICENSE` for the layer.
