import std/[strutils, unittest]
import repro_core

const
  ExpectedReprobuildVersion = "0.1.3"
  PackageMetadata = staticRead("../../reprobuild.nimble")

proc packageVersionDeclarations(): seq[string] =
  for line in PackageMetadata.splitLines():
    if line.startsWith("version"):
      result.add(line)

suite "Reprobuild version":
  test "release version is exposed by the core library":
    check ReprobuildVersion == ExpectedReprobuildVersion
    check versionString() == ExpectedReprobuildVersion

  test "package metadata declares the release version exactly once":
    check packageVersionDeclarations() ==
      @["version = \"" & ExpectedReprobuildVersion & "\""]
