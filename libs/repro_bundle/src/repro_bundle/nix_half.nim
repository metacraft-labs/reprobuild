## The Nix half of a workspace bundle (Workspace-Bundles.md §2): every
## member's dev-shell closure, its `nix-store --dump-db` registration, and a
## normalised `nix print-dev-env` per shell, so a session enters a shell with
## no evaluation.

import std/[algorithm, json, os, sequtils, sets, strutils, tables, tempfiles]
when defined(posix):
  import std/posix
import nimcrypto/sha2
import repro_core/ambient_execution
import repro_local_store/store_bundle
import repro_local_store/tar_members
import ./exec
import ./select

type
  BundleShell* = object
    name*: string        ## `<member>:<shell>`
    input*: string       ## `inputDerivation` output
    env*: string         ## store path of the normalised environment script

  NixHalf* = object
    id*: string
    system*: string
    nixVersion*: string
    zstd*: string        ## store path whose `bin/zstd` the bootstrap realises
    repro*: string       ## store path whose `bin/repro` restores the rest, or ""
    paths*: seq[string]
    unpackedBytes*: int64
    compressedBytes*: int64
    parts*: seq[BundlePart]
    registration*: BundlePart
    shells*: seq[BundleShell]
    primary*: string

  NixHalfOptions* = object
    allShells*: bool
    primary*: string
    zstd*: string
    repro*: string
    level*: int
    partSize*: int64
    checkStable*: bool

const
  NixHalfDir* = "nix"
  NixManifestName* = "nix.json"
  NixIdDomain = "reprobuild.workspace-bundle.nix.v1"

proc sha256Hex*(text: string): string =
  lowerHex(sha256.digest(text).data)

proc currentSystem*(): string =
  mustRun(requireExe("nix"), ["eval", "--impure", "--raw", "--expr",
    "builtins.currentSystem"]).strip()

proc storePathOf*(path: string): string =
  ## `/nix/store/<hash>-<name>` for a path inside the store, else "".
  let p = normalizedPath(path)
  if not p.startsWith("/nix/store/"): return ""
  let rest = p["/nix/store/".len .. ^1]
  let slash = rest.find('/')
  "/nix/store/" & (if slash < 0: rest else: rest[0 ..< slash])

proc normaliseDevEnv*(text: string): string =
  ## §2.1. `NIX_BUILD_CORES` names the building machine's cores; the
  ## shellHook installs git hooks, which repro owns. The working-directory
  ## dependence is removed by running `print-dev-env` in the member's
  ## checkout, not here.
  for line in text.splitLines(keepEol = true):
    let s = line.strip()
    if s.startsWith("eval \"${shellHook") or s.startsWith("eval \"$shellHook"):
      continue
    if line.startsWith("NIX_BUILD_CORES='"):
      result.add("NIX_BUILD_CORES=\"$(nproc 2>/dev/null || echo 1)\"\n")
      continue
    result.add(line)

proc devenvArgs(dir: string): seq[string] =
  ## devenv flakes evaluate only when told their checkout directory, the way
  ## their `.envrc` tells them.
  let flake = dir / "flake.nix"
  if fileExists(flake) and "devenv-root" in readFile(flake):
    createDir(dir / ".devenv")
    writeFile(dir / ".devenv" / "root", dir)
    @["--override-input", "devenv-root",
      "file+file://" & dir / ".devenv" / "root", "--accept-flake-config"]
  else:
    @[]

proc safeName(text: string): string =
  for ch in text:
    result.add(if ch.isAlphaNumeric or ch in {'-', '_', '.'}: ch else: '-')

proc captureEnv(nix: string; m: BundleMember; attr: string;
                fargs: seq[string]): string =
  normaliseDevEnv(mustRun(nix, @["print-dev-env"] & fargs & @[attr],
    cwd = m.absPath))

proc collectShells(members: seq[BundleMember]; system: string;
                   opts: NixHalfOptions): seq[BundleShell] =
  let nix = requireExe("nix")
  let scratch = createTempDir("repro-bundle-env-", "")
  defer: removeDir(scratch)
  for m in members:
    if not m.checkedOut or not fileExists(m.absPath / "flake.nix"):
      continue
    let fargs = devenvArgs(m.absPath)
    let namesJson = runTool(nix, @["eval"] & fargs & @["--json",
      m.absPath & "#devShells." & system, "--apply", "builtins.attrNames"])
    if namesJson.code != 0:
      stderr.writeLine("repro bundle: " & m.name & ": no devShells." & system &
        "; skipped")
      continue
    var names: seq[string]
    for n in parseJson(namesJson.output): names.add(n.getStr())
    if not opts.allShells:
      names = (if "default" in names: @["default"]
               elif names.len > 0: @[names[0]] else: @[])
    let member = (if m.relPath == ".": "workspace" else: m.name)
    for shell in names:
      let attr = m.absPath & "#devShells." & system & "." & shell
      # Built, not only evaluated: a shell whose evaluation downloads
      # archives cannot be re-evaluated in a session.
      let input = mustRun(nix, @["build"] & fargs & @["--no-link",
        "--print-out-paths", attr & ".inputDerivation"]).strip().splitLines()[0]
      let env = captureEnv(nix, m, attr, fargs)
      if opts.checkStable and captureEnv(nix, m, attr, fargs) != env:
        bundleFail("the environment of " & member & ":" & shell &
          " differs between two captures; its id would not be stable")
      let file = scratch / ("repro-bundle-" & safeName(member) & "-" &
        safeName(shell) & "-env.sh")
      writeFile(file, env)
      let envPath = mustRun(nix, ["store", "add-file", file]).strip()
      result.add(BundleShell(name: member & ":" & shell, input: input,
        env: envPath))
      stderr.writeLine("repro bundle:   " & member & ":" & shell)

proc closureOf(roots: seq[string]): seq[string] =
  if roots.len == 0: return
  var seen = initHashSet[string]()
  for line in mustRun(requireExe("nix-store"), @["-qR"] & roots).splitLines():
    let p = line.strip()
    if p.len > 0 and p notin seen:
      seen.incl(p)
      result.add(p)
  result.sort()

proc nixHalfId*(paths: seq[string]): string =
  ## A function of the sorted store-path list alone (§2.1).
  var sorted = paths
  sorted.sort()
  sha256Hex(NixIdDomain & "\n" & sorted.join("\n") & "\n")[0 ..< 32]

proc unpackedSize(paths: seq[string]): int64 =
  let node = parseJson(mustRun(requireExe("nix"),
    @["path-info", "--json"] & paths))
  if node.kind == JObject:
    for _, v in node:
      if v.kind == JObject: result += v{"narSize"}.getBiggestInt()
  else:
    for v in node: result += v{"narSize"}.getBiggestInt()

proc toJson*(h: NixHalf): JsonNode =
  var shells = newJObject()
  for s in h.shells:
    shells[s.name] = %*{"input": s.input, "env": s.env}
  %*{
    "id": h.id, "system": h.system, "nix": h.nixVersion, "zstd": h.zstd,
    "repro": h.repro, "paths": h.paths, "unpacked_bytes": h.unpackedBytes,
    "compressed_bytes": h.compressedBytes, "parts": partsJson(h.parts),
    "registration": {"file": h.registration.file,
      "bytes": h.registration.bytes, "sha256": h.registration.sha256},
    "shells": shells, "primary": h.primary}

proc parseNixHalf*(node: JsonNode): NixHalf =
  try:
    result.id = node["id"].getStr()
    result.system = node["system"].getStr()
    result.nixVersion = node{"nix"}.getStr()
    result.zstd = node["zstd"].getStr()
    result.repro = node{"repro"}.getStr()
    for p in node["paths"]: result.paths.add(p.getStr())
    result.unpackedBytes = node["unpacked_bytes"].getBiggestInt()
    result.compressedBytes = node{"compressed_bytes"}.getBiggestInt()
    result.parts = parsePartsJson(node["parts"])
    result.registration = parsePartsJson(%[node["registration"]])[0]
    for name, s in node["shells"]:
      result.shells.add(BundleShell(name: name, input: s["input"].getStr(),
        env: s["env"].getStr()))
    result.primary = node{"primary"}.getStr()
  except KeyError as e:
    bundleFail("malformed Nix half manifest: " & e.msg)

proc findZstd(paths: seq[string]): string =
  for p in paths:
    if "-zstd-" in p and fileExists(p / "bin" / "zstd"):
      return p

proc packNixHalf*(paths: seq[string]; partial: string; level: int;
                  partSize: int64): tuple[parts: seq[BundlePart];
                    registration: BundlePart;
                    unpackedBytes, compressedBytes: int64] =
  ## Write the store paths' `nix-store --dump-db` registration and their
  ## compressed tar stream, split into parts, into the fresh directory
  ## `partial` (§2.1).
  removeDir(partial)
  createDir(partial)
  let listPath = partial / ".paths"
  var list = ""
  for p in paths: list.add(p[1 .. ^1] & "\n")
  writeFile(listPath, list)
  let zstdExe = requireExe("zstd")
  discard mustRunShell("nix-store --dump-db $(cat " & quoteShell(listPath) &
    " | sed 's|^|/|') | " & zstdCompressCommand(zstdExe, 19, 0) & " > " &
    quoteShell(partial / "registration"), "nix-store --dump-db")
  let regBytes = readFile(partial / "registration")
  result.registration = BundlePart(file: "registration", bytes: regBytes.len,
    sha256: sha256Hex(regBytes))
  result.unpackedBytes = unpackedSize(paths)
  let pipeline = quoteShell(requireExe("tar")) &
    " --format=posix -C / -cf - -T " & quoteShell(listPath) & " | " &
    zstdCompressCommand(zstdExe, level, 0)
  (result.parts, result.compressedBytes) = writeCompressedParts(pipeline,
    partial, partSize)
  removeFile(listPath)

proc createNixHalf*(members: seq[BundleMember]; systemDir: string;
                    opts: NixHalfOptions): tuple[half: NixHalf; reused: bool] =
  ## Build the half into `<systemDir>/nix/<id>/`, or reuse it when a complete
  ## half with that id is already there.
  let system = currentSystem()
  let shells = collectShells(members, system, opts)
  if shells.len == 0:
    bundleFail("no member has a dev shell for " & system)
  var roots: seq[string]
  for s in shells:
    roots.add(s.input)
    roots.add(s.env)
  var reproPath = opts.repro
  if reproPath.len == 0:
    let self = getAppFilename()
    reproPath = storePathOf(self)
    if reproPath.len == 0 and symlinkExists(self):
      reproPath = storePathOf(expandSymlink(self))
  if reproPath.len > 0:
    if not fileExists(reproPath / "bin" / "repro"):
      bundleFail("--repro " & reproPath & " has no bin/repro")
    roots.add(reproPath)
  else:
    stderr.writeLine("repro bundle: this repro is not in /nix/store, so the " &
      "bundle's restore.sh will need `repro` on PATH (pass --repro=STORE-PATH)")
  var zstdPath = opts.zstd
  if zstdPath.len == 0:
    zstdPath = findZstd(closureOf(roots))
  if zstdPath.len == 0:
    let r = runTool(requireExe("nix"), ["build", "--no-link",
      "--print-out-paths", "nixpkgs#zstd.bin"])
    if r.code == 0: zstdPath = r.output.strip().splitLines()[0]
  if zstdPath.len == 0 or not fileExists(zstdPath / "bin" / "zstd"):
    bundleFail("no zstd store path for the restore side; pass --zstd=STORE-PATH")
  roots.add(zstdPath)
  let paths = closureOf(roots)
  let id = nixHalfId(paths)
  let dir = systemDir / NixHalfDir / id
  var primary = opts.primary
  if primary.len == 0:
    primary = shells[0].name
    for s in shells:
      if not s.name.startsWith("workspace:"):
        primary = s.name
        break
  if fileExists(dir / NixManifestName):
    var half = parseNixHalf(parseJson(readFile(dir / NixManifestName)))
    return (half, true)
  let partial = dir & ".partial"
  let level = (if opts.level > 0: opts.level else: DefaultZstdLevel)
  stderr.writeLine("repro bundle: nix half " & id & ": " & $paths.len &
    " paths; compressing at -" & $level)
  let packed = packNixHalf(paths, partial, level,
    (if opts.partSize > 0: opts.partSize else: DefaultPartSize))
  var half = NixHalf(id: id, system: system,
    nixVersion: mustRun(requireExe("nix"), ["--version"]).strip(),
    zstd: zstdPath, repro: reproPath, paths: paths,
    unpackedBytes: packed.unpackedBytes,
    compressedBytes: packed.compressedBytes, parts: packed.parts,
    registration: packed.registration, shells: shells, primary: primary)
  writeFile(partial / NixManifestName, pretty(half.toJson) & "\n")
  removeDir(dir)
  moveDir(partial, dir)
  (half, false)

proc shellRoots*(h: NixHalf): seq[string] =
  for s in h.shells:
    result.add(s.input)
    result.add(s.env)

proc storeArgs(root: string): seq[string] =
  if root.len > 0 and root != "/": @["--store", root] else: @[]

proc nixHalfPresent*(h: NixHalf; root = "/"): bool =
  let r = runTool(requireExe("nix-store"), storeArgs(root) &
    @["--check-validity"] & h.shellRoots)
  r.code == 0

proc zstdForRestore*(h: NixHalf): string =
  ## The host's zstd, else the half's own (realised by store path: one small
  ## download from the binary cache, no evaluation).
  result = uncontrolledFindExe("zstd")
  if result.len > 0: return
  if not fileExists(h.zstd / "bin" / "zstd"):
    discard mustRun(requireExe("nix-store"), ["--realise", h.zstd])
  result = h.zstd / "bin" / "zstd"

type RegisteredPath* = object
  ## One path's entry in a `nix-store --dump-db` registration.
  path*: string
  narHash*: string     ## SHA-256 of the path's NAR serialisation, base16
  entry*: string       ## the entry's lines, as `--load-db` reads them

proc parseRegistration*(db: string): seq[RegisteredPath] =
  ## The `nix-store --dump-db` format, which `--load-db` reads back: per path
  ## the lines `<path>`, `<narHash>` (base16), `<narSize>`, `<deriver>` (may
  ## be empty), `<n>`, then `n` reference lines. See Nix's
  ## `makeValidityRegistration` (src/libstore/store-api.cc).
  ##
  ## Each path must be `/nix/store/<name>`, one store-name component
  ## (`tar_members.nixStorePathProblem`): the registered paths decide where
  ## the half's members may be written, so one that named `/nix/store/..` or
  ## a nested directory would widen that.
  let lines = db.splitLines()
  var i = 0
  while i < lines.len:
    if lines[i].len == 0 and i == lines.len - 1: break
    if i + 4 >= lines.len or not lines[i].startsWith("/nix/store/"):
      bundleFail("malformed Nix half registration at line " & $(i + 1))
    let pathProblem = nixStorePathProblem(lines[i])
    if pathProblem.len > 0:
      bundleFail("malformed Nix half registration at line " & $(i + 1) &
        ": " & pathProblem)
    var n: int
    try: n = parseInt(lines[i + 4])
    except ValueError:
      bundleFail("malformed Nix half registration at line " & $(i + 5))
    if n < 0 or i + 5 + n > lines.len:
      bundleFail("malformed Nix half registration at line " & $(i + 5))
    result.add(RegisteredPath(path: lines[i], narHash: lines[i + 1],
      entry: lines[i ..< i + 5 + n].join("\n") & "\n"))
    i += 5 + n

proc storeLocation(root, path: string): string =
  ## Where store path `path` lives on disk for the store rooted at `root`.
  if root.len == 0 or root == "/": path
  else: root.strip(leading = false, chars = {'/'}) & path

proc invalidPaths(paths: seq[string]; root: string): seq[string] =
  ## The paths among `paths` that the store at `root` does not hold as
  ## valid. Asked 1000 at a time, so a large closure stays well within the
  ## kernel's limit on a command line's length.
  const Chunk = 1000
  var i = 0
  while i < paths.len:
    let batch = paths[i ..< min(i + Chunk, paths.len)]
    for line in mustRun(requireExe("nix-store"), storeArgs(root) &
        @["--check-validity", "--print-invalid"] & batch).splitLines():
      if line.strip().len > 0: result.add(line.strip())
    i += Chunk

proc removeStoreLeftover*(location: string) =
  ## Delete what an interrupted unpack or substitution left at an invalid
  ## store path, as Nix does before it substitutes one. Store directories
  ## are read-only, so they are made writable first; a symlink is removed,
  ## never followed.
  if symlinkExists(location) or fileExists(location):
    removeFile(location)
  elif dirExists(location):
    setFilePermissions(location, getFilePermissions(location) + {fpUserWrite})
    for sub in walkDirRec(location, yieldFilter = {pcDir},
                          followFilter = {pcDir}):
      setFilePermissions(sub, getFilePermissions(sub) + {fpUserWrite})
    removeDir(location)

when defined(posix):
  const LockEx {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint = 2
  const LockSh {.importc: "LOCK_SH", header: "<sys/file.h>".}: cint = 1
  proc cFlock(fd: cint; op: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}

type StoreLock = object
  file: string   ## `<location>.lock`
  fd: cint

proc raiseOpenFileLimit(locks: int) =
  ## Every held lock is an open descriptor, and a large half can need more
  ## than the usual soft limit (1024 on Linux, 256 on macOS). Raise it
  ## towards the hard limit, and refuse up front, naming the count, when
  ## that is still too low. An unlimited hard limit reads as a negative
  ## number on Linux and as a huge one on macOS, where `setrlimit` also
  ## refuses more than `OPEN_MAX`, so a refused raise is retried at 10240.
  when defined(posix):
    let wanted = locks + 64
    var lim: RLimit
    if getrlimit(RLIMIT_NOFILE, lim) != 0: return
    if lim.rlim_cur >= 0 and lim.rlim_cur < wanted:
      let hard = lim.rlim_max
      lim.rlim_cur = (if hard >= 0 and hard < wanted: hard else: wanted)
      if setrlimit(RLIMIT_NOFILE, lim) != 0 and lim.rlim_cur > 10240:
        lim.rlim_cur = 10240
        discard setrlimit(RLIMIT_NOFILE, lim)
      if getrlimit(RLIMIT_NOFILE, lim) == 0 and lim.rlim_cur >= 0 and
          lim.rlim_cur < wanted:
        bundleFail("restoring " & $locks & " store paths holds a lock " &
          "on each, but the open-file limit is " & $lim.rlim_cur &
          "; raise it (ulimit -n) to at least " & $wanted)

proc gcLockFile(root: string): string =
  ## Nix's `gc.lock`, in the store's state directory.
  if root.len == 0 or root == "/":
    let state = getEnv("NIX_STATE_DIR")
    (if state.len > 0: state else: "/nix/var/nix") / "gc.lock"
  else:
    root.strip(leading = false, chars = {'/'}) & "/nix/var/nix/gc.lock"

proc holdGcLock(root: string): cint =
  ## A shared `flock` on `gc.lock`. The garbage collector holds it
  ## exclusively for a whole collection and ignores per-path locks, so
  ## holding it shared keeps a collection from deleting a path, or its lock
  ## file, between the validity re-check and its registration (§7 step
  ## 3.3); a collection already running is waited for.
  when defined(posix):
    let file = gcLockFile(root)
    createDir(file.parentDir)
    result = posix.open(file.cstring, O_RDWR or O_CREAT, 0o600)
    if result < 0:
      bundleFail("cannot open the Nix GC lock " & file & ": " &
        $strerror(errno))
    while cFlock(result, LockSh) != 0:
      if errno != EINTR:
        let reason = $strerror(errno)
        discard posix.close(result)
        bundleFail("cannot lock " & file & ": " & reason)
  else:
    bundleFail("restoring a Nix half needs POSIX file locks")

proc lockStoreLocation(location: string): StoreLock =
  ## Nix's per-path lock (`PathLocks::lockPaths`, src/libstore/unix/
  ## pathlocks.cc): an exclusive `flock` on `<path>.lock`, waiting while
  ## another writer holds it. A holder that deletes its lock file writes a
  ## byte to it first, so a non-empty lock file is stale and is reopened.
  when defined(posix):
    let file = location & ".lock"
    while true:
      let fd = posix.open(file.cstring, O_RDWR or O_CREAT, 0o600)
      if fd < 0:
        bundleFail("cannot open the store lock " & file & ": " &
          $strerror(errno))
      while cFlock(fd, LockEx) != 0:
        if errno != EINTR:
          let reason = $strerror(errno)
          discard posix.close(fd)
          bundleFail("cannot lock " & file & ": " & reason)
      var st: Stat
      if fstat(fd, st) != 0:
        let reason = $strerror(errno)
        discard posix.close(fd)
        bundleFail("cannot stat " & file & ": " & reason)
      if st.st_size == 0:
        return StoreLock(file: file, fd: fd)
      discard posix.close(fd)
  else:
    bundleFail("restoring a Nix half needs POSIX file locks")

proc stillLinked(l: StoreLock): bool =
  ## Whether the lock file is still in the store. The garbage collector
  ## deletes a `<path>.lock` whose path is invalid and no temporary root,
  ## so a lock taken before `gc.lock` may have lost its file.
  when defined(posix):
    var st: Stat
    result = fstat(l.fd, st) == 0 and st.st_nlink > 0
  else:
    result = false

proc release(locks: var seq[StoreLock]) =
  ## Release as Nix releases a lock file it deletes: unlink it, write a
  ## byte so a waiter knows it is stale, close it. A lock file something
  ## else already deleted is only closed: the name may by now be another
  ## writer's lock file.
  when defined(posix):
    for l in locks:
      if l.stillLinked:
        discard posix.unlink(l.file.cstring)
        discard posix.write(l.fd, "d".cstring, 1)
      discard posix.close(l.fd)
  locks.setLen(0)

proc narHashes(locations: seq[string]): seq[string] =
  ## The base16 SHA-256 NAR hash of each location, in order ("" where it
  ## could not be computed), by `nix-hash`, 16 at a time.
  if locations.len == 0: return
  let list = locations.join("\0") & "\0"
  # `sh -c` gets nix-hash as $0 and one location as $1.
  let script = "xargs -0 -P 16 -n 1 sh -c " &
    quoteShell("printf '%s\\t%s\\n' \"$1\" " &
      "\"$(\"$0\" --type sha256 \"$1\" 2>/dev/null)\"") & " " &
    quoteShell(requireExe("nix-hash"))
  var got = initTable[string, string]()
  for line in mustRunShell(script, "hashing the restored store paths",
      stdinData = list).splitLines():
    let tab = line.find('\t')
    if tab > 0: got[line[0 ..< tab]] = line[tab + 1 .. ^1]
  for loc in locations: result.add(got.getOrDefault(loc))

proc nixListingProblem*(listingPath: string;
                        registered: HashSet[string]): string =
  ## "" when every member of the archive listed in `listingPath` may be
  ## written by a Nix half whose registration names `registered` (relative
  ## `nix/store/<name>`): it passes the rules every half applies
  ## (`tar_members.admit`, `finish`), and it and any hard link's target lie
  ## inside a registered path. Otherwise the reason, naming the member.
  var members = initMemberSet()
  try:
    for (_, m) in listingMembers(listingPath):
      var problem = members.admit(m)
      if problem.len == 0:
        problem = nixMemberProblem(memberPath(m), registered)
      if problem.len == 0 and m.kind == 'h':
        problem = nixMemberProblem(m.linkTarget, registered)
        if problem.len > 0:
          problem = "hard link " & m.name.escape & ": its target " & problem
      if problem.len > 0:
        return problem
  except ValueError as e:
    return e.msg
  members.finish()

proc restoreLockedPaths(h: NixHalf; partsDir, scratch, root, target,
    zstdExe: string; registered: seq[RegisteredPath];
    invalid: HashSet[string]) =
  ## §7 steps 3.4 to 3.7, for the paths in `invalid`, whose locks are held.
  ## `scratch` is the restore's private directory (`restoreNixHalf`).
  for r in registered:
    if r.path in invalid: removeStoreLeftover(storeLocation(root, r.path))
  # Every registered path that is valid is Nix's: tar adds nothing to it.
  var skip = ""
  for r in registered:
    if r.path notin invalid: skip.add(r.path.strip(chars = {'/'},
      trailing = false) & "\n")
  let excludes = scratch / "exclude"
  writeFile(excludes, skip)
  let errPath = scratch / "unpack.stderr"
  # A NAR hash covers a file's executable bit and nothing else of its mode
  # or owner, so tar applies neither from the archive (§7 step 3.5).
  let command = "set -o pipefail; " & NixExtractModeShell & "(" &
    quoteShell(zstdExe) & " -q -dc --long=" & $ZstdWindowLog & " - | " &
    quoteShell(requireExe("tar")) & " -C " & quoteShell(target) &
    ExtractModeOptions & " --skip-old-files --anchored --no-wildcards -X " &
    quoteShell(excludes) & " -xf -) >" & quoteShell(errPath) & " 2>&1"
  if feedParts(partsDir, h.parts, command, stopEarly = false) != 0:
    bundleFail("unpacking the Nix half failed: " &
      (if fileExists(errPath): readFile(errPath).strip() else: ""))
  var restored: seq[RegisteredPath]
  var locations: seq[string]
  for r in registered:
    if r.path in invalid:
      restored.add(r)
      locations.add(storeLocation(root, r.path))
  # Canonical modes before the hash check, so what is checked is what is
  # registered. A store path that is a symlink is left alone: chmod would
  # follow it, and `-R` does not follow the links it meets below an operand.
  var toCanonicalise: seq[string]
  for loc in locations:
    if not symlinkExists(loc) and (dirExists(loc) or fileExists(loc)):
      toCanonicalise.add(loc)
  const ChmodBatch = 512
  var i = 0
  while i < toCanonicalise.len:
    discard mustRun(requireExe("chmod"), @["-R", NixCanonicalModes, "--"] &
      toCanonicalise[i ..< min(toCanonicalise.len, i + ChmodBatch)])
    i += ChmodBatch
  let actual = narHashes(locations)
  var mismatched: seq[string]
  for i, r in restored:
    if actual[i] != r.narHash:
      mismatched.add(r.path & ": the registration says sha256 " & r.narHash &
        ", the unpacked content hashes to " &
        (if actual[i].len > 0: actual[i] else: "nothing (unreadable)"))
      removeStoreLeftover(locations[i])
  if mismatched.len > 0:
    bundleFail("the Nix half's content does not match its registration, " &
      "so nothing was registered:\n  " & mismatched.join("\n  "))
  var db = ""
  for r in restored: db.add(r.entry)
  if db.len > 0:
    discard mustRun(requireExe("nix-store"), storeArgs(root) & @["--load-db"],
      stdinData = db)

proc restoreNixHalf*(h: NixHalf; partsDir: string; root = "/") =
  ## §7 step 3. Before anything is locked, written or removed, the archive
  ## is listed with the tar that will extract it, over the same verified
  ## parts, and refused unless every member lies inside a store path the
  ## registration names (`nixListingProblem`).
  ##
  ## Only the half's *invalid* paths are restored; a valid path
  ## is Nix's, and is neither rewritten nor re-registered. Each invalid
  ## path's Nix lock (`<path>.lock`) is taken, in sorted order, and held
  ## until registration; validity is checked again under the locks, and a
  ## path another Nix writer made valid meanwhile is left to it and
  ## excluded from extraction (§7 step 3.3). A shared lock on Nix's
  ## `gc.lock`, taken after the path locks, is held until registration, so
  ## no garbage collection deletes a path being restored. Whatever an
  ## interrupted unpack or substitution left at an invalid path is deleted
  ## first, so `--skip-old-files` can never keep a truncated file. The
  ## verified parts are then unpacked, each restored path's NAR hash must
  ## match its registration, and only then are those paths registered. A
  ## run killed at any point leaves them invalid, and the next run starts
  ## them over.
  ##
  ## Every file the restore writes for itself (the member listing, the
  ## exclude list, tar's diagnostics) goes into a private directory
  ## (`privateScratchDir`), never beside the parts, which are only read.
  let zstdExe = zstdForRestore(h)
  let scratch = privateScratchDir("repro-bundle-nix-")
  defer: removeScratchDir(scratch)
  let target = (if root.len > 0: root else: "/")
  createDir(target)
  let reg = readVerifiedPart(partsDir, h.registration)
  let registered = parseRegistration(mustRunShell(quoteShell(zstdExe) &
    " -q -dc", "decompressing the registration", stdinData = reg))
  var paths: seq[string]
  var names = initHashSet[string]()
  for r in registered:
    paths.add(r.path)
    names.incl(r.path[1 .. ^1])
  # Before anything is locked, removed or written: list the archive with
  # the tar that will extract it, over the same verified parts, and refuse
  # unless every member lies inside a registered path. The part hashes come
  # from the same unsigned manifest as the parts, so they cannot confine
  # the unpack.
  block:
    let listing = scratch / "members"
    try:
      listBundleMembers(partsDir, h.parts, listing, zstdExe)
    except StoreBundleError as e:
      bundleFail("cannot check the Nix half: " & e.msg)
    let problem = nixListingProblem(listing, names)
    removeFile(listing)
    if problem.len > 0:
      bundleFail("refusing the Nix half before restoring it: " & problem &
        "; nothing was written")
  var gcLock: cint = -1
  var locks: seq[StoreLock]
  try:
    var candidates = invalidPaths(paths, root).deduplicate()
    candidates.sort()
    # Path locks first, then `gc.lock`: Nix holds a path lock while it
    # waits for a collection (`addToStore` calls `autoGC`), so waiting for
    # a path lock while holding `gc.lock` could deadlock with it. A
    # collection that ran while the path locks were taken may have deleted
    # a lock file, or a path that was valid and so is not locked; then
    # everything is let go and taken again, for every path now invalid.
    # The lock descriptors are inherited by the tar and nix-store children,
    # so a killed restore's locks last until its writers have exited too.
    var invalid: HashSet[string]
    while true:
      if candidates.len > 0:
        createDir(storeLocation(root, "/nix/store"))
        raiseOpenFileLimit(candidates.len)
      for p in candidates:
        locks.add(lockStoreLocation(storeLocation(root, p)))
      # Nothing invalid means nothing is written, so a no-op rerun stays
      # read-only and needs no access to a root-owned `gc.lock`.
      if candidates.len > 0: gcLock = holdGcLock(root)
      var intact = true
      for l in locks:
        if not l.stillLinked: intact = false
      let now = invalidPaths(paths, root)
      invalid = now.toHashSet()
      let locked = candidates.toHashSet()
      if intact and invalid <= locked: break
      release(locks)
      when defined(posix):
        if gcLock >= 0: discard posix.close(gcLock)
      gcLock = -1
      candidates = (locked + invalid).toSeq()
      candidates.sort()
    restoreLockedPaths(h, partsDir, scratch, root, target, zstdExe,
      registered, invalid)
  finally:
    release(locks)
    when defined(posix):
      if gcLock >= 0: discard posix.close(gcLock)
  if not h.nixHalfPresent(root):
    bundleFail("the Nix half's registration did not make every shell root " &
      "valid")
