## ``repro lock refresh`` records an edited certificate policy even after a
## command that evaluates the recipe through the build engine has run
## (Test-Certificates.md §"The policy snapshot in repro.lock": a writing door
## records the policy the recipe enacts; the health remedy for a stale
## snapshot is ``repro lock refresh``, so it has to clear it).
##
## The defect this holds closed: ``repro certificates list``, ``repro
## certificates plan`` and ``repro certify`` leave a provider binary in the
## recipe's output directory. After an edit to the policy module, the
## refresh's first probe compiled the edited recipe and published a record
## under the edited sources' recipe-relative key; its policy probe then
## validated that record and ran the binary in the output directory, which
## was compiled before the edit. The refresh exited 0 with the old rule, and
## the pre-commit gate went on enforcing the old ``commit_gate``.
##
## For each of the three commands:
##   1. the refresh records ``commitGate advisory``;
##   2. the command runs;
##   3. the policy module is edited to ``commitGate required``;
##   4. the refresh records the edit (no ``commit_gate = "advisory"`` is left:
##      ``required`` is the default the snapshot leaves out), and a second
##      refresh writes the same bytes.
## After ``repro certify``, an uncovered commit is then REFUSED by the real
## pre-commit gate under the edited policy (it went through under advisory).
##
## Falsifiability: make the durable provider reuse in
## ``tryLoadDurableSolverProviderArtifacts`` accept a validated
## recipe-relative hit without binding it to the durable binary → every case
## keeps ``commit_gate = "advisory"`` and the commit goes through.
##
## NO MOCKS: a real manifest workspace and repository, the built ``repro``,
## the real provider compile and engine, the real managed hooks and a real
## ``git commit``. ``cert-tool`` is a shell script standing in for a test
## command, because the case needs a test that runs, not a particular tool.
## Skip rule: ``git`` or ``ssh-keygen`` missing.

import std/unittest

import repro_test_support/reasoned_skip

include certificate_push_fixture

const certToolInterface = "import repro_project_dsl\n\n" &
  "defineCliInterface certTool, \"cert-tool\":\n" &
  "  call:\n" &
  "    flag input is string, alias = \"--input\", role = input, required = true\n" &
  "    flag output is string, alias = \"--output\", role = output, required = true\n" &
  "    outputs output\n"

const certToolScript = """#!/bin/sh
set -eu
if [ "${1:-}" = "--version" ]; then echo 'cert-tool 1.0.0'; exit 0; fi
input= output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 64 ;;
  esac
done
mkdir -p "$(dirname "$output")"
cp "$input" "$output"
"""

proc policyModule(commitGate: string): string =
  "import repro_certificates\n\n" &
    "const teamPolicy* = certificatePolicy \"team\":\n" &
    "  rule \"**\":\n" &
    "    gateMode required\n" &
    "    commitGate " & commitGate & "\n" &
    "    requires \"t-unit\"\n"

const recipe = "import repro_project_dsl\n" &
  "import \"policy/team_policy\"\n\n" &
  "package lib_a:\n" &
  "  usesImportPath \"reprobuild/packages\"\n" &
  "  enactCertificatePolicy teamPolicy\n" &
  "  uses:\n" &
  "    \"cert-tool >=1.0 <2.0\"\n\n" &
  "  build:\n" &
  "    let unit = certTool(actionId = \"unit\",\n" &
  "      input = \"src/unit.txt\",\n" &
  "      output = \"build/unit-out\")\n" &
  "    certificate \"t-unit\", aggregate(\"t-unit\", @[unit])\n"

const advisoryLine = "commit_gate = \"advisory\""

type Fixture = object
  sf: StoreFixture
  binDir: string

proc app(fx: Fixture): string = fx.sf.libAPath

proc git(fx: Fixture; args: varargs[string]): tuple[code: int; output: string] =
  result = runArgv(@["git", "-C", fx.app] & @args,
    env = @[(name: "PATH", value: fx.binDir & $PathSep & pathWithoutTool()),
            (name: "REPROBUILD_REPRO", value: fx.sf.reproBin)])
  checkpoint("git " & @args.join(" ") & ":\n" & result.output)

proc mustGit(fx: Fixture; args: varargs[string]): string =
  let res = fx.git(args)
  doAssert res.code == 0, "git " & @args.join(" ") & ":\n" & res.output
  res.output.strip()

proc repro(fx: Fixture; args: seq[string]): tuple[code: int; output: string] =
  result = runArgv(@[fx.sf.reproBin] & args, fx.app,
    daemonKeyEnv(fx.sf.daemonKey, storeKeyId) &
    @[(name: "PATH", value: fx.binDir & $PathSep & pathWithoutTool()),
      (name: "REPROBUILD_REPRO", value: fx.sf.reproBin)])
  checkpoint("repro " & args.join(" ") & ":\n" & result.output)

proc refresh(fx: Fixture): string =
  ## ``repro lock refresh``, which must succeed; returns the lock it wrote.
  let res = fx.repro(@["lock", "refresh"])
  doAssert res.code == 0, res.output
  readFile(fx.app / "repro.lock")

proc setup(slug: string): Fixture =
  ## lib-a enacting a local policy whose rule says ``commitGate advisory``,
  ## refreshed, committed and pushed, with the managed hooks installed.
  result.sf = setupStoreFixture("", slug, recordStore = false)
  result.binDir = result.sf.scratch / "bin"
  createDir(result.binDir)
  writeFile(result.binDir / "cert-tool", certToolScript)
  setFilePermissions(result.binDir / "cert-tool",
    {fpUserRead, fpUserWrite, fpUserExec})
  let app = result.sf.libAPath
  createDir(app / "src")
  createDir(app / "policy")
  createDir(app / "reprobuild" / "packages")
  writeFile(app / "src" / "unit.txt", "unit v1\n")
  writeFile(app / "policy" / "team_policy.nim", policyModule("advisory"))
  writeFile(app / "reprobuild" / "packages" / "cert_tool.nim", certToolInterface)
  writeFile(app / "repro.nim", recipe)
  writeFile(app / ".gitignore", ".repro/\nbuild/\ntest-logs/\n")
  doAssert advisoryLine in result.refresh()
  discard result.mustGit("add", "-A")
  discard result.mustGit("commit", "-q", "-m", "project")
  discard result.mustGit("push", "-q", "origin", "main")
  installHooks(result.sf)

proc editedPolicyIsRecorded(fx: Fixture) =
  ## Steps 3 and 4: edit the rule, refresh twice.
  writeFile(fx.app / "policy" / "team_policy.nim", policyModule("required"))
  let first = fx.refresh()
  check advisoryLine notin first
  check "gate_mode = \"required\"" in first
  check "[certificate_policy]" in first
  check fx.refresh() == first

template guarded(body: untyped) =
  if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
    skip("git and ssh-keygen are needed")
  else:
    body

suite "repro lock refresh records the edited policy after the recipe was evaluated":
  test "after repro certificates list":
    guarded:
      let fx = setup("refresh-after-list")
      defer: removeDir(fx.sf.scratch)
      let listed = fx.repro(@["certificates", "list",
        "--tool-provisioning=path"])
      check listed.code == 0
      check "t-unit" in listed.output
      fx.editedPolicyIsRecorded()

  test "after repro certificates plan":
    guarded:
      let fx = setup("refresh-after-plan")
      defer: removeDir(fx.sf.scratch)
      let planned = fx.repro(@["certificates", "plan", "--json", "t-unit",
        "--tool-provisioning=path"])
      check planned.code == 0
      check "t-unit" in planned.output
      fx.editedPolicyIsRecorded()

  test "after repro certify, and the pre-commit gate enforces the edit":
    guarded:
      let fx = setup("refresh-after-certify")
      defer: removeDir(fx.sf.scratch)
      let certified = fx.repro(@["certify", "t-unit",
        "--tool-provisioning=path"])
      check certified.code == 0
      fx.editedPolicyIsRecorded()

      # The edited policy, the refreshed lock and new content: nothing covers
      # this tree, and the rule now says `commit_gate = required`.
      writeFile(fx.app / "src" / "unit.txt", "unit v2\n")
      discard fx.mustGit("add", "-A")
      let before = fx.mustGit("rev-parse", "HEAD")
      let refused = fx.git("commit", "-q", "-m", "uncovered under required")
      check refused.code != 0
      check "REFUSED (commit_gate = required)" in refused.output
      check fx.mustGit("rev-parse", "HEAD") == before
