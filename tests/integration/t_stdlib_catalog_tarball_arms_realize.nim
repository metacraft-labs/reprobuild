## Every built-in catalog `tarball` arm this host's platform selects realizes,
## and its declared executable passes the probe realization applies.
##
## Provisioning-Contributions.md §"Conformance of an archive realization is
## decided by realizing it". The only check that had ever audited the built-in
## catalog read recipe SOURCE TEXT and string-matched it: it asserted that an
## entry MENTIONS a provisioning arm, and never asked whether the executable
## that arm declares exists in the archive, or is reachable the way
## realization requires. A declared path is a claim about a third party's
## layout, and text cannot decide it either way
## (reprobuild-pm/issues/
## 2026-09-24-no-conformance-check-runs-against-stdlib-tarball-arms.md).
##
## This is the sweep that decides it, for the realizer that owns a plain
## archive: the `uses:` provisioning edge. Per arm, through
## ``conformTarballArm`` — which realizes with ``resolveTarballTool``, the same
## path `repro` uses — it requires that
##
##   * the pinned digest matches the bytes the URL serves (a realize failure
##     is a conformance failure: an arm with a stale digest can never be
##     realized by anyone);
##   * ``executablePath`` resolves inside the sealed prefix to a regular file,
##     reached without traversing a symlink, with an execute bit on POSIX;
##   * every ``extraExecutable`` the arm exports beside it resolves inside the
##     prefix and is executable (symlinks followed — see
##     ``tarball_conformance`` on why the symlink rule is the primary path's
##     and not the field's);
##   * an ``executableAlias``, when declared, is a file of that name beside
##     the declared executable, because the alias is the name consumers
##     invoke.
##
## It is PER ARM, not per package. Selection picks one arm per host, so a
## package with two eligible arms (``zig`` 0.13 and 0.16, ``gradle`` 8 and 9,
## ``claude-code`` two releases) would otherwise have only its first ever
## realized and the second could be wrong indefinitely.
##
## What it found when first run, against `agents` @ a6491129 on Linux x86_64 —
## five arms, all of them live in production recipes, none reachable by any
## text check: ``npm`` and ``npx`` declared ``bin/npm`` / ``bin/npx``, which
## are symlinks in every POSIX Node tarball; ``perl`` and ``swig`` carried
## pinned digests matching no bytes upstream has ever served; and ``nim``
## exported ``bin/nimgrab``, which upstream's linux_x64 bundle does not
## contain.
##
## ## This sweep is per-host, by construction
##
## An arm declares the platform it is for, and only a host of that platform
## can realize it. A Linux run therefore decides nothing about a Windows arm —
## and 134 of the catalog's 227 arms are Windows ones, including the ten core
## shell tools that point by hand-written path into one PortableGit archive.
## Full catalog coverage needs the suite to run on each supported platform;
## where it does not, those arms are unverified and the gap belongs to that
## platform's CI (``issues/
## 2026-10-07-reprobuilds-full-suite-has-no-windows-run.md``). This file says
## so rather than letting a green Linux run read as a green catalog.
##
## Arms the HOME ARCHIVE REALIZER owns (an ``extractPath`` flatten, an
## installer, an MSYS2 merge, a non-SHA-256 digest) are reported here and
## checked by ``libs/repro_home_apply/tests/
## t_stdlib_catalog_archive_arms_realize.nim``, which applies that realizer's
## own rule. Ownership is read structurally from
## ``archiveInstallerFeatures``, so neither sweep decides it by parsing a
## refusal.
##
## No mocks. A network test: it fetches each arm's archive once, keyed by the
## pinned digest. Point ``REPRO_CONFORMANCE_STORE`` at a directory that
## survives between runs and the cost is paid once per pin rather than once
## per run; without it a temporary store is used and discarded. Measured on
## Linux x86_64 over this host's 39 ``uses:``-edge arms: ~1.8 GB fetched,
## ~6.1 GB extracted. A lane that does not set that variable pays it every
## run, which is the suite-budget problem recorded as ``issues/
## 2026-09-30-reprobuild-ci-cannot-finish-within-the-six-hour-ceiling.md``,
## not a reason to decide conformance less often.
##
## Falsifiable: restore ``executablePath = "bin/npm"`` on npm's POSIX arms and
## this sweep reports ``realize-failed`` for that arm with "extracted tarball
## declares executable bin/npm, which is present but reached through a
## symlink"; revert perl's digest and it reports "all tarball archive URLs
## failed for perl".

import std/[os, strutils, tempfiles, unittest]

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_tool_profiles/tarball_conformance
# The WHOLE catalog's arms, not the part some other consumer links. See that
# module: an arm nothing imports reaches no sweep, and an offline gate
# (``libs/repro_dsl_stdlib/tests/
# t_every_catalog_tarball_arm_is_enrolled_for_conformance.nim``) keeps the
# enrolment honest.
import repro_dsl_stdlib/catalog_tarball_packages

proc toolUseFor(packageName: string): InterfaceToolUse =
  ## The tool use a consumer declaring ``uses: "<packageName>"`` gets, built
  ## from the registered stdlib definition so the arms under test are the
  ## recipe's own rather than a copy of them.
  let iface = toProjectInterface(PackageDef(
    packageName: "catalogConformanceConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: packageName, packageSelector: packageName,
      executableName: packageName, depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1,
    "expected one tool use for " & packageName
  iface.toolUses[0]

suite "stdlib catalog tarball arms realize on this host":
  # Publishing is irrelevant here and would need credentials plus a reachable
  # endpoint; disable the shared cache so each realize is local and the bytes
  # come from upstream.
  putEnv("REPRO_CACHE_DISABLE", "1")

  let persistentStore = getEnv("REPRO_CONFORMANCE_STORE")
  let scratch = createTempDir("repro-catalog-conformance-", "")
  let storeRoot =
    if persistentStore.len > 0: absolutePath(persistentStore)
    else: scratch / "store"

  # Run from a scratch directory, because resolving a profile RUNS the
  # package's configured probe (``collectConfiguredProbes`` -> ``runProbe``,
  # typically ``<exe> --version``) and a probe's working directory is the
  # caller's. Measured: ``perl``'s arm declares the source tree's
  # ``Configure`` as its executable, and ``Configure --version`` answers by
  # creating a ``UU/`` scratch directory in the CWD — which, run from the
  # repo root, lands an untracked directory in the checkout. The store root
  # is resolved to an absolute path above, so nothing else here depends on
  # where this process stands.
  let originalDir = getCurrentDir()
  setCurrentDir(scratch)

  test "every arm this host selects realizes and probes clean":
    let target = conformanceTargetTokens()
    checkpoint("target: " & target.os & "/" & target.cpu)
    checkpoint("store: " & storeRoot)

    var totalArms = 0
    var hostArms = 0
    var homeRealizerArms = 0
    var failures: seq[string] = @[]
    var seenPackages: seq[string] = @[]

    for pkg in registeredPackages():
      if pkg.tarballProvisioning.len == 0: continue
      # A package registered twice (a module imported through two paths) is
      # one package; its arms must not be realized twice.
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
        inc totalArms
        if not armMatchesTarget(arm, target.os, target.cpu): continue
        inc hostArms
        let label = describeArm(pkg.packageName, arm)
        checkpoint(label)
        let verdict = conformTarballArm(useDef, arm, storeRoot)
        case verdict.verdict
        of acvOk:
          # A note here means the arm conforms but this host cannot start
          # it (NixOS); the realizer refuses it at resolution instead.
          if verdict.detail.len > 0:
            checkpoint(label & ": " & verdict.detail)
        of acvOwnedByHomeRealizer:
          inc homeRealizerArms
        else:
          failures.add(label & "\n      " & $verdict.verdict & ": " &
            verdict.detail)

    checkpoint("arms on the interface: " & $totalArms)
    checkpoint("arms for this host: " & $hostArms)
    checkpoint("of those, owned by the home archive realizer: " &
      $homeRealizerArms)
    for failure in failures:
      checkpoint("NOT CONFORMANT: " & failure)

    # Structural floors against a vacuous pass. An enumeration that silently
    # yielded nothing would otherwise report a clean sweep over no arms;
    # every enrolled module declares at least one arm, so the catalog's arm
    # count cannot be below the enrolment's size.
    check totalArms >= CatalogTarballModules.len
    check hostArms > 0
    check failures.len == 0

  setCurrentDir(originalDir)
  try: removeDir(scratch) except CatchableError: discard
