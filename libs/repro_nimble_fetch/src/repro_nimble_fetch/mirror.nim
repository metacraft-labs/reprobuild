## Mirrors of Nimble source objects (NPC-AREQ13, NPC-AREQ14).
##
## A mirror is a content-addressed store keyed by digest, so it needs no
## knowledge of Nimble and holds no trust: whatever it serves is checked
## against digests the client already holds. It holds two kinds of object,
## at fixed paths under its base:
##
## | Object | Path | Bytes |
## | --- | --- | --- |
## | source object | `nimble/sources/<t0t1>/<tree>.tar` | the canonical archive of the tree whose digest is `<tree>` (64 hex) |
## | closure index | `nimble/closure/<key>` | the closure index of the lock whose closure key is `<key>` (`closure_index.nim`) |
##
## A mirror is either a local directory (an absolute path) or an `https://`
## base URL. The publisher writes a directory mirror itself; an HTTPS mirror
## is read-only here (its write path is the mirror's own, NPC-M10). A
## client reads either. Neither kind is ever asked to redirect: a read that
## does not answer `200` is a miss.
##
## `missingFromMirrors` is the publish-completeness check of NPC-AREQ13 and
## threat model G12: an index revision is published only when every source
## object it names is present, at its recorded size, on EVERY required mirror.

import std/[os, strutils, tempfiles]

import repro_nimble_generator/egress
import repro_nimble_generator/source_set

import ./https_get

type
  MirrorKind* = enum
    mkDirectory = "directory"
    mkHttps = "https"

  Mirror* = object
    kind*: MirrorKind
    location*: string ## the absolute directory, or the base URL ending in `/`
    required*: bool

  MirrorRead* = object
    found*: bool
    bytes*: string
    failure*: string ## why nothing was read, when not found

  SourceObjectRef* = object
    ## A source object an index names: what a mirror must hold.
    tree*: string    ## 64 lower-case hex
    size*: int64     ## bytes of the canonical archive
    label*: string   ## `<package> <version>`, for diagnostics

  MissingObject* = object
    mirror*: string
    obj*: SourceObjectRef
    detail*: string

const
  SourcesDir* = "nimble/sources"
  ClosureDir* = "nimble/closure"

proc isTreeHex*(s: string): bool =
  s.len == 64 and s.allCharsInSet({'0'..'9', 'a'..'f'})

proc parseMirror*(location: string; required = true): Mirror =
  ## A mirror location: an `https://` base URL or an absolute directory.
  ## Raises `ValueError` otherwise.
  if location.startsWith("https://"):
    discard parseOriginUrl(location)   # the shape rules: no credentials
    Mirror(kind: mkHttps, required: required,
      location: (if location.endsWith("/"): location else: location & "/"))
  elif location.isAbsolute:
    Mirror(kind: mkDirectory, required: required,
      location: location.normalizedPath)
  else:
    raise newException(ValueError, "mirror " & location.escape() &
      " is neither an https:// URL nor an absolute directory")

proc mirrorsOf*(decls: seq[MirrorDecl]): seq[Mirror] =
  ## The mirrors a source set declares, in its order.
  for d in decls:
    result.add parseMirror(d.url, d.role == mrRequired)

proc sourceObjectPath*(tree: string): string =
  ## The relative path of a source object.
  if not isTreeHex(tree):
    raise newException(ValueError, "not a tree digest: " & tree.escape())
  SourcesDir & "/" & tree[0 .. 1] & "/" & tree & ".tar"

proc closureIndexPath*(key: string): string =
  if not isTreeHex(key):
    raise newException(ValueError, "not a closure key: " & key.escape())
  ClosureDir & "/" & key

proc urlOf*(m: Mirror; rel: string): string =
  case m.kind
  of mkHttps: m.location & rel
  of mkDirectory: m.location / rel

proc readObject*(m: Mirror; rel: string; maxBytes: int64;
                 access: EgressPolicy): MirrorRead =
  ## Read one object, at most ``maxBytes``. A miss, an oversize object or a
  ## failed request is `found = false` with the reason.
  case m.kind
  of mkDirectory:
    let p = m.location / rel
    if symlinkExists(p):
      return MirrorRead(failure: p & " is a symbolic link")
    if not fileExists(p):
      return MirrorRead(failure: "not on mirror " & m.location)
    let size = getFileSize(p)
    if size > maxBytes:
      return MirrorRead(failure: p & " is " & $size & " bytes, more than " &
        $maxBytes)
    MirrorRead(found: true, bytes: readFile(p))
  of mkHttps:
    try:
      let a = mirrorRequest(access, "GET", m.location & rel, maxBytes)
      if a.status == 200:
        MirrorRead(found: true, bytes: a.body)
      else:
        MirrorRead(failure: m.location & rel & " answered " & $a.status)
    except EgressError as e:
      MirrorRead(failure: e.msg)
    except CatchableError as e:
      MirrorRead(failure: m.location & rel & ": " & e.msg)

proc objectSize*(m: Mirror; rel: string; access: EgressPolicy):
    tuple[present: bool; size: int64; detail: string] =
  ## Whether the mirror holds ``rel``, and its size, without reading it.
  case m.kind
  of mkDirectory:
    let p = m.location / rel
    if symlinkExists(p) or not fileExists(p):
      return (false, -1'i64, "absent")
    (true, getFileSize(p), "")
  of mkHttps:
    try:
      let a = mirrorRequest(access, "HEAD", m.location & rel, 0)
      if a.status != 200:
        return (false, -1'i64, "answered " & $a.status)
      (true, a.contentLength, "")
    except CatchableError as e:
      (false, -1'i64, e.msg)

proc putObject*(m: Mirror; rel, bytes: string) =
  ## The publisher's write to a directory mirror: atomic (a private temporary
  ## file renamed into place), and a no-op when the object is already there
  ## with the same bytes. Content addressing makes a different object under
  ## the same name a corruption, which is refused rather than overwritten.
  if m.kind != mkDirectory:
    raise newException(IOError, "the publisher writes directory mirrors " &
      "only; " & m.location & " is written by its own service")
  let dest = m.location / rel
  if symlinkExists(dest):
    raise newException(IOError, dest & " is a symbolic link")
  if fileExists(dest):
    if readFile(dest) != bytes:
      raise newException(IOError, dest & " already holds different bytes; " &
        "a content-addressed object is never replaced")
    return
  createDir(parentDir(dest))
  let (f, tmp) = createTempFile(".put-", ".tmp", parentDir(dest))
  try:
    f.write(bytes)
    f.close()
    moveFile(tmp, dest)
  except CatchableError:
    try: removeFile(tmp) except CatchableError: discard
    raise

proc missingFromMirrors*(mirrors: seq[Mirror]; objects: seq[SourceObjectRef];
                         access: EgressPolicy): seq[MissingObject] =
  ## NPC-AREQ13 / G12: every source object absent, or present at another
  ## size, on EVERY required mirror. Optional mirrors are not consulted.
  for m in mirrors:
    if not m.required: continue
    for o in objects:
      let (present, size, detail) = m.objectSize(sourceObjectPath(o.tree),
        access)
      if not present:
        result.add MissingObject(mirror: m.location, obj: o, detail: detail)
      elif size != o.size:
        result.add MissingObject(mirror: m.location, obj: o,
          detail: "holds " & $size & " bytes, the index records " & $o.size)
