## Smoke test for the from-source ``btrfsProgsSource`` recipe — closes
## M9.R.27 Gap 4.

import std/[unittest]

import repro_project_dsl

import ./repro

const ExpectedUrl =
  "https://www.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v7.0.tar.xz"
const ExpectedHash =
  "c286d6876cbcd72327a0b417e4cfd280353ec23e37b549fdbcd7800a832d9a99"

suite "btrfsProgsSource — from-source recipe smoke test":

  test "fetch spec carries the upstream URL verbatim":
    let spec = registeredFetchSpec("btrfsProgsSource")
    check spec.packageName == "btrfsProgsSource"
    check spec.url == ExpectedUrl

  test "fetch spec hash is a 64-char sha256 hex string":
    let spec = registeredFetchSpec("btrfsProgsSource")
    check spec.hashHex.len == 64
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256

  test "fetch spec is the tarball variant with extractStrip = 1":
    let spec = registeredFetchSpec("btrfsProgsSource")
    check spec.kind == dfkTarball
    check spec.extractStrip == 1
