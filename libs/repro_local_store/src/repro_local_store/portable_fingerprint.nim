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

import std/[algorithm, options, os, strutils]

from repro_core/paths import extendedPath

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
    pikEnvironment
      ## An environment variable the action's processes READ (io-mon's
      ## `mrEnvRead`), keyed `env:<NAME>`, identified by its logicalized
      ## value — the portable half of the local fingerprint's observed
      ## environment. Appended last so older records decode unchanged.

  ObservedEnv* = object
    name*: string
    present*: bool
    value*: string

  PortableInput* = object
    kind*: PortableInputKind
    path*: string    ## `<label>:<rel>`.
    digest*: string  ## Content / existence / membership identity (hex).

  TreeEntryKind* = enum
    tekFile
    tekDirectory
    tekLinkToFile
    tekLinkToDir

  TreeEntry* = object
    rel*: string            ## `/`-separated, relative to the tree root.
    kind*: TreeEntryKind
    identity*: string       ## A file's BLAKE3 digest, a link's target text.

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
    entries*: seq[TreeEntry]
      ## For a directory: every entry beneath it, sorted by `rel`. A
      ## downstream action that reads, probes or enumerates INSIDE the
      ## directory is identified from these without the bytes on disk — the
      ## role of BuildXL's opaque-directory content listing.

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
  WeakDomain = "reprobuild.portable.weak.v2"
  StrongDomain = "reprobuild.portable.strong.v1"
  ProbePresent* = "present"
    ## The identity of a PROBE whose target exists.
  ProbeAbsent* = "absent"
    ## The identity of a PROBE whose target does not exist.

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

proc envInputKey*(name: string): string =
  ## `env:<NAME>`; upper-cased on Windows, where names are case-insensitive.
  when defined(windows): "env:" & name.toUpperAscii() else: "env:" & name

const AncestorPrefix* = "^"
  ## A logical path `^<label>:<rest>` names `<rest>` beneath ANY proper
  ## ancestor of root `<label>` — see `ancestorProbeKey`.

proc properAncestors(path: string): seq[string] =
  var current = path.replace('\\', '/')
  while current.len > 1 and current.endsWith("/"):
    current.setLen(current.len - 1)
  while true:
    let slash = current.rfind('/')
    if slash < 0:
      break
    let parent =
      if slash == 0: "/"
      elif slash == 2 and current.len > 1 and current[1] == ':':
        current[0 .. 2]   # a drive root: `M:/`
      else: current[0 ..< slash]
    if parent == current or parent.len == 0:
      break
    result.add(parent)
    if parent == "/" or (parent.len == 3 and parent[1] == ':'):
      break
    current = parent

proc ancestorProbeKey*(roots: openArray[LogicalRoot]; physical: string):
    string =
  ## For a PROBE of a path under no root but beneath a proper ancestor of
  ## a tracked root, the logical key `^<label>:<rest>`; otherwise "".
  ##
  ## Tools look for fixed names in every directory ABOVE the project: node
  ## and npm walk up for `node_modules` and `package.json` and put each
  ## ancestor's `node_modules/.bin` on PATH; a shell or node-gyp probes
  ## well-known install locations. What such a probe learns is whether
  ## `<rest>` exists somewhere up the tree — not at which absolute path,
  ## which is only where this host keeps the checkout. So the probe is
  ## keyed by `<rest>` relative to the ancestry, and its identity is
  ## `present` if `<rest>` exists beneath ANY proper ancestor of the root
  ## (`ancestorProbeIdentity`), computed the same way when recording and
  ## when looking up. That over-approximates what the tool saw, in the
  ## direction of a miss: a file anywhere up the tree on either host flips
  ## it. Reads are never keyed this way — content outside the roots stays
  ## non-portable.
  let target = normalizeForCompare(physical)
  for root in sortedByLength(roots):
    if root.kind != lrkTracked:
      continue
    for ancestor in properAncestors(root.path):
      var base = normalizeForCompare(ancestor)
      if not base.endsWith("/"):
        base.add("/")
      if target.startsWith(base) and target.len > base.len:
        var rest = target[base.len .. ^1]
        return AncestorPrefix & root.label & ":" & rest
  ""

proc ancestorProbeIdentity*(roots: openArray[LogicalRoot]; key: string):
    string =
  ## The identity of an `^<label>:<rest>` key on THIS host: "present" when
  ## `<rest>` exists beneath any proper ancestor of root `<label>`, else
  ## "absent"; "" when the key names no root here.
  if not key.startsWith(AncestorPrefix):
    return ""
  let colon = key.find(':')
  if colon < 0:
    return ""
  let label = key[AncestorPrefix.len ..< colon]
  let rest = key[colon + 1 .. ^1]
  for root in roots:
    if root.label == label and root.kind == lrkTracked:
      for ancestor in properAncestors(root.path):
        let candidate = ancestor.strip(leading = false, chars = {'/'}) & "/" &
          rest
        if fileExists(extendedPath(candidate)) or
            dirExists(extendedPath(candidate)):
          return "present"
      return "absent"
  ""

proc logicalizeText*(roots: openArray[LogicalRoot]; text: string): string =
  ## Replace every occurrence of a tracked root's physical path inside an
  ## arbitrary string (an argv element, an environment value) with
  ## `${<label>}`. Longest root first; separators and (on Windows) case are
  ## normalized so `M:\m\dev\x` and `m:/m/dev/x` logicalize identically.
  result = text.replace('\\', '/')
  for root in sortedByLength(roots):
    # An untracked root is deliberately NOT a portable name: rewriting it
    # would make a value's identity depend on which untracked roots the
    # caller happened to pass.
    if root.kind != lrkTracked:
      continue
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
  if not open(f, extendedPath(path), fmRead):
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

proc membershipHexOfNames*(names: openArray[string]): string =
  ## Membership digest over child names already suffixed `/` for a
  ## directory (or a link to one). Order-insensitive.
  var sorted = @names
  sorted.sort()
  blake3.digest(sorted.join("\n")).toHex()

const
  ReadOfAbsent* = "absent"
    ## The identity of a READ whose target does not exist.
  ReadOfDirectory* = "directory"
    ## The identity of a READ whose target is a directory.

proc readIdentity*(path: string): string =
  ## The identity of an observed READ of `path`, the same on the recording
  ## side and the lookup side: the file's content digest, or what stands
  ## there instead.
  ##
  ## Reads of files that do not exist are common, not exotic: node's module
  ## resolution tries to open `package.json` at every level it walks, and
  ## the monitor records each failed open as a read. The recorder used to
  ## identify such a read as "" (nothing could be hashed) while the lookup
  ## answered "cannot identify" -- so a path set holding even one of them
  ## could never be evaluated, on any host, the recording one included.
  ## gemini-cli's bundle step had 125.
  if fileExists(extendedPath(path)):
    fileContentHex(path)
  elif dirExists(extendedPath(path)):
    ReadOfDirectory
  else:
    ReadOfAbsent

proc membershipHex*(dir: string): string =
  ## Membership digest of a directory: the sorted child names, each suffixed
  ## `/` for a directory. Names only — an enumeration observes WHICH entries
  ## exist, not their content (reads of those entries are separate inputs).
  var names: seq[string] = @[]
  try:
    for kind, entry in walkDir(extendedPath(dir), relative = true):
      names.add(entry.replace('\\', '/') &
        (if kind in {pcDir, pcLinkToDir}: "/" else: ""))
  except CatchableError:
    return ""
  membershipHexOfNames(names)

proc frame(text: string): string =
  ## Length-prefixed so field boundaries cannot be forged by content.
  $text.len & ":" & text

proc envIdentity*(roots: openArray[LogicalRoot]; present: bool;
                  value: string): string =
  ## The identity of an observed environment variable: "unset", or the
  ## BLAKE3 of its value with every tracked root's path logicalized — so a
  ## value naming a path inside the project is the same on every checkout,
  ## and one naming a host path (a PATH entry in a home directory) is not.
  if not present:
    return "unset"
  blake3.digest(logicalizeText(roots, value)).toHex()

proc portableWeakFingerprint*(roots: openArray[LogicalRoot];
                              argv: openArray[string]; cwd: string;
                              env: openArray[(string, string)];
                              declaredInputs: openArray[string];
                              staticFields: openArray[string] = []): string =
  ## The action's static description, over logical paths. Environment is
  ## sorted by name; declared inputs are logicalized and sorted, because
  ## their order carries no meaning for what the action computes.
  ## `staticFields` carries the rest of that description — what an argv does
  ## not say: the action kind, a builtin's payload, its declared outputs.
  ## Without them two builtins with the same inputs (argv is empty for both)
  ## would share one identity. Each is logicalized; their order is kept,
  ## since the caller states it.
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
  payload.add(frame($staticFields.len))
  for field in staticFields:
    payload.add(frame(logicalizeText(roots, field)))
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

type
  PhysicalIdentity* = proc (physical: string;
                            kind: PortableInputKind): Option[string] {.closure.}
    ## Supplies the identity of an observed access to a physical path in
    ## place of the one read from disk; `none` keeps the disk's. The engine
    ## uses it for directories above build-graph outputs, whose listing on
    ## disk depends on which OTHER actions have run here (the graph view the
    ## lookup side computes too).

proc computePortableFingerprint*(roots: openArray[LogicalRoot];
                                 argv: openArray[string]; cwd: string;
                                 env: openArray[(string, string)];
                                 declaredInputs: openArray[string];
                                 reads, probes, enumerations:
                                   openArray[string];
                                 staticFields: openArray[string] = [];
                                 observedEnv: openArray[ObservedEnv] = [];
                                 identify: PhysicalIdentity = nil):
    PortableFingerprint =
  ## Everything at once. Deduplicates each observation class by logical path
  ## (the monitor reports repeats), drops untracked accesses, and marks the
  ## action not portable at the first access under no known root.
  ## `identify`, when given, overrides the on-disk identity of a tracked
  ## access (see `PhysicalIdentity`).
  result.portable = true
  result.weakHex = portableWeakFingerprint(roots, argv, cwd, env,
    declaredInputs, staticFields)
  var seen: seq[string] = @[]
  var rootKeys: seq[string] = @[]
  for root in roots:
    rootKeys.add(normalizeForCompare(root.path))
  proc aboveARoot(physical: string): bool =
    ## A directory that CONTAINS a root. Probing it answers "present" on
    ## every host where the root exists at all — a shell resolving a path
    ## component by component does exactly that — so the probe says nothing
    ## about the build, only about where this host keeps it.
    let key = normalizeForCompare(physical)
    for rootKey in rootKeys:
      if rootKey.len > key.len and rootKey.startsWith(key) and
          (key.endsWith("/") or rootKey[key.len] == '/'):
        return true
    false
  template consider(physical: string; inputKind: PortableInputKind;
                    identity: untyped) =
    let logical = toLogicalPath(roots, physical)
    case logical.kind
    of lpkUntracked:
      discard
    of lpkOutside:
      # A directory ABOVE a root: probing it is implied by the root
      # existing, and LISTING it (gemini-cli's bundle step enumerates the
      # drive root) observes only how this host lays out everything else it
      # stores there. Neither is an input of the build. The residual — a
      # tool that lists a directory above the project and acts on what it
      # finds — is the one BuildXL leaves to mount configuration too.
      # A READ of such a directory is a handle opened while resolving a
      # real path (node's realpath opens every component); a directory has
      # no content to read, so it says no more than the probe.
      if aboveARoot(physical):
        continue
      if inputKind == pikProbe:
        let ancestorKey = ancestorProbeKey(roots, physical)
        if ancestorKey.len > 0:
          let key = $ord(pikProbe) & "|" & ancestorKey
          if key notin seen:
            seen.add(key)
            result.inputs.add(PortableInput(kind: pikProbe, path: ancestorKey,
              digest: ancestorProbeIdentity(roots, ancestorKey)))
          continue
      if result.portable:
        result.portable = false
        result.reason = "observed " & $inputKind & " outside every logical " &
          "root: " & physical
    of lpkTracked:
      let key = $ord(inputKind) & "|" & render(logical)
      if key notin seen:
        seen.add(key)
        let given =
          if identify != nil: identify(physical, inputKind)
          else: none(string)
        result.inputs.add(PortableInput(kind: inputKind, path: render(logical),
          digest: (if given.isSome: given.get() else: identity)))
  for path in reads:
    consider(path, pikRead, readIdentity(path))
  for path in probes:
    consider(path, pikProbe,
      (if fileExists(extendedPath(path)) or dirExists(extendedPath(path)):
         ProbePresent
       else: ProbeAbsent))
  for path in enumerations:
    consider(path, pikEnumeration, membershipHex(path))
  for variable in observedEnv:
    let key = envInputKey(variable.name)
    if ($ord(pikEnvironment) & "|" & key) notin seen:
      seen.add($ord(pikEnvironment) & "|" & key)
      result.inputs.add(PortableInput(kind: pikEnvironment, path: key,
        digest: envIdentity(roots, variable.present, variable.value)))
  if result.portable:
    result.strongHex = portableStrongFingerprint(result.weakHex,
      result.inputs)

const TreeDomain = "reprobuild.portable.tree.v1"

proc treeEntries*(dir: string): seq[TreeEntry] =
  ## Every entry beneath `dir`: a file with its BLAKE3 content digest, a
  ## symlink with its target text, a directory by its presence (so an empty
  ## directory still counts). Symlinked directories are not descended into.
  ##
  ## Walked in the extended-length form: an entry whose full path passes
  ## MAX_PATH used to fail `getFileInfo` and be skipped SILENTLY, so a tree
  ## with deep names (gemini-cli's test snapshots) got a manifest missing
  ## files, and a digest no other walk of the same tree reproduced.
  let root = extendedPath(dir)
  for path in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir,
      pcLinkToDir}, relative = true, followFilter = {pcDir}):
    let full = root / path
    let rel = path.replace('\\', '/')
    let info =
      try: getFileInfo(full, followSymlink = false)
      except CatchableError: continue
    case info.kind
    of pcLinkToFile, pcLinkToDir:
      let target =
        try: expandSymlink(full).replace('\\', '/')
        except CatchableError: ""
      let toDir = info.kind == pcLinkToDir or dirExists(full)
      result.add(TreeEntry(rel: rel,
        kind: if toDir: tekLinkToDir else: tekLinkToFile, identity: target))
    of pcDir:
      result.add(TreeEntry(rel: rel, kind: tekDirectory))
    of pcFile:
      result.add(TreeEntry(rel: rel, kind: tekFile,
        identity: fileContentHex(full)))
  result.sort(proc (a, b: TreeEntry): int = cmp(a.rel, b.rel))

proc treeDigestOf*(entries: openArray[TreeEntry]): string =
  ## Content identity of a tree from its entries: the sorted (relative path,
  ## kind, identity) triples. Physical location plays no part: two copies of
  ## one tree at different absolute paths agree.
  var framed: seq[string] = @[]
  for entry in entries:
    let tag =
      case entry.kind
      of tekFile: "f"
      of tekDirectory: "d"
      of tekLinkToFile: "l"
      of tekLinkToDir: "L"
    framed.add(frame(entry.rel) & frame(tag) & frame(entry.identity))
  framed.sort()
  blake3.digest(frame(TreeDomain) & framed.join("")).toHex()

proc treeContentHex*(dir: string): string =
  ## Content identity of a directory tree (see `treeDigestOf`).
  treeDigestOf(treeEntries(dir))

proc childNames*(entries: openArray[TreeEntry]; relDir: string): seq[string] =
  ## The membership names of `relDir` ("" for the tree root) according to a
  ## tree manifest, suffixed `/` for directories: what `membershipHex` would
  ## list on disk.
  let prefix = if relDir.len == 0: "" else: relDir & "/"
  for entry in entries:
    if not entry.rel.startsWith(prefix):
      continue
    let rest = entry.rel[prefix.len .. ^1]
    if rest.len == 0 or '/' in rest:
      continue
    result.add(rest &
      (if entry.kind in {tekDirectory, tekLinkToDir}: "/" else: ""))

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
    if dirExists(extendedPath(physical)):
      let entries = treeEntries(physical)
      result.outputs.add(PortableOutput(path: render(logical),
        digest: treeDigestOf(entries), directory: true, entries: entries))
    elif fileExists(extendedPath(physical)):
      result.outputs.add(PortableOutput(path: render(logical),
        digest: fileContentHex(physical)))
    else:
      result.portable = false
      result.reason = "declared output does not exist: " & physical
      return
  result.outputs.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))
