## DSL-port M9.R.15p.2 — stdlib provisioning stub for ``libltdl``.
##
## libltdl is the dynamic-module loader library (libtool's ``ltdl.h`` +
## ``-lltdl``) that autotools projects link against when they need to
## ``dlopen``-style load plugins portably. libcanberra's configure
## script hardcodes ``AC_CHECK_LIB([ltdl], [lt_dladvise_init])`` as a
## mandatory probe (configure.ac:144) and aborts with "Unable to find
## libltdl." when the library is missing.
##
## nixpkgs's ``libtool`` derivation ships libltdl in its multi-output
## ``lib`` output:
##   /nix/store/<hash>-libtool-2.5.4-lib/lib/libltdl.so
##   /nix/store/<hash>-libtool-2.5.4-lib/lib/libltdl.so.7
##   /nix/store/<hash>-libtool-2.5.4-lib/include/ltdl.h
## The ``^*`` suffix asks nix to realize ALL outputs so the resolver's
## multi-output walk (M9.R.14f.10 in resolveNixTool) finds both the
## ``libltdl.so`` library AND its companion ``ltdl.h`` header.
##
## TODO(M9.R.10b+): widen the channel set (scoop on Windows, tarball
## as a universal fall-through). Until then the stub keeps the audit
## test green by registering the name + a single nix channel.

import repro_project_dsl

package `libltdl`:
  provisioning:
    nixPackage "nixpkgs#libtool^*", executablePath = "lib/libltdl.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
