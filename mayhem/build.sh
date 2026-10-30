#!/usr/bin/env bash
#
# mayhem/build.sh — build the MySQL Router libFuzzer harnesses (sanitized, one binary each plus a
# `-standalone` reproducer) and the Router's own gtest unit tests (normal flags) for mayhem/test.sh.
# Runs in the commit image as `mayhem` in /mayhem; fully offline (bundled boost/protobuf/gtest/etc.).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Router needs none of the server's optional plugins/submodules (rocksdb, coredumper, kmip, ldap, ...).
CMAKE_COMMON=(
  -G Ninja
  -DWITH_UNIT_TESTS=ON -DWITH_ROUTER=ON -DWITH_NDB=OFF -DWITH_LTO=OFF
  -DWITH_SSL=system -DWITH_CURL=system -DWITH_SYSTEM_LIBS=OFF
  -DWITH_ROCKSDB=OFF -DWITH_COREDUMPER=OFF -DWITH_COMPONENT_KEYRING_KMIP=OFF
  -DWITH_AUTHENTICATION_LDAP=OFF -DWITH_AUTHENTICATION_KERBEROS=OFF -DWITH_AUTHENTICATION_FIDO=OFF
  -DWITH_PAM=OFF -DWITH_FIDO=none
)

# LeakSanitizer off at build time (linked into every fuzz and standalone binary).
mkdir -p build
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o

# CMake discards the -D settings above and fails to reconfigure when the compiler path differs from the one
# cached in an existing build dir (the image build resolves clang through ccache's masquerade dir, a re-run
# resolves /usr/bin/clang), so start such a tree over.
for d in build/fuzz build/test; do
  if [ -f "$d/CMakeCache.txt" ] && ! grep -qxF "CMAKE_CXX_COMPILER:STRING=$(command -v "$CXX")" "$d/CMakeCache.txt"; then
    rm -rf "$d"
  fi
done

# 1) Sanitized fuzz build. COMPILER_HAS_PROFILE_INSTR_GENERATE=0 keeps the harnesses free of
#    -fprofile-instr-generate (no default.profraw written at exit). CMAKE_BUILD_TYPE=Debug keeps the
#    asserts: upstream's CMakeLists.txt prepends -DNDEBUG to every RelWithDebInfo/Release flag set (and
#    that -DNDEBUG lands after CMAKE_CXX_FLAGS, so -UNDEBUG there cannot undo it), which would hide the
#    bounds asserts in the SQL lexer and the classic-protocol codec from the fuzzers. -O2 in the common
#    flags (Debug adds no -O of its own) keeps the harnesses fast.
cmake -S "$SRC" -B build/fuzz "${CMAKE_COMMON[@]}" \
  -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCOMPILER_HAS_PROFILE_INSTR_GENERATE=0 \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O2" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O2" \
  -DCMAKE_EXE_LINKER_FLAGS="$SRC/build/lsan_off.o"

TARGETS=$(ninja -C build/fuzz -t targets all | grep -o '^routertest_fuzz_[a-z_0-9]*:' | tr -d : | sort -u)
[ -n "$TARGETS" ]
# shellcheck disable=SC2086
ninja -C build/fuzz -j"$MAYHEM_JOBS" $TARGETS

# copy_and_relink <name> <link command run in build/fuzz>: install the fuzz binary and relink the
# same objects with the run-once driver instead of libFuzzer.
copy_and_relink() {
  local name="$1" link="$2" out
  out="$(printf '%s\n' "$link" | sed -nE 's/.* -o ([^ ]+).*/\1/p')"
  cp "build/fuzz/$out" "$SRC/$name"
  link="${link/-fsanitize=fuzzer/$SRC/build/standalone_main.o}"
  link="$(printf '%s\n' "$link" | sed -E "s# -o [^ ]+# -o $SRC/$name-standalone#")"
  (cd build/fuzz && eval "$link")
}

for t in $TARGETS; do
  link="$(ninja -C build/fuzz -t commands "$t" | grep -- ' -o ' | tail -1)"
  link="${link#: && }"; link="${link%% && cd *}"
  copy_and_relink "${t#routertest_}" "$link"
done

# fuzz_kill.cc is a complete upstream harness (the fuzz_ping.cc template with client::Kill), but
# router/src/mysql_protocol/tests/CMakeLists.txt leaves `kill` out of its FOREACH, so no ninja target
# exists for it. Build it with fuzz_ping's own compile and link lines, renamed to the kill harness.
KILL=routertest_fuzz_mysql_protocol_kill
PING_CMDS="$(ninja -C build/fuzz -t commands routertest_fuzz_mysql_protocol_ping)"
rename_ping() { sed -e "s/routertest_fuzz_mysql_protocol_ping/$KILL/g" -e 's/fuzz_ping\.cc/fuzz_kill.cc/g'; }
compile="$(grep -- ' -c [^ ]*/fuzz_ping\.cc$' <<<"$PING_CMDS" | rename_ping)"
link="$(grep -- ' -o ' <<<"$PING_CMDS" | tail -1 | rename_ping)"
link="${link#: && }"; link="${link%% && cd *}"
[ -n "$compile" ] && [ -n "$link" ] || { echo "cannot derive the fuzz_kill build from fuzz_ping" >&2; exit 1; }
(cd build/fuzz \
  && mkdir -p "router/src/mysql_protocol/tests/CMakeFiles/$KILL.dir" \
  && eval "$compile" && eval "$link")
copy_and_relink "${KILL#routertest_}" "$link"

# 2) The Router's own gtest unit tests, built with NORMAL flags for mayhem/test.sh.
cmake -S "$SRC" -B build/test "${CMAKE_COMMON[@]}" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_DEBUG=OFF \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
# shellcheck disable=SC1091
. "$SRC/mayhem/unit-tests.txt"
ninja -C build/test -j"$MAYHEM_JOBS" $UNIT_TESTS
