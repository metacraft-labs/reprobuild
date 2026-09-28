"""Native packages ride in the release and are published by the organisation.

WHY THIS FILE EXISTS

Reprobuild's .deb and .rpm are published into the organisation's shared
repositories, deb.metacraft-labs.com and rpm.metacraft-labs.com, which every
Metacraft product publishes into under one key (metacraft-specs
infrastructure/package-distribution.md §3, §9.1). The release workflow builds
the packages, ships them as ordinary release assets, and then asks
metacraft-labs/metacraft-desktop-packages to add them. It holds neither the
repository key nor the bucket credentials. These cases pin both halves:

  * the packages are part of the release's closed asset set, declared in
    .github/release-platforms.json and derived from a platform that exists;
  * the packages the packager actually builds carry the declared names, and
    install the archive tree INTACT. The archive's launchers exec
    "$(dirname "$0")/../lib/ld-linux-*.so.2". The packages once split bin/ into
    /usr/bin and lib/ into /usr/lib/reprobuild, so the launcher looked for the
    loader in /usr/lib and the installed `repro` exited 127 on every distro.

WHAT IS STUBBED, AND WHY

The packaging cases build from a fixture tarball shaped like the release
archive (bin/ launcher, lib/), not from a real release: a real archive is
tens of megabytes and needs a finished release build. The fixture launcher
honours the same "$(dirname "$0")/../lib" contract as the real one, which is
the property under test. They need dpkg-deb, and are skipped with that reason
when it is absent. The installed-and-run check on real distributions is
tools/multi-distro-harness/tests/m3_install_{apt,dnf,pacman}.sh.
"""

import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RELEASE_YML = REPO_ROOT / ".github" / "workflows" / "release.yml"
PLATFORMS = REPO_ROOT / ".github" / "release-platforms.json"
PACKAGER = REPO_ROOT / "scripts" / "release" / "repro-build-packages.sh"
VERSION = "9.8.7"


def _spec():
    return json.loads(PLATFORMS.read_text(encoding="utf-8"))


class ReleaseWiringTests(unittest.TestCase):
    def test_release_dispatches_to_the_organisation_publisher(self):
        text = RELEASE_YML.read_text(encoding="utf-8")
        self.assertIn(
            "repos/metacraft-labs/metacraft-desktop-packages/dispatches", text
        )
        self.assertIn("event_type=publish-release", text)
        self.assertIn("client_payload[tag]=", text)

    def test_release_does_not_publish_repositories_itself(self):
        """The key and the buckets belong to the organisation's publisher."""
        text = RELEASE_YML.read_text(encoding="utf-8")
        self.assertIn("metacraft-desktop-packages", text)
        self.assertNotIn("repro-publish-repos.sh", text)
        self.assertNotIn("REPRO_PUBLISH_TARGET", text)

    def test_packages_are_built_before_the_asset_set_is_asserted(self):
        """Built after it, they would be refused as unexpected assets."""
        text = RELEASE_YML.read_text(encoding="utf-8")
        build = text.index("- name: Build native packages from the release archives")
        assert_ = text.index("- name: Assert the complete, expected asset set is present")
        sums = text.index("- name: Build SHA256SUMS")
        self.assertLess(build, assert_)
        self.assertLess(assert_, sums)


class DeclaredPackagesTests(unittest.TestCase):
    def test_packages_are_declared(self):
        ecosystems = {p["ecosystem"] for p in _spec().get("packages", [])}
        self.assertEqual({"deb", "rpm"}, ecosystems)

    def test_every_package_builds_from_a_platform_in_the_release(self):
        spec = _spec()
        platforms = {f"{p['platform']}-{p['arch']}" for p in spec["platforms"]}
        for pkg in spec["packages"]:
            self.assertIn(pkg["from"], platforms, pkg)
            self.assertIn("{version}", pkg["asset"], pkg)


@unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb is not installed")
class PackagerOutputTests(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="repro-pkg-"))
        self.addCleanup(shutil.rmtree, self.work, True)
        top = f"reprobuild-{VERSION}-linux-x86_64"
        root = self.work / top
        (root / "bin").mkdir(parents=True)
        (root / "lib").mkdir()
        launcher = root / "bin" / "repro"
        launcher.write_text(
            '#!/bin/sh\n'
            'here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
            'exec cat "$here/../lib/marker"\n',
            encoding="utf-8",
        )
        launcher.chmod(0o755)
        real = root / "bin" / ".repro.real"
        real.write_text("real binary stand-in\n", encoding="utf-8")
        real.chmod(0o755)
        (root / "bin" / "macro_sourcemap_repro.json").write_text("{}\n", encoding="utf-8")
        (root / "lib" / "marker").write_text("ran\n", encoding="utf-8")
        self.tarball = self.work / f"{top}.tar.gz"
        with tarfile.open(self.tarball, "w:gz") as tf:
            tf.add(root, arcname=top)
        self.out = self.work / "out"

    def build(self, ecosystem):
        return subprocess.run(
            ["sh", str(PACKAGER), "--version", VERSION, "--tarball", str(self.tarball),
             "--out", str(self.out), "--ecosystem", ecosystem,
             "--platform", "linux", "--asset-arch", "x86_64"],
            capture_output=True, text=True, check=False,
        )

    def test_deb_carries_the_declared_name(self):
        run = self.build("deb")
        self.assertEqual(0, run.returncode, run.stderr)
        declared = next(p["asset"] for p in _spec()["packages"] if p["ecosystem"] == "deb")
        self.assertTrue((self.out / declared.replace("{version}", VERSION)).is_file(),
                        sorted(os.listdir(self.out)))

    def test_deb_installs_the_archive_tree_intact_with_path_wrappers(self):
        run = self.build("deb")
        self.assertEqual(0, run.returncode, run.stderr)
        deb = next(self.out.glob("*.deb"))
        root = self.work / "installed"
        subprocess.run(["dpkg-deb", "-x", str(deb), str(root)], check=True)
        tree = root / "usr" / "lib" / "reprobuild"
        # The launcher and what it execs stay side by side.
        self.assertTrue((tree / "bin" / "repro").is_file())
        self.assertTrue((tree / "bin" / ".repro.real").is_file())
        self.assertTrue((tree / "lib" / "marker").is_file())
        # PATH gets the public command, and nothing else from bin/.
        on_path = sorted(os.listdir(root / "usr" / "bin"))
        self.assertEqual(["repro"], on_path)
        wrapper = (root / "usr" / "bin" / "repro").read_text(encoding="utf-8")
        self.assertIn("exec /usr/lib/reprobuild/bin/repro", wrapper)
        # Run the installed launcher from its installed place: it must find
        # its lib/ where the archive put it.
        ran = subprocess.run([str(tree / "bin" / "repro")], capture_output=True,
                             text=True, check=False)
        self.assertEqual(0, ran.returncode, ran.stderr)
        self.assertEqual("ran\n", ran.stdout)


if __name__ == "__main__":
    unittest.main()
