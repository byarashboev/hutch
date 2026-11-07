#!/usr/bin/env bash
# Unit tests for hutch's project resolution and path rules. No Docker, no network, no model.
# Checks are single-quoted on purpose: check() evals them later (SC2016, SC2034); path rules match globs (SC2053);
# sandbox() is a stub that cmd_run calls (SC2329).
# shellcheck disable=SC2016,SC2034,SC2053,SC1091,SC2329
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

export HUTCH_HOME="$tmp/home" HUTCH_LIB=1
# shellcheck source=../hutch
source "$here/hutch"
set +e
setup_provider

# A repository with a worktree, both resolving to the main checkout.
git init -q -b main "$tmp/My_Repo"
git -C "$tmp/My_Repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$tmp/My_Repo" worktree add -q "$tmp/wt" -b side

cd "$tmp/My_Repo" || exit 1
CONF=x; try_resolve
check "unconfigured project has no CONF" '[[ -z "$CONF" && "$NAME" == my-repo && "$REPO" == "$tmp/My_Repo" ]]'
out="$( (need_project) 2>&1)"; rc=$?
check "need_project exits 3 and points to AGENTS.md" '[[ $rc -eq 3 && "$out" == *"Project setup"* && "$out" == *AGENTS.md* ]]'
HUTCH_LIB='' "$here/hutch" status >/dev/null 2>&1; rc=$?
check "status exits non-zero when not set up" '[[ $rc -eq 3 || $rc -eq 4 ]]'

HUTCH_LIB='' "$here/hutch" init >/dev/null
check "init writes a home config with name and repo" '[[ -f "$HUTCH_HOME/projects/my-repo/config" ]] && grep -qx "name=my-repo" "$HUTCH_HOME/projects/my-repo/config" && grep -qx "repo=$tmp/My_Repo" "$HUTCH_HOME/projects/my-repo/config"'
cd "$tmp/wt" || exit 1
try_resolve
check "a worktree resolves to the main checkout's config" '[[ "$CONF" == "$HUTCH_HOME/projects/my-repo" && "$REPO" == "$tmp/My_Repo" ]]'
check "conf_get reads values and missing keys are empty" '[[ "$(conf_get base_branch)" == main && -z "$(conf_get nope)" ]]'

cd / || exit 1
HUTCH_PROJECT=my-repo try_resolve
check "HUTCH_PROJECT uses the home config from anywhere" '[[ "$REPO" == "$tmp/My_Repo" ]]'

mkdir -p "$tmp/My_Repo/.hutch"; printf 'name=inrepo\n' >"$tmp/My_Repo/.hutch/config"
cd "$tmp/My_Repo" || exit 1
try_resolve
check "an in-repo config wins over the home config" '[[ "$CONF" == "$tmp/My_Repo/.hutch" && "$NAME" == inrepo ]]'
rm -rf "$tmp/My_Repo/.hutch"

# Limits and timeouts: config values, environment overrides, defaults, and a refusal of non-numbers.
LIMCONF="$tmp/limconf"; mkdir -p "$LIMCONF"; printf 'pids=512\nmemory=2g\nrun_timeout=600\n' >"$LIMCONF/config"
CONF="$LIMCONF"
check "limit_args reads pids and memory from the config" '[[ "$(limit_args)" == "--pids-limit 512 --memory 2g" ]]'
check "limit_args takes the environment first" '[[ "$(HUTCH_PIDS=64 HUTCH_MEMORY=1g limit_args)" == "--pids-limit 64 --memory 1g" ]]'
check "run_timeout reads the config" '[[ "$(run_timeout)" == 600 ]]'
check "verify_timeout defaults to 1800" '[[ "$(verify_timeout)" == 1800 ]]'
check "HUTCH_VERIFY_TIMEOUT overrides" '[[ "$(HUTCH_VERIFY_TIMEOUT=5 verify_timeout)" == 5 ]]'
out="$( (HUTCH_RUN_TIMEOUT=1h run_timeout) 2>&1)"; rc=$?
check "a timeout that is not whole seconds is refused" '[[ $rc -ne 0 && "$out" == *"whole seconds"* ]]'

# A run that hits its limit: the agent runs under timeout, and exit code 124 is recorded and named.
STATE="$tmp/state"; mkdir -p "$STATE/work/slow/repo" "$STATE/out/slow"
MODEL=m SMALL_MODEL=s AGENT=opencode
sandbox() { printf '%s\n' "${SANDBOX_CMD[*]}" >"$tmp/cmd"; return 124; }
out="$( (cmd_run slow) 2>&1)"; rc=$?
check "the opencode agent runs under the run limit" '[[ "$(cat "$tmp/cmd")" == "timeout -k 30 600 opencode run "* ]]'
check "a timed-out run records 124 and says so" '[[ $rc -eq 124 && "$(cat "$STATE/out/slow/exit.code")" == 124 && "$out" == *"600s limit"* ]]'
unset -f sandbox

# Test changes: deleted test files, lines removed from existing tests and new skip markers are named.
TR="$tmp/testrepo"; git init -q -b main "$TR"
mkdir -p "$TR/test" "$TR/src"
printf 'a\nb\nc\n' >"$TR/test/a.test.js"; printf 'x\n' >"$TR/test/b.test.js"; printf 'y\n' >"$TR/src/gone_test.go"
printf 'code\n' >"$TR/src/app.js"
git -C "$TR" add -A; git -C "$TR" -c user.name=t -c user.email=t@t commit -qm base
trbase="$(git -C "$TR" rev-parse HEAD)"
printf 'a\nc\n' >"$TR/test/a.test.js"; printf 'x\ntest.skip("later", () => {});\n' >"$TR/test/b.test.js"
rm "$TR/src/gone_test.go"; printf 'new\n' >"$TR/test/c.test.js"; printf 'code2\n' >"$TR/src/app.js"
git -C "$TR" add -A; git -C "$TR" -c user.name=t -c user.email=t@t commit -qm agent
trref="$(git -C "$TR" rev-parse HEAD)"
REPO="$TR"; CONF="$tmp/trconf"; mkdir -p "$CONF"; : >"$CONF/config"
out="$(test_changes "$trbase" "$trref")"; rc=$?
check "a deleted test file is named" '[[ "$out" == *"DELETED src/gone_test.go"* ]]'
check "lines removed from an existing test are named" '[[ "$out" == *"EDITED test/a.test.js (-1)"* ]]'
check "a new skip marker is named" '[[ "$out" == *"SKIP test/b.test.js"* ]]'
check "a test with only added lines is listed as extended" '[[ "$out" == *"extended test/b.test.js (+1)"* ]]'
check "a new test file is listed, source files are not" '[[ "$out" == *"new test/c.test.js"* && "$out" != *app.js* ]]'
check "the default policy only reports" '[[ $rc -eq 0 ]]'
printf 'tests_policy=append-only\n' >"$CONF/config"
test_changes "$trbase" "$trref" >/dev/null; rc=$?
check "append-only fails on changed tests" '[[ $rc -ne 0 ]]'
git -C "$TR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m none
out="$(test_changes "$trref" "$(git -C "$TR" rev-parse HEAD)")"; rc=$?
check "append-only passes when existing tests are untouched" '[[ $rc -eq 0 && "$out" == *"no changes to existing tests"* ]]'
printf 'tests=^spec/\n' >"$CONF/config"
out="$(test_changes "$trbase" "$trref")"
check "a project tests= pattern replaces the default" '[[ "$out" == *"no changes to existing tests"* ]]'

# Path rules.
CONF="$tmp/conf"; mkdir -p "$CONF"
printf '# c\nMakefile\ncontracts/*\n*/migrations/*\n' >"$CONF/protected"
printf 'contracts/*\n' >"$CONF/openable"
OPENED_FILE="$tmp/opened"; : >"$OPENED_FILE"
check "always-protected .hutch" 'protected .hutch/config'
check "every .gitattributes is always protected (git archive obeys export-ignore in any directory)" 'protected .gitattributes && protected test/.gitattributes && protected a/b/.gitattributes'
check "protected glob" 'protected backend/migrations/0001.sql && protected Makefile'
check "not protected" '! protected src/a.go'
check "closed contract is protected" 'protected contracts/api.yaml'
printf 'contracts/*\n*/migrations/*\n' >"$OPENED_FILE"
check "opened openable pattern is not protected" '! protected contracts/api.yaml'
check "opened pattern that is not openable stays protected" 'protected backend/migrations/0001.sql'
ALLOW_FILE="$tmp/allow"; printf 'src/*\n# x\n' >"$ALLOW_FILE"
check "allowed glob" 'allowed src/deep/a.go && ! allowed lib/a.go'

# needs_pro: off without pro-paths; on when an allow glob and a pro-paths glob match in either direction.
printf 'src/*\n' >"$tmp/a1"
check "no pro-paths: rule off" '! needs_pro "$tmp/a1" "$tmp/none" >/dev/null'
printf 'x\n' >"$tmp/op"; printf 'app/billing/*\n' >"$CONF/pro-paths"
check "opened file needs pro" 'needs_pro "$tmp/a1" "$tmp/op" >/dev/null'
check "unrelated allow does not need pro" '! needs_pro "$tmp/a1" /dev/null >/dev/null'
printf 'app/*\n' >"$tmp/a2"; printf 'app/billing/invoice.go\n' >"$tmp/a3"
check "broad allow covering a pro glob needs pro" 'needs_pro "$tmp/a2" /dev/null >/dev/null'
check "narrow allow inside a pro glob needs pro" 'needs_pro "$tmp/a3" /dev/null >/dev/null'

echo "failures: $fails"
[[ $fails -eq 0 ]]
