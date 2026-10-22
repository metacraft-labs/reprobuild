## The interface extraction's nimcache: keyed by compile configuration, used
## through a pool of exclusively locked slots.
##
## reprobuild-specs issues/2026-10-22-recipe-interface-extraction-recompiles-
## library-code-per-cache-root-and-per-edit.md. The end-to-end property (a
## fresh action-cache root and an edited recipe reuse the library objects) is
## pinned by `tests/integration/t_interface_extraction_reuses_library_objects`;
## this file pins the two pieces it rests on:
##
##   * THE KEY LEAVES THE RECIPE'S LOCATION OUT and keeps the rest of the
##     configuration: the recipe's `--path:` and `-d:reproConsumerRoot=` are
##     dropped, every other define and path stays.
##   * THE SLOTS ARE EXCLUSIVE and taken lowest-free-first: two holders never
##     share a slot, a sequential user keeps getting slot 0, and a holder that
##     is busy makes the next one go to the next slot rather than wait.
##
## MOCK POLICY - none. Real file locks on a real temporary directory; the
## second holder is a separate open file description of the same lock file,
## which is what a second process holds.

import std/[os, tempfiles, unittest]

import repro_interface_artifacts

suite "interface extraction nimcache slots":

  test "the key drops the recipe's location and keeps the configuration":
    let command = @["nim", "c", "--parallelBuild:1",
      "--define:reproInterfaceMode",
      "--define:reproConsumerRoot=/projects/a",
      "--path:/libs/x",
      "--path:/projects/a",
      "--nimcache:/somewhere",
      "--out:/tmp/x/extract_runner",
      "RUNNER"]
    let flags = interfaceNimcacheKeyedCompileFlags(command, "RUNNER",
      ["--path:/projects/a", "--define:reproConsumerRoot=/projects/a"])
    check flags == @["--define:reproInterfaceMode", "--path:/libs/x"]
    # Another project's recipe, same configuration: the same key.
    let other = interfaceNimcacheKeyedCompileFlags(@["nim", "c",
      "--define:reproInterfaceMode",
      "--define:reproConsumerRoot=/projects/b",
      "--path:/libs/x",
      "--path:/projects/b",
      "--nimcache:/elsewhere",
      "--out:/tmp/y/extract_runner",
      "RUNNER2"], "RUNNER2",
      ["--path:/projects/b", "--define:reproConsumerRoot=/projects/b"])
    check interfaceNimcacheConfigKey("/work", ["-host"], ["--path:/libs"],
      flags) ==
      interfaceNimcacheConfigKey("/work", ["-host"], ["--path:/libs"], other)
    # A configuration difference still moves it.
    check interfaceNimcacheConfigKey("/work", ["-host"], ["--path:/libs"],
      flags) !=
      interfaceNimcacheConfigKey("/work", ["-host"], ["--path:/libs"],
        @["--define:reproInterfaceMode", "--define:other", "--path:/libs/x"])

  test "the root follows the temporary directory, not an action-cache root":
    let tmp = createTempDir("repro-ifslot-tmp-", "")
    defer: removeDir(tmp)
    let saved = getEnv("TMPDIR")
    defer:
      if saved.len > 0: putEnv("TMPDIR", saved) else: delEnv("TMPDIR")
    putEnv("TMPDIR", tmp)
    check interfaceExtractionNimcacheRoot().parentDir == tmp
    check interfaceExtractionIgnoredInputPrefixes() ==
      @[absolutePath(interfaceExtractionNimcacheRoot())]

  test "slots are exclusive and taken lowest-free-first":
    let root = createTempDir("repro-ifslot-", "")
    defer: removeDir(root)
    let config = root / "config"
    var a = acquireInterfaceNimcacheSlot(config, slotCount = 3)
    check a.index == 0
    check dirExists(a.dir)
    var b = acquireInterfaceNimcacheSlot(config, slotCount = 3)
    check b.index == 1
    var c = acquireInterfaceNimcacheSlot(config, slotCount = 3)
    check c.index == 2
    releaseInterfaceNimcacheSlot(a)
    # A sequential user lands back on the warm slot 0.
    var d = acquireInterfaceNimcacheSlot(config, slotCount = 3)
    check d.index == 0
    releaseInterfaceNimcacheSlot(b)
    # All but slot 1 busy: the waiter takes the one that is free.
    var e = acquireInterfaceNimcacheSlot(config, slotCount = 3)
    check e.index == 1
    releaseInterfaceNimcacheSlot(c)
    releaseInterfaceNimcacheSlot(d)
    releaseInterfaceNimcacheSlot(e)
    var f = acquireInterfaceNimcacheSlot(config, slotCount = 3)
    check f.index == 0
    releaseInterfaceNimcacheSlot(f)
