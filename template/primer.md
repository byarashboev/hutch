# <project> primer (verified pointers; trust them before exploring)

Each line was checked against <base branch> on <date>. If one is wrong, say so in your report and carry on.

## Layout
- <language, module/package roots, how to run the toolchain from the repository root>
- <where the project's rules for agents live>

## Checks
- <format, lint, type-check and unit-test commands that work offline in the sandbox>
- <tests that cannot run here and how to at least compile them>

## Helpers
- <test helpers, fixtures and builders a task usually needs, with file paths>

## Habits that save time
- Read only the files the brief names, plus their direct helpers. Do not survey the repository.
- Write the failing test first, run only its package, then fix.
