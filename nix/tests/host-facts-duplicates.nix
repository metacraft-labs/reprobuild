# One id reported twice on the Nix side of host facts
# (`reprobuild.lib.homeManagerFacts`): entries that agree on every compared
# field are one fact and the first is kept; entries that differ are refused.
# Part of the flake check `lib-host-facts` (nix/tests/host-facts.nix).
#
# reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §Host facts,
# "Schema, version 1" (the logical-id rule, written for either side);
# recorded as reprobuild-pm
# issues/2026-11-18-homemanagerfacts-keeps-the-first-entry-for-a-duplicate-id-without-comparing.md.
#
# Test double, and why: the only duplicate id a Home Manager configuration
# can report with DIFFERING compared fields is two `launchd.agents` sharing
# one `config.Label`, and agents are facts on darwin only. So that the rule
# is checked on every system this check runs on, `homeManagerFacts` is given
# a hand-written value in the shape of a `homeManagerConfiguration` result
# (`pkgs` and the `config` options the producer reads) over this nixpkgs
# instantiated for aarch64-darwin, instead of a Home Manager evaluation.
# Everything under test (`homeManagerFacts`, its launchd and environment
# facts, the merge) is the production code.
{
  pkgs,
  homeManagerFacts,
}:
let
  darwinPkgs = import pkgs.path {
    system = "aarch64-darwin";
    config = { };
    overlays = [ ];
  };
  homeDir = "/Users/gm6";

  facts =
    {
      agents ? { },
      sessionPath ? [ ],
    }:
    homeManagerFacts {
      host = "gm6-host";
      configuration = {
        pkgs = darwinPkgs;
        config = {
          home = {
            homeDirectory = homeDir;
            packages = [ ];
            file = { };
            sessionVariables = { };
            inherit sessionPath;
          };
          xdg.configHome = "${homeDir}/.config";
          launchd.agents = agents;
          # Named by the document's derivation, never built here.
          home-files = "/nix/store/gm6-no-home-files";
        };
      };
    };
  evaluated = args: (facts args).evaluated;
  # Whether the facts derivation itself can be instantiated.
  instantiates = args: (builtins.tryEval (facts args).drvPath).success;

  agent = config: {
    enable = true;
    config = {
      Label = "org.gm6.shared";
      ProgramArguments = [
        "/bin/echo"
        "one"
      ];
      RunAtLoad = true;
    }
    // config;
  };
  services = agents: (evaluated { inherit agents; }).services;
  ids = map (e: e.id);
  fails = x: !(builtins.tryEval (builtins.deepSeq x x)).success;
in
{
  # Vacuity: the double evaluates, and two agents with labels of their own
  # are two facts.
  duplicate-id-control-distinct-labels =
    ids (services {
      a = agent { };
      b = agent { Label = "org.gm6.other"; };
    }) == [
      "launchd:org.gm6.other"
      "launchd:org.gm6.shared"
    ];
  # The same label, every compared field equal: one fact, the first kept.
  duplicate-id-agreeing-keeps-first =
    let
      s = services {
        a = agent { };
        b = agent { };
      };
    in
    ids s == [ "launchd:org.gm6.shared" ] && (builtins.head s).origin == "launchd.agents.a";
  # The same label, another command: the configuration declares two
  # different agents for one fact, so the facts are refused.
  duplicate-id-differing-arguments-refused = fails (services {
    a = agent { };
    b = agent {
      ProgramArguments = [
        "/bin/echo"
        "two"
      ];
    };
  });
  # The refusal is the document's, not only the evaluated half's: the
  # derivation of the agreeing pair instantiates, the differing pair's
  # does not.
  duplicate-id-refusal-reaches-the-derivation =
    instantiates {
      agents = {
        a = agent { };
        b = agent { };
      };
    }
    && !(instantiates {
      agents = {
        a = agent { };
        b = agent { RunAtLoad = false; };
      };
    });
  # ... and so is a difference in any other compared field.
  duplicate-id-differing-run-at-load-refused = fails (services {
    a = agent { };
    b = agent { RunAtLoad = false; };
  });
  duplicate-id-differing-keep-alive-refused = fails (services {
    a = agent { };
    b = agent { KeepAlive = true; };
  });
  # A PATH entry spelled two ways is one id with no compared field: one
  # fact, never a refusal.
  duplicate-id-path-spellings-are-one-fact =
    let
      env =
        (evaluated {
          sessionPath = [
            "$HOME/.local/bin"
            "${homeDir}/.local/bin"
          ];
        }).environment;
    in
    ids env == [ "path:~/.local/bin" ];
}
