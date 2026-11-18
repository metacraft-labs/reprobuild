## A changed library source, flag, define, toolchain or target is never a
## hit; a moved checkout or an unrelated file is not a miss.
##
## The portable (path-independent) key is what lets a second checkout of a
## library take the first checkout's result. A wrong hit -- the second
## checkout served an object compiled from other source bytes, other flags or
## another compiler -- is worse than a miss, so this is a property test over
## generated edits of a library project:
##
## * OUTPUT-CHANGING classes: the library source's bytes, each compile flag
##   in a pool, a feature define the source tests with `#ifdef`, the
##   toolchain's identity (the same project built with the dev shell's GCC
##   from `PATH` instead of the store-root toolchain: another compiler on the
##   same host, whose objects differ, starting with their `.comment`), and the
##   code-generation target (`-m32`, `-march=...`). For every generated edit
##   the edited checkout's compile edge must get a DIFFERENT portable key and
##   must not resolve from any record (`portable-resolved` absent, the edge
##   executes) -- whether or not that edit happened to change the bytes, since
##   the key cannot know in advance that it would not.
## * OUTPUT-PRESERVING classes: the checkout's path (a copy under another
##   parent directory) and an unrelated file added to the project. The
##   edited checkout's compile edge must resolve the base record by its
##   portable key (`portable-resolved local strong=<the base build's key>`)
##   and its archive edge must compute the base build's archive key. Whether
##   the record's bytes are then put in place -- which the archive's own
##   resolution waits on -- is the restore's business (Caching-Architecture.md
##   D6, D7), not this test's.
## * The archive edge's key must change with the object it archives in every
##   case whose object changed.
##
## What the cases also pin, from the same design (Caching-Architecture.md
## §"Design for XPC-AREQ1"):
##
## * D1 -- no `REPRO_PORTABLE_CACHE` is set: the portable identity of the
##   compile and archive edges is the DEFAULT, for edges whose input-check
##   policy is content-checked. A `timestamp` edge in the same project gets no
##   portable fingerprint at all.
## * D2 -- the compile and archive edges state no policy; they are `hybrid`
##   because the `gcc` and `ar` tools declare it.
## * D4 -- `-g` without a prefix map embeds the checkout path in the object's
##   (compressed) debug info, so neither checkout gets a portable record and
##   the reason names the embedding; `-g -ffile-prefix-map=<root>=.` is
##   path-free and shared.
## * D5 -- the project declares `uses: "gcc >=11"` and has no sibling `gcc`
##   recipe, and the moved checkout sits under another parent: a
##   `DEP_GCC_ROOT` naming `<parent>/gcc/...` would make its key differ.
##
## VACUITY GUARD: the generated cases include at least one edit in every
## class, and every output-changing class has at least one edit whose object
## really differs from the base build's -- otherwise "never a hit" would hold
## of edits that changed nothing.
##
## FALSIFYING MUTATION (run when this test was written): dropping the
## define set from the portable key (filtering `-D` arguments out of the
## argv `portableWeakFingerprint` frames) makes the
## feature-define case resolve the base record, a wrong hit, and this test
## fails on it.
##
## The toolchain is the one the engine realizes into the store root
## (`--tool-provisioning=tarball`), so every toolchain read is inside the
## `store` root and the edges can have a portable key at all. Network: a store
## that does not hold it yet fetches the pinned archive (102 MB) once; set
## `REPRO_CONFORMANCE_STORE` to a directory that survives between runs to pay
## that once per pin. The toolchain-identity case needs the dev shell's `gcc`
## on `PATH`, as every `--tool-provisioning=path` test does.
##
## No mocks: the built `repro`, the engine-provisioned GCC and `ar`, real Git
## checkouts at different absolute paths, the real monitor and action cache,
## and the build reports the engine writes.

import std/[algorithm, os, osproc, random, sequtils, strutils, tables, unittest]

import repro_test_support
import library_cache_sharing_fixture

const
  CompileEdge = "lib-compile"
  ArchiveEdge = "lib-archive"
  StampEdge = "lib-timestamp-stamp"
  LibObject = ".repro/build/lib/obj/lib.o"
  LibArchive = ".repro/build/lib/liblib.a"
  BaseFlags = @["-O2"]

type
  EditClass = enum
    ecSource = "source bytes"
    ecFlag = "compile flag"
    ecDefine = "feature define"
    ecToolchain = "toolchain identity"
    ecTarget = "target"
    ecCheckoutPath = "checkout path"
    ecUnrelatedFile = "unrelated file"

  Edit = object
    class: EditClass
    label: string
    flags: seq[string]        ## the library compile's flags
    sourceConstant: int       ## the constant the source adds (base 0)
    unrelatedFile: string     ## a file to add beside the library ("" none)
    provisioning: string      ## `--tool-provisioning`; "" is `tarball`

const OutputChanging = {ecSource, ecFlag, ecDefine, ecToolchain, ecTarget}

proc librarySource(constant: int): string =
  ## A source with enough code for flags to matter, a feature switch, and a
  ## constant an edit can change.
  "#include \"lib.h\"\n\n" &
  "int lib_sum(const int *v, int n) {\n" &
  "    int s = " & $constant & ";\n" &
  "    for (int i = 0; i < n; ++i)\n" &
  "        s += v[i] * (i + 1);\n" &
  "#ifdef LIB_FEATURE\n" &
  "    s ^= 0x5a5a;\n" &
  "#endif\n" &
  "    return s;\n}\n"

proc flagsCode(flags: openArray[string]): string =
  result = "@["
  for i, flag in flags:
    if i > 0:
      result.add(", ")
    if flag == "<prefix-map>":
      result.add("\"-ffile-prefix-map=\" & root & \"=.\"")
    else:
      result.add(escape(flag))
  result.add("]")

proc writeProject(dest: string; edit: Edit) =
  ## A standalone project (its own Git repository) whose build file declares
  ## the library's compile and archive edges with NO input-check policy, so
  ## they take the one `gcc` and `ar` declare (D2), and one edge that STATES
  ## `timestamp` (the D1 control).
  createDir(dest / "lib" / "src")
  createDir(dest / "lib" / "include")
  writeFile(dest / "lib" / "src" / "lib.c", librarySource(edit.sourceConstant))
  writeFile(dest / "lib" / "include" / "lib.h",
    "#ifndef LIB_H\n#define LIB_H\nint lib_sum(const int *v, int n);\n#endif\n")
  if edit.unrelatedFile.len > 0:
    writeFile(dest / edit.unrelatedFile, "notes that no edge reads\n")
  writeFile(dest / "repro.nim", """import std/os
import repro_project_dsl

package changedlib:
  defaultToolProvisioning "tarball"
  uses:
    "gcc >=11"

  build:
    let root = activeProviderProjectRoot()
    let obj = root / "LIBOBJ"
    let dep = obj & ".d"
    let archive = root / "LIBARCHIVE"
    createDir(obj.parentDir)
    let compile = buildAction(id = "COMPILEEDGE",
      call = inlineExecCall(@["gcc", "-c"] & FLAGS & @["-MD", "-MF", dep,
        "-I", root / "lib/include", "-o", obj, root / "lib/src/lib.c"], root),
      inputs = @[root / "lib/src/lib.c"], outputs = @[obj], pool = "compile",
      depfile = dep, dependencyPolicy = makeDepfilePolicy(dep),
      toolIdentityRefs = @["gcc"])
    # States `timestamp`: under the default scope (D1) it gets no portable
    # identity. Ordered before the archive only so the default build runs it.
    let stamp = fs.writeText(root / ".repro/build/lib/stamp.txt", "built",
      actionId = "STAMPEDGE", actionCachePolicy = acfpTimestamp)
    let archiveAction = buildAction(id = "ARCHIVEEDGE",
      call = inlineExecCall(@["ar", "rcs", archive, obj], root),
      deps = @[compile.id, stamp.id], inputs = @[obj], outputs = @[archive],
      pool = "compile", dependencyPolicy = automaticMonitorPolicy(),
      toolIdentityRefs = @["ar"])
    defaultBuildAction(archiveAction)
""".multiReplace(("LIBOBJ", LibObject), ("LIBARCHIVE", LibArchive),
    ("COMPILEEDGE", CompileEdge), ("ARCHIVEEDGE", ArchiveEdge),
    ("STAMPEDGE", StampEdge), ("FLAGS", flagsCode(edit.flags))))
  commitCheckout(dest)

proc events(run: BuildRun; id, event: string): seq[string] =
  if id in run.edges:
    for entry in run.edges[id].trace:
      if entry.event == event:
        result.add(entry.detail)

proc portableKey(run: BuildRun; id: string): string =
  ## The strong portable key the build recorded for `id`, or "".
  for detail in run.events(id, "portable-fingerprint"):
    let at = detail.find("strong=")
    if at >= 0:
      return detail[at + "strong=".len .. ^1].split(' ')[0]
  ""

proc resolvedKey(run: BuildRun; id: string): string =
  ## The strong key of the record `id` resolved from, or "".
  for detail in run.events(id, "portable-resolved"):
    let at = detail.find("strong=")
    if at >= 0:
      return detail[at + "strong=".len .. ^1].split(' ')[0]
  ""

proc generateEdits(seed: int): seq[Edit] =
  ## The generated cases: a seeded draw from each class's pool, at least one
  ## per class, deduplicated so no two cases (and no case and the base) build
  ## the same thing -- a repeat would legitimately resolve its twin's record.
  var rng = initRand(seed)
  let flagPool = @[@["-O0"], @["-O1"], @["-O3"], @["-Os"],
    @["-O2", "-fno-tree-vectorize"], @["-O2", "-funroll-loops"],
    @["-O2", "-fPIC"], @["-O2", "-fno-inline"],
    @["-O2", "-fstack-protector-all"],
    @["-O2", "-g", "<prefix-map>"]]
  let targetPool = @[@["-O2", "-m32"], @["-O2", "-march=x86-64-v2"],
    @["-O2", "-march=x86-64-v3"]]
  let definePool = @[@["-O2", "-DLIB_FEATURE"],
    @["-O2", "-DLIB_FEATURE=1"]]
  var seen: seq[string] = @[$BaseFlags & "|0|"]
  proc add(edits: var seq[Edit]; edit: Edit) =
    let key = $edit.flags & "|" & $edit.sourceConstant & "|" &
      edit.unrelatedFile & "|" & $edit.class
    if key notin seen:
      seen.add(key)
      system.add(edits, edit)
  for _ in 0 ..< 2:
    let k = rng.rand(1 .. 1000)
    result.add(Edit(class: ecSource, label: "source constant " & $k,
      flags: BaseFlags, sourceConstant: k))
  var shuffledFlags = flagPool
  rng.shuffle(shuffledFlags)
  for flags in shuffledFlags[0 ..< 4]:
    result.add(Edit(class: ecFlag, label: flags.join(" "), flags: flags))
  for flags in definePool[0 ..< 1]:
    result.add(Edit(class: ecDefine, label: flags.join(" "), flags: flags))
  var shuffledTargets = targetPool
  rng.shuffle(shuffledTargets)
  for flags in shuffledTargets[0 ..< 2]:
    result.add(Edit(class: ecTarget, label: flags.join(" "), flags: flags))
  result.add(Edit(class: ecToolchain,
    label: "the dev shell's gcc from PATH instead of the store-root toolchain",
    flags: BaseFlags, provisioning: "path"))
  result.add(Edit(class: ecCheckoutPath, label: "another parent directory",
    flags: BaseFlags))
  let name = "NOTES-" & $rng.rand(1 .. 1_000_000) & ".txt"
  result.add(Edit(class: ecUnrelatedFile, label: name, flags: BaseFlags,
    unrelatedFile: name))

suite "a changed library source or flag is never a hit":
  test "every output-changing edit misses and every output-preserving one resolves":
    var host = newSharedHost("repro-never-a-hit-")
    defer: cleanup(host)
    let base = host.scratch / "base" / "proj"
    writeProject(base, Edit(flags: BaseFlags))
    let first = host.build(base, portable = false, provisioning = "tarball")
    checkpoint("base build (" & base & "), exit " & $first.code & ":\n" &
      first.output & "\nengine reasons:\n" & allEngineReasons(first))
    require first.code == 0
    require first.hasEdge(CompileEdge)
    require first.hasEdge(ArchiveEdge)
    check first.launched(CompileEdge)
    check nonEmptyFile(base / LibObject)
    # D1 + D2: with no REPRO_PORTABLE_CACHE, the hybrid compile and archive
    # edges get a portable key by default...
    let baseCompileKey = first.portableKey(CompileEdge)
    let baseArchiveKey = first.portableKey(ArchiveEdge)
    check baseCompileKey.len == 64
    check baseArchiveKey.len == 64
    # ...and the edge that states `timestamp` gets none.
    require first.hasEdge(StampEdge)
    check first.events(StampEdge, "portable-fingerprint").len == 0
    check first.events(StampEdge, "portable-fingerprint-unavailable").len == 0
    let baseObject = readFile(base / LibObject)

    let edits = generateEdits(seed = 20261115)
    var classesSeen: set[EditClass] = {}
    var classesWithChangedOutput: set[EditClass] = {}
    for i, edit in edits:
      classesSeen.incl(edit.class)
      let checkout = host.scratch / ("case-" & $i) / "parent-" & $i / "proj"
      writeProject(checkout, edit)
      let run = host.build(checkout, portable = false,
        provisioning = (if edit.provisioning.len > 0: edit.provisioning
                        else: "tarball"))
      checkpoint("case " & $i & " [" & $edit.class & ": " & edit.label &
        "] (" & checkout & "), exit " & $run.code & ":\n" & run.output &
        "\nengine reasons:\n" & allEngineReasons(run))
      require run.code == 0
      require run.hasEdge(CompileEdge)
      let objectChanged = readFile(checkout / LibObject) != baseObject
      if edit.class in OutputChanging:
        if objectChanged:
          classesWithChangedOutput.incl(edit.class)
          # The archive edge is a library edge too: a different object in
          # it must give it a different key. (Measured before this was
          # fixed: the archive's record bound the object it archived by its
          # kind alone, because `ar` stats it before reading it, so every
          # case here gave the archive the base's key.)
          check run.portableKey(ArchiveEdge) != baseArchiveKey
        # The property: an edit that CAN change the object is never served
        # from the base record (nor any other): the key differs and the edge
        # executes. Asserted whether or not this particular edit changed the
        # bytes, because the key cannot know in advance that it would not.
        check run.resolvedKey(CompileEdge).len == 0
        check run.launched(CompileEdge)
        check run.portableKey(CompileEdge) != baseCompileKey
        if "<prefix-map>" in edit.flags:
          # D4's other half: with the prefix map, a debug build is path-free
          # and gets a portable record.
          check run.portableKey(CompileEdge).len == 64
      else:
        check not objectChanged
        check run.resolvedKey(CompileEdge) == baseCompileKey
        # The archive resolves only once its dependency's object is put in
        # place, which is the restore's (Caching-Architecture.md D6, D7);
        # until then the archive's KEY is what this test can hold equal.
        check run.portableKey(ArchiveEdge) == baseArchiveKey

    # Vacuity guard: every class was generated, and every output-changing
    # class produced at least one object that really differs.
    check classesSeen == {low(EditClass) .. high(EditClass)}
    check classesWithChangedOutput == OutputChanging

  test "a debug build that embeds the checkout path is not shared":
    ## D4: `-g` without a prefix map puts each checkout's path in its
    ## object's compressed debug sections, so neither checkout writes a
    ## portable record, the reason names the embedding, and the second
    ## checkout does not resolve the first's.
    var host = newSharedHost("repro-never-a-hit-debug-")
    defer: cleanup(host)
    let debugEdit = Edit(class: ecFlag, label: "-O2 -g",
      flags: @["-O2", "-g"])
    let one = host.scratch / "one" / "proj"
    let two = host.scratch / "two" / "deeper" / "proj"
    writeProject(one, debugEdit)
    writeProject(two, debugEdit)
    let a = host.build(one, portable = false, provisioning = "tarball")
    checkpoint("first debug build, exit " & $a.code & ":\n" & a.output &
      "\nengine reasons:\n" & allEngineReasons(a))
    require a.code == 0
    require a.hasEdge(CompileEdge)
    check a.portableKey(CompileEdge).len == 0
    let reasons = a.events(CompileEdge, "portable-fingerprint-unavailable")
    check reasons.len == 1
    for reason in reasons:
      check "embeds the physical path of the" in reason
    # The archive holds the object, so it embeds the path too.
    check a.portableKey(ArchiveEdge).len == 0
    let b = host.build(two, portable = false, provisioning = "tarball")
    checkpoint("second debug build, exit " & $b.code & ":\n" & b.output &
      "\nengine reasons:\n" & allEngineReasons(b))
    require b.code == 0
    require b.hasEdge(CompileEdge)
    check b.resolvedKey(CompileEdge).len == 0
    check b.resolvedKey(ArchiveEdge).len == 0
    check b.launched(CompileEdge)
