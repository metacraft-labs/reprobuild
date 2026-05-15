# Database Posture

M0 does not introduce a production database or shared operational data store.
Future persistence code must document ownership, migration, backup, restore,
and benchmark behavior before it becomes a production system of record.

JSON may be emitted for inspection output, diagnostics, or benchmark reports.
It must not become the persistent source of truth for Reprobuild state.
