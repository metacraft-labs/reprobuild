## C1 P4: foreign-package DSL parse + schema-validation test.
##
## Exercises the standalone DSL surface from the campaign spec § C1:
##
##   * ``aptPackage(<name>, snapshot = <pin>)`` returns a
##     ``ptForeignBundle`` PackageRef whose fields match what B1's
##     ``parsePackageCall`` produces for the equivalent inline
##     ``package(apt, <name>, snapshot = <pin>)`` invocation. This is
##     the "DSL surface composes with B1" claim from the campaign spec.
##   * Snapshot pin validation: bad snapshot format rejected
##     (``EMalformedSnapshot``).
##   * Distro validation: ``mkForeignPackageRef`` rejects unknown distros
##     (``EUnknownForeignDistro``). The three thin entry points
##     (``aptPackage`` / ``dnfPackage`` / ``pacmanPackage``) hard-wire
##     the distro so this branch is exercised at the helper level.
##   * Missing package name rejected (``EMissingRequiredField``).
##   * ``readForeignCatalog`` rejects malformed JSON: bad snapshot,
##     unknown distro, missing package name, unsupported format_version.

import std/[os, unittest]

import repro_system_apply  # B1 surface for cross-checking PackageRef shape
import repro_dsl_stdlib/packages/foreign_apt
import repro_dsl_stdlib/packages/foreign_dnf
import repro_dsl_stdlib/packages/foreign_pacman

const RecipesRoot =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "catalog" / "foreign"

suite "C1 DSL parse + schema validation":

  test "aptPackage round-trip composes with B1 parsePackageCall":
    # Standalone DSL value
    let pinned = "debian/bookworm/20260601T000000Z"
    let standalone = aptPackage("git", snapshot = pinned)
    check standalone.tier == ptForeignBundle
    check standalone.distro == "apt"
    check standalone.name == "git"
    check standalone.snapshot == pinned

    # B1 inline value via parseSystemConfigSource
    let src = """
system unitTest:
  packages = [
    package(apt, "git", snapshot = """" & pinned & """"),
  ]
"""
    let cfg = parseSystemConfigSource("test://compose.nim", src)
    check cfg.packages.len == 1
    let inline = cfg.packages[0]
    check inline.tier == standalone.tier
    check inline.distro == standalone.distro
    check inline.name == standalone.name
    check inline.snapshot == standalone.snapshot

  test "dnfPackage produces ptForeignBundle":
    let p = dnfPackage("neovim", snapshot = "fedora/39/20260601")
    check p.tier == ptForeignBundle
    check p.distro == "dnf"
    check p.name == "neovim"
    check p.snapshot == "fedora/39/20260601"

  test "pacmanPackage produces ptForeignBundle":
    let p = pacmanPackage("htop", snapshot = "archlinux/rolling/20260601")
    check p.tier == ptForeignBundle
    check p.distro == "pacman"
    check p.name == "htop"

  test "bad snapshot format raises EMalformedSnapshot":
    expect EMalformedSnapshot:
      discard aptPackage("git", snapshot = "not-a-pin")
    expect EMalformedSnapshot:
      discard aptPackage("git", snapshot = "")
    # An empty middle segment is also malformed
    expect EMalformedSnapshot:
      discard aptPackage("git", snapshot = "debian//20260601T000000Z")
    # Only two segments is malformed
    expect EMalformedSnapshot:
      discard aptPackage("git", snapshot = "archlinux/20260601")

  test "missing package name raises EMissingRequiredField":
    expect EMissingRequiredField:
      discard aptPackage("", snapshot = "debian/bookworm/20260601T000000Z")
    expect EMissingRequiredField:
      discard dnfPackage("", snapshot = "fedora/39/20260601")
    expect EMissingRequiredField:
      discard pacmanPackage("", snapshot = "archlinux/rolling/20260601")

  test "unknown distro raises EUnknownForeignDistro via mkForeignPackageRef":
    # The three entry-point procs hard-wire the distro, so we exercise
    # the helper directly to cover the third validation axis.
    expect EUnknownForeignDistro:
      discard mkForeignPackageRef("zypper", "git",
        "opensuse/leap/20260601T000000Z")
    expect EUnknownForeignDistro:
      discard mkForeignPackageRef("brew", "git",
        "homebrew/cellar/20260601T000000Z")

  test "readForeignCatalog rejects unsupported format_version":
    let src = """
{
  "dependency_closure": [],
  "format_version": 999,
  "package": {
    "distro": "apt",
    "name": "git",
    "snapshot": "debian/bookworm/20260601T000000Z",
    "version": "1.0"
  },
  "provisioning_methods": [
    {
      "kind": "direct-snapshot-url",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "size_bytes": 0,
      "url": "https://example/x.deb"
    }
  ],
  "signed_envelope": null
}
"""
    expect EForeignCatalogVersion:
      discard readForeignCatalogFromString(src)

  test "readForeignCatalog rejects unknown distro":
    let src = """
{
  "dependency_closure": [],
  "format_version": 1,
  "package": {
    "distro": "zypper",
    "name": "git",
    "snapshot": "opensuse/leap/20260601T000000Z",
    "version": "1.0"
  },
  "provisioning_methods": [
    {
      "kind": "direct-snapshot-url",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "size_bytes": 0,
      "url": "https://example/x"
    }
  ],
  "signed_envelope": null
}
"""
    expect EForeignCatalogShape:
      discard readForeignCatalogFromString(src)

  test "readForeignCatalog rejects bad snapshot":
    let src = """
{
  "dependency_closure": [],
  "format_version": 1,
  "package": {
    "distro": "apt",
    "name": "git",
    "snapshot": "not-a-pin",
    "version": "1.0"
  },
  "provisioning_methods": [
    {
      "kind": "direct-snapshot-url",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "size_bytes": 0,
      "url": "https://example/x"
    }
  ],
  "signed_envelope": null
}
"""
    expect EForeignCatalogShape:
      discard readForeignCatalogFromString(src)

  test "readForeignCatalog rejects missing required field":
    # missing format_version
    let src = """
{
  "dependency_closure": [],
  "package": {
    "distro": "apt",
    "name": "git",
    "snapshot": "debian/bookworm/20260601T000000Z",
    "version": "1.0"
  },
  "provisioning_methods": [
    {
      "kind": "direct-snapshot-url",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "size_bytes": 0,
      "url": "https://example/x"
    }
  ]
}
"""
    expect EForeignCatalogMissingField:
      discard readForeignCatalogFromString(src)

  test "readForeignCatalog rejects empty provisioning_methods":
    let src = """
{
  "dependency_closure": [],
  "format_version": 1,
  "package": {
    "distro": "apt",
    "name": "git",
    "snapshot": "debian/bookworm/20260601T000000Z",
    "version": "1.0"
  },
  "provisioning_methods": [],
  "signed_envelope": null
}
"""
    expect EForeignCatalogShape:
      discard readForeignCatalogFromString(src)

  test "sample catalog files parse cleanly":
    let aptGit = readForeignCatalog(RecipesRoot / "apt" / "git.json")
    check aptGit.formatVersion == 1
    check aptGit.package.distro == "apt"
    check aptGit.package.name == "git"
    check aptGit.package.snapshot == "debian/bookworm/20260601T000000Z"
    check aptGit.provisioningMethods.len == 1

    let dnfHtop = readForeignCatalog(RecipesRoot / "dnf" / "htop.json")
    check dnfHtop.formatVersion == 1
    check dnfHtop.package.distro == "dnf"
    check dnfHtop.package.name == "htop"

    let pacmanNvim = readForeignCatalog(RecipesRoot / "pacman" / "neovim.json")
    check pacmanNvim.formatVersion == 1
    check pacmanNvim.package.distro == "pacman"
    check pacmanNvim.package.name == "neovim"
