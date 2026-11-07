## Store custody (ReproOS Add-On Mode §13 decisions 47 and 48; threat model
## DET-AO-5, G42).
##
## * Expected digests come from outside the store -- the ledgers, the
##   realisation index, an operator's adoption -- never from a receipt.
## * The digest cache answers only for an unchanged object (its signature)
##   and only for the expected digest: an object altered after it was
##   cached is altered.
## * The custody pass refuses what is not a prefix and, on a host under
##   custody, what has no digest (default deny); reports it unverifiable on
##   a host realised before custody; recovers an altered object from its
##   trusted source -- its altered bytes moved into the root-only evidence
##   directory, the quarantine released, a DET-AO-5 ``store-recovered``
##   record written -- and refuses, quarantined, one with no trusted source.
## * The evidence directory is bounded (entries, bytes) by its retention.
## * Generation 0's files prefix is recovered only from copies outside the
##   store whose SHA-256 is their name.
##
## Falsifying builds: ``custody-cache-ignores-signature`` (the cache step
## goes red), ``custody-admits-undigested`` (default deny),
## ``recovery-discards-evidence`` (the evidence step),
## ``recovery-trusts-store-bytes`` (the files-source step).
##
## Mocks: the recovery's re-realisation is a closure writing the original
## bytes back, standing for the realisers (static tree, files prefix, apt
## closure), whose own paths the VM gate ``e2e_addon_store_custody`` drives
## on a real host. Everything else is real: a real store, real ledgers,
## real files.

import std/[os, strutils, tables, unittest]

import repro_infra
import repro_local_store/store

import repro_addon/addon_apply
import repro_addon/evidence as addonEvidence
import repro_addon/fingerprint
import repro_addon/ledger
import repro_addon/store_custody
import repro_addon/store_root

let root = getTempDir() / ("addon-store-custody-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
let storeDir = root / "store"
let stateDir = root / "state"
createDir(stateDir)
writeFile(root / "evidence.conf", "sink = 127.0.0.1:1\n")
var site = custodySite(stateDir, storeDir).withEvidence(EvidenceSite(
  stateDir: stateDir, dir: root / "ev", outbox: root / "ev" / "outbox",
  confPath: root / "evidence.conf", attestationKey: root / "none", host: "h",
  journal: false))

proc prefix(name, content: string): string =
  ## A prefix at ``<store>/prefixes/<name>/1-x`` holding one file.
  result = storeDir / "prefixes" / name / "1-x"
  createDir(result / "bin")
  writeFile(result / "bin" / "tool", content)

proc alter(path, content: string) =
  writeFile(path / "bin" / "tool", content)

suite "store custody":
  test "expectations: ledger, then index, then adoption; never the receipt":
    let a = prefix("a", "a\n")
    let b = prefix("b", "b\n")
    writeLedger(stateDir / "addon-ledger", Ledger(generation: "g", entries: @[
      LedgerEntry(class: lcStorePrefix, path: a, value: "tree-v2:ledger")]))
    recordRealised(site, a, "tree-v2:index")
    recordRealised(site, b, storeTreeDigest(b))
    let e = expectedDigests(site)
    check e[a] == "tree-v2:ledger"
    check e[b] == storeTreeDigest(b)
    expect IOError:
      recordRealised(site, b, "tree-v2:other")
    removeFile(stateDir / "addon-ledger")
    forgetRealised(site, a)

  test "the cache answers only for an unchanged object":
    let c = prefix("c", "c\n")
    let d = storeTreeDigest(c)
    check verifiedDigest(site, c, d).verdict == cvVerified
    check verifiedDigest(site, c, d).verdict == cvVerified     # cached
    sleep(20)
    alter(c, "C\n")
    check verifiedDigest(site, c, d).verdict == cvAltered
    check verifiedDigest(site, c, "").verdict == cvUnverifiable

  test "default deny: not a prefix, and no digest under custody":
    let loose = storeDir / "loose"
    createDir(loose)
    let u = prefix("u", "u\n")
    let none = proc (o: StoreObjectRef): Recovery = Recovery(why: "none")
    var r = custodyPass(site, [StoreObjectRef(path: loose, kind: sokOther,
      referrer: "x")], none, true)
    check r.refusals.len == 1
    r = custodyPass(site, [StoreObjectRef(path: u, kind: sokPrefix,
      referrer: "x")], none, true)
    check r.refusals.len == 0
    check r.unverifiable.len == 1           # realised before custody
    markCustody(site)
    r = custodyPass(site, [StoreObjectRef(path: u, kind: sokPrefix,
      referrer: "x")], none, true)
    check r.refusals.len == 1               # under custody: refused
    check r.unverifiable.len == 0
    removeFile(site.custodyPath)

  test "an altered object is recovered, its bytes kept as evidence":
    let v = prefix("v", "good\n")
    let good = storeTreeDigest(v)
    recordRealised(site, v, good)
    quarantineStorePath(v, site.quarantinePath)
    alter(v, "evil\n")
    let rec = proc (o: StoreObjectRef): Recovery =
      Recovery(ok: true, source: "test bytes", realise: proc (): string =
        createDir(o.path / "bin")
        writeFile(o.path / "bin" / "tool", "good\n")
        storeTreeDigest(o.path))
    let r = custodyPass(site, [StoreObjectRef(path: v, kind: sokFiles,
      referrer: "x")], rec, true)
    check r.refusals.len == 0
    check r.recovered.len == 1
    check readFile(v / "bin" / "tool") == "good\n"
    check v notin readStoreQuarantine(site.quarantinePath)
    let entry = r.recovered[0].entry
    check readFile(entry / "tree" / "bin" / "tool") == "evil\n"
    check "expected\t" & good in readFile(entry / "record")
    check getFilePermissions(site.evidenceDir) ==
      {fpUserRead, fpUserWrite, fpUserExec}
    check evidenceRecords("store-recovered", site.evidence.dir).len == 1

  test "no trusted source: refused and quarantined, nothing moved":
    let w = prefix("w", "good\n")
    recordRealised(site, w, storeTreeDigest(w))
    alter(w, "evil\n")
    let r = custodyPass(site, [StoreObjectRef(path: w, kind: sokBinary,
      referrer: "x")], proc (o: StoreObjectRef): Recovery =
        Recovery(why: "no source"), true)
    check r.refusals.len == 1
    check readFile(w / "bin" / "tool") == "evil\n"
    check w in readStoreQuarantine(site.quarantinePath)
    # A plan does not recover.
    let p = custodyPass(site, [StoreObjectRef(path: w, kind: sokFiles,
      referrer: "x")], proc (o: StoreObjectRef): Recovery =
        Recovery(ok: true), false)
    check p.refusals.len == 1

  test "the evidence directory is bounded":
    for i in 0 ..< StoreEvidenceMaxEntries + 3:
      let x = prefix("x" & $i, "x\n")
      discard preserveEvidence(site, x, "e", "o", "test")
    check evidenceEntries(site).len == StoreEvidenceMaxEntries

  test "generation 0's files are recovered only from copies outside the store":
    let body = "export X=1\n"
    let name = sha256Hex(body)
    let pfx = filesPrefixPath([name], "0.0.1", storeDir)
    createDir(pfx)
    writeFile(pfx / name, "export X=1\n# planted\n")
    let target = root / "etc-profile.sh"
    var r = SystemResource(kind: srkFsSystemFile, address: "own.profile",
      sfPath: target, sfSourceLocal: pfx / name)
    writeFile(target, "tampered too\n")
    check not filesRecovery(pfx, [r], stateDir, storeDir).ok
    writeFile(target, body)
    check filesRecovery(pfx, [r], stateDir, storeDir).ok

removeDir(root)
