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

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result

suite "DSL-port M9.R.30.2 — transitive RPATH propagation":

  test "manifest_filename_is_well_known_constant":
    check m9r30PropagatedManifestName == ".m9r30_propagated_libdirs.txt"

  test "propagated_lib_dirs_are_available_to_build_actions":
    let scratch = createTempDir("repro-m9r30-build-dirs-", "")
    defer: removeDir(scratch)
    let first = scratch / "first.txt"
    let second = scratch / "second.txt"
    writeFile(first, "/recipes/wayland/usr/lib\n\n/recipes/mesa/usr/lib64\n")
    writeFile(second, "/recipes/mesa/usr/lib64\n/recipes/libdrm/usr/lib\n")

    check m9r30ReadPropagatedLibDirs(@[
      first,
      scratch / "missing.txt",
      second,
    ]) == @[
      "/recipes/wayland/usr/lib",
      "/recipes/mesa/usr/lib64",
      "/recipes/libdrm/usr/lib",
    ]

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
    # Without a recipes root each manifest keeps its absolute spelling.
    for m in manifests:
      check script.contains("\"" & m & "\"")
    # With one, the root is stated once and each manifest is relative to it.
    let rooted = m9r14fEmitRpathPatchScript(
      "/tmp/mirror/usr", @[],
      depManifestPaths = manifests,
      ownManifestPath = "/tmp/mirror/.m9r30_propagated_libdirs.txt",
      packageName = "sway",
      recipesRoot = "/recipes")
    check rooted.count("/recipes/wlroots") == 0
    check rooted.contains("\"@/wlroots/.repro/output/install/" &
      m9r30PropagatedManifestName & "\"")
    # The walker reads each manifest with [-f] guard so unbuilt deps
    # contribute nothing.
    check script.contains("[ -f ")
    # Lines are folded into rpath with dedup via case-pattern match.
    check script.contains("case \":$rpath:\" in")

  test "active recipes root remaps stale install mirror paths":
    let script = m9r14fEmitRpathPatchScript(
      "/active/current/.repro/output/install/usr", @[],
      depManifestPaths = @[
        "/active/direct/.repro/output/install/.m9r30_propagated_libdirs.txt"],
      ownManifestPath = "/active/current/.repro/output/install/" &
        ".m9r30_propagated_libdirs.txt",
      packageName = "current",
      recipesRoot = "/active")
    check script.contains("m9r14f_old_recipe=${line%%/.repro/output/install/*}")
    check script.contains(
      "m9r14f_active=\"/active/$m9r14f_dep/.repro/output/install/$m9r14f_rel\"")

  when defined(linux):
    test "stale propagated path is rewritten before its existence check":
      let scratch = createTempDir("repro-m9r30-relocate-", "")
      defer: removeDir(scratch)
      let recipesRoot = scratch / "active"
      let activeLib = recipesRoot / "transitive" / ".repro" / "output" /
        "install" / "usr" / "lib"
      let directRoot = recipesRoot / "direct" / ".repro" / "output" /
        "install"
      let currentRoot = recipesRoot / "current" / ".repro" / "output" /
        "install"
      let depManifest = directRoot / m9r30PropagatedManifestName
      let ownManifest = currentRoot / m9r30PropagatedManifestName
      createDir(activeLib)
      createDir(directRoot)
      createDir(currentRoot / "usr")
      writeFile(depManifest,
        "/retired/catalog/transitive/.repro/output/install/usr/lib\n")

      let fakeBin = scratch / "bin"
      let fakePatchelf = fakeBin / "patchelf"
      createDir(fakeBin)
      writeFile(fakePatchelf, "#!/bin/sh\nexit 0\n")
      setFilePermissions(fakePatchelf, {fpUserRead, fpUserWrite, fpUserExec})
      let emitted = scratch / "relocate.sh"
      writeFile(emitted, m9r14fEmitRpathPatchScript(
        currentRoot / "usr", @[],
        depManifestPaths = @[depManifest],
        ownManifestPath = ownManifest,
        packageName = "current",
        recipesRoot = recipesRoot))
      let priorPath = getEnv("PATH")
      putEnv("PATH", fakeBin & ":" & priorPath)
      try:
        let run = startProcess("/bin/sh", args = @[emitted],
          options = {poUsePath, poParentStreams})
        check waitForExit(run) == 0
      finally:
        putEnv("PATH", priorPath)

      check readFile(ownManifest).strip() == activeLib

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

suite "RPATH patch script size does not scale with the checkout path":
  ## An install-mirror edge is `sh -c <script>`, and Linux refuses one
  ## argument over 131072 bytes (`MAX_ARG_STRLEN`): `execve` fails E2BIG and
  ## the edge used to die as a silent exit 127. The script used to repeat the
  ## recipe root once per sibling catalog recipe several times over, so a
  ## recipe built fine from a short checkout path and not from a longer one.
  ## The root is now stated once, whatever the number of siblings.

  proc scriptFor(recipesRoot: string; siblings: int): string =
    var libDirs, manifests: seq[string]
    for i in 0 ..< siblings:
      let recipe = recipesRoot / ("sibling-recipe-" & $i)
      libDirs.add(recipe / ".repro" / "output" / "install" / "usr" / "lib")
      manifests.add(recipe / ".repro" / "output" / "install" /
        m9r30PropagatedManifestName)
    m9r14fEmitRpathPatchScript(
      recipesRoot / "current" / ".repro" / "output" / "install" / "usr",
      libDirs,
      depManifestPaths = manifests,
      ownManifestPath = recipesRoot / "current" / ".repro" / "output" /
        "install" / m9r30PropagatedManifestName,
      packageName = "current",
      recipesRoot = recipesRoot)

  test "a longer recipes root costs the same however many siblings there are":
    let shortRoot = "/scratch/a/" & repeat('s', 20)
    let longRoot = "/scratch/a/" & repeat('s', 120)
    proc growth(siblings: int): int =
      scriptFor(longRoot, siblings).len - scriptFor(shortRoot, siblings).len
    # The root appears a fixed number of times in the rest of the script (the
    # mirror's own paths); the siblings must add none.
    check growth(76) == growth(1)

  test "the script for a large catalog stays far below MAX_ARG_STRLEN":
    check scriptFor("/scratch/a/" & repeat('s', 140), 76).len < 40_000

  when defined(linux):
    proc foldedRpath(rootName: string): tuple[present, outside: string,
                                                 manifest: string] =
      ## Runs the emitted script under /bin/sh with a stand-in ``patchelf``
      ## and returns what it wrote to the consumer's own manifest. The root
      ## directory is named ``rootName`` so a name with shell-significant
      ## characters goes through the same code path as a plain one.
      let scratch = createTempDir("repro-rpath-size-", "")
      defer: removeDir(scratch)
      let recipesRoot = scratch / rootName
      let present = recipesRoot / "present" / ".repro" / "output" /
        "install" / "usr" / "lib"
      let absent = recipesRoot / "absent" / ".repro" / "output" /
        "install" / "usr" / "lib"
      let outside = scratch / "elsewhere" / "usr" / "lib"
      let currentRoot = recipesRoot / "current" / ".repro" / "output" /
        "install"
      let ownManifest = currentRoot / m9r30PropagatedManifestName
      createDir(present)
      createDir(outside)
      createDir(currentRoot / "usr")
      # A dependency's manifest: a blank line (skipped), a stale path under
      # another checkout's root that must be remapped onto this root, a path
      # that does not exist (skipped) and a nix-store path (skipped). Only the
      # remapped one may reach the RPATH, after the direct lib dirs.
      let depLib = recipesRoot / "dep" / ".repro" / "output" / "install" /
        "usr" / "lib"
      createDir(depLib)
      let depManifest = recipesRoot / "dep" / ".repro" / "output" /
        "install" / m9r30PropagatedManifestName
      writeFile(depManifest, "\n/old/checkout/dep/.repro/output/install/usr/" &
        "lib\n/old/checkout/gone/.repro/output/install/usr/lib\n" &
        "/nix/store/abc-x/lib\n" & present & "\n")
      let fakeBin = scratch / "bin"
      createDir(fakeBin)
      writeFile(fakeBin / "patchelf", "#!/bin/sh\nexit 0\n")
      setFilePermissions(fakeBin / "patchelf",
        {fpUserRead, fpUserWrite, fpUserExec})
      let emitted = scratch / "rpath.sh"
      writeFile(emitted, m9r14fEmitRpathPatchScript(
        currentRoot / "usr", @[present, absent, outside],
        depManifestPaths = @[depManifest, recipesRoot / "unbuilt" / "m.txt"],
        ownManifestPath = ownManifest,
        packageName = "current",
        recipesRoot = recipesRoot))
      let priorPath = getEnv("PATH")
      putEnv("PATH", fakeBin & ":" & priorPath)
      try:
        let run = startProcess("/bin/sh", args = @[emitted],
          options = {poUsePath, poParentStreams})
        check waitForExit(run) == 0
      finally:
        putEnv("PATH", priorPath)
      # The result is read back with the scratch root stripped, so the same
      # expectation holds for every ``rootName``.
      (present: present.replace(scratch, ""), outside: outside.replace(scratch, ""),
       manifest: readFile(ownManifest).replace(scratch, "").strip())

    for rootName in ["active", "ac tive's root"]:
      test "sibling lib dirs are folded into the RPATH only when they exist, " &
           "in order, under a root named " & rootName:
        let got = foldedRpath(rootName)
        let depLib = "/" & rootName / "dep" / ".repro" / "output" / "install" /
          "usr" / "lib"
        # Direct lib dirs keep their order and drop the absent one; the
        # manifest's stale path is remapped to this root, deduplicated against
        # the direct ones, and the missing and nix-store paths are skipped.
        check got.manifest.splitLines() ==
          @[got.present, got.outside, depLib]
