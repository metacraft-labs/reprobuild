## DSL-port M9.R.30.2 / M9.R.30.3 — transitive RPATH propagation +
## NEEDED safety net.
##
## ## Context
##
## M9.R.14f.2 (`m9r14fEmitRpathPatchScript`) embeds direct buildDeps'
## install-mirror lib dirs in every produced ELF's RPATH. But because
## each recipe's `runtimeDeps:` is still the M9.R.5b TODO placeholder
## (`discard`), the propagation is non-transitive — sway's binary
## carries wlroots' lib dir but NOT libdrm's (libdrm is a buildDep of
## wlroots, not of sway). M9.R.29 surfaced this end-to-end: sway
## crashes at startup with `libdrm.so.2: cannot open shared object`.
##
## M9.R.30.2 closes the gap with Nix `propagatedBuildInputs` semantics:
## each recipe's install-mirror writes a manifest file at
## `<recipeRoot>/.repro/output/install/.m9r30_propagated_libdirs.txt`
## containing every absolute lib dir in its final RPATH. The walker
## reads each direct dep's manifest and folds every line into the
## consumer's RPATH — so transitive propagation happens through the
## file system without a Nim-time graph walk.
##
## M9.R.30.3 layers a NEEDED safety net: after patching every ELF, the
## script verifies every DT_NEEDED resolves under the embedded RPATH
## (or under the standard system dirs). An unresolved NEEDED FAILS
## THE BUILD (exit 75) with a structured error naming the package +
## binary + missing SONAME.
##
## ## What this test pins
##
## 1. `m9r30PropagatedManifestName` is the well-known filename.
## 2. The emitted script reads each manifest file with `[ -f ... ]`
##    guard so a dep that hasn't been built yet contributes nothing.
## 3. The emitted script writes the consumer's own manifest with
##    `printf` (not `echo`).
## 4. The emitted script's NEEDED safety net is gated on
##    `REPRO_M9R30_NEEDED_CHECK=1` so single-recipe unit-test fixtures
##    don't fail accidentally.
## 5. Backward compatibility: calling `m9r14fEmitRpathPatchScript`
##    with only the two original args produces a script that does NOT
##    reference the manifest mechanism (so existing M9.R.14f.2 tests
##    still pass).

import std/[strutils, unittest]

import repro_dsl_stdlib/types/package_result

suite "DSL-port M9.R.30.2 — transitive RPATH propagation":

  test "manifest_filename_is_well_known_constant":
    check m9r30PropagatedManifestName == ".m9r30_propagated_libdirs.txt"

  test "default_args_preserve_M9R14f2_backward_compat":
    # Calling with only the two original args MUST produce a script
    # that does NOT reference the manifest mechanism so the existing
    # 79 from-source recipes' install-mirror behaviour is unchanged
    # until the per-recipe build pipeline opts in via the new args.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check not script.contains(".m9r30_propagated_libdirs.txt")
    check not script.contains("REPRO_M9R30_NEEDED_CHECK")

  test "dep_manifest_paths_appear_in_emitted_script":
    let manifests = @[
      "/recipes/wlroots/.repro/output/install/.m9r30_propagated_libdirs.txt",
      "/recipes/wayland/.repro/output/install/.m9r30_propagated_libdirs.txt",
    ]
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      depManifestPaths = manifests,
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    for m in manifests:
      check script.contains(m)
    # The walker reads each manifest with [-f] guard so unbuilt deps
    # contribute nothing.
    check script.contains("[ -f ")
    # Lines are folded into rpath with dedup via case-pattern match.
    check script.contains("case \":$rpath:\" in")

  test "own_manifest_path_is_truncated_then_written":
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    # Atomic truncate.
    check script.contains(": > \"/tmp/mirror/.m9r30_propagated_libdirs.txt\"")
    # printf write (not echo) so future entries starting with - don't
    # get interpreted as flags.
    check script.contains("printf '%s\\n'")
    # $ORIGIN family is filtered out of the manifest (binary-relative
    # tokens have no meaning to a downstream consumer's ELF).
    check script.contains("case \"$rp\" in '$ORIGIN'*) continue;;")
    # Only absolute paths land in the manifest.
    check script.contains("case \"$rp\" in /*)")

  test "needed_safety_net_is_env_gated":
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    # The check fires only when REPRO_M9R30_NEEDED_CHECK=1 so a single
    # recipe rebuilt in isolation while a downstream dep is in flight
    # can opt out.
    check script.contains("REPRO_M9R30_NEEDED_CHECK")
    # The default in the env gate is 0 (off).
    check script.contains("${REPRO_M9R30_NEEDED_CHECK:-0}")

  test "needed_safety_net_invokes_patchelf_print_needed":
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    check script.contains("patchelf --print-needed")

  test "needed_safety_net_expands_dollar_ORIGIN_per_elf":
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    # $ORIGIN must be expanded to the dirname of the ELF being checked
    # (dynamic-linker semantics).
    check script.contains("dirname \"$f\"")
    check script.contains("sed \"s|\\$ORIGIN|$origin_dir|g\"")

  test "needed_safety_net_accepts_standard_system_dirs":
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    # Without this fallback every ELF would fail on libc.so.6 /
    # ld-linux-*.so since those come from the nix-stub / base-rootfs
    # path, not from a from-source dep mirror.
    check script.contains("/lib/x86_64-linux-gnu")
    check script.contains("/usr/lib64")

  test "needed_safety_net_fails_build_on_unresolved":
    let script = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    # Unresolved NEEDED -> exit 75 ("M9.R.30 unresolved transitive NEEDED").
    check script.contains("exit 75")
    # The error message names the package, binary, AND missing SONAME
    # so the recipe author knows exactly what to add as a buildDep.
    check script.contains("UNRESOLVED NEEDED")
    check script.contains("pkg=%s bin=%s soname=%s")

  test "emitted_script_is_deterministic":
    # Same inputs -> byte-identical script.
    let manifests = @[
      "/recipes/wlroots/.repro/output/install/.m9r30_propagated_libdirs.txt",
    ]
    let first = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      depManifestPaths = manifests,
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    let second = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      depManifestPaths = manifests,
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway")
    check first == second
