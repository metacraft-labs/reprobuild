## M83 Phase A fixture: a system profile that declares an
## `fs.systemDirectory` with an inline NTFS ACL. The fixture mirrors
## the production actions-runner-tokens declaration so the e2e gate
## proves the bundled directory + ACL flows through the
## ProfileIntent -> JSON -> parse path.

import repro_profile

profile "systemFsDir":
  resources:
    fsSystemDirectory(path = "/etc/myapp.d", address = "myappDir")
    fsSystemDirectory(
      path = "C:\\actions-runner-tokens",
      acl = ntfsAcl(
        owner = "SYSTEM",
        entries = [
          aclEntry(principal = "SYSTEM", rights = FullControl,
                   `type` = Allow),
          aclEntry(principal = "BUILTIN\\Administrators",
                   rights = FullControl, `type` = Allow),
          aclEntry(principal = "NetworkService",
                   rights = ReadAndExecute, `type` = Allow)
        ],
        inheritance = ProtectedClearInherited),
      address = "runnerTokenDir")
