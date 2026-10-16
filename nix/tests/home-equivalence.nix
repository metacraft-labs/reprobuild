# The flake check `lib-home-equivalence`: `reprobuild.lib.homeEquivalenceCheck`
# end to end -- the packaged `repro home facts` of the fixture profile
# (tests/fixtures/host-facts/profile) in the build sandbox, against
# `homeManagerFacts` of a Home Manager configuration written to say the same
# thing, compared by the packaged `repro home compare`.
#
#   * equivalent: the two agree on the profile's packages (bash, cmake, and
#     patchelf on Linux), its `fs.userFile` (`xdg.configFile` on the Nix
#     side), its variable and its stow file (an out-of-store link into the
#     profile on the Nix side, digested through `outOfStoreRoots`). What Home
#     Manager adds on its own is allowlisted, each row with its reason
#     (tests/fixtures/host-facts/equivalence-allow-{linux,darwin}.toml) -- the
#     check must build, and a row matching nothing would fail it as stale;
#   * negative control: the same pair with the variable changed on the Nix
#     side must FAIL (`pkgs.testers.testBuildFailure`), and its log must name
#     the variable as `different` and NOT ALLOWED -- so the success above is
#     the comparison, not a check that cannot fail.
#
# Built on this check's system (the facts of a darwin configuration need a
# darwin builder); `nix flake check --all-systems` evaluates every system.
{
  lib,
  pkgs,
  system,
  homeManager,
  reprobuildLib,
  root,
}:
let
  isLinux = lib.hasSuffix "-linux" system;
  isDarwin = lib.hasSuffix "-darwin" system;
  homeDir = if isDarwin then "/Users/gm6" else "/home/gm6";
  profileDir = root + "/tests/fixtures/host-facts/profile";

  configurationWith =
    editor:
    homeManager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        (
          { config, ... }:
          {
            home = {
              username = "gm6";
              homeDirectory = homeDir;
              stateVersion = "25.05";
              packages = [
                pkgs.bash
                pkgs.cmake
              ]
              ++ lib.optional isLinux pkgs.patchelf;
              sessionVariables.GM6_EDITOR = editor;
              # The stow package, linked the way zah/dotfiles links it.
              file.".gm6rc".source =
                config.lib.file.mkOutOfStoreSymlink "${homeDir}/profile/stow/gm6/.gm6rc";
            };
            xdg.configFile."gm6/app.conf".text = "answer = 42\n";
          }
        )
      ];
    };

  checkWith =
    editor:
    reprobuildLib.homeEquivalenceCheck {
      name = "gm6-home-equivalence-${editor}";
      configuration = configurationWith editor;
      host = "gm6-host";
      inherit profileDir;
      allowlist =
        root + "/tests/fixtures/host-facts/equivalence-allow-${if isDarwin then "darwin" else "linux"}.toml";
      outOfStoreRoots."${homeDir}/profile" = profileDir;
    };

  equivalent = checkWith "nvim";
  diverged = pkgs.testers.testBuildFailure (checkWith "vim");
in
pkgs.runCommand "reprobuild-lib-home-equivalence"
  {
    inherit equivalent diverged;
  }
  ''
    grep -q 'result: 0 difference(s) not allowlisted, 0 stale' "$equivalent/report.txt"
    log="$diverged/testBuildFailure.log"
    grep -q 'different .*var:GM6_EDITOR.*NOT ALLOWED' "$log" || {
      echo "the diverged configuration did not fail on GM6_EDITOR:" >&2
      cat "$log" >&2
      exit 1
    }
    [ "$(cat "$diverged/testBuildFailure.exit")" = 1 ]
    mkdir -p "$out"
    cp "$equivalent/report.txt" "$out/equivalent.txt"
    cp "$log" "$out/diverged.log"
  ''
