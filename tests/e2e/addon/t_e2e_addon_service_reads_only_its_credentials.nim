## Gate ``e2e_addon_service_reads_only_its_credentials`` (milestone A7;
## spec §10.3; CRED-3).
##
## Service A cannot read service B's credential: it has no access to
## ``/run/repro/secrets/B``, and A's ``$CREDENTIALS_DIRECTORY`` has only its
## own entries.
##
## On each base: two services, ``svc-a`` and ``svc-b``, each under
## ``DynamicUser=yes`` and each loading its own ``token`` (different random
## values, delivered through ``repro system addon secret put``, the
## operator path), record from inside their own sandbox:
##
## - the entries of ``$CREDENTIALS_DIRECTORY`` (must be exactly ``token``);
## - the SHA-256 of their own ``token`` (must be their own value's);
## - an attempt to read the other service's file, and to list
##   ``/run/repro/secrets`` and the other service's directory (each must
##   fail with "Permission denied").
##
## Positive control: root in the guest reads both files (they exist, and
## the denial is the service's, not a missing file).
##
## Opt-in: ``REPRO_ADDON_VM_GATES=1``.
##
## *Mocking.* None.

import std/[json, strutils, times, unittest]

import nimcrypto/[hash, sha2]

import repro_test_support/reasoned_skip

import ./addon_testbed
import ./addon_secrets_support

proc sha256Hex(s: string): string =
  ($sha256.digest(s)).toLowerAscii()

proc unit(me, other: string): string =
  let d = "/run/" & me & "-probe/"
  let script =
    "ls -A $$CREDENTIALS_DIRECTORY > " & d & "creds; " &
    "sha256sum $$CREDENTIALS_DIRECTORY/token | cut -c1-64 > " & d & "own; " &
    "cat /run/repro/secrets/" & other & "/token > " & d & "other 2>&1; " &
    "echo rc=$$? >> " & d & "other; " &
    "ls /run/repro/secrets > " & d & "root-ls 2>&1; echo rc=$$? >> " & d & "root-ls; " &
    "ls /run/repro/secrets/" & other & " > " & d & "other-ls 2>&1; " &
    "echo rc=$$? >> " & d & "other-ls; touch " & d & "done; exec sleep infinity"
  "secrets.secretFile {\n  service = \"" & me & "\"\n  name = \"token\"\n}\n\n" &
    "systemd.systemUnit {\n  name = \"" & me & ".service\"\n" &
    "  content = \"[Unit]\nDescription=credential isolation probe\n\n" &
    "[Service]\nDynamicUser=yes\nRuntimeDirectory=" & me & "-probe\n" &
    "RuntimeDirectoryMode=0755\nExecStart=/bin/sh -c '" & script & "'\n\n" &
    "[Install]\nWantedBy=multi-user.target\n\"\n" &
    "  credentials = [\"token\"]\n}\n\n"

proc runBase(b: BaseImage; record: JsonNode): seq[string] =
  var g: Guest
  let steps = newJArray()
  var fails: seq[string]
  proc step(name: string; ok: bool; detail: string) =
    steps.add(%*{"step": name, "ok": ok, "detail": detail})
    if not ok: fails.add(b.name & ": " & name & ": " & detail)
  try:
    g = newGuest(b)
    g.boot()
    g.prepareBase()
    let (repro, sha) = g.installArtefact()
    record["artefactSha256"] = %sha
    if not g.bootstrapAddon(repro, step): return fails
    var values: seq[(string, string)]
    for svc in ["svc-a", "svc-b"]:
      let r = g.exec("head -c 24 /dev/urandom | base64 | tr -d '\\n' > " &
        "/run/" & svc & ".value; " & repro & " system addon secret put " &
        "--service " & svc & " --name token < /run/" & svc & ".value")
      step("secret put " & svc, r.exitCode == 0, r.stdout & r.stderr)
      values.add((svc, g.run("cat /run/" & svc & ".value; rm -f /run/" & svc &
                             ".value")))
    let r = g.applyProfile(repro, "iso", unit("svc-a", "svc-b") &
                                        unit("svc-b", "svc-a"))
    step("the two services apply", r.exitCode == 0, r.stdout & r.stderr)
    for (me, value) in values:
      let other = if me == "svc-a": "svc-b" else: "svc-a"
      let d = "/run/" & me & "-probe/"
      discard g.exec("for i in $(seq 1 30); do [ -e " & d & "done ] && break; " &
                     "sleep 1; done")
      let creds = g.exec("cat " & d & "creds").stdout.strip()
      step(me & ": $CREDENTIALS_DIRECTORY holds only its own entry",
           creds == "token", creds)
      let own = g.exec("cat " & d & "own").stdout.strip()
      step(me & ": it reads its own value", own == sha256Hex(value), own)
      for (f, what) in [("other", "read " & other & "'s file"),
                        ("root-ls", "list /run/repro/secrets"),
                        ("other-ls", "list " & other & "'s directory")]:
        let got = g.exec("cat " & d & f).stdout
        step(me & ": cannot " & what, "Permission denied" in got and
             "rc=0" notin got, got)
      let user = g.exec("ps -o user= -C sleep | sort -u").stdout
      record[me & "-users"] = %user
    # Positive control: the files are there for root.
    for (me, value) in values:
      step("positive control: root reads " & me & "'s file",
           g.exec("cat /run/repro/secrets/" & me & "/token").stdout == value, "")
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

suite "e2e_addon_service_reads_only_its_credentials":
  test "a service reads only its own credentials":
    if not gatesEnabled():
      skip("add-on VM gate: set REPRO_ADDON_VM_GATES=1 (just e2e_addon_service_reads_only_its_credentials)")
    else:
      var failures: seq[string]
      for b in selectedBases():
        let record = %*{"gate": "e2e_addon_service_reads_only_its_credentials",
          "base": b.name, "arch": b.debArch,
          "backend": (if useIncus(): "incus" else: "qemu"),
          "mutation": mutation(), "reprobuild": gitHead(),
          "started": $now().utc}
        let f = runBase(b, record)
        record["verdict"] = %(if f.len == 0: "green" else: "red")
        record["finished"] = %($now().utc)
        echo "record: ", writeRecord("e2e_addon_service_reads_only_its_credentials", record)
        failures.add(f)
      for f in failures: echo "FAIL ", f
      check failures.len == 0
