---
name: pstack-harness
description: Translates the Cursor tools, model slugs, and paths that pstack skills name into the harness you are running in (Claude Code, Codex, or another agent). Read it before the first spawn, question, todo list, or transcript lookup that a pstack skill asks for.
disable-model-invocation: true
---

# pstack outside Cursor

The pstack skills next to this one are copied verbatim from Cursor's plugin. They name Cursor tools (`Task`, `AskQuestion`, `TodoWrite`), Cursor model slugs, and Cursor paths. Keep following the skill as written. When it names a Cursor thing, do the equivalent below. Cursor itself needs none of this.

Read this file once per session. You do not need to re-read it for each skill.

## Sibling skills

Every pstack skill lives in a folder next to this one. "The **how** skill" means `../how/SKILL.md`, resolved from the folder of the skill you are reading. The same holds for `principle-*` skills, playbooks named by relative path, and the three skills upstream ships in `cursor-team-kit` (`deslop`, `control-cli`, `control-ui`), which are bundled here. Read the file directly. Most pstack skills hide from automatic invocation, so a skill tool may not find them by name.

Claude Code prints each loaded skill's base directory. Codex lists each skill's path. Resolve relative paths from there.

## Which harness you are in

Look at your own tool list.

| Tools you have | Harness | `--harness` value |
|---|---|---|
| `Agent` (older builds call it `Task`) and `AskUserQuestion` | Claude Code | `claude` |
| `spawn_agent`, `wait_agent`, `update_plan` | Codex | `codex` |
| `Task` and `AskQuestion` | Cursor. Stop reading. Everything works natively. | `cursor` |
| No way to spawn a subagent | Single agent | `none` |

T3 Code, Conductor, and similar apps run one of these harnesses underneath. Decide by the tools you see, not by the app's name.

## Cursor tools and their equivalents

| A pstack skill says | Claude Code | Codex | No subagents |
|---|---|---|---|
| `Task` | `Agent` | `spawn_agent` | Do the step yourself, in order, and say so in the reply. |
| `subagent_type: generalPurpose` | `subagent_type: "general-purpose"` | The default agent type | Not applicable. |
| `subagent_type: "poteto-agent"` | `"pstack:poteto-agent"` when the plugin is installed. Otherwise `"general-purpose"` with the poteto brief below. | Default agent with the poteto brief below. | Read `../poteto-mode/SKILL.md` yourself. |
| `subagent_type: "Comment Sicko"` | `"pstack:Comment Sicko"` when the plugin is installed, or `"general-purpose"` given the body of `../../agents/comment-sicko.md` as its brief. Resolve this folder with `realpath` first if it is a symlink. | Default agent given that file's body as its brief. | Review with that file's rules yourself. |
| `run_in_background: true` | Same parameter. Results arrive as notifications. | Spawns are already asynchronous. Collect with `wait_agent`. | Not applicable. |
| Several spawns "in one message" | Several `Agent` calls in one response. | Several `spawn_agent` calls, then one `wait_agent` on all ids. | Run them one after another. |
| `readonly: true` | Put "Read-only. Do not edit files." in the brief. Use `Explore` only for pure search, because it reads excerpts. | Put the same line in the brief. | Not applicable. |
| `readonly: false` (agent mode, keeps MCP) | `general-purpose`. It keeps MCP tools. | The default agent keeps MCP tools. | Not applicable. |
| `environment: "cloud"`, `cloud_base_branch` | `isolation: "remote"` where your build offers it, else `isolation: "worktree"`. | A local `git worktree add` per worker. Name its path in the brief. | One worktree at a time. |
| `environment: "local"` | Omit isolation. | The default. | The default. |
| Resume a subagent | `SendMessage` to its id. | `send_input`. | Not applicable. |
| `model: <slug>` | See **Models** below. | See **Models** below. | Ignore. |
| `AskQuestion` | `AskUserQuestion` | `request_user_input` when you have it. Otherwise ask in the reply and end the turn. | Ask in the reply and end the turn. |
| `TodoWrite`, "open a todolist" | The task or todo tool you have (`TodoWrite`, `TaskCreate`). If none, a markdown checklist in the reply. | `update_plan` | A markdown checklist in the reply, re-posted as steps finish. |
| Cursor's `/loop` | `/loop`, or `ScheduleWakeup` and `CronCreate` when present. | `/goal <objective>` for run-until-done. Codex has no timer. Poll with a bounded `sleep` loop in the shell. | Keep working in the turn. Poll with a bounded `sleep`. |
| `create-skill` (Cursor built-in) | `skill-creator` if installed. Otherwise follow `../poteto-mode/playbooks/authoring-a-skill.md` alone. | `$skill-creator` | The playbook alone. |
| Cursor's built-in `babysit` | Does not exist here. Use the Babysit playbook. | Same. | Same. |
| Read, Grep, Glob | Same names. | Shell `rg`, `sed`, `ls`. | Your file tools. |

## The poteto brief

Upstream's `poteto-agent` is a general agent that reads `poteto-mode` before working. Start every playbook delegate's brief with these lines, using the absolute path of the `poteto-mode` folder you resolved:

```
Before any work, read <abs>/poteto-mode/SKILL.md in full, including its Principles index.
Before you apply a principle, read its skill in full at <abs>/principle-<name>/SKILL.md.
Where it names a Cursor tool, model slug, or path, read <abs>/pstack-harness/SKILL.md for the equivalent.
```

Keep these lines even when Claude Code offers `pstack:poteto-agent`, so the delegate does not have to search for the files.

## Models

Skills name a role ("the `how explorer` line") and a Cursor slug default (`grok-4.7-xhigh-fast`, `claude-opus-5-5-max`, `gpt-5.6-sol-max`). Resolve the value in three steps.

1. **Read the role line.** Outside Cursor, "the `pstack-models.mdc` rule" means the first of these files that exists: `~/.config/pstack/models.md`, then `~/.cursor/rules/pstack-models.mdc`. The format is the same in both files. A missing file or line means the skill's default.
2. **Resolve it.** Run `scripts/run-agent.sh --harness <value> --resolve '<model>'` from this skill's folder. It prints one line.
   - `native` means spawn natively and omit the model parameter.
   - `native <model>` means spawn natively and pass that model.
   - `cli <spec>` means run the brief through the runner below.
   - `unavailable <reason>` means use `inherit` for that seat and name the substitution in the reply.
3. **Spawn.** A panel (arena runners, architect runners, interrogate reviewers) resolves each entry on its own. Native and CLI seats run in parallel. A seat that falls back to `inherit` still counts, so the panel keeps its size.

The resolver keeps a model native when its family matches your harness. It sends any other family to `cursor-agent`, which accepts upstream's exact slugs. Without `cursor-agent` it uses the family's own CLI (`claude`, `codex`). Values in `~/.config/pstack/models.md` may also be explicit runner specs:

| Value | Meaning |
|---|---|
| `inherit`, `inherit-parent`, `auto` | A native subagent on your own model. |
| `claude/<model>[@<effort>]` | Claude, natively in Claude Code, else `claude -p`. Model is `opus`, `sonnet`, `haiku`, `fable`, or a full id. |
| `codex/[<model>][@<effort>]` | OpenAI, natively in Codex, else `codex exec`. No model means Codex's configured default. |
| `cursor/<slug>` | Always `cursor-agent` with that slug. Use it for Grok and Gemini. |
| a bare Cursor slug | Same as upstream. The resolver picks native, `cursor-agent`, or the family CLI. |

Effort is one of `low`, `medium`, `high`, `xhigh`, `max`. Native Claude Code spawns cannot set effort. When the effort matters, write the role as `cli`-only by using a `cursor/` spec.

## Running a CLI seat

The CLI agent sees none of your conversation. Write the full brief to a file first. Then run:

```bash
<this-skill>/scripts/run-agent.sh --harness <value> --model '<value>' \
  --prompt-file /tmp/pstack/<run>/brief-a.md --out /tmp/pstack/<run>/out-a.md \
  [--read-only] [--cwd <repo>] [--timeout 1800]
```

It writes the agent's final message to `--out` and its log to `<out>.log`. A nonzero exit means the seat failed. Read the log and apply the `unavailable` rule. Launch every CLI seat in the background so the panel runs in parallel. In Claude Code, use the shell tool's `run_in_background`. In Codex, end each command with `&`, then `wait`. Codex's sandbox blocks network for child CLIs, so request escalated permissions for these commands. A headless session (`claude -p`, `codex exec`) exits when your turn ends, so there you wait for every seat in the foreground before you synthesize.

`--read-only` maps to `claude --permission-mode plan`, `codex exec -s read-only`, and `cursor-agent --mode ask`. All three can still run read-only shell commands such as `git diff`. Without it, the seat may edit files in `--cwd`, so give each writing seat its own worktree. A writing Claude seat can edit files but cannot run shell commands unless `PSTACK_CLAUDE_PERMISSION_MODE=bypassPermissions` is set.

## Transcripts

Several skills read "the active workspace's `agent-transcripts/` directory" and warn against globbing `~/.cursor/projects/*/`. Outside Cursor, run `scripts/find-transcripts.sh`. It lists this workspace's transcripts from Claude Code, Codex, and Cursor, newest first, one `<epoch> <harness> <path>` per line. `--self` prints only the current session's transcript. `--days N` limits the window. It never reads another workspace unless you pass `--cwd`. Keep the upstream rule. Read another project's transcripts only when the user asks.

| Harness | Location |
|---|---|
| Claude Code | `~/.claude/projects/<cwd with each non-alphanumeric character as ->/<session>.jsonl`, with subagents under `<session>/subagents/` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. The first line records `cwd`. |
| Cursor | `~/.cursor/projects/<slug>/agent-transcripts/` |

A "cloud-agent URL" in session pickup can also be a Claude Code web session or a Codex cloud task. Open it with the matching tool, or ask for a pushed branch.

## Paths and names

| A pstack skill says | Outside Cursor |
|---|---|
| `.cursor/skills/<name>/` (project skill) | Write it to `.agents/skills/<name>/`. Add a relative symlink at `.claude/skills/<name>` for Claude Code. Keep `.cursor/skills/<name>` too if the team uses Cursor. |
| `~/.cursor/skills/` (user skill) | `~/.claude/skills/` for Claude Code, `~/.agents/skills/` for Codex. |
| `.cursor/rules/*.mdc` (always-applied rule) | `CLAUDE.md` for Claude Code, `AGENTS.md` for Codex. |
| "the Cursor environment" (for MCP discovery) | Your own tool list. MCP tools appear as `mcp__<server>__<tool>` in Claude Code and under their server name in Codex. |
| Bugbot, "the agentic security review" | Any automated PR reviewer: Cursor Bugbot, GitHub Copilot, CodeRabbit, Claude or Codex review bots, security scanners. Triage them all with `../poteto-mode/references/bugbot-triage.md`. |
| A Cursor restart | A restart of your harness. Local subagents die. Pushed branches, open PRs, and files on disk survive. |
| `/setup-pstack` | Run it as written, with three changes. Detect models with `scripts/run-agent.sh --list-models`. Write `~/.config/pstack/models.md` without the `.mdc` front matter instead of `~/.cursor/rules/pstack-models.mdc`. Accept runner specs (`codex/gpt-6@xhigh`) as values. |

`make-bot-ui` and the benny automations drive Cursor automations, so they still need a Cursor account. Origin is Cursor's internal merge tool. The skills already fall back to `gh` when `command -v origin` fails.
