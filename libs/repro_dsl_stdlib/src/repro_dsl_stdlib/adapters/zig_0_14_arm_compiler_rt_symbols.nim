## The global symbols zig 0.14.1's compiler-rt for its 32-bit ARM targets
## defines beyond zig 0.13.0's (`zig_0_13_arm_compiler_rt_symbols`): the
## `_BitInt` conversions and division (`__*ei*`, `__divei4`, `__modei4`),
## the bit-reversal helpers and `__truncdfhf2`. zig 0.14.1's archive is
## exactly those 385 plus these 26 (411, the same for
## `arm-linux-gnueabihf.2.38` and `arm-linux-musleabihf`), measured
## 2026-11-16 with `nm -g --defined-only libcompiler_rt.a` of the archive
## zig 0.14.1 (nixpkgs `zig_0_14`) builds for a `zig cc -target <t> -shared`
## link. Without them in the `local:` list a 0.14 link exported all 26
## from every shared library (`nm -D`), which is the failure the list exists
## to prevent.
##
## A name zig 0.13 does not define is harmless in the version script: the
## wrappers link with `--undefined-version`.

const ZigArmCompilerRtSymbolsAddedIn014* = [
  "__bitreversedi2",
  "__bitreversesi2",
  "__bitreverseti2",
  "__divei4",
  "__fixdfei",
  "__fixhfei",
  "__fixsfei",
  "__fixtfei",
  "__fixunsdfei",
  "__fixunshfei",
  "__fixunssfei",
  "__fixunstfei",
  "__fixunsxfei",
  "__fixxfei",
  "__floateidf",
  "__floateihf",
  "__floateisf",
  "__floateitf",
  "__floateixf",
  "__floatuneidf",
  "__floatuneihf",
  "__floatuneisf",
  "__floatuneitf",
  "__floatuneixf",
  "__modei4",
  "__truncdfhf2",
]
