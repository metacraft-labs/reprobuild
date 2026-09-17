## ``postgresql`` — the database the commercial platform workspace's
## forced-RLS suites need.
##
## This is the package behind ``scripts/with-ephemeral-postgres.sh``. Without
## it the ``*_pg`` cases skip, which means the row-level-security behaviour
## they exist to prove goes unverified while the suite still reports green.
##
## **The Windows archive is the EnterpriseDB binaries zip**, not a GitHub
## release: PostgreSQL publishes no first-party Windows binary tarball, and
## EDB's "binaries" zip is the artifact every Windows toolchain uses. It
## carries a ``pgsql/`` wrapper holding ``bin/``, ``lib/`` and ``share/``,
## which the server resolves relative to itself, so stripComponents=1
## flattens the wrapper and keeps that tree intact.
##
## The version is EDB's compound ``<pgversion>-<build>`` tag rather than a
## plain PostgreSQL version.
##
## **What the prunes drop.** EDB's zip is an installer payload, not a server
## distribution: of its 820 MB, 671 MB is pgAdmin 4 — an Electron desktop
## admin client — and another 17 MB is StackBuilder plus the HTML manual.
## The server, the client binaries and the extension libraries together are
## about 130 MB. A dev environment starts ``postgres.exe`` from a script and
## talks to it with ``psql``; it never opens a GUI. Keeping the GUI cost
## every consumer 671 MB of store and pushed the packed prefix past the
## shared cache's publish limit, so the package could not be published at
## all and every machine had to fetch the 300 MB zip from EDB itself.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

const PostgresqlVersion = "16.14-1"

package postgresql:
  provisioning:
    nixPackage "nixpkgs#postgresql", executablePath = "bin/postgres",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash

    tarball url = "https://get.enterprisedb.com/postgresql/postgresql-" &
        PostgresqlVersion & "-windows-x64-binaries.zip",
      sha256 = "98af1417ba6a8dc30543e560e5407833a3b9e7cc7ed20e73b2006f3aa2f04663",
      archiveType = "zip",
      stripComponents = 1,
      prune = "pgAdmin 4",
      prune = "StackBuilder",
      prune = "doc",
      executablePath = "bin/postgres.exe",
      packageId = "postgresql@" & PostgresqlVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:postgresql@" & PostgresqlVersion &
        ":windows-x86_64:sha256:98af1417ba6a8dc30543e560e5407833a3b9e7cc7ed20e73b2006f3aa2f04663"
