## The one pinned Linux x86_64 C toolchain archive, shared by every package
## that is a view of it (``gcc`` realizes its driver, ``ar`` its archiver).
##
## WHAT IT IS. Bootlin's ``x86-64--glibc--stable-2026.08-1``
## (https://toolchains.bootlin.com, built with Buildroot): GCC 15.3.0,
## GNU Binutils 2.45.1 and glibc 2.44 for the ``x86_64-buildroot-linux-gnu``
## target. Bootlin publishes the SHA-256 beside the archive
## (``.../tarballs/x86-64--glibc--stable-2026.08-1.sha256``); the value below
## is that one, and the bytes fetched on 2026-11-14 matched it.
##
## WHY A DYNAMICALLY LINKED GLIBC TOOLCHAIN. The monitor enters a program
## through ``LD_PRELOAD``, which needs a dynamic loader: a statically linked
## toolchain builds correctly but none of its monitored edges (archive,
## link) can be recorded. Bootlin's host programs are dynamically linked
## against glibc and ask for ``/lib64/ld-linux-x86-64.so.2``, which NixOS
## does not have; the archive also carries glibc 2.44 in its sysroot. So
## realization relocates it (``elfInterpreter`` / ``elfRunpath`` /
## ``elfPatchDirs`` on the arm): every host program's ``PT_INTERP`` becomes
## the sysroot's loader in the realized prefix and every dynamically linked
## file's ``DT_RPATH`` gains the sysroot's library directory, so the
## toolchain runs on any Linux x86_64 host, reads its C library from inside
## the store root, and the monitor shim (which needs ``GLIBC_2.34``) loads
## into it. The toolchain's programs find each other and their private
## ``libgmp`` / ``libmpfr`` / ``libmpc`` through their own ``$ORIGIN``
## run paths, which the relocation keeps.
##
## WHAT IT MEANS FOR A CONSUMER. Objects and archives are ordinary x86_64
## ELF. ``gccLinkSpecs`` makes the driver link a dynamically linked
## executable against the realized loader and C library (``-dynamic-linker``
## and ``-rpath`` into the prefix), so the executable runs on this host; it
## carries the store path, so it is not shareable across hosts. ``-static``
## links use the sysroot's static glibc. ``-shared`` links are left as GCC
## makes them.
##
## LAYOUT, after ``stripComponents = 1``: ``bin/x86_64-buildroot-linux-gnu-*``
## (the ``-gcc`` name is a symbolic link to Buildroot's
## ``toolchain-wrapper``, which execs ``<name>.br_real``; the declared
## executable is the real driver, ``...-gcc.br_real``, aliased as ``gcc``,
## because the wrapper derives the program it runs from its own name and a
## copy named ``gcc`` would look for ``gcc.br_real``), the unprefixed
## binutils in ``x86_64-buildroot-linux-gnu/bin``, ``cc1`` / ``collect2`` /
## ``liblto_plugin.so`` in ``libexec/gcc/x86_64-buildroot-linux-gnu/15.3.0``,
## the host libraries and the BFD plugins in ``lib`` (``lib64`` is a link to
## it), and the target sysroot, glibc included, in
## ``x86_64-buildroot-linux-gnu/sysroot`` (its ``lib64`` is a link to
## ``lib``). The real driver locates its sysroot relative to itself
## (``-print-sysroot`` names ``bin/../x86_64-buildroot-linux-gnu/sysroot``),
## so it searches the same headers and libraries the wrapper's
## ``--sysroot`` names.
##
## THE WRAPPER'S DEFAULTS ARE KEPT. Besides ``--sysroot``, the wrapper of
## this build adds hardening defaults to every command line (measured
## 2026-11-15 with ``BR2_DEBUG_WRAPPER=1``, which prints the command it
## runs): ``-fstack-protector-strong`` always; ``-fPIE`` and ``-pie`` unless
## the command line has ``-fno-pie``, ``-fno-PIE``, ``-no-pie``, ``-static``,
## ``-r``, ``-D__KERNEL__`` or ``-D__UBOOT__`` (``-fPIE`` also not with
## ``-fpic`` / ``-fPIC`` / ``-fpie`` / ``-fPIE``, ``-pie`` also not with
## ``-shared``); ``-Wl,-z,now -Wl,-z,relro`` unless ``-D__KERNEL__`` /
## ``-D__UBOOT__``. Bypassing the wrapper without them would silently build
## unhardened code that the same archive builds hardened when used as its
## vendor documents. ``LinuxToolchainGccSpecDefaults`` writes the same
## defaults into the driver's specs, as GCC spec conditionals: the compile
## options into ``cc1`` and the ``-z`` options into ``link`` (both come before
## the user's own options, as the wrapper's prepended ones do, so a later
## user option still wins), and ``-pie`` into ``self_spec`` (a driver option:
## it also selects ``Scrt1.o`` and ``crtbeginS.o``). One difference remains:
## the wrapper also skips PIE for ``-Wl,-r``, which a spec cannot see (the
## driver hands ``-Wl,`` options to the linker unparsed); ``-r`` is the
## partial-link spelling GCC documents and is honoured.
##
## One URL, digest and lock identity for every view, so a lock pins the
## archive once (the WinLibs pin follows the same rule).
const
  LinuxToolchainX64Url* = "https://toolchains.bootlin.com/downloads/releases/toolchains/x86-64/tarballs/x86-64--glibc--stable-2026.08-1.tar.xz"
  LinuxToolchainX64Sha256* = "cde893afab04ac7dcd15c46aac214ff550441b982536124c88a71146a0eeedd3"
  LinuxToolchainX64PackageId* = "gcc-x86_64-buildroot-linux-gnu@15.3.0"
  LinuxToolchainX64LockIdentity* = "tarball:gcc-x86_64-buildroot-linux-gnu@15.3.0:sha256:cde893afab04ac7dcd15c46aac214ff550441b982536124c88a71146a0eeedd3"
  LinuxToolchainGccVersion* = "15.3.0"
  LinuxToolchainBinutilsVersion* = "2.45.1"
  LinuxToolchainGccDriver* = "bin/x86_64-buildroot-linux-gnu-gcc.br_real"
  LinuxToolchainArchiver* = "x86_64-buildroot-linux-gnu/bin/ar"
  LinuxToolchainLoader* = "x86_64-buildroot-linux-gnu/sysroot/lib/ld-linux-x86-64.so.2"
    ## The sysroot glibc's loader, the ``PT_INTERP`` relocation gives every
    ## host program and the ``-dynamic-linker`` of a linked executable.
  LinuxToolchainRuntimeDir* = "x86_64-buildroot-linux-gnu/sysroot/lib"
    ## The sysroot glibc's library directory, added to ``DT_RPATH``.
  LinuxToolchainPatchDirs* = ["bin", "libexec", "lib",
    "x86_64-buildroot-linux-gnu/bin"]
    ## Every directory holding host programs or the shared objects they load
    ## (``liblto_plugin.so`` in ``libexec``, the BFD plugins ``ar`` loads in
    ## ``lib/bfd-plugins``). Not the sysroot: its files are the target's C
    ## library, read by links.
  LinuxToolchainGccSpecs* = "lib/gcc/x86_64-buildroot-linux-gnu/15.3.0/specs"
  LinuxToolchainNoPie = "%{!fno-pie:%{!fno-PIE:%{!no-pie:%{!static:%{!r:" &
    "%{!D__KERNEL__:%{!D__UBOOT__:"
  LinuxToolchainNoPieEnd = "}}}}}}}"
  LinuxToolchainGccSpecDefaults* = [
    "cc1:-fstack-protector-strong " & LinuxToolchainNoPie &
      "%{!fpic:%{!fPIC:%{!fpie:%{!fPIE:-fPIE}}}}" & LinuxToolchainNoPieEnd,
    "link:%{!D__KERNEL__:%{!D__UBOOT__:-z now -z relro}}",
    "self_spec:%{!shared:" & LinuxToolchainNoPie & "-pie" &
      LinuxToolchainNoPieEnd & "}"]
    ## The defaults Buildroot's ``toolchain-wrapper`` adds for this build,
    ## as GCC spec text for the specs file ``gccLinkSpecs`` writes (see
    ## "THE WRAPPER'S DEFAULTS ARE KEPT" above;
    ## https://gcc.gnu.org/onlinedocs/gcc/Spec-Files.html).
