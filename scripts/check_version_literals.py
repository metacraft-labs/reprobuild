#!/usr/bin/env python3
"""Refuse a NEW hand-written integer literal standing in for a format version.

WHY THIS EXISTS
===============

Every binary format in this tree is framed the same way: a four-byte magic,
then a ``u16`` version at offset 4, then a length, then the body. A test that
wants to exercise the version gate therefore pokes bytes 4 and 5 of an encoded
buffer, and the number it pokes is chosen relative to whatever the version
happened to be on the day the test was written.

That relationship is not recorded anywhere, so when the version moves the
number stays. Three distinct outcomes follow, and only one of them is loud:

*   The literal lands ON the new current version. The probe now asserts that
    the CURRENT version is refused, which is false, so it fails. Loud, and
    cheap to fix.
*   The literal lands INSIDE the accepted range. The probe decodes a payload
    it was written to see refused, the ``expect``/``try`` block never fires,
    and the case asserts nothing. Silent.
*   The literal was one of a hand-listed SET meaning "everything below
    current" -- ``for stale in [2, 3, 4, 5]``. After a bump the set no longer
    means that; the newly superseded version goes unprobed. Silent, and the
    case keeps printing ``[OK]``.

The third shape is the one this gate was written for. It existed in THREE
files at ee229299f, with the same four numbers and nearly the same prose in
each (``test_m10_observed_env_cache_key``,
``t_newest_alias_and_interned_records``, ``t_dark_window_cache_records_are_
drained``), and all three had already stopped covering version 6 when the
action-record trust epoch moved 6 -> 7. Nothing failed, no sweep reported it,
and the round that set out to fix exactly this class found three OTHER
instances and missed these three -- because its search keyed on
``expect EnvelopeError``, which is one of the four exception types the idiom
raises, rather than on the SHAPE.

So the gate keys on the shape. A literal in a version position is refused
unless it is annotated, and the annotation is what turns the surviving
population from "whatever happens to be there" into an enumerable list with a
written reason beside each entry.

WHAT IS REFUSED
===============

Three shapes, all of them in ``.nim`` sources:

A. ``<buf>[4] = <int literal>`` / ``<buf>[5] = <int literal>``, and the same
   through a named offset whose identifier ends in ``VersionOffset`` --
   writing a chosen number into the version word. A literal wrapped in a
   width cast (``byte(99)``, ``uint16(3)``) counts: that spelling got past
   the first version of this scanner, and the instance it missed was nine
   lines below one it caught.

B. ``for <v> in [<int literal>, <int literal>, ...]:`` where ``<v>`` is
   written into byte 4 or 5 inside the loop body -- the hand-listed version
   SET. The loop-body condition is what keeps this from flagging the 48
   ``for shift in [0, 8, 16, 24]:`` byte-assembly loops in the tree, which
   are not versions and must not need an annotation.

C. ``check``/``require``/``doAssert`` comparing an int literal against a
   value that was READ from byte 4 or 5 -- the deliberate version PIN.

D. The same assertion against a version ACCESSOR's return value --
   ``check devEnvEnvelopeVersion() == 4'u16`` -- which is the other spelling
   of the same pin and needs no visible byte read, because the accessor's
   name is the evidence.

Shape C is in the gate even though every one of its instances today is
correct and intended. A pin that is supposed to fail on a bump is not a
defect; what makes it worth annotating is that a pin and a probe are
indistinguishable from the bytes alone, and the round that confused them is
the round this gate exists because of. With the annotation, ``grep`` over the
tree answers "which assertions are supposed to redden when this version
moves" -- which is the question a bump needs answered, and which nothing
answered before.

HOW TO SATISFY IT
=================

Derive the number, which is almost always possible and is the right answer::

    let unknown = firstUnknownServicePayloadVersion()
    v3[4] = byte(unknown and 0xff'u16)
    v3[5] = byte((unknown shr 8) and 0xff'u16)

Where the number genuinely is not relative to the current version -- a
historical version that will never move, the structural floor of zero, or a
pin that must fail loudly by design -- annotate it, on the line or on the
line directly above::

    # version-literal-ok: v1 is a frozen historical format; a v1 body must
    # keep decoding whatever the current version becomes.
    v1[4] = 1'u8

The reason is mandatory and must be at least 20 characters. An annotation
with no reason is refused the same as no annotation: the point of the
mechanism is the sentence, not the token.

WHAT THIS GATE DOES **NOT** CATCH, stated so nobody reads it as total
=====================================================================

*   A version literal written through a helper this scanner cannot follow --
    ``patchVersion(buf, 3)`` -- because the offset is not visible at the call
    site. No instance of that shape exists in the tree today; it is the way
    the class would come back.
*   A version literal at an offset other than 4 or 5 and not reached through
    a ``*VersionOffset`` name. Every envelope in this tree puts the version
    at 4; a format that did not would be invisible here.
*   A literal compared against a version through a local alias the scanner
    does not connect to a byte read (shape C needs the read and the compare
    within the same ``proc``/``test`` body and within 40 lines).
*   Anything outside ``.nim`` sources.

This is a source scan: no compiler, no build, seconds. It is a lint gate for
the same reason its neighbours are -- it can answer before anything is built.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile

ANNOTATION = "version-literal-ok:"
MIN_REASON_CHARS = 20

SKIP_DIRS = {".git", "nimcache", "build", ".direnv", "vendor", "test-logs",
             ".repro", "result"}

INT_LIT = r"(?:0x[0-9A-Fa-f_]+|\d[\d_]*)(?:'[iuf]\d{1,2}|'u|'i)?"

# A literal is still a literal inside a width cast. `future[4] = byte(99)`
# is the shape that got past the FIRST version of this scanner -- it was in
# the tree at ee229299f, nine lines below a hand-listed version set the
# scanner DID catch, and it was found by reading rather than by the gate.
# A hole you have already fallen into is not a theoretical hole.
CAST_INT_LIT = (r"(?:(?:byte|uint8|uint16|uint32|int|int8|int16|int32)\s*\(\s*)?"
                + INT_LIT + r"(?:\s*\))?")

# Shape A -- a literal into the version word.
RE_A = re.compile(
    r"^\s*(?P<buf>[A-Za-z_]\w*)\s*\[\s*"
    r"(?P<idx>4|5|[A-Za-z_]\w*[Vv]ersionOffset)\s*\]\s*=\s*"
    r"(?P<val>" + CAST_INT_LIT + r")\s*(?:#.*)?$")

# Shape B -- a `for` over a bracket list of integer literals.
RE_B = re.compile(
    r"^(?P<indent>\s*)for\s+(?P<var>[A-Za-z_]\w*)\s+in\s*\[\s*"
    r"(?P<items>" + INT_LIT + r"(?:\s*,\s*" + INT_LIT + r")+)\s*,?\s*\]\s*:")

# Shape B's confirmation -- the loop variable reaching the version word.
RE_B_USE = re.compile(
    r"\[\s*(?:4|5|[A-Za-z_]\w*[Vv]ersionOffset)\s*\]\s*=\s*[^=].*\b(?P<var>\w+)\b")

# Shape C -- an assertion comparing something to an int literal.
RE_C = re.compile(
    r"^\s*(?:check|require|doAssert|assert)\s+"
    r"(?P<lhs>[A-Za-z_]\w*)\s*(?:==|!=)\s*(?P<val>" + INT_LIT + r")\s*(?:#.*)?$")

# Shape C's confirmation -- the compared name was read from the version word.
RE_C_READ = re.compile(
    r"\b(?P<name>[A-Za-z_]\w*)\s*=\s*[^=].*\[\s*(?:4|5|[A-Za-z_]\w*[Vv]ersionOffset)\s*\]")

# Shape D -- an assertion pinning a version ACCESSOR to a literal. Shape C
# needs a visible byte read; this one needs none, because the accessor's name
# is itself the evidence.
RE_D = re.compile(
    r"^\s*(?:check|require|doAssert|assert)\s+"
    r"(?P<call>[A-Za-z_]\w*[Vv]ersion\w*)\s*\(\s*\)\s*(?:==|!=)\s*"
    r"(?P<val>" + INT_LIT + r")\s*(?:#.*)?$")

C_LOOKBACK = 40


def annotated(lines: list[str], idx: int) -> tuple[bool, str]:
    """Is line `idx` (0-based) covered by an annotation with a real reason?

    The annotation may sit on the flagged line itself as a trailing comment,
    or anywhere in the CONTIGUOUS comment block directly above it. Contiguous
    is the whole rule: the walk stops at the first line that is neither blank
    nor a comment, so an annotation that belongs to some earlier statement
    cannot drift down and silently exempt this one. A comment block is how
    these reasons are actually written -- they run four or five lines -- and a
    fixed two-line lookback refused every one of them.
    """
    probes = [idx]
    j = idx - 1
    while j >= 0:
        stripped = lines[j].strip()
        if stripped.startswith("#"):
            probes.append(j)
            j -= 1
            continue
        if stripped == "":
            # A blank line ends the block: a comment above a blank line is
            # not attached to this statement.
            break
        break
    found_without_reason = False
    for probe in probes:
        if ANNOTATION not in lines[probe]:
            continue
        # The reason is the tail of the annotation line plus every comment
        # line below it, up to and including the flagged line, so a wrapped
        # reason counts as one sentence.
        reason = [lines[probe].split(ANNOTATION, 1)[1].strip()]
        k = probe + 1
        while k < len(lines) and k <= idx and lines[k].strip().startswith("#"):
            reason.append(lines[k].strip().lstrip("#").strip())
            k += 1
        text = " ".join(x for x in reason if x).strip()
        if len(text) < MIN_REASON_CHARS:
            found_without_reason = True
            continue
        return True, ""
    if found_without_reason:
        return False, ("annotation carries no usable reason "
                       f"({MIN_REASON_CHARS} characters required)")
    return False, "no `# version-literal-ok: <reason>` annotation"


def scan_text(rel: str, text: str) -> list[tuple[str, int, str, str, str]]:
    """Return (path, lineno, shape, line, why) for each refusal."""
    lines = text.split("\n")
    out: list[tuple[str, int, str, str, str]] = []

    for i, ln in enumerate(lines):
        stripped = ln.strip()
        if stripped.startswith("#"):
            continue

        m = RE_A.match(ln)
        if m:
            # A `u16` version is TWO byte writes to the same buffer, which is
            # one logical act and takes one annotation. Anchor the annotation
            # search at the first line of a contiguous run of version-word
            # writes to the SAME buffer, so `v1[4] = 1'u8` / `v1[5] = 0'u8`
            # need not each carry the reason. A write to a DIFFERENT buffer
            # starts a new run and needs its own.
            anchor = i
            k = i - 1
            while k >= 0:
                prev = lines[k]
                if prev.strip() == "":
                    k -= 1
                    continue
                pm = RE_A.match(prev)
                if pm and pm.group("buf") == m.group("buf"):
                    anchor = k
                    k -= 1
                    continue
                break
            ok, why = annotated(lines, anchor)
            if not ok:
                out.append((rel, i + 1, "A", stripped, why))
            continue

        m = RE_B.match(ln)
        if m:
            var = m.group("var")
            indent = len(m.group("indent"))
            # Walk the loop body: lines more indented than the `for`.
            reaches = False
            for j in range(i + 1, len(lines)):
                cur = lines[j]
                if cur.strip() == "":
                    continue
                if len(cur) - len(cur.lstrip()) <= indent:
                    break
                use = RE_B_USE.search(cur)
                if use and re.search(r"\b" + re.escape(var) + r"\b", cur):
                    reaches = True
                    break
            if reaches:
                ok, why = annotated(lines, i)
                if not ok:
                    out.append((rel, i + 1, "B", stripped, why))
            continue

        m = RE_C.match(ln)
        if m:
            name = m.group("lhs")
            reads = False
            for j in range(max(0, i - C_LOOKBACK), i):
                r = RE_C_READ.search(lines[j])
                if r and r.group("name") == name:
                    reads = True
                    break
            if reads:
                ok, why = annotated(lines, i)
                if not ok:
                    out.append((rel, i + 1, "C", stripped, why))
            continue

        m = RE_D.match(ln)
        if m:
            ok, why = annotated(lines, i)
            if not ok:
                out.append((rel, i + 1, "D", stripped, why))
            continue

    return out


def scan_tree(root: str) -> tuple[list, int]:
    findings = []
    nfiles = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            if not fn.endswith(".nim"):
                continue
            fp = os.path.join(dirpath, fn)
            rel = os.path.relpath(fp, root)
            nfiles += 1
            try:
                text = open(fp, encoding="utf-8", errors="replace").read()
            except OSError as exc:
                print(f"check_version_literals: cannot read {rel}: {exc}",
                      file=sys.stderr)
                continue
            findings.extend(scan_text(rel, text))
    return findings, nfiles


# --------------------------------------------------------------------------
# The positive control.
#
# Every exemption this scanner grants is a licence to ignore a real defect, so
# each is probed with a complete, genuine instance, and each shape is probed
# with an instance that MUST be caught. A gate that reports zero because its
# regexes stopped matching anything is the failure mode the rest of this
# repository's lints learned to guard against; this is that guard.
# --------------------------------------------------------------------------
SELF_TEST_CASES: list[tuple[str, str, bool, str]] = [
    ("A-bare", """
proc f() =
  var buf = enc()
  buf[4] = 3'u8
""", True, "shape A with no annotation must be refused"),
    ("A-hex", """
proc f() =
  var env = enc()
  env[4] = 0x07'u8  # version becomes 7
""", True, "shape A written in hex, with a trailing comment, must be refused"),
    ("A-cast-literal", """
proc f() =
  var future = encoded
  future[4] = byte(99)
""", True, "a literal inside a width cast must be refused too"),
    ("A-cast-literal-u16", """
proc f() =
  var w = enc()
  w[5] = uint16(3)
""", True, "the same through a uint16 cast"),
    ("A-cast-of-a-derived-value", """
proc f() =
  var future = encoded
  future[4] = byte(firstUnknownActionRecordVersion() and 0xff'u16)
""", False, "a cast of a DERIVED value is not a literal"),
    ("A-offset-name", """
proc f() =
  var w = enc()
  w[ManifestVersionOffset] = 99
""", True, "shape A through a *VersionOffset name must be refused"),
    ("A-annotated", """
proc f() =
  var v1 = enc()
  # version-literal-ok: v1 is a frozen historical format and must keep
  # decoding whatever the current version becomes.
  v1[4] = 1'u8
""", False, "shape A with a real reason must be allowed"),
    ("A-annotation-without-reason", """
proc f() =
  var v1 = enc()
  # version-literal-ok: tbd
  v1[4] = 1'u8
""", True, "an annotation with no usable reason must NOT exempt"),
    ("A-annotated-multiline-block", """
proc f() =
  var v1 = enc()
  # version-literal-ok: 1 is a FROZEN HISTORICAL version, not an offset
  # from the current one. The property is "a v1 body still decodes",
  # and it must keep saying v1 whatever the current version becomes.
  v1[4] = 1'u8
  v1[5] = 0'u8
""", False, "an annotation at the top of a contiguous comment block counts"),
    ("A-same-buffer-run-needs-one-annotation", """
proc f() =
  var v1 = enc()
  # version-literal-ok: one annotation covers the whole u16 write, which
  # is two byte stores to the same buffer and one logical act.
  v1[4] = 1'u8
  v1[5] = 0'u8
""", False, "a u16 version write takes one annotation, not two"),
    ("A-run-of-different-buffers-needs-its-own", """
proc f() =
  # version-literal-ok: this reason covers the first buffer's version
  # word and says nothing about any other buffer.
  a[4] = 1'u8
  a[5] = 0'u8
  b[4] = 3'u8
""", True, "a write to a DIFFERENT buffer starts a new run and is refused"),
    # The fixture is a BLANK LINE AND NOTHING ELSE between the reason and
    # the poke. An earlier version of this case also had a statement in
    # between, which meant the `annotated` walk stopped on the STATEMENT
    # and the case passed with the blank-line rule deleted -- a control
    # named for a rule it did not discriminate, which is the same defect
    # shape this whole gate exists for. Measured: with the blank-line
    # `break` removed, this fixture reports 0 hits; with it, 1.
    ("A-annotation-does-not-drift-past-a-blank-line", """
proc f() =
  # version-literal-ok: this reason is separated from the poke below by a
  # blank line, so it belongs to no statement and must exempt nothing.

  other[4] = 3'u8
""", True, "a blank line ALONE ends the block, so the poke below it is refused"),
    ("A-annotation-does-not-drift-past-a-statement", """
proc f() =
  # version-literal-ok: this reason belongs to the statement right below
  # it and to nothing further down the body.
  w[4] = 1'u8
  other[4] = 3'u8
""", True, "a statement ends the block, so the second poke is refused"),
    ("A-derived", """
proc f() =
  var v3 = enc()
  let future = firstUnknownServicePayloadVersion()
  v3[4] = byte(future and 0xff'u16)
""", False, "a derived value is not a literal and must not be reported"),
    ("B-version-set", """
proc f() =
  for stale in [2'u16, 3'u16, 4'u16, 5'u16]:
    var patched = encoded
    patched[4] = byte(stale and 0xff'u16)
    patched[5] = byte((stale shr 8) and 0xff'u16)
""", True, "the hand-listed version SET must be refused"),
    ("B-shift-loop", """
proc f() =
  for shift in [0, 8, 16, 24]:
    result.add(byte((value shr shift) and 0xff))
""", False, "a byte-assembly shift loop is not a version set"),
    ("B-shift-loop-with-index", """
proc f() =
  for shift in [0, 8, 16, 24]:
    out[4] = byte(other shr 3)
""", False,
     "a loop that writes byte 4 WITHOUT using the loop variable there is "
     "not a version set"),
    ("B-derived", """
proc f() =
  for stale in actionRecordVersionsThisBuildRefuses():
    var patched = encoded
    patched[4] = byte(stale and 0xff'u16)
""", False, "a derived set must not be reported"),
    ("C-pin", """
proc f() =
  let version = uint16(encoded[4]) or (uint16(encoded[5]) shl 8)
  check version == 6'u16
""", True, "an unannotated version pin must be refused"),
    ("C-pin-annotated", """
proc f() =
  let version = uint16(encoded[4]) or (uint16(encoded[5]) shl 8)
  # version-literal-ok: a deliberate PIN -- a bump is meant to redden this
  # line by name so somebody confirms the epoch moved on purpose.
  check version == 6'u16
""", False, "an annotated pin must be allowed"),
    ("D-accessor-pin", """
proc f() =
  check devEnvEnvelopeVersion() == 4'u16
""", True, "an unannotated accessor pin must be refused"),
    ("D-accessor-pin-annotated", """
proc f() =
  # version-literal-ok: a deliberate PIN on the written envelope version;
  # a bump must redden this line so the move is confirmed on purpose.
  check devEnvEnvelopeVersion() == 4'u16
""", False, "an annotated accessor pin must be allowed"),
    ("D-non-version-accessor", """
proc f() =
  check decoded.inputs.len() == 2
""", False, "a call whose name is not version-ish is not reported"),
    ("C-unrelated-compare", """
proc f() =
  let count = decoded.inputs.len
  check count == 2
""", False, "a comparison not derived from the version word is not reported"),
    ("comment-only", """
# buf[4] = 3'u8 -- how this used to be written
proc f() = discard
""", False, "a commented-out instance must not be reported"),
]


def self_test() -> int:
    failures = 0
    for name, body, expect_hit, why in SELF_TEST_CASES:
        hits = scan_text(f"<self-test:{name}>", body.lstrip("\n"))
        got = len(hits) > 0
        if got != expect_hit:
            failures += 1
            print(f"check_version_literals --self-test FAILED: {name}: {why}")
            print(f"  expected {'a refusal' if expect_hit else 'no refusal'}, "
                  f"got {len(hits)}")
            for h in hits:
                print(f"    shape {h[2]} line {h[1]}: {h[3]}")
        else:
            print(f"  ok  {name}: {why}")
    if failures:
        print(f"\ncheck_version_literals: self-test FAILED "
              f"({failures} of {len(SELF_TEST_CASES)} cases)")
        return 1
    print(f"\ncheck_version_literals: self-test ok "
          f"({len(SELF_TEST_CASES)} cases, "
          f"{sum(1 for c in SELF_TEST_CASES if c[2])} positive, "
          f"{sum(1 for c in SELF_TEST_CASES if not c[2])} negative)")
    return 0


SHAPE_NAMES = {
    "A": "an integer literal written into the version word (byte 4/5)",
    "B": "a hand-listed set of version numbers driving a version-word poke",
    "C": "an integer literal compared against a value read from the "
         "version word",
    "D": "an integer literal pinning a version accessor's return value",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=None,
                    help="repository root (default: the parent of scripts/)")
    ap.add_argument("--self-test", action="store_true",
                    help="probe the scanner against synthetic instances and "
                         "exit; reports nothing about the tree")
    ap.add_argument("--list", action="store_true",
                    help="list every ANNOTATED site with its reason -- the "
                         "answer to \"what must I revisit when this version "
                         "moves?\"")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    root = args.root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if args.list:
        n = 0
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in sorted(filenames):
                if not fn.endswith(".nim"):
                    continue
                fp = os.path.join(dirpath, fn)
                for i, ln in enumerate(
                        open(fp, encoding="utf-8", errors="replace")
                        .read().split("\n"), 1):
                    if ANNOTATION in ln and not ln.strip().startswith("##"):
                        n += 1
                        print(f"{os.path.relpath(fp, root)}:{i}: "
                              f"{ln.strip()}")
        print(f"\ncheck_version_literals: {n} annotated version literals")
        return 0

    findings, nfiles = scan_tree(root)
    if not findings:
        print(f"check_version_literals: ok "
              f"({nfiles} .nim sources, no unannotated version literal)")
        return 0

    print(f"check_version_literals: {len(findings)} unannotated version "
          f"literal(s) in {nfiles} .nim sources\n")
    for rel, lineno, shape, line, why in findings:
        print(f"{rel}:{lineno}: {SHAPE_NAMES[shape]}")
        print(f"    {line}")
        print(f"    {why}")
    print("""
REMEDY. Derive the number from the format's own version accessor -- that is
what the accessors exist for, and it is the fix in every case where the number
means "one past current", "everything below current", or "the version an
<x> record gets":

    firstUnknownServicePayloadVersion()   firstUnknownInterfaceEnvelopeVersion()
    firstUnknownDevEnvEnvelopeVersion()   firstUnknownActionRecordVersion()
    actionRecordVersionsThisBuildRefuses()
    actionRecordVersionWithoutEnvInputs()
    envelopeVersion()  devEnvEnvelopeVersion()  interfaceEnvelopeVersion()
    servicePayloadVersion()  RbpiSchemaVersion

If the number genuinely does NOT move with the current version -- a frozen
historical version, the structural floor of zero, or a PIN that must fail
loudly when somebody bumps the format -- say so on the line or the line
above:

    # version-literal-ok: <at least 20 characters of reason>
""")
    return 1


if __name__ == "__main__":
    sys.exit(main())
