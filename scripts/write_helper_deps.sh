#!/usr/bin/env bash
# Write the dependency list a test checks a helper binary against
# (repro_test_support/fresh_binary, §13 decision 65 of the ReproOS Add-On
# Mode spec): every source file Nim read to compile <entry>, included files
# and modules from outside the tree among them, one path per line, at
# <build>/nimcache/<name>/<name>.deps.
#
#   scripts/write_helper_deps.sh <name> <entry.nim> [nim flags...]
#
# Pass the same flags the binary was built with: a define can change which
# modules are imported. Nim's --genDeps (an alias of --genScript) runs the
# compiler's front end and writes <module>.deps; it compiles and links
# nothing, so it runs in a nimcache of its own and the binary is not
# touched. Run it right after the build: a source edited in between is
# newer than the binary, which the check refuses anyway.
#
# REPRO_TEST_BUILD_DIR names another build directory (the Nim 2.2.4 lane's).
set -euo pipefail
name="${1:?usage: write_helper_deps.sh <name> <entry.nim> [nim flags...]}"
entry="${2:?usage: write_helper_deps.sh <name> <entry.nim> [nim flags...]}"
shift 2
build="${REPRO_TEST_BUILD_DIR:-build}"
cache="${build}/nimcache/${name}-deps"
rm -rf "${cache}"
mkdir -p "${cache}" "${build}/nimcache/${name}"
nim c --hints:off --warnings:off "$@" --genDeps:on \
  --nimcache:"${cache}" --out:"${cache}/${name}" "${entry}"
module="$(basename "${entry}" .nim)"
if [ ! -s "${cache}/${module}.deps" ]; then
  echo "write_helper_deps: nim wrote no ${cache}/${module}.deps" >&2
  exit 1
fi
cp "${cache}/${module}.deps" "${build}/nimcache/${name}/${name}.deps"
