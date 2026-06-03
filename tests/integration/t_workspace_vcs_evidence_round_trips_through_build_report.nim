## Workspace VCS — unified evidence round-trip (M4).
##
## M4 introduces ``WorkspaceVcsEvidence``: a single typed record that
## carries the structured output of the M2/M3 query actions
## (``head-sha`` / ``is-clean`` / ``is-published``) across the per-VCS
## boundary so downstream tools (``repro workspace status``,
## ``repro check``) consume one shape rather than re-parsing
## ``GitQueryResult`` and ``HgQueryResult`` separately.
##
## This suite is pure: it does NOT shell out to git or hg. The required
## adapters and codecs are exercised against synthesised fixtures so the
## test passes even in environments without ambient VCSes. There is no
## ``skip()`` path — every case asserts.
##
## Cases:
##   1. ``test_m4_evidence_round_trips_through_ssz`` —
##      one record per (vcsKind × queryOp × status) combination plus a
##      record with a non-empty ``diagnostic``, encoded through
##      ``toSsz`` and decoded back. The decoded seq MUST be
##      element-wise equal to the input.
##   2. ``test_m4_evidence_round_trips_through_json`` —
##      same seq through ``toJson`` / ``parseJson`` / ``fromJson``. The
##      decoded seq MUST be element-wise equal to the input.
##   3. ``test_m4_evidence_lands_in_build_report`` — a non-empty seq is
##      embedded into ``build-report.json`` via the JSON view; the
##      written report parses, and the ``workspaceVcs`` array contains
##      exactly the expected records in source order. The test invokes
##      ``toJson`` to mirror what ``writeBuildReport`` does internally
##      (we do not exercise the full ``writeBuildReport`` here because
##      its other parameters require building a full ``BuildRunResult``
##      / ``ProviderCompileArtifact`` / ``ProviderRefreshReport`` plan
##      and the M4 seam is the ``workspaceVcs`` array shape).
##   4. ``test_m4_evidence_envelope_magic_is_distinct`` — the SSZ
##      envelope starts with the documented magic string
##      ``reprobuild.workspaceVcsEvidence.v1``, and both a wrong-magic
##      payload and a truncated payload raise the structured
##      ``WorkspaceVcsEvidenceCodecError``.
##   5. ``test_m4_adapter_maps_git_query_result_exactly`` — a
##      ``GitQueryResult`` populated with distinctive field values maps
##      to the unified evidence with ``vcsKind = wvkGit`` and every
##      field preserved.
##   6. ``test_m4_adapter_maps_hg_query_result_exactly`` — same for
##      ``HgQueryResult`` → ``wvkHg``.

import std/[json, os, sequtils, strutils, tempfiles, unittest]

import evidence
import git_actions
import hg_actions

proc fixtureEvidence(): seq[WorkspaceVcsEvidence] =
  ## Construct one record per (vcsKind × op × status) combination plus
  ## an explicit diagnostic-bearing record. The values are deliberately
  ## distinctive so a byte-level field swap would surface as a failed
  ## equality assertion rather than a green test.
  var items: seq[WorkspaceVcsEvidence] = @[]
  var counter = 0
  for kind in [wvkGit, wvkHg]:
    for op in [wvqHeadSha, wvqIsClean, wvqIsPublished]:
      for status in [wvesResolved, wvesFailed]:
        counter.inc
        let kindTag = (if kind == wvkGit: "git" else: "hg")
        let opTag = case op
          of wvqHeadSha: "head-sha"
          of wvqIsClean: "is-clean"
          of wvqIsPublished: "is-published"
        items.add(WorkspaceVcsEvidence(
          vcsKind: kind,
          path: "workspace/" & kindTag & "/" & opTag,
          op: op,
          status: status,
          headSha:
            if op == wvqHeadSha and status == wvesResolved:
              "deadbeef" & $counter
            else: "",
          isClean:
            op == wvqIsClean and status == wvesResolved and (counter mod 2 == 0),
          isPublished:
            op == wvqIsPublished and status == wvesResolved and (counter mod 2 == 1),
          diagnostic:
            if status == wvesFailed: "synthetic failure #" & $counter
            else: "",
          vcsToolDigestHex: (if kind == wvkGit: "01" else: "02").repeat(32),
          observedAtUnixMs: 1717_500_000_000'i64 + int64(counter)))
  # One additional record specifically to cover the "resolved op with a
  # non-empty diagnostic" corner — the codec must preserve such a
  # record byte-identically even when the diagnostic is semantically
  # unusual for a resolved status (downstream tools may surface a
  # cache-restore warning here).
  items.add(WorkspaceVcsEvidence(
    vcsKind: wvkGit,
    path: "workspace/git/head-sha-with-note",
    op: wvqHeadSha,
    status: wvesResolved,
    headSha: "cafef00d",
    isClean: false,
    isPublished: true,
    diagnostic: "resolved with cache-restore note",
    vcsToolDigestHex: "ab".repeat(32),
    observedAtUnixMs: 1717_500_000_999'i64))
  items

suite "Workspace VCS — evidence round-trip (M4)":

  test "test_m4_evidence_round_trips_through_ssz":
    let items = fixtureEvidence()
    let encoded = toSsz(items)
    let decoded = fromSsz(encoded)
    check decoded.len == items.len
    for i in 0 ..< items.len:
      check decoded[i].vcsKind == items[i].vcsKind
      check decoded[i].path == items[i].path
      check decoded[i].op == items[i].op
      check decoded[i].status == items[i].status
      check decoded[i].headSha == items[i].headSha
      check decoded[i].isClean == items[i].isClean
      check decoded[i].isPublished == items[i].isPublished
      check decoded[i].diagnostic == items[i].diagnostic
      check decoded[i].vcsToolDigestHex == items[i].vcsToolDigestHex
      check decoded[i].observedAtUnixMs == items[i].observedAtUnixMs

  test "test_m4_evidence_round_trips_through_json":
    let items = fixtureEvidence()
    let viewText = $toJson(items)
    let parsed = parseJson(viewText)
    let decoded = fromJson(parsed)
    check decoded.len == items.len
    for i in 0 ..< items.len:
      check decoded[i].vcsKind == items[i].vcsKind
      check decoded[i].path == items[i].path
      check decoded[i].op == items[i].op
      check decoded[i].status == items[i].status
      check decoded[i].headSha == items[i].headSha
      check decoded[i].isClean == items[i].isClean
      check decoded[i].isPublished == items[i].isPublished
      check decoded[i].diagnostic == items[i].diagnostic
      check decoded[i].vcsToolDigestHex == items[i].vcsToolDigestHex
      check decoded[i].observedAtUnixMs == items[i].observedAtUnixMs

  test "test_m4_evidence_lands_in_build_report":
    let items = fixtureEvidence()
    # Mirror the exact shape ``writeBuildReport`` writes for its
    # ``workspaceVcs`` field: ``toJson`` of the unified evidence seq.
    # Then write a synthesised report and re-parse to assert the
    # field round-trips through the report container. The full
    # ``writeBuildReport`` call requires a complete BuildRunResult
    # graph; the M4 contract is the ``workspaceVcs`` slot specifically.
    let scratch = createTempDir("repro-m4-report-", "")
    defer: removeDir(scratch)
    let reportPath = scratch / "build-report.json"
    let root = %*{
      "providerBinary": "",
      "providerFingerprint": "",
      "providerCompileOutput": "",
      "cmakeRegenerationActions": newJArray(),
      "providerCompileActions": newJArray(),
      "providerSnapshot": "",
      "providerInvocations": 0,
      "actions": newJArray(),
      "trace": newJArray(),
      "workspaceVcs": toJson(items),
      "stats": newJObject()
    }
    writeFile(reportPath, $root)

    let parsed = parseJson(readFile(reportPath))
    check parsed.hasKey("workspaceVcs")
    let restored = fromJson(parsed["workspaceVcs"])
    check restored.len == items.len
    for i in 0 ..< items.len:
      check restored[i].vcsKind == items[i].vcsKind
      check restored[i].path == items[i].path
      check restored[i].op == items[i].op
      check restored[i].status == items[i].status
      check restored[i].headSha == items[i].headSha
      check restored[i].isClean == items[i].isClean
      check restored[i].isPublished == items[i].isPublished
      check restored[i].diagnostic == items[i].diagnostic
      check restored[i].vcsToolDigestHex == items[i].vcsToolDigestHex
      check restored[i].observedAtUnixMs == items[i].observedAtUnixMs

    # An empty seq must surface as an empty JSON array, not as
    # ``null`` or as a missing key — this is the contract the
    # downstream readers rely on.
    let emptyView = toJson(@[])
    check emptyView.kind == JArray
    check emptyView.len == 0

  test "test_m4_evidence_envelope_magic_is_distinct":
    let items = fixtureEvidence()
    let encoded = toSsz(items)
    # The magic is length-prefixed by ``writeString``: 4 bytes of
    # little-endian length followed by the UTF-8 bytes of the magic.
    check encoded.len >= 4 + WorkspaceVcsEvidenceMagic.len
    let declaredLen =
      uint32(encoded[0]) or
      (uint32(encoded[1]) shl 8) or
      (uint32(encoded[2]) shl 16) or
      (uint32(encoded[3]) shl 24)
    check int(declaredLen) == WorkspaceVcsEvidenceMagic.len
    var magicBytes = newString(int(declaredLen))
    for i in 0 ..< int(declaredLen):
      magicBytes[i] = char(encoded[4 + i])
    check magicBytes == WorkspaceVcsEvidenceMagic

    # Wrong magic → structured error.
    var wrongMagic = encoded
    # Flip the first character of the magic body (after the 4-byte
    # length prefix). This invalidates the magic without altering its
    # declared length, so the reader walks the length prefix
    # successfully and only fails on the string-equality check.
    wrongMagic[4] = byte(ord('X'))
    expect WorkspaceVcsEvidenceCodecError:
      discard fromSsz(wrongMagic)

    # Truncation in the middle of the SSZ body → structured error.
    let truncated = encoded[0 ..< encoded.len - 4]
    expect WorkspaceVcsEvidenceCodecError:
      discard fromSsz(truncated)

    # Truncation inside the magic itself → structured error.
    let truncatedMagic = encoded[0 ..< 5]
    expect WorkspaceVcsEvidenceCodecError:
      discard fromSsz(truncatedMagic)

  test "test_m4_adapter_maps_git_query_result_exactly":
    let input = GitQueryResult(
      status: gqsOk,
      headSha: "1234567890abcdef",
      isClean: true,
      isPublished: false,
      diagnostic: "git-side diagnostic note")
    let mapped = evidenceFor(input,
      path = "workspace/git/example",
      op = wvqIsClean,
      vcsToolDigestHex = "11".repeat(32),
      observedAtUnixMs = 1717_500_100_000'i64)
    check mapped.vcsKind == wvkGit
    check mapped.path == "workspace/git/example"
    check mapped.op == wvqIsClean
    check mapped.status == wvesResolved
    check mapped.headSha == input.headSha
    check mapped.isClean == input.isClean
    check mapped.isPublished == input.isPublished
    check mapped.diagnostic == input.diagnostic
    check mapped.vcsToolDigestHex == "11".repeat(32)
    check mapped.observedAtUnixMs == 1717_500_100_000'i64

    # Failed path: status maps to wvesFailed and the diagnostic is
    # preserved verbatim.
    let failed = GitQueryResult(
      status: gqsFailed,
      headSha: "",
      isClean: false,
      isPublished: false,
      diagnostic: "git rev-parse HEAD failed: not a repository")
    let mappedFail = evidenceFor(failed,
      path = "workspace/git/broken",
      op = wvqHeadSha,
      vcsToolDigestHex = "22".repeat(32),
      observedAtUnixMs = 1717_500_200_000'i64)
    check mappedFail.vcsKind == wvkGit
    check mappedFail.status == wvesFailed
    check mappedFail.diagnostic == failed.diagnostic
    check mappedFail.path == "workspace/git/broken"
    check mappedFail.op == wvqHeadSha

  test "test_m4_adapter_maps_hg_query_result_exactly":
    let input = HgQueryResult(
      status: hqsOk,
      headSha: "abcdef1234567890",
      isClean: false,
      isPublished: true,
      diagnostic: "hg-side diagnostic note")
    let mapped = evidenceFor(input,
      path = "workspace/hg/example",
      op = wvqIsPublished,
      vcsToolDigestHex = "33".repeat(32),
      observedAtUnixMs = 1717_500_300_000'i64)
    check mapped.vcsKind == wvkHg
    check mapped.path == "workspace/hg/example"
    check mapped.op == wvqIsPublished
    check mapped.status == wvesResolved
    check mapped.headSha == input.headSha
    check mapped.isClean == input.isClean
    check mapped.isPublished == input.isPublished
    check mapped.diagnostic == input.diagnostic
    check mapped.vcsToolDigestHex == "33".repeat(32)
    check mapped.observedAtUnixMs == 1717_500_300_000'i64

    # Failed path mirror for hg.
    let failed = HgQueryResult(
      status: hqsFailed,
      headSha: "",
      isClean: false,
      isPublished: false,
      diagnostic: "hg id -i failed: abort: no repository found")
    let mappedFail = evidenceFor(failed,
      path = "workspace/hg/broken",
      op = wvqHeadSha,
      vcsToolDigestHex = "44".repeat(32),
      observedAtUnixMs = 1717_500_400_000'i64)
    check mappedFail.vcsKind == wvkHg
    check mappedFail.status == wvesFailed
    check mappedFail.diagnostic == failed.diagnostic
    check mappedFail.path == "workspace/hg/broken"
    check mappedFail.op == wvqHeadSha

# Reference ``sequtils`` to keep the import alive in case future
# refactors trim seq comprehensions from the body above.
discard @[1].mapIt(it).len
