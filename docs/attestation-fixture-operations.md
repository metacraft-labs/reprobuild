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

And the clock is **derived rather than chosen**, by one sentence:

> a gate's `Now` is the first UTC midnight at which every artifact that
> gate judges is simultaneously in force — the midnight at or after the
> latest `notBefore` among them.

"Inside the window" is satisfied by any instant in a fifty-day interval,
and an agent who has to move a clock to get a refresh landed will reach
for one that passes. That is how a clock ends up far ahead of its
evidence, and how the refresh after it silently stops testing anything.
The earliest defensible instant is a decision nobody has to make twice:
it is re-derivable by anyone holding the corpus, from dates read out of
the artifacts themselves, and it moves when and only when the material
moves. `t_attestation_fixture_lifecycle` computes it per gate and
requires equality.

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
| *pinned clocks agree with the material they judge* | A gate's `Now` is not the instant the clock rule gives | Either a fixture was refreshed and the clock was not moved, or a clock was moved by hand. The clock is derived, not chosen: it is the first UTC midnight at which every artifact that gate judges is in force. The failure prints what the gate states and what the rule gives; set it to the second |
| *sanitization* | A private key reached a pinned artifact or a corpus module's source | **Stop and treat it as a disclosure**, not as a test failure. The bytes are in the repository's history from the commit that added them; rotating the key is the remedy, deleting the line is not |
| *the lifecycle decision* | The rules themselves changed | Nothing about fixtures. Read the diff to `repro_attest_verify/lifecycle` |

### "I need to refresh one fixture"

Refreshing a fixture is five steps and the last two are the ones people
skip. **All of them land in one commit.** Steps 1–3 alone leave the tree
red, and that is not a hazard to be careful about — it is arithmetic: a
reissued revocation list comes into force *later* than the one it
replaces, and a list that is not yet in force is set aside by every
chain evaluator here, so the gates whose pinned clock sits before the
new `thisUpdate` begin reporting "no revocation data". This happened to
be four gates on one vendor's lists and three on the other's — twelve
cases each time — and the ledger gate names them.

1. Re-fetch from the publisher named in the ledger's publisher table.
   That table carries the exact command; it is not prose. For anything
   with a row in the fetch table that command is one `curl` of the URL
   recorded there.
2. Replace the constant. Keep the surrounding provenance comment
   truthful — the observation date in particular.
3. Regenerate the ledger row (digest, size, window). Do not type a
   digest.
4. **Move every pinned clock that judges it, in the same commit.** The
   clock is not a judgement call: it is the first UTC midnight at which
   every artifact that gate judges is in force — the midnight at or
   after the latest `notBefore` among them. The ledger gate computes
   that from the artifacts' own dates and requires equality, so there
   is nothing to choose and nothing to argue about. Pick a value
   because it passes and the gate says so.
5. **Move `LedgerReferenceInstant`** to the UTC midnight that *ends*
   the new observation date. It is likewise derived — one day after the
   latest `observed` in the ledger — and the gate checks it, because a
   reference instant that stays put while the corpus moves is a set of
   cases describing a corpus nobody has.

   The *ending* midnight, and that is a repair rather than a style
   choice. `observed` is a date, so it fixes the instant only to within
   a day, and the *opening* midnight is the one instant in that day at
   which a document fetched later the same day is **not yet in force**.
   Measured, not imagined: a refresh fetched at 17:13–17:28 UTC put
   seven observed artifacts into `not-yet-in-force` at the opening
   midnight — a corpus freshly taken from its publisher reported as a
   clock fault. The ending midnight cannot do that, because a document
   the publisher *served* on a day was in force at some instant in that
   day and therefore at its end. It also moves the instant later, which
   is the strict direction: later can only turn `current` into
   `due-for-refresh` or `expired`, never the reverse.

6. **Check the two lists on the gate's row in the ledger gate.**
   `mustBeCurrent` and `notRequiredCurrent` together must be exactly the
   windowed ledger rows the gate's *source* references, and the gate
   derives that set by reading the source. If the refresh added or
   removed a reference, the row has to say what the clock does about it:
   require the artifact in force, or record that this gate does not. The
   second list is not a free pass — nothing in it may be required in
   force by any other gate, and nothing in it may carry an `observed`
   date, which every artifact somebody went to a publisher for does. A
   reissue cannot be made quiet by moving a name.

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
  horizon (at most 30 days; see the cadence section below for why it is
  a ceiling and not a fixed number). This is the state the tool exists
  to produce: it is a deadline, not an outage, and the whole value is
  that it arrives while there is time.
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

**Which is exactly why a flat 30-day horizon did not work, and this is
the correction.** Measured on the corpus: every trusted-computing-base
document and platform revocation list one of these vendors serves states
a next-update *exactly thirty days* after its issue date. Under a flat
thirty-day horizon not one of them is ever `current` — each is born due
for refresh and stays due until it expires — so seven of the sixty-seven
pinned artifacts were permanently in the report and the run was red on
the day it was switched on and every day after. A report that has never
once been empty cannot say that something changed.

So the thirty days is a **ceiling**, and the horizon an artifact gets is
the lesser of it and **half that artifact's own stated lifetime**. Half,
because half is the largest fraction that leaves a quiet period at least
as long as the warning period. A thirty-day document is now quiet for
fifteen days and warns for fifteen; a forty-eight-day revocation list is
quiet for twenty-four and warns for twenty-four; anything living longer
than sixty days gets the full thirty.

It narrows the warning and never the validity. `expired` is unchanged,
`isUsable` is unchanged, and every evaluator's refusal is unchanged; the
only thing that moves is the day the announcement starts.

### One vendor re-signs every three hours, and that is why seven documents have no drift route

Measured, because it decides whether those documents can be watched for
drift at all. The trust-domain vendor's provisioning service does **not**
serve a stable document for the thirty days it claims: it re-signs on a
roughly three-hour cadence, moving the issue/this-update and next-update
by that interval and leaving everything else alone — same evaluation-data
number, same levels, same statuses, same advisory lists, same revoked
serials. Three back-to-back requests return byte-identical answers, so it
is not per request; a request three hours later does not. Observed
2026-10-02: `17:13:18` then `20:14:40` on one endpoint, `17:26:12` then
`20:26:15` on another, both to the second.

A fetch-table row promises that one HTTP GET returns the pinned bytes.
For these seven that promise expires three hours after any pin, so a row
would make the drift half report all seven on **every** run, for ever,
and re-pinning would not quieten it — the crying-wolf failure in a form
worse than the one the capped horizon removed, because there is no action
that ends it. They therefore have no row, and only their expiry is
watched.

**What a drift route for them needs, so this is a deferral and not a dead
end:** a *substance* digest beside the byte digest — the document with its
two timestamp members excluded — pinned in the ledger and compared against
the same projection of the response. A difference in that is the signal
worth having, because it is how a platform's trusted-computing-base policy
moves, and a corpus pinned to the previous policy is testing a policy
nobody runs. The byte digest cannot answer that question and the
evaluation-data number is the field to watch.

The other vendor is not like this: its three revocation lists and three
certificate chains re-fetch byte-identical hours and days apart, which is
why they do have rows.

### What "needs attention" does not include

One class is quiet while expired, on purpose, and it is worth knowing
which and why before reading a run as clean.

**`historical-vintage`** is vendor collateral pinned *because* it is
old. A corpus holding one vintage of a trusted-computing-base document
shows that this build reads the vintage it happens to hold; two
vintages, issued years apart, show that it is reading the **format**.
Three documents here are kept at issue dates long past for that reason,
and refreshing one would delete the property it exists for. Their
expiry is therefore printed and not counted.

The class costs something rather than being a label:

* a row carrying it **must** be expired — a vintage that is current
  contradicts the class and is reported *more* loudly than an ordinary
  expiry, not less;
* a row carrying it **must not** be in the fetch table. "This cannot be
  made current" and "one HTTP GET returns the publisher's current
  answer" cannot both be true, and the tool refuses to run at all
  (exit 2) rather than deciding which half to believe;
* **drift** for it is `drifted`, exactly as for ordinary collateral. Its
  publisher is a project's committed test data at a named commit, which
  cannot answer differently, so a difference is a defect in the pin. The
  class quietens an expiry and nothing else.

### Where the periodic run actually runs

A GitHub Actions `schedule:` trigger fires **only from the repository's
default branch**. A workflow that lives on a development branch has no
scheduled run — not a late one, an absent one — and the Actions UI shows
the workflow as `active` either way, so nothing says so.

That is not hypothetical here: between this job being added and the
first expiry it was written to announce, the API recorded exactly one
run of it, from the `push` that introduced it. The one Monday in between
fell before the file existed; the next fell after the documents expired.

The job therefore runs its **offline expiry half on every push** to the
branches work lands on, and keeps the schedule for the network half. If
you are wondering whether the weekly run is working, do not read the
workflow file — ask for its runs:

```
gh api repos/<owner>/<repo>/actions/workflows/attestation-collateral.yml/runs \
  -q '.workflow_runs[] | "\(.created_at) \(.event) \(.head_branch) \(.conclusion)"'
```

An `event` column with no `schedule` in it is the answer.

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
