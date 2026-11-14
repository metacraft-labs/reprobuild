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

A record is judged by the cell it was run for, not only by its verdict
(reprobuild-pm issue
``2026-11-14-addon-a13-classifier-accepts-another-gates-record-and-an-empty-green-one``):

* its ``gate`` is the cell's gate and its ``base`` the cell's base on the
  record's ``arch`` (``debian-13`` -> ``debian-13-amd64``);
* the builds it ran are the cell's (``BUILD``, parsed from ``EXPECT``): the
  add-on build (``mutation``), the gate-level mutation (``gateMutation``, or
  ``variant`` in the tick gate's record) and the engine build
  (``engineBuild.mutation`` and ``engineBuild.testSeams`` for the engine
  closure named by ``engine``). A gate that reads ``REPRO_A13_MUTATION``
  must record it; an engine closure whose build is unknown is not as
  expected;
* a green record is complete (``GREEN``): every step ok, no ``exception``
  step, at least the steps its gate records and its gate's final step last,
  and for ``adopt`` the every-switch and live-cross-check steps and fields.

On the command line the build of a record's ``engine`` closure is read from
that closure's derivation (``nix-store -q --deriver`` and ``nix derivation
show``, see ``resolve_engine_build``) and is the authority: an older record
without ``engineBuild`` gets it, and a recorded ``engineBuild`` that
disagrees with it is not as expected (``reconcile_engine_build``).
``classify`` itself reads only the record.

Exit 0 when the cell is as expected, 1 when it is not, 2 on a usage error.
Importable: ``classify(cell, record) -> (as_expected, kind, why)``.
"""

import json
import os
import subprocess
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


# Round 7 of the A13 review: the decision-79 re-issue cells.
EXPECT.update({
    "mutreissuetgt": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                      "engine build reissue-skips-targets"),
    "mutreissuesock": ("e2e_addon_to_reproos_conversion_keeps_state", "red",
                       "engine build reissue-skips-sockets"),
})
TARGET.update({
    "mutreissuetgt": "decision 79, target:",
    "mutreissuesock": "decision 79, socket:",
})

# Round 8 of the A13 review. The add-on build narrowed-live-set has a VM
# cell again: the adopt gate's case 2e, a switch that changes only a
# service's credential. No unit driver runs for it, so nothing but step 6's
# own hold, reload and judgement keeps the restart off the root definition
# the operator left loaded. Case 2d (a depends_on restart) is no cell for
# it: the dependency restart's unit driver reloads systemd at step 3 and
# masks the build. The unit case t_addon_carried_state_fails_closed "a
# switch that writes no unit file holds, reloads and judges the services"
# tests the decision (liveCheckAtStep6) beside it.
EXPECT.update({
    "mutliveset": ("e2e_addon_adopt_hand_configured_service", "red",
                   "add-on build narrowed-live-set"),
})
TARGET.update({
    "mutliveset": "a switch that changes only a service's credential judges it",
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
    if kind == "mutliveset":
        # The credentials-only switch changed the probe's materialised
        # credential and wrote none of its unit files (``credentialsOnly``),
        # restarted it (its invocation changed), and the restarted probe ran
        # as root: its uid marker reads 0. A root run some other path made
        # (``secret put`` restarts a running consumer itself) is not this.
        cs = rec.get("credentialSwitch", {})
        return (on_target(kind, steps) and cs.get("ranAsRoot") is True and
                cs.get("restarted") is True and
                cs.get("credentialChanged") is True and
                cs.get("credentialsOnly") is True)
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



def parse_build(description):
    """The builds a cell's ``EXPECT`` description names, as a dict:
    ``mutation`` (the add-on build), ``gateMutation`` (gate-level),
    ``engine`` (the engine build) and ``engineSeams`` (the engine built with
    ``REPRO_ADDON_TEST_SEAMS``). Raises ``ValueError`` on a form it does not
    know, so a new ``EXPECT`` entry cannot be read as "no mutation"."""
    b = {"mutation": "", "gateMutation": "", "engine": "", "engineSeams": False}
    word = lambda rest: rest.split()[0].rstrip(",")
    if description.startswith("none"):
        pass
    elif description.startswith("add-on build "):
        b["mutation"] = word(description[len("add-on build "):])
    elif description.startswith("add-on seam build "):
        b["mutation"] = word(description[len("add-on seam build "):])
    elif description.startswith("gate-level REPRO_A13_MUTATION="):
        b["gateMutation"] = word(description[len("gate-level REPRO_A13_MUTATION="):])
    elif description.startswith("engine build "):
        b["engine"] = word(description[len("engine build "):])
    elif description.startswith("engine seam build with "):
        b["engine"] = word(description[len("engine seam build with "):])
        b["engineSeams"] = True
    else:
        raise ValueError("unparsed build description: " + description)
    return b


# What the description of a kind does not say in its build words: convseam
# is the product engine's seam build (no mutation; the conversion gate's
# ordering check runs only under it).
BUILD_OVERRIDES = {"convseam": {"engineSeams": True}}

BUILD = {}
for _kind, (_gate, _verdict, _desc) in EXPECT.items():
    BUILD[_kind] = parse_build(_desc)
    BUILD[_kind].update(BUILD_OVERRIDES.get(_kind, {}))

GATE_MUTATION_FIELD = {"e2e_addon_tick_observes_a_fresh_cycle": "variant",
                       "e2e_addon_validator_never_double_signs":
                           "a13GateMutation"}
"""Where a gate's record keeps its gate-level mutation
(``REPRO_A13_MUTATION``), when not in ``gateMutation``: the tick gate
records it as ``variant``; the validator gate's ``gateMutation`` is its own
``REPRO_A12_MUTATION``, and the A13 one (read by ``tickUnits``) is
``a13GateMutation``."""

OTHER_GATE_MUTATIONS = {"e2e_addon_validator_never_double_signs":
                        ["gateMutation"]}
"""A gate's other gate-level mutations, which no A13 cell runs: each must be
recorded and empty (the validator gate's ``REPRO_A12_MUTATION``)."""

GATES_WITHOUT_GATE_MUTATION = {
    "e2e_addon_confirm_or_revert",
    "e2e_addon_floor_upgrade_keeps_installed_generations",
    "e2e_addon_hard_reset_at_every_step",
    "e2e_addon_refused_recovery_keeps_its_record",
}
"""The gates that never read ``REPRO_A13_MUTATION`` (neither themselves nor
through ``agent_e2e_support.tickUnits``): their records may omit it. Every
other gate's record must say which gate-level mutation it ran."""

# A green record is complete: at least the steps its gate records, and the
# gate's final step last. The counts and final steps are the round-7 green
# records' (reprobuild-pm Measurements/
# 2026-11-14-addon-a13-round7-split-757b04f116.json; adopt and conv on all
# three bases at 757b04f116, the same count on each; convseam at
# bc83794147, confirm, parity, refused and validator at a2a1d662ae,
# agente2e and tickctl at cc02f0def7, floorupgrade at e63ec50fdd,
# hardreset at 757b04f116). A later gate that records more steps still
# passes; one that records fewer, or stops before its end, does not.
GREEN = {
    "adopt": (48, "after the rollback the state directories are unchanged"),
    "agente2e": (17, "the sequence floor is 4"),
    "confirm": (28, "uninstall"),
    "conv": (68, "a carried unit does not start at boot while its restore fails"),
    "convseam": (37, "a carried unit without default dependencies waits for "
                     "the restore (held at its seam) and does not start when "
                     "it fails"),
    "floorupgrade": (24, "and its service serves page-prefloor"),
    "hardreset": (181, "uninstall"),
    "parity": (59, "the add-on guest's re-assert materialises the token and "
                   "starts the failed vaultwarden again"),
    "refused": (26, "uninstall"),
    "tickctl": (6, "the file holds sequence 3's content"),
    "validator": (32, "positive control: a second database's real double "
                      "sign is found"),
}
for _kind, (_gate, _verdict, _desc) in EXPECT.items():
    if (_verdict == "green") != (_kind in GREEN):
        raise ValueError("GREEN and EXPECT disagree on " + _kind)

ADOPT_EVERY_SWITCH_STEPS = [
    "switch 1 of the updated profile succeeds",
    "switch 2 of the updated profile succeeds",
    "the add-on switch refuses a unit systemd loaded unconfined",
    "after the generator and the manifest are gone, the switch succeeds",
    "a switch that changes only a file the service depends_on judges it as "
    "systemd loads it",
    "a switch that changes only a service's credential judges it as systemd "
    "loads it",
    "the credentials-only switch restarted the probe for its credential alone",
]
"""The adopt gate's every-switch and live-cross-check steps (spec §11.1; A13
review rounds 7 and 8: finding 1 and its credentials-only case 2e), each of
which a green adopt record carries ok."""


def kind_of(cell):
    """The kind of a cell named ``<kind>-<base>``."""
    return cell.split("-", 1)[0].rstrip("0123456789")


def base_of(cell):
    """The base of a cell named ``<kind>-<base>`` (``debian-13``)."""
    return cell.split("-", 1)[1] if "-" in cell else ""


def build_mismatch(kind, rec):
    """Why ``rec`` was not run under the builds ``kind`` names, or None."""
    want = BUILD[kind]
    gate = EXPECT[kind][0]
    if "mutation" not in rec:
        return "mutation not recorded, expected %r" % want["mutation"]
    if rec["mutation"] != want["mutation"]:
        return "mutation %r, expected %r" % (rec["mutation"], want["mutation"])
    field = GATE_MUTATION_FIELD.get(gate, "gateMutation")
    if field in rec:
        got = rec[field]
    elif gate in GATES_WITHOUT_GATE_MUTATION:
        got = ""
    else:
        return "%s not recorded, expected %r" % (field, want["gateMutation"])
    if got != want["gateMutation"]:
        return "%s %r, expected %r" % (field, got, want["gateMutation"])
    for other in OTHER_GATE_MUTATIONS.get(gate, []):
        if rec.get(other, None) != "":
            return "%s %r, expected it recorded and empty" % (
                other, rec.get(other, "not recorded"))
    if rec.get("engine"):
        eb = rec.get("engineBuild")
        if not isinstance(eb, dict) or "mutation" not in eb or "testSeams" not in eb:
            reason = eb.get("error", "incomplete") if isinstance(eb, dict) \
                else "not recorded"
            return ("engineBuild of engine %s unknown (%s), expected engine "
                    "build %r" % (rec["engine"], reason, want["engine"]))
        if eb.get("closure") != rec["engine"]:
            # The build of another closure says nothing about this one.
            return "engineBuild is of closure %r, the record's engine is %r" % (
                eb.get("closure"), rec["engine"])
        if eb["mutation"] != want["engine"]:
            return "engine build %r, expected %r" % (eb["mutation"], want["engine"])
        if eb["testSeams"] is not want["engineSeams"]:
            return "engineBuild testSeams %r, expected %r" % (
                eb["testSeams"], want["engineSeams"])
    elif want["engine"] or want["engineSeams"]:
        return "the record names no engine, expected engine build %r%s" % (
            want["engine"], " with testSeams" if want["engineSeams"] else "")
    return None


def green_incomplete(kind, rec):
    """Why a green record of ``kind`` is not a complete run, or None."""
    steps = rec.get("steps", [])
    least, last = GREEN[kind]
    red = [st["step"] for st in steps if not st.get("ok")]
    if red:
        return "green record with red steps: %r" % red
    if any(st.get("step") == "exception" for st in steps):
        return "green record with an exception step"
    if len(steps) < least:
        return "%d steps, expected at least %d" % (len(steps), least)
    if steps[-1].get("step") != last:
        return "final step %r, expected %r" % (steps[-1].get("step"), last)
    if kind == "adopt":
        names = [st["step"] for st in steps]
        for needle in ADOPT_EVERY_SWITCH_STEPS:
            if not any(n.startswith(needle) for n in names):
                return "step %r missing" % needle
        es = rec.get("everySwitch")
        if not isinstance(es, dict):
            return "everySwitch not recorded"
        if es.get("ranAsRoot") is not False or not isinstance(es.get("exit"), int):
            return "everySwitch %r, expected ranAsRoot false and an exit code" % (
                {k: es.get(k) for k in ("exit", "ranAsRoot")})
        if es["exit"] == 0 and es.get("restarted") is not True:
            return "everySwitch exit 0 without a restart"
        cs = rec.get("credentialSwitch")
        if not isinstance(cs, dict):
            return "credentialSwitch not recorded"
        # Case 2e is the narrowed-live-set cell's case: green only when its
        # switch was the credentials-only restart it is meant to be, and the
        # restarted probe stayed confined.
        want = {"exit": 0, "restarted": True, "ranAsRoot": False,
                "credentialsOnly": True, "credentialChanged": True,
                "tokenReached": True}
        got = {k: cs.get(k) for k in want}
        if any(got[k] is not v if isinstance(v, bool) else got[k] != v
               for k, v in want.items()):
            return "credentialSwitch %r, expected %r" % (got, want)
        lc = rec.get("liveCrossCheck")
        if not isinstance(lc, dict):
            return "liveCrossCheck not recorded"
        if (lc.get("started") is not False or lc.get("ranAsRoot") is not False
                or lc.get("exit") in (0, None)):
            return "liveCrossCheck %r, expected refused, not started, not root" % (
                {k: lc.get(k) for k in ("exit", "started", "ranAsRoot")})
    return None


def classify(cell, rec):
    """(as_expected, kind, why) for ``cell`` and its gate record ``rec``."""
    kind = kind_of(cell)
    if kind not in EXPECT:
        return (False, kind, "no expectation for kind " + kind)
    gate, want, _ = EXPECT[kind]
    if rec.get("gate") != gate:
        return (False, kind, "gate %r, expected %r" % (rec.get("gate"), gate))
    base = "%s-%s" % (base_of(cell), rec.get("arch"))
    if rec.get("base") != base:
        return (False, kind, "base %r, expected %r" % (rec.get("base"), base))
    why = build_mismatch(kind, rec)
    if why:
        return (False, kind, why)
    verdict = rec.get("verdict", "missing")
    if verdict != want:
        return (False, kind, "verdict %s, expected %s" % (verdict, want))
    if want == "green":
        why = green_incomplete(kind, rec)
        if why:
            return (False, kind, why)
    if not on_target_rec(kind, rec):
        return (False, kind, "not red (or green) for its own reason: the "
                "target step or the evidence the record must carry is missing")
    return (True, kind, "as expected")


def engine_build_from_derivation(engine, deriver, text):
    """The engine build recorded in ``nix derivation show <deriver>``'s
    output ``text``: ``{"closure", "deriver", "mutation", "testSeams"}``, or
    ``{"closure", "deriver", "error"}`` when it cannot be read or is not the
    derivation of ``engine``. Both output shapes: Nix >= 2.32's
    ``{"version": N, "derivations": {"<name>.drv": ...}}`` with output paths
    by base name, and the older ``{"/nix/store/<name>.drv": ...}`` with full
    paths (https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-derivation-show)."""
    out = {"closure": engine, "deriver": deriver}
    try:
        j = json.loads(text)
        drvs = j["derivations"] if "derivations" in j else j
        body = (drvs.get(deriver) or drvs.get(os.path.basename(deriver))
                if len(drvs) != 1 else next(iter(drvs.values())))
        paths = [os.path.basename(o.get("path", ""))
                 for o in body["outputs"].values()]
        env = body["env"]
    except (ValueError, KeyError, TypeError, AttributeError, StopIteration) as e:
        out["error"] = "unreadable derivation: %s" % e
        return out
    if os.path.basename(engine.rstrip("/")) not in paths:
        out["error"] = "the deriver's outputs %r do not include the engine" % paths
        return out
    out["mutation"] = env.get("REPRO_ADDON_MUTATION", "")
    out["testSeams"] = env.get("REPRO_ADDON_TEST_SEAMS", "") == "1"
    return out


def _run(argv):
    return subprocess.run(argv, capture_output=True, text=True,
                          check=True).stdout


def resolve_engine_build(engine, run=_run):
    """The build of the engine closure ``engine``, from its derivation (see
    ``engine_build_from_derivation``). ``run(argv) -> stdout`` runs a
    command; any failure is returned as ``error``, never raised."""
    try:
        deriver = run(["nix-store", "-q", "--deriver", engine]).strip()
        if not deriver.endswith(".drv"):
            return {"closure": engine, "error": "no deriver: %r" % deriver}
        text = run(["nix", "--extra-experimental-features", "nix-command",
                    "derivation", "show", deriver])
    except (OSError, subprocess.CalledProcessError) as e:
        return {"closure": engine, "error": "derivation lookup failed: %s" % e}
    return engine_build_from_derivation(engine, deriver, text)


def reconcile_engine_build(rec, resolve=resolve_engine_build):
    """``rec`` with its ``engineBuild`` checked against the engine closure it
    names, read from that closure's derivation (``resolve``). The derivation
    is the authority: a record that lacks ``engineBuild`` (one written before
    the gates recorded it) gets the resolved one, and a record whose
    ``engineBuild`` disagrees with it has its ``engineBuild`` replaced by an
    ``error`` saying so, which ``classify`` rejects. When the closure cannot
    be resolved here (collected from this store, or no ``nix``), a recorded
    ``engineBuild`` is kept: the gate read it from the same derivation while
    the closure existed. Returns ``rec``."""
    engine = rec.get("engine")
    if not engine:
        return rec
    resolved = resolve(engine)
    recorded = rec.get("engineBuild")
    if "error" in resolved:
        if recorded is None:
            rec["engineBuild"] = resolved
            rec["engineBuild"]["resolvedFrom"] = "the record's engine closure"
        return rec
    if recorded is None:
        rec["engineBuild"] = resolved
        rec["engineBuild"]["resolvedFrom"] = "the record's engine closure"
        return rec
    keys = ("closure", "mutation", "testSeams")
    if not isinstance(recorded, dict) or any(
            recorded.get(k) != resolved.get(k) for k in keys):
        rec["engineBuild"] = {
            "closure": engine,
            "error": "the recorded engineBuild %r disagrees with the engine "
                     "closure's derivation %r" % (
                         {k: recorded.get(k) for k in keys}
                         if isinstance(recorded, dict) else recorded,
                         {k: resolved.get(k) for k in keys})}
    return rec


def main(argv):
    if len(argv) == 2 and argv[1] == "--table":
        print(json.dumps({"expect": EXPECT, "target": TARGET,
                          "altTargets": ALT_TARGETS, "build": BUILD,
                          "green": GREEN,
                          "adoptEverySwitchSteps": ADOPT_EVERY_SWITCH_STEPS},
                         indent=1))
        return 0
    if len(argv) != 3:
        print(__doc__)
        return 2
    with open(argv[2]) as f:
        rec = json.load(f)
    rec = reconcile_engine_build(rec)
    ok, kind, why = classify(argv[1], rec)
    print("%s %s %s: %s" % ("OK" if ok else "UNEXPECTED", argv[1], kind, why))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
