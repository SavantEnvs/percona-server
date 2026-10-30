#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the MySQL Router gtest unit tests that mayhem/build.sh built in build/test.
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Known-answer gtest cases (base64/KDF/auth vectors, URI parsing, classic-protocol codecs, SQL parsers),
# run through ctest; counts are taken from gtest's per-case result lines.
# shellcheck disable=SC1091
. "$SRC/mayhem/unit-tests.txt"
[ -d build/test ] || { echo "build/test missing: mayhem/build.sh did not build the unit tests" >&2; emit_ctrf "gtest" 0 1 0; exit 1; }

expected=$(wc -w <<<"$UNIT_TESTS")
regex="^($(tr ' ' '|' <<<"$UNIT_TESTS"))$"
log="$(mktemp)"
(cd build/test && ctest -R "$regex" -V) >"$log" 2>&1
ctest_rc=$?

passed=$(grep -c '\[       OK \]' "$log" || true)
failed=$(grep -cE '\[  FAILED  \] .*\([0-9]+ ms\)' "$log" || true)
skipped=$(grep -cE '\[  SKIPPED \] .*\([0-9]+ ms\)' "$log" || true)
ran=$(sed -nE 's/.*tests passed, [0-9]+ tests failed out of ([0-9]+).*/\1/p' "$log" | tail -1)

# A run that executed no gtest cases, ran fewer binaries than expected, or made ctest fail is a failure.
if [ "$passed" -eq 0 ] || [ "${ran:-0}" -ne "$expected" ] || { [ "$ctest_rc" -ne 0 ] && [ "$failed" -eq 0 ]; }; then
  [ "$failed" -gt 0 ] || failed=1
  tail -20 "$log" >&2
fi
emit_ctrf "gtest" "$passed" "$failed" "$skipped"
