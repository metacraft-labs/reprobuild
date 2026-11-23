#!/usr/bin/env python3
"""Apply each filed mutation, rebuild the gate it targets, RUN it, and
restore the tree byte for byte.

A check whose defeating mutation has not been executed is not yet known
to be a check. This driver is how that gets executed rather than
reasoned about: every row names one file, one exact substring, and the
one-line replacement that should defeat the rule -- and the row is only
worth anything if the gate goes RED and the file comes back
sha256-identical afterwards.

Usage:
  python3 tools/attestation-mutations/fixture_lifecycle_mutations.py           # all
  python3 tools/attestation-mutations/fixture_lifecycle_mutations.py L1 R4     # some
  python3 tools/attestation-mutations/fixture_lifecycle_mutations.py --list

Run it from the repository root inside the development shell.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRATCH = Path(os.environ.get("FIXTURE_MUTATION_SCRATCH", tempfile.gettempdir())) / "fixture-lifecycle-mutations"

LIFECYCLE = "tests/integration/t_attestation_fixture_lifecycle.nim"
ROTATION = "tests/integration/t_signer_roster_rotation_and_revocation.nim"

LEDGER = "tests/integration/attestation-fixture-ledger.tsv"
CENSUS = "tests/integration/attestation-corpus-census.tsv"
PUBLISHERS = "tests/integration/attestation-fixture-publishers.tsv"
LIFEMOD = "libs/repro_attest_verify/src/repro_attest_verify/lifecycle.nim"
QUORUM = "libs/repro_attest_verify/src/repro_attest_verify/quorum.nim"
VERIFY = "libs/repro_attest_verify/src/repro_attest_verify/verify.nim"
LEDGERMOD = "tests/integration/attestation_fixture_ledger.nim"
SNPVEC = "tests/integration/snp_vectors.nim"
SNPGATE = "tests/integration/t_snp_fixture_verify.nim"
MONITOR = "tools/attestation_collateral_monitor.py"
CLIATTEST = "libs/repro_cli_support/src/repro_cli_support/attest.nim"
VERDICTGATE = "tests/integration/t_snp_evidence_reaches_the_verdict.nim"
SNPTCB = "tests/integration/t_snp_tcb_policy.nim"
FETCH = "tests/integration/attestation-fixture-fetch.tsv"
TDXVEC = "tests/integration/tdx_vectors.nim"
TDXCHAIN = "tests/integration/t_tdx_chain_requires_intel_root.nim"
TDXCOLL = "tests/integration/t_tdx_collateral_and_verifier_arm.nim"
SNPFIXTURE = "tests/integration/t_snp_fixture_verify.nim"
WORKFLOW = ".github/workflows/attestation-collateral.yml"

DEFINES: dict[str, list[str]] = {}


@dataclass
class Row:
    ident: str
    what: str
    gate: str
    edits: list[tuple[str, str, str]] = field(default_factory=list)
    """(path, exact substring to find, replacement)"""
    adds: list[tuple[str, str]] = field(default_factory=list)
    """(path, whole file content) for files the mutation CREATES"""
    expect: str = "RED"


ROWS: list[Row] = [
    # ---- the ledger describes the bytes -----------------------------
    Row("L1", "one character of a recorded digest is changed",
        LIFECYCLE,
        [(LEDGER,
          "dd68e9e3feb97dd0e95135feeae47d9cc193c73239a6281ec9884c00d5e6a525",
          "dd68e9e3feb97dd0e95135feeae47d9cc193c73239a6281ec9884c00d5e6a524")]),
    Row("L2", "a recorded not_after is moved by one day",
        LIFECYCLE,
        [(LEDGER, "amd-revocation-list\t2026-09-22T07:35:42Z\t2026-11-09T01:00:00Z",
          "amd-revocation-list\t2026-09-22T07:35:42Z\t2026-11-10T01:00:00Z")]),
    Row("L3", "a recorded not_before is moved by one second",
        LIFECYCLE,
        [(LEDGER, "x509-revocation-list\t2026-02-26T13:04:00Z",
          "x509-revocation-list\t2026-02-26T13:04:01Z")]),
    Row("L4", "a recorded byte count is off by one",
        LIFECYCLE,
        [(LEDGER, "\t4602\t22e62f8d", "\t4601\t22e62f8d")]),
    Row("L5", "bytesOf returns nothing for one row",
        LIFECYCLE,
        [(LEDGERMOD, 'of "KdsMilanCrlDerHex"                         : unhexOf(KdsMilanCrlDerHex)',
          'of "KdsMilanCrlDerHex"                         : ""')]),
    # ---- completeness ------------------------------------------------
    Row("L6", "a corpus constant is added with no ledger row",
        LIFECYCLE,
        [(SNPVEC, "  KdsMilanChainPem* = ",
          "  KdsMilanExtraHex* = \"00\"\n  KdsMilanChainPem* = ")]),
    Row("L7", "a ledger row is deleted",
        LIFECYCLE,
        [(LEDGER, "\nKdsTurinCrlDerHex\t", "\n#KdsTurinCrlDerHex\t")]),
    Row("L8", "a census row is deleted",
        LIFECYCLE,
        [(CENSUS, "\nnitro_vectors.nim\t", "\n#nitro_vectors.nim\t")]),
    Row("L9", "a new corpus module appears with no census row",
        LIFECYCLE, [],
        [("tests/integration/zz_mutation_vectors.nim",
          "const ZzMutationCorpus* = \"00\"\n")]),
    Row("L10", "a publisher's remedy is emptied",
        LIFECYCLE,
        [(PUBLISHERS,
          "this-repository\tminted here, to be refused or as a reading derived from another pinned artifact\t-\tregenerate with the script or tool the corpus module's own header names; it has no upstream and cannot drift",
          "this-repository\tminted here, to be refused or as a reading derived from another pinned artifact\t-\t-")]),
    Row("L11", "the source scan returns the ledger's own names instead of reading",
        LIFECYCLE,
        [(LIFECYCLE, "  for raw in readFile(integrationDir() / module).splitLines():",
          "  for r in ledgerRows():\n    if r.module == module: result.add r.name\n  if true: return\n  for raw in readFile(integrationDir() / module).splitLines():")]),
    # ---- pinned clocks ----------------------------------------------
    Row("L12", "a pinned clock is moved past the collateral it judges",
        LIFECYCLE,
        [(SNPGATE, "  Now = 1_790_121_600'i64", "  Now = 1_795_000_000'i64"),
         (LIFECYCLE, 'source: "t_snp_fixture_verify.nim", now: 1_790_121_600\'i64',
          'source: "t_snp_fixture_verify.nim", now: 1_795_000_000\'i64')]),
    Row("L13", "a sixth gate pins a clock and no row names it",
        LIFECYCLE, [],
        [("tests/integration/t_zz_mutation_clock.nim",
          "const\n  Now = 1_790_121_600'i64\n\nwhen isMainModule: discard Now\n")]),
    Row("L14", "a gate's pinned clock is transcribed wrongly into the table",
        LIFECYCLE,
        [(LIFECYCLE, 'source: "t_snp_tcb_policy.nim", now: 1_790_121_600\'i64',
          'source: "t_snp_tcb_policy.nim", now: 1_790_121_601\'i64')]),
    Row("L15", "a gate's list of what it judges is emptied",
        LIFECYCLE,
        [(LIFECYCLE,
          """source: "t_snp_tcb_policy.nim", now: 1_790_121_600'i64,
      mustBeCurrent: @["GsgMilanVcekDerHex", "KdsMilanCrlDerHex",
                       "VirteeMilanVcekDerHex"],""",
          """source: "t_snp_tcb_policy.nim", now: 1_790_121_600'i64,
      mustBeCurrent: @[],""")]),
    # ---- the lifecycle decision --------------------------------------
    Row("L16", "classify treats the expiry instant as still current",
        LIFECYCLE,
        [(LIFEMOD, "  if nowSeconds >= w.notAfter:\n    return lsExpired",
          "  if nowSeconds > w.notAfter:\n    return lsExpired")]),
    Row("L17", "classify folds no-stated-end into current",
        LIFECYCLE,
        [(LIFEMOD, "  if not w.hasNotAfter:\n    return lsNoStatedEnd",
          "  if not w.hasNotAfter:\n    return lsCurrent")]),
    Row("L18", "classify tests the end before the start",
        LIFECYCLE,
        [(LIFEMOD,
          "  if w.hasNotBefore and nowSeconds < w.notBefore:\n    return lsNotYetInForce\n  if not w.hasNotAfter:",
          "  if w.hasNotAfter and nowSeconds >= w.notAfter:\n    return lsExpired\n  if w.hasNotBefore and nowSeconds < w.notBefore:\n    return lsNotYetInForce\n  if not w.hasNotAfter:")]),
    Row("L19", "isUsable admits an expired artifact",
        LIFECYCLE,
        [(LIFEMOD, "  s in {lsCurrent, lsDueForRefresh}",
          "  s in {lsCurrent, lsDueForRefresh, lsExpired}")]),
    Row("L20", "the refresh horizon is cut from thirty days to seven",
        LIFECYCLE,
        [(LIFEMOD, "  DefaultRefreshHorizonDays* = 30",
          "  DefaultRefreshHorizonDays* = 7")]),
    Row("L21", "a revocation list with no end is given one",
        LIFECYCLE,
        [(LIFEMOD, "  else: windowEndingNever(crl.thisUpdate)",
          "  else: window(crl.thisUpdate, crl.thisUpdate + 1)")]),
    Row("L22", "the collateral document's two dates are read the wrong way round",
        LIFECYCLE,
        [(LIFEMOD,
          '  window(parseIsoInstant(issueDate, "the document\'s issue date"),\n         parseIsoInstant(nextUpdate, "the document\'s next-update date"))',
          '  window(parseIsoInstant(nextUpdate, "the document\'s next-update date"),\n         parseIsoInstant(issueDate, "the document\'s issue date"))')]),
    Row("L23", "a trust root that drifted is reported as expected to differ",
        LIFECYCLE,
        [(LIFEMOD,
          "  of lcProtocolVector, lcTrustRoot, lcVendorCollateral, lcHistoricalVintage:",
          "  of lcTrustRoot:\n    if pinnedSha256 == observedSha256: doUnchanged else: doExpectedToDiffer\n  of lcProtocolVector, lcVendorCollateral, lcHistoricalVintage:")]),
    # NOTE, because the first attempt at this row was measured GREEN and
    # the reason is worth keeping: splitting `lcTrustRoot` out of the
    # shared arm is not by itself a mutation. The arm it was split into
    # has to DECIDE differently, or the two spellings compile to the
    # same program and a green gate is the correct answer. A mutation
    # that does not change behaviour tests nothing, and the only way to
    # find out which kind you wrote is to run it.
    Row("L24", "a class with no publisher answers instead of refusing",
        LIFECYCLE,
        [(LIFEMOD,
          "  of lcMintedNegative, lcDerivedReading:\n    raise newException(LifecycleError,",
          "  of lcMintedNegative, lcDerivedReading:\n    return (if pinnedSha256 == observedSha256: doUnchanged else: doDrifted)\n  of lcNeverReached:\n    raise newException(LifecycleError,")],
        expect="COMPILE-REFUSED"),
    Row("L25", "an instruction is built with no remedy",
        LIFECYCLE,
        [(LIFEMOD,
          '  if refreshWith.len == 0:\n    raise newException(LifecycleError,',
          '  if false:\n    raise newException(LifecycleError,')]),
    Row("L26", "the remedy is dropped from the instruction's text",
        LIFECYCLE,
        [(LIFEMOD, '  result.add ". It is " & $class & " from " & origin &\n    ". Refresh it with: " & refreshWith',
          '  result.add ". It is " & $class & " from " & origin & "."')]),
    Row("L27", "an absent observation is read as no change",
        LIFECYCLE,
        [(LIFEMOD,
          "  if pinnedSha256.len == 0 or observedSha256.len == 0:\n    raise newException(LifecycleError,",
          "  if false:\n    raise newException(LifecycleError,")]),
    Row("L28", "a comment is reworded and nothing else (GREEN control)",
        LIFECYCLE,
        [(LIFEMOD, "## ## Mocking\n##\n## None. Real DER, real dates,",
          "## ## Mocking\n##\n## Nothing is mocked. Real DER, real dates,")],
        expect="GREEN"),
    Row("L29", "the scan's discriminator is pointed at a LEDGERED module",
        LIFECYCLE,
        [(LIFECYCLE, '  UnledgeredCorpus = "tcg_event_log_vectors.nim"',
          '  UnledgeredCorpus = "snp_vectors.nim"')]),
    Row("L30", "the unreadable trust root is relabelled as readable",
        LIFECYCLE,
        [(LEDGER, "\tunreadable\t-\t-", "\tx509-certificate\t-\t-")]),
    Row("L31", "minted material is given an observation date",
        LIFECYCLE,
        [(LEDGER,
          "ImpostorArkHex\tsnp_vectors.nim\tminted-negative\tthis-repository\t-",
          "ImpostorArkHex\tsnp_vectors.nim\tminted-negative\tthis-repository\t2026-10-02")]),
    # ---- sanitization ------------------------------------------------
    Row("S1", "a private key is pasted into a corpus module's header",
        LIFECYCLE,
        [(SNPVEC, "## Pinned SEV-SNP material:",
          "## -----BEGIN EC PRIVATE KEY-----\n## Pinned SEV-SNP material:")]),
    Row("S2", "a private key reaches a pinned artifact's own bytes",
        LIFECYCLE,
        [(LEDGERMOD,
          'of "KdsMilanChainPem"                          : KdsMilanChainPem',
          'of "KdsMilanChainPem"                          : "-----BEGIN EC PRIVATE KEY-----"')]),
    Row("S3", "the scan stops reading and reports nothing for everything",
        LIFECYCLE,
        [(LIFECYCLE, "proc rowsContaining(marker: string): seq[string] =\n  for row in ledgerRows():",
          "proc rowsContaining(marker: string): seq[string] =\n  if true: return\n  for row in ledgerRows():")]),
    Row("S4", "the public-marker count is satisfied by the obvious four",
        LIFECYCLE,
        [(LIFECYCLE, "  PublicMarkerRows = 10", "  PublicMarkerRows = 4")]),
    # ---- the roster --------------------------------------------------
    Row("R1", "a roster entry may state no end to its admission",
        ROTATION,
        [(QUORUM, "    if not s.admission.hasNotAfter:\n      raise newException(RosterError,",
          "    if false:\n      raise newException(RosterError,")]),
    Row("R2", "a degenerate admission window is accepted",
        ROTATION,
        [(QUORUM, "    if s.admission.notAfter <= s.admission.notBefore:",
          "    if s.admission.notAfter < s.admission.notBefore:")]),
    Row("R3", "a revocation may carry no reason",
        ROTATION,
        [(QUORUM, "      if s.admission.revocationReason.len == 0:",
          "      if false:")]),
    Row("R4", "a revocation before the admission began is accepted",
        ROTATION,
        [(QUORUM, "      if s.admission.revokedAt < s.admission.notBefore:",
          "      if false:")]),
    Row("R5", "the admission window is tested before the revocation",
        ROTATION,
        [(QUORUM,
          "  if a.revoked and nowSeconds >= a.revokedAt: return saRevoked\n  if nowSeconds < a.notBefore: return saNotYetAdmitted",
          "  if nowSeconds < a.notBefore: return saNotYetAdmitted\n  if a.hasNotAfter and nowSeconds >= a.notAfter: return saAdmissionEnded\n  if a.revoked and nowSeconds >= a.revokedAt: return saRevoked")]),
    Row("R6", "the admission window stays open one second past its end",
        ROTATION,
        [(QUORUM, "  if a.hasNotAfter and nowSeconds >= a.notAfter: return saAdmissionEnded",
          "  if a.hasNotAfter and nowSeconds > a.notAfter: return saAdmissionEnded")]),
    Row("R7", "a revocation takes effect one second early",
        ROTATION,
        [(QUORUM, "  if a.revoked and nowSeconds >= a.revokedAt: return saRevoked",
          "  if a.revoked and nowSeconds > a.revokedAt - 2: return saRevoked")]),
    Row("R8", "a revoked signer reports as merely lapsed",
        ROTATION,
        [(QUORUM, "  of saRevoked: qeoSignerRevoked",
          "  of saRevoked: qeoSignerAdmissionEnded")]),
    Row("R9", "a lapsed signature becomes a defect that denies the bundle",
        ROTATION,
        [(QUORUM,
          "      result.entries.add entry\n      continue\n\n    if entry.signer in result.countedSigners:",
          "      result.entries.add entry\n      result.defects.add entry.detail\n      continue\n\n    if entry.signer in result.countedSigners:")]),
    Row("R10", "the evaluation stops carrying the revocation caveat",
        ROTATION,
        [(QUORUM, "      result.caveats.add RevocationHasNoSigningTimeCaveat\n      break",
          "      break")]),
    Row("R11", "the revocation caveat rides every evaluation",
        ROTATION,
        [(QUORUM,
          "  for s in roster:\n    if s.admission.revoked and nowSeconds >= s.admission.revokedAt:",
          "  result.caveats.add RevocationHasNoSigningTimeCaveat\n  for s in roster:\n    if false:")]),
    Row("R12", "the verifier judges the roster at a fixed instant",
        ROTATION,
        [(VERIFY, "                                   req.signerRoster, req.nowMs div 1000)",
          "                                   req.signerRoster, 1_000_003_600'i64)")]),
    Row("R13", "the admission check is skipped entirely",
        ROTATION,
        [(QUORUM, "      if state == saAdmitted: break admission",
          "      if true: break admission")]),
    Row("R14", "a comment is reworded and nothing else (GREEN control)",
        ROTATION,
        [(QUORUM, "## ## Mocking\n##\n## None. Real ECDSA over real bytes.",
          "## ## Mocking\n##\n## Nothing is mocked. Real ECDSA over real bytes.")],
        expect="GREEN"),
    # ---- the commitment salt: WITHDRAWN, the subject is gone ---------
    #
    # Rows C1-C3 mutated `libs/repro_attest/src/repro_attest/commitment.nim`
    # and ran `t_inference_commitment_is_hiding_and_binding`. Neither file
    # exists on this branch any more: both were deleted, together with the
    # whole authenticated-inference surface, by the commit that is the
    # parent of this tree's base. The rows are withdrawn rather than left
    # to report INCONCLUSIVE every run, because a row that cannot say
    # where it applies is not a row. They are recoverable verbatim from
    # this file's history if that surface returns.
    # ---- review's three repairs, each with its own defeating row ----
    Row("X1", "the pinned-clock scan is narrowed back to the indented form",
        LIFECYCLE,
        [(LIFECYCLE, '        if line.startsWith("const "): line = line[6 .. ^1].strip()',
          '        if false: line = line[6 .. ^1].strip()')]),
    Row("X2", "the monitor's class table is spelled differently from the enum",
        LIFECYCLE,
        [(MONITOR, '    "derived-reading": "no-publisher",',
          '    "derived_reading": "no-publisher",')]),
    Row("X3", "--vendor-revocation-list stops reaching the request",
        VERDICTGATE,
        [(CLIATTEST, "    req.vendorRevocationLists.add readFile(path)",
          "    discard readFile(path)")]),
    # ---- the refresh of 2026-10-02 and the two repairs it needed ----
    #
    # Every row below mutates something this change ADDED. A fix for a
    # check that could not fail is itself an unfalsified check.
    Row("N1", "a pinned clock is moved OFF the derived instant but left inside the window",
        LIFECYCLE,
        [(SNPTCB, "  Now = 1_790_121_600'i64        ## 2026-09-23T00:00:00Z; see",
          "  Now = 1_790_208_000'i64        ## 2026-09-23T00:00:00Z; see"),
         (LIFECYCLE, 'source: "t_snp_tcb_policy.nim", now: 1_790_121_600\'i64',
          'source: "t_snp_tcb_policy.nim", now: 1_790_208_000\'i64')]),
    Row("N2", "the clock rule rounds DOWN to a midnight instead of up",
        LIFECYCLE,
        [(LIFECYCLE, "  ((t + Day - 1) div Day) * Day", "  (t div Day) * Day")]),
    Row("N3", "the clock rule reads the END of each window instead of the start",
        LIFECYCLE,
        [(LIFECYCLE, "    if w.notBefore > result: result = w.notBefore",
          "    if w.notAfter > result: result = w.notAfter")]),
    Row("N4", "the horizon cap is removed and the flat thirty days comes back",
        LIFECYCLE,
        [(LIFEMOD, "  min(horizonSeconds, lifetime div 2)", "  horizonSeconds")]),
    Row("N5", "the horizon is capped at the whole lifetime instead of half",
        LIFECYCLE,
        [(LIFEMOD, "  min(horizonSeconds, lifetime div 2)",
          "  min(horizonSeconds, lifetime)")]),
    Row("N6", "the vintage class stops quietening anything",
        LIFECYCLE,
        [(LIFEMOD, "  if class == lcHistoricalVintage:\n    return status != lsExpired",
          "  if false:\n    return status != lsExpired")]),
    Row("N7", "the vintage class quietens a row whatever state it is in",
        LIFECYCLE,
        [(LIFEMOD, "  if class == lcHistoricalVintage:\n    return status != lsExpired",
          "  if class == lcHistoricalVintage:\n    return false")]),
    Row("N8", "the monitor keeps its own flat horizon",
        LIFECYCLE,
        [(MONITOR,
          "    if now + effective_horizon(not_before, not_after, horizon) >= not_after:",
          "    if now + horizon >= not_after:")]),
    Row("N9", "the monitor decides loudness from the status alone",
        LIFECYCLE,
        [(MONITOR, '        loud = expiry_needs_attention(row["class"], status)',
          '        loud = status in NEEDS_ATTENTION')]),
    Row("N10", "a vintage pinned for being old is given an unattended refresh route",
        LIFECYCLE,
        [(FETCH, "IntelSgxRootCaDerHex\thttps://certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer\tnone",
          "IntelSgxRootCaDerHex\thttps://certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer\tnone\nGtgQeIdentityJson\thttps://example.invalid/qe\tnone")]),
    Row("N11", "a merely out-of-date document is reclassified to quieten it",
        LIFECYCLE,
        [(LEDGER, "PcsTcbInfoEmrJson\ttdx_vectors.nim\tvendor-collateral",
          "PcsTcbInfoEmrJson\ttdx_vectors.nim\thistorical-vintage")]),
    Row("N12", "the reference instant is left behind while the corpus moves",
        LIFECYCLE,
        [(LEDGERMOD, "  LedgerReferenceInstant* = 1_790_985_600'i64",
          "  LedgerReferenceInstant* = 1_790_640_000'i64")]),
    Row("N13", "an observation date falls outside the window the artifact states",
        LIFECYCLE,
        [(LEDGER, "amd-kds\t2026-10-02\t866\tdd68e9e3",
          "amd-kds\t2026-09-01\t866\tdd68e9e3")]),
    Row("N14", "the next-expiry derivation reports the LAST one instead of the first",
        LIFECYCLE,
        [(LIFECYCLE, "      if w.notAfter < soonest:", "      if w.notAfter > soonest:")]),
    Row("N15", "the scheduled run loses the trigger it can reach",
        LIFECYCLE,
        [(WORKFLOW, "  push:\n    branches: [dev, agents]\n", "")]),
    Row("N16", "the per-landing arm starts going to the network",
        LIFECYCLE,
        [(WORKFLOW, "monitor.py --offline", "monitor.py")]),
    Row("N17", "a comment in the new horizon rule is reworded (GREEN control)",
        LIFECYCLE,
        [(LIFEMOD, "  ## Half, specifically, because half is the largest fraction that",
          "  ## Half, precisely, because half is the largest fraction that")],
        expect="GREEN"),
    # ---- the refresh of the trust-domain vendor's seven documents, and
    # ---- the mechanical tie that replaced the hand-kept clock lists --
    #
    # Same discipline as the N rows: every row below mutates something
    # THIS change added, not only the thing it was meant to catch.
    Row("P1", "one character of a re-pinned digest is changed",
        LIFECYCLE,
        [(LEDGER, "171fcc04b4a51c21b87c0ba348374bc64835314bf55a6f72ca5abf213f1c93fb",
          "171fcc04b4a51c21b87c0ba348374bc64835314bf55a6f72ca5abf213f1c93fa")]),
    Row("P2", "a re-pinned next-update is moved by one day",
        LIFECYCLE,
        [(LEDGER, "tcb-document\t2026-10-02T17:13:18Z\t2026-11-01T17:13:18Z",
          "tcb-document\t2026-10-02T17:13:18Z\t2026-11-02T17:13:18Z")]),
    Row("P3", "a re-pinned byte count is off by one",
        LIFECYCLE,
        [(LEDGER, "\t3355\td207cf20", "\t3354\td207cf20")]),
    Row("P4", "the refreshed clock is moved a day forward, still inside the window",
        LIFECYCLE,
        [(TDXCOLL, "  Now = 1_790_985_600'i64                 ## 2026-10-03T00:00:00Z; see",
          "  Now = 1_791_072_000'i64                 ## 2026-10-03T00:00:00Z; see"),
         (LIFECYCLE, 'source: "t_tdx_collateral_and_verifier_arm.nim", now: 1_790_985_600\'i64',
          'source: "t_tdx_collateral_and_verifier_arm.nim", now: 1_791_072_000\'i64')]),
    Row("P5", "the refreshed clock is left at the instant the previous vintage implied",
        LIFECYCLE,
        [(TDXCHAIN, "  Now = 1_790_985_600'i64\n", "  Now = 1_790_035_200'i64\n"),
         (LIFECYCLE, 'source: "t_tdx_chain_requires_intel_root.nim", now: 1_790_985_600\'i64',
          'source: "t_tdx_chain_requires_intel_root.nim", now: 1_790_035_200\'i64')]),
    Row("P6", "the boundary past the list's expiry is pulled back inside it",
        TDXCHAIN,
        [(TDXCHAIN, "  AfterTheListExpires = 1_794_000_000'i64",
          "  AfterTheListExpires = 1_793_000_000'i64")]),
    Row("P7", "a re-pinned issue date is reverted to the previous vintage",
        TDXCOLL,
        [(TDXCOLL, '(PcsTcbInfoEmrJson, "90c06f000000", 3, 4, 2, "2026-10-02T17:16:39Z")',
          '(PcsTcbInfoEmrJson, "90c06f000000", 3, 4, 2, "2026-09-21T03:25:24Z")')]),
    Row("P8", "one byte of a re-pinned document's signature is changed",
        TDXCOLL,
        [(TDXVEC, '"signature":"b8834e568f8e663c0172692974e66abeace2581c1dedf082c4d971e54650fb8e04362e482d7d209c0b092e10d734b84a645100f26602ba63084f03a9a22bfa1b"',
          '"signature":"b8834e568f8e663c0172692974e66abeace2581c1dedf082c4d971e54650fb8e04362e482d7d209c0b092e10d734b84a645100f26602ba63084f03a9a22bfa1a"')]),
    Row("P9", "the re-minted no-next-update negative is left at the previous vintage",
        LIFECYCLE,
        [(TDXVEC,
          '      "0613025553170d3236313030323137323631325a30820be9303302146fc34e5023"',
          '      "0613025553170d3236303932313034303230335a30820be9303302146fc34e5023"')]),
    Row("P10", "the reference instant is left at the midnight that OPENS the observation day",
        LIFECYCLE,
        [(LEDGERMOD, "  LedgerReferenceInstant* = 1_790_985_600'i64",
          "  LedgerReferenceInstant* = 1_790_899_200'i64")]),
    Row("P11", "the thirty-day life of the vendor's documents is stated as thirty-one",
        LIFECYCLE,
        [(LIFECYCLE, "      check w.notAfter - w.notBefore == 30 * Day",
          "      check w.notAfter - w.notBefore == 31 * Day")]),
    Row("P12", "the evaluation-data number is allowed to go backwards",
        LIFECYCLE,
        [(LIFECYCLE, '      check b > a\n', '      check b >= a - 10\n'),
         (LIFECYCLE,
          'for (older, newer) in [("GtgTcbInfoSprJson", "PcsTcbInfoSprJson"),',
          'for (older, newer) in [("PcsTcbInfoSprJson", "GtgTcbInfoSprJson"),')]),
    Row("P13", "the new refresh route is dropped",
        LIFECYCLE,
        [(FETCH, "\nIntelRootCrlDerHex\thttps://certificates.trustedservices.intel.com/IntelSGXRootCA.der\tnone",
          "")]),

    # ---- Part 2: the mechanical tie, and each of its costs -----------
    Row("Q1", "a gate references an artifact its row does not name",
        LIFECYCLE,
        [(SNPTCB, "let milanChain = pemCertificates(KdsMilanChainPem)",
          "proc zzMutationTouch(): int =\n  bytesOfHex(KdsGenoaCrlDerHex).len\n\nlet milanChain = pemCertificates(KdsMilanChainPem)")]),
    Row("Q2", "a gate's row names an artifact the gate does not reference",
        LIFECYCLE,
        [(LIFECYCLE,
          '      mustBeCurrent: @["GsgMilanVcekDerHex", "KdsMilanCrlDerHex",\n'
          '                       "VirteeMilanVcekDerHex"],\n'
          '      notRequiredCurrent: @[]),\n'
          '    PinnedClockGate(\n'
          '      source: "t_snp_chain_requires_amd_root.nim"',
          '      mustBeCurrent: @["GsgMilanVcekDerHex", "KdsGenoaCrlDerHex",\n'
          '                       "KdsMilanCrlDerHex", "VirteeMilanVcekDerHex"],\n'
          '      notRequiredCurrent: @[]),\n'
          '    PinnedClockGate(\n'
          '      source: "t_snp_chain_requires_amd_root.nim"')]),
    Row("Q3", "a reissued document is excused instead of refreshed",
        LIFECYCLE,
        [(LIFECYCLE,
          '                       "PcsTcbInfoSprJson", "PcsTdxQeIdentityJson"],\n'
          '      notRequiredCurrent: @["GtgQeIdentityJson", "GtgTcbInfoEmrJson",',
          '                       "PcsTdxQeIdentityJson"],\n'
          '      notRequiredCurrent: @["PcsTcbInfoSprJson",\n'
          '                            "GtgQeIdentityJson", "GtgTcbInfoEmrJson",')]),
    Row("Q4", "an artifact is excused by one gate and required by another",
        LIFECYCLE,
        [(LIFECYCLE, '      notRequiredCurrent: @["ImpostorArkHex", "ImpostorAskHex",',
          '      notRequiredCurrent: @["KdsMilanCrlDerHex", "ImpostorArkHex", "ImpostorAskHex",')]),
    Row("Q5", "the scan stops stripping comments",
        LIFECYCLE,
        [(LIFECYCLE, "    elif text[i] == '#':", "    elif false:")]),
    Row("Q6", "the scan stops stripping string literals",
        LIFECYCLE,
        [(LIFECYCLE,
          "    elif text[i] == '\"':\n      if i + 2 < text.len and text[i + 1] == '\"' and text[i + 2] == '\"':",
          "    elif false:\n      if i + 2 < text.len and text[i + 1] == '\"' and text[i + 2] == '\"':")]),
    Row("Q7", "a numeric suffix is mistaken for a character literal",
        LIFECYCLE,
        [(LIFECYCLE,
          "    if text[i] == '\\'' and\n       (i == 0 or text[i - 1] notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}):",
          "    if text[i] == '\\'':")]),
    Row("P14", "the comment is reworded on the new clock rule (GREEN control)",
        LIFECYCLE,
        [(LEDGERMOD, "    ## It moves the instant LATER, which is the strict direction:",
          "    ## It moves the instant later, which is the strict direction:")],
        expect="GREEN"),
]


JOURNAL = SCRATCH.parent / "fixture-lifecycle-mutations.journal.tsv"
IN_FLIGHT = SCRATCH.parent / "fixture-lifecycle-mutations.in-flight"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(line: str) -> None:
    """Append one finished row, and flush. A table whose results exist only
    in a buffer is a table you re-run from the start every time the host
    reboots, and this one has been re-run from the start three times."""
    with JOURNAL.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())


def mark_in_flight(ident: str, paths: list[str]) -> None:
    """Name the row and the files it has edited, BEFORE editing them.

    The restore below runs in a `finally`, which a SIGKILL does not. So the
    honest protection is not a tidier `finally` -- it is a marker that
    survives the kill and tells the next run exactly which files to check.
    Removed only after the restore has been verified.
    """
    IN_FLIGHT.write_text(ident + "\n" + "\n".join(paths) + "\n",
                         encoding="utf-8")


def clear_in_flight() -> None:
    IN_FLIGHT.unlink(missing_ok=True)


def run_gate(gate: str, tag: str) -> tuple[str, str]:
    """Build and run one gate. Returns (state, detail)."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    stem = Path(gate).stem
    binary = SCRATCH / f"{stem}-{tag}"
    cmd = ["nim", "c", "--hints:off", "--warnings:off",
           *DEFINES.get(gate, []),
           f"--nimcache:{SCRATCH}/nc-{stem}", f"-o:{binary}", gate]
    built = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if built.returncode != 0:
        errs = [ln for ln in built.stdout.splitlines() if "Error:" in ln]
        return "COMPILE-REFUSED", (errs[-1] if errs else "build failed")
    ran = subprocess.run([str(binary)], cwd=REPO, capture_output=True,
                         text=True)
    ok = ran.stdout.count("[OK]")
    failed = ran.stdout.count("[FAILED]")
    names = [ln.strip()[len("[FAILED] "):]
             for ln in ran.stdout.splitlines() if ln.strip().startswith("[FAILED]")]
    state = "GREEN" if ran.returncode == 0 and failed == 0 else "RED"
    return state, f"{ok} OK / {failed} FAILED" + (
        " -- " + "; ".join(names[:3]) if names else "")


def verify_rows() -> int:
    """Every row must still be able to NAME ITS SITE in the tree as it
    stands: its search string present, exactly once, in the file it
    edits.

    This is the check that notices this driver's own residue, and it was
    added because that residue shipped. A row is applied by substring
    replacement and reverted in a `finally`; when the revert does not
    happen -- a kill, an interrupted run, a hand edit layered on top --
    the tree keeps the REPLACEMENT and the row can no longer find its
    search string. Measured on 2026-10-03: `P12` shipped with its own
    replacement in the tree, so the comparison that proves a reissued
    vendor document is not an older one replayed had been relaxed from
    `b > a` to one that admits a rollback of ten.

    Nothing else sees this. The gate still compiles, every case count is
    unchanged, and the weakened check still passes -- the final
    verification build of that tree reported 62 OK / 0 FAILED, which is
    exactly what the correct tree reports. A mutation JOURNAL does not
    see it either: a journal attests to the tree at the moment each row
    ran, not to the tree that is shipped, and the gap between the last
    row and the commit is unaudited. That gap is where residue lives.

    So this asks the one question a case count cannot: not "does the
    suite pass" but "can each row still find the thing it claims to
    defeat". It is a source scan -- no compiler, no gate run, answers in
    well under a second -- which is why it belongs in `just lint`
    beside the other scan-shaped gates rather than in the suite.
    """
    bad: list[str] = []
    for row in ROWS:
        for path, find, repl in row.edits:
            p = REPO / path
            if not p.exists():
                bad.append(f"{row.ident}: {path}: file does not exist")
                continue
            text = p.read_text()
            n = text.count(find)
            if n == 1:
                continue
            note = (f"{row.ident}: {path}: search string occurs {n} "
                    "times, expected exactly 1")
            # The diagnosis, not just the symptom. If the row's own
            # REPLACEMENT is what the tree holds, this is not a stale
            # row -- it is this driver's unreverted edit, and the fix is
            # to restore the source rather than to re-word the row.
            if repl and text.count(repl) >= 1:
                note += ("; the row's REPLACEMENT is present instead -- "
                         "this looks like an unreverted mutation, so "
                         "restore the source rather than editing the row")
            bad.append(note)
    for line in bad:
        print(line, file=sys.stderr)
    print(f"attestation mutation rows: {len(ROWS)} checked, "
          f"{len(bad)} unable to name their site")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    if "--list" in argv:
        for row in ROWS:
            print(f"{row.ident:5} {row.expect:16} {row.what}")
        return 0
    if "--verify-rows" in argv:
        return verify_rows()
    if IN_FLIGHT.exists():
        print(f"a previous run died inside {IN_FLIGHT.read_text().splitlines()[0]} "
              f"with these files edited:\n{IN_FLIGHT.read_text()}"
              f"Check them against git, then delete {IN_FLIGHT}.",
              file=sys.stderr)
        return 2
    wanted = [a for a in argv if not a.startswith("-")]
    rows = [r for r in ROWS if not wanted or r.ident in wanted]
    print(f"{'row':5} {'expected':16} {'observed':16} detail")
    failures = 0
    for row in rows:
        originals: dict[str, bytes] = {}
        before: dict[str, str] = {}
        created: list[Path] = []
        state, detail = "INCONCLUSIVE", ""
        try:
            mark_in_flight(row.ident,
                           [p for p, _, _ in row.edits] +
                           [p for p, _ in row.adds])
            for path, find, repl in row.edits:
                p = REPO / path
                # Snapshot a file ONCE, on first touch, and never again.
                #
                # This `if` is the whole of a defect that shipped. These
                # two lines used to run per EDIT, so a row with two
                # edits to the SAME file overwrote the pristine snapshot
                # with the content edit 1 had already produced. The
                # restore below then wrote that back, leaving edit 1
                # applied for ever -- and `before[path]` was overwritten
                # the same way, so the "did not restore" check compared
                # against the post-edit-1 digest and reported success.
                # Silent in every channel: no marker, no failure, and a
                # journal line saying RED.
                #
                # Exactly one row has two edits to one file (`P12`), and
                # exactly that row's first edit is what reached a
                # delivered tree, relaxing `check b > a` to
                # `check b >= a - 10`. Rows editing two DIFFERENT files
                # were never affected, which is why this survived so
                # long.
                if path not in originals:
                    originals[path] = p.read_bytes()
                    before[path] = digest(p)
                text = p.read_text()
                if text.count(find) != 1:
                    raise RuntimeError(
                        f"{path}: the substring occurs {text.count(find)} "
                        "times; a mutation must name exactly one site")
                p.write_text(text.replace(find, repl, 1))
            for path, content in row.adds:
                p = REPO / path
                if p.exists():
                    raise RuntimeError(f"{path} already exists")
                p.write_text(content)
                created.append(p)
            state, detail = run_gate(row.gate, row.ident)
        except RuntimeError as err:
            # The row could not be applied at all. Reported as its own
            # state rather than as a red gate: "the mutation did not
            # land" and "the mutation landed and the gate caught it"
            # are different answers.
            state, detail = "INCONCLUSIVE", str(err)
        finally:
            for path, raw in originals.items():
                (REPO / path).write_bytes(raw)
            for p in created:
                p.unlink(missing_ok=True)
        restored = True
        for path, was in before.items():
            now = digest(REPO / path)
            if now != was:
                print(f"  !! {path} did not restore: {was} -> {now}", flush=True)
                failures += 1
                restored = False
        if restored:
            clear_in_flight()
        mark = "" if state == row.expect else "   <== NOT AS FILED"
        if state != row.expect:
            failures += 1
        line = f"{row.ident:5} {row.expect:16} {state:16} {detail}{mark}"
        print(line, flush=True)
        record(f"{row.ident}\t{row.expect}\t{state}\t{detail}")
    shutil.rmtree(SCRATCH, ignore_errors=True)
    print(f"{len(rows)} row(s), {failures} not as filed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
