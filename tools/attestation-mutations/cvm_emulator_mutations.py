#!/usr/bin/env python3
"""Apply each filed mutation to the confidential-computing emulator
work, rebuild the gate it targets, RUN it, and restore the tree byte
for byte.

A check whose defeating mutation has not been executed is not yet known
to be a check. Every row names one file, one exact substring, and the
replacement that should defeat the rule — and the row is only worth
anything if the gate goes RED and every file it touched comes back
sha256-identical afterwards.

The sibling driver `fixture_lifecycle_mutations.py` paid for two
mechanisms this one inherits deliberately rather than reinventing: the
per-file snapshot taken ONCE on first touch (a row with two edits to one
file used to overwrite its own pristine copy and leave the first edit
applied for ever, while reporting success), and `--verify-rows`, which
asks whether every row can still NAME ITS SITE in the tree as it stands
— the one question that notices this driver's own unreverted residue.

Usage:
  python3 tools/attestation-mutations/cvm_emulator_mutations.py           # all
  python3 tools/attestation-mutations/cvm_emulator_mutations.py P3 R7     # some
  python3 tools/attestation-mutations/cvm_emulator_mutations.py --list
  python3 tools/attestation-mutations/cvm_emulator_mutations.py --verify-rows

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
SCRATCH = Path(os.environ.get("CVM_MUTATION_SCRATCH", tempfile.gettempdir())) / "cvm-emulator-mutations"
JOURNAL = SCRATCH.parent / "cvm-emulator-mutations.journal.tsv"
IN_FLIGHT = SCRATCH.parent / "cvm-emulator-mutations.in-flight"

PATHS = "tests/integration/t_cvm_evidence_emulator_all_protocol_paths.nim"
REFUSE = "tests/integration/t_genuine_tier_policy_refuses_emulated_cvm_evidence.nim"
UKI = "tests/integration/t_reproos_uki_through_the_cvm_path.nim"

EMULATOR = "tests/integration/cvm_evidence_emulator.nim"
SCENARIOS = "tests/integration/cvm_emulator_scenarios.nim"
UKIMOD = "tests/integration/reproos_shaped_uki.nim"
CORPUS = "tests/integration/snp_digest_corpus.nim"

SNPCHAIN = "libs/repro_attest_verify/src/repro_attest_verify/snp_chain.nim"
TDXCHAIN = "libs/repro_attest_verify/src/repro_attest_verify/tdx_chain.nim"
EVIDENCE = "libs/repro_attest_verify/src/repro_attest_verify/evidence.nim"
VERIFY = "libs/repro_attest_verify/src/repro_attest_verify/verify.nim"
POLICY = "libs/repro_attest_verify/src/repro_attest_verify/policy.nim"
TDXLAUNCH = "libs/repro_attest/src/repro_attest/tdx_launch.nim"
MEASUREMENT = "libs/repro_attest/src/repro_attest/measurement.nim"
CLIATTEST = "libs/repro_cli_support/src/repro_cli_support/attest.nim"

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
    # ---- the fixture set is constrained by its own gate --------------
    Row("P1", "a fault's published spelling is renamed",
        PATHS,
        [(SCENARIOS, '"measurement", "signature", "nonce", "tcb", "chain", "policy",',
          '"measurement", "signature", "nonces", "tcb", "chain", "policy",')]),
    Row("P2", "a fault is moved to the other injection site",
        PATHS,
        [(EMULATOR, "  of cemTime: cfsVerification",
          "  of cemTime: cfsEvidence")]),

    # ---- the premise: neither measurement originates here ------------
    Row("P3", "the launch shape is built without its command line",
        PATHS,
        [(CORPUS, "  result.cmdline = v.cmdline",
          "  result.cmdline = \"\"")]),
    Row("P4", "the trust domain's fold order is the other one",
        PATHS,
        [(PATHS, "  tdxGenuine.order)", "  thoExtendAfterEachPage)")]),
    Row("P5", "the register fold hashes its two halves the other way round",
        PATHS,
        [(TDXLAUNCH,
          "  for i in 0 ..< TdxMeasurementBytes: buf[i] = current[i]\n"
          "  for i in 0 ..< TdxMeasurementBytes:\n"
          "    buf[TdxMeasurementBytes + i] = value[i]",
          "  for i in 0 ..< TdxMeasurementBytes: buf[i] = value[i]\n"
          "  for i in 0 ..< TdxMeasurementBytes:\n"
          "    buf[TdxMeasurementBytes + i] = current[i]")]),
    Row("P6", "the register fold stops after the first event",
        PATHS,
        [(TDXLAUNCH, "  for i, e in events:\n    if e.register < 0",
          "  for i, e in events[0 .. 0]:\n    if e.register < 0")]),

    # ---- the unmutated run, and the rows it is allowed to fail -------
    Row("P7", "the declared structural set gains a row",
        PATHS,
        [(SCENARIOS, "  of cbSnp: {vcCertificateChain}",
          "  of cbSnp: {vcCertificateChain, vcTcbFloor}")]),
    Row("P8", "the security-processor reader stops checking the signature",
        PATHS,
        [(EVIDENCE, "  if not verifyReportSignature(report, leaf.ecPoint):",
          "  if false:")]),
    Row("P9", "the trust-domain reader stops checking the quote signature",
        PATHS,
        [(EVIDENCE, "  if not verifyQuoteSignature(quote):",
          "  if false:")]),
    Row("P10", "the binding check reads the envelope instead of recomputing",
        PATHS,
        [(VERIFY,
          "    recomputed = reportDataHexFor(inputs.bindings, inputs.challengeHex)",
          "    recomputed = inputs.reportDataInEvidence.get")]),
    Row("P11", "the measurement check accepts any value",
        PATHS,
        [(VERIFY, "  if observed notin expected:", "  if false:")]),
    Row("P12", "the bundled-chain count rule is dropped",
        PATHS,
        [(VERIFY, "    if inputs.certificates.len != AmdChainElements:",
          "    if false:")]),
    Row("P13", "the chain fault withholds nothing",
        PATHS,
        [(EMULATOR, "    chain = @[d.hierarchy.vcekDer, d.hierarchy.arkDer]",
          "    chain = snpChain(d.hierarchy)")]),
    Row("P14", "a fault with no expression is declared caught",
        PATHS,
        [(SCENARIOS,
          "      CvmFaultDetection(caught: false, check: vcTcbFloor, adds: {})",
          "      CvmFaultDetection(caught: true, check: vcTcbFloor, adds: {})")]),
    Row("P15", "the platform-version fault stops moving any byte",
        PATHS,
        [(EMULATOR, "  of cemTcb: tcbMicrocode = 0",
          "  of cemTcb: discard")]),
    Row("P16", "two faults are told apart by the same string",
        PATHS,
        [(SCENARIOS, '  of cemChain: "and this report bundles 2"',
          '  of cemChain: "bundled chain"')]),
    Row("P17", "a rejected verdict leaves the command line with exit zero",
        PATHS,
        [(CLIATTEST, "  of vdRejected: aecRejected",
          "  of vdRejected: aecAccepted")]),
    Row("P18", "the emulated machine mints a new attestation key per driver",
        PATHS,
        [(EMULATOR,
          "  let evidence = composeTdxQuote(d.hierarchy.attestationKey,",
          "  let evidence = composeTdxQuote(newTestKey(),")]),

    # ---- the structural refusal --------------------------------------
    # Filed COMPILE-REFUSED after being measured, and the measurement is
    # the point: the gate's own `static:` block asserts the recognised
    # set's length and membership, so an edit to that constant is
    # refused by the COMPILER rather than by a failing case. That is
    # leg 2 working exactly as written — a value the compiler must
    # produce is a value nothing else can contribute to — and the
    # behavioural half is R14/R15 below, which defeat the same rule
    # without touching the constant.
    Row("R1", "the security processor's evaluator recognises the marker",
        REFUSE,
        [(SNPCHAIN, "  RecognisedAmdCriticalOids*: array[2, string] =\n"
                    "    [OidBasicConstraints, OidKeyUsage]",
          "  RecognisedAmdCriticalOids*: array[3, string] =\n"
          "    [OidBasicConstraints, OidKeyUsage, \"2.999.1.1\"]")],
        expect="COMPILE-REFUSED"),
    Row("R2", "the trust domain's evaluator recognises the marker",
        REFUSE,
        [(TDXCHAIN, "  RecognisedIntelCriticalOids*: array[2, string] =\n"
                    "    [OidBasicConstraints, OidKeyUsage]",
          "  RecognisedIntelCriticalOids*: array[3, string] =\n"
          "    [OidBasicConstraints, OidKeyUsage, \"2.999.1.1\"]")],
        expect="COMPILE-REFUSED"),
    Row("R3", "the security processor's root lookup matches anything",
        REFUSE,
        [(SNPCHAIN, "  for line in AmdProductLine:\n    let k = AmdRootKeys[line]",
          "  if true: return 0\n  for line in AmdProductLine:\n    let k = AmdRootKeys[line]")]),
    Row("R4", "the trust domain's root lookup matches anything",
        REFUSE,
        [(TDXCHAIN, "proc intelRootFor*(point: openArray[byte]): int =",
          "proc intelRootFor*(point: openArray[byte]): int =\n  if true: return 0")]),
    Row("R5", "the emulator's hierarchy is minted unmarked",
        REFUSE,
        [(EMULATOR, "  EmulatedCvmHierarchyIsMarked* = true",
          "  EmulatedCvmHierarchyIsMarked* = false")]),
    Row("R6", "the policy parser ignores a clause it does not define",
        REFUSE,
        [(POLICY, "    if r.doc.values.len > 0:", "    if false:")]),
    Row("R7", "the source scan is pointed at a path that does not exist",
        REFUSE,
        [(REFUSE,
          '"libs/repro_attest_verify/src/repro_attest_verify/snp_chain.nim",',
          '"libs/repro_attest_verify/src/repro_attest_verify/snp_chains.nim",')]),
    Row("R8", "a compile-time define appears in the root decision",
        REFUSE,
        [(SNPCHAIN, "proc isAccepted*(v: AmdChainVerdict): bool = v.reason == acAccepted",
          "when defined(reproAttestAnyRoot):\n  discard\n\n"
          "proc isAccepted*(v: AmdChainVerdict): bool = v.reason == acAccepted")]),
    Row("R9", "a second declaration of an evaluator appears elsewhere",
        REFUSE,
        [(EVIDENCE, "proc describeMockChain*(inputs: AuthoritativeInputs): CheckFinding =",
          "proc evaluateAmdChainUnused(): int = 0\n\n"
          "proc describeMockChain*(inputs: AuthoritativeInputs): CheckFinding =")]),
    Row("R10", "the positive control's clock is moved past its collateral",
        REFUSE,
        [(REFUSE, "  SnpInstant = 1_790_121_600'i64",
          "  SnpInstant = 1_800_000_000'i64")]),
    Row("R11", "the security processor's evaluator gains a sixth argument",
        REFUSE,
        [(SNPCHAIN,
          "proc evaluateAmdChain*(leafDer, intermediateDer, rootDer: seq[byte];\n"
          "                       crlDer: seq[seq[byte]];\n"
          "                       nowSeconds: int64): AmdChainVerdict =",
          "proc evaluateAmdChain*(leafDer, intermediateDer, rootDer: seq[byte];\n"
          "                       crlDer: seq[seq[byte]];\n"
          "                       nowSeconds: int64;\n"
          "                       alsoRecognise: seq[string] = @[]): AmdChainVerdict =")],
        expect="COMPILE-REFUSED"),
    Row("R12", "an environment variable reaches the critical-extension rule",
        REFUSE,
        [(SNPCHAIN, "import std/[strutils]", "import std/[os, strutils]"),
         (SNPCHAIN,
          "proc unrecognisedCriticalOid(cert: AmdCert): string =\n"
          "  for ext in cert.extensions:",
          "proc unrecognisedCriticalOid(cert: AmdCert): string =\n"
          "  if getEnv(\"REPRO_ATTEST_INSECURE\").len > 0: return \"\"\n"
          "  for ext in cert.extensions:")]),
    Row("R13", "the manifest publishes a measurement the evidence does not carry",
        REFUSE,
        [(SCENARIOS, "      measurement: m.snpMeasurementHex)]",
          "      measurement: \"ff\" & m.snpMeasurementHex[2 .. ^1])]")]),

    # ---- the image through the confidential-computing path -----------
    Row("U1", "the command-line section stops being measured",
        UKI,
        [(MEASUREMENT, '  UnmeasuredSections*: array[2, string] = [".pcrsig", ".pcrpkey"]',
          '  UnmeasuredSections*: array[2, string] = [".pcrsig", ".cmdline"]')]),
    Row("U2", "the kernel-digest page stops reaching the launch measurement",
        UKI,
        [("libs/repro_attest/src/repro_attest/snp_launch.nim",
          "    of oskKernelDigests:\n      if p.hasKernel:",
          "    of oskKernelDigests:\n      if false:")]),
    Row("U3", "the altered command line is the unaltered one",
        UKI,
        [(UKI, '  AlteredCmdline = "root=/dev/mapper/reproos ro quiE"',
          '  AlteredCmdline = "root=/dev/mapper/reproos ro quiet"')]),
    Row("U4", "the image's sections are folded into the firmware's register",
        UKI,
        [(UKIMOD, "  let index = TdxFirstLogRegisterIndex + TrustDomainUkiRegister",
          "  let index = TdxFirstLogRegisterIndex")]),
    Row("U5", "the log carries a constant digest instead of the section's",
        UKI,
        [(UKIMOD, '      sha384Hex("content:" & ev.dataDigest),',
          '      sha384Hex("content:"),')]),
    Row("U6", "the manifest publishes the wrong runtime register",
        UKI,
        [(SCENARIOS, "      rtmr1: m.tdxRtmrHex[1], rtmr2: m.tdxRtmrHex[2])]",
          "      rtmr1: m.tdxRtmrHex[1], rtmr2: m.tdxRtmrHex[1])]")]),
    Row("U7", "the verifier starts comparing a runtime register",
        UKI,
        [(VERIFY, "    for e in manifest.tdx: expected.add e.mrtd",
          "    for e in manifest.tdx: expected.add e.rtmr2")]),

    # ---- rows added after the first pass, each for a check or a fix
    # ---- the first pass left without one ----------------------------
    Row("P19", "the trust-domain chain fault shrinks the quote as well",
        PATHS,
        [(EMULATOR, "  for der in intelChain(d.hierarchy): pem.add cvmPemOf(der)",
          "  for der in chain: pem.add cvmPemOf(der)")]),
    Row("P20", "the emulated report names the other endorsement key kind",
        PATHS,
        [(EMULATOR, "  cvmPutLe(raw, OffKeyInfo, 0'u64, 4)",
          "  cvmPutLe(raw, OffKeyInfo, 4'u64, 4)")]),
    # P21 as first filed was NOT A MUTATION, and the green it produced
    # was correct and meaningless. It replaced the trust-domain chain
    # fault's two-element bundle `@[leaf, root]` with
    # `intelChain(...)[0 .. 1]` -- which is `@[leaf, authority]`, also
    # two elements. The count rule the fault exists to reach fires on
    # the COUNT, so the verifier decided exactly as before and all nine
    # cases passed. Measured rather than reasoned about, and recorded
    # rather than quietly re-worded: this is a shape this work has now
    # written down three times, and writing one is how you find out you
    # have.
    #
    # The replacement moves a value the gate reads and nothing else
    # does: the four runtime registers are written into the report body
    # in reverse order, so the quote remains well formed, the
    # initial-memory measurement is untouched and the measurement row
    # still passes -- and the case that compares each register against
    # the one the caller handed in is the only thing that moves.
    Row("P21", "the emulated quote writes its runtime registers in reverse",
        PATHS,
        [(EMULATOR,
          "    cvmPutBytes(body, OffRtMr + i * LenTeeMeasurement, f.rtmr[i])",
          "    cvmPutBytes(body, OffRtMr + i * LenTeeMeasurement,\n"
          "                f.rtmr[TdxRtMrCount - 1 - i])")]),
    Row("R14", "the security processor's critical-extension scan finds nothing",
        REFUSE,
        [(SNPCHAIN,
          "    if ext.critical and ext.oid notin RecognisedAmdCriticalOids:\n"
          "      return ext.oid",
          "    if false:\n      return ext.oid")]),
    Row("R15", "the trust domain's critical-extension scan finds nothing",
        REFUSE,
        [(TDXCHAIN,
          "    if ext.critical and ext.oid notin RecognisedIntelCriticalOids:\n"
          "      return ext.oid",
          "    if false:\n      return ext.oid")]),
    Row("U8", "the command-line case pins the manifest the machine reports",
        UKI,
        [(UKI, "    run.policyText = cvmPolicyText(cbSnp, cvmManifestDigest(cbSnp, honest))",
          "    run.policyText = cvmPolicyText(cbSnp, cvmManifestDigest(cbSnp, lying))")]),
    Row("U9", "the security-processor emulator reports a constant measurement",
        UKI,
        [(EMULATOR, "  var measurement = cvmRawOf(d.scenario.measurementHex)",
          "  var measurement = cvmRawOf(repeat(\"ab\", LenMeasurement))")]),
    Row("U10", "the initial-memory measurement is folded the other way",
        UKI,
        [(UKI,
          "let tdxMrtd = tdxMrtdHex(\n"
          "  toOpenArrayByte(tdxVector.firmware, 0, tdxVector.firmware.len - 1),\n"
          "  tdxVector.order)",
          "let tdxMrtd = tdxMrtdHex(\n"
          "  toOpenArrayByte(tdxVector.firmware, 0, tdxVector.firmware.len - 1),\n"
          "  thoExtendAfterTheRegion)")]),
    Row("C1", "the census loses the row this change added for a library module",
        "tests/integration/t_attestation_module_census.nim",
        [("tests/integration/attestation-module-census.tsv",
          "\nlibs/repro_attest/src/repro_attest/image_layout.nim\t",
          "\n#libs/repro_attest/src/repro_attest/image_layout.nim\t")]),
    Row("C2", "the census loses the row for one of this change's own gates",
        "tests/integration/t_attestation_module_census.nim",
        [("tests/integration/attestation-module-census.tsv",
          "\ntests/integration/cvm_evidence_emulator.nim\t",
          "\n#tests/integration/cvm_evidence_emulator.nim\t")]),
]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(line: str) -> None:
    JOURNAL.parent.mkdir(parents=True, exist_ok=True)
    with JOURNAL.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
        f.flush()
        os.fsync(f.fileno())


def mark_in_flight(ident: str, paths: list[str]) -> None:
    IN_FLIGHT.parent.mkdir(parents=True, exist_ok=True)
    IN_FLIGHT.write_text(ident + "\n" + "\n".join(paths) + "\n",
                         encoding="utf-8")


def clear_in_flight() -> None:
    IN_FLIGHT.unlink(missing_ok=True)


def run_gate(gate: str, tag: str) -> tuple[str, str]:
    SCRATCH.mkdir(parents=True, exist_ok=True)
    stem = Path(gate).stem
    binary = SCRATCH / f"{stem}-{tag}"
    cmd = ["nim", "c", "-d:release", "--hints:off", "--warnings:off",
           "--threads:on", *DEFINES.get(gate, []),
           f"--nimcache:{SCRATCH}/nc-{stem}", f"-o:{binary}", gate]
    # `errors="replace"` is not cosmetic. A gate that fails prints the
    # values it compared, and on this surface those are raw DER and raw
    # report bytes — so the gate's own stdout is not UTF-8, and a
    # decoder that raised took the whole run down in the middle of a
    # row. The `finally` below restored the tree, but the run stopped;
    # a driver that cannot read a RED gate's output cannot report the
    # one outcome it exists to report.
    built = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True,
                           errors="replace")
    if built.returncode != 0:
        errs = [ln for ln in built.stdout.splitlines() if "Error:" in ln]
        return "COMPILE-REFUSED", (errs[-1] if errs else "build failed")
    ran = subprocess.run([str(binary)], cwd=REPO, capture_output=True,
                         text=True, errors="replace")
    ok = ran.stdout.count("[OK]")
    failed = ran.stdout.count("[FAILED]")
    names = [ln.strip()[len("[FAILED] "):]
             for ln in ran.stdout.splitlines()
             if ln.strip().startswith("[FAILED]")]
    state = "GREEN" if ran.returncode == 0 and failed == 0 else "RED"
    return state, f"{ok} OK / {failed} FAILED" + (
        " -- " + "; ".join(names[:3]) if names else "")


def verify_rows() -> int:
    """Every row must still be able to NAME ITS SITE in the tree as it
    stands: its search string present, exactly once, in the file it
    edits. This is the check that notices this driver's own residue."""
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
            if repl and text.count(repl) >= 1:
                note += ("; the row's REPLACEMENT is present instead -- "
                         "this looks like an unreverted mutation, so "
                         "restore the source rather than editing the row")
            bad.append(note)
    for line in bad:
        print(line, file=sys.stderr)
    print(f"cvm emulator mutation rows: {len(ROWS)} checked, "
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
        print(f"a previous run died inside "
              f"{IN_FLIGHT.read_text().splitlines()[0]} with these files "
              f"edited:\n{IN_FLIGHT.read_text()}"
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
                # Snapshot a file ONCE, on first touch. Two edits to one
                # file used to overwrite the pristine copy with the
                # content the first edit produced, which left that edit
                # applied for ever while the driver reported success.
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
                print(f"  !! {path} did not restore: {was} -> {now}",
                      flush=True)
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
