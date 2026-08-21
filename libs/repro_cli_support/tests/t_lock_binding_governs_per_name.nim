## `--lock <name>=<path>` is consumed **per name** by the build path.
##
## Named-Lock-Files NLF-M8, the first of the three criteria folded in from
## NLF-M7:
##
## > M7 landed the grammar, the validation, the errors and §5.3 resolution,
## > all tested — but `lockOverride` still carries only `default`'s binding.
## > Per-lock-file *builds* need the diamond to decide what happens where two
## > graphs meet, which is exactly this milestone. Closing the CLI half
## > without the diamond would ship a flag that parses and then quietly
## > governs one graph.
##
## ## What is asserted, and at which seam
##
## `governingLockIdentityFor` is the resolver every lowered edge's
## `governingLockIdentity` comes from — §7's keying reads it, and NLF-M7 made
## that keying effective, so this value is a real cache key and not a label.
## The assertions below are therefore about what a build would KEY ON, not
## about what a flag parsed into.
##
## Four properties, each separately falsifiable:
##
##   1. a bound name resolves to ITS file, not to `default`'s;
##   2. two names bound to two files give two identities — so the binding is
##      per name and not a single global override;
##   3. an unbound name falls back to `default`'s lock (§5.3 case 3), which
##      is a non-error;
##   4. binding nothing leaves every identity exactly where it was — the
##      NLF-STAT-4 requirement, asserted at the resolver rather than assumed
##      from the fixture.
##
## ## The bound this test does NOT paper over
##
## A designation written in a recipe does not reach this resolver today: the
## lowered graph the CLI receives carries no per-edge lock-file name, so
## `workspaceGoverningLockIdentity` asks for `default` for every edge. That is
## a protocol and codec gap, stated in `workspaceGoverningLockIdentity`'s own
## doc comment and repeated here so this file is not read as evidence for more
## than it shows. What it shows is that the resolver is per name and that the
## CLI's parsed bindings reach it.
##
## ## Test-double policy: NO mocks, doubles, or fakes
##
## Real lock documents written to a real temp tree by the real
## `serializeSolvedGraphLock`, read back by the real reader, and hashed by the
## real `lockIdentityOf`. `governingLockIdentityFor` is the production
## resolver, called directly.

import std/[os, tables, unittest]

import repro_cli_support
import repro_lock_files
import repro_lock
import repro_solver

const
  HostToolsLock = "locks/hostTools.lock"
  TargetLock = "locks/targetRuntime.lock"
  TargetRuntime = "targetRuntime"

var root = ""

proc lockTextFor(version: string): string =
  ## A real solved-graph lock whose CONTENT differs per `version`, so two
  ## files genuinely have two identities rather than two paths.
  var solution = UnifiedSolution(
    variants: initTable[string, string](),
    packages: initTable[string, string](),
    selected: initTable[string, SelectionStatus](),
    optimal: true)
  solution.packages["libfoo"] = version
  solution.selected["libfoo"] = ssSelected
  serializeSolvedGraphLock(
    solutionToLock(solution, currentPlatformId(), "nlf-m8 " & version))

proc writeLock(relPath, version: string) =
  createDir(root / relPath.parentDir())
  writeFile(root / relPath, lockTextFor(version))

suite "NLF-M8 --lock <name>=<path> is consumed per name":

  setup:
    resetLockFileDeclarations()
    resetActiveLockBindings()
    discard declareLockFile(TargetRuntime, description = "What we ship.")
    root = getTempDir() / ("repro-nlf-m8-bind-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    # The committed workspace lock — §5.3 case 3's terminus.
    writeFile(root / "repro.lock", lockTextFor("1.0.0"))
    writeLock(HostToolsLock, "2.0.0")
    writeLock(TargetLock, "3.0.0")

  teardown:
    resetActiveLockBindings()
    try: removeDir(root)
    except CatchableError: discard

  test "with nothing bound, every name resolves to the committed lock":
    # Property 4. This is the pre-NLF-M8 behaviour, and it has to survive
    # exactly: an invocation that passes no `--lock` must key its edges on
    # the same identity it always did.
    let committed = governingLockIdentityFor(root, DefaultLockFileName)
    check committed == governingLockIdentityFor(root, HostToolsLockFileName)
    check committed == governingLockIdentityFor(root, TargetRuntime)
    check committed == workspaceGoverningLockIdentity(root)
    check committed.isValid()

  test "a bound name resolves to ITS file":
    # Property 1, and the one that was false before this milestone.
    var bindings = initLockBindings()
    bindings.applyLockFlag(HostToolsLockFileName & "=" & root / HostToolsLock)
    setActiveLockBindings(bindings)
    let bound = governingLockIdentityFor(root, HostToolsLockFileName)
    resetActiveLockBindings()
    let committed = governingLockIdentityFor(root, DefaultLockFileName)
    check bound.isValid()
    check bound != committed

  test "two names bound to two files give two identities":
    # Property 2. A single global override would make these equal, and would
    # do so while passing the previous test.
    var bindings = initLockBindings()
    bindings.applyLockFlag(HostToolsLockFileName & "=" & root / HostToolsLock)
    bindings.applyLockFlag(TargetRuntime & "=" & root / TargetLock)
    setActiveLockBindings(bindings)
    let host = governingLockIdentityFor(root, HostToolsLockFileName)
    let target = governingLockIdentityFor(root, TargetRuntime)
    check host.isValid()
    check target.isValid()
    check host != target

  test "an UNBOUND name still falls back to default's lock, and is no error":
    # Property 3. §5.3: "there is **no third case, and in particular no error
    # for an unbound lock file**." Bind one name and leave the other unbound
    # in the SAME invocation, so the fallback is exercised alongside a live
    # binding rather than in isolation.
    var bindings = initLockBindings()
    bindings.applyLockFlag(HostToolsLockFileName & "=" & root / HostToolsLock)
    setActiveLockBindings(bindings)
    let host = governingLockIdentityFor(root, HostToolsLockFileName)
    let unbound = governingLockIdentityFor(root, TargetRuntime)
    let default = governingLockIdentityFor(root, DefaultLockFileName)
    check unbound == default
    check unbound != host

  test "two names bound to ONE file share one identity":
    # §6.2 and NLF-CLI-1: "both names resolve to one lock file's content, so
    # one set of artifacts is built and shared". The name is not in the key,
    # so this must be sharing and not two identities that happen to be equal
    # for the wrong reason — asserted by also checking it differs from the
    # committed lock, which is a THIRD file.
    var bindings = initLockBindings()
    bindings.applyLockFlag(
      HostToolsLockFileName & "," & TargetRuntime & "=" & root / HostToolsLock)
    setActiveLockBindings(bindings)
    let host = governingLockIdentityFor(root, HostToolsLockFileName)
    let target = governingLockIdentityFor(root, TargetRuntime)
    check host == target
    resetActiveLockBindings()
    check host != governingLockIdentityFor(root, DefaultLockFileName)

  test "the resolved binding is recorded in the provenance side table":
    # §6.3, and the reason it matters: `repro why` answers "which lock file
    # governs this edge" out of this table. Before NLF-M8 it recorded
    # `default` unconditionally, so it would have named the wrong lock file
    # for every bound name.
    var bindings = initLockBindings()
    bindings.applyLockFlag(TargetRuntime & "=" & root / TargetLock)
    setActiveLockBindings(bindings)
    let target = governingLockIdentityFor(root, TargetRuntime)
    check TargetRuntime in lockProvenance().namesFor(target)
