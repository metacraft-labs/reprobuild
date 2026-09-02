## W2 — a dev-env BINDS a cross-repo ``uses:`` producer; it never BUILDS one,
## and it is never silent about a pin it did not put into effect.
##
## Spec: ``Cross-Repo-Source-Consumption.md`` §4.2 (producer graph load +
## splice, executable channel). Milestone:
## ``Windows-Cacheable-Builds-Session-Residuals.milestones.org`` §W2.
##
## The defect W2 closed was NOT that the dev-env engine declined to call the
## build's producer pre-pass — declining is correct, for four reasons recorded
## at the ``devEnvProducerPins`` definition. The defect was what it did
## instead: a ``uses:`` producer selector with a live develop override was
## dropped on the floor, and the bare name resolved from the ambient PATH with
## exit 0 and no diagnostic. That is the one failure mode a pin exists to
## prevent, and it was the DEFAULT.
##
## This file pins the decision at the level where it is decidable without
## building anything: the classification of a declared selector, the shell ops
## synthesized from it, and the notice text emitted when it is not in effect.
## The end-to-end proof that ``repro exec`` actually runs the pinned binary
## rather than an ambient decoy of the same name is
## ``tests/e2e/dev-env/t_e2e_dev_env_binds_materialized_producer.nim``.
##
## Every case is hermetic: a fresh tempdir consumer workspace plus a sibling
## producer checkout. Nothing touches $HOME, no network, no git, no build.
##
## The properties asserted, one per case:
##
##   1. A develop-override producer whose ``build/bin`` holds a materialized
##      output is ``deppBound``, and yields a ``deskPrependPath`` op for
##      exactly that directory plus the ``REPRO_DEV_ENV_PRODUCER_PINS``
##      summary. It emits NO notice — it did what the declaration asked.
##   2. The same producer whose ``build/bin`` contains no executable a PATH
##      search would find is ``deppNotBuilt``, yields NO path op, and its
##      notice NAMES the ambient binary that will answer the name instead.
##      This is the exact case that used to be silent.
##   3. A selector that is not a declared producer edge is omitted entirely.
##      Resolving it from PATH is the declared contract of
##      ``defaultToolProvisioning "path"``, not a fallthrough, so warning
##      about it would be noise. An on-disk sibling with neither an override
##      nor a lock pin is such a selector (``pbkOnDiskSibling``).
##   4. A lock-pinned producer with no checkout present is ``deppNoSource``
##      and NOTHING IS FETCHED. The assertion is on the filesystem, not on the
##      classification: the revision-keyed cache root the build would clone
##      into must still not exist afterwards.
##   5. A lock-pinned producer whose revision tree was already fetched binds
##      from that tree — the pass reads the same location the build writes.
##   6. A develop override naming a checkout that is not on disk is
##      ``deppUnresolvable`` and REPORTED, not raised. A broken pin must leave
##      the developer with a working shell that says what it could not
##      provide.
##   7. Declaration order survives the reversal ``deskPrependPath``'s
##      sequential application requires: with two bound pins, the FIRST
##      declared one ends up FIRST on the resulting PATH.
##   8. A producer whose binary name differs from its selector still binds,
##      because the mapping is read from the interface artifact a previous
##      build already extracted — not from a fresh provider compile, and not
##      by assuming ``uses: "x"`` produces ``x``. This is the shape of the
##      workspace pin: ``uses: "reprobuild"`` produces ``repro``.
##   9. On a surface that deliberately does not bind (``repro dev-env
##      export``, whose plan is tamper-sealed), a BOUND pin still produces a
##      notice saying so. Silence there would be the same defect in a new
##      place.
##
## Falsifiability: each case names, in a ``checkpoint``, the mutation that
## breaks it. Every one was applied to the implementation and reproduced —
## ten mutations over these nine cases (``M1``-``M10`` in W2's DONE section),
## each caught by the case naming the property it broke and by no others.

import std/[os, strutils, unittest]

import repro_cli_support
import repro_dev_env_artifacts
import repro_interface_artifacts
import repro_lock
import repro_provider_runtime

const
  producerName = "prod"
  otherProducerName = "prod2"
  pinnedRevision = "0123456789abcdef0123456789abcdef01234567"
  pinnedUrl = "https://vcs.invalid/prod.git"

proc scratchRoot(slug: string): string =
  result = getTempDir() / "w2-" & slug & "-" & $getCurrentProcessId()
  removeDir(result)
  createDir(result)

proc writeOverride(workspaceRoot: string;
                   entries: openArray[tuple[package, localPath: string]]) =
  ## The on-disk develop-override shape verbatim, written by hand rather than
  ## through the M20 writer so this test stays a test of the CONSUMER of that
  ## file and cannot be made to pass by a change to its writer.
  createDir(workspaceRoot / ".repro")
  var text = "schema = \"reprobuild.workspace.develop-overrides.v1\"\n"
  for entry in entries:
    text.add("\n[[override]]\npackage = \"" & entry.package & "\"\n" &
      "local_path = \"" & entry.localPath & "\"\n" &
      "state = \"editable\"\n" &
      "created_at = \"2026-07-02T00:00:00Z\"\n")
  writeFile(workspaceRoot / ".repro" / "develop-overrides.toml", text)

proc writeLockPin(workspaceRoot: string) =
  var ld = LockedDependencies(
    schema: "reprobuild.solved-graph-lock.v2",
    platform: currentPlatformId(),
    optimal: true,
    inputsDigest: inputsDigestOf("w2-fixture"))
  ld.deps.add(LockedDep(
    name: producerName,
    path: "../prod",
    coordinates: Coordinates(kind: ckVcs, url: pinnedUrl,
      gitRef: "main", revision: pinnedRevision),
    integrity: "git-sha1:" & pinnedRevision,
    visibility: "public"))
  writeFile(committedLockPath(workspaceRoot), serializeLockedDependencies(ld))

proc artifactDeclaring(projectRoot: string;
                       selectors: openArray[string]): DevEnvArtifact =
  ## The dev-env artifact shape the introspection edge writes: every ``uses:``
  ## entry lands in ``toolProfiles`` as a declared requirement, carrying the
  ## selector and the executable name. That is the ONLY record of a ``uses:``
  ## declaration the activation surfaces have, which is why the pass reads it.
  result = DevEnvArtifact(projectRoot: projectRoot,
    selectedActivities: @["default"])
  for selector in selectors:
    result.toolProfiles.add(DevEnvToolProfileRef(
      logicalName: selector, packageIdentity: selector))

proc materializeProducerOutput(producerRoot, binaryName: string) =
  let binDir = producerRoot / "build" / "bin"
  createDir(binDir)
  writeFile(binDir / binaryName, "#!/bin/sh\necho stamp\n")

proc pinFor(pins: openArray[DevEnvProducerPin];
            selector: string): DevEnvProducerPin =
  for pin in pins:
    if pin.selector == selector:
      return pin
  raise newException(KeyError, "no pin classified for selector " & selector)

proc prependedPaths(ops: openArray[DevEnvShellOp]): seq[string] =
  for op in ops:
    if op.kind == deskPrependPath and op.name == "PATH":
      result.add(op.value)

proc setEnvValue(ops: openArray[DevEnvShellOp]; name: string): string =
  for op in ops:
    if op.kind == deskSetEnv and op.name == name:
      return op.value
  ""

suite "w2_dev_env_producer_pin_binding":

  test "materialized develop-override producer binds its bin dir":
    checkpoint("mutation: dropping the deppBound arm of devEnvProducerShellOps " &
      "leaves prependedPaths empty and this case fails")
    let scratch = scratchRoot("bound")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    let producer = absolutePath(scratch / "prod")
    createDir(consumer)
    createDir(producer)
    writeFile(producer / "repro.nim", "package prod:\n  discard\n")
    writeOverride(consumer, [(producerName, "../prod")])
    materializeProducerOutput(producer, addFileExt(producerName, ExeExt))

    let pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
      consumer)
    check pins.len == 1
    let pin = pins.pinFor(producerName)
    checkpoint("state=" & $pin.state & " binDir=" & pin.binDir)
    check pin.state == deppBound
    check normalizedPath(pin.binDir) ==
      normalizedPath(producer / "build" / "bin")

    let ops = devEnvProducerShellOps(pins)
    check ops.prependedPaths() == @[pin.binDir]
    check ops.setEnvValue(DevEnvProducerPinsEnvVar) ==
      producerName & "=" & pin.binDir

    # A pin that did what it was asked is SILENT. Warning about a working pin
    # would train the developer to ignore the channel that carries the real
    # failures.
    check devEnvProducerNotices(pins).len == 0

  test "unbuilt producer is not bound and names the ambient binary":
    checkpoint("mutation: classifying an empty build/bin as deppBound makes " &
      "this case bind a directory with nothing in it and emit no notice")
    let scratch = scratchRoot("notbuilt")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    let producer = absolutePath(scratch / "prod")
    let ambientDir = absolutePath(scratch / "ambient")
    createDir(consumer)
    createDir(producer)
    createDir(ambientDir)
    writeFile(producer / "repro.nim", "package prod:\n  discard\n")
    writeOverride(consumer, [(producerName, "../prod")])
    # ``build/bin`` exists and even holds a file — but not one a PATH search
    # for ``prod`` would find. "Bound" must mean "the declared name resolves
    # here", not "this directory contains something": a predicate as loose as
    # "the directory is non-empty" binds a producer whose executable was
    # deleted, renamed or never linked, and then the prepend silently achieves
    # nothing while the pass reports success.
    createDir(producer / "build" / "bin")
    writeFile(producer / "build" / "bin" / "prod.build-log", "not a binary\n")

    # An ambient binary of the same name, so the notice has something concrete
    # to name. This is the decoy the pre-W2 behaviour ran silently.
    let ambientBinary = ambientDir / addFileExt(producerName, ExeExt)
    writeFile(ambientBinary, "#!/bin/sh\necho ambient\n")
    let savedPath = getEnv("PATH")
    putEnv("PATH", ambientDir & $PathSep & savedPath)
    defer: putEnv("PATH", savedPath)

    let pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
      consumer)
    let pin = pins.pinFor(producerName)
    checkpoint("state=" & $pin.state & " ambient=" & pin.ambientPath)
    check pin.state == deppNotBuilt
    check pin.ambientPath.len > 0
    check normalizedPath(pin.ambientPath) == normalizedPath(ambientBinary)

    # Nothing is put on PATH, so the name genuinely does fall through — and
    # the notice says so, names what it will fall through TO, and names the
    # command that fixes it.
    check devEnvProducerShellOps(pins).len == 0
    let notices = devEnvProducerNotices(pins)
    check notices.len == 1
    checkpoint(notices[0])
    check notices[0].contains(producerName)
    check notices[0].contains("repro build")
    check notices[0].contains(ambientBinary)

  test "a selector that is not a declared producer edge is omitted":
    checkpoint("mutation: dropping the declaresProducerEdge guard makes a " &
      "plain on-disk sibling produce a pin and this case fails")
    let scratch = scratchRoot("nonproducer")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    createDir(consumer)
    # A discoverable sibling checkout with NEITHER a develop override nor a
    # lock pin. ``resolveProducerBinding`` calls that ``pbkOnDiskSibling``:
    # discoverable, but not a declared build-graph edge. Materializing or
    # warning about it would be exactly the "silently build an undeclared
    # sibling" behaviour the producer seam refuses.
    let sibling = absolutePath(scratch / producerName)
    createDir(sibling)
    writeFile(sibling / "repro.nim", "package prod:\n  discard\n")
    materializeProducerOutput(sibling, addFileExt(producerName, ExeExt))

    let pins = devEnvProducerPins(
      artifactDeclaring(consumer, [producerName, "gcc", "git"]), consumer)
    checkpoint("classified pins=" & $pins.len)
    check pins.len == 0
    check devEnvProducerShellOps(pins).len == 0
    check devEnvProducerNotices(pins).len == 0

  test "a lock-pinned producer with no checkout is reported, never fetched":
    checkpoint("mutation: calling producerSourceRoot with " &
      "fetchMissingPinnedSource = true makes the cache root appear and this " &
      "case fails on the filesystem assertion, not on the classification")
    let scratch = scratchRoot("nofetch")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    createDir(consumer)
    writeLockPin(consumer)

    let pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
      consumer)
    let pin = pins.pinFor(producerName)
    checkpoint("state=" & $pin.state)
    check pin.state == deppNoSource
    check devEnvProducerShellOps(pins).len == 0
    check devEnvProducerNotices(pins).len == 1

    # The load-bearing assertion: an activation must not perform a network
    # operation. The revision-keyed tree the build would clone into must still
    # not exist.
    let cacheRoot = consumer / ".repro" / "cross-repo-producers"
    checkpoint("cross-repo-producers exists=" & $dirExists(cacheRoot))
    check not dirExists(cacheRoot)

  test "an already-fetched lock-pinned revision tree binds":
    checkpoint("mutation: probing only the workspace sibling and not the " &
      "revision-keyed cache root makes this case report deppNoSource")
    let scratch = scratchRoot("fetched")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    createDir(consumer)
    writeLockPin(consumer)
    # Exactly where ``fetchLockPinnedProducer`` puts a verified checkout:
    # ``<workspace>/.repro/cross-repo-producers/<name>/<revision>``. Reading
    # the same location the build writes is what makes "built once, then bound
    # by every shell" true rather than aspirational.
    let fetched = consumer / ".repro" / "cross-repo-producers" /
      producerName / pinnedRevision
    createDir(fetched)
    writeFile(fetched / "repro.nim", "package prod:\n  discard\n")
    materializeProducerOutput(fetched, addFileExt(producerName, ExeExt))

    let pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
      consumer)
    let pin = pins.pinFor(producerName)
    checkpoint("state=" & $pin.state & " binDir=" & pin.binDir)
    check pin.state == deppBound
    check normalizedPath(pin.binDir) ==
      normalizedPath(fetched / "build" / "bin")
    check devEnvProducerShellOps(pins).prependedPaths() == @[pin.binDir]

  test "a broken develop override is reported, not raised":
    checkpoint("mutation: removing the try/except around " &
      "resolveProducerBinding makes this case raise out of devEnvProducerPins")
    let scratch = scratchRoot("broken")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    createDir(consumer)
    # The override names a checkout that is not on disk.
    # ``resolveProducerBinding`` deliberately re-raises rather than silently
    # falling back to a lock pin. On a BUILD that is correct: fail the build.
    # On an activation it must not be: a broken pin must cost the developer
    # the pin, not the shell.
    writeOverride(consumer, [(producerName, "../absent-checkout")])

    var pins: seq[DevEnvProducerPin]
    try:
      pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
        consumer)
    except CatchableError as err:
      checkpoint("raised: " & err.msg)
      fail()
    let pin = pins.pinFor(producerName)
    checkpoint("state=" & $pin.state & " detail=" & pin.detail)
    check pin.state == deppUnresolvable
    check pin.detail.len > 0
    check devEnvProducerShellOps(pins).len == 0
    check devEnvProducerNotices(pins).len == 1

  test "declaration order survives the prepend reversal":
    checkpoint("mutation: emitting the bound pins in forward order makes the " &
      "SECOND declared pin win the PATH search and this case fails")
    let scratch = scratchRoot("order")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    let first = absolutePath(scratch / producerName)
    let second = absolutePath(scratch / otherProducerName)
    createDir(consumer)
    for root, name in [(first, producerName), (second, otherProducerName)].items:
      createDir(root)
      writeFile(root / "repro.nim", "package p:\n  discard\n")
      materializeProducerOutput(root, addFileExt(name, ExeExt))
    writeOverride(consumer, [
      (producerName, "../" & producerName),
      (otherProducerName, "../" & otherProducerName)])

    let pins = devEnvProducerPins(
      artifactDeclaring(consumer, [producerName, otherProducerName]), consumer)
    check pins.len == 2
    check pins[0].selector == producerName
    check pins[1].selector == otherProducerName

    # ``deskPrependPath`` applies sequentially, so the LAST op emitted ends up
    # FIRST on PATH. Emitting the bound pins in reverse is what makes the
    # resulting PATH order match the declaration order.
    let ordered = devEnvProducerShellOps(pins).prependedPaths()
    checkpoint("emitted prepend order=" & $ordered)
    check ordered.len == 2
    check normalizedPath(ordered[^1]) == normalizedPath(pins[0].binDir)
    check normalizedPath(ordered[0]) == normalizedPath(pins[1].binDir)

  test "the producer's own interface supplies a binary name unequal to the selector":
    checkpoint("mutation: dropping producerInterfaceExecutableNames and " &
      "probing only the selector name reports deppNotBuilt here — the exact " &
      "false negative the workspace pin `uses: \"reprobuild\"` would hit, " &
      "since it produces `repro`")
    let scratch = scratchRoot("namemap")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    let producer = absolutePath(scratch / "prod")
    createDir(consumer)
    createDir(producer)
    writeFile(producer / "repro.nim", "package prod:\n  discard\n")
    writeOverride(consumer, [(producerName, "../prod")])
    # The producer's binary is NOT named after the selector.
    const producedBinary = "prodtool"
    materializeProducerOutput(producer, addFileExt(producedBinary, ExeExt))
    check not fileExists(producer / "build" / "bin" /
      addFileExt(producerName, ExeExt))
    check not fileExists(producer / "build" / "bin" / producerName)

    # The mapping selector -> binary name lives in the producer's interface.
    # A previous ``repro build`` leaves that interface next to the producer's
    # materialized output; the pass reads that copy instead of compiling one,
    # which is what keeps the activation free of a provider compile.
    let ifaceDir = consumer / ".repro" / "build" / "default" /
      "cross-repo-producers" / producerName
    createDir(ifaceDir)
    var producerInterface = ProjectInterfaceArtifact()
    producerInterface.projectInterface.projectName = producerName
    producerInterface.projectInterface.publicExecutables.add(
      InterfaceExecutable(exportName: producedBinary,
        binaryName: producedBinary))
    producerInterface.interfaceFingerprint =
      interfaceFingerprint(producerInterface.projectInterface)
    writeInterfaceArtifact(ifaceDir / "producer-interface.rbsz",
      producerInterface)
    # Guard the fixture itself: an artifact the reader rejects would make this
    # case pass for the wrong reason (the fallback name, not the mapping).
    check readInterfaceArtifact(ifaceDir / "producer-interface.rbsz").
      projectInterface.publicExecutables.len == 1

    let pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
      consumer)
    let pin = pins.pinFor(producerName)
    checkpoint("state=" & $pin.state & " bound=" & pin.boundExecutable)
    check pin.state == deppBound
    check normalizedPath(pin.boundExecutable) == normalizedPath(
      producer / "build" / "bin" / addFileExt(producedBinary, ExeExt))
    check devEnvProducerShellOps(pins).prependedPaths() == @[pin.binDir]

  test "a surface that does not bind still says so for a bound pin":
    checkpoint("mutation: returning early for deppBound when " &
      "appliesToPath is false makes dev-env export silent about a pin it " &
      "is not applying")
    let scratch = scratchRoot("nopath")
    defer: removeDir(scratch)
    let consumer = absolutePath(scratch / "consumer")
    let producer = absolutePath(scratch / "prod")
    createDir(consumer)
    createDir(producer)
    writeFile(producer / "repro.nim", "package prod:\n  discard\n")
    writeOverride(consumer, [(producerName, "../prod")])
    materializeProducerOutput(producer, addFileExt(producerName, ExeExt))

    let pins = devEnvProducerPins(artifactDeclaring(consumer, [producerName]),
      consumer)
    check pins.pinFor(producerName).state == deppBound
    # On the binding surfaces this pin is silent (asserted in case 1). On the
    # tamper-sealed export surface it is not, because there the pin is
    # materialized and STILL not applied — the developer has to be told which
    # of the two answers they are getting.
    let notices = devEnvProducerNotices(pins, appliesToPath = false)
    check notices.len == 1
    checkpoint(notices[0])
    check notices[0].contains("does not put it on PATH")
    check notices[0].contains("repro shell")
