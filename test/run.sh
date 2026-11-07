#!/usr/bin/env bash
# Unit tests for hutch's project resolution and path rules. No Docker, no network, no model.
# Checks are single-quoted on purpose: check() evals them later (SC2016, SC2034); path rules match globs (SC2053).
# shellcheck disable=SC2016,SC2034,SC2053,SC1091
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

# Path rules.
CONF="$tmp/conf"; mkdir -p "$CONF"
printf '# c\nMakefile\ncontracts/*\n*/migrations/*\n' >"$CONF/protected"
printf 'contracts/*\n' >"$CONF/openable"
OPENED_FILE="$tmp/opened"; : >"$OPENED_FILE"
check "always-protected .hutch" 'protected .hutch/config'
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
