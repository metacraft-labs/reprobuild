# Reprobuild

> **Status:** Planning — Architecture design phase

**Reprobuild** (CLI: `repro`) is a unified build system combining reproducible environments, automatic dependency discovery, incremental rebuilds with artifact caching, and distributed execution.

## Key Ideas

- **Forward-pass build language**: Running a tool automatically records what it reads — no manual dependency declarations needed.
- **Sandbox-based dependency tracking**: Uses FUSE-based file access monitoring to discover actual inputs and outputs.
- **Two-phase caching** (inspired by BuildXL): Weak fingerprint for candidate lookup, strong fingerprint incorporating observed inputs for cache hits.
- **Content-addressed store**: All artifacts stored by content hash, enabling deduplication and parallel multi-version installation.
- **Distributed execution**: Implements the [Remote Execution API](https://github.com/bazelbuild/remote-apis) for local, LAN, and cloud builds.
- **Declarative resource management**: Manages external resources (databases, caches, cloud services) with Terraform-like plan/apply lifecycle.

## Design Documents

See [reprobuild-specs](https://github.com/metacraft-labs/reprobuild-specs) for detailed architecture and specifications.

## License

MIT
