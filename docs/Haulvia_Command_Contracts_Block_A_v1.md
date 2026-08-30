# Haulvia Command Contracts — Block A v1

**Scope:** Multi-stop draft/posting, pricing, offers, reservation, payment, assignment, cancellation, and expiry

**Authority:** Approved State Transition Matrix v1.1, Block A (19 commands/events)

**Storage baseline:** `20260814000100_haulvia_foundation_v1.sql`

**Command migration:** `20260814000200_haulvia_block_a_commands_v1.sql`

**Status:** Implemented as a trusted transactional database boundary; hosted PostgreSQL concurrency verification and RLS remain deferred

## 1. Purpose

This document converts every approved Block A matrix row into an implementation contract. It is framework-neutral: the API may be HTTP, RPC, or a worker command, but it must preserve the request fields, authorization decision, locks, all-or-nothing writes, events, queued notifications, idempotency, and tests below.

Commands run through a trusted service role. Clients must not write the operational tables directly before the separate actor/RLS policy is approved.

## 2. Common command envelope

Every request carries:

| Field | Type | Rule |
|---|---|---|
| `commandId` | UUID | Correlation identifier for logs, audit, events, and notifications. |
| `idempotencyKey` | string | Required for every externally retryable command. Unique with actor and command name. |
| `requestHash` | 64-character SHA-256 hex | Service-calculated hash of the canonical request; the same idempotency key cannot carry another payload. |
| `actorProfileId` | UUID or null | Authenticated person; null only for an authenticated system/payment worker. |
| `actorOrganizationId` | UUID or null | Authority/ownership scope. |
| `shipmentId` | UUID | Aggregate root. |
| `expectedShipmentVersion` | bigint | Must equal `shipments.lock_version` before mutation. |
| `expectedRouteVersionId` | UUID or null | Required whenever the command depends on the current route. |
| `requestedAt` | timestamp with time zone | Client/worker observation time; server commit time remains authoritative. |
| `reason` | string or null | Required when the command changes terms, cancels, or records an exception. |
| `workerAuthority` | string or null | Required only for an authenticated trusted worker; never accepted together with an end-user actor profile. |

Successful responses return `commandId`, `shipmentId`, `shipmentReference`, current macro/axis states, `lockVersion`, current `routeVersionId`, affected record IDs, and `replayed: true|false`.

## 3. Common transaction protocol

Each command uses one database transaction:

1. Insert or lock `command_idempotency` using actor, command name, and key. A retry with the same request hash returns the stored result; a different hash fails with `IDEMPOTENCY_KEY_REUSED`.
2. Lock `shipments` by ID and compare `lock_version`. A mismatch fails with `STALE_SHIPMENT_VERSION` and returns the current context.
3. Lock only the relevant current axis, route version, offer thread, reservation, payment intent, or assignment rows in a stable order.
4. Authorize the actor and recheck current route, deadline, pricing review, provider/driver/vehicle status, compliance blockers, and funding as applicable.
5. Apply all core rows, snapshots, current-axis changes, append-only events, audit, and `notification_events(status='QUEUED')` in the same transaction.
6. Mark `command_idempotency` completed with the response. Any failure rolls back every business, event, audit, and notification row.

Unique active-route, reservation, and assignment indexes decide concurrent winners. A loser never retries internally against changed state; it returns the committed current context.

## 4. Stable error contract

| Code | Meaning |
|---|---|
| `NOT_FOUND` | Shipment or command target is unavailable to the actor. |
| `NOT_AUTHORIZED` | Ownership, membership, role, or worker authority failed. |
| `STALE_SHIPMENT_VERSION` | `expectedShipmentVersion` is no longer current. |
| `STALE_ROUTE_VERSION` | Request references a superseded/non-current route. |
| `INVALID_STATE` | Macro or independent axis does not permit the command. |
| `ROUTE_INVALID` | Stop order, legs, allocation balance, capacity, timing, cargo eligibility, or evidence profile failed. |
| `MARKETPLACE_PAUSED` | A new match/offer is blocked while paused. Existing expiry timers still run. |
| `DEADLINE_EXPIRED` | Listing, offer, reconfirmation, or reservation deadline elapsed. |
| `PRICING_REVIEW_REQUIRED` | Pricing source/version/mode/amount review is absent, stale, rejected, or expired. |
| `OFFER_NOT_ACTIONABLE` | Offer/match is closed, withdrawn, declined, expired, or route-stale. |
| `COUNTER_LIMIT_REACHED` | Third customer counter or provider revision. |
| `RESERVATION_CONFLICT` | Another selection owns the active reservation. |
| `FUNDING_NOT_SECURED` | Full accepted route amount is not secured in the correct currency. |
| `COMPLIANCE_BLOCKED` | Provider, driver, or vehicle has an applicable required blocker. |
| `ASSIGNMENT_CONFLICT` | Another transaction committed the active whole-route assignment. |
| `IDEMPOTENCY_KEY_REUSED` | Key exists with a different request hash. |

## 5. Command contracts

### A01 — `saveDraft`

| Contract area | Requirement |
|---|---|
| Request | Common envelope plus pickup timing, service level, contacts, stop/service-window inputs, cargo lines, and optional current draft route version. |
| Authorization and locks | Customer profile or active customer-organization member owns the shipment. Lock shipment and current draft route. State must be `DRAFT`. |
| Atomic writes | Apply non-material shipment fields and editable plan rows only to a `DRAFT` route; increment shipment version. Do not create marketplace, pricing, payment, or assignment records. |
| Events and jobs | Append `audit_events(command_name='saveDraft')` with changed-field summary. No customer notification. |
| Automated tests | Owner succeeds; non-owner fails; stale version fails; retry returns same result; no marketplace row changes; terminal shipment fails. |

### A02 — `editDraftRoute`

| Contract area | Requirement |
|---|---|
| Request | Common envelope plus complete ordered stop plan, legs or routing input, cargo lines, allocations, and change reason. |
| Authorization and locks | Owning customer; shipment `DRAFT`; lock shipment and current draft route. |
| Atomic writes | Mark prior draft `SUPERSEDED`; create next `route_versions` draft and complete copied/changed stops, legs, cargo, and allocations with stable stop/cargo keys; increment shipment version. Do not activate yet. |
| Events and jobs | Audit prior/new route IDs and change reason. No notification. |
| Automated tests | Add/remove/reorder succeeds; invalid duplicate/gapped stop order fails activation preview; prior draft remains preserved; stale route/version and retry cases. |

### A03 — `assignCargoToStops`

| Contract area | Requirement |
|---|---|
| Request | Common envelope plus current draft route ID and complete allocation set `{cargoItemId,pickupStopId,deliveryStopId,quantity,unit}`. |
| Authorization and locks | Owning customer; shipment and route are `DRAFT`; lock both. |
| Atomic writes | Replace only the draft allocation set; validate same-version references, pickup-before-delivery, valid endpoint types, unit equality, and total allocation equality per cargo line; increment shipment version. |
| Events and jobs | Audit allocation counts/hash. No notification. |
| Automated tests | 1:1, 1:many, many:1, and architecture-ready many:many pass; reversed stops, cross-version IDs, unbalanced quantity, and unit mismatch fail. |

### A04 — `postShipment`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, current draft route, verified payment-method reference, selected pricing source/mode/version, and configured marketplace deadline. |
| Authorization and locks | Owning customer; state `DRAFT`; payment method is verified; lock shipment, four axes, route, selected policy/pricing versions. |
| Atomic writes | Validate and activate route; insert `pricing_reviews`, `shipment_rule_snapshots`, and `shipment_price_snapshots(purpose='POSTING')`; set customer-payment axis `METHOD_VERIFIED`, marketplace `ACTIVE`, shipment `POSTED`; append macro/axis events and audit. |
| Events and jobs | `shipment_state_events: postShipment`; marketplace/payment axis events; queue `SHIPMENT_POSTED` and marketplace-expiry scheduling event. |
| Automated tests | Valid multi-stop post; missing/unbalanced cargo; route infeasible; ineligible cargo; unverified payment method; stale pricing/policy; atomic rollback; concurrent post winner. |

### A05 — `editPostedShipment`

| Contract area | Requirement |
|---|---|
| Request | Common envelope plus complete replacement route/cargo plan and change reason. |
| Authorization and locks | Owning customer; state `POSTED`; no active reservation or assignment; lock shipment, marketplace axis, active route, and active offers. |
| Atomic writes | Create/validate next route plan; supersede old active plan and activate new one; rerun eligibility, ETA, pricing review, expiry, and evidence/rule snapshots; keep macro state `POSTED`; increment version. Existing offer handling follows materiality rules and never silently changes accepted terms. |
| Events and jobs | Audit route/snapshot before/after; queue `POSTED_SHIPMENT_UPDATED` to affected providers when applicable. |
| Automated tests | Non-material and material fields; reservation/assignment blocks; pricing recalculation; stale route; old snapshot preservation; concurrent offer/edit race. |

### A06 — `pauseMarketplace`

| Contract area | Requirement |
|---|---|
| Request | Common envelope and pause reason. |
| Authorization and locks | Owning customer; `POSTED` or `NEGOTIATING`; no active reservation/assignment; lock shipment and marketplace axis. |
| Atomic writes | Set marketplace `PAUSED`; do not alter macro state, offer status, or `expires_at`; increment shipment version; append axis event/audit. |
| Events and jobs | Queue `MARKETPLACE_PAUSED` for the customer. No offer-expiry job is cancelled. |
| Automated tests | New offers blocked; existing expiries unchanged and still close; post-reservation pause fails; retry/stale version. |

### A07 — `resumeMarketplace`

| Contract area | Requirement |
|---|---|
| Request | Common envelope. |
| Authorization and locks | Owning customer or expiry worker; marketplace `PAUSED`; no reservation/assignment; lock shipment, axis, route, pricing review, and relevant offers. |
| Atomic writes | Revalidate route, schedule, price source/version, eligibility, payment method, deadline, and offer timers. If deadline remains valid, set marketplace `ACTIVE`; otherwise close offers, set marketplace and shipment `EXPIRED`, and release authorization. |
| Events and jobs | Axis event plus optional `shipment_state_events: expireListing`; queue `MARKETPLACE_RESUMED` or `SHIPMENT_EXPIRED`. |
| Automated tests | Valid resume; expired deadline; stale pricing/compliance; expired offers remain expired; paused state preserved on failed validation. |

### A08 — `submitIndependentFlexOffer`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, provider/driver/vehicle IDs, amount/currency, validity window, and current route ID. |
| Authorization and locks | Active independent provider-driver membership; active eligible driver/vehicle; no compliance blocker; marketplace `ACTIVE`; shipment `POSTED` or already `NEGOTIATING`; lock shipment, axis, route, and pricing review. |
| Atomic writes | Enforce `HAULVIA_GUARDRAIL`, Flex service, full-route coverage, floor/ceiling/justification/cap, and expiry; insert pricing review/snapshot, offer thread, and immutable `INITIAL` revision. First actionable offer moves shipment to `NEGOTIATING`. |
| Events and jobs | Macro event when first offer; audit; queue `OFFER_RECEIVED` to customer and `OFFER_SUBMITTED` to provider. |
| Automated tests | Within controls; below floor/above cap; justification band; paused marketplace; ineligible/compliance-blocked provider; stale route; duplicate retry; simultaneous first offers. |

### A09 — `submitPartnerFlexOffer`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, courier provider/driver/vehicle, approved rate-card version, amount, full-route scope, and validity. |
| Authorization and locks | Active courier partner and eligible resources; marketplace `ACTIVE`; current route; lock shipment, route, rate card, and pricing review. |
| Atomic writes | Require `PARTNER_RATE_CARD` + `FLEX_NEGOTIABLE`, effective approved card and matching service/region/vehicle/currency, passed review, full-route coverage; insert snapshot/thread/initial revision; move first offer to `NEGOTIATING`. |
| Events and jobs | Same offer events/jobs as A08, with rate-card version in audit/snapshot. |
| Automated tests | Effective card succeeds; draft/suspended/retired/expired or scope mismatch fails; outlier review; stale route; pause; retry and concurrent first-offer cases. |

### A10 — `acceptFirmRouteMatch`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, provider/driver/vehicle, firm price snapshot, and configured reservation window. |
| Authorization and locks | Eligible independent/provider actor; marketplace `ACTIVE`; current route; branch is `HAULVIA_FIXED`, `FLEX_FIRM`, or `EXPEDITED_FIRM`; lock shipment, route, price/review, and marketplace. |
| Atomic writes | Create firm offer thread and immutable `FIRM_MATCH` revision; create one active reservation and accepted reservation snapshot; set marketplace `RESERVED`, payment axis `AUTHORIZING`, shipment `NEGOTIATING`; create payment intent. Counter/revision commands remain unavailable. |
| Events and jobs | State/axis events and audit; queue `FIRM_MATCH_RESERVED` and payment-timeout job/event. |
| Automated tests | Each firm branch; counter rejected; invalid rate-card scope; competing reservation race; payment window; stale route/review; retry. |

### A11 — `counterOffer / reviseOffer`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, offer thread ID, response-to revision ID, amount/currency, validity, and optional structured reason. |
| Authorization and locks | Customer owns shipment for `counterOffer`; provider owns thread for `reviseOffer`; state `NEGOTIATING`; negotiable Flex only; lock shipment and thread. |
| Atomic writes | Verify active timer/current route; run pricing review; insert matching `OFFER` price snapshot and immutable `CUSTOMER_COUNTER` or `PROVIDER_REVISION`; enforce two-per-side limits. No in-place update. |
| Events and jobs | Audit revision lineage; queue `OFFER_COUNTERED` or `OFFER_REVISED` to the opposite party plus warning/expiry job. |
| Automated tests | Two each succeed; third fails; firm branch fails; expired/stale/withdrawn thread fails; amount/snapshot mismatch; concurrent second/third revision; retry. |

### A12 — `closeLastActiveOffer`

| Contract area | Requirement |
|---|---|
| Request | Worker command with shipment ID, observed active-offer set/version, and close cause. |
| Authorization and locks | Trusted expiry/offer worker; lock shipment, marketplace axis, and all actionable threads in deterministic ID order. |
| Atomic writes | Close/expire the triggering thread; if any actionable thread/reconfirmation remains, keep `NEGOTIATING`. Otherwise return shipment to `POSTED` when deadline valid, preserve marketplace `PAUSED` when paused, or set shipment/marketplace `EXPIRED`; never delete history. |
| Events and jobs | Thread audit; macro/axis events only when state changes; queue `NO_ACTIVE_OFFERS` or `SHIPMENT_EXPIRED` to customer. |
| Automated tests | Another offer remains; last offer with active/paused/expired listing; delayed duplicate expiry; offer accepted concurrently; stable lock order. |

### A13 — `materiallyEditNegotiation`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, complete replacement plan, materiality reason, and recalculation inputs. |
| Authorization and locks | Owning customer; shipment `NEGOTIATING`; no active reservation/assignment; lock shipment, marketplace, active route, and all active threads. |
| Atomic writes | Set marketplace `PAUSED`; mark active offers/firm matches `RECONFIRMATION_REQUIRED`; create/validate/activate new route version and supersede prior; recalculate ETA/eligibility/pricing/evidence snapshots; move shipment to `POSTED`; preserve all prior terms. |
| Events and jobs | State/axis events and route/audit snapshots; queue `RECONFIRMATION_REQUIRED` to each affected provider and `SHIPMENT_EDITED` to customer. |
| Automated tests | Every active thread marked; reservation race loses safely; old route/offers immutable; failed pricing/route validation rolls back; stale route/version; retry. |

### A14 — `reconfirmOfferOrFirmMatch`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, thread ID, reconfirmation route ID, applicable price/review/snapshot, and validity. |
| Authorization and locks | Provider owns affected thread; thread `RECONFIRMATION_REQUIRED`; route is current; provider/driver/vehicle/compliance rechecked; lock shipment, route, and thread. |
| Atomic writes | Insert immutable `RECONFIRMATION` revision for new route and price version; return thread `ACTIVE`. The first actionable reconfirmation moves shipment `POSTED` to `NEGOTIATING`; marketplace remains paused until explicit resume when policy requires it. |
| Events and jobs | State event for first reconfirmation; audit old/new route and price versions; queue `OFFER_RECONFIRMED` to customer and provider. |
| Automated tests | Negotiable and firm reconfirmation; wrong/old route; expired timer; provider no longer eligible; first versus later reconfirmation; retry/concurrency. |

### A15 — `reserveSelection`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, selected thread/revision, accepted price snapshot, payment method, and configured reservation expiry. |
| Authorization and locks | Owning customer or trusted matching worker; shipment `NEGOTIATING`; selection active/current/unexpired; no reservation/assignment; lock shipment, axis, selection, and competing active threads. |
| Atomic writes | Insert the single active `offer_reservations` row; mark selection `RESERVED`; retain other still-valid offers without reviving any expired offer; set marketplace `RESERVED`, payment axis `AUTHORIZING`; create payment intent and accepted reservation snapshot. |
| Events and jobs | Axis/audit events; queue `SELECTION_RESERVED`, provider/customer notices, and payment-timeout event/job. |
| Automated tests | Valid selection; stale/expired/reconfirmation-required revision; two customers/tabs race; payment method failure; other offers retained; retry. |

### A16 — `confirmPaidAssignment`

| Contract area | Requirement |
|---|---|
| Request | Authenticated payment result with provider event ID, payment intent/reservation IDs, secured amount/currency, and agreement snapshot inputs. |
| Authorization and locks | Trusted payment worker; verify webhook authenticity outside the transaction; lock provider event/idempotency record, payment intent, shipment, axes, reservation, route, selection, and assignment key. |
| Atomic writes | Require timely full funding, active reservation/current pricing review, current route, and revalidated provider/driver/vehicle/compliance. Append payment transaction; set intent/payment axis `SECURED`; create accepted `ASSIGNMENT` price snapshot and one active whole-route assignment plus event; convert reservation; accept selected thread; close competitors and marketplace; set shipment `DRIVER_ASSIGNED`; snapshot agreement. |
| Events and jobs | Payment, marketplace, assignment, and shipment events plus audit; queue `ASSIGNMENT_CONFIRMED` to customer/provider/driver and trip-start deadline/reminder jobs. |
| Automated tests | Exact funding succeeds; partial/wrong currency fails; compliance/pricing/reservation expiry fails; two assignments race; cancellation race first commit wins; duplicated webhook replays; late success cannot assign. |

### A17 — `releaseFailedReservation`

| Contract area | Requirement |
|---|---|
| Request | Trusted payment/timeout result, intent/reservation IDs, failure category, provider event ID, and observed time. |
| Authorization and locks | Trusted worker; lock provider event, intent, shipment, axes, reservation, selected thread, and competing threads. |
| Atomic writes | Record failed/timed-out transaction and intent; release reservation; set payment axis `FAILED` or `RELEASED`; restore only selections still valid for the current route. Preserve `PAUSED` marketplace. If no actionable selection remains, apply `POSTED`/`EXPIRED` deadline result. A later success is recorded then voided/refunded and never assigns/reopens. |
| Events and jobs | Payment/marketplace/shipment events and audit; queue `PAYMENT_FAILED_OR_TIMED_OUT`; when needed queue late-success void/refund job. |
| Automated tests | Failure and timeout; valid offers restored; expired offers stay closed; paused state preserved; deadline expiry; delayed success; duplicate/out-of-order webhooks; cancel race. |

### A18 — `cancelPreAssignment`

| Contract area | Requirement |
|---|---|
| Request | Common envelope, cancellation reason, rule snapshot/version, and displayed refund/authorization outcome. |
| Authorization and locks | Owning customer; shipment `POSTED` or `NEGOTIATING`; no committed active assignment; lock shipment, axes, reservation, payment intent, and threads. |
| Atomic writes | First valid transaction wins. Set shipment `CANCELLED` and terminal time; close marketplace/selections; release reservation; void/release applicable authorization; append payment/shipment/axis events, cancellation snapshot, and audit. |
| Events and jobs | Queue `SHIPMENT_CANCELLED` to customer and affected providers plus payment void/release job when provider action is pending. |
| Automated tests | Posted and negotiating; reservation release; assignment race; stale version; duplicate; terminal cannot reopen; no partial close on provider failure. |

### A19 — `expireListing`

| Contract area | Requirement |
|---|---|
| Request | Trusted scheduler command with shipment ID, expected version, observed deadline, and expiry policy version. |
| Authorization and locks | Trusted expiry worker; state `POSTED` or `NEGOTIATING`; deadline elapsed; no paid assignment; lock shipment, axes, reservation/payment intent, and threads. |
| Atomic writes | Set shipment and marketplace `EXPIRED`; close all selections; expire/release reservation; release/void applicable authorization; append state/axis/payment events and audit. Reservation receives only its configured payment window; no implicit extension. |
| Events and jobs | Queue `SHIPMENT_EXPIRED` to customer and closure notices to affected providers. |
| Automated tests | Posted/negotiating expiry; active reservation timeout; paid assignment race; early scheduler call fails/no-op; delayed duplicate replay; terminal cannot reopen. |

## 6. Block A event and notification minimums

| Command family | Required durable records |
|---|---|
| Draft saves/edits | `command_idempotency`, route version lineage when applicable, `audit_events` |
| Posting/material edits | rule/price snapshots, `shipment_state_events`, `workflow_axis_events`, audit, queued notifications |
| Offers/counters/reconfirmation | immutable price snapshot and `offer_revisions`, thread current status, audit, queued notifications |
| Reservation/payment | reservation, payment intent/transaction, payment/marketplace axis events, audit, timeout/provider jobs |
| Assignment | assignment and `assignment_events`, accepted agreement/price snapshots, shipment/axis events, audit, reminders |
| Cancellation/expiry | terminal shipment event, marketplace/payment axis events, closed selections, release/void transaction or job, audit, notices |

## 7. Required Block A automated suites

The implementation is not complete until tests cover:

1. every command's positive path and every listed guard;
2. customer/provider/system authorization and cross-organization isolation;
3. idempotent replay and same-key/different-payload rejection;
4. stale shipment and route versions;
5. route stop order and cargo allocation/capacity balance;
6. each pricing source/mode and invalid combination;
7. counter limits and expiry/reconfirmation behavior;
8. pause semantics while existing offer timers continue;
9. reservation/payment timeout and delayed/out-of-order webhooks;
10. cancellation versus paid assignment and two-assignment races;
11. atomic rollback with no orphan event, notification, payment, offer, reservation, or assignment row;
12. terminal immutability.

`haulvia_foundation_acceptance_v1.sql` verifies the database-level prerequisites. `haulvia_block_a_acceptance_v1.sql` exercises every Block A row plus replay, authorization, stale-state, pricing, counter, reservation, funding, cancellation, expiry, and atomic rollback guards. True multi-session race tests remain part of the hosted PostgreSQL verification.

## 8. Implemented entry-point mapping

The private `haulvia_command` schema exposes one security-definer wrapper per approved row. A11 has two wrappers because customer countering and provider revision have different authorization paths.

| Matrix row | Trusted function |
|---|---|
| A01 | `command_save_draft(jsonb)` |
| A02 | `command_edit_draft_route(jsonb)` |
| A03 | `command_assign_cargo_to_stops(jsonb)` |
| A04 | `command_post_shipment(jsonb)` |
| A05 | `command_edit_posted_shipment(jsonb)` |
| A06 | `command_pause_marketplace(jsonb)` |
| A07 | `command_resume_marketplace(jsonb)` |
| A08 | `command_submit_independent_flex_offer(jsonb)` |
| A09 | `command_submit_partner_flex_offer(jsonb)` |
| A10 | `command_accept_firm_route_match(jsonb)` |
| A11 | `command_counter_offer(jsonb)` / `command_revise_offer(jsonb)` |
| A12 | `command_close_last_active_offer(jsonb)` |
| A13 | `command_materially_edit_negotiation(jsonb)` |
| A14 | `command_reconfirm_offer_or_firm_match(jsonb)` |
| A15 | `command_reserve_selection(jsonb)` |
| A16 | `command_confirm_paid_assignment(jsonb)` |
| A17 | `command_release_failed_reservation(jsonb)` |
| A18 | `command_cancel_pre_assignment(jsonb)` |
| A19 | `command_expire_listing(jsonb)` |
