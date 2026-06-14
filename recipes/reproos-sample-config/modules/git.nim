## Sample ReproOS module: a Tier 3 `git` package via the apt snapshot
## adapter. Composed into the parent via `imports:`.

system reproosGitModule:
  packages = [
    package(apt, "git", snapshot = "debian/bookworm/20260601T000000Z"),
  ]
