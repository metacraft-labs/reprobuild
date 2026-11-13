## Declaring a fixture repository's dependencies the one way reprobuild reads
## them: in its ``repro.nim``.
##
## A repo's dependencies are declared only in its recipe; the committed
## ``repro.lock`` that ``repro lock refresh`` derives from it is the only
## record of them, and every closure question (the pre-push gate's scope,
## ``repro push`` ordering, the mutual-pin rule, ``repro remove``) reads that
## lock (owner decision 2026-11-05, Unified-Locking-And-Hooks.md §14.9). A
## workspace fragment's ``depends`` key is ignored. So a fixture that needs
## "A depends on B" gives A a recipe whose ``uses:`` names B, gives B a recipe
## (``uses:`` discovers a sibling producer at ``../<name>/repro.nim``), and
## refreshes A's lock.
##
## The recipes declare no toolchain ``uses:`` and ``defaultToolProvisioning
## "path"``, so a refresh needs no package catalog and no network: the solve
## is over the fixture's own packages only.

import std/[os, strutils]

import ../repro_test_support

proc recipePackageName*(repo: string): string =
  ## A Nim identifier for the package of the repo directory ``repo``
  ## (``lib-b`` -> ``lib_b``). The ``uses:`` selector is the DIRECTORY name;
  ## the package name only has to be a valid identifier.
  repo.replace('-', '_').replace('.', '_')

const PeerContractsDir* = "peer_contracts"
  ## Where ``writeDependencyRecipe`` puts the contract modules of ``peers``.

proc dependencyRecipe*(repo: string; uses: openArray[string];
    library = true; peers: openArray[string] = []): string =
  ## The text of a ``repro.nim`` for the repo directory ``repo`` whose only
  ## dependencies are the workspace siblings ``uses`` (no ``uses:`` block at
  ## all when it is empty: a recipe that depends on nothing). ``library``
  ## declares a library, which is what lets another recipe consume it.
  ##
  ## ``peers`` are further dependencies that CLOSE A CYCLE with this repo (a
  ## mutual pin). A recipe's ``uses:`` of a workspace sibling imports that
  ## sibling's ``repro.nim``, and two recipes cannot import each other: the
  ## DSL refuses a cross-project build-reference cycle at compile time. So a
  ## peer is named through an explicit contract module instead
  ## (``usesImportPath``, which takes a selector it holds a module for and
  ## imports no implementation), exactly the way a real recipe names the other
  ## side of a cycle (Unified-Locking-And-Hooks.md §14.9). Lock generation
  ## folds the peer's recipe all the same: it walks the recipes on disk, not
  ## the imports.
  let pkg = recipePackageName(repo)
  result = "import repro_project_dsl\n\npackage " & pkg & ":\n"
  if library: result.add("  library " & pkg & "\n")
  result.add("  defaultToolProvisioning \"path\"\n")
  if peers.len > 0:
    result.add("  usesImportPath \"" & PeerContractsDir & "\"\n")
  if uses.len + peers.len > 0:
    result.add("  uses:\n")
    for u in uses: result.add("    \"" & u & "\"\n")
    for u in peers: result.add("    \"" & u & "\"\n")
  result.add("  build:\n    discard aggregate(\"" & pkg &
    "-aggregate\", actions = @[])\n")

proc writeDependencyRecipe*(repoDir: string; uses: openArray[string];
    library = true; peers: openArray[string] = []) =
  ## Write ``repoDir/repro.nim`` declaring ``uses`` (``dependencyRecipe``)
  ## and make sure ``.repro/`` is ignored: a refresh, and the pre-push gate's
  ## derivation of the dependency set, compile the recipe under it, and an
  ## untracked ``.repro/`` would make the checkout dirty. Commits nothing.
  writeFile(repoDir / "repro.nim",
    dependencyRecipe(extractFilename(repoDir), uses, library, peers))
  for peer in peers:
    createDir(repoDir / PeerContractsDir)
    writeFile(repoDir / PeerContractsDir / (recipePackageName(peer) & ".nim"),
      "## The contract this recipe names its cycle peer `" & peer &
      "` through: no typed surface is needed, only a module.\n")
  let ignore = repoDir / ".gitignore"
  let existing = if fileExists(ignore): readFile(ignore) else: ""
  if ".repro/" notin existing.splitLines():
    writeFile(ignore, existing &
      (if existing.len > 0 and not existing.endsWith("\n"): "\n" else: "") &
      ".repro/\n")

proc refreshCommittedLock*(reproBin, repoDir: string): CmdResult =
  ## ``repro lock refresh`` in ``repoDir``: writes the committed lock from the
  ## recipe (commits nothing). ``REPROBUILD_NO_RUNQUOTA`` is set because the
  ## provider compile would otherwise ask a RunQuota daemon a fixture has not
  ## started; the suite runner sets it for every test edge as well.
  runShell(shellCommand(@[reproBin, "lock", "refresh"],
    [("REPROBUILD_NO_RUNQUOTA", "1")]), cwd = repoDir)

proc declareDependenciesInRecipes*(gitBin, reproBin, workspaceRoot: string;
    graph: openArray[(string, seq[string])]; publish = true):
    seq[tuple[repo, head: string]] =
  ## The one-call form of the above for a fixture whose repos already exist as
  ## git checkouts at ``workspaceRoot/<repo>`` (each with an ``origin`` whose
  ## ``main`` they track): give every repo of ``graph`` its recipe and commit
  ## it; then write, and commit, the lock of every repo that uses something,
  ## in ``graph`` order (list a dependency before its dependents when a
  ## dependent's lock should see the dependency's final commit); then, with
  ## ``publish``, push every repo's ``main``. Returns each repo's resulting
  ## HEAD. Raises on any failure, naming the command and its output, so a
  ## fixture that could not be built never reads as a test result.
  # A fixture clone need not carry an identity of its own (nor may it inherit
  # a signing setup), so the commits made here name one explicitly.
  let committerFlags = @["-c", "user.email=tester@example.invalid", "-c",
    "user.name=Fixture", "-c", "commit.gpgsign=false"]
  proc run(args: seq[string]; cwd: string): string =
    let res = runShell(shellCommand(args), cwd = cwd)
    if res.code != 0:
      raise newException(OSError, args.join(" ") & " (in " & cwd &
        ") exited " & $res.code & ":\n" & res.output)
    res.output.strip()
  for (repo, uses) in graph:
    let dir = workspaceRoot / repo
    writeDependencyRecipe(dir, uses, library = true)
    discard run(@[gitBin, "add", "-A"], dir)
    discard run(@[gitBin] & committerFlags & @["commit", "-q", "-m",
      "declare dependencies"], dir)
  for (repo, uses) in graph:
    if uses.len == 0: continue
    let dir = workspaceRoot / repo
    let refresh = refreshCommittedLock(reproBin, dir)
    if refresh.code != 0:
      raise newException(OSError, "repro lock refresh in " & dir &
        " exited " & $refresh.code & ":\n" & refresh.output)
    discard run(@[gitBin, "add", "repro.lock"], dir)
    discard run(@[gitBin] & committerFlags & @["commit", "-q", "-m", "lock"],
      dir)
  for (repo, _) in graph:
    let dir = workspaceRoot / repo
    if publish: discard run(@[gitBin, "push", "-q", "origin", "HEAD:main"], dir)
    result.add((repo: repo, head: run(@[gitBin, "rev-parse", "HEAD"], dir)))

proc writeLockEdges*(repoDir, selfName, selfRevision: string;
    pins: openArray[tuple[name, revision: string]];
    url = "file:///fixture/unfetchable";
    pinDepends: openArray[tuple[name, depends: string]] = [];
    rootDepends: openArray[string] = []) =
  ## Write ``repoDir/repro.lock`` recording that ``selfName`` depends on the
  ## repos ``pins`` names, at the revisions given — the lock EDGES a verb such
  ## as ``repro remove`` (reachability GC) or ``repro develop``'s dependency
  ## modes reads — without compiling a recipe. Only for a verb that reads the
  ## edges and nothing else about the lock: the pre-push gate holds a lock to
  ## what its recipe derives (``committed_lock_dependency_set_*``), so a gate
  ## fixture must use ``declareDependenciesInRecipes`` instead. Every entry
  ## carries the same placeholder fetch URL; nothing here is fetched.
  ## ``pinDepends`` gives a pinned entry its own ``depends`` (a comma-separated
  ## list), the per-entry edges a lock records for each of its entries.
  ## ``rootDepends`` is the root entry's own ``depends`` — the DIRECT
  ## dependencies, which is what ``repro lock refresh`` writes there when the
  ## entries also hold transitive ones; it defaults to every pinned name.
  proc entry(name, revision: string; self: bool; depends: string): string =
    "{ name = \"" & name & "\"" & (if self: ", self = \"true\"" else: "") &
      ", coord_kind = \"vcs\", url = \"" & url & "\", revision = \"" &
      revision & "\", integrity = \"git-sha1:" & revision & "\", version = " &
      "\"\", visibility = \"public\", participation = \"\", depends = \"" &
      depends & "\", tags = \"\" }"
  var names: seq[string]
  for p in pins: names.add(p.name)
  let direct = if rootDepends.len > 0: @rootDepends else: names
  var deps = @[entry(selfName, selfRevision, true, direct.join(","))]
  for p in pins:
    var depends = ""
    for d in pinDepends:
      if d.name == p.name: depends = d.depends
    deps.add(entry(p.name, p.revision, false, depends))
  writeFile(repoDir / "repro.lock",
    "schema = \"reprobuild.solved-graph-lock.v3\"\n\n[lock]\n" &
    "platform = \"amd64-linux\"\noptimal = false\n" &
    "inputs_digest = \"fixture\"\nvariants = []\npackages = []\n" &
    "deps = [" & deps.join(", ") & "]\n")

proc writeLockEdges*(repoDir, selfName: string; pins: openArray[string]) =
  ## ``writeLockEdges`` with a placeholder revision for every entry, for a
  ## verb that reads only the names.
  const placeholder = "0000000000000000000000000000000000000000"
  var withRevisions: seq[tuple[name, revision: string]]
  for p in pins: withRevisions.add((name: p, revision: placeholder))
  writeLockEdges(repoDir, selfName, placeholder, withRevisions)
