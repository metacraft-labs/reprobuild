# `checks.<linux>.repro-portable-host-root`: the portable bundle on a host
# without /nix. See repro-portable-host-root/run.sh for the root it builds and
# the two runs it makes, and nix/repro-portable/package.nix for the defects the
# negative control reproduces.
#
# bubblewrap and nix-user-chroot each need an unprivileged user namespace; the
# Nix build sandbox provides one to nest in, so this runs as an ordinary build.
{
  lib,
  runCommand,
  bubblewrap,
  pkgsStatic,
  reproPortable,
}:
runCommand "repro-portable-host-root"
  {
    nativeBuildInputs = [ bubblewrap ];
    BUNDLE = reproPortable;
    OLD_NUC = "${reproPortable.upstreamNixUserChroot}/bin/nix-user-chroot";
    REPRO_PROGRAM = lib.getExe reproPortable.reprobuild;
    BUSYBOX = "${pkgsStatic.busybox}/bin/busybox";
    GIT_BIN = "${pkgsStatic.gitMinimal}/bin";
    PROBE = ./repro-portable-host-root/probe.sh;
    meta.platforms = lib.platforms.linux;
  }
  ''
    export BWRAP=${lib.getExe bubblewrap}
    export WORK=$PWD/work
    mkdir -p "$WORK"
    bash ${./repro-portable-host-root/run.sh}
    mkdir -p $out
    cp "$WORK"/positive.log "$WORK"/negative.log $out/
  ''
