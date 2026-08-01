import std/[strutils, unittest]
import repro_project_dsl
import ./repro

suite "nsprSource source recipe":
  test "pins the verified Mozilla release":
    let spec = registeredFetchSpec("nsprSource")
    check spec.url.endsWith("nspr-4.36.tar.gz")
    check spec.hashHex == "55dec317f1401cd2e5dba844d340b930ab7547f818179a4002bce62e6f1c6895"
  test "registers all NSPR runtime libraries":
    check registeredArtifacts("nsprSource").len == 3
