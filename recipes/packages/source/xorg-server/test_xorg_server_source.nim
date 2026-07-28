import std/[strutils, unittest]

import repro_project_dsl

import ./repro

const ExpectedHash =
  "5051b8a339b9497cb573b57871fa7311a2d55c39c3d1cecd051804bbfe9c18e2"

suite "xorgServerSource from-source recipe":
  test "pins the official X.Org release":
    let spec = registeredFetchSpec("xorgServerSource")
    check spec.url.endsWith("/xserver-xorg-server-21.1.24.tar.gz")
    check spec.hashHex == ExpectedHash
    check spec.extractStrip == 1

  test "declares local seat integration dependencies":
    let deps = registeredBuildDeps("xorgServerSource")
    check "systemd" in deps
    check "libdrm >=2.4.110" in deps
    check "libpciaccess" in deps
