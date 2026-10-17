# Host selection shared by the Nix readers (`readIntent`'s evaluation in
# intent.nix, `readData` in data.nix): which activities a host enables, and
# when a host is refused. It restates the planner's one rule,
# `enabledActivitiesFor` (`repro_home_apply/plan.nim`), once for Nix:
#
#   * `default` is always enabled; the host's `hosts:` entry adds the rest;
#   * a profile that declares a `hosts:` registry declares every host it may
#     be applied to: a host it does not name is REFUSED, not given `default`
#     alone (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md, Open
#     question 6, answered by GM8; Core-Invariants.md §Unrecognised Input Is
#     Rejected, Not Skipped). The opt-in for `default` alone is an entry
#     naming only `default`;
#   * a profile without a registry (or with an empty one) is host-agnostic:
#     every host gets `default`.
#
# The refusal message carries the same facts as the planner's
# (`EUndeclaredHost`): the host, the declared hosts (sorted), and how to opt
# in.
let
  # Why `host` cannot be selected under `hosts` (the profile's `hosts:` map,
  # host -> activity list), or null.
  undeclaredHostReason =
    hosts: host:
    if hosts == { } || hosts ? ${host} then
      null
    else
      "host `${host}` is not declared in the profile's hosts: registry (declared: ${
        builtins.concatStringsSep ", " (builtins.attrNames hosts)
      }); add an entry for it (`\"${host}\": [default]` selects only the `default` activity) or name a declared host";

  # The activities enabled on `host`: `default` plus its entry. Callers check
  # `undeclaredHostReason` first.
  enabledActivities = hosts: host: [ "default" ] ++ (hosts.${host} or [ ]);
in
{
  inherit undeclaredHostReason enabledActivities;
}
