# Senior checklist

A senior engineer also answers the questions nobody wrote down. Use this list in two places: the design notes (phase 1)
and the self-review before your final report. "Not applicable" is a valid answer only with a one-line reason. The
project may add its own items in `/task/project-checklist.md`; where the two disagree, the project's item wins.

## A. Stored data and invariants

1. **Nullability per state.** For every column or field you add or change, write when it is empty and when it is set,
   per state of its record (a field × state matrix). Each rule the store can enforce (NOT NULL, CHECK, unique index)
   becomes a named constraint. A rule that spans records becomes a code check plus a test, and you say so.
2. **Coupled fields.** Fields written together (a timestamp and its actor, an amount and its state, a version and its
   change) are all-or-none and tied to the state that sets them.
3. **Bounds from the terms.** Every number has its floor and ceiling from the record's own terms (spent ≤ reserved,
   count ≥ 0, a percentage within 0–100). Money uses the project's integer unit, never floating point.
4. **Who can delete or rewrite it.** For money, audit and history data, decide who may update or delete it and enforce
   that at the lowest layer the project uses (database privileges, triggers, append-only tables), not only in code.
5. **Mutable records** carry the update time and the version the design names, so concurrent writers can be detected.
6. **References across boundaries.** An identifier that points into another module or service is validated through
   that owner's interface, never trusted because it is well-formed.
7. **Indexes or lookups** exist for every query the design names (scoped lists, per-user counts, retention deletes) and
   for every uniqueness rule the store can guard cheaply.
8. **Schema changes** are forward-only, safe to apply under load, and bounded by lock and statement timeouts.

## B. Authorization and audit

9. **Every entry point** declares who may call it, and the code re-checks the permission and the scope of the loaded
   record, never of request parameters. An edit checks both the stored and the new scope.
10. **Unknown and out of scope look the same.** Both return the same "not found" on every path, including error paths
    after the lookup. Check scope before taking a lock, so an outsider cannot lock or time another scope's record.
11. **Refusals leave a trace** where the project audits actions. A refusal's audit record is written outside the
    transaction that is rolled back. Audit records hold identifiers, never secrets or personal data.
12. **Separation of duties, step-up and self-approval** rules hold exactly as specified, and the fields they read are
    always set when the check runs (see A.2).

## C. Interfaces and behaviour

13. **Contract = code.** Every limit, pattern and enum of the interface definition is exactly what the code accepts,
    no stricter and no looser. Every declared error is reachable and mapped; nothing undeclared is returned.
14. **Retries and replays.** The same request repeated gives the same outcome; the same idempotency key with another
    body is a conflict. State what a replay returns and make it match the interface text.
15. **Concurrency.** Optimistic version checks are made under the row lock and again in the write's condition. Lock
    order is consistent. No cache lock or in-memory mutex protects a business rule that spans processes.
16. **New enum or state values**: search for hard-coded allowlists of the old values (switches, string literals, UI
    filters) in every layer.
17. **Failure paths.** Timeouts on every outbound call, bounded retries, cancellation honoured, no goroutine, thread or
    task left without an owner and an exit.
18. **Logs and errors** never contain secrets, tokens or personal data; errors are wrapped with context and handled
    once.

## D. Tests

19. Each guard above has a test that fails without it. Prove it with a one-at-a-time mutation and report each result.
20. Tests you cannot run here (they need services) are written with valid fixtures: re-check every literal against the
    constraints you wrote, and keep each case minimal. Say in your report that they were compiled only.
21. A claim about a response, a message or a log is tested at the layer that produces it, not only below it.

## E. When the sources disagree

22. If the decision records, the interface definition and the brief disagree, or they are silent on something the code
    must decide, do **not** pick silently. Write it under "Open points" with file and line, implement the safest
    reading, and say which.
23. Never edit an accepted decision record (ADR or similar) that is on the base branch. A changed decision goes into a
    new record that says what it amends.

## Design notes (phase 1 output: `/out/design-notes.md`, at most ~150 lines)

1. Requirements: every "must / never / only / audit / exactly" sentence of the sources in scope, numbered, each mapped
   to the code unit and the test that will satisfy it.
2. Per stored record: the field × state matrix (A.1) and the resulting constraints, guards and privileges (A.4).
3. Per operation: permission, scope check, lock, version check, audit records, errors returned.
4. Failure modes: concurrent commands, replays, stale versions, a crash between steps.
5. Open points (E.22).

## Self-review (before the final report: `/out/self-review.md`)

Walk every item, this list's and the project's, against your diff. For each: where it is satisfied (file:line and test
name) or "not applicable" with the reason. Fix what you find before reporting. If a subagent is available, have it do
this walk on the diff with no access to your reasoning, then reconcile.
