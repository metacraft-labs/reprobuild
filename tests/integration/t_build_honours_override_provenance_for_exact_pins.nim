## HL-11 — `repro build` does not substitute a BULK develop override for an
## exact recipe pin (Unified-Locking-And-Hooks.md §16.4).
##
## §16.4: "An exact recipe pin is not substituted by default", because building
## against the checkout "would quietly build something the recipe disclaims".
## A bulk selection (`repro develop --all`) no longer records an override for an
## exactly pinned dependency, and the managed hooks ignore a bulk entry for one.
## But an entry recorded in bulk — and every legacy entry, written before
## provenance told `--all` from `--only` apart, which therefore counts as bulk —
## still made `repro build` bind that dependency to the checkout when it
## resolved it as a cross-repo producer. The hooks ignored the entry while the
## build used it: the inconsistency §16.4 forbids. Now the build applies the
## same explicit/bulk classification:
##
##   * `t_build_does_not_substitute_a_bulk_override_of_an_exact_pin` — the
##     consumer's `flake.nix` pins the producer's repository by revision R1
##     (identified by canonical URL, the same rule the hooks use), and a bulk
##     override (provenance `repro develop --all`, and then a legacy entry with
##     no provenance) points at a checkout at R2. The build fetches and builds
##     the producer at R1 from the lock, consumes R1's stamp, and says so ONCE
##     on stderr, naming the runnable `--only` and `--drop` remedies.
##   * `t_build_substitutes_an_explicit_override_of_an_exact_pin` — the same
##     pin under an explicit override (provenance
##     `repro develop --only=exeprod`) builds the checkout (R2's stamp), with no notice. Positive control for
##     the first case: the override is honoured when it should be.
##   * `t_build_does_not_substitute_a_bulk_override_of_a_repro_nim_exact_pin` —
##     the same, for an exact `uses:` version in `repro.nim` that the
##     producer's `versions:` maps to R1 (read from the checkout located by
##     the develop override, as path-free lock readers locate it), with an
##     explicit entry as its control.
##   * `t_build_substitutes_a_bulk_override_of_an_unpinned_dependency` — with
##     no exact pin in any recipe — no `flake.nix`, and then a `flake.nix`
##     naming the same repository on a branch, so the recipes are read and
##     state no pin — the same bulk and legacy overrides build the checkout
##     exactly as before (R2's stamp), with no notice: ordinary develop
##     overrides are unchanged.
##
## The R1 / R2 split is made observable by keeping the override's checkout
## OUTSIDE the consumer's `../<selector>` sibling slot: a lock-pinned producer
## with a `../exeprod` checkout would build that checkout
## (``producerSourceRoot``), so the lock-pinned path here is the SC-6 fetch at
## the locked revision, and the two stamps cannot be confused.
##
## Falsifiability: against the tree before this change, the first case's build
## binds the bulk override, consumes R2's stamp and prints no notice.
##
## Test-double policy: NO mocks, doubles or fakes — real git repositories, a
## real committed `repro.lock` and `.repro/develop-overrides.toml` in their
## shipped on-disk shapes, and the real `./build/bin/repro build` building and
## running a real producer executable (the SC-2 / SC-6 shape).
##
## Skip rule: `sh`/`git` missing on PATH, `./build/bin/repro` unbuilt, or a
## non-Linux host (the SC fixtures this follows are Linux-only).

import std/[os, osproc, strutils, unittest]

import repro_lock
import repro_test_support/reasoned_skip

const ReprobuildRepoRoot = currentSourcePath().parentDir().parentDir().parentDir()
const reproBinary = ReprobuildRepoRoot / "build/bin/repro".addFileExt(ExeExt)

const
  PinnedStamp = "HL11-EXEPROD-PINNED-R1-3c91e0"
  CheckoutStamp = "HL11-EXEPROD-CHECKOUT-R2-a7d254"

proc producerRecipe(stamp: string): string =
  ## The SC-2 executable producer: its build writes `build/bin/exeprod`, which
  ## prints ``stamp``. Its `versions:` maps 1.0.0 to the tag `v1` (on R1),
  ## which is what makes a consumer's `exeprod ==1.0.0` an exact pin.
  "import repro_project_dsl\n" &
  "import repro_dsl_stdlib/packages/sh\n\n" &
  "package exeprod:\n" &
  "  defaultToolProvisioning \"path\"\n\n" &
  "  versions:\n    \"1.0.0\":\n      sourceRevision = \"refs/tags/v1\"\n\n" &
  "  uses:\n    \"sh\"\n    \"mkdir\"\n    \"chmod\"\n\n" &
  "  executable exeprod:\n    name: \"exeprod\"\n\n" &
  "  build:\n" &
  "    let buildExe = shell(\n" &
  "      command = \"mkdir -p build/bin && \" &\n" &
  "        \"printf '#!/bin/sh\\necho " & stamp &
    "\\n' > build/bin/exeprod && \" &\n" &
  "        \"chmod +x build/bin/exeprod\",\n" &
  "      actionId = \"exeprod.build.exeprod\",\n" &
  "      extraOutputs = @[\"build/bin/exeprod\"])\n" &
  "    appendRegisteredActionToolIdentityRefs(buildExe.id, " &
    "[\"mkdir\", \"chmod\"])\n"

const consumerRecipe = """
import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package consumer:
  defaultToolProvisioning "path"

  uses:
    "sh"
    "mkdir"
    "exeprod"

  build:
    let consume = shell(
      command = "mkdir -p build && exeprod > build/exe.txt",
      actionId = "consumer.build.consume",
      extraOutputs = @["build/exe.txt"],
      cacheable = false)
    appendRegisteredActionToolIdentityRefs(consume.id, ["exeprod", "mkdir"])
"""

proc q(value: string): string = quoteShell(value)

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc git(dir: string; args: string): string =
  let r = run("git -C " & q(dir) & " " & args)
  doAssert r.code == 0, "git " & args & " failed in " & dir & ": " & r.output
  r.output.strip()

type Fixture = object
  scratch, remote, devCheckout, consumer, cacheRoot: string
  pinnedRev, checkoutRev: string

proc setupFixture(label: string): Fixture =
  ## * ``remote`` — the producer's repository; its HEAD is R1 (PinnedStamp).
  ## * ``devCheckout`` — a clone of it, one commit ahead at R2
  ##   (CheckoutStamp): what a develop override points at.
  ## * ``consumer`` — consumes `exeprod`; its committed `repro.lock` pins the
  ##   producer at R1 by the remote's url. No `../exeprod` sibling exists.
  result.scratch = absolutePath(getTempDir() / ("hl11-build-" & label & "-" &
    $getCurrentProcessId()))
  removeDir(result.scratch)
  createDir(result.scratch)
  result.remote = result.scratch / "remotes" / "exeprod"
  createDir(result.remote)
  writeFile(result.remote / "repro.nim", producerRecipe(PinnedStamp))
  discard git(result.remote, "init -q -b main")
  discard git(result.remote, "config user.email hl11@example.invalid")
  discard git(result.remote, "config user.name HL11")
  discard git(result.remote, "add -A")
  discard git(result.remote, "commit -q -m r1")
  result.pinnedRev = git(result.remote, "rev-parse HEAD")
  discard git(result.remote, "tag v1")
  result.devCheckout = result.scratch / "exeprod-dev"
  discard git(result.scratch, "clone -q " & q(result.remote) & " " &
    q(result.devCheckout))
  discard git(result.devCheckout, "config user.email hl11@example.invalid")
  discard git(result.devCheckout, "config user.name HL11")
  writeFile(result.devCheckout / "repro.nim", producerRecipe(CheckoutStamp))
  discard git(result.devCheckout, "commit -q -a -m r2")
  result.checkoutRev = git(result.devCheckout, "rev-parse HEAD")
  result.consumer = result.scratch / "ws" / "consumer"
  createDir(result.consumer)
  writeFile(result.consumer / "repro.nim", consumerRecipe)
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v3",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("hl11-build-fixture"))
  ld.deps.add(LockedDep(
    name: "exeprod",
    coordinates: Coordinates(kind: ckVcs, url: "file://" & result.remote,
      gitRef: "main", revision: result.pinnedRev),
    integrity: gitObjectMultihash("sha1", result.pinnedRev),
    visibility: "public"))
  writeFile(result.consumer / "repro.lock", serializeLockedDependencies(ld))
  result.cacheRoot = result.scratch / "action-cache-root"
  createDir(result.cacheRoot)
  doAssert not dirExists(parentDir(result.consumer) / "exeprod")

proc pinInFlake(fx: Fixture) =
  ## The consumer's `flake.nix` pins the producer's repository by revision R1.
  writeFile(fx.consumer / "flake.nix",
    "{\n  inputs = {\n" &
    "    exeprod-src.url = \"git+file://" & fx.remote & "?ref=main&rev=" &
      fx.pinnedRev & "\";\n" &
    "  };\n  outputs = _: { };\n}\n")

proc pinInReproNim(fx: Fixture) =
  ## The consumer's `repro.nim` pins `exeprod ==1.0.0`, which the producer's
  ## `versions:` maps to R1. The path-free lock reader locates that recipe
  ## through the develop override written before each build; the committed
  ## lock records the producer's identity and never its checkout location.
  writeFile(fx.consumer / "repro.nim",
    consumerRecipe.replace("    \"exeprod\"\n", "    \"exeprod ==1.0.0\"\n"))
  doAssert "exeprod ==1.0.0" in readFile(fx.consumer / "repro.nim")
  let lockText = readFile(fx.consumer / "repro.lock")
  doAssert "reprobuild.solved-graph-lock.v3" in lockText
  doAssert "path =" notin lockText

proc reproNimPinLine(fx: Fixture): string =
  ## `<file>:<line>` of the `repro.nim` pin, as the notice names it.
  fx.consumer / "repro.nim:" &
    $(consumerRecipe.splitLines().find("    \"exeprod\"") + 1)

proc flakePinLine(fx: Fixture): string =
  ## `<file>:<line>` of the pin, as the notice names it.
  fx.consumer / "flake.nix" & ":3"

proc writeOverride(fx: Fixture; provenance: string) =
  ## The override document `repro develop` writes, pointing `exeprod` at the
  ## R2 checkout. ``provenance`` "" writes a legacy entry with none.
  createDir(fx.consumer / ".repro")
  writeFile(fx.consumer / ".repro" / "develop-overrides.toml",
    "schema = \"reprobuild.workspace.develop-overrides.v1\"\n\n" &
    "[[override]]\n" &
    "package = \"exeprod\"\n" &
    "local_path = \"" & fx.devCheckout & "\"\n" &
    "state = \"editable\"\n" &
    "created_at = \"2026-10-15T00:00:00Z\"\n" &
    (if provenance.len > 0: "provenance = \"" & provenance & "\"\n" else: ""))

proc build(fx: Fixture): tuple[code: int; output, consumed: string] =
  let marker = fx.consumer / "build" / "exe.txt"
  if fileExists(marker): removeFile(marker)
  let cmd = q(absolutePath(reproBinary)) & " build " &
    q(fx.consumer / "repro.nim") &
    " --tool-provisioning=path --daemon=off --log=quiet" &
    " --progress=quiet --measure=none --action-cache-root=" & q(fx.cacheRoot)
  let res = run(cmd, ReprobuildRepoRoot)
  (code: res.code, output: res.output,
   consumed: (if fileExists(marker): readFile(marker).strip() else: ""))

proc notice(fx: Fixture; provenance: string; pinnedAt = ""): string =
  ## The one-time notice, exactly.
  "repro: NOT substituting 'exeprod' with the develop override at " &
    fx.devCheckout & ": " &
    (if pinnedAt.len > 0: pinnedAt else: flakePinLine(fx)) &
    " pins it by exact revision, " &
    "and the override was recorded by a bulk selection (" &
    fx.consumer / ".repro" / "develop-overrides.toml" & ", provenance " &
    (if provenance.len > 0: "'" & provenance & "'" else: "none") &
    "), which does not substitute an exact recipe pin; it is resolved from " &
    "the lock instead. Run `repro develop --only=exeprod --workspace-root=" &
    fx.consumer & "` to substitute it explicitly, or `repro develop " &
    "--drop=exeprod --workspace-root=" & fx.consumer & "` to remove the " &
    "override"

proc prerequisitesMet(): bool =
  defined(linux) and findExe("sh").len > 0 and findExe("git").len > 0 and
    fileExists(reproBinary)

const NoticeHead = "repro: NOT substituting 'exeprod'"

suite "HL-11 §16.4: repro build honours override provenance for exact pins":

  test "t_build_does_not_substitute_a_bulk_override_of_an_exact_pin":
    if not prerequisitesMet():
      skip("needs Linux, sh and git on PATH, and a built ./build/bin/repro")
    else:
      let fx = setupFixture("bulk")
      defer: removeDir(fx.scratch)
      pinInFlake(fx)
      for provenance in ["repro develop --all", ""]:
        writeOverride(fx, provenance)
        let b = build(fx)
        checkpoint("provenance '" & provenance & "': exit " & $b.code & "\n" &
          b.output)
        check b.code == 0
        # Built from the LOCK: the producer was fetched at R1 and its stamp
        # is the one consumed, not the R2 checkout's.
        check b.consumed == PinnedStamp
        check fileExists(fx.consumer / ".repro" / "cross-repo-producers" /
          "exeprod" / fx.pinnedRev / "repro.nim")
        # Said once, naming both runnable remedies.
        check b.output.count(NoticeHead) == 1
        check notice(fx, provenance) in b.output.splitLines()
        # The checkout was left alone (not built from).
        check not fileExists(fx.devCheckout / "build" / "bin" / "exeprod")

  test "t_build_substitutes_an_explicit_override_of_an_exact_pin":
    if not prerequisitesMet():
      skip("needs Linux, sh and git on PATH, and a built ./build/bin/repro")
    else:
      let fx = setupFixture("explicit")
      defer: removeDir(fx.scratch)
      pinInFlake(fx)
      writeOverride(fx, "repro develop --only=exeprod")
      let b = build(fx)
      checkpoint("exit " & $b.code & "\n" & b.output)
      check b.code == 0
      check b.consumed == CheckoutStamp
      check fileExists(fx.devCheckout / "build" / "bin" / "exeprod")
      check NoticeHead notin b.output

  test "t_build_substitutes_a_bulk_override_of_an_unpinned_dependency":
    if not prerequisitesMet():
      skip("needs Linux, sh and git on PATH, and a built ./build/bin/repro")
    else:
      let fx = setupFixture("unpinned")
      defer: removeDir(fx.scratch)
      check not fileExists(fx.consumer / "flake.nix")
      # Two recipe states, neither pinning exactly: no flake.nix at all, and
      # a flake.nix that names the SAME repository on a branch (so the bulk
      # entry matches, the recipes are read, and they state no exact pin).
      for floatingFlake in [false, true]:
        if floatingFlake:
          writeFile(fx.consumer / "flake.nix",
            "{\n  inputs = {\n" &
            "    exeprod-src.url = \"git+file://" & fx.remote &
              "?ref=main\";\n" &
            "  };\n  outputs = _: { };\n}\n")
        for provenance in ["repro develop --all", ""]:
          writeOverride(fx, provenance)
          let b = build(fx)
          checkpoint("flake.nix " & (if floatingFlake: "floating" else:
            "absent") & ", provenance '" & provenance & "': exit " & $b.code &
            "\n" & b.output)
          check b.code == 0
          check b.consumed == CheckoutStamp
          check fileExists(fx.devCheckout / "build" / "bin" / "exeprod")
          check NoticeHead notin b.output
          check not dirExists(fx.consumer / ".repro" / "cross-repo-producers" /
            "exeprod" / fx.pinnedRev)

  test "t_build_does_not_substitute_a_bulk_override_of_a_repro_nim_exact_pin":
    if not prerequisitesMet():
      skip("needs Linux, sh and git on PATH, and a built ./build/bin/repro")
    else:
      # The same rule when the pin is an exact `uses:` version in repro.nim
      # (mapped to R1 by the producer's `versions:`), not a flake.nix rev.
      let fx = setupFixture("reponim")
      defer: removeDir(fx.scratch)
      pinInReproNim(fx)
      let lockText = readFile(fx.consumer / "repro.lock")
      check reproNimPinLine(fx) == fx.consumer / "repro.nim:10"
      writeOverride(fx, "repro develop --all")
      let bulk = build(fx)
      checkpoint("bulk: exit " & $bulk.code & "\n" & bulk.output)
      check bulk.code == 0
      check bulk.consumed == PinnedStamp
      check fileExists(fx.consumer / ".repro" / "cross-repo-producers" /
        "exeprod" / fx.pinnedRev / "repro.nim")
      check not fileExists(fx.devCheckout / "build" / "bin" / "exeprod")
      check readFile(fx.consumer / "repro.lock") == lockText
      check bulk.output.count(NoticeHead) == 1
      check notice(fx, "repro develop --all", reproNimPinLine(fx)) in
        bulk.output.splitLines()
      # Control: an explicit entry for the same pin substitutes the checkout.
      writeOverride(fx, "repro develop --only=exeprod")
      let explicit = build(fx)
      checkpoint("explicit: exit " & $explicit.code & "\n" & explicit.output)
      check explicit.code == 0
      check explicit.consumed == CheckoutStamp
      check fileExists(fx.devCheckout / "build" / "bin" / "exeprod")
      check readFile(fx.consumer / "repro.lock") == lockText
      check NoticeHead notin explicit.output
