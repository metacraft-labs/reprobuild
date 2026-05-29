## M83 Phase A fixture: a home profile that imports a sibling module
## and invokes its `gitDevTooling` template inside the `resources:`
## block. Verifies that sibling imports resolve correctly and that
## user-authored templates can contribute multiple resources.

import repro_profile
import ./modules/git_dev_tooling

profile "homeWithModule":
  activity development:
    git
    gh

  resources:
    gitDevTooling()
