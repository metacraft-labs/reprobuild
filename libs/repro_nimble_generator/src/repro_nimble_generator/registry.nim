## The Nimble registry, `packages.json` of `nim-lang/packages`, read at a
## pinned commit by the generator's `registry` edge.
##
## JSON is upstream's format, read here and never stored: the edge's output
## is the registry's bytes, and what the generator keeps is the list below.
## An entry this reader cannot use is skipped with a reason rather than
## guessed at.

import std/[algorithm, json, strutils, tables]

import repro_domain_types/nimble_index/types

import ./source_set

const MaxRegistryBytes* = 64 * 1024 * 1024

type
  RegistryPackage* = object
    name*: string
    vcs*: OriginVcs
    url*: string    ## without the `?subdir=` query
    subdir*: string

  RegistryAlias* = object
    alias*, target*: string

  Registry* = object
    packages*: seq[RegistryPackage] ## sorted by name key
    aliases*: seq[RegistryAlias]    ## sorted by name key
    skipped*: seq[(string, string)] ## (name or index, reason)

proc printable(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if ord(c) < 0x21 or ord(c) > 0x7e: return false
  true

const UnspellableNameChars* = {'.', '/', ':'}
  ## What a package name after `nimble:` cannot hold (NPC-AREQ3): `.` and
  ## `/` are the grammar's own separators, and `:` the namespace's.

proc unspellableNameChar*(name: string): char =
  ## The first character of ``name`` that `nimble:<name>` cannot spell, or
  ## `\0` when there is none.
  for c in name:
    if c in UnspellableNameChars: return c
  '\0'

proc parseRegistry*(bytes: string): Registry =
  ## Read `packages.json`. Raises `ValueError` when it is not a JSON array.
  if bytes.len > MaxRegistryBytes:
    raise newException(ValueError, "packages.json is larger than " &
      $MaxRegistryBytes & " bytes")
  let doc = parseJson(bytes)
  if doc.kind != JArray:
    raise newException(ValueError, "packages.json is not a JSON array")
  var byKey = initTable[string, string]()
  for i, e in doc.elems:
    if e.kind != JObject:
      result.skipped.add ($i, "not an object")
      continue
    let name = e{"name"}.getStr("")
    if not printable(name) or name.len > MaxNameBytes:
      result.skipped.add ((if name.len > 0: name else: $i),
        "the name is empty, too long, or not printable ASCII")
      continue
    let unspellable = unspellableNameChar(name)
    if unspellable != '\0':
      # NPC-AREQ3: `uses:` spells a catalog package `nimble:<name>`, and the
      # package-name grammar after the namespace cannot hold these.
      result.skipped.add (name, "the name holds " & ($unspellable).escape() &
        ", which `nimble:<name>` cannot spell (a package name holds no " &
        "`.`, `/` or `:`)")
      continue
    let k = nameKey(name)
    if k in byKey:
      result.skipped.add (name, "its name collides with " & byKey[k] &
        " under the style-insensitive comparison")
      continue
    if e.hasKey("alias"):
      let target = e{"alias"}.getStr("")
      if not printable(target):
        result.skipped.add (name, "an alias without a target")
        continue
      byKey[k] = name
      result.aliases.add RegistryAlias(alias: name, target: target)
      continue
    let url = e{"url"}.getStr("")
    let meth = e{"method"}.getStr("git")
    if url.len == 0:
      result.skipped.add (name, "no url")
      continue
    var vcs: OriginVcs
    case meth
    of "git": vcs = ovGit
    of "hg": vcs = ovHg
    else:
      result.skipped.add (name, "unknown method " & meth.escape())
      continue
    let (u, sub) = splitOriginUrl(url)
    byKey[k] = name
    result.packages.add RegistryPackage(name: name, vcs: vcs, url: u,
      subdir: sub)
  result.packages.sort(proc (a, b: RegistryPackage): int =
    cmp(nameKey(a.name), nameKey(b.name)))
  result.aliases.sort(proc (a, b: RegistryAlias): int =
    cmp(nameKey(a.alias), nameKey(b.alias)))
