## M5 "pin the provider-compile toolchain", rule 3 — what the BOOTSTRAP does
## when the project it was started in pins a different reprobuild.
##
## Reprobuild-specs Distribution-And-Packaging.milestones.org, M5, rule 3:
## "Even when a project pins a different reprobuild, some `repro` has to run
## first. Its only job is to provision the project's pinned reprobuild (and
## toolchain), then hand over to it. The bootstrap never evaluates a recipe it
## is not pinned to."
##
## The resolving launcher (`apps/repro-trampoline`) already does this when it
## is the `repro` on `PATH`. This module is the same decision made by the
## ENGINE, because the engine is what a host has when it has no launcher: the
## native package's `repro`, `build/bin/reprobuild`, a CI image. Without it a
## pinned project is evaluated by whatever reprobuild the invocation happened
## to find, and the pin holds only on hosts that installed the launcher.
##
## PURE. The decision is a function of the pin, the store root, the running
## image and the environment marker; it reads the filesystem only to ask
## whether two paths name the same file and whether a prefix is resident. The
## side effects -- provisioning, holding a root, the exec -- belong to the
## caller (`repro_cli_support/project_pins`), so every branch here is testable
## without spawning anything.
##
## THE FOUR WAYS NOT TO HAND OVER, AND WHY EACH IS SAFE.
##
##   * No pin governs (no project, no reprobuild entry, a bare definition
##     identity). There is nothing to hand over to; the bootstrap IS the
##     reprobuild this project runs, which is what `repro` has always done.
##   * VERSION-EQUAL. The lock's pin is an identity (name + version +
##     platform) and the running image is that version. Handing over would
##     exec a second copy of the same release to do the same work.
##   * THIS IMAGE IS THE PINNED ONE. Compared by FILE IDENTITY
##     (`sameFile`), not spelling, so an 8.3 name, a symlink or a `..` that
##     reaches the prefix's engine is still recognized. This is the case every
##     hand-over lands in: the image the bootstrap exec'd starts, sees the same
##     pin, and must not hand over again.
##   * THE MARKER SAYS A HAND-OVER TO THIS PREFIX ALREADY HAPPENED, and the
##     running image is not it. That is not a case to hand over in again: the
##     exec was redirected (an inherited `REPRO_FULL_CLI`, a wrapper) or a
##     child of the pinned image re-entered through a different `repro`, and
##     handing over again is the first step of a loop. It REFUSES, which is
##     the one outcome that is neither a loop nor evaluating the recipe with
##     the wrong reprobuild.

import std/[os]

import repro_core/cli_images

import ../repro_selfhost

type
  HandOverAction* = enum
    hoaRunHere     ## no hand-over: this image evaluates the project
    hoaHandOver    ## exec the pinned image
    hoaRefuse      ## neither is safe; exit with ``exitCode``

  HandOverDecision* = object
    action*: HandOverAction
    reason*: string
      ## One sentence, for ``REPRO_SELFHOST_DEBUG`` narration and for the
      ## refusal message.
    exitCode*: int
      ## Set for ``hoaRefuse``: ``HandOverExitResolutionFailed`` or
      ## ``HandOverExitRecursion``, the launcher's own codes for the same
      ## two situations.
    prefix*: string
    entryPoint*: string
      ## ``<prefix>/bin/repro``: what a hand-over execs. The thin client of
      ## the PINNED version, exactly as the launcher execs, so a routed build
      ## goes to that version's daemon.
    engine*: string
      ## ``<prefix>/bin/reprobuild``: the pinned engine, named to the child
      ## through ``REPRO_PUBLIC_CLI_PATH``.
    prefixIdHex*: string
    resident*: bool
      ## Whether ``entryPoint`` and ``engine`` both exist. A hand-over to a
      ## non-resident prefix needs provisioning first.

const
  HandOverExitResolutionFailed* = 70
  HandOverExitRecursion* = 72
  PublicCliEnvVar* = "REPRO_PUBLIC_CLI_PATH"
  FullCliEnvVar* = "REPRO_FULL_CLI"
  NimCompilerEnvVar* = "REPRO_NIM_COMPILER"

proc isSameImage*(running, candidate: string): bool =
  ## Do ``running`` and ``candidate`` name the same file?
  if running.len == 0 or candidate.len == 0:
    return false
  if not fileExists(candidate):
    return false
  try:
    sameFile(running, candidate)
  except OSError:
    normalizedPath(absolutePath(running)) ==
      normalizedPath(absolutePath(candidate))

proc decideHandOver*(pin: SelfPin; storeRoot, runningImage, ownVersion,
                     marker: string): HandOverDecision =
  ## What an engine started in ``pin``'s project does. ``marker`` is the
  ## inherited value of ``ResolvedEnvVar`` ("" when unset).
  case pin.state
  of spsTampered:
    return HandOverDecision(action: hoaRefuse, reason: pin.detail,
      exitCode: HandOverExitResolutionFailed)
  of spsNoProject, spsNoPin, spsNotAddressable:
    return HandOverDecision(action: hoaRunHere,
      reason: "no reprobuild pin governs here: " & pin.detail)
  of spsPinned:
    discard

  result.prefix = selfPrefixAbsolutePath(storeRoot, pin)
  result.entryPoint = selfExecutableIn(result.prefix)
  result.engine = result.prefix / "bin" / reprobuildEngineExeName()
  result.prefixIdHex = prefixIdHex(selfPrefixId(pin))
  result.resident = fileExists(result.entryPoint) and fileExists(result.engine)

  if pin.version == ownVersion:
    result.action = hoaRunHere
    result.reason = pin.lockPath & " pins " & SelfPackageName & " " &
      pin.version & ", which is this image's own version; no hand-over"
    return
  if isSameImage(runningImage, result.engine):
    result.action = hoaRunHere
    result.reason = "running as the pinned image " & result.engine &
      " (" & SelfPackageName & " " & pin.version & ")"
    return
  if marker.len > 0 and marker == result.prefixIdHex:
    result.action = hoaRefuse
    result.exitCode = HandOverExitRecursion
    result.reason = "a hand-over to " & SelfPackageName & " " & pin.version &
      " at " & result.prefix & " already happened in this process tree (" &
      ResolvedEnvVar & "=" & marker & "), but the image running now is " &
      runningImage & ", version " & ownVersion & ", not that prefix's " &
      reprobuildEngineExeName() & ". Handing over again would loop, and " &
      "running here would evaluate " & pin.lockPath & "'s recipe with a " &
      "reprobuild it does not pin. Something between the hand-over and " &
      "this process redirected the exec -- check " & FullCliEnvVar & " and " &
      PublicCliEnvVar & ", which must name the pinned engine or be unset."
    return
  result.action = hoaHandOver
  result.reason = pin.lockPath & " pins " & SelfPackageName & " " &
    pin.version & "; this image is " & ownVersion & ", so it hands over to " &
    result.entryPoint

type
  EnvEdit* = object
    name*: string
    value*: string
    remove*: bool

proc handOverEnvironment*(decision: HandOverDecision;
                          providerNimCompiler: string): seq[EnvEdit] =
  ## The ONLY changes a hand-over makes to the environment it passes on.
  ## Everything else is the caller's environment, unchanged.
  ##
  ##   * ``REPRO_SELFHOST_RESOLVED`` -- the marker, the same one the launcher
  ##     sets, holding the prefix id the hand-over targeted.
  ##   * ``REPRO_PUBLIC_CLI_PATH`` -- the PINNED engine. The pinned thin
  ##     client resolves its engine from it and the engine uses it as its own
  ##     self-spawn path; an inherited value naming the bootstrap would send
  ##     the pinned thin client straight back here.
  ##   * ``REPRO_FULL_CLI`` removed, for the same reason: the thin client
  ##     honours it BEFORE ``REPRO_PUBLIC_CLI_PATH``.
  ##   * ``REPRO_NIM_COMPILER`` -- when the lock pins the provider compiler,
  ##     the realized pinned Nim. Rule 3 says the bootstrap provisions the
  ##     pinned reprobuild AND TOOLCHAIN; passing the compiler this way is
  ##     what makes the pin hold for a pinned reprobuild that predates
  ##     compiler pins, since every reprobuild honours this variable.
  result.add(EnvEdit(name: ResolvedEnvVar, value: decision.prefixIdHex))
  result.add(EnvEdit(name: PublicCliEnvVar, value: decision.engine))
  result.add(EnvEdit(name: FullCliEnvVar, remove: true))
  if providerNimCompiler.len > 0:
    result.add(EnvEdit(name: NimCompilerEnvVar, value: providerNimCompiler))

proc applyEnvEdits*(edits: openArray[EnvEdit]) =
  for e in edits:
    if e.remove:
      if existsEnv(e.name):
        delEnv(e.name)
    else:
      putEnv(e.name, e.value)
