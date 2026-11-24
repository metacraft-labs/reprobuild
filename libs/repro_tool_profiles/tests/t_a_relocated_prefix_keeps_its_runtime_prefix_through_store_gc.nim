## A prefix whose programs were relocated onto another prefix's loader and C
## library (an archive that names an `elfRuntimePackage`, as the store-root
## `rustc` and `cargo` name `gcc`) keeps that runtime prefix through store GC
## and the size-budgeted collector for as long as the relocated prefix is
## indexed, and the runtime prefix is collected once the relocated one is.
##
## Without this, a root that holds the relocated prefix does not hold the
## runtime prefix: GC reaps the runtime prefix, the relocated prefix stays
## indexed and looks valid, and its programs no longer start (their
## `PT_INTERP` names a loader that is gone).
##
## The fixture is built the way the tarball realizer builds such a pair,
## through the same steps, on a staging tree made on the spot so the test runs
## offline:
##   * the runtime prefix holds the dev shell's glibc loader and C library;
##   * the relocated prefix holds a program compiled by the dev shell's `cc`,
##     rewritten by `relocateElfTree` (the realizer's relocation step, with
##     the real `patchelf`) onto the runtime prefix, at its final store path;
##   * both are indexed by `registerInUnifiedStore`, the registration every
##     tarball realization performs, and the reference is recorded by
##     `recordRuntimePrefixReference`, which `resolveTarballTool` calls after
##     the provisioning edges ran.
## Realizing the catalog's `rustc` onto the catalog's `gcc` through the
## provisioning edges would download both toolchains (about 1.6 GB on disk) and
## the stdlib `patchelf`; that end-to-end path is covered by
## `t_store_root_rustc_links_through_the_store_root_c_driver`. What this test
## checks lives entirely in the store index and the collectors, which run here
## unmodified.
##
## Cases:
##   1. a root holds the relocated prefix: `gc` keeps both and the program
##      still runs; a targeted `gcPrefix` of the runtime prefix is refused and
##      names the relocated prefix; once the root is gone, one `gc` run
##      collects both;
##   2. nothing holds either: a budget run that must free space evicts the
##      relocated prefix before the runtime prefix, although the runtime
##      prefix was used less recently, and the program still runs when the
##      run stops after the first eviction;
##   3. a runtime prefix that is gone is refused when the reference is
##      recorded, and a prefix with no index row is reported as unrecorded.
##
## Falsifying mutation: make `recordRuntimePrefixReference` return
## `rroRecorded` without calling `recordPrefixReference`. Cases 1 and 2 fail:
## `gc` reaps the runtime prefix under a held relocated prefix, and the budget
## run evicts the older runtime prefix first.
##
## MOCK POLICY: none. A real `Store` on a real directory, the real collectors,
## the real `patchelf` and a real loader. Linux only: the relocation exists
## for Linux archives.

import std/[os, osproc, strutils, unittest]

import repro_local_store
import repro_local_store/budget_gc
import repro_project_dsl
import repro_project_dsl/install_mirror_relocation
import repro_tool_profiles
import repro_tool_profiles/elf_relocation
import repro_test_support/in_tree_scratch
import repro_test_support/reasoned_skip

const
  Loader = "lib/ld-linux-x86-64.so.2"
  Lock = "runtime-reference-test"

proc run(command: string): tuple[output: string; exitCode: int] =
  execCmdEx(command)

proc runTool(argv: seq[string]): tuple[output: string; exitCode: int] =
  ## The process runner the realizer injects (``ElfToolRunner``).
  execCmdEx(quoteShellCommand(argv))

type
  Pair = object
    storeRoot: string
    runtime: string           ## absolute path of the runtime prefix
    runtimeId: PrefixIdBytes
    relocated: string         ## absolute path of the relocated prefix
    relocatedId: PrefixIdBytes
    program: string

proc placeAndRegister(storeRoot, name: string;
                      fill: proc(prefix: string)): tuple[path: string;
                                                         id: PrefixIdBytes] =
  ## Lay a prefix down at its store path and index it, as the tarball
  ## realizer does after moving its staging tree into place.
  let place = unifiedPrefixPath(storeRoot, name, "1.0", "tarball", Lock,
    "bin/tool", "file:///" & name, name & "-digest")
  createDir(place.absolutePath)
  fill(place.absolutePath)
  let reg = registerInUnifiedStore(storeRoot, name, "1.0", "tarball", Lock,
    "bin/tool", "file:///" & name, name & "-digest", "directory", [],
    place.absolutePath, ["bin/tool"])
  doAssert reg.inserted
  doAssert reg.prefixId == place.prefixId
  (place.absolutePath, reg.prefixId)

proc makePair(scratch: string; padding = 0): Pair =
  ## A runtime prefix with a loader and libc, and a prefix whose program is
  ## relocated onto them. `padding` bytes are added to the relocated prefix,
  ## so a budget run can be told to free less than it holds.
  let patchelf = findExe("patchelf")
  doAssert patchelf.len > 0, "patchelf is not on PATH (run in the dev shell)"
  result.storeRoot = scratch / "store"
  let source = scratch / "hello.c"
  writeFile(source,
    "#include <stdio.h>\nint main(void) { puts(\"relocated\"); return 0; }\n")
  let compiled = scratch / "hello"
  let cc = run("cc -o " & quoteShell(compiled) & " " & quoteShell(source))
  doAssert cc.exitCode == 0, cc.output
  let rt = placeAndRegister(result.storeRoot, "runtime",
    proc(prefix: string) =
      createDir(prefix / "bin")
      createDir(prefix / "lib")
      writeFile(prefix / "bin" / "tool", "#!/bin/sh\n")
      setFilePermissions(prefix / "bin" / "tool",
        {fpUserRead, fpUserWrite, fpUserExec})
      for name in ["ld-linux-x86-64.so.2", "libc.so.6"]:
        let found = run("cc -print-file-name=" & name).output.strip()
        doAssert fileExists(found), "the dev shell's cc does not know " & name
        copyFile(expandFilename(found), prefix / "lib" / name)
        setFilePermissions(prefix / "lib" / name,
          {fpUserRead, fpUserWrite, fpUserExec}))
  result.runtime = rt.path
  result.runtimeId = rt.id
  let runtimePrefix = rt.path
  let rel = placeAndRegister(result.storeRoot, "relocated",
    proc(prefix: string) =
      createDir(prefix / "bin")
      copyFile(compiled, prefix / "bin" / "tool")
      setFilePermissions(prefix / "bin" / "tool",
        {fpUserRead, fpUserWrite, fpUserExec})
      if padding > 0:
        writeFile(prefix / "padding", newString(padding))
      let detail = TarballArchiveDetail(elfInterpreter: Loader,
        elfRunpath: @["lib"], elfPatchDirs: @["bin"],
        elfRuntimePackage: "runtime")
      doAssert relocateElfTree(detail, prefix, prefix, patchelf, runTool,
        runtimePrefix = runtimePrefix) == 1)
  result.relocated = rel.path
  result.relocatedId = rel.id
  result.program = rel.path / "bin" / "tool"

proc runs(pair: Pair): bool =
  let ran = run(quoteShell(pair.program))
  checkpoint "program: " & ran.output
  ran.exitCode == 0 and ran.output.strip() == "relocated"

suite "a relocated prefix keeps its runtime prefix through store GC":
  test "a held relocated prefix keeps its runtime prefix; both go together":
    when not defined(linux):
      skip("the ELF relocation applies to Linux archives only")
    else:
      let scratch = inTreeScratchDir("repro-runtime-reference-")
      defer: removeDir(scratch)
      let pair = makePair(scratch)
      # The program asks for the runtime prefix's loader, and runs.
      check readElfRuntimeFacts(pair.program).interpreter ==
        pair.runtime / Loader
      check pair.runs()
      check recordRuntimePrefixReference(pair.storeRoot, pair.relocated,
        pair.runtime) == rroRecorded
      # Recording again is a no-op.
      check recordRuntimePrefixReference(pair.storeRoot, pair.relocated,
        pair.runtime) == rroRecorded

      var store = openStore(pair.storeRoot)
      defer: store.close()
      check store.prefixReferences(pair.relocatedId) == @[pair.runtimeId]
      store.registerRoot("pin:relocated", rkPin)
      store.attachPrefixToRoot("pin:relocated", pair.relocatedId)

      let kept = store.gc(graceSeconds = 0)
      check kept.quarantined.len == 0
      check store.lookupPrefix(pair.runtimeId).found
      check store.lookupPrefix(pair.relocatedId).found
      check dirExists(pair.runtime)
      check pair.runs()

      # Named directly, the runtime prefix is refused, and the refusal says
      # what keeps it.
      let refused = store.gcPrefix(pair.runtimeId, graceSeconds = 0)
      check refused.refused
      check refused.holdingRoots.len == 0
      check refused.referencedBy.len == 1
      check refused.referencedBy.len == 1 and
        pair.relocated.endsWith(refused.referencedBy[0])
      check dirExists(pair.runtime)
      check pair.runs()

      # Once nothing holds the relocated prefix, one run collects both.
      store.deleteRoot("pin:relocated")
      let collected = store.gc(graceSeconds = 0)
      check collected.quarantined.len == 2
      check not store.lookupPrefix(pair.runtimeId).found
      check not store.lookupPrefix(pair.relocatedId).found
      check not dirExists(pair.runtime)
      check not dirExists(pair.relocated)
      check store.listPrefixReferences().len == 0

  test "a budget run evicts the relocated prefix before its runtime prefix":
    when not defined(linux):
      skip("the ELF relocation applies to Linux archives only")
    else:
      let scratch = inTreeScratchDir("repro-runtime-reference-budget-")
      defer: removeDir(scratch)
      # The relocated prefix is padded past a tenth of the store, so evicting
      # it alone meets the default target (90% of the budget).
      let pair = makePair(scratch, padding = 4 * 1024 * 1024)
      check recordRuntimePrefixReference(pair.storeRoot, pair.relocated,
        pair.runtime) == rroRecorded
      let now = 2_000_000_000'i64
      block:
        var store = openStore(pair.storeRoot)
        defer: store.close()
        # The runtime prefix is the least recently used: a collector that
        # ignored the reference would evict it first.
        for (id, at) in [(pair.runtimeId, now - 30 * 86400),
                         (pair.relocatedId, now - 10 * 86400)]:
          var u = store.db.prepare("UPDATE prefixes SET created_at = ?, " &
            "last_used_at = NULL WHERE prefix_id = ?")
          u.bindInt(1, at)
          u.bindBlob(2, id)
          discard u.step()
          u.finalize()
      let measured = budgetGc(pair.storeRoot, BudgetGcPolicy(
        budgetBytes: 1 shl 40, nowUnix: now, graceSeconds: 1))
      check measured.evicted.len == 0
      let report = budgetGc(pair.storeRoot, BudgetGcPolicy(
        budgetBytes: measured.bytesBefore - 1, nowUnix: now,
        graceSeconds: 1))
      checkpoint renderBudgetGcText(report, pair.storeRoot)
      check report.evicted.len == 1
      check report.evicted.len == 1 and
        pair.relocated.endsWith(report.evicted[0].id)
      var store = openStore(pair.storeRoot)
      defer: store.close()
      check store.lookupPrefix(pair.runtimeId).found
      check dirExists(pair.runtime)
      # Over a budget it cannot meet without it, the runtime prefix goes too,
      # after the prefix that referenced it.
      let all = budgetGc(pair.storeRoot, BudgetGcPolicy(budgetBytes: 1,
        nowUnix: now, graceSeconds: 1))
      check all.evicted.len == 1 and
        pair.runtime.endsWith(all.evicted[0].id)
      check not store.lookupPrefix(pair.runtimeId).found

  test "a gone runtime prefix is refused; an unindexed one is reported":
    when not defined(linux):
      skip("the ELF relocation applies to Linux archives only")
    else:
      let scratch = inTreeScratchDir("repro-runtime-reference-gone-")
      defer: removeDir(scratch)
      let pair = makePair(scratch)
      # A prefix the index does not know cannot carry a reference.
      let stray = pair.storeRoot / "prefixes" / "stray" / "1.0-unindexed"
      createDir(stray)
      check recordRuntimePrefixReference(pair.storeRoot, pair.relocated,
        stray) == rroUnindexed
      # A runtime prefix that is gone: the relocated programs cannot start,
      # and recording a reference to it is refused.
      var store = openStore(pair.storeRoot)
      defer: store.close()
      check store.gcPrefix(pair.runtimeId, graceSeconds = 0).reason ==
        "collected"
      check not dirExists(pair.runtime)
      check not pair.runs()
      expect RuntimePrefixMissing:
        discard recordRuntimePrefixReference(pair.storeRoot, pair.relocated,
          pair.runtime)
      # The store refuses a reference to a prefix it no longer indexes.
      expect EPrefixNotIndexed:
        discard store.recordPrefixReference(pair.relocatedId, pair.runtimeId)
