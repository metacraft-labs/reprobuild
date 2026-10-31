## A daemon that refuses to start releases the TPM it had already
## opened.
##
## ## The claim
##
## `serve` opens the root of trust while it is still a start-up path
## that can refuse: the transport is a real connection and the readiness
## probe is a real pair of TPM commands, so a machine that cannot attest
## says so before it is serving. That ordering is deliberate, and it
## means the configuration checks that follow run with a TPM already
## open — a device handle and, for the device source, whatever the
## backend later loads into the TPM.
##
## Every exit from `serve` therefore has to release it, including the
## exits that are refusals. Two of them are refusals of a configuration
## the daemon only discovers after the backend exists:
##
## 1. **The identity is unusable.** The claims the agent would answer
##    with are checked when the agent is constructed, so a `serve` with
##    no generation, config fingerprint or root hash configured is
##    refused there, after the TPM has been opened.
## 2. **The listen address cannot be taken.** The socket is bound at
##    start-up rather than lazily, so a port that is already in use is
##    refused there, also after the TPM has been opened.
##
## A refusal that left the TPM open is worse than it sounds. The device
## admits one caller at a time, so the next thing to ask for it is
## refused as well — and the daemon that is holding it is not running,
## which is the one state in which nobody thinks to look at it. On the
## device source it also leaves a transient object loaded in a TPM
## nobody is talking to any more, so a machine that restarts its agent
## in a loop spends its object slots a restart at a time.
##
## ## How the release is observed
##
## By this process's own descriptors, across the call, narrowed to the
## address family the TPM endpoint is in: a `unix:` transport is an
## `AF_UNIX` socket, and the start-up paths below open nothing else in
## that family. Narrowing is what makes the observation about the
## backend rather than about everything a refusal happens to touch —
## case 2 fails precisely because a socket could not be bound, and that
## attempt's own descriptor is not this file's subject.
##
## The alternative would be to ask the software TPM whether its client
## went away. It admits one client at a time, so a second conversation
## with a leaked first one does not fail — it WAITS, for the whole read
## bound, which would make this file a minute long and would report the
## leak as a timeout.
##
## ## Mocking
##
## None. A real `swtpm` process, a real Unix socket, a real readiness
## probe (`TPM2_PCR_Read`) over real TPM commands, and the agent's own
## entry point — `runAttestationAgent`, the one `attestation-agent`
## calls with its command line — driving its own option parser and its
## own options-to-backend mapping. No daemon process is spawned: the
## calls below run in THIS process, which is what makes the descriptors
## observable at all.
##
## The event log is an empty file. The readiness probe requires a log to
## be PRESENT and reads no byte of it, and nothing here takes a quote,
## so a composed log would add bytes no case looks at. What a quote
## proves, and what a log has to say for it to mean anything, is
## `t_tpm_quote_comes_from_the_tpm`'s subject.
##
## ## There is no skip in this file
##
## When a software TPM cannot be started this case FAILS and names the
## remedy. `swtpm` is part of this repository's development toolchain; a
## directory holding it may also be named in `REPROOS_SWTPM_BIN`.

import std/[net, os, osproc, posix, strutils, times, unittest]

import repro_attest
import repro_attest_agent/cli

const
  SwtpmBinEnv = "REPROOS_SWTPM_BIN"
    ## A directory holding `swtpm`, for a host where it is not on PATH.

  SwtpmStartAttempts = 200
  SwtpmStartIntervalMs = 50

  MaxProbedDescriptor = 1024
    ## `FD_SETSIZE` on Linux, and far above anything this process holds.

  ExitRefusal = 2
    ## `attestation-agent`'s exit code for a usage error or a refusal.
  ExitRuntimeFailure = 1
    ## Its exit code for a runtime failure, which is what an address it
    ## cannot listen on is.

  VerityRootHashForTests = "3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a" &
                           "3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a"
    ## 64 lower-case hex characters, which is the only thing the claim
    ## validator asks of it. It identifies nothing: no image was built
    ## here and no verifier is given this document.

type
  LiveTpm = ref object
    ## One software TPM, its socket, and the conversation that started
    ## it.
    dir: string
    dataSocket: string
    ctrlSocket: string
    process: Process
    transport: Tpm2Transport

proc swtpmCommand(): string =
  let dir = getEnv(SwtpmBinEnv)
  if dir.len > 0: dir / "swtpm" else: "swtpm"

proc stopLiveTpm(t: LiveTpm) =
  ## Unconditional teardown: the socket, the process and the state
  ## directory, whatever happened above. A software TPM left running
  ## holds a socket in a temporary directory that nothing will ever
  ## clean up.
  if t == nil: return
  if t.transport != nil:
    try: t.transport.transportClose()
    except CatchableError: discard
    t.transport = nil
  if t.process != nil:
    try:
      if t.process.running:
        t.process.terminate()
        for _ in 0 ..< 40:
          if not t.process.running: break
          sleep(50)
        if t.process.running: t.process.kill()
      discard t.process.waitForExit()
    except CatchableError: discard
    try: t.process.close()
    except CatchableError: discard
    t.process = nil
  try: removeDir(t.dir)
  except CatchableError: discard

proc startLiveTpm(): LiveTpm =
  ## Start one `swtpm` over a Unix socket and return once it has
  ## answered a command.
  ##
  ## Readiness is "it answered `TPM2_Startup`", not "its socket file
  ## appeared". The socket is created before the emulator is ready to
  ## converse, so waiting on the path is a race that fails inside the
  ## first real command — and it fails there as a transport error, which
  ## reads like a broken endpoint rather than like a slow start.
  result = LiveTpm()
  result.dir = getTempDir() / ("repro-agent-release-tpm-" &
                               $getCurrentProcessId() & "-" &
                               $epochTime().int64)
  removeDir(result.dir)
  createDir(result.dir)
  result.dataSocket = result.dir / "tpm-data.sock"
  result.ctrlSocket = result.dir / "tpm-ctrl.sock"

  let command = swtpmCommand()
  try:
    result.process = startProcess(command, args = @[
        "socket", "--tpm2",
        "--tpmstate", "dir=" & result.dir,
        "--server", "type=unixio,path=" & result.dataSocket,
        "--ctrl", "type=unixio,path=" & result.ctrlSocket,
        # The emulator starts its own TPM, so nothing here has to speak
        # the control channel's protocol to initialise it.
        "--flags", "not-need-init,startup-clear",
        # To a file, because the emulator writes to stderr while it runs
        # and that would land in the middle of this suite's output.
        "--log", "file=" & (result.dir / "swtpm.log")],
      # Held as a direct child rather than daemonised: teardown is then
      # a kill on a handle this process owns, and a daemon would inherit
      # every descriptor this process had open.
      options = {poUsePath, poParentStreams}, workingDir = result.dir)
  except CatchableError as e:
    let dir = result.dir
    removeDir(dir)
    raise newException(IOError,
      "could not start a software TPM (" & command & "): " & e.msg &
      ". It is part of this repository's development toolchain; enter the " &
      "development shell, or name the directory holding it in " &
      SwtpmBinEnv & ".")

  for _ in 0 ..< SwtpmStartAttempts:
    try:
      result.transport = newTpm2Transport("unix:" & result.dataSocket)
      tpmStartupClear(result.transport)
      return
    except CatchableError:
      if result.transport != nil:
        try: result.transport.transportClose()
        except CatchableError: discard
        result.transport = nil
      if not result.process.running: break
      sleep(SwtpmStartIntervalMs)

  var detail = ""
  try: detail = readFile(result.dir / "swtpm.log").strip()
  except CatchableError: discard
  let endpoint = result.dataSocket
  stopLiveTpm(result)
  raise newException(IOError,
    "the software TPM never answered on " & endpoint &
    (if detail.len > 0: "; it said: " & detail
     else: "; it printed nothing, which usually means " & command &
           " is not on this host") &
    ". Nothing was measured, so this is a failure and not a skip.")

proc handOverToTheDaemon(t: LiveTpm) =
  ## Close the setup conversation before the daemon's own begins.
  ##
  ## A software TPM's data channel serves ONE client, so two open
  ## conversations would leave the second waiting behind the first —
  ## and `serve` opens its own, because that is what a daemon told
  ## `--tpm-device` does.
  if t.transport != nil:
    t.transport.transportClose()
    t.transport = nil

proc unixSocketDescriptors(): seq[cint] =
  ## Every descriptor in this process that names an `AF_UNIX` socket.
  ##
  ## `getsockname` answers for a connected socket as well as a bound
  ## one — an unnamed `AF_UNIX` address is still an `AF_UNIX` address —
  ## so a client connection is visible here although it has no path of
  ## its own. Descriptors that are not sockets, and sockets in other
  ## families, are skipped: see the file header for why the observation
  ## is narrowed.
  result = @[]
  for fd in cint(0) ..< cint(MaxProbedDescriptor):
    var address: Sockaddr_storage
    var length = SockLen(sizeof(address))
    if getsockname(SocketHandle(fd), cast[ptr SockAddr](addr address),
                   addr length) == 0 and
       cint(address.ss_family) == AF_UNIX:
      result.add fd

proc descriptorsOpenedBy(before: seq[cint]): seq[cint] =
  result = @[]
  for fd in unixSocketDescriptors():
    if fd notin before: result.add fd

proc calibrateAgainst(opts: Options) =
  ## Show, for THIS configuration, that the backend really is opened —
  ## and that the observation above can see it.
  ##
  ## Without this the cases below could pass vacuously. A `serve` whose
  ## endpoint was unreachable would refuse in `newDriverFor`, with the
  ## same exit code as the identity refusal in case 1, having opened
  ## nothing — so "no descriptor was left behind" would be true of a
  ## run that never reached the code under test. So the same options are
  ## turned into a backend here first, through the same mapping `serve`
  ## uses, and both halves are asserted: opening adds exactly one
  ## `AF_UNIX` descriptor, and closing takes it away again.
  ##
  ## `doAssert` rather than `check`, because a failure here means the
  ## case that follows would prove nothing, and continuing to it would
  ## report a pass.
  let before = unixSocketDescriptors()
  let driver = newDriverFor(opts)
  let opened = descriptorsOpenedBy(before)
  doAssert opened.len == 1,
    "the TPM endpoint this case configures is " & $opened.len &
    " AF_UNIX descriptors rather than one, so the observation below " &
    "would not be about the backend"
  driver.driverClose()
  doAssert descriptorsOpenedBy(before).len == 0,
    "closing the backend did not release its descriptor, so the " &
    "observation below cannot tell a released endpoint from a leaked one"

proc occupiedPort(): (Socket, Port) =
  ## A listening socket this process keeps, and the port it holds.
  ##
  ## Bound to an ephemeral port rather than a fixed one, so two runs of
  ## this suite on one host cannot collide — and read back from the
  ## socket, so the port is known to be taken rather than assumed to be.
  let holder = newSocket(buffered = false)
  holder.bindAddr(Port(0), "127.0.0.1")
  holder.listen()
  (holder, getLocalAddr(holder)[1])

suite "a refused start-up releases the root of trust":

  test "an identity the agent refuses does not keep the TPM open":
    let tpm = startLiveTpm()
    try:
      let logPath = tpm.dir / "binary_bios_measurements"
      writeFile(logPath, "")
      handOverToTheDaemon(tpm)

      # No generation, no config fingerprint and no root hash: the
      # agent's constructor refuses claims it could not answer with,
      # and it refuses them after `serve` has opened the TPM.
      #
      # `--provisioned-secrets-dir=` is empty so that no secret
      # directory is required of the host. The store is built before
      # the backend, so it is not on the path under test.
      let args = @[
        "serve",
        "--tier=tpm",
        "--tpm-device=unix:" & tpm.dataSocket,
        "--tpm-event-log=" & logPath,
        "--provisioned-secrets-dir="]
      calibrateAgainst(parseArgs(args))

      let before = unixSocketDescriptors()
      let code = runAttestationAgent(args)
      check code == ExitRefusal
      check descriptorsOpenedBy(before).len == 0
    finally:
      stopLiveTpm(tpm)

  test "a listen address it cannot take does not keep the TPM open":
    let tpm = startLiveTpm()
    var holder: Socket
    try:
      let logPath = tpm.dir / "binary_bios_measurements"
      writeFile(logPath, "")
      handOverToTheDaemon(tpm)

      var port: Port
      (holder, port) = occupiedPort()

      # A usable identity this time, so the agent is constructed and
      # the refusal comes from the socket: the address is held by this
      # process for as long as the call runs.
      let args = @[
        "serve",
        "--tier=tpm",
        "--tpm-device=unix:" & tpm.dataSocket,
        "--tpm-event-log=" & logPath,
        "--provisioned-secrets-dir=",
        "--generation=start-up-refusal-gate",
        "--config-fingerprint=start-up-refusal-gate",
        "--verity-root-hash=" & VerityRootHashForTests,
        "--listen=127.0.0.1:" & $uint16(port)]
      calibrateAgainst(parseArgs(args))

      let before = unixSocketDescriptors()
      let code = runAttestationAgent(args)
      check code == ExitRuntimeFailure
      check descriptorsOpenedBy(before).len == 0
    finally:
      if holder != nil:
        try: holder.close()
        except CatchableError: discard
      stopLiveTpm(tpm)
