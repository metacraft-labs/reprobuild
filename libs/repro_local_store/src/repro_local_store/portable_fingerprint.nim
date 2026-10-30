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
## Campaign M17 chunk 2 (the published-trace record `rbpm-v2`,
## Edge-Derived-Identities.md §3.1 and §3.3): every content, membership and
## environment digest is BLAKE3-256 under ONE dedicated domain
## (`PublishedDigestDomain`); an input's identity states what stands at its
## path (`InputEntryKind`) and, for a file, its executable bit (`file:<hex>`
## / `exec:<hex>`), and a probe's identity is the kind it found, not just
## "present"; every input carries its ROLE, declared or observed. These are
## THE identity functions of a published record: the two-phase peer cache
## uses them too (`two_phase.observedIdentity`). The local action cache keeps
## its own XXH3-64 identity, untouched.
##
## Pure over strings and the filesystem: the engine adapts its own action and
## evidence types to these procs, which keeps this module testable alone.

import std/[algorithm, options, os, strutils]

from repro_core/link_target import readSymlinkTarget
from repro_core/paths import extendedPath
import ./pattern_scoped_enumeration
when defined(posix):
  from std/posix import Stat, stat, S_ISREG

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

  InputRole* = enum
    ## Campaign M17 chunk 2 (Edge-Derived-Identities.md §3.1): whether an
    ## input is one the action DECLARED or one its execution was OBSERVED
    ## accessing. A published record keeps the two apart, so a consumer that
    ## misses can say which kind of input differed. `irObserved` is first so
    ## an input built without a role is an observed one, as every input was
    ## before the split.
    irObserved = "observed"
    irDeclared = "declared"

  InputEntryKind* = enum
    ## What stands at an input's path, as a published record states it
    ## (Edge-Derived-Identities.md §2.1 / §3.1, "its kind (regular file,
    ## directory, symlink)"). Every access identity below is ONE of these plus,
    ## for a file, its executable bit and content digest; the record codec
    ## (`portable_memo.nim`, `rbpm-v2`) carries them as separate fields.
    iekAbsent = "absent"
    iekFile = "file"
    iekDirectory = "directory"
    iekSymlink = "symlink"
      ## Reserved for the shared identity function of M17 chunk 4, which
      ## decides how a symbolic link is identified on every walk. Today a link
      ## is FOLLOWED (as it always was on the portable walk) and identified as
      ## what it resolves to; no identity is produced with this kind.
    iekSpecial = "special"
      ## A device, FIFO or socket: something whose "content" is not a fixed
      ## byte string.
    iekValue = "value"
      ## An environment variable that is set (its identity is the digest of
      ## its logicalized value); an unset one is `iekAbsent`.

  PortableInput* = object
    kind*: PortableInputKind
    path*: string    ## `<label>:<rel>`.
    digest*: string
      ## The input's IDENTITY TEXT: what stands at the path, its executable
      ## bit and its content / membership / value digest, in the one canonical
      ## spelling `readIdentity`, `probeIdentity`,
      ## `membershipHex` and `envIdentity` produce (e.g. `file:<hex>`, `exec:<hex>`,
      ## `directory`, `absent`). The strong fingerprint is computed over it, so
      ## a kind or executable-bit change moves the fingerprint exactly as a
      ## content change does.
    role*: InputRole

  TreeEntryKind* = enum
    tekFile
    tekDirectory
    tekLinkToFile
    tekLinkToDir

  TreeEntry* = object
    rel*: string            ## `/`-separated, relative to the tree root.
    kind*: TreeEntryKind
    identity*: string       ## A file's BLAKE3 digest, a link's target text.
    executable*: bool
      ## A file's executable bit (`executableBit`), part of the tree digest:
      ## a downstream read of the file is identified with it.

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
    executable*: bool
      ## A file output's executable bit: a downstream action that reads the
      ## output is identified with it (lookup without materialization takes
      ## the read's identity from this record), so it is part of the record.
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
  StrongDomain = "reprobuild.portable.strong.v2"
    ## v2 (campaign M17 chunk 2, `rbpm-v2`): each input's ROLE (declared or
    ## observed) is framed with it, and its identity text carries its entry
    ## kind and executable bit. A v1 strong fingerprint is never recomputed.
  PublishedDigestDomain* = "reprobuild.published-digest.v1"
    ## THE dedicated hash domain of every digest a published record carries
    ## for an input or output: file content, directory membership and
    ## environment values (Edge-Derived-Identities.md §3.3 and its rider of
    ## 2026-10-27; §10 decision 13). Defined here once; every published digest
    ## is BLAKE3-256 over `frame(PublishedDigestDomain) & frame(<purpose>)`
    ## followed by the payload (`publishedDigestHasher`). A digest of the same
    ## bytes without the domain, or under any other domain, is a different
    ## value and never verifies. The LOCAL hash (XXH3-64, `localHash`) is
    ## untouched: it stays the digest of local records and same-machine checks.
  ProbeAbsent* = "absent"
    ## The identity of a PROBE whose target does not exist. A probe whose
    ## target exists is identified by the KIND it found (`probeIdentity`):
    ## `file`, `directory` or `special`. (Until `rbpm-v2` every present target
    ## was `present`, so a file replaced by a directory at a probed path went
    ## unseen on the portable walk, while the local walk compared the kind.)

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

proc probeIdentity*(path: string): string

proc ancestorProbeIdentity*(roots: openArray[LogicalRoot]; key: string):
    string =
  ## The identity of an `^<label>:<rest>` key on THIS host: the probe
  ## identity (`probeIdentity`, the KIND found) of `<rest>` beneath the
  ## nearest proper ancestor of root `<label>` that has it, else "absent";
  ## "" when the key names no root here.
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
          return probeIdentity(candidate)
      return ProbeAbsent
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

proc frame(text: string): string =
  ## Length-prefixed so field boundaries cannot be forged by content.
  $text.len & ":" & text

type
  PublishedDigestPurpose* = enum
    ## What a published digest is OF. Framed after `PublishedDigestDomain`,
    ## so a membership digest can never equal a content digest of bytes that
    ## happen to spell the same names.
    pdpContent = "content"
    pdpMembership = "membership"
    pdpEnvironment = "environment"

proc publishedDigestHasher*(purpose: PublishedDigestPurpose): Blake3Hasher =
  ## A BLAKE3-256 hasher already fed the domain prefix of `purpose`; the
  ## caller streams the payload into it and finalizes. The one place the
  ## prefix is spelled (see `PublishedDigestDomain`).
  result = initHasher()
  result.update(frame(PublishedDigestDomain) & frame($purpose))

proc publishedDigestHex*(purpose: PublishedDigestPurpose;
                         payload: openArray[byte]): string =
  let hasher = publishedDigestHasher(purpose)
  defer: hasher.close()
  hasher.update(payload)
  hasher.finalize().toHex()

proc publishedDigestHex*(purpose: PublishedDigestPurpose;
                         payload: string): string =
  publishedDigestHex(purpose, payload.toOpenArrayByte(0, payload.high))

proc fileContentHex*(path: string): string =
  ## The published content digest of a file: BLAKE3-256 of its bytes under
  ## `PublishedDigestDomain` (purpose `content`), streamed. "" when it cannot
  ## be read.
  var f: File
  if not open(f, extendedPath(path), fmRead):
    return ""
  defer: close(f)
  let hasher = publishedDigestHasher(pdpContent)
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
  ## directory (or a link to one). Order-insensitive. Under
  ## `PublishedDigestDomain`, purpose `membership`.
  var sorted = @names
  sorted.sort()
  publishedDigestHex(pdpMembership, sorted.join("\n"))

proc executableBit*(path: string): bool =
  ## The executable bit of the file at `path`, following a symbolic link as
  ## every portable identity does: the OWNER's execute permission
  ## (`S_IXUSR`), the bit git records as `100755` and the one an owner's
  ## `exec` needs. Always false on Windows, which has no such bit (a Windows
  ## record states false for every file, and a record from a host that set
  ## it does not verify there: a miss, never a wrong hit).
  when defined(posix):
    var st: Stat
    if stat(extendedPath(path).cstring, st) != 0:
      return false
    (int(st.st_mode) and 0o100) != 0
  else:
    false

proc entryKindAt*(path: string): InputEntryKind =
  ## What stands at `path`, following a symbolic link: a dangling link is
  ## absent, as it always was on the portable walk (how a link itself is
  ## identified is the shared identity function's, M17 chunk 4).
  let p = extendedPath(path)
  if dirExists(p):
    return iekDirectory
  when defined(posix):
    var st: Stat
    if stat(p.cstring, st) != 0:
      return iekAbsent
    if S_ISREG(st.st_mode): iekFile else: iekSpecial
  else:
    if fileExists(p): iekFile else: iekAbsent

const
  ReadOfAbsent* = "absent"
    ## The identity of a READ whose target does not exist.
  ReadOfDirectory* = "directory"
    ## The identity of a READ whose target is a directory.
  ReadOfSpecial* = "special"
    ## The identity of a READ whose target is a device, FIFO or socket.
  ReadOfUnreadable* = "unreadable"
    ## The identity of a READ of a regular file whose bytes cannot be read: a
    ## file with no content digest. No published record may carry one (the
    ## publication rule refuses a regular-file input without a digest).
  EnvUnset* = "unset"
    ## The identity of an observed environment variable that is not set.

func fileIdentity*(digest: string; executable: bool): string =
  ## The identity text of a READ of a regular file: its executable bit and
  ## its published content digest, `file:<hex>` or `exec:<hex>`.
  if digest.len == 0: ReadOfUnreadable
  elif executable: "exec:" & digest
  else: "file:" & digest

func probeIdentityOf*(kind: InputEntryKind): string =
  ## The identity text of a PROBE that found `kind`.
  case kind
  of iekAbsent: ProbeAbsent
  of iekFile: "file"
  of iekDirectory: "directory"
  of iekSymlink: "symlink"
  of iekSpecial: "special"
  of iekValue: "value"

proc readIdentity*(path: string): string =
  ## The identity of an observed READ of `path`, the same on the recording
  ## side and the lookup side: what stands there, and for a regular file its
  ## executable bit and published content digest (`fileIdentity`).
  ##
  ## Reads of files that do not exist are common, not exotic: node's module
  ## resolution tries to open `package.json` at every level it walks, and
  ## the monitor records each failed open as a read. The recorder used to
  ## identify such a read as "" (nothing could be hashed) while the lookup
  ## answered "cannot identify" -- so a path set holding even one of them
  ## could never be evaluated, on any host, the recording one included.
  ## gemini-cli's bundle step had 125.
  case entryKindAt(path)
  of iekFile: fileIdentity(fileContentHex(path), executableBit(path))
  of iekDirectory: ReadOfDirectory
  of iekSpecial: ReadOfSpecial
  else: ReadOfAbsent

proc probeIdentity*(path: string): string =
  ## The identity of an observed PROBE of `path`: the kind it finds.
  probeIdentityOf(entryKindAt(path))

func namesMatchingScope*(names: openArray[string];
                         pattern: string): seq[string] =
  ## The membership names (each suffixed `/` for a directory, as
  ## `membershipHexOfNames` takes them) whose entry may match `pattern`, or
  ## all of them for an empty pattern. One filter for the listing read from
  ## disk and for the one a graph view predicts, so the two agree.
  for name in names:
    let bare =
      if name.len > 1 and name.endsWith("/"): name[0 ..< name.len - 1]
      else: name
    if pattern.len == 0 or globComponentMatches(pattern, bare):
      result.add(name)

proc membershipHex*(dir: string): string =
  ## Membership digest of a directory: the sorted child names, each suffixed
  ## `/` for a directory. Names only — an enumeration observes WHICH entries
  ## exist, not their content (reads of those entries are separate inputs).
  ## A PATTERN-SCOPED name (`patternScopedEnumerationPath`) digests only the
  ## entries of its directory that may match its pattern.
  let (base, pattern) = splitPatternScopedEnumeration(dir)
  var names: seq[string] = @[]
  try:
    for kind, entry in walkDir(extendedPath(base), relative = true):
      names.add(entry.replace('\\', '/') &
        (if kind in {pcDir, pcLinkToDir}: "/" else: ""))
  except CatchableError:
    return ""
  membershipHexOfNames(names.namesMatchingScope(pattern))

proc envIdentity*(roots: openArray[LogicalRoot]; present: bool;
                  value: string): string =
  ## The identity of an observed environment variable: "unset", or the
  ## published digest (purpose `environment`) of its value with every tracked
  ## root's path logicalized — so a value naming a path inside the project is
  ## the same on every checkout, and one naming a host path (a PATH entry in a
  ## home directory) is not.
  if not present:
    return EnvUnset
  publishedDigestHex(pdpEnvironment, logicalizeText(roots, value))

# --- identity text <-> (entry kind, executable bit, digest) -----------------

type
  IdentityParts* = object
    ## An identity text taken apart, as the `rbpm-v2` record carries it.
    entryKind*: InputEntryKind
    executable*: bool
    digest*: string

func isHexDigest(text: string): bool =
  if text.len != 64:
    return false
  for ch in text:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

func identityParts*(access: PortableInputKind; identity: string;
                    parts: var IdentityParts): bool =
  ## Splits the identity text of an input accessed as `access` into its
  ## entry kind, executable bit and digest. False for a text no identity
  ## function of this module produces for that access.
  ##
  ## The ancestor-probe identity (`ancestorProbeIdentity`) is a probe's.
  parts = IdentityParts()
  case access
  of pikRead:
    if identity == ReadOfAbsent: parts.entryKind = iekAbsent
    elif identity == ReadOfDirectory: parts.entryKind = iekDirectory
    elif identity == ReadOfSpecial: parts.entryKind = iekSpecial
    elif identity == ReadOfUnreadable: parts.entryKind = iekFile
    elif identity.startsWith("file:") and isHexDigest(identity[5 .. ^1]):
      parts = IdentityParts(entryKind: iekFile, digest: identity[5 .. ^1])
    elif identity.startsWith("exec:") and isHexDigest(identity[5 .. ^1]):
      parts = IdentityParts(entryKind: iekFile, executable: true,
        digest: identity[5 .. ^1])
    else:
      return false
  of pikProbe:
    case identity
    of ProbeAbsent: parts.entryKind = iekAbsent
    of "file": parts.entryKind = iekFile
    of "directory": parts.entryKind = iekDirectory
    of "special": parts.entryKind = iekSpecial
    else: return false
  of pikEnumeration:
    if not isHexDigest(identity):
      return false
    parts = IdentityParts(entryKind: iekDirectory, digest: identity)
  of pikEnvironment:
    if identity == EnvUnset:
      parts.entryKind = iekAbsent
    elif isHexDigest(identity):
      parts = IdentityParts(entryKind: iekValue, digest: identity)
    else:
      return false
  true

func identityFromParts*(access: PortableInputKind; parts: IdentityParts;
                        identity: var string): bool =
  ## Inverse of `identityParts`: the one canonical identity text, or false
  ## for a combination no identity function produces (an executable
  ## directory, a digest on a probe, ...).
  if parts.executable and (access != pikRead or parts.entryKind != iekFile):
    return false
  case access
  of pikRead:
    case parts.entryKind
    of iekAbsent, iekDirectory, iekSpecial:
      if parts.digest.len != 0: return false
      identity = (if parts.entryKind == iekAbsent: ReadOfAbsent
                  elif parts.entryKind == iekDirectory: ReadOfDirectory
                  else: ReadOfSpecial)
    of iekFile:
      if parts.digest.len != 0 and not isHexDigest(parts.digest):
        return false
      identity = fileIdentity(parts.digest, parts.executable)
    else:
      return false
  of pikProbe:
    if parts.digest.len != 0 or
        parts.entryKind notin {iekAbsent, iekFile, iekDirectory, iekSpecial}:
      return false
    identity = probeIdentityOf(parts.entryKind)
  of pikEnumeration:
    if parts.entryKind != iekDirectory or not isHexDigest(parts.digest):
      return false
    identity = parts.digest
  of pikEnvironment:
    case parts.entryKind
    of iekAbsent:
      if parts.digest.len != 0: return false
      identity = EnvUnset
    of iekValue:
      if not isHexDigest(parts.digest): return false
      identity = parts.digest
    else:
      return false
  true

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
  ## Weak fingerprint plus every input's identity -- declared and observed,
  ## each framed with its role -- in a canonical order (role, kind, then
  ## logical path) so the monitor's observation order cannot change it.
  var sortedInputs = @inputs
  sortedInputs.sort(proc (a, b: PortableInput): int =
    result = cmp(ord(a.role), ord(b.role))
    if result == 0:
      result = cmp(ord(a.kind), ord(b.kind))
    if result == 0:
      result = cmp(a.path, b.path))
  var payload = frame(StrongDomain)
  payload.add(frame(weakHex))
  payload.add(frame($sortedInputs.len))
  for input in sortedInputs:
    payload.add(frame($input.role))
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
  ##
  ## An access of a path the action DECLARED as an input carries the role
  ## `irDeclared`; every other access is `irObserved` (Edge-Derived-
  ## Identities.md §3.1: declared inputs are kept apart from observed ones,
  ## each bound by content). The set of inputs is exactly the accesses given:
  ## the role labels them, it adds and removes none (the caller's filters --
  ## an action's own outputs, its transient writes -- apply to declared
  ## inputs as to every other access).
  result.portable = true
  result.weakHex = portableWeakFingerprint(roots, argv, cwd, env,
    declaredInputs, staticFields)
  var declaredKeys: seq[string] = @[]
  for input in declaredInputs:
    declaredKeys.add(normalizeForCompare(input))
  var seen: seq[string] = @[]
  var rootKeys: seq[string] = @[]
  for root in roots:
    rootKeys.add(normalizeForCompare(root.path))
  proc aboveARoot(physical: string): bool =
    ## A directory that CONTAINS a root. Probing it answers "present" on
    ## every host where the root exists at all — a shell resolving a path
    ## component by component does exactly that — so the probe says nothing
    ## about the build, only about where this host keeps it. A
    ## PATTERN-SCOPED listing (`patternScopedEnumerationPath`) is in its
    ## directory: Nim's compiler globs `*.nimble` in every directory above a
    ## module, and that scan of an ancestor says no more than a full one.
    let key = normalizeForCompare(physical.patternScopedBase())
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
        let role =
          if normalizeForCompare(physical) in declaredKeys: irDeclared
          else: irObserved
        result.inputs.add(PortableInput(kind: inputKind, path: render(logical),
          digest: (if given.isSome: given.get() else: identity), role: role))
  for path in reads:
    consider(path, pikRead, readIdentity(path))
  for path in probes:
    consider(path, pikProbe, probeIdentity(path))
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

const TreeDomain = "reprobuild.portable.tree.v2"
  ## v2 (`rbpm-v2`): a file entry's identity is its published content
  ## digest, and an executable file is tagged apart from a plain one.

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
        try: readSymlinkTarget(full).replace('\\', '/')
        except CatchableError: ""
      let toDir = info.kind == pcLinkToDir or dirExists(full)
      result.add(TreeEntry(rel: rel,
        kind: if toDir: tekLinkToDir else: tekLinkToFile, identity: target))
    of pcDir:
      result.add(TreeEntry(rel: rel, kind: tekDirectory))
    of pcFile:
      result.add(TreeEntry(rel: rel, kind: tekFile,
        identity: fileContentHex(full), executable: executableBit(full)))
  result.sort(proc (a, b: TreeEntry): int = cmp(a.rel, b.rel))

proc treeDigestOf*(entries: openArray[TreeEntry]): string =
  ## Content identity of a tree from its entries: the sorted (relative path,
  ## kind, identity) triples. Physical location plays no part: two copies of
  ## one tree at different absolute paths agree.
  var framed: seq[string] = @[]
  for entry in entries:
    let tag =
      case entry.kind
      of tekFile: (if entry.executable: "x" else: "f")
      of tekDirectory: "d"
      of tekLinkToFile: "l"
      of tekLinkToDir: "L"
    framed.add(frame(entry.rel) & frame(tag) & frame(entry.identity))
  framed.sort()
  blake3.digest(frame(TreeDomain) & framed.join("")).toHex()

func readIdentityOf*(entry: TreeEntry): string =
  ## The identity a READ of `entry` has (`readIdentity`), from a manifest.
  case entry.kind
  of tekFile: fileIdentity(entry.identity, entry.executable)
  of tekDirectory, tekLinkToDir: ReadOfDirectory
  of tekLinkToFile: ""   # what the link resolves to is not in the manifest

func readIdentityOf*(output: PortableOutput): string =
  ## The identity a READ of `output`'s path has (`readIdentity`), from its
  ## record.
  if output.directory: ReadOfDirectory
  else: fileIdentity(output.digest, output.executable)

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
        digest: fileContentHex(physical),
        executable: executableBit(physical)))
    else:
      result.portable = false
      result.reason = "declared output does not exist: " & physical
      return
  result.outputs.sort(proc (a, b: PortableOutput): int = cmp(a.path, b.path))
