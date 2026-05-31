## M3 (Realize-Closure-And-Catalog-Expansion spec) — Scoop
## ``pre_install`` PowerShell-block runner allowlist tests.
##
## The runner is a CONSTRAINED evaluator over a closed set of action
## kinds (``PreInstallActionKind``). Each test exercises ONE allowlist
## shape end-to-end against a synthetic staging dir, then validates the
## resulting tree. Allowlist-miss handling (``pre_install_unrecognized``
## landing in the slice with a ``WPreInstallUnrecognized`` warning at
## realize time) is exercised separately.
##
## The critical junction-hazard test (per project memory
## ``project_reprobuild_store_junction_hazard``) confirms Remove-Item
## over a junction does NOT recurse into the link target — even when
## the target lives outside the prefix and contains user data.

import std/[os, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_dsl_stdlib/packages_schema
import repro_home_apply/builtin_adapter

const FixtureRoot = "build/test-tmp/t-builtin-adapter-pre-install"

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

suite "M3 — cakBuiltin pre_install runner (allowlist)":

  test "test_m3_pre_install_runner_new_item_directory":
    ## ``New-Item -ItemType Directory`` → ``os.createDir``.
    let dir = FixtureRoot / "new-item-dir"
    resetDir(dir)
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolA", dir, @[
      PreInstallAction(kind: piaNewItemDir, source: "",
        target: "$dir/subdir/nested", recurse: false, literal: "")
    ], @[], "", env)
    check dirExists(extendedPath(dir / "subdir" / "nested"))

  test "test_m3_pre_install_runner_new_item_file":
    ## ``New-Item -ItemType File`` → empty file at target.
    let dir = FixtureRoot / "new-item-file"
    resetDir(dir)
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolB", dir, @[
      PreInstallAction(kind: piaNewItemFile, source: "",
        target: "$dir/marker.txt", recurse: false, literal: "")
    ], @[], "", env)
    check fileExists(extendedPath(dir / "marker.txt"))
    check readFile(extendedPath(dir / "marker.txt")) == ""

  test "test_m3_pre_install_runner_copy_item_file":
    ## ``Copy-Item -Path source -Destination target``.
    let dir = FixtureRoot / "copy-item"
    resetDir(dir)
    writeFile(extendedPath(dir / "src.txt"), "source-content")
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolC", dir, @[
      PreInstallAction(kind: piaCopyItem,
        source: "$dir/src.txt", target: "$dir/copied.txt",
        recurse: false, literal: "")
    ], @[], "", env)
    check fileExists(extendedPath(dir / "copied.txt"))
    check readFile(extendedPath(dir / "copied.txt")) == "source-content"

  test "test_m3_pre_install_runner_move_item_file":
    ## ``Move-Item -Path source -Destination target``.
    let dir = FixtureRoot / "move-item"
    resetDir(dir)
    writeFile(extendedPath(dir / "before.txt"), "moved-content")
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolD", dir, @[
      PreInstallAction(kind: piaMoveItem,
        source: "$dir/before.txt", target: "$dir/after.txt",
        recurse: false, literal: "")
    ], @[], "", env)
    check (not fileExists(extendedPath(dir / "before.txt")))
    check fileExists(extendedPath(dir / "after.txt"))
    check readFile(extendedPath(dir / "after.txt")) == "moved-content"

  test "test_m3_pre_install_runner_remove_item_recursive":
    ## ``Remove-Item -Recurse -Force`` on a regular subdir.
    let dir = FixtureRoot / "remove-item-recursive"
    resetDir(dir)
    createDir(extendedPath(dir / "doomed" / "inner"))
    writeFile(extendedPath(dir / "doomed" / "inner" / "file.txt"), "x")
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolE", dir, @[
      PreInstallAction(kind: piaRemoveItem, source: "",
        target: "$dir/doomed", recurse: true, literal: "")
    ], @[], "", env)
    check (not dirExists(extendedPath(dir / "doomed")))

  test "test_m3_pre_install_runner_remove_item_glob":
    ## ``Remove-Item -Path "$dir\*.7z"`` glob support.
    let dir = FixtureRoot / "remove-item-glob"
    resetDir(dir)
    writeFile(extendedPath(dir / "a.7z"), "fake7z-a")
    writeFile(extendedPath(dir / "b.7z"), "fake7z-b")
    writeFile(extendedPath(dir / "keep.txt"), "keep me")
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolF", dir, @[
      PreInstallAction(kind: piaRemoveItem, source: "",
        target: "$dir/*.7z", recurse: true, literal: "")
    ], @[], "", env)
    check (not fileExists(extendedPath(dir / "a.7z")))
    check (not fileExists(extendedPath(dir / "b.7z")))
    check fileExists(extendedPath(dir / "keep.txt"))

  test "test_m3_pre_install_runner_set_content_literal":
    ## ``Set-Content -Path file -Value '<literal>'`` writes the literal.
    let dir = FixtureRoot / "set-content"
    resetDir(dir)
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolG", dir, @[
      PreInstallAction(kind: piaSetContent, source: "",
        target: "$dir/etc/config.ini", recurse: false,
        literal: "[section]\nkey=value\n")
    ], @[], "", env)
    check fileExists(extendedPath(dir / "etc" / "config.ini"))
    let body = readFile(extendedPath(dir / "etc" / "config.ini"))
    check body.contains("[section]")
    check body.contains("key=value")

  test "test_m3_pre_install_runner_add_path_records_env_binding":
    ## ``Add-Path`` is metadata only — appended to env bindings as
    ## ``PATH+=<dir>``; nothing is executed at extract time.
    let dir = FixtureRoot / "add-path"
    resetDir(dir)
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolH", dir, @[
      PreInstallAction(kind: piaAddPath, source: "",
        target: "$dir/bin", recurse: false, literal: "")
    ], @[], "", env)
    check env.len == 1
    check env[0].name == "PATH+="
    # Path comparison normalized — Nim's `/` operator uses DirSep, but the
    # runner's substitutePlaceholder rewrite preserves forward slashes
    # when the input used them. Compare via replace to normalize.
    check env[0].value.replace('\\', '/') == (dir / "bin").replace('\\', '/')

  test "test_m3_pre_install_runner_unrecognized_warns_and_proceeds":
    ## A line outside the allowlist lands in ``pre_install_unrecognized``;
    ## the runner emits a ``WPreInstallUnrecognized`` warning and then
    ## proceeds with the rest of the actions (fail-soft).
    let dir = FixtureRoot / "unrecognized"
    resetDir(dir)
    var env: seq[tuple[name, value: string]] = @[]
    runPreInstallActions("toolI", dir,
      actions = @[
        PreInstallAction(kind: piaNewItemDir, source: "",
          target: "$dir/created", recurse: false, literal: "")
      ],
      unrecognized = @[
        "Invoke-WebRequest -Uri http://example.com/bogus -OutFile $dir\\bogus",
        "& \"$dir\\some-script.ps1\""
      ],
      sevenZipExe = "", envBindings = env)
    # The allowlist action still ran:
    check dirExists(extendedPath(dir / "created"))
    # The unrecognized side effects did NOT run:
    check (not fileExists(extendedPath(dir / "bogus")))

  test "test_m3_pre_install_runner_remove_does_not_recurse_into_junction":
    ## CRITICAL — per project memory ``project_reprobuild_store_junction_hazard``.
    ## A Remove-Item over a junction must NOT delete the link target's
    ## contents. Build a real junction (Windows) / symlink (POSIX) into
    ## a "user data" dir, then issue Remove-Item -Recurse over the
    ## junction; assert the link's target survives intact.
    when defined(windows):
      let dir = FixtureRoot / "junction-hazard"
      resetDir(dir)
      let userData = FixtureRoot / "junction-target-userdata"
      resetDir(userData)
      writeFile(extendedPath(userData / "must-survive.txt"),
        "the user's real data — Remove-Item -Recurse MUST NOT touch this\n")
      writeFile(extendedPath(userData / "another-file.txt"), "also intact")
      let junctionPath = dir / "junction-into-userdata"
      # Build a real junction via mklink /J. The DOS-style cmd shellout
      # is necessary because Nim's createSymlink uses CreateSymbolicLink
      # which requires admin / Developer Mode privileges; mklink /J uses
      # reparse-point junctions which any user can create.
      let mklinkRes = execShellCmd("cmd /c mklink /J " &
        quoteShell(junctionPath) & " " & quoteShell(absolutePath(userData)))
      check mklinkRes == 0
      check dirExists(extendedPath(junctionPath))
      check fileExists(extendedPath(junctionPath / "must-survive.txt"))

      var env: seq[tuple[name, value: string]] = @[]
      runPreInstallActions("toolJ", dir, @[
        PreInstallAction(kind: piaRemoveItem, source: "",
          target: "$dir/junction-into-userdata", recurse: true,
          literal: "")
      ], @[], "", env)

      # The junction itself is GONE (unlinked):
      check (not dirExists(extendedPath(junctionPath)))
      # The TARGET's contents SURVIVED (Remove-Item did not recurse
      # into the junction):
      check dirExists(extendedPath(userData))
      check fileExists(extendedPath(userData / "must-survive.txt"))
      check fileExists(extendedPath(userData / "another-file.txt"))
      check readFile(extendedPath(userData / "must-survive.txt"))
        .contains("the user's real data")
    else:
      # On POSIX, the same protection applies via the pcLinkToDir kind.
      # We exercise the symlink path so the junction-hazard guardrail
      # is covered on every host.
      let dir = FixtureRoot / "junction-hazard-posix"
      resetDir(dir)
      let userData = FixtureRoot / "junction-target-userdata-posix"
      resetDir(userData)
      writeFile(extendedPath(userData / "must-survive.txt"),
        "the user's real data\n")
      let linkPath = dir / "link-into-userdata"
      createSymlink(absolutePath(userData), linkPath)
      check fileExists(extendedPath(linkPath / "must-survive.txt"))
      var env: seq[tuple[name, value: string]] = @[]
      runPreInstallActions("toolJ", dir, @[
        PreInstallAction(kind: piaRemoveItem, source: "",
          target: "$dir/link-into-userdata", recurse: true,
          literal: "")
      ], @[], "", env)
      check (not symlinkExists(extendedPath(linkPath)))
      check fileExists(extendedPath(userData / "must-survive.txt"))
