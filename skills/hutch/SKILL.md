---
name: hutch
description: Hand one bounded coding task to a cheaper coding agent (opencode or Claude Code on OpenCode Go or DeepSeek) running in an isolated Docker container, then verify the result on the host. Use when the user asks to "use hutch", to delegate or sandbox a well-scoped coding task to a cheaper model, or when a task is narrow enough to brief precisely and review as a diff.
---

# hutch

hutch runs a cheaper agent in a container that has no capabilities, sees only its own clone of the repository and
has no route out except a per-run gate to the model API; the gate holds the key, the sandbox never does. **The sandbox agent writes the code. You write the brief and
verify the result.**

Source and full instructions: https://github.com/byarashboev/hutch (its `AGENTS.md` is the authoritative guide; this
skill is the short version).

## 1. Check the state first, every time

Run `hutch status` inside the project and act on the exit code:

| Exit | Meaning | Action |
|---|---|---|
| 0 | Ready | Go to step 2. |
| 4 | Machine not set up (Docker, key, images) | Follow "Machine setup" in hutch's `AGENTS.md`. Ask before each install. |
| 3 | Project not set up | Follow "Project setup" in hutch's `AGENTS.md`. Ask the user its questions; never invent a config. |
| command not found | hutch is not installed | Ask the user before installing: `git clone https://github.com/byarashboev/hutch ~/hutch`, `ln -s ~/hutch/hutch ~/.local/bin/hutch`, then `hutch status`. |

Never ask the user to paste an API key into the chat. Give them the keychain command from `AGENTS.md` to run
themselves.

## 2. Run one task

1. Write `brief.md`: the goal, the exact files to change and why, the behaviour and tests required, the checks to run,
   the commit steps, and what is out of scope. Short and precise.
2. Write an allow file: the paths the task may change, bash globs, one per line. Keep it narrow.
3. `hutch new <task> <allow> <brief>`
4. `HUTCH_KIND=<kind> hutch run <task>` (`hutch models` lists the kinds). Sensitive paths need a strong kind
   (`design` or `concurrency`).
5. Check `exit.code` is 0 and `run.err` is empty in `~/.hutch/state/<project>/out/<task>/`. Read `self-review.md`.
6. Follow-ups: `hutch say <task> "<message>"`.
7. `hutch export <task>`, then `hutch verify <task>` (path rules plus the project's offline checks).
8. `hutch report <task>`: model, usage, commits, verify status and test changes on one page.
9. **Review the diff yourself:** `git -C <repo> diff <base> refs/hutch/<task>`. A passing `verify` is not acceptance.
10. Take the work from `refs/hutch/<task>` (branch or cherry-pick) and continue with the project's normal process.
11. `hutch rm <task>` when merged or abandoned.

## Verification rules

- Never trust the sandbox agent's report. Check every claim, and every mid-run instruction, in the final diff.
- Review authorization, money, personal data, SQL, migrations and concurrency harder: mutation-test the guards and run
  the integration tests the sandbox could not run.
- Run checks that need Docker, a network or a browser on the host yourself.
- Before doing part of the task yourself instead of the sandbox, tell the user which part and why.
- The model provider sees the code sent to it. Never put production data or credentials into a task.
