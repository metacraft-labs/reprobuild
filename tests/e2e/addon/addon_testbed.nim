## The add-on test bed: disposable guests from stock distribution images,
## driven through gosti.
##
## Every add-on gate runs in a guest the gate itself created, and destroys
## it afterwards. Two flavours:
##
## - **QEMU** (``gosti`` ``qemu-boot`` backend): a stock cloud image, booted
##   from a qcow2 overlay this run owns, seeded with a cloud-init NoCloud
##   volume that authorises a key this run generated, reached over SSH on a
##   loopback-forwarded port. amd64 guests run under KVM; arm64 and armhf
##   guests run under TCG. Every gate that boots, reboots or inspects the
##   disk image uses this flavour.
## - **Incus system containers** (``gosti`` ``incus`` backend): the inner
##   loop. systemd is the container's PID 1, but there is no kernel, boot
##   or disk image of its own, so an Incus run is never an acceptance run.
##
## *Ownership.* Nothing outside what a run created is touched:
##
## - each run claims a fresh directory ``<cache>/runs/<name>`` with an
##   exclusive ``mkdir`` and writes a random owner token into it; the disk,
##   seed and SSH key live there, and ``destroy`` removes the directory only
##   if the token still matches;
## - QEMU guests are processes named with this test bed's own prefix
##   (``repro-addon-tb-``), each with its own user-mode network (no host
##   bridge, nothing shared), and the disk is a qcow2 overlay over the
##   read-only cached base image;
## - Incus guests carry the run's token in ``user.gosti.owner`` and sit on
##   a bridge network created for the run with the same token; gosti refuses
##   to exec in, copy to, stop or delete either when the token differs.
##
## *Images* are pinned by digest (the distributions' own SHA-512 / SHA-256
## lists, dated directories, never ``latest``) and cached under
## ``$REPRO_ADDON_TESTBED_CACHE`` (default
## ``${XDG_CACHE_HOME:-~/.cache}/reprobuild/addon-testbed``). A cached file is
## re-verified before every use.
##
## *Base preparation.* After cloud-init finishes on the first boot, the test
## bed disables the distribution's periodic apt jobs (``apt-daily*``,
## ``unattended-upgrades``, and Debian 13's hourly ``apt-listchanges.timer``,
## whose service disables itself on its first run and so changes the
## unit-file and active-unit state of a run that straddles the hour; and
## Ubuntu's ``fwupd-refresh.timer``, hourly with a random delay, whose
## ``fwupd.service`` rewrites ``/etc/fwupd/fwupd.conf`` to mode 0640 on
## its first run, with ``motd-news.timer`` and ``ua-timer.timer`` for the
## same class of reason) and runs ``apt-get update`` once. The first keeps
## an unattended upgrade from changing ``dpkg-status`` in the middle of a
## gate -- the gates fingerprint the base and an upgrade is not the add-on's
## doing; A10 runs with them on. The second makes ``apt-get install`` work,
## which the falsifying mutation of the do-no-harm gate needs. Both happen
## before the baseline fingerprint, so they are part of the base, not of
## anything a gate measures.

import std/[json, net, options, os, osproc, posix, random, strutils, tables, times]

import nimcrypto/[hash, sha2]

import repro_addon/[fingerprint, ledger]

when defined(gostiAvailable):
  import gosti

type
  BaseImage* = object
    name*: string          ## e.g. "debian-13-amd64"
    debArch*: string       ## amd64 / arm64 / armhf
    url*: string
    algo*: string          ## sha512 / sha256
    digest*: string
    file*: string
    osId*: string
    versionId*: string
    note*: string

  TestBedError* = object of CatchableError

const
  BaseImages* = [
    BaseImage(name: "debian-13-amd64", debArch: "amd64",
      url: "https://cloud.debian.org/images/cloud/trixie/20261026-2643/debian-13-genericcloud-amd64-20261026-2643.qcow2",
      algo: "sha512",
      digest: "3ace18e33bdd036edb49d1f79342bd01d2ab980e35194edb0b410435cd543538d286a0bd13bbb0835f7862306e3d385ce2f6a70d8ecf0bd961111166adbc1b8e",
      file: "debian-13-genericcloud-amd64-20261026-2643.qcow2",
      osId: "debian", versionId: "13"),
    BaseImage(name: "debian-12-amd64", debArch: "amd64",
      url: "https://cloud.debian.org/images/cloud/bookworm/20261026-2643/debian-12-genericcloud-amd64-20261026-2643.qcow2",
      algo: "sha512",
      digest: "0464b5d4ae3aa4f658468d88da83af7857b71548b30d46dcb6282770955a747fb95a983476db90d25afd0653af607224c7ebd05122ab71faa106fd712aaad652",
      file: "debian-12-genericcloud-amd64-20261026-2643.qcow2",
      osId: "debian", versionId: "12"),
    BaseImage(name: "ubuntu-24.04-amd64", debArch: "amd64",
      url: "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img",
      algo: "sha256",
      digest: "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94",
      file: "ubuntu-24.04-server-cloudimg-amd64-20261017.img",
      osId: "ubuntu", versionId: "24.04"),
    BaseImage(name: "debian-13-arm64", debArch: "arm64",
      url: "https://cloud.debian.org/images/cloud/trixie/20261026-2643/debian-13-genericcloud-arm64-20261026-2643.qcow2",
      algo: "sha512",
      digest: "71aa5d5dbcb3d9ecfe96bc3f6dd41b6805a0a41c852204a32747d230b64b95912297fb453b11a6031fd54d84a0a0a430e137d07e6986dc9ebc9d41483be003c4",
      file: "debian-13-genericcloud-arm64-20261026-2643.qcow2",
      osId: "debian", versionId: "13"),
    BaseImage(name: "ubuntu-24.04-armhf", debArch: "armhf",
      url: "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-armhf.img",
      algo: "sha256",
      digest: "892d1f6228c85fb39638b07ccebf6c392fa5d9c84c956eeb7aa042c52a124483",
      file: "ubuntu-24.04-server-cloudimg-armhf-20261017.img",
      osId: "ubuntu", versionId: "24.04"),
  ]

  DefaultBases* = ["debian-12-amd64", "debian-13-amd64", "ubuntu-24.04-amd64"]
    ## The amd64 matrix run under KVM when ``REPRO_ADDON_BASES`` is unset.

  QemuNamePrefix* = "repro-addon-tb-"
  IncusNamePrefix* = "repro-addon-tb-"

  IncusImages* = {"debian-13-amd64": "images:debian/13",
                  "debian-12-amd64": "images:debian/12",
                  "ubuntu-24.04-amd64": "images:ubuntu/24.04"}.toTable

proc baseNamed*(name: string): BaseImage =
  for b in BaseImages:
    if b.name == name: return b
  raise newException(TestBedError, "unknown test-bed base: " & name)

proc selectedBases*(): seq[BaseImage] =
  let env = getEnv("REPRO_ADDON_BASES")
  if env.len == 0:
    for n in DefaultBases: result.add(baseNamed(n))
  else:
    for n in env.split(','):
      if n.strip().len > 0: result.add(baseNamed(n.strip()))

proc gatesEnabled*(): bool = getEnv("REPRO_ADDON_VM_GATES") == "1"

proc useIncus*(): bool = getEnv("REPRO_ADDON_BACKEND") == "incus"

proc reproRoot*(): string =
  ## The reprobuild checkout (tests run from it).
  result = getEnv("REPROBUILD_SOURCE_ROOT")
  if result.len == 0: result = getCurrentDir()

proc cacheDir*(): string =
  result = getEnv("REPRO_ADDON_TESTBED_CACHE")
  if result.len == 0:
    let xdg = getEnv("XDG_CACHE_HOME")
    result = (if xdg.len > 0: xdg else: getHomeDir() / ".cache") /
             "reprobuild" / "addon-testbed"
  createDir(result)

proc recordsDir*(): string =
  result = getEnv("REPRO_ADDON_RECORDS")
  if result.len == 0: result = reproRoot() / "build" / "addon-gates" / "records"
  createDir(result)

# ---------------------------------------------------------------------------
# The add-on artefact under test.
# ---------------------------------------------------------------------------

proc mutation*(): string = getEnv("REPRO_ADDON_MUTATION")

proc testSeams*(): bool =
  ## The gate runs the build with the switch's pause points
  ## (``repro_addon/seams``, ``scripts/build_addon_static.sh --test-seams``).
  getEnv("REPRO_ADDON_TEST_SEAMS") == "1"

proc artefactDir*(): string =
  let m = mutation()
  if testSeams() and m.len > 0: reproRoot() / "build" / "addon-seams-mutations" / m
  elif testSeams(): reproRoot() / "build" / "addon-seams"
  elif m.len > 0: reproRoot() / "build" / "addon-mutations" / m
  else: reproRoot() / "build" / "addon"

proc artefact*(debArch: string): tuple[path, sha256: string] =
  ## The static ``repro`` for ``debArch`` and the digest its build
  ## published. Refuses a binary whose bytes no longer match its digest
  ## file: the gates must run what was published, and nothing else.
  let dir = artefactDir()
  let path = dir / debArch / "repro"
  let sumFile = dir / debArch / "repro.sha256"
  if not fileExists(path) or not fileExists(sumFile):
    raise newException(TestBedError, "no add-on artefact at " & path &
      "; build it with scripts/build_addon_static.sh" &
      (if mutation().len > 0: " --mutation " & mutation() else: "") &
      (if testSeams(): " --test-seams" else: "") &
      " " & debArch)
  let published = readFile(sumFile).splitWhitespace()[0]
  var ctx: sha256
  ctx.init()
  let bytes = readFile(path)
  ctx.update(bytes)
  let actual = toLowerAscii($ctx.finish())
  if actual != published:
    raise newException(TestBedError, path & " hashes to " & actual &
      " but its published digest is " & published)
  (path, published)

# ---------------------------------------------------------------------------
# Images.
# ---------------------------------------------------------------------------

proc fileDigest(path, algo: string): string =
  var f = open(path, fmRead)
  defer: f.close()
  var buf = newString(1 shl 20)
  if algo == "sha512":
    var ctx: sha512
    ctx.init()
    while true:
      let n = f.readBuffer(addr buf[0], buf.len)
      if n <= 0: break
      ctx.update(cast[ptr byte](addr buf[0]), uint(n))
    toLowerAscii($ctx.finish())
  else:
    var ctx: sha256
    ctx.init()
    while true:
      let n = f.readBuffer(addr buf[0], buf.len)
      if n <= 0: break
      ctx.update(cast[ptr byte](addr buf[0]), uint(n))
    toLowerAscii($ctx.finish())

proc fetchImage*(b: BaseImage): string =
  ## The verified cached image, downloading it first if needed. A cached
  ## file with the wrong digest is an error, never silently replaced.
  let dir = cacheDir() / "images"
  createDir(dir)
  result = dir / b.file
  if not fileExists(result):
    let part = result & ".part-" & $getCurrentProcessId()
    let rc = execCmd("curl -sSfL --retry 3 -o " & quoteShell(part) & " " &
                     quoteShell(b.url))
    if rc != 0:
      removeFile(part)
      raise newException(TestBedError, "download failed: " & b.url)
    let d = fileDigest(part, b.algo)
    if d != b.digest:
      removeFile(part)
      raise newException(TestBedError, b.url & ": " & b.algo & " " & d &
        " does not match the pin " & b.digest)
    moveFile(part, result)
  let d = fileDigest(result, b.algo)
  if d != b.digest:
    raise newException(TestBedError, "cached image " & result &
      " does not match its pin (" & b.algo & " " & d & "); delete it by hand " &
      "after checking why")

# ---------------------------------------------------------------------------
# Runs and guests.
# ---------------------------------------------------------------------------

type
  GuestKind* = enum gkQemu, gkIncus

  Guest* = ref object
    base*: BaseImage
    kind*: GuestKind
    name*: string
    runDir*: string
    ownerToken*: string
    diskPath*: string
    seedPath*: string
    keyPath*: string
    serialLog*: string
    booted*: bool
    log*: seq[string]
    when defined(gostiAvailable):
      qemu*: QemuBootBackend
      incus*: IncusBackend
      vm*: VmHandle
      incusNetwork*: string

  ExecOut* = object
    exitCode*: int
    stdout*: string
    stderr*: string

proc note*(g: Guest; s: string) =
  let line = $now() & " [" & g.name & "] " & s
  g.log.add(line)
  stderr.writeLine(line)

proc randomHex(n: int): string =
  var r = initRand()
  for i in 0 ..< n:
    result.add(toHex(r.rand(15), 1).toLowerAscii())

proc claimRunDir(name: string): tuple[dir, token: string] =
  let runs = cacheDir() / "runs"
  createDir(runs)
  let dir = runs / name
  # createDir would adopt an existing directory; an exclusive mkdir does not.
  if posix.mkdir(dir.cstring, Mode(0o700)) != 0:
    raise newException(TestBedError, "run directory already exists: " & dir)
  let token = randomHex(32)
  writeFile(dir / "owner-token", token)
  (dir, token)

proc releaseRunDir(dir, token: string) =
  if dir.len == 0 or not dirExists(dir): return
  let f = dir / "owner-token"
  if not fileExists(f) or readFile(f) != token:
    raise newException(TestBedError, "refusing to remove " & dir &
      ": its owner token is not this run's")
  removeDir(dir)

proc freePort(): int =
  ## A loopback TCP port the kernel just handed out (bound to port 0 and
  ## released again).
  let s = newSocket()
  defer: s.close()
  s.bindAddr(Port(0), "127.0.0.1")
  int(s.getLocalAddr()[1])

proc userData(pub: string): string =
  "#cloud-config\n" &
  "disable_root: false\n" &
  "ssh_pwauth: false\n" &
  "ssh_authorized_keys:\n" &
  "  - " & pub.strip() & "\n" &
  "growpart:\n  mode: auto\n  devices: ['/']\n"

when defined(gostiAvailable):
  proc qemuArch(b: BaseImage): GuestArch =
    case b.debArch
    of "amd64": gaX86_64
    of "arm64": gaArm64
    else: gaArmv7

proc newGuest*(b: BaseImage): Guest =
  ## Claim a run and prepare (not boot) a guest of ``b``.
  when not defined(gostiAvailable):
    raise newException(TestBedError,
      "gosti is not available: set GOSTI_SRC to gosti's src directory")
  else:
    let name = QemuNamePrefix & $getCurrentProcessId() & "-" & randomHex(6)
    let (dir, token) = claimRunDir(name)
    result = Guest(base: b, name: name, runDir: dir, ownerToken: token,
                   kind: (if useIncus(): gkIncus else: gkQemu))
    if result.kind == gkIncus:
      if b.name notin IncusImages:
        raise newException(TestBedError, "no Incus image for " & b.name)
      result.incus = newIncusBackend()
      return
    let image = fetchImage(b)
    result.keyPath = dir / "id_ed25519"
    if execCmd("ssh-keygen -q -t ed25519 -N '' -C repro-addon-testbed -f " &
               quoteShell(result.keyPath)) != 0:
      raise newException(TestBedError, "ssh-keygen failed")
    result.seedPath = dir / "seed.iso"
    writeNoCloudIso(result.seedPath, userData(readFile(result.keyPath & ".pub")),
      "instance-id: " & name & "\nlocal-hostname: addon-tb\n")
    result.diskPath = dir / "disk.qcow2"
    let fmt = if b.file.endsWith(".img"): "qcow2" else: "qcow2"
    if execCmd("qemu-img create -q -f qcow2 -F " & fmt & " -b " &
               quoteShell(image) & " " & quoteShell(result.diskPath) &
               " 8G") != 0:
      raise newException(TestBedError, "qemu-img create failed")
    result.serialLog = dir / "serial.log"
    result.qemu = newQemuBootBackend(stateDir = cacheDir() / "qemu-state",
      namePrefix = QemuNamePrefix, sshUser = "root", sshKeyPath = result.keyPath)

proc bootTimeout(g: Guest): int =
  case g.base.debArch
  of "amd64": 300
  else: 2400            # TCG emulation

when defined(gostiAvailable):
  proc bootQemu(g: Guest; readonly: bool) =
    var spec = BootMediaSpec(name: g.name, kind: bmkQcow2,
      mediaPath: g.diskPath, secondaryIsoPath: g.seedPath,
      cpus: (if g.base.debArch == "amd64": 2 else: 4),
      memoryMB: 2048,
      generation: (if g.base.debArch == "amd64": 1 else: 2),
      acceleration: baAuto, sshForwardPort: freePort(),
      serialLogPath: g.serialLog, guestArch: qemuArch(g.base),
      diskReadonly: readonly, diskInPlace: true)
    g.note("booting " & g.base.name & (if readonly: " (disk read-only)" else: ""))
    g.vm = g.qemu.bootFromMedia(spec)
    g.qemu.startAndAwaitReady(g.vm, timeoutSec = g.bootTimeout())
    g.booted = true
    g.note("ssh ready on port " & $g.vm.sshPort)

  proc bootIncus(g: Guest) =
    # Bridge names are kernel interface names: at most 15 characters, and
    # incus wants them to start and end alphanumeric.
    g.incusNetwork = "ratb" & g.ownerToken[0 ..< 10]
    let third = 100 + (getCurrentProcessId() mod 100)
    discard g.incus.createOwnedNetwork(g.incusNetwork,
      "10.231." & $third & ".1/24", g.ownerToken)
    g.vm = g.incus.provisionEphemeralClone(EphemeralIncusSpec(name: g.name,
      baseImage: IncusImages[g.base.name], ownerToken: g.ownerToken,
      network: g.incusNetwork))
    g.incus.startAndAwaitReady(g.vm, timeoutSec = 120)
    g.booted = true
    g.note("incus container running")

proc boot*(g: Guest; readonly = false) =
  when defined(gostiAvailable):
    if g.kind == gkIncus:
      if readonly:
        raise newException(TestBedError, "an Incus container has no disk " &
          "image to protect; read-only boots are QEMU only")
      bootIncus(g)
    else:
      bootQemu(g, readonly)


proc bootNoWait*(g: Guest) =
  ## Boot (read-write) without waiting for SSH: for a fixture that reports
  ## on the serial console instead of over the network.
  when defined(gostiAvailable):
    var spec = BootMediaSpec(name: g.name, kind: bmkQcow2,
      mediaPath: g.diskPath, secondaryIsoPath: g.seedPath,
      cpus: (if g.base.debArch == "amd64": 2 else: 4), memoryMB: 2048,
      generation: (if g.base.debArch == "amd64": 1 else: 2),
      acceleration: baAuto, sshForwardPort: freePort(),
      serialLogPath: g.serialLog, guestArch: qemuArch(g.base),
      diskInPlace: true)
    g.note("booting " & g.base.name & " (serial only)")
    g.vm = g.qemu.bootFromMedia(spec)
    g.booted = true

proc waitSerial*(g: Guest; needle: string; timeoutSec: int): string =
  ## Poll the serial log until it contains ``needle`` (or the guest's QEMU
  ## exits, or the timeout passes); return the log either way.
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    if fileExists(g.serialLog):
      result = readFile(g.serialLog)
      if needle in result: return
    sleep(2000)
  if fileExists(g.serialLog): result = readFile(g.serialLog)

proc exec*(g: Guest; script: string; timeoutSec = 900): ExecOut =
  ## Run ``script`` with ``sh -c`` as root in the guest. A transport
  ## failure (ssh's exit 255 before the remote shell ran: a reset while
  ## the guest's sshd is still being restarted by cloud-init, a slow TCG
  ## guest) is retried a few times; a command that ran is never re-run.
  when defined(gostiAvailable):
    let backend: VmBackend = if g.kind == gkIncus: g.incus else: g.qemu
    for attempt in 1 .. 4:
      let r = backend.execInGuest(g.vm, initTable[string, string](),
                                  @["sh", "-c", script], timeoutSec = timeoutSec)
      let transport = g.kind == gkQemu and r.exitCode == 255 and
        ("kex_exchange_identification" in r.stderr or
         "Connection reset" in r.stderr or "Connection refused" in r.stderr or
         "Connection timed out" in r.stderr or "Connection closed" in r.stderr)
      if transport and attempt < 4:
        g.note("ssh transport failure, retrying: " & r.stderr.strip())
        sleep(5000)
        continue
      return ExecOut(exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr)

proc run*(g: Guest; script: string; timeoutSec = 900): string =
  ## ``exec`` that must succeed; returns stdout.
  let r = g.exec(script, timeoutSec)
  if r.exitCode != 0:
    raise newException(TestBedError, "in " & g.name & ": `" & script &
      "` exited " & $r.exitCode & "\nstdout: " & r.stdout & "\nstderr: " &
      r.stderr)
  r.stdout

proc copyTo*(g: Guest; hostPath, guestPath: string) =
  when defined(gostiAvailable):
    if g.kind == gkIncus:
      g.incus.copyToGuest(g.vm, hostPath, guestPath)
    else:
      g.qemu.copyToGuest(g.vm, hostPath, guestPath)

proc shutdown*(g: Guest) =
  ## Power the guest off and wait for QEMU to exit (the disk is then
  ## quiescent and may be hashed). Incus containers are stopped.
  when defined(gostiAvailable):
    if not g.booted: return
    if g.kind == gkIncus:
      discard g.incus.runIncus(@["stop", g.name], timeoutSec = 120)
    else:
      discard g.exec("systemctl poweroff || poweroff", timeoutSec = 30)
      if not g.qemu.waitForShutdown(g.vm, g.bootTimeout()):
        g.note("guest did not power off in time; stopping QEMU")
      g.qemu.stopAndCleanup(g.vm, deleteVm = true)
    g.booted = false

proc destroy*(g: Guest) =
  ## Tear everything this run created down. Safe from ``finally``.
  if g == nil: return
  when defined(gostiAvailable):
    try:
      if g.kind == gkIncus:
        if g.vm != nil: g.incus.stopAndCleanup(g.vm, deleteVm = true)
        if g.incusNetwork.len > 0:
          discard g.incus.deleteOwnedNetwork(g.incusNetwork, g.ownerToken)
      elif g.vm != nil:
        g.qemu.stopAndCleanup(g.vm, deleteVm = true)
    except CatchableError as e:
      g.note("teardown: " & e.msg)
  try:
    releaseRunDir(g.runDir, g.ownerToken)
  except CatchableError as e:
    g.note("teardown: " & e.msg)

proc diskSha256*(g: Guest): string =
  ## SHA-256 of the guest's own qcow2 overlay (the base image under it is
  ## read-only to QEMU).
  fileDigest(g.diskPath, "sha256")

proc prepareBase*(g: Guest) =
  ## First-boot completion and the test bed's two base adjustments (see the
  ## module header): no unattended apt runs, and fresh apt lists.
  discard g.exec("cloud-init status --wait >/dev/null 2>&1 || true",
                 timeoutSec = g.bootTimeout())
  discard g.run("systemctl disable --now apt-daily.timer " &
    "apt-daily-upgrade.timer apt-listchanges.timer fwupd-refresh.timer " &
    "motd-news.timer ua-timer.timer 2>/dev/null; " &
    "systemctl stop apt-daily.service apt-daily-upgrade.service " &
    "unattended-upgrades.service 2>/dev/null; " &
    "systemctl mask --now unattended-upgrades.service 2>/dev/null; " &
    # fwupd is D-Bus activated at an unpredictable moment, and its first
    # start rewrites /etc/fwupd/fwupd.conf to mode 0640 (Ubuntu 24.04,
    # measured 2026-10-30 inside a collision-matrix run): base noise, not
    # the add-on's doing. Masked before the baseline like the timers.
    "systemctl mask --now fwupd.service 2>/dev/null; true")
  discard g.run("apt-get update -qq", timeoutSec = 1800)
  # Let anything first boot started settle.
  discard g.exec("systemctl is-system-running --wait >/dev/null 2>&1; true",
                 timeoutSec = 600)

proc installArtefact*(g: Guest; dir = "/root/addon"): tuple[repro, sha: string] =
  ## Copy the static repro into the guest and verify it there against its
  ## published digest before it is ever executed -- the guest-side half of
  ## "the operator pins the digest on the command line".
  let a = artefact(g.base.debArch)
  discard g.run("mkdir -p " & dir)
  g.copyTo(a.path, dir & "/repro")
  discard g.run("cd " & dir & " && echo '" & a.sha256 & "  repro' | " &
                "sha256sum -c - && chmod 0755 repro && " &
                "ln -sf repro repro-addon-fingerprint")
  (dir & "/repro", a.sha256)

proc takeFingerprint*(g: Guest; repro: string): string =
  g.run(repro & " system addon fingerprint")

proc gostiHead*(): string

proc writeRecord*(gate: string; data: JsonNode): string =
  ## Persist one gate run's record (what ran, against what, the verdict).
  if not data.hasKey("gosti"): data["gosti"] = %gostiHead()
  let path = recordsDir() / (gate & "-" & now().format("yyyyMMdd'T'HHmmss") &
                             "-" & $getCurrentProcessId() & ".json")
  writeFile(path, pretty(data) & "\n")
  path

proc gostiHead*(): string =
  ## The gosti revision this gate compiled against (``GOSTI_SRC``'s
  ## checkout), recorded with every gate run.
  let src = getEnv("GOSTI_SRC")
  if src.len == 0: return "unknown"
  let (o, c) = execCmdEx("git -C " & quoteShell(src / "..") & " rev-parse HEAD")
  result = if c == 0: o.strip() else: "unknown"
  let (s, _) = execCmdEx("git -C " & quoteShell(src / "..") &
                         " status --porcelain --untracked-files=no")
  if s.strip().len > 0: result.add("-dirty")

proc gitHead*(): string =
  let (o, c) = execCmdEx("git -C " & quoteShell(reproRoot()) &
                         " rev-parse HEAD")
  result = if c == 0: o.strip() else: "unknown"
  let (s, _) = execCmdEx("git -C " & quoteShell(reproRoot()) &
                         " status --porcelain --untracked-files=no")
  if s.strip().len > 0: result.add("-dirty")

# ---------------------------------------------------------------------------
# Comparisons the gates share. They run on the host, with the same library
# code the add-on uses, over text pulled out of the guest.
# ---------------------------------------------------------------------------



proc ledgerOf*(g: Guest): string =
  g.run("cat /var/lib/repro/system/addon-ledger")

proc planDigestOf*(preflightOutput: string): string =
  for line in preflightOutput.splitLines():
    if line.startsWith("plan digest:"):
      return line["plan digest:".len .. ^1].strip()
  raise newException(TestBedError, "no plan digest in preflight output:\n" &
                     preflightOutput)

proc deltaReport*(before, after: string; ledgerBefore, ledgerAfter: string):
    tuple[ok: bool; text: string] =
  ## Does ``fingerprint(after) - fingerprint(before)`` equal the delta the
  ## two ledgers account for, exactly? "" for a ledger means "no add-on".
  let lb = if ledgerBefore.len == 0: Ledger() else: parseLedger(ledgerBefore)
  let la = if ledgerAfter.len == 0: Ledger() else: parseLedger(ledgerAfter)
  let d = diff(parseFingerprint(before), parseFingerprint(after))
  let r = matchExpectations(d, expectedDelta(lb, la))
  (r.ok, (if r.ok: "fingerprint diff == ledger delta (" & $d.len & " records)"
          else: renderExpectationReport(r)))

proc identityReport*(before, after: string;
                     exceptions: openArray[string] = []):
    tuple[ok: bool; text: string] =
  ## Byte identity modulo the enumerated exceptions.
  var rules: seq[ExceptionRule]
  for e in exceptions: rules.add(parseExceptionRule(e))
  let d = applyExceptions(diff(parseFingerprint(before),
                               parseFingerprint(after)), rules)
  (d.len == 0, (if d.len == 0: "fingerprints identical" else: renderDiff(d)))

proc waitPoweredOff*(g: Guest; timeoutSec: int): bool =
  ## Wait for a guest that is powering itself off (or rebooting: QEMU runs
  ## with ``-no-reboot``, so a reboot ends the process too), then release
  ## QEMU's run state. The disk, which this run owns, is kept.
  when defined(gostiAvailable):
    if not g.booted: return true
    result = g.qemu.waitForShutdown(g.vm, timeoutSec)
    g.qemu.stopAndCleanup(g.vm, deleteVm = true)
    g.booted = false

# ---------------------------------------------------------------------------
# Trust anchors for bootstrap.
# ---------------------------------------------------------------------------

import repro_peer_cache/auth as peerAuth

const TestCacheUrl* = "https://cache.addon-testbed.invalid:7878"
  ## Never contacted: nothing in the gates substitutes. It only has to be a
  ## syntactically valid cache URL for the trust configuration.

type Anchors* = object
  deploySigners*: seq[string]
  cachePublishers*: seq[string]
  flags*: string            ## the preflight / bootstrap options naming them

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc installAnchors*(g: Guest; dir = "/root/addon"): Anchors =
  ## Two deploy-signer keys and one cache-publisher key, freshly generated,
  ## written to anchor files and copied into the guest.
  for i in 0 ..< 2:
    result.deploySigners.add(hexKey(peerAuth.generateKeypair().publicKey))
  result.cachePublishers.add(hexKey(peerAuth.generateKeypair().publicKey))
  writeFile(g.runDir / "deploy-signers.anchors",
            "# test deploy signers\n" & result.deploySigners.join("\n") & "\n")
  writeFile(g.runDir / "cache-publishers.anchors",
            result.cachePublishers.join("\n") & "\n")
  discard g.run("mkdir -p " & dir)
  g.copyTo(g.runDir / "deploy-signers.anchors", dir & "/deploy-signers.anchors")
  g.copyTo(g.runDir / "cache-publishers.anchors", dir & "/cache-publishers.anchors")
  result.flags = " --deploy-signers " & dir & "/deploy-signers.anchors" &
                 " --cache-publishers " & dir & "/cache-publishers.anchors" &
                 " --cache-url " & TestCacheUrl

# ---------------------------------------------------------------------------
# Steps the A3 gates share: bootstrapping a guest, applying a profile, and
# building an `equivs` fixture package inside the guest.
# ---------------------------------------------------------------------------

type
  StepFn* = proc(name: string; ok: bool; detail: string)
    ## A gate's step recorder (see each gate's ``runBase``).

proc bootstrapAddon*(g: Guest; repro: string; step: StepFn): bool =
  ## Preflight, then bootstrap with the acknowledged plan digest. False when
  ## either failed (the step is recorded red).
  let anchors = g.installAnchors()
  let pre = g.exec(repro & " system addon preflight" & anchors.flags)
  step("preflight is compatible", pre.exitCode == 0, pre.stdout & pre.stderr)
  if pre.exitCode != 0: return false
  let boot = g.exec(repro & " system addon bootstrap --plan " &
                    planDigestOf(pre.stdout) & anchors.flags, timeoutSec = 1800)
  step("bootstrap", boot.exitCode == 0, boot.stdout & boot.stderr)
  boot.exitCode == 0

proc putProfile*(g: Guest; name, text: string): string =
  ## Write a profile into the guest; returns its guest path.
  writeFile(g.runDir / (name & ".profile"), text)
  result = "/root/addon/" & name & ".profile"
  g.copyTo(g.runDir / (name & ".profile"), result)

proc applyProfile*(g: Guest; repro, name, text: string; flags = ""): ExecOut =
  ## ``repro infra apply --profile <text>`` in the guest.
  let p = g.putProfile(name, text)
  g.exec(repro & " infra apply --profile " & p & flags, timeoutSec = 1200)

proc planProfile*(g: Guest; repro, name, text: string; flags = ""): ExecOut =
  ## ``repro infra plan --profile <text>`` in the guest.
  let p = g.putProfile(name, text)
  g.exec(repro & " infra plan --profile " & p & flags)

proc adoptResource*(g: Guest; repro, name, text, address: string): ExecOut =
  ## ``repro system adopt <address> --profile <text>`` in the guest.
  let p = g.putProfile(name, text)
  g.exec(repro & " system adopt " & address & " --profile " & p,
         timeoutSec = 1200)

proc sha256InGuest*(g: Guest; path: string): string =
  ## The SHA-256 of a guest file, or "absent" / "link" / "dir".
  let r = g.exec("if [ -L " & path & " ]; then echo link; " &
    "elif [ -d " & path & " ]; then echo dir; " &
    "elif [ -f " & path & " ]; then sha256sum " & path & " | cut -d' ' -f1; " &
    "else echo absent; fi")
  r.stdout.strip()

proc installEquivs*(g: Guest) =
  ## ``equivs`` builds a real Debian package from a control file; it is how
  ## the gates get a package that owns a conffile of their choosing.
  discard g.run("export DEBIAN_FRONTEND=noninteractive; " &
    "apt-get install -y -qq equivs >/dev/null", timeoutSec = 1800)

proc buildEquivsPackage*(g: Guest; pkg, version: string;
                         files: seq[tuple[name, content, destDir: string]]):
    string =
  ## Build ``<pkg>_<version>_all.deb`` in the guest with ``equivs-build``
  ## and return its path. Each file is installed under ``destDir``;
  ## debhelper marks every file under ``/etc`` a conffile, which is the
  ## point: the package then owns a conffile the add-on collides with.
  let dir = "/root/fixture/" & pkg & "-" & version
  var script = "set -e\nmkdir -p " & dir & "\ncd " & dir & "\n"
  var fileLines = ""
  for f in files:
    script.add("cat > " & f.name & " <<'REPRO_FIXTURE_EOF'\n" & f.content &
               "REPRO_FIXTURE_EOF\n")
    fileLines.add("Files: " & f.name & " " & f.destDir & "\n")
  script.add("cat > control <<'REPRO_FIXTURE_EOF'\n" &
    "Section: misc\nPriority: optional\nStandards-Version: 4.6.2\n" &
    "Package: " & pkg & "\nVersion: " & version & "\n" &
    "Maintainer: Reprobuild add-on test bed <addon@testbed.invalid>\n" &
    "Architecture: all\n" & fileLines &
    "Description: Reprobuild add-on test fixture package\n" &
    " A package the add-on's collision gates collide with.\n" &
    "REPRO_FIXTURE_EOF\n")
  script.add("equivs-build control >/dev/null 2>&1 || equivs-build control\n")
  script.add("ls " & dir & "/" & pkg & "_" & version & "_all.deb\n")
  g.run(script, timeoutSec = 900).strip()

# ---------------------------------------------------------------------------
# Hard resets and paused switches (milestone A5's crash-consistency gates).
# ---------------------------------------------------------------------------

const
  SeamDir* = "/var/lib/repro/system/addon"
    ## Where the seam build's pause control files live (``seams.nim``).

proc hardReset*(g: Guest) =
  ## QEMU ``system_reset`` through the guest's QMP socket: no shutdown, no
  ## sync, guest RAM lost. Under ``-no-reboot`` QEMU exits on it; the disk
  ## (this run's overlay) keeps exactly what reached it, and ``boot``
  ## starts the same disk again.
  when defined(gostiAvailable):
    if g.kind != gkQemu:
      raise newException(TestBedError, "a hard reset needs a QEMU guest")
    let r = g.qemu.systemReset(g.vm)
    if not r.ok:
      raise newException(TestBedError, "system_reset failed: " & r.detail)
    g.note("system_reset sent")
    if not g.waitPoweredOff(120):
      raise newException(TestBedError, "QEMU did not exit after system_reset")

proc startSwitchPausedAt*(g: Guest; repro, name, text, point: string;
                          timeoutSec = 900): ExecOut =
  ## Start ``repro infra apply --profile <text>`` in the background with the
  ## seam build's pause at ``point``, and wait until the switch reports it
  ## has stopped there. Returns the paused-at check (exit 0 when reached);
  ## a switch that ended without reaching the point is a non-zero result
  ## carrying its log.
  if not testSeams():
    raise newException(TestBedError, "a paused switch needs the seam build " &
      "(REPRO_ADDON_TEST_SEAMS=1)")
  let p = g.putProfile(name, text)
  discard g.run("rm -f " & SeamDir & "/test-paused-at " & SeamDir &
    "/test-resume /root/addon/bg-apply.log /root/addon/bg-apply.rc; printf '%s\\n' " &
    point & " > " & SeamDir & "/test-pause-at; sync")
  discard g.run("setsid nohup sh -c '" & repro & " infra apply --profile " & p &
    " > /root/addon/bg-apply.log 2>&1; echo $? > /root/addon/bg-apply.rc' " &
    "> /dev/null 2>&1 < /dev/null &")
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let r = g.exec("cat " & SeamDir & "/test-paused-at 2>/dev/null; " &
                   "cat /root/addon/bg-apply.rc 2>/dev/null")
    if r.stdout.strip() == point:
      return ExecOut(exitCode: 0, stdout: point)
    if r.stdout.strip().len > 0 and r.stdout.strip() != point:
      # The apply ended (its exit code is there) without pausing.
      return ExecOut(exitCode: 1, stdout: r.stdout,
        stderr: g.exec("cat /root/addon/bg-apply.log").stdout)
    sleep(500)
  ExecOut(exitCode: 1, stderr: "the switch did not reach " & point &
    " within " & $timeoutSec & " s: " &
    g.exec("cat /root/addon/bg-apply.log").stdout)

proc resumeSwitch*(g: Guest; timeoutSec = 900): ExecOut =
  ## Let a paused switch continue and wait for it to end; its exit code and
  ## output are returned.
  discard g.run("touch " & SeamDir & "/test-resume")
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let rc = g.exec("cat /root/addon/bg-apply.rc 2>/dev/null").stdout.strip()
    if rc.len > 0:
      return ExecOut(exitCode: (try: parseInt(rc) except ValueError: 255),
        stdout: g.exec("cat /root/addon/bg-apply.log").stdout)
    sleep(500)
  ExecOut(exitCode: 255, stderr: "the resumed switch did not end in time")

proc waitReasserted*(g: Guest; timeoutSec = 900): string =
  ## After a boot: wait until the re-assert unit has run, and return its
  ## journal for this boot.
  let deadline = epochTime() + timeoutSec.float
  while epochTime() < deadline:
    let st = g.exec("systemctl show -p ActiveState --value " &
                    "repro-addon-reassert.service").stdout.strip()
    if st in ["active", "failed"]: break
    sleep(1000)
  g.exec("journalctl -b -o cat --no-pager -u repro-addon-reassert.service").stdout

proc hardResetAfterSettle*(g: Guest; settleSec = 8) =
  ## Hard-reset a guest whose switch is paused, after ``settleSec``: long
  ## enough for ext4's journal (committed every 5 s) to make the switch's
  ## renames durable, too short for the kernel's writeback (dirty data
  ## older than 30 s) to have written file contents nobody fsynced. A
  ## missing fsync shows in exactly this window -- the file is renamed into
  ## place on disk, its bytes are not -- which is why the gate waits for it
  ## rather than resetting at once (when nothing at all has reached the
  ## disk and a missing fsync would look like a clean earlier state).
  sleep(settleSec * 1000)
  g.hardReset()

proc rolledBackRecords*(g: Guest): int =
  ## How many `rolled-back` records the generations' apply logs hold.
  let r = g.exec("cat /var/lib/repro/system/generations/*/log/apply.log " &
                 "2>/dev/null | grep -a -o rolled-back | wc -l")
  try: parseInt(r.stdout.strip()) except ValueError: -1
