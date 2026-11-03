## Gate ``e2e_addon_adopt_hand_configured_service`` (milestone A13; ReproOS
## Add-On Mode §11.2, §13 decision 40).
##
## The fixture is two services hand-configured as rpi2's would be
## (decision 40), built in the guest the way an operator builds them:
##
## - ``alertmanager``: ``prometheus-alertmanager`` installed from apt (the
##   package's own unit disabled), a hand-written unit in
##   ``/etc/systemd/system``, its environment file in ``/etc/default``, its
##   configuration in ``/etc/alertmanager`` and its data in
##   ``/var/lib/alertmanager`` -- with real state in it: a silence created
##   through the API, snapshotted by a restart;
## - ``vaultwarden``: a binary copied to ``/usr/local/bin`` by hand, an
##   account made with ``useradd``, a tmpfiles fragment for its data
##   directory (named ``repro-vaultwarden.conf``, as the add-on's tmpfiles
##   class names its own), an environment file holding the admin token,
##   and its unit;
## - a local drop-in over the package's own ``prometheus-alertmanager``
##   unit, ``50-repro-nice.conf``.
##
## Then, on a bootstrapped add-on host:
##
## 1. **Describe.** ``repro system addon import --unit`` for each. The host
##    fingerprint is identical before and after (the import wrote nothing),
##    and each skeleton flags what it must: the distribution binary and its
##    package, the hand-installed binary, the admin token as a secret (the
##    environment file holding it is not declared, and the token is in no
##    skeleton), the package unit, the accounts and the state directories.
## 2. **Plan and adopt.** The two skeletons, as one profile, plan as
##    adoptions only (no create, update or reconcile), and the apply
##    commits a generation whose ledger records every pre-existing object
##    with the digest it had and ``collision = adopt`` -- the units, the
##    configuration files, the tmpfiles fragment (whose adoption runs
##    ``systemd-tmpfiles --create``) and the drop-in. The fingerprint is
##    unchanged but for the static tree link the commit moves, neither
##    service was restarted (its ``InvocationID`` is the same), and neither
##    state directory changed.
## 3. **Converge.** The hardened definitions: each service from a store
##    closure (alertmanager's apt closure from the archive; vaultwarden's
##    binary as a fixture ``.deb``, one-member closure), confinement, the
##    admin token as a credential instead of an environment line, the
##    account as a sysusers entry, the data directories in tmpfiles rules
##    and ``stateDirectories``. Both units then run from ``/repro/store``
##    and pass their health checks, and each data directory is
##    byte-identical (``repro system addon state digest``, every entry's
##    content, mode and owner) to what it was before the converge.
## 4. **Rollback.** ``repro system rollback`` to the adopted generation
##    puts the operator's own unit bytes back (the ledger kept them), the
##    services are healthy again, and the data directories are still the
##    same.
##
## Falsifying mutations:
## - ``REPRO_ADDON_MUTATION=import-writes-skeleton`` (the import keeps a copy
##   of its skeleton under ``/etc``): step 1's fingerprint differs; red.
## - ``REPRO_A13_MUTATION=converge-touches-state`` (gate-level: the converged
##   tmpfiles rule for alertmanager's directory names mode 0700 instead of
##   the directory's 0750): the converge changes the directory, step 3's
##   digest differs; red. This is the vacuity guard of the state check.
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1`` and ``REPRO_A12_PACKAGES`` (the
## reprobuild-packages checkout the vaultwarden binary was built in).
## Bases: ``REPRO_ADDON_BASES`` (amd64: the fixture ``.deb`` is amd64).
## apt reaches only the time-shifted snapshot mirror, at
## ``MirrorStamp``.
##
## *Mocking.* None: stock images, the real archive (through its snapshot
## service), real units and the real add-on.

import std/[json, os, sets, strutils, times, unittest]

import repro_test_support/reasoned_skip
import repro_infra
import repro_addon/[fingerprint, ledger]
import repro_dsl_stdlib/packages/apt_closure

import ./addon_testbed
import ./deb_fixture_support
import ./reference_services
import ./snapshot_mirror
import ./upgrade_support

const
  Gate = "e2e_addon_adopt_hand_configured_service"
  MirrorStamp* = "20261028T000000Z"
    ## After every amd64 base image's date: the archive as the images'
    ## packages left it, plus prometheus-alertmanager.

  AmUnit* = """[Unit]
Description=Alertmanager (configured by hand)
After=network-online.target

[Service]
User=prometheus
Group=prometheus
EnvironmentFile=/etc/default/alertmanager
ExecStart=/usr/bin/prometheus-alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager $ARGS
Restart=on-failure

[Install]
WantedBy=multi-user.target
"""
  AmDefault* = "# Set by hand.\nARGS=\"--web.listen-address=127.0.0.1:9093 --cluster.listen-address=\"\n"
  AmConfig* = "route:\n  receiver: \"null\"\nreceivers:\n  - name: \"null\"\n"
  AmState* = "/var/lib/alertmanager"
  VwUnit* = """[Unit]
Description=Vaultwarden (installed by hand)
After=network-online.target

[Service]
User=vaultwarden
Group=vaultwarden
EnvironmentFile=/etc/vaultwarden/vaultwarden.env
ExecStart=/usr/local/bin/vaultwarden
WorkingDirectory=/var/lib/vaultwarden
Restart=on-failure

[Install]
WantedBy=multi-user.target
"""
  VwEnvBase* = "DATA_FOLDER=/var/lib/vaultwarden\nROCKET_ADDRESS=127.0.0.1\n" &
    "ROCKET_PORT=8000\nWEB_VAULT_ENABLED=false\n"
  VwTmpfiles* = "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -\n"
  AmDropInDir* = "/etc/systemd/system/prometheus-alertmanager.service.d"
  AmDropIn* = "[Service]\nNice=5\n"
  VwState* = "/var/lib/vaultwarden"

type MutationStop = object of CatchableError
  ## Raised by a gate's step under a mutation once a step is red.

proc gateMutation*(): string = getEnv("REPRO_A13_MUTATION")

proc buildAlertmanager*(g: Guest; step: StepFn) =
  ## alertmanager, configured by hand from apt's package.
  let inst = g.exec("DEBIAN_FRONTEND=noninteractive apt-get install -y " &
    "--no-install-recommends prometheus-alertmanager 2>&1", timeoutSec = 1800)
  step("operator: apt installs prometheus-alertmanager", inst.exitCode == 0,
       inst.stdout.splitLines()[^min(5, inst.stdout.splitLines().len) .. ^1].join("\n"))
  discard g.run("systemctl disable --now prometheus-alertmanager.service")
  # A local drop-in over the package's own unit, named as the add-on
  # names its drop-ins (adopted as a `systemd.systemDropIn`).
  writeFile(g.runDir / "am.dropin", AmDropIn)
  discard g.run("mkdir -p " & AmDropInDir)
  g.copyTo(g.runDir / "am.dropin", AmDropInDir & "/50-repro-nice.conf")
  discard g.run("chmod 0644 " & AmDropInDir & "/50-repro-nice.conf && " &
    "systemctl daemon-reload")
  writeFile(g.runDir / "am.service", AmUnit)
  writeFile(g.runDir / "am.default", AmDefault)
  writeFile(g.runDir / "am.yml", AmConfig)
  discard g.run("mkdir -p /etc/alertmanager " & AmState & " && chown " &
    "prometheus:prometheus " & AmState & " && chmod 0750 " & AmState)
  g.copyTo(g.runDir / "am.service", "/etc/systemd/system/alertmanager.service")
  g.copyTo(g.runDir / "am.default", "/etc/default/alertmanager")
  g.copyTo(g.runDir / "am.yml", "/etc/alertmanager/alertmanager.yml")
  discard g.run("chmod 0644 /etc/systemd/system/alertmanager.service " &
    "/etc/default/alertmanager /etc/alertmanager/alertmanager.yml && " &
    "systemctl daemon-reload && systemctl enable --now alertmanager.service")
  let up = g.exec("for i in $(seq 1 60); do curl -sf -o /dev/null " &
    "http://127.0.0.1:9093/-/healthy && exit 0; sleep 1; done; exit 1")
  step("operator: alertmanager is up", up.exitCode == 0,
       g.exec("journalctl -u alertmanager --no-pager -n 30").stdout)
  # Real state: a silence, snapshotted to the data directory by a restart.
  let sil = g.exec("curl -sf -XPOST -H 'Content-Type: application/json' " &
    "http://127.0.0.1:9093/api/v2/silences -d '{\"matchers\":[{\"name\":" &
    "\"alertname\",\"value\":\"A13Adoption\",\"isRegex\":false}]," &
    "\"startsAt\":\"2026-01-01T00:00:00Z\",\"endsAt\":\"2036-01-01T00:00:00Z\"," &
    "\"createdBy\":\"operator\",\"comment\":\"kept across adoption\"}'")
  discard g.run("systemctl restart alertmanager.service; sleep 2")
  let files = g.exec("ls " & AmState).stdout
  step("operator: alertmanager holds state (a silence, snapshotted)",
       sil.exitCode == 0 and "silences" in files, sil.stdout & "\n" & files)

proc buildVaultwarden*(g: Guest; adminToken: string; step: StepFn) =
  ## vaultwarden, installed by hand from a downloaded binary.
  g.copyTo(vaultwardenBinary(), "/usr/local/bin/vaultwarden")
  writeFile(g.runDir / "vw.service", VwUnit)
  writeFile(g.runDir / "vw.env", VwEnvBase & "ADMIN_TOKEN=" & adminToken & "\n")
  writeFile(g.runDir / "vw.tmpfiles", VwTmpfiles)
  discard g.run("chmod 0755 /usr/local/bin/vaultwarden && useradd --system " &
    "--home-dir " & VwState & " --no-create-home --shell /usr/sbin/nologin " &
    "vaultwarden && mkdir -p /etc/vaultwarden")
  g.copyTo(g.runDir / "vw.service", "/etc/systemd/system/vaultwarden.service")
  g.copyTo(g.runDir / "vw.env", "/etc/vaultwarden/vaultwarden.env")
  g.copyTo(g.runDir / "vw.tmpfiles", "/etc/tmpfiles.d/repro-vaultwarden.conf")
  discard g.run("chmod 0644 /etc/systemd/system/vaultwarden.service " &
    "/etc/tmpfiles.d/repro-vaultwarden.conf && chmod 0600 " &
    "/etc/vaultwarden/vaultwarden.env && systemd-tmpfiles --create " &
    "/etc/tmpfiles.d/repro-vaultwarden.conf && systemctl daemon-reload && " &
    "systemctl enable --now vaultwarden.service")
  let up = g.exec("for i in $(seq 1 60); do curl -sf -o /dev/null " &
    "http://127.0.0.1:8000/alive && exit 0; sleep 1; done; exit 1")
  let files = g.exec("ls " & VwState).stdout
  step("operator: vaultwarden is up and holds state", up.exitCode == 0 and
       "db.sqlite3" in files,
       files & "\n" & g.exec("journalctl -u vaultwarden --no-pager -n 30").stdout)

proc mergeSkeletons*(texts: openArray[string]): string =
  ## One profile from several skeletons: their resources in order, the
  ## union of their managed prefixes.
  var merged: SystemProfile
  var prefixes: seq[string]
  for t in texts:
    let p = parseSystemProfile(t)
    merged.resources.add(p.resources)
    for x in p.addOn.managedEtcPrefixes:
      if x notin prefixes: prefixes.add(x)
  if prefixes.len > 0:
    merged.addOn = AddOnSettings(declared: true, managedEtcPrefixes: prefixes)
  renderProfileText(merged)

proc planVerdicts*(planOutput: string): seq[(string, string)] =
  ## (verdict, address) of each collision report line.
  var inReport = false
  for line in planOutput.splitLines():
    if line.startsWith("collision report"):
      inReport = true
      continue
    if inReport:
      if line.startsWith("  ") and not line.startsWith("    "):
        let f = line.strip().split('\t')
        if f.len >= 4: result.add((f[0], f[3]))
      elif not line.startsWith("    "):
        inReport = false

proc stateDigest*(g: Guest; repro, dir: string): string =
  g.run(repro & " system addon state digest " & dir).strip()

proc invocation(g: Guest; unit: string): string =
  g.run("systemctl show -P InvocationID " & unit).strip()

proc healthy(g: Guest; url: string): bool =
  g.exec("for i in $(seq 1 60); do curl -sf -o /dev/null " & url &
         " && exit 0; sleep 1; done; exit 1").exitCode == 0

proc q(s: string): string = quoteSystemValue(s)

proc convergedProfile*(amLock, vwLock: string; amTmpfilesMode: string): string =
  ## The hardened definitions (§11.2 step 4).
  let amUnit = """[Unit]
Description=Alertmanager (converged)
After=network-online.target

[Service]
User=prometheus
Group=prometheus
EnvironmentFile=/etc/default/alertmanager
ExecStart=/usr/bin/prometheus-alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager $ARGS
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/alertmanager

[Install]
WantedBy=multi-user.target
"""
  let vwUnit = """[Unit]
Description=Vaultwarden (converged)
After=network-online.target

[Service]
User=vaultwarden
Group=vaultwarden
EnvironmentFile=/etc/vaultwarden/vaultwarden.env
Environment=ADMIN_TOKEN_FILE=%d/admin-token
ExecStart=/usr/bin/vaultwarden
WorkingDirectory=/var/lib/vaultwarden
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/vaultwarden

[Install]
WantedBy=multi-user.target
"""
  "addOn {\n  managedEtcPrefixes = [\"/etc/alertmanager/alertmanager.yml\", " &
    "\"/etc/default/alertmanager\", \"/etc/vaultwarden/vaultwarden.env\"]\n}\n\n" &
  "secrets.secretFile {\n  service = \"vaultwarden\"\n  name = \"admin-token\"\n}\n\n" &
  "systemd.systemDropIn {\n  unit = \"prometheus-alertmanager.service\"\n" &
    "  name = \"nice\"\n  content = " & q(AmDropIn) & "\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/default/alertmanager\"\n  content = " &
    q(AmDefault) & "\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/alertmanager/alertmanager.yml\"\n  content = " &
    q(AmConfig) & "\n}\n\n" &
  "linux.tmpfilesRule {\n  name = \"repro-alertmanager.conf\"\n  content = " &
    q("d " & AmState & " " & amTmpfilesMode & " prometheus prometheus -\n") &
    "\n}\n\n" &
  "systemd.systemUnit {\n  name = \"alertmanager.service\"\n  content = " &
    q(amUnit) & "\n  aptClosureLock = " & q(amLock) &
    "\n  healthCheck = \"http://127.0.0.1:9093/-/healthy\"\n" &
    "  floorExceptions = [\"UMask: alertmanager rewrites its snapshots; " &
    "they keep the modes the service gave them before the converge\"]\n" &
    "  stateDirectories = [\"carry:" & AmState & "\"]\n" &
    "  depends_on = [\"fs.systemFile:/etc/default/alertmanager\", " &
    "\"fs.systemFile:/etc/alertmanager/alertmanager.yml\", " &
    "\"linux.tmpfilesRule:repro-alertmanager.conf\"]\n}\n\n" &
  "linux.sysusersEntry {\n  name = \"vaultwarden\"\n  description = " &
    "\"Vaultwarden\"\n  home = \"" & VwState & "\"\n}\n\n" &
  "linux.tmpfilesRule {\n  name = \"repro-vaultwarden.conf\"\n  content = " &
    q(VwTmpfiles) & "\n}\n\n" &
  "fs.systemFile {\n  path = \"/etc/vaultwarden/vaultwarden.env\"\n  content = " &
    q(VwEnvBase) & "\n}\n\n" &
  "systemd.systemUnit {\n  name = \"vaultwarden.service\"\n  content = " &
    q(vwUnit) & "\n  aptClosureLock = " & q(vwLock) &
    "\n  credentials = [\"admin-token\"]" &
    "\n  healthCheck = \"http://127.0.0.1:8000/alive\"\n" &
    "  stateDirectories = [\"carry:" & VwState & "\"]\n" &
    "  depends_on = [\"fs.systemFile:/etc/vaultwarden/vaultwarden.env\", " &
    "\"linux.tmpfilesRule:repro-vaultwarden.conf\", " &
    "\"linux.sysusersEntry:vaultwarden\"]\n}\n"

proc vaultwardenDeb*(work: string): tuple[path: string; lock: AptClosureLock] =
  ## The hand-installed binary packaged as it would be for the store: a
  ## fixture ``.deb`` with ``/usr/bin/vaultwarden``, pinned by a one-member
  ## closure lock.
  result.path = work / "vaultwarden-a13_1.0-1_amd64.deb"
  writeDeb(result.path, @[dir("./"), dir("./usr/"), dir("./usr/bin/"),
    ("./usr/bin/vaultwarden", '0', 0o755, readFile(vaultwardenBinary()), "")])
  result.lock = fixtureLock("vaultwarden-a13", result.path)

proc runBase(m: SnapshotMirror; b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok:
      fails.add(b.name & ": " & name & ": " & detail)
      # Under a falsifying mutation the first red step is the verdict;
      # the rest of the run would only spend a VM slot.
      if mutation().len > 0 or gateMutation().len > 0:
        raise newException(MutationStop, name)
  try:
    g = newMirroredGuest(b, m, diskGiB = 10)
    g.boot()
    g.prepareMirroredBase(m)
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    let adminToken = "a13-admin-" & $epochTime().int64
    g.buildAlertmanager(step)
    g.buildVaultwarden(adminToken, step)
    if fails.len > 0: return fails
    if not g.bootstrapAddon(repro, step): return fails

    # --- 1. Describe: nothing written.
    let f0 = g.takeFingerprint(repro)
    let skAm = g.exec(repro & " system addon import --unit alertmanager.service")
    let skVw = g.exec(repro & " system addon import --unit vaultwarden.service")
    let skPk = g.exec(repro & " system addon import --unit " &
                      "prometheus-alertmanager.service")
    let f1 = g.takeFingerprint(repro)
    step("import describes the three units", skAm.exitCode == 0 and
         skVw.exitCode == 0 and skPk.exitCode == 0,
         skAm.stderr & skVw.stderr & skPk.stderr)
    let same = identityReport(f0, f1)
    step("import wrote nothing (fingerprint identical)", same.ok, same.text)
    record["skeletons"] = %*{"alertmanager": skAm.stdout,
                             "vaultwarden": skVw.stdout,
                             "prometheus-alertmanager": skPk.stdout}
    step("the admin token is in no skeleton (its file is shown with a " &
         "placeholder)", adminToken notin skVw.stdout and
         "ADMIN_TOKEN=<secret" in skVw.stdout, "")
    for (sk, needles) in [
        (skAm.stdout, @["# FLAG: binary:", "/usr/bin/prometheus-alertmanager",
                        "package prometheus-alertmanager"]),
        (skAm.stdout, @["# FLAG: state: " & AmState]),
        (skAm.stdout, @["# FLAG: account: prometheus"]),
        (skVw.stdout, @["# FLAG: binary:", "/usr/local/bin/vaultwarden",
                        "no package"]),
        (skVw.stdout, @["# FLAG: secret:", "ADMIN_TOKEN"]),
        (skVw.stdout, @["# FLAG: state: " & VwState]),
        (skPk.stdout, @["# FLAG: unit: prometheus-alertmanager.service"])]:
      var all = true
      for n in needles:
        if n notin sk: all = false
      step("the skeleton flags " & needles.join(" "), all, "")
    if fails.len > 0: return fails

    # --- 2. Plan and adopt: adoptions only, zero writes, no restart.
    let skeleton = mergeSkeletons([skAm.stdout, skVw.stdout, skPk.stdout])
    let plan = g.planProfile(repro, "skeleton", skeleton)
    let verdicts = planVerdicts(plan.stdout)
    var declared = initHashSet[string]()
    for r in parseSystemProfile(skeleton).resources: declared.incl(r.address)
    var nonAdopt: seq[string]
    var adopted = initHashSet[string]()
    for (v, a) in verdicts:
      if a in declared:
        if v != "adopt": nonAdopt.add(v & " " & a)
        else: adopted.incl(a)
      elif v != "no-op":
        # The add-on's own objects (generation 0) are planned too; an
        # adoption must leave every one of them as it is.
        nonAdopt.add(v & " " & a)
    let wantAdopted = ["systemUnit:alertmanager.service",
      "systemFile:/etc/default/alertmanager",
      "systemFile:/etc/alertmanager/alertmanager.yml",
      "systemUnit:vaultwarden.service",
      "tmpfilesRule:repro-vaultwarden.conf",
      "systemDropIn:prometheus-alertmanager.service/nice"]
    var missing: seq[string]
    for a in wantAdopted:
      if a notin adopted: missing.add(a)
    step("the skeleton plans as adoptions only", plan.exitCode == 0 and
         nonAdopt.len == 0 and missing.len == 0,
         "not adopt: " & $nonAdopt & "\nmissing: " & $missing & "\n" &
         plan.stdout & plan.stderr)
    let shas = g.run("sha256sum /etc/systemd/system/alertmanager.service " &
      "/etc/default/alertmanager /etc/alertmanager/alertmanager.yml " &
      "/etc/systemd/system/vaultwarden.service " &
      "/etc/tmpfiles.d/repro-vaultwarden.conf " & AmDropInDir & "/50-repro-nice.conf")
    # Adopting the tmpfiles fragment runs `systemd-tmpfiles --create` on
    # it; the state it names must not change. (Taken with the services
    # stopped, as alertmanager snapshots on shutdown; started again before
    # their invocations are read.)
    discard g.run("systemctl stop alertmanager.service vaultwarden.service")
    let a0Am = g.stateDigest(repro, AmState)
    let a0Vw = g.stateDigest(repro, VwState)
    discard g.run("systemctl start alertmanager.service vaultwarden.service")
    let invAm = g.invocation("alertmanager.service")
    let invVw = g.invocation("vaultwarden.service")
    let ledgerBefore = g.ledgerOf()
    let ad = g.applyProfile(repro, "skeleton", skeleton)
    step("the adoption applies", ad.exitCode == 0, ad.stdout & ad.stderr)
    let f2 = g.takeFingerprint(repro)
    let zero = identityReport(f1, f2, ["etc:/etc/repro/static"])
    step("adoption wrote nothing (fingerprint identical but the static link)",
         zero.ok, zero.text)
    step("adoption restarted nothing", g.invocation("alertmanager.service") ==
         invAm and g.invocation("vaultwarden.service") == invVw,
         invAm & " " & invVw)
    discard g.run("systemctl stop alertmanager.service vaultwarden.service")
    step("adoption changed neither service's state directory",
         g.stateDigest(repro, AmState) == a0Am and
         g.stateDigest(repro, VwState) == a0Vw, "")
    discard g.run("systemctl start alertmanager.service vaultwarden.service")
    let led = parseLedger(g.ledgerOf())
    var unmatched: seq[string]
    for line in shas.splitLines():
      let f = line.splitWhitespace()
      if f.len != 2: continue
      var ok = false
      for e in led.entries:
        if e.path == f[1] and e.sha256 == f[0] and e.collision == "adopt":
          ok = true
      if not ok: unmatched.add(f[1])
    step("the ledger records each pre-existing object, adopted, at the " &
         "digest it had", unmatched.len == 0,
         $unmatched & "\n" & g.ledgerOf())
    record["ledgerBeforeAdoptionBytes"] = %ledgerBefore.len
    if fails.len > 0: return fails

    # --- 3. Converge: hardened, from the store, state untouched.
    let work = g.runDir / "a13"
    createDir(work)
    let amClosure = aptClosureFixture(m, b, @["prometheus-alertmanager"],
      (if b.osId == "ubuntu": @["main", "universe"] else: @["main"]))
    g.seedClosureCache(amClosure)
    let vw = vaultwardenDeb(work)
    g.seedClosureCache(ClosureFixture(lockText: renderAptClosureLock(vw.lock),
      debs: @[(vw.lock.debs[0].sha256, vw.path)]))
    let put = g.exec("printf '%s' '" & adminToken & "' | " & repro &
      " system addon secret put --service vaultwarden --name admin-token")
    step("the admin token is put as a secret", put.exitCode == 0,
         put.stdout & put.stderr)
    discard g.run("systemctl stop alertmanager.service vaultwarden.service")
    let d0Am = g.stateDigest(repro, AmState)
    let d0Vw = g.stateDigest(repro, VwState)
    let mode = if gateMutation() == "converge-touches-state": "0700" else: "0750"
    let conv = convergedProfile(amClosure.lockText,
                                renderAptClosureLock(vw.lock), mode)
    # The environment file held the admin token, so the skeleton did not
    # adopt it: it is still the operator's, and the converged profile
    # replaces it with its token-free form (its bytes are kept for
    # rollback and uninstall).
    let ca = g.applyProfile(repro, "converged", conv, " --reconcile-drift")
    step("the converged definitions apply", ca.exitCode == 0,
         ca.stdout & ca.stderr & "\n" &
         g.exec("journalctl -u alertmanager -u vaultwarden --no-pager -n 40").stdout)
    step("both services pass their health checks",
         g.healthy("http://127.0.0.1:9093/-/healthy") and
         g.healthy("http://127.0.0.1:8000/alive"), "")
    let amBind = g.closureBinding("alertmanager.service")
    let vwBind = g.closureBinding("vaultwarden.service")
    step("both units run from store closures", amBind.startsWith("/repro/store/") and
         vwBind.startsWith("/repro/store/"), amBind & " " & vwBind)
    step("vaultwarden reads the token as a credential, not from the file",
         "ADMIN_TOKEN" notin g.run("cat /etc/vaultwarden/vaultwarden.env") and
         g.exec("curl -sf -o /dev/null -X POST -d token=" & adminToken &
                " http://127.0.0.1:8000/admin").exitCode == 0, "")
    discard g.run("systemctl stop alertmanager.service vaultwarden.service")
    let d1Am = g.stateDigest(repro, AmState)
    let d1Vw = g.stateDigest(repro, VwState)
    step("alertmanager's state directory is byte-identical across the converge",
         d0Am == d1Am and d0Am.startsWith("sha256:"), d0Am & " / " & d1Am)
    step("vaultwarden's state directory is byte-identical across the converge",
         d0Vw == d1Vw and d0Vw.startsWith("sha256:"), d0Vw & " / " & d1Vw)
    record["stateDigests"] = %*{"alertmanager": [d0Am, d1Am],
                                "vaultwarden": [d0Vw, d1Vw]}

    # --- 4. Rollback to the adopted generation: the operator's bytes.
    let rb = g.exec(repro & " system rollback", timeoutSec = 1200)
    let back = g.run("sha256sum /etc/systemd/system/alertmanager.service " &
      "/etc/systemd/system/vaultwarden.service").splitLines()
    var origUnits = ""
    for line in shas.splitLines():
      if "/etc/systemd/system/" in line: origUnits.add(line & "\n")
    step("rollback restores the operator's unit bytes",
         rb.exitCode == 0 and back.join("\n").strip() == origUnits.strip(),
         rb.stdout & rb.stderr & "\n" & back.join("\n") & "\n" & origUnits)
    step("after the rollback both services are healthy",
         g.healthy("http://127.0.0.1:9093/-/healthy") and
         g.healthy("http://127.0.0.1:8000/alive"), "")
    discard g.run("systemctl stop alertmanager.service vaultwarden.service")
    step("after the rollback the state directories are unchanged",
         g.stateDigest(repro, AmState) == d0Am and
         g.stateDigest(repro, VwState) == d0Vw, "")
  except MutationStop as e:
    steps.add(%*{"step": "stopped at the first red step under the mutation",
                 "ok": false, "detail": e.msg})
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
  test "a hand-configured service is adopted with no write and converged " &
       "with its state untouched":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 and REPRO_A12_PACKAGES")
    else:
      let m = startSnapshotMirror(MirrorStamp)
      defer: m.stop()
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": Gate, "base": b.name, "arch": b.debArch,
          "backend": "qemu", "mutation": mutation(),
          "gateMutation": gateMutation(), "snapshot": MirrorStamp,
          "reprobuild": gitHead(), "gosti": gostiHead(),
          "started": $now().utc}
        let f = runBase(m, b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord(Gate, record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
