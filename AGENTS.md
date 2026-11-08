# hutch: instructions for the host agent

You are the agent on the host (Claude Code, Codex or similar). hutch hands one bounded coding task to a cheaper agent
(opencode or Claude Code, on OpenCode Go or the DeepSeek API) inside an isolated container. **The sandbox agent writes
the code; you write the brief and verify the result.** This file tells you how to set hutch up and how to use it. The
README is the same material for people.

## Start here, every time

Before any other hutch command in a project, run `hutch status` from inside that project and act on its exit code:

| Exit | Meaning | What you do |
|---|---|---|
| 0 | Machine and project are set up | Go to [Working with hutch](#working-with-hutch). |
| 4 | Something on this computer is missing (Docker, key, images) | Do [Machine setup](#machine-setup) for the lines marked MISSING. |
| 3 | This project is not set up | Do [Project setup](#project-setup). Do not run tasks until it is finished. |

Any other hutch command in a project that is not set up stops with exit 3 and points here. Never work around that by
writing a config without the user's answers.

If `hutch` is not on PATH, use the full path of the `hutch` script next to this file.

## Machine setup

Once per computer. Ask the user before each step that installs or stores something.

1. **Docker** must be running (`docker info`).
2. **Command on PATH**: `ln -s <this directory>/hutch ~/.local/bin/hutch` (any directory on PATH works).
3. **Provider and agent.** Ask the user which they use. The defaults are the opencode CLI (`HUTCH_AGENT=opencode`)
   on the OpenCode Go subscription (`HUTCH_PROVIDER=opencode`). The alternatives are Claude Code as the sandbox agent
   (`HUTCH_AGENT=claude`) and the paid DeepSeek API (`HUTCH_PROVIDER=deepseek`, which needs `HUTCH_AGENT=claude`).
   Any other Anthropic-format API is a provider file in `~/.hutch/providers/<name>.conf` (README, Providers). Edit
   the provider's model table if their plan has other models or limits.
4. **API key.** The user stores it; never ask them to paste a key into the chat, and never print it. Give them the
   command to run themselves:
   - macOS: `security add-generic-password -a "$USER" -s opencode-go -w` (it prompts for the key; use `deepseek-api`
     as the service name for DeepSeek).
   - Linux: `secret-tool store --label='hutch opencode-go' service opencode-go`.
   - Elsewhere: export `HUTCH_API_KEY` in the shell that runs hutch.
5. **Images**: `hutch build` builds `hutch-base`, pulls the pinned gate image and creates the two Docker networks
   (plus the project image when run inside a project that is set up).
6. Run `hutch status` again; every machine line must say ok.

The sandbox has no route out; its only peer is a gate started for each sandbox command. The gate holds the key and
forwards only the provider's `paths=` to its `upstream`. Do not widen a provider's paths or point it at another host
to make a task easier: package registries and Git hosts stay closed on purpose.

## Project setup

Once per project, when `hutch status` exits 3. Do it in this order and do not skip the questions.

### 1. Read the project first

Read the project's agent instructions (`AGENTS.md`, `CLAUDE.md`, rule directories), its README, build files
(`Makefile`, `package.json`, `go.mod`, `pyproject.toml` and so on), CI workflows and contribution or engineering docs.
From them, draft an answer to each question below, so the user confirms or corrects instead of starting from nothing.

### 2. Ask the user, in one batch

Ask these questions together, each with your drafted answer and the reason for it. Use the user's language.

1. **Consent.** May this project's source code be sent to the chosen model provider? Code only: never production data,
   credentials or personal data. If the answer is no, stop: hutch cannot be used for this project.
2. **Where the config lives.**
   - `<repo>/.hutch/`, committed with the project. Good for a personal project or when the team agrees; in a shared
     repository it goes through that repository's normal review process.
   - `~/.hutch/projects/<name>/`, only on this computer. The default for shared or team repositories.
3. **Base branch** that tasks clone (usually `main`).
4. **Toolchain.** Languages and exact versions, and the dependency manifests whose caches the image should warm, so
   the sandbox works offline. Show the versions you found.
5. **Checks.** Which format, lint, type-check and test commands prove a change, per area of the repository, and which
   of them can run with no network. These become `verify.sh` and the primer's check list.
6. **Protected paths.** Files the sandbox agent must never change. Start from `template/protected` and add the
   project's own: migrations, generated code, interface contracts, decision records, deployment manifests, fixtures.
7. **Openable paths.** Which of those protected paths a task may open when you explicitly allow it (for example
   migrations or contracts that a task must change).
8. **Sensitive paths needing a strong model.** Code where a cheap model's mistake is expensive: money, authorization,
   concurrency, migrations. These become `pro-paths`; "none" turns the rule off.
9. **Project rules for the checklist.** Which documents hold the project's hard rules (ADRs, conventions, past review
   findings). You will turn them into `checklist.md` items and show them to the user.

### 3. Write the config

1. `hutch init` (home config) or `hutch init --in-repo`. It copies `template/` and records the name and repository.
2. Fill in every file:
   - `config`: `base_branch`, `manifests` (an ERE over repository paths), `cache_mount` if the toolchain has a
     build cache worth keeping between tasks.
   - `Dockerfile`: the toolchain, pinned; warm the caches from `src/` (the manifests); end offline and as `USER hutch`.
   - `verify.sh`: the checks per changed area. Every command must work with no network. It must fail on a failing
     check.
   - `protected`, `openable`, `pro-paths`: from the answers.
   - `primer.md`: verified pointers only (layout, how to run the toolchain, the checks, test helpers). Check every line
     against the base branch before writing it; the sandbox agent trusts this file instead of exploring.
   - `checklist.md`: the project's own items with their source files, or delete it.
3. Show the user the files, or a summary of each, and apply their corrections.

### 4. Prove it works

1. `hutch build` and confirm the project image builds.
2. Create a throwaway task: an allow file with one harmless path and a one-line brief, then
   `hutch new setup-check <allow> <brief>`.
3. `HUTCH_KIND=<cheapest kind> hutch smoke setup-check`: the model answers OK.
4. `HUTCH_KIND=<cheapest kind> hutch isolation setup-check`: only the model host is reachable, nothing else answers,
   no credential directories are present, and `CapEff` is all zeros.
5. Ask the user whether to spend a small amount of model quota on one real end-to-end run of that throwaway task
   (`run`, `export`, `verify`). Do it if they agree; it proves `verify.sh` too.
6. `hutch rm setup-check`, and tell the user what was set up and what was proven.
7. Offer, without doing it unasked, to add one line to the project's own agent instructions so future agents find
   hutch: "Sandbox tasks: run `hutch status` and follow the hutch AGENTS.md it points to."

## Working with hutch

### One task

1. **Brief** (`brief.md`): the goal, the exact files to change and why, the behaviour and tests required, the checks to
   run, the steps to commit separately, and what is out of scope. Name the sources the agent must read (file paths). A
   short, precise brief beats a long one.
2. **Allow file**: the paths the task may change, bash globs, one per line. Keep it narrow.
3. **Opened file** (optional): protected patterns from `openable` this task may change, one per line, passed as
   `HUTCH_OPENED=<file> hutch new ...`. Repeat them in the brief.
4. `hutch new <task> <allow> <brief>`.
5. **Choose the model by the kind of work**: `HUTCH_KIND=<kind> hutch run <task>` (`hutch models` shows the table).
   Tasks that touch `pro-paths` or open protected paths are refused unless the kind is a strong one (`design` or
   `concurrency`). A mixed task can run `HUTCH_PHASE=design` on a strong model first (it writes
   `/out/design-notes.md`), then `HUTCH_PHASE=build` with a cheaper kind; add a "Reviewer notes" section to the
   design notes to correct them before the build.
6. After the run: `exit.code` must be 0 (124 means the run hit `run_timeout`) and `run.err` empty (both in the task's
   out directory, `~/.hutch/state/<name>/out/<task>/`). Read `self-review.md` and the end of `run.jsonl`.
7. Follow-ups: `hutch say <task> "<message>"` (opencode: after the run ends; Claude Code: during it).
8. `hutch export <task>`, then `hutch verify <task>`: it checks that every changed path is allowed and not protected,
   lists added comment lines, names changes to existing tests (deleted files, removed lines, skip markers), and runs
   `verify.sh` offline. Treat every named test change as a finding to check in the diff.
9. `hutch report <task>` gives the model, usage, commits, verify status and test changes in one page (`report.md`);
   start the review from it.
10. **Review the diff yourself** (`git -C <repo> diff <base> refs/hutch/<task>`). `verify` passing is not acceptance.
11. Take the work: create your branch from `refs/hutch/<task>` (or cherry-pick its commits) in the project, then
    continue with the project's normal process (tests that need services, review, pull request).
12. `hutch rm <task>` when it is merged or abandoned.

### Verification rules

- Never trust the sandbox agent's report, and never assume a mid-run instruction was followed: check it in the final
  diff.
- Review authorization, money, personal data, SQL, migrations and concurrency harder: mutation-test the guards, run the
  integration tests the sandbox could not run, and get an independent review.
- Run the checks that need Docker, a network or a browser on the host yourself; the sandbox cannot.
- Before doing a piece of the task yourself instead of the sandbox, tell the user which piece and why.
- When a model's limit is used up, add its name to `~/.hutch/skip` (one per line) and remove it after the reset.

## Maintaining hutch

- Update: `git -C <this directory> pull`, then `hutch build` when `image/` or `GATE_IMAGE` changed. A pull during a running
  task is safe: the script is parsed completely before it runs.
- Changing the script: keep it compatible with bash 3.2 (macOS), run `shellcheck hutch test/*.sh`, `test/run.sh` and,
  with Docker, `test/e2e.sh` (CI runs all three), and keep this file, the README and `skills/hutch/SKILL.md` in step
  with it.
- Project-specific knowledge never goes into this repository: it belongs in the project's config directory.
