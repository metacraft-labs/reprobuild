#!/usr/bin/env python3
"""Notice that the pinned attestation collateral has gone stale, while
there is still time to do something about it.

WHY THIS IS A SCHEDULED TOOL AND NOT A TEST

There are two clocks in this repository and conflating them is the most
expensive mistake available here.

Every gate that judges pinned vendor material states its own ``Now`` as
a constant, because those gates test the *evaluator*: a chain that was
valid when it was captured has to evaluate the same way in five years,
or the test is a test of the date. Replacing those with the wall clock
would make the suite fail on a day nobody chose, for a reason that is
not a defect, which is how a gate gets turned off.

This tool is the other clock, and it is the only thing in the tree that
uses the calendar over vendor material or touches the network. Its
entire job is to say "three revocation lists stop being usable in five
days" while five days remain. It reports and never edits.

WHAT IT CHECKS

Two independent things, because they fail independently:

* **Expiry** — from the ledger's recorded windows against the wall
  clock. No network. A document expires whether or not the publisher
  ever changes it.
* **Drift** — the publisher's current bytes against the pinned digest,
  for the artifacts that have an unattended refresh route. Bytes change
  whether or not any date has moved: a revocation list is reissued, a
  mirror is withdrawn.

WHAT A DIFFERENCE MEANS DEPENDS ON THE CLASS, and the ledger carries the
class for exactly this reason. A monitor that reported every difference
identically would cry wolf every month on collateral that is *supposed*
to be reissued, until nobody read it -- and the one class where a
difference is a real defect would be lost in that noise. The mapping
here is the same one ``repro_attest_verify/lifecycle`` implements for
the Nim side, and ``t_attestation_fixture_lifecycle`` checks that side
against its boundaries.

EXIT CODES

  0  nothing needs attention
  1  something does, and every line of stdout says which and what to do
  2  the tool could not do its job (a table it could not read, a fetch
     it could not complete). Deliberately distinct from 1: "I looked and
     found nothing" and "I could not look" are different answers and a
     scheduled job that conflates them eventually reports the second as
     the first.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import sys
import urllib.error
import urllib.request
from pathlib import Path

ISO = "%Y-%m-%dT%H:%M:%SZ"
DAY = 86400
DEFAULT_HORIZON_DAYS = 30

# A difference from the publisher, by class. Kept in step with
# `LifecycleClass` in libs/repro_attest_verify/src/repro_attest_verify/
# lifecycle.nim; the ledger gate checks that every class the ledger uses
# is one that module declares, and this table is checked against the
# ledger's own class column below, so a class added on either side
# cannot stay unhandled here.
DRIFT_MEANS = {
    "protocol-vector": "drifted",
    "trust-root": "drifted",
    "vendor-collateral": "drifted",
    "genuine-capture": "expected-to-differ",
    "minted-negative": "no-publisher",
    "derived-reading": "no-publisher",
}


class Unusable(Exception):
    """The tool could not do its job. Exit code 2, never 1."""


def read_table(path: Path, columns: int) -> list[list[str]]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise Unusable(f"cannot read {path}: {err}") from err
    rows = []
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != columns:
            # A short row padded with empties is how a remedy goes
            # missing without anybody noticing.
            raise Unusable(
                f"{path.name}: row {fields[0]!r} has {len(fields)} columns, "
                f"and this table has {columns}"
            )
        rows.append(fields)
    return rows


def parse_instant(value: str, what: str) -> int:
    try:
        stamp = datetime.datetime.strptime(value, ISO)
    except ValueError as err:
        raise Unusable(f"{what} is {value!r}, which is not {ISO}") from err
    return int(stamp.replace(tzinfo=datetime.timezone.utc).timestamp())


def classify(not_before: int, not_after: int | None, now: int,
             horizon: int) -> str:
    """The same five statuses, in the same order, as the Nim side.

    The order is the order the facts matter in: a window that has not
    opened is reported as that whatever its end says, because a document
    from the future is a clock fault and naming its expiry would send
    the reader after the wrong thing.
    """
    if now < not_before:
        return "not-yet-in-force"
    if not_after is None:
        return "no-stated-end"
    if now >= not_after:
        return "expired"
    if now + horizon >= not_after:
        return "due-for-refresh"
    return "current"


NEEDS_ATTENTION = {
    "not-yet-in-force", "due-for-refresh", "expired", "no-stated-end",
}


def days(a: int, b: int) -> int:
    return (b - a) // DAY


def expiry_line(row: dict, status: str, now: int, remedy: str) -> str:
    name, nb, na = row["name"], row["not_before"], row["not_after"]
    if status == "expired":
        when = f"since {na} ({days(parse_instant(na, name), now)} days ago)"
    elif status == "due-for-refresh":
        when = f"expires {na} (in {days(now, parse_instant(na, name))} days)"
    elif status == "not-yet-in-force":
        when = f"until {nb}; check this machine's clock before refreshing anything"
    elif status == "no-stated-end":
        when = ("-- no evaluator in this build honours a revocation list with "
                "no next-update, so holding only this one refuses every chain")
    elif status == "current":
        when = f"until {na}"
    else:
        raise Unusable(f"{name} classified {status!r}, which this tool "
                       "has no sentence for")
    return (f"{name}: {status} {when}. It is {row['class']} from "
            f"{row['publisher']}. Refresh it with: {remedy}")


def drift_line(name: str, cls: str, outcome: str, pinned: str,
               observed: str, url: str, remedy: str) -> str:
    if outcome == "unchanged":
        return f"{name}: unchanged at {pinned}"
    if outcome == "drifted":
        body = f"pinned {pinned}, {url} now serves {observed}"
    else:
        body = (f"pinned {pinned}, {url} answered {observed}, which for "
                f"{cls} is a second answer and not a refutation of the first")
    return f"{name}: {outcome} -- {body}. Refresh it with: {remedy}"


class CouldNotFetch(Exception):
    """One publisher was unreachable. Still exit 2 -- "I could not look"
    -- but NOT a reason to throw away the expiry findings already
    computed, which is what raising `Unusable` here used to do: a
    single unreachable host suppressed the whole report, including
    "three revocation lists stop being usable in five days". The two
    checks are documented to fail independently and now do.
    """


def fetch(url: str, normalize: str, timeout: int) -> bytes:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read()
    except (urllib.error.URLError, OSError) as err:
        raise CouldNotFetch(f"could not fetch {url}: {err}") from err
    if normalize == "strip-cr":
        return body.replace(b"\r", b"")
    if normalize != "none":
        raise Unusable(f"{url} names the normalization {normalize!r} "
                       "and this tool has none")
    return body


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ledger-root", default="tests/integration",
                    help="the directory holding the ledger tables")
    ap.add_argument("--now", default=None,
                    help="evaluate at this instant instead of the wall "
                         "clock, written " + ISO)
    ap.add_argument("--horizon-days", type=int, default=DEFAULT_HORIZON_DAYS)
    ap.add_argument("--offline", action="store_true",
                    help="skip every fetch; report expiry only")
    ap.add_argument("--observed-digests", default=None,
                    help="a two-column table of name and sha256 to use "
                         "INSTEAD of fetching, so the drift decision and "
                         "its output can be exercised without a network")
    ap.add_argument("--timeout", type=int, default=30)
    args = ap.parse_args(argv)

    root = Path(args.ledger_root)
    ledger_cols = ("name module class publisher observed bytes sha256 "
                   "window not_before not_after").split()
    ledger = [dict(zip(ledger_cols, f))
              for f in read_table(root / "attestation-fixture-ledger.tsv", 10)]
    publishers = {f[0]: f[3] for f in
                  read_table(root / "attestation-fixture-publishers.tsv", 4)}
    fetchable = {f[0]: (f[1], f[2]) for f in
                 read_table(root / "attestation-fixture-fetch.tsv", 3)}

    for row in ledger:
        if row["class"] not in DRIFT_MEANS:
            raise Unusable(
                f"{row['name']} is classified {row['class']!r} and this tool "
                "has no rule for what a difference from its publisher would "
                "mean; add one rather than defaulting")
        if row["publisher"] not in publishers:
            raise Unusable(f"{row['name']} names the publisher "
                           f"{row['publisher']!r}, which no row describes")
    for name in fetchable:
        if not any(r["name"] == name for r in ledger):
            raise Unusable(f"the fetch table names {name!r}, "
                           "which the ledger does not")

    now = (parse_instant(args.now, "--now") if args.now
           else int(datetime.datetime.now(datetime.timezone.utc).timestamp()))
    horizon = args.horizon_days * DAY

    observed = {}
    if args.observed_digests:
        for fields in read_table(Path(args.observed_digests), 2):
            observed[fields[0]] = fields[1]

    findings: list[str] = []
    quiet: list[str] = []
    unreachable: list[str] = []

    for row in ledger:
        if row["window"] in ("none", "unreadable"):
            continue
        nb = parse_instant(row["not_before"], row["name"] + " not_before")
        na = (None if row["not_after"] == "-"
              else parse_instant(row["not_after"], row["name"] + " not_after"))
        status = classify(nb, na, now, horizon)
        remedy = publishers[row["publisher"]]
        line = expiry_line(row, status, now, remedy)
        loud = status in NEEDS_ATTENTION
        # One pinned revocation list carries no next-update ON PURPOSE:
        # it is the input the evaluators' set-aside rule needs, and it
        # was minted here by removing the field. Reporting it every run
        # would be this tool crying wolf about a fixture doing its job,
        # and a report nobody reads is worse than no report. Minted
        # material still has its EXPIRY reported -- a minted certificate
        # that runs out is a real failure with a real remedy.
        if status == "no-stated-end" and row["class"] == "minted-negative":
            loud = False
        (findings if loud else quiet).append(line)

    if not args.offline:
        for row in ledger:
            name = row["name"]
            if name not in fetchable:
                continue
            url, normalize = fetchable[name]
            if name in observed:
                digest = observed[name]
            else:
                try:
                    digest = hashlib.sha256(
                        fetch(url, normalize, args.timeout)).hexdigest()
                except CouldNotFetch as err:
                    unreachable.append(f"{name}: {err}")
                    continue
            meaning = DRIFT_MEANS[row["class"]]
            if meaning == "no-publisher":
                raise Unusable(
                    f"{name} is classified {row['class']!r}, which has no "
                    "publisher, and yet the fetch table gives it a URL")
            if digest == row["sha256"]:
                outcome = "unchanged"
            else:
                outcome = meaning
            line = drift_line(name, row["class"], outcome, row["sha256"],
                              digest, url, publishers[row["publisher"]])
            (quiet if outcome in ("unchanged", "expected-to-differ")
             else findings).append(line)

    routeless = sum(1 for row in ledger if row["name"] not in fetchable)
    print(f"attestation collateral, evaluated at "
          f"{datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime(ISO)} "
          f"with a {args.horizon_days}-day horizon:")
    print(f"  {len(ledger)} pinned artifacts, {len(fetchable)} with an "
          f"unattended refresh route, {routeless} without one")
    for line in findings:
        print("  ! " + line)
    for line in unreachable:
        print("  ? " + line)
    for line in quiet:
        print("    " + line)
    if findings:
        print(f"  {len(findings)} artifact(s) need attention")
    if unreachable:
        # Exit 2 whatever the findings say. "I could not look" outranks
        # "I looked and found something", because a reader who is told
        # only the second will believe the drift half ran.
        print(f"  {len(unreachable)} publisher(s) could not be reached; "
              "the drift half of this run is INCOMPLETE")
        return 2
    if findings:
        return 1
    print("  nothing needs attention")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Unusable as err:
        print(f"attestation collateral monitor: {err}", file=sys.stderr)
        sys.exit(2)
