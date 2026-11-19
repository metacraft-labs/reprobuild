## The sources half of a workspace bundle (Workspace-Bundles.md §3): a
## shallow clone of each member checkout's current commit, nested where the
## workspace nests it, `origin` set to the real remote, and the workspace's
## checkout state.

import std/[algorithm, json, os, sets, strutils, tempfiles]
import repro_local_store/store_bundle
import repro_local_store/tar_members
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

proc hasControlChar(path: string): bool =
  for ch in path:
    if ord(ch) < 0x20 or ord(ch) == 0x7f: return true

proc isCanonicalRelative(path: string): bool =
  relativeNameProblem(path).len == 0

proc within(path, dir: string): bool =
  ## Whether `path` is `dir` or lies beneath it.
  path == dir or path.startsWith(dir & "/")

proc parentPaths(path: string): seq[string] =
  ## The strict ancestors of a canonical relative path, shortest first:
  ## `a/b/c` gives `a`, `a/b`.
  var i = path.find('/')
  while i >= 0:
    result.add(path[0 ..< i])
    i = path.find('/', i + 1)

proc checkSourcesDeclarations*(h: SourcesHalf): string =
  ## §7 step 4.1. The half's top directory name (returned), its declared
  ## checkout paths and its carried state files must be paths the member
  ## check can compare against: a single directory name, and canonical
  ## relative paths beneath it. A declared path holds no control character,
  ## because a checkout path becomes a line of `.git/info/exclude`, and no
  ## checkout lies in the root's `.git`, which a members-only restore
  ## writes. The id, which names the marker the restore writes, is the 32
  ## lowercase hex digits `sourcesHalfId` makes.
  result = extractFilename(h.workspaceDir)
  if result.len == 0 or result == "." or result == ".." or '/' in result or
      '\0' in result:
    bundleFail("the sources half's workspace directory name " &
      result.escape & " (from workspace_dir " & h.workspaceDir.escape &
      ") is not a single directory name")
  if h.id.len != 32 or not h.id.allCharsInSet({'0' .. '9', 'a' .. 'f'}):
    bundleFail("the sources half's id " & h.id.escape &
      " is not 32 lowercase hex digits")
  for r in h.repos:
    if r.relPath == ".": continue
    if not isCanonicalRelative(r.relPath) or hasControlChar(r.relPath):
      bundleFail("the sources half declares the checkout path " &
        r.relPath.escape & ", which is not a canonical relative path")
    if r.relPath.within(".git"):
      bundleFail("the sources half declares the checkout path " &
        r.relPath.escape & ", which lies in the workspace root's .git")
  for (path, _) in h.stateFiles:
    if not isCanonicalRelative(path) or hasControlChar(path):
      bundleFail("the sources half declares the state file " & path.escape &
        ", which is not a canonical relative path")

proc checkSourcesPlacement*(h: SourcesHalf; name: string;
                            members: seq[TarMember]) =
  ## §7 step 4.2, placement: every member is the top directory `<name>`
  ## itself, or `<name>/<rel>` where `<rel>` is a declared checkout's path or
  ## lies within one, is a carried state file, or (a directory only) is on
  ## the way to one of those. A hard link's target is an earlier member
  ## (`tar_members.admit`), so it has passed this check too. The restore
  ## writes its marker into `.repro` after the unpack, so `<name>/.repro`
  ## may only be a directory and the marker itself is never a member.
  var rootDeclared = false
  var checkouts: seq[string]
  for r in h.repos:
    if r.relPath == ".": rootDeclared = true
    else: checkouts.add(r.relPath)
  var state = initHashSet[string]()
  for (path, _) in h.stateFiles: state.incl(path)
  let markerDir = SourcesMarker.parentDir
  for m in members:
    let path = m.memberPath
    if path == name:
      if m.kind != 'd':
        bundleFail("the sources half's top member " & m.name.escape &
          " is not a directory")
      continue
    if not path.startsWith(name & "/"):
      bundleFail("the sources half's member " & m.name.escape &
        " lies outside its workspace directory " & (name & "/").escape)
    let rel = path[name.len + 1 .. ^1]
    if rel == SourcesMarker or (rel == markerDir and m.kind != 'd'):
      bundleFail("the sources half's member " & m.name.escape &
        " would take the place of the restore's own " &
        (if rel == SourcesMarker: "marker" else: "directory " & markerDir))
    var ok = rootDeclared or rel in state
    if not ok:
      for d in checkouts:
        if rel.within(d) or (m.kind == 'd' and d.startsWith(rel & "/")):
          ok = true
          break
    if not ok and m.kind == 'd':
      for s in state:
        if s.startsWith(rel & "/"):
          ok = true
          break
    if not ok:
      bundleFail("the sources half's member " & m.name.escape &
        " lies in no checkout and is no state file the half declares")

proc checkNoSymlinkOnDisk*(ws, name: string; members: seq[TarMember]) =
  ## §7 step 4.3. GNU tar follows a symlink it finds among a member's
  ## leading directories, and `--skip-old-files` keeps one that exists, so a
  ## link already inside the workspace would carry the unpack out of it even
  ## though every member is declared. Every directory between `ws` (the
  ## caller's, not checked) and each member, or its hard-link target, must
  ## not be a symlink.
  var checked = initHashSet[string]()
  for m in members:
    var names = @[m.memberPath]
    if m.kind == 'h': names.add(m.linkTarget)
    for n in names:
      if not n.startsWith(name & "/"): continue
      for p in parentPaths(n[name.len + 1 .. ^1]):
        if checked.containsOrIncl(p): continue
        if symlinkExists(ws / p):
          bundleFail(ws / p & " is a symlink; unpacking the sources half " &
            "would follow it to write " & (ws / n[name.len + 1 .. ^1]) &
            ", so nothing was unpacked")

proc listSourcesMembers*(h: SourcesHalf; partsDir: string): seq[TarMember] =
  ## §7 step 4.2, the rules every half shares: the archive in `h`'s verified
  ## parts, listed by the tar that will extract it, holds only files, hard
  ## links, symlinks and directories with canonical relative names, each
  ## once; a hard link's target is an earlier file; no member lies beneath a
  ## symlink member (`tar_members.admit`, `finish`). The listing is written
  ## to a fresh private directory, not beside the parts: a local bundle's
  ## parts directory may be writable by others, who could otherwise plant a
  ## symlink there for the redirection to follow, or swap the listing
  ## before it is read.
  let scratch = privateScratchDir("repro-bundle-sources-")
  defer: removeScratchDir(scratch)
  let listing = scratch / "members"
  try:
    listBundleMembers(partsDir, h.parts, listing)
  except StoreBundleError as e:
    bundleFail("cannot check the sources half: " & e.msg)
  var admitted = initMemberSet()
  var problem = ""
  try:
    for (_, m) in listingMembers(listing):
      problem = admitted.admit(m)
      if problem.len > 0: break
      result.add(m)
  except ValueError as e:
    problem = e.msg
  if problem.len == 0: problem = admitted.finish()
  if problem.len > 0:
    bundleFail("refusing the sources half before unpacking it: " & problem &
      "; nothing was written")

proc restoreSourcesHalf*(h: SourcesHalf; partsDir, workspaceDir: string): bool =
  ## §7 step 4: into the workspace's parent with `--skip-old-files`, so a
  ## checkout that already exists is never overwritten. When the workspace
  ## root is itself a checkout already (the environment cloned it), only the
  ## member checkouts are unpacked, and they are added to the root's
  ## `.git/info/exclude`. Returns whether that members-only path was taken.
  ##
  ## Before anything is written, the half's declarations, every member of
  ## its archive and the directories already on disk that the unpacked
  ## members lie beneath are checked (steps 4.1–4.3); the part hashes
  ## cannot stand in for that, because the manifest that names them is not
  ## signed (§9).
  let ws = normalizedPath(absolutePath(workspaceDir))
  let parent = ws.parentDir
  let name = checkSourcesDeclarations(h)
  # tar's diagnostics go to a private directory (`privateScratchDir`), not
  # beside the parts, which are only read.
  let scratch = privateScratchDir("repro-bundle-unpack-")
  defer: removeScratchDir(scratch)
  let errPath = scratch / "unpack.stderr"
  let rootIsCheckout = dirExists(ws / ".git")
  var members: seq[string]
  if rootIsCheckout:
    for r in h.repos:
      if r.relPath != ".": members.add(name & "/" & r.relPath)
  result = rootIsCheckout
  if not rootIsCheckout or members.len > 0:
    let listed = listSourcesMembers(h, partsDir)
    checkSourcesPlacement(h, name, listed)
    # Members-only, tar unpacks each named checkout and what lies within it.
    var unpacked: seq[TarMember]
    for m in listed:
      if not rootIsCheckout:
        unpacked.add(m)
        continue
      for sel in members:
        if m.memberPath.within(sel):
          unpacked.add(m)
          break
    # A hard link whose target is not unpacked would be made to the file
    # already on disk under that name, such as the root checkout's own
    # `.git/config`, and give the member an alias to it.
    var unpackedNames = initHashSet[string]()
    for m in unpacked: unpackedNames.incl(m.memberPath)
    for m in unpacked:
      if m.kind == 'h' and m.linkTarget notin unpackedNames:
        bundleFail("the sources half's member " & m.name.escape &
          " is a hard link to " & m.linkTarget.escape &
          ", which this restore does not unpack")
    checkNoSymlinkOnDisk(ws, name, unpacked)
  createDir(parent)
  # The archive's top directory is the creating workspace's name; a restore
  # under another name renames it on the way.
  # Every member is `name` or lies beneath it (step 4.2), so the first
  # component is matched as `[^/]*` and `name` never enters the expression.
  # In the replacement `\`, `&` and the `,` delimiter are escaped; see
  # https://www.gnu.org/software/tar/manual/html_node/transform.html. The
  # flags apply it to member names and hard-link targets, not to the text
  # of a symlink.
  var target = ""
  for ch in extractFilename(ws):
    if ch in {'\\', '&', ','}: target.add('\\')
    target.add(ch)
  let transform = (if extractFilename(ws) != name:
      " --transform=" & quoteShell("flags=rh;s,^[^/]*," & target & ",")
    else: "")
  # After `--`, so that tar reads a member that starts with `-` as a name.
  var memberArgs = ""
  if members.len > 0: memberArgs = " --"
  for m in members: memberArgs.add(" " & quoteShell(m))
  let command = "set -o pipefail; (" & quoteShell(requireExe("zstd")) &
    " -q -dc --long=" & $ZstdWindowLog & " - | " &
    quoteShell(requireExe("tar")) & " -C " & quoteShell(parent) &
    " --skip-old-files" & transform & " -xf -" & memberArgs & ") >" &
    quoteShell(errPath) & " 2>&1"
  if rootIsCheckout and members.len == 0:
    discard
  elif feedParts(partsDir, h.parts, command, stopEarly = false) != 0:
    bundleFail("unpacking the sources half failed: " &
      (if fileExists(errPath): readFile(errPath).strip() else: ""))
  if rootIsCheckout:
    # Local to the checkout and never pushed: hides the members from the
    # root repository's `git status`, as a repro workspace does.
    let exclude = ws / ".git" / "info" / "exclude"
    createDir(exclude.parentDir)
    let have = (if fileExists(exclude): readFile(exclude) else: "")
    var lines = have.splitLines()
    var add = ""
    for r in h.repos:
      if r.relPath == ".": continue
      let line = "/" & r.relPath & "/"
      if line notin lines:
        add.add(line & "\n")
        lines.add(line)
    if add.len > 0:
      writeFile(exclude, have & (if have.len > 0 and not have.endsWith("\n"):
        "\n" else: "") & add)
  createDir((ws / SourcesMarker).parentDir)
  writeFile(ws / SourcesMarker, h.id & "\n")
