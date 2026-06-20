## DSL-port M9.R.14f.2 — install-mirror RPATH patching.
##
## ## Context
##
## M9.R.14f.1 (transitive libDirs union) thread runtime lib dirs onto
## the action env at fork time so a downstream action can find its
## deps via LD_LIBRARY_PATH. But the resulting binaries cannot run
## STANDALONE without that env — re-execing a from-source-built
## ``wayland-scanner`` without LD_LIBRARY_PATH would fail to find
## ``libexpat.so.1``.
##
## M9.R.14f.2 closes the gap by embedding the search paths in the ELF
## via ``patchelf --set-rpath`` at install-mirror time:
##
##   * ``$ORIGIN`` (the binary's own dir) — covers SONAME chains where
##     the recipe ships multiple .so files in the same lib/.
##   * ``$ORIGIN/../lib`` + ``$ORIGIN/../lib64`` — covers
##     ``<mirror>/bin/<tool>`` reaching ``<mirror>/lib/<dep>``.
##   * Absolute paths to each dep's install-mirror lib/ dir — covers
##     transitive runtime deps from other recipes.
##
## ## What this test pins
##
##   1. ``m9r14fStripDepConstraint`` strips version-constraint suffixes
##      like ``" >=1.22"`` to the bare dep name.
##   2. ``m9r14fEmitRpathPatchScript`` emits a shell snippet that:
##      a. Invokes ``patchelf --set-rpath``.
##      b. Includes the literal ``$ORIGIN`` token (the dynamic linker
##         evaluates it at load time, so it must reach patchelf
##         verbatim).
##      c. Includes ``$ORIGIN/../lib`` for the bin/ → lib/ hop.
##      d. Includes every absolute peer-recipe dep mirror lib dir.
##      e. Walks the mirror's lib/ + lib64/ + bin/ dirs.
##   3. Idempotence: emitting the script twice with the same inputs
##      produces byte-identical output.
##   4. Linux-only end-to-end: when ``patchelf`` is on PATH AND a C
##      compiler is available, build a synthetic ELF, run patchelf
##      with the same RPATH layout the script produces, verify
##      ``patchelf --print-rpath`` matches.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_dsl_stdlib/types/package_result

suite "DSL-port M9.R.14f.2 — install-mirror RPATH patching":

  test "strip_dep_constraint_handles_common_grammars":
    check m9r14fStripDepConstraint("wayland >=1.22") == "wayland"
    check m9r14fStripDepConstraint("libxml2 >=2.9") == "libxml2"
    check m9r14fStripDepConstraint("expat") == "expat"
    check m9r14fStripDepConstraint("foo<2.0") == "foo"
    check m9r14fStripDepConstraint("bar=1.0") == "bar"
    check m9r14fStripDepConstraint("baz~1") == "baz"
    check m9r14fStripDepConstraint("qux^2") == "qux"
    check m9r14fStripDepConstraint("") == ""

  test "emitted_script_contains_patchelf_invocation":
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("patchelf --set-rpath")

  test "emitted_script_preserves_dollar_ORIGIN_token":
    # $ORIGIN must be passed to patchelf VERBATIM (single-quoted in
    # the shell) so the dynamic linker can evaluate it at load time.
    # An expanded $ORIGIN would be the empty string at script time,
    # which would yield an unusable RPATH.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("'$ORIGIN'")
    # And the bin/ -> lib/ hop:
    check script.contains("'$ORIGIN/../lib'")
    check script.contains("'$ORIGIN/../lib64'")

  test "emitted_script_walks_lib_lib64_bin":
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("/tmp/mirror/usr/lib")
    check script.contains("/tmp/mirror/usr/lib64")
    check script.contains("/tmp/mirror/usr/bin")

  test "emitted_script_includes_dep_mirror_lib_dirs":
    let deps = @[
      "/recipes/expat/.repro/output/install/usr/lib",
      "/recipes/libffi/.repro/output/install/usr/lib",
    ]
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", deps)
    for dep in deps:
      check script.contains(dep)

  test "emitted_script_is_deterministic_idempotent":
    let deps = @[
      "/recipes/expat/.repro/output/install/usr/lib",
      "/recipes/libffi/.repro/output/install/usr/lib64",
    ]
    let first = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", deps)
    let second = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", deps)
    check first == second

  test "emitted_script_handles_empty_deps":
    # No deps still emits the $ORIGIN family so a recipe's same-mirror
    # SONAME chain (libwayland-server next to libwayland-client) works
    # even when the recipe has no transitive deps.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("'$ORIGIN'")
    check script.contains("'$ORIGIN/../lib'")
    check script.contains("patchelf --set-rpath")

  test "emitted_script_guards_on_patchelf_availability":
    # The script must short-circuit when patchelf isn't on PATH so
    # host-side action-graph emission (where patchelf may not be
    # provisioned) doesn't fail the build.
    let script = m9r14fEmitRpathPatchScript("/tmp/mirror/usr", @[])
    check script.contains("command -v patchelf")

  when defined(linux):
    test "linux_end_to_end_patchelf_against_synthetic_elf":
      let patchelfPath = findExe("patchelf")
      if patchelfPath.len == 0:
        skip()
        return
      let ccPath =
        if findExe("cc").len > 0: findExe("cc")
        elif findExe("gcc").len > 0: findExe("gcc")
        else: ""
      if ccPath.len == 0:
        skip()
        return

      let scratch = createTempDir("repro-m9r14f-2-", "")
      defer: removeDir(scratch)

      # Build a tiny shared library + executable so patchelf has real
      # ELFs to operate on.
      writeFile(scratch / "lib.c", "int foo(void) { return 42; }\n")
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

      # Construct the same RPATH the install-mirror script generates.
      let expectedRpath = "$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib64:" &
        scratch & "/peerlib"
      let patch = startProcess(patchelfPath,
        args = ["--set-rpath", expectedRpath, scratch / "main"],
        options = {poUsePath, poParentStreams})
      check waitForExit(patch) == 0

      # Read the RPATH back via `patchelf --print-rpath`.
      let probe = startProcess(patchelfPath,
        args = ["--print-rpath", scratch / "main"],
        options = {poUsePath})
      let probeOutput = probe.outputStream.readAll().strip()
      check waitForExit(probe) == 0
      check probeOutput == expectedRpath
      check probeOutput.contains("$ORIGIN")
      check probeOutput.contains(scratch & "/peerlib")

      # Idempotent: re-apply the same RPATH; the readback is
      # byte-identical.
      let patch2 = startProcess(patchelfPath,
        args = ["--set-rpath", expectedRpath, scratch / "main"],
        options = {poUsePath, poParentStreams})
      check waitForExit(patch2) == 0
      let probe2 = startProcess(patchelfPath,
        args = ["--print-rpath", scratch / "main"],
        options = {poUsePath})
      let probe2Output = probe2.outputStream.readAll().strip()
      check waitForExit(probe2) == 0
      check probe2Output == expectedRpath

  else:
    test "non_linux_host_documents_runtime_skip":
      # The patchelf E2E test runs only on Linux. The structural
      # script-emit tests above pin the contract on every platform.
      check true
