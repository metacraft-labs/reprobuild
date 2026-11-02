## ``repro system addon import --unit`` (ReproOS Add-On Mode §11.2 step 1,
## ``repro_addon/addon_import``): the skeleton of a hand-configured service
## reproduces its unit, environment file, referenced ``/etc`` files and
## tmpfiles fragment byte for byte, with the narrowest managed prefixes,
## parses as a profile, and flags what it cannot declare -- a tmpfiles
## fragment the add-on cannot own under its name, the
## distribution binary and its package, a hand-installed binary, a secret
## in an environment file, a package's file, a drop-in, the account and
## the state locations. The fixture is the two services A13's VM gate
## builds by hand (decision 40): ``alertmanager`` from apt's
## ``prometheus-alertmanager`` and a hand-installed ``vaultwarden``.
##
## *Mocking.* The host is a fixture tree (``ImportObserver.root``) with a
## dpkg database of its own, read by the production dpkg driver; the one
## seam is the unit provision (``systemctl show``), which needs the
## guest's systemd -- the VM gate ``e2e_addon_adopt_hand_configured_service``
## runs the import against the real one, and asserts the host fingerprint
## is unchanged by it.

import std/[os, posix, strutils, unittest]

import repro_infra
from repro_test_support import testCaseScratchSlug
import repro_addon/[addon_import, collision]

const
  AmUnit = """[Unit]
Description=Alertmanager (configured by hand)
After=network-online.target

[Service]
User=prometheus
Group=prometheus
EnvironmentFile=/etc/default/alertmanager
ExecStart=/usr/bin/prometheus-alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager $ARGS
Restart=on-failure

[Install]
WantedBy=multi-user.target
"""
  AmDefault = "ARGS=\"--web.listen-address=127.0.0.1:9093 --cluster.listen-address=\"\n"
  AmConfig = "route:\n  receiver: \"null\"\nreceivers:\n  - name: \"null\"\n"
  VwUnit = """[Unit]
Description=Vaultwarden (installed by hand)

[Service]
User=vaultwarden
EnvironmentFile=/etc/vaultwarden/vaultwarden.env
ExecStart=/usr/local/bin/vaultwarden
WorkingDirectory=/var/lib/vaultwarden
ReadWritePaths=/var/lib/vaultwarden

[Install]
WantedBy=multi-user.target
"""
  VwEnv = "DATA_FOLDER=/var/lib/vaultwarden\nROCKET_PORT=8000\nADMIN_TOKEN=s3cret\n"
  VwTmpfiles = "d /var/lib/vaultwarden 0700 vaultwarden vaultwarden -\n"

var root = getTempDir() / ("t_addon_import_skeleton" & testCaseScratchSlug())

proc put(path, content: string) =
  createDir(parentDir(root & path))
  writeFile(root & path, content)

proc fixture() =
  removeDir(root)
  put("/etc/systemd/system/alertmanager.service", AmUnit)
  put("/etc/default/alertmanager", AmDefault)
  put("/etc/alertmanager/alertmanager.yml", AmConfig)
  put("/etc/systemd/system/vaultwarden.service", VwUnit)
  put("/etc/systemd/system/vaultwarden.service.d/override.conf",
      "[Service]\nNice=5\n")
  put("/etc/vaultwarden/vaultwarden.env", VwEnv)
  put("/etc/tmpfiles.d/vaultwarden.conf", VwTmpfiles)
  put("/etc/tmpfiles.d/unrelated.conf", "d /run/other 0755 root root -\n")
  put("/usr/bin/prometheus-alertmanager", "ELF")
  put("/usr/local/bin/vaultwarden", "ELF")
  put("/usr/lib/systemd/system/prometheus-alertmanager.service", "[Service]\n")
  put("/var/lib/dpkg/info/prometheus-alertmanager.list",
      "/usr/bin/prometheus-alertmanager\n" &
      "/usr/lib/systemd/system/prometheus-alertmanager.service\n" &
      "/etc/default/prometheus-alertmanager\n")
  put("/var/lib/dpkg/status", "")
  createDir(root & "/var/lib/alertmanager")

proc observer(): ImportObserver =
  let r = root
  ImportObserver(root: r, driver: newDpkgDriver(r,
    proc(u: string): UnitProvision {.gcsafe.} =
      case u
      of "alertmanager.service":
        UnitProvision(loadState: "loaded",
          fragmentPath: "/etc/systemd/system/alertmanager.service",
          unitFileState: "enabled", activeState: "active")
      of "vaultwarden.service":
        UnitProvision(loadState: "loaded",
          fragmentPath: "/etc/systemd/system/vaultwarden.service",
          dropInPaths: @["/etc/systemd/system/vaultwarden.service.d/override.conf"],
          unitFileState: "disabled", activeState: "active")
      of "prometheus-alertmanager.service":
        UnitProvision(loadState: "loaded",
          fragmentPath: "/usr/lib/systemd/system/prometheus-alertmanager.service",
          unitFileState: "disabled")
      of "transient.service":
        UnitProvision(loadState: "loaded",
          fragmentPath: "/run/systemd/transient/transient.service")
      else:
        UnitProvision(loadState: "not-found")))

proc flagged(sk: ImportSkeleton; needles: varargs[string]): bool =
  for f in sk.flags:
    var all = true
    for n in needles:
      if n notin f: all = false
    if all: return true
  false

suite "import skeleton":
  test "alertmanager from apt: unit, environment file and config, as they are":
    fixture()
    let sk = importUnit(observer(), "alertmanager.service")
    let p = parseSystemProfile(sk.text)
    check p.addOn.managedEtcPrefixes ==
      @["/etc/alertmanager/alertmanager.yml", "/etc/default/alertmanager"]
    var byAddr: seq[string]
    for r in p.resources: byAddr.add(r.address)
    check byAddr == @["systemUnit:alertmanager.service",
                      "systemFile:/etc/default/alertmanager",
                      "systemFile:/etc/alertmanager/alertmanager.yml"]
    check p.resources[0].suContent == AmUnit and p.resources[0].suEnabled
    # The floor is waived by name, so the unit renders as written.
    check p.resources[0].suFloorExceptions == @[AdoptedFloorWaiver]
    let onAddOn = parseSystemProfile(sk.text, addOnDefaults = true)
    check renderedSystemUnitContent(onAddOn.resources[0]) == AmUnit
    check sk.flagged("floor: alertmanager.service", "waives")
    check p.resources[1].sfContent == AmDefault
    check p.resources[2].sfContent == AmConfig
    check sk.flagged("binary:", "/usr/bin/prometheus-alertmanager",
                     "package prometheus-alertmanager", "store package")
    check sk.flagged("account: prometheus")
    check sk.flagged("state: /var/lib/alertmanager", "keep:", "carry:")
    check not sk.flagged("secret:")
    # Every flag is a comment of the printed skeleton.
    for f in sk.flags: check ("# FLAG: " & f) in sk.text

  test "vaultwarden by hand: secret, hand binary, drop-in and tmpfiles":
    fixture()
    let sk = importUnit(observer(), "vaultwarden.service")
    let p = parseSystemProfile(sk.text)
    check p.addOn.managedEtcPrefixes == @["/etc/vaultwarden/vaultwarden.env"]
    var kinds: seq[string]
    for r in p.resources: kinds.add($r.kind & " " & r.address)
    check kinds == @["systemd.systemUnit systemUnit:vaultwarden.service",
                     "fs.systemFile systemFile:/etc/vaultwarden/vaultwarden.env"]
    check not p.resources[0].suEnabled
    check sk.flagged("tmpfiles: /etc/tmpfiles.d/vaultwarden.conf",
                     "cannot be adopted", "repro-")
    check sk.flagged("secret:", "ADMIN_TOKEN", "credential")
    check not sk.flagged("secret:", "ROCKET_PORT")
    check sk.flagged("binary:", "/usr/local/bin/vaultwarden", "no package")
    check sk.flagged("drop-in:", "override.conf", "unmanaged")
    check sk.flagged("state: /var/lib/vaultwarden")
    check sk.flagged("account: vaultwarden")

  test "a fragment named as the add-on names its own is adopted":
    fixture()
    removeFile(root & "/etc/tmpfiles.d/vaultwarden.conf")
    put("/etc/tmpfiles.d/repro-vaultwarden.conf", VwTmpfiles)
    let sk = importUnit(observer(), "vaultwarden.service")
    let p = parseSystemProfile(sk.text)
    check p.resources[^1].kind == srkLinuxTmpfilesRule
    check p.resources[^1].tmpfilesName == "repro-vaultwarden.conf"
    check p.resources[^1].tmpfilesContent == VwTmpfiles

  test "a package's file and a package's unit are flagged, not adopted":
    fixture()
    put("/var/lib/dpkg/info/prometheus-alertmanager.list",
        "/usr/bin/prometheus-alertmanager\n/etc/default/alertmanager\n" &
        "/usr/lib/systemd/system/prometheus-alertmanager.service\n")
    let sk = importUnit(observer(), "alertmanager.service")
    check sk.flagged("file: /etc/default/alertmanager",
                     "package prometheus-alertmanager", "divert")
    for r in sk.profile.resources:
      check r.address != "systemFile:/etc/default/alertmanager"
    let pk = importUnit(observer(), "prometheus-alertmanager.service")
    check pk.flagged("unit: prometheus-alertmanager.service",
                     "package prometheus-alertmanager", "dropIn")
    for r in pk.profile.resources:
      check r.kind != srkSystemdSystemUnit

  test "units that cannot be described refuse":
    fixture()
    for u in ["missing.service", "transient.service", "../x.service"]:
      expect ImportError:
        discard importUnit(observer(), u)

  test "nothing under the fixture root changes":
    fixture()
    var before: seq[string]
    for p in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile}):
      before.add(p & " " & $getFileInfo(p).lastWriteTime)
    discard importUnit(observer(), "alertmanager.service")
    discard importUnit(observer(), "vaultwarden.service")
    var after: seq[string]
    for p in walkDirRec(root, yieldFilter = {pcFile, pcDir, pcLinkToFile}):
      after.add(p & " " & $getFileInfo(p).lastWriteTime)
    check before == after

  test "parsing helpers":
    check commandTokens("-/usr/bin/x --config=/etc/a 'b c' \"/etc/d\"") ==
      @["/usr/bin/x", "--config=/etc/a", "/etc/a", "b c", "/etc/d"]
    check envFileAssignments("# c\nA=1\nB=\"x y\"\n\n") ==
      @[("A", "1"), ("B", "x y")]
    check looksSecret("admin_token") and looksSecret("DB_PASSWORD") and
      not looksSecret("ROCKET_PORT")
    check unitDirectives("[Service]\nExecStart=/a \\\n  b\n# x\n") ==
      @[("Service", "ExecStart", "/a b")]

removeDir(root)
