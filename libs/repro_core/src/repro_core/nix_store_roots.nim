## Nix GC roots for what reprobuild leaves behind: working-tree build outputs
## and recorded tool realizations.
##
## ## Why this module exists
##
## A store path survives `nix-collect-garbage` / `nix store gc` only while a
## GC root reaches it. Before this module the only root reprobuild created was
## the dev-shell profile (`nix print-dev-env --profile`, see
## `repro_dsl_stdlib/foreign_env/flake.nim`). That profile roots THE SHELL at
## the generation it was written; it does not root
##
## * the store paths a working-tree build output names — a linked binary's
##   `LC_LOAD_DYLIB` / `DT_NEEDED` / RPATH entries, a generated script's
##   `#!`, a receipt that records a realized path — which can be a different
##   version from anything any retained profile generation holds; nor
## * the paths `resolveNixTool` realizes with `nix build --no-link` and then
##   records in `nix-store-path.txt` and the materialization cache.
##
## A collection then deletes them while the output or the record survives,
## and the next build reports an unrunnable artifact as up to date
## (reprobuild-pm issue 2026-10-02, "the dev-env profile gcroot covers the
## shell but not the libraries a working-tree build output links").
##
## ## What it does
##
## 1. `scanStoreReferences` finds the store paths an output names, the same
##    way Nix decides what a store path references: by looking for the store
##    path's text in the bytes (Nix's `RefScanSink`, see
##    https://github.com/NixOS/nix/blob/master/src/libstore/references.cc).
##    Nix scans for the 32-character hash parts of a KNOWN candidate set; an
##    output in the working tree has no candidate set, so this scans for the
##    full `<storeDir>/<hash>-<name>` shape instead. Pure Nim, streamed in
##    chunks, no subprocess.
## 2. The roots themselves are INDIRECT roots: a symlink reprobuild owns,
##    registered with Nix by `nix-store --realise --add-root <link> <path>…`
##    (https://nix.dev/manual/nix/latest/command-ref/nix-store/realise and
##    https://nix.dev/manual/nix/latest/package-management/garbage-collector-roots).
##    Nix records the LINK under `/nix/var/nix/gcroots/auto/`; deleting the
##    link is therefore all it takes to drop the root, and Nix forgets a
##    dangling auto-root by itself on its next root scan.
## 3. Two layouts are built on that primitive:
##
##    * `rootStorePaths(rootDir, paths)` — an EXACT root set per directory,
##      used for one tool realization at a time;
##    * a **root ledger** (`recordOutputRoots` / `ledgerMissingStorePaths` /
##      `pruneStaleRoots`) for the build engine: one manifest per action
##      under `<ledger>/actions/`, ONE shared pool of root links under
##      `<ledger>/store/` (one link per distinct store path), and an index
##      summarising every manifest in one file (`NixLedgerIndex`) so a warm
##      build does not read a manifest per action.
##
## ## Why the engine's roots are pooled rather than per action
##
## Measured on aarch64-darwin, Determinate Nix 2.33, 2026-10-14: one
## `nix-store --realise --add-root` round trip costs 85–135 ms. Nearly every
## object file of a C project built against Nix names store paths (debug info
## carries header paths), so one registration per ACTION would add minutes to
## a cold build of a few thousand objects. Those actions name the same few
## dozen store paths between them, so registering once per distinct PATH,
## into a pool the per-action manifests share, costs a handful of round trips
## per project and none at all once warm. The manifest is still per action,
## which is what pruning and the "a referenced path is gone" check need.
##
## ## Failure policy
##
## Rooting is protection, not correctness of the build that just ran: the
## output that was produced is the output the action declared, whether or not
## Nix agreed to root what it names. So a failure to root RAISES
## `NixStoreRootError` and callers turn it into a visible diagnostic (the
## engine traces it) instead of failing the build. What IS a correctness
## question — "does an output still have every store path it named when it
## was produced?" — is answered by the manifest alone, with one `lstat` per
## path, and does not depend on rooting having succeeded.
##
## On a host with no Nix store directory every operation here is a no-op.

import std/[algorithm, os, osproc, sets, strtabs, strutils, tables, times]
when defined(posix):
  import std/posix

import ./ambient_execution
import ./paths

const
  NixBase32Alphabet* = "0123456789abcdfghijklmnpqrsvwxyz"
    ## Nix's base-32 alphabet: digits and lowercase letters WITHOUT `e`, `o`,
    ## `t` and `u` (`nix-store --help`; `src/libutil/hash.cc`, `base32Chars`).
  NixStoreHashLen* = 32
    ## Characters in the hash part of a store path (160 bits, base-32).
  NixStoreNameMaxLen* = 211
    ## Nix refuses a store path name longer than this (`checkName`,
    ## `src/libstore/path.cc`), so a longer run is not a store path.
  ScanChunkSize = 1 shl 20
    ## Bytes read per `readBuffer`. Large enough that a big output is read in
    ## few syscalls, small enough to keep the resident cost flat.
  ManifestHeader = "# reprobuild nix-gc-roots manifest v1"
  ExactRootManifestName* = "refs.txt"
    ## The manifest `rootStorePaths` keeps beside its links.
  LedgerActionsDirName* = "actions"
  LedgerPoolDirName* = "store"
  ManifestSuffix* = ".refs"
  LedgerIndexName* = "index.txt"
    ## The ledger's one-file summary of every manifest; see `NixLedgerIndex`.
  IndexHeader = "# reprobuild nix-gc-roots index v1"

type
  NixStoreRootError* = object of CatchableError
    ## Rooting failed (no `nix-store`, or it exited non-zero). Never a reason
    ## to fail the build that produced the output; see "Failure policy".

  NixRootOutcome* = object
    ## What a rooting call did, for diagnostics and for tests.
    rooted*: seq[string]
      ## Store paths that now have a root in the target directory.
    absent*: seq[string]
      ## Requested paths that are not in the store. Nothing can root them.
    registered*: int
      ## Paths newly registered with Nix by this call (0 on a warm call).
    nixStoreCalls*: int
      ## `nix-store` invocations this call made (0 on a warm call).

  NixRootsManifest* = object
    ## One manifest: which outputs it covers and which store paths they name.
    label*: string
      ## Free text identifying the owner (an action id, a tool selector).
    outputs*: seq[string]
      ## Absolute paths of the outputs that were scanned.
    refs*: seq[string]
      ## Store paths the outputs named that EXISTED when the manifest was
      ## written. Only these can be "lost": a path that was already absent
      ## when the output was produced is not one the output depends on
      ## having, and listing it here would re-execute the producer forever.
    absentAtRecord*: seq[string]
      ## Store paths the outputs named that did NOT exist when the manifest
      ## was written. Diagnostic only.

# ---------------------------------------------------------------------------
# Store directory and path existence
# ---------------------------------------------------------------------------

proc nixStoreDir*(): string =
  ## The store directory: `NIX_STORE_DIR` when set (Nix honours it the same
  ## way), otherwise `/nix/store`. Returned without a trailing separator.
  result = getEnv("NIX_STORE_DIR", "/nix/store")
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc storePathExists*(path: string): bool =
  ## Does `path` exist, WITHOUT following a symlink (a store path may itself
  ## be a symlink, and a dangling one is still a valid store object)? One
  ## `lstat`. Any error other than "no such entry" counts as present: an
  ## unreadable path is not evidence that it was collected.
  when defined(posix):
    var st: Stat
    if lstat(path.cstring, st) == 0:
      return true
    return errno != ENOENT and errno != ENOTDIR
  else:
    symlinkExists(extendedPath(path)) or fileExists(extendedPath(path)) or
      dirExists(extendedPath(path))

proc isUnderStoreDir(path, storeDir: string): bool =
  path.startsWith(storeDir & "/") and path.len > storeDir.len + 1

proc isRootableStorePath*(path, storeDir: string): bool =
  ## A store path this module roots and tracks: under the store, and NOT a
  ## derivation (`.drv`).
  ##
  ## A derivation is excluded because `nix-store --realise <x>.drv` does not
  ## root the `.drv` — it BUILDS the derivation and roots its outputs
  ## (https://nix.dev/manual/nix/latest/command-ref/nix-store/realise). An
  ## output that merely mentions a `.drv` (a build log, a nix-generated
  ## script) would therefore start a build of that derivation on every
  ## scan, and since the root that appears names an output path rather than
  ## the `.drv`, it would never look rooted and would be re-registered —
  ## and rebuilt — by every action that mentions it. Measured before this
  ## filter: a 2,000-action graph whose outputs each named one `.drv` took
  ## 501 s cold instead of 11 s. A derivation is a build recipe, not
  ## something a working-tree artifact needs at run time, so it is neither
  ## rooted nor counted as "lost".
  path.isUnderStoreDir(storeDir) and not path.endsWith(".drv")

# ---------------------------------------------------------------------------
# Reference scanning
# ---------------------------------------------------------------------------

proc isNixBase32Char(c: char): bool {.inline.} =
  c in {'0' .. '9', 'a' .. 'd', 'f' .. 'n', 'p' .. 's', 'v' .. 'z'}

proc isStoreNameChar(c: char): bool {.inline.} =
  ## Nix's store path name alphabet (`checkName`, `src/libstore/path.cc`).
  c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '+', '-', '.', '_', '?', '='}

type StoreRefScanner = object
  prefix: string          ## `<storeDir>/`
  storeDir: string
  found: HashSet[string]

proc maxMatchLen(s: StoreRefScanner): int {.inline.} =
  ## The longest byte run one match can span, plus one byte to see that the
  ## name ended. A carry this long guarantees a match cut by a chunk boundary
  ## is seen whole in the next buffer.
  s.prefix.len + NixStoreHashLen + 1 + NixStoreNameMaxLen + 1

proc scanBuffer(s: var StoreRefScanner; buf: string; final: bool): int =
  ## Record every complete store path in `buf`. Returns the index the NEXT
  ## buffer must start from (everything before it is fully decided); with
  ## `final` the whole buffer is decided and the result is `buf.len`.
  ##
  ## A candidate is `<prefix><32 base-32 chars>-<1..211 name chars>`. The
  ## name is the maximal run of name characters, which is how a store path
  ## ends inside a longer path (`…-openssl-3.5.8/lib/libssl.3.dylib`), a
  ## C string (NUL) or text (space, quote, newline).
  var pos = 0
  var undecided = -1
  while pos < buf.len:
    let i = buf.find(s.prefix, pos)
    if i < 0:
      break
    let hashStart = i + s.prefix.len
    if hashStart + NixStoreHashLen + 1 > buf.len:
      # The candidate's hash runs past the buffer: decide it next time.
      if not final:
        undecided = i
      break
    var ok = true
    for k in hashStart ..< hashStart + NixStoreHashLen:
      if not isNixBase32Char(buf[k]):
        ok = false
        break
    if not ok or buf[hashStart + NixStoreHashLen] != '-':
      pos = i + 1
      continue
    let nameStart = hashStart + NixStoreHashLen + 1
    var nameEnd = nameStart
    while nameEnd < buf.len and isStoreNameChar(buf[nameEnd]) and
        nameEnd - nameStart <= NixStoreNameMaxLen:
      inc nameEnd
    if nameEnd == buf.len and not final:
      # The name may continue in the next chunk.
      undecided = i
      break
    let nameLen = nameEnd - nameStart
    if nameLen >= 1 and nameLen <= NixStoreNameMaxLen and buf[nameStart] != '.':
      s.found.incl(s.storeDir & "/" & buf[hashStart ..< nameEnd])
    pos = nameEnd
  if final:
    return buf.len
  # Keep enough of the tail that a prefix cut by the boundary is re-seen; an
  # undecided candidate pins the carry to its own start.
  let tailStart = max(0, buf.len - (s.prefix.len - 1))
  if undecided >= 0: min(undecided, tailStart) else: tailStart

proc scanFile(s: var StoreRefScanner; path: string) =
  var f: File
  if not open(f, extendedPath(path), fmRead):
    return  # Unreadable: nothing this scan can learn from it.
  defer: close(f)
  let carryCap = s.maxMatchLen()
  var buf = newString(carryCap + ScanChunkSize)
  var carry = 0
  while true:
    let got = f.readBuffer(addr buf[carry], ScanChunkSize)
    let filled = carry + max(got, 0)
    let atEof = got < ScanChunkSize
    buf.setLen(filled)
    let keepFrom = s.scanBuffer(buf, atEof)
    if atEof:
      break
    # Move the undecided tail to the front; it is at most `carryCap` bytes
    # because `scanBuffer` never pins the carry further back than one match.
    carry = filled - keepFrom
    if carry > carryCap:
      carry = carryCap
    if carry > 0:
      moveMem(addr buf[0], addr buf[filled - carry], carry)
    buf.setLen(carryCap + ScanChunkSize)

proc isRegularFile(path: string): bool =
  ## Only regular files are opened: a FIFO or a device in an output tree
  ## would block or stream forever.
  when defined(posix):
    var st: Stat
    lstat(path.cstring, st) == 0 and S_ISREG(st.st_mode)
  else:
    fileExists(extendedPath(path)) and not symlinkExists(extendedPath(path))

proc scanPath(s: var StoreRefScanner; path: string) =
  ## Files are read; directories are walked; a symlink is NOT followed (it
  ## may point anywhere, including back into the store or out of the output
  ## tree), but its TARGET STRING is scanned — a symlink into the store is
  ## the plainest reference an output can carry.
  if symlinkExists(extendedPath(path)):
    try:
      discard s.scanBuffer(expandSymlink(extendedPath(path)), final = true)
    except OSError:
      discard
  elif dirExists(extendedPath(path)):
    for kind, child in walkDir(extendedPath(path), relative = false,
                               checkDir = false):
      case kind
      of pcLinkToFile, pcLinkToDir, pcDir:
        s.scanPath(child)
      of pcFile:
        if isRegularFile(child):
          s.scanFile(child)
  elif isRegularFile(path):
    s.scanFile(path)

proc resolveScannedStorePath(path, storeDir: string): string =
  ## `path` as scanned (`<storeDir>/<hash>-<maximal name run>`), or, when that
  ## spelling does not exist, the longest existing `<storeDir>/<hash>-<prefix
  ## of the name>`. See `scanStoreReferences` for why the name's end is a
  ## guess. One `lstat` for a path that exists, which is the common case.
  if storePathExists(path):
    return path
  let nameStart = storeDir.len + 1 + NixStoreHashLen + 1
  for nameEnd in countdown(path.len - 1, nameStart + 1):
    let candidate = path[0 ..< nameEnd]
    if storePathExists(candidate):
      return candidate
  path

proc scanStoreReferences*(paths: openArray[string];
                          storeDir = nixStoreDir()): seq[string] =
  ## The distinct top-level store paths (`<storeDir>/<hash>-<name>`, cut at
  ## the first `/` after the store entry) that the bytes of `paths` name,
  ## sorted. A path that does not exist contributes nothing.
  ##
  ## Existence of the FOUND paths is not checked here: an output may name a
  ## store path that never existed on this host (a log quoting another
  ## machine's path), and only the caller knows what that means for it.
  ##
  ## WITH ONE EXCEPTION, the name's END. The text gives no reliable end for a
  ## name: a store path serialized without a terminator (a length-prefixed
  ## string in a binary artifact, such as a provider's `.rbsz`) is followed
  ## by whatever byte comes next, and when that byte is a name character the
  ## maximal run overshoots: `…-source` followed by a length byte `'9'`
  ## scans as `…-source9`, which exists nowhere. Nix itself identifies a
  ## reference by its HASH alone (`RefScanSink`), so the hash is the fact
  ## and the name is the guess. When the maximal spelling is absent, the
  ## longest PREFIX of its name that is an existing store entry under the
  ## same hash is the reference. Only when no prefix exists is the maximal
  ## spelling kept, as before. Without this the false spelling was recorded
  ## as absent, and an output scanned with no ledger manifest (a shared
  ## recipe-compile output reached from another copy of the recipe) was
  ## judged to have LOST a store path and re-executed on every copy.
  var s = StoreRefScanner(prefix: storeDir & "/", storeDir: storeDir,
    found: initHashSet[string]())
  for path in paths:
    s.scanPath(path)
  var resolved = initHashSet[string]()
  for p in s.found:
    resolved.incl(resolveScannedStorePath(p, storeDir))
  for p in resolved:
    result.add(p)
  result.sort()

# ---------------------------------------------------------------------------
# Registering roots with Nix
# ---------------------------------------------------------------------------

proc resolveNixStoreExe*(explicit = ""): string =
  ## The `nix-store` to register roots with, or "" when the host has none.
  ##
  ## Next to the `nix` reprobuild already runs for nix work — the one
  ## `REPRO_FOREIGN_ENV_NIX` names, as `resolveNixExe` in
  ## `foreign_env/flake.nim` honours it, else the first `nix` on PATH — and
  ## only then any `nix-store` on PATH. The roots must be registered with the
  ## SAME store daemon that store's `nix` talks to.
  ##
  ## Symlinks are NOT followed: `nix-store` is a symlink to the multi-call
  ## `nix` binary, which dispatches on `argv[0]`; resolving through the link
  ## yields a `nix` that answers `--realise` with "unrecognised flag".
  ##
  ## Uncontrolled deliberately, for the reason `resolveNixExe` gives: this
  ## talks to the developer's own Nix about the developer's own store, and no
  ## execution profile exists — or could — for the store's garbage collector.
  if explicit.len > 0:
    return explicit
  for nix in [getEnv("REPRO_FOREIGN_ENV_NIX"),
              uncontrolledFindExe("nix", followSymlinks = false)]:
    if nix.len == 0:
      continue
    let sibling = parentDir(nix) / "nix-store"
    if fileExists(sibling):
      return sibling
  uncontrolledFindExe("nix-store", followSymlinks = false)

proc hostNixEnvironment(): StringTableRef =
  ## The caller's environment minus loader controls. A build may run with a
  ## provisioned profile's `LD_LIBRARY_PATH` / `DYLD_*` exported, and Nix is
  ## a host bootstrap tool that must not load those libraries (the same
  ## reason `repro_tool_profiles.hostToolEnvironment` drops them).
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    case key
    of "LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT", "LD_DEBUG",
       "LD_DEBUG_OUTPUT", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
       "DYLD_INSERT_LIBRARIES":
      discard
    else:
      result[key] = value

var rootNameCounter {.threadvar.}: int

proc freshRootName(dir: string): string =
  ## A link name no earlier registration in `dir` used. `nix-store` names the
  ## roots of a multi-path call `<name>`, `<name>-2`, `<name>-3`, … (it
  ## appends `-<n>` from the second path on), so the base must be unique and
  ## must not end in `-<digits>` itself.
  inc rootNameCounter
  result = "r" & $getCurrentProcessId() & "x" &
    $int64(epochTime() * 1_000_000.0) & "x" & $rootNameCounter
  while symlinkExists(dir / result) or fileExists(dir / result):
    inc rootNameCounter
    result = result & "y" & $rootNameCounter

proc registerRoots(dir: string; storePaths: openArray[string];
                   nixStore: string): int =
  ## Register indirect roots in `dir` for `storePaths` with ONE `nix-store`
  ## call. Returns the number of calls made (0 or 1).
  if storePaths.len == 0:
    return 0
  let exe = resolveNixStoreExe(nixStore)
  if exe.len == 0:
    raise newException(NixStoreRootError,
      "cannot register Nix GC roots for " & $storePaths.len &
      " store path(s): no nix-store next to nix and none on PATH")
  createDir(extendedPath(dir))
  var cmd = quoteShell(exe) & " --realise --add-root " &
    quoteShell(absolutePath(dir) / freshRootName(dir))
  for p in storePaths:
    cmd.add(" " & quoteShell(p))
  let res = uncontrolledExecCmdEx(cmd, options = {poStdErrToStdOut},
    env = hostNixEnvironment())
  if res.exitCode != 0:
    raise newException(NixStoreRootError,
      "nix-store --realise --add-root exited " & $res.exitCode &
      " registering GC roots under " & dir & ": " & res.output.strip())
  1

# ---------------------------------------------------------------------------
# A directory of root links
# ---------------------------------------------------------------------------

type RootLinks = object
  dir: string
  byTarget: seq[tuple[link, target: string]]

proc readRootLinks(dir: string; storeDir: string): RootLinks =
  ## The root links in `dir`: every symlink whose target is under the store.
  ## Anything else in the directory (a manifest, a stray file) is not a root.
  result.dir = dir
  if not dirExists(extendedPath(dir)):
    return
  for kind, child in walkDir(extendedPath(dir), relative = false,
                             checkDir = false):
    if kind notin {pcLinkToFile, pcLinkToDir}:
      continue
    try:
      let target = expandSymlink(child)
      if target.isUnderStoreDir(storeDir):
        result.byTarget.add((link: child, target: target))
    except OSError:
      discard

proc targets(links: RootLinks): HashSet[string] =
  result = initHashSet[string]()
  for item in links.byTarget:
    result.incl(item.target)

proc addRoots(dir: string; storePaths: openArray[string]; nixStore: string;
              storeDir: string): NixRootOutcome =
  ## Make every EXISTING path in `storePaths` rooted in `dir`, registering
  ## only the ones not already rooted there. Never removes a root.
  var wanted: seq[string] = @[]
  var seen = initHashSet[string]()
  for p in storePaths:
    if p in seen or not p.isRootableStorePath(storeDir):
      continue
    seen.incl(p)
    if storePathExists(p):
      wanted.add(p)
    else:
      result.absent.add(p)
  if wanted.len == 0:
    return
  let have = readRootLinks(dir, storeDir).targets()
  var missing: seq[string] = @[]
  for p in wanted:
    if p notin have:
      missing.add(p)
  if missing.len == 0:
    # The warm case: everything is already rooted here, and nothing below
    # (a registration, a second listing) has anything to add.
    result.rooted = wanted
    return
  if missing.len > 0:
    try:
      result.nixStoreCalls += registerRoots(dir, missing, nixStore)
    except NixStoreRootError:
      # A path can vanish between the `lstat` above and the call, and
      # `--realise` then tries to (re)build it. Retry once with what still
      # exists, so one collected path does not cost the others their roots.
      var still: seq[string] = @[]
      for p in missing:
        if storePathExists(p):
          still.add(p)
        else:
          result.absent.add(p)
      if still.len == missing.len:
        raise
      result.nixStoreCalls += registerRoots(dir, still, nixStore)
      missing = still
    result.registered = missing.len
  let now = readRootLinks(dir, storeDir).targets()
  for p in wanted:
    if p in now:
      result.rooted.add(p)
  for p in wanted:
    if p notin now and storePathExists(p):
      raise newException(NixStoreRootError,
        "nix-store reported success but no root for " & p & " appeared in " &
        dir)

proc removeUnkept(links: RootLinks; keep: HashSet[string]): int =
  ## Remove every link in `links` whose target is not in `keep`, and every
  ## duplicate link to one target. Returns the number removed. Removing the
  ## link IS dropping the root: Nix's auto-root entry for it then dangles and
  ## Nix discards it on its next root scan.
  var kept = initHashSet[string]()
  for item in links.byTarget:
    if item.target notin keep or item.target in kept:
      try:
        removeFile(item.link)
        inc result
      except OSError:
        discard
    else:
      kept.incl(item.target)

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------

proc encodeManifest(m: NixRootsManifest): string =
  result = ManifestHeader & "\n"
  result.add("label\t" & m.label.replace('\n', ' ').replace('\t', ' ') & "\n")
  for o in m.outputs:
    result.add("output\t" & o & "\n")
  for r in m.refs:
    result.add("ref\t" & r & "\n")
  for r in m.absentAtRecord:
    result.add("absent\t" & r & "\n")

proc readNixRootsManifest*(path: string): tuple[found: bool;
                                              manifest: NixRootsManifest] =
  ## Read a manifest. `found` is false when there is none or it is not one
  ## this version wrote (an unknown header is treated as absent, so a future
  ## format is re-recorded rather than misread).
  var text: string
  try:
    text = readFile(extendedPath(path))
  except IOError, OSError:
    return
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != ManifestHeader:
    return
  result.found = true
  for line in lines[1 .. ^1]:
    let tab = line.find('\t')
    if tab <= 0:
      continue
    let value = line[tab + 1 .. ^1]
    case line[0 ..< tab]
    of "label": result.manifest.label = value
    of "output": result.manifest.outputs.add(value)
    of "ref": result.manifest.refs.add(value)
    of "absent": result.manifest.absentAtRecord.add(value)
    else: discard

proc writeNixRootsManifest*(path: string; m: NixRootsManifest) =
  ## Write a manifest atomically (temp sibling + rename), so a concurrent
  ## reader sees the old manifest or the new one and never half of either.
  ##
  ## An identical manifest is left alone. An action re-executed into the
  ## same references is the common case, and not rewriting it is both
  ## cheaper (a read instead of a write and a rename) and what keeps the
  ## ledger index (`NixLedgerIndex`) valid across that build: every rename
  ## into the directory moves the stamp the index is checked against.
  let text = encodeManifest(m)
  try:
    if readFile(extendedPath(path)) == text:
      return
  except IOError, OSError:
    discard
  createDir(extendedPath(parentDir(path)))
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  writeFile(extendedPath(tmp), text)
  moveFile(extendedPath(tmp), extendedPath(path))

proc missingStorePaths*(manifest: NixRootsManifest): seq[string] =
  ## The manifest's `refs` that no longer exist. One `lstat` each.
  for r in manifest.refs:
    if not storePathExists(r):
      result.add(r)

proc missingStorePaths*(manifestPath: string): seq[string] =
  ## `missingStorePaths` of the manifest at `manifestPath`; empty when there
  ## is none.
  let read = readNixRootsManifest(manifestPath)
  if read.found:
    result = read.manifest.missingStorePaths()

# ---------------------------------------------------------------------------
# Exact root sets (tool realizations)
# ---------------------------------------------------------------------------

proc rootStorePaths*(rootDir: string; storePaths: openArray[string];
                     label = ""; nixStore = "";
                     storeDir = nixStoreDir()): NixRootOutcome =
  ## Make `rootDir` hold exactly the GC roots for the existing paths among
  ## `storePaths`, and record them in `rootDir/refs.txt`.
  ##
  ## WARM CALLS RUN NO SUBPROCESS: when every wanted path already has a link
  ## in `rootDir`, the only cost is one directory listing. New paths are
  ## registered with one `nix-store` call. Stale links are removed only
  ## AFTER the new ones are registered, so a path in both the old and the new
  ## set is never unrooted in between. Raises `NixStoreRootError` when the
  ## registration fails; a no-op on a host without a store directory.
  if not dirExists(storeDir):
    return
  result = addRoots(rootDir, storePaths, nixStore, storeDir)
  var keep = initHashSet[string]()
  for p in result.rooted:
    keep.incl(p)
  discard readRootLinks(rootDir, storeDir).removeUnkept(keep)
  var m = NixRootsManifest(label: label, refs: result.rooted,
    absentAtRecord: result.absent)
  m.refs.sort()
  m.absentAtRecord.sort()
  let manifestPath = rootDir / ExactRootManifestName
  let prior = readNixRootsManifest(manifestPath)
  if not prior.found or prior.manifest.refs != m.refs or
      prior.manifest.absentAtRecord != m.absentAtRecord or
      prior.manifest.label != m.label:
    writeNixRootsManifest(manifestPath, m)

# ---------------------------------------------------------------------------
# The root ledger (build outputs)
# ---------------------------------------------------------------------------

proc ledgerKey*(owner: string; scope = ""): string =
  ## A filesystem-safe, collision-resistant manifest name for `owner` (an
  ## action id) within `scope` (its working directory): a readable prefix of
  ## the id plus a 64-bit FNV-1a digest of both. The digest is what makes
  ## the name unique; the prefix is only for a human reading the directory.
  var h = 0xcbf29ce484222325'u64
  for c in scope & "\0" & owner:
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  var readable = ""
  for c in owner:
    if readable.len >= 48:
      break
    readable.add(if c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '.', '_', '-'}:
      c else: '_')
  readable & "-" & toHex(h, 16).toLowerAscii()

proc ledgerManifestPath*(ledgerDir, key: string): string =
  ledgerDir / LedgerActionsDirName / (key & ManifestSuffix)

proc ledgerPoolDir*(ledgerDir: string): string =
  ledgerDir / LedgerPoolDirName

proc recordOutputRoots*(ledgerDir, key, label: string;
                        outputs: openArray[string]; nixStore = "";
                        storeDir = nixStoreDir();
                        absentIsLost = false): NixRootOutcome =
  ## Scan `outputs` (absolute paths), write the action's manifest, and make
  ## sure every store path they name that exists has a root in the shared
  ## pool. Replaces any earlier manifest for `key`; the pool links an earlier
  ## manifest needed and this one does not are dropped by `pruneStaleRoots`.
  ##
  ## `absentIsLost` says what an ABSENT referenced path means. Scanning
  ## outputs the caller has just produced (executed or restored), it means
  ## the producer itself named a path this host does not have; re-executing
  ## cannot change that, so it is recorded as `absentAtRecord` and never
  ## reported lost. Scanning outputs that were ALREADY in the working tree
  ## and have no manifest (produced before the ledger existed, or by a run
  ## that could not write one), it is the opposite: the output was produced
  ## while the path existed and the path has since been collected — the very
  ## case reprobuild-pm issue 2026-10-02 observed. With `absentIsLost` such a
  ## path is recorded in `refs`, so `missingStorePaths` reports it until a
  ## re-execution replaces the manifest.
  ##
  ## The manifest is written BEFORE the pool roots are added. A concurrent
  ## `pruneStaleRoots` lists the pool first and reads manifests second, so a
  ## link this call adds is either not yet listed (and left alone) or listed
  ## after this manifest already names it (and kept).
  ##
  ## Raises `NixStoreRootError` when registration fails; the manifest is
  ## written regardless, so the "lost a store path" check still works.
  let refs = scanStoreReferences(outputs, storeDir)
  var m = NixRootsManifest(label: label, outputs: @outputs)
  for r in refs:
    if not r.isRootableStorePath(storeDir):
      continue
    if absentIsLost or storePathExists(r):
      m.refs.add(r)
    else:
      m.absentAtRecord.add(r)
  writeNixRootsManifest(ledgerManifestPath(ledgerDir, key), m)
  if m.refs.len == 0 or not dirExists(storeDir):
    result.absent = m.absentAtRecord
    return
  # `addRoots` skips (and reports as `absent`) whatever does not exist, so an
  # `absentIsLost` ref is never handed to `nix-store`.
  result = addRoots(ledgerPoolDir(ledgerDir), m.refs, nixStore, storeDir)
  result.absent.add(m.absentAtRecord)

proc ledgerMissingStorePaths*(ledgerDir, key: string):
    tuple[found: bool; missing: seq[string]] =
  ## Whether `key` has a manifest, and which of the store paths it recorded
  ## are gone: one file read and one `lstat` per path. The fallback for when
  ## the ledger index (`NixLedgerIndex`) is not valid; with a valid index,
  ## its `missingStorePaths` answers the same question without the read.
  let read = readNixRootsManifest(ledgerManifestPath(ledgerDir, key))
  if not read.found:
    return
  (found: true, missing: read.manifest.missingStorePaths())

proc ensureLedgerRoots*(ledgerDir, key: string; nixStore = "";
                        storeDir = nixStoreDir()): NixRootOutcome =
  ## Re-assert the pool roots `key`'s manifest names, without re-scanning
  ## any output. Cheap when they are all present (one directory listing).
  let read = readNixRootsManifest(ledgerManifestPath(ledgerDir, key))
  if not read.found or read.manifest.refs.len == 0 or not dirExists(storeDir):
    return
  addRoots(ledgerPoolDir(ledgerDir), read.manifest.refs, nixStore, storeDir)

proc directoryStamp(dir: string): string =
  ## The directory's modification time (nanoseconds) and identity. Creating,
  ## renaming or removing an entry moves it — and writing a manifest is a
  ## rename into `actions/` — so an equal stamp means "the same set of
  ## manifest files as when the stamp was taken". "" when unreadable.
  try:
    let info = getFileInfo(extendedPath(dir), followSymlink = false)
    $info.lastWriteTime.toUnix & "." & $info.lastWriteTime.nanosecond & "/" &
      $info.id.device & ":" & $info.id.file
  except OSError:
    ""

type
  NixLedgerIndex* = object
    ## Every manifest's store paths in ONE file, so the warm path reads one
    ## file per build instead of one per action. Measured on aarch64-darwin
    ## (2026-10-14, 2,000 trivial actions, warm whole-graph no-op): reading
    ## each action's manifest cost ~30 µs per action, ~60 ms of a ~470 ms
    ## no-op build.
    ##
    ## It is a CACHE of the manifests and is trusted only when it provably
    ## is one: it records the `actions/` directory stamp it was built
    ## against, and a different stamp now means a manifest was written or
    ## removed since, so the index is ignored and callers read manifests.
    ## With an equal stamp a key ABSENT from the index has no manifest,
    ## because creating one would have moved the stamp.
    ##
    ## The stamp is only as fine as the filesystem's directory mtime: APFS,
    ## ext4, btrfs and XFS keep nanoseconds, which is what this relies on. On
    ## a one-second filesystem (HFS+, ext3) a manifest replaced within the
    ## second the index was stamped would go unnoticed until the next prune.
    valid*: bool
    stamp: string           ## the `actions/` stamp it was built against
    paths: seq[string]
    present: seq[int8]      ## 0 unknown, 1 present, 2 missing; per run
    byKey: Table[string, seq[int]]

proc loadNixLedgerIndex*(ledgerDir: string): NixLedgerIndex =
  ## The ledger index, `valid` only when it matches the manifests on disk.
  result.byKey = initTable[string, seq[int]]()
  var text: string
  try:
    text = readFile(extendedPath(ledgerDir / LedgerIndexName))
  except IOError, OSError:
    return
  let lines = text.splitLines()
  if lines.len < 2 or lines[0] != IndexHeader or
      not lines[1].startsWith("stamp\t"):
    return
  let stamp = lines[1]["stamp\t".len .. ^1]
  if stamp.len == 0 or
      stamp != directoryStamp(ledgerDir / LedgerActionsDirName):
    return
  for line in lines[2 .. ^1]:
    if line.startsWith("path\t"):
      result.paths.add(line["path\t".len .. ^1])
    elif line.startsWith("key\t"):
      let fields = line.split('\t')
      var ids: seq[int] = @[]
      if fields.len > 2 and fields[2].len > 0:
        for item in fields[2].split(','):
          try:
            let id = parseInt(item)
            if id < 0 or id >= result.paths.len:
              return
            ids.add(id)
          except ValueError:
            return
      if fields.len >= 2:
        result.byKey[fields[1]] = ids
  result.present = newSeq[int8](result.paths.len)
  result.stamp = stamp
  result.valid = true

proc nixLedgerNeedsMaintenance*(ledgerDir: string;
                                index: NixLedgerIndex): bool =
  ## Whether `pruneStaleRoots` has anything to do: true exactly when the
  ## manifests on disk are not the ones `index` summarises — a manifest was
  ## written, replaced or removed since the last prune (one `stat`). False
  ## when the ledger holds no manifests at all.
  ##
  ## That is also exactly when pruning can matter. A pool root becomes
  ## unneeded only when a manifest stops naming it, and a manifest becomes
  ## prunable only when its outputs are deleted — which re-executes the
  ## action if it is still in the graph (rewriting the manifest), and
  ## otherwise is noticed at the next build that writes any manifest. Until
  ## then an unpruned root only keeps a store path alive a little longer.
  let stamp = directoryStamp(ledgerDir / LedgerActionsDirName)
  stamp.len > 0 and not (index.valid and index.stamp == stamp)

proc missingStorePaths*(index: var NixLedgerIndex; key: string):
    tuple[found: bool; missing: seq[string]] =
  ## `ledgerMissingStorePaths` answered from a valid index: no file read, and
  ## one `lstat` per DISTINCT store path per build, however many actions
  ## name it.
  doAssert index.valid
  if key notin index.byKey:
    return
  result.found = true
  for id in index.byKey[key]:
    if index.present[id] == 0:
      index.present[id] = if storePathExists(index.paths[id]): 1 else: 2
    if index.present[id] == 2:
      result.missing.add(index.paths[id])

proc writeLedgerIndex(ledgerDir, stamp: string;
                      entries: seq[tuple[key: string; refs: seq[string]]]) =
  var ids = initTable[string, int]()
  var text = IndexHeader & "\nstamp\t" & stamp & "\n"
  for entry in entries:
    for r in entry.refs:
      if r notin ids:
        ids[r] = ids.len
        text.add("path\t" & r & "\n")
  for entry in entries:
    var list: seq[string] = @[]
    for r in entry.refs:
      list.add($ids[r])
    text.add("key\t" & entry.key & "\t" & list.join(",") & "\n")
  let path = ledgerDir / LedgerIndexName
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  writeFile(extendedPath(tmp), text)
  moveFile(extendedPath(tmp), extendedPath(path))

proc pruneStaleRoots*(ledgerDir: string; storeDir = nixStoreDir()):
    tuple[manifestsRemoved, rootsRemoved: int] =
  ## Drop what no surviving output needs:
  ##
  ## 1. every manifest none of whose covered outputs exists any more — the
  ##    output was deleted, or its producer left the graph and someone
  ##    cleaned up after it;
  ## 2. every pool root no remaining manifest names — the output was rebuilt
  ##    and now names different store paths, or (1) removed its manifest.
  ##
  ## The pool is listed BEFORE the manifests are read; see
  ## `recordOutputRoots` for the race that ordering closes.
  ##
  ## Having read every manifest anyway, it also rewrites the ledger index
  ## (`NixLedgerIndex`) — but only when the index would be exact: stamped
  ## with the `actions/` directory as it was BEFORE the read, and only if
  ## nothing moved that stamp during it (a manifest written concurrently, or
  ## one this call removed). Otherwise the index is deleted and the next
  ## build reads manifests until a later prune rebuilds it.
  let pool = readRootLinks(ledgerPoolDir(ledgerDir), storeDir)
  var keep = initHashSet[string]()
  let actionsDir = ledgerDir / LedgerActionsDirName
  let stampBefore = directoryStamp(actionsDir)
  var entries: seq[tuple[key: string; refs: seq[string]]] = @[]
  if dirExists(extendedPath(actionsDir)):
    for kind, path in walkDir(extendedPath(actionsDir), relative = false,
                              checkDir = false):
      if kind != pcFile or not path.endsWith(ManifestSuffix):
        continue
      let read = readNixRootsManifest(path)
      if not read.found:
        continue
      var anyOutput = false
      for o in read.manifest.outputs:
        if storePathExists(o):
          anyOutput = true
          break
      if read.manifest.outputs.len > 0 and not anyOutput:
        try:
          removeFile(path)
          inc result.manifestsRemoved
        except OSError:
          discard
        continue
      for r in read.manifest.refs:
        keep.incl(r)
      let name = path.extractFilename
      entries.add((key: name[0 ..< name.len - ManifestSuffix.len],
        refs: read.manifest.refs))
  result.rootsRemoved = pool.removeUnkept(keep)
  if stampBefore.len > 0 and result.manifestsRemoved == 0 and
      directoryStamp(actionsDir) == stampBefore:
    entries.sort(proc (a, b: tuple[key: string; refs: seq[string]]): int =
      cmp(a.key, b.key))
    writeLedgerIndex(ledgerDir, stampBefore, entries)
  else:
    try:
      removeFile(extendedPath(ledgerDir / LedgerIndexName))
    except OSError:
      discard
