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
reload_hutch() {
  # shellcheck source=../hutch
  source "$here/hutch"
  set +e
}
setup_provider

# Providers: the repository's providers/*.conf, a user's ~/.hutch/providers/*.conf, and refusal of unsafe values.
check "the default provider is OpenCode Go from providers/opencode.conf" '[[ "$PROVIDER" == opencode && "$UPSTREAM" == https://opencode.ai && "$KEY_ITEM" == opencode-go && "$CLAUDE_BASE" == /inference/go/anthropic && "$OPENCODE_PROVIDER" == opencode-go && "$MODELS_FILE" == "$here/models/opencode.tsv" ]]'
check "deepseek runs only the Claude Code agent" '! (HUTCH_PROVIDER=deepseek; setup_provider) 2>/dev/null && (HUTCH_PROVIDER=deepseek HUTCH_AGENT=claude; setup_provider; [[ "$COMPACT_WINDOW" == 786432 ]])'
mkdir -p "$HUTCH_HOME/providers"
printf 'upstream=https://api.example.com\nkey_item=myrouter\nclaude_base=/anthropic\npaths=/anthropic/v1/\nmodels=myrouter.tsv\n' >"$HUTCH_HOME/providers/myrouter.conf"
check "a provider in ~/.hutch/providers is found, with its model table next to it" '(HUTCH_PROVIDER=myrouter HUTCH_AGENT=claude; setup_provider; [[ "$UPSTREAM" == https://api.example.com && "$KEY_ITEM" == myrouter && "$MODELS_FILE" == "$HUTCH_HOME/providers/myrouter.tsv" ]])'
out="$( (HUTCH_PROVIDER=myrouter; setup_provider) 2>&1)"; rc=$?
check "the opencode agent needs a provider with opencode_provider" '[[ $rc -ne 0 && "$out" == *opencode_provider* ]]'
out="$( (HUTCH_PROVIDER=nope; setup_provider) 2>&1)"; rc=$?
check "an unknown provider is refused" '[[ $rc -ne 0 && "$out" == *"no provider"* ]]'
printf 'upstream=http://api.example.com\nkey_item=k\nclaude_base=/a\npaths=/a/\n' >"$HUTCH_HOME/providers/plain.conf"
out="$( (HUTCH_PROVIDER=plain HUTCH_AGENT=claude; setup_provider) 2>&1)"; rc=$?
check "a provider upstream must be https://host" '[[ $rc -ne 0 && "$out" == *"https://host"* ]]'
printf 'upstream=https://api.example.com\nkey_item=k\nclaude_base=/a\npaths=/a/;deny\n' >"$HUTCH_HOME/providers/inject.conf"
out="$( (HUTCH_PROVIDER=inject HUTCH_AGENT=claude; setup_provider) 2>&1)"; rc=$?
check "a provider path with other characters is refused" '[[ $rc -ne 0 && "$out" == *paths* ]]'

# The gate's nginx template: one location per allowed path, the key only as a variable, everything else refused.
out="$(gate_conf)"
check "the gate forwards each allowed path to the upstream over verified TLS" '[[ "$out" == *"location ^~ /zen/go/v1/ {"* && "$out" == *"location ^~ /inference/go/anthropic/v1/ {"* && "$out" == *"proxy_pass https://opencode.ai;"* && "$out" == *"proxy_ssl_verify on;"* ]]'
check "the gate sets the key from its own environment" '[[ "$out" == *"Authorization \"Bearer \${HUTCH_KEY}\""* && "$out" == *"x-api-key \"\${HUTCH_KEY}\""* ]]'
check "the gate refuses every other path" '[[ "$out" == *"location / {"*"return 403"* ]]'

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
reload_hutch

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

# Usage from the agents' logs: opencode step_finish events and Claude Code result events, across every phase's log.
UO="$tmp/usage"; mkdir -p "$UO"
cat >"$UO/run.jsonl" <<'EOF'
{"type":"step_start","timestamp":1000}
{"type":"step_finish","timestamp":61000,"part":{"type":"step-finish","cost":0.01,"tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":50,"write":0}}}}
not json
{"type":"step_finish","timestamp":121000,"part":{"type":"step-finish","cost":0.02,"tokens":{"input":200,"output":30,"reasoning":0,"cache":{"read":0,"write":10}}}}
EOF
cat >"$UO/run.20261108010101.jsonl" <<'EOF'
{"type":"result","duration_ms":30000,"total_cost_usd":0.5,"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":500,"cache_creation_input_tokens":0}}
EOF
out="$(run_usage "$UO")"
check "run_usage sums tokens across agents and phases" '[[ "$out" == *"input 1300, output 150, reasoning 5, cache read 550, cache write 10"* ]]'
check "run_usage sums reported cost and agent time" '[[ "$out" == *"cost reported 0.53"* && "$out" == *"agent time 150s"* ]]'
out="$(run_usage "$tmp/nothing-here")"
check "run_usage with no logs says so" '[[ "$out" == *"no run logs"* ]]'

# The container runtime (gVisor's runsc, for example): config, environment override, refusal of other values, and the
# flag on the containers that run the agent's code.
CONF="$tmp/rtconf"; mkdir -p "$CONF"; printf 'runtime=runsc\n' >"$CONF/config"
setup_runtime
check "runtime= in the config sets the runtime" '[[ "$RUNTIME" == runsc ]]'
check "HUTCH_RUNTIME overrides the config" '(HUTCH_RUNTIME=kata; setup_runtime; [[ "$RUNTIME" == kata ]])'
out="$( (HUTCH_RUNTIME="runsc --privileged"; setup_runtime) 2>&1)"; rc=$?
check "a runtime that is not a plain name is refused" '[[ $rc -ne 0 && "$out" == *"runtime name"* ]]'
docker() { printf '%s\n' "$@" >"$tmp/dargs"; }
offline img true
check "verify's checks run under the runtime" '[[ "$(grep -A1 -x -- --runtime "$tmp/dargs" | tail -1)" == runsc ]]'
RUNTIME=""; offline img true
check "no runtime set: Docker's default, no --runtime flag" '! grep -qx -- --runtime "$tmp/dargs"'
unset -f docker

# hutch ls: one line per task with its run state, verify status, host-side commits and model.
STATE="$tmp/lsstate"; NAME=lsproj; REPO="$TR"
for t in finished live fresh; do mkdir -p "$STATE/work/$t/repo" "$STATE/out/$t"; echo "$trbase" >"$STATE/work/$t/base"; done
echo 0 >"$STATE/out/finished/exit.code"; echo passed >"$STATE/out/finished/verify.status"
echo "2026-11-08T00:00:00Z agent=opencode provider=opencode kind=build model=glm-5 small=x phase=" >"$STATE/out/finished/models.log"
git -C "$TR" update-ref refs/hutch/finished "$trref"
: >"$STATE/out/live/run.jsonl"
docker() { [[ "$1" == ps ]] && echo live; }
# hutch itself runs with errexit and pipefail; so does this call.
out="$(set -eo pipefail; cmd_ls)"
unset -f docker
check "ls shows a finished task's exit code, verify status, commits and model" '[[ "$out" =~ finished\ +[0-9]+s\ +exit\ 0\ +passed\ +1\ +glm-5 ]]'
check "ls shows a task whose gate is up as running" '[[ "$out" =~ live\ +[0-9]+s\ +running\ +-\ +- ]]'
check "ls shows a task that has not run" '[[ "$out" =~ fresh\ +[0-9]+s\ +not\ run ]]'

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

# Workstream 1: Two-tier path scoping, hard denylist, pre-existing tests, scope_mode.
CONF="$tmp/hardconf"; mkdir -p "$CONF"; : >"$CONF/protected"; : >"$CONF/openable"
OPENED_FILE="$tmp/hardopened"; printf '.git/*\npackage.json\n.env*\n' >"$OPENED_FILE"
check "hard denylist blocks git, CI, manifests, lockfiles, build scripts, and .env even with empty protected" '
  protected .git/hooks/pre-commit &&
  protected sub/.git/config &&
  protected .github/workflows/ci.yml &&
  protected package.json &&
  protected apps/web/package.json &&
  protected yarn.lock &&
  protected go.mod &&
  protected Cargo.toml &&
  protected pyproject.toml &&
  protected Makefile &&
  protected Dockerfile &&
  protected docker/Dockerfile.prod &&
  protected .env &&
  protected api/.env.local &&
  ! protected src/helper.ts
'

CONF="$tmp/trconf"; REPO="$TR"; : >"$CONF/config"
check "is_preexisting_test detects existing test files at base but allows new test files" '
  is_preexisting_test "$trbase" test/a.test.js &&
  ! is_preexisting_test "$trbase" test/c.test.js &&
  ! is_preexisting_test "$trbase" src/app.js
'

check "scope_mode defaults to soft and honors config, env, and explicit arg" '
  [[ "$(scope_mode)" == soft ]] &&
  (printf "scope_mode=strict\n" >"$CONF/config"; [[ "$(scope_mode)" == strict ]]) &&
  (printf "scope_mode=soft\n" >"$CONF/config"; HUTCH_STRICT_SCOPE=1; [[ "$(scope_mode)" == strict ]]) &&
  (printf "scope_mode=strict\n" >"$CONF/config"; HUTCH_SOFT_SCOPE=1; [[ "$(scope_mode)" == soft ]]) &&
  [[ "$(HUTCH_STRICT_SCOPE=1 scope_mode soft)" == soft ]] &&
  ! (printf "scope_mode=bogus\n" >"$CONF/config"; scope_mode) 2>/dev/null
'

# Workstream 1: cmd_new flags/.git exclude & cmd_verify 3-tier path enforcement.
VREPO="$tmp/vrepo"; git init -q -b main "$VREPO"
mkdir -p "$VREPO/src" "$VREPO/test"
printf 'export const a = 1;\n' >"$VREPO/src/a.js"
printf 'export const b = 2;\n' >"$VREPO/src/extra.js"
printf '{"name":"v"}\n' >"$VREPO/package.json"
printf 'test("a", () => {});\n' >"$VREPO/test/existing.test.js"
git -C "$VREPO" add -A; git -C "$VREPO" -c user.name=t -c user.email=t@t commit -qm base
vbase="$(git -C "$VREPO" rev-parse HEAD)"

CONF="$tmp/vconf"; mkdir -p "$CONF"
: >"$CONF/config"; : >"$CONF/protected"; : >"$CONF/openable"
printf 'true\n' >"$CONF/verify.sh"
STATE="$tmp/vstate"; NAME=vproj; REPO="$VREPO"; PROJECT_IMAGE="hutch-vproj:latest"
printf 'src/a.js\n' >"$tmp/vallow"
printf '# brief\n' >"$tmp/vbrief"

out="$(cmd_new vflags --allow 'src/*.js' --allow 'lib/*.js' --brief "$tmp/vbrief" 2>&1)"; rc=$?
check "cmd_new accepts --allow/--brief flags and excludes .hutch-needs-scope" '
  [[ $rc -eq 0 ]] &&
  grep -qxF "src/*.js" "$STATE/work/vflags/allow" &&
  grep -qxF "lib/*.js" "$STATE/work/vflags/allow" &&
  grep -qxF ".hutch-needs-scope" "$STATE/work/vflags/repo/.git/info/exclude"
'

make_vtask() {
  local t="$1" script="$2"
  cmd_new "$t" "$tmp/vallow" "$tmp/vbrief" >/dev/null
  (cd "$STATE/work/$t/repo" && eval "$script" && git add -A && git commit -qm "agent: $t")
  git -C "$STATE/work/$t/repo" bundle create "$STATE/out/$t/$t.bundle" "${vbase}..hutch/$t" >/dev/null 2>&1
}

need_image() { return 0; }
offline() { return 0; }

make_vtask vhard 'printf "{\"hack\":true}\n" >package.json'
out="$( (cmd_verify vhard) 2>&1)"; rc=$?
check "verify rejects hard-protected manifest even in default soft mode" '[[ $rc -ne 0 && "$out" == *"PROTECTED package.json"* ]]'

make_vtask vpretest 'printf "// more\n" >>test/existing.test.js'
out="$( (cmd_verify vpretest) 2>&1)"; rc=$?
check "verify rejects pre-existing test changes by default" '[[ $rc -ne 0 && "$out" == *"PROTECTED-TEST test/existing.test.js"* ]]'
out="$( (cmd_verify --allow-tests vpretest) 2>&1)"; rc=$?
check "verify allows pre-existing test changes with --allow-tests" '[[ $rc -eq 0 && "$out" == *"verify passed"* ]]'

make_vtask vnewtest 'printf "// ok\n" >>src/a.js; printf "test(\"new\", () => {});\n" >test/new.test.js'
out="$( (cmd_verify vnewtest) 2>&1)"; rc=$?
check "verify soft mode passes a newly created test file without --allow-tests" '[[ $rc -eq 0 && "$out" == *"WARN: UNSCOPED_PATHS"* && "$out" == *"UNSCOPED test/new.test.js"* ]]'

make_vtask vsoft 'printf "// a\n" >>src/a.js; printf "// b\n" >>src/extra.js'
out="$( (cmd_verify vsoft) 2>&1)"; rc=$?
check "verify soft mode warns on non-protected unscoped file with diff stat and passes" '
  [[ $rc -eq 0 && "$out" == *"ok src/a.js"* && "$out" == *"== WARN: UNSCOPED_PATHS"* &&
     "$out" == *"UNSCOPED src/extra.js"* && "$out" == *"unscoped diff stat"* &&
     "$(cat "$STATE/out/vsoft/unscoped.txt")" == "src/extra.js" &&
     "$(cat "$STATE/out/vsoft/verify.status")" == "passed (warn: 1 unscoped)" ]]
'
rep="$(cmd_report vsoft)"
check "report includes WARN: UNSCOPED_PATHS section when unscoped.txt exists" '[[ "$rep" == *"## WARN: UNSCOPED_PATHS"* && "$rep" == *"src/extra.js"* ]]'

out="$( (cmd_verify --strict-scope vsoft) 2>&1)"; rc=$?
check "verify --strict-scope rejects unscoped file" '[[ $rc -ne 0 && "$out" == *"NOT-ALLOWED src/extra.js"* ]]'

out="$( (cmd_verify --strict-scope --allow src/extra.js vsoft) 2>&1)"; rc=$?
check "verify --allow promotes unscoped file to ok and clears unscoped.txt" '
  [[ $rc -eq 0 && "$out" == *"ok src/extra.js"* && ! -e "$STATE/out/vsoft/unscoped.txt" ]]
'

printf 'scope_mode=strict\n' >"$CONF/config"
out="$( (cmd_verify vsoft) 2>&1)"; rc=$?
check "config scope_mode=strict rejects unscoped file unless --soft-scope overrides" '
  [[ $rc -ne 0 && "$out" == *"NOT-ALLOWED src/extra.js"* ]] &&
  (cmd_verify --soft-scope vsoft >/dev/null 2>&1)
'

unset -f need_image offline
reload_hutch

# Workstream 1: Early scope escalation via .hutch-needs-scope file and stdout/JSONL marker.
MODEL=m SMALL_MODEL=s AGENT=opencode
: >"$CONF/config"
sandbox() { printf 'src/types.ts\n# needed interface\nsrc/config.ts\n' >"$(task_dir "$1")/repo/.hutch-needs-scope"; return 0; }
out="$( (cmd_run vsoft) 2>&1)"; rc=$?
unset -f sandbox
reload_hutch
check "cmd_run returns exit 42 and EARLY_ABORT: NEEDS_SCOPE when .hutch-needs-scope is written" '
  [[ $rc -eq 42 && "$out" == *"EARLY_ABORT: NEEDS_SCOPE"* && "$out" == *"src/types.ts"* &&
     "$(cat "$STATE/out/vsoft/exit.code")" == 42 &&
     "$(cat "$STATE/out/vsoft/needs-scope.txt")" == $'\''src/types.ts\nsrc/config.ts'\'' ]]
'
rep="$(cmd_report vsoft)"
check "report includes Requested Scope Escalation section" '[[ "$rep" == *"## Requested Scope Escalation"* && "$rep" == *"src/config.ts"* ]]'
rm -f "$STATE/work/vsoft/repo/.hutch-needs-scope"

sandbox() {
  printf '%s\n' '{"type":"text","part":{"text":"Cannot proceed.\nHUTCH_NEEDS_SCOPE: src/foo.ts, src/bar.ts\nHUTCH_NEEDS_SCOPE: src/foo.ts"}}'
  return 0
}
out="$( (cmd_run vsoft) 2>&1)"; rc=$?
unset -f sandbox
reload_hutch
check "cmd_run returns exit 42 when HUTCH_NEEDS_SCOPE marker appears in run.jsonl" '
  [[ $rc -eq 42 && "$out" == *"EARLY_ABORT: NEEDS_SCOPE"* &&
     "$(cat "$STATE/out/vsoft/needs-scope.txt")" == $'\''src/foo.ts\nsrc/bar.ts'\'' ]]
'

# Workstream 2: Zero-knowledge credential-injecting API proxy.
gate_out="$(gate_conf)"
check "gate_conf enforces HUTCH_PROXY_TOKEN via nginx maps and strips alternative auth headers" '
  [[ "$gate_out" == *"map \$http_authorization \$hutch_auth_state"* &&
     "$gate_out" == *"map \$http_x_api_key \$hutch_xkey_state"* &&
     "$gate_out" == *"\$hutch_token_ok"* &&
     "$gate_out" == *"return 403 \"hutch gate: invalid proxy token"* &&
     "$gate_out" == *"proxy_set_header api-key \"\""* &&
     "$gate_out" == *"proxy_set_header x-auth-token \"\""* &&
     "$gate_out" == *"proxy_set_header x-goog-api-key \"\""* &&
     "$gate_out" == *"proxy_set_header Proxy-Authorization \"\""* &&
     "$gate_out" == *"proxy_set_header Cookie \"\""* &&
     "$gate_out" == *"hutch gate: invalid path"* &&
     "$gate_out" == *"hutch gate: credential query param not allowed"* ]]
'

printf 'upstream=https://api.example.com\nkey_item=exactp\nclaude_base=/v1\npaths=/v1/chat/completions /v1/messages\nmodels=myrouter.tsv\n' >"$HUTCH_HOME/providers/exactp.conf"
cp "$HUTCH_HOME/providers/myrouter.tsv" "$HUTCH_HOME/providers/exactp.tsv" 2>/dev/null || : >"$HUTCH_HOME/providers/exactp.tsv"
exact_gate="$(HUTCH_PROVIDER=exactp HUTCH_AGENT=claude; setup_provider; gate_conf)"
check "gate_conf locks non-trailing-slash paths with exact (=) and prefix/ (/) locations" '
  [[ "$exact_gate" == *"location = /v1/messages {"* &&
     "$exact_gate" == *"location ^~ /v1/messages/ {"* &&
     "$exact_gate" == *"location = /v1/chat/completions {"* &&
     "$exact_gate" == *"location ^~ /v1/chat/completions/ {"* ]]
'

check "gate_conf nginx map truth table rejects missing or spoofed keys across all header combinations" '
  GATE_CONF_SAMPLE="$gate_out" python3 -I - <<'\''PYEOF'\''
import os, re, sys
conf = os.environ["GATE_CONF_SAMPLE"]
if "map $http_authorization" not in conf or "$hutch_token_ok" not in conf:
    sys.exit(1)
token = "hutch-proxy-deadbeef"
rendered = conf.replace("${HUTCH_PROXY_TOKEN}", token)
def map_auth(v):
    if v == "": return "empty"
    if f"\"Bearer {token}\" valid;" in re.sub(r" +", " ", rendered):
        if v == f"Bearer {token}": return "valid"
    return "invalid"
def map_xkey(v):
    if v == "": return "empty"
    if f"\"{token}\" valid;" in re.sub(r" +", " ", rendered) and v == token:
        return "valid"
    return "invalid"
def map_ok(a, x):
    return 1 if f"{a}:{x}" in ("valid:valid", "valid:empty", "empty:valid") else 0
cases = [
    ("", "", 0),
    (f"Bearer {token}", "", 1),
    ("", token, 1),
    (f"Bearer {token}", token, 1),
    ("Bearer sk-attacker", "", 0),
    ("", "sk-attacker", 0),
    (f"Bearer {token}", "sk-attacker", 0),
    ("Bearer sk-attacker", token, 0),
    ("Bearer sk-attacker", "sk-attacker", 0),
]
for a, x, want in cases:
    got = map_ok(map_auth(a), map_xkey(x))
    assert got == want, (a, x, got, want)
PYEOF
'

CONF="$tmp/vconf"; REPO="$VREPO"; STATE="$tmp/vstate"; NAME=vproj; PROJECT_IMAGE="hutch-vproj:latest"
printf '# primer\n' >"$CONF/primer.md"
MODEL=m SMALL_MODEL=s
SANDBOX_CMD=(true)
need_image() { return 0; }
out="$( (HUTCH_API_KEY='bad"key;rm' gate_up g1 "$tmp/gc" "$tmp/gl" vsoft tok1) 2>&1)"; rc=$?
check "gate_up refuses API keys with unsafe characters" '[[ $rc -ne 0 && "$out" == *"unsafe characters"* ]]'

docker() {
  local sub="$1"; shift
  case "$sub" in
    run)
      if [[ " $* " == *" $GATE_IMAGE "* ]]; then
        printf 'GATE_ENV_KEY=%s\nGATE_ENV_TOK=%s\n' "${HUTCH_KEY:-}" "${HUTCH_PROXY_TOKEN:-}" >"$tmp/gate_run"
        printf '%s\n' "$@" >>"$tmp/gate_run"
      else
        printf '%s\n' "$@" >"$tmp/sbx_run"
      fi ;;
    network) return 0 ;;
    inspect) echo "172.30.0.2" ;;
    exec) return 0 ;;
    logs|rm) return 0 ;;
  esac
}
export HUTCH_API_KEY="sk-real-secret-value" DEEPSEEK_API_KEY="sk-ds-secret" OPENAI_API_KEY="sk-oai-secret" ANTHROPIC_API_KEY="sk-ant-secret"
AGENT=opencode sandbox vsoft >/dev/null
sbx1="$(cat "$tmp/sbx_run")"
gate1="$(cat "$tmp/gate_run")"
oc1="$(cat "$STATE/work/vsoft/opencode.json")"
gt1="$(cat "$STATE/work/vsoft/gate.conf.template")"
tok1="$(awk -F= '/^GATE_ENV_TOK=/{print $2}' "$tmp/gate_run")"
AGENT=claude sandbox vsoft >/dev/null
sbx2="$(cat "$tmp/sbx_run")"
tok2="$(awk -F= '/^GATE_ENV_TOK=/{print $2}' "$tmp/gate_run")"
unset -f docker need_image
reload_hutch
unset HUTCH_API_KEY DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY

check "sandbox never receives real API keys and gets a unique per-run HUTCH_PROXY_TOKEN" '
  [[ "$tok1" == hutch-proxy-* && "$tok2" == hutch-proxy-* && "$tok1" != "$tok2" ]] &&
  [[ "$gate1" == *"GATE_ENV_KEY=sk-real-secret-value"* ]] &&
  [[ "$sbx1" != *"sk-real-secret-value"* && "$sbx1" != *"sk-ds-secret"* && "$sbx1" != *"sk-oai-secret"* && "$sbx1" != *"sk-ant-secret"* ]] &&
  [[ "$oc1" != *"sk-real-secret-value"* && "$oc1" == *"\"apiKey\": \"$tok1\""* ]] &&
  [[ "$gt1" != *"sk-real-secret-value"* && "$gt1" != *"$tok1"* ]] &&
  [[ "$sbx1" == *"HUTCH_PROXY_TOKEN=$tok1"* && "$sbx1" == *"OPENCODE_API_KEY=$tok1"* ]] &&
  [[ "$sbx2" == *"HUTCH_PROXY_TOKEN=$tok2"* && "$sbx2" == *"ANTHROPIC_AUTH_TOKEN=$tok2"* ]]
'

# Workstream 3: Copy-on-Write / Overlay dependency & build caching + status cache readiness.
check "validate_overlay_entry accepts valid specs and rejects bad paths/targets" '
  validate_overlay_entry "node_modules:/work/node_modules" &&
  validate_overlay_entry "~/.cache/go-build:/cache/go-build" &&
  ! (validate_overlay_entry "bad-no-colon") 2>/dev/null &&
  ! (validate_overlay_entry "a,b:/cache/x") 2>/dev/null &&
  ! (validate_overlay_entry "node_modules:/work") 2>/dev/null &&
  ! (validate_overlay_entry "node_modules:/etc/evil") 2>/dev/null &&
  ! (validate_overlay_entry "node_modules:/work/../escape") 2>/dev/null
'

OVREPO="$tmp/ovrepo"; mkdir -p "$OVREPO/node_modules/pkg"
printf 'ok\n' >"$OVREPO/node_modules/pkg/index.js"
OVCONF="$tmp/ovconf"; mkdir -p "$OVCONF"
printf 'cache_overlays=node_modules:/work/node_modules\ncache_overlay_mode=cow-tmpfs\n' >"$OVCONF/config"
CONF="$OVCONF"; REPO="$OVREPO"; STATE="$tmp/ovstate"; NAME=ovproj; CACHE_VOLUME="hutch-ovproj-cache"

overlay_up testov
check "cow-tmpfs mounts host cache strictly read-only with an ephemeral writable tmpfs target" '
  [[ "${OVERLAY_DOCKER_ARGS[*]}" == *"-v $OVREPO/node_modules:/.hutch-ro/ov0:ro"* &&
     "${OVERLAY_DOCKER_ARGS[*]}" == *"--tmpfs /work/node_modules:exec,"* &&
     "${OVERLAY_COW_PAIRS[*]}" == *"/.hutch-ro/ov0:/work/node_modules"* ]]
'
overlay_down

printf 'cache_overlays=node_modules:/work/node_modules\ncache_overlay_mode=docker-overlay\n' >"$OVCONF/config"
docker() {
  printf '%s\n' "$*" >>"$tmp/ovdocker"
  return 0
}
: >"$tmp/ovdocker"
overlay_up testdok
check "docker-overlay creates ephemeral overlayfs volume from lowerdir and cleans it up" '
  grep -q "volume create --driver local --opt type=overlay --opt device=overlay" "$tmp/ovdocker" &&
  grep -q "lowerdir=$OVREPO/node_modules,upperdir=" "$tmp/ovdocker" &&
  [[ "${OVERLAY_DOCKER_ARGS[*]}" == *"-v hutch-ov-ovproj-testdok-0:/work/node_modules"* ]]
'
overlay_down
check "overlay_down removes docker overlay volume and temp directories" '
  grep -q "volume rm -f hutch-ov-ovproj-testdok-0" "$tmp/ovdocker" &&
  [[ ! -e "$STATE/tmp/ov-testdok-0" ]]
'
unset -f docker

printf 'cache_mount=/cache/go-build\ncache_overlay_mode=cow-tmpfs\n' >"$OVCONF/config"
overlay_up testcm
check "legacy cache_mount is mounted read-only under /.hutch-ro/cache with ephemeral tmpfs overlay" '
  [[ "${OVERLAY_DOCKER_ARGS[*]}" == *"-v hutch-ovproj-cache:/.hutch-ro/cache:ro"* &&
     "${OVERLAY_DOCKER_ARGS[*]}" == *"--tmpfs /cache/go-build:exec,"* &&
     "${OVERLAY_COW_PAIRS[*]}" == *"/.hutch-ro/cache:/cache/go-build"* ]]
'
overlay_down

# status cache readiness
docker() {
  case "$1" in
    info) return 0 ;;
    image) return 0 ;;
    volume) return 0 ;;
    *) return 0 ;;
  esac
}
have_key() { return 0; }
try_resolve() { return 0; }
printf 'cache_overlays=node_modules:/work/node_modules\ncache_overlay_mode=cow-tmpfs\n' >"$OVCONF/config"
out="$(cmd_status)"; rc=$?
check "status reports ok cache overlay when host source dir exists" '[[ $rc -eq 0 && "$out" == *"cache /work/node_modules"* && "$out" == *"ok ("* ]]'
printf 'cache_overlays=missing_dir:/work/node_modules\n' >"$OVCONF/config"
out="$(cmd_status)"; rc=$?
check "status reports MISSING and exits 4 when configured overlay source dir is absent" '[[ $rc -eq 4 && "$out" == *"cache /work/node_modules"* && "$out" == *"MISSING"* ]]'
: >"$OVCONF/config"
out="$(cmd_status)"; rc=$?
check "status reports image-baked cache when no overlays are configured" '[[ $rc -eq 0 && "$out" == *"cache"* && "$out" == *"none (image-baked)"* ]]'
unset -f docker have_key try_resolve
reload_hutch

# offline with cow-tmpfs mounts and wraps verify command cleanly, then cleans up
CONF="$OVCONF"; REPO="$OVREPO"; STATE="$tmp/ovstate"; NAME=ovproj; CACHE_VOLUME="hutch-ovproj-cache"
printf 'cache_overlays=node_modules:/work/node_modules\ncache_overlay_mode=cow-tmpfs\n' >"$OVCONF/config"
docker() { printf '%s\n' "$@" >"$tmp/ovoffline"; }
offline -v "$tmp/t:/work" img -- bash /task/verify.sh
offargs="$(cat "$tmp/ovoffline")"
unset -f docker
reload_hutch
check "offline uses read-only overlay mount, passes HUTCH_COW_MOUNTS, and wraps verify command" '
  [[ "$offargs" == *"/.hutch-ro/ov0:ro"* &&
     "$offargs" == *"HUTCH_COW_MOUNTS=/.hutch-ro/ov0:/work/node_modules"* &&
     "$offargs" == *"--tmpfs"*"/work/node_modules"* &&
     "$offargs" == *"/task/verify.sh"* ]]
'

# Workstream 4: Context pre-packing (--context) and Mid-Flight Watchdog.
CTXR="$tmp/ctxrepo"; git init -q -b main "$CTXR"
mkdir -p "$CTXR/src"
printf 'line1\nline2\nline3\nline4\nline5\n' >"$CTXR/src/types.ts"
printf 'export const x = 1;\n' >"$CTXR/src/util.ts"
printf 'SECRET=1\n' >"$CTXR/.env"
git -C "$CTXR" add -A; git -C "$CTXR" -c user.name=t -c user.email=t@t commit -qm base

pack_context "$CTXR" "$tmp/ctx.md" "src/types.ts:2-4" "src/util.ts"
ctx_out="$(cat "$tmp/ctx.md")"
check "pack_context slices line ranges and whole files with line numbers" '
  [[ "$ctx_out" == *"### \`src/types.ts\` (lines 2-4 of 5)"* &&
     "$ctx_out" == *"2 | line2"* && "$ctx_out" == *"4 | line4"* &&
     "$ctx_out" != *"1 | line1"* && "$ctx_out" != *"5 | line5"* &&
     "$ctx_out" == *"### \`src/util.ts\` (lines 1-1 of 1)"* &&
     "$ctx_out" == *"1 | export const x = 1;"* ]]
'
check "pack_context rejects traversal, absolute paths, .env, missing files, and inverted ranges" '
  ! (pack_context "$CTXR" "$tmp/bad.md" "../outside") 2>/dev/null &&
  ! (pack_context "$CTXR" "$tmp/bad.md" "/etc/passwd") 2>/dev/null &&
  ! (pack_context "$CTXR" "$tmp/bad.md" ".env") 2>/dev/null &&
  ! (pack_context "$CTXR" "$tmp/bad.md" "src/missing.ts") 2>/dev/null &&
  ! (pack_context "$CTXR" "$tmp/bad.md" "src/types.ts:4-2") 2>/dev/null
'

CONF="$tmp/vconf"; REPO="$CTXR"; STATE="$tmp/ctxstate"; NAME=ctxproj; PROJECT_IMAGE="hutch-ctxproj:latest"
: >"$CONF/config"; printf '# primer\n' >"$CONF/primer.md"
MODEL=m SMALL_MODEL=s AGENT=opencode
cmd_new ctx1 --allow 'src/*.ts' --brief "$tmp/vbrief" --context "src/types.ts:2-3" >/dev/null
sandbox() { printf '%s\n' "${SANDBOX_CMD[@]}" >"$tmp/ctxcmd"; return 0; }
cmd_run ctx1 --context "src/util.ts:1" >/dev/null
reload_hutch
ctx_prompt="$(cat "$tmp/ctxcmd")"
check "cmd_new and cmd_run --context inline pre-packed snippets into the agent prompt" '
  [[ -s "$STATE/work/ctx1/context.md" &&
     "$ctx_prompt" == *"Pre-packed context"* &&
     "$ctx_prompt" == *"2 | line2"* &&
     "$ctx_prompt" == *"1 | export const x = 1;"* ]]
'

# Mid-Flight Watchdog: opencode loop detection (mid-flight abort while stub sleeps).
export HUTCH_WATCHDOG_POLL=0.1
sandbox() {
  printf '%s\n' \
    '{"type":"step_start"}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"TypeError: bad"}}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"TypeError: bad"}}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"TypeError: bad"}}}'
  sleep 15
}
out="$( (cmd_run ctx1) 2>&1)"; rc=$?
reload_hutch
check "watchdog aborts mid-flight on 3 consecutive identical failing opencode commands with exit 43" '
  [[ $rc -eq 43 && "$out" == *"EARLY_ABORT: LOOP_DETECTED"* && "$out" == *"TypeError: bad"* &&
     "$(cat "$STATE/out/ctx1/exit.code")" == 43 && -s "$STATE/out/ctx1/abort.log" ]]
'

# Mid-Flight Watchdog: claude tool_result loop detection (the same command with the same error).
sandbox() {
  printf '%s\n' \
    '{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cmd1"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"EACCES permission denied"}]}}' \
    '{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cmd1"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"EACCES permission denied"}]}}' \
    '{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"cmd1"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"EACCES permission denied"}]}}'
  sleep 15
}
out="$( (cmd_run ctx1) 2>&1)"; rc=$?
reload_hutch
check "watchdog aborts mid-flight on 3 consecutive identical claude tool errors with exit 43" '
  [[ $rc -eq 43 && "$out" == *"EARLY_ABORT: LOOP_DETECTED"* && "$out" == *"EACCES permission denied"* ]]
'

# Mid-Flight Watchdog: streak resets on a passing command.
sandbox() {
  printf '%s\n' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"fail"}}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"fail"}}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":0},"output":"ok"}}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"fail"}}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"metadata":{"exit":1},"output":"fail"}}}'
  return 0
}
out="$( (cmd_run ctx1) 2>&1)"; rc=$?
reload_hutch
check "watchdog resets failure streak on a passing command and exits 0" '[[ $rc -eq 0 && "$out" != *"LOOP_DETECTED"* ]]'

# Mid-Flight Watchdog: --max-turns enforcement (allows N turns, aborts on N+1).
sandbox() {
  printf '%s\n' '{"type":"step_start"}' '{"type":"step_finish"}' '{"type":"step_start"}' '{"type":"step_finish"}'
  return 0
}
out="$( (cmd_run --max-turns 2 ctx1) 2>&1)"; rc=$?
check "cmd_run --max-turns 2 succeeds when only 2 turns run" '[[ $rc -eq 0 ]]'
sandbox() {
  printf '%s\n' '{"type":"step_start"}' '{"type":"step_finish"}' '{"type":"step_start"}' '{"type":"step_finish"}' '{"type":"step_start"}'
  sleep 15
}
out="$( (cmd_run --max-turns 2 ctx1) 2>&1)"; rc=$?
reload_hutch
check "cmd_run --max-turns 2 aborts mid-flight on turn 3 with exit 44" '[[ $rc -eq 44 && "$out" == *"EARLY_ABORT: MAX_TURNS"* && "$(cat "$STATE/out/ctx1/exit.code")" == 44 ]]'

# Mid-Flight Watchdog: --max-timeout and mid-flight .hutch-needs-scope abort.
sandbox() { sleep 15; }
out="$( (cmd_run --max-timeout 1 ctx1) 2>&1)"; rc=$?
reload_hutch
check "cmd_run --max-timeout aborts a stalled sandbox on host with exit 124" '[[ $rc -eq 124 && "$out" == *"1s limit"* ]]'

sandbox() {
  printf 'src/other.ts\n' >"$(task_dir "$1")/repo/.hutch-needs-scope"
  sleep 15
}
out="$( (cmd_run ctx1) 2>&1)"; rc=$?
reload_hutch
rm -f "$STATE/work/ctx1/repo/.hutch-needs-scope"
check "watchdog aborts a sleeping sandbox mid-flight when .hutch-needs-scope appears" '[[ $rc -eq 42 && "$out" == *"EARLY_ABORT: NEEDS_SCOPE"* && "$out" == *"src/other.ts"* ]]'
unset HUTCH_WATCHDOG_POLL

# Workstream 5: Per-task claude state dir, unique RUN_ID gate names, and cmd_batch parallel fan-out.
docker() {
  local sub="$1"; shift
  case "$sub" in
    run)
      if [[ " $* " == *" $GATE_IMAGE "* ]]; then
        printf '%s\n' "$@" >>"$tmp/p5gate"
      else
        printf '%s\n' "$@" >"$tmp/p5sbx"
      fi ;;
    network) return 0 ;;
    inspect) echo "172.30.0.9" ;;
    exec|logs|rm) return 0 ;;
  esac
}
need_image() { return 0; }
have_key() { return 0; }
export HUTCH_API_KEY="sk-p5-test"
SANDBOX_CMD=(true)
: >"$tmp/p5gate"
AGENT=claude sandbox ctx1 >/dev/null
p5sbx="$(cat "$tmp/p5sbx")"
AGENT=claude sandbox ctx1 >/dev/null
gnames="$(awk '$0 == "--name" { getline; print }' "$tmp/p5gate")"
gname1="$(printf '%s\n' "$gnames" | sed -n '1p')"
gname2="$(printf '%s\n' "$gnames" | sed -n '2p')"
unset -f docker need_image have_key
reload_hutch
unset HUTCH_API_KEY
check "claude sandbox mounts per-task claude-data and assigns unique gate names per run" '
  [[ "$p5sbx" == *"$STATE/work/ctx1/claude-data:/home/hutch/.claude"* &&
     "$p5sbx" != *"hutch-ctxproj-claude:"* &&
     -n "$gname1" && -n "$gname2" && "$gname1" != "$gname2" ]]
'

for bt in bt1 bt2 bt3; do
  cmd_new "$bt" --allow 'src/*.ts' --brief "$tmp/vbrief" >/dev/null
done
export HUTCH_WATCHDOG_POLL=0.1
sandbox() {
  case "$1" in
    bt1) return 0 ;;
    bt2) printf 'src/need.ts\n' >"$(task_dir bt2)/repo/.hutch-needs-scope"; sleep 10 ;;
    bt3) printf '%s\n' \
           '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"t"},"metadata":{"exit":1},"output":"boom"}}}' \
           '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"t"},"metadata":{"exit":1},"output":"boom"}}}' \
           '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"t"},"metadata":{"exit":1},"output":"boom"}}}'
         sleep 10 ;;
  esac
}
out="$( (cmd_batch bt1 bt2 bt3) 2>&1)"; rc=$?
reload_hutch
check "cmd_batch runs tasks in parallel, prints summary outcomes, and fails if any task aborts" '
  [[ $rc -ne 0 && "$out" == *"== batch summary"* &&
     "$out" == *"bt1"* && "$out" == *"ok"* &&
     "$out" == *"bt2"* && "$out" == *"NEEDS_SCOPE"* &&
     "$out" == *"bt3"* && "$out" == *"LOOP_DETECTED"* ]]
'

rm -f "$(task_dir bt2)/repo/.hutch-needs-scope"
sandbox() { sleep 0.2; return 0; }
out="$( (cmd_batch --max-parallel 2 bt1 bt2 bt3) 2>&1)"; rc=$?
reload_hutch
unset HUTCH_WATCHDOG_POLL
check "cmd_batch --max-parallel 2 exits 0 when all tasks succeed" '
  [[ $rc -eq 0 && "$out" == *"bt1"* && "$out" == *"bt2"* && "$out" == *"bt3"* ]]
'

# --- PR2 fixes: group A (run + watchdog) ---
MODEL=m SMALL_MODEL=s AGENT=opencode
: >"$CONF/config"
cmd_new ga --allow 'src/*.ts' --brief "$tmp/vbrief" >/dev/null
GA_OUT="$STATE/out/ga"; GA_REPO="$STATE/work/ga/repo"
export HUTCH_WATCHDOG_POLL=0.1
ga_secs() { echo $(( $(date +%s) - ga_t0 )); }

# B1: /out is the sandbox subdirectory; the files hutch writes are in a directory no container sees.
docker() {
  local sub="$1"; shift
  case "$sub" in
    run) [[ " $* " == *" $GATE_IMAGE "* ]] || printf '%s\n' "$@" >"$tmp/ga_sbx" ;;
    inspect) echo "172.30.0.3" ;;
  esac
  return 0
}
need_image() { return 0; }
HUTCH_API_KEY=sk-ga SANDBOX_CMD=(true) sandbox ga >/dev/null
check "B1: the sandbox gets out/<task>/sandbox as /out, never out/<task>" '
  grep -qxF "$GA_OUT/sandbox:/out" "$tmp/ga_sbx" && ! grep -qxF "$GA_OUT:/out" "$tmp/ga_sbx" && [[ -d "$GA_OUT/sandbox" ]]'
mkdir -p "$tmp/ga_elsewhere"; mv "$GA_OUT/sandbox" "$tmp/ga_sbxdir"; ln -s "$tmp/ga_elsewhere" "$GA_OUT/sandbox"
out="$( (HUTCH_API_KEY=sk-ga SANDBOX_CMD=(true) sandbox ga) 2>&1)"; rc=$?
rm "$GA_OUT/sandbox"; mv "$tmp/ga_sbxdir" "$GA_OUT/sandbox"
check "B1: the sandbox refuses a symlinked out/<task>/sandbox" '[[ $rc -ne 0 && "$out" == *"is a symlink"* ]]'

# B1: export runs git in a container that writes to an empty directory, then moves the bundle in.
docker() {
  local a prev=""
  for a in "$@"; do
    if [[ "$prev" == -v && "$a" == *:/out ]]; then
      printf '%s\n' "${a%:/out}" >"$tmp/ga_export_mount"; echo bundle >"${a%:/out}/ga.bundle"
    fi
    prev="$a"
  done
}
cmd_export ga
check "B1: export never mounts the output directory and leaves the bundle there" '
  [[ "$(cat "$tmp/ga_export_mount")" == "$STATE/work/ga/export" && "$(cat "$GA_OUT/ga.bundle")" == bundle &&
     ! -e "$STATE/work/ga/export" ]]'

unset -f docker need_image
reload_hutch

# B1: a symlinked .hutch-needs-scope (in /work or /out) is never read on the host.
echo "secret-host-line" >"$tmp/ga_hostfile"
sandbox() {
  ln -s "$tmp/ga_hostfile" "$GA_REPO/.hutch-needs-scope"
  ln -s "$tmp/ga_hostfile" "$GA_OUT/sandbox/.hutch-needs-scope"
  return 0
}
out="$( (cmd_run ga) 2>&1)"; rc=$?
reload_hutch
check "B1: the watchdog ignores a symlinked .hutch-needs-scope" '
  [[ $rc -eq 0 && "$out" != *"secret-host-line"* && "$out" != *NEEDS_SCOPE* && ! -e "$GA_OUT/needs-scope.txt" ]]'

# M4: malformed or unexpectedly typed events are skipped; later events still count.
sandbox() {
  printf '%s\n' 'not json' '[1, 2]' '"str"' \
    '{"type":"error","error":{"message":{"x":1}}}' \
    '{"type":"assistant","message":{"id":{"x":1},"content":[{"type":"tool_use","id":["t"],"input":{}}]}}' \
    '{"type":"tool_use","part":{"tool":"bash","state":{"status":"error","input":{"command":{"x":1}},"error":{"a":1}}}}' \
    '{"type":"result","is_error":true,"result":{"x":1},"num_turns":"9"}' \
    '{"type":"step_start"}' '{"type":"step_start"}' '{"type":"step_start"}'
  sleep 15
}
out="$( (set -e; cmd_run --max-turns 2 ga) 2>&1)"; rc=$?
reload_hutch
check "M4: the watchdog survives malformed events and still enforces max-turns" '[[ $rc -eq 44 && "$out" == *"EARLY_ABORT: MAX_TURNS"* ]]'

# M3: only the same command with the same error is a loop; generic errors and different commands are not.
ga_oc() { printf '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"%s"},"metadata":{"exit":1},"output":"%s"}}}\n' "$1" "$2"; }
sandbox() { ga_oc "grep a f" ""; ga_oc "grep b f" ""; ga_oc "test -f x" ""; return 0; }
out="$( (cmd_run ga) 2>&1)"; rc=$?
check "M3: three different commands failing with no output are not a loop" '[[ $rc -eq 0 && "$out" != *LOOP_DETECTED* ]]'
sandbox() { ga_oc "npm test" "fail one"; ga_oc "npm test" "fail two"; ga_oc "npm test" "fail three"; return 0; }
out="$( (cmd_run ga) 2>&1)"; rc=$?
check "M3: the same command with different errors is not a loop" '[[ $rc -eq 0 && "$out" != *LOOP_DETECTED* ]]'
sandbox() { ga_oc "npm test" ""; ga_oc "npm test" ""; ga_oc "npm test" ""; return 0; }
out="$( (cmd_run ga) 2>&1)"; rc=$?
check "M3: the same command with only a generic error is not a loop" '[[ $rc -eq 0 && "$out" != *LOOP_DETECTED* ]]'
ga_cl() {
  printf '{"type":"assistant","message":{"id":"m%s","content":[{"type":"tool_use","id":"t%s","name":"Bash","input":{"command":"%s"}}]}}\n' "$1" "$1" "$2"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t%s","content":"Exit code 1"}]}}\n' "$1"
}
sandbox() { ga_cl 1 "grep a f"; ga_cl 2 "grep b f"; ga_cl 3 "test -f x"; return 0; }
out="$( (cmd_run ga) 2>&1)"; rc=$?
reload_hutch
check "M3: claude: different commands with \"Exit code 1\" are not a loop" '[[ $rc -eq 0 && "$out" != *LOOP_DETECTED* ]]'

# Minor: HUTCH_NEEDS_SCOPE: counts only in the agent's own text, not in a tool's output.
sandbox() {
  printf '%s\n' '{"type":"tool_use","part":{"tool":"bash","state":{"status":"completed","input":{"command":"cat notes"},"metadata":{"exit":0},"output":"HUTCH_NEEDS_SCOPE: src/a.ts"}}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"HUTCH_NEEDS_SCOPE: src/b.ts"}]}}'
  return 0
}
out="$( (cmd_run ga) 2>&1)"; rc=$?
check "minor: HUTCH_NEEDS_SCOPE: in tool output does not stop the run" '[[ $rc -eq 0 && "$out" != *NEEDS_SCOPE* ]]'
sandbox() { printf '%s\n' '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Blocked.\nHUTCH_NEEDS_SCOPE: src/c.ts"}]}}'; return 0; }
out="$( (cmd_run ga) 2>&1)"; rc=$?
reload_hutch
check "minor: HUTCH_NEEDS_SCOPE: in claude assistant text stops the run" '[[ $rc -eq 42 && "$(cat "$GA_OUT/needs-scope.txt")" == src/c.ts ]]'

# M2: a stopped run removes its gates by name, in case its job was killed while gate_up ran.
docker() { printf '%s\n' "$*" >>"$tmp/ga_stop"; [[ "$1" == ps ]] && echo g-leaked; return 0; }
: >"$tmp/ga_stop"
stop_sandbox_run hutch-run-proj-ga-123-abcd "" ""
check "M2: stop_sandbox_run removes the run's gates by name" '
  grep -qxF "ps -aq --filter name=hutch-gate-proj-ga-123-" "$tmp/ga_stop" && grep -qxF "rm -f g-leaked" "$tmp/ga_stop"'
unset -f docker
reload_hutch

# M2: scope markers left by an earlier run are removed when a run starts.
printf 'src/x.ts\n' >"$GA_REPO/.hutch-needs-scope"; printf 'src/y.ts\n' >"$GA_OUT/sandbox/.hutch-needs-scope"
sandbox() { touch "$tmp/ga_ran"; return 0; }
out="$( (cmd_run ga) 2>&1)"; rc=$?
reload_hutch
check "M2: a stale .hutch-needs-scope does not stop the next run" '
  [[ $rc -eq 0 && -e "$tmp/ga_ran" && "$out" != *NEEDS_SCOPE* && ! -e "$GA_REPO/.hutch-needs-scope" ]]'

# B2: a sandbox that exits non-zero ends the run at once, under set -e, for both agents.
sandbox() { return 3; }
ga_t0="$(date +%s)"; out="$( (set -e; cmd_run --max-timeout 6 ga) 2>&1)"; rc=$?; el="$(ga_secs)"
check "B2: opencode: a failing sandbox returns its exit code at once" '[[ $rc -eq 3 && $el -lt 5 && "$(cat "$GA_OUT/exit.code")" == 3 ]]'
ga_t0="$(date +%s)"; out="$( (set -e; AGENT=claude; cmd_run --max-timeout 6 ga) 2>&1)"; rc=$?; el="$(ga_secs)"
check "B2: claude: a failing sandbox returns its exit code at once" '[[ $rc -eq 3 && $el -lt 5 ]]'
# B2/M4: the run also ends when its job is gone without an exit code (the loop checks that the job is alive).
sandbox() { sh -c 'kill -9 $PPID'; sleep 10; }
ga_t0="$(date +%s)"; out="$( (set -e; cmd_run --max-timeout 6 ga) 2>&1)"; rc=$?; el="$(ga_secs)"
reload_hutch
check "B2: a run whose job died ends at once with the job's status" '[[ $rc -eq 137 && $el -lt 5 ]]'

# Minor: a limit of 0 means no limit, as with coreutils timeout.
sandbox() { printf '%s\n' "${SANDBOX_CMD[*]}" >"$tmp/ga_cmd"; sleep 1.5; return 0; }
out="$( (cmd_run --max-timeout 0 ga) 2>&1)"; rc=$?
check "minor: --max-timeout 0 runs with no limit" '[[ $rc -eq 0 && "$(cat "$tmp/ga_cmd")" == "timeout -k 30 0 opencode run "* ]]'
out="$( (HUTCH_RUN_TIMEOUT=0 cmd_run ga) 2>&1)"; rc=$?
reload_hutch
check "minor: run_timeout=0 runs with no limit" '[[ $rc -eq 0 ]]'

# Minor: batch rejects duplicate tasks, and on TERM stops its runs and their sandboxes and prints the summary.
out="$( (cmd_batch ga ga) 2>&1)"; rc=$?
check "minor: batch rejects a task listed twice" '[[ $rc -ne 0 && "$out" == *"listed twice"* ]]'
cmd_new gb --allow 'src/*.ts' --brief "$tmp/vbrief" >/dev/null
sandbox() { sh -c 'echo $$ >"$1"; exec sleep 30' _ "$tmp/ga_sleep_$1"; }
ga_t0="$(date +%s)"
(cmd_batch ga gb) >"$tmp/ga_batch" 2>&1 &
bpid=$!
sleep 2; kill -TERM "$bpid"; wait "$bpid"; rc=$?; el="$(ga_secs)"
reload_hutch
out="$(cat "$tmp/ga_batch")"
check "minor: batch on TERM stops every run, kills their sandboxes and prints the summary" '
  [[ $rc -eq 143 && $el -lt 10 && "$out" == *"== batch summary"* &&
     "$(grep -c " interrupted$" "$tmp/ga_batch")" == 2 ]] &&
  ! kill -0 "$(cat "$tmp/ga_sleep_ga")" 2>/dev/null && ! kill -0 "$(cat "$tmp/ga_sleep_gb")" 2>/dev/null'
unset HUTCH_WATCHDOG_POLL

# --- PR2 fixes: group B (verify) ---
BREPO="$tmp/brepo"; git init -q -b main "$BREPO"
mkdir -p "$BREPO/src" "$BREPO/tests" "$BREPO/.github/workflows" "$BREPO/billing"
printf 'a = 1\n' >"$BREPO/src/a.py"
printf 'def test_a():\n    pass\n' >"$BREPO/tests/test_a.py"
printf 'def test_b():\n    pass\n' >"$BREPO/tests/tëst_b.py"
printf '{}\n' >"$BREPO/package.json"
printf 'on: push\n' >"$BREPO/.github/workflows/ci.yml"
printf 'fee = 1\n' >"$BREPO/billing/fees.py"
git -C "$BREPO" add -A; git -C "$BREPO" -c user.name=t -c user.email=t@t commit -qm base
bbase="$(git -C "$BREPO" rev-parse HEAD)"
CONF="$tmp/bconf"; mkdir -p "$CONF"
printf 'scope_mode=soft\n' >"$CONF/config"; : >"$CONF/protected"; : >"$CONF/openable"; printf 'true\n' >"$CONF/verify.sh"
STATE="$tmp/bstate"; NAME=bproj; REPO="$BREPO"; PROJECT_IMAGE="hutch-bproj:latest"
printf 'src/*\n' >"$tmp/ballow"
make_btask() {
  local t="$1" script="$2"
  cmd_new "$t" "$tmp/ballow" "$tmp/vbrief" >/dev/null
  (cd "$STATE/work/$t/repo" && eval "$script" && git add -A && git commit -qm "agent: $t")
  git -C "$STATE/work/$t/repo" bundle create "$STATE/out/$t/$t.bundle" "${bbase}..hutch/$t" >/dev/null 2>&1
}
need_image() { return 0; }
offline() { return 0; }

make_btask bquote 'printf "x\n" >.github/workflows/déploy.yml'
out="$( (cmd_verify bquote) 2>&1)"; rc=$?
check "B4: verify rejects a protected path with a non-ASCII name (no quoted paths)" '
  [[ $rc -ne 0 && "$out" == *"PROTECTED .github/workflows/déploy.yml"* ]]'

make_btask brentest 'git mv tests/test_a.py src/old_a.py'
out="$( (cmd_verify --strict-scope brentest) 2>&1)"; rc=$?
check "B4: verify counts a renamed existing test as its deletion (PROTECTED-TEST)" '
  [[ $rc -ne 0 && "$out" == *"PROTECTED-TEST tests/test_a.py"* && "$out" == *"ok src/old_a.py"* ]]'

make_btask brenprot 'git mv package.json src/pkg.json && git mv .github/workflows/ci.yml src/ci.yml'
out="$( (cmd_verify --strict-scope brenprot) 2>&1)"; rc=$?
check "B4: verify rejects moving protected files into an allowed directory" '
  [[ $rc -ne 0 && "$out" == *"PROTECTED package.json"* && "$out" == *"PROTECTED .github/workflows/ci.yml"* ]]'

make_btask bedittest 'printf "def test_b():\n" >tests/tëst_b.py'
out="$( (cmd_verify --allow-tests bedittest) 2>&1)"; rc=$?
check "B4: test changes name an edited test with a non-ASCII name" '[[ "$out" == *"EDITED tests/tëst_b.py (-1)"* ]]'

unset -f need_image offline
reload_hutch

echo "failures: $fails"
[[ $fails -eq 0 ]]
