## A client refused for a missing daemon feature must be told WHICH features,
## WHICH two images disagree, that the matching version strings are not
## evidence, and how to fix it -- over the real handshake.
##
## reprobuild-pm issue 2026-10-13 ("`repro daemon status` reports
## `binary-version` as the daemon's identity, but two daemons differing by a
## required feature report the same string"), suggested direction 2. A daemon
## launched from a nix-store image and a CLI built locally both report
## `0.2.5`, while only the CLI knows a feature it then requires of the
## daemon. `connectUserDaemon` refused with exactly
##
##   user daemon does not advertise required feature: <first missing name>
##
## -- one feature (the loop raised on the first miss, so a client missing
## three learned of one per restart), no image path for either side even
## though the hello-ack had just carried the daemon's (`parseHelloAck`
## returned `daemon` and nothing read it), and no remedy. A reader holding
## that line next to two identical version strings had every reason to
## look somewhere other than the daemon image.
##
## WITHOUT THE FIX this file does not compile: it reads each feature's
## description from `userDaemonFeatureDescription`, which did not exist.
## With that one proc stubbed in, the first case fails on its content
## checks, because the old refusal was exactly
##
##   user daemon does not advertise required feature: substitute-routing
##
## so `lease-registry`, both descriptions, both image paths, both versions,
## the version-string warning and the `repro daemon restart` remedy are all
## absent. The success case passes either way; it is here so the refusal
## cannot be "fixed" by refusing more.
##
## WHY A FAKE DAEMON, and why it is not a mock of the code under test. The
## defect is a mismatch between two real builds, which a test cannot
## manufacture from one source tree: every real daemon this tree can start
## advertises exactly `UserDaemonFeatureFlags`. So the daemon side is an
## in-process accept loop that answers the hello with the REAL
## `helloAckBody` encoder over the REAL `IpcListener` / `writeFrame`
## transport, differing from `handleHello` only in the feature string it
## advertises -- the one input the defect is about. Everything on the
## client side -- `connectUserDaemon`, its hello, its ack parse and its
## refusal -- is the production path, unmodified. (The binary-cache
## suite's `t_a2_5_p6_daemon_substitute_ipc` embeds a daemon the same way
## for the same reason.)

import std/[atomics, os, random, strutils, unittest]

import repro_core
import repro_daemon_core/client
import repro_daemon_core/protocol

const
  FakeDaemonImage = "/nix/store/0a8j7cz0kccz6iplxrkz0vq250hbd8jk-" &
    "reprobuild-0.2.5/bin/.reprobuild-wrapped"
  # The daemon is one release behind in the only way that matters here: it
  # predates two features this client requires. Its version string is the
  # client's own, exactly as in the issue.
  ReducedFeatureFlags =
    "lifecycle,status,logs,shutdown,sessions,build-routing,build-events," &
    "watch-routing,watch-events,watch-sessions,dev-self-restart"

type
  FakeDaemonArgs = tuple[endpoint: string; connections: int]

var fakeDaemonReady: Atomic[bool]

proc runFakeDaemon(args: FakeDaemonArgs) {.thread.} =
  ## Serve `connections` hellos, each answered with a hello-ack that
  ## advertises `ReducedFeatureFlags` under the client's own version
  ## string, then exit. A bounded wait per connection keeps a broken test
  ## from wedging the suite.
  var listener = bindIpcListener(args.endpoint)
  defer: closeIpcListener(listener)
  fakeDaemonReady.store(true)
  for _ in 0 ..< args.connections:
    if not listener.waitForClient(30_000):
      return
    var conn = listener.acceptIpc()
    try:
      let hello = conn.readFrame(10_000)
      if hello.kind == udkHello:
        let daemon = binaryIdentity("repro", FakeDaemonImage, versionString())
        conn.writeFrame(udkHelloAck,
          helloAckBody(daemon, ReducedFeatureFlags, "fake-generation"),
          timeoutMs = 10_000)
        # Hold the connection until the client hangs up, so the client's
        # ack read can never race this side's close.
        try: discard conn.readFrame(10_000)
        except CatchableError: discard
    except CatchableError:
      discard
    conn.closeIpcConn()

proc fakeEndpoint(): string =
  randomize()
  when defined(windows):
    r"\\.\pipe\repro-missing-feature-" & $getCurrentProcessId() & "-" &
      $rand(999_999)
  else:
    # Short on purpose: AF_UNIX `sun_path` is 108 bytes.
    getTempDir() / ("rmf-" & $getCurrentProcessId() & "-" & $rand(99_999) &
      ".sock")

proc startFakeDaemon(connections: int): (Thread[FakeDaemonArgs], string) =
  let endpoint = fakeEndpoint()
  fakeDaemonReady.store(false)
  createThread(result[0], runFakeDaemon, (endpoint, connections))
  result[1] = endpoint
  for _ in 0 ..< 500:
    if fakeDaemonReady.load():
      return
    sleep(10)
  doAssert false, "fake daemon never bound " & endpoint

suite "a missing daemon feature is refused with a diagnosis":

  test "the refusal names every missing feature, both images, and the remedy":
    var (thread, endpoint) = startFakeDaemon(1)
    var message = ""
    try:
      let conn = connectUserDaemon(endpoint, commandMode = "status",
        requiredFeatures = ["build-routing", "substitute-routing",
                            "lease-registry"])
      conn.closeIpcConn()
    except UserDaemonClientError as exc:
      message = exc.msg
    joinThread(thread)
    checkpoint("refusal was:\n" & message)

    # Refused at all, and still under the wording existing matchers use.
    check message.contains("user daemon does not advertise required feature")
    # EVERY missing feature, not the first; the present one is not blamed.
    check message.contains("substitute-routing")
    check message.contains("lease-registry")
    check not message.contains("build-routing")
    # Each with what it is for, from the protocol's own table.
    check message.contains(userDaemonFeatureDescription("substitute-routing"))
    check message.contains(userDaemonFeatureDescription("lease-registry"))
    # Both images: the daemon's from the hello-ack, the client's own.
    check message.contains(FakeDaemonImage)
    check message.contains(getAppFilename())
    # Both version strings -- identical here, which is the trap -- and the
    # statement that identical strings are not evidence.
    check message.count(versionString()) >= 2
    check message.contains("same version string does not mean")
    # And the one command that fixes it.
    check message.contains("repro daemon restart")

  test "a daemon advertising everything required is accepted":
    var (thread, endpoint) = startFakeDaemon(1)
    var refused = ""
    try:
      let conn = connectUserDaemon(endpoint, commandMode = "status",
        requiredFeatures = ["build-routing", "watch-sessions"])
      conn.closeIpcConn()
    except UserDaemonClientError as exc:
      refused = exc.msg
    joinThread(thread)
    check refused == ""
