## The engine's content-addressed shape guard recognises a store realization
## by EXACTLY the two names the store gives one, and nothing else.
##
## Issue: reprobuild-pm
## issues/2026-11-12-the-realization-hash-envelope-omits-the-recipe-itself-runtimedeps-and-environment-values.md.
## Governing spec: Local-Content-Addressed-Store.md §"Realization Hash
## (normative)", "The directory name: the one truncation".
##
## `contentAddressedRoot` elides reads under a `<store>/…/prefixes/<pkg>/<dir>`
## only when `<dir>` names a realization digest (`isRealizationDirName`). The
## store now names a prefix `<version>-<40 hex>` and keeps prefixes an older
## build named `<version>-<16 hex>` where they lie, so both must be
## recognised -- a tool run from either is content-addressed -- and every
## other shape must not be, or a mutable tree beside the realizations would
## be elided and keyed as if its path named its own content.
##
## The predicate is two copies of one shape, each a conjunction of a
## SEPARATOR arm (a `-` exactly `width + 1` from the end, which also bounds
## the length) and a DIGIT arm (only lowercase hex after it). Each rejecting
## name below is rejected by exactly one arm of each copy, so deleting any
## one arm turns at least one of them into a wrong answer:
##
##   name                                   40: sep  digit   16: sep  digit
##   <44 hex>                                   rej             rej
##   x-<40 non-hex>                                  rej        rej
##   bash-mutable-checkout                      rej                    rej
##   5.2-<20 hex>                               rej             rej
##   5.2-<40 UPPER hex>                              rej        rej
##   latest                                     rej             rej
##
## The two accepting names are the denominators: without them an empty answer
## could mean `$REPRO_STORE_ROOT` never took. The same arms are graded end to
## end, with a real tool and the cache, by
## `tests/integration/t_executed_binary_is_a_recorded_input.nim`.
##
## MOCK POLICY: none. Only path arithmetic is exercised; the store root is a
## real temporary directory named through `$REPRO_STORE_ROOT`.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine
import repro_local_store

suite "store realization names of both widths are content-addressed":

  test "the 40-hex and the 16-hex realization names, and nothing else":
    let root = createTempDir("repro-ca-widths-", "")
    defer: removeDir(root)
    let hadStore = existsEnv("REPRO_STORE_ROOT")
    let oldStore = getEnv("REPRO_STORE_ROOT")
    putEnv("REPRO_STORE_ROOT", root)
    defer:
      if hadStore: putEnv("REPRO_STORE_ROOT", oldStore)
      else: delEnv("REPRO_STORE_ROOT")
    var digest: PrefixIdBytes
    for i in 0 ..< 32: digest[i] = byte(0xC0 or (i and 0x0F))
    let slashRoot = root.replace('\\', '/')

    let current = slashRoot & "/" & prefixRelativePath("bash", "5.2", digest)
    let legacy = slashRoot & "/" & legacyPrefixRelativePath("bash", "5.2",
                                                             digest)
    check current.extractFilename.len == "5.2-".len + 40
    check legacy.extractFilename.len == "5.2-".len + 16
    check contentAddressedRoot(current & "/bin/sh") == current
    check contentAddressedRoot(legacy & "/bin/sh") == legacy

    let hex40 = prefixIdHex(digest)[0 ..< 40]
    for name in [
        prefixIdHex(digest)[0 ..< 44],
        "x-" & repeat('g', 40),
        "bash-mutable-checkout",
        "5.2-" & prefixIdHex(digest)[0 ..< 20],
        "5.2-" & hex40.toUpperAscii(),
        "latest"]:
      let dir = slashRoot & "/prefixes/bash/" & name
      checkpoint name
      check contentAddressedRoot(dir & "/bin/sh") == ""
