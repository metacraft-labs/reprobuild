## No built-in catalog ``tarball`` arm declares a source tree's build driver
## as the executable it provides.
##
## ``spec/CLI/build.md`` (``--tool-provisioning=tarball``): "realizes each tool
## from its pinned tarball; a package with no tarball for the host falls
## through to its from-source recipe". A tarball arm is therefore a claim that
## the archive IS the tool for the hosts it names. An upstream SOURCE release
## declared as an arm breaks that twice over: the consumer that asked for the
## tool is handed a build script, and because an arm matched, the fall-through
## to the from-source recipe — the place a source tree belongs — never happens.
##
## That is what ``perl`` did: its one arm was the cpan.org source release,
## ``os = "any"``, with ``Configure`` as the executable (reprobuild-pm/issues/
## 2026-10-20-stdlib-perl-tarball-realization-is-a-source-tree-not-a-perl.md).
## The conformance sweep could not catch it — ``Configure`` IS a regular,
## executable file inside the archive, so the arm realized and probed clean —
## and the M9.R.11 placeholder check only looked for the lower-case
## ``configure`` / ``configure.sh`` in a fixed list of packages. This guard
## covers the class across the WHOLE catalog (``catalog_tarball_packages``,
## the same enrolment the conformance sweeps use), every host's arms, and
## both ``executablePath`` and every ``extraExecutable``.
##
## The name list is deliberately conservative: only file names that are
## unambiguously a source tree's build driver or build description, never a
## name a binary distribution could plausibly ship as its tool. It is a
## declaration check, so it runs offline and needs no download.
##
## No mocks: the real registered catalog.
##
## Falsifiable: restore perl's former arm (``executablePath = "Configure"``)
## and the case names it.

import std/[os, strutils, unittest]

import repro_project_dsl
import repro_dsl_stdlib/catalog_tarball_packages

const SourceBuildDrivers = [
  "configure", # autoconf's generated driver
  "Configure", # perl's and OpenSSL's hand-written drivers
  "configure.sh",
  "configure.ac", "configure.in",
  "autogen.sh",
  "Makefile.am", "Makefile.in",
  "Makefile.SH", # perl's generated-makefile driver
  "Makefile.PL", # a CPAN distribution's build driver
  "CMakeLists.txt",
  "meson.build",
]

proc declaredBasename(path: string): string =
  ## The file name an arm declares, for both separator spellings the catalog
  ## uses (``bin/x`` and ``bin\\x``) whatever host this runs on.
  extractFilename(path.replace('\\', '/'))

suite "no catalog tarball arm declares a source build driver":

  test "every arm's executables are tools, not a source tree's driver":
    var arms = 0
    var offenders: seq[string] = @[]
    for pkg in registeredPackages():
      for arm in pkg.tarballProvisioning:
        inc arms
        var declared = @[arm.executablePath]
        for extra in arm.detail.extraExecutables:
          declared.add(extra)
        for path in declared:
          if declaredBasename(path) in SourceBuildDrivers:
            offenders.add(pkg.packageName & ": " & path & " in " & arm.url &
              " (os=" & (if arm.os.len > 0: arm.os else: "any") &
              " cpu=" & (if arm.cpu.len > 0: arm.cpu else: "any") & ")")
    checkpoint("tarball arms inspected: " & $arms)
    for offender in offenders:
      checkpoint("SOURCE TREE POSING AS A TOOL: " & offender)
    # A floor against a vacuous pass: every enrolled module declares at
    # least one arm, so an enumeration that found fewer saw nothing.
    check arms >= CatalogTarballModules.len
    check offenders.len == 0
