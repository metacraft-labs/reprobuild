## Refuses to publish a macOS application prefix that no longer verifies.
##
## A prefix holding an application is the realization of a pinned archive: the
## bundle in it passed the trust checks when it was realized. An application's
## own updater can rewrite a writable copy afterwards, and a prefix published
## from such a copy would serve the rewritten bytes under the pinned archive's
## cache key to every host that substitutes it. So every publish of a prefix
## re-runs the checks on the bytes about to be uploaded, and a prefix that
## fails is refused before anything leaves the machine.
##
## The prefix says what it holds in its adapter receipt
## (``.reprobuild-tarball-receipt.json``): ``appBundle`` carries the item the
## record places and the identity the record declares. A prefix written before
## that field existed still names its executable
## (``Name.app/Contents/MacOS/Name``), which locates the bundle; its identity
## is then read from the bundle itself, so the signature, the Developer ID
## chain and the notarization are still checked, though not the version
## against the record.
##
## Trust is never relaxed here. A caller that realizes fixture bundles with a
## relaxed policy does not publish them (``publishToolPrefix``).
import std/[json, os, strutils]

when defined(macosx):
  import repro_home_resources/drivers/app_bundle

const AdapterReceiptName = ".reprobuild-tarball-receipt.json"

when not defined(macosx):
  proc appPrefixPublishRefusal*(prefixDir: string): string =
    ## Applications are macOS bundles; no other host verifies one.
    discard prefixDir
    ""
else:
  proc appPrefixPublishRefusal*(prefixDir: string;
                                policy: AppTrustPolicy = {}): string =
    ## "" when ``prefixDir`` holds no application, or holds one that passes
    ## trust checks 1 to 5; otherwise the reason the prefix must not be
    ## published, naming the failed check. ``policy`` is for tests that build
    ## their fixture bundles at test time (never signed by Apple); production
    ## callers leave it empty, and ``publishInProcess`` does.
    let receiptPath = prefixDir / AdapterReceiptName
    if not fileExists(receiptPath):
      return ""
    var receipt: JsonNode
    try:
      receipt = parseFile(receiptPath)
    except CatchableError:
      return ""
    var item = ""
    var expected = AppBundleExpectation()
    let declared = receipt{"appBundle"}
    if declared != nil and declared.kind == JObject:
      item = declared{"item"}.getStr()
      expected = AppBundleExpectation(bundleId: declared{"bundleId"}.getStr(),
        version: declared{"version"}.getStr(),
        teamId: declared{"teamId"}.getStr())
    else:
      let executable = receipt{"declaredExecutablePath"}.getStr()
      let marker = executable.find(".app/")
      if marker < 0:
        return ""
      item = executable[0 ..< marker + 4]
    if item.len == 0 or item.contains("..") or isAbsolute(item):
      return "the prefix names an application item " & item.escape &
        " that is not a relative path inside it"
    let bundle = prefixDir / item
    if symlinkExists(bundle):
      return "the application item " & item.escape &
        " of the prefix is a symbolic link"
    try:
      if expected.bundleId.len == 0:
        # No record to compare against: hold the bundle to its own claimed
        # identity, so the signature, Developer ID chain and notarization
        # checks (2 to 5) still run for the team it names.
        let identity = readAppBundleIdentity(bundle)
        expected = AppBundleExpectation(bundleId: identity.bundleId,
          teamId: identity.teamId)
      discard verifyAppBundle(bundle, expected, policy)
    except EAppBundleRefused as err:
      return "the application prefix " & prefixDir &
        " fails verification (" & err.check & "): " & err.msg
