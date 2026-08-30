# Haulvia Command Contracts — Block E v1

**Approved source:** State Transition Matrix v1.1, Block E and its locked rules

**Scope:** Cancellation boundaries, failed-stop decisions, custody transfer, linked recovery, storage, return, disputes, controlled resumption, and terminal-shipment reposting

**Implementation:** `20260814000600_haulvia_block_e_commands_v1.sql`

## 1. Shared command envelope

Every Block E entry point accepts one `jsonb` request through a named security-definer wrapper.

| Field | Rule |
|---|---|
| `commandId` | UUID correlation identifier. |
| `idempotencyKey` | Stable retry key for the actor and named command. |
| `requestHash` | SHA-256 hex of the canonical request. Reusing a key with another hash fails. |
| `shipmentId` | Shipment aggregate to lock. |
| `expectedShipmentVersion` | Must equal `shipments.lock_version`; a completed matching retry replays before this stale check. |
| `actorProfileId` | Customer/provider/admin profile UUID; null only for an exact approved worker authority. |
| `actorOrganizationId` | Organization scope for customer membership or permission checks. |
| `workerAuthority` | Exact trusted worker code accepted by that handler. |
| `reason` | Specific retained explanation; sensitive commands require at least eight characters. |
| `reauthSessionId` | Current password, passkey, or MFA proof for profile-driven sensitive commands. |

Route commands also carry the retained `expectedRouteVersionId`, `expectedAssignmentId`, `expectedRouteExecutionId`, and `expectedRouteExecutionVersion`. Stop commands carry `expectedStopExecutionId` or `expectedNextStopExecutionId`. Custody-dependent commands supply an exact `custodyBalance`/`custodyBalanceSnapshot` copied from the current append-only movement ledger.

The dispatcher claims `command_idempotency`, locks current aggregate rows, executes one approved handler, returns the merged operating context, and stores the response in the same transaction. The 15 new wrappers are revoked from `PUBLIC`; E04 reuses the existing `command_expire_listing`, producing 70 cumulative wrappers for Foundation plus Blocks A–E. Only named `command_*` wrappers are granted to `service_role`; internal helpers and dispatchers are not.

## 2. Locked Block E rules

1. Every failed stop and every retry is a separate immutable fact. A retry never changes a prior failed attempt into success.
2. Ordinary cancellation, release, or automatic repost is prohibited after the first verified `LOAD`.
3. Post-custody inability is resolved through verified transfer, linked recovery/redelivery/return, or approved storage—not by erasing the route.
4. A recovery segment creates a new route version, execution, and price snapshot. It never overwrites original route or accepted-price history.
5. Dispute finance and physical movement are independent. A dispute stops movement only when unsafe, unlawful, or formally held.
6. Terminal shipments remain immutable. Reposting creates a distinct `DRAFT` linked by `source_shipment_id` and `terminal_shipment_reposts`.

## 3. E01 — `cancelDraft`

**Entry point:** `haulvia_command.command_cancel_draft(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment `DRAFT → CANCELLED`; marketplace becomes `CLOSED`; customer-payment axis becomes `RELEASED`. |
| Actor | Owning customer profile or active member of the owning customer organization. |
| Guards | No verified custody and no active/completed assignment history. |
| Required facts | Specific reason and optional policy/cancellation snapshot. |
| Atomic writes | Append cancellation snapshot, axis events, terminal shipment event, audit, and notification. No financial provider action is created. |

## 4. E02 — `cancelMarketplaceShipment`

**Entry point:** `haulvia_command.command_cancel_marketplace_shipment(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment `POSTED` or `NEGOTIATING → CANCELLED`; marketplace closes and funding is released. |
| Actor | Owning customer. |
| Guards | Expected active route, zero verified custody, and no committed/completed assignment. |
| Atomic writes | Close offer threads, release any reservation, mark an in-flight payment intent `VOIDED`, append cancellation/events/audit, and queue the provider void job when needed. |

## 5. E03 — `cancelAssignedBeforeCustody`

**Entry point:** `haulvia_command.command_cancel_assigned_before_custody(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | `DRIVER_ASSIGNED` or pre-custody `ROUTE_IN_PROGRESS → CANCELLED`; assignment and any current execution close. |
| Actor | Owning customer. |
| Guards | Expected active route/assignment and execution when in progress; no verified custody milestone or `LOAD`. |
| Financial rule | Versioned policy, responsibility, charge, refund, driver compensation, and currency must exactly reconcile to secured funds. |
| Atomic writes | Append `pre_custody_financial_decisions`, close assignment/execution/stops, update payment and marketplace axes, queue settlement, and append events/audit/notification. |

## 6. E04 — `expireListing`

**Entry point:** existing `haulvia_command.command_expire_listing(jsonb)`

Block E deliberately introduces no duplicate wrapper. The existing Block A contract remains authoritative: exact `EXPIRY_WORKER`, elapsed marketplace deadline, `POSTED`/`NEGOTIATING`, and no active assignment. It expires offers/reservation, times out any pending authorization, closes the listing, releases the payment axis, and makes the shipment terminal `EXPIRED`.

## 7. E05 — `retryFailedStopSameDriver`

**Entry point:** `haulvia_command.command_retry_failed_stop_same_driver(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current stop `FAILED → ARRIVED` through a new attempt; route returns to `ACTIVE` or `RECOVERY_ACTIVE`. |
| Actor | Assigned driver or authorized route operator. |
| Guards | Finalized failed attempt, unresolved linked exception, still-active assignment, and retained `serviceable`, `assignmentValid`, and assessment code. |
| Hold rule | A linked active movement hold must be named and explicitly released. |
| Preservation | `stop_retry_records` links the immutable failed and retry attempts; the old attempt remains `FAILED` and ended. |

## 8. E06 — `prepareFailedFirstPickupRepost`

**Entry point:** `haulvia_command.command_prepare_failed_first_pickup_repost(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Failed first pickup with zero custody: `ROUTE_IN_PROGRESS → POSTED`, marketplace `PAUSED`, execution/assignment closed. |
| Actor | Owning customer or exact authorized route workflow. |
| Guards | First route stop is a failed `PICKUP`; route cannot continue; unresolved exception; zero verified custody. |
| Financial rule | Retain an exactly reconciled pre-custody policy decision. |
| No auto-repost | `automaticRepublish` is false. Customer must review and deliberately post again. |

## 9. E07 — `closeFailedFirstPickup`

**Entry point:** `haulvia_command.command_close_failed_first_pickup(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Failed first pickup with zero custody: `ROUTE_IN_PROGRESS → CANCELLED` or `EXPIRED`. |
| Actor | Customer for `CANCELLED`; exact expiry/route worker plus elapsed deadline for `EXPIRED`. |
| Guards | Expected route/assignment/execution, failed first pickup, unresolved exception, zero custody. |
| Atomic writes | Close stops, execution, tracking, assignment, exception, marketplace, and payment axes; append retained financial and failed-pickup resolution records. |

## 10. E08 — `continueRouteAfterFailedStop`

**Entry point:** `haulvia_command.command_continue_route_after_failed_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Failed stop remains `FAILED`; next eligible stop gets a new `EN_ROUTE` attempt. |
| Actor | Customer or authorized route workflow. |
| Required decision | `SKIP`, `RECOVERY`, `AMENDMENT`, `RETURN`, `REDELIVERY`, `ALTERNATE_DESTINATION`, `TRANSFER`, or `STORAGE`. |
| Guards | Retained failure report; route, capacity, timing, custody, and feasibility all revalidated; exact customer instructions; no active movement hold. |
| Pickup skip | Append `APPROVED_NOT_LOADED` outcomes for affected allocation quantities; do not create false cargo movements. |
| Preservation | `stop_continuation_authorizations` is separate from the failed attempt/report and names the newly started stop. |

## 11. E09 — `authorizeCustodyTransfer`

**Entry point:** `haulvia_command.command_authorize_custody_transfer(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | `CUSTODY_TRANSFER_WORKER`, or profile with sensitive `CUSTODY_TRANSFER_AUTHORIZE`, current reauthentication, and reason. |
| Guards | In-progress current route; positive custody; complete transfer manifest exactly matching every onboard stable cargo key/unit/quantity; eligible different replacement provider/driver/vehicle. |
| Handoff evidence | QR or PIN verified, GPS and captured time, both drivers confirmed, at least one retained photo, and non-empty authority snapshot. |
| Assignment result | Prior assignment becomes `TRANSFERRED`; a new active whole-route assignment is created using the retained accepted price. Current execution points to it. |
| Custody rule | Physical custody balance is unchanged. `custody_transfers`, items, and `custody_transfer_authorizations` preserve the verified handoff. |

## 12. E10 — `startRecoveryLeg`

**Entry point:** `haulvia_command.command_start_recovery_leg(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | `RECOVERY_WORKER`, or profile with sensitive `SHIPMENT_STATE_OVERRIDE`, fresh authentication, and reason. |
| Recovery type | `RECOVERY`, `RETURN`, or `REDELIVERY`; approved action code names return, alternate delivery, redelivery, storage, transfer, or other recovery. |
| Guards | Positive exact custody snapshot; provider acceptance by current driver; destination/reason snapshot; new route retains every onboard stable cargo key/unit/quantity. |
| Price/payment | Create a distinct `ADJUSTMENT` price snapshot equal to `additionalPaymentAmount`. Positive non-emergency work requires a separately secured intent; emergency work may create a completion-only payment-due hold. |
| Lineage | Old route becomes `SUPERSEDED`, old execution `COMPLETED`; new route becomes `ACTIVE`, and a child `RECOVERY_ACTIVE` execution starts. `recovery_route_records` links both pairs and the new price. |

## 13. E11 — `secureCargoInStorage`

**Entry point:** `haulvia_command.command_secure_cargo_in_storage(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | `RECOVERY_WORKER`/`STORAGE_WORKER`, or profile with sensitive override authority and fresh authentication. |
| Stop gate | Current `STORAGE` stop is `EVIDENCE_PENDING` with required GPS, timestamp, photo, quantity, and snapshotted evidence. |
| Storage facts | Facility name/address, access authority, condition/identifier, acceptance proof and time, item manifest, expenses/charges/notices, responsible party, release conditions, and optional future deadline. |
| Custody writes | Append `STORAGE_IN` movements and `STORED` allocation outcomes; verify quantities do not exceed onboard balance. |
| Result | Complete the storage stop, create an active movement/completion hold, set route `HELD`, and append `storage_custody_records`. |

## 14. E12 — `verifyReturnHandoff`

**Entry point:** `haulvia_command.command_verify_return_handoff(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | Evidence reviewer or exact return-verification worker. |
| Stop gate | Current `RETURN` stop is `EVIDENCE_PENDING`; required evidence is present and reviewed. |
| Return facts | Exact cargo quantities/units, sender acceptance, receiver label, captured time, evidence snapshot, and explicit mixed-outcome disclosure. |
| Custody writes | Append `UNLOAD` movements and `RETURNED` outcomes. |
| Terminal rule | If all onboard balances become zero, complete execution/assignment, freeze route, and transition to `RETURNED_TO_SENDER`; otherwise remain in progress for remaining cargo. |

## 15. E13 — `openDispute`

**Entry point:** `haulvia_command.command_open_dispute(jsonb)`

| Contract area | Requirement |
|---|---|
| Shipment state | Any serviced non-draft state, including terminal history; shipment state itself is unchanged. |
| Actor | Owning customer or retained assigned provider/driver. |
| Financial rule | Evidence, accepted price snapshot, allocation basis, and disputed amount are required. Protect only `min(disputed, operationally available)` and retain any unprotected remainder. |
| Movement default | Physical movement continues and the request must explicitly say so. |
| Exceptional hold | `blocksRouteMovement: true` requires `UNSAFE`, `UNLAWFUL`, or `FORMAL_HOLD`, the current execution/version, and an explicit control snapshot. A separate workflow hold changes only route execution to `HELD`. |
| Records | Append dispute/event/financial hold plus `dispute_operational_controls`; audit records that operational history was not rewritten. |

## 16. E14 — `resolveDispute`

**Entry point:** `haulvia_command.command_resolve_dispute(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | Profile with sensitive `DISPUTE_RESOLVE`, current reauthentication, and a specific reason. |
| Guards | Expected dispute is `OPEN`, `EVIDENCE_COLLECTION`, or `UNDER_REVIEW`; summary, approved decision code, evidence decision, financial allocation, and next route action are non-empty. |
| Exact money allocation | `releaseHeldAmount + retainHeldAmount` must equal the active protected hold. A dispute with no protected hold must allocate zero. |
| Writes | Release prior hold, optionally create a retained resolution hold, resolve dispute/event/axis, recompute payout readiness, and append `dispute_resolution_records`. |
| Separation | Route movement and any workflow hold do not change here. Resumption is E15. |

## 17. E15 — `resumeAfterResolution`

**Entry point:** `haulvia_command.command_resume_after_resolution(jsonb)`

| Contract area | Requirement |
|---|---|
| Actor | `ROUTE_OPERATIONS_WORKER`, or profile with sensitive state-override permission, fresh authentication, and reason. |
| Guards | Shipment is `ROUTE_IN_PROGRESS`; current execution is `HELD`; route, assignment, execution version, active leg, current stop, exact custody, and active movement hold all match. |
| Resolved source | Named `DISPUTE` is resolved/closed and linked through its operational control, or named `ROUTE_EXCEPTION` is resolved/closed and linked to the hold. |
| Stop restart | `PENDING → EN_ROUTE` or `EXCEPTION_REVIEW → ARRIVED` using a new stop attempt. The prior attempt is ended and retained. |
| Atomic writes | Release exact hold; resume route `ACTIVE`/`RECOVERY_ACTIVE`; append stop/axis/audit history and `workflow_resumption_records`. |

## 18. E16 — `copyTerminalShipmentForRepost`

**Entry point:** `haulvia_command.command_copy_terminal_shipment_for_repost(jsonb)`

| Contract area | Requirement |
|---|---|
| Source | `CANCELLED`, `EXPIRED`, `COMPLETED`, or `RETURNED_TO_SENDER`; exact retained source route must validate. |
| Actor | Owning customer; otherwise terminal-repost worker or profile with sensitive override authority and fresh authentication. |
| Required facts | Specific reason and non-empty eligibility snapshot describing the deliberate repost decision. |
| Copy result | Create a distinct `DRAFT` shipment linked by `source_shipment_id`; copy ordered stops, legs, cargo items, allocations, and stable lineage keys into route version 1 `DRAFT`. |
| Fresh decisions | Policy, pricing, marketplace publication, funding, and assignment are not copied as current authority; they must be recalculated through normal commands. |
| Preservation | Source shipment and route receive no update. `terminal_shipment_reposts` records source/new IDs and exact copy counts. |

## 19. Block E append-only records

| Table | Purpose |
|---|---|
| `stop_retry_records` | Failed attempt to newly authorized same-driver attempt lineage. |
| `failed_first_pickup_resolutions` | Explicit repost-review or terminal outcome for a zero-custody failed first pickup. |
| `custody_transfer_authorizations` | Complete custody, evidence, authority, and old/new assignment handoff snapshot. |
| `recovery_route_records` | Old/new route and execution lineage, price/payment, provider acceptance, and custody snapshot. |
| `storage_custody_records` | Facility, cargo, proof, expense, responsibility, access/release, deadline, and hold facts. |
| `return_handoff_records` | Sender handoff evidence, movements, custody reconciliation, and terminal/mixed result. |
| `dispute_operational_controls` | Independent movement effect and any justified route hold for a dispute. |
| `dispute_resolution_records` | Authorized evidence decision, exact money allocation, and next route action. |
| `workflow_resumption_records` | Resolved source, released hold, old/new route and stop states, custody, and authority. |
| `terminal_shipment_reposts` | Terminal source to new draft/route link and exact copy counts. |

All ten tables reject `UPDATE` and `DELETE` with SQLSTATE `55000`.

## 20. Stable rejection codes exercised by the suite

| Code | Meaning |
|---|---|
| `CUSTODY_EXISTS` | Ordinary cancellation/release/repost attempted after verified `LOAD`. |
| `CUSTODY_REQUIRED` | Transfer/recovery/storage/return requires positive verified onboard cargo. |
| `CUSTODY_SNAPSHOT_STALE` | Request no longer matches the append-only custody ledger. |
| `STOP_NOT_SERVICEABLE` | Same-driver retry lacks a retained current serviceability assessment. |
| `CONTINUATION_NOT_FEASIBLE` | Route/capacity/timing/custody feasibility was not fully revalidated. |
| `CUSTODY_HANDOFF_INVALID` | Transfer lacks exact QR/PIN, GPS/time, confirmations, or valid values. |
| `REPLACEMENT_NOT_ELIGIBLE` / `COMPLIANCE_BLOCKED` | Replacement resources are inactive or blocked. |
| `ADDITIONAL_PAYMENT_NOT_SECURED` | Positive non-emergency recovery has no separate secured funds. |
| `STORAGE_CUSTODY_INVALID` | Facility, condition, proof, charges, access, or release facts are incomplete. |
| `RETURN_HANDOFF_INVALID` | Sender evidence, cargo, or mixed-outcome disclosure is incomplete. |
| `ROUTE_HOLD_NOT_JUSTIFIED` | Dispute attempts to stop movement without unsafe, unlawful, or formal-hold basis. |
| `FINANCIAL_ALLOCATION_INVALID` | Protected dispute amount is not allocated exactly. |
| `FRESH_AUTH_REQUIRED` | Sensitive transfer/recovery/resolution/resumption lacks current reauthentication. |
| `SOURCE_NOT_RESOLVED` | E15 names an unresolved or unrelated dispute/route exception. |
| `TERMINAL_SHIPMENT_IMMUTABLE` | A command attempts to edit/reopen terminal history instead of copying. |

## 21. Verification

`haulvia_block_e_acceptance_v1.sql` is rollback-only. It exercises all 16 Block E rows, E01 replay, E04 wrapper reuse, the first verified `LOAD` cancellation boundary, failed-attempt preservation, explicit repost/close/continue decisions, exact transfer custody, linked recovery route/price/execution, storage proof and hold, zero-balance terminal return, disputed-only financial protection, justified physical hold, evidence-based resolution, separate resumption attempt, terminal-source immutability, complete route copying, all ten append-only tables, the five appended operating-context summaries, and wrapper-only service-role authority.

The complete Foundation → A → B → C → D → E migration chain and all six rollback-only suites execute successfully in a PostgreSQL-compatible runtime. Final executable shape is 110 base tables, 5 views, and 70 wrappers, with zero `PUBLIC` function grants and zero internal-helper grants to `service_role`. Hosted PostgreSQL/Supabase still requires true multi-session race tests, provider sandbox webhooks, RLS, and API-adapter tests before production exposure.
