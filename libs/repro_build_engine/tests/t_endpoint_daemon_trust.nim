## Endpoint-keyed daemon trust (Dev-Env-Warm-Entry.md §3).
##
## On a socket-activated host (NixOS's nix-daemon, among others) the kernel
## reports the ACTIVATOR, pid 1, as the peer of every service it activated.
## A pid cannot say which service a monitored client reached, so DA-4's
## pid-keyed trust cannot attribute a connection to the Nix daemon at all.
## The identity used instead is the ENDPOINT: a socket whose whole path only
## root can write, dialled by the client (io-mon records the `sun_path`), and
## accepted by a uid-0 peer on that very connection.
##
## What each case pins:
##   * ownership: a socket a user can create is refused; a root-controlled
##     socket passes; the stock macOS Nix daemon's writable ancestry is refused;
##   * grading: a loss is attributed only when the dialled path is the trusted
##     endpoint AND its peer uid is 0. Another endpoint behind the same pid 1,
##     or the trusted path with a non-root peer, stays a loss;
##   * revalidation: trust built from a path that no longer holds is dropped
##     before it can forgive anything.
##
## MOCKS: none. Grading uses this host's real Nix daemon socket on Linux,
## or its real Nix GC socket on macOS: the stock macOS daemon's symlink
## traverses group-writable `/private/var/run`, whereas the GC socket has
## root-controlled ancestry. Only absence decides a fixture skip; failed
## ownership is a test failure. This suite tests endpoint attribution, not
## either service's protocol. Monitor records are hand-built in the exact shape io-mon writes (see
## io-mon `recordIpcConnect` and `unmonitoredSubtreeLossDetails`): the grading
## under test is the engine's, and io-mon's own suite covers the shim.

import std/[net, os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_build_engine
import io_mon/[capabilities, types]

const
  NixDaemonSocket = "/nix/var/nix/daemon-socket/socket"
  GradingSocket = when defined(macosx): "/nix/var/nix/gc-socket/socket"
                  else: NixDaemonSocket

proc socketPresent(path: string): bool =
  # Socket presence is independent of the production ownership verdict.
  try:
    discard getFileInfo(path, followSymlink = false)
    result = true
  except OSError:
    result = false

proc ipcLoss(path: string; peerUid: int): MonitorRecord =
  ## The event-loss record io-mon writes for an out-of-tree IPC peer, with the
  ## activator (pid 1) as the peer, as on a socket-activated host.
  MonitorRecord(kind: mrEventLoss, observationKind: moEventLoss,
    detail: UnmonitoredSubtreeLossDetailPrefix & IpcPeerLossDetailPrefix &
      "pid=100 peer=1 peerstart= peeruid=" & $peerUid & " path=" & path)

proc grade(records: seq[MonitorRecord];
           endpoints: seq[TrustedEndpoint]):
    tuple[status: MonitorEvidenceStatus, diagnostics: seq[string]] =
  var evidence: PathSetEvidence
  var seen: EvidenceSeenSets
  var attribution = initMonitorPeerAttribution([], endpoints)
  # A real backend profile, so the capture-scope grade cannot be what decides
  # the status; only the IPC attribution varies between cases.
  result.status = foldMonitorRecordsEvidence(
    profileRecords(defaultHooksMonitorProfile()) & records, getTempDir(),
    evidence, seen, attribution)
  result.diagnostics = evidence.diagnostics

proc trustedSocket(): TrustedEndpoint =
  TrustedEndpoint(endpoint: GradingSocket,
    canonical: endpointRootOwned(GradingSocket).canonical,
    name: "nix-endpoint", contribution: tdcContentAlreadyKeyed)

suite "endpoint-keyed daemon trust":
  test "a socket an unprivileged user can create is not root-owned":
    let dir = createTempDir("repro-endpoint-", "")
    defer: removeDir(dir)
    let path = dir / "d.sock"
    let server = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP)
    server.bindUnix(path)
    server.listen()
    defer: server.close()
    let owned = endpointRootOwned(path)
    check not owned.ok
    check owned.detail.len > 0

  test "the real Nix daemon socket follows the ownership policy":
    if not socketPresent(NixDaemonSocket):
      skip("no multi-user Nix daemon socket on this host")
    else:
      let owned = endpointRootOwned(NixDaemonSocket)
      var stockMacWritableAncestor = false
      when defined(macosx):
        # Inspect the installation independently of the ownership function:
        # a failed production check must never decide its own expectation.
        stockMacWritableAncestor =
          expandFilename(NixDaemonSocket) == "/private/var/run/nix-daemon.socket" and
          fpGroupWrite in getFilePermissions("/private/var/run")
      if stockMacWritableAncestor:
        check not owned.ok
        check owned.detail == "/private/var/run is writable by group or others"
        let stale = TrustedEndpoint(endpoint: NixDaemonSocket,
          canonical: expandFilename(NixDaemonSocket),
          name: "nix-daemon", contribution: tdcContentAlreadyKeyed)
        check revalidatedTrustedEndpoints(@[stale]).len == 0
        check grade(@[ipcLoss(NixDaemonSocket, 0)], @[stale]).status ==
          mesUnknownScopeLoss
      else:
        checkpoint(owned.detail)
        check owned.ok
        check owned.canonical.len > 0

  test "the real grading socket has root-controlled ancestry":
    if not socketPresent(GradingSocket):
      skip("no multi-user Nix grading socket on this host")
    else:
      let owned = endpointRootOwned(GradingSocket)
      checkpoint(owned.detail)
      check owned.ok
      check owned.canonical.len > 0

  test "a loss on the trusted endpoint with a root peer is attributed":
    if not socketPresent(GradingSocket):
      skip("no multi-user Nix grading socket on this host")
    else:
      let graded = grade(@[ipcLoss(GradingSocket, 0)], @[trustedSocket()])
      check graded.status == mesComplete
      var named = false
      for d in graded.diagnostics:
        if "by endpoint " & GradingSocket in d: named = true
      check named

  test "another endpoint behind the same activator pid stays a loss":
    if not socketPresent(GradingSocket):
      skip("no multi-user Nix grading socket on this host")
    else:
      let graded = grade(@[ipcLoss(GradingSocket, 0),
        ipcLoss("/run/some-other-service.sock", 0)], @[trustedSocket()])
      check graded.status == mesUnknownScopeLoss

  test "the trusted path with a non-root peer stays a loss":
    if not socketPresent(GradingSocket):
      skip("no multi-user Nix grading socket on this host")
    else:
      let graded = grade(@[ipcLoss(GradingSocket, 1000)], @[trustedSocket()])
      check graded.status == mesUnknownScopeLoss

  test "trust whose path no longer holds is dropped at grading time":
    # A TrustedEndpoint naming a user-owned socket (as if its ownership had
    # changed since the check) must not survive revalidation.
    let dir = createTempDir("repro-endpoint-", "")
    defer: removeDir(dir)
    let path = dir / "d.sock"
    let server = newSocket(net.AF_UNIX, net.SOCK_STREAM, net.IPPROTO_IP)
    server.bindUnix(path)
    server.listen()
    defer: server.close()
    let stale = TrustedEndpoint(endpoint: path, canonical: path,
      name: "nix-daemon", contribution: tdcContentAlreadyKeyed)
    check revalidatedTrustedEndpoints(@[stale]).len == 0
    let graded = grade(@[ipcLoss(path, 0)], @[stale])
    check graded.status == mesUnknownScopeLoss
