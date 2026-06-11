#!/usr/bin/env bash
# Repro multi-distro test runner.
#
# Usage:
#   scripts/run_multi_distro_tests.sh <test-name> [distro [distro ...]]
#   scripts/run_multi_distro_tests.sh <test-name> --all
#
# <test-name> resolves to:
#   tools/multi-distro-harness/tests/<test-name>.sh
#
# Distros are one or more of: arch debian ubuntu fedora opensuse alpine.
# The script invokes the test inside each WSL instance (repro-<distro>) and
# reports per-distro pass/fail plus a final aggregate line. Exit code is 0
# when every requested distro passes, 1 otherwise.
#
# See tools/multi-distro-harness/README.md and
# D:/metacraft/reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org M0.

set -eu

ALL_DISTROS='arch debian ubuntu fedora opensuse alpine'

if [ $# -lt 1 ]; then
  cat >&2 <<USAGE
usage: $0 <test-name> [distro1 distro2 ...]
       $0 <test-name> --all
known distros: $ALL_DISTROS
USAGE
  exit 2
fi

test_name=$1
shift

if [ $# -eq 0 ]; then
  cat >&2 <<USAGE
usage: $0 <test-name> [distro1 distro2 ...]
       $0 <test-name> --all
(no distros specified)
USAGE
  exit 2
fi

if [ "$1" = '--all' ]; then
  distros=$ALL_DISTROS
else
  distros=$*
fi

# Resolve repo root - script lives in $repo/scripts/.
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
test_script_host="$repo_root/tools/multi-distro-harness/tests/$test_name.sh"

if [ ! -f "$test_script_host" ]; then
  echo "ERR: test script not found: $test_script_host" >&2
  echo "available tests:" >&2
  ls "$repo_root/tools/multi-distro-harness/tests/" 2>&1 >&2 || true
  exit 2
fi

# wslpath is provided by every WSL distro and is the canonical Windows<->WSL
# path translator. Use the host's wsl.exe to call wslpath inside a distro we
# can rely on. The bash running this script may be git-bash (which has its
# own wslpath shim) or a WSL bash; either way the path translation needs to
# yield a valid WSL-side path that ALL repro-* distros can read via /mnt/.
case "$(uname -s)" in
  Linux*)
    # Running from inside WSL itself. Host paths under /mnt/<drive>/ already.
    test_script_wsl=$test_script_host
    ;;
  *)
    # Running from git-bash on Windows. Use wsl.exe wslpath via a reliable
    # distro; eli-wsl is the user's default and is always present per the
    # campaign baseline, but we MUST NOT touch it. Use the first available
    # repro-* instance instead. Fall back to a temporary path translation.
    test_script_wsl=$(cygpath -w "$test_script_host" 2>/dev/null | \
      sed -E 's|^([A-Za-z]):|/mnt/\L\1|' | tr '\\' '/')
    if [ -z "$test_script_wsl" ]; then
      echo "ERR: could not translate host path to WSL path: $test_script_host" >&2
      exit 2
    fi
    ;;
esac

passed=0
failed=0
total=0
fail_list=''

for distro in $distros; do
  total=$((total + 1))
  instance="repro-$distro"
  # Safety: refuse anything that doesn't start with "repro-".
  case "$instance" in
    repro-*) : ;;
    *)
      echo "ERR: refusing to operate on non-repro instance '$instance'" >&2
      failed=$((failed + 1))
      fail_list="$fail_list $distro"
      continue
      ;;
  esac

  # Check the WSL instance exists.
  if ! wsl.exe --list --quiet 2>/dev/null | tr -d '\0\r' | grep -Fxq "$instance" 2>/dev/null; then
    echo "[FAIL] $distro: WSL instance '$instance' missing"
    echo "       provision with: pwsh tools/multi-distro-harness/provision-$distro.ps1"
    failed=$((failed + 1))
    fail_list="$fail_list $distro"
    continue
  fi

  echo ''
  echo "==== $distro ($instance) : $test_name ===="
  # Capture both stdout and stderr; keep last 20 lines on failure.
  log=$(mktemp)
  set +e
  # MSYS_NO_PATHCONV=1 + MSYS2_ARG_CONV_EXCL='*' prevent git-bash on Windows
  # from POSIX-translating /bin/sh and the test path; without these,
  # /bin/sh is rewritten to the host's C:/Users/.../scoop/.../sh.exe and
  # execvpe inside WSL fails ("No such file or directory").
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    wsl.exe -d "$instance" -u root --exec /bin/sh "$test_script_wsl" >"$log" 2>&1
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    tail -n 5 "$log" || true
    echo "[PASS] $distro: $test_name (rc=0)"
    passed=$((passed + 1))
  else
    echo "[FAIL] $distro: $test_name (rc=$rc) - last 20 lines:"
    tail -n 20 "$log" || true
    failed=$((failed + 1))
    fail_list="$fail_list $distro"
  fi
  rm -f "$log"
done

echo ''
echo "repro multi-distro: $passed/$total distros passed"
if [ "$failed" -gt 0 ]; then
  echo "  failed:$fail_list"
  exit 1
fi
exit 0
