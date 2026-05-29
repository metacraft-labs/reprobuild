## M83 Phase A fixture: a minimal system profile with one
## `windows.capability` resource + one `fs.systemFile`. The same
## macro library handles both home and system scopes; the difference
## is the set of resource constructors invoked.

import repro_profile

profile "systemBasic":
  resources:
    windowsCapability(name = "OpenSSH.Server~~~~0.0.1.0")
    fsSystemFile(path = "/etc/hosts.d/local",
      content = "127.0.0.1 dev")
