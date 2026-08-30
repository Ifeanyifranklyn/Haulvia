# Haulvia Command Contracts — Block D v1

**Approved source:** State Transition Matrix v1.1, Block D and its locked rules

**Scope:** Stop-level delivery review, irreversible operational completion, post-delivery dispute opening, driver payout, and authorized refund/adjustment initiation

**Implementation:** `20260814000500_haulvia_block_d_commands_v1.sql`

## 1. Shared command envelope

Every Block D entry point accepts one `jsonb` request. The trusted API/service layer supplies:

| Field | Rule |
|---|---|
| `commandId` | UUID correlation identifier. |
| `idempotencyKey` | Stable retry key for the actor and named command. |
| `requestHash` | SHA-256 hex of the canonical request. Reusing a key with another hash fails. |
| `shipmentId` | Shipment aggregate to lock. |
| `expectedShipmentVersion` | Must equal `shipments.lock_version`. A completed retry replays before this stale check. |
| `actorProfileId` | Profile UUID for customer/provider/admin actions; null for verified receiver links and approved workers. |
| `actorOrganizationId` | Required for organization-scoped customer/provider/admin authority. |
| `workerAuthority` | Required for system calls and restricted to the handler's exact approved worker. |

Receiver commands additionally carry the expected stop/window/resolved-route identifiers and versions plus a token ID and SHA-256 token proof. Payout callbacks carry the payout/request transaction, provider, event, amount, reference, occurrence time, and retained response payload. Sensitive admin calls carry a valid `reauthSessionId` and specific `reason`.

All handlers run inside the shared idempotent dispatcher. A matching completed request replays its stored response. Shipment, delivery-window, route-execution, assignment, payout, and provider-request rows are locked before mutation. Business records, immutable history, audit, notifications, and the retry result commit or roll back together.

The nine named wrappers remain revoked from `PUBLIC`; all 55 cumulative wrappers are granted only to `service_role` when that role exists. Internal dispatcher and helper functions are not granted.

## 2. Delivery-review boundary

When a Block C delivery stop becomes physically `COMPLETED`, `stop_executions_start_delivery_review` creates one immutable `delivery_review_windows` row:

- contactless delivery requires a receiver token and a positive `deliveryReviewSeconds` value from the shipment's retained policy snapshot;
- the token deadline must match that snapshotted duration;
- non-contactless delivery creates an immediate `NOT_REQUIRED` resolution;
- a unique window and unique resolution enforce first-valid-commit-wins per stop;
- the provisional 24-hour launch duration is configuration data (`86400` seconds in the acceptance policy), not command code.

## 3. D01 — `confirmReceiverReceipt`

**Entry point:** `haulvia_command.command_confirm_receiver_receipt(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | That stop's delivery-verification state `PENDING_RECEIVER_CONFIRMATION → RECEIVER_CONFIRMED`; shipment stays `DELIVERED`. |
| Actor | Verified external receiver using the exact unexpired, unused, unrevoked stop token with `confirmReceipt` permission. |
| Guards | Expected review window, stop, completed route execution, and route-execution version; response before deadline; cargo manifest exactly matches delivered allocation quantities and units. |
| Atomic writes | Append receiver confirmation and window resolution; mark token used; update only that stop and the resolved-route next action/version; append axis/audit/notification records. |
| Race rule | Row locks and unique stop/window results mean the first valid receiver response or expiry result wins. |

## 4. D02 — `reportDeliveryProblem`

**Entry point:** `haulvia_command.command_report_delivery_problem(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | That stop's delivery-verification state `PENDING_RECEIVER_CONFIRMATION → ISSUE_REPORTED`; shipment stays `DELIVERED`. |
| Actor | Verified external receiver using the exact token with `reportIssue` permission. |
| Required facts | `MISSING`, `DAMAGED`, `INCORRECT`, or `NOT_RECEIVED`; specific explanation; exact cargo/quantity manifest; non-empty evidence manifest; retained price-allocation basis. |
| Financial rule | Open a separate dispute and protect only the disputed amount that remains operationally available. Preserve requested, protected, and unprotected amounts. |
| Atomic writes | Append receiver confirmation, problem report, dispute/event, optional financial hold, and window resolution; update independent dispute/payout/verification axes; audit and notify. |
| Completion rule | `ISSUE_REPORTED` and its unresolved exception/dispute path block `completeShipment`; they do not rewrite the already resolved route or custody ledger. |

## 5. D03 — `expireConfirmationWindow`

**Entry point:** `haulvia_command.command_expire_confirmation_window(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | After the retained deadline, eligible evidence yields `VERIFIED_BY_PROOF_OF_DROP`; otherwise the stop becomes `EXCEPTION_REVIEW`. |
| Actor | Exact `RECEIVER_WINDOW_EXPIRY` worker. |
| Proof guard | Structured assessment identifies reviewer and policy rule and references only `VERIFIED` evidence reviews belonging to that stop. |
| No fabrication | No `receiver_confirmations` row is written. Resolution metadata explicitly records `receiverConfirmed: false`. |
| Exception path | Ineligible proof opens a completion-blocking route exception and changes the route next action to evidence review. |
| Race rule | Expiry locks the same unique window as receiver responses, so a later receiver response cannot replace the committed result. |

## 6. D04 — `openPostDeliveryDispute`

**Entry point:** `haulvia_command.command_open_post_delivery_dispute(jsonb)`

| Contract area | Requirement |
|---|---|
| Shipment state | Allowed in `DELIVERED` and `COMPLETED`; operational shipment state never changes. |
| Actor | Owning customer or retained whole-route assigned provider/driver. |
| Required facts | Stop/cargo scope when applicable, category, explanation, non-empty evidence, disputed amount/currency, accepted price snapshot, and allocation basis. |
| Financial rule | Protect `min(disputed amount, still-operationally-available amount)`. Retain any unprotected remainder rather than hiding it. |
| Independence | Dispute and financial-hold axes update independently. A `READY` payout becomes `HELD`; already submitted or paid provider work is preserved. |

## 7. D05 — `completeShipment`

**Entry point:** `haulvia_command.command_complete_shipment(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment `DELIVERED → COMPLETED`; terminal shipment becomes read-only. |
| Actor | `COMPLETION_WORKER`, or profile with sensitive `SHIPMENT_STATE_OVERRIDE`, fresh authentication, and a specific reason. |
| Physical guards | Immutable route resolution; completed route; active retained assignment; every delivery stop and evidence package complete; every applicable review window resolved to `NOT_REQUIRED`, `RECEIVER_CONFIRMED`, or `VERIFIED_BY_PROOF_OF_DROP`; no blocking workflow exception; zero custody balance. |
| Release guard | Non-empty authorization code/reason plus versioned payout allocation and retained accepted route price/policy snapshots. |
| Payout result | Create a whole-route payout and eligibility snapshot. State is `READY` when no protected amount remains, otherwise `HELD`. Public/internal disposition text is `HELD_FOR_PAYOUT`, not escrow. |
| Independence | Completion does not wait for bank settlement. Later disputes, refunds, adjustments, payout failure, and claims remain separate and cannot move the shipment backward. |

## 8. D06 — `submitDriverPayout`

**Entry point:** `haulvia_command.command_submit_driver_payout(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Aggregate payout `READY`, `HELD`, or retryable `FAILED → PROCESSING`; shipment remains `COMPLETED`. |
| Actor | `PAYOUT_WORKER`, or profile with sensitive `PAYOUT_MANAGE`, fresh authentication, and reason. |
| Guards | Retained whole-route payout eligibility; current valid payout account; positive amount no larger than net minus successful, outstanding, and active-held allocations. |
| Partial release | An undisputed share may be submitted while the exact disputed share remains protected. |
| Provider idempotency | Append one `PENDING` request transaction keyed by payout/provider idempotency and retain account reference, provider request, and financial allocation snapshot. |

## 9. D07 — `confirmDriverPayout`

**Entry point:** `haulvia_command.command_confirm_driver_payout(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | Exact `PAYOUT_PROVIDER_CALLBACK` worker carrying a provider result. |
| Guards | Event matches one outstanding request's payout, provider, amount, and currency. Provider event IDs are unique when present. |
| Atomic writes | Append a `SUCCEEDED` outcome linked to its request; retain provider reference/event/time/payload/allocation; recompute aggregate paid, pending, and held amounts. |
| Aggregate state | `PAID` when successful allocations equal the whole net payout; otherwise `PROCESSING`, `HELD`, or `READY` according to remaining work. |
| Duplicate callback | A matching already committed provider event returns `duplicateProviderEvent: true`; conflicting reuse fails. |

## 10. D08 — `handlePayoutFailure`

**Entry point:** `haulvia_command.command_handle_payout_failure(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | Exact `PAYOUT_PROVIDER_CALLBACK` worker. |
| Transition | Append `FAILED` provider outcome; aggregate payout becomes `FAILED` when no other request is outstanding, otherwise remains `PROCESSING`. |
| Preservation | Original request and failure payload remain immutable. Shipment remains `COMPLETED`. |
| Retry | A new provider idempotency key may submit the still-available amount. Failed attempts are excluded from paid/pending totals but never deleted. |

## 11. D09 — `issueRefundOrAdjustment`

**Entry point:** `haulvia_command.command_issue_refund_or_adjustment(jsonb)`

| Contract area | Requirement |
|---|---|
| Shipment state | Allowed in `DELIVERED` and `COMPLETED`; physical state remains unchanged. |
| Actor | Profile with sensitive `FINANCIAL_ADJUST`, fresh authentication, and a specific reason. |
| Scope | Separate shipment transaction with optional route execution, stop, and cargo links; exact policy, authorization, and provider request snapshots are retained. |
| Customer charge | Requires explicit customer approval evidence. No unilateral charge or off-platform payment path exists. |
| Refund | Uses the retained payment intent and original provider path; successful cumulative refunds cannot exceed the original collected amount. |
| Driver compensation | Links a separate payout transaction and increases the retained payout adjustment/net amount without rewriting shipment history. |
| Idempotency | One `financial_adjustments` record and provider transaction per provider idempotency key. |

## 12. Block D append-only records

| Table | Purpose |
|---|---|
| `delivery_review_windows` | Exact stop deadline, policy version, duration, token, and timing snapshot created when delivery evidence is verified. |
| `delivery_review_window_resolutions` | One first-valid receiver, proof, issue, exception, or non-required result per window/stop. |
| `delivery_problem_reports` | Receiver issue, cargo references, evidence, dispute, and disputed/protected amount split. |
| `payout_eligibility_records` | Whole-route evidence/window, accepted price, policy, allocation, hold, and release-authorization snapshot. |
| `shipment_completion_records` | Immutable proof for irreversible `COMPLETED` and its separately created payout. |

`receiver_confirmations`, `payout_transactions`, `financial_adjustments`, workflow-axis events, shipment events, and audit remain append-only. Mutable current rows (`stop_executions`, payout axes, `driver_payouts`) are only pointers/summaries over retained history.

## 13. Stable rejection codes exercised by the suite

| Code | Meaning |
|---|---|
| `DELIVERY_REVIEW_NOT_FOUND` | Expected stop/window relationship was not found. |
| `DELIVERY_REVIEW_ALREADY_RESOLVED` | Another valid receiver/expiry result won first. |
| `RECEIVER_NOT_VERIFIED` | Token proof, permission, scope, or one-use condition failed. |
| `DELIVERY_REVIEW_ACTIVE` / `DELIVERY_REVIEW_EXPIRED` | Expiry fired too early or receiver answered too late. |
| `CARGO_REFERENCE_INVALID` | Receiver cargo allocation, quantity, or unit differs from verified delivery outcomes. |
| `DELIVERY_REVIEW_UNRESOLVED` | Completion still has pending/issue/exception verification or missing evidence/window resolution. |
| `RELEASE_AUTHORIZATION_REQUIRED` | Completion lacks a retained authorization code/reason. |
| `PAYOUT_ALLOCATION_INVALID` | Driver allocation does not reconcile to accepted pricing/currency/formula. |
| `PAYOUT_NOT_ELIGIBLE` / `PAYOUT_AMOUNT_UNAVAILABLE` | Whole-route eligibility is absent or submitted amount exceeds paid/pending/held-adjusted availability. |
| `PAYOUT_REQUEST_MISMATCH` / `PROVIDER_EVENT_CONFLICT` | Callback does not match an outstanding request or reuses an event inconsistently. |
| `FRESH_AUTH_REQUIRED` | Sensitive action lacks current password/passkey/MFA proof. |
| `CUSTOMER_APPROVAL_REQUIRED` | Additional charge lacks explicit retained customer approval. |
| `REFUND_AMOUNT_INVALID` | Refund exceeds the original collected amount. |

## 14. Verification

`haulvia_block_d_acceptance_v1.sql` is rollback-only. It exercises all nine Block D entry points, automatic versioned window start, receiver replay, first-stop result uniqueness, problem evidence/dispute/hold, proof-based expiry, non-fabricated confirmation, exception review, irreversible completion, READY/HELD eligibility, full payout success, duplicate callback handling, disputed-only holds, undisputed partial release, payout failure/retry, fresh-auth rejection, refund issuance, append-only records, cumulative schema shape, and wrapper-only service-role authority.

The complete Foundation → Block A → Block B → Block C → Block D chain and all five suites execute successfully in a PostgreSQL-compatible runtime. Hosted PostgreSQL/Supabase still needs true multi-session race tests, provider sandbox webhooks, RLS, and API-adapter tests before production exposure.
