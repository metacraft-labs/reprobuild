## Role-checked statements through the registry Boundary
## (`Remix-Registry.md` §"Admission", statements): a release's reviews,
## vouches, yanks and evidence reach clients only when the signer held the
## required role at the statement's log position, and authors cannot review
## their own lineage (Trust And Reputation invariant). Real keys, real key
## logs, the real registrar; frames go straight into the spool.

import std/[os, sequtils, tempfiles, unittest]

import repro_remix
import repro_remix_registry
import ../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

proc bytesOf(s: string): seq[byte] = s.mapIt(byte(ord(it)))
proc d32(seed: byte): Digest32 =
  for i in 0 ..< 32: result[i] = seed xor byte(i)
proc kid(k: PeerKeypair): Digest32 = Digest32(keyIdOf(k))

let logKey = generateKeypair()

proc frame(payload: seq[byte]): seq[byte] =
  encodeMessage(BoundaryMessage(msgType: mtSubmitRelease, intake: "i", rateKey: "k",
                                payload: payload))

proc genesis(k: PeerKeypair; roles: set[Role]): seq[byte] =
  encodeEnvelope(entrySigned(KeyLogEntry(operation: klGenesis,
    algorithm: saEcdsaP256, publicKey: @(k.publicKey), roles: roles), @[k]))

proc manifest(name: string; k: PeerKeypair; parents: seq[Digest32] = @[]): seq[byte] =
  var env = newManifestEnvelope(Manifest(remixName: name, version: "1.0.0",
    intent: "Fixture.", license: "MIT", targets: @[Target(original: OriginalRef(
      package: "firefox", interfaceFingerprint: d32(1),
      catalogWorkspace: "reprobuild-packages",
      catalogRemote: "https://github.com/metacraft-labs/reprobuild-packages",
      catalogRevision: "0123456789abcdef0123456789abcdef01234567",
      catalogInterfaceArtifact: d32(2)), constraintKind: ckExactFingerprint)],
    parents: parents, authors: @[kid(k)]))
  env.signEnvelope(k)
  encodeEnvelope(env)

proc statement(kind: StatementKind; subject: Digest32; k: PeerKeypair): seq[byte] =
  var env = newStatementEnvelope(Statement(kind: kind, subjectKind: sbRelease,
                                           subject: subject, issuer: kid(k)))
  env.signEnvelope(k)
  encodeEnvelope(env)

suite "Remix registry — role-checked statements":

  test "reviews, yanks and evidence are admitted only from the right role":
    let root = createTempDir("remix-statements-", "")
    defer: removeDir(root)
    let reg = newRegistrar(dirs(root), logKey)
    let spool = initSpool(dirs(root).spoolDir)
    let author = generateKeypair()
    let reviewer = generateKeypair()
    let builder = generateKeypair()
    let stranger = generateKeypair()
    for (k, roles) in [(author, {roleAuthor, roleReviewer}), (reviewer, {roleReviewer}),
                       (builder, {roleBuilder}), (stranger, {roleAuthor})]:
      discard spool.deliver("i", frame(genesis(k, roles)))
    discard reg.tick()
    let parent = manifest("alice/base", author)
    discard spool.deliver("i", frame(parent))
    discard reg.tick()
    let parentId = Digest32(decodeAndVerify(parent).id)
    let child = manifest("strange/child", stranger, @[parentId])
    discard spool.deliver("i", frame(child))
    discard reg.tick()
    let childId = Digest32(decodeAndVerify(child).id)

    proc submit(b: seq[byte]): Outcome =
      discard spool.deliver("i", frame(b))
      reg.tick()[0]

    # A reviewer reviews; a builder attaches evidence; the author yanks.
    check submit(statement(skReview, parentId, reviewer)).admitted
    check submit(statement(skBuildEvidence, parentId, builder)).admitted
    check submit(statement(skYank, parentId, author)).admitted
    # Wrong roles and wrong people are refused.
    check submit(statement(skReview, parentId, builder)).refusal == rrInactiveKey
    check submit(statement(skYank, parentId, stranger)).refusal == rrForbiddenContent
    check submit(statement(skBuildEvidence, parentId, reviewer)).refusal == rrInactiveKey
    # The author holds a reviewer role but may not review their own lineage —
    # neither their release nor a descendant someone else built on it.
    check submit(statement(skReview, parentId, author)).refusal == rrForbiddenContent
    check submit(statement(skReview, childId, author)).refusal == rrForbiddenContent
    # Policy kinds never come through the Boundary.
    check submit(statement(skVerdict, parentId, reviewer)).refusal == rrForbiddenContent
    # Two reviewers' identical judgements are two statements, both logged.
    let second = generateKeypair()
    discard spool.deliver("i", frame(genesis(second, {roleReviewer})))
    discard reg.tick()
    check submit(statement(skReview, parentId, second)).admitted
    # Claiming another key as issuer is refused.
    var forged = newStatementEnvelope(Statement(kind: skReview, subjectKind: sbRelease,
      subject: parentId, issuer: kid(reviewer)))
    forged.signEnvelope(second)
    check submit(encodeEnvelope(forged)).refusal == rrForbiddenContent
    # A statement about a release the registry does not hold.
    check submit(statement(skReview, d32(99), reviewer)).refusal == rrDanglingReference
