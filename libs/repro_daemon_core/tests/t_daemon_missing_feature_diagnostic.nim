## The unsupported-daemon diagnostic, and the feature table it reads, checked
## without a socket.
##
## reprobuild-pm issue 2026-10-13 ("`repro daemon status` reports
## `binary-version` as the daemon's identity, but two daemons differing by a
## required feature report the same string"), suggested direction 2: "when a
## required feature is absent, name the feature, the daemon's image path and
## the client's, and the remedy (`repro daemon restart`) ... it needs each
## `requiredFeatures` call site to carry a human-facing name for its
## feature." `connectUserDaemon` used to raise
##
##   user daemon does not advertise required feature: <first missing name>
##
## and nothing else. `t_daemon_missing_feature_refusal` drives that refusal
## through a real handshake; this file pins the two pieces it is built
## from, so each can fail on its own terms:
##
## * `userDaemonFeatureDescription` -- the human-facing name. The table is
##   keyed by the wire names in `UserDaemonFeatureFlags`, and the
##   completeness case below fails the moment a flag is added to that
##   constant without a description, which is the only point at which
##   anyone is guaranteed to be looking at both.
## * `unsupportedDaemonMessage` / `requireDaemonFeatures` -- the message
##   itself, from plain values.
##
## WITHOUT THE FIX this file does not compile: none of
## `userDaemonFeatureDescription`, `missingUserDaemonFeatures`,
## `unsupportedDaemonMessage` or an exported `requireDaemonFeatures`
## existed, and the old private `requireDaemonFeatures` had no daemon or
## client identity to report even if it had wanted to.
##
## No mocks: pure procs over the real constants and the real
## `BinaryIdentity` type the handshake carries.

import std/[sets, strutils, unittest]

import repro_daemon_core/client
import repro_daemon_core/protocol

proc advertisedFlags(): seq[string] =
  for raw in UserDaemonFeatureFlags.split(','):
    let name = raw.strip()
    if name.len > 0:
      result.add(name)

const
  DaemonImage = "/nix/store/0a8j7cz0kccz6iplxrkz0vq250hbd8jk-" &
    "reprobuild-0.2.5/bin/.reprobuild-wrapped"
  ClientImage = "/home/u/reprobuild-sds/local-out/reprobuild"

let
  daemonId = BinaryIdentity(name: "repro", path: DaemonImage,
    version: "0.2.5")
  clientId = BinaryIdentity(name: "repro", path: ClientImage,
    version: "0.2.5")

suite "every advertised daemon feature has a human-facing description":

  test "no flag in UserDaemonFeatureFlags falls back to the unknown text":
    # THE COMPLETENESS GUARD. A new flag added to the advertised constant
    # without a table entry fails here, by name.
    let flags = advertisedFlags()
    check flags.len >= 13
    for name in flags:
      checkpoint("flag: " & name)
      let description = userDaemonFeatureDescription(name)
      check description.len > 0
      check description != unknownUserDaemonFeatureDescription(name)

  test "descriptions are distinct, so a list of them is not ambiguous":
    var seen = initHashSet[string]()
    for name in advertisedFlags():
      let description = userDaemonFeatureDescription(name)
      check description notin seen
      seen.incl(description)

  test "an unknown name gets a fallback that still names it":
    # A client newer than this table (or a typo at a call site) must still
    # produce a readable refusal, never an empty bullet.
    let fallback = userDaemonFeatureDescription("service-instance-registry-v9")
    check fallback == unknownUserDaemonFeatureDescription(
      "service-instance-registry-v9")
    check fallback.len > 0

suite "missing features are computed against the advertised list":

  test "all missing features, in the order required, without duplicates":
    check missingUserDaemonFeatures("lifecycle, status,build-routing",
      ["build-routing", "lease-registry", "substitute-routing",
       "lease-registry"]) == @["lease-registry", "substitute-routing"]

  test "a feature name is matched whole, not as a substring":
    # `build-events` must not satisfy `build`, nor `watch` satisfy
    # `watch-sessions`; the advertised list is comma-separated names.
    check missingUserDaemonFeatures("build-events,watch",
      ["build", "watch-sessions"]) == @["build", "watch-sessions"]

  test "nothing required, or everything present, means nothing missing":
    check missingUserDaemonFeatures(UserDaemonFeatureFlags, []).len == 0
    check missingUserDaemonFeatures(UserDaemonFeatureFlags,
      advertisedFlags()).len == 0

suite "the unsupported-daemon message is a diagnosis, not just a name":

  test "it names every missing feature, both images, both versions, the fix":
    let message = unsupportedDaemonMessage(
      ["substitute-routing", "lease-registry"], daemonId, clientId)
    checkpoint(message)
    # The prefix existing matchers and readers key on.
    check message.startsWith(
      "user daemon does not advertise required feature")
    for name in ["substitute-routing", "lease-registry"]:
      check message.contains(name)
      check message.contains(userDaemonFeatureDescription(name))
    check message.contains(DaemonImage)
    check message.contains(ClientImage)
    check message.count("0.2.5") >= 2
    check message.contains("same version string does not mean")
    check message.contains("repro daemon restart")

  test "a single missing feature keeps the original first line verbatim":
    # Exactly the text `connectUserDaemon` used to raise, as the message's
    # first line, so anything that matched the full old line still does.
    let message = unsupportedDaemonMessage(["lease-registry"], daemonId,
      clientId)
    check message.splitLines()[0] ==
      "user daemon does not advertise required feature: lease-registry"

  test "an image path the handshake did not carry is said to be unknown":
    # A pre-identity daemon, or a client whose own path the platform could
    # not answer: an empty field would read as a blank, not as a gap.
    let message = unsupportedDaemonMessage(["lease-registry"],
      BinaryIdentity(), clientId)
    check message.contains("<unknown>")

  test "requireDaemonFeatures raises only when something is missing":
    # Nothing missing: no raise, for the empty requirement too.
    requireDaemonFeatures(UserDaemonFeatureFlags,
      ["build-routing", "lease-registry"], daemonId, clientId)
    requireDaemonFeatures("", [], daemonId, clientId)
    var raised = ""
    try:
      requireDaemonFeatures("lifecycle,status", ["status", "lease-registry"],
        daemonId, clientId)
    except UserDaemonClientError as exc:
      raised = exc.msg
    check raised == unsupportedDaemonMessage(["lease-registry"], daemonId,
      clientId)
