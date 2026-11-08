## Gate ``e2e_addon_zero_touch_image_synthesis_boots_converged`` (milestone
## A16; ReproOS Add-On Mode §6.5.2, §6.5.4).
##
## A ready-to-flash image of a test-bed host is synthesised with ``repro
## infra image`` from a base of the matrix, then booted -- from a fresh
## overlay of the output, with no seed volume, no network command and no
## login before the checks. The image's own cloud-init seed (declared in the
## profile's ``baseOs:``) authorises this run's key; everything else must
## already be there:
##
## - the guest reaches ``multi-user.target`` and the system is ``running``;
## - ``/repro/store`` is mounted read-only and holds the add-on binary's
##   prefix, generation 0's files prefix and the fixture apt closure;
## - ``/etc/repro`` holds exactly the anchors the profile names;
## - generation 0 and the host's initial generation are recorded, the
##   latter ``current``;
## - the profile's service (``tb-image-hello.service``, running from its apt
##   closure) and generation 0's units are active;
## - the first boot's ``repro-addon-reassert.service`` reported ``ok``;
## - ``repro infra plan`` on the booted guest predicts nothing (no ledger
##   change, no transition) and ``repro system addon verify`` is ok;
## - the boot was a first boot: a machine id and SSH host keys of its own,
##   and cloud-init ran the declared instance.
##
## Falsifying mutations (``REPRO_ADDON_MUTATION``):
## ``image-omits-gen0-ledger`` and ``image-omits-store-closure`` make the
## assembly delete the ledger copy, or the apt closure's store prefixes,
## before power-off. The first boot's re-assert must then report
## ``degraded`` (and the plan or verify fail): red.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` (``just
## e2e_addon_zero_touch_image_synthesis_boots_converged``). Bases:
## ``REPRO_ADDON_BASES`` (the recipe's default: ``debian-13-amd64``). The
## full engine must be built (``just build``): ``repro infra image`` runs
## on the build host, the static add-on (built by the gate runner, mutated
## when asked) inside the image.
##
## *Mocking.* None of behaviour. The fixture ``.deb`` is built here (a
## static binary in a ustar-in-ar container, ``deb_fixture_support``) and
## handed to the image command's ``--deb-cache``, which checks it against
## the lock exactly as it checks a download; the lock's archive URL is
## never contacted. The upstream image is the test bed's digest-pinned
## cloud image, named by ``file://`` URL with its SHA-256.

import std/[json, os, osproc, strutils, times, unittest]

import repro_test_support/reasoned_skip

import repro_dsl_stdlib/packages/apt_closure
import repro_peer_cache/auth as peerAuth

import ./addon_testbed
import ./deb_fixture_support

const
  Gate = "e2e_addon_zero_touch_image_synthesis_boots_converged"
  Host = "tb-image"
  ServiceUnit = "tb-image-hello.service"

proc hexKey(k: openArray[byte]): string =
  for b in k: result.add(toHex(int(b), 2).toLowerAscii())

proc engine(): string =
  ## The full engine of this checkout: `repro infra image` compiles the
  ## profile on the build host.
  result = reproRoot() / "build" / "bin" / "repro"
  if not fileExists(result):
    raise newException(TestBedError, "no engine at " & result &
      "; build it with `just build`")

proc helloDeb(work, debArch: string): tuple[path: string; lock: AptClosureLock] =
  ## A closure whose only member ships a static binary that waits forever:
  ## the unit's /usr IS the closure's, so it cannot be a script.
  let src = reproRoot() / "tests/e2e/addon/fixtures/image_service/a16_pause.c"
  let bin = work / "tb-hello"
  let cc = staticCc(debArch)
  let (o, c) = execCmdEx(quoteShell(cc) & " -static -O2 -o " & quoteShell(bin) &
                         " " & quoteShell(src))
  if c != 0: raise newException(TestBedError, "static cc failed: " & o)
  result.path = work / "tb-hello.deb"
  writeDeb(result.path, @[dir("./"), dir("./usr/"), dir("./usr/bin/"),
    ("./usr/bin/tb-hello", '0', 0o755, readFile(bin), "")])
  result.lock = fixtureLock("tb-hello", result.path, debArch)

proc profileText(b: BaseImage; imageUrl, imageSha, pubKey: string): string =
  """import repro_profile

const helloLock = staticRead("tb-hello.lock")

profile "tb-image":
  baseOs:
    image: """" & imageUrl & """"
    sha256: """" & imageSha & """"
    arch: """" & b.debArch & """"
    buildBoot: "pc"
    diskSize: "6G"
    hostname: "tb-image"
    layout:
      disks:
        "main":
          table: "gpt"
          partitions:
            "root":
              size: "100%"
              content:
                filesystem:
                  format: "ext4"
                  mountpoint: "/"
            "bios":
              size: "3M"
            "esp":
              size: "124M"
              content:
                filesystem:
                  format: "vfat"
                  mountpoint: "/boot/efi"
    cloudInit:
      seed: "rootSeedDir"
      userData: "#cloud-config\ndisable_root: false\nssh_pwauth: false\nssh_authorized_keys:\n  - """ &
        pubKey & """\n"
      metaData: "instance-id: tb-image-first-boot\nlocal-hostname: tb-image\n"
    bootstrap:
      deploySigners: "deploy-signers.anchors"
      cachePublishers: "cache-publishers.anchors"
      cacheUrl: """" & TestCacheUrl & """"

  addOn:
    managedEtcPrefixes:
      "/etc/tb-image/"

  resources:
    fsSystemFile(path = "/etc/tb-image/motd",
      content = "built by repro infra image\n", address = "motd")
    systemdSystemUnit(name = "tb-image-hello.service",
      content = "[Unit]\nDescription=A16 image fixture\n\n[Service]\nExecStart=/usr/bin/tb-hello\nProtectSystem=strict\n\n[Install]\nWantedBy=multi-user.target\n",
      aptClosureLock = helloLock,
      floorExceptions = @["serviceFloor: a test fixture binary"],
      healthCheck = "active", address = "hello")
"""

proc runBase(b: BaseImage; record: JsonNode; work: string): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    # The inputs: the pinned upstream image, anchors, a key, a closure.
    let upstream = fetchImage(b)
    let (sha, _) = execCmdEx("sha256sum " & quoteShell(upstream))
    let imageSha = sha.splitWhitespace()[0]
    let prof = work / "profile"
    createDir(prof)
    var signers: seq[string]
    for i in 0 ..< 2: signers.add hexKey(peerAuth.generateKeypair().publicKey)
    let publisher = hexKey(peerAuth.generateKeypair().publicKey)
    writeFile(prof / "deploy-signers.anchors", "# A16 signers\n" &
              signers.join("\n") & "\n")
    writeFile(prof / "cache-publishers.anchors", publisher & "\n")
    let key = work / "id_ed25519"
    discard execCmd("ssh-keygen -q -t ed25519 -N '' -C a16-image -f " &
                    quoteShell(key))
    let hello = helloDeb(work, b.debArch)
    writeFile(prof / "tb-hello.lock", renderAptClosureLock(hello.lock))
    let debs = work / "debs"
    createDir(debs)
    copyFile(hello.path, debs / (hello.lock.debs[0].sha256 & ".deb"))
    writeFile(prof / "system.nim", profileText(b, "file://" & upstream,
      imageSha, readFile(key & ".pub").strip()))
    let (addonPath, addonSha) = artefact(b.debArch)
    record["artefactSha256"] = %addonSha
    record["upstream"] = %*{"file": upstream, "sha256": imageSha}

    # The image, built on this host without privilege.
    let output = work / "tb-image.img.xz"
    let cmd = quoteShell(engine()) & " infra image --host " & Host &
      " --profile " & quoteShell(prof / "system.nim") &
      " --addon-binary " & quoteShell(addonPath) & " --addon-sha256 " & addonSha &
      " --deb-cache " & quoteShell(debs) & " --compress xz --output " &
      quoteShell(output)
    let started = epochTime()
    let (imgOut, imgRc) = execCmdEx(cmd)
    record["imageCommand"] = %cmd
    record["imageSeconds"] = %int(epochTime() - started)
    step("repro infra image synthesises the image", imgRc == 0 and
         fileExists(output), imgOut)
    if imgRc != 0: return fails
    let manifest = parseJson(readFile(output & ".manifest.json"))
    record["manifest"] = manifest
    let (osha, _) = execCmdEx("sha256sum " & quoteShell(output))
    step("the output's digest is the one beside it",
         readFile(output & ".sha256").splitWhitespace()[0] ==
           osha.splitWhitespace()[0], readFile(output & ".sha256"))
    let raw = work / "tb-image.raw"
    let (xo, xc) = execCmdEx("xz -dc " & quoteShell(output) & " > " &
                             quoteShell(raw))
    step("the xz output unpacks", xc == 0, xo)

    # The boot: a fresh overlay of the output, the image's own seed.
    g = newImageGuest(b, raw, key)
    g.boot()
    let running = g.exec("systemctl is-system-running --wait", timeoutSec = 600)
    step("the first boot reaches a running system", running.stdout.strip() ==
         "running", running.stdout & running.stderr &
         g.exec("systemctl --failed --no-legend").stdout)
    let mu = g.exec("systemctl is-active multi-user.target")
    step("multi-user.target is active", mu.stdout.strip() == "active", mu.stdout)
    let ci = g.exec("cloud-init status --long; cloud-init query instance-id")
    step("cloud-init ran the declared instance", "status: done" in ci.stdout and
         "tb-image-first-boot" in ci.stdout, ci.stdout & ci.stderr)
    let mid = g.exec("cat /etc/machine-id; ls /etc/ssh/ssh_host_*_key.pub")
    step("a first boot: its own machine id and SSH host keys",
         mid.exitCode == 0 and mid.stdout.splitLines()[0].len == 32, mid.stdout)

    let store = g.exec("findmnt -n -o OPTIONS /repro/store; " &
                       "ls -d /repro/store/prefixes/*/*")
    let prefixes = store.stdout
    step("/repro/store is mounted read-only", store.exitCode == 0 and
         prefixes.splitLines()[0].split(',')[0] == "ro", prefixes)
    let union = aptClosurePrefixPath(AddOnSystemStoreRoot, hello.lock)
    step("the store holds the fixture closure", union in prefixes, prefixes)
    let reproExe = manifest["assembly"]["reproExe"].getStr()
    step("the store holds the add-on binary", reproExe.len > 0 and
         g.exec("test -x " & quoteShell(reproExe)).exitCode == 0, reproExe)
    let anchors = g.exec("cat /etc/repro/anchors/deploy-signers.anchors; " &
                         "cat /etc/repro/caches.conf")
    var anchorsOk = anchors.exitCode == 0 and publisher in anchors.stdout
    for s in signers: anchorsOk = anchorsOk and s in anchors.stdout
    step("/etc/repro holds exactly the declared anchors", anchorsOk,
         anchors.stdout)

    let status = g.exec(reproExe & " system addon status")
    record["status"] = %status.stdout
    var current = ""
    for line in status.stdout.splitLines():
      if line.startsWith("current generation:"):
        current = line.split(':', 1)[1].strip()
    step("the initial generation is current", current.len > 0 and
         current == manifest["assembly"]["generationId"].getStr(),
         current & " / " & status.stdout)
    let gens = g.exec("ls /var/lib/repro/system/generations")
    step("generation 0 and the initial generation are recorded",
         gens.stdout.splitLines().len >= 2, gens.stdout)
    let active = g.exec("systemctl is-active " & ServiceUnit &
      " repro-addon.target repro-store.mount repro-addon-reassert.service")
    step("the profile's service and generation 0's units are active",
         active.exitCode == 0, active.stdout & active.stderr)
    # The report file could be the assembly boot's; this boot's journal
    # cannot.
    let report = g.exec("cat /var/lib/repro/system/addon/reassert-report")
    let journal = g.exec("journalctl -b -u repro-addon-reassert.service " &
                         "--no-pager -o cat")
    record["reassert"] = %(report.stdout & "\n--- journal ---\n" & journal.stdout)
    step("the first boot's re-assert reported ok",
         "\nrepro-addon reassert: ok\n" in "\n" & report.stdout and
           "repro-addon reassert: ok" in journal.stdout and
           "reassert: degraded" notin journal.stdout and
           "reassert: drift" notin journal.stdout,
         report.stdout & journal.stdout)
    writeFile(g.runDir / "applied.profile", manifest["profileText"].getStr())
    g.copyTo(g.runDir / "applied.profile", "/root/applied.profile")
    let plan = g.exec(reproExe & " infra plan --profile /root/applied.profile")
    record["plan"] = %(plan.stdout & plan.stderr)
    step("repro infra plan on the booted guest predicts nothing",
         plan.exitCode == 0 and "ledger diff: no change" in plan.stdout and
         "service transitions: none" in plan.stdout, plan.stdout & plan.stderr)
    let v = g.exec(reproExe & " system addon verify")
    step("repro system addon verify is ok", v.exitCode == 0 and
         "verify: ok" in v.stdout, v.stdout & v.stderr)
  except CatchableError as e:
    fails.add(b.name & ": " & e.msg)
    steps.add(%*{"step": "exception", "ok": false, "detail": e.msg})
  finally:
    record["steps"] = steps
    if g != nil:
      record["guest"] = %g.name
      record["log"] = %g.log
      g.destroy()
  fails

suite Gate:
  test "an image from repro infra image boots converged with no touch":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just " & Gate & ")")
    else:
      let work = getTempDir() / ("repro-a16-image-" & $getCurrentProcessId())
      createDir(work)
      defer: removeDir(work)
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(), "reprobuild": gitHead(),
          "gosti": gostiHead(), "started": $now().utc,
          "host": getEnv("HOSTNAME", "")}
        let f = runBase(b, record, work)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
