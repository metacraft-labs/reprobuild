## M25 — Private manifest layering integrated end-to-end.
##
## The milestone demo path: a composer-mode workspace lists two
## ``[[manifest]]`` layers (one public, one private). The four scenarios
## the milestone enumerates are:
##
##   (a) ``repro workspace init`` succeeds for the user with access to
##       both layers, materialising every repo declared across the union
##       of layers.
##   (b) The same init fails with a clear diagnostic naming the private
##       layer (visibility + URL) for a user without access.
##   (c) The lock produced by the full-access run round-trips through
##       the M5 strict reader.
##   (d) A public-only user can still init the public subset by
##       passing ``--allow-missing-layers`` (M25 opt-in flag) — the
##       composer drops the unreachable private layer, the public
##       subset materialises, and ``skippedLayers`` in the init report
##       records the dropped layer with its visibility tier.
##
## Fixture: hermetic local bare git repos stand in for the public and
## private manifest URLs (same pattern the M8 layered-workspace tests
## use). "No private access" is simulated by making the private
## bare-origin URL unreachable — for the failure cases the private bare
## is created and then removed so the URL points at a non-existent
## filesystem location. The composer's M2 clone action raises, which
## the M25 diagnostic wrapper restamps with the
## ``manifest-layer-unreachable:`` tag and the visibility tier
## ("private").
##
## Skip rule: skip only when ``git`` is missing from PATH (same
## convention as M2 / M3 / M8 / M9 / M10 / M11).

import std/[json, os, osproc, strutils, tables, tempfiles, unittest]

import repro_test_support

import repro_workspace_manifests

# ---- shared shell helpers -------------------------------------------------

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

# ---- repro binary build ---------------------------------------------------

proc repoRoot(): string =
  result = currentSourcePath().parentDir.parentDir.parentDir

proc compileRepro(tempRoot: string): string =
  result = tempRoot / "bin" / addFileExt("repro", ExeExt)
  createDir(parentDir(result))
  let root = repoRoot()
  let args = @[
    "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
    "--nimcache:" & root / "build" / "nimcache" / "m25-private-layer-e2e",
    "--out:" & result,
    root / "apps" / "repro" / "repro.nim",
  ]
  discard requireSuccess(shellCommand(args), root)

# ---- bare-repo fixtures ---------------------------------------------------

proc seedGitOrigin(gitBin, originPath, workPath: string;
                   branch = "main"): string =
  ## Single-commit bare origin used as a stand-in for a public repo's
  ## fetch URL. Mirrors the M9 / M10 / M11 fixture pattern.
  discard requireGit(q(gitBin) & " init --bare -b " & branch & " " &
    q(originPath))
  discard requireGit(q(gitBin) & " init -b " & branch & " " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M25 Tester\"")
  writeFile(workPath / "README.md", "M25 fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " push origin " & branch)
  result = requireGit(q(gitBin) & " -C " & q(workPath) &
    " rev-parse HEAD").strip()

proc seedManifestBare(gitBin, scratch, barePath: string;
                      files: openArray[(string, string)]) =
  ## Build a one-commit bare git repo that hosts the manifest TOMLs the
  ## composer reads. Mirrors the helper in
  ## ``t_workspace_manifests_private_override_shadows_public``.
  let workPath = scratch / ("seed-" & extractFilename(barePath))
  removeDir(workPath)
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"M25 Tester\"")
  for entry in files:
    let relPath = entry[0]
    let body = entry[1]
    let absPath = workPath / relPath
    createDir(absPath.splitPath.head)
    writeFile(absPath, body)
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add -A")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m fixture")
  removeDir(barePath)
  discard requireGit(q(gitBin) & " clone --bare " & q(workPath) & " " &
    q(barePath))

# ---- manifest TOML strings ------------------------------------------------
#
# The composed workspace declares a project ``myproject`` that, after
# composition, has three repos: ``lib-public-a`` and ``lib-public-b``
# from the public layer, and ``lib-private`` from the private layer.
# This shape lets us assert "public subset still resolves" (the two
# public repos) versus "full union materialises" (all three).

proc publicProjectToml(originPubA, originPubB: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"pub-a-origin\"\nfetch = \"" &
      originPubA & "\"\n\n" &
    "[[remote]]\nname = \"pub-b-origin\"\nfetch = \"" &
      originPubB & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-public-a.toml\",\n" &
    "  \"repos/lib-public-b.toml\",\n" &
    "]\n"

proc privateProjectToml(originPrivate: string): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"myproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"priv-origin\"\nfetch = \"" &
      originPrivate & "\"\n\n" &
    "includes = [\n" &
    "  \"repos/lib-private.toml\",\n" &
    "]\n"

const libPublicAFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-public-a"
path = "lib-public-a"
remote = "pub-a-origin"
revision = "main"
"""

const libPublicBFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-public-b"
path = "lib-public-b"
remote = "pub-b-origin"
revision = "main"
"""

const libPrivateFragment = """
schema = "reprobuild.workspace.repo.v1"

[repo]
name = "lib-private"
path = "lib-private"
remote = "priv-origin"
revision = "main"
"""

# ---- fixture builder ------------------------------------------------------

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    workspaceTomlPath: string
    publicManifestBare: string
    privateManifestBare: string
    privateManifestBareReachable: bool
    libPublicAOrigin: string
    libPublicBOrigin: string
    libPrivateOrigin: string
    libPublicASha: string
    libPublicBSha: string
    libPrivateSha: string

proc writeWorkspaceToml(workspaceRoot: string;
                        publicManifestUrl, privateManifestUrl: string):
                          string =
  let dotRepo = workspaceRoot / ".repo"
  createDir(dotRepo)
  result = dotRepo / "workspace.toml"
  let body =
    "schema = \"reprobuild.workspace.local.v1\"\n\n" &
    "[workspace]\nproject = \"myproject\"\nbranch = \"main\"\n\n" &
    "[[manifest]]\n" &
    "url = \"" & publicManifestUrl & "\"\n" &
    "visibility = \"public\"\nbranch = \"main\"\n\n" &
    "[[manifest]]\n" &
    "url = \"" & privateManifestUrl & "\"\n" &
    "visibility = \"private\"\nbranch = \"main\"\n"
  writeFile(result, body)

proc setupFixture(gitBin, slug: string;
                  privateManifestReachable: bool): Fixture =
  result.scratch = createTempDir("repro-m25-" & slug & "-", "")
  result.reproBin = compileRepro(result.scratch)
  result.privateManifestBareReachable = privateManifestReachable

  # Three bare repos stand in for the project's per-repo fetch URLs.
  result.libPublicAOrigin = result.scratch / "origin-lib-public-a.git"
  result.libPublicBOrigin = result.scratch / "origin-lib-public-b.git"
  result.libPrivateOrigin = result.scratch / "origin-lib-private.git"
  result.libPublicASha = seedGitOrigin(gitBin, result.libPublicAOrigin,
    result.scratch / "seed-lib-public-a")
  result.libPublicBSha = seedGitOrigin(gitBin, result.libPublicBOrigin,
    result.scratch / "seed-lib-public-b")
  result.libPrivateSha = seedGitOrigin(gitBin, result.libPrivateOrigin,
    result.scratch / "seed-lib-private")

  # Two bare repos stand in for the manifest layer URLs. The private
  # manifest bare is either kept reachable (full-access user) or removed
  # after seeding to simulate "no access" (the URL in workspace.toml
  # still points at it, but a git clone fails).
  result.publicManifestBare = result.scratch / "bare-public-manifest.git"
  result.privateManifestBare = result.scratch / "bare-private-manifest.git"

  seedManifestBare(gitBin, result.scratch, result.publicManifestBare, [
    ("projects/myproject.toml", publicProjectToml(
      fileUrl(result.libPublicAOrigin),
      fileUrl(result.libPublicBOrigin))),
    ("repos/lib-public-a.toml", libPublicAFragment),
    ("repos/lib-public-b.toml", libPublicBFragment),
  ])
  seedManifestBare(gitBin, result.scratch, result.privateManifestBare, [
    ("projects/myproject.toml", privateProjectToml(
      fileUrl(result.libPrivateOrigin))),
    ("repos/lib-private.toml", libPrivateFragment),
  ])
  if not privateManifestReachable:
    # Simulate "no private access" by removing the private manifest's
    # bare origin AFTER it was seeded. The workspace.toml URL still
    # points at it, but git clone will fail with "does not appear to
    # be a git repository" — exactly the access-control shape the
    # M25 spec exercises.
    removeDir(result.privateManifestBare)

  result.workspaceRoot = result.scratch / "workspace"
  createDir(result.workspaceRoot)
  result.workspaceTomlPath = writeWorkspaceToml(result.workspaceRoot,
    fileUrl(result.publicManifestBare),
    fileUrl(result.privateManifestBare))

# ---- helpers --------------------------------------------------------------

proc invokeInit(fx: Fixture; extraArgs: openArray[string] = []): CmdResult =
  var argv = @[
    fx.reproBin, "workspace", "init", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for arg in extraArgs:
    argv.add(arg)
  runShell(shellCommand(argv))

proc invokeLock(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "lock",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc readInitReport(fx: Fixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "workspace" /
    "init-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

# ---- the suite ------------------------------------------------------------

suite "M25 — private manifest layering integrated end-to-end":

  test "test_m25_init_succeeds_with_full_access_to_public_and_private":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "full-access",
                            privateManifestReachable = true)
      defer: removeDir(fx.scratch)

      let res = invokeInit(fx)
      if res.code != 0:
        checkpoint("init output: " & res.output)
      check res.code == 0

      # All three repos materialise. The composer pulled the union of
      # the two layers and the M9 dispatcher cloned every declared repo.
      check dirExists(fx.workspaceRoot / "lib-public-a" / ".git")
      check dirExists(fx.workspaceRoot / "lib-public-b" / ".git")
      check dirExists(fx.workspaceRoot / "lib-private" / ".git")

      let report = readInitReport(fx)
      check report["project"].getStr() == "myproject"
      check report["cloned"].len == 3
      check report["upToDate"].len == 0
      check report["divergences"].len == 0
      # No layer was skipped — both layers reachable, no opt-in flag.
      check report["skippedLayers"].kind == JArray
      check report["skippedLayers"].len == 0

      # The per-repo clones must carry the bare-origin HEAD SHAs.
      let publicAHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-public-a") & " rev-parse HEAD").strip()
      check publicAHead == fx.libPublicASha
      let privateHead = requireGit(q(gitBin) & " -C " &
        q(fx.workspaceRoot / "lib-private") & " rev-parse HEAD").strip()
      check privateHead == fx.libPrivateSha

  test "test_m25_init_fails_with_clear_diagnostic_when_private_layer_unreachable":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "no-private-access",
                            privateManifestReachable = false)
      defer: removeDir(fx.scratch)

      let res = invokeInit(fx)
      # Without ``--allow-missing-layers`` the unreachable private
      # layer is fatal. The dispatcher converts the structured
      # diagnostic to exit code 1 and stderr text.
      check res.code == 1

      # The diagnostic must explicitly name the private layer (so the
      # user can tell which layer requires credentials) AND carry the
      # stable ``manifest-layer-unreachable:`` tag so a JSON consumer
      # can detect the access-denied class of failure.
      check manifestLayerUnreachableTag in res.output
      check "visibility=private" in res.output
      check fileUrl(fx.privateManifestBare) in res.output

      # No per-repo clones happened: the composer aborted before the
      # init dispatcher reached its per-repo loop.
      check not dirExists(fx.workspaceRoot / "lib-public-a" / ".git")
      check not dirExists(fx.workspaceRoot / "lib-private" / ".git")

  test "test_m25_lock_round_trips_after_full_access_init":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "lock-round-trip",
                            privateManifestReachable = true)
      defer: removeDir(fx.scratch)

      let initRes = invokeInit(fx)
      if initRes.code != 0:
        checkpoint("init output: " & initRes.output)
      check initRes.code == 0

      # Drive M11 on the workspace the M25 init produced. The lock
      # writer composes the same layers, gathers per-repo HEAD SHAs,
      # and writes both ``locks/<project>/<trigger>-<sha>.toml`` and
      # the index file under the public manifest layer's checkout
      # (the first layer in workspace.toml).
      let lockRes = invokeLock(fx)
      if lockRes.code != 0:
        checkpoint("lock output: " & lockRes.output)
      check lockRes.code == 0

      let lockReportPath = fx.workspaceRoot / ".repro" / "workspace" /
        "lock-report.json"
      check fileExists(lockReportPath)
      let lockReport = parseFile(lockReportPath)
      check lockReport["exitCode"].getInt() == 0
      check lockReport["project"].getStr() == "myproject"
      check lockReport["repos"].len == 3

      let lockPath = lockReport["lockFilePath"].getStr()
      check fileExists(lockPath)

      # Round-trip the lock TOML through the M5 strict reader. The
      # parsed lock must carry every repo (public AND private) with
      # the SHA the live workspace observed.
      let parsed = readLock(lockPath)
      check parsed.lock.project == "myproject"
      check parsed.repo.len == 3

      var byName = initTable[string, LockedRepo]()
      for r in parsed.repo:
        byName[r.name] = r

      check byName.hasKey("lib-public-a")
      check byName.hasKey("lib-public-b")
      check byName.hasKey("lib-private")
      check byName["lib-public-a"].revision == fx.libPublicASha
      check byName["lib-public-b"].revision == fx.libPublicBSha
      check byName["lib-private"].revision == fx.libPrivateSha

  test "test_m25_init_succeeds_with_public_only_when_skip_flag_present":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "public-only-skip",
                            privateManifestReachable = false)
      defer: removeDir(fx.scratch)

      let res = invokeInit(fx, @["--allow-missing-layers"])
      if res.code != 0:
        checkpoint("init output: " & res.output)
      check res.code == 0

      # Only the public subset materialises. ``lib-private`` was not
      # in the composed project (its layer was dropped) so the
      # dispatcher never tried to clone it.
      check dirExists(fx.workspaceRoot / "lib-public-a" / ".git")
      check dirExists(fx.workspaceRoot / "lib-public-b" / ".git")
      check not dirExists(fx.workspaceRoot / "lib-private")

      let report = readInitReport(fx)
      check report["project"].getStr() == "myproject"
      # Two repos cloned, both from the public layer.
      check report["cloned"].len == 2
      var clonedPaths: seq[string]
      for entry in report["cloned"]:
        clonedPaths.add(entry["path"].getStr())
      check "lib-public-a" in clonedPaths
      check "lib-public-b" in clonedPaths
      check "lib-private" notin clonedPaths

      # The dropped layer is recorded with its visibility tier and the
      # original diagnostic so downstream tooling can tell the operator
      # which part of the workspace is unavailable.
      check report["skippedLayers"].kind == JArray
      check report["skippedLayers"].len == 1
      let skipped = report["skippedLayers"][0]
      check skipped["visibility"].getStr() == "private"
      check skipped["provenance"].getStr() ==
        fileUrl(fx.privateManifestBare)
      check skipped["index"].getInt() == 1
      check manifestLayerUnreachableTag in skipped["diagnostic"].getStr()
