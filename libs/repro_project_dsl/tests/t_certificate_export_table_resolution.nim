## Test-Certificates TC-9a: the DSL half of ``certificate "<name>", <handle>``
## — the declaration registry, ``resolveCertificateExports`` and the
## certificate-export table codec — exercised directly against the DSL
## runtime registries, without a provider binary.
##
## The end-to-end behaviour (provider compile, stored graph, CLI) is covered
## by the ``t_certificate_*`` / ``t_plan_reports_*`` integration tests; this
## file pins the rules the provider applies, including the runtime collision
## check the macro cannot reach (a name computed while the body runs).

import std/[strutils, unittest]

import repro_project_dsl

proc exportRows(name: string): seq[TargetExportEntry] =
  for entry in registeredTargetExports().entries:
    if entry.name == name:
      result.add(entry)

suite "t_certificate_export_table_resolution":
  setup:
    resetBuildActionRegistry()
    resetBuildTargetRegistry()
    resetTargetExportRegistry()
    resetCertificateRegistry()

  test "a declaration over an aggregate of the same name adds no target":
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    let b = buildAction("b", publicCliCall("p", "tool", "", "ep", @[]))
    certificate "unit-suite", aggregate("unit-suite", @[a, b])
    var targets = registeredBuildTargets()
    for target in targets:
      registerExplicitTargetExport(target, "pkg")
    let table = resolveCertificateExports("pkg", targets)
    check targets.len == 1
    check table.entries.len == 1
    check table.entries[0].name == "unit-suite"
    check table.entries[0].nodeKind == cnkTarget
    check table.entries[0].node == "unit-suite"
    check table.entries[0].owningPackage == "pkg"
    check not table.entries[0].implicit
    check table.entries[0].sourceFile.endsWith(
      "t_certificate_export_table_resolution.nim")
    check table.entries[0].sourceLine > 0

  test "a declaration over an unnamed edge exports the name":
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    certificate "only-a", a
    var targets = registeredBuildTargets()
    let table = resolveCertificateExports("pkg", targets)
    check table.entries.len == 1
    check table.entries[0].nodeKind == cnkAction
    check table.entries[0].node == "a"
    check targets.len == 1
    check targets[0].name == "only-a"
    check targets[0].actions == @["a"]
    check targets[0].kind == btkTarget
    let rows = exportRows("only-a")
    check rows.len == 1
    check rows[0].actionId == "a"

  test "a computed name colliding with a target is refused naming the site":
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    let b = buildAction("b", publicCliCall("p", "tool", "", "ep", @[]))
    discard target("x", a)
    let computed = "X".toLowerAscii
    certificate computed, b
    var targets = registeredBuildTargets()
    for target in targets:
      registerExplicitTargetExport(target, "pkg")
    expect ValueError:
      discard resolveCertificateExports("pkg", targets)
    try:
      discard resolveCertificateExports("pkg", targets)
    except ValueError as err:
      check "certificate name 'x' declared at" in err.msg
      check "t_certificate_export_table_resolution.nim:" in err.msg
      check "collides with the target 'x'" in err.msg

  test "a name declared twice is refused naming both sites":
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    let name = "dup"
    certificate name, a
    certificate name, a
    var targets = registeredBuildTargets()
    try:
      discard resolveCertificateExports("pkg", targets)
      check false
    except ValueError as err:
      check "certificate name 'dup' is declared twice" in err.msg
      check err.msg.count("t_certificate_export_table_resolution.nim:") == 2

  test "the test target is marked implicitly; an explicit test replaces it":
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    let b = buildAction("b", publicCliCall("p", "tool", "", "ep", @[]))
    discard aggregate("test", @[a, b])
    var targets = registeredBuildTargets()
    for target in targets:
      registerExplicitTargetExport(target, "pkg")
    let implicitTable = resolveCertificateExports("pkg", targets)
    check implicitTable.entries.len == 1
    check implicitTable.entries[0].name == "test"
    check implicitTable.entries[0].implicit
    check implicitTable.entries[0].node == "test"

    resetCertificateRegistry()
    certificate "test", aggregate("fast", @[a])
    targets = registeredBuildTargets()
    let explicitTable = resolveCertificateExports("pkg", targets)
    check explicitTable.entries.len == 1
    check not explicitTable.entries[0].implicit
    check explicitTable.entries[0].node == "fast"
    # The ``test`` target itself is untouched.
    check exportRows("test").len == 1

  test "the implicit marking follows the selector test, not a target only":
    # ``repro test`` is ``repro build test``: the marking is whatever that
    # selector resolves to, in the engine's order — an action id, then a
    # build target (``collect`` included), then an exported name.
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    registerImplicitTargetExports("a", "pkg", ["test"], "/p/repro.nim", 7)
    var targets = registeredBuildTargets()
    var table = resolveCertificateExports("pkg", targets)
    check table.entries.len == 1
    check table.entries[0].implicit
    check table.entries[0].nodeKind == cnkAction
    check table.entries[0].node == "a"
    check table.entries[0].sourceLine == 7

    resetCertificateRegistry()
    discard collect("test", @[a])
    targets = registeredBuildTargets()
    table = resolveCertificateExports("pkg", targets)
    check table.entries.len == 1
    check table.entries[0].nodeKind == cnkTarget
    check table.entries[0].node == "test"

    resetCertificateRegistry()
    let t = buildAction("test", publicCliCall("p", "tool", "", "ep", @[]))
    discard t
    table = resolveCertificateExports("pkg", targets)
    check table.entries.len == 1
    check table.entries[0].nodeKind == cnkAction
    check table.entries[0].node == "test"

  test "no test target, no implicit marking":
    let a = buildAction("a", publicCliCall("p", "tool", "", "ep", @[]))
    discard aggregate("unit", @[a])
    var targets = registeredBuildTargets()
    check resolveCertificateExports("pkg", targets).entries.len == 0

  test "the certificate-export table round-trips and rejects damage":
    let table = CertificateExportTable(entries: @[
      CertificateExportEntry(name: "unit-suite", owningPackage: "pkg",
        nodeKind: cnkTarget, node: "unit-suite", sourceFile: "/p/repro.nim",
        sourceLine: 12),
      CertificateExportEntry(name: "test", owningPackage: "pkg",
        nodeKind: cnkAction, node: "edge-1", implicit: true)])
    let bytes = encodeCertificateExportTablePayload(table)
    check decodeCertificateExportTablePayload(bytes) == table
    var truncated = bytes
    truncated.setLen(bytes.len - 1)
    expect BuildActionPayloadError:
      discard decodeCertificateExportTablePayload(truncated)
    var badKind = bytes
    # The first entry's kind byte follows the entry count and two strings.
    let kindAt = 10 + 4 + (4 + "unit-suite".len) + (4 + "pkg".len)
    check badKind[kindAt] == byte(ord(cnkTarget))
    badKind[kindAt] = 7
    expect BuildActionPayloadError:
      discard decodeCertificateExportTablePayload(badKind)
    # The entry count is the first payload word after the 10-byte envelope. A
    # corrupted count must be refused against the bytes left, not used to
    # size the entry seq: ``high(uint32)`` entries is hundreds of gigabytes.
    var badCount = bytes
    for i in 0 ..< 4:
      badCount[10 + i] = 0xff
    try:
      discard decodeCertificateExportTablePayload(badCount)
      check false
    except BuildActionPayloadError as err:
      check err.msg ==
        "certificate export entry count exceeds remaining payload bytes"
