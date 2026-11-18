## The elevation channel's name carries no secret, and the parent's pipe
## is the only instance of that name.
##
## Property protected (`reprobuild-pm` `spec/Elevation-And-Privileged-Operations.md`
## §"The IPC Channel And Authentication"):
##
## * The pipe name is public: any process can list `\\.\pipe\`. So the
##   nonce the broker checks in `Hello` is never part of the name, and
##   the broker refuses a `--channel` that is not a channel id (it can
##   only ever open a `repro-elev-` pipe).
## * The parent creates the FIRST and ONLY instance of the name, under a
##   DACL that admits Administrators and SYSTEM alone. A process of the
##   same user cannot add a second instance beside it (where the elevated
##   broker could connect to the squatter instead of the parent), and the
##   parent refuses, rather than joins, a name somebody created first.
## * A non-elevated process cannot open the pipe as a client.
##
## Recorded from `reprobuild-pm`
## `issues/2026-11-12-the-broker-ipc-handshake-does-not-authenticate-the-peer-that-matters.md`:
## the pipe was `repro-elev-<nonce>`, created with
## `PIPE_UNLIMITED_INSTANCES`, no `FILE_FLAG_FIRST_PIPE_INSTANCE` and the
## default DACL, so a same-user process could read the nonce from the
## pipe list and create a second instance for the broker to reach.
##
## The Windows cases are the attack itself: this process plays the
## same-user squatter against the production `createListeningChannel`.
## On the code before the fix the squatter's `CreateNamedPipeW` succeeds
## and the parent's creation joins a pre-existing name.
##
## MOCKS: none. The production channel code runs against the real named
## pipe file system. The POSIX build runs the platform-pure cases only;
## the POSIX transport is not implemented yet (`ipc.nim`).

import std/[strutils, unittest]

import repro_elevation

suite "elevation channel: the name carries no secret":
  test "the pipe name is derived from the channel id, never the nonce":
    let channelId = generateChannelId()
    let nonce = generateNonce()
    check channelId != nonce
    let args = brokerCommandArgs(channelId, nonce)
    let channelArg = args[args.find(BrokerChannelFlag) + 1]
    let tokenArg = args[args.find(BrokerTokenFlag) + 1]
    check tokenArg == nonce
    check channelArg == channelId
    let pipeName = pipeNameForChannel(channelArg)
    check pipeName.startsWith(ElevationPipePrefix)
    check nonce notin pipeName

  test "the broker refuses a --channel that is not a channel id":
    for bad in ["\\\\.\\pipe\\someone-elses-pipe", "", "xyz",
                "0123456789ABCDEF0123456789ABCDEF",
                "0123456789abcdef0123456789abcde"]:
      expect EProtocol:
        discard parseBrokerModeArgs(@["--privileged-broker",
          "--channel", bad, "--token", "t"])
      expect EProtocol:
        discard pipeNameForChannel(bad)

  test "channel ids are fresh":
    check generateChannelId() != generateChannelId()
    check isChannelId(generateChannelId())

when defined(windows):
  import std/[os, winlean]

  const
    PipeAccessDuplex = 0x00000003'i32
    PipeUnlimitedInstances = 255'i32
    PipeRejectRemoteClients = 0x00000008'i32
    OpenExisting = 3'i32
    GenericReadWrite = cast[int32](0xC0000000'u32)

  proc squatInstance(name: string): Handle =
    ## What a same-user process would do: create an instance of `name`
    ## with the default DACL and room for more instances.
    createNamedPipe(newWideCString(name), PipeAccessDuplex,
      PipeRejectRemoteClients, PipeUnlimitedInstances, 4096, 4096, 0, nil)

  suite "elevation channel: the parent's pipe is the only instance":
    test "a second instance cannot be created beside the parent's":
      let channelId = generateChannelId()
      var ch = createListeningChannel(channelId)
      defer: ch.close()
      let squatter = squatInstance(pipeNameForChannel(channelId))
      let err = osLastError()
      if squatter != INVALID_HANDLE_VALUE:
        discard closeHandle(squatter)
      check squatter == INVALID_HANDLE_VALUE
      checkpoint "squatter CreateNamedPipeW status " & $int(err)

    test "the parent refuses a name somebody created first":
      let channelId = generateChannelId()
      let squatter = squatInstance(pipeNameForChannel(channelId))
      check squatter != INVALID_HANDLE_VALUE
      defer: discard closeHandle(squatter)
      expect EBrokerLaunch:
        var ch = createListeningChannel(channelId)
        ch.close()

    test "only an elevated process can open the pipe as a client":
      let channelId = generateChannelId()
      var ch = createListeningChannel(channelId)
      defer: ch.close()
      let client = createFileW(newWideCString(pipeNameForChannel(channelId)),
        GenericReadWrite, 0, nil, OpenExisting, 0, 0)
      let err = osLastError()
      if isProcessElevated():
        # The elevated case: the client is admitted, and the parent's
        # elevation check accepts it.
        check client != INVALID_HANDLE_VALUE
        acceptAuthenticatedClient(ch)
      else:
        check client == INVALID_HANDLE_VALUE
        check int(err) == ERROR_ACCESS_DENIED
      if client != INVALID_HANDLE_VALUE:
        discard closeHandle(client)
