# Haulvia Command Contracts — Block B v1

**Approved source:** State Transition Matrix v1.1, Block B

**Scope:** Assignment through route start, first-stop execution, pre-custody cancellation/repost, and first verified custody

**Implementation:** `20260814000300_haulvia_block_b_commands_v1.sql`

## 1. Shared command envelope

Every Block B entry point accepts one `jsonb` request. The trusted API/service layer supplies:

| Field | Rule |
|---|---|
| `commandId` | UUID correlation identifier. |
| `idempotencyKey` | Stable retry key for the actor and named command. |
| `requestHash` | SHA-256 hex of the canonical request. Reusing a key with another hash fails. |
| `shipmentId` | Shipment aggregate to lock. |
| `expectedShipmentVersion` | Must equal `shipments.lock_version`. A completed retry replays before this stale check. |
| `expectedRouteVersionId` | Must be the shipment's current active route version. |
| `expectedAssignmentId` | Must be the one active whole-route assignment. |
| `actorProfileId` | Required for customer/driver actions; null for an approved trusted worker. |
| `actorOrganizationId` | Required when ownership or a profile permission is organization-scoped. |
| `workerAuthority` | Required for system-worker calls and restricted to the handler's approved authority. |

Commands after route start also require `expectedRouteExecutionId`, `expectedRouteExecutionVersion`, and—when stop-scoped—`expectedStopExecutionId`. Shipment locking, route-execution versioning, unique active records, and ledger constraints implement first-valid-commit-wins.

All handlers:

- commit the business change, immutable events/evidence, audit record, and outbox work in one transaction;
- return the current macro and independent axes plus route execution position and custody summary;
- reject invalid requests without leaving a partial idempotency, evidence, movement, event, notification, hold, or financial-decision record;
- remain revoked from `PUBLIC`; only the trusted service role may execute them.

## 2. B01 — `startRoute`

**Entry point:** `haulvia_command.command_start_route(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment `DRIVER_ASSIGNED → ROUTE_IN_PROGRESS`; first pickup `PENDING → EN_ROUTE`; route execution `NOT_STARTED → ACTIVE`. |
| Actor | The exact assigned driver's profile. |
| Guards | Current active route and assignment; secured full-route funds; active provider/driver/vehicle and no compliance blocker; no movement-blocking workflow hold; no competing current execution. |
| Atomic writes | Create the primary route execution, instantiate every ordered stop, create first attempt, set active stop/first route leg/next action/version, start one tracking session, and append the initial route update. |
| Durable records | Stop attempt event, route-execution axis event, shipment event, audit, customer route-start/ETA notification. |

## 3. B02 — `confirmArrivalAtFirstPickup`

**Entry point:** `haulvia_command.command_confirm_arrival_at_first_pickup(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | First pickup `EN_ROUTE → ARRIVED`; shipment remains `ROUTE_IN_PROGRESS`. |
| Actor | Assigned driver. |
| Guards | Active current execution/first pickup/attempt; valid coordinates and accuracy; inside the configured geofence or a specific reason plus structured exception evidence. |
| Atomic writes | Append GPS and timestamp evidence, stamp arrival, update current position/next action/version, append route update, and queue the versioned free-waiting deadline job. |
| Required request | Coordinates, accuracy when known, captured time, and `waitingFreeUntil`; documented exception fields when outside/unconfigured. |

## 4. B03 — `correctFirstStopArrival`

**Entry point:** `haulvia_command.command_correct_first_stop_arrival(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | First pickup `ARRIVED → EN_ROUTE`. |
| Actor | Assigned driver or profile with `ROUTE_OPERATIONS_MANAGE`; approved route-operations worker is also accepted. |
| Guards | No service start, ended/failure attempt, or finalized stop financial adjustment. A specific reason is mandatory. |
| Atomic writes | Cancel the pending waiting job, change only the current stop/attempt position, increment execution version, and append correction event/audit/notice. Original arrival evidence and event remain immutable. |

## 5. B04 — `startFirstPickupService`

**Entry point:** `haulvia_command.command_start_first_pickup_service(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | First pickup `ARRIVED → SERVICE_IN_PROGRESS`. |
| Actor | Assigned driver. |
| Guards | Correct contact and location explicitly confirmed; active attempt; cargo is available or a structured discrepancy is supplied. |
| Atomic writes | Stamp service start, update next action/version, cancel the pending grace-expiry job, and append attempt event/audit. A cargo discrepancy creates a completion-blocking route exception without inventing custody. |

## 6. B05 — `submitFirstPickupEvidence`

**Entry point:** `haulvia_command.command_submit_first_pickup_evidence(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | First pickup `SERVICE_IN_PROGRESS → EVIDENCE_PENDING`. |
| Actor | Assigned driver. |
| Guards | Active service attempt; driver confirmation and releasing-person name; immutable evidence array satisfies baseline and the accepted route/rule snapshot. |
| Baseline evidence | GPS, timestamp, cargo photo, quantity, condition, and PIN or QR. Snapshot flags can additionally require signature, identifier, seal, securement, contact, note, or other supported types. |
| Atomic writes | Append every evidence item, stamp submission, update next action/version, and append stop event/audit/customer notice. Originals are never overwritten. |

## 7. B06 — `verifyFirstPickup`

**Entry point:** `haulvia_command.command_verify_first_pickup(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | First pickup `EVIDENCE_PENDING → COMPLETED`; shipment remains `ROUTE_IN_PROGRESS`. |
| Actor | `EVIDENCE_REVIEWER` worker or profile with `STOP_EVIDENCE_REVIEW`. |
| Guards | Current execution/stop/attempt and complete evidence; no prior verified custody; exactly one actual LOAD request per first-stop allocation; quantity/unit cannot exceed plan. Partial quantity requires a structured discrepancy. |
| Atomic writes | Append evidence reviews and LOAD ledger rows, complete attempt/stop, create the one immutable first-custody milestone, update onboard balance/position/version, and append route update/event/audit/notice. |
| Boundary | Once the first LOAD commits, ordinary cancellation, driver release, paused repost, and other pre-custody handlers reject with `CUSTODY_EXISTS`. |

## 8. B07 — `reportFailedFirstPickup`

**Entry point:** `haulvia_command.command_report_failed_first_pickup(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Active arrived/service/evidence stop `→ FAILED` or `EXCEPTION_REVIEW`; macro shipment remains unchanged. |
| Actor | Assigned driver or authorized route operator/worker. |
| Guards | Verified arrival; configured grace period complete; no verified LOAD; non-empty contact attempts, supporting evidence, affected allocations, responsibility, failure reason, and zero custody snapshot. |
| Atomic writes | Append evidence/contact records, finish the attempt, create the route exception, create a movement/completion-blocking hold for review when applicable, update next action/version, and append events/audit/notice. No cargo movement is posted. |

## 9. B08 — `cancelBeforeAnyCustody`

**Entry point:** `haulvia_command.command_cancel_before_any_custody(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | `DRIVER_ASSIGNED` or `ROUTE_IN_PROGRESS → CANCELLED`. |
| Actor | Owning customer. |
| Guards | Active assignment/current route; zero verified custody; accepted policy snapshot; displayed charge + refund equals secured amount; driver compensation does not exceed collected charge. |
| Atomic writes | Cancel active assignment/execution and nonterminal stops, end tracking, close marketplace, update customer-payment summary, create immutable financial decision, append events/audit/notices, and queue provider settlement. |
| Preservation | The financial row records policy version, responsibility, charge, expected refund, expected driver compensation, currency, reason, and displayed decision snapshot. |

## 10. B09 — `releaseDriverBeforeAnyCustody`

**Entry point:** `haulvia_command.command_release_driver_before_any_custody(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Assigned/in-progress `→ POSTED` with marketplace `PAUSED`, or `→ EXPIRED`. |
| Actor | Approved route-operations/eligibility worker or profile with route-operations authority; the driver cannot directly execute the release handler. |
| Guards | Current active assignment/route; zero verified custody; provider-release financial decision must charge customer zero and release the full secured amount. |
| Atomic writes | Close assignment/execution/nonterminal stops and tracking, set payment `RELEASED`, create immutable decision and settlement job, append events/audit/notice. |
| Preservation | `automaticRepublish` is always false. Old offers and assignment remain history. |

## 11. B10 — `editPausedAfterDriverCancellation`

**Entry point:** `haulvia_command.command_edit_paused_after_driver_cancellation(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment remains `POSTED`; marketplace remains `PAUSED`. |
| Actor | Owning customer. |
| Guards | No active reservation/assignment; zero custody; current active route; current approved policy and valid complete replacement plan/pricing branch. |
| Atomic writes | Create and validate the next route version, capture evidence/policy and price snapshots, supersede the old route, activate the new route, update deadline, audit, and notify. |
| Preservation | Cancelled execution/assignment and all prior route/offer terms remain immutable. Explicit repost is still required. |

## 12. B11 — `repostPausedShipment`

**Entry point:** `haulvia_command.command_repost_paused_shipment(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Marketplace `PAUSED → ACTIVE`; shipment remains `POSTED`. |
| Actor | Owning customer deliberately selecting Repost. |
| Guards | No active assignment/reservation or verified custody; no marketplace-blocking hold; complete active route; accepted still-effective evidence policy; verified payment method; future deadline; current pricing/rate-card branch and review. |
| Atomic writes | Capture new posting price/review, reset payment summary to `METHOD_VERIFIED`, activate marketplace, update deadline, append axis events/audit/notice, and queue expiry. |
| Preservation | No expired offer or cancelled assignment is revived. |

## 13. B12 — `reportPreCustodyIssue`

**Entry point:** `haulvia_command.command_report_pre_custody_issue(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment and stop physical state are unchanged. |
| Actor | Customer, assigned driver, or `ROUTE_OPERATIONS_WORKER`. |
| Guards | Assigned/in-progress current route and assignment; zero verified custody; optional stop must belong to current execution. |
| Atomic writes | Create route/stop/cargo exception and optional independently scoped workflow hold, append hold-axis event/audit/notice, and increment only the shipment concurrency version. |
| Preservation | The exception/hold never overwrites route position, stop status, payment, payout, dispute, or custody. |

## 14. Stable rejection codes exercised by the suite

| Code | Meaning |
|---|---|
| `NOT_AUTHORIZED` | Actor is not the customer, assigned driver, reviewer, or approved worker for that command. |
| `STALE_SHIPMENT_VERSION` | Shipment changed before commit. |
| `STALE_ROUTE_VERSION` | Request targets a noncurrent route. |
| `STALE_ROUTE_EXECUTION_VERSION` | Stop/position/custody changed before commit. |
| `ASSIGNMENT_NOT_ACTIVE` | Expected whole-route assignment is no longer active. |
| `WORKFLOW_HELD` | Independent hold blocks movement or marketplace. |
| `LOCATION_NOT_VERIFIED` | Arrival is outside geofence and lacks documented exception. |
| `EVIDENCE_INVALID` | Baseline or snapshot-required immutable evidence is incomplete/invalid. |
| `WAITING_PERIOD_ACTIVE` | Failure attempted before the versioned grace period ended. |
| `CARGO_BALANCE_INVALID` | Actual LOAD set, quantity, unit, allocation, or idempotency violates custody rules. |
| `CUSTODY_EXISTS` | A pre-custody-only action was attempted after verified LOAD. |
| `FINANCIAL_DECISION_INVALID` | Displayed charge/refund/compensation does not reconcile to secured funds. |

## 15. Verification

The 26-check `haulvia_block_b_acceptance_v1.sql` suite exercises all 12 entry points, the complete first-custody path, arrival correction preservation, failed pickup, customer cancellation, driver release/edit/repost, issue/hold separation, replay, authorization, geofence, stale-version, zero-custody, and atomic rollback guards. Multi-session first-valid-commit-wins races remain part of hosted PostgreSQL verification.
