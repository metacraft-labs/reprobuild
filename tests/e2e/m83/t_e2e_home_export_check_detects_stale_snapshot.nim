## `repro home export --check FILE` fails when a committed snapshot no longer
## matches what the profile says, and passes when it does.
##
## Primary assertion — `e2e_home_export_check_detects_stale_snapshot`:
##
## 1. A snapshot written by `repro home export` is checked against the
##    unchanged profile: exit 0 (negative control).
## 2. An activity edit (a package added to `alpha_tools`) makes `--check`
##    exit 1, and the diagnostic names the activity and the package.
## 3. Re-exporting to the same file makes `--check` exit 0 again.
## 4. A host-selection edit (`hosts:` gives `alpha` a second activity) fails
##    the check in `selection.activities`; a snapshot for a different host
##    fails it too.
##
## The documented provenance policy is pinned as well: `--check` compares
## `format`, `schemaVersion`, `selection`, `intent` and `platforms`, never
## `provenance`. A snapshot whose `platforms` claims a platform the profile
## does not describe fails the check (that claim is what a consumer refuses
## or accepts a target on).
## A snapshot whose recorded repro version and profile digest were altered
## still passes (with a "not compared" note), and so does the snapshot after
## a comment-only edit of `home.nim`, which changes the profile digest but not
## the intent.
##
## Falsifying mutation (performed when this gate was written): make `--check`
## always succeed. The gate goes red at step 2.
##
## Vacuity guard: the snapshot has non-empty activities and resources, and
## the edit is visible in the fresh export (the added package is in it).
##
## No mocks: real `build/bin/repro`, real Nim, real io-mon shim, real
## filesystem; the `nim` spy is a pass-through counter (harness header).

import repro_test_support/reasoned_skip

const PlatformSkipReason =
  "[platform N/A] t_e2e_home_export_check_detects_stale_snapshot: the nim " &
  "spy and the stderr capture are POSIX shell, and the profile-compile edge " &
  "is verified on Linux, where io-mon is the established backend."

when not defined(linux):
  import std/unittest

  suite "repro home export --check":
    test "e2e_home_export_check_detects_stale_snapshot":
      skip(PlatformSkipReason)
else:
  import std/[json, os, strutils, unittest]

  import ./profile_compile_edge_harness

  const Header = """
import repro_profile

"""

  proc profileText(alphaExtra = ""; alphaHosts = "[alpha_tools]";
                   comment = ""): string =
    Header & comment & """
profile "gm2Check":
  activity default:
    ripgrep

  activity alpha_tools:
    jq
""" & alphaExtra & """

  activity beta_tools:
    fd

  hosts:
    "alpha": """ & alphaHosts & """

    "beta": [beta_tools]

  resources:
    fsUserFile(hostFile = "~/gm2-check-marker.txt",
      content = "checked\n")
"""

  proc run(sb: ProfileSandbox; args: openArray[string]): ReproRun =
    result = sb.runRepro(@["home", "export"] & @args, host = "")
    checkpoint("repro home export " & args.join(" ") & " -> exit " &
      $result.exitCode & "\nstdout:\n" & result.stdout & "\nstderr:\n" &
      result.stderr)

  proc exportTo(sb: ProfileSandbox; host, path: string) =
    let r = sb.run(["--host", host, "--format", "json"])
    require r.exitCode == 0
    writeFile(path, r.stdout)

  suite "repro home export --check":

    test "e2e_home_export_check_detects_stale_snapshot":
      let sb = newProfileSandbox("gm2-check", profileText())
      defer: sb.dispose()
      let snapshot = sb.root / "home-export.alpha.json"

      sb.exportTo("alpha", snapshot)
      let doc = parseJson(readFile(snapshot))
      check doc["intent"]["activities"].len == 3
      check doc["intent"]["resources"].len == 1

      # 1. Negative control: unchanged profile, current snapshot.
      let fresh = sb.run(["--host", "alpha", "--check", snapshot])
      check fresh.exitCode == 0
      check fresh.stdout.contains("matches a fresh export")

      # Provenance is reported, never compared.
      var tampered = parseJson(readFile(snapshot))
      tampered["provenance"]["repro"]["version"] = %"0.0.0-gm2-test"
      tampered["provenance"]["profile"]["digest"] = %"0000"
      let tamperedPath = sb.root / "tampered.json"
      writeFile(tamperedPath, pretty(tampered))
      let tamperedRun = sb.run(["--host", "alpha", "--check", tamperedPath])
      check tamperedRun.exitCode == 0
      check tamperedRun.stderr.contains("not compared")
      check tamperedRun.stderr.contains("0.0.0-gm2-test")

      # `platforms` is compared: a consumer decides on it.
      var wrongPlatforms = parseJson(readFile(snapshot))
      wrongPlatforms["platforms"]["x86_64-windows"] = %"differs"
      let wrongPlatformsPath = sb.root / "wrong-platforms.json"
      writeFile(wrongPlatformsPath, pretty(wrongPlatforms))
      let platformsRun = sb.run(["--host", "alpha", "--check",
        wrongPlatformsPath])
      check platformsRun.exitCode == 1
      check platformsRun.stderr.contains("platforms.x86_64-windows")

      # A comment-only edit changes the profile digest, not the intent.
      writeFile(sb.profilePath,
        profileText(comment = "# a comment that changes no intent\n"))
      let commentRun = sb.run(["--host", "alpha", "--check", snapshot])
      check commentRun.exitCode == 0
      check commentRun.stderr.contains("provenance.profile.digest")

      # 2. An activity edit makes the snapshot stale.
      writeFile(sb.profilePath, profileText(alphaExtra = "    yq\n"))
      let stale = sb.run(["--host", "alpha", "--check", snapshot])
      check stale.exitCode == 1
      check stale.stderr.contains("is stale")
      check stale.stderr.contains("alpha_tools")
      check stale.stderr.contains("yq")
      check stale.stderr.contains("repro home export --format json")
      # Vacuity: the edit really is in the fresh intent.
      let edited = sb.run(["--host", "alpha"])
      require edited.exitCode == 0
      check edited.stdout.contains("\"yq\"")
      check not readFile(snapshot).contains("\"yq\"")

      # 3. Re-export, and the check passes again.
      sb.exportTo("alpha", snapshot)
      let refreshed = sb.run(["--host", "alpha", "--check", snapshot])
      check refreshed.exitCode == 0

      # 4. A host-selection edit is a staleness too.
      writeFile(sb.profilePath, profileText(alphaExtra = "    yq\n",
        alphaHosts = "[alpha_tools, beta_tools]"))
      let reselected = sb.run(["--host", "alpha", "--check", snapshot])
      check reselected.exitCode == 1
      check reselected.stderr.contains("selection.activities")
      # ...and a snapshot taken for another host does not pass for this one.
      sb.exportTo("alpha", snapshot)
      let otherHost = sb.run(["--host", "beta", "--check", snapshot])
      check otherHost.exitCode == 1
      check otherHost.stderr.contains("selection.host")

      # Usage: an unreadable or non-JSON snapshot is a usage error, not a pass.
      let missing = sb.run(["--host", "alpha", "--check",
        sb.root / "no-such-snapshot.json"])
      check missing.exitCode == 2
      let garbagePath = sb.root / "garbage.json"
      writeFile(garbagePath, "not json")
      let garbage = sb.run(["--host", "alpha", "--check", garbagePath])
      check garbage.exitCode == 2
