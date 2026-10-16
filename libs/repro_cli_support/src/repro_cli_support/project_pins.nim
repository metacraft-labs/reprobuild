## M5 "pin the provider-compile toolchain", rules 1 and 3, on the ENGINE's
## side: what a reprobuild started inside a project does with the pins that
## project's committed ``repro.lock`` makes.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5:
##
##   1. With pins. A project's lock may pin both the reprobuild version and
##      the Nim compiler used to build its provider. Both are ordinary locked
##      packages, realized into the store like any other.
##   3. The bootstrap is always required, and its job is narrow. [...] Its
##      only job is to provision the project's pinned reprobuild (and
##      toolchain), then hand over to it. The bootstrap never evaluates a
##      recipe it is not pinned to.
##
## ``applyProjectPinsAtEntry`` runs from ``runThinApp`` BEFORE any dispatch,
## so the environment it hands over is the one the caller gave and no verb
## has read the recipe yet. In order:
##
##   * a tampered pin (either package) refuses, exit 70 -- the launcher's
##     rule, for the launcher's reason;
##   * the reprobuild pin is decided by ``repro_selfhost/handover``: run here
##     (no pin, version-equal, or this image IS the pinned one), refuse (the
##     loop guard), or hand over. A hand-over to a version the store does not
##     hold refuses, exit 70, naming ``repro self install``;
##   * a pinned provider Nim is realized into the store (resident prefix, or
##     the official archive the lock pins by URL and SHA-256, built from
##     source where that archive is the source one) and held by a pin root;
##   * a hand-over execs the pinned prefix's ``bin/repro`` with the caller's
##     argv unchanged and the environment edits ``handOverEnvironment``
##     documents (the compiler among them);
##   * when this image runs the project itself and the provider Nim is
##     pinned, ``REPRO_NIM_COMPILER`` is published so the provider compile
##     uses it.
##
## WHICH PROJECT. The one enclosing the WORKING DIRECTORY, exactly as the
## launcher decides it. A ``repro build <path>`` naming a project elsewhere
## is decided by the working directory's lock too; resolving the target path
## here would mean duplicating ``parseBuildTarget`` ahead of dispatch.

import std/[os, osproc, strutils]
when not defined(windows):
  import std/posix

import repro_core
import repro_core/ambient_execution
import repro_elevation/broker
import repro_local_store
import repro_lock
import repro_selfhost
import repro_selfhost/handover
import repro_selfhost/install as selfinstall
import repro_tool_profiles

export handover

const
  SelfHostDebugEnvVar = "REPRO_SELFHOST_DEBUG"
  ExitExecFailed = 127

proc selfHostDebug(): bool =
  let v = getEnv(SelfHostDebugEnvVar)
  v.len > 0 and v != "0"

proc note(msg: string) =
  ## ``REPRO_SELFHOST_DEBUG=1`` narration, on stderr, prefixed with the
  ## running version so a transcript says WHICH reprobuild decided.
  if selfHostDebug():
    try:
      stderr.writeLine("repro(" & versionString() & "): " & msg)
      stderr.flushFile()
    except IOError:
      discard

proc bootstrapNimVersion*(): string =
  ## The Nim version the running reprobuild can fetch by itself: the version
  ## component of ``bootstrapNimToolUse``'s package selector (``nim@2.2.10``),
  ## or "" when that route names no version (the Nix route on Linux, whose
  ## version is whatever the pinned nixpkgs carries).
  let selector = bootstrapNimToolUse().packageSelector
  let at = selector.rfind('@')
  if at > 0 and at + 1 < selector.len: selector[at + 1 .. ^1] else: ""

type ProviderNimPinError* = object of CatchableError

proc realizePinnedProviderNim*(storeRoot: string; pin: SelfPin): string =
  ## Put the Nim ``pin`` names into the store and return its executable.
  ##
  ## Resident: arithmetic and one ``fileExists``, like the reprobuild pin.
  ## Not resident, in order:
  ##
  ##   1. The archive the LOCK pins (``pin.archive``: URL + SHA-256, written
  ##      by ``repro lock refresh`` for the lock's platform). Realized through
  ##      the tool store's provisioning edges (``provisionPinnedNim``): a
  ##      binary archive is downloaded and verified against the pinned digest;
  ##      a source archive is verified the same way and then built with the
  ##      bootstrap C compiler. Any released Nim version, on every host.
  ##   2. A lock written before archive pins existed carries none. Its pin is
  ##      still realizable when it names the bootstrap's own Nim
  ##      (``bootstrapNimToolUse``), whose digest this reprobuild carries.
  ##
  ## The realized distribution is then installed at the pin's own prefix
  ## (hardlinked, so no second copy of the bytes), which is what makes the
  ## next resolution arithmetic again and lets ``repro store gc`` see it.
  ##
  ## Every other case, and every failure, RAISES ``ProviderNimPinError``
  ## naming what was being provisioned, from where, the failure and the
  ## remedy. Falling back to the bootstrap's default Nim would compile the
  ## provider with a compiler the lock does not name, which is the failure
  ## the pin exists to rule out.
  let pkg = providerNimPin()
  let prefix = selfPrefixAbsolutePath(storeRoot, pin)
  let exe = pinnedExecutableIn(pkg, prefix)
  if fileExists(exe):
    return exe
  let installCmd = "repro self install --package=" & pkg.name &
    " --from=<nim-distribution-dir> --version=" & pin.version &
    " --platform=" & pin.platform & " --store-root=" & storeRoot
  let host = currentPlatformId()
  if pin.platform != host:
    raise newException(ProviderNimPinError,
      pin.lockPath & " pins the provider compiler " & pkg.name & " " &
      pin.version & " for platform \"" & pin.platform & "\", which is not " &
      "in the store at " & prefix & ", and this host is \"" & host &
      "\", so the archive the lock pins is not one this host can run. " &
      "Re-lock on this platform (`repro lock refresh`), or install that " &
      "distribution: " & installCmd)
  let toolStore = storeRoot / "tool-store"
  var tree = ""
  if pin.archive.isPinned:
    note("realizing the pinned provider compiler " & pkg.name & " " &
      pin.version & " from " & pin.archive.url & " (" & pin.archive.build &
      ", sha256 " & pin.archive.sha256 & ")")
    try:
      tree = provisionPinnedNim(toolStore, pin.version, pin.archive.url,
        pin.archive.sha256, pin.archive.archiveType, pin.archive.build).tree
    except CatchableError as err:
      raise newException(ProviderNimPinError,
        "could not provision the provider compiler " & pkg.name & " " &
        pin.version & " that " & pin.lockPath & " pins" &
        "\n  archive: " & pin.archive.url & " (" & pin.archive.build &
        ", sha256 " & pin.archive.sha256 & ", as the lock records it)" &
        "\n  tool store: " & toolStore &
        "\n  failure: " & err.msg.strip().replace("\n", "\n    ") &
        "\n  remedy: if the archive's digest no longer matches, the lock " &
        "and upstream disagree; re-run `repro lock refresh` and review the " &
        "new digest before committing it. To provide the compiler by hand " &
        "instead: " & installCmd)
  else:
    let routeVersion = bootstrapNimVersion()
    let useDef = bootstrapNimToolUse()
    if routeVersion != pin.version or useDef.tarballProvisioning.len == 0:
      raise newException(ProviderNimPinError,
        pin.lockPath & " pins the provider compiler " & pkg.name & " " &
        pin.version & ", which is not in the store at " & prefix & ", and " &
        "the lock records no archive for it (it was written before " &
        "`repro lock refresh` recorded one). Re-run `repro lock refresh` " &
        "to pin the official " & pkg.name & " " & pin.version & " archive " &
        "for " & pin.platform & ", or install it from a Nim distribution " &
        "directory: " & installCmd)
    note("realizing the pinned provider compiler " & pkg.name & " " &
      pin.version & " from this reprobuild's own pin, " &
      useDef.tarballProvisioning[0].url)
    try:
      let profile = resolveTarballTool(useDef, toolStore)
      bumpWindowsNimStack(profile.resolvedExecutablePath)
      tree = profile.selectedStorePath
    except CatchableError as err:
      raise newException(ProviderNimPinError,
        "could not realize the pinned provider compiler " & pkg.name & " " &
        pin.version & " (" & useDef.tarballProvisioning[0].url & ", sha256 " &
        useDef.tarballProvisioning[0].sha256 & ") into the tool store at " &
        toolStore & ": " & err.msg & ". Or install it from a Nim " &
        "distribution directory: " & installCmd)
  let installed =
    try:
      selfinstall.installPinnedImage(pkg, storeRoot, pin.version,
        pin.platform, tree)
    except CatchableError as err:
      raise newException(ProviderNimPinError,
        "the provider compiler " & pkg.name & " " & pin.version &
        " was realized at " & tree & " but could not be installed at " &
        prefix & ": " & err.msg)
  if not fileExists(installed.executablePath):
    raise newException(ProviderNimPinError,
      "installing the pinned provider compiler " & pkg.name & " " &
      pin.version & " reported success but left no " &
      installed.executablePath)
  installed.executablePath

proc holdPin(pkg: PinnedPackage; storeRoot: string; pin: SelfPin) =
  ## Best effort: a failure costs a gc root, not the invocation.
  try:
    if selfinstall.attachPinRoot(pkg, storeRoot, pin.projectRoot,
        selfPrefixId(pin)):
      note("held " & pinRootIdFor(pkg, pin.projectRoot) & " -> " &
        prefixIdHex(selfPrefixId(pin)))
  except CatchableError as err:
    note("could not attach the " & pkg.name & " pin root for " &
      pin.projectRoot & ": " & err.msg)

proc publishPinnedProviderNim*(nimExe: string) =
  ## Make ``nimExe`` the provider compiler for this process and its
  ## children. The pin WINS over an inherited ``REPRO_NIM_COMPILER``: the
  ## lock is the project's committed statement of which compiler reads its
  ## recipe, and an ambient variable that silently outranked it would be the
  ## "whatever compiler the invocation finds" the pin replaces. Overriding a
  ## DIFFERENT explicit value is said out loud, once.
  let existing = getEnv(NimCompilerEnvVar)
  if existing.len > 0 and existing != nimExe:
    try:
      if not sameFile(existing, nimExe):
        stderr.writeLine("repro: warning: " & NimCompilerEnvVar & "=" &
          existing & " is overridden by the project's pinned provider " &
          "compiler " & nimExe)
    except OSError:
      stderr.writeLine("repro: warning: " & NimCompilerEnvVar & "=" &
        existing & " is overridden by the project's pinned provider " &
        "compiler " & nimExe)
  putEnv(NimCompilerEnvVar, nimExe)

proc exemptFromPins(args: openArray[string]): bool =
  ## Verbs the bootstrap answers for ITSELF, in any project:
  ##
  ##   * ``self ...`` is the provisioning surface. The launcher calls
  ##     ``<bootstrap> self provision`` / ``self hold`` from inside the pinned
  ##     project; handing those over would ask the unprovisioned version to
  ##     provision itself.
  ##   * ``internal ...`` / ``__repro-*`` are self-spawns of an image that
  ##     has already decided; they inherit its decision (and its
  ##     ``REPRO_NIM_COMPILER``) and may run in any directory.
  ##   * the privileged broker is spawned by an elevation request, not by a
  ##     user in a project.
  if args.len == 0:
    return false
  let verb = args[0]
  verb == "self" or verb == "internal" or verb.startsWith("__") or
    verb == BrokerModeFlag

proc needsProviderToolchain(args: openArray[string]): bool =
  ## Whether the invocation may compile a provider, so a non-resident pinned
  ## compiler is worth realizing now. ``--version`` and help never do.
  if args.len == 0:
    return false
  args[0] notin ["--version", "-V", "help", "--help", "-h"]

proc execHandOver(entryPoint: string; args: seq[string]): int =
  ## Replace this process with the pinned entry point (POSIX ``execv``), or
  ## spawn it attached to this process's streams and wait (Windows, which has
  ## no ``execv``: the C runtime's ``_execv`` returns immediately and orphans
  ## the child, so every waiting caller would see a premature exit 0).
  stdout.flushFile()
  stderr.flushFile()
  when defined(windows):
    try:
      var p = uncontrolledStartProcess(entryPoint, args = args,
        options = {poParentStreams})
      try:
        result = p.waitForExit()
      finally:
        p.close()
    except CatchableError as err:
      stderr.writeLine("repro: cannot start the pinned reprobuild " &
        entryPoint & ": " & err.msg)
      result = ExitExecFailed
  else:
    var argv = @[entryPoint]
    argv.add(args)
    var cargs = allocCStringArray(argv)
    discard execv(cstring(entryPoint), cargs)
    deallocCStringArray(cargs)
    stderr.writeLine("repro: cannot exec the pinned reprobuild " &
      entryPoint & ": " & $strerror(errno))
    result = ExitExecFailed

type PinEntryOutcome* = object
  handled*: bool
    ## True when the invocation is finished (handed over or refused) and
    ## ``exitCode`` is its result; false when this image runs it.
  exitCode*: int

proc refuse(code: int; msg: string): PinEntryOutcome =
  stderr.writeLine("repro: " & msg)
  PinEntryOutcome(handled: true, exitCode: code)

proc applyProjectPinsAtEntry*(args: seq[string]): PinEntryOutcome =
  ## Rules 1 and 3 at the engine's entry. See the module header.
  if exemptFromPins(args):
    return
  let cwd =
    try: getCurrentDir()
    except OSError: ""
  let projectRoot = findProjectRoot(cwd)
  if projectRoot.len == 0:
    return
  let pins = projectPinsFor(projectRoot)
  if pins.reprobuild.state notin {spsPinned, spsTampered} and
      pins.providerNim.state notin {spsPinned, spsTampered}:
    return
  note("project=" & projectRoot & " reprobuild=" & $pins.reprobuild.state &
    " " & pins.reprobuild.version & " nim=" & $pins.providerNim.state & " " &
    pins.providerNim.version)
  if pins.providerNim.state == spsTampered:
    return refuse(HandOverExitResolutionFailed, pins.providerNim.detail)
  let storeRoot =
    try: resolveStoreRoot()
    except CatchableError as err:
      return refuse(HandOverExitResolutionFailed,
        "cannot resolve the store the project's pins live in: " & err.msg)

  let decision = decideHandOver(pins.reprobuild, storeRoot,
    getAppFilename(), versionString(), getEnv(ResolvedEnvVar))
  note(decision.reason)
  if decision.action == hoaRefuse:
    return refuse(decision.exitCode, decision.reason)

  let pin = pins.reprobuild
  if decision.action == hoaHandOver and not decision.resident:
    # The bootstrap's provisioning surface, run in-process. Its only local
    # route is an image tree someone offers; there is no remote substituter
    # into the prefix store yet (see `repro self provision`), so a pinned
    # version that is not resident is a refusal naming the install command.
    # Never a fallback to running the recipe here.
    return refuse(HandOverExitResolutionFailed,
      pin.lockPath & " pins " & SelfPackageName & " " & pin.version &
      " (store address " & pin.storeHash & "), which is not in the store " &
      "at " & decision.prefix & ". This reprobuild (" & versionString() &
      ") does not evaluate a recipe it is not pinned to. Install the pinned " &
      "version from a built tree holding bin/repro and bin/reprobuild: " &
      "repro self install --from=<dir> --version=" & pin.version &
      " --platform=" & pin.platform & " --store-root=" & storeRoot &
      ". To move the pin instead, change the recipe's uses: constraint, " &
      "delete the reprobuild entries from repro.lock and run `repro lock " &
      "refresh`.")
  # Then the toolchain: rule 3 has the bootstrap provision the pinned
  # reprobuild AND its toolchain before handing over, and the compiler is
  # the half every reprobuild honours through the environment. After the
  # residency refusal above, so a hand-over that cannot happen does not
  # first download a compiler.
  var nimExe = ""
  if pins.providerNim.state == spsPinned and needsProviderToolchain(args):
    try:
      nimExe = realizePinnedProviderNim(storeRoot, pins.providerNim)
    except CatchableError as err:
      return refuse(HandOverExitResolutionFailed, err.msg)
    holdPin(providerNimPin(), storeRoot, pins.providerNim)
    note("provider compiler " & nimExe)

  if decision.action == hoaRunHere:
    if nimExe.len > 0:
      publishPinnedProviderNim(nimExe)
    return

  # hoaHandOver.
  holdPin(reprobuildPin(), storeRoot, pin)
  applyEnvEdits(handOverEnvironment(decision, nimExe))
  note("exec " & decision.entryPoint & " (engine " & decision.engine & ")")
  PinEntryOutcome(handled: true,
    exitCode: execHandOver(decision.entryPoint, args))

type DaemonPinVerdict* = object
  decline*: bool
    ## The daemon must not host this build: the project pins a reprobuild
    ## this daemon is not. The client falls back to its engine, which hands
    ## over.
  message*: string
  providerNim*: string
    ## The pinned provider compiler to publish for the request, or "".

proc daemonPinVerdict*(workingDir: string): DaemonPinVerdict =
  ## Rule 3 for a DAEMON-HOSTED build. The thin client routes a quiet
  ## non-terminal ``repro build`` to whatever daemon is running without
  ## reading any lock (it links no lock reader, by design), so the daemon is
  ## the first reprobuild that can see the pin -- and it is a bootstrap like
  ## any other. It declines rather than evaluating a recipe it is not pinned
  ## to; the decline is ``unsupported`` with fallback allowed, so the client
  ## execs its engine and the engine's entry hands over.
  let projectRoot = findProjectRoot(workingDir)
  if projectRoot.len == 0:
    return
  let pins = projectPinsFor(projectRoot)
  if pins.reprobuild.state notin {spsPinned, spsTampered} and
      pins.providerNim.state notin {spsPinned, spsTampered}:
    return
  if pins.reprobuild.state == spsTampered or
      pins.providerNim.state == spsTampered:
    return DaemonPinVerdict(decline: true, message:
      "the project's committed lock has a tampered pin; the engine reports it")
  let storeRoot =
    try: resolveStoreRoot()
    except CatchableError as err:
      return DaemonPinVerdict(decline: true, message:
        "cannot resolve the store the project's pins live in: " & err.msg)
  let decision = decideHandOver(pins.reprobuild, storeRoot, getAppFilename(),
    versionString(), "")
  if decision.action != hoaRunHere:
    return DaemonPinVerdict(decline: true, message:
      "the project pins " & SelfPackageName & " " & pins.reprobuild.version &
      " and this daemon is " & versionString() &
      "; the build is handed to the pinned reprobuild")
  if pins.providerNim.state == spsPinned:
    try:
      result.providerNim = realizePinnedProviderNim(storeRoot,
        pins.providerNim)
    except CatchableError as err:
      return DaemonPinVerdict(decline: true, message: err.msg)
