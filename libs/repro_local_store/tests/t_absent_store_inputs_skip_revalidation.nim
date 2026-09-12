## Soundness of skipping revalidation for inputs that were absent inside a
## published package-store output path.
##
## Graded on SOUNDNESS, never on timing. Every case here asks "does an input
## that could change still invalidate", because the failure mode of this
## optimisation is a stale cache hit, not a slow one. The timing claim is
## carried by the `store absence skips` counter against `absent first
## touches`, which is a measurement and does not belong in a test.
##
## No mocks. The store cases run against the real `/nix/store` on this host,
## because the predicate deliberately takes no injection point: honouring an
## ambient store location was a measured hole that permanently poisoned
## records, and a test seam would be the same hole with a different name.
## Where the host has no store the cases `skip()` with that reason rather
## than passing vacuously.

import std/[options, os, sets, strutils, unittest]

import repro_local_store

proc anExistingStoreOutputPath(): string =
  ## A real published output path on this host, or "" if there is none.
  if not dirExists("/nix/store"):
    return ""
  for kind, path in walkDir("/nix/store"):
    if kind != pcDir:
      continue
    if path.lastPathPart.startsWith("."):
      continue
    # Must itself be listable, so the "absent inside it" case is genuinely
    # absence rather than an unreadable directory.
    try:
      for _, _ in walkDir(path):
        discard
      return path
    except OSError, IOError:
      continue
  ""

proc absentInput(path: string): FileFingerprint =
  FileFingerprint(path: path, policy: ffpTimestamp,
    metadata: FileMetadata(kind: ffkMissing))

proc recordWith(inputs: varargs[FileFingerprint]): ActionResultRecord =
  result = ActionResultRecord(policy: ffpTimestamp)
  for input in inputs:
    result.inputs.add(input)

suite "absent store inputs skip revalidation":

  test "only a path STRICTLY INSIDE an output path is classified":
    # The bare output path is the case that makes this unsound if dropped:
    # building or substituting the package is exactly what brings it into
    # existence, so its absence is not stable.
    check immutableStoreOutputPath("/nix/store/abc-foo/lib/libx.so") ==
      "/nix/store/abc-foo"
    check immutableStoreOutputPath("/nix/store/abc-foo/lib/") ==
      "/nix/store/abc-foo"
    check immutableStoreOutputPath("/nix/store/abc-foo") == ""
    check immutableStoreOutputPath("/nix/store/") == ""
    check immutableStoreOutputPath("/nix/store") == ""

  test "the class-3 residue is not classified and keeps being probed":
    # Every one of these can come into existence between two builds, and an
    # exclusion that swallowed them would serve a stale hit. This is the
    # exposure a blanket evidence-scope narrowing discards and this change
    # deliberately keeps.
    for path in ["/usr/bin/ld", "/home/someone/.config/nim/nim.cfg",
                 "/home/someone/project/nimble.lock",
                 "/home/someone/project/config.nims",
                 "/opt/homebrew/lib/libz.dylib",
                 "/tmp/nim-parameter-file-12345",
                 "/nix/var/nix/profiles/default/bin/cc",
                 "relative/path/x.h", ""]:
      check immutableStoreOutputPath(path) == ""

  test "a near-miss prefix is not classified":
    # A directory that merely LOOKS like the store must not inherit the
    # store's write discipline.
    check immutableStoreOutputPath("/nix/store-other/abc/x") == ""
    check immutableStoreOutputPath("/home/u/nix/store/abc/x") == ""
    check immutableStoreOutputPath("/nix/stores/abc/x") == ""

  test "an input absent inside an existing output path is skipped":
    let storePath = anExistingStoreOutputPath()
    if storePath.len == 0:
      skip()
    else:
      resetOutputStateCheckStats()
      var cache = initFileMetadataCache()
      let missing = storePath / "definitely-absent-6f3a1c" / "x.h"
      check not fileExists(missing)
      let record = recordWith(absentInput(missing))
      check hotMetadataRecordInputsUnchanged([record], addr cache)
      # The skip happened, and it was not merely a metadata-cache hit.
      check storeAbsenceSkipStats() == 1
      check cache.metadataStats().warmRevalidated == 0

  test "an input absent inside a NON-EXISTENT output path is still probed":
    # The output path can still be built or substituted, and it would bring
    # this path with it. Skipping here would be the stale hit.
    resetOutputStateCheckStats()
    var cache = initFileMetadataCache()
    let missing =
      "/nix/store/0000000000000000000000000000000-absent-pkg/lib/x.h"
    check not fileExists(missing)
    let record = recordWith(absentInput(missing))
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    check storeAbsenceSkipStats() == 0

  test "a PRESENT input inside an output path is still probed":
    # Immutability stops entries being ADDED; it does not stop the whole
    # output path being garbage-collected. A present store input that
    # disappears must invalidate, so it keeps its probe.
    let storePath = anExistingStoreOutputPath()
    if storePath.len == 0:
      skip()
    else:
      # Store paths keep their files under `bin/`, `lib/` and friends, so a
      # top-level-only search skipped this case vacuously and hid the
      # assertion it exists for.
      var present = ""
      for path in walkDirRec(storePath):
        if fileExists(path) and not symlinkExists(path):
          present = path
          break
      if present.len == 0:
        skip()
      else:
        resetOutputStateCheckStats()
        var cache = initFileMetadataCache()
        let record = recordWith(observeFile(present, ffpTimestamp))
        check hotMetadataRecordInputsUnchanged([record], addr cache)
        check storeAbsenceSkipStats() == 0
        check cache.metadataStats().warmRevalidated == 1

  test "an absent input OUTSIDE the store invalidates when it appears":
    # THE MUTATION GUARD. Widening the prefix test to cover a writable
    # directory reddens exactly this case, because the file it creates is
    # precisely what the store's write discipline promises cannot happen.
    let dir = getTempDir() / "repro-absent-outside-store-6f3a1c"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    let appears = dir / "appears-later.h"
    check not fileExists(appears)
    let record = recordWith(absentInput(appears))

    resetOutputStateCheckStats()
    var before = initFileMetadataCache()
    check hotMetadataRecordInputsUnchanged([record], addr before)
    check storeAbsenceSkipStats() == 0

    writeFile(appears, "#pragma once\n")
    resetOutputStateCheckStats()
    var after = initFileMetadataCache()
    check not hotMetadataRecordInputsUnchanged([record], addr after)

  test "an absent input inside an output path that APPEARS is still caught":
    # The same guard one level in: the output path itself is created, which
    # the classification refuses to treat as immutable, so the input inside
    # it must be seen to appear.
    let fakeStore = getTempDir() / "repro-fake-store-6f3a1c"
    removeDir(fakeStore)
    createDir(fakeStore)
    defer: removeDir(fakeStore)
    let inside = fakeStore / "abc-pkg" / "lib" / "x.h"
    let record = recordWith(absentInput(inside))
    resetOutputStateCheckStats()
    var cache = initFileMetadataCache()
    check hotMetadataRecordInputsUnchanged([record], addr cache)
    createDir(fakeStore / "abc-pkg" / "lib")
    writeFile(inside, "#pragma once\n")
    var after = initFileMetadataCache()
    check not hotMetadataRecordInputsUnchanged([record], addr after)
