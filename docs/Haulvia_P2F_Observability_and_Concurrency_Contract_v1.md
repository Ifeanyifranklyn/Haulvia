# Haulvia P2F Observability and Concurrency Contract v1

**Status:** FROZEN DESIGN CANDIDATE

**Phase:** P2F — Observability and Concurrency Preparation

**Baseline:** Phase 2A through Phase 2E complete at repository checkpoint `74ba509`.

**Hosted validation boundary:** Local design, migration development, rollback acceptance and concurrency-harness development may proceed while `haulvia-db-test` is paused. Authoritative hosted concurrency execution and hosted validation are deferred until the hosted project is intentionally resumed.

---

## 1. Purpose

P2F prepares Haulvia for operational monitoring and deliberate concurrency validation without creating duplicate operational truth.

P2F must:

1. provide administrator-safe audit projections;
2. provide derived failed-command, stuck-workflow, payout, dispute and compliance attention queues;
3. define stable observability/attention codes;
4. place operational alert thresholds in the existing versioned platform-configuration system;
5. provide deterministic multi-session race harnesses for the existing command/state model;
6. preserve all existing command, authority, RLS, idempotency, audit, financial, custody and provider-adapter boundaries;
7. provide an exact hosted-validation checklist for later execution.

P2F is an observability and verification layer. It is not a replacement workflow model.

---

## 2. Non-negotiable architecture invariants

### P2F-01 — Existing operational facts remain authoritative

P2F must not create a second canonical copy of:

- command state;
- shipment state;
- marketplace state;
- payment state;
- payout state;
- dispute state;
- compliance state;
- route/execution state;
- custody state;
- provider-adapter state;
- provider-webhook state.

P2F projections derive from existing authoritative relations.

### P2F-02 — Audit facts remain immutable

`haulvia.audit_events` remains the canonical audit fact source.

P2F may project, filter, classify and aggregate audit data.

P2F must never rewrite or normalize historical `audit_events` rows in place.

### P2F-03 — Command retry truth and failed-attempt evidence

`haulvia.command_idempotency` remains authoritative for command request ownership, request hashing, retry state and successfully completed replay results.

The current command path does not guarantee a durable `FAILED` idempotency row for an ordinary rejected command. `haulvia_command.fail(...)` raises an exception; `begin_request(...)` creates or locks `STARTED`; and `complete_request(...)` is the existing successful transition to `COMPLETED`. A failed command transaction can therefore roll back its newly created idempotency row.

P2F must not treat `command_idempotency.status = 'FAILED'` as a complete command-failure history.

P2F introduces `haulvia.command_failure_observations` as append-only observability evidence written by the trusted server boundary only after the failed command transaction has ended.

`command_failure_observations` is not command lifecycle truth. It must never be used to determine whether a command committed, and it must not replace command idempotency.

Minimum retained fields are:

- observation ID;
- observation timestamp;
- unique observation key for idempotent logging retries;
- source code;
- command name;
- nullable actor, organization and shipment identifiers;
- correlation ID;
- request SHA-256 when available;
- SHA-256 of the command idempotency key when available;
- normalized Haulvia error code;
- nullable SQLSTATE;
- retryable flag.

The observation must not store request payloads, raw database/provider error messages, stack traces, unrestricted error context, credentials or secrets.

The existing server-only command adapter must record normalized database-command failures through a narrowly scoped trusted P2F writer in a separate follow-up transaction after the failed command RPC returns.

Transport failures that never produced a database command rejection must not be recorded as database command failures because the caller may not know whether PostgreSQL committed before the transport was lost.

A persisted `command_idempotency.status = 'FAILED'` row remains valid if an explicit current or future flow creates one. P2F must not change existing command transaction semantics merely to manufacture `FAILED` idempotency rows.

### P2F-03A — Failure-observation writer boundary

P2F introduces exactly one trusted failure-observation RPC wrapper:

`haulvia_command.command_record_command_failure_observation(p_request jsonb)`

This wrapper is observability infrastructure, not business-command lifecycle state.

It must:

1. insert only into `haulvia.command_failure_observations`;
2. use the observation key as its own idempotency identity;
3. enforce uniqueness so replaying the same observation write creates no duplicate row;
4. not call `haulvia_command.begin_request(...)`;
5. not call `haulvia_command.complete_request(...)`;
6. not create another `command_idempotency` row;
7. require trusted worker authority `OBSERVABILITY_WORKER`;
8. reject a non-null calling `actorProfileId`;
9. accept only sanitized scalar/hash fields defined by this contract;
10. return only safe observation identity/replay information.

`OBSERVABILITY_WORKER` is a backend execution authority only. It must never be inserted as a human role, organization role, membership role or client claim.

The writer must be executable by `service_role` only through the approved backend boundary.

`PUBLIC`, `anon` and `authenticated` receive no execute permission.

`service_role` receives no direct raw INSERT, UPDATE, DELETE or SELECT privilege on `command_failure_observations` merely because it may execute the writer.

The raw observation table remains protected storage.

### P2F-03B — Shared command-manifest extension

The failure-observation writer is added explicitly to the existing shared Haulvia command manifest with phase `P2F`.

The cumulative manifest after P2F contains exactly:

- 86 `PRE_P2E` commands;
- 5 `P2E` commands;
- 1 `P2F` command;
- 92 unique commands total.

P2F must preserve all 91 pre-existing manifest entries unchanged in identity and RPC mapping.

The new P2F entry is:

`command_record_command_failure_observation`

Unknown functions, helpers and unlisted RPC names remain non-invocable through the generic command adapter.

Any regression test that previously treated 91 as the permanent total must be made phase-aware without weakening the frozen facts that the pre-P2E subset remains 86 and the P2E subset remains 5.

### P2F-03C — Non-recursive adapter behavior

For a database RPC rejection, the command adapter must first preserve the original normalized command failure.

It may then attempt one follow-up failure-observation RPC using the dedicated P2F manifest entry.

The failure-observation writer itself must never trigger another failure observation.

No recursive observation attempt is permitted.

A failure to persist the observation must not:

- convert the original command failure into success;
- replace the original command error code or message;
- cause an infinite retry/observation loop;
- imply that the original business command committed.

The original normalized command failure remains the caller-visible result.

An observation-write failure must be separately detectable by trusted server logging and by P2F acceptance tests.

A transport exception where no database rejection was received must not invoke the failure-observation writer.

### P2F-04 — Workflow-job truth remains canonical

`haulvia.workflow_jobs` remains authoritative for queued asynchronous work.

P2F may classify jobs as late, stale or failed using configured thresholds but must not invent a second job state.

### P2F-05 — Financial truth remains canonical

Existing payment, payout, hold, adjustment and provider-adapter relations remain authoritative.

P2F attention queues contain only derived operational indicators.

### P2F-06 — Compliance truth remains canonical

Existing compliance subjects, items, requirement versions, reviews and document records remain authoritative.

The existing `v_compliance_blockers` predicate remains the baseline definition of a current compliance blocker unless a later approved contract changes it.

### P2F-07 — Dispute truth remains canonical

Existing `disputes`, dispute events, operational controls, financial holds and resolution records remain authoritative.

### P2F-08 — Route and custody truth remains canonical

Existing route versions, route executions, stop executions, stop attempts, cargo allocations, cargo movements and custody-transfer facts remain authoritative.

No P2F route, stop or custody shadow model may be introduced.

---

## 3. Data-minimization boundary

P2F operational views are intentionally minimized.

Ordinary P2F audit and attention projections must not expose:

- `audit_events.before_value`;
- `audit_events.after_value`;
- unrestricted audit metadata;
- unrestricted audit reason text;
- `command_idempotency.result`;
- raw command-failure request payloads;
- raw command-failure messages, stack traces or unrestricted error context;
- workflow-job `payload`;
- provider adapter `request_snapshot`;
- provider adapter `normalized_result`;
- provider adapter `response_snapshot`;
- provider webhook `verification_context`;
- provider webhook `normalized_event_snapshot`;
- provider webhook `command_result`;
- provider webhook `error_context`;
- payment or payout raw provider response payloads;
- private storage object keys;
- document download locations;
- full compliance credential numbers;
- compliance documents;
- raw evidence manifests;
- arbitrary protected JSON snapshots.

P2F may expose safe scalar identifiers, codes, statuses, timestamps, durations, counts and operationally necessary monetary totals.

Presence of protected details may be represented by safe booleans or counts when useful.

---

## 4. Admin-safe audit projection

P2F introduces:

`haulvia.v_admin_audit_projection`

The projection is read-only operational evidence derived from `haulvia.audit_events`.

Minimum safe fields:

- `audit_event_id`
- `occurred_at`
- `actor_kind`
- `actor_profile_id`
- `actor_provider_id`
- `organization_id`
- `command_name`
- `authority_code`
- `entity_schema`
- `entity_table`
- `entity_id`
- `correlation_id`
- `has_idempotency_key`
- `idempotency_key_sha256`
- `has_reason`
- `has_before_value`
- `has_after_value`

The ordinary projection must not expose raw before/after values, unrestricted metadata or unrestricted reason text.

Viewing this projection requires the existing `AUDIT_VIEW` authority path or a trusted backend boundary acting for an authorized staff member.

`AUDIT_EXPORT` remains a separate sensitive permission and is not implemented implicitly by this ordinary projection.

---

## 5. Failed-command attention queue

P2F introduces:

`haulvia.v_failed_command_queue`

Authoritative sources:

- `haulvia.command_idempotency` for durable retry state;
- `haulvia.command_failure_observations` for post-rollback failed-attempt evidence.

Minimum classifications:

- `COMMAND_FAILED`
- `COMMAND_STALE_STARTED`

`COMMAND_FAILED` is emitted when either:

1. a sanitized `command_failure_observations` row records a database-command rejection; or
2. an explicit persisted `command_idempotency.status = 'FAILED'` row exists.

The queue must expose a safe failure-source discriminator so an operator can distinguish observed rejected attempts from persisted idempotency state.

`COMMAND_STALE_STARTED` applies only when:

- canonical idempotency status remains `STARTED`; and
- elapsed time exceeds the effective configured `OBS_COMMAND_STARTED_STALE_SECONDS`.

The queue may expose:

- failure-observation ID where applicable;
- command-idempotency row ID where applicable;
- actor profile ID;
- command name;
- correlation ID;
- request SHA-256 where available;
- SHA-256 of the idempotency key where available;
- canonical idempotency status where applicable;
- normalized Haulvia error code where applicable;
- retryable flag where applicable;
- started/completed/observed timestamps;
- safe age/duration;
- failure source;
- attention code.

The queue must not expose the stored command result, raw idempotency key, request payload, raw error message, stack trace or unrestricted error context.

A failure observation is operational evidence that an invocation was rejected at the command boundary. It does not create or mutate operational command state.

A stale STARTED classification is observability only. It does not mutate the command row.

---

## 6. Stuck-workflow attention queue

P2F introduces:

`haulvia.v_stuck_workflow_queue`

Authoritative source:

`haulvia.workflow_jobs`

Minimum classifications:

- `WORKFLOW_JOB_FAILED`
- `WORKFLOW_JOB_LATE`
- `WORKFLOW_JOB_STALE_RUNNING`

Definitions:

### WORKFLOW_JOB_FAILED

Canonical workflow-job status is `FAILED`.

### WORKFLOW_JOB_LATE

Canonical workflow-job status is `QUEUED`, `run_after` is in the past, and lateness exceeds effective configured `OBS_WORKFLOW_QUEUED_LATE_SECONDS`.

### WORKFLOW_JOB_STALE_RUNNING

Canonical workflow-job status is `RUNNING` and time since `updated_at` exceeds effective configured `OBS_WORKFLOW_RUNNING_STALE_SECONDS`.

Safe queue fields may include:

- workflow-job ID;
- shipment ID;
- job code;
- canonical status;
- run-after timestamp;
- attempt count;
- created/updated timestamps;
- safe age/duration;
- whether `last_error` is present;
- attention code.

Raw job payload and unrestricted `last_error` text are excluded from the ordinary queue.

---

## 7. Payout attention queue

P2F introduces:

`haulvia.v_payout_attention_queue`

Authoritative sources include:

- `haulvia.driver_payouts`;
- `haulvia.payout_eligibility_records`;
- `haulvia.payout_transactions`;
- provider-adapter evidence when correlation to the payout exists.

Minimum classifications:

- `PAYOUT_FAILED`
- `PAYOUT_HELD`
- `PAYOUT_STALE_READY`
- `PAYOUT_STALE_PROCESSING`

`PAYOUT_STALE_READY` uses effective configured `OBS_PAYOUT_READY_STALE_SECONDS`.

`PAYOUT_STALE_PROCESSING` uses effective configured `OBS_PAYOUT_PROCESSING_STALE_SECONDS`.

The queue may expose:

- payout ID;
- shipment ID;
- assignment ID;
- provider ID;
- driver ID;
- canonical payout state;
- state-change timestamp;
- currency;
- gross/net/releasable amounts where operationally required;
- latest safe transaction status;
- safe provider-attempt status/category;
- age/duration;
- attention code.

Raw provider responses, payout snapshots and unrestricted provider metadata are excluded.

---

## 8. Dispute attention queue

P2F introduces:

`haulvia.v_dispute_attention_queue`

Authoritative sources include:

- `haulvia.disputes`;
- `haulvia.dispute_operational_controls`;
- `haulvia.financial_holds`;
- `haulvia.dispute_resolution_records`.

Minimum classifications:

- `DISPUTE_OPEN`
- `DISPUTE_BLOCKING_MOVEMENT`
- `DISPUTE_STALE_OPEN`

A dispute is open when canonical status is not terminal.

`DISPUTE_STALE_OPEN` uses effective configured `OBS_DISPUTE_OPEN_STALE_SECONDS`.

The queue may expose:

- dispute ID;
- shipment ID;
- stop-execution ID;
- cargo-item ID;
- category code;
- canonical dispute status;
- opened/resolved timestamps;
- disputed amount/currency;
- whether route movement is blocked;
- whether a financial hold is active;
- safe age/duration;
- attention code.

Raw evidence manifests, resolution JSON and unrestricted notes are excluded from the ordinary queue.

---

## 9. Compliance attention queue

P2F introduces:

`haulvia.v_compliance_attention_queue`

The queue reuses the existing canonical blocker predicate represented by:

`haulvia.v_compliance_blockers`

It must not implement a conflicting blocker definition.

Minimum classifications:

- `COMPLIANCE_BLOCKER`
- `COMPLIANCE_EXPIRING`

`COMPLIANCE_BLOCKER` represents an active, applicable, required item that is not VERIFIED.

`COMPLIANCE_EXPIRING` may classify an otherwise relevant item whose expiry date falls inside the effective configured `OBS_COMPLIANCE_EXPIRY_WARNING_DAYS`.

Safe fields may include:

- compliance subject ID;
- compliance-item ID;
- compliance code;
- compliance name;
- review status;
- expiry date;
- subject kind where safely joinable;
- attention code.

Credential numbers, document locations, document payloads and sensitive compliance evidence are excluded.

---

## 10. Stable attention and metric codes

P2F v1 defines these stable codes:

### Command

- `COMMAND_FAILED`
- `COMMAND_STALE_STARTED`

### Workflow

- `WORKFLOW_JOB_FAILED`
- `WORKFLOW_JOB_LATE`
- `WORKFLOW_JOB_STALE_RUNNING`

### Payout

- `PAYOUT_FAILED`
- `PAYOUT_HELD`
- `PAYOUT_STALE_READY`
- `PAYOUT_STALE_PROCESSING`

### Dispute

- `DISPUTE_OPEN`
- `DISPUTE_BLOCKING_MOVEMENT`
- `DISPUTE_STALE_OPEN`

### Compliance

- `COMPLIANCE_BLOCKER`
- `COMPLIANCE_EXPIRING`

### Provider integration metrics

P2F monitoring may additionally aggregate these existing P2E facts:

- `PROVIDER_ADAPTER_SUBMISSION_FAILED`
- `PROVIDER_ADAPTER_ATTEMPT_FAILED`
- `PROVIDER_WEBHOOK_DISPATCH_FAILED`

These provider-integration codes are derived metrics only. P2F does not introduce another provider lifecycle.

No persisted metric-event table is required in P2F v1.

---

## 11. Configured observability thresholds

P2F must reuse:

- `haulvia.platform_config_definitions`
- `haulvia.platform_config_versions`

P2F introduces stable configuration definitions only.

Required keys:

- `OBS_COMMAND_STARTED_STALE_SECONDS`
- `OBS_WORKFLOW_QUEUED_LATE_SECONDS`
- `OBS_WORKFLOW_RUNNING_STALE_SECONDS`
- `OBS_PAYOUT_READY_STALE_SECONDS`
- `OBS_PAYOUT_PROCESSING_STALE_SECONDS`
- `OBS_DISPUTE_OPEN_STALE_SECONDS`
- `OBS_COMPLIANCE_EXPIRY_WARNING_DAYS`

Rules:

1. Definitions use stable uppercase keys.
2. All seven definitions use category `OBSERVABILITY`.
3. All seven definitions use value type `INTEGER`.
4. Every `*_SECONDS` definition uses unit `SECONDS`.
5. `OBS_COMPLIANCE_EXPIRY_WARNING_DAYS` uses unit `DAYS`.
6. P2F migration inserts definitions only and must not insert an effective production configuration version.
7. An age-based classification requires exactly one `APPROVED`, non-null, currently effective configuration version.
8. The effective integer value must be greater than zero.
9. Zero matching effective versions must produce no threshold-dependent classification; the system must not invent a fallback value.
10. Multiple simultaneously effective approved versions are a configuration defect and must fail closed rather than choosing one silently.
11. Application code must not embed operational thresholds as constants.
12. Acceptance tests may create transaction-local effective configuration versions and roll them back.
13. Non-threshold classifications such as explicit `FAILED`, `HELD`, open dispute and compliance-blocker states remain observable even when an age threshold is not configured.

---

## 12. Permission and service-boundary rules

P2F introduces no new human role family.

Existing permission vocabulary is reused.

Relevant existing permissions include:

- `AUDIT_VIEW`
- `INTERNAL_SHIPMENT_VIEW`
- `INTERNAL_PROVIDER_VIEW`
- `INTERNAL_PAYMENT_VIEW`
- `COMPLIANCE_REVIEW`
- `DISPUTE_RESOLVE`
- `ROUTE_OPERATIONS_MANAGE`
- `PAYOUT_MANAGE`
- `PLATFORM_CONFIGURATION_VIEW`

P2F must not:

- grant raw operational table access broadly;
- grant raw P2E integration-table access broadly;
- grant new command execution to `PUBLIC`;
- grant unrestricted operational projections to `anon`;
- bypass organization/Haulvia-staff membership checks;
- turn `PLATFORM_ADMIN` into a bypass role.

Views and backend access must preserve the P2C command/read boundary.

Every P2F projection view must be created or hardened with `security_invoker = true`.

P2F must grant no direct projection access to `PUBLIC`, `anon` or `authenticated`.

P2F must not grant raw source-table access to `service_role` merely to make a projection queryable.

The six P2F views are internal minimized database projections. Future admin-UI exposure must use a purpose-built trusted server read boundary that rechecks the acting Haulvia staff identity, active Haulvia-organization membership and the specific existing permission required for that projection.

Existence of a P2F view is not, by itself, authorization to expose it to a client.

---

## 13. Concurrency model under test

P2F does not replace existing concurrency controls.

The harness validates the existing combination of:

- unique active/current indexes;
- `shipments.lock_version`;
- `route_executions.record_version`;
- row-level `FOR UPDATE` locking;
- command idempotency;
- event idempotency;
- provider idempotency;
- append-only event/evidence relations;
- first-valid-commit-wins semantics.

Test-only synchronization mechanisms may coordinate concurrent sessions.

Test-only synchronization must not create production locking semantics.

---

## 14. Multi-session race-harness requirements

P2F introduces:

`tests/haulvia_p2f_concurrency_harness_v1.ps1`

The harness must use genuinely separate PostgreSQL sessions/processes.

Sequential execution that merely simulates two actors is not authoritative concurrency proof.

Each race must capture:

- both session inputs;
- start synchronization evidence;
- completion order;
- exit/result classification;
- canonical post-race state;
- duplicate/orphan counts;
- rollback or disposable-database cleanup evidence.

---

## 15. Required race domains

### P2F-09 — Offer race

Concurrent actions against the same active offer/thread must preserve:

- valid revision ordering;
- counter limits;
- thread actionability;
- idempotency;
- no duplicate accepted logical outcome.

### P2F-10 — Reservation race

Two competing reservation attempts for the same shipment must result in at most one active reservation.

The losing operation must fail or no-op through an approved deterministic conflict path.

No orphan payment or pricing facts may remain.

### P2F-11 — Assignment race

Competing assignment creation/confirmation paths must result in at most one active assignment for the shipment.

Funding, reservation and selected-revision invariants must remain intact.

### P2F-12 — Stop-execution race

Two commands acting on the same route/stop position must respect the current route-execution record version and stop state.

A stale command must not overwrite a newer committed execution position.

### P2F-13 — Custody race

Concurrent custody-affecting actions must preserve the append-only custody ledger and quantity balance.

The race must not:

- double-load;
- double-unload;
- create negative onboard quantity;
- bypass verified-custody boundaries;
- resolve a route with unbalanced custody.

### P2F-14 — Receiver-review race

Concurrent receiver acceptance/problem-report actions against the same review window must produce one valid canonical outcome.

No duplicate downstream financial/dispute work may be created.

### P2F-15 — Payout race

Concurrent payout submit/retry/callback activity must preserve:

- one payout per assignment;
- provider/idempotency uniqueness;
- one valid provider outcome per logical request;
- no duplicate payout transaction;
- no duplicate money movement.

### P2F-16 — Recovery race

Concurrent recovery creation/activation attempts must preserve one current execution path and valid parent/recovery linkage.

No two active/recovery-active route executions may survive for one shipment where the existing invariant prohibits it.

---

## 16. General race acceptance rule

For every exclusive race:

1. exactly one valid logical winner may commit when exclusivity is required;
2. a loser must fail or return an approved idempotent/no-op result;
3. no loser may partially persist orphan operational facts;
4. no duplicate financial fact may remain;
5. no duplicate assignment/reservation/current execution may remain;
6. no custody imbalance may remain;
7. no audit/event idempotency invariant may be violated;
8. same-key replay must return/reuse the established logical result where the existing command contract requires replay;
9. same-key/different-request-hash reuse must fail closed;
10. the final database state must satisfy all existing constraints.

---

## 17. Local acceptance requirements

P2F local acceptance must prove at minimum:

### Projection structure

- all six required P2F projections exist;
- projections are derived from existing canonical sources;
- prohibited sensitive columns are absent;
- raw idempotency keys are absent from ordinary P2F projections;
- all six P2F views are `security_invoker = true`;
- `PUBLIC`, `anon` and `authenticated` have no direct P2F view access;
- no P2F projection is a replacement lifecycle table;
- `command_failure_observations` exists as a narrowly scoped append-only observability table rather than command lifecycle state;
- command-failure observations contain no raw request payload, raw error message, stack trace or unrestricted error context;
- the trusted failure-observation write path is not executable by `PUBLIC`, `anon` or `authenticated`;
- `service_role` may execute `command_record_command_failure_observation(jsonb)`;
- `OBSERVABILITY_WORKER` is not present as a human role or membership role;
- raw `command_failure_observations` access is not granted broadly;
- the shared command manifest contains exactly 86 `PRE_P2E`, 5 `P2E` and 1 `P2F` entry;
- the cumulative command manifest contains exactly 92 unique command entries;
- all 91 pre-existing command manifest identities/RPC mappings remain unchanged.

### Configuration

- all required P2F config definitions exist;
- definitions are deterministic/idempotent;
- no effective production threshold is seeded;
- configuration versions remain subject to existing approval/effective-date rules.

### Security

- raw P2E tables retain existing RLS/privilege closure;
- P2F does not grant raw protected-table access to `PUBLIC`, `anon` or unauthorized users;
- no broad write path is introduced;
- existing P2C permission and membership boundaries remain intact.

### Queue behavior

Transaction-local fixtures must prove each required attention classification and its negative case.

The `COMMAND_FAILED` acceptance case must not rely only on manually inserting `command_idempotency.status = 'FAILED'`.

Acceptance must prove the dedicated failure-observation path and demonstrate that a failed command can be represented after the failed command transaction has rolled back without persisting the rejected business mutation.

Transport-only failure must have a negative test proving it is not falsely recorded as a confirmed database-command rejection.

Acceptance must additionally prove:

- exact observation replay creates one observation row;
- a second observation key may represent a later distinct rejected invocation;
- the writer creates no `command_idempotency` row for itself;
- the writer does not recursively observe its own failure;
- simulated observation-write failure preserves the original normalized command failure;
- the observation path receives no raw request payload or raw idempotency key;
- the generic adapter still rejects unknown/unlisted RPC names.

### Rollback

Local acceptance must leave the pre-P2F database baseline unchanged after rollback.

---

## 18. Secret-safety requirements

P2F source, tests and evidence must contain no:

- production provider credential;
- webhook signing secret;
- database password;
- service-role key;
- customer payment secret;
- private document URL;
- plaintext protected credential.

Logs and generated evidence must redact or avoid protected values.

---

## 19. Hosted validation boundary

Authoritative hosted P2F validation occurs only after `haulvia-db-test` is intentionally resumed.

Hosted validation must be non-destructive except for explicitly approved disposable acceptance fixtures.

The hosted checklist must verify:

1. migration-history alignment;
2. P2F relation/view existence;
3. configuration definitions;
4. permission and RLS closure;
5. no broad raw-table grants;
6. admin-safe projection shape;
7. queue classification behavior;
8. concurrency harness execution against the hosted PostgreSQL concurrency model;
9. exact winner/loser evidence for each required race;
10. no orphan/duplicate facts after each race;
11. cleanup of disposable fixtures;
12. exact pass/fail counts;
13. repository artifact hashes used for the hosted run.

---

## 20. Required P2F artifacts

P2F v1 will produce:

- `docs/Haulvia_P2F_Observability_and_Concurrency_Contract_v1.md`
- `supabase/migrations/<timestamp>_haulvia_p2f_observability_and_concurrency_preparation_v1.sql`
- `tests/haulvia_p2f_acceptance_v1.sql`
- `tests/haulvia_p2f_concurrency_harness_v1.ps1`
- `tests/haulvia_p2f_final_gate_v1.ps1`
- `docs/Haulvia_P2F_Hosted_Validation_Checklist_v1.md`
- P2F failure-observation integration in `supabase/functions/_shared/haulvia-command-adapter.ts`
- the exact one-entry P2F extension to `supabase/functions/_shared/haulvia-command-manifest.ts`
- phase-aware command-manifest regression coverage preserving the original 86 + 5 P2E boundary while validating the new cumulative total of 92
- a permanent adapter acceptance test proving safe failure observation, observation replay, non-recursion, writer-failure isolation and transport-failure exclusion

Additional narrowly scoped fixture helpers are allowed when required by deterministic concurrency or observability testing.

---

## 21. Out of scope for P2F v1

P2F v1 does not:

- redesign shipment state machines;
- redesign offer negotiation;
- create a new job scheduler;
- create a new payment/payout model;
- create a new compliance model;
- create a new dispute model;
- create a new route/custody model;
- create a generic log warehouse;
- introduce a third-party monitoring vendor;
- assign arbitrary production alert thresholds;
- expose raw audit/provider/document payloads;
- implement customer-facing analytics;
- mutate hosted Supabase during the local-only stage.

---

## 22. P2F completion definition

P2F is complete only when:

1. the frozen contract is represented exactly by migration and tests;
2. local acceptance passes;
3. all required queue classifications pass positive and negative tests;
4. all required sensitive-field exclusions pass;
5. the multi-session harness is deterministic and locally runnable;
6. local rollback restores the pre-P2F baseline;
7. the final local P2F gate passes;
8. hosted validation is later completed after deliberate project resume;
9. authoritative hosted concurrency races pass;
10. the hosted validation checklist contains exact evidence and artifact hashes;
11. migration, contract, acceptance and harness artifacts are committed and pushed with a clean working tree.
