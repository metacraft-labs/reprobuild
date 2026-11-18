## The elevation pipe cannot be squatted by a process of the same user.
##
## Property protected (`reprobuild-pm` `spec/Elevation-And-Privileged-Operations.md`
## §"The IPC Channel And Authentication"): the parent creates the FIRST and
## ONLY instance of its pipe's name, under a DACL that admits Administrators
## and SYSTEM and leaves the owner read-control only. So
##
## 1. no process can add a second instance beside the parent's, where the
##    elevated broker could connect instead (`nMaxInstances = 1`; for a
##    non-elevated squatter also the DACL);
## 2. a name some process created first makes the parent's creation fail
##    instead of joining it (`FILE_FLAG_FIRST_PIPE_INSTANCE`);
## 3. a non-elevated process cannot open the pipe as a client, nor open it
##    to rewrite its DACL (the DACL and its `OWNER RIGHTS` entry).
##
## Recorded from `reprobuild-pm`
## `issues/2026-11-12-the-broker-ipc-handshake-does-not-authenticate-the-peer-that-matters.md`.
## The previous code created the pipe with `PIPE_UNLIMITED_INSTANCES`, no
## `FILE_FLAG_FIRST_PIPE_INSTANCE` and the default DACL, and every case
## here succeeded as an attack.
##
## This test calls only `createListeningChannel(<string>)` and
## `acceptAuthenticatedClient`, which have the same shape before and after
## the fix, and builds the pipe name itself, so it compiles against both.
## Case 1 isolates `nMaxInstances` when run elevated (the DACL admits an
## elevated squatter); case 3 needs a NON-elevated run and reports a skip,
## naming why, when elevated. Run it both ways.
##
## MOCKS: none. This process plays the squatter against the production
## channel code on the real named pipe file system.

import std/unittest

import repro_elevation
import repro_test_support/reasoned_skip

when defined(windows):
  import std/[os, strutils, sysrand, winlean]

  const
    PipeAccessDuplex = 0x00000003'i32
    PipeUnlimitedInstances = 255'i32
    PipeRejectRemoteClients = 0x00000008'i32
    OpenExisting = 3'i32
    GenericReadWrite = cast[int32](0xC0000000'u32)
    WriteDac = 0x00040000'i32

  proc freshId(): string =
    var bytes: array[16, byte]
    doAssert urandom(bytes)
    for b in bytes:
      result.add(toHex(int(b), 2).toLowerAscii())

  proc pipeName(id: string): string = "\\\\.\\pipe\\repro-elev-" & id

  proc squatInstance(name: string;
                     maxInstances = PipeUnlimitedInstances): Handle =
    ## What a same-user process would do: create an instance of `name`
    ## with the default DACL and, by default, room for more instances.
    createNamedPipe(newWideCString(name), PipeAccessDuplex,
      PipeRejectRemoteClients, maxInstances, 4096, 4096, 0, nil)

  proc openClient(name: string; access: int32): Handle =
    createFileW(newWideCString(name), access, 0, nil, OpenExisting, 0, 0)

  suite "elevation pipe: a same-user squatter gets nothing":
    test "a second instance cannot be created beside the parent's":
      let id = freshId()
      var ch = createListeningChannel(id)
      defer: ch.close()
      # Both instance counts: a squatter asking for unlimited instances
      # is refused on the count mismatch alone, so one asking for 1, the
      # parent's own count, is what shows the parent's limit holds.
      for maxInstances in [PipeUnlimitedInstances, 1'i32]:
        let squatter = squatInstance(pipeName(id), maxInstances)
        let err = osLastError()
        if squatter != INVALID_HANDLE_VALUE:
          discard closeHandle(squatter)
        checkpoint "elevated=" & $isProcessElevated() & " nMaxInstances=" &
          $maxInstances & " squatter CreateNamedPipeW status " & $int(err)
        check squatter == INVALID_HANDLE_VALUE

    test "the parent refuses a name somebody created first":
      let id = freshId()
      let squatter = squatInstance(pipeName(id))
      check squatter != INVALID_HANDLE_VALUE
      defer: discard closeHandle(squatter)
      expect EBrokerLaunch:
        var ch = createListeningChannel(id)
        ch.close()

    test "a non-elevated process can neither open the pipe nor rewrite its DACL":
      if isProcessElevated():
        skip("needs a non-elevated run; an elevated client is " &
          "admitted by design")
      else:
        let id = freshId()
        var ch = createListeningChannel(id)
        defer: ch.close()
        for access in [GenericReadWrite, WriteDac]:
          let client = openClient(pipeName(id), access)
          let err = osLastError()
          if client != INVALID_HANDLE_VALUE:
            discard closeHandle(client)
          checkpoint "access 0x" & toHex(access) & " status " & $int(err)
          check client == INVALID_HANDLE_VALUE
          check int(err) == ERROR_ACCESS_DENIED

    test "an elevated client is accepted":
      if not isProcessElevated():
        skip("needs an elevated run")
      else:
        let id = freshId()
        var ch = createListeningChannel(id)
        defer: ch.close()
        let client = openClient(pipeName(id), GenericReadWrite)
        check client != INVALID_HANDLE_VALUE
        acceptAuthenticatedClient(ch)
        if client != INVALID_HANDLE_VALUE:
          discard closeHandle(client)
else:
  suite "elevation pipe: a same-user squatter gets nothing":
    test "Windows named pipes only":
      skip("the squatting cases use Windows named pipes; this is not Windows")
