## Unit tests for the volatile-runtime input decision in
## ``repro_core/paths``: under ``/run`` a recorded input is judged by what is
## on disk, not by its prefix.
##
## The contract (``dropsAsVolatileInput`` and ``volatileInputVerdict``):
##
## * A path the prefix rule does not drop (``dropsAsVolatileRuntimeState``
##   false: outside the volatile prefixes, ``/run/user/<uid>``, ``/run/media``,
##   the invocation's own trees) is kept without looking at the disk.
## * ``/dev``, ``/proc`` and ``/sys`` keep the prefix rule: dropped, counted as
##   kernel state, never host-bound.
## * Anything else under ``/run`` is kept when it is a regular file, a
##   directory, a symbolic link (followed; a dangling one is kept, since its
##   target can be re-read with ``readlink``) or absent (an absence probe is
##   re-checkable), and when its type cannot be read. It is dropped only when
##   it is a socket, a FIFO or a character or block device: a runtime object.
##
## The file-type probe (``runtimeEntryKind``) runs against a real temporary
## directory holding a real regular file, directory, symlink, dangling
## symlink, FIFO and unix socket — no mocks, because the rule is about what
## ``lstat``/``stat`` say. A test cannot create entries under the real ``/run``
## (only ``/run/user/<uid>``, which the prefix rule already keeps), so the
## verdict for ``/run`` paths is tested through ``volatileVerdictFor``, the pure
## half that takes the probed kind as an argument; ``volatileInputVerdict`` is
## the composition of the two and is exercised on paths whose answer does not
## depend on this host's ``/run`` (``/proc``, ``/run/user``, a non-volatile
## temporary path).
##
## Falsifiability: making ``volatileVerdictFor`` drop every ``/run`` kind
## (the old prefix rule) fails the keep cases; making it keep sockets and
## FIFOs fails the runtime-object cases; making ``runtimeEntryKind`` use
## ``stat`` alone fails the dangling-symlink case (it reads as absent, which
## is kept too, so that case checks the KIND); using ``lstat`` alone fails the
## symlink-to-socket case.

import std/[os, unittest, tempfiles]

when defined(posix):
  import std/[net, posix]

import repro_test_support/reasoned_skip
import repro_core/paths as corepaths

suite "volatile runtime input by file type":

  test "the pure verdict keeps files, directories, symlinks and absent paths under /run and drops runtime objects":
    let scope = volatileScope([])
    for kind in [rekRegular, rekDirectory, rekSymlink, rekAbsent, rekUnknown]:
      check volatileVerdictFor("/run/current-system/sw/bin/sh", scope,
        kind) == vvKeep
    for kind in [rekSocket, rekFifo, rekDevice]:
      check volatileVerdictFor("/run/nscd/socket", scope, kind) ==
        vvDropRuntimeObject
      check volatileVerdictFor("/run/nscd/socket", scope, kind).isDrop

  test "/dev, /proc and /sys keep the prefix rule whatever the kind":
    let scope = volatileScope([])
    for path in ["/proc/self/fd/4", "/proc/cpuinfo",
                 "/sys/devices/system/cpu/online", "/dev/null",
                 "/dev/shm/sem.mp-1"]:
      for kind in [rekRegular, rekAbsent, rekDevice]:
        check volatileVerdictFor(path, scope, kind) == vvDropKernelState
      check dropsAsVolatileInput(path, scope)
      check volatileInputVerdict(path, scope) == vvDropKernelState
    # A directory under `/dev/shm` holds ordinary files; the prefix rule
    # keeps it already.
    check volatileVerdictFor("/dev/shm/build/x", scope, rekRegular) == vvKeep

  test "what the prefix rule keeps is kept without a probe":
    let scope = volatileScope(["/run/admin-mount/project"])
    for path in ["/run/user/1000/build/input.txt", "/run/user/1000",
                 "/run/media/me/disk/input.txt",
                 "/run/admin-mount/project/src/a.txt", "/home/me/p/a.txt",
                 "/nix/store/abc-x/bin/sh"]:
      # Even the kind of a runtime object does not drop it: the place says
      # what it is.
      check volatileVerdictFor(path, scope, rekSocket) == vvKeep
      check volatileInputVerdict(path, scope) == vvKeep
      check not dropsAsVolatileInput(path, scope)

  test "the probe reads the kind of a real entry":
    when not defined(posix):
      skip("needs POSIX lstat/stat file types, FIFOs and unix sockets")
    else:
      let dir = createTempDir("repro-runtime-kind-", "")
      defer: removeDir(dir)
      writeFile(dir / "file", "x")
      createDir(dir / "dir")
      createSymlink(dir / "file", dir / "link")
      createSymlink(dir / "dir", dir / "dirlink")
      createSymlink(dir / "nowhere", dir / "dangling")
      doAssert mkfifo(cstring(dir / "fifo"), Mode(0o600)) == 0
      let listener = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM,
        Protocol.IPPROTO_IP)
      listener.bindUnix(dir / "sock")
      listener.close()
      createSymlink(dir / "sock", dir / "socklink")

      check runtimeEntryKind(dir / "file") == rekRegular
      check runtimeEntryKind(dir / "dir") == rekDirectory
      # A link to an ordinary entry is followed to it.
      check runtimeEntryKind(dir / "link") == rekRegular
      check runtimeEntryKind(dir / "dirlink") == rekDirectory
      # A dangling link is still a link: its target is re-readable.
      check runtimeEntryKind(dir / "dangling") == rekSymlink
      check runtimeEntryKind(dir / "missing") == rekAbsent
      check runtimeEntryKind(dir / "file" / "below") == rekAbsent
      check runtimeEntryKind(dir / "fifo") == rekFifo
      check runtimeEntryKind(dir / "sock") == rekSocket
      # A link to a socket is followed: what is opened is the socket.
      check runtimeEntryKind(dir / "socklink") == rekSocket
      check runtimeEntryKind("/dev/null") == rekDevice

      # Composed with the verdict: the kinds the probe found, under `/run`.
      let scope = volatileScope([])
      for name in ["file", "dir", "link", "dirlink", "dangling", "missing"]:
        check volatileVerdictFor("/run/x", scope,
          runtimeEntryKind(dir / name)) == vvKeep
      for name in ["fifo", "sock", "socklink"]:
        check volatileVerdictFor("/run/x", scope,
          runtimeEntryKind(dir / name)) == vvDropRuntimeObject

  test "a path outside every volatile prefix is kept even when it is a socket":
    when not defined(posix):
      skip("needs POSIX lstat/stat file types, FIFOs and unix sockets")
    else:
      let dir = createTempDir("repro-runtime-kind-", "")
      defer: removeDir(dir)
      doAssert mkfifo(cstring(dir / "fifo"), Mode(0o600)) == 0
      # Not under `/run`, `/dev`, `/proc` or `/sys`: not this decision's to
      # drop (unless TMPDIR is itself under `/run/<not user>`, which the
      # prefix rule would then judge; skip that host layout).
      if not isVolatileRuntimeStatePath(dir):
        check volatileInputVerdict(dir / "fifo", volatileScope([])) == vvKeep
      else:
        skip("TMPDIR is under a volatile prefix on this host, where the " &
          "prefix rule, not this case, decides")

  test "the links a path under /run passes through are its link hops":
    # Only `/run` is judged: a path elsewhere has none, whatever it holds.
    check linkHopsUnderRun("/nix/store/x/bin/sh").len == 0
    check linkHopsUnderRun("/run").len == 0
    when not defined(posix):
      skip("needs POSIX lstat")
    else:
      # A test cannot create a link under `/run`; use one the host has
      # (NixOS's `/run/current-system`, or any link directly under `/run`).
      var link = ""
      for kind, path in walkDir("/run"):
        if kind == pcLinkToDir:
          link = path
          break
      if link.len == 0:
        skip("this host has no link to a directory directly under /run")
      else:
        # The link is a hop of what is reached through it, and the final
        # component never is (it is the input itself).
        let through = link / "no-such-entry" / "file"
        check linkHopsUnderRun(through) == @[link]
        check linkHopsUnderRun(link).len == 0
        # A component that is a real directory is not a hop.
        check "/run" notin linkHopsUnderRun(through)
