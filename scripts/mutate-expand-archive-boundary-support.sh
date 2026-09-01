#!/usr/bin/env bash
#
# Mutation arm for the M3f Windows execution-boundary support module.
#
# WHY THIS EXISTS
#
# The gate this module serves runs only on `eph-win-x64`, where a job waits 45
# minutes to three hours for a runner. Iterating a Windows-only assertion
# against CI is therefore not a debugging loop, it is a day. So the two
# contracts the gate actually got wrong were factored into
# `tests/windows/expand_archive_boundary_support.nim`, which is pure string
# work and runs on any host -- and this script is the proof that the
# assertions written for them have teeth.
#
# A green test suite says the implementation passes the tests. It does not say
# the tests would notice if the implementation were wrong. This script answers
# the second question: it applies single-edit mutations to the module, one at a
# time, and requires each one to redden THE SPECIFIC CASE written for it.
# A mutation that reddens some other case is reported as a MISS, not a kill:
# collateral damage is not coverage.
#
# DECLARED SURVIVORS
#
# Two mutations are known to be equivalent -- they change the source without
# changing behaviour. They are listed at the bottom with their reasoning, and
# the corresponding source lines carry a comment saying so. They are recorded
# rather than deleted because a survivor whose reason is written down is
# evidence; a survivor that was quietly removed from the list is not.
#
# USAGE
#
#   scripts/mutate-expand-archive-boundary-support.sh
#
# Exit codes:
#   0 -- the control arm is green and every mutation was killed by its case.
#   1 -- the control arm is red, or a mutation survived / missed its case.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

module="tests/windows/expand_archive_boundary_support.nim"
test_source="tests/windows/t_expand_archive_boundary_support.nim"
work="${TMPDIR:-/tmp}/reprobuild-mutate-expand-archive-$$"
backup="${work}/module.orig.nim"
binary="${work}/t_expand_archive_boundary_support"
nimcache="${work}/nimcache"

mkdir -p "${work}"
cp "${module}" "${backup}"

restore() {
  cp "${backup}" "${module}"
}
trap 'restore; rm -rf "${work}"' EXIT

# Apply an exact, unique string replacement. Deliberately fatal when the anchor
# is absent or ambiguous: a mutation that silently failed to apply reports
# "survived" and would be read as a gap in the tests rather than a gap in this
# script.
apply() {
  python3 - "$1" "$2" <<'PY'
import sys, pathlib
path = pathlib.Path("tests/windows/expand_archive_boundary_support.nim")
old, new = sys.argv[1], sys.argv[2]
text = path.read_text()
count = text.count(old)
if count != 1:
    sys.stderr.write(f"anchor matched {count} times, expected exactly 1:\n{old}\n")
    sys.exit(2)
path.write_text(text.replace(old, new))
PY
}

run_suite() {
  # Returns the suite output on stdout; non-zero exit means red (compile error
  # or failing case), which for a mutation arm is the desired outcome.
  nim c -r --hints:off --warnings:off \
    --nimcache:"${nimcache}" --out:"${binary}" "${test_source}" 2>&1
}

failures=0
killed=0

echo "== control arm =="
control_output="$(run_suite)"
control_rc=$?
if [ "${control_rc}" -ne 0 ]; then
  echo "${control_output}"
  echo "FAIL: the control arm is red. Fix that before reading any mutation." >&2
  exit 1
fi
echo "${control_output}" | grep -c '\[OK\]' | sed 's/^/  cases green: /'
echo "  control arm rc=0"

# mutate <id> <expected-red-case> <anchor> <replacement>
mutate() {
  local id="$1" expected="$2" anchor="$3" replacement="$4"
  restore
  if ! apply "${anchor}" "${replacement}"; then
    echo "  ${id}: ERROR — mutation did not apply" >&2
    failures=$((failures + 1))
    return
  fi
  local output rc
  output="$(run_suite)"
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "  ${id}: SURVIVED — suite still green (expected '${expected}' to redden)"
    failures=$((failures + 1))
    return
  fi
  if echo "${output}" | grep -qF "[FAILED] ${expected}"; then
    echo "  ${id}: killed by '${expected}'"
    killed=$((killed + 1))
  else
    echo "  ${id}: MISS — suite went red, but not via '${expected}'"
    echo "${output}" | grep -F '[FAILED]' | sed 's/^/      /'
    failures=$((failures + 1))
  fi
}

echo
echo "== mutation arm =="

mutate "M01 taggedValue matches anywhere in the line" \
  "a marker must begin its line" \
  'if line.startsWith(tag):' \
  'if line.contains(tag):'

mutate "M02 taggedValue takes the first match, not the last" \
  "the last marker line wins" \
  '      result.found = true
      result.value = line[tag.len .. ^1]' \
  '      result.found = true
      result.value = line[tag.len .. ^1]
      return'

mutate "M03 taggedValue does not strip the line" \
  "CRLF and leading whitespace do not hide a marker" \
  '    let line = rawLine.strip()' \
  '    let line = rawLine'

mutate "M04 an unparseable child exit counts as reported" \
  "a non-numeric child exit is not a report" \
  '      result.childExitReported = false' \
  '      result.childExitReported = true'

mutate "M05 a scratch report is never propagated" \
  "a complete observer transcript reports both markers" \
  '  result.scratchReported = scratch.found' \
  '  result.scratchReported = false'

mutate "M06 the child exit code loses its sign" \
  "a negative child exit is preserved" \
  '      result.childExit = parseInt(childExit.value)' \
  '      result.childExit = abs(parseInt(childExit.value))'

mutate "M07 the fixture interpreter falls back to PATH resolution" \
  "the fixture interpreter is named absolutely, not left to PATH" \
  '  winJoin(windowsPowerShellRoot(systemRoot), "powershell.exe")' \
  '  "powershell.exe"'

mutate "M08 the Desktop system module directory is dropped" \
  "the module path is Desktop edition's own three directories, in order" \
  '  parts.add(winJoin(windowsPowerShellRoot(systemRoot), "Modules"))' \
  '  discard windowsPowerShellRoot(systemRoot)'

mutate "M09 the module path uses the POSIX separator" \
  "the module path is Desktop edition's own three directories, in order" \
  '  parts.join(";")' \
  '  parts.join(":")'

mutate "M10 no inherited entry is ever reported as foreign" \
  "foreign entries name the PowerShell 7 directories of an inherited path" \
  '    if not owned:' \
  '    if false:'

mutate "M11 the foreign-entry comparison becomes case-sensitive" \
  "a Desktop entry is not foreign whatever its case or separator" \
  '    value.replace("/", "\\").strip().toLowerAscii()' \
  '    value.replace("/", "\\").strip()'

mutate "M12 the foreign-entry comparison stops normalising separators" \
  "a Desktop entry is not foreign whatever its case or separator" \
  '    value.replace("/", "\\").strip().toLowerAscii()' \
  '    value.strip().toLowerAscii()'

mutate "M13 winJoin always inserts a separator" \
  "winJoin composes exactly one backslash between segments" \
  '    if result.len > 0 and result[^1] != '"'"'\\'"'"':' \
  '    if result.len > 0:'

mutate "M14 winJoin stops skipping empty segments" \
  "winJoin composes exactly one backslash between segments" \
  '    if part.len == 0:
      continue' \
  '    if false:
      continue'

restore

echo
echo "== declared survivors =="
# Recorded, not deleted. Each is a real edit to the source that provably cannot
# change behaviour, so no assertion can distinguish it. The corresponding
# source lines carry a matching comment.
echo "  S01 foreignModulePathEntries: deleting the 'break' after 'owned = true'."
echo "      The loop only sets a flag and never reads it again inside the loop,"
echo "      so the break is a performance edit. Equivalent by construction."
echo "  S02 parseObserverReport: replacing 'result.childExitReported = false'"
echo "      in the ValueError branch with 'discard'. The field is already false"
echo "      from object zero-initialisation; the write is documentation. The"
echo "      NON-equivalent mutation of the same line (write 'true') is M04,"
echo "      which is killed -- so the line is covered, only this edit is inert."

echo
echo "== summary =="
echo "  mutations applied: 14"
echo "  killed by their named case: ${killed}"
echo "  declared survivors (equivalent, not run): 2"
if [ "${failures}" -ne 0 ]; then
  echo "  unexpected results: ${failures}" >&2
  exit 1
fi
echo "  unexpected results: 0"
