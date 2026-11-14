"""The A13 verdict classifier judges a record by the cell it was run for.

WHAT IS UNDER TEST
==================

``scripts/addon_a13_classify.py``: ``classify(cell, record)`` decides whether
an A13 add-on VM gate cell's record is what the cell must show. It is the
verdict behind every "as expected" cell of the A13 measurement records.
reprobuild-pm issue
``2026-11-14-addon-a13-classifier-accepts-another-gates-record-and-an-empty-green-one``
found that it compared only the verdict and, for some kinds, the red step:

* a green record with no steps was "as expected" for every green kind
  without its own evidence branch (adopt, confirm, floorupgrade, ...);
* a conversion-gate record of debian-12 was "as expected" for
  ``adopt-ubuntu-24.04`` and for any ``conv-<base>``: the record's ``gate``
  and ``base`` were never read;
* an adopt record with its every-switch and live-cross-check steps and
  fields deleted was still green "as expected";
* a red single-target cell was "as expected" for any record red at the
  target step, whatever add-on build, gate-level mutation or engine build
  produced it (the engine's build was not in the record at all).

These cases pin each of those, and the fixes' own edges: the base's
architecture suffix, a record that names an engine closure whose build is
unknown, a green record with a red or ``exception`` step, the seam builds,
a gate that reads ``REPRO_A13_MUTATION`` but whose record does not say what
it was, and the parser for ``nix derivation show`` in both its output
shapes. Positive controls -- a well-formed record of every green kind and of
a sample of red kinds -- are accepted, so no rejection here can come from a
classifier that rejects everything.

FIXTURES, JUSTIFIED
===================

The records are synthetic, built in this file. The real gate records (in
``build/addon-gates/records``) carry workstation paths, guest logs of
several megabytes and the run's store paths, and this repository is public,
so none is committed. Each synthetic record has the fields and steps the
gate writes (names taken from the gates' sources and from the round-7 green
records at 757b04f116), filler steps to reach the gate's step count, and
nothing else. No mock replaces the classifier: its module is imported and
its CLI runs as a subprocess. The engine-build resolver's ``nix`` calls are
replaced by canned ``nix derivation show`` output, because a unit test must
not depend on a particular store path existing on the host; the parser is
the code under test there, and the real resolution is exercised by
re-classifying the round-7 records (reprobuild-pm Measurements).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "addon_a13_classify.py"


def load_classifier():
    spec = importlib.util.spec_from_file_location("addon_a13_classify", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cls = load_classifier()

ADOPT = "e2e_addon_adopt_hand_configured_service"
CONV = "e2e_addon_to_reproos_conversion_keeps_state"
TICK = "e2e_addon_tick_observes_a_fresh_cycle"
HARDRESET = "e2e_addon_hard_reset_at_every_step"
ENGINE = "/nix/store/00000000000000000000000000000000-reprobuild-test"

ADOPT_EVERY_SWITCH_STEPS = [
    "switch 1 of the updated profile succeeds and keeps the edit",
    "switch 2 of the updated profile succeeds and keeps the edit",
    "the add-on switch refuses a unit systemd loaded unconfined, and it "
    "never starts (held through the revert)",
    "after the generator and the manifest are gone, the switch succeeds",
    "a confined service that depends_on a file is applied and runs "
    "confined, carried state on the host",
    "the operator's reload left systemd's loaded definition running the "
    "service as root (the case's premise)",
    "a switch that changes only a file the service depends_on judges it as "
    "systemd loads it before restarting it: it never runs as root",
    "after the manifest is gone, the switch back to the skeleton succeeds",
]


def ok(name):
    return {"step": name, "ok": True, "detail": ""}


def red(name, detail=""):
    return {"step": name, "ok": False, "detail": detail}


def padded(named, count, last):
    """``named`` steps, filler up to ``count`` steps, ``last`` at the end."""
    steps = [ok(n) for n in named]
    while len(steps) < count - 1:
        steps.append(ok("filler step %d" % len(steps)))
    steps.append(ok(last))
    return steps


def base_record(gate, base="debian-13", arch="amd64", mutation="",
                gate_mutation="", engine=None, engine_mutation="",
                seams=False, with_gate_mutation=True):
    rec = {"gate": gate, "base": base + "-" + arch, "arch": arch,
           "backend": "qemu", "mutation": mutation}
    if with_gate_mutation:
        rec["gateMutation"] = gate_mutation
    if engine:
        rec["engine"] = engine
        rec["engineBuild"] = {"closure": engine, "mutation": engine_mutation,
                              "testSeams": seams}
    return rec


def conv_probes():
    labels = cls.ROUND4_PROBES + cls.ROUND5_PROBES + cls.ROUND6_PROBES
    probes = {l: {"judged": True, "refusedForReason": True} for l in labels}
    probes["hostControl"] = {"judged": True, "exit": 0, "ran": True}
    return probes


def green(kind, base="debian-13"):
    """A well-formed green record of ``kind``, as its gate writes one."""
    if kind == "adopt":
        rec = base_record(ADOPT, base)
        rec["steps"] = padded(ADOPT_EVERY_SWITCH_STEPS, 48,
                              "after the rollback the state directories are "
                              "unchanged")
        rec["everySwitch"] = {"exit": 0, "restarted": True, "ranAsRoot": False,
                              "loadedUserBefore": "root"}
        rec["liveCrossCheck"] = {"exit": 1, "started": False,
                                 "ranAsRoot": False}
        rec["revertStepReached"] = True
    elif kind in ("conv", "convseam"):
        rec = base_record(CONV, base, engine=ENGINE,
                          seams=(kind == "convseam"))
        if kind == "conv":
            rec["steps"] = padded([], 68, "a carried unit does not start at "
                                  "boot while its restore fails")
            rec["roundFourProbes"] = conv_probes()
            rec["decision79"] = {"target": {"ran": True},
                                 "socket": {"ran": True}}
            rec["orderingCheck"] = "not run: the product engine carries no seam"
        else:
            rec["steps"] = padded([], 37, "a carried unit without default "
                                  "dependencies waits for the restore (held "
                                  "at its seam) and does not start when it "
                                  "fails")
            rec["orderingCheck"] = "run (engine seam build)"
    elif kind == "confirm":
        rec = base_record("e2e_addon_confirm_or_revert", base,
                          with_gate_mutation=False)
        rec["steps"] = padded([], 28, "uninstall")
    elif kind == "floorupgrade":
        rec = base_record("e2e_addon_floor_upgrade_keeps_installed_generations",
                          base, with_gate_mutation=False)
        rec["steps"] = padded([], 24, "and its service serves page-prefloor")
    elif kind == "hardreset":
        rec = base_record(HARDRESET, base, with_gate_mutation=False)
        rec["steps"] = padded(
            ["receipt receipt-before-rename: after the reset the receipt is "
             "the old one",
             "receipt receipt-before-dir-fsync: after the reset the receipt "
             "is the old one or the new one"], 181, "uninstall")
        rec["testSeams"] = True
    elif kind == "refused":
        rec = base_record("e2e_addon_refused_recovery_keeps_its_record", base,
                          with_gate_mutation=False)
        rec["steps"] = padded([], 26, "uninstall")
    elif kind == "tickctl":
        rec = base_record(TICK, base, with_gate_mutation=False)
        rec["variant"] = ""
        rec["steps"] = padded([], 6, "the file holds sequence 3's content")
    elif kind == "agente2e":
        rec = base_record("e2e_addon_agent_end_to_end", base)
        rec["steps"] = padded([], 17, "the sequence floor is 4")
    elif kind == "validator":
        rec = base_record("e2e_addon_validator_never_double_signs", base,
                          engine=ENGINE)
        # Its gateMutation is its own REPRO_A12_MUTATION; tickUnits's
        # REPRO_A13_MUTATION is a13GateMutation.
        rec["a13GateMutation"] = ""
        rec["steps"] = padded([], 32, "positive control: a second database's "
                              "real double sign is found")
    elif kind == "parity":
        rec = base_record("e2e_addon_reproos_service_parity", base,
                          engine=ENGINE)
        rec["steps"] = padded([], 59, "the add-on guest's re-assert "
                              "materialises the token and starts the failed "
                              "vaultwarden again")
    else:
        raise KeyError(kind)
    rec["verdict"] = "green"
    return rec


def red_record(kind, base="debian-13"):
    """A well-formed red record of ``kind``, from the build its cell names."""
    if kind == "mutexec":
        rec = base_record(CONV, base, engine=ENGINE,
                          engine_mutation="exec-first-command-only")
        probes = conv_probes()
        probes["r6exec"] = {"judged": True, "exit": 0, "ran": True}
        rec["roundFourProbes"] = probes
        rec["steps"] = [ok("bootstrap"),
                        red("round 6, exec: refused while the directory is "
                            "pending"),
                        red("stopped at the first red step under the mutation")]
    elif kind == "mutimport":
        rec = base_record(ADOPT, base, mutation="import-writes-skeleton")
        rec["steps"] = [ok("bootstrap"),
                        red("import wrote nothing (fingerprint identical)")]
    elif kind == "mutstate":
        rec = base_record(ADOPT, base, gate_mutation="converge-touches-state")
        rec["steps"] = [ok("bootstrap"),
                        red("alertmanager's state directory is byte-identical "
                            "across the converge")]
    elif kind == "mutunordered":
        rec = base_record(CONV, base, engine=ENGINE,
                          engine_mutation="restore-unordered", seams=True)
        rec["steps"] = [ok("bootstrap"),
                        red("a carried unit without default dependencies "
                            "waits for the restore (held at its seam) and "
                            "does not start when it fails")]
    elif kind == "tickold":
        rec = base_record(TICK, base, with_gate_mutation=False)
        rec["variant"] = "tick-joins-in-flight"
        rec["steps"] = [ok("bootstrap"),
                        red("the tick observes a fresh cycle, which applies "
                            "sequence 3")]
    elif kind == "mutreceipt":
        rec = base_record(HARDRESET, base, mutation="receipt-no-fsync",
                          with_gate_mutation=False)
        rec["steps"] = [
            ok("receipt receipt-before-rename: after the reset the receipt is "
               "the old one"),
            red("receipt receipt-before-dir-fsync: after the reset the receipt "
                "is the old one or the new one", "on disk (0 bytes)")]
    else:
        raise KeyError(kind)
    rec["verdict"] = "red"
    return rec


GREEN_KINDS = ["adopt", "conv", "convseam", "confirm", "floorupgrade",
               "hardreset", "refused", "tickctl", "agente2e", "validator",
               "parity"]
RED_KINDS = ["mutexec", "mutimport", "mutstate", "mutunordered", "tickold",
             "mutreceipt"]


class Accepts(unittest.TestCase):
    """Positive controls: the classifier is not rejecting everything."""

    def test_every_green_kind(self):
        for kind in GREEN_KINDS:
            with self.subTest(kind=kind):
                self.assertEqual(
                    cls.classify(kind + "-debian-13", green(kind)),
                    (True, kind, "as expected"))

    def test_a_sample_of_red_kinds(self):
        for kind in RED_KINDS:
            with self.subTest(kind=kind):
                self.assertEqual(
                    cls.classify(kind + "-debian-13", red_record(kind)),
                    (True, kind, "as expected"))

    def test_other_bases(self):
        for base in ("debian-12", "ubuntu-24.04"):
            with self.subTest(base=base):
                self.assertTrue(cls.classify("conv-" + base,
                                             green("conv", base))[0])
                self.assertTrue(cls.classify("adopt-" + base,
                                             green("adopt", base))[0])

    def test_a_gate_that_never_reads_the_gate_mutation_may_omit_it(self):
        rec = green("confirm")
        self.assertNotIn("gateMutation", rec)
        self.assertTrue(cls.classify("confirm-debian-13", rec)[0])


class TheIssuesDoctoredInputs(unittest.TestCase):
    """Each input the issue fed the classifier at 757b04f116."""

    def assertRejected(self, cell, rec, *needles):
        ok_, _, why = cls.classify(cell, rec)
        self.assertFalse(ok_, "%s accepted: %s" % (cell, why))
        for n in needles:
            self.assertIn(n, why)

    def test_an_empty_green_record(self):
        for cell in ("adopt-debian-13", "confirm-debian-13",
                     "floorupgrade-debian-13"):
            with self.subTest(cell=cell):
                self.assertRejected(cell, {"verdict": "green", "steps": []})

    def test_a_conversion_record_judged_as_adopt(self):
        self.assertRejected("adopt-ubuntu-24.04", green("conv", "debian-12"),
                            "gate", CONV)

    def test_a_debian_12_record_judged_as_another_base(self):
        self.assertRejected("conv-debian-13", green("conv", "debian-12"),
                            "base", "debian-12-amd64")

    def test_an_adopt_record_without_its_every_switch_case(self):
        rec = green("adopt")
        rec["steps"] = [s for s in rec["steps"]
                        if s["step"] not in ADOPT_EVERY_SWITCH_STEPS]
        del rec["everySwitch"]
        del rec["liveCrossCheck"]
        self.assertRejected("adopt-debian-13", rec)

    def test_an_adopt_record_without_the_every_switch_fields(self):
        for field in ("everySwitch", "liveCrossCheck"):
            with self.subTest(field=field):
                rec = green("adopt")
                del rec[field]
                self.assertRejected("adopt-debian-13", rec, field)

    def test_an_adopt_record_whose_cross_checks_ran_as_root(self):
        for field in ("everySwitch", "liveCrossCheck"):
            with self.subTest(field=field):
                rec = green("adopt")
                rec[field]["ranAsRoot"] = True
                self.assertRejected("adopt-debian-13", rec, field)
        rec = green("adopt")
        rec["liveCrossCheck"]["started"] = True
        self.assertRejected("adopt-debian-13", rec, "liveCrossCheck")

    def test_an_adopt_record_missing_one_every_switch_step(self):
        for name in ADOPT_EVERY_SWITCH_STEPS[:4] + ADOPT_EVERY_SWITCH_STEPS[6:7]:
            with self.subTest(step=name):
                rec = green("adopt")
                rec["steps"] = [s if s["step"] != name else ok("filler")
                                for s in rec["steps"]]
                self.assertRejected("adopt-debian-13", rec)


class TheRecordsBuild(unittest.TestCase):
    """A red cell is red under its own build, not another's."""

    def assertRejected(self, cell, rec, *needles):
        ok_, _, why = cls.classify(cell, rec)
        self.assertFalse(ok_, "%s accepted: %s" % (cell, why))
        for n in needles:
            self.assertIn(n, why)

    def test_an_engine_falsifier_under_another_engine(self):
        for engine_mutation in ("", "unit-lines-continue-as-text"):
            with self.subTest(engine=engine_mutation):
                rec = red_record("mutexec")
                rec["engineBuild"]["mutation"] = engine_mutation
                self.assertRejected("mutexec-debian-13", rec,
                                    "engine", "exec-first-command-only")

    def test_an_add_on_falsifier_under_another_add_on_build(self):
        rec = red_record("mutimport")
        rec["mutation"] = "restore-after-start"
        self.assertRejected("mutimport-debian-13", rec, "mutation",
                            "import-writes-skeleton", "restore-after-start")

    def test_a_record_that_does_not_say_its_add_on_build(self):
        rec = red_record("mutimport")
        del rec["mutation"]
        self.assertRejected("mutimport-debian-13", rec, "mutation")

    def test_a_gate_level_falsifier_under_another_gate_mutation(self):
        rec = red_record("mutstate")
        rec["gateMutation"] = ""
        self.assertRejected("mutstate-debian-13", rec, "gateMutation",
                            "converge-touches-state")
        rec = red_record("tickold")
        rec["variant"] = "tick-skips-idle-wait"
        self.assertRejected("tickold-debian-13", rec, "tick-joins-in-flight")

    def test_a_green_cell_under_a_mutation(self):
        rec = green("tickctl")
        rec["variant"] = "tick-joins-in-flight"
        self.assertRejected("tickctl-debian-13", rec, "tick-joins-in-flight")
        rec = green("adopt")
        rec["mutation"] = "restore-after-start"
        self.assertRejected("adopt-debian-13", rec, "mutation")
        rec = green("conv")
        rec["engineBuild"]["mutation"] = "apply-ignores-carried-state"
        self.assertRejected("conv-debian-13", rec, "engine")

    def test_a_gate_that_reads_the_gate_mutation_must_record_it(self):
        for kind in ("adopt", "agente2e", "validator", "parity", "conv"):
            with self.subTest(kind=kind):
                rec = green(kind)
                del rec["gateMutation"]
                self.assertRejected(kind + "-debian-13", rec, "not recorded")
        rec = green("tickctl")
        del rec["variant"]
        self.assertRejected("tickctl-debian-13", rec, "not recorded")

    def test_the_validator_gates_two_gate_mutations(self):
        # Its gateMutation is REPRO_A12_MUTATION; tickUnits reads
        # REPRO_A13_MUTATION, recorded as a13GateMutation. Both must be
        # recorded, and neither set, for its green cell.
        rec = green("validator")
        del rec["a13GateMutation"]
        self.assertRejected("validator-debian-13", rec, "a13GateMutation",
                            "not recorded")
        rec = green("validator")
        rec["a13GateMutation"] = "tick-joins-in-flight"
        self.assertRejected("validator-debian-13", rec, "tick-joins-in-flight")
        rec = green("validator")
        rec["gateMutation"] = "monitor-sleeps"
        self.assertRejected("validator-debian-13", rec, "gateMutation",
                            "monitor-sleeps")

    def test_an_engine_build_of_another_closure(self):
        rec = red_record("mutexec")
        rec["engineBuild"]["closure"] = ENGINE + "-other"
        self.assertRejected("mutexec-debian-13", rec, "closure")
        rec = red_record("mutexec")
        del rec["engineBuild"]["closure"]
        self.assertRejected("mutexec-debian-13", rec, "closure")

    def test_an_engine_whose_build_is_unknown(self):
        rec = green("conv")
        del rec["engineBuild"]
        self.assertRejected("conv-debian-13", rec, "engineBuild")
        rec = green("conv")
        rec["engineBuild"] = {"closure": ENGINE, "error": "no deriver"}
        self.assertRejected("conv-debian-13", rec, "engineBuild")

    def test_an_engine_cell_whose_record_ran_no_engine(self):
        rec = red_record("mutexec")
        del rec["engine"]
        del rec["engineBuild"]
        self.assertRejected("mutexec-debian-13", rec, "engine")

    def test_the_seam_builds(self):
        rec = green("conv")
        rec["engineBuild"]["testSeams"] = True
        self.assertRejected("conv-debian-13", rec, "testSeams")
        rec = green("convseam")
        rec["engineBuild"]["testSeams"] = False
        self.assertRejected("convseam-debian-13", rec, "testSeams")
        rec = red_record("mutunordered")
        rec["engineBuild"]["testSeams"] = False
        self.assertRejected("mutunordered-debian-13", rec, "testSeams")

    def test_the_base_and_its_architecture(self):
        rec = green("conv")
        rec["base"] = "debian-13-arm64"
        self.assertRejected("conv-debian-13", rec, "base")
        rec = green("conv")
        del rec["base"]
        self.assertRejected("conv-debian-13", rec, "base")


class AGreenRecordIsComplete(unittest.TestCase):

    def assertRejected(self, cell, rec):
        ok_, _, why = cls.classify(cell, rec)
        self.assertFalse(ok_, "%s accepted: %s" % (cell, why))

    def test_a_red_step_in_a_green_record(self):
        for kind in GREEN_KINDS:
            with self.subTest(kind=kind):
                rec = green(kind)
                rec["steps"][3]["ok"] = False
                self.assertRejected(kind + "-debian-13", rec)

    def test_an_exception_step(self):
        for kind in ("conv", "confirm"):
            rec = green(kind)
            rec["steps"].insert(5, {"step": "exception", "ok": True,
                                    "detail": "boom"})
            self.assertRejected(kind + "-debian-13", rec)

    def test_a_truncated_record(self):
        for kind in GREEN_KINDS:
            with self.subTest(kind=kind):
                rec = green(kind)
                rec["steps"] = rec["steps"][:-1]
                self.assertRejected(kind + "-debian-13", rec)

    def test_too_few_steps(self):
        for kind in GREEN_KINDS:
            with self.subTest(kind=kind):
                rec = green(kind)
                rec["steps"] = rec["steps"][-1:]
                self.assertRejected(kind + "-debian-13", rec)


class TheEngineBuildResolver(unittest.TestCase):
    """``nix derivation show`` read in both its output shapes."""

    DRV = "/nix/store/11111111111111111111111111111111-reprobuild-test.drv"

    def drv_body(self, out_path, env):
        return {"outputs": {"out": {"path": out_path}}, "env": env}

    def test_the_current_shape(self):
        text = json.dumps({"version": 4, "derivations": {
            Path(self.DRV).name: self.drv_body(
                Path(ENGINE).name,
                {"REPRO_ADDON_MUTATION": "exec-first-command-only"})}})
        b = cls.engine_build_from_derivation(ENGINE, self.DRV, text)
        self.assertEqual(b["mutation"], "exec-first-command-only")
        self.assertIs(b["testSeams"], False)
        self.assertEqual(b["deriver"], self.DRV)

    def test_the_older_flat_shape(self):
        text = json.dumps({self.DRV: self.drv_body(
            ENGINE, {"REPRO_ADDON_TEST_SEAMS": "1",
                     "REPRO_ADDON_MUTATION": "restore-unordered"})})
        b = cls.engine_build_from_derivation(ENGINE, self.DRV, text)
        self.assertEqual(b["mutation"], "restore-unordered")
        self.assertIs(b["testSeams"], True)

    def test_the_product_engine(self):
        text = json.dumps({self.DRV: self.drv_body(ENGINE, {})})
        b = cls.engine_build_from_derivation(ENGINE, self.DRV, text)
        self.assertEqual((b["mutation"], b["testSeams"]), ("", False))

    def test_a_derivation_of_another_output(self):
        text = json.dumps({self.DRV: self.drv_body(
            "/nix/store/22222222222222222222222222222222-other", {})})
        b = cls.engine_build_from_derivation(ENGINE, self.DRV, text)
        self.assertIn("error", b)
        self.assertNotIn("mutation", b)

    def test_unreadable_output(self):
        b = cls.engine_build_from_derivation(ENGINE, self.DRV, "not json")
        self.assertIn("error", b)
        self.assertNotIn("mutation", b)

    def test_a_failed_lookup_leaves_the_record_unresolved(self):
        def fails(argv):
            raise OSError("no nix here")
        b = cls.resolve_engine_build(ENGINE, run=fails)
        self.assertIn("error", b)
        rec = green("conv")
        rec["engineBuild"] = b
        self.assertFalse(cls.classify("conv-debian-13", rec)[0])


class TheEngineClosureIsTheAuthority(unittest.TestCase):
    """``reconcile_engine_build``: the closure's derivation decides the
    engine build, not a recorded ``engineBuild`` alone."""

    def resolver(self, mutation="", seams=False, error=None):
        def resolve(engine):
            if error:
                return {"closure": engine, "error": error}
            return {"closure": engine, "deriver": "/nix/store/x.drv",
                    "mutation": mutation, "testSeams": seams}
        return resolve

    def test_a_forged_engine_build(self):
        # The record claims the falsifier; the closure is the product engine.
        rec = cls.reconcile_engine_build(red_record("mutexec"),
                                         resolve=self.resolver())
        ok_, _, why = cls.classify("mutexec-debian-13", rec)
        self.assertFalse(ok_, why)
        self.assertIn("disagrees", why)
        # The other way round: a falsifier's closure recorded as the product.
        rec = green("conv")
        rec = cls.reconcile_engine_build(
            rec, resolve=self.resolver("apply-ignores-carried-state"))
        self.assertFalse(cls.classify("conv-debian-13", rec)[0])
        rec = green("convseam")
        rec = cls.reconcile_engine_build(rec, resolve=self.resolver())
        self.assertFalse(cls.classify("convseam-debian-13", rec)[0])

    def test_an_agreeing_engine_build(self):
        rec = cls.reconcile_engine_build(
            red_record("mutexec"),
            resolve=self.resolver("exec-first-command-only"))
        self.assertEqual(cls.classify("mutexec-debian-13", rec),
                         (True, "mutexec", "as expected"))

    def test_an_older_record_without_engine_build(self):
        rec = red_record("mutexec")
        del rec["engineBuild"]
        rec = cls.reconcile_engine_build(
            rec, resolve=self.resolver("exec-first-command-only"))
        self.assertTrue(cls.classify("mutexec-debian-13", rec)[0])
        rec = red_record("mutexec")
        del rec["engineBuild"]
        rec = cls.reconcile_engine_build(rec, resolve=self.resolver())
        self.assertFalse(cls.classify("mutexec-debian-13", rec)[0])

    def test_an_unresolvable_closure(self):
        # A recorded build is kept (the gate read it from the derivation);
        # without one the record is not as expected.
        rec = cls.reconcile_engine_build(
            red_record("mutexec"), resolve=self.resolver(error="gone"))
        self.assertTrue(cls.classify("mutexec-debian-13", rec)[0])
        rec = red_record("mutexec")
        del rec["engineBuild"]
        rec = cls.reconcile_engine_build(rec,
                                         resolve=self.resolver(error="gone"))
        self.assertFalse(cls.classify("mutexec-debian-13", rec)[0])

    def test_a_record_without_an_engine_is_left_alone(self):
        rec = green("adopt")
        def never(engine):
            raise AssertionError("resolved an engine the record does not name")
        self.assertIs(cls.reconcile_engine_build(rec, resolve=never), rec)
        self.assertNotIn("engineBuild", rec)


class TheCommandLine(unittest.TestCase):

    def run_cli(self, cell, rec):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "record.json"
            p.write_text(json.dumps(rec))
            return subprocess.run([sys.executable, str(SCRIPT), cell, str(p)],
                                  capture_output=True, text=True)

    def test_accepts_and_rejects(self):
        r = self.run_cli("adopt-debian-13", green("adopt"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("OK adopt-debian-13", r.stdout)
        r = self.run_cli("adopt-debian-13", {"verdict": "green", "steps": []})
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("UNEXPECTED", r.stdout)

    def test_the_table(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "--table"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        table = json.loads(r.stdout)
        self.assertEqual(table["build"]["mutexec"]["engine"],
                         "exec-first-command-only")
        self.assertIn("adopt", table["green"])


if __name__ == "__main__":
    unittest.main()
