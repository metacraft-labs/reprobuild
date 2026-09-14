"""A live Nix helper must not retain its launcher's operation locks or pipes."""

import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time
import unittest

if os.name == "posix":
    import fcntl
    import resource


DAEMON = Path(__file__).resolve().parents[2] / "tools/reprobuild-nix-daemon/reprobuild-nix-daemon"
LOWER_LIMIT = """import os, resource, sys
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (64, hard))
os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
"""


@unittest.skipUnless(os.name == "posix", "Nix provisioning requires a POSIX host")
class DaemonDescriptors(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="repro-nix-fds-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def stop(self, process):
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)

    def start(self, descriptors=(), lower_limit=False):
        endpoint = self.root / "daemon.sock"
        args = [sys.executable]
        if lower_limit:
            args += ["-c", LOWER_LIMIT]
        args += [str(DAEMON), "--socket-path", str(endpoint), "--idle-exit-ms=30000"]
        process = subprocess.Popen(args, cwd=self.root, pass_fds=descriptors,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        self.addCleanup(self.stop, process)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                _, error = process.communicate()
                self.fail("daemon exited before readiness: " + error.decode(errors="replace"))
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(2)
                    client.connect(str(endpoint))
                    client.sendall(b'{"action":"descriptor-readiness"}\n')
                    with client.makefile("rb") as response:
                        self.assertEqual(json.loads(response.readline()),
                                         {"status": "error", "error": "unsupported action"})
                    return process
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.01)
        self.fail("daemon did not bind its socket")

    def test_releases_inherited_file_lock_while_alive(self):
        path = self.root / "operation.lock"
        with path.open("w+b") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process = self.start((owner.fileno(),))
        with path.open("r+b") as next_owner:
            fcntl.flock(next_owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertIsNone(process.poll(), "release must not depend on daemon exit")

    def assert_pipe_released(self, high_descriptor):
        read_fd, write_fd = os.pipe()
        try:
            if high_descriptor:
                if resource.getrlimit(resource.RLIMIT_NOFILE)[0] <= 128:
                    self.skipTest("test requires room for descriptor 128")
                duplicate = fcntl.fcntl(write_fd, fcntl.F_DUPFD, 128)
                os.close(write_fd)
                write_fd = duplicate
                self.assertGreaterEqual(write_fd, 128)
            process = self.start((write_fd,), lower_limit=high_descriptor)
            os.close(write_fd)
            write_fd = None
            readable, _, _ = select.select([read_fd], [], [], 1)
            self.assertEqual(readable, [read_fd], "inherited writer prevents pipe EOF")
            self.assertEqual(os.read(read_fd, 1), b"")
            self.assertIsNone(process.poll(), "EOF must not depend on daemon exit")
        finally:
            os.close(read_fd)
            if write_fd is not None:
                os.close(write_fd)

    def test_releases_inherited_pipe_writer_while_alive(self):
        self.assert_pipe_released(False)

    def test_releases_descriptor_above_lowered_soft_limit(self):
        self.assert_pipe_released(True)

    def test_standard_output_and_error_remain_usable(self):
        help_result = subprocess.run([sys.executable, str(DAEMON), "--help"],
                                     capture_output=True, timeout=5)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn(b"--socket-path", help_result.stdout)
        error_result = subprocess.run([sys.executable, str(DAEMON), "--unknown-option"],
                                      capture_output=True, timeout=5)
        self.assertEqual(error_result.returncode, 2)
        self.assertIn(b"unrecognized arguments", error_result.stderr)


if __name__ == "__main__":
    unittest.main()
