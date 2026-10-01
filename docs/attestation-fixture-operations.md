# Attestation collateral: keeping a verifier's own inputs current

Four runbooks. They answer four different questions that all come from
the same fact: **a verifier judges machines with dated documents, and
those documents go stale on a schedule nobody in this repository
controls.**

* [A local developer](#a-local-developer) — a gate started failing and
  nothing in the diff touched it.
* [A collateral operator](#a-collateral-operator) — the scheduled drift
  and expiry run is red, and it names artifacts.
* [Incident response](#incident-response) — a vendor revoked something,
  or a root rotated.
* [Verifier policy](#verifier-policy) — what an operator has to decide,
  and what happens if they decide nothing.

A fifth section, [what this corpus is and is not](#what-this-corpus-is-and-is-not),
records the limits, because every one of these runbooks is only as good
as the reader's understanding of what the pinned bytes establish.

---

## The two-clock rule

Every runbook here rests on one distinction, and getting it wrong is the
single most common way to waste an afternoon on this material.

**There are two clocks, and they answer different questions.**

1. **The pinned clock.** Every gate that judges pinned vendor material
   states its own `Now` as a constant. Those gates are testing the
   *evaluator*, not the calendar: a chain that was valid when it was
   captured must still evaluate the same way in five years, or the test
   is a test of the date. A pinned clock is not a workaround and must
   not be "fixed" by replacing it with the wall clock.

2. **The wall clock.** The scheduled collateral run uses it, on purpose,
   because its entire job is to notice that a real document is about to
   stop being usable *today*.

So: a pinned-clock gate failing means the **evaluator or the bytes**
changed. A wall-clock run failing means the **calendar** moved. They
almost never need the same response, and the fix for one is usually
wrong for the other.

The ledger keeps the two honest about each other. Every pinned clock in
the suite is checked to fall inside the validity window of the material
it judges — so refreshing a fixture without moving the clock beside it,
or moving a clock past the material it was chosen for, is a failure with
a name rather than a surprise six months later.

---

## A local developer

### "A gate I did not touch is failing on dates"

Run the ledger gate first. It is hermetic, it uses pinned clocks only,
and it will tell you whether the tree disagrees with itself:

```
repro build '.#test#t_attestation_fixture_lifecycle'
```

Read the failure by which of its suites failed.

| Suite that failed | What it means | What to do |
|---|---|---|
| *the ledger describes the bytes* | A pinned constant's bytes changed, or the ledger's record of them did | Do not edit the ledger to match. Find out which side moved — `git log -p` the corpus module. A digest that changed without a deliberate refresh is a corrupted or mis-transcribed constant |
| *every date is read out of the artifact* | The ledger's recorded window disagrees with the window the bytes state | The ledger was edited by hand. Regenerate it; never transcribe |
| *the ledger is complete* | A corpus constant exists with no ledger row, or a row names a constant that is gone | Add or remove the row. This is the check that stops a corpus growing a member nobody tracks |
| *pinned clocks agree with the material they judge* | A gate's `Now` fell outside the window of the material it judges | Either the fixture was refreshed and the clock was not moved, or a clock was moved past its material. Move the clock to sit inside the new window, and say in the commit which fixture forced it |
| *sanitization* | A private key reached a pinned artifact or a corpus module's source | **Stop and treat it as a disclosure**, not as a test failure. The bytes are in the repository's history from the commit that added them; rotating the key is the remedy, deleting the line is not |
| *the lifecycle decision* | The rules themselves changed | Nothing about fixtures. Read the diff to `repro_attest_verify/lifecycle` |

### "I need to refresh one fixture"

Refreshing a fixture is four steps and the fourth is the one people skip.

1. Re-fetch from the publisher named in the ledger's publisher table.
   That table carries the exact command; it is not prose.
2. Replace the constant. Keep the surrounding provenance comment
   truthful — the observation date in particular.
3. Regenerate the ledger row (digest, size, window). Do not type a
   digest.
4. **Check every pinned clock that judges it.** The ledger gate will
   tell you which, by name. A refreshed CRL with a later `nextUpdate`
   will happily pass a gate whose pinned clock is now *before* its
   `thisUpdate`, and that gate is then testing nothing.

### The review checklist for a new or refreshed fixture

Six questions, in this order. The gate answers four of them; the other
two are the reviewer's, and they are the two that matter most.

1. **Where did it come from, and who else publishes it?** A single
   fetch is a single point of trust. For anything that will be used as
   a *positive* — a root, a chain, a genuine report — require a second
   publisher that does not derive from the first, and record both.
2. **Is it what it claims to be?** Verify it with something other than
   the code under test before that code is pointed at it.
3. Does the ledger row match the bytes? *(gate)*
4. Is the window read out of the artifact rather than typed? *(gate)*
5. Does anything in it carry key material? *(gate)*
6. Does every pinned clock that judges it still sit inside its
   window? *(gate)*

### "Can I just extend the date?"

No, and it is worth knowing why the question does not have a clever
answer. The dates are inside signed documents. Changing one invalidates
the signature, and every one of these gates verifies the signature —
which is the point of them. A fixture whose date you can move is a
fixture that establishes nothing.

---

## A collateral operator

The scheduled run is the only thing in this repository that uses the
wall clock over vendor material, and the only thing that touches the
network.

```
python3 tools/attestation_collateral_monitor.py --ledger-root tests/integration
```

It exits non-zero when anything needs attention and prints one line per
artifact. It never edits the tree.

### Reading its output

Four statuses, and what each asks of you. `current` is the fifth
and is not printed as a finding.

* **`expired`** — the document stopped being usable on a date now in the
  past. Every evaluator in this build refuses on it. Refresh now.
* **`due-for-refresh`** — it is still valid and expires inside the
  horizon (30 days by default). This is the state the tool exists to
  produce: it is a deadline, not an outage, and the whole value is that
  it arrives while there is time.
* **`no-stated-end`** — a revocation list with no `nextUpdate`. This is
  *not* "valid forever": the chain evaluators set such a list aside, so
  a verifier holding only that one cannot ask the revocation question at
  all and will refuse every chain. Treat it as missing collateral.
* **`not-yet-in-force`** — check the machine's clock before touching any
  fixture. A document from the future is nearly always a clock fault.

And for drift, two:

* **`drifted`** — the publisher now serves different bytes for a
  protocol vector, a trust root, or vendor collateral. For collateral
  this is routine (they are reissued on a schedule) and the pin needs
  refreshing. For a **trust root** it is not routine: read
  [incident response](#incident-response) before refreshing anything.
* **`expected-to-differ`** — a live endpoint answered with a different
  document than the one captured. This is not a refutation. A quote is
  minted per request; asking again gets a second one, not a correction
  of the first. Nothing to do.

### The refresh cadence, and why it is not a policy anybody chose

The vendors set it, and they do not agree with each other. Both AMD's
and Intel's distribution services reissue their revocation lists and
trusted-computing-base documents on roughly monthly windows, so a corpus
of them goes stale about that fast whatever anybody here would prefer.
That is why the horizon is 30 days: a shorter one announces deadlines
that have already passed, and a longer one is indistinguishable from not
checking.

---

## Incident response

### A vendor revoked a certificate

The revocation arrives as a *new revocation list*, not as a
notification. So the sequence is:

1. Re-fetch the list from the publisher. Confirm the new entry: the
   monitor reports the digest changed; it does not read the entries.
2. Establish whether anything in this repository is affected. A revoked
   serial matters only if a pinned chain contains it.
3. If a pinned endorsement chain is revoked, **do not remove it**. A
   revoked-but-genuine chain is a good negative fixture and a bad
   positive one: move it, keep it, and say in its provenance comment
   what it now demonstrates.
4. Refresh the list and move the pinned clocks that judge it.

There is a real precedent in this tree worth reading before you decide
anything is broken: one vendor's distribution service now serves an
intermediate with a *later serial* than the one the pinned revocation
list names as revoked. That is a rotation, correctly reflected in both
documents, and it is not a compromise.

### A trust root rotated

This is the case where haste does damage, because a root is exactly the
thing an attacker would like you to replace.

1. **Do not refresh from one source.** Obtain the new root from at least
   two publishers that do not derive it from each other, and require the
   bytes to be identical. The pinned roots in this tree were established
   that way — one of them agrees byte for byte across three independent
   publishers — and that is the standard a replacement has to meet, not
   a nicety.
2. Check the new root's own validity window before pinning it. A root
   with an already-passed `notAfter` is a signal, not a document.
3. The roots this build accepts are compile-time constants with no
   run-time insertion point, deliberately. Rotating one is a code change
   that goes through review. There is no configuration file that would
   let a rotation happen quietly, and that is the design.

### A rebuilder's signing key is compromised

Rebuilder keys are admitted by identity, each with a stated admission
window, and a revocation cuts that window short. Two properties are
worth knowing before you rely on this:

* **Revocation is evaluated at verification time.** A signature carries
  no signing time, so nothing distinguishes a signature made before the
  revocation from one made after. Revoking a key therefore invalidates
  every bundle that key contributed to, including honest older ones.
  That is the fail-closed reading and it is the only one the evidence
  supports.
* **Rotation is overlap, not replacement.** Admit the successor key with
  a window that opens before the predecessor's closes, so bundles signed
  in the handover reach the threshold under both. Closing one window on
  the same instant the next opens leaves any in-flight bundle short.

---

## Verifier policy

What an operator decides, and what happens if they decide nothing.

| Decision | If you decide nothing | Where it is made |
|---|---|---|
| Which revocation lists to hold | Every chain is refused — an absent list is an unasked question, never an answer of "not revoked" | `--revocation-list` for operator chains, `--vendor-revocation-list` for vendor chains |
| The trusted-computing-base floor | No floor is enforced | the policy document's measurement section |
| The grace window after a floor moves | No grace: a below-floor report is refused the instant the floor rises | the policy document, plus the date the floor took effect, which the verifier holds and never takes from evidence |
| Challenge freshness | No bound on how old a nonce may be | the policy document's freshness section |
| The rebuilder quorum | A manifest is accepted only by pinning its digest | the policy document's evidence section |

Two rules that are not configurable, and should not become so:

* **A verifier never takes a document from the machine it is judging.**
  Anchors, revocation lists and vendor collateral all arrive from the
  operator's side. A machine that supplied the collateral it is judged
  against is vouching for itself.
* **Nothing degrades into an acceptance.** Missing collateral, an
  unreadable document and an expired one all refuse. There is no
  configuration that turns a refusal into a warning, because the one
  time that setting matters is the one time it should not have been on.

---

## What this corpus is and is not

Stated here rather than in a commit message, because every runbook above
is only as good as this paragraph.

**What the pinned material establishes.** That the readers, chain
evaluators, and signature checks in this repository produce the right
answers on bytes that real vendors and real machines produced —
certificates and revocation lists fetched from vendor distribution
services and corroborated against independent publishers, attestation
reports and quotes from several different parts, firmware images
published by their operators, and measured-boot logs written by real
firmware. The negatives are minted here on purpose, which is the one
place making the bytes yourself is required: an attacker mints their
own, so a test has to.

**What it does not establish.** That any of it is *current*. Every date
in it is a date in the past, and a corpus is not a subscription. The
scheduled monitor is the only thing that connects this repository to
what the vendors serve today, and it reports rather than repairs.

**One limit measured rather than assumed.** This build's X.509 reader
verifies a single signature algorithm, deliberately. At least one pinned
trust root is signed with a different one, so **this build cannot read
that root's validity window at all** — the ledger records it as
unreadable, with the refusal, rather than recording a date nobody
derived. Widening the reader to make that row prettier would relax a
narrowing that is load-bearing elsewhere. The honest record is the
unreadable one.
