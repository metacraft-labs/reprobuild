## `repro cargo record-live --pass-through` and the stream splitter under the
## cargo shim: a MIXED stream, cargo's
## JSON lines among other output, is split so that the recorder gets the JSON
## and standard output gets every other byte unchanged and live.
##
## The splitter is pure, so its cases need no mock and no process; the
## recorder case builds a fixture crate with REAL cargo and mixes a real
## `--message-format=json-render-diagnostics` stream with lines the way
## `cargo test` interleaves a test binary's output. Nothing is faked.
##
## Falsifying mutations (applied once to stream.nim, observed to fail,
## reverted): hold a line until its newline before forwarding (the
## partial-line case fails); divert a line when it merely starts with `{`
## (the not-cargo's-JSON case fails).

import std/[algorithm, os, osproc, sequtils, strutils, tempfiles, unittest]
import repro_cargo_gc

type Split = tuple[pass, divert: string]

proc splitIn(chunks: seq[string]): Split =
  var s = initStreamSplitter()
  var got: Split
  let pass: ChunkSink = proc (c: string) = got.pass.add c
  let divert: ChunkSink = proc (c: string) = got.divert.add c
  for c in chunks: s.feed(c, pass, divert)
  s.finish(pass)
  got

const
  Json1 = "{\"reason\":\"compiler-artifact\",\"fresh\":false}\n"
  Json2 = "{\"reason\":\"build-finished\",\"success\":true}\n"
  Mixed = "running 1 test\n" & Json1 & "test a ... ok\n{not json}\n" &
    "{\"reasonx\":1}\n" & Json2 & "partial no newline"

suite "stream splitter":

  test "cargo's JSON lines are diverted and every other byte is forwarded " &
      "in order, whatever the chunking":
    let whole = splitIn(@[Mixed])
    check whole.divert == Json1 & Json2
    check whole.pass == "running 1 test\ntest a ... ok\n{not json}\n" &
      "{\"reasonx\":1}\npartial no newline"
    # Every two-chunk split, and one byte at a time, give the same result.
    for cut in 0 .. Mixed.len:
      check splitIn(@[Mixed[0 ..< cut], Mixed[cut .. ^1]]) == whole
    check splitIn(Mixed.mapIt($it)) == whole
    check whole.divert.len > 0 and whole.pass.len > 0 # not a vacuous split

  test "a partial last line is forwarded at once, without waiting for a " &
      "newline; only a line's leading marker bytes are ever held":
    var s = initStreamSplitter()
    var passed = ""
    var diverted = ""
    let pass: ChunkSink = proc (c: string) = passed.add c
    let divert: ChunkSink = proc (c: string) = diverted.add c
    s.feed("test output without a newline", pass, divert)
    check passed == "test output without a newline" # at once
    s.feed(" and more", pass, divert)
    check passed == "test output without a newline and more"
    s.feed("\n{\"rea", pass, divert) # a prefix of the marker: held
    check passed.endsWith("more\n")
    s.feed("dy\" no newline either", pass, divert) # contradicted: released
    check passed.endsWith("{\"ready\" no newline either")
    check diverted.len == 0
    s.feed("\n{\"reas", pass, divert)
    s.finish(pass) # the stream ends inside the held prefix
    check passed.endsWith("\n{\"reas")
    check diverted.len == 0

  test "a JSON line split across chunks is diverted whole":
    var s = initStreamSplitter()
    var passed = ""
    var diverted = ""
    let pass: ChunkSink = proc (c: string) = passed.add c
    let divert: ChunkSink = proc (c: string) = diverted.add c
    s.feed("{\"reason\":\"compiler-art", pass, divert)
    s.feed("ifact\"}\nnext line\n", pass, divert)
    s.finish(pass)
    check diverted == "{\"reason\":\"compiler-artifact\"}\n"
    check passed == "next line\n"

suite "record-live --pass-through (library)":

  test "recordLiveSetPassThrough records what recordLiveSet records from the " &
      "JSON lines alone and forwards the rest unchanged":
    doAssert findExe("cargo").len > 0 and findExe("rustc").len > 0,
      "this case needs cargo and rustc on PATH (the dev shell provides them)"
    let root = createTempDir("rqe-cg2-passthrough-", "")
    defer: removeDir(root)
    let project = root / "project"
    createDir(project / "src")
    writeFile(project / "Cargo.toml",
      "[package]\nname = \"pt\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
    writeFile(project / "src" / "lib.rs", "pub fn f() -> u32 { 1 }\n")
    let target = root / "target"
    for name in ["CARGO_TARGET_DIR", "RUSTFLAGS", "RUSTC_WRAPPER",
                 "CARGO_ENCODED_RUSTFLAGS"]:
      delEnv(name)
    putEnv("CARGO_HOME", root / "cargo-home")
    let (output, code) = execCmdEx("cargo build --offline --quiet " &
      "--message-format=json --target-dir " & quoteShell(target),
      workingDir = project)
    require code == 0
    let jsonLines = output.splitLines.filterIt(it.startsWith("{"))
    require jsonLines.len >= 2
    # Interleave program output the way `cargo test` does.
    var mixed = "before\n"
    for line in jsonLines: mixed.add line & "\nbetween lines\n"
    mixed.add "tail without newline"
    let input = root / "stream.txt"
    let forwarded = root / "forwarded.txt"
    writeFile(input, mixed)
    let inF = open(input, fmRead)
    let outF = open(forwarded, fmWrite)
    let report = recordLiveSetPassThrough(target, inF, outF)
    close(inF)
    close(outF)
    check report.units >= 1
    check readFile(forwarded) == "before\n" &
      jsonLines.mapIt("between lines\n").join("") & "tail without newline"
    # The oracle: the library entry point fed the JSON lines alone.
    let oracle = recordLiveSet(target, jsonLines)
    check oracle.units == report.units
    check oracle.profileDirs == report.profileDirs
