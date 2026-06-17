## DSL-port M9.F acceptance — cross-artifact ``toolBuild`` wiring.
##
## Pins the contract for the M9.F consumer-side surface: an artifact's
## ``build:`` block calls ``toolBuild(toolName, inputs, outputPath)`` to
## record that the artifact consumes one or more producer outputs via
## named slots, and emits a new output path of its own.
##
## The ``toolBuild`` helper stands in for v8's
## ``<tool>.build(input1 = expr1, …, output = "…")`` dot-call surface
## without requiring M3's macro layer to parse ``<ident>.build(…)``;
## NDE0-K's kernel rewrite spells the kernel-compile invocation as a
## flat ``toolBuild("kernelCompile", @[("config", outputOf("kernel",
## "configFile"))], "build/bzImage")`` call. The v8 dot syntax is
## DEFERRED — see the section header in ``dsl_port_runtime.nim``.
##
## Fixture shape: one producer artifact (``configFile``) declares an
## output, then one consumer artifact (``bzImage``) wires that output
## into a ``"config"`` input slot AND declares its own ``build/bzImage``
## output. Assertions check the M9.F build-input registry surface AND
## confirm the consumer's output flowed through to the M4 string
## registry so the existing accessors still work.

import std/[unittest]

import repro_project_dsl

package krnlPkg:
  files configFile:
    build:
      discard output("/build/config-used")
  executable bzImage:
    build:
      toolBuild(
        "kernelCompile",
        @[("config", outputOf("krnlPkg", "configFile"))],
        "build/bzImage")

suite "DSL-port M9.F — toolBuild wires consumer build inputs":

  test "build-input registry records exactly one consumer wiring":
    # ``toolBuild`` walks its ``inputs`` argument and calls
    # ``registerBuildInput`` once per ``(slot, producerRef)`` pair.
    # With one pair in the fixture there is exactly one row in the
    # consumer's bucket.
    let inputs = registeredBuildInputs("krnlPkg", "bzImage")
    check inputs.len == 1

  test "build-input row carries the input slot name":
    # ``"config"`` is the slot name the fixture passed as the first
    # element of the ``(slot, producerRef)`` tuple — it survives the
    # round-trip through the registry.
    let inputs = registeredBuildInputs("krnlPkg", "bzImage")
    check inputs[0].inputName == "config"

  test "build-input row carries the producer's package + artifact name":
    # The wiring is a directed edge: the row knows which producer the
    # value came from so a downstream consumer can dereference the
    # producer's registered output path. ``outputOf("krnlPkg",
    # "configFile")`` resolves to the producer fixture's first
    # registered output, so the row's producer fields match.
    let inputs = registeredBuildInputs("krnlPkg", "bzImage")
    check inputs[0].producerPackageName == "krnlPkg"
    check inputs[0].producerArtifactName == "configFile"

  test "build-input row carries the producer's registered path":
    # The producer's first registered output is ``/build/config-used``;
    # ``outputOf`` looked it up at the time the ``toolBuild`` call
    # expanded inside the consumer's build body.
    let inputs = registeredBuildInputs("krnlPkg", "bzImage")
    check inputs[0].producerPath == "/build/config-used"

  test "build-input row carries the consumer's package + artifact name":
    # Even though the registry is keyed by ``(consumerPackage,
    # consumerArtifact)``, the row stamps the consumer identity
    # explicitly so downstream code that iterates the values without
    # remembering the key can still recover the consumer side.
    let inputs = registeredBuildInputs("krnlPkg", "bzImage")
    check inputs[0].consumerPackageName == "krnlPkg"
    check inputs[0].consumerArtifactName == "bzImage"

  test "consumer's tool-build output flows through to M4 string registry":
    # ``toolBuild`` funnels its ``outputPath`` argument through
    # ``output()`` so the M4 string registry observes a row indexed
    # under ``(consumerPackage, consumerArtifact)``. NDE0-K-style
    # downstream code that walks the legacy ``registeredOutputs``
    # accessor MUST still see ``build/bzImage`` against ``bzImage``.
    let outs = registeredOutputs("krnlPkg", "bzImage")
    check outs.len == 1
    check outs[0] == "build/bzImage"

  test "producer's output is unchanged by the consumer-side wiring":
    # Producer's M4 registry row is independent of the wiring; M9.F
    # must not double-count ``configFile``'s registered path.
    let outs = registeredOutputs("krnlPkg", "configFile")
    check outs.len == 1
    check outs[0] == "/build/config-used"

  test "querying an unwired consumer artifact yields the empty seq":
    # Symmetric with the M2/M3/M4 accessor convention: an unregistered
    # ``(consumerPackage, consumerArtifact)`` returns an empty seq
    # rather than raising.
    let unknown = registeredBuildInputs("krnlPkg", "noSuchConsumer")
    check unknown.len == 0
