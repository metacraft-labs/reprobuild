## ReproOS-Remix-Protocol-And-Registry M2 verification
## ``test_remix_composition_is_order_independent``.
##
## "Compatible parent permutations produce one identity and graph, while
## ambiguous or conflicting compositions require an explicit resolution
## artifact."
##
## Every member is a real signed release decoded through the M1 path; patch
## blobs are real unified diffs read by the composition engine. Two inputs
## are supplied as in-memory functions rather than services, because the
## services do not exist yet: the blob store (a table of the very bytes
## the manifests reference) and the trust verdict lookup (`isBlocked`),
## whose owner is the Trust And Reputation campaign. Both are the exact
## interfaces the engine will be wired to; neither changes what is tested.

import std/[algorithm, sequtils, sets, tables, unittest]

import repro_remix
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))

proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32:
    result[i] = seed xor byte(i)

var blobStore = initTable[Digest32, seq[byte]]()

proc put(text, mediaType: string): BlobRef =
  let b = bytesOf(text)
  blobStore[blobId(b)] = b
  BlobRef(id: blobId(b), mediaType: mediaType, size: uint64(b.len))

proc diff(path: string; line: int; oldText, newText: string): string =
  "--- a/" & path & "\n+++ b/" & path & "\n@@ -" & $line & ",1 +" & $line &
    ",1 @@\n-" & oldText & "\n+" & newText & "\n"

let firefox = OriginalRef(package: "firefox", interfaceFingerprint: d32(1),
  catalogWorkspace: "reprobuild-packages",
  catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
  catalogRevision: "0123456789abcdef0123456789abcdef01234567",
  catalogInterfaceArtifact: d32(2))

let alice = generateKeypair()
let bob = generateKeypair()
let resolver = generateKeypair()

proc release(name: string; key: PeerKeypair; patches: seq[(string, int)] = @[];
             config: seq[(string, string, ConfigPriority, ConfigOperation)] = @[];
             parents: seq[Digest32] = @[]; license = "MIT";
             permissions: seq[Permission] = @[];
             migrations: seq[string] = @[];
             sources: seq[SourceTree] = @[];
             constraint = ""): VerifiedManifest =
  var m = Manifest(remixName: "u/" & name, version: "1.0.0",
    intent: "Fixture " & name & ".", license: license,
    targets: @[Target(original: firefox,
      constraintKind: (if constraint.len > 0: ckVersionRange else: ckExactFingerprint),
      constraint: constraint)],
    parents: parents, authors: @[Digest32(keyIdOf(key))],
    permissions: permissions, sources: sources)
  for i, (path, line) in patches:
    m.patches.add Patch(appliesToKind: ptTarget, appliesToIndex: 0,
      blob: put(diff(path, line, "old " & name, "new " & name), "text/x-diff"),
      strip: 1, order: uint16(i))
  for (cfg, value, prio, op) in config:
    m.configuration.add ConfigContribution(configurable: cfg,
      schemaFingerprint: d32(7), priority: prio, operation: op,
      value: put(value, "text/plain"))
  m.configuration.sort(proc (a, b: ConfigContribution): int = cmp(a.configurable, b.configurable))
  for s in migrations:
    m.dataMigrations.add DataMigration(store: s, kind: mkReversible, edge: "migrate")
  var env = newManifestEnvelope(m)
  env.signEnvelope(key)
  decodeAndVerify(encodeEnvelope(env))

var parentsOf = initTable[Digest32, seq[Digest32]]()
var blocked = initHashSet[Digest32]()

proc remember(v: VerifiedManifest): VerifiedManifest =
  parentsOf[Digest32(v.id)] = v.manifest.parents
  v

let allPermissions = @[Permission(kind: pkNetworkClient),
                       Permission(kind: pkFilesystemRead, scope: "user-config")]

proc inputs(ms: seq[VerifiedManifest]; rs: seq[Resolution] = @[]): ComposeInputs =
  ComposeInputs(
    members: ms.mapIt(MemberSpec(release: it)),
    resolutions: rs, baseLock: d32(99),
    blobs: proc (id: Digest32): (bool, seq[byte]) =
      if id in blobStore: (true, blobStore[id]) else: (false, @[]),
    parents: proc (id: ReleaseId): (bool, seq[Digest32]) =
      let k = Digest32(id)
      if k in parentsOf: (true, parentsOf[k]) else: (false, @[]),
    isBlocked: proc (id: Digest32): bool = id in blocked,
    grantedPermissions: allPermissions,
    admittedLicenses: @["MIT", "Apache-2.0"])

proc permutations[T](xs: seq[T]): seq[seq[T]] =
  if xs.len <= 1: return @[xs]
  for i in 0 ..< xs.len:
    var rest = xs
    rest.delete(i)
    for p in permutations(rest):
      result.add @[xs[i]] & p

proc refusal(f: proc ()): string =
  try:
    f()
    "accepted"
  except RemixError as e:
    $e.reason

let compactTabs = remember release("compact-tabs", alice, patches = @[("tabs.css", 10)],
  config = @[("firefox.tabHeight", "28", cpSet, coReplace)])
let darkMenus = remember release("dark-menus", bob, patches = @[("menu.css", 3)],
  config = @[("firefox.menuTheme", "dark", cpSet, coReplace)])
let quietUpdates = remember release("quiet-updates", alice,
  config = @[("firefox.updateNag", "off", cpOverride, coReplace)],
  permissions = @[Permission(kind: pkNetworkClient)])
let roomyTabs = remember release("roomy-tabs", bob, patches = @[("tabs.css", 11)],
  config = @[("firefox.tabHeight", "44", cpSet, coReplace)])

suite "Remix M2 — composition is order independent":

  test "compatible members compose to one identity and one plan in every order":
    let base = compose(inputs(@[compactTabs, darkMenus, quietUpdates]))
    check base.status == csReady
    check base.conflicts.len == 0
    for perm in permutations(@[compactTabs, darkMenus, quietUpdates]):
      let c = compose(inputs(perm))
      check c.id == base.id
      check c.envelope.body == base.envelope.body
      check c.plan == base.plan
    check base.plan.patches.len == 2
    check base.plan.configuration.len == 3
    check base.plan.members.len == 3
    check base.deferredChecks == @[ccSymbol, ccFileOwnership, ccService, ccPort]

  test "conflicting members need an explicit resolution and install nothing until then":
    let c = compose(inputs(@[compactTabs, roomyTabs]))
    check c.status == csNeedsResolution
    check c.conflicts.mapIt(it.class) == @[ccPatch, ccConfiguration]
    check c.conflicts.allIt(it.resolvedBy == -1)
    # The conflict set is the same whichever order the user picked them.
    check compose(inputs(@[roomyTabs, compactTabs])).conflicts == c.conflicts

  test "a signed resolution artifact settles the conflicts and is attributable":
    let unresolved = compose(inputs(@[compactTabs, roomyTabs]))
    let patchConflict = unresolved.conflicts[0]
    let configConflict = unresolved.conflicts[1]
    let rs = @[
      Resolution(class: ccPatch, members: patchConflict.members,
        subject: patchConflict.subject, kind: rsReplacementPatch,
        blob: put(diff("tabs.css", 10, "old compact-tabs", "merged tabs"), "text/x-diff"),
        author: Digest32(keyIdOf(resolver))),
      Resolution(class: ccConfiguration, members: configConflict.members,
        subject: "firefox.tabHeight", kind: rsSelectMember,
        selected: Digest32(compactTabs.id), author: Digest32(keyIdOf(resolver)))]
    var resolved = compose(inputs(@[compactTabs, roomyTabs], rs))
    check resolved.status == csReady
    check resolved.id != unresolved.id
    # Order of members and of resolutions does not matter.
    for perm in permutations(@[compactTabs, roomyTabs]):
      for rperm in permutations(rs):
        check compose(inputs(perm, rperm)).id == resolved.id
    # The selected member's value survives; the replacement patch replaces
    # both members' patches to that file and is attributed to the resolver.
    let heights = resolved.plan.configuration.filterIt(
      it.contribution.configurable == "firefox.tabHeight")
    check heights.len == 1
    check heights[0].member == Digest32(compactTabs.id)
    check resolved.plan.patches.len == 1
    check resolved.plan.patches[0].member == Digest32(keyIdOf(resolver))
    # Attribution: the resolver must sign, and only the resolver.
    check refusal(proc () = verifyCompositionSignatures(resolved)) == $rrMissingAuthorSignature
    resolved.envelope.signEnvelope(resolver)
    check refusal(proc () = verifyCompositionSignatures(resolved)) == "accepted"
    resolved.envelope.signEnvelope(alice)
    check refusal(proc () = verifyCompositionSignatures(resolved)) == $rrForbiddenContent

  test "resolutions cannot be unused, misdirected or smuggle extra changes":
    let c = compose(inputs(@[compactTabs, roomyTabs]))
    let pc = c.conflicts[0]
    check refusal(proc () = discard compose(inputs(@[compactTabs, darkMenus], @[
      Resolution(class: ccPatch, members: pc.members, subject: pc.subject,
        kind: rsSelectMember, selected: Digest32(compactTabs.id))]))) == $rrDanglingReference
    check refusal(proc () = discard compose(inputs(@[compactTabs, roomyTabs], @[
      Resolution(class: ccPatch, members: pc.members, subject: pc.subject,
        kind: rsSelectMember, selected: Digest32(darkMenus.id))]))) == $rrDanglingReference
    let smuggling = put(diff("tabs.css", 10, "a", "b") & diff("prefs.js", 1, "c", "d"),
                        "text/x-diff")
    check refusal(proc () = discard compose(inputs(@[compactTabs, roomyTabs], @[
      Resolution(class: ccPatch, members: pc.members, subject: pc.subject,
        kind: rsReplacementPatch, blob: smuggling)]))) == $rrForbiddenContent

  test "a blocked member or ancestor refuses the composition and cannot be resolved":
    let child = remember release("child", bob, patches = @[("toolbar.css", 1)],
                                 parents = @[Digest32(darkMenus.id)])
    blocked.incl Digest32(darkMenus.id)
    let c = compose(inputs(@[compactTabs, child]))
    check c.status == csRefused
    check c.conflicts.anyIt(it.class == ccBlocked and it.members == @[Digest32(child.id)])
    check refusal(proc () = discard compose(inputs(@[compactTabs, child], @[
      Resolution(class: ccBlocked, members: @[Digest32(child.id)], subject: "blocked",
        kind: rsSelectMember, selected: Digest32(child.id))]))) == $rrForbiddenContent
    blocked.excl Digest32(darkMenus.id)
    # A revoked author key blocks every release it signed.
    blocked.incl Digest32(keyIdOf(bob))
    check compose(inputs(@[darkMenus])).status == csRefused
    blocked.excl Digest32(keyIdOf(bob))

  test "composing a release with its own ancestor is a lineage conflict":
    let child = remember release("child2", alice, patches = @[("toolbar.css", 1)],
                                 parents = @[Digest32(darkMenus.id)])
    let c = compose(inputs(@[darkMenus, child]))
    check c.conflicts.anyIt(it.class == ccLineage and it.subject == "ancestor-member")
    check c.plan.ancestors.len == 0
    check compose(inputs(@[child])).plan.ancestors == @[Digest32(darkMenus.id)]

  test "sources, versions, migrations, permissions and licenses are classified":
    let srcA = SourceTree(repo: "tabkit", remote: "https://example.invalid/tabkit",
      revision: "1111111111111111111111111111111111111111", digest: "blake3:" & toHex(d32(3)))
    var srcB = srcA
    srcB.revision = "2222222222222222222222222222222222222222"
    let a = remember release("src-a", alice, sources = @[srcA], migrations = @["profile"],
                             constraint = ">=128 <130")
    let b = remember release("src-b", bob, sources = @[srcB], migrations = @["profile"],
                             constraint = ">=131")
    let classes = compose(inputs(@[a, b])).conflicts.mapIt(it.class)
    check ccSource in classes
    check ccDataMigration in classes
    check ccPackageVersion in classes
    let c = remember release("range-c", bob, constraint = ">=129 <140")
    check ccPackageVersion notin compose(inputs(@[a, c])).conflicts.mapIt(it.class)
    let gpl = remember release("gpl", bob, license = "GPL-3.0-only")
    let gplC = compose(inputs(@[gpl]))
    check gplC.status == csRefused
    check gplC.conflicts[0].class == ccLicense
    let dual = remember release("dual", bob, license = "GPL-3.0-only OR MIT")
    check compose(inputs(@[dual])).status == csReady
    let listener = remember release("listener", alice,
      permissions = @[Permission(kind: pkNetworkListen)])
    let lc = compose(inputs(@[listener]))
    check lc.status == csRefused
    check lc.conflicts[0].class == ccPermission

suite "Remix M2 — patch reader refuses hostile diffs":

  test "well-formed multi-file diffs are read":
    let files = parseUnifiedDiff(diff("a/b.c", 4, "x", "y") & diff("c.h", 1, "p", "q"), 1)
    check files.mapIt(it.path) == @["a/b.c", "c.h"]
    check files[0].hunks == @[Hunk(oldStart: 4, oldCount: 1)]

  test "traversal, absolute paths, renames, creation and lying counts are refused":
    check refusal(proc () = discard parseUnifiedDiff(diff("../../etc/passwd", 1, "a", "b"), 1)) == $rrInvalidText
    check refusal(proc () = discard parseUnifiedDiff(
      "--- /etc/passwd\n+++ /etc/passwd\n@@ -1,1 +1,1 @@\n-a\n+b\n", 0)) == $rrInvalidText
    check refusal(proc () = discard parseUnifiedDiff(
      "--- /dev/null\n+++ b/new.c\n@@ -0,0 +1,1 @@\n+a\n", 1)) == $rrForbiddenContent
    check refusal(proc () = discard parseUnifiedDiff(
      "--- a/x.c\n+++ b/y.c\n@@ -1,1 +1,1 @@\n-a\n+b\n", 1)) == $rrForbiddenContent
    check refusal(proc () = discard parseUnifiedDiff(
      "--- a/x.c\n+++ b/x.c\n@@ -1,3 +1,1 @@\n-a\n+b\n", 1)) == $rrMalformed
    check refusal(proc () = discard parseUnifiedDiff("Binary files a/x and b/x differ\n", 1)) == $rrForbiddenContent
    check refusal(proc () = discard parseUnifiedDiff("just text\n", 1)) == $rrMalformed

  test "hunk overlap treats touching ranges as conflicting":
    check overlaps(Hunk(oldStart: 10, oldCount: 1), Hunk(oldStart: 11, oldCount: 1))
    check overlaps(Hunk(oldStart: 10, oldCount: 3), Hunk(oldStart: 12, oldCount: 1))
    check not overlaps(Hunk(oldStart: 10, oldCount: 1), Hunk(oldStart: 12, oldCount: 1))
