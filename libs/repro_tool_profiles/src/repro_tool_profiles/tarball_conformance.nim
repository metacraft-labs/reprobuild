## Conformance of one `tarball` arm, decided by realizing it.
##
## Provisioning-Contributions.md §"Conformance of an archive realization is
## decided by realizing it": for an archive realization, "every exported
## executable has a realization binding" and "executable probes pass" are
## claims about a THIRD PARTY'S ARCHIVE, not about the recipe's text. A check
## that reads the declaration decides neither, because `executablePath` is a
## path typed into somebody else's layout and the recipe cannot say whether
## that path is a regular file, a directory, a symlink or absent.
##
## This module is the check. Given a package's tool use and one of its arms it
## realizes that arm from its pinned URL and digest through
## ``resolveTarballTool`` — the same path `repro` uses, not a re-implementation
## of it — and then applies the realizer's own probe to the result.
##
## It exists as a library rather than inside a test because two sweeps drive
## it (the `uses:` provisioning edge's arms here, the home archive realizer's
## arms through ``repro_home_apply/archive_conformance``) and because a check
## whose logic lives in a test cannot be run from anywhere else.
##
## **Ownership is decided structurally, never from message text.** Each arm is
## routed to exactly one realizer (Provisioning-Contributions.md §"Open gaps"
## 3); ``archiveInstallerFeatures`` is that routing, so an arm the `uses:`
## edge does not perform is reported as ``acvOwnedByHomeRealizer`` without a
## download, rather than realized and then classified by parsing the refusal
## it raised.

import std/[os, strutils]

import repro_interface_artifacts
# The parent module, for ``resolveTarballTool`` and ``PathOnlyToolProfile``,
# and through its re-exports for ``declared_executable`` and
# ``realization_selection``. The dependency runs this way only: nothing in the
# realizer needs the conformance check, so there is no cycle.
import repro_tool_profiles

type
  ArmConformanceVerdict* = enum
    ## What realizing one arm on this host established.
    acvOk = "ok"
      ## Realized, and the declared executable is a regular file inside the
      ## sealed prefix.
    acvOwnedByHomeRealizer = "owned-by-home-realizer"
      ## The arm asks for work only the home archive realizer performs, so
      ## this sweep is not its conformance check. Nothing was downloaded.
    acvRealizeFailed = "realize-failed"
      ## Realization itself refused or failed: a stale digest, an upstream
      ## that no longer serves the URL, an extractor the host lacks. The
      ## realizer's own first line is in ``detail``.
    acvDeclaredExecutableMissing = "declared-executable-missing"
    acvDeclaredExecutableSymlinked = "declared-executable-symlinked"
    acvDeclaredExecutableNotExecutable = "declared-executable-not-executable"
    acvDeclaredExecutableOutsidePrefix = "declared-executable-outside-prefix"
      ## The realization reported an executable that is not under the prefix
      ## it sealed — "realization paths remain inside the realized prefix" is
      ## the last bullet of §"Conformance And Trust".
    acvDeclaredExtraExecutableUnbound = "declared-extra-executable-unbound"
      ## The arm declares an ``extraExecutable`` the realized prefix does not
      ## bind under this realizer's rule. ``detail`` carries which path and
      ## which of the four ways it failed.
      ##
      ## ``extraExecutables`` are "prefix-relative executables exported
      ## beside ``executablePath``" (``TarballArchiveDetail``), so they are
      ## exported executables of the same interface and
      ## §"Conformance And Trust" asks for a realization binding for EVERY
      ## one of them — not only the first. They are checked here for the
      ## same reason the primary is: the path is typed into a third party's
      ## layout and the recipe cannot say whether it is there.
      ##
      ## Measured on this host when the check was added, which is why the
      ## verdict exists: ``nim``'s Linux arm declared ``bin/nimgrab``, which
      ## the pinned nim-2.2.10 tarball does not contain — it ships only the
      ## source, ``tools/nimgrab.nim``, which upstream builds with ``koch
      ## tools`` and does not put in the prebuilt bundle.
    acvDeclaredAliasMissing = "declared-alias-missing"
      ## The arm declares an ``executableAlias`` and the realized prefix does
      ## not carry a file of that name beside the declared executable.
      ##
      ## This is a conformance failure and not a detail of realize, because
      ## the alias is THE NAME CONSUMERS INVOKE: a realized prefix reaches
      ## PATH as a directory, so a command's name there is a file's own name.
      ## An arm whose declared payload is a script
      ## (``lib/node_modules/npm/bin/npm-cli.js``) satisfies every check on
      ## its ``executablePath`` while the command the recipe exists to
      ## provide is absent — which is "every exported executable has a
      ## realization binding" unmet, the first bullet of the same section.
      ##
      ## **What this verdict does NOT catch, measured rather than assumed.**
      ## The first attempt at npm's POSIX arms wrote ``prunePaths = @[...]``
      ## where the DSL spells a repeatable ``prune = "<path>"``; the unknown
      ## argument was dropped silently (issues/
      ## 2026-10-08-package-level-dsl-heads-and-bodies-silently-drop-arguments.md),
      ## upstream's own ``npm`` script survived in the directory that goes on
      ## PATH, and realize skipped the alias it would otherwise have written
      ## because that name already existed. **Re-measured with this verdict
      ## in place, the sweep is still green on that tree**, because the name
      ## does exist — as somebody else's file. The same holds for dropping
      ## ``executableAlias`` itself: the arm then declares no alias, this
      ## check does not run, and the prefix carries no command at all.
      ##
      ## Neither is reachable from a conformance sweep, and the reason is
      ## structural rather than a missing assertion: a silently dropped
      ## argument leaves NO declaration to check reality against. Closing it
      ## belongs to the DSL refusing unknown arguments (the issue above), and
      ## to the realizer deciding whether an alias name already occupied by
      ## the archive should be overwritten rather than conceded. What this
      ## verdict does cover is the case where the declaration survives and
      ## the realization does not honour it.

  ArmConformance* = object
    ## One arm's verdict, carrying enough to name the arm in a failure
    ## without the caller holding the declaration too.
    packageSelector*: string
    url*: string
    declaredExecutablePath*: string
    archiveType*: string
    os*: string
    cpu*: string
    verdict*: ArmConformanceVerdict
    detail*: string
    prefix*: string
    resolvedExecutablePath*: string

proc conformanceTargetTokens*(): tuple[os, cpu: string] =
  ## The ``os``/``cpu`` tokens a catalog arm is written in, for THIS host.
  ##
  ## Spelled from the compile-time host rather than taken from
  ## ``hostRealizationTarget``: an arm's ``os``/``cpu`` are the recipe
  ## author's strings ("linux", "macos", "windows" / "x86_64", "aarch64"),
  ## and ``hostCPU`` answers "amd64" on the same machine.
  let osToken =
    when defined(linux): "linux"
    elif defined(macosx): "macos"
    elif defined(windows): "windows"
    else: hostOS
  let cpuToken =
    when defined(amd64): "x86_64"
    elif defined(arm64): "aarch64"
    else: hostCPU
  (os: osToken, cpu: cpuToken)

proc armMatchesTarget*(arm: InterfaceTarballProvisioning;
                       os, cpu: string): bool =
  ## Whether ``arm`` is declared for the (os, cpu) target.
  ##
  ## An empty field and ``any`` are both wildcards — a package with one arm
  ## for every host leaves them off (`perl`, `swig`) and one that spells it
  ## out writes ``any``. The CPU side also accepts the ``amd64`` / ``x64``
  ## spellings of x86_64, which catalog entries use interchangeably.
  let armOs = arm.os.toLowerAscii
  let armCpu = arm.cpu.toLowerAscii
  let wantOs = os.toLowerAscii
  let wantCpu = cpu.toLowerAscii
  let osOk = armOs.len == 0 or armOs == "any" or armOs == wantOs
  let cpuOk = armCpu.len == 0 or armCpu == "any" or armCpu == wantCpu or
    (wantCpu == "x86_64" and armCpu in ["amd64", "x64"]) or
    (wantCpu == "aarch64" and armCpu in ["arm64"])
  osOk and cpuOk

proc describeArm*(packageSelector: string;
                 arm: InterfaceTarballProvisioning): string =
  ## A one-line identification of an arm, for a checkpoint or a failure.
  packageSelector & " [" & arm.executablePath & "] " & arm.url &
    " (" & (if arm.os.len > 0: arm.os else: "any") & "/" &
    (if arm.cpu.len > 0: arm.cpu else: "any") & ")"

proc verdictFor(probe: DeclaredExecutableProbe): ArmConformanceVerdict =
  case probe.verdict
  of deOk: acvOk
  of deSymlinkedPath: acvDeclaredExecutableSymlinked
  of deNotExecutable: acvDeclaredExecutableNotExecutable
  of deUnsafePath, deMissing: acvDeclaredExecutableMissing

proc conformTarballArm*(useDef: InterfaceToolUse;
                        arm: InterfaceTarballProvisioning;
                        storeRoot: string): ArmConformance =
  ## Realize exactly ``arm`` into ``storeRoot`` and probe what it produced.
  ##
  ## ``useDef`` supplies the package identity and the tool-use shape; the arm
  ## is substituted for the package's whole arm list so selection cannot pick
  ## a sibling. That is what makes this a per-ARM check: a package with two
  ## eligible arms for one host (`zig` 0.13 and 0.16, `gradle` 8 and 9) would
  ## otherwise only ever have its first one realized, and the second could be
  ## wrong indefinitely.
  result = ArmConformance(packageSelector: useDef.packageSelector,
    url: arm.url, declaredExecutablePath: arm.executablePath,
    archiveType: arm.archiveType, os: arm.os, cpu: arm.cpu)

  let homeFeatures = archiveInstallerFeatures(arm)
  if homeFeatures.len > 0:
    result.verdict = acvOwnedByHomeRealizer
    result.detail = "needs " & homeFeatures.join(", ")
    return

  var single = useDef
  single.tarballProvisioning = @[arm]
  var profile: PathOnlyToolProfile
  try:
    profile = resolveTarballTool(single, storeRoot)
  except CatchableError as err:
    result.verdict = acvRealizeFailed
    result.detail = err.msg.splitLines()[0]
    return

  result.prefix = profile.selectedStorePath
  result.resolvedExecutablePath = profile.resolvedExecutablePath

  # The realizer's own probe, re-applied to the sealed prefix. Asking the
  # prefix again rather than trusting the receipt is the point: a receipt is
  # a claim about a realization, and this check exists because claims about
  # realizations were what nobody had verified.
  let probe = probeDeclaredExecutable(result.prefix, arm.executablePath,
    rejectSymlinks = true)
  if probe.verdict != deOk:
    result.verdict = verdictFor(probe)
    result.detail = probe.reason
    return

  if not probe.resolvedPath.startsWith(result.prefix):
    result.verdict = acvDeclaredExecutableOutsidePrefix
    result.detail = probe.resolvedPath & " is not under " & result.prefix
    return

  # Every OTHER executable the arm exports. See
  # ``acvDeclaredExtraExecutableUnbound``: an ``extraExecutable`` is an
  # exported executable of the interface, so "every exported executable has a
  # realization binding" reaches it, and a check that stopped at
  # ``executablePath`` would leave the rest of a multi-tool archive's claims
  # (cmake's ``ctest``, foundry's ``anvil``, nim's seven) asserted by nothing
  # that had opened the archive.
  #
  # **Symlinks are FOLLOWED here, and that is the rule rather than a
  # relaxation of one.** ``rejectSymlinks`` applies to ``executablePath``
  # because that is the path realize seals, reports as
  # ``resolvedExecutablePath`` and records in the receipt. An
  # ``extraExecutable`` is never that: it is reached by NAME from the prefix
  # directory once that directory is on PATH, and a link inside the prefix
  # pointing at a sibling inside the same prefix serves that name correctly.
  # So the rule asked of it is the one ``repro_home_apply/
  # archive_conformance`` already asks of the extras it owns — present
  # following symlinks, resolving inside the prefix, executable — which also
  # keeps one rule for the field across both realizers.
  for extra in arm.detail.extraExecutables:
    if extra.len == 0: continue
    let extraProbe = probeDeclaredExecutable(result.prefix, extra)
    if extraProbe.verdict != deOk:
      result.verdict = acvDeclaredExtraExecutableUnbound
      result.detail = "declares extraExecutable " & extra & ": " &
        extraProbe.reason
      return
    var resolvedExtra = extraProbe.resolvedPath
    try:
      resolvedExtra = expandFilename(resolvedExtra)
    except OSError, IOError:
      result.verdict = acvDeclaredExtraExecutableUnbound
      result.detail = "declares extraExecutable " & extra &
        ", which is present but does not resolve"
      return
    if not resolvedExtra.startsWith(expandFilename(result.prefix)):
      result.verdict = acvDeclaredExecutableOutsidePrefix
      result.detail = "extraExecutable " & extra & " resolves to " &
        resolvedExtra & ", which is not under " & result.prefix
      return

  # The alias, when one is declared: the name a consumer invokes. See
  # ``acvDeclaredAliasMissing`` for why this belongs to conformance rather
  # than to realize's own bookkeeping. A launcher-pair alias is a plain file
  # too (a ``#!/bin/sh`` stub on POSIX), so one existence check covers both
  # the copy and the launcher shapes.
  if arm.executableAlias.len > 0:
    let aliasPath = probe.resolvedPath.parentDir / arm.executableAlias
    if not fileExists(aliasPath):
      result.verdict = acvDeclaredAliasMissing
      result.detail = "declares executableAlias " & arm.executableAlias &
        ", which the realized prefix does not carry beside " &
        arm.executablePath
      return

  result.verdict = acvOk
  result.detail = ""
