import std/[algorithm, json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support

include ../fixtures/hcr/reference_corpus_map

proc gitHead(repoPath: string): string =
  requireSuccess(shellCommand(@["git", "-C", repoPath, "rev-parse", "HEAD"])).strip()

proc entryById(corpus: HcrReferenceCorpus; id: string): HcrReferenceEntry =
  for entry in corpus.entries:
    if entry.id == id:
      return entry
  fail()

proc containsNeedle(text: string; needle: string): bool =
  text.find(needle) >= 0

proc containsAny(text: string; needles: openArray[string]): bool =
  for needle in needles:
    if text.containsNeedle(needle):
      return true
  false

proc writeInspection(path: string; corpus: HcrReferenceCorpus;
                     oldObj, newObj, fileOld, fileNew, nmOld, nmNew,
                     commands: string) =
  var root = newJObject()
  root["schemaId"] = newJString("reprobuild.hcr.m25.inspection.v1")
  root["referenceSchemaId"] = newJString(corpus.schemaId)
  root["oldObject"] = newJString(oldObj)
  root["newObject"] = newJString(newObj)
  root["oldFile"] = newJString(fileOld.strip())
  root["newFile"] = newJString(fileNew.strip())
  root["oldSymbols"] = newJString(nmOld)
  root["newSymbols"] = newJString(nmNew)
  root["compileCommandEvidence"] = newJString(commands)
  writeFile(path, pretty(root))

suite "integration_hcr_reference_corpus_and_object_inputs":
  when isNixSupported:
    test "reference corpus, direct-HCR metadata, and real object inputs":
      let repoRoot = getCurrentDir()
      let corpus = hcrReferenceCorpus()
      let gateMetadata = directHcrGateMetadata()

      check corpus.schemaId ==
        "reprobuild.hcr.reference-linker-corpus.v1"
      check corpus.entries.len == 4
      check corpus.entries.mapIt(it.id).sorted() ==
        @["llvm-jitlink-lld", "mold", "msvc-incremental", "wild"]

      check gateMetadata.schemaId == "reprobuild.hcr.direct-gate-metadata.v1"
      check gateMetadata.milestone == "M25"
      check gateMetadata.positivePath.contains("direct-in-target")
      check gateMetadata.sharedLibraryLoadingPositivePath == "forbidden"
      check gateMetadata.forbiddenPositivePathApis.contains("dlopen")
      check gateMetadata.forbiddenPositivePathApis.contains("LoadLibrary")
      check gateMetadata.forbiddenBuildFlags.contains("-shared")
      check gateMetadata.forbiddenBuildFlags.contains("-dynamiclib")

      for id in ["mold", "wild", "llvm-jitlink-lld"]:
        let entry = corpus.entryById(id)
        check entry.availabilityMode == "manifest-repo"
        check entry.localCheckout.len > 0
        check entry.pinnedCommit.len == 40
        check entry.algorithmAreas.len >= 3
        check entry.hcrSpecSections.len >= 3
        check entry.sourcePaths.len >= 4

        let checkout = repoRoot / entry.localCheckout
        check dirExists(checkout)
        check gitHead(checkout) == entry.pinnedCommit

        for mappedPath in entry.sourcePaths:
          check fileExists(checkout / mappedPath)
        for mappedPath in entry.documentationPaths:
          check fileExists(checkout / mappedPath)

      let msvc = corpus.entryById("msvc-incremental")
      check msvc.availabilityMode == "pinned-map"
      check msvc.localCheckout.len == 0
      check msvc.pinnedCommit.len == 0
      check msvc.sourcePaths.len == 0
      check msvc.documentationPaths.len == 0
      check msvc.docUrls.len >= 3
      check msvc.docsAccessDate == "2026-05-16"
      check msvc.docsProvenance.contains("Microsoft Learn")
      check msvc.docsProvenance.contains("no network access")
      check msvc.algorithmAreas.contains("hotpatchable function padding")
      check msvc.hcrSpecSections.len >= 3

      let tempRoot = createTempDir("repro-hcr-m25", "")
      defer: removeDir(tempRoot)

      let fixtureDir = repoRoot / "tests" / "fixtures" / "hcr" / "object-inputs"
      let buildScript = fixtureDir / "build-hcr-object-fixture.sh"
      check fileExists(fixtureDir / "hcr_old.c")
      check fileExists(fixtureDir / "hcr_new.c")
      check fileExists(buildScript)

      discard requireSuccess(shellCommand([buildScript, tempRoot]), repoRoot)

      let oldObj = tempRoot / "hcr_old.o"
      let newObj = tempRoot / "hcr_new.o"
      let evidencePath = tempRoot / "compile-commands.txt"

      check fileExists(oldObj)
      check fileExists(newObj)
      check not fileExists(tempRoot / "hcr_old.dylib")
      check not fileExists(tempRoot / "hcr_new.dylib")
      check not fileExists(tempRoot / "hcr_old.so")
      check not fileExists(tempRoot / "hcr_new.so")
      check readFile(oldObj) != readFile(newObj)

      let fileOld = requireSuccess(shellCommand(["file", oldObj]))
      let fileNew = requireSuccess(shellCommand(["file", newObj]))
      check fileOld.toLowerAscii().containsAny(["object", "relocatable"])
      check fileNew.toLowerAscii().containsAny(["object", "relocatable"])
      check not fileOld.toLowerAscii().containsAny([
        "shared library",
        "dynamically linked shared library",
        "dynamic library"
      ])
      check not fileNew.toLowerAscii().containsAny([
        "shared library",
        "dynamically linked shared library",
        "dynamic library"
      ])

      let nmOld = requireSuccess(shellCommand(["nm", "-a", oldObj]))
      let nmNew = requireSuccess(shellCommand(["nm", "-a", newObj]))
      for symbol in [
        "hcr_changed_function",
        "hcr_caller",
        "hcr_data_bias",
        "hcr_external_seed"
      ]:
        check nmOld.contains(symbol)
        check nmNew.contains(symbol)

      let commands = readFile(evidencePath)
      check commands.contains("schema_id=reprobuild.hcr.object-fixture-commands.v1")
      check commands.contains("positive_path=relocatable-object")
      check commands.contains("shared_library_loading_positive_path=forbidden")
      check commands.contains("-c")
      check commands.contains("-g")
      check commands.contains("-ffunction-sections")
      check commands.contains("-fpatchable-function-entry=8,4")
      check not commands.contains("-shared")
      check not commands.contains("-dynamiclib")
      check not commands.contains("dlopen")
      check not commands.contains("LoadLibrary")

      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeInspection(logDir / "integration_hcr_reference_corpus_and_object_inputs.json",
        corpus, oldObj, newObj, fileOld, fileNew, nmOld, nmNew, commands)
