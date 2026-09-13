# Haulvia P2C RLS and Security Policy Contract v1

Status: DRAFT FOR IMPLEMENTATION

Phase: 2C — Row-Level Security and Security Policy Boundary

Depends on:
- Haulvia Foundation v1
- Blocks A–E
- P2A Authority and Configuration Seeds
- P2B Auth/Profile Mapping

## 1. Purpose

P2C establishes the database access-control boundary around the Haulvia
core relational model.

P2C is a security-hardening phase. It does not redesign the domain model,
state machines, pricing logic, payment logic, compliance model, or trusted
command layer.

The core principles are:

1. The `haulvia` schema is the private canonical data model.
2. Browser and mobile clients do not receive direct access to raw Haulvia
   base tables in P2C.
3. Mutating business operations remain command-mediated.
4. RLS is defense in depth in addition to PostgreSQL grants.
5. Client-facing read models must be intentionally designed rather than
   exposing the raw operational schema.
6. Existing P2A and P2B authority and identity rules remain authoritative.

## 2. P2C security invariants

### 2.1 Core-schema privacy

The `haulvia` schema is a private application-core schema.

P2C must not make the raw `haulvia` relational model generally available
to `PUBLIC`, `anon`, or `authenticated`.

No assumption may be made that an object is safe merely because the
application currently does not query it.

### 2.2 Defense in depth

PostgreSQL object privileges and row-level security are separate controls.

Both controls must fail closed.

A mistaken future table grant must not automatically make all rows visible.

A mistaken future RLS policy must not automatically provide an operation
for which the caller lacks the PostgreSQL object privilege.

### 2.3 Default deny

Every P2C-protected Haulvia base table must have row-level security enabled.

P2C v1 intentionally defines no general raw-table access policy for
`anon` or `authenticated`.

For those roles, lack of an applicable policy remains default-deny.

### 2.4 RLS is not the business-command layer

P2C must not reproduce the shipment state machine, negotiation rules,
custody rules, financial authorization rules, compliance workflow, or
other command invariants inside RLS policies.

Those rules remain enforced through the existing trusted command layer.

RLS is an access-containment mechanism, not a replacement for command
validation.

### 2.5 No FORCE RLS in P2C v1

P2C v1 enables row-level security but does not require
`FORCE ROW LEVEL SECURITY`.

Trusted SECURITY DEFINER command functions and internal execution paths
must continue to operate under the intended database-owner/trusted-role
boundary.

Any later use of FORCE RLS requires its own compatibility review against
the command layer.

## 3. Authentication and authority boundary

### 3.1 P2B remains authoritative

`profiles` remains the canonical Haulvia application person.

`profiles.auth_user_id` remains the bridge from an external authenticated
Auth principal to a Haulvia profile.

P2C must not introduce a second canonical user mapping.

### 3.2 JWT claims do not become business authority

P2C must not trust client-supplied organization IDs, profile IDs, provider
IDs, driver IDs, role names, permission names, or equivalent JWT metadata
as business authority.

The P2B rule remains unchanged:

the external authenticated principal identifies a candidate Auth UUID;
database state determines the corresponding profile, memberships,
roles, permissions, provider relationships, and operational access.

### 3.3 No premature auth.uid() policy surface

Because P2C v1 grants no raw-table access to authenticated clients, P2C
does not need to introduce broad direct-table policies based on
`auth.uid()`.

When a future curated client-read surface is approved, its policy may use
the trusted Auth subject and P2B database mapping.

That future policy must not treat mutable JWT application metadata as
authority.

## 4. PostgreSQL role and grant model

### 4.1 PUBLIC

`PUBLIC` receives no direct access to Haulvia base tables or core views.

`PUBLIC` must not receive EXECUTE on privileged SECURITY DEFINER functions.

### 4.2 anon

`anon` receives no direct SELECT, INSERT, UPDATE, DELETE, TRUNCATE,
REFERENCES, or TRIGGER privileges on raw Haulvia base tables.

`anon` receives no access to internal Haulvia views.

`anon` receives no execution right on the trusted command schema.

### 4.3 authenticated

`authenticated` receives no direct raw-table access in P2C v1.

In particular, P2C v1 does not grant direct INSERT, UPDATE, DELETE, or
TRUNCATE privileges on Haulvia core tables.

P2C v1 also does not grant broad SELECT access to the raw operational
schema.

### 4.4 service_role

P2C does not introduce new broad raw-table grants to `service_role`.

Existing intentionally granted execution rights on trusted command
functions must continue to work.

Future direct service-role table access must be explicit and justified by
the server-side use case that requires it.

### 4.5 Trusted commands

`haulvia_command` remains the trusted business-command boundary.

Client roles must not gain broad EXECUTE access to it.

Existing server-side allowlisting and revocation rules remain in force.

## 5. Base-table RLS contract

### 5.1 Coverage

Every existing BASE TABLE in schema `haulvia` at P2C migration execution
must have row-level security enabled.

The P2C discovery baseline contains 123 Haulvia base tables.

The migration must operate on the actual catalog rather than assuming
that only tables with `organization_id`, `profile_id`, or `shipment_id`
require protection.

### 5.2 Indirect tenancy

A table does not become non-sensitive merely because it lacks a direct
tenant column.

Haulvia tenancy and participant relationships may be inherited through:

- shipment relationships;
- route-version and route-execution relationships;
- provider relationships;
- driver relationships;
- organization memberships;
- provider-driver relationships;
- compliance subjects;
- claims and disputes;
- financial relationships;
- workflow and custody relationships.

P2C therefore protects the complete core schema rather than only
directly tenant-keyed tables.

### 5.3 No generic tenant predicate

P2C must not introduce a generic policy such as:

`organization_id = <client supplied organization>`

as a universal authorization rule.

The schema does not support such a simplification safely.

### 5.4 No direct client mutations

No P2C policy may authorize raw-table INSERT, UPDATE, DELETE, or TRUNCATE
for `anon` or `authenticated`.

Mutation remains command-mediated.

## 6. Sensitive-data classes

### 6.1 Identity and security records

The following classes are internal/private by default:

- profiles beyond a future explicitly approved projection;
- reauthentication sessions;
- command idempotency records;
- organization invitation secrets/digests;
- profile claim proofs;
- profile Auth recovery proofs;
- security audit records.

### 6.2 Compliance

Raw compliance subjects, items, documents, document reviews, history,
requirement administration, credential numbers, object keys, and review
metadata are not directly client-readable in P2C v1.

Future carrier/provider compliance interfaces require dedicated,
purpose-built projections or trusted endpoints.

### 6.3 Financial

Raw payment methods, payment intents, payment transactions, payouts,
financial holds, financial adjustments, approval records, pricing reviews,
refund/compensation decisions, and financial workflow state remain
internal by default.

A shipment participant relationship alone does not authorize unrestricted
access to raw financial rows.

### 6.4 Audit and idempotency

Audit and command-idempotency records are internal security evidence.

They are not client-readable simply because the actor or entity referenced
by the record belongs to the client.

### 6.5 Receiver secrets

Receiver access tokens and other proof/secret-bearing records remain
internal.

Possession of a public shipment reference is never sufficient authority
to query secret-bearing tables.

### 6.6 Operational raw data

Shipment, route, assignment, offer, tracking, custody, stop, recovery,
workflow, claim, and dispute base tables remain protected raw storage.

Client-visible operational information will be exposed later through
purpose-built read models that contain only the fields appropriate to the
requesting participant.

## 7. Existing views

P2C discovery identified these existing Haulvia views:

- `v_cargo_custody_balance`
- `v_compliance_blockers`
- `v_compliance_item_export`
- `v_route_allocation_manifest`
- `v_shipment_operating_context`

### 7.1 View access

None of these views receives direct `PUBLIC`, `anon`, or `authenticated`
access in P2C v1.

### 7.2 security_invoker

Each existing view must be configured as `security_invoker = true`.

This is defense in depth against a later accidental grant causing the
view owner's privileges to become an unintended RLS bypass.

### 7.3 Sensitive projections

`v_compliance_item_export` is considered compliance-sensitive.

`v_shipment_operating_context` is considered an internal composite
operational view because it combines marketplace, customer payment,
driver payout, dispute, route, custody, recovery, and workflow state.

Neither is an approved public/client API merely because it already exists.

## 8. SECURITY DEFINER hardening

### 8.1 Execution grants

A SECURITY DEFINER function is privileged code.

P2C must verify that privileged functions are not executable by
`PUBLIC`, `anon`, or `authenticated` unless an explicit contract
allowlist says otherwise.

P2C v1 defines no such client allowlist for core command functions.

### 8.2 Search path

Every SECURITY DEFINER function in the Haulvia security boundary must use
a pinned, controlled search path.

The search path must not depend on caller-controlled `$user` resolution
or an untrusted writable schema.

Existing function bodies do not need to be rewritten merely to force an
empty search path if they already use a safe controlled path.

Any unsafe SECURITY DEFINER search path discovered by P2C acceptance
testing must be hardened before P2C is complete.

### 8.3 Ownership

Privileged functions must not be owned by `anon` or `authenticated`.

## 9. Schema hardening

### 9.1 Schema privileges

P2C must explicitly prevent `PUBLIC`, `anon`, and `authenticated` from
creating objects inside the core `haulvia` schema or trusted
`haulvia_command` schema.

### 9.2 Future-object defaults

P2C must harden relevant default privileges for objects subsequently
created by the migration owner in the Haulvia schemas.

Future tables/views must not become generally client-accessible merely
because PostgreSQL or a hosted platform supplied permissive defaults.

Future privileged functions must not rely on PostgreSQL's default PUBLIC
EXECUTE grant.

### 9.3 Future migrations

P2C does not create an event trigger that automatically modifies all
future tables.

Every later migration adding a Haulvia table remains responsible for
meeting the P2C security contract.

## 10. Client-facing API boundary

### 10.1 Raw schema is not the frontend API

The Haulvia relational schema is optimized for correctness, auditability,
state transitions, and referential integrity.

It is not itself the client API contract.

### 10.2 Future read models

Future direct client reads should use purpose-built projections, views,
or RPC/read functions with:

- explicit column selection;
- explicit participant visibility;
- explicit grants;
- appropriate RLS or trusted-function authority;
- tests for both allowed and denied users.

### 10.3 Marketplace discovery

Provider marketplace discovery must not be implemented by granting all
providers SELECT access to raw shipment rows and their entire related
graph.

Marketplace discovery requires a deliberately sanitized listing/read
model.

### 10.4 Customer access

Future customer shipment access may derive from
`shipments.customer_profile_id` or
`shipments.customer_organization_id`, but only through an explicitly
approved client-read contract.

### 10.5 Provider access

Future provider access may derive from `service_providers`,
organization authority, `provider_drivers`, offers, assignments, and
other approved relationships.

Provider participation in one shipment must not create visibility into
unrelated provider, customer, financial, compliance, or audit data.

### 10.6 Driver access

Future driver access may derive from `drivers.profile_id`,
`provider_drivers`, assignment relationships, and explicitly approved
execution relationships.

A driver's identity alone must not grant provider-wide access.

## 11. P2C acceptance requirements

The P2C acceptance suite must prove each requirement below.

P2C-01 — all existing Haulvia base tables have RLS enabled.

P2C-02 — the P2C baseline covers all 123 currently discovered base tables.

P2C-03 — P2C does not require FORCE RLS on the core tables.

P2C-04 — PUBLIC has no raw Haulvia table privileges.

P2C-05 — anon has no raw Haulvia table privileges.

P2C-06 — authenticated has no raw Haulvia table privileges.

P2C-07 — P2C introduces no new broad service_role raw-table grants.

P2C-08 — PUBLIC has no direct privilege on the existing Haulvia views.

P2C-09 — anon has no direct privilege on the existing Haulvia views.

P2C-10 — authenticated has no direct privilege on the existing Haulvia views.

P2C-11 — all five existing Haulvia views are security-invoker views.

P2C-12 — v_cargo_custody_balance remains client-denied.

P2C-13 — v_compliance_blockers remains client-denied.

P2C-14 — v_compliance_item_export remains client-denied.

P2C-15 — v_route_allocation_manifest remains client-denied.

P2C-16 — v_shipment_operating_context remains client-denied.

P2C-17 — anon has no command-schema execution surface.

P2C-18 — authenticated has no command-schema execution surface.

P2C-19 — PUBLIC has no command-schema execution surface.

P2C-20 — existing intended service_role command execution remains available.

P2C-21 — no raw client INSERT grant exists.

P2C-22 — no raw client UPDATE grant exists.

P2C-23 — no raw client DELETE grant exists.

P2C-24 — no raw client TRUNCATE grant exists.

P2C-25 — P2C creates no permissive anon raw-table policy.

P2C-26 — P2C creates no permissive authenticated raw-table policy.

P2C-27 — profile claim proof records remain client-denied.

P2C-28 — profile Auth recovery proof records remain client-denied.

P2C-29 — reauthentication-session records remain client-denied.

P2C-30 — organization invitation secret-bearing records remain client-denied.

P2C-31 — command-idempotency records remain client-denied.

P2C-32 — audit-event records remain client-denied.

P2C-33 — customer payment-method references remain client-denied.

P2C-34 — raw payment and payout records remain client-denied.

P2C-35 — raw financial-adjustment and hold records remain client-denied.

P2C-36 — raw compliance documents remain client-denied.

P2C-37 — raw compliance credential/item records remain client-denied.

P2C-38 — receiver access-token records remain client-denied.

P2C-39 — raw configuration and RBAC administration tables remain client-denied.

P2C-40 — SECURITY DEFINER functions have controlled search paths.

P2C-41 — privileged SECURITY DEFINER functions are not owned by anon or authenticated.

P2C-42 — default table/view privileges do not create future PUBLIC/anon/authenticated exposure for objects created by the migration owner.

P2C-43 — default function privileges do not create future PUBLIC execution exposure for privileged Haulvia functions created by the migration owner.

P2C-44 — P2C preserves the P2A/P2B authority and Auth/profile mapping invariants.

## 12. Implementation boundary

P2C includes:

- core-schema RLS enablement;
- explicit client-role revocation;
- view security-invoker hardening;
- schema privilege hardening;
- SECURITY DEFINER privilege/search-path validation and required corrections;
- default-privilege hardening;
- rollback-only acceptance testing.

P2C does not include:

- frontend screens;
- hosted Auth hooks;
- storage-bucket policies;
- document-storage retention;
- broad client-facing read APIs;
- marketplace listing projections;
- payment-provider integration;
- external API adapters;
- hosted Supabase deployment.

Those remain later-phase work.

## 13. Implementation order

Implementation order is:

1. lock this contract;
2. fingerprint the contract;
3. write the P2C migration;
4. build the rollback-only acceptance suite;
5. execute Foundation through P2C on a disposable local database;
6. resolve all acceptance failures;
7. verify the complete P2C security surface;
8. commit and push only after all checks pass.

Hosted Supabase remains unchanged during local P2C development.

## 14. Next implementation artifact

The next artifact after this contract is:

`supabase/migrations/<timestamp>_haulvia_p2c_rls_and_security_policies_v1.sql`

The acceptance artifact is:

`tests/haulvia_p2c_acceptance_v1.sql`