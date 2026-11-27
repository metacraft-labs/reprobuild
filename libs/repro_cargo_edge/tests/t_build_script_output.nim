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
## Falsifying mutations (applied, observed to fail, reverted): keeping a
## value's trailing whitespace fails the first case; sorting link-search
## paths by the given spelling of `OUT_DIR` alone fails the second; reading
## an unknown `cargo::` key as metadata fails the fourth; writing values
## without normalising them fails the sixth and the eighth.

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
      "cargo:rustc-cfg=has_a",
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
      "cargo:rustc-cfg=has_b"].join("\n")
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
    check p.values["metadata"] == @["include=" & o & "/include", "root=" & o]
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
                 "cargo:metadata=x=y"]:
      checkpoint line
      let (failure, msg) = failureOf(line, "/o")
      check failure == dfRefusal
      check line in msg

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
    proc opts(scriptPath, tag: string): BuildScriptRunOptions =
      BuildScriptRunOptions(package: "pkg@1.0.0", run: "r-1",
        outDir: outDir, directives: base / tag / "directives",
        stdoutFile: base / tag / "stdout", tmpDir: base / tag / "tmp",
        roots: @["out=" & base / "out", "project=" & ws],
        script: @[scriptPath])
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

    # OUT_DIR is the engine's to empty: a leftover is refused.
    expect BuildScriptRunError:
      discard runBuildScript(opts(good, "again"))
    removeDir(outDir)

    # An unmodelled directive is a refusal, with its exit code and no files.
    let unmodelled = script("unmodelled.sh",
      "echo 'cargo:rustc-link-lib=static:+whole-archive=x'\n")
    check runBuildScript(opts(unmodelled, "unmodelled")) == RefusalExitCode
    check not fileExists(base / "unmodelled" / "directives" /
      directiveFileName("rustc-cfg"))
    removeDir(outDir)

    # A failing script ends with its status; a `cargo::error` with 1.
    let failing = script("failing.sh", "exit 7\n")
    check runBuildScript(opts(failing, "failing")) == 7
    removeDir(outDir)
    let erroring = script("erroring.sh", "echo 'cargo::error=no'\n")
    check runBuildScript(opts(erroring, "erroring")) == 1
    removeDir(outDir)

    # OUT_DIR must be the one the run was given.
    putEnv("OUT_DIR", base / "elsewhere")
    expect BuildScriptRunError:
      discard runBuildScript(opts(good, "mismatch"))
