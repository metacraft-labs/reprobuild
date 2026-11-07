## ``t_start_binds_before_it_returns``: ``BinaryCacheHttpServer.start``
## binds its listener before it returns.
##
## - Port 0 binds a port the kernel picks, and ``listenPort`` is that
##   port, so a caller can be told where the daemon listens with no probe
##   for a free port beforehand.
## - A port that is already taken makes ``start`` raise.
##
## Before this change the plain-HTTP listener was bound inside the
## accept-loop future. A failed bind was stored there and never read, so
## the process carried on and printed "listening" for a port it did not
## hold. A test harness waiting for that line, after probing for a free port
## that another process could take first, either hung or misreported.
##
## *Mocking.* None: the real server on real loopback sockets.

import std/[asyncdispatch, httpclient, nativesockets, net, os, unittest]

import ../src/repro_binary_cache_server/index
import ../src/repro_binary_cache_server/server

proc root(tag: string): string =
  result = getTempDir() / ("t-bcs-bind-" & tag & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

suite "the binary cache binds before start returns":
  test "port 0 is bound and reported":
    let r = root("zero")
    defer: removeDir(r)
    let srv = newBinaryCacheHttpServer(openBinaryCacheServer(r))
    waitFor srv.start("127.0.0.1:0")
    defer: srv.close()
    check int(srv.listenPort) != 0
    proc get(): Future[int] {.async.} =
      let c = newAsyncHttpClient()
      defer: c.close()
      let resp = await c.get("http://127.0.0.1:" & $int(srv.listenPort) &
                             "/healthz")
      return resp.code.int
    check waitFor(get()) == 200

  test "a taken port makes start raise":
    let holder = newSocket()
    defer: holder.close()
    holder.bindAddr(Port(0), "127.0.0.1")
    holder.listen()
    let taken = holder.getLocalAddr()[1]
    let r = root("taken")
    defer: removeDir(r)
    let srv = newBinaryCacheHttpServer(openBinaryCacheServer(r))
    expect OSError:
      waitFor srv.start("127.0.0.1:" & $int(taken))
