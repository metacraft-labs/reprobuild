import std/[strutils, unittest]
import repro_project_dsl
import ../nghttp2/repro
import ../libpsl/repro

suite "libsoup source foundations":
  test "pin verified upstream releases":
    check registeredFetchSpec("nghttp2Source").hashHex == "88bb94c9e4fd1c499967f83dece36a78122af7d5fb40da2019c56b9ccc6eb9dd"
    check registeredFetchSpec("libpslSource").hashHex == "1dcc9ceae8b128f3c0b3f654decd0e1e891afc6ff81098f227ef260449dae208"
  test "register both required libraries":
    check registeredArtifacts("nghttp2Source")[0].artifactName == "libNghttp2"
    check registeredArtifacts("libpslSource")[0].artifactName == "libPsl"
