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
## WHERE THIS SITS RELATIVE TO THE THIN DAEMON CLIENT. Since the
## thin-client-on-PATH rename there are three claimants on the name ``repro``:
## this launcher (version selection), `apps/repro-client` (daemon dispatch),
## and the engine (`apps/repro`, now installed as ``reprobuild``). They
## compose, in exactly one order:
##
##   PATH/repro (THIS: which reprobuild?)
##     -> <prefix>/bin/repro (thin client: daemon or engine?)
##       -> <prefix>/bin/reprobuild  |  that version's daemon
##
## Version selection is OUTERMOST and that is forced rather than preferred. A
## thin client placed outside this launcher would hand the build to whatever
## daemon happens to be resident — an engine of unknown version — and so would
## silently defeat the pin, which is the same failure ``spsTampered`` below
## refuses to produce ("every version-selection bug this milestone exists to
## prevent looks exactly like a quiet fallback"). Inside it, the prefix's own
## ``bin/repro`` is the thin client for THAT version and its own
## ``bin/reprobuild`` is that version's engine, so the daemon is spawned from
## the pinned image and the pin holds.
##
## ``bin/repro`` staying the prefix's entry point is not a choice either:
## ``selfDeclaredExecutablePath`` folds it into the realization hash, so
## renaming it would re-address every prefix and invalidate every existing
## pin. The pinned entry point is therefore the thin client, and this launcher
## names the engine separately through ``REPRO_PUBLIC_CLI_PATH`` — one
## variable, read by the thin client as the engine to defer to and by the
## engine as its own self-spawn path, so the two cannot derive different
## answers.
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
import repro_core/cli_images

import repro_selfhost

const
  BootstrapEnvVar = "REPRO_BOOTSTRAP_CLI"
    ## Absolute path of the bootstrap reprobuild. Set by the packaging layer
    ## (and by the gate harness) so the launcher never has to guess.
  DebugEnvVar = "REPRO_SELFHOST_DEBUG"
  BootstrapSiblingDir = "reprobuild"
    ## Fallback location, relative to the launcher: `<bin>/../libexec/
    ## reprobuild/repro`. A DIRECTORY rather than a different filename, and the
    ## reason has CHANGED -- read this before simplifying it away.
    ##
    ## IT USED TO BE A NAME CONSTRAINT. `repro` schedules its
    ## interface-extraction and provider-compile edges by self-spawning its own
    ## image with an internal verb, and `internalReproHelperCliPath` once
    ## accepted only an image whose FILENAME was `repro`. A bootstrap installed
    ## as `repro-bootstrap.exe` therefore answered
    ##
    ##   repro build: error: cannot schedule the provider-compile edge for
    ##   <recipe>: no `repro` image to spawn it with. The running image is
    ##   ...(dir)/repro-bootstrap.exe and no public CLI path was supplied.
    ##
    ## -- observed on this host during M5, and the same root cause as N36 (a
    ## wrapped package whose real image is `.repro-wrapped` silently losing its
    ## io-monitor driver).
    ##
    ## THAT CONSTRAINT IS GONE. N36 replaced the filename test with the image's
    ## own DECLARATION (`runThinApp("repro")` as a literal in
    ## `apps/repro/repro.nim`); see `runningImageIsReproCli` and
    ## `libs/repro_cli_support/tests/
    ## t_image_identity_is_declared_not_filename.nim`. An engine image works
    ## under any filename now, which is what made `reprobuild` possible at
    ## all.
    ##
    ## THE DIRECTORY IS STILL RIGHT, for a plainer reason: a bootstrap install
    ## is a PAIR (`repro` the thin client and `reprobuild` beside it, which
    ## is how the thin client's sibling probe finds its engine), this launcher
    ## owns `bin/repro` on `PATH`, and a pair has to be moved as a directory.
    ## Do not "fix" this by renaming the bootstrap file: splitting the pair is
    ## what breaks it.

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
      # The note that used to live here -- "a reprobuild not named `repro`
      # cannot self-spawn its internal verbs, install it under the name
      # `repro`" -- has been DELETED rather than reworded. It stopped being
      # true when N36 made the self-spawn permission come from the image's own
      # declaration instead of its filename (see `BootstrapSiblingDir` above),
      # and a remedy that no longer works is worse than no remedy: it sends
      # whoever hits a provisioning failure to rename a file that was never
      # the cause.
      let why = ""
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
  # NAME THE ENGINE OF THE VERSION WE JUST SELECTED, explicitly.
  #
  # `exe` is the prefix's `bin/repro`, which since the thin-client rename is
  # the THIN DAEMON CLIENT. `REPRO_PUBLIC_CLI_PATH` is read by TWO different
  # programs -- the thin client resolves its engine from it, and the engine
  # uses it as its own self-spawn path for `internal io monitor` /
  # `__repro-extract-interface` / `__repro-compile-provider` -- so it has to
  # name the ENGINE, not the entry point. Pointing it at the thin client would
  # have the engine try to self-spawn a binary that implements none of those
  # verbs.
  #
  # Setting it at all (rather than leaving both to `getAppFilename()`) is the
  # N36 lesson: the engine accepts a self-spawn target it has been TOLD about,
  # and telling it here is what gives the pinned reprobuild a working
  # io-monitor driver.
  #
  # MISSING ENGINE IS A REFUSAL, NOT A FALLBACK.
  #
  # An earlier draft fell back to `exe` (the prefix's `bin/repro`) when the
  # prefix had no `reprobuild` beside it, on the theory that a pre-rename
  # prefix is a supported layout. That is deleted, and the owner's reason is
  # the deciding one: reprobuild is in heavy development, so running an OLD
  # image is typically a MISTAKE rather than a configuration anyone chose. A
  # silent fallback turns a wrong-version run into something nobody can see --
  # the build succeeds, with the wrong engine, and nothing says so. A refusal
  # turns it into a diagnosable error, which is the same trade `spsTampered`
  # above already makes for a tampered pin.
  #
  # WHAT THIS DECIDES ON, since "probe for a file" would be inferring what is
  # already declared. Nothing available here DECLARES the layout, and that is a
  # fact about the data rather than an excuse:
  #
  #   * `SelfPin` carries `state`, `projectRoot`, `lockPath`, `version`,
  #     `platform`, `storeHash`, `integrity`, `detail` -- no layout field. A
  #     bare version string cannot answer "does this prefix ship two images?".
  #   * A version THRESHOLD would have to be invented. The two-image layout is
  #     unreleased, so there is no released version number to compare against;
  #     writing one down now would be an unverified constant of exactly the
  #     kind this launcher already deleted one of.
  #   * The prefix does not describe itself either: `repro self install`
  #     materializes a whole source tree (`materializeViaHardlinkOrCopy`) and
  #     writes no manifest of its contents, and `selfDeclaredExecutablePath`
  #     names only `bin/repro`.
  #
  # So the predicate is NOT "which layout is this?" -- there is only one
  # supported layout, for every version this launcher will hand over to. It is
  # "is the contract satisfied?", and the probe is the anomaly detector for a
  # contract violation rather than a branch between two ways of being right.
  # `repro self install` refuses at install time for the same reason and in the
  # same terms (see `repro_selfhost/install.nim`), so a prefix produced by the
  # normal path CANNOT lack this file -- which is what makes reaching the
  # refusal below evidence of something genuinely wrong rather than of a
  # configuration the reader was expected to have.
  let prefixEngine = prefix / "bin" / reprobuildEngineExeName()
  if not fileExists(prefixEngine):
    fail(ExitResolutionFailed,
      pin.lockPath & " pins " & SelfPackageName & " " & pin.version &
      ", which resolved to " & prefix & ", but that prefix has no " &
      reprobuildEngineExeName() & " beside its bin/" & selfExecutableName() &
      ". bin/" & selfExecutableName() & " is the thin daemon client and it " &
      "cannot build on its own; bin/" & reprobuildEngineExeName() &
      " is the engine it hands every other invocation to. `repro self " &
      "install` refuses to create a prefix without it, so this one predates " &
      "that check or has been modified. To repair it: delete " & prefix &
      " and re-install that version from a tree that has both images, with `" &
      ReproThinClientName & " self install --from=<dir> --version=" &
      pin.version & " --platform=" & pin.platform & "` (--from and --version " &
      "are both required). Or repin " & pin.lockPath &
      " to a version whose prefix carries both images.")
  # `REPRO_PUBLIC_CLI_PATH` is read by TWO different programs -- the thin
  # client resolves its engine from it, and the engine uses it as its own
  # self-spawn path -- so one variable keeps the two from deriving different
  # answers. It names the ENGINE, never `exe`.
  putEnv("REPRO_PUBLIC_CLI_PATH", prefixEngine)
  note("engine " & prefixEngine)
  note("exec " & exe)
  quit(runChild(exe, passthrough))
