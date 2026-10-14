## `macos.appBundle` driver — a macOS application bundle placed in an
## Applications directory (GM4c of the Gradual-Nix-To-Reprobuild-Migration
## plan; Store-And-Installation-Layout.md §"macOS Application Bundles").
##
## A realized app bundle lives in the store, verified, read-only. Activation
## COPIES it (``ditto --clone``: an APFS clone when the store and the
## Applications directory share a volume) to ``<Applications>/<Name>.app``;
## the spec records why a copy and not a symlink. This module owns the three
## operations that touch a bundle, and nothing else:
##
## * **trust verification** (``verifyAppBundle``) — the bundle's
##   ``Info.plist`` identifier and version, its code signature
##   (``codesign --verify --deep --strict``), its signing team checked
##   against the team the contribution declares, proven by an Apple-anchored
##   Developer ID chain (a designated-requirement test, ``codesign -R``), and
##   Gatekeeper's notarization verdict (``spctl --assess --type execute``);
## * **identity** (``readAppBundleIdentity`` / ``appBundleCanonicalBytes``)
##   — what the resource lifecycle digests: identifier, versions, team and
##   the code-directory hash of the main executable. Cheap: it reads the
##   signature, it does not re-verify the bundle;
## * **placement** (``placeAppBundle`` / ``removeAppBundle``, and the two
##   halves of placement, ``stageAppBundle`` / ``commitStagedAppBundle``) —
##   stage, verify the staged copy, then rename it into place. Refusal places
##   nothing. A bundle at the target path that Reprobuild did not place is
##   never overwritten.
##
## Every tool runs from its absolute ``/usr/bin`` / ``/usr/sbin`` path:
## a Nix dev shell can put ``sigtool``'s minimal ``codesign`` first on
## ``PATH``, and it does not implement ``--verify --deep`` or ``-R``.
## Arguments go through an argument vector, never a shell.
##
## References:
## * codesign(1), "Code Signing Guide: Using the codesign Tool's Requirement
##   Language" — https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html
## * Developer ID certificate OIDs (1.2.840.113635.100.6.2.6 intermediate,
##   1.2.840.113635.100.6.1.13 leaf) — Apple Root CA certificate policy,
##   https://www.apple.com/certificateauthority/
## * spctl(8); "Notarizing macOS software before distribution" —
##   https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

import std/[os, osproc, strutils, streams]
from repro_core/ambient_execution import uncontrolledStartProcess

const
  CodesignExe* = "/usr/bin/codesign"
  SpctlExe* = "/usr/sbin/spctl"
  DittoExe* = "/usr/bin/ditto"
  PlutilExe* = "/usr/bin/plutil"
  ChmodExe* = "/bin/chmod"

  AppBundleIdentityFormat* = "macos.appBundle.v1"
    ## First line of the canonical identity bytes; bump when the set of
    ## identity fields changes so an old recorded binding never compares
    ## equal to a new observation by accident.

type
  AppTrustRelaxation* = enum
    ## A check ``verifyAppBundle`` may be told to skip. The EMPTY set is the
    ## policy every production caller uses; each member exists for the one
    ## situation that cannot meet it, and says which check it drops.
    atrUnanchoredTeamIdentifier
      ## Accept the ``TeamIdentifier`` a signature carries without proving it
      ## through an Apple-issued Developer ID chain. An ad-hoc signature can
      ## claim any team (``codesign -s - --team-identifier X``), so this is
      ## only for fixtures built at test time, which cannot be signed by
      ## Apple. Signature integrity and the team EQUALITY are still checked.
    atrSkipNotarization
      ## Do not require Gatekeeper to report a notarized Developer ID. Only
      ## for the same test fixtures: nothing built at test time is notarized.

  AppTrustPolicy* = set[AppTrustRelaxation]
    ## ``{}`` is strict — the zero value, so a forgotten field cannot relax
    ## anything.

  AppBundleExpectation* = object
    ## What a contribution declares about the bundle it delivers.
    bundleId*: string        ## expected ``CFBundleIdentifier``
    version*: string         ## expected ``CFBundleShortVersionString``
    teamId*: string          ## expected signing team (10 characters)

  AppBundleIdentity* = object
    ## What a bundle on disk says about itself.
    bundleId*: string
    shortVersion*: string
    bundleVersion*: string
    teamId*: string          ## "" when unsigned / no team
    cdhash*: string          ## code-directory hash of the main executable; "" when unsigned
    adhoc*: bool             ## the signature is ad-hoc (no certificate chain)
    authority*: seq[string]  ## the certificate chain, leaf first

  EAppBundleRefused* = object of CatchableError
    ## The bundle failed a trust check. Nothing was placed.
    bundlePath*: string
    check*: string           ## which check refused: "info-plist",
                             ## "bundle-id", "version", "signature",
                             ## "team-id", "developer-id", "notarization",
                             ## "identity" (a pinned identity differs)

  EAppBundleCollision* = object of CatchableError
    ## The target path holds a bundle Reprobuild did not place.
    targetPath*: string

  EAppBundlePlacement* = object of CatchableError
    ## A copy, rename or removal failed.
    targetPath*: string

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------
#
# The ONE place the macOS application code starts a process (this driver and
# `repro_home_apply/macos_archives`). Every caller passes an absolute path to
# an operating-system tool under `/usr/bin`, `/usr/sbin` or `/bin` -- the
# SIP-protected system volume, which no PATH, Nix profile or user can
# shadow -- never a name resolved through PATH. These tools ARE the platform
# interface being driven (code signing, Gatekeeper, disk images, installer
# packages); there is no store realization of them to prefer. That is why
# the launch goes through the ambient-execution linter's explicit escape
# hatch (`uncontrolledStartProcess`) rather than a typed execution profile.

proc runSystemTool*(exe: string; args: openArray[string]; stdinText = ""):
    tuple[exitCode: int; output, errors: string] =
  ## Run the system tool ``exe`` (an absolute path) with an argument vector
  ## (no shell). stdout and stderr are kept apart (``hdiutil -plist`` writes
  ## the plist on stdout and progress on stderr); stdin receives
  ## ``stdinText`` and is then closed, so a tool that would prompt (an image's
  ## licence agreement) reads end-of-file instead of waiting.
  doAssert exe.isAbsolute, "runSystemTool needs an absolute path: " & exe
  var p: Process
  try:
    p = uncontrolledStartProcess(exe, args = @args, options = {})
  except OSError as err:
    return (127, "", "could not start " & exe & ": " & err.msg)
  try:
    if stdinText.len > 0:
      p.inputStream.write(stdinText)
    p.inputStream.close()
    # Both streams are read before waiting. The tools driven here write
    # little to stderr, so draining stdout first cannot fill stderr's pipe.
    let output = p.outputStream.readAll()
    let errors = p.errorStream.readAll()
    let code = p.waitForExit()
    result = (code, output, errors)
  finally:
    p.close()

proc runTool*(exe: string; args: openArray[string]):
    tuple[exitCode: int; output: string] =
  ## ``runSystemTool`` with stdout and stderr together, for the diagnostics
  ## of ``codesign`` and ``spctl``, which report on stderr.
  let res = runSystemTool(exe, args)
  (res.exitCode, res.output & res.errors)

proc refuse(bundlePath, check, msg: string) {.noreturn.} =
  var e = newException(EAppBundleRefused, "app bundle " & bundlePath.escape &
    " refused (" & check & "): " & msg)
  e.bundlePath = bundlePath
  e.check = check
  raise e

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

proc plistString(plist, key: string): string =
  ## One string value of an ``Info.plist`` (XML or binary) through
  ## ``plutil -extract <key> raw``; "" when the key is absent.
  let res = runTool(PlutilExe, ["-extract", key, "raw", "-o", "-", plist])
  if res.exitCode != 0:
    return ""
  res.output.strip(leading = false, chars = {'\n', '\r'})

proc isValidTeamId*(teamId: string): bool =
  ## Apple team identifiers are ten upper-case letters and digits. Checked
  ## before the value is spliced into a code requirement.
  if teamId.len != 10:
    return false
  for ch in teamId:
    if ch notin {'A'..'Z', '0'..'9'}:
      return false
  true

proc readAppBundleIdentity*(bundlePath: string): AppBundleIdentity =
  ## Read what ``bundlePath`` declares and how it is signed, without
  ## verifying the signature. Raises ``EAppBundleRefused`` (check
  ## ``info-plist``) when the path is not a bundle with an ``Info.plist``.
  let plist = bundlePath / "Contents" / "Info.plist"
  if not dirExists(bundlePath) or not fileExists(plist):
    refuse(bundlePath, "info-plist", "no Contents/Info.plist")
  result.bundleId = plistString(plist, "CFBundleIdentifier")
  result.shortVersion = plistString(plist, "CFBundleShortVersionString")
  result.bundleVersion = plistString(plist, "CFBundleVersion")
  # `codesign -d -vvv` prints the signature description on stderr; an
  # unsigned bundle exits non-zero with "code object is not signed at all".
  let sig = runTool(CodesignExe, ["-d", "-vvv", bundlePath])
  if sig.exitCode != 0:
    return
  for raw in sig.output.splitLines():
    let line = raw.strip()
    if line.startsWith("TeamIdentifier="):
      let v = line["TeamIdentifier=".len .. ^1]
      result.teamId = if v == "not set": "" else: v
    elif line.startsWith("CDHash="):
      result.cdhash = line["CDHash=".len .. ^1]
    elif line == "Signature=adhoc":
      result.adhoc = true
    elif line.startsWith("Authority="):
      result.authority.add(line["Authority=".len .. ^1])

proc appBundleCanonicalBytes*(identity: AppBundleIdentity): seq[byte] =
  ## The bytes the resource lifecycle digests and records for a placed
  ## bundle. Two bundles with the same canonical bytes carry the same signed
  ## code directory, so the comparison is a content comparison of what the
  ## signature seals, without hashing hundreds of megabytes on every apply.
  let text = AppBundleIdentityFormat & "\n" &
    "bundleId=" & identity.bundleId & "\n" &
    "shortVersion=" & identity.shortVersion & "\n" &
    "bundleVersion=" & identity.bundleVersion & "\n" &
    "teamId=" & identity.teamId & "\n" &
    "cdhash=" & identity.cdhash & "\n"
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

proc developerIdRequirement*(teamId: string): string =
  ## The code requirement a Developer ID-signed bundle of ``teamId``
  ## satisfies: anchored at Apple's root, issued through the Developer ID
  ## intermediate, a Developer ID Application leaf, and the team in the
  ## leaf's subject OU. This is the form Apple documents for Developer ID
  ## designated requirements.
  "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] " &
    "exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists " &
    "and certificate leaf[subject.OU] = \"" & teamId & "\""

proc verifyAppBundle*(bundlePath: string; expected: AppBundleExpectation;
                      policy: AppTrustPolicy = {}): AppBundleIdentity =
  ## Every trust check, in order; the first failure raises
  ## ``EAppBundleRefused`` naming the check. Returns the bundle's identity.
  if not isValidTeamId(expected.teamId):
    refuse(bundlePath, "team-id", "the contribution declares team id " &
      expected.teamId.escape & ", which is not a 10-character Apple team " &
      "identifier; a contribution must declare the team that signs the app")
  result = readAppBundleIdentity(bundlePath)
  if expected.bundleId.len == 0 or result.bundleId != expected.bundleId:
    refuse(bundlePath, "bundle-id", "CFBundleIdentifier is " &
      result.bundleId.escape & ", the contribution declares " &
      expected.bundleId.escape)
  if expected.version.len > 0 and result.shortVersion != expected.version:
    refuse(bundlePath, "version", "CFBundleShortVersionString is " &
      result.shortVersion.escape & ", the contribution declares " &
      expected.version.escape)
  # Integrity of the whole bundle: every nested code object and every sealed
  # resource. --strict also rejects symlinks that leave the bundle and
  # unsealed additions.
  let verify = runTool(CodesignExe,
    ["--verify", "--deep", "--strict", "--verbose=2", bundlePath])
  if verify.exitCode != 0:
    refuse(bundlePath, "signature", "codesign --verify --deep --strict " &
      "failed:\n" & verify.output.strip())
  if result.teamId != expected.teamId:
    refuse(bundlePath, "team-id", "signed by team " &
      (if result.teamId.len > 0: result.teamId else: "<none>") &
      ", the contribution declares " & expected.teamId)
  if atrUnanchoredTeamIdentifier notin policy:
    # The TeamIdentifier above is a claim inside the signature; an ad-hoc
    # signature can carry any value. The requirement test proves it through
    # Apple's certificate chain.
    let req = runTool(CodesignExe, ["--verify", "--strict",
      "-R=" & developerIdRequirement(expected.teamId), bundlePath])
    if req.exitCode != 0:
      refuse(bundlePath, "developer-id", "the signature does not chain to " &
        "an Apple Developer ID Application certificate of team " &
        expected.teamId & ":\n" & req.output.strip())
  if atrSkipNotarization notin policy:
    let assess = runTool(SpctlExe,
      ["--assess", "--type", "execute", "-vv", bundlePath])
    if assess.exitCode != 0 or
        "source=Notarized Developer ID" notin assess.output:
      refuse(bundlePath, "notarization", "Gatekeeper does not assess the " &
        "bundle as a notarized Developer ID app" &
        (if "assessments disabled" in assess.output:
           " (Gatekeeper assessments are disabled on this host, so " &
             "notarization cannot be established; re-enable them with " &
             "`spctl --global-enable`)"
         else: "") & ":\n" & assess.output.strip())

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

type
  AppPlacementScope* = enum
    ## Spec P3: the home/system boundary is privilege.
    apsHome = "home"       ## ``~/Applications`` — unelevated
    apsSystem = "system"   ## ``/Applications`` — needs administrator rights

proc applicationsDir*(scope: AppPlacementScope; homeDir: string;
                      systemRoot = "/"): string =
  ## The Applications directory of ``scope``. ``systemRoot`` re-roots the
  ## system scope (an image being assembled, or a test's scratch root); it
  ## is ``/`` for a live system.
  case scope
  of apsHome: homeDir / "Applications"
  of apsSystem: systemRoot / "Applications"

proc pathPresent(path: string): bool =
  symlinkExists(path) or fileExists(path) or dirExists(path)

proc makeOwnerWritable(path: string) =
  ## Store prefixes are read-only; a copy keeps their modes. Placed bundles
  ## must stay removable (and updatable by an app's own updater).
  if not pathPresent(path) or symlinkExists(path):
    return
  let res = runTool(ChmodExe, ["-R", "u+w", path])
  if res.exitCode != 0:
    var e = newException(EAppBundlePlacement, "chmod -R u+w " &
      path.escape & " failed: " & res.output.strip())
    e.targetPath = path
    raise e

proc removeTree(path: string) =
  ## Remove a placed bundle, or a symlink at its path (never what a symlink
  ## points to).
  if symlinkExists(path) or fileExists(path):
    removeFile(path)
    return
  if not dirExists(path):
    return
  makeOwnerWritable(path)
  removeDir(path)

proc copyBundle*(source, dest: string) =
  ## ``ditto`` preserves what a code signature depends on — symlinks inside
  ## frameworks, extended attributes, resource forks, ACLs — and ``--clone``
  ## makes it an APFS clone when source and destination share a volume.
  ## ``--noqtn``: Reprobuild has made the Gatekeeper assessment itself; a
  ## quarantine flag carried over would make macOS translocate the app on
  ## first launch.
  let res = runTool(DittoExe, ["--clone", "--noqtn", source, dest])
  if res.exitCode != 0:
    var e = newException(EAppBundlePlacement, "ditto " & source.escape &
      " -> " & dest.escape & " failed: " & res.output.strip())
    e.targetPath = dest
    raise e

proc verifyPinnedAppBundle*(bundlePath: string;
                            pinned: openArray[byte]): AppBundleIdentity =
  ## Verify ``bundlePath`` against identity bytes a generation recorded when
  ## it placed the bundle (``appBundleCanonicalBytes``): the signature must
  ## be intact (``codesign --verify --deep --strict``) and the identity —
  ## identifier, versions, team, code-directory hash — byte-for-byte equal.
  ## Equal code-directory hashes and an intact signature mean the same signed
  ## code as the bundle that passed every trust check when it was recorded,
  ## so rollback re-places a bundle without re-running the anchor and
  ## notarization checks.
  result = readAppBundleIdentity(bundlePath)
  let verify = runTool(CodesignExe,
    ["--verify", "--deep", "--strict", "--verbose=2", bundlePath])
  if verify.exitCode != 0:
    refuse(bundlePath, "signature", "codesign --verify --deep --strict " &
      "failed:\n" & verify.output.strip())
  let observed = appBundleCanonicalBytes(result)
  if observed.len != pinned.len or observed != @pinned:
    var observedText = newString(observed.len)
    for i, b in observed: observedText[i] = char(b)
    var pinnedText = newString(pinned.len)
    for i, b in pinned: pinnedText[i] = char(b)
    refuse(bundlePath, "identity", "the bundle is not the one the " &
      "generation recorded.\nrecorded:\n" & pinnedText & "observed:\n" &
      observedText)

type
  StagedAppBundle* = object
    ## A verified copy of a bundle waiting beside its target
    ## (``stageAppBundle``). It is either renamed into place
    ## (``commitStagedAppBundle``) or discarded (``discardStagedAppBundle``);
    ## until then the target is exactly as it was.
    target*: string            ## ``applicationsDir / bundleName``
    identity*: AppBundleIdentity
      ## What the staged copy carries (verified).
    applicationsDir: string
    stagingDir: string         ## private directory holding the staged copy
    retiredDir: string         ## where a replaced bundle is moved aside
    createdDir: bool           ## staging created ``applicationsDir``

proc dropDirIfCreatedAndEmpty(staged: StagedAppBundle) =
  ## Remove the Applications directory when staging created it and nothing
  ## else is in it, so a refused placement leaves the filesystem as it found
  ## it. Never removes a directory that holds anything (another bundle
  ## staged by the same caller, or a file someone else put there).
  if not staged.createdDir or not dirExists(staged.applicationsDir):
    return
  for _ in walkDir(staged.applicationsDir):
    return
  try: removeDir(staged.applicationsDir, checkDir = false)
  except OSError: discard

proc discardStagedAppBundle*(staged: StagedAppBundle) =
  ## Drop a staged copy that will not be placed. The target is untouched.
  ## Several bundles staged into one newly created Applications directory
  ## must be discarded in the reverse order of staging for that directory
  ## to be removed (only the first staging created it).
  try: removeTree(staged.stagingDir) except CatchableError: discard
  dropDirIfCreatedAndEmpty(staged)

proc stageAppBundle*(source, applicationsDir, bundleName: string;
                     expected: AppBundleExpectation;
                     policy: AppTrustPolicy = {};
                     managedPrior = false;
                     pinned: seq[byte] = @[]): StagedAppBundle =
  ## The first half of ``placeAppBundle``: copy ``source`` beside
  ## ``applicationsDir / bundleName`` and verify the copy, without touching
  ## the target. Raises (``EAppBundleCollision``, ``EAppBundleRefused``,
  ## ``EAppBundlePlacement``) with nothing left behind: no staged copy and
  ## no Applications directory this call created. Verification is as
  ## documented on ``placeAppBundle``.
  ##
  ## A caller placing several bundles stages them all first and commits
  ## only when every one verified, so a refusal of any bundle changes none
  ## (rollback does this). Each bundle has its own staging directory, so
  ## several can be staged into one Applications directory at once.
  if bundleName.len == 0 or '/' in bundleName or bundleName == "." or
      bundleName == ".." or not bundleName.endsWith(".app"):
    var e = newException(EAppBundlePlacement, "invalid bundle name " &
      bundleName.escape)
    e.targetPath = applicationsDir / bundleName
    raise e
  let target = applicationsDir / bundleName
  if pathPresent(target) and not managedPrior:
    var e = newException(EAppBundleCollision, target.escape & " already " &
      "exists and was not placed by Reprobuild; refusing to replace it. " &
      "Remove or rename it, or claim it with `repro home adopt`.")
    e.targetPath = target
    raise e
  # Staging and retired copies keep the bundle's OWN name, inside private
  # directories beside the target (same volume, so the final moves are
  # renames). The name matters: a bundle whose `CFBundleExecutable` is empty
  # (DB Browser for SQLite ships one) has its main executable found from the
  # bundle's directory name, so a renamed copy is "not signed at all". The
  # directories are per bundle so that several bundles can be staged at
  # once.
  let workRoot = applicationsDir / (".repro-" & $getCurrentProcessId() &
    "-" & bundleName.changeFileExt(""))
  result = StagedAppBundle(target: target, applicationsDir: applicationsDir,
    stagingDir: workRoot & ".staging", retiredDir: workRoot & ".old",
    createdDir: not dirExists(applicationsDir))
  let staging = result.stagingDir / bundleName
  try:
    createDir(applicationsDir)
    removeTree(result.stagingDir)
    removeTree(result.retiredDir)
    createDir(result.stagingDir)
    copyBundle(source, staging)
    makeOwnerWritable(staging)
    if expected.teamId.len == 0 and pinned.len > 0:
      result.identity = verifyPinnedAppBundle(staging, pinned)
    else:
      result.identity = verifyAppBundle(staging, expected, policy)
      if pinned.len > 0:
        discard verifyPinnedAppBundle(staging, pinned)
  except CatchableError:
    discardStagedAppBundle(result)
    raise

proc commitStagedAppBundle*(staged: StagedAppBundle): AppBundleIdentity =
  ## The second half of ``placeAppBundle``: rename the staged copy into
  ## place. A bundle already at the target is first moved aside and is
  ## removed only after the staged copy is in place, so the target never
  ## holds neither. A failed rename puts the moved-aside bundle back and
  ## raises ``EAppBundlePlacement``.
  let bundleName = extractFilename(staged.target)
  let staging = staged.stagingDir / bundleName
  let retired = staged.retiredDir / bundleName
  var movedAside = false
  try:
    if pathPresent(staged.target):
      createDir(staged.retiredDir)
      moveDir(staged.target, retired)
      movedAside = true
    moveDir(staging, staged.target)
  except OSError as err:
    if movedAside and not pathPresent(staged.target):
      try: moveDir(retired, staged.target) except OSError: discard
    try: removeTree(staged.retiredDir) except CatchableError: discard
    discardStagedAppBundle(staged)
    var e = newException(EAppBundlePlacement, "could not move " &
      staging.escape & " into place at " & staged.target.escape & ": " &
      err.msg)
    e.targetPath = staged.target
    raise e
  removeTree(staged.stagingDir)
  removeTree(staged.retiredDir)
  staged.identity

proc placeAppBundle*(source, applicationsDir, bundleName: string;
                     expected: AppBundleExpectation;
                     policy: AppTrustPolicy = {};
                     managedPrior = false;
                     pinned: seq[byte] = @[]): AppBundleIdentity =
  ## Place ``source`` (a verified bundle in the store) at
  ## ``applicationsDir / bundleName``.
  ##
  ## ``managedPrior`` says the previous generation recorded a bundle at that
  ## path: only then may an existing bundle be replaced. Otherwise an
  ## existing path is a bundle the user (or another installer) put there and
  ## the call raises ``EAppBundleCollision`` without touching it.
  ##
  ## The copy is staged beside the target, VERIFIED as staged (the bytes
  ## that will be launched, not the store's), and only then renamed into
  ## place, so a refused or interrupted placement leaves the target as it
  ## was. The staged copy passes ``verifyAppBundle(expected, policy)``; when
  ## ``pinned`` is non-empty it must ALSO carry exactly that identity (apply
  ## pins the store bundle's identity, so the placed copy is the realized
  ## bundle). Rollback passes ``pinned`` with an empty ``expected.teamId``
  ## to verify against the recorded identity alone
  ## (``verifyPinnedAppBundle``). ``stageAppBundle`` followed by
  ## ``commitStagedAppBundle``.
  commitStagedAppBundle(stageAppBundle(source, applicationsDir, bundleName,
    expected, policy, managedPrior, pinned))

proc removeAppBundle*(targetPath: string) =
  ## Remove a bundle Reprobuild placed. The caller has established
  ## ownership (the recorded binding's digest matches what is there).
  try:
    removeTree(targetPath)
  except OSError as err:
    var e = newException(EAppBundlePlacement, "could not remove " &
      targetPath.escape & ": " & err.msg)
    e.targetPath = targetPath
    raise e
