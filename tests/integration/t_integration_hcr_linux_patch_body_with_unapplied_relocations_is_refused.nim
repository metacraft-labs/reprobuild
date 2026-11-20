## Gate `integration_hcr_linux_patch_body_with_unapplied_relocations_is_refused`.
##
## Property protected: on the `linux-x86_64-elf-direct-hcr-v1` profile, the
## patch body that `repro watch --hcr` and `repro hcr coordinate` put on the
## wire never depends on a reference that nothing relocates. A body with any
## relocation inside the function, or a body that shares its section with
## another defined symbol, is REFUSED by name before a request is built. A
## function alone in its section and with no relocation is extracted unchanged.
##
## Why. Both commands take the body from `objectFunctionBytes`, which returns
## the function's raw bytes from a relocatable object. In a RELA object the
## relocated field holds zero or a placeholder and the value lives in
## `.rela.text`. Neither the coordinator nor the Linux agent applies
## `.rela.text` to a patch body. Before this gate such a body was published
## and ran with its placeholders: a `call` (`R_X86_64_PLT32`) fell through to
## the next instruction, and a RIP-relative load of a global (`R_X86_64_PC32`)
## read the patch page. An initial-exec TLS access (`R_X86_64_GOTTPOFF`) loaded
## its TP offset from the code bytes. Nothing reported any of it. A `call` to a
## `static` helper in the same `.text` is worse: the assembler resolves it and
## leaves no relocation at all, so only the shared-section rule catches it.
## Spec: `reprobuild-pm/spec/HCR/Linux-ELF-Provider.md` §2 and §9,
## `Relocation-Processing.md` §4.1 (a relocation is applied or the patch is
## refused by name). Issue (closed by the commit that added this gate):
## `reprobuild-pm/issues/2026-11-17-linux-hcr-coordinator-sends-patch-bodies-without-applying-or-checking-relocations.md`.
##
## `allowed_mocks: none`. Every object is compiled here by the real gcc with
## the real patchable-TU profile (`patchableCompileFlags`, which on Linux
## includes `-ftls-model=global-dynamic`). Every body is extracted by the
## production `objectFunctionBytes` that both send paths call. The gate stops
## short of a live target: what it protects is that the body is refused before
## a request exists, so no agent is needed to observe it. It does not drive
## `repro watch --hcr` itself, so it would not notice a caller that stopped
## using `objectFunctionBytes`.
##
## Anti-vacuity. Each provoking object is first checked with `readelf -rW`,
## independently of the reader under test. It must carry the relocation the
## arm is named for, or, for the static-helper arm, carry NO relocation in the
## function, which is what makes that arm the hard case. The leaf controls are
## checked to carry none. With the refusal disabled (red, measured when this
## gate was written), every provoking arm extracts a body and fails on
## "refusal.len > 0".
##
## No silent skips: a missing compiler fails the gate loudly.

import std/[os, osproc, strutils, unittest]

when defined(linux) and defined(amd64):
  import repro_cli_support
  import repro_hcr_linkgraph
  import repro_project_dsl

  let PatchableFlags = patchableCompileFlags(ReproHcr())
  const Profile = "linux-x86_64-elf-direct-hcr-v1"

  proc runSuccess(args: openArray[string]; cwd: string): string =
    let command = args.quoteShellCommand()
    let res = execCmdEx(command, workingDir = cwd)
    # Raises rather than `require`s: a `check`/`require` inside a helper proc
    # does not fail the enclosing unittest test, an exception does.
    if res.exitCode != 0:
      raise newException(AssertionDefect, "command failed (exit " &
        $res.exitCode & "): " & command & "\n" & res.output)
    res.output

  proc requireTool(name: string) =
    if findExe(name).len == 0:
      raise newException(AssertionDefect,
        "required tool is not on PATH: " & name)

  proc freshWorkDir(arm: string): string =
    requireTool("gcc")
    requireTool("readelf")
    # The watch path calls `objectFunctionBytes` with this host default, so
    # the profile tested here is the one production sends under on Linux.
    doAssert CodetracerHcrSupportProfile == Profile
    doAssert hcrProfileIsElf(Profile)
    result = getCurrentDir() / "build" / "hcr-linux-patch-body-relocations" /
      arm
    removeDir(result)
    createDir(result)

  proc compileFixture(workDir, name, source: string;
                      extra: openArray[string] = []): string =
    let sourcePath = workDir / (name & ".c")
    result = workDir / (name & ".o")
    writeFile(sourcePath, source)
    # -fno-pic matches a project that compiles its patchable TU without PIC,
    # which is when GCC uses initial-exec for an extern __thread even under
    # -ftls-model=global-dynamic (Linux-ELF-Provider.md §9).
    discard runSuccess(@["gcc", "-O1", "-fno-pic"] & PatchableFlags & @extra &
      @["-c", sourcePath, "-o", result], workDir)

  proc relocationsIn(objectPath, workDir, relaSection: string): string =
    ## The entries of exactly `relaSection` as readelf prints them,
    ## independent of the reader under test.
    let listing = runSuccess(@["readelf", "-rW", objectPath], workDir)
    var inSection = false
    for line in listing.splitLines():
      if line.startsWith("Relocation section"):
        inSection = ("'" & relaSection & "'") in line
      elif inSection:
        result.add line & "\n"

  proc refusalOf(obj, symbol: string): string =
    try:
      discard objectFunctionBytes(obj, symbol, Profile)
    except HcrPatchBodyRelocationRefused as err:
      result = err.msg
    checkpoint("refusal: " & result)

  template checkRefusedForRelocation(name, source, kind, target: string) =
    ## A template, not a proc: `check` and `require` only fail the test they
    ## are expanded in.
    let workDir = freshWorkDir(name)
    let obj = compileFixture(workDir, name, source)
    let relocs = relocationsIn(obj, workDir, ".rela.text")
    checkpoint("readelf .rela.text of " & obj & ":\n" & relocs)
    # Anti-vacuity: the compiler really emitted the relocation this arm is
    # named for.
    require (kind & " ") in relocs and target in relocs
    let refusal {.inject.} = refusalOf(obj, "patch_" & name)
    check refusal.len > 0 # expected a refusal; the body was extracted
    check (kind & "->" & target & "@+") in refusal
    check ("patch_" & name) in refusal
    check Profile in refusal

  suite "integration_hcr_linux_patch_body_with_unapplied_relocations_is_refused":
    test "a leaf body with no relocations is extracted unchanged":
      let workDir = freshWorkDir("leaf")
      let obj = compileFixture(workDir, "leaf",
        "int patch_leaf(int i) { return i * 3 + 77; }\n")
      check relocationsIn(obj, workDir, ".rela.text").strip().len == 0
      let graph = parseElfX86_64Object(obj)
      let expected = graph.functionBytes(graph.findSymbol("patch_leaf"))
      require expected.len > 0
      check objectFunctionBytes(obj, "patch_leaf", Profile) == expected

    test "a body with R_X86_64_PLT32 against helper is refused by name":
      checkRefusedForRelocation("calls_helper",
        "int helper(int);\nint patch_calls_helper(int i) { return helper(i) + 1; }\n",
        "R_X86_64_PLT32", "helper")
      # The template asserts the detail; this keeps one assertion visible in
      # the test body for the vacuous-case scanner.
      check refusal.startsWith("hcr patch refused: patch body patch_calls_helper")

    test "a body with R_X86_64_PC32 against counter is refused by name":
      checkRefusedForRelocation("reads_global",
        "extern int counter;\nint patch_reads_global(void) { return counter + 1; }\n",
        "R_X86_64_PC32", "counter")
      # The template asserts the detail; this keeps one assertion visible in
      # the test body for the vacuous-case scanner.
      check refusal.startsWith("hcr patch refused: patch body patch_reads_global")

    test "a body with R_X86_64_GOTTPOFF against tls_counter is refused by name":
      checkRefusedForRelocation("reads_tls",
        "extern __thread int tls_counter;\nint patch_reads_tls(void) { return tls_counter + 1; }\n",
        "R_X86_64_GOTTPOFF", "tls_counter")
      # The template asserts the detail; this keeps one assertion visible in
      # the test body for the vacuous-case scanner.
      check refusal.startsWith("hcr patch refused: patch body patch_reads_tls")

    test "a call to a static helper in the same section, which leaves no relocation, is refused":
      let workDir = freshWorkDir("static_helper")
      let obj = compileFixture(workDir, "static_helper",
        "static __attribute__((noinline)) int helper(int i) { return i * 7; }\n" &
        "int patch_static_helper(int i) { return helper(i) + 1; }\n")
      let relocs = relocationsIn(obj, workDir, ".rela.text")
      checkpoint("readelf .rela.text of " & obj & ":\n" & relocs)
      # Anti-vacuity: the hard case is that the call left NO relocation, so a
      # relocation check alone would pass this body.
      let graph = parseElfX86_64Object(obj)
      require graph.relocationsForSymbol(
        graph.findSymbol("patch_static_helper")).len == 0
      require "helper" notin relocs
      let refusal = refusalOf(obj, "patch_static_helper")
      check refusal.len > 0 # expected a refusal; the body was extracted
      check "also holds helper" in refusal
      check "-ffunction-sections" in refusal

    test "under -ffunction-sections the static call becomes a relocation, and a leaf beside it still extracts":
      let workDir = freshWorkDir("function_sections")
      let obj = compileFixture(workDir, "function_sections",
        "static __attribute__((noinline)) int helper(int i) { return i * 7; }\n" &
        "int patch_fs_calls(int i) { return helper(i) + 1; }\n" &
        "int patch_fs_leaf(int i) { return i * 3 + 77; }\n",
        ["-ffunction-sections"])
      let callRelocs = relocationsIn(obj, workDir, ".rela.text.patch_fs_calls")
      checkpoint("readelf .rela.text.patch_fs_calls:\n" & callRelocs)
      require "helper" in callRelocs or ".text.helper" in callRelocs
      let callRefusal = refusalOf(obj, "patch_fs_calls")
      check callRefusal.len > 0
      check "relocation(s)" in callRefusal
      check "also holds" notin callRefusal
      check relocationsIn(obj, workDir, ".rela.text.patch_fs_leaf").strip().len == 0
      let graph = parseElfX86_64Object(obj)
      let expected = graph.functionBytes(graph.findSymbol("patch_fs_leaf"))
      require expected.len > 0
      check objectFunctionBytes(obj, "patch_fs_leaf", Profile) == expected
else:
  import std/unittest
  import repro_test_support/reasoned_skip
  suite "integration_hcr_linux_patch_body_with_unapplied_relocations_is_refused":
    test "Linux x86_64 only":
      skip("the Linux ELF HCR patch-body profile is only built on Linux x86_64")
