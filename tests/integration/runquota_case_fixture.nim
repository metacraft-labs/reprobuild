## Private source workspace for the cross-project RunQuota integration cases.
import std/[os, sha1, strtabs]
import repro_test_support

type RunQuotaCaseFixture* = object
  root*, consumer*, checkout*, daemon*: string
  env*: StringTableRef

proc sharedRunQuotaDaemonState*(repoRoot: string): string =
  var measured: seq[string]
  for root in [repoRoot.parentDir / "runquota", requireRunQuotaSourceRoot(repoRoot)]:
    let source = if dirExists(root): expandFilename(root)
                 else: absolutePath(root).normalizedPath
    if source in measured:
      continue
    measured.add(source)
    let path = source / "build" / "bin" / addFileExt("runquotad", ExeExt)
    result.add(path & "=" &
      (if fileExists(path): $secureHashFile(path) else: "missing") & "\n")

proc copySources(source, destination: string) =
  createDir(destination)
  for kind, path in walkDir(source):
    let name = path.extractFilename
    if name in [".git", ".repro", ".nimcache", ".direnv", "build", "test-logs",
                "result"]:
      continue
    let target = destination / name
    case kind
    of pcDir: copySources(path, target)
    of pcFile, pcLinkToFile: copyFileWithPermissions(path, target,
      ignorePermissionErrors = false)
    of pcLinkToDir: copySources(path, target)

proc prepareRunQuotaCase*(repoRoot: string;
                         variant = ""): RunQuotaCaseFixture =
  result.root = repoRoot / "build" / "test-fixtures" /
    "runquota-cases" / (testScratchSlug() & variant)
  result.consumer = result.root / "consumer"
  result.checkout = result.root / "runquota"
  result.daemon = result.checkout / "build" / "bin" /
    addFileExt("runquotad", ExeExt)
  # Reset the source/output tree, retaining this case's content-addressed cache
  # and work roots so a repeated run can restore the real engine's artifacts.
  if dirExists(result.checkout):
    removeDir(result.checkout)
  copySources(requireRunQuotaSourceRoot(repoRoot), result.checkout)
  createDir(result.consumer)
  writeFile(result.consumer / "repro.nim", """import repro_project_dsl
package consumer:
  version: "0.0.0"
""")
  result.env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result.env[key] = value
  result.env["RUNQUOTA_SRC"] = result.checkout
  result.env["XDG_CACHE_HOME"] = result.root / "cache"
  result.env["REPROBUILD_STORE_ROOT"] = result.root / "store"
  result.env["REPROBUILD_ACTION_CACHE_ROOT"] = result.root / "action-cache"
  result.env["REPROBUILD_WORK_ROOT"] = result.root / "work"

proc installRunQuotaCaseDaemon*(fixture: RunQuotaCaseFixture;
                               repoRoot: string) =
  let binary = requireBinary(repoRoot / "build" / "test-fixtures" /
    "runquota" / addFileExt("runquotad", ExeExt),
    "reprobuild.test_fixtures.runquotad")
  createDir(fixture.daemon.parentDir)
  copyFileWithPermissions(binary, fixture.daemon, ignorePermissionErrors = false)
