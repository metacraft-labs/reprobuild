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

The fixture archive also carries share/repro/completions/, as the release
archive does. Its scripts are tests/fixtures/release-completions/, which are
the output of a real `repro completion <shell>` (each calls `repro __complete`
and the zsh one starts with `#compdef repro`): the packager copies them and
never reads them, so a real binary's output is the faithful stand-in and no
compiled repro is needed. test_cs_m8a_packages_carry_completion_files builds
the deb, the rpm and the pacman package and needs dpkg-deb, rpmbuild, rpm,
rpm2cpio, cpio and bsdtar; it is skipped, which counts as not passed, when
one is missing. Run it as
  nix shell nixpkgs#dpkg nixpkgs#rpm nixpkgs#cpio nixpkgs#libarchive -c \
    python3 -m unittest tests.unit.test_release_native_packages
"""

import json
import os
import stat
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
COMPLETIONS_FIXTURE = REPO_ROOT / "tests" / "fixtures" / "release-completions"
COMPLETION_SCRIPTS = ("repro.bash", "_repro", "repro.fish", "repro.ps1")
VERSION = "9.8.7"

# Where each package installs each archive script (the zsh directory differs:
# Debian's zsh reads other packages' functions from vendor-completions).
BASH_COMPLETION = "usr/share/bash-completion/completions/repro"
FISH_COMPLETION = "usr/share/fish/vendor_completions.d/repro.fish"
EXPECTED_COMPLETIONS = {
    "deb": {BASH_COMPLETION: "repro.bash",
            "usr/share/zsh/vendor-completions/_repro": "_repro",
            FISH_COMPLETION: "repro.fish"},
    "rpm": {BASH_COMPLETION: "repro.bash",
            "usr/share/zsh/site-functions/_repro": "_repro",
            FISH_COMPLETION: "repro.fish"},
    "arch": {BASH_COMPLETION: "repro.bash",
             "usr/share/zsh/site-functions/_repro": "_repro",
             FISH_COMPLETION: "repro.fish"},
}


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

    def test_packages_are_built_in_the_linux_build_leg_and_uploaded(self):
        """The publish job has no dev environment: `nix` is not on its PATH.

        v0.2.1's first tag run built all three archives and then died in the
        publish job with `nix: command not found`, because packaging had been
        placed there. The build leg runs setup-dev-env, so packaging lives in
        it, and the leg's artifact carries the packages to the publish job.
        """
        text = RELEASE_YML.read_text(encoding="utf-8")
        build_leg = text[text.index("\n  build-release:"):text.index("\n  publish-release:")]
        publish = text[text.index("\n  publish-release:"):]
        step = build_leg.index("- name: Build native packages from this leg's archive")
        upload = build_leg.index("- name: Upload build artifact")
        self.assertLess(step, upload)
        self.assertIn("dev-exec nix shell", build_leg[step:upload])
        for pattern in ("reprobuild_*.deb", "reprobuild-*.rpm"):
            self.assertIn(pattern, build_leg[upload:])
        self.assertNotIn("repro-build-packages.sh", publish)


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


class PackagerFixture(unittest.TestCase):
    """A fixture archive shaped like the release archive, in a fresh temp dir."""

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
        # The RunQuota daemon and CLI every archive carries; runquota's own
        # packages own /usr/bin/runquotad and /usr/bin/runquota.
        for name in ("runquotad", "runquota"):
            stand_in = root / "bin" / name
            stand_in.write_text("#!/bin/sh\n", encoding="utf-8")
            stand_in.chmod(0o755)
        (root / "lib" / "marker").write_text("ran\n", encoding="utf-8")
        # The sources an installed repro compiles recipes against (#428):
        # found at <prefix>/share/repro/source from the binary's location.
        src = root / "share" / "repro" / "source" / "libs" / "repro_interface_artifacts" / "src"
        src.mkdir(parents=True)
        (src / "repro_interface_artifacts.nim").write_text("discard\n", encoding="utf-8")
        (root / "share" / "repro" / "src").mkdir()
        (root / "share" / "repro" / "src" / "sibling.nim").write_text("discard\n", encoding="utf-8")
        # The completion scripts the release leg generates
        # (scripts/release/stage_release_completions.sh).
        completions = root / "share" / "repro" / "completions"
        completions.mkdir()
        for name in COMPLETION_SCRIPTS:
            shutil.copyfile(COMPLETIONS_FIXTURE / name, completions / name)
            (completions / name).chmod(0o644)
        self.archive_root = root
        self.archive_top = top
        self.out = self.work / "out"
        self.pack()

    def pack(self):
        """(Re)write the fixture tarball from the archive tree."""
        self.tarball = self.work / f"{self.archive_top}.tar.gz"
        with tarfile.open(self.tarball, "w:gz") as tf:
            tf.add(self.archive_root, arcname=self.archive_top)

    def build(self, ecosystem):
        return subprocess.run(
            ["sh", str(PACKAGER), "--version", VERSION, "--tarball", str(self.tarball),
             "--out", str(self.out), "--ecosystem", ecosystem,
             "--platform", "linux", "--asset-arch", "x86_64"],
            capture_output=True, text=True, check=False,
        )


@unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb is not installed")
class PackagerOutputTests(PackagerFixture):
    def test_deb_carries_the_declared_name(self):
        run = self.build("deb")
        self.assertEqual(0, run.returncode, run.stderr)
        declared = next(p["asset"] for p in _spec()["packages"] if p["ecosystem"] == "deb")
        self.assertTrue((self.out / declared.replace("{version}", VERSION)).is_file(),
                        sorted(os.listdir(self.out)))

    def test_deb_installs_every_file_the_archive_carries(self):
        """What the archive carries, the package carries.

        v0.2.3's packages copied only bin/ and lib/, so share/repro (the
        sources a recipe compile needs) never reached an apt/dnf install.
        """
        run = self.build("deb")
        self.assertEqual(0, run.returncode, run.stderr)
        deb = next(self.out.glob("*.deb"))
        root = self.work / "installed-all"
        subprocess.run(["dpkg-deb", "-x", str(deb), str(root)], check=True)
        tree = root / "usr" / "lib" / "reprobuild"

        def listing(base):
            return sorted(str(p.relative_to(base)) for p in base.rglob("*"))

        self.assertEqual(listing(self.archive_root), listing(tree))
        self.assertTrue((tree / "share" / "repro" / "source" / "libs"
                         / "repro_interface_artifacts" / "src"
                         / "repro_interface_artifacts.nim").is_file())

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
        # PATH gets the public command, and nothing else from bin/: not the
        # runquota commands, whose /usr/bin paths runquota's packages own.
        on_path = sorted(os.listdir(root / "usr" / "bin"))
        self.assertEqual(["repro"], on_path)
        self.assertTrue((tree / "bin" / "runquotad").is_file())
        wrapper = (root / "usr" / "bin" / "repro").read_text(encoding="utf-8")
        self.assertIn("exec /usr/lib/reprobuild/bin/repro", wrapper)
        # The engine finds the bundled daemon through RUNQUOTAD_BIN instead,
        # and a caller's own choice still wins.
        self.assertIn('${RUNQUOTAD_BIN:=/usr/lib/reprobuild/bin/runquotad}', wrapper)
        named = subprocess.run(
            ["sh", "-c", wrapper.splitlines()[1] + '; printf %s "$RUNQUOTAD_BIN"'],
            capture_output=True, text=True, check=True,
            env={k: v for k, v in os.environ.items() if k != "RUNQUOTAD_BIN"})
        self.assertEqual("/usr/lib/reprobuild/bin/runquotad", named.stdout)
        kept = subprocess.run(
            ["sh", "-c", wrapper.splitlines()[1] + '; printf %s "$RUNQUOTAD_BIN"'],
            capture_output=True, text=True, check=True,
            env={**os.environ, "RUNQUOTAD_BIN": "/opt/runquotad"})
        self.assertEqual("/opt/runquotad", kept.stdout)
        # Run the installed launcher from its installed place: it must find
        # its lib/ where the archive put it.
        ran = subprocess.run([str(tree / "bin" / "repro")], capture_output=True,
                             text=True, check=False)
        self.assertEqual(0, ran.returncode, ran.stderr)
        self.assertEqual("ran\n", ran.stdout)



def _newc_members(stream):
    """The regular files of an uncompressed cpio "newc" archive (rpm2cpio's
    output): {path: (mode, bytes)}. Format: cpio(5), "New ASCII Format"
    (https://man.freebsd.org/cgi/man.cgi?query=cpio&sektion=5)."""
    members = {}
    off = 0
    while True:
        header = stream[off:off + 110]
        if header[:6] not in (b"070701", b"070702"):
            raise ValueError(f"not a newc cpio header at offset {off}: {header[:6]!r}")
        fields = [int(header[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        mode, filesize, namesize = fields[1], fields[6], fields[11]
        name_start = off + 110
        name = stream[name_start:name_start + namesize - 1].decode()
        data_start = (name_start + namesize + 3) & ~3
        data = stream[data_start:data_start + filesize]
        off = (data_start + filesize + 3) & ~3
        if name == "TRAILER!!!":
            return members
        if stat.S_ISREG(mode):
            members[name.lstrip("./")] = (stat.S_IMODE(mode), data)


_PACKAGE_TOOLS = ("dpkg-deb", "rpmbuild", "rpm", "rpm2cpio", "bsdtar")


@unittest.skipUnless(all(shutil.which(t) for t in _PACKAGE_TOOLS),
                     "needs " + ", ".join(_PACKAGE_TOOLS))
class CompletionFilesTests(PackagerFixture):
    """The deb, rpm and pacman packages install repro's shell completion where
    each distribution's shells load it with no setup by the user."""

    def archive_bytes(self, name):
        return (self.archive_root / "share" / "repro" / "completions" / name).read_bytes()

    def deb_files(self, pkg):
        """{path: (mode, bytes)} of the regular files under usr/share/ outside
        usr/share/doc, from the package's own listing and its extraction."""
        listing = subprocess.run(["dpkg-deb", "-c", str(pkg)], capture_output=True,
                                 text=True, check=True).stdout
        modes = {}
        for line in listing.splitlines():
            perms, _owner, _size, _date, _time, path = line.split(None, 5)
            path = path.split(" -> ")[0].lstrip("./")
            if perms.startswith("-") and path.startswith("usr/share/"):
                modes[path] = perms
        root = self.work / "deb-x"
        subprocess.run(["dpkg-deb", "-x", str(pkg), str(root)], check=True)
        return {p: (m, (root / p).read_bytes()) for p, m in modes.items()}

    def rpm_files(self, pkg):
        dump = subprocess.run(["rpm", "-qlp", "--dump", str(pkg)], capture_output=True,
                              text=True, check=True).stdout
        entries = {}
        for line in dump.splitlines():
            fields = line.split()
            entries[fields[0].lstrip("/")] = int(fields[4], 8)
        payload = subprocess.run(["rpm2cpio", str(pkg)], capture_output=True,
                                 check=True).stdout
        members = _newc_members(payload)
        return entries, {p: v for p, v in members.items() if p.startswith("usr/share/")}

    def arch_files(self, pkg):
        listing = subprocess.run(["bsdtar", "-tvf", str(pkg)], capture_output=True,
                                 text=True, check=True).stdout
        modes = {}
        for line in listing.splitlines():
            fields = line.split(None, 8)
            path = fields[8]
            if fields[0].startswith("-") and path.startswith("usr/share/"):
                modes[path] = fields[0]
        root = self.work / "arch-x"
        root.mkdir()
        subprocess.run(["bsdtar", "-xf", str(pkg), "-C", str(root)], check=True)
        return {p: (m, (root / p).read_bytes()) for p, m in modes.items()}

    def assert_completions(self, fmt, files):
        expected = EXPECTED_COMPLETIONS[fmt]
        # Exactly the three files, nothing else under usr/share/.
        self.assertEqual(sorted(expected), sorted(files), fmt)
        for path, source in expected.items():
            mode, data = files[path]
            self.assertEqual(self.archive_bytes(source), data,
                             f"{fmt}: {path} differs from the archive's {source}")
            self.assertIn(b"__complete", data, f"{fmt}: {path}")
            if isinstance(mode, int):
                self.assertEqual(0o644, mode, f"{fmt}: {path} mode {oct(mode)}")
            else:
                self.assertEqual("-rw-r--r--", mode, f"{fmt}: {path}")

    def test_cs_m8a_packages_carry_completion_files(self):
        # (1) deb, rpm and Arch: the listing and the extracted bytes hold
        # exactly the three files, byte-identical to the archive's, mode 0644.
        # Each package is a subtest, so a defect in one format's copy list is
        # reported against that format and the others are still checked.
        with self.subTest(package="deb"):
            run = self.build("deb")
            self.assertEqual(0, run.returncode, f"deb: {run.stderr}")
            self.assert_completions("deb", self.deb_files(next(self.out.glob("*.deb"))))
        with self.subTest(package="rpm"):
            run = self.build("rpm")
            self.assertEqual(0, run.returncode, f"rpm: {run.stderr}")
            rpm_entries, rpm_members = self.rpm_files(next(self.out.glob("*.rpm")))
            self.assert_completions("rpm", rpm_members)
            for path in EXPECTED_COMPLETIONS["rpm"]:
                self.assertEqual(0o100644, rpm_entries[path], f"rpm --dump mode of {path}")
            # (2) The rpm owns none of the three directories, nor any
            # directory above them under /usr/share: the shells' own packages
            # own them.
            for path in EXPECTED_COMPLETIONS["rpm"]:
                parent = Path(path).parent
                while str(parent) not in ("usr", "."):
                    self.assertNotIn(str(parent), rpm_entries,
                                     f"the rpm owns the directory /{parent}")
                    parent = parent.parent
        with self.subTest(package="arch"):
            run = self.build("arch")
            self.assertEqual(0, run.returncode, f"arch: {run.stderr}")
            self.assert_completions("arch", self.arch_files(next(self.out.glob("*.pkg.tar.zst"))))

        # (3) An archive without the zsh script makes the packager fail, for
        # every format, and name the missing file.
        (self.archive_root / "share" / "repro" / "completions" / "_repro").unlink()
        self.pack()
        for fmt in ("deb", "rpm", "arch"):
            run = self.build(fmt)
            self.assertNotEqual(0, run.returncode, f"{fmt} built without _repro")
            self.assertIn("share/repro/completions/_repro", run.stderr, fmt)


if __name__ == "__main__":
    unittest.main()
