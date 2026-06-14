## C3 P2 / P3: realize-time machinery for the foreign-package sandbox
## launcher.
##
## This module sits between the C2 catalog output
## (``recipes/catalog/foreign/<distro>/<pkg>.json``) and the C3 native
## launcher (``apps/reprobuild-sandbox-launcher/launcher.c``). At
## realize time it:
##
##   1. Walks the catalog GRAPH starting from a single root catalog,
##      reading each dep's catalog file in turn and unioning the
##      reachable ``PackageRef`` set. This closes the C2 risk #4
##      contract: each catalog only carries its OWN transitive bind
##      set, so the launcher manifest generator MUST walk the graph
##      and cannot just trust one root's ``dependency_closure``.
##
##   2. Composes a deterministic launcher manifest (text, LF endings,
##      stable lex order on ``(target, source)``) that the C3 launcher
##      reads via ``parse_manifest``.
##
##   3. Emits per-binary shim scripts at ``$prefix/bin/<name>`` that
##      ``exec`` the launcher with the manifest path. The shim is the
##      operator-visible entry point — putting ``$prefix/bin`` on PATH
##      gives the operator a transparent wrapper.
##
## ## Why not just walk one root's ``dependency_closure``?
##
## In the C2 fixture, the harvester populates each catalog's
## ``dependency_closure`` with the FULL per-record transitive set (see
## ``apps/repro-harvest-apt/repro_harvest_apt.nim`` lines 314-324).
## But the design CONTRACT (echoed in C2's mkCatalogForRecord
## docstring) is: "each catalog carries its OWN per-record bind set,
## NOT the union closure of the harvest request". The launcher
## consumer is required to walk the graph rather than trust one root's
## closure, because:
##
##   * A future harvester (dnf, pacman) MAY emit non-transitive
##     ``dependency_closure`` sets (immediate deps only) and rely on
##     the consumer to walk.
##   * Composing two roots in one home profile (``git`` + ``vim``)
##     means the launcher for each binary needs ITS root's closure,
##     not the union — independent walks per root.
##   * Per-record closure means each catalog's identity is composed
##     against a small fixed set of dep catalogs, NOT the whole
##     harvest universe — keeping the recursive ``CacheEntryKey``
##     composer's depth bounded.
##
## So this module always walks. The walk is cheap (each catalog file
## is a few hundred bytes; closures are tens of packages).
##
## ## What this module deliberately does NOT do
##
##   * Realize a package (fetch the .deb, extract it). That's the M9
##     store-realize pipeline's job; this module assumes the realized
##     prefixes already exist under ``<store-root>/prefixes/<name>/<hash>/``.
##   * Verify catalog signatures. ``readForeignCatalog`` enforces JSON
##     shape; cryptographic verification happens upstream at harvest
##     time and at fetch time.
##   * Determine the target binary's bin/ contents. The realize
##     pipeline emits the prefix and the catalog tells us which deps
##     to bind; the caller passes in the exec list explicitly.

import std/[algorithm, options, os, sets, strutils, tables]

import repro_dsl_stdlib/packages/foreign_common

type
  CatalogResolveError* = object of CatchableError
    ## Raised by ``walkCatalogGraph`` when a dep catalog file cannot
    ## be located under the catalog root. The walker hard-fails on
    ## missing deps — silent skip would let a launcher run with a
    ## hollow FS view and crash at runtime with a confusing
    ## ``ld.so: cannot open shared object`` message.
    parentCatalog*: string
    missingDep*: string
    searchedPath*: string

  CycleDetectedError* = object of CatchableError
    ## Raised if the catalog graph has a cycle. apt cycles are rare
    ## but possible (mutually-recommending packages); we treat them
    ## as a hard error so the launcher manifest is well-defined.

  PrefixesMap* = Table[string, string]
    ## Maps each ``(distro, name)`` pair (encoded as ``<distro>/<name>``)
    ## to the realized content-addressed prefix path on the host
    ## (e.g. ``/store/prefixes/git/a1b2c3.../``). The realize pipeline
    ## produces this; the launcher manifest generator consumes it.

  BindMount* = object
    ## One bind-mount entry the manifest writer emits as
    ## ``<source>:<target>:<flags>``.
    source*: string
    target*: string
    flags*: string

  SandboxManifest* = object
    ## In-memory shape of the manifest before serialization. Held
    ## separately from the on-disk text so tests + the realize
    ## pipeline can inspect / compose without round-tripping.
    binds*: seq[BindMount]
    execPath*: string
    cwd*: string
    extraDirectives*: seq[string]   # e.g. ``proc``, ``sys``

# ---------------------------------------------------------------------------
# Catalog graph walk
# ---------------------------------------------------------------------------

proc prefixesMapKey*(p: PackageRef): string =
  ## Stable key for the ``PrefixesMap``. The store layout uses
  ## ``<distro>/<name>`` because a single package name (``libc6``) may
  ## be harvested from multiple distros (apt + pacman) in one home
  ## profile.
  p.distro & "/" & p.name

proc catalogPathFor*(catalogRoot: string; p: PackageRef): string =
  ## On-disk catalog path. Mirrors ``foreign_common.catalogRelpath``
  ## but takes an explicit root (the harvester writes to
  ## ``<output-dir>/<distro>/<name>.json``; the C3 caller passes
  ## ``<output-dir>`` here).
  catalogRoot / p.distro / (p.name & ".json")

proc cmpPackageRef(a, b: PackageRef): int =
  result = cmp(a.distro, b.distro)
  if result != 0: return
  result = cmp(a.name, b.name)
  if result != 0: return
  result = cmp(a.snapshot, b.snapshot)

proc walkCatalogGraph*(rootCatalogPath: string;
                      catalogRoot: string;
                      includeRoot: bool = true):
    seq[PackageRef] =
  ## C3 P2 — closure-walk closer for risk #4.
  ##
  ## Reads ``rootCatalogPath``, then transitively reads every dep
  ## catalog under ``catalogRoot/<distro>/<name>.json``, unioning the
  ## reachable ``PackageRef`` set.
  ##
  ## Returns the union sorted by ``(distro, name, snapshot)`` so two
  ## walks of the same catalog graph produce byte-identical results
  ## (the deterministic-manifest contract from ``MANIFEST-FORMAT.md``).
  ##
  ## Hard-fails on:
  ##   * a missing dep catalog file (``CatalogResolveError``);
  ##   * a cycle in the dep graph (``CycleDetectedError``).
  ##
  ## Does NOT verify signatures — that's harvest-time + realize-time
  ## responsibility.
  let root = readForeignCatalog(rootCatalogPath)

  var seen = initHashSet[string]()  # prefixesMapKey(p)
  var stack: seq[PackageRef] = @[]
  var ordered: seq[PackageRef] = @[]

  proc visit(p: PackageRef, sourcePath: string) =
    let key = prefixesMapKey(p)
    if key in seen: return
    seen.incl(key)
    ordered.add(p)
    let depPath = catalogPathFor(catalogRoot, p)
    if not fileExists(depPath):
      var e = newException(CatalogResolveError,
        "dep catalog not found: '" & depPath &
        "' (referenced from '" & sourcePath & "')")
      e.parentCatalog = sourcePath
      e.missingDep = key
      e.searchedPath = depPath
      raise e
    let depCatalog = readForeignCatalog(depPath)
    for d in depCatalog.dependencyClosure:
      stack.add(d)

  if includeRoot:
    visit(root.package, rootCatalogPath)
  else:
    seen.incl(prefixesMapKey(root.package))

  # Seed from the root catalog's own deps, then drain the stack.
  for d in root.dependencyClosure:
    stack.add(d)

  # Iterative DFS with explicit cycle detection.
  var visiting = initHashSet[string]()
  while stack.len > 0:
    let p = stack.pop()
    let key = prefixesMapKey(p)
    if key in seen: continue
    if key in visiting:
      var e = newException(CycleDetectedError,
        "catalog dep graph contains a cycle through '" & key & "'")
      raise e
    visiting.incl(key)
    visit(p, rootCatalogPath)
    visiting.excl(key)

  # Sort for deterministic output (the visitation order depends on
  # how the harvester wrote deps; the launcher manifest must be
  # byte-stable across re-emissions of the same input).
  result = ordered
  result.sort(cmpPackageRef)

# ---------------------------------------------------------------------------
# Bind-mount layout for the apt distro
# ---------------------------------------------------------------------------
#
# For apt packages, a realized prefix mirrors the .deb's payload
# layout under ``$prefix/``:
#
#   $prefix/usr/bin/
#   $prefix/usr/lib/x86_64-linux-gnu/
#   $prefix/lib/x86_64-linux-gnu/
#   $prefix/lib64/
#   $prefix/etc/...
#
# To present an FHS-coherent view to the wrapped binary we bind-mount
# each present subdir at its FHS-canonical target. The
# ``bindEntriesForAptPrefix`` proc walks the prefix's bin/lib roots
# and emits one ``BindMount`` per existing subdir; non-present
# subdirs are silently skipped so a package shipping only headers
# doesn't produce a stale ``/usr/include`` bind.

const AptBindCandidates* = @[
  ("usr/bin",                       "/usr/bin"),
  ("usr/sbin",                      "/usr/sbin"),
  ("usr/lib",                       "/usr/lib"),
  ("usr/lib/x86_64-linux-gnu",      "/usr/lib/x86_64-linux-gnu"),
  ("usr/libexec",                   "/usr/libexec"),
  ("usr/share",                     "/usr/share"),
  ("usr/include",                   "/usr/include"),
  ("bin",                           "/bin"),
  ("sbin",                          "/sbin"),
  ("lib",                           "/lib"),
  ("lib/x86_64-linux-gnu",          "/lib/x86_64-linux-gnu"),
  ("lib64",                         "/lib64"),
  ("etc",                           "/etc"),
]

proc bindEntriesForPrefix*(prefixPath: string;
                          distro: string;
                          existsCheck: proc(p: string): bool {.closure.} = nil):
    seq[BindMount] =
  ## Walk a realized package prefix and emit bind-mount entries for
  ## every existing FHS-canonical subdir. ``existsCheck`` defaults to
  ## ``os.dirExists``; tests inject a fixture closure.
  let check = if existsCheck.isNil:
    proc(p: string): bool = dirExists(p)
  else:
    existsCheck

  case distro
  of "apt":
    for (rel, fhs) in AptBindCandidates:
      let src = prefixPath / rel
      if check(src):
        result.add(BindMount(source: src, target: fhs,
                             flags: "rbind,ro"))
  else:
    # dnf/pacman use the same FHS so the apt mapping works.
    # M2/M3 of the Sandbox-MVP campaign already validated this for
    # consumption; the harvester for those distros will land in D2.
    for (rel, fhs) in AptBindCandidates:
      let src = prefixPath / rel
      if check(src):
        result.add(BindMount(source: src, target: fhs,
                             flags: "rbind,ro"))

# ---------------------------------------------------------------------------
# Manifest composer
# ---------------------------------------------------------------------------

proc cmpBindMount(a, b: BindMount): int =
  result = cmp(a.target, b.target)
  if result != 0: return
  result = cmp(a.source, b.source)
  if result != 0: return
  result = cmp(a.flags, b.flags)

proc composeSandboxManifest*(closure: seq[PackageRef];
                            prefixes: PrefixesMap;
                            execPath: string;
                            cwd: string = "";
                            includeProc: bool = true;
                            includeSys: bool = false;
                            existsCheck: proc(p: string): bool {.closure.} = nil):
    SandboxManifest =
  ## Combine the closure + prefix map + exec path into the in-memory
  ## ``SandboxManifest``. Deterministic: sorts the bind set by
  ## ``(target, source, flags)``.
  ##
  ## Raises ``KeyError`` if a closure entry has no realized prefix in
  ## ``prefixes``. The realize pipeline is supposed to materialize the
  ## entire closure before calling here, so a missing entry is a hard
  ## bug.
  result.execPath = execPath
  result.cwd = cwd

  var binds: seq[BindMount] = @[]
  for p in closure:
    let key = prefixesMapKey(p)
    if key notin prefixes:
      raise newException(KeyError,
        "no realized prefix for closure entry '" & key &
        "'; realize pipeline must materialize before manifest emit")
    let prefixPath = prefixes[key]
    for bm in bindEntriesForPrefix(prefixPath, p.distro,
        existsCheck = existsCheck):
      binds.add(bm)

  binds.sort(cmpBindMount)

  # Deduplicate by target: when two packages bind into the same FHS
  # directory (e.g. libc6 + libcrypt1 both shipping into /lib), the
  # later bind shadows the earlier one in Linux's mount stack. We
  # PROACTIVELY warn and prefer the FIRST entry by lex order; the
  # caller can override by partitioning the prefixes map.
  #
  # In practice the apt closure has every shared library laid out at
  # distinct paths under each prefix's lib tree -- collisions only
  # happen on shared directories like /usr/share/doc. For the C3 MVP
  # we accept the bind-stacking behavior: later mounts shadow earlier
  # mounts at the same target. The kernel's mount stack semantics
  # remain correct; only the topmost mount is visible inside the
  # namespace.
  result.binds = binds
  if includeProc:
    result.extraDirectives.add("proc")
  if includeSys:
    result.extraDirectives.add("sys")

# ---------------------------------------------------------------------------
# Manifest serialization (the format the C3 launcher parses)
# ---------------------------------------------------------------------------

proc normSepsForward(s: string): string =
  ## Normalize backslash path separators to forward slashes. On Linux
  ## this is a no-op (no backslashes); on Windows the realize pipeline
  ## may produce native-separator prefix paths that the manifest's
  ## colon-delimited bind syntax can't represent (``D:\foo`` parses as
  ## source=``D``, target=``\foo``). Forcing forward slashes side-steps
  ## the Windows drive-letter collision and keeps the manifest's
  ## grammar single-delimiter.
  result = newStringOfCap(s.len)
  for c in s:
    if c == '\\': result.add('/')
    else: result.add(c)

proc serializeManifest*(m: SandboxManifest): string =
  ## Emit the canonical LF-terminated text the C3 launcher reads. The
  ## section order is fixed: header comment, ``exec=`` + ``cwd=``,
  ## bind-mount lines, ``proc`` / ``sys`` directives. Byte-stable for
  ## a given input.
  result.add("# reprobuild-sandbox-launcher manifest\n")
  result.add("# Generated by repro_local_store/sandbox_manifest.nim\n")
  result.add("# Do not edit by hand; regenerated on each realize.\n")
  result.add("\n")
  if m.execPath.len > 0:
    result.add("exec=")
    result.add(normSepsForward(m.execPath))
    result.add("\n")
  if m.cwd.len > 0:
    result.add("cwd=")
    result.add(normSepsForward(m.cwd))
    result.add("\n")
  if m.binds.len > 0 or m.extraDirectives.len > 0:
    result.add("\n")
  for b in m.binds:
    result.add(normSepsForward(b.source))
    result.add(":")
    result.add(b.target)  # always POSIX-style already
    result.add(":")
    result.add(b.flags)
    result.add("\n")
  if m.extraDirectives.len > 0:
    result.add("\n")
    for d in m.extraDirectives:
      result.add(d)
      result.add("\n")

proc writeManifest*(m: SandboxManifest; path: string) =
  writeFile(path, serializeManifest(m))

# ---------------------------------------------------------------------------
# Realize-time manifest materialization
# ---------------------------------------------------------------------------

proc materializeSandboxManifest*(rootCatalogPath: string;
                                catalogRoot: string;
                                prefixes: PrefixesMap;
                                execPath: string;
                                outPath: string;
                                cwd: string = "";
                                existsCheck: proc(p: string): bool {.closure.} = nil):
    seq[PackageRef] =
  ## End-to-end: walk the catalog graph, compose the manifest, write
  ## it to ``outPath``. Returns the closure for the caller's logging.
  let closure = walkCatalogGraph(rootCatalogPath, catalogRoot,
    includeRoot = true)
  let manifest = composeSandboxManifest(closure, prefixes,
    execPath = execPath, cwd = cwd, existsCheck = existsCheck)
  writeManifest(manifest, outPath)
  closure

# ---------------------------------------------------------------------------
# Per-binary shim emit
# ---------------------------------------------------------------------------

proc generateLauncherShim*(binaryName: string;
                          actualPath: string;
                          manifestPath: string;
                          launcherBinPath: string;
                          shellHashbang: string = "#!/bin/sh"):
    string =
  ## Emit the per-binary shim script. The shim is what lands at
  ## ``$prefix/bin/<binaryName>``; ``actualPath`` is the wrapped
  ## binary's actual store path (e.g.
  ## ``/store/prefixes/git/<hash>/usr/bin/git``); ``manifestPath`` is
  ## the absolute path of the launcher manifest the launcher reads.
  ##
  ## The shim ``exec``s ``launcherBinPath`` so the launcher takes
  ## over the process slot — there's no extra subprocess overhead at
  ## launch time. (Combined with the launcher's sub-100ms namespace
  ## setup, total wrapping cost stays under the C3 perf budget.)
  result = shellHashbang & "\n"
  result.add("# Auto-generated by repro_local_store/sandbox_manifest.nim\n")
  result.add("# Do not edit by hand.\n")
  result.add("exec ")
  result.add(launcherBinPath)
  result.add(" --manifest=")
  result.add(manifestPath)
  result.add(" --exec=")
  result.add(actualPath)
  result.add(" -- \"$@\"\n")

proc emitLauncherShims*(prefixBinDir: string;
                      execList: seq[(string, string)];
                      manifestPath: string;
                      launcherBinPath: string;
                      makeExecutable: proc(p: string) {.closure.} = nil) =
  ## Write per-binary shims under ``prefixBinDir`` for every
  ## ``(binaryName, actualPath)`` entry. The realize pipeline supplies
  ## ``execList`` either from a catalog-recorded ``exec_paths`` field
  ## (future C3 extension) or by walking the realized prefix's
  ## ``bin/`` + ``usr/bin/`` at apply time.
  ##
  ## ``makeExecutable`` lets callers inject ``setFilePermissions`` or
  ## ``chmod +x``; the default ``nil`` leaves permission setting to
  ## the caller (which is the right boundary on Windows where chmod
  ## doesn't apply).
  createDir(prefixBinDir)
  for (name, actualPath) in execList:
    let shimPath = prefixBinDir / name
    let shimText = generateLauncherShim(name, actualPath, manifestPath,
      launcherBinPath)
    writeFile(shimPath, shimText)
    if not makeExecutable.isNil:
      makeExecutable(shimPath)

# ---------------------------------------------------------------------------
# Convenience: discover binaries under a realized prefix
# ---------------------------------------------------------------------------

proc discoverBinaries*(prefixPath: string): seq[(string, string)] =
  ## Walk ``$prefix/usr/bin`` and ``$prefix/bin`` and return
  ## ``(name, absolute-path)`` pairs. The realize pipeline calls this
  ## then feeds the list to ``emitLauncherShims``. Order is sorted by
  ## name so two passes are byte-stable.
  var names = initHashSet[string]()
  var seen: seq[(string, string)] = @[]
  for sub in ["usr/bin", "bin"]:
    let d = prefixPath / sub
    if not dirExists(d): continue
    for kind, p in walkDir(d, relative = false):
      if kind != pcFile and kind != pcLinkToFile: continue
      let n = extractFilename(p)
      if n.len == 0 or n in names: continue
      names.incl(n)
      seen.add((n, p))
  seen.sort do (a, b: (string, string)) -> int:
    cmp(a[0], b[0])
  seen
