## Test support (not a test): repositories with submodules for the NPC-M13
## tests (spec § 6.1, "Submodule sources"), on top of `generator_fixtures`.
##
## Every repository is a local bare repository served by `git http-backend`
## behind the fixture's TLS listener, and the generator and the client reach
## it through the production egress policy (see `generator_fixtures`). A
## submodule URL in a fixture's `.gitmodules` is therefore an
## `https://forge.test:<port>/...` URL, or a relative one resolved against
## such a URL.
##
## `craftedCommit` writes a commit whose tree git's porcelain would refuse to
## build (two entries of one name: a symbolic link `lib` and a directory
## `lib/` holding a gitlink), the way a hostile origin can serve one: git
## neither checks served trees nor fetched ones by default.

import std/[algorithm, options, os, strutils, tables]

import repro_domain_types/nimble_index
import repro_multihash
import repro_nimble_generator
import repro_nimble_index

import ./generator_fixtures

export generator_fixtures

type
  Expected* = object
    ## One entry of a composed tree, as a test expects it.
    path*, content*: string
    kind*: CanonicalEntryKind

  Crafted* = object
    ## One entry of a crafted tree: a blob (`100644`, `100755`, `120000`)
    ## with its content, or a gitlink (`160000`) to ``oid``.
    mode*, path*, content*, oid*: string

proc gitmodules*(entries: seq[(string, string)]): FileSpec =
  ## A `.gitmodules` with one section per (path, url).
  var t = ""
  for (p, u) in entries:
    t.add "[submodule \"" & p & "\"]\n\tpath = " & p & "\n\turl = " & u & "\n"
  file(".gitmodules", t)

proc served*(f: Fixture; path: string; files: seq[FileSpec];
             tags: seq[string] = @[]): tuple[work, commit: string] =
  ## A served repository at ``path`` with one commit of ``files``, tagged.
  let w = f.newRepo(path)
  let c = w.commit(files)
  for t in tags: w.tag(t)
  w.publish()
  (w, c)

proc registryOf*(f: Fixture; pkgs: seq[(string, string)]):
    tuple[url, commit: string] =
  let reg = f.newRepo("nim-lang/packages.git")
  let c = reg.commit(@[packagesJson(pkgs)])
  reg.publish()
  (f.url("nim-lang/packages.git"), c)

proc generation*(f: Fixture; reg: tuple[url, commit: string]; at: uint64;
                 state: string; previous = ""; outputDir = "";
                 mirror = ""; observer: NetworkObserver = nil):
                   GenerationResult =
  let ss = parseSourceSet(sourceSetText(reg.url, reg.commit,
    mirror = mirror), "s.toml")
  var cfg = f.genConfig(ss, at, state, previous = previous,
    outputDir = outputDir)
  cfg.observer = observer
  generate(cfg)

proc recordOf*(b: BuiltIndex; name, tag: string): Option[VersionRecord] =
  if not b.hasPackage(name): return none(VersionRecord)
  for v in b.envelopeOf(name).versions:
    if v.version.tag == tag: return some(v)
  none(VersionRecord)

proc goneOf*(g: GenerationResult; pkg: string): seq[OriginEvent] =
  for e in g.events:
    if e.kind == oeGone and e.package == pkg: result.add e

proc executedOf*(g: GenerationResult; family: EdgeFamily): seq[string] =
  for e in g.executed:
    if e.family == family: result.add e.subject

proc expectedTree*(entries: seq[Expected]): string =
  ## The canonical tree digest (hex) of ``entries``, computed here from the
  ## content the test wrote, not by the generator.
  var typed: seq[CanonicalTreeEntry]
  for e in entries:
    typed.add CanonicalTreeEntry(path: e.path, kind: e.kind,
      content: e.content)
  canonicalTreeMultihash(typed)["blake3:".len .. ^1]

proc expectFile*(path, content: string): Expected =
  Expected(path: path, content: content, kind: cekRegular)
proc expectLink*(path, target: string): Expected =
  Expected(path: path, content: target, kind: cekSymlink)

proc linuxPlatform*(): NimblePlatform =
  NimblePlatform(id: "linux-amd64", targetOs: "linux", targetCpu: "amd64",
    hostOs: "linux", hostCpu: "amd64")

proc offeredTags*(b: BuiltIndex; name: string): seq[string] =
  ## The tags of ``name`` the solver input offers on linux-amd64.
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  let input = solverInput(idx, [name], linuxPlatform())
  for p in input.packages:
    if nameKey(p.name) != nameKey(name): continue
    for c in p.candidates:
      if c.offered: result.add c.record.version.tag
  result.sort()

proc exclusionsOf*(b: BuiltIndex; name, tag: string): seq[ExclusionKind] =
  var idx = openIndex(memorySource(b.objectTable()), b.rootId)
  let input = solverInput(idx, [name], linuxPlatform())
  for p in input.packages:
    if nameKey(p.name) != nameKey(name): continue
    for c in p.candidates:
      if c.record.version.tag == tag:
        for x in c.exclusions: result.add x.kind

# ---------------------------------------------------------------------------
# Crafted trees
# ---------------------------------------------------------------------------

proc hexBytes(h: string): string =
  for i in countup(0, h.len - 2, 2):
    result.add chr(parseHexInt(h[i .. i + 1]))

proc writeTree(bare: string; entries: seq[Crafted]): string =
  ## The tree object of ``entries`` (paths relative to it), subtrees
  ## written first. An entry and a subtree of one name are both kept.
  var leaves: seq[(string, string, string)] ## (mode, name, oid)
  var groups = initOrderedTable[string, seq[Crafted]]()
  for e in entries:
    let slash = e.path.find('/')
    if slash < 0:
      let oid =
        if e.mode == "160000": e.oid
        else: run(["git", "--git-dir=" & bare, "hash-object", "-w",
                   "--stdin"], input = e.content).strip()
      leaves.add (e.mode, e.path, oid)
    else:
      var rest = e
      rest.path = e.path[slash + 1 .. ^1]
      groups.mgetOrPut(e.path[0 ..< slash], @[]).add rest
  for name, children in groups:
    leaves.add ("40000", name, writeTree(bare, children))
  leaves.sort(proc (a, b: (string, string, string)): int = cmp(a[1], b[1]))
  var body = ""
  for (mode, name, oid) in leaves:
    body.add mode & " " & name & "\0" & hexBytes(oid)
  run(["git", "--git-dir=" & bare, "hash-object", "-w", "--literally", "-t",
    "tree", "--stdin"], input = body).strip()

proc craftedCommit*(f: Fixture; path: string; entries: seq[Crafted];
                    tagName: string): string =
  ## A commit of the crafted tree ``entries`` written straight into the
  ## served repository ``path`` (created when absent), tagged ``tagName``.
  let bare = f.root / path
  if not dirExists(bare):
    discard f.newRepo(path)
  let tree = writeTree(bare, entries)
  result = run(["git", "--git-dir=" & bare, "commit-tree", tree, "-m",
    "crafted"], env = gitEnv()).strip()
  discard run(["git", "--git-dir=" & bare, "update-ref",
    "refs/tags/" & tagName, result], env = gitEnv())

proc blob*(path, content: string): Crafted =
  Crafted(mode: "100644", path: path, content: content)
proc linkBlob*(path, target: string): Crafted =
  Crafted(mode: "120000", path: path, content: target)
proc gitlinkEntry*(path, commit: string): Crafted =
  Crafted(mode: "160000", path: path, oid: commit)
