## NPC-M10 verification
## `test_npc_m10_probe_cannot_reach_network_or_write_outside_scratch`
## (NPC-AREQ8 step 3, threat model G6).
##
## A hostile `.nimble` is probed (`nimble dump --json`, which evaluates its
## NimScript) in the probe's sandbox (`probe.runProbe`):
##
## * one runs `exec "<curl> http://127.0.0.1:<port>/exfiltrate"` against a
##   listener this test holds open on the host's loopback: the probe fails,
##   no connection reaches the listener, and the failure is captured
##   (`probe-violation`, naming the package, the source object's digest,
##   the origin and commit, and the probe's diagnostics naming the command);
## * one writes a file into a directory of the host outside scratch: the
##   probe fails, the file does not exist, and the failure is captured.
##
## Positive controls: the listener accepts a connection from the test
## itself; a benign `.nimble` that runs the same curl (`--version`) inside
## the sandbox and writes into its own `HOME` (scratch) is probed
## successfully, and its dump names it -- so the denials above are the
## sandbox's, not a missing tool.
##
## The same benign probe reports the sandbox as its code sees it, and the
## test checks that view: its network namespace has the loopback interface
## alone; no Unix socket is reachable (the host's `/nix/var` daemon socket
## would hand it a build service that reaches the network); every mount
## but scratch, `/dev` and `/proc` is read-only; and a file the test wrote
## beside scratch is not there.
##
## A `.nimble` that runs past the time limit is killed with everything it
## started (no process of it is left), and one whose dump is larger than a
## pipe holds is not stalled by it.
##
## `nimble` is `REPRO_TEST_NIMBLE` when set, else the one on `PATH`; the
## test fails, it does not skip, without it, `nim`, `bwrap` and `curl`.
##
## Falsifying mutation (recorded in the plan): neutering the network
## denial lets the request out, and fails the test.

import std/[nativesockets, net, os, strutils, tempfiles, times, unittest]

import repro_nimble_generator

proc tool(name: string; env = ""): string =
  result = if env.len > 0: getEnv(env, findExe(name)) else: findExe(name)
  doAssert result.len > 0, name & " is needed by this test" &
    (if env.len > 0: " (set " & env & ")" else: "")
  result = expandFilename(result)

proc onPath(name: string): string =
  ## A tool as `PATH` names it, its link not resolved: a coreutils program
  ## is a link to one binary that reads its name from the link.
  result = findExe(name, followSymlinks = false)
  doAssert result.len > 0, name & " is needed by this test"
  result = absolutePath(result)

proc pendingConnection(server: Socket): bool =
  ## Whether a connection waits in the listener's backlog.
  server.getFd().setBlocking(false)
  var client: Socket
  try:
    server.accept(client)
    client.close()
    result = true
  except OSError:
    result = false
  server.getFd().setBlocking(true)

suite "NPC-M10: the probe has no network and writes only to scratch":

  let cfg = ProbeConfig(sandboxBin: tool("bwrap"),
    nimbleBin: tool("nimble", "REPRO_TEST_NIMBLE"), nimBin: tool("nim"),
    wallSeconds: 60)
  let curl = tool("curl")
  let header = "version = \"1.0\"\nauthor = \"x\"\ndescription = \"x\"\n" &
    "license = \"MIT\"\n"

  test "an exec of curl reaches nothing; a write outside scratch fails; both are captured":
    let work = createTempDir("npc-m10-probe-", "")
    let log = work / "captures.log"
    let server = newSocket()
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let port = server.getLocalAddr()[1]
    defer: server.close()

    # Control: the listener sees a connection from outside the sandbox.
    let probeClient = newSocket()
    probeClient.connect("127.0.0.1", port)
    check server.pendingConnection()
    probeClient.close()

    let net = runProbe(cfg, header & "exec \"" & curl & " -s -m 5 " &
      "http://127.0.0.1:" & $port & "/exfiltrate\"\n", "netprobe.nimble",
      work / "scratch-net")
    checkpoint net.diagnostics
    check not net.ok
    check "FAILED" in net.diagnostics
    check "/exfiltrate" in net.diagnostics
    check not server.pendingConnection()

    let outside = work / "outside"
    createDir(outside)
    let canary = outside / "written-by-the-probe"
    let wr = runProbe(cfg, header & "writeFile(\"" & canary & "\", \"x\")\n",
      "writeprobe.nimble", work / "scratch-write")
    checkpoint wr.diagnostics
    check not wr.ok
    check canary in wr.diagnostics # the write itself failed
    check not fileExists(canary)

    let tree = repeat("c", 64)
    appendCaptures(log, [
      probeCapture("netprobe", "https://forge.test/netprobe.git", repeat("1", 40),
        tree, net, 1_790_000_000),
      probeCapture("writeprobe", "https://forge.test/writeprobe.git",
        repeat("2", 40), tree, wr, 1_790_000_000)])
    let got = readCaptures(log)
    check got.len == 2
    if got.len == 2:
      check got[0].class == ccProbeViolation
      check got[0].package == "netprobe"
      check got[0].expected == tree
      check got[0].source == "https://forge.test/netprobe.git@" & repeat("1", 40)
      check "/exfiltrate" in got[0].detail
      check got[1].package == "writeprobe"
      check got[1].observed.startsWith("exit ")

  test "a benign .nimble runs curl and writes its HOME inside the sandbox":
    let work = createTempDir("npc-m10-probe-ok-", "")
    let ok = runProbe(cfg, header & "exec \"" & curl & " --version\"\n" &
      "writeFile(getEnv(\"HOME\") & \"/note\", \"x\")\nrequires \"nim >= 1.0\"\n",
      "benign.nimble", work / "scratch")
    checkpoint ok.diagnostics
    check ok.ok
    check "\"name\": \"benign\"" in ok.dump
    check fileExists(work / "scratch" / "home" / "note")

  test "the probe's view: loopback only, no socket, a read-only host, nothing beside scratch":
    let work = createTempDir("npc-m10-probe-view-", "")
    let scratch = work / "scratch"
    let beside = work / "beside-scratch"
    writeFile(beside, "the test's own file\n")
    let find = onPath("find")
    let home = scratch / "home"
    # Control for the socket search: a socket of the test's own, in scratch.
    createDir(scratch)
    let control = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    control.bindUnix(scratch / "control.sock")
    defer: control.close()
    let view = runProbe(cfg, header &
      "writeFile(getEnv(\"HOME\") & \"/netdev\", readFile(\"/proc/net/dev\"))\n" &
      "writeFile(getEnv(\"HOME\") & \"/mountinfo\", " &
        "readFile(\"/proc/self/mountinfo\"))\n" &
      "writeFile(getEnv(\"HOME\") & \"/beside\", $fileExists(\"" & beside &
        "\"))\n" &
      "exec \"" & find & " / -path /proc -prune -o -path /dev -prune -o " &
        "-path /nix/store -prune -o -type s -print > \" & getEnv(\"HOME\") & " &
        "\"/sockets 2>/dev/null; echo end >> \" & getEnv(\"HOME\") & " &
        "\"/sockets\"\n",
      "view.nimble", scratch)
    checkpoint view.diagnostics
    check view.ok

    # The network namespace: the loopback interface alone.
    var ifaces: seq[string]
    for line in readFile(home / "netdev").splitLines():
      let colon = line.find(':')
      if colon > 0: ifaces.add line[0 ..< colon].strip()
    checkpoint $ifaces
    check ifaces == @["lo"]

    # No Unix socket of the host is reachable: the search finds the
    # control socket in scratch, and nothing else.
    let sockets = readFile(home / "sockets").strip().splitLines()
    checkpoint $sockets
    check sockets == @[scratch / "control.sock", "end"]

    # Every mount but scratch, /dev and /proc is read-only.
    var mounts = 0
    for line in readFile(home / "mountinfo").splitLines():
      let fs = line.split(' ')
      if fs.len < 6: continue
      inc mounts
      let point = fs[4]
      if point == scratch or point.startsWith("/dev") or
          point.startsWith("/proc"):
        continue
      checkpoint line
      check "ro" in fs[5].split(',')
    check mounts > 2
    check readFile(home / "beside") == "false"

  test "past the time limit the probe is killed with all it started; a large output does not stall it":
    let work = createTempDir("npc-m10-probe-limit-", "")
    let marker = "600.04" & $getCurrentProcessId()
    var slow = cfg
    slow.wallSeconds = 3
    let started = epochTime()
    let late = runProbe(slow, header & "exec \"" & onPath("sleep") & " " &
      marker & "\"\n", "slow.nimble", work / "scratch-slow")
    let took = epochTime() - started
    check late.timedOut
    check not late.ok
    check took < 20.0
    proc stillRunning(): bool =
      for kind, dir in walkDir("/proc"):
        try:
          if marker in readFile(dir / "cmdline"): return true
        except IOError, OSError:
          discard
    var left = stillRunning()
    for _ in 0 ..< 100:
      if not left: break
      sleep(20)
      left = stillRunning()
    check not left

    # A dump larger than a pipe holds (a 300 kB description).
    let loud = runProbe(cfg, "import std/strutils\n" & header &
      "description = repeat('x', 300000)\n", "loud.nimble",
      work / "scratch-loud")
    checkpoint loud.diagnostics
    check not loud.timedOut
    check loud.ok
    check repeat('x', 300000) in loud.dump
