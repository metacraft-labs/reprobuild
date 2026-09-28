## Portable fingerprints — Cache-Scope Phase 3, P3.1.
##
## The action cache's local strong fingerprint (`strongIdentityPayload` in
## `repro_local_store.nim`) is deliberately a LOCAL identity: it hashes each
## observed input's absolute host path byte-for-byte and identifies content by
## mtime (`ffpTimestamp`) or a 64-bit xxh3 local hash. That is exactly right for
## local incrementality and exactly wrong for sharing a result with another
## host, whose checkout lives somewhere else and whose files have other mtimes.
##
## This module computes the PORTABLE identity the specs call for, alongside
## the local one and without touching it:
##
## * Hermetic-Builds-And-Path-Independence.md, Goal B ("cache-key path
##   independence") and "Logical Paths Versus Physical Paths": an observed
##   path is rewritten against the logical root it lives under — the
##   project/recipe root, the workspace, the tool store, a fetched-source
##   root — so two checkouts at different absolute paths agree.
## * Caching-Architecture.md: "portable cache identities and remote
##   substitutes require content-addressed verification" — every input is
##   identified by a BLAKE3-256 content digest (reads), its existence
##   (probes) or a membership digest (enumerations); never an mtime.
## * Filesystem-Policy-And-Observed-Inputs.md, read-only / writable /
##   UNTRACKED roots (BuildXL's mounts): an access under an untracked root
##   (host system directories) does not contribute; an access under NO known
##   root makes the action not portable — it may still cache locally, but a
##   result whose inputs cannot be named portably must not be shared.
##
## BuildXL's model, which the specs follow: the weak fingerprint is the
## action's static description; the strong fingerprint adds the observed
## inputs' content. Both are computed here over LOGICAL paths.
##
## Pure over strings and the filesystem: the engine adapts its own action and
## evidence types to these procs, which keeps this module testable alone.

import std/[algorithm, os, strutils]

import blake3

type
  LogicalRootKind* = enum
    lrkTracked    ## Accesses contribute to the portable fingerprint.
    lrkUntracked  ## Accesses are deliberately ignored (host system dirs).

  LogicalRoot* = object
    label*: string
      ## Stable logical name, e.g. `project`, `workspace`, `toolstore`. Two
      ## hosts must assign the same label to the equivalent root.
    path*: string
      ## Absolute physical location on THIS host.
    kind*: LogicalRootKind

  LogicalPathKind* = enum
    lpkTracked
    lpkUntracked
    lpkOutside  ## Under no known root: cannot be named portably.

  LogicalPath* = object
    kind*: LogicalPathKind
    label*: string
    rel*: string  ## Root-relative, `/`-separated; "" for the root itself.

  PortableInputKind* = enum
    pikRead
    pikProbe
    pikEnumeration

  PortableInput* = object
    kind*: PortableInputKind
    path*: string    ## `<label>:<rel>`.
    digest*: string  ## Content / existence / membership identity (hex).

  PortableOutput* = object
    ## Cache-Scope P3.2: one output of an action, named portably. A file's
    ## `digest` is its BLAKE3 content digest; a directory's is a tree digest
    ## over its sorted (relative path, entry identity) pairs. This is what
    ## lets a DOWNSTREAM action's portable strong fingerprint be computed from
    ## an upstream memo record instead of an upstream file: a downstream read
    ## of `project:out/x` and this output are the same logical path.
    path*: string    ## `<label>:<rel>`.
    digest*: string
    directory*: bool

  PortableOutputs* = object
    portable*: bool
    reason*: string
    outputs*: seq[PortableOutput]

  PortableFingerprint* = object
    portable*: bool
    reason*: string
      ## Empty when portable; otherwise names the first physical path that
      ## could not be expressed against a logical root.
    weakHex*: string
    strongHex*: string
    inputs*: seq[PortableInput]

const
  WeakDomain = "reprobuild.portable.weak.v1"
  StrongDomain = "reprobuild.portable.strong.v1"
  ProbePresent = "present"
  ProbeAbsent = "absent"

proc normalizeForCompare(path: string): string =
  ## Separator-normalized, and case-folded on Windows where the filesystem is
  ## case-insensitive, so `M:\m\dev` and `m:/m/dev/` compare equal.
  var p = path.replace('\\', '/')
  while p.len > 1 and p.endsWith("/"):
    p.setLen(p.len - 1)
  when defined(windows):
    p = p.toLowerAscii()
  p

proc sortedByLength(roots: openArray[LogicalRoot]): seq[LogicalRoot] =
  ## Longest root first, so a root nested inside another (a project inside a
  ## workspace, a tool store inside a project) wins.
  result = @roots
  result.sort(proc (a, b: LogicalRoot): int =
    cmp(normalizeForCompare(b.path).len, normalizeForCompare(a.path).len))

proc toLogicalPath*(roots: openArray[LogicalRoot]; physical: string):
    LogicalPath =
  ## Rewrite an absolute physical path against the longest matching root.
  let target = normalizeForCompare(physical)
  let original = physical.replace('\\', '/')
  for root in sortedByLength(roots):
    let base = normalizeForCompare(root.path)
    if base.len == 0:
      continue
    if target == base or target.startsWith(base & "/"):
      let kind = if root.kind == lrkUntracked: lpkUntracked else: lpkTracked
      # Keep the ORIGINAL spelling of the relative part: case matters for
      # content on case-sensitive hosts and is merely cosmetic elsewhere.
      # Case folding preserves length and `target` differs from `original`
      # only by it (plus trailing-separator trimming at the END), so the
      # root prefix occupies the same `base.len` characters in both.
      let rel =
        if target == base: ""
        else: original[base.len + 1 .. ^1].strip(leading = false,
          chars = {'/'})
      return LogicalPath(kind: kind, label: root.label, rel: rel)
  LogicalPath(kind: lpkOutside, rel: original)

proc render(path: LogicalPath): string =
  path.label & ":" & path.rel

proc logicalizeText*(roots: openArray[LogicalRoot]; text: string): string =
  ## Replace every occurrence of a tracked root's physical path inside an
  ## arbitrary string (an argv element, an environment value) with
  ## `${<label>}`. Longest root first; separators and (on Windows) case are
  ## normalized so `M:\m\dev\x` and `m:/m/dev/x` logicalize identically.
  result = text.replace('\\', '/')
  for root in sortedByLength(roots):
    let base = root.path.replace('\\', '/').strip(leading = false,
      chars = {'/'})
    if base.len == 0:
      continue
    let token = "${" & root.label & "}"
    when defined(windows):
      var i = 0
      var built = ""
      let lower = result.toLowerAscii()
      let needle = base.toLowerAscii()
      while i < result.len:
        let hit = lower.find(needle, i)
        if hit < 0:
          built.add(result[i .. ^1])
          break
        built.add(result[i ..< hit])
        built.add(token)
        i = hit + needle.len
      result = built
    else:
      result = result.replace(base, token)

proc fileContentHex*(path: string): string =
  ## BLAKE3-256 of a file's bytes, streamed. "" when it cannot be read.
  var f: File
  if not open(f, path, fmRead):
    return ""
  defer: close(f)
  let hasher = initHasher()
  defer: hasher.close()
  var buf: array[65536, byte]
  while true:
    let n = readBytes(f, buf, 0, buf.len)
    if n <= 0:
      break
    hasher.update(buf.toOpenArray(0, n - 1))
  hasher.finalize().toHex()

proc membershipHex*(dir: string): string =
  ## Membership digest of a directory: the sorted child names, each suffixed
  ## `/` for a directory. Names only — an enumeration observes WHICH entries
  ## exist, not their content (reads of those entries are separate inputs).
  var names: seq[string] = @[]
  try:
    for kind, entry in walkDir(dir, relative = true):
      names.add(entry.replace('\\', '/') &
        (if kind in {pcDir, pcLinkToDir}: "/" else: ""))
  except CatchableError:
    return ""
  names.sort()
  blake3.digest(names.join("\n")).toHex()

proc frame(text: string): string =
  ## Length-prefixed so field boundaries cannot be forged by content.
  $text.len & ":" & text

proc portableWeakFingerprint*(roots: openArray[LogicalRoot];
                              argv: openArray[string]; cwd: string;
                              env: openArray[(string, string)];
                              declaredInputs: openArray[string]): string =
  ## The action's static description, over logical paths. Environment is
  ## sorted by name; declared inputs are logicalized and sorted, because
  ## their order carries no meaning for what the action computes.
  var payload = frame(WeakDomain)
  payload.add(frame($argv.len))
  for arg in argv:
    payload.add(frame(logicalizeText(roots, arg)))
  payload.add(frame(logicalizeText(roots, cwd)))
  var envSorted = @env
  envSorted.sort(proc (a, b: (string, string)): int = cmp(a[0], b[0]))
  payload.add(frame($envSorted.len))
  for (name, value) in envSorted:
    payload.add(frame(name))
    payload.add(frame(logicalizeText(roots, value)))
  var inputs: seq[string] = @[]
  for input in declaredInputs:
    inputs.add(logicalizeText(roots, input))
  inputs.sort()
  payload.add(frame($inputs.len))
  for input in inputs:
    payload.add(frame(input))
  blake3.digest(payload).toHex()

proc portableStrongFingerprint*(weakHex: string;
                                inputs: openArray[PortableInput]): string =
  ## Weak fingerprint plus the observed inputs' content identities, in a
  ## canonical order (kind, then logical path) so the monitor's observation
  ## order cannot change the identity.
  var sortedInputs = @inputs
  sortedInputs.sort(proc (a, b: PortableInput): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.path, b.path))
  var payload = frame(StrongDomain)
  payload.add(frame(weakHex))
  payload.add(frame($sortedInputs.len))
  for input in sortedInputs:
    payload.add(frame($ord(input.kind)))
    payload.add(frame(input.path))
    payload.add(frame(input.digest))
  blake3.digest(payload).toHex()

proc computePortableFingerprint*(roots: openArray[LogicalRoot];
                                 argv: openArray[string]; cwd: string;
                                 env: openArray[(string, string)];
                                 declaredInputs: openArray[string];
                                 reads, probes, enumerations:
                                   openArray[string]): PortableFingerprint =
  ## Everything at once. Deduplicates each observation class by logical path
  ## (the monitor reports repeats), drops untracked accesses, and marks the
  ## action not portable at the first access under no known root.
  result.portable = true
  result.weakHex = portableWeakFingerprint(roots, argv, cwd, env,
    declaredInputs)
  var seen: seq[string] = @[]
  template consider(physical: string; inputKind: PortableInputKind;
                    identity: untyped) =
    let logical = toLogicalPath(roots, physical)
    case logical.kind
    of lpkUntracked:
      discard
    of lpkOutside:
      if result.portable:
        result.portable = false
        result.reason = "observed " & $inputKind & " outside every logical " &
          "root: " & physical
    of lpkTracked:
      let key = $ord(inputKind) & "|" & render(logical)
      if key notin seen:
        seen.add(key)
        result.inputs.add(PortableInput(kind: inputKind, path: render(logical),
          digest: identity))
  for path in reads:
    consider(path, pikRead, fileContentHex(path))
  for path in probes:
    consider(path, pikProbe,
      (if fileExists(path) or dirExists(path): ProbePresent
       else: ProbeAbsent))
  for path in enumerations:
    consider(path, pikEnumeration, membershipHex(path))
  if result.portable:
    result.strongHex = portableStrongFingerprint(result.weakHex,
      result.inputs)

const TreeDomain = "reprobuild.portable.tree.v1"

proc treeContentHex*(dir: string): string =
  ## Content identity of a directory tree: the sorted (relative path, kind,
  ## identity) triples of every entry beneath it -- a file by its BLAKE3
  ## content digest, a symlink by its target text, a directory by its
  ## presence (so an empty directory still counts). Physical location plays
  ## no part: two copies of the same tree at different absolute paths agree.
  var entries: seq[string] = @[]
  for path in walkDirRec(dir, yieldFilter = {pcFile, pcLinkToFile, pcDir,
      pcLinkToDir}, relative = true, followFilter = {pcDir}):
    let full = dir / path
    let rel = path.replace('\\', '/')
    let info =
      try: getFileInfo(full, followSymlink = false)
      except CatchableError: continue
    case info.kind
    of pcLinkToFile, pcLinkToDir:
      let target =
        try: expandSymlink(full).replace('\\', '/')
        except CatchableError: ""
      entries.add(frame(rel) & frame("l") & frame(target))
    of pcDir:
      entries.add(frame(rel) & frame("d") & frame(""))
    of pcFile:
      entries.add(frame(rel) & frame("f") & frame(fileContentHex(full)))
  entries.sort()
  blake3.digest(frame(TreeDomain) & entries.join("")).toHex()

proc portableOutputs*(roots: openArray[LogicalRoot];
                      outputs: openArray[string]): PortableOutputs =
  ## Name each output portably and identify its bytes. An output under no
  ## tracked root cannot be referenced by another host, so the action is not
  ## portable; a missing output is reported the same way, since a record
  ## promising bytes that do not exist must never be shared.
  result.portable = true
  for physical in outputs:
    let logical = toLogicalPath(roots, physical)
    if logical.kind != lpkTracked:
      result.portable = false
      result.reason = "output outside every tracked logical root: " &
        physical
      return
    if dirExists(physical):
      result.outputs.add(PortableOutput(path: render(logical),
        digest: treeContentHex(physical), directory: true))
    elif fileExists(physical):
      result.outputs.add(PortableOutput(path: render(logical),
        digest: fileContentHex(physical)))
    else:
      result.portable = false
      result.reason = "declared output does not exist: " & physical
      return
  result.outputs.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))
