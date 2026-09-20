# Haulvia P2E Provider Adapters and Webhooks Contract v1

Status: FROZEN DESIGN CANDIDATE  
Phase: P2E  
Scope: Provider-neutral financial integration and backend command-adapter boundary  
Hosted Supabase changes: NONE during local P2E development

---

## 1. Purpose

P2E adds the external-provider integration boundary around Haulvia's existing
financial and command-domain model.

P2E does not replace or duplicate the existing financial source of truth.

The existing Haulvia domain remains authoritative for:

- customer payment state;
- payment intents;
- payment transactions;
- driver payout state;
- driver payouts;
- payout transactions;
- financial holds;
- financial adjustments;
- shipment and assignment state;
- command authorization and idempotency.

External payment or payout providers execute financial operations, but provider
objects and provider events are evidence used to reconcile Haulvia's canonical
domain state.

---

## 2. Existing financial model preserved

The following existing structures remain canonical:

- haulvia.customer_payment_method_refs
- haulvia.shipment_customer_payment_axes
- haulvia.shipment_driver_payout_axes
- haulvia.payment_intents
- haulvia.payment_transactions
- haulvia.driver_payouts
- haulvia.payout_transactions
- haulvia.financial_holds
- haulvia.financial_adjustments

P2E must not create a second payment-intent, payout, refund, adjustment, or
financial-state model.

`customer_payment_method_refs` remains an opaque provider-reference model.
Haulvia must not store raw card numbers, CVVs, bank credentials, provider API
keys, webhook signing secrets, or equivalent sensitive provider credentials.

---

## 3. Existing command boundary

At the P2E starting checkpoint, the repository contains 86 existing
`haulvia_command.command_*` wrappers.

P2E may add new P2E-specific wrappers, but the existing 86 command wrappers
must remain present and retain their existing domain responsibilities.

The backend command adapter must use an explicit allowlist/manifest.

It must never expose:

- arbitrary SQL execution;
- dynamic function-name execution;
- internal `apply_*` functions;
- authority helpers;
- raw table mutation;
- SECURITY DEFINER helper invocation outside an approved public wrapper.

---

## 4. Existing financial-provider behavior preserved

Customer payment flow already includes:

- payment-method verification;
- AUTHORIZING payment intents;
- provider-confirmed secured payment;
- exact amount and currency validation;
- payment transaction persistence;
- assignment creation only after successful funding;
- failed or timed-out reservation release;
- late-success reversal queueing;
- cancellation/expiry authorization-void queueing.

Driver payout flow already includes:

- eligible payout calculation;
- outbound payout submission;
- provider-level idempotency;
- PENDING payout request transactions;
- provider callback reconciliation;
- duplicate provider-event replay;
- provider-event conflict rejection;
- one provider outcome per payout request;
- partial payout accounting;
- hold-aware payout availability;
- payout failure handling.

P2E must integrate with those paths rather than create parallel paths.

---

## 5. Worker-authority separation

Outbound customer-payment work uses `PAYMENT_WORKER`.

Inbound verified customer-payment provider outcomes use the new dedicated
worker authority:

`PAYMENT_PROVIDER_CALLBACK`

P2E must prospectively update the relevant customer-payment provider-outcome
paths so that provider callbacks do not rely on generic outbound
`PAYMENT_WORKER` authority.

Outbound payout work continues to use `PAYOUT_WORKER`.

Inbound payout provider outcomes continue to use:

`PAYOUT_PROVIDER_CALLBACK`

Worker authorities must remain outside the human RBAC role catalog.

---

## 6. Provider-neutral integration records

P2E v1 may introduce the following provider-neutral integration relations:

- `provider_adapter_requests`
- `provider_adapter_attempts`
- `provider_webhook_events`
- `provider_webhook_dispatches`

These records are integration evidence and observability records.

They are not a replacement financial ledger.

No table, enum, function, permission, or constraint may be named for Stripe,
Adyen, PayPal, Square, or another concrete provider.

---

## 7. Outbound provider operations

P2E v1 recognizes these provider-neutral financial operations:

- PAYMENT_AUTHORIZE
- PAYMENT_CAPTURE
- PAYMENT_VOID
- CUSTOMER_REFUND
- DRIVER_PAYOUT
- FINANCIAL_ADJUSTMENT

A provider adapter request must identify:

- canonical request UUID;
- provider;
- operation;
- correlation ID;
- provider idempotency key;
- relevant shipment;
- relevant canonical financial entity when applicable;
- sanitized request snapshot;
- creation time;
- current integration status.

Provider integration status must describe adapter execution, not redefine
Haulvia financial state.

---

## 8. Outbound request lifecycle

The P2E adapter-request lifecycle is:

- PREPARED
- SUBMITTED
- SUBMISSION_FAILED
- CANCELLED

`SUBMITTED` means that the outbound request was accepted for provider
processing.

It does not independently mean that payment, refund, payout, or adjustment
succeeded.

Canonical financial success or failure remains represented by the existing
Haulvia financial domain.

---

## 9. Adapter attempts

Each outbound provider request may have one or more execution attempts.

Attempts are append-only.

Each attempt must record enough normalized information to determine:

- which request was attempted;
- attempt sequence number;
- when execution began and ended;
- provider;
- correlation ID;
- whether submission succeeded;
- normalized provider result;
- normalized error category;
- safe provider status/reference metadata;
- whether retry is appropriate.

Attempts must not store:

- API keys;
- Authorization headers;
- webhook secrets;
- raw card data;
- CVVs;
- bank credentials;
- access tokens;
- refresh tokens.

---

## 10. Normalized provider errors

P2E must normalize provider-specific failures into provider-neutral categories.

At minimum, the model must distinguish:

- AUTHENTICATION_ERROR
- INVALID_PROVIDER_REQUEST
- INVALID_PROVIDER_RESPONSE
- RATE_LIMITED
- TEMPORARY_PROVIDER_ERROR
- PERMANENT_PROVIDER_ERROR
- TIMEOUT
- NETWORK_ERROR
- UNKNOWN_PROVIDER_ERROR

Provider-specific error codes may be retained only as supplemental sanitized
metadata.

Haulvia command/domain errors remain distinct from provider transport errors.

---

## 11. Provider request idempotency

Provider request identity is independent from Haulvia command idempotency, but
both must be preserved.

For a provider and financial operation, reuse of the same provider
idempotency key with identical facts must replay safely.

Reuse of the same provider idempotency key with materially different facts
must fail closed.

Adapter retries must never bypass the existing Haulvia command-idempotency
contract.

---

## 12. Correlation

Every P2E provider operation must have a correlation ID.

The same correlation context must be traceable across, where applicable:

- backend command invocation;
- provider adapter request;
- provider adapter attempt;
- provider event;
- provider event dispatch;
- canonical payment/payout transaction;
- audit record.

Correlation IDs are observability identifiers, not authorization credentials.

---

## 13. Webhook ingress

Provider webhook/event ingress must be provider-neutral.

Each accepted event must preserve:

- canonical event UUID;
- provider;
- provider event ID;
- provider event type;
- received timestamp;
- provider occurrence timestamp when supplied;
- lowercase SHA-256 body digest;
- signature-verification result;
- verifier identity/context;
- normalized sanitized event snapshot;
- correlation context where resolvable.

Raw signing secrets must never be persisted.

---

## 14. Signature verification

No provider event may invoke a financial domain command until its provider
signature has been successfully verified by a trusted backend boundary.

Client roles cannot assert that a signature was verified.

The database may receive trusted verification facts from an authorized
provider-callback worker, but P2E must not place live webhook secrets in SQL,
fixtures, migrations, repository files, or database rows.

Verification metadata may include a safe provider key/version identifier.

It must not contain the secret itself.

---

## 15. Webhook replay and conflict protection

For a given provider, a non-null provider event ID identifies one provider
event.

The same provider event ID and same body digest must replay safely without
performing a second domain mutation.

The same provider event ID with a different body digest must fail closed as a
provider-event conflict.

A provider event may have at most one successfully committed domain dispatch.

Failed processing attempts may be retained as separate append-only dispatch
records.

---

## 16. Webhook dispatch

Provider-specific event names must be normalized before invoking the Haulvia
domain.

A webhook dispatch must identify:

- provider event;
- normalized financial operation;
- normalized outcome;
- target public Haulvia command;
- correlation ID;
- dispatch attempt;
- command idempotency context;
- result or normalized failure.

Unknown or unsupported provider events must not mutate financial domain state.

---

## 17. Customer payment provider outcomes

A verified successful customer-payment provider outcome must reconcile through
the existing `confirmPaidAssignment` domain behavior.

It must continue to require:

- the expected payment intent;
- the expected reservation;
- exact secured amount;
- exact shipment currency;
- current reservation/funding window;
- provider event identity;
- valid route context;
- current provider/driver/vehicle eligibility.

Payment provider callbacks must use `PAYMENT_PROVIDER_CALLBACK`.

They must not use customer authority or generic client credentials.

---

## 18. Customer payment failure and timeout

Verified payment failure or timeout must reconcile through the existing
failed-reservation behavior.

It must preserve:

- release of the reservation;
- payment intent failure/timed-out state;
- restoration of marketplace state when appropriate;
- no assignment creation;
- exact provider-event persistence.

A late provider success received after reservation release must not create an
assignment.

The existing late-success reversal job behavior must remain intact.

---

## 19. Payment authorization voids

Existing cancellation and expiry behavior that queues
`VOID_PAYMENT_AUTHORIZATION` must remain intact.

P2E may provide the adapter implementation that executes the external void,
but it must not bypass the existing cancellation or expiry commands.

---

## 20. Driver payout provider behavior

The existing outbound payout request model remains canonical.

P2E must preserve:

- `PAYOUT_WORKER` for outbound payout work;
- `PAYOUT_PROVIDER_CALLBACK` for inbound provider outcomes;
- provider payout idempotency;
- duplicate provider-event replay;
- `PROVIDER_EVENT_CONFLICT`;
- outstanding-request matching;
- one outcome per payout request;
- partial payout accounting;
- financial-hold protection.

---

## 21. Refunds and adjustments

Refunds, customer credits/charges, and driver compensation remain governed by
the existing `issueRefundOrAdjustment` domain command.

P2E must not bypass:

- `FINANCIAL_ADJUST`;
- sensitive-command authorization;
- required reauthentication;
- authorization snapshots;
- explicit customer approval for additional customer charges;
- refund amount ceilings;
- existing canonical financial adjustment records.

Provider adapter records supplement those records; they do not replace them.

---

## 22. Existing provider-event uniqueness

P2E must preserve the existing payment provider-event uniqueness rule:

`(external_provider, provider_event_id)`

for non-null payment provider event IDs.

P2E must preserve the equivalent payout provider-event uniqueness rule.

P2E must preserve the rule that a payout request transaction has at most one
provider outcome transaction.

---

## 23. Backend command adapter

The P2E backend command adapter must expose an explicit mapping to approved
`haulvia_command.command_*` functions.

The baseline manifest must account for all 86 existing wrappers.

An unrecognized command name must be rejected.

The adapter must not derive executable SQL identifiers directly from
untrusted request input.

P2E-specific wrappers added later must be explicitly added to the manifest.

---

## 24. Command result normalization

The backend adapter must return a consistent result envelope containing, at
minimum:

- success/failure;
- command name;
- correlation ID;
- command result on success;
- Haulvia error code on domain failure;
- safe error details where supplied;
- provider/transport error classification when relevant.

The adapter must not convert a domain rejection into a provider success or
silently suppress a Haulvia command error.

---

## 25. Security and privileges

All P2E base tables must have RLS enabled.

P2E must grant no raw integration-table privileges to:

- PUBLIC;
- anon;
- authenticated.

`service_role` must not receive broad raw-table access merely because it is a
backend role.

Mutations must occur through narrowly scoped trusted wrappers.

P2E SECURITY DEFINER functions must:

- use controlled pinned search paths;
- exclude `public` from the search path;
- include `pg_temp`;
- not be owned by anon or authenticated;
- not expose internal helpers directly to client roles.

---

## 26. Worker-role separation

`PAYMENT_PROVIDER_CALLBACK` is a worker authority, not a human RBAC role.

It must be protected by the established worker-authority role-rejection
mechanism.

P2E must not grant `PAYMENT_PROVIDER_CALLBACK` as a human organization role.

---

## 27. Secrets and sensitive provider data

P2E migrations, tests, fixtures, logs, audit metadata, request snapshots, and
event snapshots must not contain live provider credentials.

The P2E database model must not become a secret store.

Live provider credentials and webhook signing secrets are deployment/runtime
configuration and remain outside the P2E database contract.

---

## 28. Provider payload retention

Provider request and response snapshots must be sanitized before persistence.

The contract permits retention of provider evidence needed for:

- reconciliation;
- debugging;
- audit;
- dispute investigation;
- idempotency;
- correlation.

It does not permit persistence of unnecessary authentication material or raw
payment credentials.

---

## 29. No live-provider dependency

P2E acceptance must run without:

- Stripe credentials;
- another payment-provider account;
- network access;
- hosted webhook endpoints;
- hosted Supabase modification.

Provider behavior must be testable with deterministic mock adapter inputs.

---

## 30. Historical migration preservation

P2E must not edit the frozen historical P2A, P2B, P2C, or P2D migrations.

Changes to existing financial functions required by P2E must be made
prospectively in the P2E migration with `CREATE OR REPLACE` or equivalent
forward migration logic.

---

## 31. Existing command count baseline

P2E begins with exactly 86 existing named `command_*` wrappers.

P2E acceptance must prove that all 86 pre-P2E wrappers still exist after the
P2E migration.

New P2E wrappers may increase the total wrapper count.

The baseline 86 must not disappear or silently change into internal-only
entry points.

---

## 32. Existing financial source of truth

Provider adapter requests, attempts, events, and dispatches must never be used
as the sole basis for deciding that:

- payment is secured;
- a shipment may be assigned;
- a refund completed;
- a payout completed;
- a payout failed;
- an adjustment is authorized.

Those business facts must remain represented by the existing canonical Haulvia
domain commands and financial records.

---

## 33. Acceptance requirements

P2E acceptance must include deterministic local tests for at least:

- provider-neutral schema;
- absence of provider-branded database identifiers;
- outbound provider-request creation;
- identical provider-request replay;
- conflicting provider-idempotency reuse;
- append-only request attempts;
- normalized temporary failure;
- normalized permanent failure;
- normalized timeout;
- webhook signature-verification gate;
- exact webhook replay;
- conflicting webhook-body replay;
- one committed domain dispatch per provider event;
- successful customer payment callback;
- failed customer payment callback;
- late customer-payment success without assignment creation;
- payout submission;
- payout success callback;
- payout failure callback;
- duplicate payout callback;
- conflicting payout event;
- refund/adjustment authority preservation;
- no raw secrets persisted;
- RLS;
- raw-table privilege denial;
- SECURITY DEFINER hardening;
- worker-authority separation;
- all 86 pre-P2E command wrappers preserved;
- P2A/P2B/P2C/P2D regression invariants.

---

## 34. Frozen P2E requirements

P2E-01: P2E remains provider-neutral and introduces no provider-branded database identifiers.

P2E-02: Existing Haulvia financial tables remain the canonical financial source of truth.

P2E-03: P2E integration records supplement rather than duplicate payment, payout, refund, or adjustment state.

P2E-04: P2E requires no live provider credentials, network calls, or hosted resources for acceptance.

P2E-05: Raw card data, CVVs, bank credentials, API keys, signing secrets, and access tokens are never persisted.

P2E-06: `customer_payment_method_refs` remains an opaque provider-reference abstraction.

P2E-07: All 86 pre-P2E named command wrappers remain present.

P2E-08: The backend command adapter uses an explicit allowlist/manifest for approved command wrappers.

P2E-09: Unknown commands, internal helpers, and non-command functions cannot be invoked through the backend command adapter.

P2E-10: P2E does not introduce a generic dynamic-SQL execute-by-name command gateway.

P2E-11: Backend command results use a normalized success/error envelope with command and correlation context.

P2E-12: Existing Haulvia domain error codes and safe error details are preserved through the adapter boundary.

P2E-13: Adapter retries preserve existing command-idempotency semantics and cannot bypass request-hash mismatch protection.

P2E-14: Provider operations carry a traceable correlation ID.

P2E-15: A provider-neutral outbound adapter-request relation exists.

P2E-16: Provider adapter requests use canonical UUID identity.

P2E-17: P2E v1 supports PAYMENT_AUTHORIZE, PAYMENT_CAPTURE, PAYMENT_VOID, CUSTOMER_REFUND, DRIVER_PAYOUT, and FINANCIAL_ADJUSTMENT operations.

P2E-18: Provider adapter requests link to the relevant shipment and canonical financial entity where applicable.

P2E-19: External provider and provider idempotency key are required and nonblank for outbound provider requests.

P2E-20: Provider, operation, and provider idempotency key cannot identify conflicting outbound request facts.

P2E-21: Persisted provider request snapshots are sanitized and contain no provider authentication secrets.

P2E-22: Provider adapter request lifecycle is PREPARED, SUBMITTED, SUBMISSION_FAILED, or CANCELLED.

P2E-23: SUBMITTED represents provider submission, not canonical financial success.

P2E-24: Provider adapter execution attempts are append-only.

P2E-25: Adapter attempt sequence is unique within one provider request.

P2E-26: Adapter attempts retain timestamps, correlation, normalized result/error, and safe provider-response metadata.

P2E-27: Adapter attempts cannot persist authorization headers, signing secrets, payment credentials, or equivalent secrets.

P2E-28: A provider-neutral webhook/event ingress relation exists.

P2E-29: Provider event identity is unique for a provider when a provider event ID is present.

P2E-30: Every accepted provider event retains a lowercase SHA-256 digest of the signed event body.

P2E-31: Provider event ingress facts are immutable after acceptance.

P2E-32: A provider event cannot dispatch a financial domain command until signature verification succeeded.

P2E-33: Signature-verification provenance is attributable without persisting webhook secrets or raw authentication material.

P2E-34: Same provider event ID plus same body digest replays without a second financial mutation.

P2E-35: Same provider event ID plus a different body digest fails closed as a provider-event conflict.

P2E-36: Webhook dispatch history is append-only and permits at most one successfully committed domain dispatch per provider event.

P2E-37: Provider-specific event types are normalized before domain-command dispatch.

P2E-38: Successful customer-payment provider outcomes reconcile through the existing `confirmPaidAssignment` domain behavior using `PAYMENT_PROVIDER_CALLBACK`.

P2E-39: Customer-payment failure or timeout reconciles through existing failed-reservation behavior using `PAYMENT_PROVIDER_CALLBACK`.

P2E-40: Late customer-payment success cannot create an assignment and preserves the existing reversal-queue behavior.

P2E-41: Payout submission and payout callback behavior preserve the existing `PAYOUT_WORKER` / `PAYOUT_PROVIDER_CALLBACK` authority split and payout reconciliation invariants.

P2E-42: Refunds and adjustments continue through the existing sensitive `issueRefundOrAdjustment` authority and reauthentication path.

P2E-43: Existing cancellation and expiry payment-authorization void queue behavior remains intact.

P2E-44: Existing payment/payout provider-event uniqueness and one-outcome-per-payout-request protections remain intact.

P2E-45: All P2E base tables use RLS and expose no raw integration-table privileges to PUBLIC, anon, authenticated, or broad service-role table access.

P2E-46: P2E SECURITY DEFINER functions use controlled pinned search paths, safe ownership, and wrapper-only execution.

P2E-47: `PAYMENT_PROVIDER_CALLBACK` remains a worker authority rather than a human RBAC role, and P2E preserves all P2A/P2B/P2C/P2D security and authority invariants.

P2E-48: P2E acceptance uses deterministic mocks to prove outbound retry/idempotency, webhook signature/replay/conflict behavior, payment and payout outcomes, adjustment authority, secret absence, the 86-wrapper baseline, and all P2E security invariants without modifying hosted Supabase.

---

## 35. Implementation boundary

The P2E migration and adapter implementation must be derived from this frozen
contract.

If implementation discovery proves that a requirement is structurally
impossible or contradicts an already-frozen earlier-phase invariant, stop and
amend the contract explicitly before implementing a workaround.

Do not silently weaken an earlier invariant.

---

End of Haulvia P2E Provider Adapters and Webhooks Contract v1.
