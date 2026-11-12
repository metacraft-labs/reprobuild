---
title: Tests and certificates
description: How reprobuild runs tests as part of the build graph, splits a suite across machines, and records which content passed which tests.
kind: explanation
persona: build-maintainer
order: 30
verifies:
  commands: [test, test --shard, test --no-certify, build, certify, certify --verify, certificates policy, push, gateway pre-receive, gateway post-receive, gateway migrate]
  tests:
    - tests/integration/t_b3_repro_test_runs_through_engine.nim
    - tests/integration/t_b4_repro_test_alias_covers_all.nim
    - tests/e2e/sharding/t_e2e_repro_test_shard_partition_total_coverage.nim
    - tests/e2e/sharding/t_e2e_repro_test_shard_balances_wall_time.nim
    - tests/integration/t_recertify_is_noop_when_no_executed_function_changed.nim
    - tests/integration/t_certificate_requires_verified_tree.nim
    - tests/integration/t_certificates_travel_with_pushed_commit.nim
    - tests/integration/t_repro_push_certifies_only_content_that_was_not_tested.nim
    - tests/integration/t_gateway_finds_certificates_by_the_pushed_tree.nim
unverified:
  - claim: "A repository states its certificate policy in its project file, and repro certificates policy prints it."
    reason: "Exercised by the shared-policy fixture's cases; this page does not cite one of them by name yet."
    owner: unassigned
  - claim: "repro gateway migrate points the push URL of each repository in a workspace at its gateway."
    reason: "Read from the command's description; no test is cited."
    owner: unassigned
---

# Tests and certificates

This page explains how reprobuild runs a project's tests, how it splits them
across machines, and how it records which content passed them.

## A test is an action in the build graph

A test that a project declares becomes an action in the same build graph as the
code it tests. `repro test` runs the project's `test` collection, and
`repro test <name>` runs one test through the build engine. A test is a build
target as well: `repro build .#test#<name>` runs the same action.

## Splitting a suite across machines

`repro test --shard 2/4` runs the second of four parts of the suite. Run each
part on its own machine and every test runs exactly once: none is left out and
none runs twice. reprobuild sizes the parts by how long each test took before,
so the parts take similar time rather than holding similar numbers of tests.

## A certificate records what passed

A test certificate is a signed record that named tests passed on one platform
against one exact content of the repository. When `repro test` passes and its
preconditions hold, such as a clean working tree, it issues one into your local
certificate store; `--no-certify` turns that off. `repro certify` runs the tests
a certificate requires, for when the certificate is what you want.

A certificate names content, not a commit. A commit whose message you reword
keeps its certificate, and a change to any file needs a new one. Certifying again
when nothing relevant has changed runs no tests: the existing certificate stands.
`repro certify --verify` checks a certificate against the content it names and
refuses one whose bytes were altered.

## Certificates travel with the commit

`repro push` publishes the certificates for the content it pushes. They are
stored as git notes on that content, so whoever fetches the commit can read what
was tested and on which platform. Certificates for several platforms accumulate
on the same commit; one does not replace another.

`repro push` also uses certificates to decide what to test. Content that a
certificate already covers runs no tests. Uncovered content in your working tree
is tested and certified before the push, and an uncovered commit that is not your
working tree's content is refused by name before anything is published.

## Requiring certificates

A repository can require certificates. It states its policy in its project file,
and `repro certificates policy` prints the policy in force. Because a check on
your own machine can be skipped with `git push --no-verify`, the policy is
enforced where the push arrives, by a gateway: a bare repository that you push to
instead of the upstream. Its hooks run `repro gateway pre-receive` and
`repro gateway post-receive`.

The gateway forwards a push to the upstream when the pushed content carries the
certificates the policy asks for. It refuses any other push, and the refusal says
that the pushed content must be the content that was tested.
`repro gateway migrate` points the push URL of each repository in a workspace at
its gateway.

## What this does not cover

- reprobuild has no coverage command.
- A certificate shows that tests passed on the machine that issued it. It does not make a test that depends on the time, the network or chance give the same answer elsewhere.

## Related

- [How reprobuild works](how-reprobuild-works.md)
- [Coming from Bazel and Buck2](../coming-from/bazel-and-buck2.md)
- [Glossary: Test certificate](../reference/glossary.md#test-certificate)
