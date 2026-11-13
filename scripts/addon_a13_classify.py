#!/usr/bin/env python3
"""The verdict of an A13 add-on VM gate cell: whether its gate record is what
the cell must show.

A cell is ``<kind>-<base>`` (``mutexec-debian-13``): ``kind`` names the gate,
the expected verdict (green, or red under a falsifying build or a gate-level
mutation) and, for a red cell, the step that must be red and the evidence its
record must carry -- a probe a falsifier lets in must be shown to have run
(its marker), not only to have been let in; a cell red at any other step, or
without that evidence, is not as expected. ``scripts/run_addon_gate.sh``
writes the records this reads (``build/addon-gates/records``).

Usage::

    addon_a13_classify.py <cell> <record.json>      # prints the verdict
    addon_a13_classify.py --table                    # the expectations, JSON

Exit 0 when the cell is as expected, 1 when it is not, 2 on a usage error.
Importable: ``classify(cell, record) -> (as_expected, kind, why)``.
"""

import json
import sys

EXPECT = {
    "adopt": ("e2e_addon_adopt_hand_configured_service", "green", "none"),
    "mutimport": ("e2e_addon_adopt_hand_configured_service", "red",
                  "add-on build import-writes-skeleton"),
    "mutstate": ("e2e_addon_adopt_hand_configured_service", "red",
                 "gate-level REPRO_A13_MUTATION=converge-touches-state"),
    "conv": ("e2e_addon_to_reproos_conversion_keeps_state", "green", "none"),
    "mutheld": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                "add-on build state-units-not-held"),
    "muttamper": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                  "gate-level REPRO_A13_MUTATION=carried-archive-tampered"),
    "mutapply": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                 "engine build apply-ignores-carried-state"),
    "mutrestore": ("e2e_addon_adopt_hand_configured_service", "red",
                   "add-on build restore-after-start"),
    "mutholdreboot": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                      "add-on build hold-runtime-only"),
    "mutkeep": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                "engine build keep-without-mount-requirement"),
    "revexec": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                "gate-level REPRO_A13_MUTATION=rev-execution-dropped"),
    "revbeacon": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                  "gate-level REPRO_A13_MUTATION=rev-beacon-dropped"),
    "revslash": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                 "gate-level REPRO_A13_MUTATION=rev-slashing-db-reset"),
    "hardreset": ("e2e_addon_hard_reset_at_every_step", "green",
                  "none (A4 regression; includes the new point step-6-restore)"),
    "confirm": ("e2e_addon_confirm_or_revert", "green", "none (A4/A5 regression)"),
    "validator": ("e2e_addon_validator_never_double_signs", "green",
                  "none (A12 regression: the reference fixture changed)"),
    "parity": ("e2e_addon_reproos_service_parity", "green",
               "none (A12 regression: the reference fixture changed)"),
    "floorupgrade": ("e2e_addon_floor_upgrade_keeps_installed_generations", "green",
                     "none (A9 cross-check: carried-state check reads a stored target under its own rules)"),
    "tickctl": ("e2e_addon_tick_observes_a_fresh_cycle", "green",
                "none (positive control of agent_e2e_support.tickUnits)"),
    "tickold": ("e2e_addon_tick_observes_a_fresh_cycle", "red",
                "gate-level REPRO_A13_MUTATION=tick-joins-in-flight (the old helper)"),
    "tickproof": ("e2e_addon_tick_observes_a_fresh_cycle", "red",
                  "gate-level REPRO_A13_MUTATION=tick-skips-idle-wait (the proof alone)"),
    "agente2e": ("e2e_addon_agent_end_to_end", "green",
                 "none (A8 cross-check: tickUnits changed)"),
    "revinode": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                 "gate-level REPRO_A13_MUTATION=rev-inode-reuse"),
    "revslashnodg": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                     "gate-level REPRO_A13_MUTATION=rev-slashing-db-reset-no-doppelganger"),
    "mutrestorereq": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                      "engine build restore-not-required-by-units"),
    "mutunordered": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                     "engine seam build with restore-unordered"),
    "convseam": ("e2e_addon_to_reproos_conversion_keeps_state", "green",
                 "none (the engine's seam build: the ordering check runs)"),
    "mutbylink": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                  "engine build restore-required-by-link"),
    "mutreachname": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                     "engine build carried-reach-by-unit-name"),
    "mutreceipt": ("e2e_addon_hard_reset_at_every_step", "red",
                   "add-on seam build receipt-no-fsync, aimed at the receipt points"),
    "mutacct": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                "engine build account-as-written"),
    "muttimer": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                 "engine build reach-timer-dropins-unread"),
    "mutpathunit": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                    "engine build reach-path-unit-paths-ignored"),
    "muthost": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                "engine build reach-host-dropins-ignored"),
    "mutreq": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
               "engine build restore-requirement-by-manifest-only"),
    # The live cross-check off as well: it refuses these probes too, so
    # under the static reading's build alone the probe never runs (A13
    # review round 7). mutinfralive is the other half of each pair.
    "mutvalues": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build reach-values-as-text-without-live-check"),
    "mutalias": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build reach-alias-dropins-unread-without-live-check"),
    "mutconfine": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build confined-without-nnp-or-groups"),
    "mutnss": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build account-nss-unread"),
    "mutprefix": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build account-dynamic-name-from-stem-without-live-check"),
    "mutactivated": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build restore-requirement-skips-activated"),
    "mutundeclared": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build full-apply-keeps-undeclared-dropins"),
    "mutplan": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build plan-ignores-profile-digest"),
    "mutdropintarget": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build restore-requirement-skips-dropin-targets"),
    "mutlines": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build unit-lines-continue-as-text"),
    "mutexec": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build exec-first-command-only"),
    "mutchain": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build alias-chain-first-link-only"),
    "mutdeplinks": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build dependency-links-unread"),
    "mutreserved": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build requirement-name-not-reserved"),
    "mutdaemons": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build privileged-daemons-unread"),
    "mutinfralive": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build infra-live-reach-skipped"),
    "mutclosure": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build restore-requirement-skips-closure"),
    "mutaddonlive": ("e2e_addon_adopt_hand_configured_service", "red", "add-on build addon-live-reach-skipped"),
    "mutlivechoice": ("e2e_addon_adopt_hand_configured_service", "red", "add-on build live-units-chosen-after-writes"),
    "mutpostreload": ("e2e_addon_to_reproos_conversion_keeps_state", "red", "engine build post-reload-refusal-skipped"),
    "mutadoptprofile": ("e2e_addon_adopt_hand_configured_service", "red", "add-on build adopt-without-profile"),
    "refused": ("e2e_addon_refused_recovery_keeps_its_record", "green",
                "none (A4/A5 regression)"),
}
TARGET = {
    "mutimport": "import wrote nothing",
    "mutstate": "alertmanager's state directory is byte-identical",
    "mutheld": "after the backup the validator is held",
    "muttamper": "the first-boot unit restored the carried state",
    "mutapply": "an apply before the restore is refused",
    "mutrestore": "rollback restores the operator's unit bytes",
    "mutholdreboot": "after a reboot the validator is still held",
    "mutkeep": "with its kept disk missing vaultwarden does not start",
    "revexec": "the validator signs on the converted host",
    "revbeacon": "the beacon node resumes from the carried chain",
    "revslash": "the slashing-protection history was carried",
    "tickold": "the tick observes a fresh cycle, which applies sequence 3",
    "tickproof": "__requires_alt__",
    "revinode": "__requires_alt__",
    "revslashnodg": "__requires_alt__",
    "mutrestorereq": "a carried unit does not start at boot while its restore fails",
    "mutunordered": "waits for the restore (held at its seam)",
    "mutbylink": "a carried unit does not start at boot while its restore fails",
    "mutreachname": "reaches the carried directory only by its path",
    "mutacct": "round 4, account: refused while the directory is pending",
    "muttimer": "round 4, timer: refused while the directory is pending",
    "mutpathunit": "round 4, path: refused while the directory is pending",
    "muthost": "round 4, host drop-in: a drop-in in /run",
    "mutreq": "a unit the manifest does not name that reaches the carried",
    "mutvalues": "round 5, values: refused",
    "mutalias": "round 5, alias: refused",
    "mutconfine": "round 5, group: refused",
    "mutnss": "round 5, userdb: refused",
    "mutprefix": "round 5, prefix: refused",
    "mutactivated": "round 5, wants:",
    "mutundeclared": "round 5, undeclared:",
    "mutdropintarget": "round 5, dropin:",
    "mutlines": "round 6, lines:",
    "mutexec": "round 6, exec:",
    "mutchain": "round 6, aliaschain:",
    "mutdeplinks": "round 6, wantslink:",
    "mutreserved": "round 6, reserved:",
    "mutdaemons": "round 6, polkit:",
    "mutinfralive": "round 6, live:",
    "mutclosure": "round 6, closure:",
    "mutaddonlive": "the add-on switch refuses a unit systemd loaded unconfined",
    "mutlivechoice": "the add-on switch refuses a unit systemd loaded unconfined",
    "mutpostreload": "round 6, liverw:",
    "mutadoptprofile": "`repro system adopt` refuses while the profile declares the old",
    "mutplan": "round 5, plan: a plan made before install-unit is refused",
}
# A mutation two guards can catch, whichever sees it first: with
# validator.db deleted the validator either starts and the carried-history
# step is red, or prysm's doppelganger check finds the keys' own earlier
# attestations on chain and refuses to run (the health step is red with
# that refusal in its detail). Both are the mutation caught.
ALT_TARGETS = {
    # The apply after the replacement is refused for the carried state.
    "revinode": [("the reinstalled host realises the activities in full",
                  "ECarriedStatePending")],
    # The old helper reports the stale sequence; the proof alone reports it
    # as a stale cycle. Both are red on the fresh-cycle step.
    "tickproof": [("the tick observes a fresh cycle", "stale-cycle")],
    "revslash": [("eth-validator.service passes its health check",
                  "Duplicate instances exists in the network")],
}


# Round 7 of the A13 review.
EXPECT.update({
    "mutnarrowed": ("e2e_addon_adopt_hand_configured_service", "red",
                    "add-on build narrowed-live-set"),
    "mutreissuetgt": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                      "engine build reissue-skips-targets"),
    "mutreissuesock": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                       "engine build reissue-skips-sockets"),
})
TARGET.update({
    "mutnarrowed": "a switch that changes only a file the service depends_on",
    "mutreissuetgt": "decision 79, target:",
    "mutreissuesock": "decision 79, socket:",
})

ROUND4_PROBES = ["account", "timer", "pathfloored", "path", "host"]
ROUND5_PROBES = ["r5values", "r5alias", "r5group", "r5nnp", "r5userdb",
                 "r5prefix", "r5plan"]
LIVE_PAIRED_PROBES = ["r5values", "r5alias", "r5prefix"]
"""The probes the full apply's live cross-check refuses as well as the
static reading each falsifier breaks: their falsifiers are built with the
live check off too, and mutinfralive shows them refused without it."""
ROUND6_PROBES = ["r6lines", "r6exec", "r6aliaschain", "r6wantslink",
                 "r6reserved", "r6polkit", "r6live", "r6liverw"]


def let_in_and_ran(probes, label):
    """A probe a falsifier lets in: judged (its profile compiled), let in
    (exit 0) and shown to have run (its marker written, no failure after its
    start): a let-in probe that never ran is no evidence."""
    pr = probes.get(label, {})
    return (pr.get("judged") is True and pr.get("exit") == 0 and
            pr.get("ran") is True)


def on_target_rec(kind, rec):
    """on_target, plus the evidence a cell's red (or green) must carry."""
    steps = rec.get("steps", [])
    probes = rec.get("roundFourProbes", {})
    if kind == "revslashnodg":
        ev = rec.get("historyEvidence", {})
        red = [st["step"] for st in steps if not st["ok"]]
        return (any("slashing-protection history was carried" in r for r in red)
                and ev.get("progressed") is True
                and ev.get("attestations", 0) > 0
                and ev.get("earliestMin", -1) > ev.get("addOnEpoch", 1 << 30))
    if kind in ("mutvalues", "mutalias", "mutconfine", "mutnss", "mutprefix"):
        labels = {"mutvalues": ["r5values"], "mutalias": ["r5alias"],
                  "mutconfine": ["r5group", "r5nnp"], "mutnss": ["r5userdb"],
                  "mutprefix": ["r5prefix"]}[kind]
        return all(let_in_and_ran(probes, l) for l in labels) and on_target(kind, steps)
    if kind == "mutinfralive" and not all(
            probes.get(l, {}).get("judged") is True and
            probes.get(l, {}).get("refusedForReason") is True
            for l in LIVE_PAIRED_PROBES):
        # The pair of the three "-without-live-check" builds: with the live
        # check off and the static readings intact, each of their probes is
        # still refused for its own reason (the round-5 probes run before
        # this cell's target step).
        return False
    if kind in ("mutlines", "mutexec", "mutchain", "mutdeplinks", "mutreserved",
                "mutdaemons", "mutinfralive", "mutpostreload"):
        label = {"mutlines": "r6lines", "mutexec": "r6exec", "mutchain": "r6aliaschain",
                 "mutdeplinks": "r6wantslink", "mutreserved": "r6reserved",
                 "mutdaemons": "r6polkit", "mutinfralive": "r6live",
                 "mutpostreload": "r6liverw"}[kind]
        return let_in_and_ran(probes, label) and on_target(kind, steps)
    if kind in ("mutaddonlive", "mutlivechoice"):
        # Started, and ran as root: its ExecStartPre's uid marker reads 0.
        lc = rec.get("liveCrossCheck", {})
        return on_target(kind, steps) and lc.get("ranAsRoot") is True
    if kind == "mutnarrowed":
        # The restart ran the loaded root definition: the uid marker reads 0.
        ev = rec.get("everySwitch", {})
        return (on_target(kind, steps) and ev.get("ranAsRoot") is True and
                ev.get("loadedUserBefore") == "root")
    if kind == "mutadoptprofile":
        # The silent revert itself: the gate reached the revert step (its
        # record says so) and the old profile's switch ran (no scope or drift
        # refusal) and wrote the old bytes back over the adopted edit.
        rv = [st for st in steps if not st["ok"] and
              "a switch of the old profile does not revert the edit" in st["step"]]
        return (on_target(kind, steps) and len(rv) == 1 and
                rec.get("revertStepReached") is True and
                "EAddOnOutOfScope" not in rv[0]["detail"] and
                "EDrift" not in rv[0]["detail"])
    if kind == "mutplan":
        return let_in_and_ran(probes, "r5plan") and on_target(kind, steps)
    if kind in ("mutacct", "muttimer", "mutpathunit", "muthost"):
        label = {"mutacct": "account", "muttimer": "timer",
                 "mutpathunit": "path", "muthost": "host"}[kind]
        ok = let_in_and_ran(probes, label)
        if kind == "muthost":
            ok = ok and let_in_and_ran(probes, "hostControl")
        if kind == "mutpathunit":
            # The floor still refuses the floored variant (defence in depth);
            # only the reach step goes red.
            ok = ok and probes.get("pathfloored", {}).get("refusedForReason") is True
        return ok and on_target(kind, steps)
    if kind in ("mutreissuetgt", "mutreissuesock"):
        # Red because the pulled-in service stayed down, not for another
        # reason: the other decision-79 service is up and ran.
        d = rec.get("decision79", {})
        other = "socket" if kind == "mutreissuetgt" else "target"
        mine = "target" if kind == "mutreissuetgt" else "socket"
        return (on_target(kind, steps) and d.get(other, {}).get("ran") is True and
                d.get(mine, {}).get("ran") is not True)
    if kind == "conv":
        # Every probe of every round judged and refused for its reason, the
        # round-4 host control let in and shown to run, and both decision-79
        # services up and shown to run.
        labels = ROUND4_PROBES + ROUND5_PROBES + ROUND6_PROBES
        ctl = probes.get("hostControl", {})
        d = rec.get("decision79", {})
        return (all(probes.get(l, {}).get("judged") is True and
                    probes.get(l, {}).get("refusedForReason") is True
                    for l in labels) and
                ctl.get("exit") == 0 and ctl.get("ran") is True and
                d.get("target", {}).get("ran") is True and
                d.get("socket", {}).get("ran") is True)
    if kind == "mutreceipt":
        # At receipt-before-dir-fsync the receipt on the disk is empty (the
        # rename committed, the data not); before the rename the old receipt
        # is untouched either way.
        st = {x["step"]: x for x in steps}
        late = [x for n, x in st.items() if n.startswith("receipt receipt-before-dir-fsync: after the reset")]
        early = [x for n, x in st.items() if n.startswith("receipt receipt-before-rename: after the reset")]
        return (len(late) == 1 and not late[0]["ok"] and
                "on disk (0 bytes)" in late[0]["detail"] and
                len(early) == 1 and early[0]["ok"])
    if kind == "hardreset":
        st = [x for x in steps if x["step"].startswith("receipt receipt-before-") and "after the reset" in x["step"]]
        return len(st) == 2 and all(x["ok"] for x in st)
    if kind == "convseam":
        return (rec.get("orderingCheck", "").startswith("run") and
                any("waits for the restore (held at its seam)" in st["step"]
                    and st["ok"] for st in steps))
    return on_target(kind, steps)


def on_target(kind, steps):
    red = [st for st in steps if not st["ok"]]
    if kind not in TARGET:
        return True
    if any(TARGET[kind] in st["step"] for st in red):
        return True
    for stepNeedle, detailNeedle in ALT_TARGETS.get(kind, []):
        if any(stepNeedle in st["step"] and detailNeedle in st["detail"] for st in red):
            return True
    return False



def kind_of(cell):
    """The kind of a cell named ``<kind>-<base>``."""
    return cell.split("-", 1)[0].rstrip("0123456789")


def classify(cell, rec):
    """(as_expected, kind, why) for ``cell`` and its gate record ``rec``."""
    kind = kind_of(cell)
    if kind not in EXPECT:
        return (False, kind, "no expectation for kind " + kind)
    want = EXPECT[kind][1]
    verdict = rec.get("verdict", "missing")
    if verdict != want:
        return (False, kind, "verdict %s, expected %s" % (verdict, want))
    if not on_target_rec(kind, rec):
        return (False, kind, "not red (or green) for its own reason: the "
                "target step or the evidence the record must carry is missing")
    return (True, kind, "as expected")


def main(argv):
    if len(argv) == 2 and argv[1] == "--table":
        print(json.dumps({"expect": EXPECT, "target": TARGET,
                          "altTargets": ALT_TARGETS}, indent=1))
        return 0
    if len(argv) != 3:
        print(__doc__)
        return 2
    rec = json.load(open(argv[2]))
    ok, kind, why = classify(argv[1], rec)
    print("%s %s %s: %s" % ("OK" if ok else "UNEXPECTED", argv[1], kind, why))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
