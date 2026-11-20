<p align="center"><img src="assets/banner.png" alt="hutch: hand coding tasks to cheaper models in a locked-down sandbox, verify before you merge"></p>

# hutch

**Let Claude Code, Codex or any host agent hand bounded coding tasks to cheaper models (DeepSeek, Kimi, GLM, Qwen via
OpenCode Go, or the DeepSeek API) in a locked-down Docker sandbox, then verify the result before it reaches your
repository.**

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Agent skill](https://img.shields.io/badge/agent%20skill-SKILL.md-6366F1.svg)](skills/hutch/SKILL.md)

hutch hands one bounded coding task to a cheaper coding agent running in an isolated container, and gives the result
back to your main agent (or to you) for review. The sandbox agent writes the code; the host side writes the brief and
verifies.

- **Agents:** the [opencode](https://opencode.ai) CLI (default) or Claude Code.
- **Providers:** OpenCode Go (default), the DeepSeek API, or any Anthropic-format API you describe in
  `~/.hutch/providers/<name>.conf` (Claude Code agent). The model is chosen by the kind of work (`HUTCH_KIND`).
- **Isolation:** the container has no capabilities, sees only its own clone of the repository, and has no route out.
  Its only peer is a per-run zero-knowledge gate that authenticates a per-run `HUTCH_PROXY_TOKEN`, strips alternative
  auth headers, forwards only plain paths (no dot segments, no query string except `?beta=true`), injects the real host key in-flight only for allowed API paths, and logs every call.
  Dependency/build caches (`cache_overlays`) mount read-only under ephemeral per-run copy-on-write layers so the sandbox
  runs warm offline without risking host cache poisoning. Results come back as a git bundle.
- **Any project:** each project describes its toolchain, checks and protected paths in a small config directory.

## Why

- **Cost.** Your strong model writes a short brief and reviews a diff; a cheap model does the reading, coding, testing
  and committing.
- **Containment.** The sandbox has no capabilities and its own clone of the repository, and reaches nothing but the
  model API: no package registry, Git host, DNS or host port.
- **Verification.** `hutch verify` rejects any change outside the task's allow list or in a protected path, then runs
  the project's checks offline. You (or your agent) still review the diff before taking the commits.

## Example run

One task on a small Node project: add seconds and days to a duration parser and reject invalid input.

| | |
|---|---|
| Model | `HUTCH_KIND=script` → `deepseek-v4.1-flash` on OpenCode Go |
| Time | 7 min 18 s, exit 0 |
| Result | 3 commits, 2 files, tests from 2 to 15, a self-review with a 10-mutation table |
| `hutch verify` | both paths allowed, 15/15 tests pass in the offline container |
| `hutch isolation` | model host reachable; GitHub, npm, PyPI, DNS and host ports blocked; `CapEff` all zeros |

## How it works

```
host                                          container (no network except the model API)
----                                          -------------------------------------------
hutch new    clone base branch  ───────────▶  /work (private clone, branch hutch/<task>)
hutch run    brief + primer + rules ───────▶  agent edits, tests, commits
hutch export                     ◀───────────  git bundle (git runs in a network-less container)
hutch verify fetch → refs/hutch/<task>
             path rules (allow / protected)
             project checks, offline container
you          review the diff, take the commits
```

## Requirements

- macOS or Linux with Docker. On macOS the system bash 3.2 is enough.
- `git`, `python3` (for `hutch report` and the Claude Code agent's mid-run messages).
- An OpenCode Go subscription or a DeepSeek API key.
- arm64 or x86-64 (amd64): the opencode binary is pinned by sha256 for both in `image/Dockerfile`.

## Install

```sh
git clone <this repository> ~/hutch
ln -s ~/hutch/hutch ~/.local/bin/hutch          # any directory on PATH
security add-generic-password -a "$USER" -s opencode-go -w   # macOS: prompts for the OpenCode Go key
hutch build                                      # base image, gate image, networks
hutch status
```

On Linux store the key with `secret-tool store --label='hutch opencode-go' service opencode-go`, or export
`HUTCH_API_KEY`. For DeepSeek, use the service name `deepseek-api` and `HUTCH_PROVIDER=deepseek HUTCH_AGENT=claude`.

Updates: `git -C ~/hutch pull`, then `hutch build` if `image/` changed or the gate image was updated. Every project uses the same
checkout, so a fix reaches all of them at once.

## Providers

A provider is a small `key=value` file: [providers/opencode.conf](providers/opencode.conf) (OpenCode Go) and
[providers/deepseek.conf](providers/deepseek.conf) ship with hutch. To use another Anthropic-format API (an
aggregator, a self-hosted gateway), add `~/.hutch/providers/<name>.conf` with `upstream=https://host`, `key_item=`,
`paths=` (the path prefixes the gate may forward), `claude_base=` and `models=<name>.tsv` (a model table next to it),
store the key under `key_item`, and run with `HUTCH_PROVIDER=<name> HUTCH_AGENT=claude`. The opencode agent works with
the providers opencode ships (`opencode_provider=`), because the sandbox cannot download others.

## Set up a project

Open your agent in the project and ask it to use hutch. The agent runs `hutch status`, sees that the project is not
set up, and follows [AGENTS.md](AGENTS.md#project-setup): it reads the project, asks you a few questions (consent to
send the code to the provider, where to keep the config, toolchain, checks, protected and sensitive paths) and writes
the config, then proves it with a build, a smoke test and an isolation check.

By hand: `hutch init` (or `hutch init --in-repo`) copies [template/](template/) and you fill in each file:

| File | Purpose |
|---|---|
| `config` | `base_branch`, `manifests`, `cache_overlays`, `cache_overlay_mode`, `scope_mode`, `max_turns`, `loop_threshold`, limits |
| `Dockerfile` | `FROM hutch-base` plus the project's toolchain, caches warmed for offline use |
| `verify.sh` | the checks `hutch verify` runs offline, per changed area |
| `protected` | paths the agent may never change |
| `openable` | protected paths a task may open explicitly |
| `pro-paths` | sensitive paths that need a strong model |
| `primer.md` | verified pointers the agent reads first |
| `checklist.md` | the project's own review items (optional) |

The config lives in `<repo>/.hutch/` (committed with the project) or in `~/.hutch/projects/<name>/` (only on this
computer, for shared repositories). hutch looks in that order.

## Commands

| Command | |
|---|---|
| `hutch status` | machine, cache overlay readiness, and project state (exit 3: project not set up, 4: machine/cache missing) |
| `hutch init [--in-repo]` | create the project config from the template |
| `hutch build` | build the images |
| `hutch new <task> [<allow> <brief>] [options]` | clone base branch; supports `--allow`, `--brief`, `--opened`, `--context path[:start-end]` |
| `HUTCH_KIND=<kind> hutch run [options] <task>` | run agent with watchdog (`--context`, `--max-turns`, `--max-timeout`, `--loop-threshold`; exit 42/43/44/124) |
| `hutch batch [options] <task1> <task2>...` | run tasks concurrently (`--max-parallel`, `--max-turns`, `--max-timeout`, `--loop-threshold`) |
| `hutch say <task> <message>` | follow-up message |
| `hutch shell <task>` | interactive agent session in the sandbox |
| `hutch export <task>` / `hutch verify [options] <task>` | bundle the result / two-tier check (`--soft-scope`, `--strict-scope`, `--allow-tests`, `--allow`; strict scope is the default) offline |
| `hutch report <task>` | model, tokens, time, commits, verify status, test changes, unscoped/scope warnings (`report.md`) |
| `hutch ls` | the project's tasks: age, running or exit code, verify status, commits, model |
| `hutch rm <task>` | remove the task |
| `hutch smoke <task>` / `hutch isolation <task>` | model call / isolation, proxy-token, and mount probes |
| `hutch models` | model per kind, skipped models |

Environment: `HUTCH_KIND`, `HUTCH_MODEL`, `HUTCH_SMALL_MODEL`, `HUTCH_PHASE` (`design`/`build`), `HUTCH_AGENT`,
`HUTCH_PROVIDER`, `HUTCH_BRANCH`, `HUTCH_OPENED`, `HUTCH_CONTEXT`, `HUTCH_PROJECT` (use a home config from outside the
repository), `HUTCH_HOME` (default `~/.hutch`), `HUTCH_API_KEY`, `HUTCH_MEMORY`, `HUTCH_PIDS`, `HUTCH_RUNTIME`,
`HUTCH_RUN_TIMEOUT`, `HUTCH_VERIFY_TIMEOUT`, `HUTCH_MAX_TURNS`, `HUTCH_LOOP_THRESHOLD`, `HUTCH_STRICT_SCOPE`,
`HUTCH_SOFT_SCOPE`, `HUTCH_ALLOW_TESTS`, `HUTCH_CACHE_OVERLAYS`, `HUTCH_CACHE_OVERLAY_MODE`, `HUTCH_EFFORT`, `HUTCH_IDLE_S`.

## Agent skill

[skills/hutch/SKILL.md](skills/hutch/SKILL.md) is a short [Agent Skill](https://agentskills.io) that teaches a host
agent the hutch loop: check `hutch status`, write the brief, run, verify, review the diff. This repository is also a
Claude Code plugin marketplace, so in Claude Code it installs with:

```
/plugin marketplace add byarashboev/hutch
/plugin install hutch@hutch
```

The plugin carries only the skill: install the `hutch` CLI and Docker as above. To follow your own checkout instead,
link it: `mkdir -p ~/.claude/skills && ln -s ~/hutch/skills/hutch ~/.claude/skills/hutch` (use one or the other, not
both). Other agents read the same `SKILL.md` from their own skills directory. [AGENTS.md](AGENTS.md) stays the full
guide.

## Universal rules

[rules/sandbox.md](rules/sandbox.md) is what the sandbox agent always follows, and
[rules/checklist.md](rules/checklist.md) is the senior checklist it designs and self-reviews against. A project adds
its own items in its `checklist.md`; nothing project-specific goes into this repository.

## Limits

- The model provider sees the code you send it. Never put production data or credentials into a task.
- The sandbox never holds the provider key, but it can use it through the gate for the provider's API paths during a
  run (that is how the agent works), so a run can spend quota up to `run_timeout`. The gate's access log is kept as
  `gate.log` in the task's out directory.
- A Docker container shares the kernel of Docker's VM with your other containers. `runtime=runsc` in the project
  config (or `HUTCH_RUNTIME=runsc`) runs the sandbox and the checks under [gVisor](https://gvisor.dev), a user-space
  kernel, on Linux hosts where it is installed; CI runs the end-to-end test under it. For a microVM boundary, see
  [brig](https://github.com/brig-sh/brig).
- `verify` passing means the paths and the project's offline checks are fine, not that the change is correct.
  Review the diff.

## License

Copyright 2026 Yarashboev Bahodir. Licensed under the [Apache License, Version 2.0](LICENSE); see [NOTICE](NOTICE).
