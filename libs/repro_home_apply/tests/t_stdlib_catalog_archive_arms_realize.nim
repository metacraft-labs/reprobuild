## Every built-in catalog `tarball` arm the HOME ARCHIVE REALIZER owns and
## this host's platform selects realizes, and every path it declares is bound.
##
## The sibling of ``tests/integration/t_stdlib_catalog_tarball_arms_realize.nim``,
## for the other half of the split recorded as Provisioning-Contributions.md
## §"Open gaps" 3. Each arm is routed to exactly one realizer: an arm that
## asks for an installer run, an MSYS2 merge, a pre-install step, launcher
## emission, a nested 7z pass, an ``extractPath`` flatten or a digest other
## than SHA-256 is realized by ``builtin_adapter.realizeBuiltinPackage`` and
## refused by name by the `uses:` provisioning edge. Ten of this host's
## catalog arms are in that class — ``go``, ``crystal``, ``ghc``, ``gradle``
## x2, ``jdk``, ``llvm-mingw``, ``maven``, ``zig`` x2 — so a sweep that only
## drove the `uses:` edge would report them as "not mine" and nothing would
## check them.
##
## **The rule applied here is this realizer's own, and it is weaker.** The
## `uses:` edge probes with ``rejectSymlinks = true``; ``realizeBuiltinPackage``
## does not, and arms it owns rely on that: ``llvm-mingw`` declares
## ``bin/clang``, a symlink to ``clang-22`` in the pinned bindist, and
## declaring ``bin/clang-22`` instead would be a worse declaration that breaks
## at the next LLVM bump. Conformance is judged against the realizer that owns
## the arm — the requirement is to run the probe realization uses, and for
## this realizer that is: the declared path, FOLLOWING symlinks, exists inside
## the realized prefix and is executable. See
## ``repro_home_apply/archive_conformance`` for the rule and
## ``Provisioning-Contributions.md`` §"Open gaps" 3 for what unifying the two
## would then require of those arms.
##
## Every declared path is checked, not only the primary: ``detail
## .extraExecutables`` are the interface's other exported executables, and
## "every exported executable or library has a realization binding" is the
## first bullet of §"Conformance And Trust". ``jdk`` declares four and the
## Linux ``ghc`` seven.
##
## What it found when first run, against `agents` @ a6491129 on Linux x86_64 —
## both defects in ``ghc``'s Linux arm, and neither visible from the recipe:
## ``extractPath = "ghc-9.12.1"`` where the bindist's inner directory is
## ``ghc-9.12.1-x86_64-unknown-linux`` (so the arm had NEVER realized), and
## ``extraExecutable = "bin/ghci-9.12.1"``, which the bindist carries only as
## an install-time template under ``wrappers/``.
##
## This sweep is per-host by construction, exactly as its sibling is: an arm
## declares the platform it is for, so a Linux run decides nothing about a
## Windows arm, and where a platform has no suite run its arms are unverified
## (``issues/2026-10-07-reprobuilds-full-suite-has-no-windows-run.md``).
##
## No mocks. A network test: it fetches each arm's archive once into a store
## keyed by the realization hash. Point ``REPRO_CONFORMANCE_HOME_STORE`` at a
## directory that survives between runs and the cost is paid once per pin.
## Measured on Linux x86_64 over this host's ten arms: ~8.8 GB extracted, of
## which ghc's bindist is most. A lane that does not set that variable pays it
## every run — the suite-budget problem recorded as ``issues/
## 2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling.md``.
##
## Falsifiable, and both were re-measured rather than predicted: restore
## ``extractPath = "ghc-9.12.1"`` and this sweep reports ``realize-failed``
## for that arm with "extract_path 'ghc-9.12.1' not present"; restore
## ``extraExecutable = "bin/ghci-9.12.1"`` and it reports ``realize-failed``
## with "realized prefix for 'ghc' v9.12.1 is missing declared binary
## 'bin/ghci-9.12.1'" — the home realizer refuses an absent ``binRelpath``
## itself, so the absent case never reaches this check's own verdict. The
## verdict that does fire here is the one the realizer does NOT decide:
## declare a path that exists without an execute bit (``build.mk`` in ghc's
## prefix) and it reports ``declared-executable-not-executable``.

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles/tarball_conformance
import repro_home_apply/archive_conformance
# The WHOLE catalog's arms; see that module on why the enrolment is explicit.
import repro_dsl_stdlib/catalog_tarball_packages

proc toolUseFor(packageName: string): InterfaceToolUse =
  ## The arms a consumer naming ``packageName`` reaches, from the registered
  ## stdlib definition, so the declarations under test are the recipe's own.
  let iface = toProjectInterface(PackageDef(
    packageName: "archiveConformanceConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: packageName, packageSelector: packageName,
      executableName: packageName, depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1,
    "expected one tool use for " & packageName
  iface.toolUses[0]

suite "stdlib catalog archive arms realize through the home realizer":
  let persistentStore = getEnv("REPRO_CONFORMANCE_HOME_STORE")
  let scratch = createTempDir("repro-archive-conformance-", "")
  let storeDir =
    if persistentStore.len > 0: absolutePath(persistentStore)
    else: scratch / "store"
  # As in the sibling sweep: a realize may run a probe whose working
  # directory is this process's, so stand somewhere disposable.
  let originalDir = getCurrentDir()
  setCurrentDir(scratch)

  test "every home-realizer arm this host selects realizes and binds":
    let target = conformanceTargetTokens()
    checkpoint("target: " & target.os & "/" & target.cpu)
    checkpoint("store: " & storeDir)

    var hostArms = 0
    var homeArms = 0
    var failures: seq[string] = @[]
    var seenPackages: seq[string] = @[]

    for pkg in registeredPackages():
      if pkg.tarballProvisioning.len == 0: continue
      if pkg.packageName in seenPackages: continue
      seenPackages.add(pkg.packageName)

      var useDef: InterfaceToolUse
      try:
        useDef = toolUseFor(pkg.packageName)
      except CatchableError as err:
        failures.add(pkg.packageName & ": no tool use (" &
          err.msg.splitLines()[0] & ")")
        continue

      for arm in useDef.tarballProvisioning:
        if not armMatchesTarget(arm, target.os, target.cpu): continue
        inc hostArms
        let label = describeArm(pkg.packageName, arm)
        let verdict = conformArchiveArm(pkg.packageName, arm, storeDir)
        case verdict.verdict
        of aacOwnedByUsesEdge:
          discard
        of aacOk:
          inc homeArms
          checkpoint(label)
        else:
          inc homeArms
          failures.add(label & "\n      " & $verdict.verdict & ": " &
            verdict.detail)

    checkpoint("arms for this host: " & $hostArms)
    checkpoint("of those, owned by the home archive realizer: " & $homeArms)
    for failure in failures:
      checkpoint("NOT CONFORMANT: " & failure)

    # Structural floor against a vacuous pass: this host has arms, and some of
    # them are this realizer's. A host with none would be a platform whose
    # catalog carries no installer-class arm at all, which is not any platform
    # the catalog supports today — and if it became one, this check saying so
    # is the right outcome rather than a silent zero.
    check hostArms > 0
    check homeArms > 0
    check failures.len == 0

  setCurrentDir(originalDir)
  try: removeDir(scratch) except CatchableError: discard
