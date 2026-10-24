## Whether a stow file and an `fs.userFile` resource on one `$HOME` path
## differ in `mode` depends on the TARGET platform, not on the host's
## permission bits (reprobuild-pm spec Home-Profile-Intent-Layer.md
## §"A Stow File And An `fs.userFile` On One Path";
## Home-Profile-Resource-Lifecycle.md, `fs.userFile` `mode`: "ignored on
## Windows"; issue
## 2026-10-23-windows-stow-file-reads-as-0755-so-it-never-agrees-with-an-fs-user-file).
##
## On Windows Nim's `getFilePermissions` reports every file as executable,
## so `linkedMode` called every Windows stow file `0755` and refused each
## agreeing `fs.userFile`. The rule is now keyed on the target's
## `HostContext.platform`, which is what makes it checkable here on every
## host: a `windows` target is planned from a POSIX host with a stow source
## whose execute bit is really set.
##
## * `linkedMode` reports `0644` for a `windows` target whatever the
##   source's bits; for a POSIX target it reports the source's execute bit
##   (on a Windows host, where that bit cannot be read, `0644`).
## * `resolveStowResourceOverlap` for a `windows` target takes over the
##   stow file when the bytes agree, whatever the resource's declared mode
##   (`0644`, `0755`, `0600`), and still refuses differing bytes.
## * The same pairs for a `linux` target are refused on mode (control: the
##   POSIX rule is unchanged).
##
## No mocks: the real planner helpers over real files in a per-case scratch
## directory. Platforms: every host.

import std/[os, strutils, unittest]
from repro_core/paths import extendedPath

import repro_home_resources
import repro_home_apply/errors
import repro_home_apply/file_facts
import repro_home_apply/plan
import repro_home_apply/stow
from repro_test_support import testCaseScratchSlug

const
  Rel = ".config/t/caches.conf"
  Bytes = "trusted-public-keys = t-a:AAAA\n"

type Fixture = object
  root, profileDir, homeDir, source: string

proc newFixture(executable: bool): Fixture =
  ## A profile with one stow file, `stow/t/<Rel>`, whose execute bit is set
  ## when `executable` (where the host can set one).
  result.root = absolutePath("build/test-tmp/t-stow-resource-mode" /
    testCaseScratchSlug())
  if dirExists(extendedPath(result.root)):
    removeDir(extendedPath(result.root))
  result.profileDir = result.root / "profile"
  result.homeDir = result.root / "home"
  result.source = result.profileDir / "stow" / "t" / Rel
  createDir(extendedPath(result.source.parentDir))
  createDir(extendedPath(result.homeDir))
  writeFile(extendedPath(result.source), Bytes)
  var perms = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}
  if executable:
    perms.incl {fpUserExec, fpGroupExec, fpOthersExec}
  setFilePermissions(extendedPath(result.source), perms)

proc planned(f: Fixture): seq[PlannedGeneratedFile] =
  var bytes = newSeq[byte](Bytes.len)
  for i, ch in Bytes:
    bytes[i] = byte(ord(ch))
  @[PlannedGeneratedFile(absoluteOutputPath: f.homeDir / Rel,
    relativeHomePath: Rel, sourceKind: pgfsStowFile,
    stowSourcePath: f.source, contentBytes: bytes)]

proc entries(f: Fixture): seq[StowEntry] =
  @[StowEntry(sourceAbsolutePath: f.source, homeRelativePath: Rel,
    targetAbsolutePath: f.homeDir / Rel, package: "t")]

proc resources(f: Fixture; mode: string; content = Bytes): DesiredSet =
  result = initDesiredSet()
  result.add Resource(kind: rkFsUserFile, address: "tCaches",
    userFileHostPath: f.homeDir / Rel, userFileContent: content,
    userFileMode: mode)

proc resolve(f: Fixture; mode, platform: string; content = Bytes):
    StowResourceResolution =
  resolveStowResourceOverlap(f.planned, f.entries,
    f.resources(mode, content), f.profileDir, f.homeDir, platform)

proc refusal(f: Fixture; mode, platform: string; content = Bytes): string =
  ## The refusal message, or "" when the pair was accepted.
  try:
    discard f.resolve(mode, platform, content)
  except EApplyPlanFailed as e:
    return e.msg

suite "stow file and fs.userFile mode by target platform":

  test "linked_mode_is_0644_for_a_windows_target":
    let f = newFixture(executable = true)
    check linkedMode(f.source, "windows") == "0644"
    when defined(windows):
      # The host cannot carry the bit, so no target reads it as set.
      check linkedMode(f.source, "linux") == "0644"
    else:
      # Control: the bit is really set, and a POSIX target reports it.
      check fpUserExec in getFilePermissions(f.source)
      check linkedMode(f.source, "linux") == "0755"
      check linkedMode(f.source, "wsl") == "0755"
    let plain = newFixture(executable = false)
    check linkedMode(plain.source, "windows") == "0644"
    check linkedMode(plain.source, "linux") == "0644"
    check not fileModeIsApplied("windows")
    for p in ["linux", "macos", "bsd", "wsl"]:
      check fileModeIsApplied(p)

  test "windows_target_compares_the_digest_alone":
    for executable in [false, true]:
      let f = newFixture(executable)
      for mode in ["0644", "0755", "0600"]:
        checkpoint("executable=" & $executable & " mode=" & mode)
        let r = f.resolve(mode, "windows")
        # Taken over: the stow file is neither planned nor linked.
        check r.files.len == 0
        check r.stowEntries.len == 0
        check r.diagnostics.len == 1
        if r.diagnostics.len == 1:
          check r.diagnostics[0].message.endsWith(
            "resource tCaches writes the same file (same digest)")
      # Differing bytes are still refused, on the digest only.
      let msg = f.refusal("0644", "windows", "other bytes\n")
      check "disagree on digest (" in msg
      check "mode (" notin msg

  test "posix_target_still_refuses_a_mode_difference":
    let f = newFixture(executable = false)
    let msg = f.refusal("0600", "linux")
    check "`~/" & Rel & "` is written by stow stow/t/" & Rel &
      " and by resource tCaches, which disagree on mode (0644 vs 0600)" in msg
    let agreed = f.resolve("0644", "linux")
    check agreed.files.len == 0
    check agreed.diagnostics.len == 1
    if agreed.diagnostics.len == 1:
      check agreed.diagnostics[0].message.endsWith(
        "(same mode and digest)")
    when not defined(windows):
      let x = newFixture(executable = true)
      check "disagree on mode (0755 vs 0644)" in x.refusal("0644", "linux")
      check x.resolve("0755", "linux").files.len == 0
