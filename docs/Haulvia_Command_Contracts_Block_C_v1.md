# Haulvia Command Contracts — Block C v1

**Approved source:** State Transition Matrix v1.1, Block C and its locked rules

**Scope:** Reusable remaining-stop execution, per-stop custody/evidence, failed-stop continuation, live ETA updates, route amendment, and aggregate route resolution

**Implementation:** `20260814000400_haulvia_block_c_commands_v1.sql`

## 1. Shared command envelope

Every Block C entry point accepts one `jsonb` request. The trusted API/service layer supplies:

| Field | Rule |
|---|---|
| `commandId` | UUID correlation identifier. |
| `idempotencyKey` | Stable retry key for the actor and named command. |
| `requestHash` | SHA-256 hex of the canonical request. Reusing a key with another hash fails. |
| `shipmentId` | Shipment aggregate to lock. |
| `expectedShipmentVersion` | Must equal `shipments.lock_version`. A completed retry replays before this stale check. |
| `expectedRouteVersionId` | Must be the shipment's current active route version. |
| `expectedAssignmentId` | Must be the one active whole-route assignment. |
| `expectedRouteExecutionId` | Must be the current execution segment. |
| `expectedRouteExecutionVersion` | Must match `route_executions.record_version`. |
| `expectedStopExecutionId` | Required for stop-scoped work and must match the execution's active stop. |
| `actorProfileId` | Required for customer/driver actions; null for an approved trusted worker. |
| `actorOrganizationId` | Required when customer ownership or profile permission is organization-scoped. |
| `workerAuthority` | Required for system-worker calls and restricted to the handler's approved authority. |

All handlers run inside the shared idempotent command dispatcher. The shipment, assignment, execution, and stop rows are locked before current-position changes. Business writes, append-only evidence/history, audit, notification/outbox work, and the stored retry result commit or roll back together.

The named wrappers remain revoked from `PUBLIC`; they are granted only to `service_role` when that role exists.

## 2. C01 — `advanceToNextStop`

**Entry point:** `haulvia_command.command_advance_to_next_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current terminal stop remains immutable; next ordered `PENDING → EN_ROUTE`; shipment remains `ROUTE_IN_PROGRESS`. |
| Actor | Assigned driver, authorized route operator, or approved route-operations worker. |
| Guards | Active route/execution; current stop is `COMPLETED`, `SKIPPED`, or `CANCELLED`; no movement-blocking hold; next stop and its incoming leg are eligible. |
| Atomic writes | Start the next attempt, update active stop/leg/next action/version, append route update and stop/axis/audit events, recalculate downstream ETAs, and notify the next stop. |
| Completion boundary | If no later eligible stop exists, reject with `NO_NEXT_STOP`; only `completePlannedRoute` resolves the aggregate route. |

## 3. C02 — `confirmArrivalAtStop`

**Entry point:** `haulvia_command.command_confirm_arrival_at_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Active stop and attempt `EN_ROUTE → ARRIVED`. |
| Actor | Exact assigned driver. |
| Guards | Current active execution/stop/attempt; valid coordinates; inside the accepted geofence or a specific reason plus structured exception evidence; `waitingFreeUntil` follows captured arrival. |
| Atomic writes | Append GPS/time evidence, retain any location exception, stamp arrival and free-waiting deadline, update route position, append route update, recalculate all affected downstream ETAs, queue grace expiry, and notify that stop's contact. |

## 4. C03 — `correctStopArrival`

**Entry point:** `haulvia_command.command_correct_stop_arrival(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current stop and attempt `ARRIVED → EN_ROUTE`. |
| Actor | Assigned driver, authorized route operator, or approved route-operations worker. |
| Guards | Specific reason; no service start and no finalized stop financial adjustment. |
| Preservation | Cancel the queued waiting deadline and change current position only. Original arrival evidence and attempt event remain immutable. |

## 5. C04 — `startStopService`

**Entry point:** `haulvia_command.command_start_stop_service(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current pickup or delivery `ARRIVED → SERVICE_IN_PROGRESS`. |
| Actor | Exact assigned driver. |
| Guards | No movement-blocking hold; contact and location confirmed; pickup availability or delivery onboard balance checked against the planned allocations. |
| Discrepancy path | A mismatch requires structured `cargoDiscrepancy` data and opens a completion-blocking route exception without inventing or deleting custody. |
| Atomic writes | Cancel grace expiry, stamp service start, update next action/version, and append stop event/audit. |

## 6. C05 — `submitStopEvidence`

**Entry point:** `haulvia_command.command_submit_stop_evidence(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current stop and attempt `SERVICE_IN_PROGRESS → EVIDENCE_PENDING`. |
| Actor | Exact assigned driver. |
| Guards | Driver confirmation; pickup releasing-person identity or standard-delivery receiver identity; evidence array satisfies baseline plus the accepted per-stop snapshot. |
| Offline rule | Offline capture is explicit. Capture/sync metadata is retained; unsynchronized evidence may be submitted but cannot be verified into custody. Ordinary online sync latency is not labeled offline. |
| Preservation | Evidence is appended to this stop attempt only; no other stop's evidence, attempt, waiting, or verification state is changed. |

## 7. C06 — `verifyPickupStop`

**Entry point:** `haulvia_command.command_verify_pickup_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current pickup `EVIDENCE_PENDING → COMPLETED`. |
| Actor | `EVIDENCE_REVIEWER` worker or profile with stop-evidence review permission. |
| Guards | Complete synchronized evidence; exactly one LOAD request for every allocation at this pickup; quantity/unit within plan; partial quantity and damage require structured exceptions; resulting vehicle weight remains within capacity. |
| Atomic writes | Append evidence reviews and LOAD movements, create the first-custody milestone if needed, complete attempt/stop, retain discrepancies, update custody/position/version, recalculate downstream ETAs, and notify. |
| Locked rule | LOAD movements from earlier stops remain authoritative even if a later pickup fails. |

## 8. C07 — `verifyDeliveryStop`

**Entry point:** `haulvia_command.command_verify_delivery_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current delivery `EVIDENCE_PENDING → COMPLETED`; its delivery-verification axis becomes `PENDING_RECEIVER_CONFIRMATION` only for an accepted contactless stop. |
| Actor | `EVIDENCE_REVIEWER` worker or profile with stop-evidence review permission. |
| Guards | Complete synchronized evidence; exactly one UNLOAD per allocation at the stop; sufficient matching custody; partial delivery requires a discrepancy. |
| Contactless guards | Must match the accepted stop snapshot and retain preapproval, exact drop location, verified identity, and instructions. High-value, sensitive, dangerous/controlled, temperature-sensitive, and signature-required cargo is ineligible. |
| Atomic writes | Append reviews, UNLOAD movements, and allocation outcomes; complete stop/attempt; create a narrowly scoped receiver token and expiry job when contactless; update custody/position/ETA and immutable events. With Block D installed, physical completion also snapshots the exact versioned stop review window and verifies the token deadline against `deliveryReviewSeconds`. |
| Independence | A pending receiver confirmation never fabricates receipt and does not prevent later planned stops from executing. |

## 9. C08 — `reportFailedPickupStop`

**Entry point:** `haulvia_command.command_report_failed_pickup_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current arrived/service/evidence pickup `→ FAILED` or `EXCEPTION_REVIEW`. |
| Actor | Assigned driver, authorized route operator, or approved route-operations worker. |
| Required record | Verified arrival GPS/time, elapsed grace period, contacts, stop evidence, affected allocations, responsibility, reason, downstream impact, and exact current custody snapshot. |
| Atomic writes | Complete the attempt as failed/review, append evidence, route exception, immutable failure report, events/audit/notice, and—when review is requested—a movement/completion hold. |
| Locked rule | The failure row describes only this attempt; prior LOAD movements and onboard cargo remain unchanged. |

## 10. C09 — `reportFailedDeliveryStop`

**Entry point:** `haulvia_command.command_report_failed_delivery_stop(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Current arrived/service/evidence delivery `→ FAILED` or `EXCEPTION_REVIEW`. |
| Actor | Assigned driver, authorized route operator, or approved route-operations worker. |
| Required record | All failed-stop evidence required by C08 plus an `approvedNextRouteDecision` snapshot. |
| Preservation | Cargo remains in its ledger-derived custody; no automatic unload, return, storage, route stop, or continuation is inferred. |

## 11. C10 — `authorizeContinueAfterStopFailure`

**Entry point:** `haulvia_command.command_authorize_continue_after_stop_failure(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Failed stop remains `FAILED`; next eligible stop `PENDING → EN_ROUTE`. |
| Actor | Owning customer, authorized route administrator, or approved customer/route workflow. |
| Guards | Exact failure report; approved `SKIP`, `RECOVERY`, `AMENDMENT`, `RETURN`, `REDELIVERY`, `ALTERNATE_DESTINATION`, `TRANSFER`, or `STORAGE` decision; route, capacity, timing, custody, and customer instructions all revalidated and snapshotted; no movement hold. |
| Failed delivery | Continuation decision must exactly match the decision retained with the failure report. |
| Failed pickup skip | Creates an `APPROVED_NOT_LOADED` allocation outcome and resolves the associated exception while leaving earlier onboard cargo untouched. |
| Atomic writes | Append explicit continuation authorization, start next attempt/leg, recalculate ETA, update position/version, and retain the failed stop unchanged. |

## 12. C11 — `authorizeRouteAmendment`

**Entry point:** `haulvia_command.command_authorize_route_amendment(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment stays `ROUTE_IN_PROGRESS`; old route becomes `SUPERSEDED`; a new active route version and linked `AMENDMENT` execution segment begin. |
| Actor | Owning customer, authorized route administrator, or approved customer/route workflow. |
| Guards | Accepted current driver; complete replacement plan; terminal stop stable keys preserved; all onboard stable cargo keys/units/quantities preserved; prior approved cargo outcomes map to the new allocations; current policy/evidence/timing/risk snapshot; accepted adjustment price. |
| Payment | Positive non-emergency additional work requires a separate matching secured payment intent before activation. An emergency waiver may proceed with a completion-blocking payment-due hold. Zero-price work cannot consume a payment intent. |
| Atomic writes | Create immutable route/rule/price snapshots, close only the prior execution segment, retain all prior attempts/evidence/movements, instantiate the new segment, carry approved outcomes without duplicating custody movements, start tracking/ETA, record amendment lineage, and release only explicitly listed holds/exceptions. |

## 13. C12 — `recordRouteUpdate`

**Entry point:** `haulvia_command.command_record_route_update(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment, route execution, and stop physical states remain unchanged. |
| Actor | Assigned driver, authorized route operator, or approved route-operations worker. |
| Guards | Current active/held execution and active leg; valid GPS/time/speed/heading/dwell values; active tracking session; exact ledger-derived custody snapshot. |
| Atomic writes | Append tracking point and route update with GPS, leg, ETA, dwell, delay, connectivity, custody, capture/sync times, and explicit offline flag; append ETA calculation/predictions and downstream notifications; increment execution version only. |
| ETA rule | Predictions use remaining legs plus expected service time. Delay notifications are scoped to stops whose ETA change crosses the requested threshold. |

## 14. C13 — `reportTransitIssue`

**Entry point:** `haulvia_command.command_report_transit_issue(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Physical shipment/stop position remains unchanged; execution becomes `HELD` only when the new workflow hold blocks movement. |
| Actor | Assigned driver, owning customer, authorized route operator, or approved route-operations worker. |
| Guards | Current route/assignment/execution/stop and exact custody snapshot; structured issue evidence. |
| Atomic writes | Open route exception and optional independently scoped hold, update execution next action/version only when required, and append hold-axis event/audit/notice. |

## 15. C14 — `completePlannedRoute`

**Entry point:** `haulvia_command.command_complete_planned_route(jsonb)`

| Contract area | Requirement |
|---|---|
| Transition | Shipment `ROUTE_IN_PROGRESS → DELIVERED`; current execution `ACTIVE → COMPLETED`. `DELIVERED` is the aggregate internal route-resolution state. |
| Actor | `EVIDENCE_REVIEWER` worker or profile with stop-evidence review permission. |
| Guards | Every planned/authorized stop has a terminal result; no completion hold/open blocking exception; every current-route allocation quantity has verified delivery or approved recovery; all completed-stop evidence is retained and verified; onboard balance is zero. |
| Public disclosure | `route_resolution_records.public_outcome_label` enumerates every distinct delivered/returned/stored/transferred/not-loaded/other-recovery outcome. `outcome_summary.byOutcomeAndUnit` keeps quantities grouped by unit instead of combining incompatible measures. |
| Contactless boundary | Pending receiver confirmations are counted and remain independent. The route may resolve, but the execution next action remains `AWAIT_RECEIVER_CONFIRMATION`; no receiver response is fabricated. |
| Atomic writes | Append the route-resolution record, end tracking, complete execution, append route/shipment events and audit, and queue the resolution notice. |

## 16. Block C append-only records

| Table | Purpose |
|---|---|
| `route_eta_calculations` | One immutable ETA calculation trigger, route snapshot, delay, actor, and formula context. |
| `route_stop_eta_predictions` | Per-downstream-stop ETA result, prior ETA, drive/service contribution, delta, and notification link. |
| `stop_failure_reports` | Attempt-level failed pickup/delivery fact with evidence, responsibility, affected cargo, custody, impact, and decision snapshot. |
| `stop_continuation_authorizations` | Separate authority to move after a failed stop with feasibility/capacity/timing/custody/customer snapshots. |
| `route_amendments` | Immutable lineage between old/new route plans and execution segments, with driver, price, payment, reason, and approval snapshots. |
| `cargo_resolution_outcomes` | Quantity/unit outcome per active-route allocation, tied to verified movement or approved recovery. |
| `route_resolution_records` | Aggregate completion proof, accurate public outcome label, unit-safe outcome summary, custody reconciliation, and evidence reconciliation. |

`stop_executions.current_eta_at`, `eta_updated_at`, and `waiting_free_until` are current pointers only. Their calculation, arrival, evidence, and correction histories remain append-only.

## 17. Stable rejection codes exercised by the suite

| Code | Meaning |
|---|---|
| `CURRENT_STOP_UNRESOLVED` | Attempted to advance before the current stop had a terminal or authorized result. |
| `LOCATION_NOT_VERIFIED` | Arrival/failure lacks valid geofence or retained GPS/time evidence. |
| `WAITING_PERIOD_ACTIVE` | Failure was reported before the per-stop grace deadline. |
| `EVIDENCE_INVALID` / `EVIDENCE_NOT_SYNCED` | Required stop evidence is missing, invalid, or not yet synchronized for custody verification. |
| `CUSTODY_SNAPSHOT_STALE` | Supplied custody snapshot differs from the append-only movement ledger. |
| `CARGO_BALANCE_INVALID` | Planned allocation, quantity, unit, movement, outcome, or custody reconciliation is invalid. |
| `CAPACITY_EXCEEDED` | Verified pickup would exceed assigned vehicle capacity. |
| `NEXT_ROUTE_DECISION_REQUIRED` | Failed delivery lacks or conflicts with its approved next route decision. |
| `CONTINUATION_NOT_FEASIBLE` | Route/capacity/timing/custody revalidation did not all pass. |
| `ADDITIONAL_PAYMENT_NOT_SECURED` | Non-emergency amendment work lacks separate secured funding. |
| `DRIVER_ACCEPTANCE_REQUIRED` | Current assigned driver did not accept the amendment. |
| `WORKFLOW_HELD` | An independent hold blocks movement or completion. |
| `CARGO_OUTCOME_INCOMPLETE` | At least one active-route allocation lacks a full verified/approved outcome. |
| `ROUTE_NOT_RESOLVED` | One or more planned/authorized stops is still nonterminal. |

## 18. Verification

The 23-check `haulvia_block_c_acceptance_v1.sql` rollback-only suite exercises all 14 Block C entry points. It covers a three-stop/two-allocation route, repeated advance replay, arrival correction preservation, later pickup LOAD, completed-service exclusion from downstream ETA, live ETA recalculation, online sync-latency handling, transit issue independence, contactless delivery and pending confirmation, unit-safe aggregate resolution, failed pickup with earlier cargo still onboard, stale-custody rejection, explicit skip continuation, failed delivery custody retention, unfunded-amendment rollback, approved immutable amendment lineage, wrapper count, append-only record presence, zero `PUBLIC` grants, and wrapper-only `service_role` execution.

The complete Foundation → Block A → Block B → Block C chain and all four suites execute successfully in a PostgreSQL-compatible runtime. True multi-session first-valid-commit-wins races remain part of hosted PostgreSQL/Supabase verification.
