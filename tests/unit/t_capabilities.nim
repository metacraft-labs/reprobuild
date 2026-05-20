import std/[json, strutils, unittest]

import repro_cli_support

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
    check caps["interfaces"]["hcr"]["profiles"][0]["id"].getStr() ==
      "clang-gcc-debug-patchable-no-lto-v1"
