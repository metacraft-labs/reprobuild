import std/unittest
import repro_core

suite "Reprobuild version":
  test "version is exposed by the core library":
    check versionString() == "0.1.0"
