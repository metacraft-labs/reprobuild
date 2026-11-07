"""The Nim 2.2.4 lane refuses a suite name that names none of its suites,
and an empty selection, instead of running nothing and reporting green
(reprobuild-pm issue 2026-11-08-nim224-lane-reports-green-for-an-unknown-
suite-and-does-not-hold-the-simulator).

The real script runs with ``NIM224_LANE_SELECT_ONLY=1``, which stops it
after the selection, before it resolves Nim or builds anything.

Falsifier: ``NIM224_LANE_MUTATION=unknown-suite-runs-nothing`` (the
selection as before round 5) turns the two refusal cases red; run them with
``A11_LANE_FALSIFIER=1``.

Mocks: none -- the real script; only its build half is not reached.
"""
import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LANE = os.path.join(ROOT, "scripts", "run_nim224_lane.sh")


def lane(*args):
    env = dict(os.environ, NIM224_LANE_SELECT_ONLY="1")
    if os.environ.get("A11_LANE_FALSIFIER") == "1":
        env["NIM224_LANE_MUTATION"] = "unknown-suite-runs-nothing"
    return subprocess.run(["bash", LANE, *args], cwd=ROOT, env=env,
                          capture_output=True, text=True)


class LaneSelection(unittest.TestCase):
    def test_an_unknown_suite_is_refused(self):
        r = lane("t_no_such_suite")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("'t_no_such_suite' is not a lane suite", r.stderr)
        self.assertNotIn("green", r.stdout)

    def test_one_unknown_name_among_known_ones_is_refused(self):
        r = lane("t_addon_review_round4", "t_addon_reveiw_round5")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("'t_addon_reveiw_round5' is not a lane suite", r.stderr)

    def test_a_known_suite_is_selected(self):
        r = lane("t_sim_tls_smoke_pass_stops_its_peers")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual([l for l in r.stdout.splitlines() if l.startswith("selected: ")],
                         ["selected: t_sim_tls_smoke_pass_stops_its_peers"])

    def test_no_argument_selects_every_suite(self):
        r = lane()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        selected = [l for l in r.stdout.splitlines() if l.startswith("selected: ")]
        self.assertIn("selected: t_sim_tls_smoke_pass_stops_its_peers", selected)
        self.assertIn("selected: t_signer_closes_after_its_early_returns", selected)


if __name__ == "__main__":
    unittest.main()
