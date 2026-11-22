## The decision `requireTrustedRecipeConfiguration` applies to each
## configuration file above a recipe (`recipeConfigEntryRefusal`), over the
## owners and modes that a test cannot stage on a real file system without
## privilege: files and directories another account owns. The cases this
## user CAN stage are exercised end to end, through both recipe compiles, in
## `t_recipe_configuration_above_the_recipe_must_be_trusted.nim`.
##
## No mocks: the decision is a pure function of `stat` facts, called with
## them directly, and the store-object test is a pure function of the
## path.

import std/[strutils, unittest]

import repro_interface_artifacts

suite "the decision over another account's files and directories":
  const Me = 1000
  const Other = 1001
  test "a file another account owns is refused, wherever it is":
    check recipeConfigEntryRefusal(Other, 0o644, false, 0, 0o1777, false,
      Me) == "it belongs to another account"
    check recipeConfigEntryRefusal(Other, 0o644, false, Me, 0o755, false,
      Me) == "it belongs to another account"
  test "a file in a directory another account owns is refused":
    check recipeConfigEntryRefusal(Me, 0o644, false, Other, 0o755, false,
      Me).contains("belongs to another account")
    check recipeConfigEntryRefusal(Me, 0o644, false, Other, 0o1777, false,
      Me).contains("belongs to another account")
  test "group write is refused unless the group is this user's private one":
    check recipeConfigEntryRefusal(Me, 0o664, false, Me, 0o755, false,
      Me) == "it is writable by other accounts"
    check recipeConfigEntryRefusal(Me, 0o664, true, Me, 0o755, false,
      Me) == ""
    check recipeConfigEntryRefusal(Me, 0o644, false, Me, 0o775, false,
      Me).contains("not sticky")
    check recipeConfigEntryRefusal(Me, 0o644, false, Me, 0o775, true,
      Me) == ""
  test "root's files and directories, and a sticky directory, are trusted":
    check recipeConfigEntryRefusal(0, 0o644, false, 0, 0o755, false,
      Me) == ""
    check recipeConfigEntryRefusal(Me, 0o644, false, 0, 0o1777, false,
      Me) == ""
    check recipeConfigEntryRefusal(0, 0o644, false, 0, 0o1777, false,
      Me) == ""

suite "a file inside a Nix store object is admitted, one directly in the store is not":
  test "below an entry of the store directory":
    check recipeConfigInsideStoreObject(
      "/nix/store/0000000000000000000000000000000a-src/config.nims",
      "/nix/store")
    check recipeConfigInsideStoreObject(
      "/nix/store/0000000000000000000000000000000a-src/a/b/nim.cfg",
      "/nix/store/")
  test "directly in the store directory, or outside it":
    check not recipeConfigInsideStoreObject("/nix/store/config.nims",
      "/nix/store")
    check not recipeConfigInsideStoreObject(
      "/nix/store/0000000000000000000000000000000a-config.nims", "/nix/store")
    check not recipeConfigInsideStoreObject("/nix/storefront/x/config.nims",
      "/nix/store")
    check not recipeConfigInsideStoreObject("/tmp/x/config.nims",
      "/nix/store")
    check not recipeConfigInsideStoreObject("/x/config.nims", "/")
    check not recipeConfigInsideStoreObject("/nix/store/x/config.nims", "")

when defined(posix):
  # Separators and roots are spelled the POSIX way.
  suite "the files Nim reads beside the recipe are examined too":
    test "nim.cfg, config.nims and the recipe's own <name> files":
      # A path that does not exist, so no symbolic link is resolved and the
      # answer is a function of the path alone.
      check recipeConfigProjectFiles(
        "/nonexistent-recipe-config-root/project/repro.nim") == @[
          "/nonexistent-recipe-config-root/project/nim.cfg",
          "/nonexistent-recipe-config-root/project/config.nims",
          "/nonexistent-recipe-config-root/project/repro.nimcfg",
          "/nonexistent-recipe-config-root/project/repro.nim.cfg",
          "/nonexistent-recipe-config-root/project/repro.nims"]
