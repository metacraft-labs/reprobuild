## Workspace-Manifest-Optional MO-3 — the external-CLI ``LockStore`` backend
## invokes its documented CLI/JSON contract EXACTLY and round-trips through a
## stub program that persists to a local file.
##
## Contract (``ExternalCliContractSchemaV1`` = "reprobuild.lockstore.external-
## cli.v1"). The store invokes the program with exactly two verbs:
##
##   * ``PROG put <KEY>`` — request JSON on STDIN:
##       {"schema":"reprobuild.lockstore.external-cli.v1",
##        "op":"put","key":"<KEY>","value":"<BASE64>"}
##     ``<BASE64>`` is standard base64 of the value bytes (the framed record).
##   * ``PROG get <KEY>`` — no stdin; JSON on STDOUT:
##       hit  {"schema":"...","found":true,"value":"<BASE64>"}  exit 0
##       miss {"schema":"...","found":false}                    exit 0/3
##
## We assert the EXACT argv and the EXACT request JSON the store emits for the
## record key, that base64-decoding the value yields the framed record, and
## that the read verb is ``get latest/<project>/<repo>``. A stub program logs
## every invocation (argv + stdin) and persists value-by-key to a file-backed
## KV store, so the same record reads back through ``latestLock``.
##
## Falsifiable: the stub's log fixes the argv/JSON; if the store emitted a
## different verb, key, schema, or value the exact-equality assertions fail
## (confirmed by perturbing ``ecPutRaw``'s argv — the ``put``-line assertion
## then fails). The round-trip fails if the value were not faithfully encoded.
##
## Skip rule: none — the stub is a POSIX shell script (``bash`` required).

import std/[base64, options, os, strutils, tempfiles, unittest]

import repro_lock_store

proc writeStubCli(path, log: string) =
  ## Logging KV stub: appends ``op\tkey\tstdin`` to ``$LOG_FILE`` and stores
  ## the base64 value-by-key under ``$DB_DIR``. Base64 carries no ``"`` so the
  ## sed extraction is lossless.
  writeFile(path, """#!/usr/bin/env bash
set -euo pipefail
db="${DB_DIR:?DB_DIR unset}"
log="${LOG_FILE:?LOG_FILE unset}"
op="$1"; key="$2"
safe=$(printf '%s' "$key" | tr '/' '_')
if [ "$op" = "put" ]; then
  json=$(cat)
  printf 'put\t%s\t%s\n' "$key" "$json" >> "$log"
  val=$(printf '%s' "$json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  printf '%s' "$val" > "$db/$safe"
  exit 0
elif [ "$op" = "get" ]; then
  printf 'get\t%s\t\n' "$key" >> "$log"
  if [ -f "$db/$safe" ]; then
    val=$(cat "$db/$safe")
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":true,"value":"%s"}' "$val"
  else
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":false}'
  fi
  exit 0
fi
echo "unknown op: $op" >&2
exit 1
""")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

suite "MO-3 — external-CLI store honors its documented contract":

  test "t_external_cli_store_contract_writes_and_reads":
    if findExe("bash").len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-mo3-extcli-", "")
      defer: removeDir(scratch)
      let db = scratch / "db"
      createDir(db)
      let log = scratch / "calls.log"
      writeFile(log, "")
      let stub = scratch / "stub.sh"
      writeStubCli(stub, log)
      putEnv("DB_DIR", db)
      putEnv("LOG_FILE", log)

      let sha = "abcabcabcabcabcabcabcabcabcabcabcabcabca"
      let rec = StoreLockRecord(
        key: StoreLockKey(project: "demo", repo: "demo", sha: sha),
        body: "[[repo]]\npath = \"demo\"\nrevision = \"" & sha & "\"\n")
      let framed = encodeRecord(rec)
      let valueB64 = base64.encode(framed)

      let store: LockStore = newExternalCliLockStore(stub)
      let put = store.putLock(rec)
      check put.outcome == spoOk

      # ---- exact argv + request JSON for the record-key put -------------
      let recKey = "lock/demo/demo/" & sha
      let expectedJson =
        "{\"schema\":\"" & ExternalCliContractSchemaV1 &
        "\",\"op\":\"put\",\"key\":\"" & recKey &
        "\",\"value\":\"" & valueB64 & "\"}"
      var putLines: seq[string]
      for raw in readFile(log).splitLines():
        if raw.len == 0: continue
        let parts = raw.split('\t')
        check parts.len == 3
        if parts[0] == "put": putLines.add(raw)

      # putLock writes the record key plus the two latest pointers (record,
      # latest, latest-any), each carrying the full framed record as value.
      check putLines.len == 3
      let recPutFields = putLines[0].split('\t')
      check recPutFields[0] == "put"            # exact verb
      check recPutFields[1] == recKey           # exact key argv[2]
      check recPutFields[2] == expectedJson     # exact request JSON

      # Every put's value base64-decodes to the framed record.
      for line in putLines:
        let fields = line.split('\t')
        let v = fields[2]
        # Pull the base64 value out of the request JSON the same way the
        # contract documents it lives there.
        let marker = "\"value\":\""
        let start = v.find(marker) + marker.len
        let stop = v.find('"', start)
        check v[start ..< stop] == valueB64
      check base64.decode(valueB64) == framed

      # All three documented keys were written.
      var keys: seq[string]
      for line in putLines: keys.add(line.split('\t')[1])
      check recKey in keys
      check ("latest/demo/demo") in keys
      check ("latest-any/demo") in keys

      # ---- read back: exact get verb/key + round-trip ------------------
      let got = store.latestLock("demo", "demo")
      check got.isSome
      if got.isSome:
        check got.get().key.project == "demo"
        check got.get().key.repo == "demo"
        check got.get().key.sha == sha
        check got.get().body == rec.body

      # Re-read the log AFTER the read so the ``get`` invocation is visible.
      var getLines: seq[string]
      for raw in readFile(log).splitLines():
        if raw.len == 0: continue
        let parts = raw.split('\t')
        if parts[0] == "get": getLines.add(raw)
      check getLines.len >= 1
      let getFields = getLines[^1].split('\t')
      check getFields[0] == "get"               # exact verb
      check getFields[1] == "latest/demo/demo"  # exact key argv[2]

      delEnv("DB_DIR")
      delEnv("LOG_FILE")
