## Test support (not a test): NPC-M6's lock verbs end to end.
##
## A Nimble index repository is a real git repository whose commits carry
## `published-index/` written by the production index writer; the project
## reads it through the workspace's shared bare clone (under
## `REPRO_WORKSPACE_CLONES`), exactly as `repro ws sync` leaves it. The
## project is a directory with a `repro.solver` sidecar (its `uses:`, so no
## recipe is compiled), `repro-catalogs.toml` importing the index by a ref,
## and the lock the verbs write. The verbs run in process through
## ``runReproLockCommand``; their stdout and stderr are captured at the file
## descriptors, so what is checked is what a terminal would show.
##
## Nothing here contacts the internet; `example.invalid` names no host.

import std/[options, os, osproc, posix, strutils, tables, tempfiles, times]

import repro_lock
import repro_nimble_index
import repro_cli_support

import ../../repro_nimble_index/tests/index_fixtures
import ../../../tests/integration/published_catalog_fixtures

export index_fixtures, published_catalog_fixtures, repro_lock,
  repro_nimble_index, repro_cli_support, tables

const
  IndexRepo* = "nimble-index"
  IndexRemote* = "https://example.invalid/nim/nimble-index"

type
  World* = object
    root*: string
    clones*: string
    repo*: CatalogRepo

  Ran* = object
    rc*: int
    output*: string ## stdout and stderr, interleaved as written

proc newWorld*(tag: string): World =
  ## A scratch world: its own `HOME`, shared-clone root and index repository.
  result.root = createTempDir("npc-m6-" & tag & "-", "")
  createDir(result.root / "home")
  putEnv("HOME", result.root / "home")
  putEnv("XDG_CACHE_HOME", result.root / "home" / ".cache")
  result.clones = result.root / "clones"
  putEnv("REPRO_WORKSPACE_CLONES", result.clones)
  putEnv("REPRO_CACHE_DISABLE", "1")
  result.repo = initCatalogRepo(result.root, IndexRepo, IndexRemote)

proc publish*(w: World; packages: seq[PackageEnvelope]; generatedAt: int64;
              message: string; events: seq[OriginEvent] = @[];
              extraFiles: seq[(string, string)] = @[];
              sourceSet = none(IndexObjectId)):
    tuple[commit: string; built: BuiltIndex] =
  ## Commit a generation of ``packages`` on `main` and sync the shared
  ## clone. Returns the commit and the index. ``sourceSet``: the source-set
  ## identity the root names (the fixture's placeholder when none).
  var input = buildInput(packages)
  input.generatedAt = uint64(generatedAt)
  input.events = events
  if sourceSet.isSome: input.sourceSet = sourceSet.get
  result.built = buildIndex(input)
  # Committed by hand rather than through ``publishCommit``, which checks
  # the branch out with `-f` after the files are written (and so would
  # discard them) and cannot delete the previous generation's objects.
  let up = w.repo.upstream
  if execCmdEx("git -C " & quoteShell(up) &
      " rev-parse --verify -q refs/heads/main").exitCode == 0:
    discard git(["checkout", "-q", "-f", "main"], up)
  let dir = up / "published-index"
  if dirExists(dir): removeDir(dir)
  writeIndexDir(result.built, dir)
  for (rel, content) in extraFiles:
    createDir(parentDir(up / rel))
    writeFile(up / rel, content)
  discard git(["add", "-A"], up)
  discard git(["commit", "-q", "--allow-empty", "-m", message], up)
  result.commit = git(["rev-parse", "HEAD"], up).strip()
  discard w.repo.syncSharedClone(w.clones)

proc resetMain*(w: World; commit: string) =
  ## Move `main` back to ``commit`` upstream (a rewound index) and sync.
  discard git(["checkout", "-q", "-f", "main"], w.repo.upstream)
  discard git(["reset", "-q", "--hard", commit], w.repo.upstream)
  discard w.repo.syncSharedClone(w.clones)

var projects = 0

proc newProject*(w: World; requires: seq[(string, string)];
                 extra = ""): string =
  ## A project requiring ``requires`` (`nimble:` name, range) from the
  ## index imported by ref `main`. ``extra`` is appended to `repro.solver`.
  inc projects
  result = w.root / "projects" / ("p" & $projects)
  createDir(result)
  var solver = "package app\nversions: 1.0.0\n"
  for (n, r) in requires:
    solver.add "depends: nimble:" & n & (if r.len > 0: " " & r else: "") & "\n"
  solver.add extra
  writeFile(result / "repro.solver", solver)
  writeFile(result / "repro-catalogs.toml",
    "schema = \"reprobuild.catalog-imports.v1\"\n\n[[import]]\n" &
    "repo = \"" & IndexRepo & "\"\nremote = \"" & IndexRemote & "\"\n" &
    "kind = \"nimble-index\"\nref = \"main\"\n")

proc captured*(body: proc (): int): Ran =
  ## Run ``body`` with fd 1 and 2 redirected to a file; return its result
  ## and everything written.
  let (f, path) = createTempFile("npc-m6-out-", ".txt")
  close(f)
  flushFile(stdout)
  flushFile(stderr)
  let saveOut = dup(1)
  let saveErr = dup(2)
  let fd = posix.open(path.cstring, O_WRONLY or O_TRUNC, 0o600)
  doAssert fd >= 0
  discard dup2(fd, 1)
  discard dup2(fd, 2)
  try:
    result.rc = body()
  finally:
    flushFile(stdout)
    flushFile(stderr)
    discard dup2(saveOut, 1)
    discard dup2(saveErr, 2)
    discard posix.close(fd)
    discard posix.close(saveOut)
    discard posix.close(saveErr)
  result.output = readFile(path)
  removeFile(path)

proc lockVerb*(dir: string; verb: string; extra: seq[string] = @[]): Ran =
  ## `repro lock <verb> <dir> --inputs <dir>/repro.solver <extra...>`.
  let args = @[verb, dir, "--inputs", dir / "repro.solver"] & extra
  captured(proc (): int = runReproLockCommand(args))

proc refreshProvisioning*(dir: string; extra: seq[string] = @[]): Ran =
  lockVerb(dir, "refresh", @["--provisioning"] & extra)

proc lockDiff*(oldLock, newLock: string): Ran =
  captured(proc (): int = runReproLockCommand(@["diff", oldLock, newLock]))

proc lockOf*(dir: string): LockedDependencies =
  parseLockedDependencies(readFile(dir / "repro.lock"))

proc nimbleRows*(dir: string): Table[string, LockedDep] =
  for d in lockOf(dir).deps:
    if d.name.startsWith("nimble:"): result[d.name] = d

proc indexPin*(dir: string): LockedCatalogImport =
  for p in lockOf(dir).lockedCatalogImportPins():
    if p.repo == IndexRepo: return p

proc daysAgo*(days: int): int64 =
  getTime().toUnix - int64(days) * 86_400

proc isoUtc*(t: int64): string =
  fromUnix(t).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
