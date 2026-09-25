"""Real shell subprocesses exercise wrapper presence checks; no mocked process.

The fixture is a makeWrapper-format executable shell wrapper. The production
transform is also checked against a real installed Nix wrapper in the campaign.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/mark_wrapper_defaults.py"
spec = importlib.util.spec_from_file_location("wrapper_provenance", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WrapperDefaultProvenance(unittest.TestCase):
    def run_wrapper(self, supplied):
        with tempfile.TemporaryDirectory() as root:
            wrapper = Path(root) / "wrapper"
            wrapper.write_text(module.mark_defaults(
                "#!/bin/sh\nexport FIXTURE=${FIXTURE-'path with spaces'}\nexec \"$@\"\n"))
            env = os.environ.copy()
            env.pop("FIXTURE", None)
            env.pop("REPRO_BOOTSTRAP_SOURCE_ENV", None)
            env.update(supplied)
            return json.loads(subprocess.check_output([
                "sh", str(wrapper), sys.executable, "-c",
                "import json,os; print(json.dumps([os.getenv('FIXTURE'),"
                "os.getenv('REPRO_BOOTSTRAP_SOURCE_ENV')]))"], env=env, text=True))

    def test_added_default_has_exact_value_provenance(self):
        value, marker = self.run_wrapper({})
        self.assertEqual(value, "path with spaces")
        self.assertEqual(bytes.fromhex(marker.strip().split("=", 1)[1]).decode(), value)

    def test_explicit_values_including_empty_are_preserved_and_unmarked(self):
        for value in ["", "override", "path with spaces"]:
            self.assertEqual(self.run_wrapper({"FIXTURE": value}), [value, None])

    def test_unrecognised_wrapper_refuses_instead_of_omitting_provenance(self):
        with self.assertRaises(ValueError):
            module.mark_defaults("#!/bin/sh\nexec program\n")


if __name__ == "__main__":
    unittest.main()
