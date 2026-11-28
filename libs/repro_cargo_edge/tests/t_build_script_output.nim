## The run-edge half of the build-script directive interpreter
## (`build_script_output`): parsing a script's output in both directive
## forms, the refusals and build errors it tells apart, the normalisation of
## paths to logical-root tokens, the directive record, and the run edge's
## process end to end on real child processes.
##
## The scripts of the last cases are small shell scripts standing in for a
## compiled `build.rs`: what is tested is the interpreter around a process
## that prints directives, and a shell script is such a process. The
## integration cases (`tests/integration/t_rqe_cg5_build_script_cfg_and_links`
## and the fourth case of `t_rqe_cg5_plan_completes_to_cargos_argv`) run real
## compiled build scripts through the engine and monitor and compare with a
## real cargo build. No mocks.
##
## The older-form rules (`cargo:error=` and `cargo:metadata=` are metadata,
## an unknown `cargo:rustc-*` or `cargo:rerun-*` key is metadata, a line is
## trimmed before its prefix is read) were measured against cargo 1.94.0,
## and the integration case re-measures them against the cargo it runs.
##
## Falsifying mutations (applied, observed to fail, reverted): keeping a
## value's trailing whitespace fails the first case; sorting link-search
## paths by the given spelling of `OUT_DIR` alone fails the second; reading
## an unknown `cargo::` key as metadata fails the fourth; writing values
## without normalising them fails the sixth and the ninth. Not trimming a
## line's leading whitespace fails the first (and the integration case's
## cargo comparison); reading older-form `cargo:error=` as an error fails
## the first; keeping an unknown older-form `rustc-*` or `rerun-*` key as
## metadata fails the third; passing the script's exit status through fails
## the ninth and the tenth; not checking that the script left the
## directives directory alone fails the tenth; resolving the roots before
## `OUT_DIR` exists fails the eleventh; not normalising a `rerun-if-changed`
## path before comparing it with the roots, or not following a symbolic link
## to a directory, fails the twelfth; writing the raw output into the
## script's `TMPDIR` fails the ninth; letting more values than a record
## holds through fails the thirteenth.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_cargo_edge/[build_script_output, record_mode]

proc failureOf(text, outDir: string; rustVersion = ""):
    (DirectiveFailure, string) =
  try:
    discard parseBuildScriptOutput(text, outDir, rustVersion)
  except BuildScriptOutputError as err:
    return (err.failure, err.msg)
  raise newException(AssertionDefect, "no failure for " & text)

suite "build-script output":

  test "both forms, every modelled directive, in printed order":
    let o = "/w/out/pkg-abc/out"
    let text = [
      "noise before",
      "  cargo:rustc-cfg=has_a",
      "cargo::rustc-cfg=feature=\"x\"   ",
      "cargo:rustc-check-cfg=cfg(has_a)",
      "cargo::rustc-env=GEN=" & o & "/gen.rs",
      "cargo:rustc-env=PLAIN=a=b",
      "cargo:rustc-link-lib=static=foo",
      "cargo::rustc-link-lib=bar:baz",
      "cargo:rustc-link-search=native=" & o & "/lib",
      "cargo::rustc-link-search=/usr/lib/x",
      "cargo:rustc-flags=-l dylib=z -L" & o & "/f -lq",
      "cargo:rustc-link-arg=-Wl,--a",
      "cargo::rustc-link-arg-bins=-Wl,--b",
      "cargo:rustc-link-arg-bin=tool=-Wl,--c",
      "cargo:rustc-link-arg-tests=t",
      "cargo:rustc-link-arg-examples=e",
      "cargo:rustc-link-arg-benches=b",
      "cargo:rustc-cdylib-link-arg=c1",
      "cargo::rustc-link-arg-cdylib=c2",
      "cargo::metadata=include=" & o & "/include",
      "cargo:root=" & o,
      "cargo:rerun-if-changed=build.rs",
      "cargo::rerun-if-env-changed=FOO_DIR\r",
      "cargo:warning=careful",
      "cargo::error=bad thing",
      "cargo:error=old form",
      "cargo:metadata=k=v",
      "\tcargo:rustc-cfg=has_b"].join("\n")
    let p = parseBuildScriptOutput(text, o)
    check p.values["rustc-cfg"] == @["has_a", "feature=\"x\"", "has_b"]
    check p.values["rustc-check-cfg"] == @["cfg(has_a)"]
    check p.values["rustc-env"] == @["GEN=" & o & "/gen.rs", "PLAIN=a=b"]
    check p.values["rustc-link-lib"] == @["static=foo", "bar:baz",
      "dylib=z", "q"]
    check p.values["rustc-link-search-in-out-dir"] == @["native=" & o &
      "/lib", o & "/f"]
    check p.values["rustc-link-search-outside-out-dir"] == @["/usr/lib/x"]
    check p.values["rustc-link-arg"] == @["-Wl,--a"]
    check p.values["rustc-link-arg-bins"] == @["-Wl,--b"]
    check p.values["rustc-link-arg-bin"] == @["tool=-Wl,--c"]
    check p.values["rustc-link-arg-tests"] == @["t"]
    check p.values["rustc-link-arg-examples"] == @["e"]
    check p.values["rustc-link-arg-benches"] == @["b"]
    check p.values["rustc-link-arg-cdylib"] == @["c1", "c2"]
    check p.values["metadata"] == @["include=" & o & "/include", "root=" & o,
      "error=old form", "metadata=k=v"]
    check p.values["rerun-if-changed"] == @["build.rs"]
    check p.values["rerun-if-env-changed"] == @["FOO_DIR"]
    check p.values["warning"] == @["careful"]
    check p.errors == @["bad thing"]
    for kind in DirectiveKinds: check kind in p.values

  test "a link-search path is inside OUT_DIR under any spelling of it":
    let base = createTempDir("cg5-bso-", "")
    defer: removeDir(base)
    createDir(base / "real" / "out")
    createSymlink(base / "real", base / "link")
    let given = base / "link" / "out"
    let p = parseBuildScriptOutput(
      "cargo:rustc-link-search=" & base / "real" / "out" / "lib\n" &
      "cargo:rustc-link-search=" & given & "\n" &
      "cargo:rustc-link-search=" & base / "real" / "outside\n", given)
    check p.values["rustc-link-search-in-out-dir"] == @[
      base / "real" / "out" / "lib", given]
    check p.values["rustc-link-search-outside-out-dir"] == @[
      base / "real" / "outside"]

  test "what cargo accepts and these edges do not model is a refusal":
    for line in ["cargo:rustc-link-lib=static:+whole-archive=foo",
                 "cargo:rustc-link-lib=framework=Cocoa",
                 "cargo:rustc-link-lib=raw-dylib=foo",
                 "cargo:rustc-link-lib=",
                 "cargo:rustc-link-search=native=relative/lib",
                 "cargo:rustc-flags=-L relative",
                 "cargo:rustc-env=RUSTC_BOOTSTRAP=1",
                 "cargo:rustc-link-args=-Wl,-x",
                 "cargo:rerun-bogus=1"]:
      checkpoint line
      let (failure, msg) = failureOf(line, "/o")
      check failure == dfRefusal
      check line.strip() in msg

  test "what cargo itself rejects is a build error":
    for (line, rv) in [("cargo:nokey", ""), ("cargo::nokey", ""),
                       ("cargo::bogus=1", ""),
                       ("cargo:rustc-flags=-C opt-level=3", ""),
                       ("cargo:rustc-flags=-l", ""),
                       ("cargo:rustc-env=NOVALUE", ""),
                       ("cargo:rustc-link-arg-bin=noarg", ""),
                       ("cargo::metadata=novalue", ""),
                       ("cargo::rustc-cfg=x", "1.70"),
                       ("cargo:=x", "")]:
      checkpoint line & " " & rv
      let (failure, msg) = failureOf(line, "/o", rv)
      check failure == dfBuildError
      check line in msg
    # The newer form is accepted from 1.77 on, and when no rust-version is
    # declared; the older form under any.
    for rv in ["", "1.77", "1.80.1"]:
      check parseBuildScriptOutput("cargo::rustc-cfg=x", "/o",
        rv).values["rustc-cfg"] == @["x"]
    check parseBuildScriptOutput("cargo:rustc-cfg=x", "/o",
      "1.60").values["rustc-cfg"] == @["x"]

  test "the older form reads an unknown key as metadata":
    let p = parseBuildScriptOutput("cargo:include=/i\ncargo:version=3",
      "/o")
    check p.values["metadata"] == @["include=/i", "version=3"]

  test "values are normalised to root tokens and expand back":
    let roots = withResolvedSpellings(parseRecordRoots(
      "OUT_DIR=/w/out/r-1/out\nout=/w/out\nproject=/w/ws"))
    let values = @["native=/w/out/r-1/out/lib", "GEN=/w/out/r-1/out/a.rs",
      "/w/out/r-2/out/lib", "/w/ws/vendor/x", "/usr/lib/y",
      "COST=$5", "/w/wsx/not-a-root"]
    let n = normaliseValues(roots, values)
    check n == @["native=${OUT_DIR}/lib", "GEN=${OUT_DIR}/a.rs",
      "${out}/r-2/out/lib", "${project}/vendor/x", "/usr/lib/y", "COST=$$5",
      "/w/wsx/not-a-root"]
    for i, v in n: check expandRecorded(roots, v) == values[i]

  test "the directive record round-trips and is checked when read":
    let r = DirectiveRecord(run: "pkg-1.0.0-abc", kind: "rustc-cfg",
      values: @["a", "b=\"c\"", ""])
    let bytes = encodeDirectiveRecord(r)
    check decodeDirectiveRecord(bytes) == r
    expect DirectiveRecordError:
      discard decodeDirectiveRecord(bytes[0 ..< ^1])
    var bad = bytes
    bad[4] = byte('X')
    expect DirectiveRecordError:
      discard decodeDirectiveRecord(bad)
    expect DirectiveRecordError:
      discard encodeDirectiveRecord(DirectiveRecord(run: "x", kind: "nope"))

  test "the outcome record round-trips and is checked when read":
    for r in [OutcomeRecord(run: "r-1", outcome: roSuccess),
              OutcomeRecord(run: "r-1", outcome: roRefusal,
                refusalClass: RefusalClassUnmodelled, message: "m"),
              OutcomeRecord(run: "r-1", outcome: roBuildError, message: "e")]:
      check decodeOutcomeRecord(encodeOutcomeRecord(r)) == r
    expect DirectiveRecordError:
      discard decodeOutcomeRecord(encodeOutcomeRecord(OutcomeRecord(
        run: "r", outcome: roRefusal)))
    expect DirectiveRecordError:
      discard decodeOutcomeRecord(encodeDirectiveRecord(DirectiveRecord(
        run: "r", kind: "rustc-cfg")))

  test "the run edge's process: files, refusals and failures":
    let base = createTempDir("cg5-bsrun-", "")
    defer: removeDir(base)
    let outDir = base / "out" / "r-1" / "out"
    let ws = base / "ws"
    createDir(ws / "extra")
    writeFile(ws / "extra" / "a.txt", "a")
    proc script(name, body: string): string =
      result = base / name
      writeFile(result, "#!/bin/sh\n" & body)
      setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
    proc opts(scriptPath, tag: string; od = outDir): BuildScriptRunOptions =
      BuildScriptRunOptions(package: "pkg@1.0.0", run: "r-1",
        outDir: od, directives: base / tag / "directives",
        stdoutFile: base / tag / "stdout", tmpDir: base / tag / "tmp",
        workDir: base / tag / "work",
        roots: @["out=" & base / "out", "project=" & ws],
        script: @[scriptPath])
    proc outcome(tag: string): OutcomeRecord =
      readOutcomeRecord(base / tag / "directives" / OutcomeFileName)
    putEnv("OUT_DIR", outDir)
    defer: delEnv("OUT_DIR")
    let saved = getCurrentDir()
    setCurrentDir(ws)
    defer: setCurrentDir(saved)

    # A script that writes into OUT_DIR and its TMPDIR and prints both
    # forms.
    let good = script("good.sh",
      "mkdir -p \"$OUT_DIR/lib\" && : > \"$OUT_DIR/lib/libx.a\"\n" &
      "echo 'cargo:rustc-cfg=has_x'\n" &
      "echo \"cargo::rustc-link-search=native=$OUT_DIR/lib\"\n" &
      "echo 'cargo:rustc-link-lib=static=x'\n" &
      "echo 'cargo:rerun-if-changed=extra'\n" &
      "echo 'cargo:warning=w1'\n")
    check runBuildScript(opts(good, "good")) == 0
    check outcome("good").outcome == roSuccess
    check fileExists(outDir / "lib" / "libx.a")
    for kind in DirectiveKinds:
      let rec = readDirectiveRecord(base / "good" / "directives" /
        directiveFileName(kind))
      check rec.run == "r-1"
      check rec.kind == kind
    check readDirectiveRecord(base / "good" / "directives" /
      directiveFileName("rustc-link-search-in-out-dir")).values ==
      @["native=${OUT_DIR}/lib"]
    check readDirectiveRecord(base / "good" / "directives" /
      directiveFileName("rustc-cfg")).values == @["has_x"]
    let stdoutText = readFile(base / "good" / "stdout")
    check "native=${OUT_DIR}/lib" in stdoutText
    check outDir notin stdoutText
    # The raw output is the interpreter's, not in the script's TMPDIR.
    var inTmp = 0
    for _ in walkDir(base / "good" / "tmp"): inc inTmp
    check inTmp == 0
    check fileExists(base / "good" / "work" / "build-script-stdout")

    # OUT_DIR is the engine's to empty: a leftover is refused.
    expect BuildScriptRunError:
      discard runBuildScript(opts(good, "again"))
    removeDir(outDir)

    # An unmodelled directive is a refusal, in the record, with no
    # directive files.
    let unmodelled = script("unmodelled.sh",
      "echo 'cargo:rustc-link-lib=static:+whole-archive=x'\n")
    check runBuildScript(opts(unmodelled, "unmodelled")) == RefusalExitCode
    check outcome("unmodelled").outcome == roRefusal
    check outcome("unmodelled").refusalClass == RefusalClassUnmodelled
    check not fileExists(base / "unmodelled" / "directives" /
      directiveFileName("rustc-cfg"))
    removeDir(outDir)

    # A failing script ends as a build error whatever its status; a
    # `cargo::error` too.
    let failing = script("failing.sh", "exit 7\n")
    check runBuildScript(opts(failing, "failing")) == BuildErrorExitCode
    check outcome("failing").outcome == roBuildError
    removeDir(outDir)
    let erroring = script("erroring.sh", "echo 'cargo::error=no'\n")
    check runBuildScript(opts(erroring, "erroring")) == BuildErrorExitCode
    check outcome("erroring").outcome == roBuildError
    removeDir(outDir)

    # OUT_DIR must be the one the run was given.
    putEnv("OUT_DIR", base / "elsewhere")
    expect BuildScriptRunError:
      discard runBuildScript(opts(good, "mismatch"))
    putEnv("OUT_DIR", outDir)

  test "a script cannot forge a refusal":
    let base = createTempDir("cg5-bsforge-", "")
    defer: removeDir(base)
    let outDir = base / "out" / "r-1" / "out"
    proc script(name, body: string): string =
      result = base / name
      writeFile(result, "#!/bin/sh\n" & body)
      setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
    proc opts(scriptPath, tag: string): BuildScriptRunOptions =
      BuildScriptRunOptions(package: "pkg@1.0.0", run: "r-1",
        outDir: outDir, directives: base / tag / "directives",
        stdoutFile: base / tag / "stdout", tmpDir: base / tag / "tmp",
        workDir: base / tag / "work", roots: @["out=" & base / "out"],
        script: @[scriptPath])
    proc outcome(tag: string): OutcomeRecord =
      readOutcomeRecord(base / tag / "directives" / OutcomeFileName)
    putEnv("OUT_DIR", outDir)
    defer: delEnv("OUT_DIR")
    # Exit 3, the refusal status, with the refusal line on standard error:
    # a build error.
    let forged = script("forged.sh", "echo '" & RefusalLinePrefix &
      "(" & RefusalClassUnmodelled & "): pkg@1.0.0: fake' >&2\nexit " &
      $RefusalExitCode & "\n")
    check runBuildScript(opts(forged, "forged")) == BuildErrorExitCode
    check outcome("forged").outcome == roBuildError
    check outcome("forged").refusalClass == ""
    removeDir(outDir)
    # The same line on a successful run: success.
    let noisy = script("noisy.sh", "echo '" & RefusalLinePrefix &
      "(x): fake' >&2\necho 'cargo:rustc-cfg=ok'\n")
    check runBuildScript(opts(noisy, "noisy")) == 0
    check outcome("noisy").outcome == roSuccess
    removeDir(outDir)
    # A forged outcome record written into the directives directory: the
    # run is refused as a write outside OUT_DIR, and the record is the
    # interpreter's.
    let writer = script("writer.sh",
      "printf 'forged' > '" & base / "writer" / "directives" / OutcomeFileName &
      "'\necho 'cargo:rustc-cfg=ok'\n")
    check runBuildScript(opts(writer, "writer")) == RefusalExitCode
    check outcome("writer").outcome == roRefusal
    check outcome("writer").refusalClass == RefusalClassWriteOutside

  test "an OUT_DIR under a symbolic link is found under its resolved spelling":
    let base = createTempDir("cg5-bslink-", "")
    defer: removeDir(base)
    createDir(base / "real")
    createSymlink(base / "real", base / "link")
    let outDir = base / "link" / "r-1" / "out"
    let sh = base / "resolved.sh"
    writeFile(sh, "#!/bin/sh\nmkdir -p \"$OUT_DIR/lib\"\n" &
      "echo \"cargo:rustc-link-search=native=$(cd \"$OUT_DIR\" && pwd -P)/lib\"\n")
    setFilePermissions(sh, {fpUserRead, fpUserWrite, fpUserExec})
    putEnv("OUT_DIR", outDir)
    defer: delEnv("OUT_DIR")
    let o = BuildScriptRunOptions(package: "pkg@1.0.0", run: "r-1",
      outDir: outDir, directives: base / "d", stdoutFile: base / "stdout",
      tmpDir: base / "tmp", workDir: base / "work", script: @[sh])
    check runBuildScript(o) == 0
    check readDirectiveRecord(base / "d" /
      directiveFileName("rustc-link-search-in-out-dir")).values ==
      @["native=${OUT_DIR}/lib"]

  test "rerun-if-changed folding: normalised, links followed, outputs skipped":
    let base = createTempDir("cg5-bsfold-", "")
    defer: removeDir(base)
    let pkg = base / "pkg"
    for d in ["src", "extra/sub", "linked-target", "target", "out/x"]:
      createDir(pkg / d)
    writeFile(pkg / "src" / "a.rs", "a")
    writeFile(pkg / "extra" / "sub" / "b.txt", "b")
    writeFile(pkg / "linked-target" / "c.txt", "c")
    writeFile(pkg / "target" / "t.txt", "t")
    writeFile(pkg / "out" / "x" / "o.txt", "o")
    createSymlink(pkg / "linked-target", pkg / "extra" / "link")
    createSymlink(pkg / "extra", pkg / "extra" / "sub" / "loop")
    let saved = getCurrentDir()
    setCurrentDir(pkg)
    defer: setCurrentDir(saved)
    # An absolute path through `..` (a relative one is joined, and resolved,
    # by `absolutePath` already): lexically under `out`, really `src`.
    let read = foldRerunPaths([pkg & "/out/../src", "extra", "target",
      "out/x", "absent", "build.rs"], [pkg / "out", pkg / "target"])
    check read == @[pkg / "src" / "a.rs", pkg / "extra" / "link" / "c.txt",
      pkg / "extra" / "sub" / "b.txt"]

  test "a value or a count the record cannot hold is a refusal":
    let base = createTempDir("cg5-bsbig-", "")
    defer: removeDir(base)
    let outDir = base / "out" / "r-1" / "out"
    putEnv("OUT_DIR", outDir)
    defer: delEnv("OUT_DIR")
    for (tag, body) in [
        ("long", "printf 'cargo:rustc-cfg=%0" & $(MaxRecordTextBytes + 1) &
          "d\\n' 0\n"),
        ("many", "i=0; while [ $i -le " & $MaxRecordValues &
          " ]; do echo cargo:rustc-cfg=c; i=$((i+1)); done\n")]:
      checkpoint tag
      let sh = base / (tag & ".sh")
      writeFile(sh, "#!/bin/sh\n" & body)
      setFilePermissions(sh, {fpUserRead, fpUserWrite, fpUserExec})
      let o = BuildScriptRunOptions(package: "pkg@1.0.0", run: "r-1",
        outDir: outDir, directives: base / tag / "d",
        stdoutFile: base / tag / "stdout", tmpDir: base / tag / "tmp",
        workDir: base / tag / "work", script: @[sh])
      check runBuildScript(o) == RefusalExitCode
      let rec = readOutcomeRecord(base / tag / "d" / OutcomeFileName)
      check rec.outcome == roRefusal
      check rec.refusalClass == RefusalClassUnmodelled
      removeDir(outDir)
