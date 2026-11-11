## A dynamic graph fragment's `create-action` record keys its command line.
##
## The record names an action by `id`, and the action it materialises may be
## `cacheable`. Its weak fingerprint was the id alone, so two records with
## one id and different `argv` or `cwd` addressed one local cache record:
## the second command was served the first one's outputs.
##
## Falsifier: put `parseCreateActionRecord`'s fingerprint back to
## `weakFingerprintFromText(id)` and every "differs" case below goes red.

import std/[json, unittest]

import repro_build_engine {.all.}

proc record(argv: openArray[string]; cwd = "/work"): BuildAction =
  let payload = $(%*{
    "id": "synth-compile",
    "argv": argv,
    "cwd": cwd,
    "outputs": ["synth.o"],
    "cacheable": true
  })
  parseCreateActionRecord(payload, "consumer.rbdyn", 2,
    lockIdentityOutsideSolvedGraph())

suite "create-action record keys its command line":

  test "the same record keys the same":
    check record(["/bin/cc", "-c", "a.c"]).weakFingerprint ==
      record(["/bin/cc", "-c", "a.c"]).weakFingerprint

  test "one changed argv element is a different key":
    let base = record(["/bin/cc", "-O0", "-c", "a.c"])
    check base.cacheable
    check base.weakFingerprint !=
      record(["/bin/cc", "-O2", "-c", "a.c"]).weakFingerprint

  test "an added argv element is a different key":
    check record(["/bin/cc", "-c", "a.c"]).weakFingerprint !=
      record(["/bin/cc", "-c", "a.c", "-DX"]).weakFingerprint

  test "a changed cwd is a different key":
    check record(["/bin/cc", "-c", "a.c"], "/work/a").weakFingerprint !=
      record(["/bin/cc", "-c", "a.c"], "/work/b").weakFingerprint

  test "argv elements are framed, not concatenated":
    check record(["/bin/sh", "-c", "a b"]).weakFingerprint !=
      record(["/bin/sh", "-c", "a", "b"]).weakFingerprint
    check record(["/bin/sh", "-c", "ab"]).weakFingerprint !=
      record(["/bin/sh", "-c", "a", "b"]).weakFingerprint

suite "keyedOnArgv":

  test "an empty argv still moves the key, and cwd is framed apart":
    let seed = weakFingerprintFromText("seed")
    check keyedOnArgv(seed, []) != seed
    check keyedOnArgv(seed, ["x"]) != keyedOnArgv(seed, [], "x")
    check keyedOnArgv(seed, ["x"], "y") == keyedOnArgv(seed, ["x"], "y")
