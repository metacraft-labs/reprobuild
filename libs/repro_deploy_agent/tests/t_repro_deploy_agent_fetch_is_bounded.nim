## The agent's manifest fetch holds at most `MaxDeployManifestBytes` of a
## body, however large the source's answer is.
##
## Governing spec: ``reprobuild-pm/spec/Deploy-Agent.md`` §Strictness ("an
## agent also caps what it will read from a source at 32 MiB … checked
## against Content-Length before the body is fetched and again while
## reading it"). The cap exists for a target with little memory (rpi2 has
## 920 MB), so a cap applied AFTER a client has buffered the whole body —
## which is what the synchronous `HttpClient.request` does — bounds
## nothing. The check here is the one that distinguishes the two: the
## server counts how many bytes it managed to send before the client went
## away, and a bounded client disconnects long before the end.
##
## Fixture, justified: a real HTTP server is needed, and Python's
## `http.server` from the dev shell is used as one (no Nim HTTP server
## framework shares a dispatcher with the client under test without also
## sharing its event loop). The handler is seven lines: it streams a
## chunked body of the requested size and, when the client disconnects,
## records how far it got. Nothing about the agent is mocked:
## `defaultHttpGet` is the production fetch, called through the production
## `AgentDeps` default.

import std/[net, os, osproc, streams, strutils, times, unittest]

import repro_deploy_agent
import repro_test_support/reasoned_skip

const ServerScript = """
import http.server, sys, socketserver, time
PROGRESS = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        # /chunked/<mib> streams <mib> MiB with no Content-Length;
        # /sized/<mib> declares Content-Length and streams the same;
        # /trickle/<n> sends <n> one-byte chunks 400 ms apart, each well
        # inside a per-chunk timeout, for as long as the client stays.
        kind, arg = self.path.strip("/").split("/")
        if kind == "trickle":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            sent = 0
            try:
                for _ in range(int(arg)):
                    self.wfile.write(b"1\r\nt\r\n"); self.wfile.flush()
                    sent += 1
                    time.sleep(0.4)
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with open(PROGRESS, "w") as fh:
                    fh.write(str(sent))
            return
        total = int(arg) * 1024 * 1024
        self.send_response(200)
        if kind == "sized":
            self.send_header("Content-Length", str(total))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        sent = 0
        piece = b"m" * 65536
        try:
            while sent < total:
                if kind == "sized":
                    self.wfile.write(piece)
                else:
                    self.wfile.write(b"%x\r\n" % len(piece) + piece + b"\r\n")
                self.wfile.flush()
                sent += len(piece)
            if kind != "sized":
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with open(PROGRESS, "w") as fh:
                fh.write(str(sent))
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
srv = S(("127.0.0.1", int(sys.argv[1])), H)
print("READY", flush=True)
srv.serve_forever()
"""

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

suite "deploy agent: the manifest fetch is bounded while streaming":
  test "a body over the cap is refused with little of it ever read":
    when not defined(linux):
      skip("the fixture server is Python's http.server from the dev shell; " &
        "the Linux leg is the one that measures the rpi2 constraint")
    else:
      let dir = getTempDir() / "t_deploy_agent_fetch_" & $getCurrentProcessId()
      createDir(dir)
      defer: removeDir(dir)
      let script = dir / "server.py"
      let progress = dir / "progress"
      writeFile(script, ServerScript)
      let port = freePort()
      let python = findExe("python3")
      check python.len > 0
      let srv = startProcess(python, args = @["-I", script, $port, progress],
        options = {poStdErrToStdOut})
      defer:
        srv.kill()
        discard srv.waitForExit()
        srv.close()
      check srv.outputStream.readLine() == "READY"
      let base = "http://127.0.0.1:" & $port

      # 1. Chunked, no Content-Length, 256 MiB offered: refused at the cap,
      #    and the server saw the client leave well before the end.
      let big = defaultHttpGet(base & "/chunked/256", 30_000)
      check not big.ok
      check not big.missing
      check "exceeds the " & $MaxDeployManifestBytes in big.error
      check big.body.len == 0
      var sent = -1
      for _ in 0 ..< 200:
        if fileExists(progress):
          try:
            sent = parseInt(readFile(progress).strip())
            break
          except ValueError: discard
        sleep(50)
      checkpoint "server sent " & $sent & " bytes before the client left"
      check sent >= 0
      # What the server got out before the disconnect is the cap plus the
      # chunks in flight; a client that buffered the whole body would read
      # all 256 MiB. Allow 4x the cap for socket buffers and scheduling.
      check sent < 4 * MaxDeployManifestBytes
      check sent < 256 * 1024 * 1024

      # 2. Content-Length over the cap: refused before a byte is read.
      removeFile(progress)
      let declared = defaultHttpGet(base & "/sized/64", 30_000)
      check not declared.ok
      check "bytes exceeds the" in declared.error
      for _ in 0 ..< 200:
        if fileExists(progress): break
        sleep(50)
      let sentDeclared = if fileExists(progress):
        parseInt(readFile(progress).strip()) else: -1
      checkpoint "server sent " & $sentDeclared & " bytes after the refusal"
      check sentDeclared < 4 * MaxDeployManifestBytes

      # 3. Under the cap: the whole body arrives intact.
      let small = defaultHttpGet(base & "/chunked/2", 30_000)
      check small.ok
      check small.body.len == 2 * 1024 * 1024
      check small.body[0] == byte('m') and small.body[^1] == byte('m')

  test "a trickling source is cut by the whole-fetch deadline":
    when not defined(linux):
      skip("the fixture server is Python's http.server from the dev shell; " &
        "the Linux leg is the one that measures the rpi2 constraint")
    else:
      # The production deadline is never under a minute
      # (`fetchDeadlineMs`); the bounded core takes it as a parameter so
      # this measures the mechanism in seconds.
      check fetchDeadlineMs(2_000) == 60_000
      check fetchDeadlineMs(30_000) == 120_000
      check fetchDeadlineMs(0) == 60_000
      let dir = getTempDir() / "t_deploy_agent_trickle_" & $getCurrentProcessId()
      createDir(dir)
      defer: removeDir(dir)
      let script = dir / "server.py"
      let progress = dir / "progress"
      writeFile(script, ServerScript)
      let port = freePort()
      let srv = startProcess(findExe("python3"),
        args = @["-I", script, $port, progress], options = {poStdErrToStdOut})
      defer:
        srv.kill()
        discard srv.waitForExit()
        srv.close()
      check srv.outputStream.readLine() == "READY"
      # 50 chunks × 400 ms = 20 s if the client stayed; the per-chunk
      # timeout (2 s) is never tripped. A 3 s whole-fetch deadline ends it.
      let t0 = epochTime()
      let r = httpGetBounded("http://127.0.0.1:" & $port & "/trickle/50",
        timeoutMs = 2_000, deadlineMs = 3_000)
      let elapsed = epochTime() - t0
      checkpoint "trickle fetch ended after " & $elapsed & " s: " & r.error
      check not r.ok
      check "deadline" in r.error
      check elapsed < 8.0
      # Positive control: the same source under the deadline completes.
      let ok = httpGetBounded("http://127.0.0.1:" & $port & "/trickle/3",
        timeoutMs = 2_000, deadlineMs = 10_000)
      check ok.ok
      check ok.body.len == 3
