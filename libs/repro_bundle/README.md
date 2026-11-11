# repro_bundle

Workspace bundles: `repro bundle create | publish | restore`. A bundle packs
a workspace selection's Nix dev-shell closure, its source checkouts and its
native store into content-addressed, parallel-downloadable parts, plus a
generated `restore.sh` that a machine without `repro` can run. The design and
the format are in [`docs/workspace-bundles.md`](../../docs/workspace-bundles.md).

| Module | Does |
| --- | --- |
| `repro_bundle.nim` | create, restore (space check, staging, ordering, activation), publish to S3 or GitHub |
| `repro_bundle/select.nim` | resolves a selector through the workspace manifests |
| `repro_bundle/nix_half.nim` | dev-shell closure, `--dump-db` registration, normalised `print-dev-env` |
| `repro_bundle/sources_half.nim` | shallow clones at their workspace paths, checkout state |
| `repro_bundle/github.nim` | the GitHub layout (orphan branches of 20 files), push and raw download |
| `repro_bundle/bootstrap.nim` | renders `restore.sh` |
| `repro_bundle/exec.nim` | runs the host tools (`nix`, `git`, `tar`, `zstd`, `curl`) |

The native-store half is `repro_local_store/store_bundle`.

## Why it is its own library

It sits above the store (`repro_local_store`) and the manifests
(`repro_workspace_manifests`) and below the CLI. The CLI only parses
arguments and supplies the two hooks it owns: resolving the action-cache root
and writing a dev-env allow file.
