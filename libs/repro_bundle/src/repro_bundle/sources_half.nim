## The sources half of a workspace bundle (Workspace-Bundles.md §3): a
## shallow clone of each member checkout's current commit, nested where the
## workspace nests it, `origin` set to the real remote, and the workspace's
## checkout state.

import std/[algorithm, json, os, strutils, tempfiles]
import repro_local_store/store_bundle
import ./exec
import ./select
import ./nix_half

type
  SourceRepo* = object
    relPath*: string
    branch*: string
    rev*: string
    origin*: string

  SourcesHalf* = object
    id*: string
    workspaceDir*: string     ## absolute workspace path at create time
    unpackedBytes*: int64
    compressedBytes*: int64
    parts*: seq[BundlePart]
    repos*: seq[SourceRepo]
    stateFiles*: seq[tuple[path, sha256: string]]
    skipped*: seq[tuple[relPath, reason: string]]

const
  SourcesHalfDir* = "sources"
  SourcesManifestName* = "sources.json"
  SourcesIdDomain = "reprobuild.workspace-bundle.sources.v1"
  CarriedStateFiles* = [".repro/workspace-state.toml", "workspace-projects.md"]
  SourcesMarker* = ".repro/bundle-sources-id"

proc git(args: openArray[string]; cwd = ""): string =
  mustRun(requireExe("git"), args, cwd).strip()

proc toJson*(h: SourcesHalf): JsonNode =
  var repos = newJObject()
  for r in h.repos:
    var row = newJObject()
    row["branch"] = %r.branch
    row["rev"] = %r.rev
    row["origin"] = %r.origin
    repos[r.relPath] = row
  var state = newJObject()
  for entry in h.stateFiles: state[entry.path] = %entry.sha256
  result = newJObject()
  result["id"] = %h.id
  result["workspace_dir"] = %h.workspaceDir
  result["unpacked_bytes"] = %h.unpackedBytes
  result["compressed_bytes"] = %h.compressedBytes
  result["parts"] = partsJson(h.parts)
  result["repos"] = repos
  result["state_files"] = state

proc parseSourcesHalf*(node: JsonNode): SourcesHalf =
  try:
    result.id = node["id"].getStr()
    result.workspaceDir = node["workspace_dir"].getStr()
    result.unpackedBytes = node["unpacked_bytes"].getBiggestInt()
    result.compressedBytes = node{"compressed_bytes"}.getBiggestInt()
    result.parts = parsePartsJson(node["parts"])
    for rel, r in node["repos"]:
      result.repos.add(SourceRepo(relPath: rel, branch: r{"branch"}.getStr(),
        rev: r["rev"].getStr(), origin: r{"origin"}.getStr()))
    if node.hasKey("state_files"):
      for path, sha in node["state_files"]:
        result.stateFiles.add((path, sha.getStr()))
  except KeyError as e:
    bundleFail("malformed sources half manifest: " & e.msg)

proc sourcesHalfId*(repos: seq[SourceRepo];
                    state: seq[tuple[path, sha256: string]]): string =
  var rows: seq[string]
  for r in repos:
    rows.add(r.relPath & "\t" & r.branch & "\t" & r.rev & "\t" & r.origin)
  for (path, sha) in state:
    rows.add("state\t" & path & "\t" & sha)
  rows.sort()
  sha256Hex(SourcesIdDomain & "\n" & rows.join("\n") & "\n")[0 ..< 32]

proc dirSize(dir: string): int64 =
  for path in walkDirRec(dir, yieldFilter = {pcFile}):
    try: result += getFileSize(path) except OSError: discard

proc createSourcesHalf*(workspaceRoot: string; members: seq[BundleMember];
                        bundleDir: string; level: int; partSize: int64):
    tuple[half: SourcesHalf; reused: bool] =
  ## Into `<bundleDir>/sources/<id>/`, reusing a complete half with that id.
  let ws = normalizedPath(absolutePath(workspaceRoot))
  var half = SourcesHalf(workspaceDir: ws)
  var cloneable: seq[BundleMember]
  for m in byDepth(members):
    if not m.checkedOut:
      half.skipped.add((m.relPath, "not checked out"))
      stderr.writeLine("repro bundle: " & m.name & " is not checked out at " &
        m.absPath & "; not in the sources")
      continue
    let rev = git(["-C", m.absPath, "rev-parse", "HEAD"])
    let branch = git(["-C", m.absPath, "branch", "--show-current"])
    let originR = runTool(requireExe("git"), ["-C", m.absPath, "remote",
      "get-url", "origin"])
    let origin = (if originR.code == 0: originR.output.strip() else: "")
    if git(["-C", m.absPath, "status", "--porcelain",
        "--untracked-files=no"]).len > 0:
      stderr.writeLine("repro bundle: " & m.relPath & " has uncommitted " &
        "changes; only its commit " & rev[0 ..< 12] & " is bundled")
    half.repos.add(SourceRepo(relPath: m.relPath, branch: branch, rev: rev,
      origin: origin))
    cloneable.add(m)
  for f in CarriedStateFiles:
    if fileExists(ws / f):
      half.stateFiles.add((f, sha256Hex(readFile(ws / f))))
  half.id = sourcesHalfId(half.repos, half.stateFiles)
  let dir = bundleDir / SourcesHalfDir / half.id
  if fileExists(dir / SourcesManifestName):
    var reused = parseSourcesHalf(parseJson(readFile(dir / SourcesManifestName)))
    reused.skipped = half.skipped
    return (reused, true)
  let staging = createTempDir("repro-bundle-src-", "")
  defer: removeDir(staging)
  let top = staging / extractFilename(ws)
  for i, m in cloneable:
    let r = half.repos[i]
    let to = (if m.relPath == ".": top else: top / m.relPath)
    createDir(to)
    discard git(["-C", to, "init", "-q"])
    # By commit, so a detached checkout bundles exactly what it has.
    discard git(["-C", to, "fetch", "-q", "--depth", "1",
      "file://" & m.absPath, r.rev])
    if r.branch.len > 0:
      discard git(["-C", to, "checkout", "-q", "-B", r.branch, "FETCH_HEAD"])
    else:
      discard git(["-C", to, "checkout", "-q", "--detach", "FETCH_HEAD"])
    if r.origin.len > 0:
      discard git(["-C", to, "remote", "add", "origin", r.origin])
  for (f, _) in half.stateFiles:
    createDir((top / f).parentDir)
    copyFile(ws / f, top / f)
  half.unpackedBytes = dirSize(staging)
  let partial = dir & ".partial"
  removeDir(partial)
  let pipeline = quoteShell(requireExe("tar")) & " --format=posix -C " &
    quoteShell(staging) & " -cf - " & quoteShell(extractFilename(ws)) &
    " | " & zstdCompressCommand(requireExe("zstd"),
      (if level > 0: level else: DefaultZstdLevel), 0)
  let (parts, total) = writeCompressedParts(pipeline, partial,
    (if partSize > 0: partSize else: DefaultPartSize))
  half.parts = parts
  half.compressedBytes = total
  writeFile(partial / SourcesManifestName, pretty(half.toJson) & "\n")
  removeDir(dir)
  moveDir(partial, dir)
  (half, false)

proc sourcesPresent*(h: SourcesHalf; workspaceDir: string): bool =
  let marker = workspaceDir / SourcesMarker
  fileExists(marker) and readFile(marker).strip() == h.id

proc restoreSourcesHalf*(h: SourcesHalf; partsDir, workspaceDir: string) =
  ## §7 step 4: into the workspace's parent with `--skip-old-files`, so a
  ## checkout that already exists is never overwritten.
  let ws = normalizedPath(absolutePath(workspaceDir))
  let parent = ws.parentDir
  createDir(parent)
  let name = extractFilename(h.workspaceDir)
  let errPath = partsDir / ".unpack.stderr"
  # The archive's top directory is the creating workspace's name; a restore
  # under another name renames it on the way.
  let transform = (if extractFilename(ws) != name:
      " --transform=" & quoteShell("s|^" & name & "|" & extractFilename(ws) & "|")
    else: "")
  let command = "set -o pipefail; (" & quoteShell(requireExe("zstd")) &
    " -q -dc --long=" & $ZstdWindowLog & " - | " &
    quoteShell(requireExe("tar")) & " -C " & quoteShell(parent) &
    " --skip-old-files" & transform & " -xf -) >" & quoteShell(errPath) &
    " 2>&1"
  if feedParts(partsDir, h.parts, command, stopEarly = false) != 0:
    bundleFail("unpacking the sources half failed: " &
      (if fileExists(errPath): readFile(errPath).strip() else: ""))
  createDir((ws / SourcesMarker).parentDir)
  writeFile(ws / SourcesMarker, h.id & "\n")
