## Sample ReproOS module: the user list.
##
## Loaded into `reproos-sample-config/configuration.nim` via the
## `imports:` block. The parent file's own `users:` block can
## override individual entries (matched by user name) per the
## last-write-wins merge rule documented in
## `docs/reproos-config-dsl.md`.

system reproosUsersModule:
  users:
    user "root":
      shell = bash
      password_hash = "$y$j9T$root-placeholder-hash"
    user "ada":
      shell = bash
      groups = ["wheel", "audio"]
      home_dir = "/home/ada"
