## M5 SELF-HOST — the resolving launcher.
##
## This binary is installed on ``PATH`` under the name ``repro``. Every
## invocation does the same three things and nothing else:
##
##   1. walk up from the working directory to the nearest ``repro.lock``;
##   2. read the ``reprobuild`` pin out of it — the ORDINARY dependency pin,
##      the same ``LockedDep`` shape a pinned ``nim`` or ``gcc`` gets — and
##      compute the store prefix that pin addresses;
##   3. exec ``<prefix>/bin/repro`` with the caller's argv unchanged,
##      provisioning the prefix first if it is not resident.
##
## It reads NO file of its own. There is no ``.reprobuild-version``, no
## ``.tool-versions``, no launcher-private section of any config file; delete
## every file in a project except ``repro.lock`` and the answer does not
## change, and edit ``repro.lock``'s pin and it does. That is the whole point
## of the milestone this implements, and it is why the resolution lives in
## ``repro_selfhost`` — a library whose only inputs are the committed lock
## and the store's own naming contract.
##
## WHY THIS IS A SEPARATE BINARY. ``Distribution-And-Packaging.md`` §12 left
## "a new thin binary or a ``repro`` mode" open. It is a separate binary
## because the thing it launches is a ``repro``, and a mode would mean every
## pinned image also carrying the resolver that chose it — a loop to be
## broken by a flag rather than by construction. Thin is measured, not
## claimed: it links ``repro_lock`` plus the store's pure path/hash pair, no
## SQLite, no solver, no engine.
##
## WHAT IT DOES WHEN THERE IS NO PIN. It execs the BOOTSTRAP reprobuild — the
## one the native package or the installer put on the machine — so ``repro``
## outside a pinned project behaves exactly as ``repro`` always did. A pin
## that names a version the store has not got is provisioned through that
## same bootstrap (``repro self provision``), which is the spec's "a
## bootstrap repro builds/fetches other versions into the store".
##
## EXIT CODES OF ITS OWN (every other exit code is the pinned image's):
##   * 70 — resolution failed: the pin is unusable, or provisioning it did.
##   * 71 — no bootstrap reprobuild could be named.
##   * 72 — recursion guard: this launcher was reached from inside a
##          resolved exec, which means a pinned prefix contains a launcher
##          rather than a reprobuild.

import std/[os, osproc, streams, strutils]

# Ambient-execution hatch, and the ONE call in this binary that needs it.
# Naming it is the point: a resolving launcher exists to run a binary it
# was TOLD about by the committed lock, so "a typed execution profile"
# is not available and could not be -- the profile system lives inside
# the reprobuild this launcher has not started yet. `git grep
# uncontrolled` is the audit surface.
import repro_core/ambient_execution

import repro_selfhost

const
  BootstrapEnvVar = "REPRO_BOOTSTRAP_CLI"
    ## Absolute path of the bootstrap reprobuild. Set by the packaging layer
    ## (and by the gate harness) so the launcher never has to guess.
  DebugEnvVar = "REPRO_SELFHOST_DEBUG"
  BootstrapSiblingDir = "reprobuild"
    ## Fallback location, relative to the launcher: `<bin>/../libexec/
    ## reprobuild/repro`. A DIRECTORY rather than a different filename,
    ## because the bootstrap image has to be NAMED `repro` and the launcher
    ## already owns that name on `PATH`.
    ##
    ## Why the name matters, measured rather than assumed. `repro` schedules
    ## its interface-extraction and provider-compile edges by self-spawning
    ## its own image with an internal verb, and
    ## `internalReproHelperCliPath` accepts only an image actually called
    ## `repro` (or an explicitly supplied `REPRO_PUBLIC_CLI_PATH`). A
    ## bootstrap installed as `repro-bootstrap.exe` therefore answers
    ##
    ##   repro build: error: cannot schedule the provider-compile edge for
    ##   <recipe>: no `repro` image to spawn it with. The running image is
    ##   ...(dir)/repro-bootstrap.exe and no public CLI path was supplied.
    ##
    ## -- which was observed on this host during M5, and is the same root
    ## cause as N36 (a wrapped package whose real image is `.repro-wrapped`
    ## silently loses its io-monitor driver). Renaming the bootstrap is not a
    ## workaround for that defect; it is the layout the defect forces, and
    ## naming it here is what stops the next installer from rediscovering it.

  ExitResolutionFailed = 70
  ExitNoBootstrap = 71
  ExitRecursion = 72

proc debugEnabled(): bool =
  let v = getEnv(DebugEnvVar)
  v.len > 0 and v != "0"

proc note(msg: string) =
  if debugEnabled():
    stderr.writeLine("repro(trampoline): " & msg)

proc fail(code: int; msg: string) {.noreturn.} =
  stderr.writeLine("repro: " & msg)
  quit(code)

proc storeRoot(): string =
  ## The store this launcher resolves against; `repro_selfhost` owns the
  ## resolution and a test pins it against the store's own.
  try:
    selfStoreRoot()
  except StoreRootError as err:
    fail(ExitResolutionFailed, err.msg)

proc bootstrapCli(): string =
  ## The bootstrap reprobuild, or "" when none can be named.
  let configured = getEnv(BootstrapEnvVar)
  if configured.len > 0:
    if fileExists(configured):
      return configured
    fail(ExitNoBootstrap,
      BootstrapEnvVar & " names " & configured & ", which does not exist")
  let launcherDir = parentDir(getAppFilename())
  let sibling = parentDir(launcherDir) / "libexec" / BootstrapSiblingDir /
    addFileExt("repro", ExeExt)
  if fileExists(sibling):
    return sibling
  ""

proc runChild(exe: string; args: seq[string]): int =
  ## Run ``exe`` with ``args``, attached to this process's own streams, and
  ## return its exit code.
  ##
  ## Nim has no portable ``execv``, and on Windows there is no ``execv`` at
  ## all — ``_execv`` creates a NEW process and returns, which breaks every
  ## caller that waits on the launcher's pid (a shell job, a CI step, a
  ## parent build). So the launcher stays in the picture as a waiter on both
  ## platforms rather than being a process on one and a ghost on the other.
  ## The cost is one sleeping process per invocation; the benefit is that
  ## ``$?``, job control and process-tree kills all mean what they look like
  ## they mean.
  var p = uncontrolledStartProcess(exe, args = args,
    options = {poParentStreams})
  try:
    result = p.waitForExit()
  finally:
    p.close()

proc runChildQuiet(exe: string; args: seq[string]): tuple[code: int;
    output: string] =
  ## Run `exe` with its output CAPTURED rather than inherited.
  ##
  ## The launcher's stdout belongs to the command the user typed. A
  ## bookkeeping child that shares it corrupts every caller that reads the
  ## output -- which is not hypothetical: the first run of the M5 gate had
  ## `repro --version` answer with the pin-root attachment line, because the
  ## `self hold` child was started with `poParentStreams` like the exec'd
  ## image is. Anything the launcher runs FOR ITSELF goes through here;
  ## only the image it finally hands over to gets the real streams.
  var p = uncontrolledStartProcess(exe, args = args, options = {
    poStdErrToStdOut})
  try:
    # Read before waiting: a child that fills the pipe while nobody drains
    # it blocks forever, and "forever" in a launcher is the whole command.
    #
    # `readData` in a loop rather than `readAll`, and that is not style.
    # Measured on this host: `p.outputStream.readAll()` returned ONE BYTE of
    # a four-line diagnostic, so the launcher forwarded `r` where it meant
    # to forward the command that would install the missing version. A
    # truncated diagnostic is worse than none, because it looks like the
    # whole message.
    var chunk = newString(4096)
    while true:
      let n = p.outputStream.readData(addr chunk[0], chunk.len)
      if n <= 0:
        break
      result.output.add(chunk[0 ..< n])
    result.code = p.waitForExit()
  finally:
    p.close()

proc provision(bootstrap, version, platform, root: string): bool =
  ## Ask the bootstrap reprobuild to put ``version`` in the store.
  note("provisioning " & SelfPackageName & " " & version & " via " & bootstrap)
  let child = runChildQuiet(bootstrap, @["self", "provision",
    "--version=" & version, "--platform=" & platform,
    "--store-root=" & root])
  if child.code != 0:
    # Provisioning is the one bookkeeping call whose output the user needs
    # when it goes wrong: it names the version, the store and the command
    # that would install it. Forwarded to stderr so it never lands on the
    # stdout the real command owns.
    stderr.write(child.output)
  child.code == 0

when isMainModule:
  let passthrough = commandLineParams()

  if getEnv(ResolvedEnvVar).len > 0:
    fail(ExitRecursion,
      "the resolving launcher was reached from inside an already-resolved " &
      "exec (" & ResolvedEnvVar & "=" & getEnv(ResolvedEnvVar) & "). The " &
      "store prefix a pin resolved to contains a launcher rather than a " &
      "reprobuild; reinstall that version with `repro self install`.")

  let cwd =
    try: getCurrentDir()
    except CatchableError: ""
  let pin = selfPinFrom(cwd)
  note("project=" & pin.projectRoot & " state=" & $pin.state &
    " version=" & pin.version)

  if pin.state == spsTampered:
    # NOT a fallback case, and the distinction is the whole reason the state
    # exists. `spsNoPin` / `spsNotAddressable` mean "this directory is not
    # governed by a pin", and the honest answer to that is the bootstrap --
    # it is what `repro` did before this milestone and what the reprobuild
    # repository itself still gets, since its own lock records the bare
    # definition identity. `spsTampered` means the opposite: a pin IS
    # governing here and its coordinate does not match its content. Running
    # SOMETHING in that situation is the one outcome that must not happen,
    # because every version-selection bug this milestone exists to prevent
    # looks exactly like a quiet fallback.
    fail(ExitResolutionFailed, pin.detail)

  if pin.state != spsPinned:
    # No pin governs this directory: behave exactly like the bootstrap.
    let bootstrap = bootstrapCli()
    if bootstrap.len == 0:
      fail(ExitNoBootstrap,
        "no reprobuild version is pinned here (" & pin.detail &
        ") and no bootstrap reprobuild could be named: set " &
        BootstrapEnvVar & " or install one at " &
        (parentDir(parentDir(getAppFilename())) / "libexec" /
         BootstrapSiblingDir / addFileExt("repro", ExeExt)))
    note("unpinned; delegating to bootstrap " & bootstrap)
    quit(runChild(bootstrap, passthrough))

  let root = storeRoot()
  let prefix = selfPrefixAbsolutePath(root, pin)
  var exe = selfExecutableIn(prefix)
  if not fileExists(exe):
    let bootstrap = bootstrapCli()
    if bootstrap.len == 0:
      fail(ExitNoBootstrap,
        pin.lockPath & " pins " & SelfPackageName & " " & pin.version &
        ", which is not in the store at " & prefix &
        ", and no bootstrap reprobuild could be named to install it: set " &
        BootstrapEnvVar & " or install one at " &
        (parentDir(parentDir(getAppFilename())) / "libexec" /
         BootstrapSiblingDir / addFileExt("repro", ExeExt)))
    if not provision(bootstrap, pin.version, pin.platform, root):
      var why = ""
      if extractFilename(bootstrap) != addFileExt("repro", ExeExt):
        why = " NOTE: the bootstrap at " & bootstrap & " is not named " &
          addFileExt("repro", ExeExt) & ", and a reprobuild that is not " &
          "named `repro` cannot self-spawn its internal verbs, so it " &
          "cannot schedule an interface-extraction or provider-compile " &
          "edge. Install the bootstrap under the name `repro` in a " &
          "directory of its own, or set REPRO_PUBLIC_CLI_PATH."
      fail(ExitResolutionFailed,
        pin.lockPath & " pins " & SelfPackageName & " " & pin.version &
        " (store address " & pin.storeHash & ") and it could not be " &
        "provisioned into " & root & "." & why)
    if not fileExists(exe):
      fail(ExitResolutionFailed,
        "provisioning " & SelfPackageName & " " & pin.version &
        " reported success but left no " & exe)

  # Hold the version for as long as the project pins it. Delegated to the
  # bootstrap because attaching a root is a store-index write and this
  # binary does not open the index. Best effort: a failure here costs a gc
  # root, not a launch, and saying so is better than refusing to run.
  block holdRoot:
    let bootstrap = bootstrapCli()
    if bootstrap.len == 0:
      break holdRoot
    let held = runChildQuiet(bootstrap, @["self", "hold",
      "--project=" & pin.projectRoot, "--store-root=" & root])
    if held.code != 0:
      note("could not attach the pin root for " & pin.projectRoot &
        " (exit " & $held.code & "): " & held.output.strip())
    else:
      note("held " & held.output.strip())

  putEnv(ResolvedEnvVar, prefixIdHex(selfPrefixId(pin)))
  # N36 — an image spawned with an internal verb must be named `repro`, and
  # the engine only accepts one it has been told about. The resolved prefix's
  # image IS named `repro`, so naming it here gives the pinned reprobuild a
  # working io-monitor driver instead of leaving it to `getAppFilename()`.
  putEnv("REPRO_PUBLIC_CLI_PATH", exe)
  note("exec " & exe)
  quit(runChild(exe, passthrough))
