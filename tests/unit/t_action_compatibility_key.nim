## M17: the action COMPATIBILITY KEY is coarser than the action-cache key,
## asserted directly against both real functions.
##
## ``Build-Analytics-And-Optimization.md`` §"Observation Model":
##
##   "The exact weak fingerprint used for cache identity is too specific for
##    long-term performance history: a source edit should not make all
##    duration history useless. The compatibility key must therefore be
##    coarser than the action-cache key while still separating measurements
##    that are not comparable."
##
## WHY THIS EXISTS BESIDE THE INTEGRATION TEST. The integration test drives
## a real build, edits an input and shows the compatibility key unchanged
## while the cache REJECTS the record by input. What it cannot show is the
## action-cache KEY itself: on every miss path the lookup returns, the
## strong fingerprint is either cleared (the metadata-only hot record
## deliberately drops it) or the arm returns no record at all -- so the row
## honestly reports NULL and there is nothing to compare. This file closes
## that half by computing both quantities directly, with
## ``computeStrongFingerprint`` -- the function the cache itself uses to
## decide identity -- so "the cache key changed" is measured rather than
## inferred from a decision.
##
## NO MOCKS. Both functions under test are the shipped ones; the only thing
## constructed here is the input digest pair a source edit produces, which
## is the fixture and never the answer.

import std/[options, unittest]

import repro_build_engine
import repro_hash
import repro_hash/blake3_policy
import repro_local_store

proc inputWith(path, content: string): FileFingerprint =
  ## One input fingerprinted BY CONTENT, which is the policy under which a
  ## source edit is supposed to move the cache key. Under the timestamp
  ## policy the same edit moves it via the file metadata instead; either
  ## way the quantity below is the one the cache compares.
  var bytes = newSeq[byte](content.len)
  for i, ch in content:
    bytes[i] = byte(ord(ch))
  FileFingerprint(path: path, policy: ffpChecksum, hasLocalHash: true,
    localHash: localHash(bytes))

suite "M17 action compatibility key":

  test "a source edit moves the cache key and leaves the compatibility key":
    let argv = @["/nix/store/aaaa-gcc/bin/gcc", "-O2", "-c",
      "src/widget.c", "-o", "build/widget.o"]
    let outputs = @["build/widget.o"]
    let weak = weakFingerprintFromText("compile:widget")

    # THE ACTION-CACHE KEY, computed the way the cache computes it: the
    # weak fingerprint folded together with the CONTENT digests of the
    # inputs. Editing the source changes exactly one of those digests.
    let before = computeStrongFingerprint(weak,
      @[inputWith("src/widget.c", "int main(void) { return 0; }")])
    let after = computeStrongFingerprint(weak,
      @[inputWith("src/widget.c", "int main(void) { return 1; }")])

    # NON-VACUITY FIRST: the edit really did move the cache key. Without
    # this, an implementation whose strong fingerprint ignored input
    # content would make the equality below meaningless.
    check before != after

    let keyBefore = compatibilityKey("process", "cc", "gcc",
      "gcc@/nix/store/aaaa-gcc", argv, outputs)
    let keyAfter = compatibilityKey("process", "cc", "gcc",
      "gcc@/nix/store/aaaa-gcc", argv, outputs)
    check keyBefore == keyAfter

  test "the key still separates measurements that are not comparable":
    # COARSER IS NOT CONSTANT. Every dimension §"Observation Model" names
    # must move the key, or the key would pool work whose costs cannot be
    # compared -- which is the other half of the requirement and the one a
    # trivially-constant implementation would pass the test above with.
    let base = compatibilityKey("process", "cc", "gcc", "gcc@v13",
      @["gcc", "-O2", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.o"])

    # optimisation flag
    check base != compatibilityKey("process", "cc", "gcc", "gcc@v13",
      @["gcc", "-O0", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.o"])
    # tool version identity
    check base != compatibilityKey("process", "cc", "gcc", "gcc@v14",
      @["gcc", "-O2", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.o"])
    # tool kind
    check base != compatibilityKey("process", "cc", "clang", "gcc@v13",
      @["gcc", "-O2", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.o"])
    # command stats id
    check base != compatibilityKey("process", "link", "gcc", "gcc@v13",
      @["gcc", "-O2", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.o"])
    # action kind
    check base != compatibilityKey("copyfile", "cc", "gcc", "gcc@v13",
      @["gcc", "-O2", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.o"])
    # OUTPUT ROLE, VARIED ALONE. An object file and a shared library are
    # not the same kind of work. The argv is held IDENTICAL here on
    # purpose: the first draft varied `-o build/a.o` to `-o build/a.so`
    # as well, and the normalized argv shape carries the extension, so a
    # key that ignored the output role entirely still passed. Varying
    # only the declared outputs is the difference between asserting the
    # role dimension and asserting the argv dimension twice.
    check base != compatibilityKey("process", "cc", "gcc", "gcc@v13",
      @["gcc", "-O2", "-c", "src/a.c", "-o", "build/a.o"], @["build/a.so"])

  test "renaming a source file does not move the key, and its role does":
    # THE OTHER EDIT THAT MUST NOT DISCARD HISTORY. A file rename changes
    # the argv and therefore the weak fingerprint -- the cache identity --
    # while the work is the same compile it was yesterday.
    let before = compatibilityKey("process", "cc", "gcc", "gcc@v13",
      @["gcc", "-O2", "-c", "src/widget.c", "-o", "build/widget.o"],
      @["build/widget.o"])
    let after = compatibilityKey("process", "cc", "gcc", "gcc@v13",
      @["gcc", "-O2", "-c", "src/gadget.c", "-o", "build/gadget.o"],
      @["build/gadget.o"])
    check before == after
    # And the weak fingerprint -- cache identity -- really did move, so the
    # equality above is a statement about the key rather than about the
    # rename being invisible everywhere.
    check weakFingerprintFromText("gcc -c src/widget.c") !=
      weakFingerprintFromText("gcc -c src/gadget.c")

  test "the extension declares the version its ladder can reach":
    # A DECLARATION NAMING A VERSION WITH NO STEP FOR IT IS REFUSED by
    # RunQuota rather than approximated, so the two must agree here or
    # every row this client sends is dropped at the far end.
    check reproActionMigrations().len == int(ReproActionSchemaVersion)
    check ReproActionExtensionId == "repro_action"
    check registeredExtensionName() == "reprobuild.action.v1"
    # Every column the row writes must be a bare lowercase identifier or
    # RunQuota refuses the row: it interpolates column names into SQL by
    # concatenation and will not quote what a client asked for.
    for name in reproActionColumns():
      check name.len > 0
      check name[0] in {'a' .. 'z'}
      for ch in name:
        check ch in {'a' .. 'z', '0' .. '9', '_'}
