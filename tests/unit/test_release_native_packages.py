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

test_cs_m8b_macos_packages_carry_completion_files is the macOS counterpart. It
builds the component .pkg with pkgbuild from a darwin fixture archive and reads
it back with `pkgutil --payload-files` and `pkgutil --expand-full`; and it
generates the Homebrew formula with scripts/release/repro-publish-repos.sh,
the code path a release uses, and runs the formula's `install` method over the
fixture archive against a small stand-in for Homebrew's Formula class, which
puts files where Homebrew's own helpers do. It needs macOS's pkgbuild and
pkgutil, ruby (macOS ships one), sha256sum and a shell; it is skipped, which
counts as not passed, anywhere else. brew itself is not used: running a real
`brew install` writes to the machine's Homebrew prefix.

test_cs_m8c_windows_packages_carry_completion is the Windows counterpart. From
a fixture .zip of the Windows archive's shape it generates the MSI authoring
(.wxs) with repro-build-packages.sh --ecosystem msi, builds the MSI with
msitools' wixl and reads it back with msiinfo and msiextract, and generates the
Scoop manifest with repro-publish-repos.sh. It needs wixl, msiinfo and
msiextract and is skipped, which counts as not passed, without them:
  nix shell nixpkgs#msitools nixpkgs#python3 -c \
    python3 -m unittest tests.unit.test_release_native_packages
The MSI read-back cases and the Scoop hooks case also need pwsh: the
PowerShell text repro-build-packages.sh and repro-publish-repos.sh write from
bash is handed to pwsh's own parser (Parser::ParseFile), because nothing else
can say whether it is PowerShell; without pwsh they are skipped, which counts
as not passed.
Neither package is installed: installing an MSI changes the machine (Program
Files, the machine PATH, the all-users PowerShell profiles), and Scoop's
hooks write the user's profiles. Running them, and building the MSI with WiX v3
on Windows, is tools/multi-distro-harness/tests/m8c_windows_packages_carry_completion.ps1.

test_cs_m8c_harness_helpers_under_pwsh runs
tools/multi-distro-harness/tests/m8c_common_unit.ps1, the unit checks of the
helpers those Windows checks share (the MSYS form of a Windows path for Git
for Windows' tools, a native call whose standard error is not raised under
$ErrorActionPreference = 'Stop', the build's version, a PowerShell's own
$PSHOME). It needs pwsh and is skipped, which counts as not passed, without
it; the dev shell has it.

test_the_windows_release_zip_is_written_by_the_portable_writer and
test_windows_release_zip_entry_names_use_forward_slashes cover the Windows
release zip itself: package_windows_release.ps1 writes it with
scripts/release/write_release_zip.ps1 (not Compress-Archive, whose Windows
PowerShell 5.1 version writes backslash entry names), and that writer's
archive, read back with zipfile, names every entry with '/' under one
top-level directory, with every directory and file of the tree and nothing
else. The second needs pwsh and is skipped, which counts as not passed,
without it.
"""

import json
import os
import re
import stat
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
RELEASE_YML = REPO_ROOT / ".github" / "workflows" / "release-pipeline.yml"
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

    PLATFORM = "linux"
    ASSET_ARCH = "x86_64"

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="repro-pkg-"))
        self.addCleanup(shutil.rmtree, self.work, True)
        top = f"reprobuild-{VERSION}-{self.PLATFORM}-{self.ASSET_ARCH}"
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

    def add_engine_and_graph_helper(self):
        """Put the engine and its graph helper image in the fixture archive,
        as the release archive carries them: on Linux each is a launcher
        beside its `.X.real` image (the launcher contract above)."""
        for name in ("reprobuild", "reprobuild-helper"):
            launcher = self.archive_root / "bin" / name
            launcher.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            launcher.chmod(0o755)
            real = self.archive_root / "bin" / f".{name}.real"
            real.write_text("real binary stand-in\n", encoding="utf-8")
            real.chmod(0o755)
        self.pack()

    def pack(self):
        """(Re)write the fixture tarball from the archive tree."""
        self.tarball = self.work / f"{self.archive_top}.tar.gz"
        with tarfile.open(self.tarball, "w:gz") as tf:
            tf.add(self.archive_root, arcname=self.archive_top)

    def build(self, ecosystem, packager=None):
        return subprocess.run(
            ["sh", str(packager or PACKAGER), "--version", VERSION,
             "--tarball", str(self.tarball),
             "--out", str(self.out), "--ecosystem", ecosystem,
             "--platform", self.PLATFORM, "--asset-arch", self.ASSET_ARCH],
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


    def test_deb_installs_the_graph_helper_beside_the_engine_off_path(self):
        """The engine runs the build graph's helper commands with
        bin/reprobuild-helper from beside its own image, so the package
        installs it there, and only there: a user never runs it, so it gets
        no /usr/bin wrapper."""
        self.add_engine_and_graph_helper()
        run = self.build("deb")
        self.assertEqual(0, run.returncode, run.stderr)
        deb = next(self.out.glob("*.deb"))
        root = self.work / "installed-helper"
        subprocess.run(["dpkg-deb", "-x", str(deb), str(root)], check=True)
        tree = root / "usr" / "lib" / "reprobuild" / "bin"
        for name in ("reprobuild", "reprobuild-helper"):
            self.assertTrue((tree / name).is_file(), name)
            self.assertTrue((tree / f".{name}.real").is_file(), name)
        on_path = sorted(os.listdir(root / "usr" / "bin"))
        self.assertEqual(["repro", "reprobuild"], on_path)

    def test_an_engine_without_its_graph_helper_is_refused(self):
        """An archive with bin/reprobuild and no bin/reprobuild-helper is a
        broken release: every graph helper command would be refused."""
        self.add_engine_and_graph_helper()
        (self.archive_root / "bin" / "reprobuild-helper").unlink()
        self.pack()
        run = self.build("deb")
        self.assertNotEqual(0, run.returncode, "packaged an engine without its helper")
        self.assertIn("reprobuild-helper", run.stderr)


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

    def package_paths(self, fmt, pkg):
        """Every path a package installs, without a leading `./` or `/`."""
        if fmt == "deb":
            listing = subprocess.run(["dpkg-deb", "-c", str(pkg)], capture_output=True,
                                     text=True, check=True).stdout
            return {line.split(None, 5)[5].split(" -> ")[0].lstrip("./").rstrip("/")
                    for line in listing.splitlines()}
        if fmt == "rpm":
            listing = subprocess.run(["rpm", "-qlp", str(pkg)], capture_output=True,
                                     text=True, check=True).stdout
            return {line.lstrip("/") for line in listing.splitlines()}
        listing = subprocess.run(["bsdtar", "-tf", str(pkg)], capture_output=True,
                                 text=True, check=True).stdout
        return {line.rstrip("/") for line in listing.splitlines()}

    def test_every_package_installs_the_graph_helper_image(self):
        """deb, rpm and pacman each install bin/reprobuild-helper beside the
        engine in the archive tree, and none puts it on PATH."""
        self.add_engine_and_graph_helper()
        globs = {"deb": "*.deb", "rpm": "*.rpm", "arch": "*.pkg.tar.zst"}
        for fmt, glob in globs.items():
            with self.subTest(package=fmt):
                self.out = self.work / f"out-helper-{fmt}"
                run = self.build(fmt)
                self.assertEqual(0, run.returncode, f"{fmt}: {run.stderr}")
                paths = self.package_paths(fmt, next(self.out.glob(glob)))
                for name in ("reprobuild", "reprobuild-helper"):
                    self.assertIn(f"usr/lib/reprobuild/bin/{name}", paths, fmt)
                    self.assertIn(f"usr/lib/reprobuild/bin/.{name}.real", paths, fmt)
                self.assertIn("usr/bin/reprobuild", paths, fmt)
                self.assertNotIn("usr/bin/reprobuild-helper", paths, fmt)


# ---------------------------------------------------------------------------
# macOS: the component .pkg and the Homebrew formula
# ---------------------------------------------------------------------------
PUBLISHER = REPO_ROOT / "scripts" / "release" / "repro-publish-repos.sh"

# Where the .pkg installs each archive script: under /usr/local, because
# macOS's /usr is read-only.
MACOS_PKG_COMPLETIONS = {
    "usr/local/share/bash-completion/completions/repro": "repro.bash",
    "usr/local/share/zsh/site-functions/_repro": "_repro",
    "usr/local/share/fish/vendor_completions.d/repro.fish": "repro.fish",
}
# Where Homebrew's completion helpers put them, inside the formula's keg
# (Formula#bash_completion, #zsh_completion and #fish_completion): `brew link`
# then links each into $(brew --prefix)/etc/bash_completion.d,
# share/zsh/site-functions and share/fish/vendor_completions.d.
HOMEBREW_COMPLETIONS = {
    "etc/bash_completion.d/repro": "repro.bash",
    "share/zsh/site-functions/_repro": "_repro",
    "share/fish/vendor_completions.d/repro.fish": "repro.fish",
}

# A stand-in for the part of Homebrew's Formula API the generated formula
# uses, run by the system ruby. It follows Homebrew's definitions
# (Library/Homebrew/formula.rb and extend/pathname.rb): `bash_completion` is
# prefix/"etc/bash_completion.d", `zsh_completion` share/"zsh/site-functions",
# `fish_completion` share/"fish/vendor_completions.d", and Pathname#install
# takes paths, arrays of paths, or a {source => new name} hash and raises when
# a source does not exist. The prefix is the scratch keg given in
# STUB_PREFIX; the working directory is the archive's top directory, which is
# where brew runs `install` for a tarball with one top-level directory.
HOMEBREW_STUB = r"""
require 'fileutils'
require 'pathname'

class Pathname
  def install(*sources)
    sources.flatten.each do |src|
      if src.is_a?(Hash)
        src.each { |from, to| install_one(from, to) }
      else
        install_one(src, File.basename(src.to_s))
      end
    end
  end

  def install_one(from, to)
    raise Errno::ENOENT, from.to_s unless File.exist?(from.to_s)
    mkpath
    FileUtils.cp_r(from.to_s, (self + to).to_s)
  end
end

class Formula
  class << self
    %i[desc homepage url sha256 version license].each { |m| define_method(m) { |*a| } }
    def test(&block); end
  end

  def prefix;           Pathname.new(ENV.fetch('STUB_PREFIX')); end
  def bin;              prefix + 'bin'; end
  def lib;              prefix + 'lib'; end
  def share;            prefix + 'share'; end
  def bash_completion;  prefix + 'etc/bash_completion.d'; end
  def zsh_completion;   share + 'zsh/site-functions'; end
  def fish_completion;  share + 'fish/vendor_completions.d'; end
end

load ENV.fetch('STUB_FORMULA')
Reprobuild.new.install
"""

_MACOS_TOOLS = ("pkgbuild", "pkgutil", "ruby", "sha256sum", "sh")


@unittest.skipUnless(all(shutil.which(t) for t in _MACOS_TOOLS),
                     "needs " + ", ".join(_MACOS_TOOLS) + " (macOS)")
class MacosCompletionFilesTests(PackagerFixture):
    """The macOS .pkg and the Homebrew formula install repro's shell
    completion where macOS's shells look for it."""

    PLATFORM = "darwin"
    ASSET_ARCH = "aarch64"

    def archive_bytes(self, name):
        return (self.archive_root / "share" / "repro" / "completions" / name).read_bytes()

    # ------------------------------------------------------------ the .pkg
    def pkg_payload(self, pkg, tag):
        """(listing, {path: (mode, bytes)} of every regular file under
        usr/local/share): the payload as pkgutil lists it, and as pkgutil
        expands it. Paths have no leading './'."""
        listing = subprocess.run(["pkgutil", "--payload-files", str(pkg)],
                                 capture_output=True, text=True, check=True).stdout
        # `._name` entries are AppleDouble records of a file's extended
        # attributes (pkgbuild writes one for each attribute holder, such as
        # the provenance mark macOS puts on files a sandboxed process made,
        # which `xattr -c` cannot remove). The installer applies them as
        # attributes; they are not files, so they are not listed here.
        paths = sorted(line[2:] if line.startswith("./") else line
                       for line in listing.splitlines()
                       if line not in ("", ".") and not os.path.basename(line).startswith("._"))
        expanded = self.work / f"pkg-expanded-{tag}"
        subprocess.run(["pkgutil", "--expand-full", str(pkg), str(expanded)], check=True)
        payload = expanded / "Payload"
        shared = {}
        for path in payload.joinpath("usr", "local", "share").rglob("*"):
            if path.is_file() and not path.is_symlink():
                shared[str(path.relative_to(payload))] = (
                    stat.S_IMODE(path.stat().st_mode), path.read_bytes())
        return paths, shared, expanded

    def assert_pkg_completions(self, paths, shared):
        # Exactly the three files under /usr/local/share, none elsewhere under
        # /usr (macOS's /usr is read-only) outside /usr/local.
        self.assertEqual(sorted(MACOS_PKG_COMPLETIONS), sorted(shared))
        for path, source in MACOS_PKG_COMPLETIONS.items():
            mode, data = shared[path]
            self.assertEqual(self.archive_bytes(source), data,
                             f"pkg: {path} differs from the archive's {source}")
            self.assertIn(b"__complete", data, f"pkg: {path}")
            self.assertEqual(0o644, mode, f"pkg: {path} mode {oct(mode)}")
            self.assertIn(path, paths, f"pkgutil --payload-files lists no {path}")
        for path in paths:
            self.assertTrue(path == "usr" or path.startswith("usr/local"),
                            f"the package installs {path} outside /usr/local")

    def test_cs_m8b_macos_packages_carry_completion_files(self):
        # (1) The .pkg: its payload holds, under /usr/local, the archive tree
        # intact, the command's wrapper, and the three completion files
        # byte-identical to the archive's, mode 0644.
        with self.subTest(package="pkg"):
            run = self.build("pkg")
            self.assertEqual(0, run.returncode, f"pkg: {run.stderr}")
            pkg = self.out / f"reprobuild-{VERSION}-{self.PLATFORM}-{self.ASSET_ARCH}.pkg"
            self.assertTrue(pkg.is_file(), sorted(os.listdir(self.out)))
            paths, shared, expanded = self.pkg_payload(pkg, "good")
            self.assert_pkg_completions(paths, shared)
            self.assertIn("usr/local/bin/repro", paths)
            self.assertIn("usr/local/lib/reprobuild/lib/marker", paths)
            info = (expanded / "PackageInfo").read_text(encoding="utf-8")
            self.assertIn('install-location="/"', info)
            self.assertIn('identifier="com.metacraft-labs.reprobuild"', info)
            wrapper = (expanded / "Payload" / "usr" / "local" / "bin" / "repro"
                       ).read_text(encoding="utf-8")
            self.assertIn("exec /usr/local/lib/reprobuild/bin/repro", wrapper)

        # (2) Negative controls. A packager whose install list lacks the zsh
        # file produces a package the assertion above rejects. The packager
        # reads its own output back and refuses such a package, so the copy
        # loses that check too, to show the assertion itself catches it.
        text = PACKAGER.read_text(encoding="utf-8")
        pair = '    "_repro:$_zsh_dir/_repro" \\\n'
        readback = '      ./usr/local/share/zsh/site-functions/_repro \\\n'
        self.assertEqual(1, text.count(pair), "the packager's install list changed")
        self.assertEqual(1, text.count(readback), "the packager's read-back changed")
        without_pair = self.work / "packager-without-zsh.sh"
        without_pair.write_text(text.replace(pair, ""), encoding="utf-8")
        self.out = self.work / "out-no-zsh-checked"
        run = self.build("pkg", packager=without_pair)
        self.assertNotEqual(0, run.returncode, "the packager built a .pkg without _repro")
        self.assertIn("_repro", run.stderr)
        without_both = self.work / "packager-without-zsh-or-readback.sh"
        without_both.write_text(text.replace(pair, "").replace(readback, ""),
                                encoding="utf-8")
        self.out = self.work / "out-no-zsh"
        run = self.build("pkg", packager=without_both)
        self.assertEqual(0, run.returncode, run.stderr)
        pkg = next(self.out.glob("*.pkg"))
        paths, shared, _ = self.pkg_payload(pkg, "mutant")
        with self.assertRaises(AssertionError):
            self.assert_pkg_completions(paths, shared)
        # An archive without the zsh script makes the packager fail and name it.
        (self.archive_root / "share" / "repro" / "completions" / "_repro").unlink()
        self.pack()
        self.out = self.work / "out-no-archive-zsh"
        run = self.build("pkg")
        self.assertNotEqual(0, run.returncode, "pkg built without _repro")
        self.assertIn("share/repro/completions/_repro", run.stderr)

    # ------------------------------------------------------ the Homebrew formula
    def generate_formula(self):
        """The Homebrew formula repro-publish-repos.sh generates for the
        fixture's darwin archive, as text."""
        packages = self.work / "release-assets"
        packages.mkdir()
        shutil.copy(self.tarball, packages / self.tarball.name)
        repo_root = self.work / "tap-repo"
        run = subprocess.run(
            ["sh", str(PUBLISHER), "--version", VERSION, "--packages", str(packages),
             "--ecosystem", "homebrew", "--repo-root", str(repo_root),
             "--target", "none", "--scoop-downloads-base", "https://downloads.example"],
            capture_output=True, text=True, check=False)
        self.assertEqual(0, run.returncode, run.stderr)
        return (repo_root / "homebrew" / "Formula" / "reprobuild.rb").read_text(encoding="utf-8")

    def run_formula_install(self, formula_text, tag):
        """Run the formula's `install` over the fixture archive's top
        directory, into a scratch keg; return the keg's {path: bytes}."""
        formula = self.work / f"formula-{tag}.rb"
        formula.write_text(formula_text, encoding="utf-8")
        stub = self.work / "homebrew_stub.rb"
        stub.write_text(HOMEBREW_STUB, encoding="utf-8")
        keg = self.work / f"keg-{tag}"
        keg.mkdir()
        run = subprocess.run(
            ["ruby", str(stub)], cwd=str(self.archive_root), capture_output=True,
            text=True, check=False,
            env={**os.environ, "STUB_PREFIX": str(keg), "STUB_FORMULA": str(formula)})
        return run, {str(p.relative_to(keg)): p.read_bytes()
                     for p in keg.rglob("*") if p.is_file()}

    def assert_homebrew_completions(self, run, tree):
        self.assertEqual(0, run.returncode, run.stderr)
        completions = {p: b for p, b in tree.items() if p.startswith(("etc/", "share/"))}
        self.assertEqual(sorted(HOMEBREW_COMPLETIONS), sorted(completions))
        for path, source in HOMEBREW_COMPLETIONS.items():
            self.assertEqual(self.archive_bytes(source), completions[path],
                             f"formula: {path} differs from the archive's {source}")
            self.assertIn(b"__complete", completions[path], f"formula: {path}")

    def test_cs_m8b_homebrew_formula_installs_completion_files(self):
        # The formula repro-publish-repos.sh generates, installed from the
        # fixture archive: the command, its lib/, and the three completion
        # files at the places Homebrew's helpers use.
        formula = self.generate_formula()
        run, tree = self.run_formula_install(formula, "good")
        self.assert_homebrew_completions(run, tree)
        self.assertIn("bin/repro", tree)
        self.assertIn("lib/marker", tree)
        # Negative control: the formula without one shell's line installs no
        # file for that shell, and the assertion rejects it.
        for shell, line in (("zsh", '    zsh_completion.install "share/repro/completions/_repro"\n'),
                            ("fish", '    fish_completion.install "share/repro/completions/repro.fish"\n'),
                            ("bash", '    bash_completion.install "share/repro/completions/repro.bash" => "repro"\n')):
            self.assertEqual(1, formula.count(line), f"the formula's {shell} line changed")
            mutant_run, mutant_tree = self.run_formula_install(formula.replace(line, ""), f"no-{shell}")
            with self.assertRaises(AssertionError, msg=f"formula without {shell} passed"):
                self.assert_homebrew_completions(mutant_run, mutant_tree)
        # An archive that lacks a completion file fails the install, as brew's
        # own helper does for a missing source, rather than installing less.
        (self.archive_root / "share" / "repro" / "completions" / "_repro").unlink()
        broken_run, _ = self.run_formula_install(formula, "no-archive-zsh")
        self.assertNotEqual(0, broken_run.returncode)
        self.assertIn("_repro", broken_run.stderr)


# Where the MSI installs the PowerShell completion script (the archive tree
# intact under %ProgramFiles%\Reprobuild), and the commands its custom actions
# and the Scoop manifest's hooks run to register it: all users through the
# all-users profile for the per-machine MSI, the installing user for Scoop,
# which installs per user.
MSI_COMPLETION_PATH = "ProgramFiles64Folder/Reprobuild/share/repro/completions/repro.ps1"
MSI_REPRO_PATH = "ProgramFiles64Folder/Reprobuild/bin/repro.exe"
MSI_GRAPH_HELPER_PATH = "ProgramFiles64Folder/Reprobuild/bin/reprobuild-helper.exe"
MSI_CUSTOM_ACTIONS = {
    "ReproCompletionEnsure": "hooks ensure --shell-autocomplete --system",
    "ReproCompletionRemove": "hooks uninstall --shell-autocomplete --system",
}
# msidbCustomActionTypeExe + SourceFile (18), ContinueOnError (64),
# InScript (1024), NoImpersonate (2048):
# https://learn.microsoft.com/windows/win32/msi/custom-action-types
MSI_CUSTOM_ACTION_TYPE = 18 + 64 + 1024 + 2048
SCOOP_ENSURE = '& "$dir\\bin\\repro.exe" hooks ensure --shell-autocomplete --profile'
SCOOP_UNINSTALL = '& "$dir\\bin\\repro.exe" hooks uninstall --shell-autocomplete --profile'

_MSI_TOOLS = ("wixl", "msiinfo", "msiextract")


@unittest.skipUnless(all(shutil.which(t) for t in _MSI_TOOLS),
                     "needs " + ", ".join(_MSI_TOOLS) + " (nixpkgs#msitools)")
class WindowsCompletionTests(PackagerFixture):
    """The MSI and the Scoop manifest install repro's PowerShell completion
    where the Windows rows of the platform matrix put it."""

    PLATFORM = "windows"
    ASSET_ARCH = "x86_64"

    def setUp(self):
        super().setUp()
        # The Windows archive's command, engine and the engine's graph
        # helper image are .exe images.
        for name in ("repro.exe", "reprobuild.exe", "reprobuild-helper.exe"):
            (self.archive_root / "bin" / name).write_bytes(b"MZ stand-in\n")
        self.pack()

    def pack(self):
        """(Re)write the fixture .zip, the Windows release asset's shape."""
        self.tarball = self.work / f"{self.archive_top}.zip"
        with zipfile.ZipFile(self.tarball, "w", zipfile.ZIP_DEFLATED) as zf:
            for path in sorted(self.archive_root.rglob("*")):
                if path.is_file():
                    zf.write(path, f"{self.archive_top}/{path.relative_to(self.archive_root).as_posix()}")

    def archive_ps1(self):
        return (self.archive_root / "share" / "repro" / "completions" / "repro.ps1").read_bytes()

    def build_msi(self, packager=None, source_only=False):
        env = dict(os.environ)
        env.pop("REPRO_MSI_TOOLSET", None)
        if source_only:
            env["REPRO_MSI_SOURCE_ONLY"] = "1"
        return subprocess.run(
            ["sh", str(packager or PACKAGER), "--version", VERSION,
             "--tarball", str(self.tarball), "--out", str(self.out),
             "--ecosystem", "msi", "--platform", self.PLATFORM,
             "--asset-arch", self.ASSET_ARCH],
            capture_output=True, text=True, check=False, env=env)

    # ------------------------------------------------------------ the .msi
    def msi_rows(self, msi, table):
        text = subprocess.run(["msiinfo", "export", str(msi), table],
                              capture_output=True, text=True, check=True).stdout
        return [line.rstrip("\r").split("\t") for line in text.splitlines()[3:] if line.strip()]

    def msi_contents(self, msi, tag):
        """({install path: bytes}, {custom action: (type, source, target)},
        {sequenced action: condition}): the package's files resolved through
        its Directory, Component and File tables, each with the bytes
        msiextract writes for it, and its custom actions."""
        parent, name = {}, {}
        for d, p, default in self.msi_rows(msi, "Directory"):
            parent[d], name[d] = p, default

        def longname(s):
            s = s.split(":")[0]
            return s.split("|")[-1]

        def dpath(d):
            if d in ("TARGETDIR", "ProgramFiles64Folder") or d not in parent:
                return d
            return dpath(parent[d]) + "/" + longname(name[d])

        cdir = {row[0]: row[2] for row in self.msi_rows(msi, "Component")}
        extracted = self.work / f"msi-x-{tag}"
        extracted.mkdir()
        subprocess.run(["msiextract", "-C", str(extracted), str(msi)],
                       capture_output=True, check=True)
        files = {}
        for row in self.msi_rows(msi, "File"):
            path = dpath(cdir[row[1]]) + "/" + longname(row[2])
            on_disk = extracted / path.split("/", 1)[1]
            files[path] = on_disk.read_bytes() if on_disk.is_file() else None
        actions = {row[0]: (int(row[1]), row[2], row[3])
                   for row in self.msi_rows(msi, "CustomAction")}
        sequence = {row[0]: row[1] for row in self.msi_rows(msi, "InstallExecuteSequence")}
        return files, actions, sequence

    def assert_msi_completion(self, files, actions, sequence):
        self.assertIn(MSI_COMPLETION_PATH, files, sorted(files))
        self.assertEqual(self.archive_ps1(), files[MSI_COMPLETION_PATH],
                         "msi: the completion script differs from the archive's")
        self.assertIn(b"__complete", files[MSI_COMPLETION_PATH])
        self.assertIn(MSI_REPRO_PATH, files)
        for action, command in MSI_CUSTOM_ACTIONS.items():
            self.assertIn(action, actions)
            kind, source, target = actions[action]
            self.assertEqual(MSI_CUSTOM_ACTION_TYPE, kind, action)
            self.assertEqual("fil_repro_exe", source, action)
            self.assertEqual(command, target, action)
            self.assertIn(action, sequence)
        self.assertEqual('REMOVE~="ALL"', sequence["ReproCompletionRemove"])
        self.assertEqual('NOT (REMOVE~="ALL")', sequence["ReproCompletionEnsure"])

    # ------------------------------------------------------ the Scoop manifest
    def generate_scoop_manifest(self):
        packages = self.work / "release-assets"
        packages.mkdir(exist_ok=True)
        shutil.copy(self.tarball, packages / self.tarball.name)
        repo_root = self.work / "bucket-repo"
        run = subprocess.run(
            ["sh", str(PUBLISHER), "--version", VERSION, "--packages", str(packages),
             "--ecosystem", "scoop", "--repo-root", str(repo_root),
             "--target", "none", "--scoop-downloads-base", "https://downloads.example"],
            capture_output=True, text=True, check=False)
        self.assertEqual(0, run.returncode, run.stderr)
        return json.loads((repo_root / "scoop" / "bucket" / "reprobuild.json")
                          .read_text(encoding="utf-8"))

    def assert_scoop_completion(self, manifest):
        # Scoop extracts the archive's top directory as the app's $dir, so the
        # script is at $dir\share\repro\completions\repro.ps1 ...
        self.assertEqual(self.archive_top, manifest["extract_dir"])
        with zipfile.ZipFile(self.tarball) as zf:
            self.assertEqual(self.archive_ps1(),
                             zf.read(f"{self.archive_top}/share/repro/completions/repro.ps1"))
        self.assertEqual(["bin\\repro.exe"], manifest["bin"])
        # ... and, Scoop being per user, the hooks register it for the user
        # (the CurrentUserAllHosts block of `--profile`) and remove it again.
        post = "\n".join(manifest.get("post_install", []))
        pre = "\n".join(manifest.get("pre_uninstall", []))
        self.assertIn(SCOOP_ENSURE, post)
        self.assertIn("$env:REPRO_NO_COMPLETION -eq '1'", post)
        self.assertLess(post.index("$env:REPRO_NO_COMPLETION"), post.index(SCOOP_ENSURE))
        self.assertIn(SCOOP_UNINSTALL, pre)
        self.assertNotIn("--system", post + pre)

    def test_cs_m8c_windows_packages_carry_completion(self):
        wxs_text = ""
        # (1) The MSI source: the completion script is a File of the
        # completions directory under the install folder, from the archive's
        # copy; the custom actions run the installed repro.exe.
        with self.subTest(package="msi source"):
            run = self.build_msi(source_only=True)
            self.assertEqual(0, run.returncode, run.stderr)
            wxs = self.out / f"reprobuild-{VERSION}-{self.PLATFORM}-{self.ASSET_ARCH}.wxs"
            self.assertFalse(wxs.with_suffix(".msi").exists())
            ns = {"w": "http://schemas.microsoft.com/wix/2006/wi"}
            tree = ET.parse(wxs)
            chain = []

            def find(node, trail):
                for child in node:
                    tag = child.tag.split("}")[1]
                    here = trail + [child.get("Name") or child.get("Id")] if tag == "Directory" else trail
                    if tag == "File" and child.get("Id") == "fil_completion_ps1":
                        chain.append((here, child))
                    find(child, here)

            find(tree.getroot(), [])
            self.assertEqual(1, len(chain), "the .wxs has no single completion File")
            dirs, element = chain[0]
            self.assertEqual(["SourceDir", "ProgramFiles64Folder", "Reprobuild", "share",
                              "repro", "completions"], dirs)
            self.assertEqual("repro.ps1", element.get("Name"))
            self.assertEqual(f"$(var.SourceDir)/{self.archive_top}/share/repro/completions/repro.ps1",
                             element.get("Source"))
            commands = {ca.get("Id"): (ca.get("FileKey"), ca.get("ExeCommand"), ca.get("Execute"),
                                       ca.get("Impersonate"), ca.get("Return"))
                        for ca in tree.getroot().iterfind(".//w:CustomAction", ns)}
            for action, command in MSI_CUSTOM_ACTIONS.items():
                self.assertEqual(("fil_repro_exe", command, "deferred", "no", "ignore"),
                                 commands.get(action), action)
            env = tree.getroot().find(".//w:Environment", ns)
            self.assertEqual(("PATH", "[BINDIR]", "yes"),
                             (env.get("Name"), env.get("Value"), env.get("System")))

        # (2) The built MSI, read back: the script is installed at
        # %ProgramFiles%\Reprobuild\share\repro\completions\repro.ps1,
        # byte-identical to the archive's, and both actions are sequenced.
        with self.subTest(package="msi"):
            self.out = self.work / "out-msi"
            run = self.build_msi()
            self.assertEqual(0, run.returncode, run.stderr)
            msi = self.out / f"reprobuild-{VERSION}-{self.PLATFORM}-{self.ASSET_ARCH}.msi"
            contents = self.msi_contents(msi, "good")
            self.assert_msi_completion(*contents)
            # The engine's graph helper image is installed beside it.
            self.assertIn(MSI_GRAPH_HELPER_PATH, contents[0], sorted(contents[0]))
            wxs_text = msi.with_suffix(".wxs").read_text(encoding="utf-8")

        # (3) Negative control: the same source without the completion
        # script's component builds a package the assertion rejects.
        with self.subTest(package="msi without the completion entry"):
            self.assertTrue(wxs_text, "no authoring from the MSI build above")
            component = re.search(r'\s*<Component Id="cmp_completion_ps1".*?</Component>\n',
                                  wxs_text, re.S)
            self.assertIsNotNone(component)
            mutant = (wxs_text.replace(component.group(0), "\n")
                      .replace('      <ComponentRef Id="cmp_completion_ps1" />\n', ""))
            self.assertNotIn("fil_completion_ps1", mutant)
            src = self.work / "msi-src"
            src.mkdir()
            with zipfile.ZipFile(self.tarball) as zf:
                zf.extractall(src)
            mutant_wxs = self.work / "mutant.wxs"
            mutant_wxs.write_text(mutant, encoding="utf-8")
            mutant_msi = self.work / "mutant.msi"
            subprocess.run(["wixl", "-a", "x64", "-D", f"SourceDir={src}", "-o",
                            str(mutant_msi), str(mutant_wxs)],
                           capture_output=True, text=True, check=True, cwd=str(src))
            with self.assertRaises(AssertionError):
                self.assert_msi_completion(*self.msi_contents(mutant_msi, "mutant"))

        # (4) The Scoop manifest the publisher generates.
        with self.subTest(package="scoop"):
            manifest = self.generate_scoop_manifest()
            self.assert_scoop_completion(manifest)
            # Negative control: the manifest without its post_install.
            mutant = dict(manifest)
            del mutant["post_install"]
            with self.assertRaises(AssertionError):
                self.assert_scoop_completion(mutant)

        # (5) An archive without the script: the packager refuses and names it.
        with self.subTest(package="msi from an archive without repro.ps1"):
            (self.archive_root / "share" / "repro" / "completions" / "repro.ps1").unlink()
            self.pack()
            self.out = self.work / "out-no-ps1"
            run = self.build_msi()
            self.assertNotEqual(0, run.returncode, "an MSI was built without repro.ps1")
            self.assertIn("share/repro/completions/repro.ps1", run.stderr)

    # -------------------------------------- the MSI read-back on Windows
    # On Windows there is no msiinfo, and the packager reads the MSI back
    # through powershell.exe and the Windows Installer API, handing it a
    # script as -EncodedCommand. That script is generated from bash, so
    # nothing but PowerShell's own parser can say whether it is PowerShell:
    # a reader whose query was written "SELECT * FROM `" + ... + "`" did not
    # parse (inside a double-quoted PowerShell string a backtick escapes the
    # quote), every table read back empty, and a correct MSI was refused as
    # not installing bin/repro.exe (seen on a real Windows host).
    #
    # The stand-in below is powershell.exe as the packager sees it: it
    # decodes the script from -EncodedCommand (or takes it from -Command),
    # hands the EXACT text to the real PowerShell parser (pwsh's
    # Parser::ParseFile, which parses as Windows PowerShell does for this
    # syntax), and on a parse error prints the errors and exits 1, as
    # powershell.exe does. A script that parses is answered as the COM
    # object would answer it, from msiinfo. The COM object itself is not
    # used: it exists only on Windows. A stand-in is justified here because
    # what is under test is the script text and its hand-off, which reach
    # the real parser unchanged, not the Windows Installer API.
    POWERSHELL_STANDIN = r"""#!/bin/sh
log="$STANDIN_LOG"
script=""
have_script=0
while [ $# -gt 0 ]; do
  printf 'arg: %s\n' "$1" >> "$log"
  case "$1" in
    -Command) shift; script="$1"; have_script=1 ;;
    -EncodedCommand) shift; script=$(printf '%s' "$1" | base64 -d | iconv -f UTF-16LE -t UTF-8); have_script=1 ;;
  esac
  shift
done
[ "$have_script" = 1 ] || { echo "stand-in: no script given" >&2; exit 2; }
n=$(ls "$STANDIN_DIR" | grep -c '^script-' || true)
file="$STANDIN_DIR/script-$n.ps1"
printf '%s' "$script" > "$file"
printf '%s\n----\n' "$script" >> "$STANDIN_SCRIPTS"
"$STANDIN_PWSH" -NoProfile -NonInteractive -File "$STANDIN_PARSER" "$file" >&2 || exit 1
"$STANDIN_MSIINFO" export "$REPRO_MSI_DB" "$REPRO_MSI_TABLE" | tail -n +4
"""

    def without_msiinfo_env(self):
        """The environment with powershell.exe's stand-in first on PATH and
        no msiinfo on it, so the packager takes its Windows read-back path;
        wixl stays reachable to build the package."""
        msiinfo = shutil.which("msiinfo")
        wixl = shutil.which("wixl")
        standin_dir = self.work / "standin-bin"
        standin_dir.mkdir()
        exe = standin_dir / "powershell.exe"
        exe.write_text(self.POWERSHELL_STANDIN, encoding="utf-8")
        exe.chmod(0o755)
        (standin_dir / "wixl").symlink_to(wixl)
        scripts_dir = self.work / "standin-scripts"
        scripts_dir.mkdir()
        parser = self.work / "parse-check.ps1"
        parser.write_text(PARSE_CHECK_PS1, encoding="utf-8")
        msitools_dir = str(Path(msiinfo).parent)
        path = [str(standin_dir)] + [d for d in os.environ.get("PATH", "").split(os.pathsep)
                                     if d and d != msitools_dir
                                     and not (Path(d) / "msiinfo").exists()]
        env = dict(os.environ, PATH=os.pathsep.join(path),
                   STANDIN_LOG=str(self.work / "standin.log"),
                   STANDIN_SCRIPTS=str(self.work / "standin-scripts.txt"),
                   STANDIN_DIR=str(scripts_dir),
                   STANDIN_PARSER=str(parser),
                   STANDIN_PWSH=shutil.which("pwsh"),
                   STANDIN_MSIINFO=msiinfo)
        env.pop("REPRO_MSI_TOOLSET", None)
        return env

    @unittest.skipUnless(shutil.which("pwsh"), "needs pwsh (PowerShell 7) to parse the reader")
    def test_the_msi_read_back_survives_the_windows_command_line(self):
        env = self.without_msiinfo_env()
        self.assertIsNone(shutil.which("msiinfo", path=env["PATH"]))
        run = subprocess.run(
            ["sh", str(PACKAGER), "--version", VERSION,
             "--tarball", str(self.tarball), "--out", str(self.out),
             "--ecosystem", "msi", "--platform", self.PLATFORM,
             "--asset-arch", self.ASSET_ARCH],
            capture_output=True, text=True, check=False, env=env)
        self.assertEqual(0, run.returncode, run.stderr)
        log = (self.work / "standin.log").read_text(encoding="utf-8")
        # The packager went through powershell.exe, with -EncodedCommand.
        self.assertIn("arg: -EncodedCommand", log)
        self.assertNotIn("arg: -Command", log)
        # Each read handed the parser a script, and every one parsed (the
        # packager would have refused otherwise; this says so directly).
        scripts = sorted((self.work / "standin-scripts").glob("script-*.ps1"))
        self.assertGreaterEqual(len(scripts), 3, "the reader ran fewer than three times")
        for script in scripts:
            self.assertEqual([], powershell_parse_errors(script), script.read_text(encoding="utf-8"))
        text = scripts[0].read_text(encoding="utf-8")
        self.assertIn("$env:REPRO_MSI_TABLE", text)
        self.assertIn("SELECT * FROM", text)

    @unittest.skipUnless(shutil.which("pwsh"), "needs pwsh (PowerShell 7) to parse the reader")
    def test_a_reader_that_does_not_parse_is_refused_not_read_as_empty(self):
        """Control for the case above: the 2026-11 reader text, whose query
        does not parse, is refused by the real parser through the same
        stand-in, and the packager stops naming the table instead of
        reading it as empty."""
        broken = PACKAGER.read_text(encoding="utf-8").replace(
            "$q = 'SELECT * FROM `' + $env:REPRO_MSI_TABLE + '`'",
            '$q = "SELECT * FROM `" + $env:REPRO_MSI_TABLE + "`"')
        self.assertNotEqual(broken, PACKAGER.read_text(encoding="utf-8"),
                            "the reader's query line moved; update this control")
        mutant = self.work / "repro-build-packages-broken.sh"
        mutant.write_text(broken, encoding="utf-8")
        env = self.without_msiinfo_env()
        run = subprocess.run(
            ["sh", str(mutant), "--version", VERSION,
             "--tarball", str(self.tarball), "--out", str(self.out),
             "--ecosystem", "msi", "--platform", self.PLATFORM,
             "--asset-arch", self.ASSET_ARCH],
            capture_output=True, text=True, check=False, env=env)
        self.assertNotEqual(0, run.returncode, run.stderr)
        self.assertIn("cannot read the Directory table", run.stderr)
        self.assertIn("Unexpected token", run.stderr)
        self.assertNotIn("does not install", run.stderr)

    @unittest.skipUnless(shutil.which("pwsh"), "needs pwsh (PowerShell 7) to parse the hooks")
    def test_the_scoop_hooks_parse_as_powershell(self):
        """The Scoop manifest's post_install and pre_uninstall are PowerShell
        written from bash (repro-publish-repos.sh, a here-document inside
        JSON). Scoop joins each hook's lines and runs them, so each joined
        hook must parse; the real parser says whether it does."""
        manifest = self.generate_scoop_manifest()
        for hook in ("post_install", "pre_uninstall"):
            with self.subTest(hook=hook):
                text = "\n".join(manifest[hook])
                script = self.work / f"scoop-{hook}.ps1"
                script.write_text(text, encoding="utf-8")
                self.assertEqual([], powershell_parse_errors(script), text)
        # Control: the parser does refuse the reader text that broke on
        # Windows, so an empty error list above is the parser's verdict.
        bad = self.work / "known-bad.ps1"
        bad.write_text('$q = @("SELECT * FROM `" + $env:T + "`")', encoding="utf-8")
        self.assertNotEqual([], powershell_parse_errors(bad))


# Parses one file with the real PowerShell parser and prints each error as
# "<line>:<column>: <message>"; exits with the number of errors.
PARSE_CHECK_PS1 = r"""param([Parameter(Mandatory)][string]$Path)
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
foreach ($e in $errors) {
  [Console]::Out.WriteLine(('{0}:{1}: {2}' -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message))
}
exit $errors.Count
"""


def powershell_parse_errors(path):
    """The PowerShell parser's errors for the file at `path`, one string
    each, from pwsh's Parser::ParseFile; [] when it parses."""
    with tempfile.TemporaryDirectory() as d:
        checker = Path(d) / "parse-check.ps1"
        checker.write_text(PARSE_CHECK_PS1, encoding="utf-8")
        run = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(checker), str(path)],
            capture_output=True, text=True, check=False)
    errors = [line for line in run.stdout.splitlines() if line.strip()]
    if run.returncode != len(errors):
        raise AssertionError(f"the parse check itself failed (exit {run.returncode}): {run.stderr}")
    return errors


M8C_COMMON_UNIT = REPO_ROOT / "tools" / "multi-distro-harness" / "tests" / "m8c_common_unit.ps1"


@unittest.skipUnless(shutil.which("pwsh"), "needs pwsh (PowerShell 7)")
class WindowsHarnessHelperTests(unittest.TestCase):
    """The host-independent helpers of the Windows completion checks
    (m8c_common.ps1): the MSYS form of a Windows path, a native call whose
    standard error is not raised under $ErrorActionPreference = 'Stop', the
    build's version, and a PowerShell's own $PSHOME. Without them the
    Windows checks die in the harness before they test anything."""

    def test_cs_m8c_harness_helpers_under_pwsh(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, TMPDIR=tmp)
            run = subprocess.run(
                ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(M8C_COMMON_UNIT)],
                cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=300)
        self.assertEqual(0, run.returncode, run.stdout + run.stderr)
        self.assertIn("0 failure(s)", run.stdout)
        self.assertNotIn("FAIL  ", run.stdout)



WRITE_RELEASE_ZIP = REPO_ROOT / "scripts" / "release" / "write_release_zip.ps1"
PACKAGE_WINDOWS_RELEASE = REPO_ROOT / "scripts" / "release" / "package_windows_release.ps1"


def _powershell_code(path: Path) -> str:
    """The lines of a PowerShell script that are not `#` comments."""
    return "\n".join(line for line in path.read_text(encoding="utf-8").splitlines()
                     if not line.lstrip().startswith("#"))


class WindowsReleaseZipWriterTests(unittest.TestCase):
    """The Windows release zip is written by write_release_zip.ps1, not by
    Compress-Archive, whose Windows PowerShell 5.1 version names entries with
    backslashes (`reprobuild-<v>-windows-x86_64\\bin\\...`). The ZIP format
    requires '/' (APPNOTE.TXT 4.4.17.1,
    https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT), and
    repro-build-packages.sh's unzip could not unpack such an archive, so no
    MSI was built from it. This case needs no PowerShell: it reads the
    packaging script, so it runs on every host."""

    def test_the_windows_release_zip_is_written_by_the_portable_writer(self):
        code = _powershell_code(PACKAGE_WINDOWS_RELEASE)
        self.assertIn("write_release_zip.ps1", code)
        self.assertNotIn("Compress-Archive", code)
        self.assertNotIn("CreateFromDirectory", code)


@unittest.skipUnless(shutil.which("pwsh"), "needs pwsh (PowerShell 7)")
class WindowsReleaseZipEntryNameTests(unittest.TestCase):
    """write_release_zip.ps1's archive, read back with Python's zipfile: every
    entry name uses '/', the one top-level entry is the tree's own directory,
    every directory (an empty one too) has its `<dir>/` entry, every file is
    there with its bytes, and nothing else is. Under pwsh on Linux the
    platform separator is already '/', so this case shows the names are
    built by the script and not by the platform's paths only together with
    the mutation recorded beside it (names joined with '\\' fail it); on
    Windows PowerShell 5.1 the separator itself is what the script replaces.
    It needs pwsh and is skipped, which counts as not passed, without it; the
    dev shell has it."""

    def build_tree(self, root: Path) -> dict:
        files = {
            "bin/repro.exe": b"MZ client\n",
            "bin/reprobuild.exe": b"MZ engine\n",
            "lib/runtime.dll": b"MZ dll\n",
            "share/repro/completions/repro.ps1": b"Register-ArgumentCompleter\n",
            "share/repro/source/.gitignore": b"build/\n",
            "share/repro/source/deep/er/module.nim": b"echo 1\n",
        }
        for rel, data in files.items():
            path = root.joinpath(*rel.split("/"))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (root / "share" / "repro" / "empty").mkdir(parents=True)
        return files

    def write_zip(self, source: Path, zip_path: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", str(WRITE_RELEASE_ZIP),
             "-SourceDir", str(source), "-DestinationPath", str(zip_path)],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=300)

    def test_windows_release_zip_entry_names_use_forward_slashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            top = f"reprobuild-{VERSION}-windows-x86_64"
            root = Path(tmp) / "pkg" / top
            files = self.build_tree(root)
            zip_path = Path(tmp) / f"{top}.zip"
            run = self.write_zip(root, zip_path)
            self.assertEqual(0, run.returncode, run.stdout + run.stderr)
            self.assertEqual("", run.stdout, "the writer prints nothing on success")
            with zipfile.ZipFile(zip_path) as archive:
                names = archive.namelist()
                self.assertEqual([], [n for n in names if "\\" in n],
                                 "entry names with backslashes")
                self.assertEqual([], [n for n in names if not n.startswith(top + "/")],
                                 "entries outside the one top-level directory")
                self.assertEqual(len(names), len(set(names)), "duplicate entries")
                want_dirs = {f"{top}/"}
                for rel in list(files) + ["share/repro/empty/x"]:
                    parts = rel.split("/")[:-1]
                    for i in range(1, len(parts) + 1):
                        want_dirs.add(f"{top}/" + "/".join(parts[:i]) + "/")
                self.assertEqual(want_dirs, {n for n in names if n.endswith("/")})
                self.assertEqual({f"{top}/{rel}" for rel in files},
                                 {n for n in names if not n.endswith("/")})
                for rel, data in files.items():
                    self.assertEqual(data, archive.read(f"{top}/{rel}"), rel)
                    self.assertTrue(archive.getinfo(f"{top}/{rel}").compress_type
                                    in (zipfile.ZIP_DEFLATED, zipfile.ZIP_STORED))
            # A second run refuses to overwrite the archive and leaves it.
            before = zip_path.read_bytes()
            again = self.write_zip(root, zip_path)
            self.assertNotEqual(0, again.returncode)
            self.assertIn("already exists", again.stdout + again.stderr)
            self.assertEqual(before, zip_path.read_bytes())


if __name__ == "__main__":
    unittest.main()
