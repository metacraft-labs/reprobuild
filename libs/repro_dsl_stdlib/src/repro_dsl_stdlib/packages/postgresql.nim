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
      executablePath = "bin/postgres.exe",
      packageId = "postgresql@" & PostgresqlVersion,
      cpu = "x86_64",
      os = "windows",
      lockIdentity = "tarball:postgresql@" & PostgresqlVersion &
        ":windows-x86_64:sha256:98af1417ba6a8dc30543e560e5407833a3b9e7cc7ed20e73b2006f3aa2f04663"
