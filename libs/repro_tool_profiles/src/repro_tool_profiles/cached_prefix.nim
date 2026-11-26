## Cached application-bundle prefixes: verified before reuse, repaired when
## they no longer verify, sealed read-only and kept out of Launch Services.
##
## A store prefix that holds a macOS application is written once, by the
## realizer, after the bundle passed the trust checks. It is then reused by
## every later apply. Between those two moments three things can happen to it
## that the realizer did not intend:
##
## * an interrupted or cache-substituted realization left no
##   ``.repro-receipt``, so the prefix cannot be told from a half-published
##   one;
## * the application's own updater (Sparkle, Squirrel) rewrote the copy in
##   place, because a prefix is an ordinary writable directory, so the bundle
##   no longer is the one the record pins; and
## * Launch Services registered the prefix's bundle, so "Open With", the Dock
##   and URL handlers can start the cached copy -- which then updates itself.
##
## This module is the policy for all three
## (Store-And-Installation-Layout.md § macOS Application Bundles, "Cached
## prefixes"): the trust checks run again on the cached bytes whenever the
## prefix is reused; a prefix that passes gets its receipt and is sealed; one
## that fails is discarded and realized again, unless a process runs from it.
import std/[os, strutils]

from repro_core/paths import extendedPath
import repro_local_store
import repro_home_resources/drivers/app_bundle
import ./archive_inputs
import ./archive_steps

const
  LsRegisterPath* =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/" &
    "LaunchServices.framework/Support/lsregister"
    ## Launch Services' command-line registration tool. ``-u <bundle>``
    ## removes the registration of the bundle at a path.

type
  CachedBundleVerdict* = object
    ## What the trust checks said about a cached prefix.
    verified*: bool
    check*: string
      ## The check that failed (``EAppBundleRefused.check``): ``info-plist``,
      ## ``bundle-id``, ``version``, ``signature``, ``team-id``,
      ## ``developer-id`` or ``notarization``. Empty when verified.
    detail*: string
      ## The refusal's message, for the diagnostic.

  EPrefixRepairDeferred* = object of CatchableError
    ## A cached prefix failed verification but a process runs from it, so it
    ## cannot be replaced under that process. Reported, not fatal: the
    ## caller keeps what it had and the next apply repairs the prefix once
    ## the application has quit.
    prefix*: string
    check*: string
    pids*: seq[int]

proc cachedBundleVerdict*(resolution: ArchiveRealization; prefix: string;
                          appTrust: AppTrustPolicy = {}): CachedBundleVerdict =
  ## Trust checks 1 to 5 against the cached bytes of ``prefix``, with the
  ## same expectation (bundle id, version, team) the record declares. A
  ## prefix whose bundle is missing or unreadable fails ``info-plist``.
  try:
    verifyArchiveApplication(resolution, prefix, appTrust)
    result.verified = true
  except EAppBundleRefused as err:
    result.check = err.check
    result.detail = err.msg

proc processesRunningFromPrefix*(prefix: string): seq[int] =
  ## The ids of the processes whose executable lies inside ``prefix``.
  processesRunningFrom(prefix)

proc discardCachedPrefix*(prefix: string; verdict: CachedBundleVerdict) =
  ## Remove a cached prefix that failed verification so it can be realized
  ## again from the pinned archive or the shared cache. Raises
  ## ``EPrefixRepairDeferred`` instead when a process runs from the prefix
  ## (libproc, as for placed bundles): the files of a running application are
  ## never removed under it.
  let pids = processesRunningFromPrefix(prefix)
  if pids.len > 0:
    var e = newException(EPrefixRepairDeferred, "the cached prefix " &
      prefix & " failed the " & verdict.check & " check (" &
      verdict.detail & "), and is in use by running process " &
      pids.join(", ") & "; it is repaired by the next apply after the " &
      "application quits")
    e.prefix = prefix
    e.check = verdict.check
    e.pids = pids
    raise e
  removeStoreTree(prefix)

proc sealCachedBundle*(prefix: string; resolution: ArchiveRealization) =
  ## Clear every write bit under the application's item in ``prefix`` (the
  ## bundle, or the folder an installer application produced), so an updater
  ## that starts from the cached copy cannot rewrite it. The prefix directory
  ## itself stays writable: the receipt is sealed into it, and a discard
  ## removes it (``removeStoreTree`` restores directory write bits first).
  ## Placement copies the bundle and makes the copy writable again, so a
  ## placed bundle keeps updating itself (§ "Vendor updates").
  let item = prefix / appPlacedItem(resolution).item
  if dirExists(extendedPath(item)) and not symlinkExists(extendedPath(item)):
    stripTreeWriteBits(item)

proc resolvedPath(path: string): string =
  ## Launch Services records the resolved path (``/private/tmp/x`` for
  ## ``/tmp/x``), so registration and unregistration name that one.
  try: expandFilename(path)
  except OSError: path

proc nestedBundles(dir: string): seq[string] =
  ## Every ``*.app`` directory below ``dir`` (helpers, plug-ins, updaters),
  ## not following symbolic links: Launch Services registers those as well.
  for kind, path in walkDir(dir, relative = false):
    if kind == pcDir:
      if path.endsWith(".app"):
        result.add(path)
      result.add(nestedBundles(path))

proc keepOutOfLaunchServices*(prefix: string; resolution: ArchiveRealization;
                              nested = true; lsregister = LsRegisterPath) =
  ## Unregister the cached bundle -- and, with ``nested``, every bundle inside
  ## it -- from Launch Services, so "Open With", the Dock and URL handlers
  ## cannot resolve to the cache. Idempotent and best-effort: an
  ## unregistration that fails leaves the prefix read-only and verified, which
  ## already stops it from updating itself. The top-level bundle is
  ## unregistered every time a prefix is reused (one 20 ms call); the nested
  ## ones only when the prefix is sealed, because walking a bundle for them
  ## is not free and nothing opens a helper by itself.
  if not fileExists(lsregister):
    return
  let item = resolvedPath(prefix / appPlacedItem(resolution).item)
  if not (dirExists(extendedPath(item)) or fileExists(extendedPath(item))):
    return
  discard runSystemTool(lsregister, ["-u", item])
  if nested and dirExists(extendedPath(item)):
    for inner in nestedBundles(item):
      discard runSystemTool(lsregister, ["-u", inner])

proc isCachedBundleSealed*(prefix: string; resolution: ArchiveRealization):
    bool =
  ## Whether the application item of ``prefix`` has had its write bits
  ## cleared. Looks at the item's own directory, which ``sealCachedBundle``
  ## clears last.
  let item = prefix / appPlacedItem(resolution).item
  if not dirExists(extendedPath(item)):
    return false
  fpUserWrite notin getFilePermissions(item)

proc settleVerifiedPrefix*(prefix: string; resolution: ArchiveRealization) =
  ## What a prefix that passed the trust checks gets, every time it is
  ## reused: sealed read-only when it is not yet (a prefix an older engine
  ## wrote is writable), and out of Launch Services.
  var sealed = isCachedBundleSealed(prefix, resolution)
  if not sealed:
    # Best effort: a prefix that verified is usable whether or not every
    # chmod succeeded (a file owned by another user, say).
    try:
      sealCachedBundle(prefix, resolution)
    except OSError as err:
      stderr.writeLine("repro: could not make " & prefix &
        " read-only: " & err.msg)
      sealed = true # do not walk the bundle again for the nested bundles
  keepOutOfLaunchServices(prefix, resolution, nested = not sealed)

proc cachedBundleRegisteredWithLaunchServices*(bundlePath: string;
    lsregister = LsRegisterPath): bool =
  ## Whether Launch Services has a registration whose path is exactly
  ## ``bundlePath``. Reads the whole registration database
  ## (``lsregister -dump``), so it is a test and diagnostic aid, not a hot
  ## path.
  if not fileExists(lsregister):
    return false
  let wanted = resolvedPath(bundlePath)
  let dump = runSystemTool(lsregister, ["-dump"])
  for line in dump.output.splitLines:
    let stripped = line.strip
    # ``path:   /x/y/Name.app (0x4dac)`` -- the number is the registration id.
    if stripped.startsWith("path:") and
        stripped.contains(" " & wanted & " (0x"):
      return true
