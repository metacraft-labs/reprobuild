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
          "873efcf8c8cedc28c603cf50acdff8556a704658357a0d9daab297f483deb0df",
          "873efcf8c8cedc28c603cf50acdff8556a704658357a0d9daab297f483deb0de")]),
    Row("L2", "a recorded not_after is moved by one day",
        LIFECYCLE,
        [(LEDGER, "amd-revocation-list\t2026-08-19T14:19:23Z\t2026-10-04T00:00:00Z",
          "amd-revocation-list\t2026-08-19T14:19:23Z\t2026-10-05T00:00:00Z")]),
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
        [(SNPGATE, "  Now = 1_788_220_800'i64", "  Now = 1_795_000_000'i64"),
         (LIFECYCLE, 'source: "t_snp_fixture_verify.nim", now: 1_788_220_800\'i64',
          'source: "t_snp_fixture_verify.nim", now: 1_795_000_000\'i64')]),
    Row("L13", "a sixth gate pins a clock and no row names it",
        LIFECYCLE, [],
        [("tests/integration/t_zz_mutation_clock.nim",
          "const\n  Now = 1_788_220_800'i64\n\nwhen isMainModule: discard Now\n")]),
    Row("L14", "a gate's pinned clock is transcribed wrongly into the table",
        LIFECYCLE,
        [(LIFECYCLE, 'source: "t_snp_tcb_policy.nim", now: 1_788_220_800\'i64',
          'source: "t_snp_tcb_policy.nim", now: 1_788_220_801\'i64')]),
    Row("L15", "a gate's list of what it judges is emptied",
        LIFECYCLE,
        [(LIFECYCLE,
          'mustBeCurrent: @["KdsMilanCrlDerHex", "VirteeMilanVcekDerHex"]',
          'mustBeCurrent: @[]')]),
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
          "  of lcProtocolVector, lcTrustRoot, lcVendorCollateral:\n    if pinnedSha256 == observedSha256: doUnchanged else: doDrifted",
          "  of lcProtocolVector, lcVendorCollateral:\n    if pinnedSha256 == observedSha256: doUnchanged else: doDrifted\n  of lcTrustRoot:\n    if pinnedSha256 == observedSha256: doUnchanged else: doExpectedToDiffer")]),
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
          "ImpostorArkHex\tsnp_vectors.nim\tminted-negative\tthis-repository\t2026-09-29")]),
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


def main(argv: list[str]) -> int:
    if "--list" in argv:
        for row in ROWS:
            print(f"{row.ident:5} {row.expect:16} {row.what}")
        return 0
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
