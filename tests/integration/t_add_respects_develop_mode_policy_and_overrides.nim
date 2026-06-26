## RA-22 — `repro add <repo>` develop-mode policy + per-add overrides +
## init/clone-without-add.
##
## Black-box: drives the compiled ``repro`` binary against a hermetic
## single-project workspace via ``execCmdEx`` (non-TTY by nature). Local bare
## git origins stand in for the company-org and third-party remotes.
##
## The policy default is DATA: a host bootstrap config
## (``.repro-workspace.toml``) carries ``[develop] org_urls`` listing the
## fetch-URL prefix whose repos default to DEVELOP mode. A repo whose remote
## begins with that prefix defaults to develop (a local sibling checkout +
## a ``depends`` edge); every other repo defaults to BINARY (no checkout).
## ``--develop`` / ``--binary`` override the default per-add. ``--no-membership``
## clones a repo WITHOUT recording it as a dependency.
##
## Sub-cases (each its own ``test_ra22_*`` block):
##   1. develop-org repo, no flag       → develop (checkout + depends edge).
##   2. third-party repo, no flag       → binary (NO checkout; binary_dependency).
##   3. develop-org repo, ``--binary``  → binary (override; NO checkout).
##   4. third-party repo, ``--develop`` → develop (override; checkout present).
##   5. ``--no-membership``             → clones but NO depends edge / membership.
##
## Skip rule: ``git`` missing on PATH (same convention as the RA suites).

import std/[json, os, osproc, strutils, tempfiles, unittest]

import repro_test_support

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

proc seedGitOrigin(gitBin, originPath, workPath: string; branch = "main") =
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"RA22 Tester\"")
  writeFile(workPath / "README.md", "RA22 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin " & branch)

# A develop-mode "root" repo already present in the workspace, so a
# ``--depends-of`` edge has somewhere to land.
const rootFragmentToml = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "app"
path = "app"
remote = "app-origin"
revision = "main"
"""

proc projectToml(appUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"demo\"\n" &
  "default_revision = \"main\"\n" &
  "trunk = \"main\"\n\n" &
  "[[remote]]\nname = \"app-origin\"\nfetch = \"" & appUrl & "\"\n\n" &
  "includes = [\n" &
  "  \"repos/app.toml\",\n" &
  "]\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    projectFile: string
    appFragment: string
    orgPrefix: string         ## the develop-by-default URL prefix.
    orgRepoUrl: string        ## a repo UNDER the org prefix.
    thirdPartyUrl: string     ## a repo NOT under the org prefix.

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-ra22-add-" & slug & "-", "")
  result.reproBin = reproBinary()

  # Two distinct origin directory roots so the URL PREFIX cleanly separates
  # the "company org" from "third party". The org prefix is the file:// URL
  # of the org directory; the third-party origin lives elsewhere.
  let orgDir = result.scratch / "org"
  let tpDir = result.scratch / "thirdparty"
  createDir(orgDir)
  createDir(tpDir)

  let appOrigin = orgDir / "app.git"
  let orgRepoOrigin = orgDir / "orglib.git"
  let tpOrigin = tpDir / "tplib.git"
  seedGitOrigin(gitBin, appOrigin, result.scratch / "seed-app")
  seedGitOrigin(gitBin, orgRepoOrigin, result.scratch / "seed-orglib")
  seedGitOrigin(gitBin, tpOrigin, result.scratch / "seed-tplib")

  result.orgPrefix = fileUrl(orgDir) & "/"
  result.orgRepoUrl = fileUrl(orgRepoOrigin)
  result.thirdPartyUrl = fileUrl(tpOrigin)

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  let manifestsRoot = workspaceRoot / ".repo" / "manifests"
  createDir(manifestsRoot / "projects")
  createDir(manifestsRoot / "repos")
  result.projectFile = manifestsRoot / "projects" / "demo.toml"
  writeFile(result.projectFile, projectToml(fileUrl(appOrigin)))
  result.appFragment = manifestsRoot / "repos" / "app.toml"
  writeFile(result.appFragment, rootFragmentToml)

  # Clone the root repo into the workspace so it is a present sibling.
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(appOrigin)) & " " &
    q(workspaceRoot / "app"))

  # The host bootstrap config carrying the develop-by-default policy: any
  # repo under the org prefix defaults to develop mode.
  writeFile(workspaceRoot / ".repro-workspace.toml",
    "schema = \"reprobuild.workspace.bootstrap.v1\"\n\n" &
    "[manifest]\nurl = \"" & fileUrl(appOrigin) & "\"\n\n" &
    "[develop]\norg_urls = [\"" & result.orgPrefix & "\"]\n")

  # Metadata-only workspace.toml so the project resolves without `init`.
  writeFile(workspaceRoot / ".repo" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"demo\"\nbranch = \"main\"\n")
  result.workspaceRoot = workspaceRoot

proc invokeAdd(fx: Fixture; extra: seq[string]): tuple[code: int; output: string] =
  var parts = @[q(fx.reproBin), "add"]
  for e in extra: parts.add(q(e))
  parts.add("--workspace-root=" & q(fx.workspaceRoot))
  parts.add("--json")
  # The bootstrap config lives at the workspace root; point the resolver at it.
  runCmd(parts.join(" "))

proc parseReport(output: string): JsonNode =
  let braceIdx = output.find('{')
  doAssert braceIdx >= 0, "no JSON object in output:\n" & output
  parseJson(output[braceIdx .. ^1])

proc appDependsContains(fx: Fixture; dep: string): bool =
  readFile(fx.appFragment).contains("\"" & dep & "\"")

suite "RA-22 — repro add develop-mode policy and overrides":

  test "test_ra22_develop_org_repo_defaults_to_develop_checkout_and_edge":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "org-develop")
      defer: removeDir(fx.scratch)

      let res = invokeAdd(fx,
        @["orglib", "--remote=" & fx.orgRepoUrl, "--depends-of=app"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      let rep = parseReport(res.output)
      # Policy default for an org-prefix repo is develop.
      check rep["policyDefault"].getStr() == "develop"
      check rep["resolvedMode"].getStr() == "develop"
      check rep["overridden"].getBool() == false
      check rep["checkedOut"].getBool() == true
      # On-disk: the sibling checkout exists and the include landed.
      check dirExists(fx.workspaceRoot / "orglib")
      check readFile(fx.projectFile).contains("repos/orglib.toml")
      # The depends edge was recorded on the root repo.
      check rep["dependsEdgeOn"].getStr() == "app"
      check appDependsContains(fx, "orglib")

  test "test_ra22_third_party_repo_defaults_to_binary_no_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "tp-binary")
      defer: removeDir(fx.scratch)

      let res = invokeAdd(fx, @["tplib", "--remote=" & fx.thirdPartyUrl])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      let rep = parseReport(res.output)
      # Policy default for a non-org repo is binary.
      check rep["policyDefault"].getStr() == "binary"
      check rep["resolvedMode"].getStr() == "binary"
      check rep["checkedOut"].getBool() == false
      # On-disk: NO checkout; recorded as a binary_dependency, NOT an include.
      check not dirExists(fx.workspaceRoot / "tplib")
      check readFile(fx.projectFile).contains("[[binary_dependency]]")
      check not readFile(fx.projectFile).contains("repos/tplib.toml")

  test "test_ra22_binary_override_on_develop_org_repo_no_checkout":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "org-binary-override")
      defer: removeDir(fx.scratch)

      let res = invokeAdd(fx,
        @["orglib", "--remote=" & fx.orgRepoUrl, "--binary"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      let rep = parseReport(res.output)
      # Policy default WAS develop; --binary overrode it.
      check rep["policyDefault"].getStr() == "develop"
      check rep["resolvedMode"].getStr() == "binary"
      check rep["overridden"].getBool() == true
      check rep["checkedOut"].getBool() == false
      check not dirExists(fx.workspaceRoot / "orglib")
      check not readFile(fx.projectFile).contains("repos/orglib.toml")

  test "test_ra22_develop_override_on_third_party_repo_checks_out":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "tp-develop-override")
      defer: removeDir(fx.scratch)

      let res = invokeAdd(fx,
        @["tplib", "--remote=" & fx.thirdPartyUrl, "--develop"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      let rep = parseReport(res.output)
      # Policy default WAS binary; --develop overrode it.
      check rep["policyDefault"].getStr() == "binary"
      check rep["resolvedMode"].getStr() == "develop"
      check rep["overridden"].getBool() == true
      check rep["checkedOut"].getBool() == true
      check dirExists(fx.workspaceRoot / "tplib")
      check readFile(fx.projectFile).contains("repos/tplib.toml")

  test "test_ra22_no_membership_clones_without_adding_dependency":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-membership")
      defer: removeDir(fx.scratch)

      let res = invokeAdd(fx,
        @["orglib", "--remote=" & fx.orgRepoUrl, "--no-membership"])
      if res.code != 0:
        checkpoint("output: " & res.output)
      check res.code == 0
      let rep = parseReport(res.output)
      check rep["resolvedMode"].getStr() == "no-membership"
      check rep["checkedOut"].getBool() == true
      check rep["declarationChanged"].getBool() == false
      # Cloned on disk, but NOT a membership/dependency: no include, no
      # binary_dependency, no depends edge.
      check dirExists(fx.workspaceRoot / "orglib")
      check not readFile(fx.projectFile).contains("repos/orglib.toml")
      check not appDependsContains(fx, "orglib")
