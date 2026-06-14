## B1 P5: parse-the-sample-config integration test.
##
## Verifies:
##   * The full `recipes/reproos-sample-config/configuration.nim`
##     fixture parses cleanly.
##   * Type-checking rejects the major error classes:
##     - missing required field (`mount` with no `source`)
##     - unknown service name (suffix not in the recognized set)
##     - circular imports
##     - malformed snapshot string (no slash, or empty segment)

import std/[options, os, strutils, tempfiles, unittest]
from repro_core/paths import extendedPath

import repro_system_apply

const SampleConfigPath =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir /
    "recipes" / "reproos-sample-config" / "configuration.nim"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

suite "B1 DSL parse":

  test "sample config parses cleanly":
    check fileExists(extendedPath(SampleConfigPath))
    let cfg = parseSystemConfigFile(SampleConfigPath)
    check cfg.name == "reproosSampleConfig"
    check cfg.kernel.name == "reproosKernel"
    check cfg.kernelCmdline.parts.len == 3
    check "rw" in cfg.kernelCmdline.parts
    # Tier 1 packages: coreutils + bash + systemd
    # Tier 3 packages: vim (parent) + git (imported)
    var pkgNames: seq[string]
    for p in cfg.packages:
      pkgNames.add p.name
    check "coreutils" in pkgNames
    check "bash" in pkgNames
    check "systemd" in pkgNames
    check "vim" in pkgNames
    check "git" in pkgNames
    # Users: root + ada (parent overrides the imported ada)
    var userNames: seq[string]
    for u in cfg.users:
      userNames.add u.name
    check "root" in userNames
    check "ada" in userNames
    # Services
    check cfg.services.len == 3
    var enabledUnits: seq[string]
    var disabledUnits: seq[string]
    for s in cfg.services:
      case s.state
      of svsEnabled: enabledUnits.add s.unit
      of svsDisabled: disabledUnits.add s.unit
      of svsMasked: discard
    check "systemd-networkd.service" in enabledUnits
    check "systemd-resolved.service" in disabledUnits
    # Mounts
    check cfg.mounts.len == 2
    var mountPoints: seq[string]
    for m in cfg.mounts:
      mountPoints.add m.mountPoint
    check "/" in mountPoints
    check "/boot" in mountPoints
    # Imports
    check cfg.imports.len == 2

  test "tier 3 packages carry their snapshot pin":
    let cfg = parseSystemConfigFile(SampleConfigPath)
    var vim: PackageRef
    var git: PackageRef
    for p in cfg.packages:
      if p.name == "vim": vim = p
      if p.name == "git": git = p
    check vim.tier == ptForeignBundle
    check vim.distro == "apt"
    check vim.snapshot == "debian/bookworm/20260601T000000Z"
    check git.tier == ptForeignBundle
    check git.distro == "apt"
    check git.snapshot == "debian/bookworm/20260601T000000Z"

  test "missing required mount source raises EMissingRequiredField":
    let src = """
system bad:
  mounts:
    mount "/", fstype = "ext4"
"""
    expect EMissingRequiredField:
      discard parseSystemConfigSource("test://bad.nim", src)

  test "unknown service unit suffix raises EUnknownService":
    let src = """
system bad:
  services:
    enable "foo.bar"
"""
    expect EUnknownService:
      discard parseSystemConfigSource("test://bad.nim", src)

  test "unknown foreign-package distro raises EUnknownForeignDistro":
    let src = """
system bad:
  packages = [
    package(zypper, "git", snapshot = "opensuse/leap/20260101T000000Z"),
  ]
"""
    expect EUnknownForeignDistro:
      discard parseSystemConfigSource("test://bad.nim", src)

  test "malformed snapshot raises EMalformedSnapshot":
    let src = """
system bad:
  packages = [
    package(apt, "git", snapshot = "not-a-pin"),
  ]
"""
    expect EMalformedSnapshot:
      discard parseSystemConfigSource("test://bad.nim", src)

  test "missing user shell raises EMissingRequiredField":
    let src = """
system bad:
  users:
    user "alice":
      groups = ["wheel"]
"""
    expect EMissingRequiredField:
      discard parseSystemConfigSource("test://bad.nim", src)

  test "unknown fstype raises EUnknownFstype":
    let src = """
system bad:
  mounts:
    mount "/", source = "LABEL=root", fstype = "reiser5"
"""
    expect EUnknownFstype:
      discard parseSystemConfigSource("test://bad.nim", src)

  test "circular import raises ECircularImport":
    let dir = createTempDir("b1-circ-", "")
    let a = dir / "a.nim"
    let b = dir / "b.nim"
    writeFile(extendedPath(a), """
system aMod:
  imports:
    "./b.nim"
""")
    writeFile(extendedPath(b), """
system bMod:
  imports:
    "./a.nim"
""")
    expect ECircularImport:
      discard parseSystemConfigFile(a)
    removeDir(extendedPath(dir))

  test "non-existent import raises EImportNotFound":
    let dir = createTempDir("b1-missing-", "")
    let a = dir / "a.nim"
    writeFile(extendedPath(a), """
system aMod:
  imports:
    "./does-not-exist.nim"
""")
    expect EImportNotFound:
      discard parseSystemConfigFile(a)
    removeDir(extendedPath(dir))

  test "anonymous system header raises EUnstructured":
    let src = """
system:
  kernel = linux
"""
    expect EUnstructured:
      discard parseSystemConfigSource("test://anon.nim", src)

  test "missing system header raises EUnstructured":
    let src = """
import repro/system
"""
    expect EUnstructured:
      discard parseSystemConfigSource("test://empty.nim", src)
