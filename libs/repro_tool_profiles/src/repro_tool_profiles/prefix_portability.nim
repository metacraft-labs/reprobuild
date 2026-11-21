## Portability and identity of a realized tool prefix that is shared through
## the binary cache.
##
## A tool prefix (the sealed output of a provisioning edge) is published under
## a cache identity that is meant to be the same on every host. Two things
## make that safe, and this module holds both:
##
## * **The staging-path leak scan.** A prefix is built in a staging directory
##   and moved into place when it is sealed. A step that ran in the staging
##   tree (an installer, a native build, a generated launcher) can write that
##   absolute path into a file. Such a prefix only works where it was built,
##   so it must never be published under a portable identity. Before sealing,
##   the realizer scans every file of the staging tree for the staging path,
##   spelled with ``/`` and with ``\`` separators and in UTF-16LE (the form a
##   Windows tool writes into a resource or a registry export), and fails the
##   edge naming the file. It is not published under a weaker identity
##   instead: the fix is to make the step normalise or prune what it writes.
##
## * **The identity of a realized input.** A prefix whose bytes were produced
##   by a build step (a post-extraction step, a source build) is a function of
##   the tools that step ran with. Its identity therefore lists the cache
##   identity key of each such tool. A tool whose identity cannot be stated
##   completely (a compiler found on the host, a library built by a recipe
##   whose source identity is not yet bound) makes the composite identity
##   incomplete, and an incomplete identity neither substitutes nor publishes.
##   Every sealed tool prefix records its own key in
##   ``PrefixIdentityFileName`` so a later step can name it.

import std/[algorithm, json, os, strutils]

import blake3
from repro_core/paths import extendedPath

const
  PrefixIdentityFileName* = ".repro-cache-identity.json"
    ## Written into a tool prefix when it is sealed: the binary-cache key the
    ## prefix was realized under, or why it has none. A file inside the
    ## prefix, so a prefix substituted from the cache carries the key it was
    ## published under, and a step that runs a tool from it can name it.
  PrefixIdentitySchema = "reprobuild.tool-prefix-identity.v1"
  LeakScanChunk = 1 shl 20
  MaxReportedLeaks = 16

type
  StagingPathLeak* = object
    ## One file of a staging tree that carries the staging path.
    file*: string
      ## Path relative to the staging root, with ``/`` separators.
    spelling*: string
      ## Which spelling matched: ``slash``, ``backslash``, ``utf16le-slash``
      ## or ``utf16le-backslash``; ``symlink-target`` for a link that points
      ## into the staging tree by absolute path.

  StagingPathLeakError* = object of OSError
    ## The staging tree of a provisioning edge holds its own absolute path.
    leaks*: seq[StagingPathLeak]

  RealizedInputIdentity* = object
    ## The cache identity of one tool or library a build step ran with.
    role*: string
      ## What the input is to the step (a package selector or a role name).
      ## Diagnostic only; it is not part of any key.
    keyHex*: string
      ## The input's complete cache-entry key, 64 lowercase hex digits; ""
      ## when ``incomplete`` is set.
    incomplete*: string
      ## Why the input has no complete identity; "" when it has one.
    localIdentity*: string
      ## What distinguishes this input on THIS host when it has no complete
      ## identity (its realized path). Keys the local prefix directory so a
      ## moved or rebuilt input re-realizes the prefix; never enters a
      ## shared cache key.

proc spellings(stagingPath: string): seq[tuple[name: string; bytes: string]] =
  ## The byte patterns the scan looks for. The path is normalised to its two
  ## separator forms, and each is also encoded as UTF-16LE.
  var base = stagingPath
  when defined(windows):
    if base.startsWith("\\\\?\\"):
      base = base[4 .. ^1]
  while base.len > 1 and base[^1] in {'/', '\\'}:
    base.setLen(base.len - 1)
  let slash = base.replace('\\', '/')
  let backslash = base.replace('/', '\\')
  proc utf16le(text: string): string =
    # The staging path is built by the realizer from the store root and an
    # ASCII suffix; a non-ASCII store root is encoded byte-wise, which matches
    # what a Windows tool writes for the Latin-1 range and is a conservative
    # miss beyond it.
    for ch in text:
      result.add(ch)
      result.add('\0')
  result.add((name: "slash", bytes: slash))
  if backslash != slash:
    result.add((name: "backslash", bytes: backslash))
  result.add((name: "utf16le-slash", bytes: utf16le(slash)))
  if backslash != slash:
    result.add((name: "utf16le-backslash", bytes: utf16le(backslash)))

proc foldCase(text: var string) =
  ## Windows paths compare case-insensitively, so a tool may write the
  ## staging path with a different drive-letter or directory case. ASCII
  ## folding is enough: the realizer builds the staging path itself.
  when defined(windows):
    for i in 0 ..< text.len:
      text[i] = toLowerAscii(text[i])
  else:
    discard text

proc fileLeakSpelling(path: string;
                      patterns: seq[tuple[name: string; bytes: string]]):
    string =
  ## The first spelling found in the file at ``path``, or "". Reads in
  ## chunks with an overlap of the longest pattern, so a file of any size is
  ## scanned without holding it in memory and a match across a chunk boundary
  ## is still found.
  var longest = 0
  for pattern in patterns:
    longest = max(longest, pattern.bytes.len)
  var file: File
  if not open(file, extendedPath(path), fmRead):
    raise newException(OSError, "cannot read " & path &
      " for the staging-path leak scan")
  defer: close(file)
  var carry = ""
  var buffer = newString(LeakScanChunk)
  while true:
    let got = readBuffer(file, addr buffer[0], LeakScanChunk)
    if got <= 0:
      break
    var window = carry & buffer[0 ..< got]
    foldCase(window)
    for pattern in patterns:
      if window.find(pattern.bytes) >= 0:
        return pattern.name
    if window.len > longest:
      carry = window[window.len - longest .. ^1]
    else:
      carry = window
  ""

proc findStagingPathLeaks*(stagingRoot: string;
                           stagingPath = ""): seq[StagingPathLeak] =
  ## Every file under ``stagingRoot`` that carries ``stagingPath`` (default:
  ## ``stagingRoot`` itself), at most ``MaxReportedLeaks`` of them. Symbolic
  ## links are not followed; a link whose target names the staging path is
  ## itself a leak, because it stops resolving once the tree is moved.
  let needle = if stagingPath.len > 0: stagingPath else: stagingRoot
  var patterns = spellings(needle)
  for pattern in patterns.mitems:
    foldCase(pattern.bytes)
  let root = stagingRoot
  for path in walkDirRec(extendedPath(root),
      yieldFilter = {pcFile, pcLinkToFile, pcLinkToDir},
      followFilter = {pcDir}):
    var plain = path
    when defined(windows):
      if plain.startsWith("\\\\?\\"):
        plain = plain[4 .. ^1]
    let relative = relativePath(plain, root).replace('\\', '/')
    if symlinkExists(path):
      var target = ""
      try:
        target = expandSymlink(path)
      except OSError:
        target = ""
      foldCase(target)
      for pattern in patterns:
        if pattern.name in ["slash", "backslash"] and
            target.find(pattern.bytes) >= 0:
          result.add(StagingPathLeak(file: relative,
            spelling: "symlink-target"))
          break
    else:
      let spelling = fileLeakSpelling(path, patterns)
      if spelling.len > 0:
        result.add(StagingPathLeak(file: relative, spelling: spelling))
    if result.len >= MaxReportedLeaks:
      break

proc refuseStagingPathLeaks*(stagingRoot, packageLabel: string;
                             stagingPath = "") =
  ## Raise ``StagingPathLeakError`` naming every leaking file (up to a bound)
  ## when the staging tree carries its own path; return otherwise.
  let leaks = findStagingPathLeaks(stagingRoot, stagingPath)
  if leaks.len == 0:
    return
  var lines: seq[string]
  for leak in leaks:
    lines.add(leak.file & " (" & leak.spelling & ")")
  let err = newException(StagingPathLeakError,
    "tool-resolution failed: the realized prefix of " & packageLabel &
    " contains the absolute path it was staged at (" &
    (if stagingPath.len > 0: stagingPath else: stagingRoot) &
    "), so it would only work on this host and cannot be sealed or shared. " &
    "The step that wrote it must write a relative path, normalise the file " &
    "or prune it. Leaking files:\n  " & lines.join("\n  "))
  err.leaks = leaks
  raise err

proc writePrefixIdentityFile*(prefix, keyHex, incomplete: string) =
  ## Record, inside ``prefix``, the cache key it is sealed under (``keyHex``)
  ## or why it has no complete one (``incomplete``).
  writeFile(extendedPath(prefix / PrefixIdentityFileName), $(%*{
    "schema": PrefixIdentitySchema,
    "key": keyHex,
    "incomplete": incomplete}) & "\n")

proc readPrefixIdentityFile*(prefix: string):
    tuple[found: bool; keyHex: string; incomplete: string] =
  ## The record ``writePrefixIdentityFile`` left in ``prefix``. ``found`` is
  ## false when there is none or it cannot be read.
  let path = prefix / PrefixIdentityFileName
  if not fileExists(extendedPath(path)):
    return
  try:
    let node = parseFile(extendedPath(path))
    if node{"schema"}.getStr() != PrefixIdentitySchema:
      return
    result = (found: true, keyHex: node{"key"}.getStr(),
      incomplete: node{"incomplete"}.getStr())
  except CatchableError:
    result.found = false

proc isEntryKeyHex(value: string): bool =
  value.len == 64 and value.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc nixStorePathOf(path: string): string =
  ## ``/nix/store/<hash>-<name>`` for a path inside the Nix store, else "".
  const storeDir = "/nix/store/"
  if not path.startsWith(storeDir):
    return ""
  let rest = path[storeDir.len .. ^1]
  let slash = rest.find('/')
  storeDir & (if slash < 0: rest else: rest[0 ..< slash])

proc realizedInputIdentity*(role, path: string): RealizedInputIdentity =
  ## The identity of the tool or library at ``path`` (a file or directory)
  ## that a build step runs with.
  ##
  ## * Inside a sealed tool prefix (an ancestor directory holds
  ##   ``PrefixIdentityFileName``): that prefix's recorded key, or its
  ##   recorded reason for having none.
  ## * Inside the Nix store: the store path names its derivation's inputs
  ##   completely, so its digest is a complete identity.
  ## * Anywhere else (a compiler on the host, a recipe's build directory):
  ##   incomplete, because nothing binds the bytes to a declaration.
  result.role = role
  if path.len == 0:
    result.incomplete = role & " has no realized path"
    return
  let absolute = absolutePath(path)
  let storePath = nixStorePathOf(absolute)
  if storePath.len > 0:
    result.keyHex = blake3.toHex(blake3.digest(
      "reprobuild.nix-store-path.v1\0" & storePath))
    return
  var dir = if dirExists(extendedPath(absolute)): absolute
            else: parentDir(absolute)
  while dir.len > 0:
    let recorded = readPrefixIdentityFile(dir)
    if recorded.found:
      if recorded.incomplete.len == 0 and isEntryKeyHex(recorded.keyHex):
        result.keyHex = recorded.keyHex
      else:
        result.incomplete = role & " (" & dir & ") was realized with an " &
          "incomplete identity: " &
          (if recorded.incomplete.len > 0: recorded.incomplete
           else: "no key recorded")
        result.localIdentity = dir
      return
    let parent = parentDir(dir)
    if parent == dir or parent.len == 0:
      break
    dir = parent
  result.incomplete = role & " (" & absolute & ") is not inside a " &
    "content-keyed tool prefix or the Nix store, so its bytes are not " &
    "bound to any declaration"
  result.localIdentity = absolute

proc incompleteReasons*(inputs: openArray[RealizedInputIdentity]): seq[string] =
  ## The reasons of every incomplete input, in order.
  for input in inputs:
    if input.incomplete.len > 0:
      result.add(input.incomplete)

proc localInputsDigest*(inputs: openArray[RealizedInputIdentity]): string =
  ## A digest of every input's key, or of its local identity when it has no
  ## complete key, for the LOCAL prefix directory key. Order-independent.
  var parts: seq[string]
  for input in inputs:
    parts.add(if input.keyHex.len > 0: "key:" & input.keyHex
              else: "local:" & input.localIdentity & "\0" & input.incomplete)
  parts.sort()
  blake3.toHex(blake3.digest(parts.join("\n")))

proc buildInputKeys*(inputs: openArray[RealizedInputIdentity]): string =
  ## The complete keys of the tools a build step ran with, sorted and
  ## de-duplicated, as one cache-entry option value. These are build-time
  ## inputs: they key the entry but are not references a consumer fetches
  ## with it. Incomplete inputs contribute nothing here; they make the
  ## identity incomplete instead.
  var keys: seq[string]
  for input in inputs:
    if input.keyHex.len > 0:
      let key = input.keyHex.toLowerAscii
      if key notin keys:
        keys.add(key)
  keys.sort()
  keys.join("\n")
