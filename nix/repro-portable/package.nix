# `repro-portable`: the whole `reprobuild` closure as ONE self-extracting
# executable, for a host with no /nix/store (a GitHub Actions runner image, a
# plain Debian box). See the `reproPortable` comment in flake.nix for why this
# is a bundle and not a static binary.
#
# The bundle is nix-community/nix-bundle's: an `arx tmpx` shell archive that
# extracts the closure to `$HOME/.cache/tmpx-<hash>/dat`, then a startup script
# that runs `nix-user-chroot -n ./nix -- <repro>`. nix-user-chroot enters a user
# namespace, builds a fresh root, bind-mounts the extracted store at /nix and
# chroots into it, so every baked /nix/store path resolves.
#
# We assemble it from nix-bundle's own pieces instead of calling the stock
# `bundlers.toArx`, because the stock pieces are wrong for a CLI in three ways,
# each invisible to `repro --version` and `repro hooks protocol`:
#
#  1. The new root mirrored a FIXED list of host directories -- /dev /etc /home
#     /proc /root /run /sys /tmp /usr /var -- so /bin, /lib, /lib64, /sbin,
#     /opt, /srv, /mnt and /media did not exist inside it. Every
#     `/bin/sh -c ...` repro spawns (Nim's execCmd*, the hook bodies, `repro ws
#     forall`) failed with ENOENT, which is what broke the managed git hooks on
#     the GARM Linux runner image (infra #2421). nix-community/nix-user-chroot
#     (the Rust rewrite) mirrors all of `/` except /nix; nix-bundle's diverged
#     C++ copy never did.
#  2. nix-user-chroot did `chdir("/")` after the chroot, and arx had already
#     `cd`'d into the extraction directory before the startup script ran, so
#     repro always started in `/` instead of the caller's directory.
#  3. nix-user-chroot did `setenv("PATH", ENV_PATH)` with ENV_PATH defaulting
#     to "", so repro ran with an EMPTY PATH and could not find the host's git.
#
# `nix-user-chroot-host-root.patch` fixes all three in nix-user-chroot itself:
# every top-level host entry except /nix is mirrored (symlinks as symlinks, so
# a merged-/usr host keeps `/bin -> usr/bin`), a new `-w <dir>` option (default:
# the directory it was started in) sets the starting directory inside the
# sandbox, and an empty ENV_PATH keeps the caller's PATH. The archive header
# below records the caller's directory before arx `cd`s away from it, and the
# startup script hands it to `-w`.
#
# `tests/repro-portable-host-root.nix` is the proof, against a host-shaped root
# with no /nix at all, with the stock nix-user-chroot as its negative control.
# Anything that re-enables shipping this bundle (gosti's GOSTI_RUNNER_REPRO,
# infra's runner image) should require that check to pass on the revision it
# ships.
{
  lib,
  pkgs,
  writeScript,
  # nix-community/nix-bundle's source tree (the `nix-bundle` input of
  # NixOS/bundlers, which flake.nix already locks).
  nix-bundle-src,
  reprobuild,
}:
let
  nixBundle = import nix-bundle-src { nixpkgs = pkgs; };

  # The stock helper, kept reachable for the negative control.
  upstreamNixUserChroot = nixBundle.nix-user-chroot;

  nixUserChroot = upstreamNixUserChroot.overrideAttrs (old: {
    name = "nix-user-chroot-2c52b5f-host-root";
    patches = (old.patches or [ ]) ++ [ ./nix-user-chroot-host-root.patch ];
  });

  program = lib.getExe reprobuild;

  # Runs from the extraction directory (`dat`), which is what lets the
  # relative `./nix/store/...` interpreter nix-bundle patches into
  # nix-user-chroot resolve.
  startup = writeScript "startup" ''
    #!/bin/sh
    if [ -n "''${REPRO_PORTABLE_CALLER_CWD:-}" ]; then
      set -- -w "$REPRO_PORTABLE_CALLER_CWD" -- ${program} "$@"
    else
      set -- -- ${program} "$@"
    fi
    unset REPRO_PORTABLE_CALLER_CWD
    exec .${nixUserChroot}/bin/nix-user-chroot -n ./nix "$@"
  '';

  arx = nixBundle.makebootstrap {
    drvToBundle = reprobuild;
    targets = [ startup ];
    startup = ".${builtins.unsafeDiscardStringContext startup} '\"$@\"'";
  };

  # arx's generated header `cd`s into the extraction directory before it runs
  # the startup script and keeps no record of where it was called from, so the
  # caller's directory is captured on the line after the shebang. It is set
  # unconditionally: an inherited value would be a parent's directory, not
  # this invocation's.
  captureLine = "REPRO_PORTABLE_CALLER_CWD=$(pwd) ; export REPRO_PORTABLE_CALLER_CWD";
in
arx.overrideAttrs (old: {
  buildCommand = old.buildCommand + ''
    shebang='#!/bin/sh'
    if [ "$(head -n 1 "$out")" != "$shebang" ]; then
      echo "repro-portable: unexpected arx header: $(head -n 1 "$out")" >&2
      exit 1
    fi
    mv "$out" archive
    {
      printf '%s\n' "$shebang" ${lib.escapeShellArg captureLine}
      tail -c +$(( ''${#shebang} + 2 )) archive
    } > "$out"
    rm archive
    chmod +x "$out"
  '';
  passthru = (old.passthru or { }) // {
    inherit reprobuild nixUserChroot upstreamNixUserChroot;
  };
  meta = (old.meta or { }) // {
    platforms = lib.platforms.linux;
  };
})
