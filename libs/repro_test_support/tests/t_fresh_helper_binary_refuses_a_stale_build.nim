## A test's helper binary is used only when it was built from the tree
## under test (reprobuild-pm issues 2026-11-07-addon-allow-listed-source-
## field-turns-the-sinks-redaction-case-red-masked-by-a-stale-sink and
## 2026-11-08-fresh-binary-does-not-see-included-files-or-modules-outside-
## the-tree; §13 decision 65 of the ReproOS Add-On Mode spec).
##
## A small tree is compiled by the real Nim into ``build/bin/foo-helper``
## (a name other than the main module's, as ``repro-evidence-sink`` is) with its own
## nimcache, and its dependency list written by
## ``scripts/write_helper_deps.sh``, as ``scripts/build_apps.sh`` does for a
## helper. The app imports a library module of the tree, ``include``s a file
## of its own, imports a module from a directory outside the tree (as a
## sibling checkout is), compiles a C file with ``{.compile.}`` that
## includes a header, ``staticRead``s a file, and runs a ``staticExec``
## command that reads another. ``freshRepoBinary`` is asked for it:
##
## 1. Built from the tree as it is: the binary is returned, and the list
##    names each of those sources under its kind.
## 2. A library module edited after the build: refused, naming it.
## 3. The app's own module edited after an incremental rebuild that
##    compiled nothing: refused.
## 4. The included file edited after the build: refused.
## 5. The module from outside the tree edited after the build: refused.
## 6. Rebuilt: accepted again.
## 7. No binary, or no dependency list: refused.
## 8. The C file edited after the build: refused.
## 9. The header it includes edited after the build: refused.
## 10. The ``staticRead`` file edited after the build: refused.
## 11. The binary rebuilt by ``nim c`` alone, its list not rewritten (a
##     list from another build): refused.
## 12. ``write_helper_deps.sh`` failing after a good build: the old list is
##     removed, so the binary is refused.
## 13. A file a ``staticExec`` command reads by a RELATIVE path (Nim runs
##     the command in the calling module's directory): listed, and an edit
##     to it after the build is refused.
## 14. Eight files a ``staticExec`` command reads concurrently (``cat … &``):
##     all eight listed, in each of three runs (the list does not depend on
##     scheduling).
##
## 15-18. A file a ``staticExec`` command reads whose name strace escapes
##     (non-ASCII bytes, ``>``, a newline, a backslash): listed (strace
##     ``-xx``, decoded), and an edit to it after the build is refused.
## 19. A workspace binary a ``staticExec`` command executes (``execve``):
##     listed, and a newer one refused.
## 20. A directory a ``staticExec`` command lists (``getdents``): its
##     Nim entries are recorded, and a new ``.nim`` entry refuses the
##     binary; a new non-Nim entry does not (§13 decisions 80 and 111).
## 21. A traced workspace path that is no longer a file when the list is
##     written fails the writer: no list, never a silent drop.
## 22. A strace that prints a format the writer does not parse (a wrapper
##     that drops ``-xx``, as any strace whose ``-y`` paths are text does):
##     the writer fails, no list is written, and the binary is refused --
##     never a list of ``module`` entries alone that accepts the binary
##     after its ``staticRead`` input changed.
## 23. A strace that traces none of the writer's syscalls (a wrapper that
##     replaces ``-e trace=``): the positive control -- the entry module's
##     own ``open`` -- is missing, so the writer fails and writes no list.
## 24. (round 9, decision 111) A ``.nimcache/`` directory, another directory,
##     a ``result`` link and a non-source file added to directories the
##     compiler listed (the tree root among them) are not a change.
## 25. (round 9, decision 111) A new ``.nim`` file in a directory the
##     compiler searched (the tree root, the app's directory) is refused.
## 26-27. (round 9) A file read under a name with a trailing, or a
##     leading, space is checked under that name, not under the decoy of
##     the trimmed name beside it.
## 28. A successful open of a workspace file whose fd path strace marks
##     ``(deleted)`` (printed after the closing ``>``): the file was read
##     and the list cannot check it, so the writer fails -- it is never
##     skipped as a failed syscall, which left the ``staticRead`` file out
##     of the list.
## 29. A ``staticExec`` command that makes an ``O_TMPFILE`` file (Python's
##     ``tempfile.TemporaryFile()``, glibc ``tmpfile()``) and reopens it
##     through ``/proc/self/fd``: strace prints both opens ``(deleted)``,
##     and they are anonymous, never sources, so the list is written.
## 30. (round 9) A directory a ``staticExec`` command lists whose name
##     ends in a space is recorded and checked under that name: a new
##     ``.nim`` entry in it is refused, and one in the decoy directory of
##     the trimmed name beside it is not.
##
## 31-34. (round 10's listing rules, no §13 decision yet) In a tree
##     whose app imports ``pkgx/util`` through ``--path:vendor``: a
##     package directory ``apps/foo/pkgx`` that shadows the import,
##     ``apps/foo/foo.nim.cfg``, ``apps/foo/nim.cfg`` and a parent
##     ``apps/nim.cfg`` (each adding a define) are each refused, and
##     accepted again once removed.
##
## Falsifying builds: ``stale-helper-accepted`` (cases 2-5 and 8-10 red),
## ``fresh-skips-included`` (case 4), ``fresh-skips-outside-tree`` (case
## 5), ``fresh-skips-c-sources`` (case 8), ``fresh-skips-headers`` (case
## 9), ``fresh-skips-static-reads`` (case 10), ``fresh-ignores-list-binary``
## (case 11), ``fresh-ignores-listings`` (cases 20, 25); and the script's
## ``WRITE_HELPER_DEPS_MUTATION`` in the environment: ``keep-old-list``
## (case 12), ``relative-to-script-dir`` (case 13), ``single-trace``
## (case 14), ``text-paths`` (cases 15-18; it is the round-7 trace, so
## 19-25 go red with it), ``no-execve`` (case 19), ``no-listing``
## (cases 20, 25, and 24, which first checks that the root and the app's
## directory were listed), ``drop-unresolved`` (case 21),
## ``accept-unparsed`` (cases 22 and 23), ``listing-digests-every-entry``
## (cases 20, 24: round 8's digest of every name, written and checked as
## the list says), ``trim-edge-spaces`` (case 26: the path written without
## its trailing space, as round 8's strip() read it; case 27's leading
## space sits after the path's "/", so no line strip reaches it, and it is
## a positive case only; case 30: the listing written for the trimmed
## directory name), ``suffix-is-failure`` (case 28; ``accept-unparsed``
## turns it red too), ``deleted-is-unparsed`` (case 29),
## ``listing-skips-subdirectories`` (case 31), ``listing-skips-project-cfg``
## (case 32), ``listing-skips-nim-cfg`` (cases 33 and 34) and
## ``no-parent-listings`` (case 34, the parent ``apps/nim.cfg``; it also
## turns case 25's tree-root ``.nim`` red, and case 24, which checks that
## the tree root was listed).
##
## Cases 22, 23 and 28 run the real strace behind a wrapper script named by
## ``REPRO_STRACE``. The wrapper is justified: it is how the writer's
## caller selects a strace, and it stands in for a strace build that prints
## another format (or the caller's PATH strace, which path mode runs),
## which cannot be installed on demand.
##
## Mocks: none -- the real compiler, the real script, strace.

import std/[os, osproc, sequtils, strutils, tempfiles, times, unittest]

import repro_test_support/fresh_binary

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

let base = createTempDir("fresh-binary-", "")
let tree = base / "tree"
let lib = tree / "libs" / "foolib" / "src" / "foolib" / "bar.nim"
let app = tree / "apps" / "foo" / "foo.nim"
let included = tree / "apps" / "foo" / "foo_part.nim"
let outside = base / "sibling" / "src" / "ext.nim"
let csrc = tree / "apps" / "foo" / "helper.c"
let header = tree / "apps" / "foo" / "inc" / "helper.h"
let blob = tree / "apps" / "foo" / "blob.txt"
let execInput = tree / "apps" / "foo" / "exec-input.txt"
let relInput = tree / "apps" / "foo" / "rel-input.txt"
var parInputs: seq[string]
for i in 1 .. 8: parInputs.add(tree / "apps" / "foo" / ("par" & $i & ".txt"))
createDir(parentDir(lib))
createDir(parentDir(app))
createDir(parentDir(outside))
createDir(parentDir(header))
writeFile(csrc, "#include \"helper.h\"\nint fooHelper(void) { return HELPER_VALUE; }\n")
writeFile(header, "#define HELPER_VALUE 7\n")
writeFile(blob, "read at compile time\n")
writeFile(execInput, "read by a staticExec command\n")
writeFile(relInput, "read by a relative path, in the module's directory\n")
for p in parInputs: writeFile(p, "read concurrently\n")
var parCmd = ""
for p in parInputs: parCmd.add("cat " & p & " & ")
parCmd.add("wait")
# Round 8: names strace escapes, an executed workspace binary, a listed
# directory (§13 decision 80).
let fooDir = tree / "apps" / "foo"
let nonAscii = fooDir / "\xC3\xA9.txt"           # "é.txt"
let gtName = fooDir / "a>b.txt"
let nlName = fooDir / "nl\nx.txt"
let bsName = fooDir / "bs\\c.txt"
let helloSrc = fooDir / "hello.c"
let hello = fooDir / "hello"
let listDir = fooDir / "listdir"
for p in [nonAscii, gtName, nlName, bsName]: writeFile(p, "escaped by strace\n")
# Round 9: names with a trailing and a leading space, each beside a decoy
# of the trimmed name.
let trailing = fooDir / "tr.txt "
let leading = fooDir / " lead.txt"
for p in [trailing, leading]: writeFile(p, "a name with an edge space\n")
for p in [fooDir / "tr.txt", fooDir / "lead.txt"]: writeFile(p, "decoy\n")
# ...and a listed directory whose name ends in a space, beside a decoy of
# the trimmed name with the same entries (so the two digests agree until
# the case adds an entry).
let spaceDir = fooDir / "ld "
let spaceDirDecoy = fooDir / "ld"
for d in [spaceDir, spaceDirDecoy]:
  createDir(d)
  writeFile(d / "one.nim", "discard\n")
writeFile(helloSrc, "#include <stdio.h>\nint main(void){puts(\"hello\");return 0;}\n")
block:
  let (o, c) = execCmdEx(quoteShellCommand(["gcc", "-o", hello, helloSrc]))
  doAssert c == 0, o
createDir(listDir)
writeFile(listDir / "one.txt", "listed\n")
writeFile(lib, "proc greeting*(): string = \"hello\"\n")
writeFile(outside, "proc farAway*(): string = \"from outside\"\n")
writeFile(included, "proc part(): string = \"included\"\n")
proc writeApp(extra = "") =
  writeFile(app, "import foolib/bar\nimport ext\ninclude foo_part\n" &
    "{.compile(\"helper.c\", \"-I" & parentDir(header) & "\").}\n" &
    "proc fooHelper(): cint {.importc.}\n" &
    "const blob = staticRead(\"blob.txt\")\n" &
    "const fromExec = staticExec(\"cat " & execInput & "\")\n" &
    "const fromRel = staticExec(\"cat rel-input.txt\")\n" &
    "const fromPar = staticExec(\"" & parCmd & "\")\n" &
    "const fromEscaped = staticExec(\"cat \xC3\xA9.txt 'a>b.txt' nl?x.txt bs?c.txt\")\n" &
    "const fromHello = staticExec(\"./hello\")\n" &
    "const fromListing = staticExec(\"ls listdir\")\n" &
    "const fromSpaces = staticExec(\"cat 'tr.txt ' ' lead.txt'\")\n" &
    "const fromSpaceDir = staticExec(\"ls 'ld '\")\n" &
    "echo greeting(), farAway(), part(), fooHelper(), blob, fromExec, fromRel, fromPar.len, fromEscaped.len, fromHello, fromListing, fromSpaces.len, fromSpaceDir\n" & extra)
writeApp()
let binary = tree / "build" / "bin" / addFileExt("foo-helper", ExeExt)

proc build() =
  ## Compile the tree and write its dependency list, after dating its
  ## sources a minute back (an earlier case may have dated one into the
  ## future).
  for src in @[lib, app, included, outside, csrc, header, blob, execInput, relInput,
               nonAscii, gtName, nlName, bsName, hello, trailing, leading] & parInputs:
    setLastModificationTime(src, getTime() - initDuration(seconds = 60))
  let flags = @["--path:" & tree / "libs" / "foolib" / "src",
                "--path:" & parentDir(outside)]
  let (o1, c1) = execCmdEx(quoteShellCommand(@["nim", "c", "--hints:off",
    "--warnings:off"] & flags & @["--nimcache:" & tree / "build" / "nimcache" / "foo-helper",
    "--out:" & binary, app]))
  doAssert c1 == 0, o1
  let (o2, c2) = execCmdEx(quoteShellCommand(@["bash",
    RepoRoot / "scripts" / "write_helper_deps.sh", "foo-helper", app] & flags),
    workingDir = tree)
  doAssert c2 == 0, o2

proc touchAfterBinary(path: string) =
  ## Mark ``path`` edited ten seconds after the binary was built, without
  ## depending on the file system's timestamp resolution.
  setLastModificationTime(path,
    getLastModificationTime(binary) + initDuration(seconds = 10))

proc refusal(): string =
  try:
    discard freshRepoBinary(tree, "foo-helper")
    ""
  except StaleHelperBinary as e:
    e.msg

suite "a helper binary is used only when built from the tree under test":
  test "1: built from the tree as it is, it is returned":
    build()
    check freshRepoBinary(tree, "foo-helper") == binary
    let deps = helperDependencies(tree, "foo-helper")
    checkpoint deps.join("\n")
    for want in [lib, app, included, outside, csrc, header, blob, execInput]:
      check want in deps
    let list = readFile(tree / "build" / "nimcache" / "foo-helper" / "foo-helper.deps")
    check list.startsWith("binary-sha256 ")
    check ("csource " & csrc) in list
    check ("header " & header) in list
    check ("read " & blob) in list

  test "2: a library module edited after the build is refused":
    # Each case builds the tree itself: the test runner runs every case in
    # a process of its own, with a fresh tree (createTempDir above).
    build()
    check refusal() == ""
    touchAfterBinary(lib)
    let why = refusal()
    checkpoint why
    check ("older than " & lib) in why
    check "just build" in why

  test "3: the app's module edited after an incremental rebuild is refused":
    build()
    check refusal() == ""
    touchAfterBinary(app)
    let why = refusal()
    checkpoint why
    check ("older than " & app) in why

  test "4: an included file edited after the build is refused":
    build()
    check refusal() == ""
    touchAfterBinary(included)
    let why = refusal()
    checkpoint why
    check ("older than " & included) in why

  test "5: a module from outside the tree edited after the build is refused":
    build()
    check refusal() == ""
    touchAfterBinary(outside)
    let why = refusal()
    checkpoint why
    check ("older than " & outside) in why

  test "6: rebuilt, it is accepted again":
    build()
    check refusal() == ""

  test "8: the {.compile.} C file edited after the build is refused":
    build()
    check refusal() == ""
    touchAfterBinary(csrc)
    let why = refusal()
    checkpoint why
    check ("older than " & csrc) in why

  test "9: the header that C file includes edited after the build is refused":
    build()
    check refusal() == ""
    touchAfterBinary(header)
    let why = refusal()
    checkpoint why
    check ("older than " & header) in why

  test "10: the staticRead file edited after the build is refused":
    build()
    check refusal() == ""
    touchAfterBinary(blob)
    let why = refusal()
    checkpoint why
    check ("older than " & blob) in why

  test "11: a binary rebuilt without its list (a list from another build) is refused":
    build()
    check refusal() == ""
    writeApp("echo \"rebuilt\"\n")
    let (o, c) = execCmdEx(quoteShellCommand(@["nim", "c", "--hints:off",
      "--warnings:off", "--path:" & tree / "libs" / "foolib" / "src",
      "--path:" & parentDir(outside),
      "--nimcache:" & tree / "build" / "nimcache" / "foo-helper",
      "--out:" & binary, app]))
    doAssert c == 0, o
    let why = refusal()
    checkpoint why
    check "is not the binary its dependency list describes" in why
    writeApp()

  test "12: a failed list write after a good build leaves no list":
    build()
    check refusal() == ""
    let (o, c) = execCmdEx(quoteShellCommand(@["bash",
      RepoRoot / "scripts" / "write_helper_deps.sh", "foo-helper",
      tree / "apps" / "foo" / "no_such_entry.nim"]), workingDir = tree)
    checkpoint o
    check c != 0
    check "has no dependency list" in refusal()

  test "13: a file a staticExec command reads by a relative path is checked":
    build()
    check relInput in helperDependencies(tree, "foo-helper")
    check refusal() == ""
    touchAfterBinary(relInput)
    let why = refusal()
    checkpoint why
    check ("older than " & relInput) in why

  test "14: files a staticExec command reads concurrently are all listed, every run":
    for run in 1 .. 3:
      build()
      let deps = helperDependencies(tree, "foo-helper")
      var missing: seq[string]
      for p in parInputs:
        if p notin deps: missing.add(p)
      checkpoint "run " & $run & ": missing " & $missing
      check missing.len == 0

  for (n, label, p) in [(15, "a non-ASCII name", nonAscii), (16, "a name with '>'", gtName),
                        (17, "a name with a newline", nlName), (18, "a name with a backslash", bsName)]:
    test $n & ": a file with " & label & " a staticExec command reads is checked":
      build()
      check p in helperDependencies(tree, "foo-helper")
      check refusal() == ""
      touchAfterBinary(p)
      let why = refusal()
      checkpoint why
      check ("older than " & p) in why

  test "19: a workspace binary a staticExec command executes is checked":
    build()
    check hello in helperDependencies(tree, "foo-helper")
    check refusal() == ""
    touchAfterBinary(hello)
    let why = refusal()
    checkpoint why
    check ("older than " & hello) in why

  test "20: a directory a staticExec command lists is checked by its Nim entries":
    build()
    check refusal() == ""
    # §13 decision 111: a name that cannot change what the compiler
    # resolves does not count, even in a listing a command made.
    writeFile(listDir / "two.txt", "a new entry\n")
    check refusal() == ""
    writeFile(listDir / "two.nim", "discard\n")
    let why = refusal()
    checkpoint why
    check ("listing of " & listDir & " that has changed") in why
    removeFile(listDir / "two.nim")
    check refusal() == ""

  test "21: a traced workspace path that is not a file fails the list":
    # Its own tree: a staticExec that reads a file and removes it, so the
    # path the trace names is no file when the list is written.
    let t2 = base / "tree21"
    let app2 = t2 / "apps" / "gone" / "gone.nim"
    createDir(parentDir(app2))
    writeFile(app2, "const g = staticExec(\"echo x > gone.txt; cat gone.txt; rm gone.txt\")\necho g\n")
    let bin2 = t2 / "build" / "bin" / "gone"
    let (o1, c1) = execCmdEx(quoteShellCommand(@["nim", "c", "--hints:off",
      "--warnings:off", "--nimcache:" & t2 / "build" / "nimcache" / "gone",
      "--out:" & bin2, app2]))
    doAssert c1 == 0, o1
    let (o2, c2) = execCmdEx(quoteShellCommand(@["bash",
      RepoRoot / "scripts" / "write_helper_deps.sh", "gone", app2]),
      workingDir = t2)
    checkpoint o2
    check c2 != 0
    check "not what they were traced as" in o2
    check not fileExists(t2 / "build" / "nimcache" / "gone" / "gone.deps")

  proc straceWrapper(name, filter: string): string =
    ## A ``REPRO_STRACE`` that runs the real strace with its arguments
    ## rewritten by the bash ``filter`` (which reads ``$a``, appends to
    ## ``args``).
    let real = findExe("strace")
    doAssert real.len > 0, "strace is required"
    result = base / name
    writeFile(result, "#!/usr/bin/env bash\nargs=()\nfor a in \"$@\"; do\n" &
      filter & "\ndone\nexec " & quoteShell(real) & " \"${args[@]}\"\n")
    setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

  proc writeWith(strace: string): (string, int) =
    let env = "REPRO_STRACE=" & quoteShell(strace) & " "
    execCmdEx(env & quoteShellCommand(@["bash",
      RepoRoot / "scripts" / "write_helper_deps.sh", "foo-helper", app,
      "--path:" & tree / "libs" / "foolib" / "src",
      "--path:" & parentDir(outside)]), workingDir = tree)

  test "22: a trace in a format the writer does not parse fails the list":
    build()
    check refusal() == ""
    let (o, c) = writeWith(straceWrapper("strace-no-xx",
      "  [ \"$a\" = -xx ] || args+=(\"$a\")"))
    checkpoint o
    check c != 0
    check "could not parse" in o
    check not fileExists(tree / "build" / "nimcache" / "foo-helper" / "foo-helper.deps")
    check "has no dependency list" in refusal()

  test "23: a trace without the entry module's own open fails the list":
    build()
    check refusal() == ""
    let (o, c) = writeWith(straceWrapper("strace-traces-nothing",
      "  case \"$a\" in trace=*) args+=(\"trace=getpid\") ;; *) args+=(\"$a\") ;; esac"))
    checkpoint o
    check c != 0
    check "positive control" in o
    check not fileExists(tree / "build" / "nimcache" / "foo-helper" / "foo-helper.deps")
    check "has no dependency list" in refusal()

  test "24: a .nimcache, a .git, a build directory or a result link in a listed directory is not a change":
    # §13 decision 111: what a plain `nim c` (config.nims's default
    # <checkout>/.nimcache), `just build` or `nix build` leaves in the
    # tree root, a directory the compiler's package search lists.
    build()
    check refusal() == ""
    let listed = helperListings(tree, "foo-helper")
    checkpoint $listed
    check listed.anyIt(it.dir == tree)
    check listed.anyIt(it.dir == fooDir)
    createDir(tree / ".nimcache" / "foo")
    writeFile(tree / ".nimcache" / "foo" / "x.c", "/* generated */\n")
    createDir(tree / ".git" / "objects")
    createSymlink(tree / "build", tree / "result")
    writeFile(fooDir / "notes.md", "not a source\n")
    let why = refusal()
    checkpoint why
    check why == ""

  test "25: a new .nim file in a directory the compiler searched is refused":
    build()
    check refusal() == ""
    for d in [tree, fooDir]:
      writeFile(d / "shadow.nim", "discard\n")
      let why = refusal()
      checkpoint why
      check ("listing of " & d & " that has changed") in why
      removeFile(d / "shadow.nim")
      check refusal() == ""

  for (n, label, p) in [(26, "a trailing", trailing), (27, "a leading", leading)]:
    test $n & ": a name with " & label & " space is checked under its own name, not its decoy's":
      build()
      check p in helperDependencies(tree, "foo-helper")
      check refusal() == ""
      touchAfterBinary(p)
      let why = refusal()
      checkpoint why
      check ("older than " & p) in why

  test "28: a successful open strace marks (deleted) fails the list":
    # The wrapper runs the real strace, then marks ONLY the open of
    # blob.txt the way strace prints an fd whose file is gone
    # (`= 3<path>(deleted)`), so the entry module's open -- the positive
    # control -- is untouched and only this line's handling is tested.
    let real = findExe("strace")
    doAssert real.len > 0, "strace is required"
    var blobHex = ""
    for c in "/blob.txt": blobHex.add("\\\\x" & toHex(ord(c), 2).toLowerAscii)
    let wrapper = base / "strace-marks-deleted"
    writeFile(wrapper, "#!/usr/bin/env bash\nout=''\nprev=''\n" &
      "for a in \"$@\"; do [ \"$prev\" = -o ] && out=\"$a\"; prev=\"$a\"; done\n" &
      quoteShell(real) & " \"$@\"\nrc=$?\n" &
      "for f in \"$out\".*; do sed -i -E 's/^(open[a-z0-9]*\\(.*\\) += [0-9]+<[^>]*" &
      blobHex & ">)$/\\1(deleted)/' \"$f\"; done\nexit $rc\n")
    setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
    build()
    check refusal() == ""
    let (o, c) = writeWith(wrapper)
    checkpoint o
    check c != 0
    check "opened and then deleted" in o
    check blob in o
    check not fileExists(tree / "build" / "nimcache" / "foo-helper" / "foo-helper.deps")
    check "has no dependency list" in refusal()

  test "29: an O_TMPFILE file a staticExec command makes does not fail the list":
    # Its own tree, so the other cases do not depend on python3. The
    # command makes an anonymous file (O_TMPFILE) and reopens it through
    # /proc/self/fd; strace prints both opens `<...>(deleted)`.
    let py = findExe("python3")
    doAssert py.len > 0, "python3 is required"
    let t3 = base / "tree29"
    let app3 = t3 / "apps" / "tmpf" / "tmpf.nim"
    createDir(parentDir(app3))
    writeFile(app3, "const t = staticExec(\"" & py & " -c 'import os, tempfile; " &
      "f = tempfile.TemporaryFile(); f.write(b\\\"x\\\"); f.flush(); " &
      "os.close(os.open(\\\"/proc/self/fd/%d\\\" % f.fileno(), os.O_RDONLY)); " &
      "print(\\\"made\\\")'\")\necho t\n")
    let bin3 = t3 / "build" / "bin" / "tmpf"
    let (o1, c1) = execCmdEx(quoteShellCommand(@["nim", "c", "--hints:off",
      "--warnings:off", "--nimcache:" & t3 / "build" / "nimcache" / "tmpf",
      "--out:" & bin3, app3]))
    doAssert c1 == 0, o1
    let (ob, cb) = execCmdEx(quoteShellCommand(@[bin3]))
    doAssert cb == 0 and "made" in ob, ob
    let (o2, c2) = execCmdEx(quoteShellCommand(@["bash",
      RepoRoot / "scripts" / "write_helper_deps.sh", "tmpf", app3]),
      workingDir = t3)
    checkpoint o2
    check c2 == 0
    check fileExists(t3 / "build" / "nimcache" / "tmpf" / "tmpf.deps")
    check freshRepoBinary(t3, "tmpf") == bin3

  test "30: a listed directory whose name ends in a space is checked under its own name":
    build()
    var dirs: seq[string]
    for (d, _) in helperListings(tree, "foo-helper"): dirs.add(d)
    checkpoint $dirs
    check spaceDir in dirs
    check refusal() == ""
    # The directory the command listed first, while the decoy is as it
    # was: an edit to it alone must be refused (a list that recorded the
    # decoy accepts it).
    writeFile(spaceDir / "two.nim", "discard\n")
    let why = refusal()
    checkpoint why
    check ("listing of " & spaceDir & " that has changed") in why
    removeFile(spaceDir / "two.nim")
    check refusal() == ""
    # The decoy is not what was listed: a new entry there changes nothing.
    writeFile(spaceDirDecoy / "two.nim", "discard\n")
    check refusal() == ""

  # ---- round 10's listing rules (reprobuild-pm issue 2026-11-13-helper-
  # list-listing-filter-accepts-a-new-package-directory-or-nim-cfg-that-
  # changes-the-build; no §13 decision yet): what else changes what the
  # compiler resolves. Its own tree: an app that imports ``pkgx/util``
  # through ``--path:vendor`` and reads a define.
  let rt = base / "tree-resolve"
  let rApp = rt / "apps" / "foo" / "foo.nim"
  let rBin = rt / "build" / "bin" / "rfoo"
  proc buildResolve() =
    createDir(rt / "vendor" / "pkgx")
    createDir(parentDir(rApp))
    writeFile(rt / "vendor" / "pkgx" / "util.nim", "proc which*(): string = \"vendor\"\n")
    writeFile(rApp, "import pkgx/util\nwhen defined(probeFlag): echo \"flag\"\necho which()\n")
    for p in [rApp, rt / "vendor" / "pkgx" / "util.nim"]:
      setLastModificationTime(p, getTime() - initDuration(seconds = 60))
    let (o1, c1) = execCmdEx(quoteShellCommand(@["nim", "c", "--hints:off",
      "--warnings:off", "--path:" & rt / "vendor",
      "--nimcache:" & rt / "build" / "nimcache" / "rfoo", "--out:" & rBin, rApp]))
    doAssert c1 == 0, o1
    let (o2, c2) = execCmdEx(quoteShellCommand(@["bash",
      RepoRoot / "scripts" / "write_helper_deps.sh", "rfoo", rApp,
      "--path:" & rt / "vendor"]), workingDir = rt)
    doAssert c2 == 0, o2
  proc rRefusal(): string =
    try:
      discard freshRepoBinary(rt, "rfoo")
      ""
    except StaleHelperBinary as e:
      e.msg

  for (n, label, rel, body) in [
      (31, "a package directory that shadows an import", "apps/foo/pkgx/util.nim",
       "proc which*(): string = \"local shadow\"\n"),
      (32, "a <project>.nim.cfg", "apps/foo/foo.nim.cfg", "-d:probeFlag\n"),
      (33, "a nim.cfg beside the project", "apps/foo/nim.cfg", "-d:probeFlag\n"),
      (34, "a nim.cfg in a parent directory", "apps/nim.cfg", "-d:probeFlag\n")]:
    test $n & ": " & label & " added after the build is refused":
      buildResolve()
      check rRefusal() == ""
      createDir(parentDir(rt / rel))
      writeFile(rt / rel, body)
      let why = rRefusal()
      checkpoint why
      check "that has changed since" in why
      removeFile(rt / rel)
      if n == 31: removeDir(rt / "apps" / "foo" / "pkgx")
      check rRefusal() == ""

  test "7: no binary, or no dependency list, is refused":
    build()
    check refusal() == ""
    removeFile(tree / "build" / "nimcache" / "foo-helper" / "foo-helper.deps")
    check "has no dependency list" in refusal()
    removeFile(binary)
    check "does not exist" in refusal()

removeDir(base)
