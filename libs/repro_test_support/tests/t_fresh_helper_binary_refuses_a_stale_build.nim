## A test's helper binary is used only when it was built from the tree
## under test (reprobuild-pm issues 2026-11-07-addon-allow-listed-source-
## field-turns-the-sinks-redaction-case-red-masked-by-a-stale-sink and
## 2026-11-08-fresh-binary-does-not-see-included-files-or-modules-outside-
## the-tree; §13 decision 65 of the ReproOS Add-On Mode spec).
##
## A small tree is compiled by the real Nim into ``build/bin`` with its own
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
##
## Falsifying builds: ``stale-helper-accepted`` (cases 2-5 and 8-10 red),
## ``fresh-skips-included`` (case 4), ``fresh-skips-outside-tree`` (case
## 5), ``fresh-skips-c-sources`` (case 8), ``fresh-skips-headers`` (case
## 9), ``fresh-skips-static-reads`` (case 10), ``fresh-ignores-list-binary``
## (case 11); and the script's ``WRITE_HELPER_DEPS_MUTATION=keep-old-list``
## in the environment (case 12).
##
## Mocks: none -- the real compiler, the real script, strace.

import std/[os, osproc, strutils, tempfiles, times, unittest]

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
createDir(parentDir(lib))
createDir(parentDir(app))
createDir(parentDir(outside))
createDir(parentDir(header))
writeFile(csrc, "#include \"helper.h\"\nint fooHelper(void) { return HELPER_VALUE; }\n")
writeFile(header, "#define HELPER_VALUE 7\n")
writeFile(blob, "read at compile time\n")
writeFile(execInput, "read by a staticExec command\n")
writeFile(lib, "proc greeting*(): string = \"hello\"\n")
writeFile(outside, "proc farAway*(): string = \"from outside\"\n")
writeFile(included, "proc part(): string = \"included\"\n")
proc writeApp(extra = "") =
  writeFile(app, "import foolib/bar\nimport ext\ninclude foo_part\n" &
    "{.compile(\"helper.c\", \"-I" & parentDir(header) & "\").}\n" &
    "proc fooHelper(): cint {.importc.}\n" &
    "const blob = staticRead(\"blob.txt\")\n" &
    "const fromExec = staticExec(\"cat " & execInput & "\")\n" &
    "echo greeting(), farAway(), part(), fooHelper(), blob, fromExec\n" & extra)
writeApp()
let binary = tree / "build" / "bin" / addFileExt("foo", ExeExt)

proc build() =
  ## Compile the tree and write its dependency list, after dating its
  ## sources a minute back (an earlier case may have dated one into the
  ## future).
  for src in [lib, app, included, outside, csrc, header, blob, execInput]:
    setLastModificationTime(src, getTime() - initDuration(seconds = 60))
  let flags = @["--path:" & tree / "libs" / "foolib" / "src",
                "--path:" & parentDir(outside)]
  let (o1, c1) = execCmdEx(quoteShellCommand(@["nim", "c", "--hints:off",
    "--warnings:off"] & flags & @["--nimcache:" & tree / "build" / "nimcache" / "foo",
    "--out:" & binary, app]))
  doAssert c1 == 0, o1
  let (o2, c2) = execCmdEx(quoteShellCommand(@["bash",
    RepoRoot / "scripts" / "write_helper_deps.sh", "foo", app] & flags),
    workingDir = tree)
  doAssert c2 == 0, o2

proc touchAfterBinary(path: string) =
  ## Mark ``path`` edited ten seconds after the binary was built, without
  ## depending on the file system's timestamp resolution.
  setLastModificationTime(path,
    getLastModificationTime(binary) + initDuration(seconds = 10))

proc refusal(): string =
  try:
    discard freshRepoBinary(tree, "foo")
    ""
  except StaleHelperBinary as e:
    e.msg

suite "a helper binary is used only when built from the tree under test":
  test "1: built from the tree as it is, it is returned":
    build()
    check freshRepoBinary(tree, "foo") == binary
    let deps = helperDependencies(tree, "foo")
    checkpoint deps.join("\n")
    for want in [lib, app, included, outside, csrc, header, blob, execInput]:
      check want in deps
    let list = readFile(tree / "build" / "nimcache" / "foo" / "foo.deps")
    check list.startsWith("binary-sha256 ")
    check ("csource " & csrc) in list
    check ("header " & header) in list
    check ("read " & blob) in list

  test "2: a library module edited after the build is refused":
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
      "--nimcache:" & tree / "build" / "nimcache" / "foo",
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
      RepoRoot / "scripts" / "write_helper_deps.sh", "foo",
      tree / "apps" / "foo" / "no_such_entry.nim"]), workingDir = tree)
    checkpoint o
    check c != 0
    check "has no dependency list" in refusal()

  test "7: no binary, or no dependency list, is refused":
    removeFile(tree / "build" / "nimcache" / "foo" / "foo.deps")
    check "has no dependency list" in refusal()
    removeFile(binary)
    check "does not exist" in refusal()

removeDir(base)
