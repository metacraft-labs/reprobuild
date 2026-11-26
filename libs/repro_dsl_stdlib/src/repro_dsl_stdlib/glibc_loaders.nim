## Where each glibc target keeps its dynamic loader.
##
## An ELF executable linked against glibc names its loader by absolute path
## in `PT_INTERP`, and the kernel opens that path before the program runs. A
## binary meant for a distribution must name the distribution's loader, not
## the one of the toolchain that linked it (a Nix gcc names a
## `/nix/store/...-glibc-<version>/lib/ld-linux-*.so.*` that no target has).
## This table is the one place that says what the system loader is, by
## target triple and by the architecture names the packaging layer uses.
##
## Every path is glibc's own: the loader's file name is the `ld=` line of
## the port's `shlib-versions`, and its directory is the port's `rtlddir`,
## set by `LIBC_SLIBDIR_RTLDDIR([slibdir], [rtlddir])` in the port's
## `configure.ac` (defaulting to `/lib` in `sysdeps/gnu/configure.ac`).
## glibc links its own programs with
## `-Wl,-dynamic-linker=$(rtlddir)/$(rtld-installed-name)` (`Makeconfig`),
## which is the path every glibc distribution installs. Read from
## https://sourceware.org/git/?p=glibc.git (branch `release/2.42/master`,
## 2026-11-26); the file of each row is cited beside it.

import std/strutils

type
  GlibcLoader* = object
    ## One glibc port's loader.
    path*: string
      ## the absolute path executables name in `PT_INTERP`
    triples*: seq[string]
      ## target triples, in the Rust spelling reprobuild's `--target` takes
    architectures*: seq[string]
      ## the packaging layer's architecture names (`Distribution.architecture`)

const
  GlibcLoaders* = [
    # sysdeps/unix/sysv/linux/x86_64/64/shlib-versions:
    # ld=ld-linux-x86-64.so.2; sysdeps/unix/sysv/linux/x86_64/64/configure.ac:
    # LIBC_SLIBDIR_RTLDDIR([lib64], [lib64]).
    GlibcLoader(path: "/lib64/ld-linux-x86-64.so.2",
      triples: @["x86_64-unknown-linux-gnu"],
      architectures: @["x86_64", "amd64"]),
    # sysdeps/unix/sysv/linux/aarch64/shlib-versions:
    # ld=ld-linux-aarch64.so.1; sysdeps/unix/sysv/linux/aarch64/configure.ac:
    # LIBC_SLIBDIR_RTLDDIR([lib64], [lib]).
    GlibcLoader(path: "/lib/ld-linux-aarch64.so.1",
      triples: @["aarch64-unknown-linux-gnu"],
      architectures: @["aarch64", "arm64"]),
    # sysdeps/unix/sysv/linux/i386/shlib-versions: ld=ld-linux.so.2; no
    # LIBC_SLIBDIR_RTLDDIR of its own, so sysdeps/gnu/configure.ac's
    # ([lib], [lib]).
    GlibcLoader(path: "/lib/ld-linux.so.2",
      triples: @["i686-unknown-linux-gnu", "i586-unknown-linux-gnu"],
      architectures: @["i386", "i686"]),
    # sysdeps/unix/sysv/linux/arm/shlib-versions: ld=ld-linux-armhf.so.3
    # under HAVE_ARM_PCS_VFP (the hard-float ABI); rtlddir as for i386.
    GlibcLoader(path: "/lib/ld-linux-armhf.so.3",
      triples: @["armv7-unknown-linux-gnueabihf",
        "arm-unknown-linux-gnueabihf"],
      architectures: @["armv7l", "armhf"]),
    # The same file: ld=ld-linux.so.3 without HAVE_ARM_PCS_VFP (soft-float).
    GlibcLoader(path: "/lib/ld-linux.so.3",
      triples: @["armv7-unknown-linux-gnueabi", "arm-unknown-linux-gnueabi"],
      architectures: @[]),
    # sysdeps/unix/sysv/linux/riscv/shlib-versions:
    # ld=ld-linux-riscv64-lp64d.so.1 for the lp64d ABI (RV64GC);
    # sysdeps/unix/sysv/linux/riscv/configure.ac, case lp64d-riscv/rv64:
    # LIBC_SLIBDIR_RTLDDIR([lib64/lp64d], [lib]).
    GlibcLoader(path: "/lib/ld-linux-riscv64-lp64d.so.1",
      triples: @["riscv64gc-unknown-linux-gnu"],
      architectures: @["riscv64"]),
    # sysdeps/unix/sysv/linux/powerpc/powerpc64/shlib-versions: ld=ld64.so.2
    # under HAVE_ELFV2_ABI (little-endian ppc64 is ELFv2);
    # sysdeps/unix/sysv/linux/powerpc/powerpc64/configure.ac:
    # LIBC_SLIBDIR_RTLDDIR([lib64], [lib64]).
    GlibcLoader(path: "/lib64/ld64.so.2",
      triples: @["powerpc64le-unknown-linux-gnu"],
      architectures: @["ppc64le", "powerpc64le"]),
    # sysdeps/unix/sysv/linux/s390/s390-64/shlib-versions: ld=ld64.so.1;
    # sysdeps/unix/sysv/linux/s390/s390-64/configure.ac:
    # LIBC_SLIBDIR_RTLDDIR([lib64], [lib]).
    GlibcLoader(path: "/lib/ld64.so.1",
      triples: @["s390x-unknown-linux-gnu"],
      architectures: @["s390x"]),
    # sysdeps/unix/sysv/linux/loongarch/shlib-versions:
    # ld=ld-linux-loongarch-lp64d.so.1 for GRLEN 64 / FRLEN 64;
    # sysdeps/unix/sysv/linux/loongarch/configure.ac:
    # LIBC_SLIBDIR_RTLDDIR([lib64], [lib64]).
    GlibcLoader(path: "/lib64/ld-linux-loongarch-lp64d.so.1",
      triples: @["loongarch64-unknown-linux-gnu"],
      architectures: @["loongarch64"]),
  ]

proc glibcLoaderOfTriple*(triple: string): string =
  ## The system loader of `triple`'s glibc, or "" for a triple the table
  ## does not hold (a musl or non-Linux triple, or a glibc port not listed:
  ## the caller decides whether that is an error).
  for row in GlibcLoaders:
    if triple in row.triples:
      return row.path
  ""

proc glibcLoaderOfArchitecture*(architecture: string): string =
  ## The system loader for a packaging architecture name, or "".
  for row in GlibcLoaders:
    if architecture in row.architectures:
      return row.path
  ""

proc glibcLoaderTriples*(): seq[string] =
  ## Every triple the table holds, in table order (for a refusal's message).
  for row in GlibcLoaders:
    for t in row.triples:
      result.add(t)

proc glibcLoaderSonames*(): seq[string] =
  ## The file name of every loader in the table, once each: the names a
  ## prefix that keeps glibc the target's must not bundle.
  for row in GlibcLoaders:
    let name = row.path.rsplit('/', maxsplit = 1)[^1]
    if name notin result:
      result.add(name)
