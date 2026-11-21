# Target systems a home export can be evaluated for, and the predicate facts
# each one supplies.
#
# Mirrors `ProfileTargetPlatforms` in
# `libs/repro_profile_compile/src/repro_profile_compile/platforms.nim`, the
# table `repro home export --target` uses. The shared predicate fixtures
# (`tests/fixtures/predicates/cases.json`) list every system and are
# evaluated on both sides for each of them, so a row that differs here fails
# `lib-tests` and `t_builtin_predicate_fixtures` alike.
#
# `wsl` is false for every target: WSL is a fact only the planner running on
# the host knows (spec §Platform-neutral intent).
let
  table = {
    "x86_64-linux" = {
      platform = "linux";
      arch = "x86_64";
    };
    "aarch64-linux" = {
      platform = "linux";
      arch = "arm64";
    };
    "x86_64-darwin" = {
      platform = "macos";
      arch = "x86_64";
    };
    "aarch64-darwin" = {
      platform = "macos";
      arch = "arm64";
    };
    "x86_64-windows" = {
      platform = "windows";
      arch = "x86_64";
    };
    "aarch64-windows" = {
      platform = "windows";
      arch = "arm64";
    };
  };
in
{
  systems = builtins.attrNames table;

  # The facts predicates are evaluated against for `host` on `system`
  # (`targetHostContext`). Throws for a system that is not a target.
  factsFor =
    system: host:
    if table ? ${system} then
      table.${system}
      // {
        inherit host;
        wsl = false;
      }
    else
      throw "reprobuild: unknown target system '${system}' (known: ${builtins.concatStringsSep ", " (builtins.attrNames table)})";
}
