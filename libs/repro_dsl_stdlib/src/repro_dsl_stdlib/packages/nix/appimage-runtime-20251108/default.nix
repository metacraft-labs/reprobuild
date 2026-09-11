# The AppImage TYPE-2 RUNTIME, realized through the NIX provisioning
# channel.
#
# ## Why this file exists -- M1's N29, second half
#
# Giving `appimagetool` a nix channel moved the `--tool-provisioning=nix`
# failure exactly one tool along::
#
#   tool-resolution failed: package "appimage-runtime" requested by uses
#   "appimage-runtime" does not declare provisioning: nixPackage metadata
#
# Same shape, same reason, same fix. Both are needed for the dogfood
# distribution to resolve under nix at all, because tool resolution is a
# property of the WHOLE graph.
#
# ## Why not nixpkgs
#
# For the same measured reason as `appimagetool`'s: at the canonical pin
# every /[aA]ppimage/ attribute is for CONSUMING an AppImage. The type-2
# runtime is not packaged there under any name.
#
# ## Why this adds no dependency
#
# The URL and the sha256 are `AppImageRuntimeUrl` and
# `AppImageRuntimeSha256` from `packages/appimage_runtime.nim`,
# unchanged: the same 944,632-byte asset, fetched by nix instead of by
# reprobuild.
#
# ## Why a plain copy
#
# The runtime is not executed as a TOOL at all -- the producer passes it
# to `appimagetool --runtime-file` as an INPUT, and appimagetool
# concatenates it in front of the squashfs image. The file's name is part
# of the contract (`AppImageRuntimeFileName`), so it is installed under
# that name, and `executablePath` names it.
let
  pkgs = import ../nixpkgs.nix;
  asset = pkgs.fetchurl {
    url =
      "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64";
    sha256 = "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d";
  };
in
  pkgs.runCommand "reprobuild-appimage-runtime-20251108" { } ''
    mkdir -p $out/bin
    cp ${asset} $out/bin/runtime-x86_64
    chmod 0755 $out/bin/runtime-x86_64
  ''
