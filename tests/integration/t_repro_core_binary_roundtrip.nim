import std/[os, strutils, tempfiles, unittest]

import blake3
import cbor
import gxhash
import repro_core
import repro_core/paths as corepaths
import repro_domain_types
import repro_hash
import xxh3

proc sid(seed: byte): StableId =
  var bytes: array[16, byte]
  for i in 0 ..< bytes.len:
    bytes[i] = seed + byte(i)
  stableId(bytes)

proc bytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

suite "integration_repro_core_binary_roundtrip":
  test "fixed-schema envelopes round-trip and JSON is inspection-only":
    let tempRoot = createTempDir("repro-core-roundtrip", "")
    defer: removeDir(tempRoot)

    let metadata = cborMap([
      entry("backend", cborText("m6-minimal-cbor")),
      entry("schema", cborUInt(1)),
      entry("stable", cborBool(true))
    ])

    let repo = repositoryValue(RepositoryMetadata(
      repositoryId: sid(1),
      displayName: "primary",
      formatVersion: 1,
      metadata: metadata))

    let depPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormatValidatedByMonitor,
      completeness: decComplete,
      recognizedReports: @[
        RecognizedDependencyReportSpec(
          formatName: DependencyFormatName("make-depfile"),
          outputs: @[
            ExpectedDependencyFile(
              logicalName: "compile-deps",
              path: "build/main.d",
              required: true)
          ])
      ])

    let process = directProcess(
      corepaths.normalizedPath("/usr/bin/cc"),
      ["-c", "src/main.c", "-o", "build/main.o"],
      corepaths.normalizedPath("/workspace/project"),
      [EnvVar(name: "LC_ALL", value: "C")])

    let action = actionValue(ActionSpec(
      actionId: sid(32),
      process: process,
      dependencyPolicy: depPolicy,
      metadata: cborMap([entry("tool", cborText("cc"))])))

    let digest = contentDigestValue(ContentDigestEnvelope(
      digest: casDigest(bytes("object-bytes")),
      size: 12))

    let repoPath = tempRoot / "repo.rbsz"
    let actionPath = tempRoot / "action.rbsz"
    let digestPath = tempRoot / "digest.rbsz"

    writeEnvelope(repoPath, repo)
    writeEnvelope(actionPath, action)
    writeEnvelope(digestPath, digest)

    let rawRepo = readFile(repoPath)
    check rawRepo.len > 4
    check rawRepo[0] != '{'
    check rawRepo[0] != '['
    check rawRepo[0] == 'R'
    check rawRepo[1] == 'B'
    check rawRepo[2] == 'S'
    check rawRepo[3] == 'Z'

    let repoRead = readEnvelope(repoPath)
    let actionRead = readEnvelope(actionPath)
    let digestRead = readEnvelope(digestPath)

    check repoRead == repo
    check actionRead == action
    check digestRead == digest

    let jsonView = toJsonInspection(actionRead)
    check jsonView[0] == '{'
    check jsonView.contains("\"kind\":\"actionSpec\"")
    check jsonView.contains("\"dependencyPolicy\"")

  test "malformed and unknown envelope versions fail closed":
    let value = repositoryValue(RepositoryMetadata(
      repositoryId: sid(9),
      displayName: "bad-version-check",
      formatVersion: 1,
      metadata: cborNull()))
    var encoded = encodeEnvelope(value)
    encoded[4] = 2
    expect EnvelopeError:
      discard decodeEnvelope(encoded)

    expect EnvelopeError:
      discard decodeEnvelope(encoded.toOpenArray(0, 5))

  test "hash implementations and policy domains are real and separated":
    check blake3.toHex(blake3.digest("")) ==
      "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9ad" &
      "c112b7cc9a93cae41f3262"
    check xxh3.value(xxh3.digest64("")) == 0x2d06800538d394c2'u64

    let payload = bytes("same payload")
    let cas = casDigest(payload)
    let action = blake3DomainDigest(payload, hdActionFingerprint)
    let local = localHash(payload)
    let selected = localHashSelection()

    check cas.algorithm == haBlake3_256
    check cas.domain == hdCasContent
    check cas.bytes.len == 32
    check action.algorithm == haBlake3_256
    check action.domain == hdActionFingerprint
    check cas.bytes != action.bytes

    check local.domain == hdLocalInvalidation
    check local.algorithm != cas.algorithm
    check local.algorithm == selected.algorithm
    check selected.algorithm == haXxh3_64
    check selected.implementation == "xxh3"
    check selected.reason.contains("GxHash unavailable")
    check gxhash.isAvailable() == false
