## End-to-end: a materialized LaunchPlan carries the runtime library
## directories its package's dependencies declare.
##
## The pieces are covered separately — the join in
## `repro_project_dsl/.../t_dsl_runtime_library_resolution`, the host-token and
## selector conversions in `t_runtime_library_binding`. What none of those prove
## is that the values survive the trip through `materializeLaunchers`,
## `storeLaunchPlan` and back out of the CAS, which is the only form in which a
## launcher ever sees them.
##
## That trip is exactly where the old behaviour hid: `runtimeLibraryDirs` was
## hardcoded to `@[]` inside `buildLaunchPlan`, so every component could have
## been correct and the plan would still have arrived empty. A test that stops
## short of reading the stored plan would not have caught it.

import std/[os, strutils, unittest]

import repro_local_store
import repro_launch_plan
import repro_home_apply
import repro_project_dsl
import repro_dsl_stdlib/prefix_layout

# The producer: a package providing a shared library on every host, so the test
# asserts the same expectation whatever it runs on. The per-host slice
# behaviour is covered by the resolution suite, which can vary the host.
package rlpProvider:
  runtimeLibrary "rlpthing", dir = "lib"

package rlpProviderConda:
  runtimeLibrary "rlpconda", dir = runtimeLibDir(plConda)

# The consumer whose launcher must end up carrying the directories.
package rlpConsumer:
  runtimeDeps:
    "rlpProvider"
    "rlpProviderConda"

# A package depending only on something that declares no runtime library.
package rlpToolOnlyConsumer:
  runtimeDeps:
    "rlpNotAProvider"

package rlpNotAProvider:
  uses:
    "nim >=2.2 <3.0"

proc tempRoot(name: string): string =
  ## A scratch root unique to this process.
  ##
  ## An earlier version keyed the path on `name` alone and `removeDir`'d it
  ## first. That collides between concurrent runs of the suite, and on Windows
  ## the `removeDir` itself can fail outright — store files are frequently
  ## read-only, and any lingering handle makes the whole test error rather than
  ## fail, which reads as a code defect when it is a fixture defect. Including
  ## the pid means each run gets its own tree and nothing has to be deleted
  ## before use.
  result = getTempDir() / ("repro-rlp-" & $getCurrentProcessId() & "-" & name)
  if dirExists(result):
    try:
      removeDir(result)
    except OSError:
      # Same-pid reuse within one run is not expected; if the directory cannot
      # be cleared, a fresh suffix is better than aborting the test.
      result = result & "-b"
  createDir(result)

proc realized(pkg, prefix, exe: string): RealizedRecord =
  result.packageId = pkg
  result.prefixAbsolutePath = prefix
  result.resolvedExecutablePath = exe

proc planFor(rootName: string; launcherPkg: string;
             records: seq[RealizedRecord]): LaunchPlan =
  ## Materialize launchers into a scratch store and read the stored plan back.
  let root = tempRoot(rootName)
  var store = openStore(root / "store")
  let binDir = root / "bin"
  let launchers = @[PlannedLauncher(commandName: launcherPkg,
                                    fromPackageId: launcherPkg)]
  let mats = materializeLaunchers(store, binDir, records, launchers)
  doAssert mats.len == 1, "expected exactly one materialized launcher"
  # Read the plan back out of the CAS rather than trusting the in-memory value:
  # the round trip is what a launcher actually consumes.
  readLaunchPlanByHex(store.root, prefixIdHex(mats[0].launchPlanDigest))

suite "a materialized launch plan carries declared runtime library dirs":
  test "one directory per declaring dependency, in declaration order":
    let plan = planFor("basic", "rlpConsumer", @[
      realized("rlpConsumer", "/prefix/consumer", "/prefix/consumer/bin/c.exe"),
      realized("rlpProvider", "/prefix/prov", ""),
      realized("rlpProviderConda", "/prefix/conda", "")])
    check plan.runtimeLibraryDirs == @["/prefix/prov/lib",
                                       "/prefix/conda/Library/bin"]

  test "the directory is the provider's prefix, not the consumer's":
    # The whole point of the producer-side declaration: the consumer never
    # names a path, and the path it gets is the PROVIDER's realized prefix.
    let plan = planFor("prefix", "rlpConsumer", @[
      realized("rlpConsumer", "/prefix/consumer", "/prefix/consumer/bin/c.exe"),
      realized("rlpProvider", "/somewhere/else", ""),
      realized("rlpProviderConda", "/prefix/conda", "")])
    check "/somewhere/else/lib" in plan.runtimeLibraryDirs
    for d in plan.runtimeLibraryDirs:
      check not d.startsWith("/prefix/consumer")

  test "a dependency declaring no runtime library contributes nothing":
    # The ordinary tool case. It must not fail, and must not invent a
    # directory.
    let plan = planFor("toolonly", "rlpToolOnlyConsumer", @[
      realized("rlpToolOnlyConsumer", "/prefix/t", "/prefix/t/bin/t.exe"),
      realized("rlpNotAProvider", "/prefix/n", "")])
    check plan.runtimeLibraryDirs.len == 0

  test "a package with no runtimeDeps gets an empty list, not a failure":
    let plan = planFor("nodeps", "rlpProvider", @[
      realized("rlpProvider", "/prefix/prov", "/prefix/prov/bin/p.exe")])
    check plan.runtimeLibraryDirs.len == 0

  test "an unrealized declaring dependency fails the launcher build":
    # Refusing is the contract: omitting the directory would produce a launcher
    # that looks complete and dies at load time — the original bug relocated.
    let root = tempRoot("unresolved")
    var store = openStore(root / "store")
    expect CatchableError:
      discard materializeLaunchers(store, root / "bin",
        @[realized("rlpConsumer", "/prefix/consumer",
                   "/prefix/consumer/bin/c.exe")],
        @[PlannedLauncher(commandName: "rlpConsumer",
                          fromPackageId: "rlpConsumer")])
