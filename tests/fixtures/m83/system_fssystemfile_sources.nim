## Windows-System-Resources Phase A fixture: a system profile that
## exercises ALL THREE of `fs.systemFile`'s content sources (inline
## `content`, controller-side `sourceLocal`, and the URL fetch
## `sourceUrl` + `sha256` pair). Mirrors the shape the production
## `system_windows_runner.nim` profile uses for the actions-runner
## download (URL + pinned digest) alongside an inline `etc` drop-in
## and a controller-side staging file.
##
## The e2e gate compiles + runs this fixture and asserts the emitted
## ProfileIntent JSON carries the matching fields. Nothing is
## downloaded — the URL is a placeholder.

import repro_profile

profile "systemFsFileSources":
  resources:
    fsSystemFile(path = "/etc/hosts.d/local",
      content = "127.0.0.1 dev",
      address = "hostsInline")
    fsSystemFile(
      path = "C:\\actions-runner-cache\\actions-runner-win-x64.zip",
      sourceUrl = "https://github.com/actions/runner/releases/download/" &
                  "v2.335.1/actions-runner-win-x64-2.335.1.zip",
      sha256 = "0123456789abcdef0123456789abcdef" &
               "0123456789abcdef0123456789abcdef",
      address = "actionsRunnerZip")
    fsSystemFile(
      path = "/etc/myapp/config.toml",
      sourceLocal = "/home/zah/profiles/myapp.toml",
      address = "myappConfig")
