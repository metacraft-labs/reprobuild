## DSL-port M9.R.15q.5.1 — RPATH resolution for nix-stub deps.
##
## ## Context
##
## M9.R.14f.2 emitted an install-mirror RPATH patch script that
## hard-coded ``<recipeRoot>/<depName>/.repro/output/install/usr/lib``
## for every declared dep. For from-source sibling recipes this works:
## the dep is built before the consumer's install-mirror runs, so the
## path exists on disk and the dynamic loader can resolve the SONAME.
##
## For nix-stub deps (libltdl, hwdata, libxdmcp, ...) there's no sibling
## recipe — the dep is resolved via ``/nix/store/...`` at engine fork
## time and the hard-coded ``<recipeRoot>/<dep>/.repro/output/install/
## usr/lib`` path NEVER exists. ``patchelf`` happily bakes the dangling
## path into the ELF and the dynamic loader silently skips it,
## requiring downstream consumers to fall back to ``LD_LIBRARY_PATH``
## (load-time, not embed-time) — which works inside the originating
## nix-shell but breaks every standalone re-exec.
##
## libcanberra → libltdl is the canonical trip: configure.ac:144 probes
## ``AC_CHECK_LIB([ltdl], [lt_dladvise_init])`` and the resulting
## ``libcanberra.so.0`` carries the dangling
## ``/.../recipes/packages/source/libltdl/.repro/output/install/usr/lib``
## entry.
##
## ## What this test pins
##
##   1. ``m9r14fEmitRpathPatchScript`` existence-checks every dep mirror
##      lib dir before appending it to RPATH. The check is a ``[ -d
##      ... ]`` shell test so nix-stub deps' nonexistent paths are
##      silently skipped instead of baking a dangling entry into the
##      ELF.
##   2. The emitted script ALSO folds every existing dir in
##      ``$LD_LIBRARY_PATH`` onto the rpath at install-mirror time.
##      That env var is populated by the engine from each dep's
##      ``libraryPathList`` (nix-store lib dirs for nix-stub deps;
##      sibling install-mirror lib dirs for from-source deps) when the
##      install-mirror action lists the dep on its
##      ``toolIdentityRefs``.
##   3. Idempotence: emitting the script twice with the same inputs
##      still produces byte-identical output.
##   4. Linux end-to-end: synthesize a tiny ELF + a tmp dir that
##      pretends to be a nix-store output. Build the same RPATH the
##      script generates (existence-checked + LD_LIBRARY_PATH-derived),
##      run patchelf, and verify the readback DOES include the
##      nix-store dir AND does NOT include the dangling sibling-recipe
##      path.

import std/[envvars, os, osproc, streams, strutils, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result

suite "DSL-port M9.R.15q.5.1 — RPATH resolution for nix-stub deps":

  test "emitted_script_existence_checks_each_dep_mirror_lib_dir":
    # The fix gates every dep mirror dir behind ``[ -d ... ]`` so a
    # nonexistent path (nix-stub dep) is silently skipped instead of
    # baking a dangling entry into the embedded RPATH.
    let deps = @[
      "/recipes/expat/.repro/output/install/usr/lib",
      "/recipes/libltdl/.repro/output/install/usr/lib",
    ]
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", deps)
    for dep in deps:
      check script.contains("[ -d \"" & dep & "\" ]")

  test "emitted_script_folds_ld_library_path_into_rpath":
    # ``$LD_LIBRARY_PATH`` is populated by the engine from each dep's
    # ``libraryPathList`` at fork time. For a nix-stub dep this is the
    # only channel through which the install-mirror script can learn
    # the dep's actual ``/nix/store/...`` lib dir.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("$LD_LIBRARY_PATH")
    # Every entry in $LD_LIBRARY_PATH MUST be existence-checked too —
    # the engine may thread non-existent dirs for half-resolved deps.
    check script.contains("[ -d \"$ldp\" ]")

  test "emitted_script_preserves_origin_family":
    # The $ORIGIN family (M9.R.14f.2 baseline) must still be present
    # after the M9.R.15q.5.1 refactor.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("'$ORIGIN'")
    check script.contains("'$ORIGIN/../lib'")
    check script.contains("'$ORIGIN/../lib64'")

  test "emitted_script_is_deterministic_idempotent_post_q5":
    let deps = @[
      "/recipes/expat/.repro/output/install/usr/lib",
      "/recipes/libltdl/.repro/output/install/usr/lib",
      "/recipes/libffi/.repro/output/install/usr/lib64",
    ]
    let first = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", deps)
    let second = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", deps)
    check first == second

  test "emitted_script_handles_empty_deps_with_q5_changes":
    # No deps + no LD_LIBRARY_PATH still emits the $ORIGIN family + the
    # patchelf-availability guard.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("'$ORIGIN'")
    check script.contains("patchelf --set-rpath")
    check script.contains("command -v patchelf")

  when defined(linux):
    test "linux_end_to_end_rpath_excludes_dangling_includes_real":
      let patchelfPath = findExe("patchelf")
      let ccPath =
        if findExe("cc").len > 0: findExe("cc")
        elif findExe("gcc").len > 0: findExe("gcc")
        else: ""
      if patchelfPath.len == 0 or ccPath.len == 0:
        skip()
      else:
        let scratch = createTempDir("repro-m9r15q-5-", "")
        defer: removeDir(scratch)

        # Build a tiny shared library + executable.
        writeFile(scratch / "lib.c", "int foo(void) { return 7; }\n")
        writeFile(scratch / "main.c",
          "int foo(void); int main(void) { return foo(); }\n")
        let compileLib = startProcess(ccPath,
          args = ["-shared", "-fPIC", "-o", scratch / "libfoo.so",
                  scratch / "lib.c"],
          options = {poUsePath, poParentStreams})
        check waitForExit(compileLib) == 0
        let compileExe = startProcess(ccPath,
          args = ["-o", scratch / "main", scratch / "main.c",
                  "-L" & scratch, "-lfoo", "-Wl,-rpath,/will/overwrite"],
          options = {poUsePath, poParentStreams})
        check waitForExit(compileExe) == 0

        # Set up a real nix-store-style dir + a dangling sibling-recipe
        # path. The shell script (which we exec via /bin/sh -c below)
        # should pick up the real dir, skip the dangling one, AND fold
        # in the LD_LIBRARY_PATH entry pointing at the real dir.
        let realDir = scratch / "nix-store-fake/lib"
        createDir(realDir)
        let danglingDir = scratch / "recipes/libltdl/.repro/output/install/usr/lib"
        let mirrorUsr = scratch / "mirror/usr"
        createDir(mirrorUsr / "lib")
        createDir(mirrorUsr / "bin")
        # Move the synthesized main into the mirror's bin/ so the script
        # walks it.
        moveFile(scratch / "main", mirrorUsr / "bin" / "main")

        # Generate the script with the dangling path declared as a dep
        # so the existence-check has a real target to skip.
        let script = m9r14fEmitRpathPatchScript(mirrorUsr, @[danglingDir])

        # Drive the script with LD_LIBRARY_PATH set to the real
        # nix-store-style dir.
        let oldLdp = getEnv("LD_LIBRARY_PATH")
        putEnv("LD_LIBRARY_PATH", realDir)
        defer: putEnv("LD_LIBRARY_PATH", oldLdp)

        let sh = startProcess("/bin/sh",
          args = ["-c", script],
          options = {poUsePath, poParentStreams})
        check waitForExit(sh) == 0

        # Read the RPATH back; verify the dangling sibling-recipe path
        # is ABSENT and the real nix-store-style dir is PRESENT.
        let probe = startProcess(patchelfPath,
          args = ["--print-rpath", mirrorUsr / "bin" / "main"],
          options = {poUsePath})
        let probeOutput = probe.outputStream.readAll().strip()
        check waitForExit(probe) == 0
        # The dangling sibling-recipe path MUST be absent — that's the
        # whole point of M9.R.15q.5.1.
        check not probeOutput.contains(danglingDir)
        # The real nix-store-style dir MUST be present — folded in via
        # $LD_LIBRARY_PATH.
        check probeOutput.contains(realDir)
        # $ORIGIN family must still be intact.
        check probeOutput.contains("$ORIGIN")

  else:
    test "non_linux_host_documents_runtime_skip_q5":
      check true
