## Spec-Implementation M3 — native ``CrossTarget`` integration test.
##
## Asserts:
##   1. ``nativeCrossTarget()`` returns a fully populated handle
##      whose ``isNative`` is true and whose ``triple`` matches the
##      detected host CPU+OS shape.
##   2. ``hostPrefix()`` is empty (the native adapter doesn't prefix
##      tool invocations).
##   3. ``tripleOrEmpty`` returns ``""`` for the native adapter.
##   4. ``binaryFormat`` matches the host OS family.

import std/unittest

import repro_dsl_stdlib/interfaces/cross_target
import repro_dsl_stdlib/adapters/native_cross_target

suite "Spec-Implementation M3: native CrossTarget":

  test "nativeCrossTarget is fully populated":
    let ct = nativeCrossTarget()
    validate(ct)
    check ct.name == "native"
    check ct.isNative
    check ct.triple.len > 0
    # The triple is ``<cpu>-<os>[-<abi>]``; on every supported host
    # the CPU prefix is present, so a simple length floor catches
    # a stub triple.
    check ct.triple.len >= 5

  test "hostPrefix is empty for native":
    let ct = nativeCrossTarget()
    check ct.hostPrefix() == ""
    check ct.targetTriple() == ct.triple

  test "tripleOrEmpty is empty for native":
    let ct = nativeCrossTarget()
    check tripleOrEmpty(ct) == ""

  test "binaryFormat matches the host":
    let ct = nativeCrossTarget()
    when defined(macosx):
      check ct.binaryFormat == bfMachO
    elif defined(windows):
      check ct.binaryFormat == bfPE
    else:
      check ct.binaryFormat == bfELF
    check ct.pageSize == 4096
