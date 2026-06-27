let
  pkgs = import ../nixpkgs.nix;
in pkgs.buildNpmPackage {
  pname = "reprobuild-stylus-provisioning";
  version = "1.0.0";
  src = ./.;
  npmDepsHash = "sha256-KdTsfQPnTJMAjqEHqF2ZIarebu3OoeYf1e8qBmWrraw=";
  dontNpmBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/node_modules/reprobuild-stylus-provisioning $out/bin
    cp -R node_modules package.json package-lock.json \
      $out/lib/node_modules/reprobuild-stylus-provisioning/
    ln -s \
      $out/lib/node_modules/reprobuild-stylus-provisioning/node_modules/.bin/stylus \
      $out/bin/stylus
    runHook postInstall
  '';
}
