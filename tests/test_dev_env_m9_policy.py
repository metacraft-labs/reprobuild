#!/usr/bin/env python3
import pathlib
import re
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
DEV_ENV_TEST_DIR = REPO / "tests" / "e2e" / "dev-env"
WORKFLOW_DIR = REPO / ".github" / "workflows"
RUN_TESTS = REPO / "scripts" / "run_tests.sh"
JUSTFILE = REPO / "Justfile"


def text(path):
    return path.read_text(encoding="utf-8")


class DevEnvM9PolicyTest(unittest.TestCase):
    def test_integration_dev_env_no_ignored_tests(self):
        forbidden = [
            re.compile(r"\bskip\s*\("),
            re.compile(r"\bignored?\b", re.IGNORECASE),
            re.compile(r"\bdisabled\b", re.IGNORECASE),
            re.compile(r"platform\s+N/A", re.IGNORECASE),
            re.compile(r"platform-skip", re.IGNORECASE),
            re.compile(r"\bcheck\s+true\b"),
        ]
        failures = []
        for path in sorted(DEV_ENV_TEST_DIR.glob("t*.nim")):
            for lineno, line in enumerate(text(path).splitlines(), 1):
                for pattern in forbidden:
                    if pattern.search(line):
                        failures.append(
                            f"{path.relative_to(REPO)}:{lineno}: {line.strip()}"
                        )
        self.assertEqual(
            [],
            failures,
            "dev-env positive-path gates must not hide coverage with skips, "
            "dummy passes, or platform-N/A branches",
        )

    def test_dev_env_milestone_gates_are_present(self):
        required = {
            "e2e_provider_dev_env_introspection_fixture":
                "tests/e2e/dev-env/t_e2e_provider_dev_env_introspection.nim",
            "integration_dev_env_artifact_ssz_round_trip":
                "tests/integration/t_dev_env_artifact.nim",
            "e2e_dev_env_edge_noop_reuses_cached_artifact":
                "tests/e2e/dev-env/t_e2e_dev_env_edge_cache.nim",
            "e2e_repro_exec_uses_cached_dev_env_artifact":
                "tests/e2e/dev-env/t_e2e_repro_exec_shell.nim",
            "e2e_hooks_shell_direnv_real_activation":
                "tests/e2e/dev-env/t_e2e_hooks_shell_direnv.nim",
            "e2e_native_shell_hooks_bash_zsh_fish":
                "tests/e2e/dev-env/t_e2e_native_shell_hooks.nim",
            "e2e_develop_override_rebinds_dev_env":
                "tests/e2e/dev-env/t_e2e_develop_overrides_activity.nim",
            "e2e_repro_up_down_supervises_real_services":
                "tests/e2e/dev-env/t_e2e_repro_dev_sessions.nim",
            "benchmark_dev_env_activation_noop":
                "tests/e2e/dev-env/t_e2e_dev_env_performance_gates.nim",
            "benchmark_dev_env_activation_changed_inputs":
                "tests/e2e/dev-env/t_e2e_dev_env_performance_gates.nim",
        }
        for test_name, relpath in required.items():
            source = text(REPO / relpath)
            self.assertIn(test_name, source,
                          f"{test_name} missing from {relpath}")

    def test_full_suite_gate_keeps_relevant_components_in_scope(self):
        run_tests = text(RUN_TESTS)
        justfile = text(JUSTFILE)
        self.assertIn("bash ./scripts/run_tests.sh", justfile)
        self.assertIn("dev-env-full-regression:", justfile)
        self.assertIn("find tests -type f -name 'test_*.py'", run_tests)
        self.assertIn("find tests -type f -name 't*.nim'", run_tests)
        self.assertIn("find libs -path '*/tests/t*.nim'", run_tests)

        required_component_globs = {
            "provider": ["tests/e2e/dev-env/t_e2e_provider_dev_env_introspection.nim"],
            "build engine": ["tests/e2e/local-build-engine/t_e2e_*.nim"],
            "monitoring": ["tests/e2e/dev-env/t_e2e_dev_env_edge_cache.nim"],
            "tool profiles": ["tests/e2e/path-only/t_path_only_tool_interfaces.nim"],
            "home resources": ["tests/e2e/home-resources/t_*.nim"],
            "hooks": [
                "tests/e2e/dev-env/t_e2e_hooks_shell_direnv.nim",
                "tests/e2e/dev-env/t_e2e_native_shell_hooks.nim",
            ],
            "CLI activation": ["tests/e2e/dev-env/t_e2e_repro_exec_shell.nim"],
        }
        missing = []
        for component, globs in required_component_globs.items():
            if not any(list(REPO.glob(pattern)) for pattern in globs):
                missing.append(component)
        self.assertEqual([], missing)

        selected_by_full_runner = {
            path.relative_to(REPO).as_posix()
            for pattern in ("tests/test_*.py", "tests/t*.nim", "libs/**/tests/t*.nim")
            for path in REPO.glob(pattern)
        }
        # scripts/run_tests.sh searches recursively under tests/ and libs/.
        selected_by_full_runner.update(
            path.relative_to(REPO).as_posix()
            for path in (REPO / "tests").rglob("test_*.py")
        )
        selected_by_full_runner.update(
            path.relative_to(REPO).as_posix()
            for path in (REPO / "tests").rglob("t*.nim")
        )
        selected_by_full_runner.update(
            path.relative_to(REPO).as_posix()
            for path in (REPO / "libs").glob("**/tests/t*.nim")
        )

        required_paths = {
            path
            for globs in required_component_globs.values()
            for pattern in globs
            for path in (match.relative_to(REPO).as_posix()
                         for match in REPO.glob(pattern))
        }
        missing_from_runner = sorted(required_paths - selected_by_full_runner)
        self.assertEqual([], missing_from_runner)

    def test_ci_and_runner_do_not_suppress_dev_env_gates(self):
        run_tests = text(RUN_TESTS)
        justfile = text(JUSTFILE)
        workflows = {
            path.relative_to(REPO).as_posix(): text(path)
            for path in sorted(WORKFLOW_DIR.glob("*.yml"))
        }
        workflows.update({
            path.relative_to(REPO).as_posix(): text(path)
            for path in sorted(WORKFLOW_DIR.glob("*.yaml"))
        })

        self.assertTrue(workflows, "CI workflow files are required")
        self.assertIn("just test", "\n".join(workflows.values()))
        self.assertIn("bash ./scripts/run_tests.sh", justfile)
        self.assertIn("set -euo pipefail", run_tests)

        suspicious = []
        checked_files = {
            "scripts/run_tests.sh": run_tests,
            "Justfile": justfile,
            **workflows,
        }
        dev_env_suppression = re.compile(
            r"(dev[-_]?env|tests/e2e/dev-env).*(skip|ignore|disable|exclude|"
            r"prune|if:\s*false|continue-on-error)",
            re.IGNORECASE,
        )
        global_suppression = re.compile(
            r"(SKIP_DEV_ENV|DEV_ENV_TESTS\s*[:=]\s*0|REPRO.*SKIP.*DEV_ENV)",
            re.IGNORECASE,
        )
        for name, source in checked_files.items():
            for lineno, line in enumerate(source.splitlines(), 1):
                if dev_env_suppression.search(line) or global_suppression.search(line):
                    suspicious.append(f"{name}:{lineno}: {line.strip()}")
        self.assertEqual(
            [],
            suspicious,
            "CI and full-suite runners must not hide dev-env gates with "
            "dev-env-specific skip/exclude/ignore controls",
        )


if __name__ == "__main__":
    unittest.main()
