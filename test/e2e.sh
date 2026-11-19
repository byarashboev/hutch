#!/usr/bin/env bash
# End-to-end test of hutch with Docker and no model: hutch builds the images and a throwaway project, the test plays
# the sandbox agent by committing into the task's workspace, then hutch export and hutch verify must accept a clean
# change and reject each kind of bad one. The isolation probe runs with a dummy key: only the gate may answer, and
# only for the provider's paths. It builds hutch-base, pulls the gate and creates the networks, like hutch build does.
# With HUTCH_RUNTIME set (CI sets runsc), every sandbox and check runs under that runtime.
# Checks are single-quoted on purpose: check() evals them later (SC2016, SC2034).
# shellcheck disable=SC2016,SC2034
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
hutch="$here/hutch"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"; docker rmi -f hutch-e2e-demo:latest >/dev/null 2>&1 || true' EXIT
export HUTCH_HOME="$tmp/home"
unset HUTCH_PROJECT HUTCH_BRANCH HUTCH_OPENED HUTCH_RUN_TIMEOUT HUTCH_VERIFY_TIMEOUT HUTCH_PIDS HUTCH_MEMORY
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; echo "$out" | sed 's/^/     | /' | tail -20; fi; }

# A small Node project: one module, one test, no dependencies (hutch-base already has Node).
repo="$tmp/e2e-demo"
mkdir -p "$repo/src" "$repo/test"
git init -q -b main "$repo"
cat >"$repo/package.json" <<'EOF'
{ "name": "e2e-demo", "type": "module", "scripts": { "test": "node --test" } }
EOF
printf 'export const add = (a, b) => a + b;\n' >"$repo/src/math.js"
cat >"$repo/test/math.test.js" <<'EOF'
import { test } from "node:test";
import assert from "node:assert/strict";
import { add } from "../src/math.js";
test("adds", () => { assert.equal(add(1, 2), 3); });
EOF
git -C "$repo" add -A
git -C "$repo" -c user.name=e2e -c user.email=e2e@localhost commit -qm base
cd "$repo"

"$hutch" init >/dev/null
conf="$HUTCH_HOME/projects/e2e-demo"
# The checks below cover soft scope; the template's default is strict.
sed 's/^scope_mode=.*/scope_mode=soft/' "$conf/config" >"$tmp/config" && mv "$tmp/config" "$conf/config"
printf 'ARG HUTCH_BASE=hutch-base:latest\nFROM ${HUTCH_BASE}\nUSER hutch\nWORKDIR /work\n' >"$conf/Dockerfile"
printf 'cd /work\nnode --test\n' >"$conf/verify.sh"
printf '# e2e primer\n' >"$conf/primer.md"
rm -f "$conf/checklist.md"
"$hutch" build >"$tmp/build.log" 2>&1 || { tail -30 "$tmp/build.log"; exit 1; }
pass "hutch build (base image, gate, project image)"

printf 'src/*\n' >"$tmp/allow"
printf '# brief\nAdd mul.\n' >"$tmp/brief.md"

# agent_task creates task $1, runs the shell commands $2 in its workspace as the agent, and commits them.
agent_task() {
  "$hutch" new "$1" "$tmp/allow" "$tmp/brief.md" >/dev/null
  (cd "$HUTCH_HOME/state/e2e-demo/work/$1/repo" && eval "$2" && git add -A && git commit -qm "agent: $1")
  "$hutch" export "$1" >/dev/null 2>&1
}

# Workstream 1: new test files pass without --allow-tests; pre-existing tests require --allow-tests;
# non-protected unscoped files pass with WARN: UNSCOPED_PATHS in soft mode and fail under --strict-scope;
# hard denylist (package.json, .gitattributes) always fails.
agent_task clean 'printf "export const mul = (a, b) => a * b;\n" >>src/math.js
  printf "import { test } from \"node:test\"; import assert from \"node:assert/strict\"; import { mul } from \"../src/math.js\"; test(\"muls\", () => assert.equal(mul(2, 3), 6));\n" >test/mul.test.js'
rc=0; out="$("$hutch" verify clean 2>&1)" || rc=$?
check "a clean change + new test passes verify without --allow-tests" '[[ $rc -eq 0 && "$out" == *"verify passed"* && "$out" == *"WARN: UNSCOPED_PATHS"* && "$out" == *"new test/mul.test.js"* ]]'

agent_task extend-test 'printf "test(\"muls\", async () => { const m = await import(\"../src/math.js\"); assert.equal(m.add(2, 3), 5); });\n" >>test/math.test.js'
rc=0; out="$("$hutch" verify extend-test 2>&1)" || rc=$?
check "modifying a pre-existing test fails verify by default" '[[ $rc -ne 0 && "$out" == *"PROTECTED-TEST test/math.test.js"* ]]'
rc=0; out="$("$hutch" verify --allow-tests extend-test 2>&1)" || rc=$?
check "modifying a pre-existing test passes with --allow-tests" '[[ $rc -eq 0 && "$out" == *"verify passed"* && "$out" == *"extended test/math.test.js"* ]]'

agent_task outside 'printf "export const h = 1;\n" >src/helper.js; printf "x\n" >README.md'
rc=0; out="$("$hutch" verify outside 2>&1)" || rc=$?
check "soft mode passes non-protected unscoped paths with WARN: UNSCOPED_PATHS" '[[ $rc -eq 0 && "$out" == *"WARN: UNSCOPED_PATHS"* && "$out" == *"UNSCOPED README.md"* ]]'
rc=0; out="$("$hutch" verify --strict-scope outside 2>&1)" || rc=$?
check "a change outside the allow list is rejected under --strict-scope" '[[ $rc -ne 0 && "$out" == *"NOT-ALLOWED README.md"* ]]'

agent_task hard-deny 'printf "{\"name\":\"tampered\"}\n" >package.json'
rc=0; out="$("$hutch" verify hard-deny 2>&1)" || rc=$?
check "hard denylist rejects package.json even in soft mode" '[[ $rc -ne 0 && "$out" == *"PROTECTED package.json"* ]]'

agent_task hide 'printf "throw new Error(\"broken\");\n" >>src/math.js; printf "* export-ignore\n" >test/.gitattributes'
rc=0; out="$("$hutch" verify hide 2>&1)" || rc=$?
check "a nested .gitattributes that hides tests is rejected" '[[ $rc -ne 0 && "$out" == *"PROTECTED test/.gitattributes"* ]]'

agent_task broken 'printf "export const sub = (a, b) => a + b;\n" >>src/math.js
  printf "import { test } from \"node:test\"; import assert from \"node:assert/strict\"; import { sub } from \"../src/math.js\"; test(\"subs\", () => assert.equal(sub(3, 1), 2));\n" >test/sub.test.js'
rc=0; out="$("$hutch" verify broken 2>&1)" || rc=$?
check "a failing check fails verify" '[[ $rc -ne 0 && "$out" == *"checks failed"* ]]'

# conf_get reads the first tests_policy= line, so the template's line is replaced, not followed by another.
{ grep -v '^tests_policy=' "$conf/config"; echo tests_policy=append-only; } >"$tmp/config" && mv "$tmp/config" "$conf/config"
agent_task weaken 'git rm -q test/math.test.js'
rc=0; out="$("$hutch" verify --allow-tests weaken 2>&1)" || rc=$?
check "a deleted test fails verify under append-only" '[[ $rc -ne 0 && "$out" == *"DELETED test/math.test.js"* && "$out" == *"append-only"* ]]'

agent_task slow 'printf "test(\"hangs\", () => new Promise(() => setInterval(() => {}, 1000)));\n" >>test/math.test.js'
rc=0; out="$(HUTCH_VERIFY_TIMEOUT=5 "$hutch" verify --allow-tests slow 2>&1)" || rc=$?
check "a hanging check stops at the verify limit" '[[ $rc -ne 0 && "$out" == *"5s limit"* ]]'

# Workstream 2: Zero-knowledge gate isolation probes.
out="$(HUTCH_API_KEY=dummy-secret HUTCH_KIND=script "$hutch" isolation clean 2>&1 </dev/null)" || true
check "isolation: GitHub, npm, the Anthropic API and DNS are blocked" '[[ "$out" == *"blocked direct https://github.com"* && "$out" == *"blocked direct https://registry.npmjs.org"* && "$out" == *"blocked direct https://api.anthropic.com"* && "$out" == *"blocked dns github.com"* ]]'
check "isolation: gate rejects spoofed auth, missing auth, traversal, and credential query params with 403" '
  [[ "$out" == *"spoofed Authorization http=403"* &&
     "$out" == *"spoofed x-api-key http=403"* &&
     "$out" == *"missing auth http=403"* &&
     "$out" == *"path traversal http=403"* &&
     "$out" == *"query credential http=403"* &&
     "$out" == *"other gate path http=403"* ]]
'
check "isolation: the provider key is not in the sandbox" '[[ "$out" == *"provider key: not in the sandbox"* && "$out" != *"dummy-secret"* ]]'
check "isolation: no capabilities and no credential directories" '[[ "$out" == *"CapEff:"*"0000000000000000"* && "$out" != *PRESENT* ]]'
check "isolation: the model API answers through the gate" '[[ "$out" =~ model\ API\ via\ gate\ http=[1-5][0-9][0-9] ]]'
if [[ -n "${HUTCH_RUNTIME:-}" ]]; then
  # gVisor reports its own kernel version, so on a Linux host the sandbox's kernel differs from the host's (CI).
  check "isolation: the sandbox runs under $HUTCH_RUNTIME, not the host kernel" '[[ "$out" == *"kernel "* && "$out" != *"kernel $(uname -r)"* ]]'
fi
check "isolation: the gate is removed afterwards and its log is kept" '[[ -z "$(docker ps -q --filter name=hutch-gate-e2e-demo)" && -s "$HUTCH_HOME/state/e2e-demo/out/clean/gate.log" ]]'
# --- PR2 fixes: group C (gate, key, networks) ---
check "isolation: the run's own internal network is removed afterwards" '[[ -z "$(docker network ls -q --filter label=hutch.project=e2e-demo)" ]]'

# Workstream 3: Warm read-only dependency overlay with ephemeral CoW writes (never mutating host).
mkdir -p "$repo/node_modules/demo-dep"
printf 'export const fortyTwo = 42;\n' >"$repo/node_modules/demo-dep/index.js"
printf '{"name":"demo-dep","type":"module","main":"index.js"}\n' >"$repo/node_modules/demo-dep/package.json"
echo "cache_overlays=node_modules:/work/node_modules" >>"$conf/config"
out="$("$hutch" status 2>&1)" || true
check "status reports warm cache overlay readiness" '[[ "$out" == *"cache /work/node_modules"* && "$out" == *"ok ("* ]]'
cat >"$conf/verify.sh" <<'EOF'
cd /work
node -e 'import("demo-dep").then(m => { if (m.fortyTwo !== 42) process.exit(1); })'
mkdir -p /work/node_modules/.cache
echo poisoned > /work/node_modules/.cache/probe
node --test
EOF
agent_task warm 'printf "export const ok = true;\n" >src/warm.js'
rc=0; out="$("$hutch" verify warm 2>&1)" || rc=$?
check "verify uses warm node_modules overlay offline and isolates writes from host" '
  [[ $rc -eq 0 && "$out" == *"verify passed"* &&
     ! -e "$repo/node_modules/.cache/probe" &&
     "$(cat "$repo/node_modules/demo-dep/index.js")" == "export const fortyTwo = 42;" ]]
'
# Reset verify.sh & remove overlay for parallel test cleanly or keep overlay active.
printf 'cd /work\nnode --test\n' >"$conf/verify.sh"

# Workstream 5: Concurrent export & verify fan-out without collisions.
agent_task par1 'printf "export const p1 = 1;\n" >src/p1.js'
agent_task par2 'printf "export const p2 = 2;\n" >src/p2.js'
(
  "$hutch" verify par1 >"$tmp/par1.out" 2>&1
) &
p1_pid=$!
(
  "$hutch" verify par2 >"$tmp/par2.out" 2>&1
) &
p2_pid=$!
p1_rc=0; p2_rc=0
wait "$p1_pid" || p1_rc=$?
wait "$p2_pid" || p2_rc=$?
check "parallel verify invocations succeed concurrently without collisions" '
  [[ $p1_rc -eq 0 && $p2_rc -eq 0 ]] &&
  grep -q "verify passed" "$tmp/par1.out" &&
  grep -q "verify passed" "$tmp/par2.out"
'

out="$("$hutch" ls 2>&1)" || true
check "ls lists every task with its verify status" '[[ "$out" =~ clean\ +[0-9]+[smh]\ +[^\ ]+.*passed && "$out" =~ broken\ .*failed:\ checks\ failed && "$out" == *slow* ]]'

out="$("$hutch" report clean 2>&1)" || true
check "report shows the verify outcome, the commit and the test changes" '[[ "$out" == *"verify: passed"* && "$out" == *"agent: clean"* && "$out" == *"new test/mul.test.js"* ]]'
out="$("$hutch" report broken 2>&1)" || true
check "report shows a failed verify" '[[ "$out" == *"verify: failed: checks failed"* ]]'

for t in clean extend-test outside hard-deny hide broken weaken slow warm par1 par2; do "$hutch" rm "$t"; done
echo "failures: $fails"
[[ $fails -eq 0 ]]
