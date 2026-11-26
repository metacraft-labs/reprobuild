## Federated catalog discovery from published repositories -- ReproOS-
## Campaign-Completion M6 deliverables 1 and 2, normatively specified by
## ``reprobuild-specs/Federated-Catalog-Imports.md`` § Discovery.
##
## This is the half of discovery that touches the outside world: it reads a
## declared catalog's objects AT A PINNED REVISION and hands the pure half
## (``repro_interface_artifacts/catalog_declaration``) the bytes. It is the
## production supplier of the inputs the M7 provisioning resolver needs and
## a build cannot read out of its own artifact -- the explicitly identified
## catalog imports, the offered contributions' full identities (provider
## identity included), the curator policy and a dependency resolver -- and
## ``provisioning_lock_selection`` installs it as the default
## ``ProvisioningCatalogSource``.
##
## ## Where the bytes come from, and why they can be trusted
##
## A catalog's objects are read from the workspace's SHARED BARE CLONE of
## its declared ``remote`` (``shared_clones.sharedBarePath`` under the
## shared-clone root -- ``REPRO_WORKSPACE_CLONES`` when set), never from a
## checkout's working tree, a checkout's ``HEAD``, a directory next to the
## consumer, or a develop override. Three checks make that store safe to
## read even though it is mutable local state:
##
##   1. the bare must name exactly one ``remote.origin.url``, a fetch must
##      use exactly one URL for ``origin`` once ``url.<base>.insteadOf``
##      rewrites are applied, and both must have an unambiguous shape
##      (``remoteShapeDefect``) and the declared remote's canonical identity
##      (``canonicalRemoteIdentity``) -- the URL slug that names the directory
##      is many-to-one, so this is what stops a cache entry of another
##      repository answering for this one. (It checks what the store SAYS it
##      is a clone of; whoever can write the store can write its refs too, so
##      a moving ``ref`` resolved in it is only as good as that store. A
##      ``commit`` pin is bound by its id, below, whatever the store);
##   2. every object on the path pinned commit -> root tree ->
##      ``published-interfaces`` tree -> each artifact blob is requested by
##      object id and its id is RECOMPUTED from the bytes git returned
##      (``<type> <size>\0<content>``, SHA-1). A corrupted or substituted
##      object, a dereferenced object of another type, or an object the
##      store does not have refuses;
##   3. git runs with replace refs and lazy (promisor) fetches disabled and
##      every ``GIT_*`` variable removed from its environment, so neither
##      the ambient environment nor a replace ref can redirect the read, and
##      discovery never touches the network.
##
## So a dirty checkout, a checkout at another commit, or a sibling directory
## that happens to carry the catalog's name cannot stand in for the pinned
## revision: none of them is read, and the store that is read can only
## return the pinned bytes or refuse.
##
## ## Nothing is compiled or executed
##
## The catalog's provider (its ``repro.nim``) is never compiled, imported or
## run: the contribution records come from the published interface
## artifacts' ``provisioningContributions`` sections, decoded by the
## envelope codec. The only processes started are ``git`` reads.
##
## ## SHA-256 repositories
##
## Refused for now (a false refusal): the object ids of a SHA-256 repository
## are not re-hashed by this module yet.

import std/[algorithm, options, os, osproc, sequtils, streams, strtabs,
            strutils, tables, times]

{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}

import repro_core/ambient_execution
import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration
import repro_interface_artifacts/contribution_fingerprint
import repro_lock
import repro_nimble_index
import repro_nimble_generator/capture
import git_tool
import shared_clones

export catalog_declaration

type
  GitStore = object
    gitBin: string
    gitDir: string

  CatalogDiscoveryError* = object of CatchableError
    ## A declared catalog could not be read at its pinned identity. The
    ## message names every cause and the remedy; nothing falls back.

  DiscoveredCatalog* = object
    ## One catalog, read at one exact revision.
    repo*: string
    remote*: string
    gitRef*: string                 ## the declared moving reference, or "".
    revision*: string               ## full-width lower-case commit id.
    interfaceArtifact*: string      ## RECOMPUTED from the artifacts read.
    providerIdentity*: string
    rootTree*: string
    objectStore*: string            ## the shared clone read (diagnostics).
    published*: seq[PublishedArtifact]
    content*: CatalogContent
    offered*: seq[ContributionIdentity]

  DiscoveredNimbleIndex* = object
    ## A ``kind = "nimble-index"`` catalog read at one exact revision: its
    ## verified root and where each published object's blob is. Shards are
    ## read on demand, through ``indexSource``.
    repo*: string
    remote*: string
    gitRef*: string
    revision*: string
    indexIdentity*: string ## RECOMPUTED: BLAKE3 of the root, 64 hex.
    rootId*: IndexObjectId
    root*: NimbleIndexRoot
    rootTree*: string
    objectStore*: string
    store: GitStore
    blobs: Table[string, string] ## object id (hex) -> blob id
    objectCache*: string
      ## the local index-object cache objects are read through first
      ## (``cachingSource``); "" reads the shared clone alone
    projectRoot: string
    lazy: bool
      ## opened from the cache by the pinned root (``cachedNimbleIndexAt``):
      ## the shared clone is read only for an object the cache lacks

  CatalogEvidenceFailure* = object
    ## A catalog that could not be read at a locked record's own revision
    ## for DIAGNOSTIC evidence (M6 deliverable 4): a diff then cannot name
    ## the cause field by field, and says why instead of only "not
    ## determinable".
    repo*: string
    remote*: string
    revision*: string
    cause*: string

  CatalogAnswer* = object
    ## What discovery supplies to the provisioning resolver.
    imports*: seq[CatalogImport]
    offered*: seq[ContributionIdentity]
    policy*: CatalogSelectionPolicy
    resolver*: ContributionResolver
    previous*: seq[ContributionIdentity]
    pins*: seq[LockedCatalogImport]
      ## The import pins this answer was read at: the lock's own (verified)
      ## for a build, freshly resolved ones for re-selection. Every kind.
    nimbleIndexes*: seq[DiscoveredNimbleIndex]
      ## The ``nimble-index`` imports, read at their pins. They supply no
      ## provisioning content.
    evidenceFailures*: seq[CatalogEvidenceFailure]
      ## Locked records whose own catalog revision could not be read for
      ## ``previous`` (diagnostics only).
    declaration*: LocatedCatalogDeclaration
      ## The declaration the answer was read for (diagnostics only).
    notes*: seq[string]
      ## What re-selection reports beside the pins: a rewind that
      ## ``--allow-rewind`` accepted (NPC-AREQ15).

  LocatedCatalogDeclaration* = object
    ## The declaration and where each table starts, for diagnostics.
    path*: string
    declaration*: CatalogImportsDeclaration
    policyTables*: seq[CatalogPolicyDeclaration]

proc discoveryError(message: string) {.noreturn.} =
  raise newException(CatalogDiscoveryError, message)

# ---------------------------------------------------------------------------
# git, read-only and verified
# ---------------------------------------------------------------------------

proc catalogGitEnv(): StringTableRef =
  ## The ambient environment WITHOUT any ``GIT_*`` variable (compared case-
  ## insensitively, for Windows), plus the switches that keep a read local
  ## and literal.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    if key.toUpperAscii().startsWith("GIT_"):
      continue
    result[key] = value
  # Replace refs are disabled by ``--no-replace-objects`` in every argv
  # (``run``), deliberately not also by ``GIT_NO_REPLACE_OBJECTS``: two
  # switches for one property would each be deletable with the other in
  # place.
  result["GIT_NO_LAZY_FETCH"] = "1"
  result["GIT_TERMINAL_PROMPT"] = "0"

proc drain(s: Stream): string =
  ## Every byte until end of stream. NOT ``readAll``: on Windows it stops at
  ## the first short pipe read (see ``gitRunPlain``), which would truncate an
  ## artifact -- the re-hash would refuse it, but a truncated read is not a
  ## read.
  var buffer: array[65536, char]
  while true:
    let n = s.readData(addr buffer[0], buffer.len)
    if n <= 0:
      break
    let at = result.len
    result.setLen(at + n)
    copyMem(addr result[at], addr buffer[0], n)

proc run(store: GitStore; args: openArray[string]):
    tuple[code: int; output, errors: string] =
  ## One read-only git command against the shared clone, argv-structured.
  ## ``uncontrolledStartProcess`` because ``gitBin`` comes from the typed
  ## PATH-only git profile (``git_tool.resolveGitTool``), which records the
  ## resolved path and version; the spawn itself has no profile of its own.
  ##
  ## KNOWN VIOLATION, kept deliberately until it is replaced: this runs
  ## ``git`` OUTSIDE the build graph, which Build-Engine-And-Scheduler.md
  ## § "Universal Edge-Based Execution and Invalidation" does not allow, and
  ## a label on the hatch is not an edge. Its replacement is the
  ## engine-defined, monitored, cacheable edges ``__repro_catalog_extract``
  ## / ``__repro_catalog_resolve_ref`` of Edge-Derived-Identities.md §6:
  ## ReproOS-Campaign-Completion milestone M6, deliverable 2 (reopened
  ## 2026-10-08), gated by ``t_catalog_extract_edge_is_monitored_and_cached``
  ## and scheduled after M17. Every check this module makes moves into that
  ## edge unchanged.
  var full = @["--no-replace-objects", "--git-dir=" & store.gitDir]
  for a in args: full.add(a)
  var p: Process
  try:
    p = uncontrolledStartProcess(store.gitBin, args = full,
      env = catalogGitEnv(), options = {})
  except CatchableError as err:
    return (-1, "", err.msg)
  try:
    let output = drain(p.outputStream)
    let errors = drain(p.errorStream)
    let code = p.waitForExit()
    result = (code, output, errors)
  finally:
    p.close()

proc gitObjectId*(kind, content: string): string =
  ## The SHA-1 object id of a git object of type ``kind`` with ``content``.
  toLowerAscii($secureHash(kind & " " & $content.len & "\0" & content))

type ObjectTooLarge = object of CatalogDiscoveryError
  ## An object larger than its reader's bound, refused before it was read.
  size: int64

proc objectSize(store: GitStore; oid: string): int64 =
  ## The size git records for object ``oid`` (`git cat-file -s`), read from
  ## the object's header without reading its content. Raises when git cannot
  ## say.
  let r = store.run(["cat-file", "-s", oid])
  if r.code != 0:
    discoveryError("object " & oid & " cannot be sized in " & store.gitDir &
      ": " & r.errors.strip())
  try:
    parseBiggestInt(r.output.strip())
  except ValueError:
    discoveryError("`git cat-file -s " & oid & "` answered " &
      r.output.strip().escape() & ", not a size")

proc readVerified(store: GitStore; kind, oid: string; maxBytes = -1): string =
  ## The bytes of object ``oid``, which must be of type ``kind`` and hash to
  ## ``oid``. Raises otherwise. With ``maxBytes`` >= 0 the object's size is
  ## asked first and a larger object is refused (`ObjectTooLarge`) WITHOUT
  ## its content being read: a hostile pinned repository cannot make the
  ## reader hold more than the bound (NPC-M3's gap, closed by NPC-M5).
  if maxBytes >= 0:
    let size = store.objectSize(oid)
    if size > maxBytes:
      var e = newException(ObjectTooLarge, "object " & oid & " (" & kind &
        ") of " & store.gitDir & " is " & $size & " bytes, more than " &
        $maxBytes & "; it is not read")
      e.size = size
      raise e
  let r = store.run(["cat-file", kind, oid])
  if r.code != 0:
    discoveryError("object " & oid & " (" & kind & ") cannot be read from " &
      store.gitDir & ": " & r.errors.strip())
  let actual = gitObjectId(kind, r.output)
  if actual != oid:
    discoveryError("object " & oid & " (" & kind & ") read from " &
      store.gitDir & " hashes to " & actual & ", not to the id it was " &
      "requested by: the object store is corrupt or was tampered with, " &
      "and nothing read from it is used")
  r.output

type TreeEntry = object
  mode, name, oid: string

proc parseTree(content, oid: string): seq[TreeEntry] =
  var pos = 0
  while pos < content.len:
    let space = content.find(' ', pos)
    let nul = if space < 0: -1 else: content.find('\0', space + 1)
    # The entry's object id is the 20 bytes AFTER the NUL, at
    # ``nul + 1 .. nul + 20``: the last of them must be inside ``content``.
    if space < 0 or nul < 0 or nul + 21 > content.len:
      discoveryError("tree " & oid & " is malformed")
    var hex = ""
    for i in nul + 1 .. nul + 20:
      hex.add(toHex(ord(content[i]), 2).toLowerAscii())
    result.add(TreeEntry(mode: content[pos ..< space],
      name: content[space + 1 ..< nul], oid: hex))
    pos = nul + 21

proc isLowerHex40(value: string): bool =
  value.len == 40 and value.allIt(it in {'0'..'9', 'a'..'f'})

proc catalogObjectStore*(remote, projectRoot: string): string =
  ## The shared bare clone discovery reads ``remote`` from.
  sharedBarePath(defaultCacheRoot(projectRoot), remote)

proc catalogName*(repo, remote: string): string =
  ## How every discovery diagnostic names a catalog: by the ``repo`` and
  ## ``remote`` its import declares (M6 deliverable 4).
  "catalog \"" & repo & "\" (" & remote & ")"

proc recloneCommand(remote, bare: string): string =
  "`git clone --bare " & quoteShell(remote) & " " & quoteShell(bare) & "`"

proc openCatalogStore(repo, remote, projectRoot: string): GitStore =
  var gitBin = ""
  try:
    gitBin = resolveGitTool(tpmPathOnly, getEnv("PATH")).binaryPath
  except CatchableError as err:
    discoveryError(catalogName(repo, remote) & ": git is needed to read " &
      "catalog objects out of the shared clone of " & remote & " and " &
      "cannot be resolved: " & err.msg & ". Put git on PATH and re-run")
  let remoteShape = remoteShapeDefect(remote)
  if remoteShape.len > 0:
    # Checked BEFORE the remote reaches ``urlSlug`` / ``canonicalRemoteIdentity``:
    # a lock record's remote reaches here unparsed (``evidenceAt``).
    discoveryError("catalog \"" & repo & "\": catalog remote " &
      remote.escape() & " " & remoteShape)
  let bare = catalogObjectStore(remote, projectRoot)
  if not (dirExists(bare / "objects") and fileExists(bare / "HEAD")):
    discoveryError(catalogName(repo, remote) & ": there is no shared clone " &
      "of catalog remote " & remote & " at " & bare & ". Populate it with " &
      "`repro ws sync` (or " & recloneCommand(remote, bare) & "). Discovery " &
      "reads ONLY that store -- never a working checkout, a sibling " &
      "directory or a develop override")
  result = GitStore(gitBin: gitBin, gitDir: bare)
  # What the store says it is a clone of. EVERY ``remote.origin.url`` value
  # (``--get`` would answer with the last of several, while a fetch uses the
  # first), and the URL a fetch would really use once ``url.<base>.insteadOf``
  # rewrites are applied (``remote get-url``): each must be exactly one URL,
  # of an unambiguous shape, with the declared remote's identity.
  let declaredIdentity = canonicalRemoteIdentity(remote)
  proc urlsOf(r: tuple[code: int; output, errors: string]): seq[string] =
    if r.code == 0:
      for line in r.output.splitLines():
        if line.strip().len > 0:
          result.add(line.strip())
  let configured = urlsOf(result.run(["config", "--get-all",
    "remote.origin.url"]))
  let who = catalogName(repo, remote) & ": "
  let reclone = "Move it aside and re-create it with " &
    recloneCommand(remote, bare) & " (or `repro ws sync`)"
  if configured.len == 0:
    discoveryError(who & "the shared clone at " & bare & " has no " &
      "remote.origin.url, so nothing shows it is a clone of " & remote &
      ". It is not read for this catalog. " & reclone)
  let effective = urlsOf(result.run(["remote", "get-url", "--all", "origin"]))
  if configured.len != 1 or effective.len != 1:
    discoveryError(who & "the shared clone at " & bare & " names " &
      $configured.len & " origin URL(s) (" & configured.join(", ") &
      ") that a fetch would use as " & $effective.len & " URL(s) (" &
      effective.join(", ") & "); a store that is a clone of " & remote &
      " names exactly one. It is not read for this catalog. " & reclone)
  for (what, observed) in [("is a clone of", configured[0]),
                           ("fetches (after url.*.insteadOf) from", effective[0])]:
    let shape = remoteShapeDefect(observed)
    if shape.len > 0:
      discoveryError(who & "the shared clone at " & bare & " " & what & " " &
        observed.escape() & ", which " & shape & "; it is not read for " &
        "catalog remote " & remote & ". " & reclone)
    if canonicalRemoteIdentity(observed) != declaredIdentity:
      discoveryError(who & "the shared clone at " & bare & " " & what & " " &
        observed & ", not " & (if what.startsWith("is"): "of" else: "from") &
        " catalog remote " & remote & " (two remotes " &
        "share one cache directory name, or the store's configuration " &
        "redirects it); it is not read for this catalog. " & reclone)
  let format = result.run(["rev-parse", "--show-object-format"])
  if format.code != 0 or format.output.strip() != "sha1":
    discoveryError(who & "the shared clone at " & bare & " uses the " &
      (if format.code != 0: "undeterminable (" & format.errors.strip() & ")"
       else: format.output.strip()) & " object format; catalog discovery " &
      "re-hashes SHA-1 objects only and refuses the rest (a false refusal: " &
      "SHA-256 repositories are not supported yet)")

# ---------------------------------------------------------------------------
# Reading one catalog at one revision
# ---------------------------------------------------------------------------

proc pinnedRootTree(store: GitStore; revision, where, republish: string):
    string =
  ## The root tree of the pinned commit, read by id and re-hashed.
  var commit = ""
  try:
    commit = store.readVerified("commit", revision)
  except CatalogDiscoveryError as err:
    discoveryError(where & ": the pinned commit is not available in the " &
      "shared clone " & store.gitDir & " (" & err.msg & "). Fetch it with " &
      "`git --git-dir=" & quoteShell(store.gitDir) & " fetch origin " &
      revision & "` or `repro ws sync`; another revision, a checkout or a " &
      "sibling directory is never used instead")
  if not commit.startsWith("tree ") or commit.len < 46 or commit[45] != '\n':
    discoveryError(where & ": the commit object does not start with its " &
      "tree" & republish)
  result = commit[5 ..< 45]
  if not isLowerHex40(result):
    discoveryError(where & ": the commit names a malformed tree" & republish)

proc verifiedTree(store: GitStore; oid, where, republish: string):
    seq[TreeEntry] =
  ## A tree on the path to the published objects. Its refusal names the
  ## catalog and the remedy (M6 deliverable 4): a tree that cannot be read
  ## or does not hash to its id is a damaged store; one that does not parse
  ## was published that way.
  try:
    result = parseTree(store.readVerified("tree", oid), oid)
  except CatalogDiscoveryError as err:
    if err.msg.endsWith(" is malformed"):
      discoveryError(where & ": " & err.msg & republish)
    discoveryError(where & ": " & err.msg & ". Move the shared clone " &
      store.gitDir & " aside and re-create it (`repro ws sync`)")

proc discoverCatalogAt*(repo, remote, gitRef, revision,
                        projectRoot: string): DiscoveredCatalog =
  ## Read the catalog ``remote`` at exactly ``revision`` (see the module
  ## docstring). Raises ``CatalogDiscoveryError`` naming every cause.
  if not isFullRevision(revision):
    discoveryError("catalog \"" & repo & "\" (" & remote & ") is pinned to " &
      revision.escape() & ", which is not a full-width lower-case commit " &
      "id; a branch name or an abbreviated id names a set of commits")
  let store = openCatalogStore(repo, remote, projectRoot)
  if not isLowerHex40(revision):
    discoveryError(catalogName(repo, remote) & " is pinned to a 64-hex " &
      "revision; SHA-256 repositories are not supported yet")
  let where = catalogName(repo, remote) & " at " & revision
  let republish = ". Pin a revision of \"" & repo & "\" that publishes " &
    "valid interface artifacts (the `commit` or `ref` of its [[import]] in " &
    CatalogImportsFileName & "), or have its publisher regenerate and " &
    "commit `" & PublishedInterfacesDir & "/`"
  let rootTree = pinnedRootTree(store, revision, where, republish)
  proc treeAt(oid: string): seq[TreeEntry] =
    verifiedTree(store, oid, where, republish)
  let rootEntries = treeAt(rootTree)
  let pubs = rootEntries.filterIt(it.name == PublishedInterfacesDir)
  if pubs.len == 0:
    discoveryError(where & ": the commit publishes no interface artifacts " &
      "(there is no `" & PublishedInterfacesDir & "/` directory at the " &
      "repository root). A catalog publishes its generated artifacts there; " &
      "its provider is never run to discover contributions" & republish)
  if pubs.len > 1:
    # git never writes such a tree; a crafted one could, and which entry
    # "is" the publication would then be the reader's choice.
    discoveryError(where & ": the root tree names `" & PublishedInterfacesDir &
      "` " & $pubs.len & " times" & republish)
  if pubs[0].mode != "40000":
    discoveryError(where & ": `" & PublishedInterfacesDir & "` is not a " &
      "directory (mode " & pubs[0].mode & ")" & republish)
  let entries = treeAt(pubs[0].oid)
  var refusals: seq[string] = @[]
  var names: seq[string] = @[]
  for e in entries:
    if e.name in names:
      refusals.add("`" & PublishedInterfacesDir & "/" & e.name & "` appears " &
        "more than once in the tree")
    names.add(e.name)
    if e.mode notin ["100644", "100755"] or
        not e.name.endsWith(PublishedArtifactSuffix) or
        e.name.len <= PublishedArtifactSuffix.len or '/' in e.name:
      refusals.add("`" & PublishedInterfacesDir & "/" & e.name & "` (mode " &
        e.mode & ") is not a regular `*" & PublishedArtifactSuffix &
        "` file; the directory holds published artifacts and nothing else")
  if entries.len == 0:
    refusals.add("`" & PublishedInterfacesDir & "/` is empty")
  var published: seq[PublishedArtifact] = @[]
  var damaged = 0
    ## Refusals that are a damaged store, not a bad publication.
  if refusals.len == 0:
    for e in entries:
      let path = PublishedInterfacesDir & "/" & e.name
      var bytes = ""
      try:
        bytes = store.readVerified("blob", e.oid)
      except CatalogDiscoveryError as err:
        # A damaged store, not a bad publication: its own remedy.
        refusals.add(err.msg & ". Move the shared clone " & store.gitDir &
          " aside and re-create it (`repro ws sync`)")
        inc damaged
        continue
      try:
        published.add(PublishedArtifact(path: path,
          artifact: decodePublishedArtifact(path, bytes)))
      except CatchableError as err:
        refusals.add(err.msg)
  var content: CatalogContent
  if refusals.len == 0:
    content = publishedCatalogContent(published, refusals)
  if refusals.len > 0:
    # The publication remedy only when something IS wrong with the
    # publication; a damaged store names its own remedy on its line.
    discoveryError(where & " cannot be composed:\n    " &
      refusals.sorted(cmp).join("\n    ") &
      (if refusals.len > damaged:
         "\n    fix: pin a revision of \"" & repo & "\" that publishes valid " &
         "interface artifacts (the `commit` or `ref` of its [[import]] in " &
         CatalogImportsFileName & "), or have its publisher regenerate and " &
         "commit `" & PublishedInterfacesDir & "/`"
       else: ""))
  result = DiscoveredCatalog(repo: repo, remote: remote, gitRef: gitRef,
    revision: revision, interfaceArtifact: publishedArtifactIdentity(published),
    providerIdentity: catalogProviderIdentity("sha1", rootTree),
    rootTree: rootTree, objectStore: store.gitDir, published: published,
    content: content)
  result.offered = offeredIdentities(content, result.providerIdentity)

proc resolveCatalogRef*(repo, remote, gitRef, projectRoot: string): string =
  ## The commit the moving reference ``gitRef`` names in the shared clone of
  ## ``remote``: ``refs/heads/<ref>``, or ``refs/tags/<ref>`` peeled to its
  ## commit. Neither -> refuse; both naming different commits -> refuse; a
  ## symbolic ref -> refuse (it would answer with its target, possibly
  ## ``HEAD``). ``HEAD`` is never consulted. Used ONLY by re-selection; a build reads
  ## the lock's revision.
  let who = catalogName(repo, remote) & ": "
  let defect = refDefect(gitRef)
  if defect.len > 0:
    discoveryError(who & "ref " & gitRef.escape() & " " & defect &
      "; correct the `ref` of its [[import]] in " & CatalogImportsFileName)
  let store = openCatalogStore(repo, remote, projectRoot)
  let heads = "refs/heads/" & gitRef
  let tags = "refs/tags/" & gitRef
  let r = store.run(["for-each-ref",
    "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)" &
      "%00%(*objecttype)%00%(symref)", heads, tags])
  if r.code != 0:
    discoveryError(who & "cannot list refs in " & store.gitDir & ": " &
      r.errors.strip())
  var found: seq[(string, string)] = @[]
  for line in r.output.splitLines():
    if line.len == 0: continue
    let f = line.split('\0')
    if f.len != 6 or f[0] notin [heads, tags]:
      continue
    if f[5].len > 0:
      # A symbolic ref answers with its target's commit -- possibly HEAD's
      # (``refs/heads/x -> HEAD``), which a ref is never resolved through.
      discoveryError(who & f[0] & " is a symbolic ref (to " & f[5] &
        "); name the branch or tag itself, or pin a `commit`, in its " &
        "[[import]] in " & CatalogImportsFileName)
    var commit = ""
    if f[2] == "commit":
      commit = f[1]
    elif f[2] == "tag" and f[4] == "commit":
      commit = f[3]
    else:
      discoveryError(who & f[0] & " does not name a commit (it names a " &
        f[2] & "); name a branch or tag that points at a commit, or pin a " &
        "`commit`, in its [[import]] in " & CatalogImportsFileName)
    found.add((f[0], commit.toLowerAscii()))
  if found.len == 0:
    discoveryError(who & "there is no branch or tag " & gitRef.escape() &
      " in the shared clone " & store.gitDir & " of " & remote &
      "; fetch it (`repro ws sync`) or pin a `commit`")
  if found.len > 1 and found[0][1] != found[1][1]:
    discoveryError(who & gitRef.escape() & " is " &
      "both a branch (" & found.filterIt(it[0] == heads).mapIt(it[1]).join() &
      ") and a tag (" & found.filterIt(it[0] == tags).mapIt(it[1]).join() &
      ") naming different commits; pin a `commit` instead (in its " &
      "[[import]] in " & CatalogImportsFileName & ")")
  found[0][1]

proc catalogImportOf*(d: DiscoveredCatalog): CatalogImport =
  ## The explicitly identified ``CatalogImport`` composition takes. The
  ## coordinate carries the RECOMPUTED interface-artifact identity; the
  ## object store is named for diagnostics only.
  CatalogImport(
    coordinate: CatalogCoordinate(workspace: d.repo, remote: d.remote,
      revision: d.revision, interfaceArtifact: d.interfaceArtifact),
    discoveredAt: d.objectStore & " @ " & d.revision,
    content: some(d.content))

proc lockPinOf*(d: DiscoveredCatalog): LockedCatalogImport =
  LockedCatalogImport(repo: d.repo, remote: d.remote, gitRef: d.gitRef,
    revision: d.revision, interfaceArtifact: d.interfaceArtifact,
    kind: cikProvisioning)

proc lockPinOf*(d: DiscoveredNimbleIndex): LockedCatalogImport =
  ## The ``catalog_imports`` record of a Nimble index import: its revision
  ## and the index identity (the root's hash) in ``interface_artifact``.
  LockedCatalogImport(repo: d.repo, remote: d.remote, gitRef: d.gitRef,
    revision: d.revision, interfaceArtifact: d.indexIdentity,
    kind: cikNimbleIndex)

# ---------------------------------------------------------------------------
# The `nimble-index` kind
# ---------------------------------------------------------------------------

proc isLowerHex64(value: string): bool =
  value.len == 64 and value.allIt(it in {'0'..'9', 'a'..'f'})

proc parseIndexObjectId(hex: string): IndexObjectId =
  ## A 64-hex index object id (``isLowerHex64``) as its bytes.
  for i in 0 ..< 32:
    result[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))

proc nimbleIndexObjectCache*(): string =
  ## Where Nimble index objects are cached by id: beside the Nimble source
  ## store, under the user cache directory (objects under ``objects/<id>``).
  ## Shared by every project of the user: an object is named by its hash,
  ## so whatever wrote it, it is the same object, and every reader checks
  ## the hash again.
  getCacheDir("reprobuild") / "store" / "nimble-index"

proc discoverNimbleIndexAt*(repo, remote, gitRef, revision,
                            projectRoot: string): DiscoveredNimbleIndex =
  ## Read the Nimble index ``remote`` publishes at exactly ``revision``:
  ## ``published-index/root`` and the listing of ``published-index/objects``,
  ## every object read by id and re-hashed (C1), from the shared clone whose
  ## origin is ``remote`` (C2). The root is decoded by the bounded codec;
  ## every object it names must be published beside it. No shard is read
  ## here. Raises ``CatalogDiscoveryError`` naming every cause.
  if not isFullRevision(revision):
    discoveryError("catalog \"" & repo & "\" (" & remote & ") is pinned to " &
      revision.escape() & ", which is not a full-width lower-case commit " &
      "id; a branch name or an abbreviated id names a set of commits")
  let store = openCatalogStore(repo, remote, projectRoot)
  if not isLowerHex40(revision):
    discoveryError(catalogName(repo, remote) & " is pinned to a 64-hex " &
      "revision; SHA-256 repositories are not supported yet")
  let where = catalogName(repo, remote) & " at " & revision
  let republish = ". Pin a revision of \"" & repo & "\" that publishes a " &
    "valid Nimble index (the `commit` or `ref` of its [[import]] in " &
    CatalogImportsFileName & "), or have its generator regenerate and " &
    "commit `" & PublishedIndexDir & "/`"
  let rootTree = pinnedRootTree(store, revision, where, republish)
  let rootEntries = verifiedTree(store, rootTree, where, republish)
  let pubs = rootEntries.filterIt(it.name == PublishedIndexDir)
  if pubs.len != 1 or pubs[0].mode != "40000":
    discoveryError(where & ": the commit publishes no Nimble index (" &
      (if pubs.len == 0: "there is no `" & PublishedIndexDir & "/` directory"
       elif pubs.len > 1: "the root tree names `" & PublishedIndexDir & "` " &
         $pubs.len & " times"
       else: "`" & PublishedIndexDir & "` is not a directory") &
      " at the repository root)" & republish)
  var refusals: seq[string] = @[]
  var rootBlob = ""
  var objectsTree = ""
  var seen: seq[string] = @[]
  for e in verifiedTree(store, pubs[0].oid, where, republish):
    if e.name in seen:
      refusals.add("`" & PublishedIndexDir & "/" & e.name & "` appears more " &
        "than once in the tree")
    seen.add(e.name)
    if e.name == IndexRootFile and e.mode == "100644":
      rootBlob = e.oid
    elif e.name == IndexObjectsDir and e.mode == "40000":
      objectsTree = e.oid
    else:
      refusals.add("`" & PublishedIndexDir & "/" & e.name & "` (mode " &
        e.mode & ") is neither the `" & IndexRootFile & "` file nor the `" &
        IndexObjectsDir & "/` directory; the directory holds the index and " &
        "nothing else")
  if rootBlob.len == 0:
    refusals.add("`" & PublishedIndexDir & "/" & IndexRootFile & "` is missing")
  if objectsTree.len == 0:
    refusals.add("`" & PublishedIndexDir & "/" & IndexObjectsDir &
      "/` is missing")
  var blobs = initTable[string, string]()
  if objectsTree.len > 0:
    for e in verifiedTree(store, objectsTree, where, republish):
      if e.mode != "100644" or not isLowerHex64(e.name):
        refusals.add("`" & PublishedIndexDir & "/" & IndexObjectsDir & "/" &
          e.name & "` (mode " & e.mode & ") is not a regular file named by " &
          "a 64-hex object id")
      elif e.name in blobs:
        refusals.add("`" & PublishedIndexDir & "/" & IndexObjectsDir & "/" &
          e.name & "` appears more than once in the tree")
      else:
        blobs[e.name] = e.oid
  if refusals.len > 0:
    discoveryError(where & " cannot be read as a Nimble index:\n    " &
      refusals.sorted(cmp).join("\n    ") & "\n    fix" & republish[1 .. ^1])
  var rootText = ""
  try:
    rootText = store.readVerified("blob", rootBlob, MaxRootBytes)
  except ObjectTooLarge as err:
    discoveryError(where & ": `" & PublishedIndexDir & "/" & IndexRootFile &
      "` is refused: " & err.msg & republish)
  except CatalogDiscoveryError as err:
    discoveryError(err.msg & ". Move the shared clone " & store.gitDir &
      " aside and re-create it (`repro ws sync`)")
  var rootBytes = newSeq[byte](rootText.len)
  for i, c in rootText: rootBytes[i] = byte(ord(c))
  let rootId = indexObjectId(rootBytes)
  var root: NimbleIndexRoot
  try:
    root = decodeRoot(rootBytes)
  except NimbleIndexError as err:
    discoveryError(where & ": `" & PublishedIndexDir & "/" & IndexRootFile &
      "` is refused: " & err.msg & republish)
  var named = @[($rootId, "the root"), ($root.nameMap.id, "the name map"),
    ($root.events.id, "the events")]
  for sh in root.shards:
    named.add(($sh.id, "shard " & $sh.bucket))
  for (hex, what) in named:
    if hex notin blobs:
      refusals.add(what & " (" & hex & ") is not published in `" &
        PublishedIndexDir & "/" & IndexObjectsDir & "/`")
  if $rootId in blobs and blobs[$rootId] != rootBlob:
    refusals.add("`" & PublishedIndexDir & "/" & IndexObjectsDir & "/" &
      $rootId & "` is not the same blob as `" & PublishedIndexDir & "/" &
      IndexRootFile & "`")
  if refusals.len > 0:
    discoveryError(where & " publishes an incomplete Nimble index:\n    " &
      refusals.sorted(cmp).join("\n    ") & "\n    fix" & republish[1 .. ^1])
  # The verified root goes into the object cache by its id, so a later
  # resolution of a lock that pins this root reads it -- and the shards it
  # caches as they are read -- without the shared clone (spec § 1.1).
  let cache = nimbleIndexObjectCache()
  cacheIndexObject(cache, rootId, rootBytes)
  DiscoveredNimbleIndex(repo: repo, remote: remote, gitRef: gitRef,
    revision: revision, indexIdentity: $rootId, rootId: rootId, root: root,
    rootTree: rootTree, objectStore: store.gitDir, store: store, blobs: blobs,
    objectCache: cache, projectRoot: projectRoot)

proc gitIndexSource(d: DiscoveredNimbleIndex): IndexObjectSource =
  ## The index's objects, read from the shared clone at the pinned revision:
  ## each blob by id and re-hashed (git's id), then checked against the
  ## index object id by the index reader.
  let store = d.store
  let blobs = d.blobs
  let where = catalogName(d.repo, d.remote) & " at " & d.revision
  IndexObjectSource(description: where,
    fetch: proc (id: IndexObjectId; maxBytes: int): seq[byte] =
      let hex = $id
      if hex notin blobs:
        refuse(nrMissingObject, "object " & hex & " is not published by " &
          where)
      var text = ""
      var failure = ""
      var oversize = false
      try:
        text = store.readVerified("blob", blobs[hex], maxBytes)
      except ObjectTooLarge as err:
        failure = err.msg
        oversize = true
      except CatalogDiscoveryError as err:
        failure = err.msg
      if oversize:
        refuse(nrOversize, "object " & hex & " of " & where & ": " & failure)
      if failure.len > 0:
        refuse(nrMissingObject, failure)
      if text.len > maxBytes:
        refuse(nrOversize, "object " & hex & " of " & where & " is " &
          $text.len & " bytes, more than " & $maxBytes)
      result = newSeq[byte](text.len)
      for i, c in text: result[i] = byte(ord(c)))

proc materialized*(d: DiscoveredNimbleIndex): DiscoveredNimbleIndex =
  ## ``d`` with its shared clone read: itself, unless it was opened from the
  ## cache alone (``cachedNimbleIndexAt``), in which case the pinned
  ## revision is discovered now -- and must publish the same root.
  if not d.lazy:
    return d
  result = discoverNimbleIndexAt(d.repo, d.remote, d.gitRef, d.revision,
    d.projectRoot)
  if result.indexIdentity != d.indexIdentity:
    discoveryError(catalogName(d.repo, d.remote) & " at " & d.revision &
      " publishes the Nimble index " & result.indexIdentity & ", not the " &
      "pinned " & d.indexIdentity)

proc indexSource*(d: DiscoveredNimbleIndex): IndexObjectSource =
  ## The index's objects: through the local object cache when the index
  ## has one, the shared clone read only for what it lacks; otherwise from
  ## the shared clone.
  if d.objectCache.len == 0:
    return gitIndexSource(d)
  let pinned = d
  cachingSource(d.objectCache, proc (): IndexObjectSource =
    gitIndexSource(materialized(pinned)))

proc cachedNimbleIndexAt*(pin: LockedCatalogImport;
                          projectRoot: string): Option[DiscoveredNimbleIndex] =
  ## The index a lock pins, opened from the local object cache by the
  ## pinned root id alone -- no git process, no shared clone -- when the
  ## cache holds that root (spec § 1.1: "it is not read at resolution time
  ## when the lock already names the root"). Shards are then read from the
  ## cache, and the shared clone only for a shard it lacks. None when the
  ## root is not cached, or the pin is not a 64-hex root id.
  if pin.kind != cikNimbleIndex or not isLowerHex64(pin.interfaceArtifact):
    return none(DiscoveredNimbleIndex)
  let cache = nimbleIndexObjectCache()
  var rootId: IndexObjectId
  try:
    rootId = parseIndexObjectId(pin.interfaceArtifact)
  except CatchableError:
    return none(DiscoveredNimbleIndex)
  try:
    let bytes = readVerified(directorySource(cache), rootId, -1,
      MaxRootBytes, "root")
    let root = decodeRoot(bytes)
    some(DiscoveredNimbleIndex(repo: pin.repo, remote: pin.remote,
      gitRef: pin.gitRef, revision: pin.revision,
      indexIdentity: pin.interfaceArtifact, rootId: rootId, root: root,
      objectCache: cache, projectRoot: projectRoot, lazy: true))
  except NimbleIndexError:
    none(DiscoveredNimbleIndex)

proc openNimbleIndex*(d: DiscoveredNimbleIndex): NimbleIndex =
  ## The index for reading: root verified again by its id, shards on demand.
  openIndex(indexSource(d), d.rootId)

proc readPublishedFile*(d: DiscoveredNimbleIndex; name: string;
                        maxBytes: int): tuple[found: bool; text: string] =
  ## The file ``name`` at the root of the index repository at the pinned
  ## revision (``nimble-sources.toml``: the index's own source set, which
  ## declares its mirrors), read by object id and re-hashed like every
  ## other object. ``found`` is false when the commit has no such regular
  ## file; a file larger than ``maxBytes`` is refused unread.
  ##
  ## What was read is recorded in the local object cache, by the pinned
  ## commit (`published-files/<commit>/<name>`: the object id of its bytes,
  ## filed as a cache object, or `absent`), so an index opened from the
  ## cache alone (``cachedNimbleIndexAt``) reads it again without the shared
  ## clone: resolving a lock that names the root runs no git (spec § 1.1).
  ## The commit's content never changes, and the bytes are checked against
  ## the recorded id; a record that cannot be used is ignored and the file
  ## is read from the shared clone again.
  let where = catalogName(d.repo, d.remote) & " at " & d.revision
  let record =
    if d.objectCache.len > 0 and (isLowerHex40(d.revision) or
        isLowerHex64(d.revision)) and '/' notin name:
      d.objectCache / "published-files" / d.revision / name
    else: ""
  if record.len > 0 and fileExists(record):
    var line = ""
    try:
      line = readFile(record).strip()
    except IOError:
      discard
    if line == "absent":
      return (false, "")
    var id: IndexObjectId
    if parseObjectId(line, id):
      try:
        let bytes = readVerified(directorySource(d.objectCache), id, -1,
          maxBytes, name)
        var text = newString(bytes.len)
        for i, b in bytes: text[i] = char(b)
        return (true, text)
      except NimbleIndexError:
        discard
  proc remember(content: string) =
    if record.len == 0: return
    try:
      createDir(parentDir(record))
      let tmp = record & ".tmp-" & $getCurrentProcessId()
      writeFile(tmp, content & "\n")
      moveFile(tmp, record)
    except CatchableError:
      discard
  let m = materialized(d)
  for e in verifiedTree(m.store, m.rootTree, where, ""):
    if e.name == name:
      if e.mode notin ["100644", "100755"]:
        discoveryError(where & ": `" & name & "` is not a regular file")
      var text = ""
      try:
        text = m.store.readVerified("blob", e.oid, maxBytes)
      except ObjectTooLarge as err:
        discoveryError(where & ": `" & name & "` is refused: " & err.msg)
      if record.len > 0:
        var bytes = newSeq[byte](text.len)
        for i, c in text: bytes[i] = byte(ord(c))
        let id = indexObjectId(bytes)
        cacheIndexObject(d.objectCache, id, bytes)
        remember($id)
      return (true, text)
  remember("absent")
  (false, "")

proc descendantDefect(store: GitStore; pinned, candidate: string): string =
  ## Why ``candidate`` cannot be taken as a refresh of ``pinned``
  ## (NPC-AREQ15), or "" when it descends from it (or is it). Checked from
  ## the commit objects of the shared clone: the pinned commit must be
  ## present and an ancestor of the candidate. An absent pinned commit is a
  ## refusal, not a pass: without it nothing shows the candidate is newer.
  if pinned == candidate:
    return ""
  let present = store.run(["cat-file", "-e", pinned & "^{commit}"])
  if present.code != 0:
    return "the pinned revision " & pinned & " is not in the shared clone " &
      store.gitDir & ", so whether " & candidate & " descends from it " &
      "cannot be checked"
  let r = store.run(["merge-base", "--is-ancestor", pinned, candidate])
  case r.code
  of 0: ""
  of 1: candidate & " does not descend from the pinned revision " & pinned &
    " (the index's history moved backwards or was rewritten)"
  else: "whether " & candidate & " descends from " & pinned & " cannot be " &
    "decided: " & r.errors.strip()

proc rewindCheck(d: CatalogImportDeclaration; revision, projectRoot: string;
                 incumbent: seq[LockedCatalogImport]; allowRewind: seq[string];
                 notes: var seq[string]): string =
  ## NPC-AREQ15 for one ``nimble-index`` import that names a ``ref``: the
  ## revision the ref names now must descend from the revision the lock
  ## pins, or ``--allow-rewind`` must name the import. Returns the refusal,
  ## or "" (adding a note when a rewind was allowed). An import that names
  ## a ``commit``, or one whose remote changed, is the declaration's own
  ## explicit choice and is not checked.
  if d.gitRef.len == 0:
    return ""
  for p in incumbent:
    if p.repo != d.repo or p.remote != d.remote or p.kind != d.kind:
      continue
    let store = openCatalogStore(d.repo, d.remote, projectRoot)
    let defect = descendantDefect(store, p.revision, revision)
    if defect.len == 0:
      return ""
    let who = catalogName(d.repo, d.remote)
    if d.repo in allowRewind:
      notes.add(who & ": ref " & d.gitRef.escape() & " now names " &
        revision & ", which is not a descendant of the pinned " &
        p.revision & "; accepted because --allow-rewind names \"" & d.repo &
        "\"")
      return ""
    # Kept (threat model § 9): the refusal goes to the project's capture
    # log, the only thing a refused refresh writes.
    appendCaptures(projectCaptureLog(projectRoot), [rewoundRefreshCapture(
      who, d.remote, p.revision, revision, defect, uint64(epochTime()))])
    return who & ": refresh refused: ref " & d.gitRef.escape() & " now " &
      "names " & revision & ", and " & defect & ". A refresh moves a " &
      "catalog only forward; if this revision is intended, pass " &
      "--allow-rewind=" & d.repo & " (nothing was written to the lock)"
  ""

proc nimbleIndexHistory*(d: DiscoveredNimbleIndex; fromRevision,
                         projectRoot: string): seq[DiscoveredNimbleIndex] =
  ## The index generations published after ``fromRevision`` up to and
  ## including ``d``'s revision, oldest first: each first-parent commit of
  ## ``fromRevision..d.revision`` that publishes an index, read like any
  ## pinned revision. Used to show the origin events since a lock's pin
  ## (NPC-AREQ19); a commit that cannot be read is skipped, and an
  ## unrelated ``fromRevision`` yields the target generation alone.
  if fromRevision == d.revision:
    return @[]
  let store = openCatalogStore(d.repo, d.remote, projectRoot)
  let r = store.run(["rev-list", "--first-parent", "--reverse",
    fromRevision & ".." & d.revision])
  if r.code != 0:
    return @[d]
  for line in r.output.splitLines():
    let c = line.strip()
    if not isLowerHex40(c): continue
    if c == d.revision:
      result.add(d)
      continue
    try:
      result.add(discoverNimbleIndexAt(d.repo, d.remote, d.gitRef, c,
        projectRoot))
    except CatalogDiscoveryError:
      discard

# ---------------------------------------------------------------------------
# The declaration
# ---------------------------------------------------------------------------

proc declarationLocation*(located: LocatedCatalogDeclaration;
                          repo: string): string =
  ## ``<path>:<line>`` of the ``[[import]]`` naming ``repo``, or "" when the
  ## declaration names none.
  for d in located.declaration.imports:
    if d.repo == repo:
      return located.path & ":" & $d.line
  ""

proc readLocatedCatalogDeclaration*(projectRoot: string;
                                    lockClaims: seq[LockedRealization] = @[]):
    LocatedCatalogDeclaration =
  ## ``<projectRoot>/repro-catalogs.toml``, strictly read, with where each
  ## table starts. Raises ``CatalogDiscoveryError`` when it is missing or
  ## cannot be read, and when two imports name one remote in two
  ## spellings. ``lockClaims``: the committed lock's provisioning records,
  ## named in the "missing" refusal so the user knows what to declare.
  let path = projectRoot / CatalogImportsFileName
  result.path = path
  if not fileExists(path):
    var named: seq[string] = @[]
    for r in lockClaims:
      let line = catalogName(r.catalogWorkspace, r.catalogRemote) & " at " &
        r.catalogRevision
      if line notin named: named.add(line)
    named.sort(cmp)
    discoveryError("the project declares no catalog imports: " & path &
      " does not exist. Declare the catalogs it imports there " &
      "(Federated-Catalog-Imports.md); a catalog is never inferred from a " &
      "sibling directory. Create it with `schema = \"" &
      CatalogImportsSchemaV1 & "\"` and one [[import]] table (`repo`, " &
      "`remote`, and `commit` or `ref`) per catalog" &
      (if named.len > 0:
         "; the committed lock's provisioning records were selected from " &
         named.join(", ")
       else: ""))
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as err:
    discoveryError("cannot read " & path & ": " & err.msg)
  try:
    result.declaration = parseCatalogImportsDeclaration(text, path,
      result.policyTables)
  except CatalogDeclarationError as err:
    discoveryError(err.msg & "\n  fix: correct " & path & " as stated above " &
      "(Federated-Catalog-Imports.md, \"Reading the file\")")
  var identities = initTable[string, CatalogImportDeclaration]()
  var clashes: seq[string] = @[]
  for d in result.declaration.imports:
    let identity = canonicalRemoteIdentity(d.remote)
    if identity in identities:
      let first = identities[identity]
      clashes.add("imports \"" & first.repo & "\" (line " & $first.line &
        ") and \"" & d.repo & "\" (line " & $d.line & ") name one remote (" &
        identity & ")")
    else:
      identities[identity] = d
  if clashes.len > 0:
    discoveryError(path & ": one remote is one catalog import: " &
      clashes.join("; ") & ". Keep one [[import]] per repository and " &
      "remove the other")

proc readCatalogDeclaration*(projectRoot: string): CatalogImportsDeclaration =
  ## ``readLocatedCatalogDeclaration`` without the diagnostic locations.
  readLocatedCatalogDeclaration(projectRoot).declaration

# ---------------------------------------------------------------------------
# What the resolver is handed
# ---------------------------------------------------------------------------

proc evidenceAt(records: seq[LockedRealization]; projectRoot: string;
                known: seq[DiscoveredCatalog];
                failures: var seq[CatalogEvidenceFailure]):
    seq[ContributionIdentity] =
  ## Diagnostic evidence: the identities each record's own catalog
  ## coordinate offers for the record's (package, contributor), where that
  ## catalog can be read at the RECORDED revision. Best effort -- evidence
  ## is optional and is used only if it reproduces the recorded fingerprint
  ## -- but never silent: a catalog that cannot be read is reported in
  ## ``failures`` with its cause (M6 deliverable 4), so a diff that cannot
  ## name a cause says why.
  var cache = known
  var attempted: seq[string] = @[]
  for r in records:
    let key = r.catalogRemote & "@" & r.catalogRevision
    var at = -1
    for i, d in cache:
      if d.remote == r.catalogRemote and d.revision == r.catalogRevision:
        at = i
    if at < 0 and key notin attempted:
      attempted.add(key)
      try:
        cache.add(discoverCatalogAt(r.catalogWorkspace, r.catalogRemote, "",
          r.catalogRevision, projectRoot))
        at = cache.high
      except CatchableError as err:
        failures.add(CatalogEvidenceFailure(repo: r.catalogWorkspace,
          remote: r.catalogRemote, revision: r.catalogRevision,
          cause: err.msg))
    if at < 0:
      continue
    for identity in cache[at].offered:
      if identity.contribution.targetPackage == r.packageName and
          identity.contribution.contributor == r.contributor and
          identity notin result:
        result.add(identity)
  failures.sort(proc (a, b: CatalogEvidenceFailure): int =
    result = cmp(a.repo, b.repo)
    if result == 0: result = cmp(a.remote, b.remote)
    if result == 0: result = cmp(a.revision, b.revision))

proc catalogEvidenceForRecords*(records: seq[LockedRealization];
                                projectRoot: string;
                                failures: var seq[CatalogEvidenceFailure]):
    seq[ContributionIdentity] =
  ## ``repro lock diff``'s evidence: the published identities at each
  ## record's own catalog coordinate, where readable; ``failures`` receives
  ## each catalog that could not be read, with its cause.
  failures = @[]
  evidenceAt(records, projectRoot, @[], failures)

proc catalogEvidenceForRecords*(records: seq[LockedRealization];
                                projectRoot: string): seq[ContributionIdentity] =
  ## ``catalogEvidenceForRecords`` without the failures.
  var ignored: seq[CatalogEvidenceFailure]
  catalogEvidenceForRecords(records, projectRoot, ignored)

proc renderEvidenceFailures*(failures: seq[CatalogEvidenceFailure]):
    seq[string] =
  ## The lines a diff appends when a cause is not determinable because
  ## these catalogs could not be read at the recorded revisions: each
  ## catalog, why, and the command that makes it readable.
  if failures.len == 0:
    return
  result.add("the published catalogs that would explain this field by " &
    "field could not be read at the recorded revisions:")
  for f in failures:
    var cause = f.cause.splitLines()
    if cause.len == 0: cause = @[""]
    # The cause usually names the catalog itself; it is named once.
    let name = catalogName(f.repo, f.remote)
    for prefix in [name & " at " & f.revision & ": ", name & ": "]:
      if cause[0].startsWith(prefix):
        cause[0] = cause[0][prefix.len .. ^1]
        break
    result.add("  " & name & " at " & f.revision & ": " & cause[0])
    for extra in cause[min(1, cause.len) .. ^1]:
      result.add("  " & extra)
  result.add("  fix: fetch each revision into the workspace's shared clone " &
    "(`repro ws sync`) and run the command again")

proc answerOf(located: LocatedCatalogDeclaration;
              discovered: seq[DiscoveredCatalog];
              indexes: seq[DiscoveredNimbleIndex];
              claims: seq[LockedRealization];
              projectRoot: string): CatalogAnswer =
  for d in discovered:
    result.imports.add(catalogImportOf(d))
    result.offered.add(d.offered)
    result.pins.add(lockPinOf(d))
  for d in indexes:
    result.pins.add(lockPinOf(d))
  result.nimbleIndexes = indexes
  result.pins.sort(proc (a, b: LockedCatalogImport): int = cmp(a.repo, b.repo))
  result.policy = located.declaration.policy
  result.resolver = offeredContributionResolver(result.offered)
  result.previous = evidenceAt(claims, projectRoot, discovered,
    result.evidenceFailures)
  result.declaration = located

proc defaultReselectCommand(projectRoot: string): string =
  "repro lock refresh --provisioning " & quoteShell(projectRoot)

proc catalogsForBuild*(projectRoot: string; lockPins: seq[LockedCatalogImport];
                       claims: seq[LockedRealization];
                       reselectCommand = ""): CatalogAnswer =
  ## The catalogs a build whose committed lock carries provisioning records
  ## is verified against: every declared import, read at the revision the
  ## lock pins for it. Refuses -- naming every cause and its remedy -- when
  ## the declaration is missing, an import has no pin, a pin is not declared
  ## or disagrees with its declaration, or the artifacts read at the pinned
  ## revision do not have the pinned identity. ``reselectCommand`` is the
  ## exact re-select command for this lock (default: the project's own).
  let located = readLocatedCatalogDeclaration(projectRoot, claims)
  let declaration = located.declaration
  let command =
    if reselectCommand.len > 0: reselectCommand
    else: defaultReselectCommand(projectRoot)
  let reselect = "re-pin with `" & command & "`"
  var refusals: seq[string] = @[]
  var pinOf = initTable[string, LockedCatalogImport]()
  for p in lockPins:
    pinOf[p.repo] = p
  var declared: seq[string] = @[]
  var toRead: seq[(CatalogImportDeclaration, LockedCatalogImport)] = @[]
  for d in declaration.imports:
    declared.add(d.repo)
    let at = located.path & ":" & $d.line
    if d.repo notin pinOf:
      refusals.add("catalog import \"" & d.repo & "\" (" & d.remote & ", " &
        at & ") is declared but the committed lock pins no revision for " &
        "it; " & reselect)
      continue
    let p = pinOf[d.repo]
    var disagree: seq[string] = @[]
    if p.remote != d.remote:
      disagree.add("remote " & p.remote.escape() & " is declared as " &
        d.remote.escape())
    if d.commit.len > 0 and (p.revision != d.commit or p.gitRef.len > 0):
      disagree.add("the declaration names commit " & d.commit &
        ", the lock pins revision " & p.revision &
        (if p.gitRef.len > 0: " for ref " & p.gitRef.escape() else: ""))
    if d.gitRef.len > 0 and p.gitRef != d.gitRef:
      disagree.add("the declaration names ref " & d.gitRef.escape() &
        ", the lock pinned " & (if p.gitRef.len > 0: "ref " & p.gitRef.escape()
                                 else: "a commit"))
    if d.interfaceArtifact.len > 0 and p.interfaceArtifact != d.interfaceArtifact:
      disagree.add("the declaration asserts interface artifact " &
        d.interfaceArtifact & ", the lock pins " & p.interfaceArtifact)
    if p.kind != d.kind:
      disagree.add("the declaration names kind `" & $d.kind & "`, the lock " &
        "pins kind `" & $p.kind & "`")
    if disagree.len > 0:
      refusals.add("the committed lock's pin for catalog import \"" & d.repo &
        "\" disagrees with repro-catalogs.toml (" & at & "): " &
        disagree.join("; ") & "; " & reselect & " to adopt the " &
        "declaration, or change the [[import]] at " & at & " back to what " &
        "the lock pins")
      continue
    toRead.add((d, p))
  for p in lockPins:
    if p.repo notin declared:
      refusals.add("the committed lock pins catalog import \"" & p.repo &
        "\" (" & p.remote & " at " & p.revision & "), which " &
        "repro-catalogs.toml does not declare; " & reselect & " to drop " &
        "the pin, or declare it in " & located.path)
  var discovered: seq[DiscoveredCatalog] = @[]
  var indexes: seq[DiscoveredNimbleIndex] = @[]
  for (d, p) in toRead:
    let at = located.path & ":" & $d.line
    if d.kind == cikNimbleIndex:
      try:
        let found = discoverNimbleIndexAt(p.repo, p.remote, p.gitRef,
          p.revision, projectRoot)
        if found.indexIdentity != p.interfaceArtifact:
          refusals.add("catalog \"" & p.repo & "\" (" & p.remote & ") at " &
            p.revision & " publishes the Nimble index " & found.indexIdentity &
            ", but the committed lock pins " & p.interfaceArtifact &
            "; nothing read at that revision is used. " &
            reselect.capitalizeAscii())
          continue
        indexes.add(found)
      except CatalogDiscoveryError as err:
        refusals.add(err.msg & "\n    (the [[import]] of \"" & p.repo &
          "\" is at " & at & ")")
      continue
    try:
      let found = discoverCatalogAt(p.repo, p.remote, p.gitRef, p.revision,
        projectRoot)
      if found.interfaceArtifact != p.interfaceArtifact:
        refusals.add("catalog \"" & p.repo & "\" (" & p.remote & ") at " &
          p.revision & " publishes interface artifact " &
          found.interfaceArtifact & ", but the committed lock pins " &
          p.interfaceArtifact & " (a stale or hand-edited pin, or a " &
          "republished revision); nothing read at that revision is used. " &
          reselect.capitalizeAscii())
        continue
      discovered.add(found)
    except CatalogDiscoveryError as err:
      refusals.add(err.msg & "\n    (the [[import]] of \"" & p.repo &
        "\" is at " & at & ")")
  if refusals.len > 0:
    discoveryError(refusals.sorted(cmp).join("\n  "))
  answerOf(located, discovered, indexes, claims, projectRoot)

proc catalogsForReselect*(projectRoot: string;
                          claims: seq[LockedRealization];
                          incumbent: seq[LockedCatalogImport] = @[];
                          allowRewind: seq[string] = @[]): CatalogAnswer =
  ## The catalogs explicit re-selection (``repro lock refresh
  ## --provisioning``) selects from: every declared import, at its declared
  ## commit or at the commit its declared ref names NOW. The answer's
  ## ``pins`` are what the lock is to record. A ``nimble-index`` import
  ## whose ref now names a revision that does not descend from its
  ## ``incumbent`` pin is refused unless ``allowRewind`` names it
  ## (NPC-AREQ15; ``rewindCheck``).
  let located = readLocatedCatalogDeclaration(projectRoot)
  var notes: seq[string] = @[]
  var refusals: seq[string] = @[]
  var discovered: seq[DiscoveredCatalog] = @[]
  var indexes: seq[DiscoveredNimbleIndex] = @[]
  for d in located.declaration.imports:
    let at = located.path & ":" & $d.line
    try:
      let revision =
        if d.commit.len > 0: d.commit
        else: resolveCatalogRef(d.repo, d.remote, d.gitRef, projectRoot)
      if d.kind == cikNimbleIndex:
        let rewind = rewindCheck(d, revision, projectRoot, incumbent,
          allowRewind, notes)
        if rewind.len > 0:
          refusals.add(rewind & "\n    (the [[import]] of \"" & d.repo &
            "\" is at " & at & ")")
          continue
        let found = discoverNimbleIndexAt(d.repo, d.remote, d.gitRef,
          revision, projectRoot)
        if d.interfaceArtifact.len > 0 and
            found.indexIdentity != d.interfaceArtifact:
          refusals.add("catalog \"" & d.repo & "\" (" & d.remote & ") at " &
            revision & " publishes the Nimble index " & found.indexIdentity &
            ", but repro-catalogs.toml asserts " & d.interfaceArtifact &
            " (" & at & "); correct or remove the `interface_artifact` " &
            "assertion there, or pin the revision that publishes it")
          continue
        indexes.add(found)
        continue
      let found = discoverCatalogAt(d.repo, d.remote, d.gitRef, revision,
        projectRoot)
      if d.interfaceArtifact.len > 0 and
          found.interfaceArtifact != d.interfaceArtifact:
        refusals.add("catalog \"" & d.repo & "\" (" & d.remote & ") at " &
          revision & " publishes interface artifact " &
          found.interfaceArtifact & ", but repro-catalogs.toml asserts " &
          d.interfaceArtifact & " (" & at & "); correct or remove the " &
          "`interface_artifact` assertion there, or pin the revision that " &
          "publishes it")
        continue
      discovered.add(found)
    except CatalogDiscoveryError as err:
      refusals.add(err.msg & "\n    (the [[import]] of \"" & d.repo &
        "\" is at " & at & ")")
  if refusals.len > 0:
    discoveryError(refusals.sorted(cmp).join("\n  "))
  result = answerOf(located, discovered, indexes, claims, projectRoot)
  result.notes = notes

proc nimbleIndexesForSolve*(projectRoot: string;
                            incumbent: seq[LockedCatalogImport];
                            reselect: bool; allowRewind: seq[string];
                            notes: var seq[string]):
    seq[DiscoveredNimbleIndex] =
  ## The ``nimble-index`` imports a lock solve resolves `nimble:` names
  ## through (NPC-AREQ1, NPC-AREQ15). ``reselect`` (``repro lock refresh
  ## --provisioning``): each at its declared commit, or the commit its ref
  ## names now, which must descend from the ``incumbent`` pin unless
  ## ``allowRewind`` names it. Otherwise: each at the revision the lock
  ## already pins, re-read and checked against the pinned index identity;
  ## an import the lock does not pin yet, or pins differently from the
  ## declaration, refuses with the command that pins it. Nothing else is
  ## read: no provisioning catalog, no shard.
  let located = readLocatedCatalogDeclaration(projectRoot)
  let reselectCmd = "repro lock refresh --provisioning " &
    quoteShell(projectRoot)
  var refusals: seq[string] = @[]
  for d in located.declaration.imports:
    if d.kind != cikNimbleIndex:
      continue
    let at = located.path & ":" & $d.line
    try:
      if reselect:
        let revision =
          if d.commit.len > 0: d.commit
          else: resolveCatalogRef(d.repo, d.remote, d.gitRef, projectRoot)
        let rewind = rewindCheck(d, revision, projectRoot, incumbent,
          allowRewind, notes)
        if rewind.len > 0:
          refusals.add(rewind & "\n    (the [[import]] of \"" & d.repo &
            "\" is at " & at & ")")
          continue
        let found = discoverNimbleIndexAt(d.repo, d.remote, d.gitRef,
          revision, projectRoot)
        if d.interfaceArtifact.len > 0 and
            found.indexIdentity != d.interfaceArtifact:
          refusals.add("catalog \"" & d.repo & "\" (" & d.remote & ") at " &
            revision & " publishes the Nimble index " & found.indexIdentity &
            ", but repro-catalogs.toml asserts " & d.interfaceArtifact &
            " (" & at & ")")
          continue
        result.add(found)
        continue
      var pin: LockedCatalogImport
      var pinned = false
      for p in incumbent:
        if p.repo == d.repo:
          pin = p
          pinned = true
      if not pinned:
        refusals.add("the Nimble index \"" & d.repo & "\" (" & d.remote &
          ", " & at & ") is declared but the committed lock pins no " &
          "revision of it; pin it with `" & reselectCmd & "`")
        continue
      if pin.remote != d.remote or pin.kind != d.kind or
          (d.commit.len > 0 and pin.revision != d.commit):
        refusals.add("the committed lock's pin of the Nimble index \"" &
          d.repo & "\" (" & pin.remote & " at " & pin.revision & ") " &
          "disagrees with its declaration at " & at & "; re-pin it with `" &
          reselectCmd & "`")
        continue
      # The lock names the root: read it, and the shards, from the local
      # object cache when it holds them -- no git (spec § 1.1). The cache
      # is keyed by the pinned root's hash, so it cannot answer for another
      # index.
      let cached = cachedNimbleIndexAt(pin, projectRoot)
      if cached.isSome:
        result.add(cached.get)
        continue
      let found = discoverNimbleIndexAt(pin.repo, pin.remote, pin.gitRef,
        pin.revision, projectRoot)
      if found.indexIdentity != pin.interfaceArtifact:
        refusals.add("catalog \"" & pin.repo & "\" (" & pin.remote &
          ") at " & pin.revision & " publishes the Nimble index " &
          found.indexIdentity & ", but the committed lock pins " &
          pin.interfaceArtifact & "; nothing read at that revision is used")
        continue
      result.add(found)
    except CatalogDiscoveryError as err:
      refusals.add(err.msg & "\n    (the [[import]] of \"" & d.repo &
        "\" is at " & at & ")")
  if refusals.len > 0:
    discoveryError(refusals.sorted(cmp).join("\n  "))

proc renderCatalogPinChanges*(old, new: seq[LockedCatalogImport]): seq[string] =
  ## One line per catalog import pin that re-selection added, removed or
  ## moved, sorted by repo. Empty when the pins are unchanged.
  var repos: seq[string] = @[]
  for p in old & new:
    if p.repo notin repos: repos.add(p.repo)
  repos.sort(cmp)
  for repo in repos:
    let a = old.filterIt(it.repo == repo)
    let b = new.filterIt(it.repo == repo)
    if a.len == 0:
      result.add("catalog import \"" & repo & "\": pinned " & b[0].remote &
        " at " & b[0].revision & (if b[0].gitRef.len > 0: " (ref \"" &
        b[0].gitRef & "\")" else: "") & ", interface artifact " &
        b[0].interfaceArtifact)
    elif b.len == 0:
      result.add("catalog import \"" & repo & "\": no longer pinned (was " &
        a[0].remote & " at " & a[0].revision & ")")
    elif a[0] != b[0]:
      var parts: seq[string] = @[]
      if a[0].remote != b[0].remote:
        parts.add("remote " & a[0].remote & " -> " & b[0].remote)
      if a[0].kind != b[0].kind:
        parts.add("kind " & $a[0].kind & " -> " & $b[0].kind)
      if a[0].gitRef != b[0].gitRef:
        parts.add("ref \"" & a[0].gitRef & "\" -> \"" & b[0].gitRef & "\"")
      if a[0].revision != b[0].revision:
        parts.add("revision " & a[0].revision & " -> " & b[0].revision)
      if a[0].interfaceArtifact != b[0].interfaceArtifact:
        parts.add("interface artifact " & a[0].interfaceArtifact & " -> " &
          b[0].interfaceArtifact)
      result.add("catalog import \"" & repo & "\": " & parts.join(", "))
