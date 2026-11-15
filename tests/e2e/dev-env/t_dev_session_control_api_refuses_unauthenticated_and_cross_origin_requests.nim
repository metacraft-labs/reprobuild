## The dev-session control API refuses every request that does not prove it
## comes from the session's own user, and every request a web page could have
## forged.
##
## Issue: reprobuild-pm
## `issues/2026-11-12-local-http-control-api-no-authentication-host-origin-checks-or-bind-restriction.md`.
## The listener used to discard every request header and serve
## `POST /session/stop`, `/session`, `/status` and `/events` to anyone who
## could reach its port: any local account on a multi-user host, any web page
## through a CORS-simple `POST` or through DNS rebinding, and -- with a
## non-loopback `--http` -- the network. The rules these cases hold the
## listener to are in reprobuild-pm
## `spec/Development-Environments-And-Control-API.md`
## §"Control API Access Control".
##
## Every case talks to the listener the way an attacker would: raw HTTP/1.1
## written by hand on a raw socket, with exactly the headers a browser or a
## curious local user would send and nothing else. No client library of the
## code under test is used to build the hostile requests, because a client
## that "helpfully" adds the right header would hide the very gap under test.
##
## MOCKS: NONE. The listener is the real `__repro-dev-session-http` helper of
## the real `build/bin/repro`, started the way the supervisor starts it
## (session directory, parent pid), on a real socket. The whole-session cases
## run the real `repro up` / `repro down` against a real project with a real
## supervised `sh` service. The attack is judged by its real side effect: the
## `stop.request.json` the listener writes when it accepts a stop, and whether
## the listener and the session are still running afterwards.

import std/[json, net, os, osproc, streams, strtabs, strutils, tempfiles,
  unittest]
when defined(posix):
  import std/posix

import repro_test_support

proc reproBinary(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  RawResponse = object
    status: int
    headers: seq[tuple[name, value: string]]
    body: string

proc header(response: RawResponse; name: string): string =
  for h in response.headers:
    if cmpIgnoreCase(h.name, name) == 0:
      return h.value

proc connectTo(bindValue: string): Socket =
  ## Open a raw stream socket to a published control-API bind:
  ## `unix:<path>` or `http://<host>:<port>`.
  if bindValue.startsWith("unix:"):
    when defined(posix):
      result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
      result.connectUnix(bindValue["unix:".len .. ^1])
    else:
      raise newException(ValueError, "AF_UNIX bind on a non-POSIX host: " &
        bindValue)
  else:
    var raw = bindValue
    if raw.startsWith("http://"):
      raw = raw["http://".len .. ^1]
    let colon = raw.rfind(':')
    var host = raw[0 ..< colon]
    let port = parseInt(raw[colon + 1 .. ^1])
    if host.startsWith("[") and host.endsWith("]"):
      host = host[1 .. ^2]
    if host == "0.0.0.0":
      host = "127.0.0.1"
    result = newSocket(if ':' in host: Domain.AF_INET6 else: Domain.AF_INET)
    result.connect(host, Port(port))

proc exchange(bindValue, request: string): RawResponse =
  ## Send `request` verbatim and read the whole response. The request is the
  ## attacker's own bytes; nothing is added to it.
  let socket = connectTo(bindValue)
  defer: socket.close()
  socket.send(request)
  var raw = ""
  while true:
    let chunk = socket.recv(4096, timeout = 10_000)
    if chunk.len == 0:
      break
    raw.add(chunk)
  let headEnd = raw.find("\r\n\r\n")
  let head = if headEnd >= 0: raw[0 ..< headEnd] else: raw
  result.body = if headEnd >= 0: raw[headEnd + 4 .. ^1] else: ""
  let lines = head.split("\r\n")
  if lines.len > 0:
    let fields = lines[0].splitWhitespace()
    if fields.len >= 2 and fields[0].startsWith("HTTP/"):
      result.status = parseInt(fields[1])
  for line in lines[1 .. ^1]:
    let colon = line.find(':')
    if colon > 0:
      result.headers.add((name: line[0 ..< colon].strip(),
        value: line[colon + 1 .. ^1].strip()))

proc request(httpMethod, path: string;
             headers: openArray[string]; body = ""): string =
  ## A raw HTTP/1.1 request carrying exactly `headers` (each `Name: value`).
  result = httpMethod & " " & path & " HTTP/1.1\r\n"
  for h in headers:
    result.add(h & "\r\n")
  result.add("Connection: close\r\n")
  result.add("Content-Length: " & $body.len & "\r\n\r\n")
  result.add(body)

proc hostOf(bindValue: string): string =
  ## The `Host` value a well-behaved client would send to this bind.
  if bindValue.startsWith("unix:"): "localhost"
  else: bindValue.replace("http://", "")

type
  Listener = object
    process: Process
    sessionDir: string
    ready: JsonNode
    bindValue: string
    token: string
    tokenPath: string

proc stopFile(listener: Listener): string =
  listener.sessionDir / "stop.request.json"

proc waitForReady(path: string; helper: Process): bool =
  for _ in 0 ..< 1500:
    if fileExists(path): return true
    if not helper.running(): return false
    sleep(20)
  false

proc startListener(sessionDir: string; extraArgs: openArray[string]): Listener =
  ## The real control-API helper, started as the supervisor starts it, owned
  ## by this test process. A session.json carrying a recognisable secret is
  ## written first, so a 401 can be checked for leaking it.
  createDir(sessionDir)
  writeFile(sessionDir / "session.json", $(%*{
    "schemaId": "reprobuild.dev-session.v1",
    "sessionId": "secret-session-id-7f3a", "status": "up",
    "projectRoot": "/secret/project/root"}))
  result.sessionDir = sessionDir
  result.process = startProcess(reproBinary(), args = @[
    "__repro-dev-session-http", "--session-dir", sessionDir,
    "--parent-pid", $getCurrentProcessId()] & @extraArgs,
    options = {poStdErrToStdOut})
  let readyPath = sessionDir / "http-ready.json"
  if not waitForReady(readyPath, result.process):
    let output =
      if result.process.running(): ""
      else: result.process.outputStream.readAll()
    raise newException(IOError,
      "control-API helper did not publish " & readyPath & "\n" & output)
  result.ready = parseJson(readFile(readyPath))
  result.bindValue = result.ready["httpBind"].getStr()
  result.tokenPath = result.ready{"httpTokenPath"}.getStr()
  if result.tokenPath.len > 0 and fileExists(result.tokenPath):
    result.token = readFile(result.tokenPath).strip()
  checkpoint("listener bind: " & result.bindValue)
  checkpoint("listener token path: " & result.tokenPath)

proc close(listener: var Listener) =
  ## Stop the listener the way its supervisor would -- the stop-request
  ## file its watchdog polls -- so it removes its own token and socket, and
  ## kill it only if it does not go.
  if listener.process == nil: return
  if listener.process.running():
    try: writeFile(listener.stopFile, "{}")
    except IOError: discard
    for _ in 0 ..< 100:
      if not listener.process.running(): break
      sleep(50)
  if listener.process.running(): listener.process.kill()
  discard listener.process.waitForExit()
  listener.process.close()
  listener.process = nil

proc exitsSoon(process: Process): bool =
  for _ in 0 ..< 100:
    if not process.running(): return true
    sleep(50)
  not process.running()

proc auth(listener: Listener): string =
  ## A correct bearer header -- or, against a listener that publishes no
  ## token, a placeholder that a token-checking listener would refuse.
  "Authorization: Bearer " &
    (if listener.token.len > 0: listener.token else: "no-token-was-published")

proc requireNoSideEffect(listener: Listener; what: string) =
  checkpoint(what)
  check not fileExists(listener.stopFile)
  check listener.process.running()

proc requireNoLeak(response: RawResponse) =
  check not response.body.contains("secret-session-id-7f3a")
  check not response.body.contains("/secret/project/root")
  check response.header("Access-Control-Allow-Origin").len == 0

when defined(posix):
  proc modeOf(path: string): int =
    var st: Stat
    if lstat(path.cstring, st) != 0:
      raiseOSError(osLastError(), path)
    int(st.st_mode) and 0o777

  proc ownerOf(path: string): int =
    var st: Stat
    if lstat(path.cstring, st) != 0:
      raiseOSError(osLastError(), path)
    int(st.st_uid)

suite "dev_session_control_api_access_control":
  test "an unauthenticated or forged request changes nothing and leaks nothing":
    let root = createTempDir("repro-ctl-acl-", "")
    defer: removeDir(root)
    var listener = startListener(root / "session",
      ["--host", "127.0.0.1", "--port", "0"])
    defer: listener.close()
    let host = "Host: " & hostOf(listener.bindValue)

    # The CORS-simple POST a hostile web page can send without a preflight:
    # text/plain, no credentials of any kind.
    var r = exchange(listener.bindValue, request("POST", "/session/stop",
      [host, "Content-Type: text/plain", "Origin: http://evil.example"],
      body = "x"))
    checkpoint("cross-origin text/plain stop: HTTP " & $r.status)
    check r.status == 403
    listener.requireNoSideEffect("after a cross-origin text/plain stop")

    # The same POST from a local process that sends no Origin and no token.
    r = exchange(listener.bindValue, request("POST", "/session/stop",
      [host, "Content-Type: text/plain"], body = "x"))
    checkpoint("unauthenticated text/plain stop: HTTP " & $r.status)
    check r.status == 401
    listener.requireNoSideEffect("after an unauthenticated stop")

    # Even with the content type a real client uses: no token, no stop.
    r = exchange(listener.bindValue, request("POST", "/session/stop",
      [host, "Content-Type: application/json"], body = "{}"))
    checkpoint("unauthenticated json stop: HTTP " & $r.status)
    check r.status == 401
    listener.requireNoSideEffect("after an unauthenticated json stop")

    # A wrong token of the right shape.
    r = exchange(listener.bindValue, request("POST", "/session/stop",
      [host, "Content-Type: application/json",
       "Authorization: Bearer " & repeat('0', 64)], body = "{}"))
    checkpoint("wrong-token stop: HTTP " & $r.status)
    check r.status == 401
    listener.requireNoSideEffect("after a wrong-token stop")

    # Reads: no session metadata and no event stream without the token.
    for path in ["/session", "/status", "/events?wait-ms=0", "/health"]:
      r = exchange(listener.bindValue, request("GET", path, [host]))
      checkpoint("unauthenticated GET " & path & ": HTTP " & $r.status &
        "\n" & r.body)
      check r.status == 401
      r.requireNoLeak()

  test "a correct token does not admit a rebinding Host or a foreign Origin":
    let root = createTempDir("repro-ctl-acl-", "")
    defer: removeDir(root)
    var listener = startListener(root / "session",
      ["--host", "127.0.0.1", "--port", "0"])
    defer: listener.close()
    let port = listener.bindValue[listener.bindValue.rfind(':') + 1 .. ^1]
    let token = listener.auth()

    # DNS rebinding: the browser resolved attacker.example to 127.0.0.1 and
    # sends the attacker's name. The token is (hypothetically) known.
    var r = exchange(listener.bindValue, request("GET", "/session",
      ["Host: attacker.example:" & port, token]))
    checkpoint("rebinding Host: HTTP " & $r.status)
    check r.status == 403
    r.requireNoLeak()
    r = exchange(listener.bindValue, request("POST", "/session/stop",
      ["Host: attacker.example:" & port, token,
       "Content-Type: application/json"], body = "{}"))
    check r.status == 403
    listener.requireNoSideEffect("after a rebinding-Host stop")

    # No Host at all.
    r = exchange(listener.bindValue, request("GET", "/session", [token]))
    checkpoint("absent Host: HTTP " & $r.status)
    check r.status == 403
    r.requireNoLeak()

    # A second Host, Origin or Authorization header is refused as if it
    # were foreign, whichever copy comes first: a parser that kept only the
    # first (or only the last) would let the other one through unchecked.
    for headers in [
        @["Host: 127.0.0.1:" & port, "Host: attacker.example:" & port, token],
        @["Host: attacker.example:" & port, "Host: 127.0.0.1:" & port, token],
        @["Host: 127.0.0.1:" & port, "Origin: http://127.0.0.1:" & port,
          "Origin: http://evil.example", token],
        @["Host: 127.0.0.1:" & port, token, "Authorization: Bearer x"]]:
      r = exchange(listener.bindValue, request("POST", "/session/stop",
        headers & @["Content-Type: application/json"], body = "{}"))
      checkpoint("duplicated header " & $headers & ": HTTP " & $r.status)
      check r.status in [401, 403]
      listener.requireNoSideEffect("after a duplicated-header stop")

    # A rebinding name dressed up as a loopback one is still not loopback.
    for hostValue in ["localhost.attacker.example:" & port,
                      "127.0.0.1.attacker.example:" & port,
                      "attacker.example:" & port & "@127.0.0.1",
                      "0.0.0.0:" & port]:
      r = exchange(listener.bindValue, request("GET", "/session",
        ["Host: " & hostValue, token]))
      checkpoint("Host " & hostValue & ": HTTP " & $r.status)
      check r.status == 403
      r.requireNoLeak()

    # POSITIVE CONTROL for the cases above: the loopback names in any case,
    # and the IPv6 loopback in brackets, are this API.
    for hostValue in ["LOCALHOST:" & port, "127.0.0.1", "[::1]:" & port]:
      r = exchange(listener.bindValue, request("GET", "/status",
        ["Host: " & hostValue, token]))
      checkpoint("Host " & hostValue & ": HTTP " & $r.status)
      check r.status == 200

    # A foreign Origin, and the opaque `null` origin a sandboxed frame sends.
    for origin in ["http://evil.example", "null",
                   "http://127.0.0.1:" & port & ".evil.example",
                   "https://127.0.0.1:" & port]:
      r = exchange(listener.bindValue, request("POST", "/session/stop",
        ["Host: 127.0.0.1:" & port, "Origin: " & origin, token,
         "Content-Type: application/json"], body = "{}"))
      checkpoint("Origin " & origin & ": HTTP " & $r.status)
      check r.status == 403
      check r.header("Access-Control-Allow-Origin").len == 0
      listener.requireNoSideEffect("after an Origin " & origin & " stop")

  test "a mutating route takes only POST with application/json":
    let root = createTempDir("repro-ctl-acl-", "")
    defer: removeDir(root)
    var listener = startListener(root / "session",
      ["--host", "127.0.0.1", "--port", "0"])
    defer: listener.close()
    let host = "Host: " & hostOf(listener.bindValue)
    let token = listener.auth()

    var r = exchange(listener.bindValue, request("POST", "/session/stop",
      [host, token, "Content-Type: text/plain"], body = "{}"))
    checkpoint("token + text/plain stop: HTTP " & $r.status)
    check r.status == 415
    listener.requireNoSideEffect("after a text/plain stop")
    r = exchange(listener.bindValue, request("POST", "/session/stop",
      [host, token], body = "{}"))
    checkpoint("token + no content type stop: HTTP " & $r.status)
    check r.status == 415
    listener.requireNoSideEffect("after a stop with no content type")
    r = exchange(listener.bindValue, request("GET", "/session/stop",
      [host, token]))
    checkpoint("token + GET stop: HTTP " & $r.status)
    check r.status == 405
    listener.requireNoSideEffect("after a GET stop")

    # POSITIVE CONTROL: the same listener, the right token, a loopback Host,
    # the API's own Origin and application/json -- this one must stop it, or
    # every refusal above could be a listener that refuses everything.
    r = exchange(listener.bindValue, request("GET", "/session",
      [host, token]))
    checkpoint("authenticated GET /session: HTTP " & $r.status)
    check r.status == 200
    check r.body.contains("secret-session-id-7f3a")
    let port = listener.bindValue[listener.bindValue.rfind(':') + 1 .. ^1]
    r = exchange(listener.bindValue, request("POST", "/session/stop",
      ["Host: localhost:" & port, "Origin: http://localhost:" & port, token,
       "Content-Type: application/json"], body = "{}"))
    checkpoint("authenticated stop: HTTP " & $r.status)
    check r.status == 202
    check listener.process.exitsSoon()
    check fileExists(listener.stopFile)
    # The token does not outlive its listener.
    if listener.tokenPath.len > 0:
      check not fileExists(listener.tokenPath)

  test "a non-loopback bind is refused unless remote access is asked for":
    let root = createTempDir("repro-ctl-acl-", "")
    defer: removeDir(root)
    let sessionDir = root / "session"
    createDir(sessionDir)
    let helper = startProcess(reproBinary(), args = @[
      "__repro-dev-session-http", "--session-dir", sessionDir,
      "--host", "0.0.0.0", "--port", "0",
      "--parent-pid", $getCurrentProcessId()],
      options = {poStdErrToStdOut})
    defer:
      if helper.running(): helper.kill()
      discard helper.waitForExit()
      helper.close()
    let exited = helper.exitsSoon()
    let output = if exited: helper.outputStream.readAll() else: ""
    checkpoint("helper on 0.0.0.0 exited: " & $exited & "\n" & output)
    check exited
    check output.contains("--http-allow-remote")
    check not fileExists(sessionDir / "http-ready.json")

  when defined(posix):
    test "the default transport is an AF_UNIX socket in a private directory":
      let root = createTempDir("repro-ctl-acl-", "")
      defer: removeDir(root)
      var listener = startListener(root / "session", [])
      defer: listener.close()
      check listener.bindValue.startsWith("unix:")
      if listener.bindValue.startsWith("unix:"):
        let socketPath = listener.bindValue["unix:".len .. ^1]
        let endpointDir = parentDir(socketPath)
        checkpoint("endpoint dir: " & endpointDir)
        check isAbsolute(socketPath)
        check modeOf(endpointDir) == 0o700
        check ownerOf(endpointDir) == int(getuid())
        # Not inside the session directory, whose mode nothing guarantees.
        check not socketPath.startsWith(listener.sessionDir)
        check listener.tokenPath.len > 0
        check parentDir(listener.tokenPath) == endpointDir
        check modeOf(listener.tokenPath) == 0o600
        check listener.token.len >= 64
        check listener.token.allCharsInSet(HexDigits)
        # The token's PATH is published, never the token.
        check not readFile(listener.sessionDir / "http-ready.json").contains(
          listener.token)
        let r0 = exchange(listener.bindValue, request("POST", "/session/stop",
          ["Host: localhost", "Content-Type: application/json"], body = "{}"))
        check r0.status == 401
        listener.requireNoSideEffect("after an unauthenticated unix stop")
        let r1 = exchange(listener.bindValue, request("GET", "/status",
          ["Host: localhost", listener.auth()]))
        check r1.status == 200
        let r2 = exchange(listener.bindValue, request("POST", "/session/stop",
          ["Host: localhost", listener.auth(),
           "Content-Type: application/json"], body = "{}"))
        check r2.status == 202
        check listener.process.exitsSoon()
        check not fileExists(socketPath)
        check not fileExists(listener.tokenPath)

        # An endpoint directory another user could enter is refused, by
        # name, and nothing is served from it. (The listener removes its
        # emptied directory on exit, so it is recreated here, as a squatter
        # or a permissive umask would have left it.)
        createDir(endpointDir)
        setFilePermissions(endpointDir, {fpUserRead, fpUserWrite,
          fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
        removeFile(listener.stopFile)
        let again = startProcess(reproBinary(), args = @[
          "__repro-dev-session-http", "--session-dir", listener.sessionDir,
          "--parent-pid", $getCurrentProcessId()],
          options = {poStdErrToStdOut})
        defer:
          if again.running(): again.kill()
          discard again.waitForExit()
          again.close()
        let refused = again.exitsSoon()
        let output = if refused: again.outputStream.readAll() else: ""
        checkpoint("helper with a 0755 endpoint dir:\n" & output)
        check refused
        check output.contains(endpointDir)
        check not fileExists(listener.sessionDir / "http-ready.json")
        try: removeDir(endpointDir)
        except OSError: discard

    test "an XDG_RUNTIME_DIR spelled with a trailing slash is the per-user root":
      # The endpoint directory is created under `$XDG_RUNTIME_DIR` and every
      # directory between that root and it is checked for ownership. The
      # root itself is the system's, and so is everything above it -- a
      # check that found the root by comparing path strings walked straight
      # past `/run/user/<uid>/` and refused the root-owned `/run`.
      # Under /tmp, not $TMPDIR: an XDG_RUNTIME_DIR is used verbatim, so a
      # deep temporary directory would refuse the socket path as too long.
      let root = createTempDir("repro-ctl-acl-xdg-", "", "/tmp")
      defer: removeDir(root)
      let xdg = root / "xdg"
      createDir(xdg)
      setFilePermissions(xdg, {fpUserRead, fpUserWrite, fpUserExec})
      let sessionDir = root / "session"
      createDir(sessionDir)
      var env = newStringTable(modeCaseSensitive)
      for name, value in envPairs():
        env[name] = value
      env["XDG_RUNTIME_DIR"] = xdg & "/"
      let helper = startProcess(reproBinary(), args = @[
        "__repro-dev-session-http", "--session-dir", sessionDir,
        "--parent-pid", $getCurrentProcessId()], env = env,
        options = {poStdErrToStdOut})
      defer:
        if helper.running():
          try: writeFile(sessionDir / "stop.request.json", "{}")
          except IOError: discard
          discard helper.exitsSoon()
        if helper.running(): helper.kill()
        discard helper.waitForExit()
        helper.close()
      let published = waitForReady(sessionDir / "http-ready.json", helper)
      let output =
        if published or helper.running(): ""
        else: helper.outputStream.readAll()
      checkpoint("helper with XDG_RUNTIME_DIR=" & xdg & "/:\n" & output)
      require published
      let bindValue = parseJson(readFile(sessionDir / "http-ready.json"))[
        "httpBind"].getStr()
      checkpoint("bind: " & bindValue)
      check bindValue.startsWith("unix:" & xdg & "/repro/dev-sessions/")

  when isIoMonitorSupported and defined(posix):
    # The whole production path: `repro up` with no `--http`, a real
    # supervised service, an attacker on the published bind, `repro down`.
    proc writeProject(dir: string) =
      createDir(dir / "scripts")
      writeFile(dir / "scripts" / "svc.sh",
        "#!/bin/sh\nmkdir -p state\ntouch state/svc.ready\n" &
        "trap 'exit 0' TERM INT\nwhile :; do sleep 1; done\n")
      let metadata = $(%*{
        "schemaId": "reprobuild.dev-session.service.v1",
        "command": ["sh", "scripts/svc.sh"], "cwd": ".",
        "readiness": {"kind": "fileExists", "path": "state/svc.ready",
          "timeoutMs": 5000}})
      writeFile(dir / "reprobuild.nim",
        "import repro_project_dsl\n\npackage fixture:\n  devEnv:\n" &
        "    activity \"default\"\n" &
        "    servicePlaceholder \"svc\", metadata = \"\"\"" & metadata &
        "\"\"\"\n")

    proc runRepro(args: openArray[string]): tuple[code: int; output: string] =
      let repoRoot = getCurrentDir()
      let tools = prepareMonitorTools(repoRoot, "", "ctl-acl")
      var env: seq[tuple[name, value: string]] = @[
        (name: "REPROBUILD_SOURCE_ROOT", value: repoRoot),
        (name: "REPRO_MONITOR_SHIM_LIB", value: tools.shim)]
      let res = runShell(shellCommand(@[reproBinary()] & @args, env),
        repoRoot)
      (code: res.code, output: res.output)

    proc reap(projectRoot: string) =
      ## Best-effort teardown in either direction of the fix: ask the
      ## session to stop through the file the supervisor polls, then kill
      ## any pid it published that still names this project.
      let sessionDir = projectRoot / ".repro" / "dev-env" / "default" /
        "session"
      if not dirExists(sessionDir): return
      try: writeFile(sessionDir / "stop.request.json", "{}")
      except CatchableError: discard
      sleep(1500)
      for file in ["session.json", "http-ready.json"]:
        try:
          let node = parseJson(readFile(sessionDir / file))
          var pids = @[node{"pid"}.getInt(), node{"supervisorPid"}.getInt(),
            node{"httpPid"}.getInt()]
          for service in node{"services"}.getElems():
            pids.add(service{"pid"}.getInt())
          for pid in pids:
            if pid <= 0: continue
            let cmdline =
              try: readFile("/proc/" & $pid & "/cmdline")
              except CatchableError: ""
            let cwd =
              try: expandSymlink("/proc/" & $pid & "/cwd")
              except CatchableError: ""
            if cmdline.contains(projectRoot) or cwd == projectRoot:
              discard posix.kill(Pid(pid), SIGKILL)
        except CatchableError:
          discard

    test "repro up serves over AF_UNIX with a token and refuses a non-loopback --http":
      let root = createTempDir("repro-ctl-acl-up-", "")
      let projectRoot = root / "project"
      writeProject(projectRoot)
      defer:
        reap(projectRoot)
        removeDir(root)

      # The bind restriction is checked before any session exists.
      let remote = runRepro(["up", projectRoot, "--http=0.0.0.0:0"])
      checkpoint("repro up --http=0.0.0.0:0 -> exit " & $remote.code & "\n" &
        remote.output)
      check remote.code != 0
      check remote.output.contains("--http-allow-remote")
      let sessionJson = projectRoot / ".repro" / "dev-env" / "default" /
        "session" / "session.json"
      check not fileExists(sessionJson)
      if fileExists(sessionJson):
        discard runRepro(["down", projectRoot, "--force"])
        reap(projectRoot)
        removeFile(sessionJson)

      let up = runRepro(["up", projectRoot])
      checkpoint("repro up -> exit " & $up.code & "\n" & up.output)
      require up.code == 0
      let metadata = parseJson(readFile(sessionJson))
      let bindValue = metadata["httpBind"].getStr()
      checkpoint("recorded bind: " & bindValue)
      check bindValue.startsWith("unix:")
      let tokenPath = metadata{"httpTokenPath"}.getStr()
      check tokenPath.len > 0
      if tokenPath.len > 0:
        check modeOf(tokenPath) == 0o600
        check not readFile(sessionJson).contains(readFile(tokenPath).strip())

      # The attacker: a local process with no token.
      let attack = exchange(bindValue, request("POST", "/session/stop",
        ["Host: " & hostOf(bindValue), "Content-Type: text/plain"],
        body = "x"))
      checkpoint("unauthenticated stop of the live session: HTTP " &
        $attack.status)
      check attack.status == 401
      sleep(500)
      check parseJson(readFile(sessionJson))["status"].getStr() == "up"

      # POSITIVE CONTROL: the real client, which reads the token, stops it.
      let down = runRepro(["down", projectRoot])
      checkpoint("repro down -> exit " & $down.code & "\n" & down.output)
      check down.code == 0
      check parseJson(readFile(sessionJson))["status"].getStr() == "down"
      if tokenPath.len > 0:
        check not fileExists(tokenPath)
      if bindValue.startsWith("unix:"):
        check not fileExists(bindValue["unix:".len .. ^1])
