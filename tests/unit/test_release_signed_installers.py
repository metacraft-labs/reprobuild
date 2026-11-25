"""The signed installers: the macOS .pkg and the Windows MSI, signed with
stand-in certificates until the production ones are configured.

Under test, with the real tools:
  scripts/release-signing/make-test-installer-certs.sh   the stand-in certificates
  scripts/release-signing/repro-sign-installer.sh        sign + verify, one path
  scripts/release-signing/verify-xar-signature.py        the .pkg verifier
  scripts/release-signing/stand-in-notary.sh             the notary stand-in
  scripts/release/build_signed_installer.sh              the leg's driver (mode)
  scripts/release/refuse_stand_in_signed_assets.sh       the publish refusal

Run in `nix shell nixpkgs#openssl nixpkgs#osslsigncode nixpkgs#rcodesign
nixpkgs#xar nixpkgs#msitools nixpkgs#python3`. A class whose tools are
missing is SKIPPED, which is not a pass.

What is stubbed, and why (the repository's rule: every mock is justified):

* The notary service. Apple notarizes only packages signed with a Developer
  ID certificate Apple issued, so no stand-in-signed package can reach the
  real service, and the production credentials are not available to a test.
  The leg's own stand-in, scripts/release-signing/stand-in-notary.sh, answers
  as `notarytool submit --output-format json` and `stapler staple` do; the
  production-mode cases supply a second stand-in (`SERVICE_NOTARY` below) that
  answers like the real tool (no stand-in mark), so the mode logic is tested
  and the notary's identity is the only thing assumed. What only the real
  service can show is shown only by a run with the production credentials.
* The packages themselves are fixtures, not the release packager's output:
  an MSI built by msitools' `wixl` from a two-file authoring, and a flat
  package (XAR with PackageInfo and Payload) built by `xar`. Signing and
  verification operate on the container format (the MSI's compound file and
  the XAR table of contents), which these are; the packager's own output is
  tested in test_release_native_packages.py. pkgbuild exists only on macOS, so
  the macOS cases (`MacosProductsignTests`) build a real .pkg there.

Nothing here touches a keychain, a certificate store, HOME or the login
profile: every certificate and key is generated into the test's temporary
directory, and the macOS productsign case uses a keychain file created there.
"""

from pathlib import Path
import base64
import gzip
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SIGN_DIR = ROOT / "scripts" / "release-signing"
MAKE_CERTS = SIGN_DIR / "make-test-installer-certs.sh"
SIGNER = SIGN_DIR / "repro-sign-installer.sh"
VERIFY_XAR = SIGN_DIR / "verify-xar-signature.py"
STANDIN_NOTARY = SIGN_DIR / "stand-in-notary.sh"
DRIVER = ROOT / "scripts" / "release" / "build_signed_installer.sh"
REFUSE = ROOT / "scripts" / "release" / "refuse_stand_in_signed_assets.sh"
MARKER = "REPROBUILD UNTRUSTED TEST CERTIFICATE"
MARKER_SUFFIX = ".SIGNED-WITH-A-TEST-CERTIFICATE"
TIMEOUT = 300

# Every variable that selects a mode or a tool; a test starts from none.
SIGNING_VARS = (
    "REPRO_PKG_SIGNING_P12_BASE64", "REPRO_PKG_SIGNING_P12_PASSWORD",
    "REPRO_NOTARY_API_KEY_P8", "REPRO_NOTARY_API_KEY_ID", "REPRO_NOTARY_API_ISSUER_ID",
    "REPRO_AUTHENTICODE_PFX_BASE64", "REPRO_AUTHENTICODE_PFX_PASSWORD",
    "REPRO_SIGNING_ALLOW_TEST_KEY", "REPRO_RELEASE_PUBLISHING", "REPRO_NOTARYTOOL",
    "REPRO_STAPLER", "REPRO_PKG_SIGN_TOOL", "REPRO_AUTHENTICODE_TOOL", "REPRO_SIGNTOOL",
    "REPRO_PKG_TRUST_ROOT", "REPRO_AUTHENTICODE_TRUST_BUNDLE",
    "REPRO_AUTHENTICODE_TIMESTAMP_URL", "REPRO_PKG_TIMESTAMP_URL",
    "REPRO_STANDIN_NOTARY_ANSWER", "REPRO_STANDIN_NOTARY_LOG")

# A notary tool that answers as the real `notarytool submit --output-format
# json` does, WITHOUT the stand-in's mark, and records its calls (credentials
# redacted). Used only by the production-mode cases; see the module header.
SERVICE_NOTARY = r"""#!/bin/sh
printf '%s\n' "$*" | sed 's/--key [^ ]*/--key <redacted>/; s/--key-id [^ ]*/--key-id <redacted>/; s/--issuer [^ ]*/--issuer <redacted>/' >> "$SERVICE_NOTARY_LOG"
case "$1" in
  submit) printf '{"id":"11111111-1111-4111-8111-111111111111","message":"Processing complete","status":"Accepted"}\n' ;;
  staple) printf 'The staple and validate action worked!\n' ;;
  *) exit 2 ;;
esac
"""


def tools(*names):
    return all(shutil.which(n) for n in names)


class Fixture(unittest.TestCase):
    def setUp(self):
        base = os.environ.get("TMPDIR") or None
        tmp = tempfile.TemporaryDirectory(prefix="repro-test-signed-installers-", dir=base)
        self.addCleanup(tmp.cleanup)
        self.work = Path(tmp.name)
        self.tmp = self.work / "tmp"
        self.tmp.mkdir()

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if k not in SIGNING_VARS}
        env["TMPDIR"] = str(self.tmp)
        env.update({k: str(v) for k, v in extra.items()})
        return env

    def run_cmd(self, cmd, env=None, cwd=None):
        return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, check=False,
                              timeout=TIMEOUT, env=env or self.env(), cwd=cwd)

    def certs(self, name="certs", unmarked=False):
        d = self.work / name
        cmd = ["sh", MAKE_CERTS, "--dir", d] + (["--unmarked"] if unmarked else [])
        r = self.run_cmd(cmd)
        self.assertEqual(0, r.returncode, r.stderr)
        return d

    def openssl_text(self, *args):
        r = self.run_cmd(["openssl", *args])
        self.assertEqual(0, r.returncode, r.stderr)
        return r.stdout

    def driver(self, ecosystem, package, out, **env):
        return self.run_cmd(["sh", DRIVER, "--ecosystem", ecosystem, "--package", package, "--out", out],
                            env=self.env(**env))

    # ---------------------------------------------------------------- fixtures
    def msi(self, name="reprobuild-9.8.7-windows-x86_64.msi"):
        src = self.work / "msi-src"
        src.mkdir(exist_ok=True)
        (src / "hello.txt").write_text("hello from the fixture\n" * 50)
        wxs = src / "fixture.wxs"
        wxs.write_text("""<?xml version="1.0"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
 <Product Id="*" Name="Fixture" Language="1033" Version="1.0.0" Manufacturer="Fixture"
          UpgradeCode="{6F2D8C1E-4B7A-4E39-9C55-2A1B3C4D5E6F}">
  <Package InstallerVersion="200" Compressed="yes" InstallScope="perMachine"/>
  <Media Id="1" Cabinet="fixture.cab" EmbedCab="yes"/>
  <Directory Id="TARGETDIR" Name="SourceDir"><Directory Id="ProgramFilesFolder">
   <Directory Id="D" Name="Fixture">
    <Component Id="C" Guid="{6F2D8C1E-4B7A-4E39-9C55-2A1B3C4D5E70}"><File Id="F" Source="hello.txt"/></Component>
   </Directory></Directory></Directory>
  <Feature Id="Main" Level="1"><ComponentRef Id="C"/></Feature>
 </Product>
</Wix>
""")
        out = self.work / name
        r = self.run_cmd(["wixl", "-o", out, wxs], cwd=src)
        self.assertEqual(0, r.returncode, r.stderr)
        return out

    def pkg(self, name="reprobuild-9.8.7-darwin-aarch64.pkg"):
        src = self.work / "pkg-src"
        src.mkdir(exist_ok=True)
        (src / "PackageInfo").write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<pkg-info format-version="2" identifier="com.example.fixture" version="1.0" '
            'install-location="/" auth="root"><payload numberOfFiles="1" installKBytes="1"/></pkg-info>\n')
        (src / "Payload").write_bytes(gzip.compress(b"fixture payload " * 400))
        out = self.work / name
        r = self.run_cmd(["xar", "--compression", "none", "-cf", out, "PackageInfo", "Payload"], cwd=src)
        self.assertEqual(0, r.returncode, r.stderr)
        return out


def flip_byte(path, offset):
    data = bytearray(path.read_bytes())
    data[offset] ^= 0x01
    path.write_bytes(bytes(data))


# ═════════════════════════════════════════════════════ the certificates
@unittest.skipUnless(tools("openssl"), "needs openssl")
class StandInCertificateTests(Fixture):
    DEVID_EKU = "1.2.840.113635.100.4.13"
    DEVID_LEAF = "1.2.840.113635.100.6.1.14"
    DEVID_CA = "1.2.840.113635.100.6.2.6"

    def developer_id_installer_shape(self, leaf, ca):
        """The checks a test of the shape makes; returns the failures."""
        text = self.openssl_text("x509", "-in", leaf, "-noout", "-text")
        failures = []
        if self.DEVID_EKU not in text.split("Extended Key Usage", 1)[-1].split("\n", 2)[1]:
            failures.append("no Developer ID Installer extended key usage")
        if f"{self.DEVID_LEAF}: critical" not in text:
            failures.append("no critical Developer ID Installer leaf extension")
        if "CA:FALSE" not in text:
            failures.append("not CA:FALSE")
        if "Developer ID Installer: " not in text:
            failures.append("subject not in Apple's 'Developer ID Installer: <name> (<team>)' form")
        if self.DEVID_CA not in self.openssl_text("x509", "-in", ca, "-noout", "-text"):
            failures.append("intermediate lacks the Developer ID CA marker")
        return failures

    def test_cs_m8e_the_pkg_leaf_is_shaped_like_a_developer_id_installer_certificate(self):
        d = self.certs()
        self.assertEqual([], self.developer_id_installer_shape(d / "pkg-signer.pem", d / "pkg-ca.pem"))
        self.assertIn(f"O={MARKER}", self.openssl_text(
            "x509", "-in", d / "pkg-signer.pem", "-noout", "-subject"))
        # Chains to the stand-in root (OpenSSL does not know Apple's critical
        # leaf extension, hence -ignore_critical; the EKU is checked above).
        r = self.run_cmd(["openssl", "verify", "-ignore_critical", "-CAfile", d / "pkg-root.pem",
                          "-untrusted", d / "pkg-ca.pem", d / "pkg-signer.pem"])
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)
        # The .p12 opens with its password and pairs the key with the leaf.
        leaf = self.openssl_text("pkcs12", "-in", d / "pkg-signer.p12", "-passin",
                                 f"file:{d / 'pkg-signer.p12.password'}", "-clcerts", "-nokeys")
        self.assertIn("Developer ID Installer: Reprobuild Stand-in (TESTTEAM01)", leaf)

    def test_cs_m8e_the_shape_check_rejects_a_plain_code_signing_certificate(self):
        """Control: the Authenticode certificate is not Developer ID-shaped."""
        d = self.certs()
        failures = self.developer_id_installer_shape(d / "authenticode.pem", d / "authenticode.pem")
        self.assertIn("no Developer ID Installer extended key usage", failures)
        self.assertIn("intermediate lacks the Developer ID CA marker", failures)

    def test_cs_m8e_the_authenticode_certificate_is_self_signed_for_code_signing(self):
        d = self.certs()
        text = self.openssl_text("x509", "-in", d / "authenticode.pem", "-noout", "-text")
        self.assertIn("Code Signing", text)
        self.assertIn("CA:FALSE", text)
        subj = self.openssl_text("x509", "-in", d / "authenticode.pem", "-noout", "-subject", "-issuer")
        lines = [ln.split("=", 1)[1] for ln in subj.splitlines()]
        self.assertEqual(lines[0], lines[1], "not self-signed")
        self.assertIn(MARKER, lines[0])
        # Control: the .pkg leaf does not carry the code-signing usage.
        self.assertNotIn("Code Signing", self.openssl_text("x509", "-in", d / "pkg-signer.pem", "-noout", "-text"))

    def test_cs_m8e_no_private_key_is_left_outside_the_containers(self):
        d = self.certs()
        self.assertEqual(sorted(p.name for p in d.iterdir()), sorted([
            "authenticode.pem", "authenticode.pfx", "authenticode.pfx.password",
            "pkg-ca.pem", "pkg-root.pem", "pkg-signer.p12", "pkg-signer.p12.password", "pkg-signer.pem"]))
        for pem in d.glob("*.pem"):
            self.assertNotIn("PRIVATE KEY", pem.read_text(), pem)
        self.assertEqual(0o700, d.stat().st_mode & 0o777)

    def test_cs_m8e_unmarked_certificates_carry_no_marker(self):
        d = self.certs(unmarked=True)
        for pem in ("pkg-signer.pem", "authenticode.pem"):
            self.assertNotIn(MARKER, self.openssl_text("x509", "-in", d / pem, "-noout", "-subject"))

    def test_cs_m8e_a_non_empty_directory_is_refused(self):
        d = self.work / "busy"
        d.mkdir()
        (d / "left-over").write_text("x")
        r = self.run_cmd(["sh", MAKE_CERTS, "--dir", d])
        self.assertNotEqual(0, r.returncode)
        self.assertIn("not empty", r.stderr)


# ═════════════════════════════════════════════════════════════ the MSI
@unittest.skipUnless(tools("openssl", "osslsigncode", "wixl"), "needs openssl, osslsigncode and wixl (msitools)")
class MsiSigningTests(Fixture):
    def verify(self, msi, root):
        return self.run_cmd(["osslsigncode", "verify", "-CAfile", root, "-in", msi])

    def sign_standin(self):
        out = self.work / "out"
        r = self.driver("msi", self.msi(), out)
        self.assertEqual(0, r.returncode, r.stderr)
        return out / "reprobuild-9.8.7-windows-x86_64.msi", r

    def test_cs_m8e_the_msi_is_signed_with_the_stand_in_and_verifies_against_it(self):
        msi, r = self.sign_standin()
        report = Path(str(msi) + ".signing-report.txt").read_text()
        self.assertIn("mode: standin", report)
        self.assertIn("signing: class=test tool=osslsigncode", report)
        self.assertTrue(Path(str(msi) + MARKER_SUFFIX).is_file())
        root = Path(str(msi) + ".stand-in-root.pem")
        self.assertNotIn("PRIVATE KEY", root.read_text())
        v = self.verify(msi, root)
        self.assertEqual(0, v.returncode, v.stdout + v.stderr)
        self.assertIn("Signature verification: ok", v.stdout)
        self.assertIn(MARKER, v.stdout)
        digest, name = Path(str(msi) + ".sha256").read_text().split()
        self.assertEqual(name, msi.name)
        # No key, and none of the run's scratch, is left in the output.
        for f in msi.parent.iterdir():
            self.assertNotIn(b"PRIVATE KEY", f.read_bytes(), f)
        self.assertEqual([], list(self.tmp.iterdir()), "the run left scratch behind")

    def test_cs_m8e_a_tampered_msi_fails_verification(self):
        msi, _ = self.sign_standin()
        root = Path(str(msi) + ".stand-in-root.pem")
        data = msi.read_bytes()
        cab = data.find(b"MSCF")
        self.assertGreater(cab, 0, "no embedded cabinet in the fixture")
        flip_byte(msi, cab + 200)
        v = self.verify(msi, root)
        self.assertNotEqual(0, v.returncode, v.stdout)

    def test_cs_m8e_a_signature_by_a_different_root_fails(self):
        msi, _ = self.sign_standin()
        other = self.certs("other")
        v = self.verify(msi, other / "authenticode.pem")
        self.assertNotEqual(0, v.returncode, v.stdout)

    def test_cs_m8e_an_unsigned_msi_fails(self):
        d = self.certs()
        v = self.verify(self.msi(), d / "authenticode.pem")
        self.assertNotEqual(0, v.returncode, v.stdout)

    def test_cs_m8e_the_signer_refuses_a_test_certificate_unless_admitted(self):
        d = self.certs()
        base = ["sh", SIGNER, "--kind", "msi", "--in", self.msi(), "--out", self.work / "s.msi",
                "--identity", d / "authenticode.pfx", "--password-file", d / "authenticode.pfx.password",
                "--trust-root", d / "authenticode.pem"]
        r = self.run_cmd(base)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("REPRO_SIGNING_ALLOW_TEST_KEY is not 1", r.stderr)
        self.assertFalse((self.work / "s.msi").exists())
        r = self.run_cmd(base, env=self.env(REPRO_SIGNING_ALLOW_TEST_KEY=1, REPRO_RELEASE_PUBLISHING=1))
        self.assertNotEqual(0, r.returncode)
        self.assertIn("publishing run", r.stderr)
        # Control: admitted, on a run that does not publish, it signs.
        r = self.run_cmd(base, env=self.env(REPRO_SIGNING_ALLOW_TEST_KEY=1))
        self.assertEqual(0, r.returncode, r.stderr)
        self.assertTrue(r.stdout.startswith("class=test tool=osslsigncode"), r.stdout)

    def test_cs_m8e_a_publishing_run_refuses_the_stand_in_mode(self):
        r = self.driver("msi", self.msi(), self.work / "out", REPRO_RELEASE_PUBLISHING=1)
        self.assertNotEqual(0, r.returncode)
        # The driver's own refusal, before any stand-in is generated -- not
        # the signer's later one, which would also stop it (that refusal has
        # its own case above).
        self.assertIn("build-signed-installer: REFUSED: no production credentials for the msi "
                      "and this is a publishing run", r.stderr)
        self.assertNotIn("repro-sign-installer:", r.stderr)
        self.assertFalse((self.work / "out" / "reprobuild-9.8.7-windows-x86_64.msi").exists())

    # -------------------------------------------------- production mode
    def production_env(self, certs, **extra):
        pfx = (certs / "authenticode.pfx").read_bytes()
        return dict(REPRO_AUTHENTICODE_PFX_BASE64=base64.b64encode(pfx).decode(),
                    REPRO_AUTHENTICODE_PFX_PASSWORD=(certs / "authenticode.pfx.password").read_text(),
                    REPRO_AUTHENTICODE_TIMESTAMP_URL="none", **extra)

    def test_cs_m8e_the_secrets_alone_select_production_mode(self):
        """Throwaway, unmarked credentials in the production secrets: the
        same driver and signer, a production report, and the trust is the
        configured root (REPRO_AUTHENTICODE_TRUST_BUNDLE), not a stand-in's."""
        d = self.certs(unmarked=True)
        out = self.work / "out"
        r = self.driver("msi", self.msi(), out,
                        **self.production_env(d, REPRO_AUTHENTICODE_TRUST_BUNDLE=d / "authenticode.pem"))
        self.assertEqual(0, r.returncode, r.stderr)
        msi = out / "reprobuild-9.8.7-windows-x86_64.msi"
        report = Path(str(msi) + ".signing-report.txt").read_text()
        self.assertIn("mode: production", report)
        self.assertIn("signing: class=platform tool=osslsigncode", report)
        self.assertFalse(Path(str(msi) + MARKER_SUFFIX).exists())
        self.assertFalse(Path(str(msi) + ".stand-in-root.pem").exists())
        # And the publish refusal lets it through.
        p = self.run_cmd(["sh", REFUSE, out])
        self.assertEqual(0, p.returncode, p.stdout + p.stderr)

    def test_cs_m8e_production_mode_refuses_a_certificate_the_platform_does_not_trust(self):
        """Without a configured root, the production signature must verify
        against the default trust, which a throwaway certificate fails."""
        d = self.certs(unmarked=True)
        out = self.work / "out"
        r = self.driver("msi", self.msi(), out, **self.production_env(d))
        self.assertNotEqual(0, r.returncode)
        self.assertIn("mode: production", r.stderr)
        self.assertIn("osslsigncode does not verify the signed MSI", r.stderr)
        self.assertFalse((out / "reprobuild-9.8.7-windows-x86_64.msi").exists())

    def test_cs_m8e_production_mode_refuses_a_stand_in_certificate(self):
        d = self.certs()
        r = self.driver("msi", self.msi(), self.work / "out", **self.production_env(d))
        self.assertNotEqual(0, r.returncode)
        self.assertIn("REPRO_SIGNING_ALLOW_TEST_KEY is not 1", r.stderr)
        # Even if the admission variable leaks into the environment.
        r = self.driver("msi", self.msi(), self.work / "out2",
                        **self.production_env(d, REPRO_SIGNING_ALLOW_TEST_KEY=1))
        self.assertNotEqual(0, r.returncode)
        # The signer refuses it (production mode gives it no stand-in root);
        # the driver's own check behind that names it too, were it to sign.
        self.assertIn("a TEST certificate", r.stderr)
        self.assertFalse((self.work / "out2" / "reprobuild-9.8.7-windows-x86_64.msi").exists())

    def test_cs_m8e_incomplete_production_credentials_are_refused(self):
        d = self.certs(unmarked=True)
        env = self.production_env(d)
        del env["REPRO_AUTHENTICODE_PFX_PASSWORD"]
        r = self.driver("msi", self.msi(), self.work / "out", **env)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("missing: REPRO_AUTHENTICODE_PFX_PASSWORD", r.stderr)


# ═════════════════════════════════════════════════════════════ the .pkg
@unittest.skipUnless(tools("openssl", "rcodesign", "xar"), "needs openssl, rcodesign (apple-codesign) and xar")
class PkgSigningTests(Fixture):
    def verify(self, pkg, root):
        return self.run_cmd([sys.executable, "-I", VERIFY_XAR, pkg, "--trust-root", root])

    def sign_standin(self, **env):
        out = self.work / "out"
        log = self.work / "notary.log"
        r = self.driver("pkg", self.pkg(), out, REPRO_STANDIN_NOTARY_LOG=log, **env)
        return out / "reprobuild-9.8.7-darwin-aarch64.pkg", r, log

    def test_cs_m8e_the_pkg_is_signed_notarized_and_stapled_against_the_stand_ins(self):
        pkg, r, log = self.sign_standin()
        self.assertEqual(0, r.returncode, r.stderr)
        report = Path(str(pkg) + ".signing-report.txt").read_text()
        self.assertIn("mode: standin", report)
        self.assertIn("signing: class=test tool=rcodesign", report)
        self.assertIn("(stand-in), status Accepted", report)
        self.assertIn("stapled: yes (stand-in)", report)
        self.assertTrue(Path(str(pkg) + MARKER_SUFFIX).is_file())
        v = self.verify(pkg, Path(str(pkg) + ".stand-in-root.pem"))
        self.assertEqual(0, v.returncode, v.stderr)
        self.assertIn("Developer ID Installer: Reprobuild Stand-in (TESTTEAM01)", v.stdout)
        self.assertIn("CMS signature verified", v.stdout)
        calls = log.read_text().splitlines()
        self.assertEqual(2, len(calls), calls)
        self.assertRegex(calls[0], r"^notarytool submit \S+\.pkg --key <redacted> --key-id <redacted> "
                                   r"--issuer <redacted> --wait --output-format json$")
        self.assertRegex(calls[1], r"^stapler staple \S+\.pkg$")
        self.assertEqual([], list(self.tmp.iterdir()), "the run left scratch behind")

    def test_cs_m8e_a_tampered_pkg_fails_verification(self):
        pkg, r, _ = self.sign_standin()
        self.assertEqual(0, r.returncode, r.stderr)
        root = Path(str(pkg) + ".stand-in-root.pem")
        flip_byte(pkg, len(pkg.read_bytes()) - 100)   # inside the Payload's data
        v = self.verify(pkg, root)
        self.assertNotEqual(0, v.returncode)
        self.assertIn("does not match its archived", v.stderr)

    def test_cs_m8e_a_changed_table_of_contents_fails_verification(self):
        pkg, r, _ = self.sign_standin()
        self.assertEqual(0, r.returncode, r.stderr)
        flip_byte(pkg, 40)   # inside the compressed table of contents
        v = self.verify(pkg, Path(str(pkg) + ".stand-in-root.pem"))
        self.assertNotEqual(0, v.returncode)

    def test_cs_m8e_a_pkg_signature_by_a_different_root_fails(self):
        pkg, r, _ = self.sign_standin()
        self.assertEqual(0, r.returncode, r.stderr)
        other = self.certs("other")
        v = self.verify(pkg, other / "pkg-root.pem")
        self.assertNotEqual(0, v.returncode)
        self.assertIn("does not chain to the trust root", v.stderr)

    def test_cs_m8e_an_unsigned_pkg_fails(self):
        d = self.certs()
        v = self.verify(self.pkg(), d / "pkg-root.pem")
        self.assertNotEqual(0, v.returncode)
        self.assertIn("not signed", v.stderr)

    def test_cs_m8e_an_invalid_notarization_fails_the_leg(self):
        pkg, r, log = self.sign_standin(REPRO_STANDIN_NOTARY_ANSWER="Invalid")
        self.assertNotEqual(0, r.returncode)
        self.assertIn("status 'Invalid', not Accepted", r.stderr)
        self.assertIn("Archive contains critical validation errors", r.stderr)  # the log was fetched
        self.assertFalse(pkg.exists(), "a package that failed notarization was left in the output")
        self.assertIn("notarytool log", log.read_text())

    def test_cs_m8e_the_stand_in_notary_never_records_a_credential(self):
        _, r, log = self.sign_standin()
        self.assertEqual(0, r.returncode, r.stderr)
        text = log.read_text()
        self.assertNotIn("notary.p8", text)
        self.assertNotIn("STANDIN000", text)

    # -------------------------------------------------- production mode
    def production_env(self, certs, notary):
        p12 = (certs / "pkg-signer.p12").read_bytes()
        key = self.run_cmd(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"])
        return dict(REPRO_PKG_SIGNING_P12_BASE64=base64.b64encode(p12).decode(),
                    REPRO_PKG_SIGNING_P12_PASSWORD=(certs / "pkg-signer.p12.password").read_text(),
                    REPRO_NOTARY_API_KEY_P8=key.stdout, REPRO_NOTARY_API_KEY_ID="THROWAWAY1",
                    REPRO_NOTARY_API_ISSUER_ID="22222222-2222-4222-8222-222222222222",
                    REPRO_PKG_TIMESTAMP_URL="none", REPRO_NOTARYTOOL=notary, REPRO_STAPLER=notary)

    def service_notary(self):
        script = self.work / "service-notary.sh"
        script.write_text(SERVICE_NOTARY)
        script.chmod(0o755)
        return script

    def test_cs_m8e_the_secrets_alone_select_production_mode_for_the_pkg(self):
        d = self.certs(unmarked=True)
        out = self.work / "out"
        log = self.work / "service.log"
        r = self.driver("pkg", self.pkg(), out, SERVICE_NOTARY_LOG=log,
                        REPRO_PKG_TRUST_ROOT=d / "pkg-root.pem", **self.production_env(d, self.service_notary()))
        self.assertEqual(0, r.returncode, r.stderr)
        pkg = out / "reprobuild-9.8.7-darwin-aarch64.pkg"
        report = Path(str(pkg) + ".signing-report.txt").read_text()
        self.assertIn("mode: production", report)
        self.assertIn("signing: class=platform tool=rcodesign", report)
        self.assertIn("(service), status Accepted", report)
        self.assertFalse(Path(str(pkg) + MARKER_SUFFIX).exists())
        self.assertRegex(log.read_text().splitlines()[0],
                         r"^submit \S+\.pkg --key <redacted> --key-id <redacted> --issuer <redacted> "
                         r"--wait --output-format json$")

    def test_cs_m8e_production_mode_refuses_the_stand_in_notary(self):
        d = self.certs(unmarked=True)
        r = self.driver("pkg", self.pkg(), self.work / "out", REPRO_PKG_TRUST_ROOT=d / "pkg-root.pem",
                        **self.production_env(d, f"sh {STANDIN_NOTARY} notarytool"))
        self.assertNotEqual(0, r.returncode)
        self.assertIn("answered by the stand-in notary", r.stderr)

    def test_cs_m8e_production_mode_without_platform_trust_refuses_the_pkg(self):
        """Off macOS, with no Apple root configured, nothing can establish
        platform trust, so a production signature is refused."""
        if shutil.which("pkgutil"):
            self.skipTest("pkgutil is present (macOS): the platform check differs there")
        d = self.certs(unmarked=True)
        r = self.driver("pkg", self.pkg(), self.work / "out", **self.production_env(d, self.service_notary()))
        self.assertNotEqual(0, r.returncode)
        self.assertIn("no verifier could run", r.stderr)

    def test_cs_m8e_incomplete_pkg_credentials_are_refused(self):
        d = self.certs(unmarked=True)
        env = self.production_env(d, self.service_notary())
        del env["REPRO_NOTARY_API_ISSUER_ID"]
        r = self.driver("pkg", self.pkg(), self.work / "out", **env)
        self.assertNotEqual(0, r.returncode)
        self.assertIn("missing: REPRO_NOTARY_API_ISSUER_ID", r.stderr)


# ══════════════════════════════════════════════════ the publish refusal
@unittest.skipUnless(tools("openssl", "osslsigncode", "wixl", "rcodesign", "xar"),
                     "needs openssl, osslsigncode, wixl, rcodesign and xar")
class PublishRefusalTests(Fixture):
    def test_cs_m8e_stand_in_signed_packages_are_refused_even_without_their_markers(self):
        out = self.work / "out"
        for eco, pkg in (("msi", self.msi()), ("pkg", self.pkg())):
            r = self.driver(eco, pkg, out, REPRO_STANDIN_NOTARY_LOG=self.work / "n.log")
            self.assertEqual(0, r.returncode, r.stderr)
        staging = self.work / "staging"
        staging.mkdir()
        for f in out.iterdir():
            shutil.copy(f, staging)
        r = self.run_cmd(["sh", REFUSE, staging])
        self.assertNotEqual(0, r.returncode)
        self.assertIn(MARKER_SUFFIX, r.stderr)
        # Drop every marker and stand-in root: the signatures still say it.
        for f in staging.iterdir():
            if f.name.endswith((MARKER_SUFFIX, ".stand-in-root.pem")):
                f.unlink()
        r = self.run_cmd(["sh", REFUSE, staging])
        self.assertNotEqual(0, r.returncode)
        for name in ("reprobuild-9.8.7-windows-x86_64.msi", "reprobuild-9.8.7-darwin-aarch64.pkg"):
            self.assertIn(f"{name} is signed with a stand-in", r.stderr)

    def test_cs_m8e_unsigned_and_other_assets_pass(self):
        """Control: nothing stand-in-signed, nothing refused."""
        staging = self.work / "staging"
        staging.mkdir()
        shutil.copy(self.msi(), staging)
        shutil.copy(self.pkg(), staging)
        (staging / "reprobuild-9.8.7-linux-x86_64.tar.gz").write_bytes(gzip.compress(MARKER.encode()))
        r = self.run_cmd(["sh", REFUSE, staging])
        self.assertEqual(0, r.returncode, r.stdout + r.stderr)


# ══════════════════════════════════════════════════ macOS: productsign
@unittest.skipUnless(sys.platform == "darwin" and tools("pkgbuild", "productsign", "pkgutil", "security",
                                                        "spctl", "openssl"),
                     "macOS only: pkgbuild, productsign, pkgutil, security and spctl")
class MacosProductsignTests(Fixture):
    """The leg's own path on macOS: pkgbuild, productsign with a keychain
    created in the test's directory (never the login keychain, never added to
    the search list), pkgutil, spctl. Run on a macOS host."""

    def real_pkg(self):
        root = self.work / "root" / "usr" / "local" / "bin"
        root.mkdir(parents=True)
        (root / "repro-fixture").write_text("#!/bin/sh\necho fixture\n")
        (root / "repro-fixture").chmod(0o755)
        pkg = self.work / "reprobuild-9.8.7-darwin-aarch64.pkg"
        r = self.run_cmd(["pkgbuild", "--root", self.work / "root", "--identifier", "com.example.fixture",
                          "--version", "1.0", "--install-location", "/", pkg])
        self.assertEqual(0, r.returncode, r.stderr)
        return pkg

    def test_cs_m8e_productsign_signs_with_the_stand_in_and_gatekeeper_rejects_it(self):
        keychains_before = self.run_cmd(["security", "list-keychains"]).stdout
        out = self.work / "out"
        r = self.driver("pkg", self.real_pkg(), out, REPRO_PKG_SIGN_TOOL="productsign")
        self.assertEqual(0, r.returncode, r.stderr)
        pkg = out / "reprobuild-9.8.7-darwin-aarch64.pkg"
        report = Path(str(pkg) + ".signing-report.txt").read_text()
        self.assertIn("signing: class=test tool=productsign", report)
        self.assertIn("gatekeeper: rejected, as a stand-in must be", report)
        chk = self.run_cmd(["pkgutil", "--check-signature", pkg])
        self.assertIn("Developer ID Installer: Reprobuild Stand-in (TESTTEAM01)", chk.stdout)
        v = self.run_cmd([sys.executable, "-I", VERIFY_XAR, pkg, "--trust-root",
                          Path(str(pkg) + ".stand-in-root.pem")])
        self.assertEqual(0, v.returncode, v.stderr)
        self.assertEqual(keychains_before, self.run_cmd(["security", "list-keychains"]).stdout,
                         "the keychain search list changed")

    def test_cs_m8e_rcodesign_on_macos_matches(self):
        if not tools("rcodesign"):
            self.skipTest("rcodesign not on PATH")
        out = self.work / "out"
        r = self.driver("pkg", self.real_pkg(), out, REPRO_PKG_SIGN_TOOL="rcodesign")
        self.assertEqual(0, r.returncode, r.stderr)
        chk = self.run_cmd(["pkgutil", "--check-signature", out / "reprobuild-9.8.7-darwin-aarch64.pkg"])
        self.assertIn("Developer ID Installer: Reprobuild Stand-in (TESTTEAM01)", chk.stdout)


if __name__ == "__main__":
    unittest.main()
