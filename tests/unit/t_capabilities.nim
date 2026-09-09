import std/[json, sequtils, strutils, unittest]

import repro_cli_support

proc profileById(caps: JsonNode; id: string): JsonNode =
  for profile in caps["interfaces"]["hcr"]["profiles"].getElems():
    if profile["id"].getStr() == id:
      return profile
  raise newException(ValueError, "missing HCR profile: " & id)

suite "repro capabilities":
  test "public capability query is build-system neutral":
    let caps = capabilitiesJson()

    check caps["schemaId"].getStr() == "reprobuild.capabilities.v1"
    check caps["interfaces"]["capabilityQuery"]["command"].getStr() ==
      "repro capabilities"
    check caps["interfaces"]["hcr"]["decisionAuthority"].getStr() ==
      "reprobuild"
    check caps["interfaces"]["hcr"]["buildSystemRole"].getStr().contains(
      "annotate candidate targets")
    block:
      var hasPriming = false
      for feature in caps["interfaces"]["provider"]["features"].getElems():
        if feature.getStr() == "provider-cache-priming":
          hasPriming = true
      check hasPriming

  test "JSON rendering round-trips":
    let caps = parseJson(renderCapabilitiesJson())

    check caps["interfaces"]["capabilityQuery"]["defaultFormat"].getStr() ==
      "json"
    check caps["interfaces"]["provider"]["metadataVersion"].getInt() == 3
    check profileById(caps, "clang-gcc-debug-patchable-no-lto-v1")[
      "status"].getStr() == "prototype"
    let codetracerProfile =
      profileById(caps, "macos-arm64-direct-hcr-in-codetracer-v1")
    check codetracerProfile["status"].getStr() == "prototype"
    check codetracerProfile["requires"].getElems().anyIt(
      it.getStr() == "hcr-agent-protocol")
    check codetracerProfile["features"].getElems().anyIt(
      it.getStr() == "unix-domain-agent-ipc")
    check codetracerProfile["features"].getElems().anyIt(
      it.getStr() == "coordinator-report-json")
    check codetracerProfile["features"].getElems().anyIt(
      it.getStr() == "repro-hcr-coordinate-command")
    check codetracerProfile["missingComponents"].getElems().len == 0

    # HLX-M0: the Linux ELF/x86_64 direct-patch profile is registered alongside
    # the macOS one, and is honest about what it does NOT yet cover.
    let linuxProfile = profileById(caps, "linux-x86_64-elf-direct-hcr-v1")
    check linuxProfile["status"].getStr() == "prototype"
    check linuxProfile["requires"].getElems().anyIt(
      it.getStr() == "membarrier-private-expedited-sync-core")
    check linuxProfile["features"].getElems().anyIt(
      it.getStr() == "single-aligned-store-e9-rel32-publication")
    check linuxProfile["features"].getElems().anyIt(
      it.getStr() == "single-threaded-only")
    check linuxProfile["rejects"].getElems().anyIt(
      it.getStr() == "multithreaded-targets")
    check linuxProfile["missingComponents"].getElems().len > 0
