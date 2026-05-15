# Repository Requirements

Reprobuild implements the Metacraft repository requirements locally through:

- `flake.nix` for dev shells, default package output, and Nix checks.
- `.envrc` using the repository flake.
- `Justfile` targets for build, test, lint, format, version bumping,
  benchmarking, and repomix snapshots.
- `scripts/check_repo_requirements.sh` for the local policy gate.
- `.github/workflows/ci.yml` for parallel lint, test, and Nix build jobs with
  preserved logs.
- `AGENTS.md` as the canonical agent instruction file, with per-tool symlinks.

Workspace source dependencies must be selected by workspace locks. This
repository must not commit `.github/sibling-pins`,
`.github/sibling-pins.json`, `.github/sibling-repos`, or
`.repo-workspaces.env`.
