## TC-4 — CI fast-track: CI SKIPS target sets covered by a VALID certificate
## for a platform, and RUNS everything else.
##
## ``repro ci plan --platform=P --json`` resolves the project's certificate
## policy (required targets/platforms + ci_trust) and the CONTENT the certs
## must name (TC-8c: the checked-out tracked files), reads the certs noted on
## that content's tree (the TC-2 git-notes carrier) and those in the local
## certificate store, and emits the per-platform SKIP/RUN plan
## (``reprobuild.ci-plan.v2``) a CI job consumes. The decision REUSES the push
## gate's evaluator, so the CI trust boundary is identical to the push gate's:
## only a registered-signed, unrevoked, content+lock+platform-matching cert can
## move a target into SKIP, and only when the project explicitly set
## ``ci_trust = "skip"``.
##
## Assertions (each falsifiable — see the inline FALSIFY notes):
##   1. Platform A with a VALID signed cert covering target ``t-unit`` attached
##      to HEAD: ``ci plan --platform=A`` puts ``t-unit`` in SKIP (fast-track).
##   2. Platform B with NO valid cert: ``ci plan --platform=B`` puts the required
##      targets in RUN (run normally) — no skip.
##   3. Partial coverage: cert covers ``t-unit`` but required is {t-unit, t-int}
##      → ``t-unit`` SKIP, ``t-int`` RUN.
##   4. SECURITY: a FORGED cert (real signature by an UNREGISTERED key) does NOT
##      cause a skip — the target stays in RUN. (A forged cert letting CI skip
##      would be a security hole.) Same for a WRONG-PLATFORM cert (covered by
##      assertion 2's no-cert-for-B path) and a TAMPERED cert.
##   5. ``ci_trust=advisory`` → NOTHING is skipped even when covered (run
##      everything); the valid cert is surfaced as an advisory note.
##
## Falsifiability (recorded, then reverted):
##   - make the plan skip without checking the signature (count every attached
##     cert) → assertion 4 (forged cert) wrongly skips → fails.
##   - ignore the platform binding (skip on any covered target) → assertion 2
##     (wrong platform) wrongly skips → fails.
##   - ignore ci_trust (always skip when covered) → assertion 5 (advisory)
##     wrongly skips → fails.
##
## Hermetic: only local ``git init`` / ``git init --bare`` repos; ed25519 keys
## generated in-test with ssh-keygen. Skip rule: ``git`` or ``ssh-keygen``
## missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support
import repro_cli_support
import repro_workspace_manifests
import repro_lock
import repro_lock/certificate_policy

include tc5_cert_signing_helpers

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"TC4 Tester\"")
  writeFile(workPath / "README.md", "TC-4 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " &
    q(fileUrl(originPath)) & " " & q(targetPath))
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(targetPath) &
    " config user.name \"TC4 Tester\"")

proc projectToml(libAUrl, certificatesTable: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"lib-a\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  certificatesTable &
  "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n]\n"

const libAFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-a"
path = "lib-a"
remote = "lib-a-origin"
revision = "main"
"""

# Platform A is the HOST tag (so a real issued cert matches it); platform B is a
# DIFFERENT platform string that the host never issues a cert for.
let platformA = currentPlatformTag()
const platformB = "freebsd/riscv64"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libAOrigin: string
    libAPath: string
    libASha: string

proc writeProjectManifest(fx: Fixture; certificatesTable: string) =
  let manifestsRoot = fx.workspaceRoot
  writeFile(manifestsRoot / "projects" / "lib-a.toml",
    projectToml(fileUrl(fx.libAOrigin), certificatesTable))

proc policyTable(targets: seq[string]; ciTrust: string): string =
  ## ``[certificates]`` table: gate_mode advisory (CI plan does not depend on
  ## the gate mode), required targets, both platforms A and B required, and the
  ## explicit ci_trust under test.
  var t = "[certificates]\n"
  t.add("gate_mode = \"advisory\"\n")
  t.add("required_targets = [")
  for i, x in targets:
    if i > 0: t.add(", ")
    t.add("\"" & x & "\"")
  t.add("]\n")
  t.add("required_platforms = [\"" & platformA & "\", \"" & platformB & "\"]\n")
  t.add("ci_trust = \"" & ciTrust & "\"\n\n")
  t

proc setupFixture(gitBin: string): Fixture =
  result.scratch = createTempDir("repro-tc4-ci-", "")
  discard isolateCertificateStore(result.scratch)
  result.reproBin = reproBinary()
  result.libAOrigin = result.scratch / "origin-lib-a.git"
  result.libASha = seedGitOrigin(gitBin, result.libAOrigin,
    result.scratch / "seed-lib-a")
  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  writeFile(manifestsRoot / "repos" / "lib-a.toml", libAFragmentToml)
  result.workspaceRoot = workspaceRoot
  seedManifestLockStore(gitBin, workspaceRoot)
  result.libAPath = workspaceRoot / "lib-a"
  cloneInto(gitBin, result.libAOrigin, result.libAPath)
  writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")

proc seedLock(fx: Fixture) =
  let res = runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot]))
  if res.code != 0: checkpoint("workspace lock failed: " & res.output)
  check res.code == 0

proc writeTestFixtureJson(path: string; selectors: seq[string]) =
  var obj = newJObject()
  obj["fallbackBuildCostNs"] = %1
  obj["fallbackTestCostNs"] = %1
  var edges = newJArray()
  for i, selector in selectors:
    var e = newJObject()
    e["id"] = %(i + 1)
    e["selector"] = %selector
    e["historyKey"] = %selector
    e["buildDeps"] = newJArray()
    var cmd = newJArray()
    cmd.add(%"sh"); cmd.add(%"-c"); cmd.add(%"exit 0")
    e["runCmd"] = cmd
    e["testName"] = %selector
    edges.add(e)
  obj["testEdges"] = edges
  obj["buildActions"] = newJArray()
  let parent = parentDir(path)
  if parent.len > 0 and not dirExists(parent): createDir(parent)
  writeFile(path, obj.pretty() & "\n")

proc issueRealCert(fx: Fixture; daemonKey, keyId: string;
                   targets: seq[string]): TestCertificate =
  ## Drive the TC-1/TC-5 issuance path: a REAL passing run in a clean state,
  ## signed by the daemon key. Returns the issued (signed) cert read from disk.
  let fixtureJson = fx.scratch / ("fixture-" & keyId & ".json")
  writeTestFixtureJson(fixtureJson, targets)
  let certFile = fx.scratch / ("issued-" & keyId & ".toml")
  var selectorArgs: seq[string]
  for t in targets: selectorArgs.add(t)
  let issued = runShell(shellCommand(@[
    fx.reproBin, "test",
    "--fixture-from=" & fixtureJson,
    "--shard=1/1", "--certify",
    "--certificate-out=" & certFile,
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath] & selectorArgs,
    daemonKeyEnv(daemonKey, keyId)), fx.workspaceRoot)
  if issued.code != 0: checkpoint("repro test output: " & issued.output)
  check issued.code == 0
  check fileExists(certFile)
  result = readCertificateFile(certFile)

proc planJson(fx: Fixture; platform: string): JsonNode =
  let res = runShell(shellCommand(@[
    fx.reproBin, "ci", "plan",
    "--platform=" & platform,
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & fx.libAPath, "--json"]))
  checkpoint("ci plan (" & platform & ") output:\n" & res.output)
  check res.code == 0
  # The JSON is the LAST object in the output (stderr notes may precede on
  # stdout=… ; runShell merges streams). Find the first '{'.
  let start = res.output.find('{')
  check start >= 0
  parseJson(res.output[start .. ^1])

proc platformBlock(plan: JsonNode; platform: string): JsonNode =
  for p in plan["platforms"]:
    if p["platform"].getStr() == platform:
      return p
  checkpoint("platform not in plan: " & platform)
  check false
  newJObject()

proc targets(node: JsonNode; key: string): seq[string] =
  for x in node[key]: result.add(x.getStr())

suite "TC-4 — CI fast-track: skip targets covered by a valid cert per platform":

  test "t_ci_skips_targets_covered_by_valid_certificate_per_platform":
    let gitBin = findExe("git")
    let sshKeygen = findExe("ssh-keygen")
    if gitBin.len == 0 or sshKeygen.len == 0:
      skip()
    else:
      # ============ ci_trust = "skip" — covered targets fast-track ============
      block skipMode:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        writeProjectManifest(fx, policyTable(@["t-unit", "t-int"], "skip"))
        seedLock(fx)

        # Register key A; issue a VALID signed cert covering ONLY t-unit.
        const keyIdA = "tc4-key-a"
        let keyA = genEd25519Key(fx.scratch / "keys", "key-a", keyIdA)
        writeRegistry(fx.workspaceRoot,
          @[RegisteredKey(keyId: keyIdA, publicKey: keyA.pub,
            status: rksActive)])
        let certA = issueRealCert(fx, keyA.priv, keyIdA, @["t-unit"])
        check certA.isSigned
        check certA.platform == platformA
        let attA = attachCertificate(gitBin, fx.libAPath, certA)
        check attA.ok

        # ---- 1 + 3. Platform A: t-unit SKIP (covered), t-int RUN (uncovered).
        let planA = planJson(fx, platformA)
        let blockA = platformBlock(planA, platformA)
        check targets(blockA, "skip") == @["t-unit"]    # assertion 1 + 3 (skip)
        check targets(blockA, "run") == @["t-int"]       # assertion 3 (run)
        check planA["ci_trust"].getStr() == "skip"

        # ---- 2. Platform B: NO valid cert → required targets all RUN.
        let planB = planJson(fx, platformB)
        let blockB = platformBlock(planB, platformB)
        check targets(blockB, "skip").len == 0           # nothing skipped
        # FALSIFY (ignore platform): if the plan skipped on any covered target
        # regardless of platform, t-unit would wrongly appear here.
        check targets(blockB, "run") == @["t-unit", "t-int"]

      # ============ SECURITY: a FORGED cert must NOT cause a skip ============
      block forgedCert:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        writeProjectManifest(fx, policyTable(@["t-unit"], "skip"))
        seedLock(fx)

        # Issue a cert with a REAL signature by key F — but DO NOT register F.
        # The signature is cryptographically valid yet the key is unknown, so
        # the verifier returns svUnregisteredKey and the cert MUST be ignored.
        const keyIdF = "tc4-forged-key"
        let keyF = genEd25519Key(fx.scratch / "keys", "key-f", keyIdF)
        # Register an UNRELATED key so the store exists but does not trust F.
        const keyIdReal = "tc4-real-key"
        let keyReal = genEd25519Key(fx.scratch / "keys", "key-real", keyIdReal)
        writeRegistry(fx.workspaceRoot,
          @[RegisteredKey(keyId: keyIdReal, publicKey: keyReal.pub,
            status: rksActive)])
        let forged = issueRealCert(fx, keyF.priv, keyIdF, @["t-unit"])
        check forged.isSigned
        let attF = attachCertificate(gitBin, fx.libAPath, forged)
        check attF.ok

        let planF = planJson(fx, platformA)
        let blockF = platformBlock(planF, platformA)
        # FALSIFY (skip without checking the signature): a forged-but-signed
        # cert by an unregistered key would wrongly land t-unit in skip.
        check targets(blockF, "skip").len == 0
        check targets(blockF, "run") == @["t-unit"]

      # ============ ci_trust = "advisory" — never skip, surface signal =======
      block advisoryMode:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        writeProjectManifest(fx, policyTable(@["t-unit"], "advisory"))
        seedLock(fx)

        const keyIdA = "tc4-adv-key"
        let keyA = genEd25519Key(fx.scratch / "keys", "key-adv", keyIdA)
        writeRegistry(fx.workspaceRoot,
          @[RegisteredKey(keyId: keyIdA, publicKey: keyA.pub,
            status: rksActive)])
        let certA = issueRealCert(fx, keyA.priv, keyIdA, @["t-unit"])
        let attA = attachCertificate(gitBin, fx.libAPath, certA)
        check attA.ok

        let planAdv = planJson(fx, platformA)
        check planAdv["ci_trust"].getStr() == "advisory"
        let blockAdv = platformBlock(planAdv, platformA)
        # FALSIFY (ignore ci_trust): always-skip-when-covered would land t-unit
        # in skip even though the project chose advisory.
        check targets(blockAdv, "skip").len == 0
        check targets(blockAdv, "run") == @["t-unit"]
        # The valid cert is surfaced as an advisory signal (not a skip).
        check blockAdv.hasKey("advisory_note")
        check "ci_trust=advisory" in blockAdv["advisory_note"].getStr()

      # ============ TC-9c: the requirement declared as a policy ============
      # The same fast-track, with the requirement declared as a policy
      # snapshot in the committed `repro.lock` of the base (`origin/main`,
      # which the job evaluates against) rather than in the `[certificates]`
      # table. The table is left saying something else (`t-never`,
      # `ci_trust = "advisory"`): where a snapshot exists the table is not
      # consulted, so the plan follows the snapshot.
      block policyDeclared:
        let fx = setupFixture(gitBin)
        defer: removeDir(fx.scratch)
        writeProjectManifest(fx, policyTable(@["t-never"], "advisory"))
        let snapshot = renderCertificatePolicySnapshot(BranchCertificatePolicy(
          name: "ci-fast-track", package: "certpolicy", ciTrust: pctSkip,
          rules: @[PolicyRule(branches: @["main"], gateMode: pmAdvisory,
            commitGate: pmAdvisory, requires: @[PolicyRequirement(
              certificate: "t-unit", platforms: @[platformA, platformB])])]))
        writeFile(fx.libAPath / "repro.lock", replaceCertificatePolicySection(
          serializeLockedDependencies(LockedDependencies(
            schema: "reprobuild.solved-graph-lock.v2", deps: @[])), snapshot))
        discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
          " add repro.lock")
        discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
          " commit -q --no-verify -m policy")
        discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
          " push -q --no-verify origin main")
        # The candidate is a change on top of the base, published on its own
        # branch the way a pull request's head is: the base must not be the
        # candidate itself, or it would be trusting its own snapshot.
        writeFile(fx.libAPath / "change.txt", "the change under review\n")
        discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
          " add change.txt")
        discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
          " commit -q --no-verify -m change")
        discard requireGit(q(gitBin) & " -C " & q(fx.libAPath) &
          " push -q --no-verify origin HEAD:refs/heads/pr")
        seedLock(fx)
        const keyIdP = "tc9c-policy-key"
        let keyP = genEd25519Key(fx.scratch / "keys", "key-policy", keyIdP)
        writeRegistry(fx.workspaceRoot,
          @[RegisteredKey(keyId: keyIdP, publicKey: keyP.pub,
            status: rksActive)])
        let certP = issueRealCert(fx, keyP.priv, keyIdP, @["t-unit"])
        check attachCertificate(gitBin, fx.libAPath, certP).ok

        let planP = planJson(fx, platformA)
        check planP["ci_trust"].getStr() == "skip"
        check planP["policy"]["source"].getStr() == "base"
        check planP["required_targets"].to(seq[string]) == @["t-unit"]
        let blockP = platformBlock(planP, platformA)
        check targets(blockP, "skip") == @["t-unit"]
        check targets(blockP, "run").len == 0
        let planPB = planJson(fx, platformB)
        check targets(platformBlock(planPB, platformB), "run") == @["t-unit"]
