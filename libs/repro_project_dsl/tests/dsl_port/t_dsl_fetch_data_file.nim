import std/[strutils, unittest]

import repro_project_dsl

package dataFilePkg:
  fetch:
    url: "https://example.com/source.pem"
    sha256: "abc" & repeat("0", 61)
    dataFile: true
    extractStrip: 0

suite "DSL fetch registry data-file mode":

  test "records a verified flat source file":
    let spec = registeredFetchSpec("dataFilePkg")
    check spec.packageName == "dataFilePkg"
    check spec.kind == dfkDataFile
    check spec.url == "https://example.com/source.pem"
    check spec.hashAlg == dshaSha256
    check spec.hashHex == "abc" & repeat("0", 61)
    check spec.gitRevision.len == 0
    check spec.extractStrip == 0
