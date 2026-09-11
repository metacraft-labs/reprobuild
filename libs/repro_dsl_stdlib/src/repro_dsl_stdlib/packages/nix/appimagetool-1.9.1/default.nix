# ``appimagetool``, realized through the NIX provisioning channel.
#
# ## Why this file exists at all -- M1's N29
#
# `--tool-provisioning=nix` could not resolve `appimagetool`, so the
# WHOLE dogfood distribution graph was unbuildable in nix mode, not just
# the AppImage edge: `nixAcquisitionPlan` raises on a package with no
# `nixPackage` entry and tool resolution is a property of the whole
# graph. That had been true since `b3d6117d`, the commit that added the
# AppImage producer.
#
# ## Why it is not `nixpkgs#appimagetool`
#
# There is no such attribute, and this is measured rather than assumed.
# At the canonical pin (`nixpkgs_pin.CanonicalNixpkgsRev`,
# `addf7cf5f383a3101ecfba091b98d0a1263dc9b8`) the attribute names
# matching /[aA]ppimage/ are exactly:
#
#   appimage-run  appimage-run-tests  appimageTools  appimageupdate
#   appimageupdate-qt  cura-appimage  libappimage  session-desktop-appimage
#
# `nix eval` on `appimagetool` answers "Did you mean appimageTools?", and
# `appimageTools` itself exposes only `appimage-exec`,
# `defaultFhsEnvArgs`, `extract`, `extractType1`, `extractType2`,
# `wrapAppImage`, `wrapType1` and `wrapType2` -- every one of them for
# CONSUMING an AppImage. Nothing in that pin BUILDS one.
#
# ## Why this adds no dependency
#
# The URL and the sha256 here are `AppImageToolUrl` and
# `AppImageToolSha256` from `packages/appimagetool.nim`, unchanged: this
# channel realizes THE SAME BYTES the `tarball` channel already
# realizes, through nix's fetcher instead of reprobuild's. The reason
# the seventh pass recorded N29 rather than fixing it was that adding a
# provisioning channel is adding a dependency; an expression that is
# pinned to the identical asset is not.
#
# ## Why a plain copy and not `autoPatchelfHook` or `wrapType2`
#
# The asset is STATICALLY LINKED -- `patchelf --print-interpreter`
# answers "cannot find section '.interp'. The input file is most likely
# statically linked" -- so there is no interpreter to rewrite and no FHS
# to supply. The type-2 runtime finds its own payload from its own image.
# `appimageTools.wrapType2` would wrap it in a `buildFHSEnv`, which needs
# user namespaces at RUN time and would make the tool less usable inside
# a build sandbox, not more.
#
# The producer passes `--appimage-extract-and-run` as argv[1] regardless,
# so no `/dev/fuse` is required of the build host either way.
let
  pkgs = import ../nixpkgs.nix;
  asset = pkgs.fetchurl {
    url =
      "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage";
    sha256 = "ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0";
  };
in
  pkgs.runCommand "reprobuild-appimagetool-1.9.1" { } ''
    mkdir -p $out/bin
    cp ${asset} $out/bin/appimagetool
    chmod 0755 $out/bin/appimagetool
  ''
