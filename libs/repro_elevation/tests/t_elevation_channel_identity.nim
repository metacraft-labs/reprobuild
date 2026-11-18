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
## This file holds the command line and its parsing, and (Windows) the
## broker's hold on its parent: a parent killed so its pipe name could be
## re-created is refused. The attack on the pipe itself is
## `t_elevation_pipe_squatting.nim`, kept apart so that it also compiles
## against the code before the fix and can be shown red there.
##
## MOCKS: none.

import std/[strutils, unittest]

import repro_elevation

suite "elevation channel: the name carries no secret":
  test "the pipe name is derived from the channel id, never the nonce":
    let channelId = generateChannelId()
    let nonce = generateNonce()
    check channelId != nonce
    let args = brokerCommandArgs(channelId, nonce, 4242,
      133000000000000000'u64)
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
          "--channel", bad, "--token", "t", "--parent-pid", "4242",
          "--parent-start", "1"])
      expect EProtocol:
        discard pipeNameForChannel(bad)

  test "the broker refuses to start without the parent's identity":
    # Without it the broker could not tell a live parent's pipe from one
    # a squatter created after killing the parent.
    for args in [@["--parent-pid", "4242"], @["--parent-start", "1"],
                 @["--parent-pid", "0", "--parent-start", "1"],
                 @["--parent-pid", "x", "--parent-start", "1"]]:
      expect EProtocol:
        discard parseBrokerModeArgs(@["--privileged-broker", "--channel",
          "0123456789abcdef0123456789abcdef", "--token", "t"] & args)

  test "channel ids are fresh":
    check generateChannelId() != generateChannelId()
    check isChannelId(generateChannelId())

when defined(windows):
  import std/osproc

  suite "elevation channel: the broker holds its parent":
    test "a process with the parent's pid but another creation time is refused":
      let me = currentProcessIdentity()
      expect EChannelAuth:
        var w = watchParent(me.pid, me.start + 1)
        w.close()

    test "the launching parent is accepted while it lives":
      let me = currentProcessIdentity()
      var w = watchParent(me.pid, me.start)
      requireParentAlive(w)
      w.close()

    test "a parent that died before the connect is refused":
      # The attack: kill the parent so its pipe name is released, then
      # re-create the name. The broker must notice the parent is gone.
      var child = startProcess("cmd.exe", args = ["/c", "ping -n 30 127.0.0.1"],
        options = {poUsePath})
      let pid = child.processID
      var w = watchParent(pid, processStartTimeOf(pid))
      requireParentAlive(w)
      child.terminate()
      discard child.waitForExit()
      child.close()
      expect EChannelAuth:
        requireParentAlive(w)
      w.close()
