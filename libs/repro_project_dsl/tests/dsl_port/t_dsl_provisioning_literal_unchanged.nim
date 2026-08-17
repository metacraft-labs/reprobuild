## Regression guard for the literal path of `tarball(...)` provisioning.
##
## `parseTarballProvisioning` used to store the VALUE of each string field and
## the emitters re-quoted it with `escForCode`. It now stores emittable SOURCE
## and the emitters splice it verbatim, so that a `const` or a `func` call
## survives instead of being replaced by its own spelling.
##
## Every real consumer in the tree writes literals — `repro_dsl_stdlib`'s `nim`
## and `nsis` packages are the only `tarball(...)` call sites outside the DSL's
## own tests. For them the emitted source must be byte-identical to before, so
## this pins the shapes they actually use: every field set explicitly, plus the
## two DERIVED defaults (`packageId` from `url`, `lockIdentity` from `sha256`)
## which moved from macro-time string concatenation into the emitted code.
##
## The derived-default cases matter most. They were computed by pasting the
## macro's own view of the value; they are now generated as an expression over
## whatever the field holds. If that expression is malformed the failure is a
## compile error here rather than a wrong lock identity discovered at fetch
## time.

import std/[unittest]

import repro_project_dsl
import repro_dsl_stdlib/types

package tarballLiteralPkg:
  provisioning:
    # The `nim` / `nsis` shape: every field explicit, all literals.
    tarball url = "https://nim-lang.org/download/nim-2.2.10_x64.zip",
      sha256 = "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f",
      archiveType = "zip",
      stripComponents = 1,
      executablePath = "bin/nim.exe",
      packageId = "nim@2.2.10",
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:nim@2.2.10:sha256:fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"

package tarballDefaultsPkg:
  provisioning:
    # Neither packageId nor lockIdentity given — both are derived. These are
    # the two defaults that moved into the emitted code.
    tarball url = "https://example.invalid/pkg-1.0.tar.gz",
      sha256 = "1111111111111111111111111111111111111111111111111111111111111111",
      executablePath = "bin/pkg"

package tarballEscapingPkg:
  provisioning:
    # A URL carrying characters that must survive the source round-trip:
    # a percent-escape (as in the real NSIS Sourceforge URL, "NSIS%203") and
    # a backslash, which is the one that would break naive re-emission.
    tarball url = "https://example.invalid/a%20b/c\\d?x=1&y=2",
      sha256 = "2222222222222222222222222222222222222222222222222222222222222222",
      executablePath = "bin/quoted"

proc provisioningOf(name: string): TarballProvisioningDef =
  for p in registeredPackages():
    if p.packageName == name:
      check p.tarballProvisioning.len == 1
      return p.tarballProvisioning[0]
  raise newException(ValueError, "package not found: " & name)

suite "tarball literal provisioning is unchanged":
  test "every explicitly-set field round-trips":
    let t = provisioningOf("tarballLiteralPkg")
    check t.url == "https://nim-lang.org/download/nim-2.2.10_x64.zip"
    check t.sha256 ==
      "fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"
    check t.archiveType == "zip"
    check t.stripComponents == 1
    check t.executablePath == "bin/nim.exe"
    check t.packageId == "nim@2.2.10"
    check t.cpu == "x86_64"
    check t.os == "windows"
    check t.lockIdentity ==
      "tarball:nim@2.2.10:sha256:fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f"

  test "archiveType defaults to tar.gz when unset":
    check provisioningOf("tarballDefaultsPkg").archiveType == "tar.gz"

  test "stripComponents defaults to 0 when unset":
    check provisioningOf("tarballDefaultsPkg").stripComponents == 0

  test "an unset cpu/os stays empty rather than becoming a stray literal":
    let t = provisioningOf("tarballDefaultsPkg")
    check t.cpu == ""
    check t.os == ""

  test "packageId derives from url":
    check provisioningOf("tarballDefaultsPkg").packageId ==
      "https://example.invalid/pkg-1.0.tar.gz"

  test "lockIdentity derives from sha256":
    check provisioningOf("tarballDefaultsPkg").lockIdentity ==
      "sha256:1111111111111111111111111111111111111111111111111111111111111111"

  test "a url with escapes and a backslash survives the source round-trip":
    let t = provisioningOf("tarballEscapingPkg")
    check t.url == "https://example.invalid/a%20b/c\\d?x=1&y=2"
    # Derived from the same field, so it must carry the escapes too.
    check t.packageId == "https://example.invalid/a%20b/c\\d?x=1&y=2"
