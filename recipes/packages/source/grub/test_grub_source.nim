import std/unittest

import repro_project_dsl
import ./repro

const
  ExpectedUrl = "https://ftp.gnu.org/gnu/grub/grub-2.12.tar.xz"
  ExpectedHash = "f3c97391f7c4eaa677a78e090c7e97e6dc47b16f655f04683ebd37bef7fe0faa"

suite "grubSource from-source recipe":
  test "pins the upstream GRUB release tarball":
    let spec = registeredFetchSpec("grubSource")
    check spec.packageName == "grubSource"
    check spec.url == ExpectedUrl
    check spec.hashHex == ExpectedHash
    check spec.hashAlg == dshaSha256
    check spec.kind == dfkTarball
    check spec.extractStrip == 1

  test "records the upstream release metadata":
    let versions = registeredVersions("grubSource")
    check versions.len == 1
    check versions[0].version == "2.12"
    check versions[0].sourceRevision == "grub-2.12"
    check versions[0].sourceUrl == ExpectedUrl
    check versions[0].sourceRepository ==
      "https://git.savannah.gnu.org/git/grub.git"
