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
## The PLACED ITEM is usually the bundle itself. An installer application's
## product can instead be a bundle inside a FOLDER of the installed prefix
## (``OpenWebStart/OpenWebStart javaws.app``); the folder is then the placed
## item, copied and removed as a whole, and its identity is the folder
## identity (``readPlacedItemIdentityBytes``): the identities of the bundles
## directly in it. Store-And-Installation-Layout.md § Installer applications,
## "Activation".
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

import std/[algorithm, os, osproc, strutils, streams]
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
  AppFolderIdentityFormat* = "macos.appFolder.v1"
    ## First line of a FOLDER's identity bytes (a placed item that holds
    ## bundles rather than being one; Store-And-Installation-Layout.md
    ## § Installer applications, "Activation"). Distinct from
    ## ``AppBundleIdentityFormat``, so a folder never compares equal to a
    ## bundle.

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

proc appBundleExecutableName*(bundlePath: string): string =
  ## The bundle's ``CFBundleExecutable`` ("" when absent or empty; macOS
  ## then uses the bundle's directory name).
  plistString(bundlePath / "Contents" / "Info.plist", "CFBundleExecutable")

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

proc appBundleIdentityFields(identity: AppBundleIdentity): string =
  ## The identity field lines shared by a bundle's and a folder's identity
  ## bytes: identifier, both versions, team, code-directory hash.
  "bundleId=" & identity.bundleId & "\n" &
    "shortVersion=" & identity.shortVersion & "\n" &
    "bundleVersion=" & identity.bundleVersion & "\n" &
    "teamId=" & identity.teamId & "\n" &
    "cdhash=" & identity.cdhash & "\n"

proc bytesOfText(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc appBundleCanonicalBytes*(identity: AppBundleIdentity): seq[byte] =
  ## The bytes the resource lifecycle digests and records for a placed
  ## bundle. Two bundles with the same canonical bytes carry the same signed
  ## code directory, so the comparison is a content comparison of what the
  ## signature seals, without hashing hundreds of megabytes on every apply.
  bytesOfText(AppBundleIdentityFormat & "\n" &
    appBundleIdentityFields(identity))

proc isAppBundleName*(name: string): bool =
  ## A placed item named ``<Name>.app`` is a bundle; any other name is a
  ## folder holding bundles.
  name.endsWith(".app")

proc placedItemOf*(appBundle: string): tuple[item, mainBundle: string] =
  ## The placed item of an installer application whose product bundle is
  ## ``appBundle`` (a path in the installed prefix), and the product
  ## bundle's path inside it: the bundle itself for a one-component path
  ## (``mainBundle`` ""), otherwise the first component -- the folder holding
  ## the product -- and the rest (Store-And-Installation-Layout.md
  ## § Installer applications, "Declaring it").
  let parts = appBundle.replace('\\', '/').split('/')
  if parts.len == 1:
    (parts[0], "")
  else:
    (parts[0], parts[1 .. ^1].join("/"))

proc installerProductPathError*(appBundle: string): string =
  ## "" when ``appBundle`` is a valid product-bundle path of an installer
  ## application, otherwise why it is not (Store-And-Installation-Layout.md
  ## § Installer applications, "Declaring it"): a relative ``/``-separated
  ## path of ONE or TWO components, none empty, ``.``, ``..`` or hidden,
  ## naming a ``.app``; with two, the first (the placed folder) is not itself
  ## a ``.app``. Two at most because the folder identity covers only the
  ## bundles DIRECTLY in the placed folder: a product nested deeper would be
  ## launched from bytes the recorded identity does not pin.
  if appBundle.len == 0 or appBundle.startsWith("/") or '\\' in appBundle:
    return "it must be a relative '/'-separated path"
  let parts = appBundle.split('/')
  if parts.len > 2:
    return "it has " & $parts.len & " components; it names the product " &
      "bundle (one component) or the folder holding it and the bundle (two)"
  for part in parts:
    if part.len == 0 or part == "." or part == ".." or part.startsWith("."):
      return "it has an empty, '.', '..' or hidden component"
  if not parts[^1].endsWith(".app"):
    return "it must name a .app bundle"
  if parts.len == 2 and parts[0].endsWith(".app"):
    return "its first component is the placed item, which holds the " &
      "product bundle and must not itself be a .app bundle"
  ""

proc topLevelBundles*(folder: string): seq[string] =
  ## The names of the ``.app`` bundles directly in ``folder``, in byte order
  ## (the order of the folder identity). A symlink named ``*.app`` is not a
  ## bundle of the folder: it is not followed, so it cannot pull a bundle
  ## from elsewhere into the identity.
  for kind, name in walkDir(folder, relative = true):
    if kind == pcDir and isAppBundleName(name):
      result.add(name)
  result.sort(system.cmp[string])

proc readPlacedItemIdentityBytes*(itemPath: string): seq[byte] =
  ## The identity bytes of a placed item, which the resource lifecycle
  ## records and compares: for a bundle (``<Name>.app``) exactly
  ## ``appBundleCanonicalBytes`` -- so every bundle placed before folders
  ## existed keeps its recorded identity -- and for a folder the folder
  ## identity: ``macos.appFolder.v1``, then for each bundle directly in the
  ## folder in byte order of its name a ``bundle=<name>`` line followed by
  ## that bundle's identity fields. Files outside a bundle's signature are
  ## not part of it (Store-And-Installation-Layout.md § Installer
  ## applications, "Activation"). Raises ``EAppBundleRefused`` (check
  ## ``info-plist``) when the item is not a readable bundle or folder.
  if isAppBundleName(extractFilename(itemPath)):
    return appBundleCanonicalBytes(readAppBundleIdentity(itemPath))
  if symlinkExists(itemPath) or not dirExists(itemPath):
    refuse(itemPath, "info-plist", "not a folder of application bundles")
  var text = AppFolderIdentityFormat & "\n"
  for name in topLevelBundles(itemPath):
    text.add("bundle=" & name & "\n" &
      appBundleIdentityFields(readAppBundleIdentity(itemPath / name)))
  bytesOfText(text)

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

proc refuseInvalidTeamId(bundlePath, teamId: string) =
  if not isValidTeamId(teamId):
    refuse(bundlePath, "team-id", "the contribution declares team id " &
      teamId.escape & ", which is not a 10-character Apple team " &
      "identifier; a contribution must declare the team that signs the app")

proc verifySignatureIntegrity*(bundlePath: string) =
  ## Trust check 2: integrity of the whole bundle -- every nested code
  ## object and every sealed resource. ``--strict`` also rejects symlinks
  ## that leave the bundle and unsealed additions.
  let verify = runTool(CodesignExe,
    ["--verify", "--deep", "--strict", "--verbose=2", bundlePath])
  if verify.exitCode != 0:
    refuse(bundlePath, "signature", "codesign --verify --deep --strict " &
      "failed:\n" & verify.output.strip())

proc verifyTeamSignature(bundlePath: string; identity: AppBundleIdentity;
                         teamId: string; policy: AppTrustPolicy) =
  ## Trust checks 2 to 5 against ``teamId``: signature integrity, the
  ## signing team, the Developer ID chain proving it, and notarization.
  verifySignatureIntegrity(bundlePath)
  if identity.teamId != teamId:
    refuse(bundlePath, "team-id", "signed by team " &
      (if identity.teamId.len > 0: identity.teamId else: "<none>") &
      ", the contribution declares " & teamId)
  if atrUnanchoredTeamIdentifier notin policy:
    # The TeamIdentifier above is a claim inside the signature; an ad-hoc
    # signature can carry any value. The requirement test proves it through
    # Apple's certificate chain.
    let req = runTool(CodesignExe, ["--verify", "--strict",
      "-R=" & developerIdRequirement(teamId), bundlePath])
    if req.exitCode != 0:
      refuse(bundlePath, "developer-id", "the signature does not chain to " &
        "an Apple Developer ID Application certificate of team " &
        teamId & ":\n" & req.output.strip())
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

proc verifyAppBundle*(bundlePath: string; expected: AppBundleExpectation;
                      policy: AppTrustPolicy = {}): AppBundleIdentity =
  ## Every trust check, in order; the first failure raises
  ## ``EAppBundleRefused`` naming the check. Returns the bundle's identity.
  refuseInvalidTeamId(bundlePath, expected.teamId)
  result = readAppBundleIdentity(bundlePath)
  if expected.bundleId.len == 0 or result.bundleId != expected.bundleId:
    refuse(bundlePath, "bundle-id", "CFBundleIdentifier is " &
      result.bundleId.escape & ", the contribution declares " &
      expected.bundleId.escape)
  if expected.version.len > 0 and result.shortVersion != expected.version:
    refuse(bundlePath, "version", "CFBundleShortVersionString is " &
      result.shortVersion.escape & ", the contribution declares " &
      expected.version.escape)
  verifyTeamSignature(bundlePath, result, expected.teamId, policy)

proc verifyAppBundleTeam*(bundlePath, teamId: string;
                          policy: AppTrustPolicy = {}): AppBundleIdentity =
  ## Trust checks 2 to 5 against ``teamId`` for a bundle that declares no
  ## identifier or version of its own: an installer application (pinned by
  ## its archive's sha256) and the other bundles an installer produced
  ## (Store-And-Installation-Layout.md § Installer applications). Check 1
  ## only requires ``Contents/Info.plist``. ``policy`` relaxes checks 4 and
  ## 5 exactly as for ``verifyAppBundle``.
  refuseInvalidTeamId(bundlePath, teamId)
  result = readAppBundleIdentity(bundlePath)
  verifyTeamSignature(bundlePath, result, teamId, policy)

# ---------------------------------------------------------------------------
# Vendor updates and running applications
# ---------------------------------------------------------------------------
#
# Store-And-Installation-Layout.md § macOS Application Bundles, "Vendor
# updates" and "Running applications". An application that updates itself
# (Sparkle, Squirrel / Electron updaters) replaces the placed bundle with a
# newer build its vendor signed; the apply recognises that instead of
# calling it drift, and never replaces the bundle of an application that is
# running.

proc parseAppBundleIdentityBytes*(bytes: openArray[byte];
                                  identity: var AppBundleIdentity): bool =
  ## Parse the identity bytes of a BUNDLE (``appBundleCanonicalBytes``).
  ## False for anything else -- a folder identity, the not-a-bundle marker,
  ## an unknown format -- so only a placed bundle can ever be recognised as
  ## a vendor update. ``adhoc`` and ``authority`` are not part of the bytes
  ## and stay empty.
  var text = newString(bytes.len)
  for i, b in bytes:
    text[i] = char(b)
  let lines = text.splitLines()
  if lines.len == 0 or lines[0] != AppBundleIdentityFormat:
    return false
  var seen = 0
  for line in lines[1 .. ^1]:
    if line.len == 0:
      continue
    let eq = line.find('=')
    if eq <= 0:
      return false
    let value = line[eq + 1 .. ^1]
    case line[0 ..< eq]
    of "bundleId": identity.bundleId = value
    of "shortVersion": identity.shortVersion = value
    of "bundleVersion": identity.bundleVersion = value
    of "teamId": identity.teamId = value
    of "cdhash": identity.cdhash = value
    else: return false
    inc seen
  seen == 5

proc compareVersionStrings*(a, b: string): int =
  ## Compare two bundle version strings: runs of digits numerically, every
  ## other character by its code, component by component (``1.142.0`` >
  ## ``1.141.0``, ``2.42304.0`` > ``2.37337.1``, ``26.1007.41230`` >
  ## ``26.623.141536``). A string that is a prefix of the other is older
  ## (``1.2`` < ``1.2.1``). Returns -1, 0 or 1.
  var i, j = 0
  while i < a.len and j < b.len:
    if a[i].isDigit and b[j].isDigit:
      var ia = i
      while ia < a.len and a[ia] == '0': inc ia
      var ib = j
      while ib < b.len and b[ib] == '0': inc ib
      var ea = ia
      while ea < a.len and a[ea].isDigit: inc ea
      var eb = ib
      while eb < b.len and b[eb].isDigit: inc eb
      # Fewer significant digits is the smaller number; equal lengths
      # compare lexically.
      if ea - ia != eb - ib:
        return (if ea - ia < eb - ib: -1 else: 1)
      let c = cmp(a[ia ..< ea], b[ib ..< eb])
      if c != 0:
        return (if c < 0: -1 else: 1)
      i = ea
      j = eb
    else:
      if a[i] != b[j]:
        return (if a[i] < b[j]: -1 else: 1)
      inc i
      inc j
  if i < a.len: 1
  elif j < b.len: -1
  else: 0

proc compareBundleVersions*(a, b: AppBundleIdentity): int =
  ## Order two builds of one application: ``CFBundleShortVersionString``
  ## first, ``CFBundleVersion`` to break a tie.
  result = compareVersionStrings(a.shortVersion, b.shortVersion)
  if result == 0:
    result = compareVersionStrings(a.bundleVersion, b.bundleVersion)

proc vendorUpdateCandidate*(recorded, observed: openArray[byte]): bool =
  ## The cheap half of ``isAcceptedVendorUpdate``, reading identity bytes
  ## only: both are bundles, the same application (``CFBundleIdentifier``)
  ## signed by the same team, and the observed build is NEWER than the
  ## recorded one. A downgrade, another application, another team, an
  ## unsigned copy or a folder is never a candidate.
  var r, o: AppBundleIdentity
  if not parseAppBundleIdentityBytes(recorded, r) or
      not parseAppBundleIdentityBytes(observed, o):
    return false
  r.bundleId.len > 0 and o.bundleId == r.bundleId and
    isValidTeamId(r.teamId) and o.teamId == r.teamId and
    o.cdhash.len > 0 and compareBundleVersions(o, r) > 0

proc isAcceptedVendorUpdate*(recorded, observed: openArray[byte];
                             bundlePath: string;
                             policy: AppTrustPolicy = {}): bool =
  ## Whether the bundle at ``bundlePath``, whose identity bytes are
  ## ``observed``, is its vendor's own update of the bundle a generation
  ## recorded (``recorded``): a ``vendorUpdateCandidate`` that passes trust
  ## checks 2, 4 and 5 against the recorded team -- an intact signature, the
  ## team's Developer ID, notarized -- the checks that admitted the
  ## recorded bundle. Check 1's identifier is part of the candidate test;
  ## its version is by construction not the declared one. ``policy``
  ## relaxes checks 4 and 5 exactly as for ``verifyAppBundle`` (tests only).
  if not vendorUpdateCandidate(recorded, observed):
    return false
  var r: AppBundleIdentity
  discard parseAppBundleIdentityBytes(recorded, r)
  try:
    let live = verifyAppBundleTeam(bundlePath, r.teamId, policy)
    # The bytes were read before the checks ran; the bundle verified must
    # be the one observed, not one an updater swapped in since.
    appBundleCanonicalBytes(live) == @observed
  except EAppBundleRefused:
    false

proc describeIdentityVersion*(bytes: openArray[byte]): string =
  ## ``<shortVersion> (<bundleVersion>)`` of a bundle's identity bytes, or
  ## "" for anything that is not a bundle identity. For messages.
  var identity: AppBundleIdentity
  if not parseAppBundleIdentityBytes(bytes, identity):
    return ""
  if identity.bundleVersion.len > 0 and
      identity.bundleVersion != identity.shortVersion:
    identity.shortVersion & " (" & identity.bundleVersion & ")"
  else:
    identity.shortVersion

when defined(macosx):
  proc procListAllPids(buffer: pointer; bufferSize: cint): cint
    {.importc: "proc_listallpids", header: "<libproc.h>".}
  proc procPidPath(pid: cint; buffer: pointer; bufferSize: uint32): cint
    {.importc: "proc_pidpath", header: "<libproc.h>".}

proc processesRunningFrom*(itemPath: string): seq[int] =
  ## The ids of the processes whose executable lies inside ``itemPath`` (a
  ## placed bundle or folder): the application and every helper it started
  ## from its own bundle. Read through libproc (``proc_listallpids``,
  ## ``proc_pidpath``), which reports the executable's resolved path; a
  ## process of another user whose path cannot be read is not reported.
  ## Empty off macOS.
  when defined(macosx):
    let resolved =
      try: expandFilename(itemPath)
      except OSError: itemPath
    let prefix = resolved & "/"
    var capacity = 4096
    var pids: seq[cint]
    while true:
      pids.setLen(capacity)
      let n = procListAllPids(addr pids[0], cint(capacity * sizeof(cint)))
      if n <= 0:
        return
      if n < capacity:
        pids.setLen(n)
        break
      capacity *= 2
    const ProcPidPathInfoMaxSize = 4 * 1024
    var buf = newString(ProcPidPathInfoMaxSize)
    for pid in pids:
      if pid <= 0:
        continue
      let len = procPidPath(pid, addr buf[0], uint32(ProcPidPathInfoMaxSize))
      if len <= 0:
        continue
      let path = buf[0 ..< len]
      if path.startsWith(prefix):
        result.add int(pid)
    result.sort()
  else:
    discard itemPath

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

proc refuseIdentityMismatch(path: string; observed: seq[byte];
                            pinned: openArray[byte]) =
  if observed.len != pinned.len or observed != @pinned:
    var observedText = newString(observed.len)
    for i, b in observed: observedText[i] = char(b)
    var pinnedText = newString(pinned.len)
    for i, b in pinned: pinnedText[i] = char(b)
    refuse(path, "identity", "the bundle is not the one the " &
      "generation recorded.\nrecorded:\n" & pinnedText & "observed:\n" &
      observedText)

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
  verifySignatureIntegrity(bundlePath)
  refuseIdentityMismatch(bundlePath, appBundleCanonicalBytes(result), pinned)

proc verifyPinnedPlacedItem*(itemPath: string; pinned: openArray[byte]) =
  ## ``verifyPinnedAppBundle`` for any placed item. A folder is verified
  ## against the folder identity a generation recorded: check 2 on every
  ## bundle directly in it, and byte-equal folder identity bytes, which carry
  ## each bundle's code-directory hash -- what rollback needs to re-place a
  ## folder without re-running the anchor and notarization checks
  ## (Store-And-Installation-Layout.md § Installer applications,
  ## "Activation").
  if isAppBundleName(extractFilename(itemPath)):
    discard verifyPinnedAppBundle(itemPath, pinned)
    return
  let observed = readPlacedItemIdentityBytes(itemPath)
  for name in topLevelBundles(itemPath):
    verifySignatureIntegrity(itemPath / name)
  refuseIdentityMismatch(itemPath, observed, pinned)

type
  StagedAppBundle* = object
    ## A verified copy of a bundle waiting beside its target
    ## (``stageAppBundle``). It is either renamed into place
    ## (``commitStagedAppBundle``) or discarded (``discardStagedAppBundle``);
    ## until then the target is exactly as it was.
    target*: string            ## ``applicationsDir / bundleName``
    identity*: AppBundleIdentity
      ## What the staged copy carries (verified): the bundle's identity, or
      ## for a folder its product bundle's (empty when a folder was staged
      ## against pinned bytes alone, as rollback does).
    itemIdentity*: seq[byte]
      ## ``readPlacedItemIdentityBytes`` of the staged copy: what the
      ## resource lifecycle records for the placed item.
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

proc invalidPlacement(target, msg: string) {.noreturn.} =
  var e = newException(EAppBundlePlacement, msg)
  e.targetPath = target
  raise e

proc validMainBundlePath(mainBundle: string): bool =
  ## A product bundle's path inside a placed folder: ONE component naming a
  ## ``.app`` directly in the folder, because the folder identity covers
  ## only the bundles directly in it (``installerProductPathError``).
  mainBundle.len > 0 and '/' notin mainBundle and '\\' notin mainBundle and
    mainBundle != "." and mainBundle != ".." and
    not mainBundle.startsWith(".") and mainBundle.endsWith(".app")

proc verifyStagedFolder(staging, mainBundle: string;
                        expected: AppBundleExpectation;
                        policy: AppTrustPolicy): AppBundleIdentity =
  ## A staged FOLDER (Store-And-Installation-Layout.md § Installer
  ## applications, "Activation"): its product bundle passes trust checks 1
  ## to 5 and every other bundle directly in it check 2. The product bundle
  ## is reached without crossing a symlink, so the checks run on the bytes
  ## that will be launched.
  var walked = staging
  for part in mainBundle.split('/'):
    walked = walked / part
    if symlinkExists(walked):
      refuse(walked, "info-plist", "the product bundle path " &
        mainBundle.escape & " crosses a symlink")
  result = verifyAppBundle(staging / mainBundle, expected, policy)
  for name in topLevelBundles(staging):
    if name != mainBundle:
      verifySignatureIntegrity(staging / name)

proc stageAppBundle*(source, applicationsDir, bundleName: string;
                     expected: AppBundleExpectation;
                     policy: AppTrustPolicy = {};
                     managedPrior = false;
                     pinned: seq[byte] = @[];
                     mainBundle = ""): StagedAppBundle =
  ## The first half of ``placeAppBundle``: copy ``source`` beside
  ## ``applicationsDir / bundleName`` and verify the copy, without touching
  ## the target. Raises (``EAppBundleCollision``, ``EAppBundleRefused``,
  ## ``EAppBundlePlacement``) with nothing left behind: no staged copy and
  ## no Applications directory this call created. Verification is as
  ## documented on ``placeAppBundle``.
  ##
  ## ``bundleName`` is the placed item: ``<Name>.app``, or a folder name
  ## (an installer application's product folder), in which case
  ## ``mainBundle`` is the product bundle's path inside it that
  ## ``expected`` describes. Rollback stages a folder with an empty
  ## ``expected`` and the recorded ``pinned`` bytes alone, and needs no
  ## ``mainBundle``.
  ##
  ## A caller placing several bundles stages them all first and commits
  ## only when every one verified, so a refusal of any bundle changes none
  ## (rollback does this). Each bundle has its own staging directory, so
  ## several can be staged into one Applications directory at once.
  if bundleName.len == 0 or '/' in bundleName or bundleName == "." or
      bundleName == ".." or bundleName.startsWith("."):
    invalidPlacement(applicationsDir / bundleName,
      "invalid placed-item name " & bundleName.escape)
  let isFolder = not isAppBundleName(bundleName)
  let pinnedOnly = expected.teamId.len == 0 and pinned.len > 0
  if not isFolder and mainBundle.len > 0:
    invalidPlacement(applicationsDir / bundleName, "bundle " &
      bundleName.escape & " is placed as itself; it has no product bundle " &
      "path (got " & mainBundle.escape & ")")
  if isFolder and not pinnedOnly and not validMainBundlePath(mainBundle):
    invalidPlacement(applicationsDir / bundleName, "folder " &
      bundleName.escape & " needs its product bundle, the name of a " &
      ".app directly in it (got " & mainBundle.escape & ")")
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
    "-" & (if isFolder: bundleName else: bundleName.changeFileExt("")))
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
    if not isFolder:
      if pinnedOnly:
        result.identity = verifyPinnedAppBundle(staging, pinned)
      else:
        result.identity = verifyAppBundle(staging, expected, policy)
        if pinned.len > 0:
          discard verifyPinnedAppBundle(staging, pinned)
      result.itemIdentity = appBundleCanonicalBytes(result.identity)
    elif pinnedOnly:
      verifyPinnedPlacedItem(staging, pinned)
      result.itemIdentity = pinned
    else:
      result.identity = verifyStagedFolder(staging, mainBundle, expected,
        policy)
      result.itemIdentity = readPlacedItemIdentityBytes(staging)
      if pinned.len > 0:
        refuseIdentityMismatch(staging, result.itemIdentity, pinned)
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
                     pinned: seq[byte] = @[];
                     mainBundle = ""): AppBundleIdentity =
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
  ##
  ## A FOLDER placed item (``bundleName`` not ending in ``.app``; an
  ## installer application's product folder) is placed as a whole: its
  ## product bundle ``mainBundle`` passes ``verifyAppBundle``, every other
  ## bundle directly in it passes check 2, and ``pinned`` is compared with
  ## the folder identity (``readPlacedItemIdentityBytes``).
  commitStagedAppBundle(stageAppBundle(source, applicationsDir, bundleName,
    expected, policy, managedPrior, pinned, mainBundle))

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
