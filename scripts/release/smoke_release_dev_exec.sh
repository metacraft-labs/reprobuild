#!/usr/bin/env bash
# smoke_release_dev_exec.sh <package-dir>
#
# Run the PACKAGED `repro` the way a consumer's CI does -- `repro exec` in a
# project that has a `repro.nim` -- and require it to reach the command.
#
# That first `repro exec` compiles the project's recipe (interface extraction)
# and its provider against the sources the archive ships under share/repro.
# v0.2.0 passed every existing release check (`--version`, `--help`,
# `capabilities`) and still failed here on every consumer:
#
#   Error: cannot open file: repro_interface_artifacts
#
# The project lives in a fresh temporary directory, so no reprobuild checkout
# is its sibling or ancestor, and every variable that could point the image at
# the build host's sources is removed first. The package itself is COPIED into
# that temporary directory and run from there, so the image does not run from
# inside the checkout it was built in either. The image has to find its own
# sources, exactly as on a consumer's machine (see "Where the sources come
# from" below; check_release_source_closure.sh proves those trees are complete
# without the host).
#
# It then runs `repro build --tool-provisioning=tarball` in a second fresh
# project with no `runquotad` in reach but the archive's, which is the first
# thing a from-source recipe needs and which `repro exec` never exercises (see
# "repro build with the archive's own lease coordinator" below).
#
# Needs a Nim compiler and a C compiler on PATH (the release legs have both).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <package-dir>" >&2
  exit 64
fi
src_pkg=$(cd "$1" && pwd)
[[ -f "$src_pkg/bin/repro" || -f "$src_pkg/bin/repro.exe" ]] ||
  { echo "smoke_release_dev_exec: no bin/repro in $src_pkg" >&2; exit 1; }

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/repro-release-smoke-XXXXXX")
# Best-effort: on Windows a helper the run started can still hold the
# project directory open for a moment ("Device or resource busy"), and a
# leftover temp dir must not turn a passed check into a failed step.
quota_runtime=''
trap 'rm -rf "$work" 2>/dev/null || true; if [[ -n "$quota_runtime" ]]; then rm -rf "$quota_runtime" 2>/dev/null || true; fi' EXIT

# Where the sources come from. The engine resolves the tree it compiles a
# recipe against from, in order: the REPROBUILD_LIBS_DIR / REPROBUILD_REPO_ROOT
# / REPROBUILD_SOURCE_ROOT variables, the installed layout beside its own image
# (<prefix>/share/repro/source), the current directory when that is a
# reprobuild tree, and last the checkout it was compiled in -- but only while
# the image runs from inside that checkout (reprobuildSourceRootCandidates in
# libs/repro_core/src/repro_core/source_root.nim). On the build host the
# package directory sits inside the checkout, so that last arm would quietly
# rescue an archive whose share/repro is missing. Running a copy that lives
# outside the checkout closes it; the variables are scrubbed below and the
# project directory is not a reprobuild tree, so a command that runs at all
# was compiled against the archive's own sources.
#
# This used to be observed instead through the REPROBUILD_SOURCE_ROOT the
# command inherited. `repro exec` now withdraws the roots the engine seeded
# for its own compiles before it starts the command (they are not the
# caller's, Distribution-And-Packaging section 5), so the command can no
# longer see which tree was used, and the copy is what proves it.
pkg="$work/$(basename "$src_pkg")"
cp -R "$src_pkg" "$pkg"
repro_bin="$pkg/bin/repro"
[[ -f "$repro_bin" ]] || repro_bin="$pkg/bin/repro.exe"
project="$work/project"
mkdir -p "$project"
# On Linux the recipe also declares a `dslDeps:` dependency and USES the symbol
# it exports. Its macro expansion resolves the dependency by running
# `<reproBin> internal resolve-package …` through `staticExec`, which ignores a
# failed command: under the archive's loader launcher a `reproBin` naming the
# glibc loader (getAppFilename()) resolved nothing and dropped the import
# without a word. Using the symbol turns that into a compile error here
# (`undeclared identifier`). The use is gated on `reproInterfaceMode` because
# only the interface compile receives the dslDeps imports. Linux only because
# the loader launcher is Linux-only, and that is where this has been verified.
if [[ "$(uname -s)" == Linux* ]]; then
  mkdir -p "$work/release_smoke_exporter"
  cat > "$work/release_smoke_exporter/repro.nim" <<'EOF'
const releaseSmokeExported* = "exported"
EOF
  cat > "$project/repro.nim" <<'EOF'
import repro_project_dsl

package releaseSmoke:
  dslDeps:
    "release_smoke_exporter"
  when defined(reproInterfaceMode):
    const releaseSmokeImported = releaseSmokeExported
    static: doAssert releaseSmokeImported.len > 0
  devEnv:
    discard
EOF
else
  cat > "$project/repro.nim" <<'EOF'
import repro_project_dsl

package releaseSmoke:
  devEnv:
    discard
EOF
fi

scrub=(
  REPROBUILD_SOURCE_ROOT REPROBUILD_LIBS_DIR REPROBUILD_REPO_ROOT
  REPROBUILD_SRC REPRO_BOOTSTRAP_SOURCE_ENV REPRO_PUBLIC_CLI_PATH
  NIMCRYPTO_SRC BEARSSL_SRC STACKABLE_HOOKS_SRC CODETRACER_TRACE_FORMAT_NIM_SRC
  IO_MON_SRC SHM_GSET_SRC SHM_QUEUE_SRC CODETRACER_SRC CODETRACER_PINNED_SRC
  REPRO_CT_TEST_RUNNER_SRC REPRO_TEST_ADAPTERS_SRC TEST_CERTIFICATES_TOOLS_SRC RUNQUOTA_SRC
  GOSTI_SRC
  FASTSTREAMS_SRC NIM_STEW_SRC NIM_SERIALIZATION_SRC NIM_JSON_SERIALIZATION_SRC
  NIM_TOML_SERIALIZATION_SRC SSZ_SERIALIZATION_SRC RESULTS_SRC STINT_SRC
)
for v in "${scrub[@]}"; do unset "$v"; done

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
# Windows' default RunQuota authority is host-wide. The release test runs in
# an exclusive fresh guest; each invocation retains and cleans only a server
# authenticated as this private archive's newly created image.
# Every Windows archive invocation can auto-start its coordinator, including
# the first exec. Isolate it before that invocation, not only before build.
isolate_archive_runquota() {
  # Drop source/build installations and explicit daemon/bypass overrides;
  # ordinary lookup must discover only the archive copy. Binary-cache
  # settings are withdrawn too, so this check neither substitutes nor publishes.
  local v d kept_path="" path_entries
  unset RUNQUOTAD_BIN RUNQUOTA_BIN RUNQUOTA_SOCKET REPROBUILD_NO_RUNQUOTA
  for v in $(env | sed -n 's/^\(REPRO_BINARY_CACHE_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
  # A PATH entry that holds a runquotad is replaced by a copy of itself
  # without it, not dropped: on a merged profile directory the same entry is
  # where `mv`, `cat` and the rest of this script's tools come from.
  local shadow shadow_index=0 entry
  IFS=: read -r -a path_entries <<< "$PATH"
  for d in ${path_entries[@]+"${path_entries[@]}"}; do
    [[ -n "$d" ]] || continue
    if [[ -e "$d/runquotad" || -e "$d/runquotad.exe" ]]; then
      shadow_index=$((shadow_index + 1))
      shadow="$work/path-without-runquotad-$shadow_index"
      rm -rf "$shadow"
      mkdir -p "$shadow"
      for entry in "$d"/* "$d"/.[!.]*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        case "${entry##*/}" in runquotad|runquotad.exe) continue ;; esac
        ln -s "$entry" "$shadow/${entry##*/}"
      done
      d="$shadow"
    fi
    kept_path="${kept_path:+$kept_path:}$d"
  done
  PATH="$pkg/bin:$kept_path"
  export PATH
}
windows_repro=no
if [[ -f "$pkg/bin/runquotad.exe" || -f "$pkg/bin/repro.exe" ]]; then
  windows_repro=yes
  windows_helper=$(native "$(cd "$(dirname "$0")" && pwd)/with_windows_archive_runquota.ps1")
  repro_bin=$(native "$repro_bin")
  isolate_archive_runquota
fi

marker="repro-release-smoke-ok"
echo "=== repro exec in a fresh project, using only $pkg ==="
out="$work/exec.log"
# Output goes to a FILE, not through `| tee`: a helper that outlives
# `repro exec` (on Windows, an msiexec it spawned) keeps a pipe's write end
# open, so a failed exec that printed its error at once still held the step
# for its whole 60-minute timeout. Bounded as well, for the same reason.
bound=()
if command -v timeout >/dev/null 2>&1; then
  bound=(timeout --kill-after=60 "${REPRO_SMOKE_TIMEOUT_SECONDS:-2700}")
fi
run_packaged_repro() {
  if [[ "$windows_repro" == yes ]]; then
    # printf is Bash's builtin: no Python/jq or new bootstrap dependency.
    # NUL framing preserves empty, quoted and trailing-backslash arguments.
    printf '%s\0' "$repro_bin" "$@" > "$work/command.argv"
    # This child-only policy leaves runner/user settings and Group Policy intact.
    ${bound[@]+"${bound[@]}"} powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -File "$windows_helper" \
      -ArchiveDaemon "$(native "$pkg/bin/runquotad.exe")" \
      -ArgumentFile "$(native "$work/command.argv")"
  else
    ${bound[@]+"${bound[@]}"} "$repro_bin" "$@"
  fi
}
set +e
# Guarded array expansion: under `set -u`, bash < 4.4 treats `"${bound[@]}"` on an
# empty array as an unbound variable. `${bound[@]+"${bound[@]}"}` expands to nothing
# when empty without triggering nounset errors on macOS stock /bin/bash (3.2).
(cd "$project" && run_packaged_repro exec -- bash -c \
  'echo "$1"' _ "$marker") \
  > "$out" 2>&1 < /dev/null
rc=$?
set -e
cat "$out"
if [[ $rc -eq 124 || $rc -eq 137 ]]; then
  echo "smoke_release_dev_exec: ERROR: repro exec did not finish within ${REPRO_SMOKE_TIMEOUT_SECONDS:-2700}s." >&2
  exit 1
fi
if [[ $rc -ne 0 ]] || ! grep -q "^${marker}" "$out"; then
  echo "smoke_release_dev_exec: ERROR: the packaged repro could not run a command in a fresh project (exit $rc)." >&2
  if grep -q "cannot open file" "$out"; then
    echo "  A module the installed compile needs is missing from the archive's share/repro;" >&2
    echo "  see scripts/release/stage_release_sources.sh." >&2
  fi
  if grep -q "error while loading shared libraries" "$out"; then
    echo "  The engine re-executed the glibc loader instead of its launcher;" >&2
    echo "  see publicCliImagePath in libs/repro_core/src/repro_core/source_root.nim." >&2
  elif grep -q "undeclared identifier" "$out"; then
    echo "  The recipe's dslDeps: import was dropped: its resolve-package callback" >&2
    echo "  (-d:reproBin) did not name a runnable engine." >&2
  fi
  exit 1
fi
echo "=== repro exec smoke test PASSED (sources: the archive copy at $pkg) ==="

# ---- repro build with the archive's own lease coordinator --------------------
#
# Under `--tool-provisioning=tarball` (and `nix`) the engine will not run an
# action without a RunQuota lease, and it starts `runquotad` itself only when it
# can find one: `$RUNQUOTAD_BIN`, PATH, or `../runquota/build/bin` above its
# image. v0.2.12 shipped no daemon in any archive and every from-source build of
# the unpacked release stopped before its first action:
#
#   runquota daemon unreachable and bypass is disabled.
#
# `repro exec` above never asks for a lease, so it cannot see that. This builds
# a fresh project under `tarball` with the archive's bin/ on PATH, as an
# installed prefix puts it, and every other `runquotad` removed from reach.
#
# The project carries a token unique to this run, so no action cache can
# answer its first leased edge (interface extraction) and skip the lease.
# REPRO_NIM_COMPILER and REPRO_BOOTSTRAP_CC name the toolchain this leg already
# has, when the caller has not; without them `tarball` would download the
# pinned Nim and C compiler, which is not what this checks.
build_project="$work/build-project"
mkdir -p "$build_project"
cat > "$build_project/repro.nim" <<EOF
import repro_project_dsl

const smokeRun {.used.} = "$(date +%s)-$$-${RANDOM}"

package releaseRunquotaSmoke:
  build:
    let outDir = fs.ensureDir(path = "out", actionId = "out-dir")
    defaultTarget(outDir)
EOF

exe=""
[[ -f "$pkg/bin/runquotad.exe" ]] && exe=".exe"
[[ -f "$pkg/bin/runquotad$exe" ]] || {
  echo "smoke_release_dev_exec: ERROR: no bin/runquotad$exe in the archive (scripts/release/stage_release_runquota.sh)." >&2
  exit 1
}

if [[ -z "${REPRO_NIM_COMPILER:-}" ]] && nim_exe=$(command -v nim); then
  REPRO_NIM_COMPILER=$(native "$nim_exe")
  export REPRO_NIM_COMPILER
fi
if [[ -z "${REPRO_BOOTSTRAP_CC:-}" ]] && cc_exe=$(command -v cc || command -v gcc); then
  REPRO_BOOTSTRAP_CC=$(native "$cc_exe")
  export REPRO_BOOTSTRAP_CC
fi

isolate_archive_runquota

# POSIX auto-start owns a private socket. Windows retains the real default
# discovery path through the helper; an occupied endpoint refuses qualification.
if [[ -z "$exe" ]]; then
  # Keep the consumer project/archive under its original (possibly deep) work
  # root. Only this fixture-owned rendezvous needs a short, private parent:
  # Nim's Darwin Unix-socket binding allows 91 bytes, including the pathname.
  quota_runtime=$(umask 077; mktemp -d /tmp/repro-release-rq-XXXXXX)
  RUNQUOTA_SOCKET="$quota_runtime/runquota.sock"
  RUNQUOTA_ENDPOINT_SCOPE=private
  export RUNQUOTA_SOCKET RUNQUOTA_ENDPOINT_SCOPE
fi

run_build() { # run_build <log>
  set +e
  (cd "$build_project" && run_packaged_repro build \
    --daemon=off --tool-provisioning=tarball) > "$1" 2>&1 < /dev/null
  local rc=$?
  set -e
  return $rc
}

# The control: with the archive's daemon hidden the same build must be
# refused. If it is not, something other than the archive answered, and the
# run below would prove nothing.
echo "=== repro build --tool-provisioning=tarball, archive runquotad hidden (must be refused) ==="
mv "$pkg/bin/runquotad$exe" "$pkg/bin/runquotad$exe.hidden"
control_rc=0
run_build "$work/build-control.log" || control_rc=$?
mv "$pkg/bin/runquotad$exe.hidden" "$pkg/bin/runquotad$exe"
cat "$work/build-control.log"
missing_daemon=no
if [[ $control_rc -ne 0 ]] &&
    grep -Fq "runquota daemon unreachable and bypass is disabled." "$work/build-control.log" &&
    ! grep -Fq "socket path too long" "$work/build-control.log"; then
  # POSIX must actually report the absent endpoint, not an unrelated failure
  # wrapped in the same high-level unreachable diagnostic. Windows keeps its
  # existing native helper's default-pipe/owned-process control unchanged.
  if [[ "$windows_repro" == yes ]] ||
      grep -Fq "Underlying error: No such file or directory" "$work/build-control.log"; then
    missing_daemon=yes
  fi
fi
if [[ "$missing_daemon" != yes ]]; then
  echo "smoke_release_dev_exec: ERROR: with the archive's runquotad hidden, the build was not refused" >&2
  echo "  for want of a daemon at a valid endpoint (exit $control_rc), so the build below could not show that the" >&2
  echo "  archive's runquotad is the one found." >&2
  exit 1
fi

echo "=== repro build --tool-provisioning=tarball in a fresh project, runquotad from $pkg/bin ==="
build_rc=0
run_build "$work/build.log" || build_rc=$?
cat "$work/build.log"
if [[ $build_rc -ne 0 ]]; then
  echo "smoke_release_dev_exec: ERROR: the packaged repro could not build a project under --tool-provisioning=tarball (exit $build_rc)." >&2
  if grep -q "runquota daemon unreachable" "$work/build.log"; then
    echo "  It found no runquotad to start: the archive's bin/runquotad$exe was not found or" >&2
    echo "  did not start. See scripts/release/stage_release_runquota.sh." >&2
  fi
  exit 1
fi
echo "=== repro build smoke test PASSED (runquotad: the archive copy at $pkg/bin) ==="
