## Windows-System-Resources Phase D fixture: a system profile that
## exercises the `fs.systemDirectory` ACL APPLY path — every documented
## inheritance variant + the Allow and Deny ACE directions + an
## owner-unset stanza (where the driver skips `takeown` + `icacls
## /setowner` and only stamps the entries / inheritance).
##
## The e2e gate compiles + runs this fixture and asserts the emitted
## ProfileIntent JSON carries the matching `aclOwner` / `aclEntries` /
## `aclInheritance` fields per resource. Nothing is materialized —
## the driver's icacls shell-out is exercised only by the Windows
## integration gate.
##
## Phase A added `system_fssystemfile_sources.nim`, Phase B added
## `system_windowsservice_phaseb.nim`, Phase C added
## `system_windowsscheduledtask.nim`; this fixture is the Phase D
## addition that fills the same per-phase slot in `tests/e2e/m83/`.

import repro_profile

profile "systemFsDirAcl":
  resources:
    # The production actions-runner-tokens directory: SYSTEM as owner,
    # `protected-clear-inherited` for a pinned-explicit DACL (the
    # spec's strict mode), three Allow ACEs covering SYSTEM,
    # Administrators, and NetworkService.
    fsSystemDirectory(
      path = "C:\\actions-runner-tokens",
      acl = ntfsAcl(
        owner = "SYSTEM",
        entries = [
          aclEntry(principal = "SYSTEM", rights = FullControl),
          aclEntry(principal = "BUILTIN\\Administrators",
                   rights = FullControl),
          aclEntry(principal = "NetworkService",
                   rights = ReadAndExecute)],
        inheritance = ProtectedClearInherited),
      address = "runnerTokenDir")

    # A directory whose ACL declares the Deny direction + the
    # `disabled-replace` inheritance mode. The driver routes the Deny
    # ACE through `icacls /deny`; the inheritance mode lowers to
    # `/inheritance:r`.
    fsSystemDirectory(
      path = "C:\\actions-runner-cache",
      acl = ntfsAcl(
        owner = "BUILTIN\\Administrators",
        entries = [
          aclEntry(principal = "BUILTIN\\Administrators",
                   rights = FullControl),
          aclEntry(principal = "Users", rights = ReadAndExecute),
          aclEntry(principal = "Guests", rights = Write,
                   `type` = Deny)],
        inheritance = DisabledReplace),
      address = "runnerCacheDir")

    # Owner-unset: the driver leaves ownership untouched (no
    # `takeown` / `icacls /setowner`); only the entries +
    # `disabled-convert` inheritance mode are applied.
    fsSystemDirectory(
      path = "C:\\repro-managed",
      acl = ntfsAcl(
        entries = [
          aclEntry(principal = "NT AUTHORITY\\SYSTEM",
                   rights = FullControl)],
        inheritance = DisabledConvert),
      address = "reproManagedDir")

    # Inheritance = Enabled — the driver applies the entries but
    # leaves inheritance as the OS default. Used here to exercise the
    # full closed-set vocabulary in one fixture.
    fsSystemDirectory(
      path = "C:\\repro-data",
      acl = ntfsAcl(
        owner = "SYSTEM",
        entries = [
          aclEntry(principal = "SYSTEM", rights = Modify)],
        inheritance = Enabled),
      address = "reproDataDir")
