## Which planner applies a resource kind: the home planner (`repro home
## apply`, unelevated, per user) or the system planner (`repro infra apply`,
## elevated, through the privileged-operation broker).
##
## This is the ONE classification both adapters read
## (`adapter_home.profileIntentToHomeProfile`,
## `adapter_system.profileIntentToSystemProfile`). They used to keep two
## lists, `isHomeScopeResource` and `isSystemScopeResource`, that had to stay
## complementary and each silently dropped what it did not list
## (reprobuild-pm spec Gradual-Nix-To-Reprobuild-Migration.md §Principles P6,
## the "resource scope" row: the fix is to delete one implementation, not to
## synchronise the two).
##
## Each adapter refuses, naming the resource, a kind that is not its own
## scope -- a home-scope kind in a system profile, a system-scope kind in a
## home profile -- and a kind this table does not name (`rsUnknown`), rather
## than skipping it (Core-Invariants.md §Unrecognised Input Is Rejected, Not
## Skipped). Every kind a `repro_profile` constructor emits is listed; the
## suite "resource scope: one classification for both planners" in
## `tests/t_smoke_profile_adapter.nim` fails when a constructor's kind is
## missing here.

type
  ResourceScope* = enum
    rsUnknown  ## Not a kind either planner applies.
    rsHome     ## Applied by the home planner.
    rsSystem   ## Applied by the system planner.

proc resourceScope*(kind: string): ResourceScope =
  ## The scope of the resource kind `kind` (the `ResourceIntent.kind`
  ## spelling the `repro_profile` constructors emit).
  ##
  ## `systemd.userUnit` and `launchd.userAgent` are POSIX per-user services
  ## -- home scope. They live under `~/.config/systemd/user/` /
  ## `~/Library/LaunchAgents/` and are reconciled unelevated by
  ## `systemctl --user` / `launchctl bootstrap gui/<uid>`. Their peers
  ## `systemd.systemUnit` and `launchd.systemDaemon` (`/etc/systemd/system/`,
  ## `/Library/LaunchDaemons/`) are elevated: system scope.
  case kind
  of "env.userPath", "env.userVariable", "fs.managedBlock",
     "shell.integration", "windows.registryValueHKCU",
     "windows.startup", "fs.userFile", "vscode.extension",
     "systemd.userUnit", "launchd.userAgent",
     "linux.dconfKey", "linux.kdeConfigKey",
     "pkg.homebrewFormula", "pkg.homebrewCask":
    rsHome
  of "windows.registryValueHKLM",
     "windows.optionalFeature", "windows.capability",
     "windows.service", "windows.scheduledTask",
     "windows.vsInstaller",
     "windows.firewallRule", "windows.acl",
     "macos.systemDefault", "systemd.systemUnit",
     "launchd.systemDaemon", "fs.systemFile", "fs.systemDirectory",
     "env.systemVariable", "passwd.user",
     "os.timezone", "os.hostname",
     "linux.sysctl", "linux.udevRule", "linux.polkitRule",
     "linux.tmpfilesRule", "linux.sudoersRule",
     "passwd.group", "linux.nixDaemonSetting",
     "systemd.systemTimer", "linux.firewallRule",
     "linux.nixosSystemModule", "macos.darwinSystemModule",
     "linux.fhsSandbox":
    rsSystem
  else:
    rsUnknown
