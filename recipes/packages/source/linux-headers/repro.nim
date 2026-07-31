## Linux userspace API headers built from the official kernel source release.
##
## glibc headers include Linux UAPI definitions such as linux/limits.h.
## Keeping the exported header tree in the source suite prevents C packages
## from relying on a host or Nix-provided kernel-headers prefix.

import repro_project_dsl

package linuxHeadersSource:
  versions:
    "6.6.142":
      sourceRevision = "v6.6.142"
      sourceUrl = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz"
      sourceRepository = "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"

  fetch:
    url: "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.142.tar.xz"
    sha256: "b2f6607a75cd27b2e368cf2d25e1637e1e0da9dfed4cda536658879eee6f2b70"
    extractStrip: 1

  nativeBuildDeps:
    "gcc >=11"
    "make >=4.3"

  executable `linux-headers`:
    build:
      shell "make -C $extracted ARCH=x86_64 uapi-asm-generic && CPATH=\"$extracted/include/uapi:$extracted/arch/x86/include/uapi:$extracted/arch/x86/include/generated/uapi${CPATH:+:$CPATH}\" make -C $extracted ARCH=x86_64 headers_install INSTALL_HDR_PATH=$out"
      shell "mkdir -p $out/bin; printf '#!/bin/sh\necho \"$(CDPATH= cd -- \"$(dirname -- \"$0\")/../include\" && pwd)\"\n' > $out/bin/linux-headers; chmod +x $out/bin/linux-headers"

  runtimeDeps:
    discard
