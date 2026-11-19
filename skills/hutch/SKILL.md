---
name: hutch
description: Hand one bounded coding task to a cheaper coding agent (opencode or Claude Code on OpenCode Go or DeepSeek) running in an isolated Docker container, then verify the result on the host. Use when the user asks to "use hutch", to delegate or sandbox a well-scoped coding task to a cheaper model, or when a task is narrow enough to brief precisely and review as a diff.
---

# hutch

hutch runs a cheaper agent in a container that has no capabilities, sees only its own clone of the repository, and
reaches nothing except a per-run gate to the model API. The gate holds the real key and enforces a per-run proxy token (`HUTCH_PROXY_TOKEN`), so the sandbox never sees or holds credentials. **The sandbox agent writes the code. You write the brief and verify the result.**

Source and full instructions: https://github.com/byarashboev/hutch (its `AGENTS.md` is the authoritative guide; this
skill is the short version).

## 0. When NOT to Delegate vs. When to Delegate

Do not blindly delegate every edit to `hutch` — container startup, git bundling, and verification carry orchestration latency.

- **Do NOT use `hutch` (edit directly instead):**
  - Small edits (<50 lines across 1–2 files) where you already have the relevant files loaded in your context.
  - Exploratory debugging or interactive architecture Q&A where you do not yet know what needs changing.
- **DO use `hutch`:**
  - Well-bounded mechanical tasks, refactors with clear contracts/specs, or isolated unit/integration test generation.
  - **Parallel fan-out** across multiple independent modules or packages (`hutch batch t1 t2 t3`).
  - Untrusted codebases or long-running build/test loops you want isolated from host credentials and caches.

## 1. Check the state first, every time

Run `hutch status` inside the project and act on the exit code:

| Exit | Meaning | Action |
|---|---|---|
| 0 | Ready (Docker, key, images, cache overlays ok) | Go to step 2. |
| 4 | Machine setup or cache overlay source missing | Follow "Machine setup" in `AGENTS.md` or fix missing `cache_overlays` directory. |
| 3 | Project not set up | Follow "Project setup" in `AGENTS.md`. Ask the user its questions; never invent a config. |
| command not found | hutch is not installed | Ask the user before installing: `git clone https://github.com/byarashboev/hutch ~/hutch`, `ln -s ~/hutch/hutch ~/.local/bin/hutch`, then `hutch status`. |

Never ask the user to paste an API key into the chat. Give them the keychain command from `AGENTS.md` to run
themselves.

## 2. Run one task (Context Pre-Packing + Watchdog)

1. **Think before briefing:** Surface any ambiguous requirements or design tradeoffs to the user upfront (or run `HUTCH_PHASE=design` first) so the headless sandbox receives an unambiguous brief and never guesses or stalls. Write `brief.md`: the goal, exact files to change and why, required behavior and tests, checks to run, commit steps, and out-of-scope boundaries. Short and precise.
2. Write an allow file (or pass `--allow <glob>`): bash globs of the expected paths, one per line.
3. Create the task with **pre-packed context** (`--context path[:start-end]`) so the inner agent starts coding immediately instead of wasting turns grepping/reading files you already found:
   ```sh
   hutch new <task> <allow> <brief> --context src/types.ts:1-60 --context src/api.ts:40-110
   ```
4. Run with `HUTCH_KIND=<kind>` and watchdog guardrails (`--max-turns`, `--max-timeout`, `--loop-threshold`):
   ```sh
   HUTCH_KIND=script hutch run --max-turns 12 --max-timeout 600 --loop-threshold 3 <task>
   ```
   - Exit `0`: finished cleanly. Inspect `self-review.md` and `run.jsonl`.
   - Exit `42` (`EARLY_ABORT: NEEDS_SCOPE`): the sandbox stopped early requesting extra paths in `needs-scope.txt`. Decide whether to expand scope (`--allow`), handle directly, or reject.
   - Exit `43` (`EARLY_ABORT: LOOP_DETECTED`): repeated identical failing command/error 3 times consecutively. Read `abort.log` in `~/.hutch/state/<project>/out/<task>/`.
   - Exit `44` (`EARLY_ABORT: MAX_TURNS`) or `124` (timeout): inspect `abort.log` / `run.jsonl` and partial commits.
5. Follow-ups: `hutch say <task> "<message>"`.
6. Export and verify offline with **two-tier path scoping**:
   ```sh
   hutch export <task>
   hutch verify <task>
   ```
   - **Hard Denylist (always fails):** `.hutch/*`, `.git/*`, CI configs, manifests/lockfiles (`package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, etc.), build scripts (`Makefile`, `Dockerfile`), `.env*`, `.gitattributes`, and **pre-existing test files** (pass `--allow-tests` only when test edits are intended). New test files are allowed without `--allow-tests`.
   - **Explicit Allowlist (`--allow`):** passes cleanly (`ok`).
   - **Soft Scope (default):** non-protected source edits outside `--allow` still pass verification with a structured **`WARN: UNSCOPED_PATHS`** section + diff stat so you can review and approve/reject them. Use `--strict-scope` to reject unscoped edits, or `--allow <glob>` on `verify` to promote them.
7. `hutch report <task>`: one-page summary including `WARN: UNSCOPED_PATHS` and `Requested Scope Escalation` if present.
8. **Review the diff yourself:** `git -C <repo> diff <base> refs/hutch/<task>`. Passing `verify` is not acceptance.
9. Take the work from `refs/hutch/<task>` (branch or cherry-pick) and continue with your normal process.
10. `hutch rm <task>` when merged or abandoned; `hutch ls` lists active/completed tasks.

## 3. Parallel Fan-Out (`hutch batch`)

Every `hutch` sandbox isolates its gate container, per-run proxy token, internal IP, CoW cache overlay, agent state dir (`oc-data` / `claude-data`), and export bundle — so multiple tasks can safely run concurrently:

```sh
hutch batch --max-parallel 4 --max-turns 12 --max-timeout 600 mod-a mod-b mod-c mod-d
```

Or run `hutch run t1 & hutch run t2 & wait`, followed by concurrent `hutch export` / `hutch verify`.

## Verification rules

- Never trust the sandbox agent's report. Check every claim, unscoped file (`WARN: UNSCOPED_PATHS`), and mid-run instruction in the final diff.
- Review authorization, money, personal data, SQL, migrations and concurrency harder: mutation-test the guards and run
  the integration tests the sandbox could not run.
- Run checks that need Docker, a network or a browser on the host yourself.
- Before doing part of the task yourself instead of the sandbox, tell the user which part and why.
- The model provider sees the code sent to it. Never put production data or credentials into a task.
