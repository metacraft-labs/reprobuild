## How rust-lang's Linux x86_64 toolchain release is relocated when the
## ``tarball`` provisioning realizes it into the store root (the ``rustc``
## and ``cargo`` arms of ``x86_64-unknown-linux-gnu``).
##
## WHY. rust-lang's prebuilt ``rustc``, ``cargo``, ``librustc_driver``,
## ``libLLVM`` and ``rust-lld`` are dynamically linked against glibc and ask
## for the host's loader (``PT_INTERP`` = ``/lib64/ld-linux-x86-64.so.2``).
## NixOS has no such file, and on any other host the toolchain would read the
## host's C library, outside every logical root of the portable cache
## identity, so no edge that runs it could be shared between checkouts. The
## archive carries no C library of its own, so it is relocated onto the one
## the catalog's Linux C toolchain carries: the ``gcc`` package's realized
## prefix (``linux_toolchain_pin``), which a dependency edge of the Rust
## realization puts in the same tool store first. Every program's
## ``PT_INTERP`` becomes that prefix's loader, and every dynamically linked
## file's ``DT_RPATH`` gains the prefix's glibc directory and its host
## library directory (``libz.so.1``, which ``libLLVM`` and ``rust-lld``
## need). The files' own ``$ORIGIN/../lib`` entries stay first, so
## ``rustc`` still finds ``librustc_driver`` beside itself.
##
## WHICH FILES. ``bin`` (``rustc``, ``cargo``, ``rustdoc``, ...),
## ``libexec`` and ``lib``, recursively: ``lib`` holds ``librustc_driver``
## and ``libLLVM``, and below it ``lib/rustlib/<triple>/bin`` holds
## ``rust-lld`` and the ``gcc-ld`` linker shims rustc runs during a link.
## The recursion also reaches the target's ``libstd-*.so`` (used only by a
## ``-C prefer-dynamic`` link); its run path gains the same directories,
## which is where a program the relocated toolchain links finds its C
## library anyway. Static archives (``.rlib``) and objects are not ELF
## shared objects and are left as shipped.
##
## WHAT IT MEANS FOR A LINK. rustc links through ``cc`` on ``PATH``; the
## ``gcc`` arm exports its driver under that name
## (``LinuxToolchainCcAlias``), and the driver's specs give a linked
## executable the realized loader and run path. rust-lang's default for this
## target, ``-fuse-ld=lld`` with its bundled ``rust-lld``, is kept: the
## specs pass ``-dynamic-linker`` and ``-rpath`` to whichever linker runs.

import repro_dsl_stdlib/linux_toolchain_pin

const
  RustLinuxRuntimePackage* = LinuxToolchainRuntimePackage
    ## The package the Rust toolchain's loader and C library come from.
  RustLinuxLoader* = LinuxToolchainLoader
    ## The loader, as a path in that package's prefix.
  RustLinuxRunpath* = LinuxToolchainRuntimeLibDirs
    ## The library directories, as paths in that package's prefix.
  RustLinuxPatchDirs* = ["bin", "lib", "libexec"]
    ## The directories of the Rust archive whose ELF files are rewritten.
