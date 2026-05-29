## Canonical M83 Phase F1 example: a home profile that composes
## sibling modules.
##
## This file is the entry point reprobuild compiles when the user
## runs ``repro home apply`` on this directory. Two sibling modules
## under ``./modules/`` contribute to it:
##
##   * ``git_dev_environment`` — bundles the git-development packages
##     into the ``develop_software`` activity and registers a git
##     identity in the ``config:`` block.
##   * ``dev_shell`` — bundles a small set of CLI tools into the
##     ``default`` activity.
##
## Both modules are resolved by Nim's normal sibling-import machinery
## (the M83 architectural unlock). The legacy text parsers never saw
## the modules; the compile pipeline does, end-to-end.

import repro_profile
import ./modules/git_dev_environment
import ./modules/dev_shell

profile "homeWithModules":
  activity default:
    developerShell()

  activity develop_software:
    gitDevTooling()

  config:
    gitIdentity(name = "Example User",
      email = "example-user@example.com")

  hosts:
    "example-host": [default, develop_software]
