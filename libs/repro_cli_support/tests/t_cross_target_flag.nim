## `repro build --target`: the spelling, and the platform it publishes under.
##
## ReproOS-Add-On-Mode A15. The flag is the whole of a cross build's
## command-line surface, so the two things it decides are pinned here: what
## `targetTriple` value a spelling assigns (a full triple verbatim; the short
## `<cpu>-<os>` form the milestone writes, `armv7-linux`, expands to the
## catalog's appliance triple -- and that expansion MUST name a row of the
## zig adapter's table, or the short form would select an adapter that does
## not exist), and which platform a build for the triple is published under
## (the CONSUMER's: `armv7 / linux / gnu / ""` for a static-musl binary a
## glibc Raspberry Pi substitutes, because that is the key the Pi's own
## apply derives).
##
## Nothing is mocked: the module under test is pure string logic over the
## catalog's platform vocabulary and the adapter's table.

import std/[strutils, unittest]

import repro_cli_support/cross_target_flag
import repro_dsl_stdlib/adapters/cross_zig

suite "--target spelling":

  test "a full triple is taken as written, lower-cased":
    check canonicalTargetTriple("armv7-unknown-linux-musleabihf") ==
      "armv7-unknown-linux-musleabihf"
    check canonicalTargetTriple("AArch64-Linux-GNU") == "aarch64-linux-gnu"

  test "native assigns nothing":
    check canonicalTargetTriple("native") == ""

  test "every short form expands to a row of the zig adapter's table":
    for (short, full) in ShortTargetAliases:
      check canonicalTargetTriple(short) == full
      check isZigCrossTriple(full)
    check canonicalTargetTriple("armv7-linux") ==
      "armv7-unknown-linux-musleabihf"

  test "an unknown short form and a non-triple are refused by name":
    for bad in ["mips-linux", "armv7", "", "a--b", "a-b-c-d-e"]:
      expect ValueError:
        discard canonicalTargetTriple(bad)
    try:
      discard canonicalTargetTriple("mips-linux")
    except ValueError as e:
      check "mips-linux" in e.msg
      check "armv7-linux" in e.msg

suite "the published platform is the consumer's":

  test "a static-musl armv7 target publishes under the Pi's glibc key":
    let p = consumerPlatformForTarget("armv7-unknown-linux-musleabihf")
    check p.cpu == "armv7"
    check p.os == "linux"
    check p.abi == "gnu"
    check p.libcVariant == ""

  test "the CPU family is the cache's spelling":
    check targetTripleCpu("arm-linux-gnueabihf") == "armv7"
    check targetTripleCpu("aarch64-unknown-linux-musl") == "aarch64"
    check targetTripleCpu("x86_64-unknown-linux-gnu") == "x86_64"
    expect ValueError:
      discard targetTripleCpu("mips-unknown-linux-gnu")

  test "the OS is found wherever the triple puts it":
    check targetTripleOs("aarch64-apple-darwin") == "darwin"
    check targetTripleOs("x86_64-pc-windows-msvc") == "windows"
    check consumerPlatformForTarget("x86_64-pc-windows-msvc").abi == "msvc"
    expect ValueError:
      discard targetTripleOs("riscv64-unknown-elf")
