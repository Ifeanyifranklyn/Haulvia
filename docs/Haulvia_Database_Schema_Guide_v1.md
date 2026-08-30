# Haulvia Database Schema Guide v1

**Status:** Verified foundation plus implemented Block A, Block B, Block C, Block D, and Block E command layers, derived from the approved Policy Decision Register v1.1 and State Transition Matrix v1.1

**Prepared:** August 14, 2026

**Implementation target:** PostgreSQL 16, written to remain compatible with Supabase Postgres

**Migrations:** `20260814000100_haulvia_foundation_v1.sql`, followed in order by additive migrations `20260814000200_haulvia_block_a_commands_v1.sql` through `20260814000600_haulvia_block_e_commands_v1.sql`

## 1. Outcome

The schema starts with the architecture required by the approved baseline rather than retrofitting it later:

- immutable, versioned route plans;
- ordered stops and adjacent route legs;
- versioned cargo lines with explicit pickup-to-delivery quantity allocations;
- append-only actual custody movements;
- reusable stop attempts and evidence at every stop;
- Haulvia and courier-partner pricing sources with accepted snapshots;
- whole-route offers, reservations, assignments, and payouts;
- separate shipment, marketplace, customer-payment, route-execution, payout, dispute, and delivery-verification axes;
- append-only histories, idempotency controls, and sensitive-action authority checks.

The foundation is followed by trusted Block A–E database command layers. All 19 approved Block A rows have named transactional entry points for draft/posting, pricing, offers, reservation, payment, assignment, cancellation, and expiry. All 12 approved Block B rows cover route start, first-stop service/evidence, first verified custody, pre-custody cancellation/driver release, deliberate edit/repost, and route/stop issues. All 14 approved Block C rows implement the reusable remaining-stop loop, per-stop pickup/delivery custody, failed-stop continuation, downstream ETA recalculation, immutable route amendment, transit issues, and aggregate route resolution. All 9 approved Block D rows implement stop-level receiver review, proof-based expiry, post-delivery dispute opening, irreversible operational completion, payout submission/provider outcomes, and authorized refunds or adjustments. All 16 approved Block E rows implement terminal-safe cancellation/expiry, immutable stop retry, explicit failed-pickup decisions, post-failure continuation, verified custody transfer, linked recovery, storage/return custody, independent dispute control/resolution/resumption, and terminal-to-draft copying. E04 reuses the existing `expireListing` wrapper, so Block E adds 15 wrappers rather than duplicating expiry.

## 2. Engine assumption

PostgreSQL 16 / Supabase compatibility is an implementation target, not a new policy decision. It is a reversible choice because the model uses ordinary relational constraints, PostgreSQL enums, `jsonb` only for snapshots/provider payloads, and PostgreSQL's built-in `gen_random_uuid()`. No Supabase-specific RLS or `auth.users` foreign key is included yet.

Before production, a follow-up security migration must define row-level policies after the actor and access rules are approved. Until then, the schema should be exposed only through a trusted service role/API layer.

## 3. Non-negotiable invariants

| Invariant | Database implementation |
|---|---|
| Daily public reference | `next_shipment_reference(date)` emits `HV-YYYYMMDD-0001` through `9999`, resetting by date. The API should pass the configured business date; the function default uses the database session date. |
| Independent status axes | Shipment, marketplace, customer payment, driver payout, dispute, route execution, and per-stop delivery verification use separate records/enums. `PAYMENT_PROCESSING` is not a shipment state. |
| Immutable terminals | `COMPLETED`, `CANCELLED`, `EXPIRED`, and `RETURNED_TO_SENDER` shipments cannot reopen or be edited. Reposting creates a new draft linked by `source_shipment_id`. |
| Versioned route | Only `DRAFT` route plans can be edited. Material changes create a new `route_versions` row and copied/changed stops, legs, cargo lines, and allocations. |
| Valid multi-stop route | Activation requires contiguous stop order beginning at 1, a pickup and delivery/recovery endpoint, one leg per adjacent stop pair, and fully balanced planned cargo allocations. |
| Pickup precedes delivery | Every `cargo_allocations` row links a cargo line, pickup stop, delivery/recovery stop, quantity, and unit inside the same route version; a trigger verifies sequence and endpoint types. |
| One active plan | A partial unique index permits only one active route version per shipment. |
| One active whole-route assignment | A partial unique index permits only one active assignment per shipment. Stop-level assignment is deliberately absent. |
| One current route execution | A partial unique index permits only one `NOT_STARTED`, `ACTIVE`, `HELD`, or `RECOVERY_ACTIVE` execution per shipment. |
| Funding before assignment | The assignment trigger requires the customer-payment axis to be `SECURED` for at least the accepted route snapshot total and matching currency. |
| Eligible assignment parties | The provider, provider-driver membership, driver, and vehicle must all be active when an assignment becomes active. |
| Negotiation limits | Only negotiable Flex branches allow counters/revisions. A trigger caps each thread at two customer counters and two provider revisions. Firm branches use `FIRM_MATCH`. |
| Offer reservation | Only one active reservation exists per shipment; assignment validates a current reservation when one is present. |
| Evidence preservation | Stop evidence, reviews, and corrections are append-only. A correction points to replacement evidence and never overwrites the original. |
| Custody preservation | `cargo_movements` is an append-only LOAD/UNLOAD/TRANSFER/STORAGE ledger with per-execution idempotency. Route resolution requires zero onboard balance. |
| No post-custody ordinary cancellation | A shipment that has any verified `LOAD` movement cannot use the ordinary cancellation/repost transitions. Recovery, transfer, return, or storage must be used. |
| Immutable retry lineage | A same-driver retry creates a new `stop_attempts` row and `stop_retry_records` link. The finalized failed attempt remains `FAILED`; continuation and retry authority are separate facts. |
| Verified custody transfer | Transfer requires exact onboard manifest, eligible replacement resources, QR/PIN, photo, GPS/time, both driver confirmations, and sensitive authority. Assignment changes while physical custody balance remains unchanged. |
| Recovery never overwrites | Recovery/return/redelivery creates a new route version, price snapshot, and child execution linked by `recovery_route_records`; the prior route/execution remain historical. |
| Complete storage custody | Storage records facility/address/access, condition/identifier, acceptance proof, item manifest, expenses/notices, responsibility, release conditions, deadline, movements/outcomes, and a selective workflow hold. |
| Exact return reconciliation | A return handoff appends `UNLOAD` and `RETURNED` facts. `RETURNED_TO_SENDER` is allowed only when every onboard balance reaches zero. |
| Dispute/operation separation | A dispute protects only the available disputed amount and does not stop movement by default. Movement may be held only for an unsafe, unlawful, or formal-hold basis, then resumes through a separate authorized command after resolution. |
| Terminal repost copy | A terminal source receives no update. `copyTerminalShipmentForRepost` creates a linked draft and copied draft route; policy, pricing, publication, funding, and assignment must be established afresh. |
| Per-stop receiver result | Delivery verification is stored on `stop_executions`, allowing later stops and aggregate route resolution while one contactless stop awaits receiver confirmation. Timeout never creates a receiver confirmation. |
| Versioned delivery-review window | Physical delivery completion creates one stop-level window from the retained `deliveryReviewSeconds` policy value. One immutable resolution wins; eligible proof may verify an expired window, but expiry never fabricates receiver identity or response. |
| Irreversible completion gate | `completeShipment` requires resolved delivery evidence/windows, route resolution, zero custody, no blocking physical exception, a retained release authorization, and versioned payout allocation. `COMPLETED` never waits for or moves backward because of bank settlement. |
| Disputed-only financial protection | Post-delivery issues and disputes preserve requested, protected, and unprotected amounts. Only the still-operationally-available disputed share is held; an undisputed payout share may proceed independently. |
| Provider outcome lineage | Payout requests and provider success/failure outcomes are separate append-only transactions. A unique non-null provider event and one outcome per request prevent duplicate callbacks from duplicating money movement. |
| Failed-stop custody truth | `stop_failure_reports` records the failed attempt, affected cargo, evidence, responsibility, downstream impact, and ledger-derived custody snapshot. Failure itself posts no LOAD/UNLOAD and cannot erase earlier onboard cargo. |
| Explicit continuation after failure | `stop_continuation_authorizations` separately retains the customer/workflow decision and route, capacity, timing, custody, and instruction snapshots before the next stop begins. The failed stop stays immutable. |
| ETA history and propagation | Current stop ETA is a pointer; `route_eta_calculations` and `route_stop_eta_predictions` append the formula inputs and every affected downstream prediction/notification. |
| Amendment lineage and funding | Post-assignment material change creates a new immutable route version and linked execution segment. Terminal stop keys, onboard cargo, and approved outcomes survive; positive non-emergency work requires separate secured payment first. |
| Aggregate route resolution | Completion rejects nonterminal stops, active completion holds, unresolved blocking exceptions, incomplete allocation outcomes, missing verified stop evidence, or nonzero onboard balance. Contactless confirmation remains independent. |
| Accurate public outcome | `cargo_resolution_outcomes` reconciles each allocation quantity. Public route labels enumerate distinct outcomes, while summaries group quantity by outcome and unit rather than adding incompatible measures. |
| Pricing preservation | Every price snapshot records source, partner mode, exact rule/rate-card version, review, amounts, currency, breakdown, and content hash. Snapshots are append-only. |
| Published rate-card preservation | Lines can change only while a rate-card version is draft or pending review. Accepted shipment snapshots continue pointing to the prior version. |
| Compliance non-applicability | A non-applicable item is forced to `is_required = false`; the blocker view considers only active, applicable, required, non-verified items. |
| Compliance action history | Approved compliance transitions require reviewer identity and an action note, timestamp the action, and append prior/current state plus item metadata. |
| Sensitive action gate | `assert_sensitive_authority` checks permission, fresh password/passkey/MFA reauthentication, authority scope, and a specific reason. The command must also write before/after audit. |
| Duplicate/race control | Unique active indexes, row locks inside guard triggers, `lock_version`, provider idempotency keys, and append-only command/event keys support first-valid-commit-wins handling. |
| Trusted Block A+B+C+D+E writes | `haulvia_command` is revoked from `PUBLIC`; named security-definer entry points use a fixed search path and are granted only to `service_role` when that role exists. |
| Retry before stale check | A completed matching idempotency request replays its stored response before shipment-version validation; the same key with another SHA-256 request hash fails. |
| Reservation pause memory | `offer_reservations.marketplace_state_before_reservation` restores `PAUSED` after failed payment instead of silently reopening the listing. |
| Unassigned provider payment reference | Multiple payment intents may have a null external reference; a partial unique index enforces uniqueness only after the provider reference exists. |
| Current route position | `route_executions` stores the active stop, active leg, next action, and optimistic `record_version`; append-only route updates and stop-attempt events preserve the position history. |
| First custody boundary | The first verified LOAD atomically creates `shipment_custody_milestones`; all pre-custody-only commands also check the append-only movement ledger. |
| Pre-custody financial decision | Cancellation/release preserves policy version, displayed charge, refund, compensation, responsibility, and reason independently from provider settlement work. |

## 4. Aggregate boundaries

| Aggregate or domain | Root | Owned records | Cross-domain references |
|---|---|---|---|
| Identity and authority | `organizations`, `profiles` | memberships, roles, permissions, reauth sessions | actors in audit and workflow records |
| Provider onboarding | `provider_applications`, `service_providers` | application events, provider-driver memberships, vehicles | eligibility and assignment |
| Compliance | `compliance_subjects` | items, documents, reviews, item history | providers, drivers, vehicles, applications |
| Policy and pricing publication | policy/rule/rate-card roots | immutable versions and rate-card lines | shipment snapshots and pricing reviews |
| Shipment | `shipments` | independent current axes and workflow histories | customer organization/profile |
| Route plan | `route_versions` | ordered stops, legs, cargo items, allocations | shipment, rule/price snapshots |
| Marketplace | `offer_threads` | revisions and reservations | route version, provider, driver, vehicle, snapshots |
| Assignment/execution | `assignments`, `route_executions` | stop executions, attempts, evidence, tracking, movements | funded reservation and accepted route |
| Financial | payment intents and payouts | immutable provider transactions, holds, adjustments | shipment, assignment, dispute/claim |
| Exception resolution | disputes, claims, holds, route exceptions | append-only resolution events | shipment/stop/cargo scopes |
| Receiver/communications | stop-scoped receiver token | confirmation, messages, notifications | shipment and stop execution |
| Block A+B+C+D+E command support | shipment command boundary | payment/cancellation/custody records plus ETA, failure/continuation, amendment, cargo outcome, route resolution, delivery review, completion, payout eligibility, retry, recovery, storage/return, dispute control/resolution, resumption, and terminal-copy facts | shipment, route, assignment/execution, policy, payment/payout, evidence, custody, receiver, dispute, hold, notification |

## 5. Table catalog

### 5.1 Identity, authority, and audit

| Table | Purpose |
|---|---|
| `organizations` | Stable organization/company identity for customers, providers, partners, and Haulvia. |
| `profiles` | Person identity with an optional portable `auth_user_id`; intentionally not hard-wired to Supabase Auth yet. |
| `organization_memberships` | Person-to-organization membership and lifecycle. |
| `roles`, `permissions`, `role_permissions`, `membership_roles` | Scoped authorization model, including stable sensitive permission codes. |
| `reauth_sessions` | Short-lived proof of password, passkey, or MFA verification. |
| `audit_events` | Append-only named-command audit with authority, reason, before/after data, correlation, and idempotency. |
| `command_idempotency` | Request ownership/result record for safe command retries. |

### 5.2 Provider and compliance

| Table | Purpose |
|---|---|
| `provider_applications` | Current application status; first meaningful review action should set `REVIEWING`. |
| `provider_application_events` | Append-only application action/status history. Internal work while awaiting information records an event without changing `NEEDS_MORE_INFO`. |
| `service_providers` | Approved or pending independent-driver/courier-partner business entity. |
| `drivers`, `provider_drivers`, `vehicles` | Driver identity, provider relationship, and assignable vehicle/capabilities. |
| `compliance_subjects` | Typed owner for application, provider, driver, or vehicle requirements. |
| `compliance_requirements` | Stable requirement definition: safety credential, maintenance, insurance, conditional TDG, licence/review documents, or custom Other. |
| `compliance_requirement_versions` | Effective applicability and evidence rules. Conditional TDG and non-applicability live here instead of hardcoded UI logic. |
| `compliance_items` | Subject-specific requirement instance and approved export fields. `item_instance_key` permits one row per carried insurance policy. |
| `compliance_documents` | Versioned uploaded files with object key and SHA-256. |
| `compliance_document_reviews` | Append-only document decisions. |
| `compliance_item_history` | Append-only prior/current lifecycle, reviewer, timestamp, action note, and item metadata. |
| `compliance_state_transition_rules` | Stable allowed lifecycle edges. |

The view `v_compliance_item_export` returns the exact approved field contract:

`itemCategory`, `complianceCode`, `complianceName`, `relatedServiceCode`, `holderName`, `credentialNumber`, `issuingAuthority`, `issueDate`, `effectiveDate`, `expiryDate`, `reviewStatus`, `isRequired`, `notes`, `reviewedAt`, `reviewerLabel`, `status`, `documentCount`, `acceptedDocumentCount`.

### 5.3 Versioned policy and pricing publication

| Table | Purpose |
|---|---|
| `policy_sets`, `policy_versions` | Versioned fees, percentages, timers, radii, evidence/risk rules, deadlines, and payout windows. |
| `pricing_rule_sets`, `pricing_rule_versions` | Haulvia guardrail and fixed-price configurations. |
| `partner_rate_cards` | Courier partner/service/region/vehicle scope, currency, and Flex/Expedited mode. |
| `partner_rate_card_versions` | Reviewed effective publication version with approver and reauthentication reference. |
| `partner_rate_card_lines` | Structured base, distance, duration, stop, waiting, surcharge, min/max, and tax components. |

Pricing branch mapping:

| Provider/service branch | `pricing_source` | `pricing_mode` | Negotiation |
|---|---|---|---|
| Independent Flex | `HAULVIA_GUARDRAIL` | `NOT_APPLICABLE` | Yes, within controls |
| Independent Expedited | `HAULVIA_FIXED` | `NOT_APPLICABLE` | No |
| Partner Flex negotiable | `PARTNER_RATE_CARD` | `FLEX_NEGOTIABLE` | Yes |
| Partner Flex firm | `PARTNER_RATE_CARD` | `FLEX_FIRM` | No |
| Partner Expedited | `PARTNER_RATE_CARD` | `EXPEDITED_FIRM` | No |

### 5.4 Shipment and independent axes

| Table | Purpose |
|---|---|
| `shipment_reference_counters` | Locked daily sequence source for public references. |
| `shipments` | Operational aggregate root and macro physical lifecycle only. |
| `shipment_marketplace_axes` | Visibility/pause/reservation/closure independent of physical lifecycle. |
| `shipment_customer_payment_axes` | Current customer funding summary. |
| `shipment_driver_payout_axes` | Current route-payout readiness/processing summary. |
| `shipment_dispute_axes` | Current dispute summary/count. |
| `shipment_state_transition_rules` | Stable approved macro transitions. |
| `shipment_state_events` | Append-only macro transition history. |
| `workflow_axis_events` | Append-only history for every independent axis. |

Each shipment insert initializes all four one-to-one summary axes and appends its initial `DRAFT` event.

### 5.5 Route plan, cargo, and snapshots

| Table | Purpose |
|---|---|
| `route_versions` | Draft/active/superseded/frozen route plan version and amendment lineage. |
| `route_stops` | Ordered address/contact/window/service/evidence snapshot. |
| `route_legs` | Adjacent stop-to-stop planned movement, distance, time, and routing-provider response. |
| `cargo_items` | Versioned cargo lines with stable keys, quantity, value, handling, and risk attributes. |
| `cargo_allocations` | Quantity-level pickup-stop to delivery/recovery-stop mapping. |
| `shipment_rule_snapshots` | Accepted evidence, cancellation, refund, timing, and risk configuration. |
| `pricing_reviews` | Outlier/guardrail/rate-card review independent of route state. |
| `shipment_price_snapshots` | Append-only price source/mode/version/amount/breakdown accepted by a workflow stage. |

The allocation model supports one-to-one, one-to-many, many-to-one, and many-to-many route plans. Product exposure should initially allow the first three only. It does not support automated consolidation of independent customer shipments.

### 5.6 Marketplace and assignment

| Table | Purpose |
|---|---|
| `offer_threads` | Provider/driver/vehicle response to a complete route and pricing branch. |
| `offer_revisions` | Immutable initial, counter, provider revision, firm match, or reconfirmation terms. |
| `offer_reservations` | Short payment window for one selected revision while other valid offers are held. |
| `assignments` | One whole-route funded provider/driver/vehicle agreement. |
| `assignment_events` | Append-only assignment/reassignment/cancellation history. |

Pausing changes only `shipment_marketplace_axes.state`; offer `expires_at` values continue to run. A material route edit creates another route version and marks affected threads `RECONFIRMATION_REQUIRED`; old offers never revive implicitly.

### 5.7 Route execution, evidence, tracking, and custody

| Table | Purpose |
|---|---|
| `route_executions` | Primary, amendment, recovery, return, or redelivery execution plus current active stop/leg, next action, and optimistic position version. |
| `stop_executions` | Per-stop current state, receiver-verification state, current ETA pointer, ETA update time, and free-waiting deadline for one route execution. |
| `stop_state_transition_rules` | Stable reusable stop-loop transitions. |
| `stop_attempts`, `stop_attempt_events` | Retry-safe attempt record and immutable attempt timeline. |
| `stop_evidence`, `stop_evidence_reviews`, `stop_evidence_corrections` | Original evidence, decisions, and correction lineage. |
| `cargo_movements` | Actual append-only custody ledger. |
| `shipment_custody_milestones` | Immutable first verified LOAD boundary linked to its execution, stop, and first movement. |
| `tracking_sessions`, `tracking_points`, `route_updates` | Online/offline position, ETA, dwell, delay, active leg/stop, and custody summaries. |
| `route_eta_calculations` | Append-only trigger, route snapshot, base ETA, delay, and formula context for each recalculation. |
| `route_stop_eta_predictions` | Append-only per-downstream-stop ETA with prior ETA, drive/service contribution, change, and notification link. |
| `workflow_holds` | Selective blockers for marketplace, route movement, or completion without replacing physical state. |
| `route_exceptions` | Stop/route/cargo problem and audited resolution. |
| `stop_failure_reports` | Immutable attempt-level pickup/delivery failure with affected cargo, custody, evidence context, responsibility, impact, and next-decision snapshot. |
| `stop_continuation_authorizations` | Separate approved authority to move after failure with route, capacity, timing, custody, and customer-instruction snapshots. |
| `route_amendments` | Immutable old/new route-version and execution-segment lineage, driver acceptance, repricing, payment, reason, and approval snapshot. |
| `cargo_resolution_outcomes` | Quantity/unit result per allocation: delivered, returned, stored, transferred, approved not loaded, or other approved recovery. |
| `route_resolution_records` | Aggregate route completion proof with public outcome disclosure and custody/evidence reconciliation. |
| `custody_transfers`, `custody_transfer_items` | Verified driver/vehicle handoff and cargo quantities. |
| `stop_retry_records` | Immutable failed-attempt to new same-driver attempt lineage and serviceability snapshot. |
| `failed_first_pickup_resolutions` | Explicit zero-custody repost-review or terminal closure decision for a failed first pickup. |
| `custody_transfer_authorizations` | Exact custody, evidence, authority, and old/new assignment transfer snapshot. |
| `recovery_route_records` | Prior/new route and execution lineage plus provider acceptance, custody, price, payment, and recovery decision. |
| `storage_custody_records` | Complete facility, condition, identifier, access, expense, notice, responsibility, release, deadline, movement-hold custody record. |
| `return_handoff_records` | Sender acceptance, cargo manifest, movements, evidence, mixed outcomes, and before/after custody reconciliation. |
| `workflow_resumption_records` | Resolved source, released hold, old/new route and stop states, new attempt, custody, next action, and authority. |

`v_cargo_custody_balance` signs movements from the active driver's onboard perspective: LOAD, TRANSFER_IN, and STORAGE_OUT add; UNLOAD, TRANSFER_OUT, and STORAGE_IN subtract.

### 5.8 Financials, disputes, and claims

| Table | Purpose |
|---|---|
| `payment_intents` | Customer authorization/security request and late-timeout state. |
| `payment_transactions` | Append-only authorize/capture/void/refund/adjustment/chargeback provider events. |
| `driver_payouts`, `payout_transactions` | Whole-route payout summary and immutable provider attempts/results. |
| `financial_holds` | Amount-scoped protection independent of shipment execution. |
| `financial_adjustments` | Append-only authorized refund, charge, credit, or driver compensation linked to route/stop/cargo, fresh authentication, and provider request when applicable. |
| `disputes`, `dispute_events` | Evidence-based dispute case and immutable history. |
| `dispute_operational_controls` | Independent physical-movement effect, safety/legal/formal-hold basis, and linked workflow hold for a dispute. |
| `dispute_resolution_records` | Authorized evidence decision, exact release/retention of protected funds, and next route action. |
| `claims`, `claim_events` | Damage, shortage, or loss claim that can remain open after operational completion. |
| `payout_eligibility_records` | Immutable whole-route evidence/window, accepted-price, policy, hold, allocation, and release-authorization snapshot. |
| `shipment_completion_records` | Immutable proof of operational completion and the separately created payout. |

Late payment success is recorded in `payment_transactions`, but it must not change the payment axis to `SECURED` after reservation timeout; the payment handler issues the configured void/refund. The assignment trigger therefore cannot assign a timed-out late success.

### 5.9 Receiver and communications

| Table | Purpose |
|---|---|
| `receiver_access_tokens` | Hashed, expiring, shipment/stop-limited access with no pricing/edit/cancel authority. |
| `receiver_confirmations` | Stop/cargo-specific confirmation or issue response. |
| `delivery_review_windows` | Exact delivery-stop deadline and retained timing-policy/token snapshot. |
| `delivery_review_window_resolutions` | First-valid receiver, proof, issue, exception, or non-required result for a stop window. |
| `delivery_problem_reports` | Receiver issue evidence plus cargo, dispute, and disputed/protected amount references. |
| `shipment_messages` | Shipment/stop-scoped protected communication and attachment metadata. |
| `notification_events` | Template/version/channel delivery history and idempotency. |

### 5.10 Block A, Block B, Block C, Block D, and Block E command-support records

| Table | Purpose |
|---|---|
| `customer_payment_method_refs` | Verified external payment-method evidence without storing raw card or bank credentials. |
| `workflow_jobs` | Durable transactional outbox for listing/offer expiry, payment timeout, void/refund, and trip reminders. |
| `shipment_cancellation_snapshots` | Append-only pre-assignment cancellation evidence with prior macro/marketplace/payment states and governing policy. |
| `shipment_custody_milestones` | One immutable first-custody boundary per shipment; the movement ledger remains quantity authority. |
| `pre_custody_financial_decisions` | Append-only accepted-policy charge/refund/driver-compensation decision for assigned or in-progress cancellation/release. |
| `route_eta_calculations`, `route_stop_eta_predictions` | Immutable ETA calculation and per-stop propagation records. |
| `stop_failure_reports`, `stop_continuation_authorizations` | Failed-stop fact and separately approved continuation decision. |
| `route_amendments` | Immutable post-assignment material-change lineage and funding/acceptance proof. |
| `cargo_resolution_outcomes`, `route_resolution_records` | Allocation-level result evidence and unit-safe aggregate route reconciliation. |
| `delivery_review_windows`, `delivery_review_window_resolutions` | Versioned stop deadline and one immutable receiver/proof/issue/exception result. |
| `delivery_problem_reports` | Receiver problem evidence, dispute link, and exact disputed/protected allocation. |
| `payout_eligibility_records`, `shipment_completion_records` | Whole-route release/payout snapshot and irreversible operational completion proof. |
| `stop_retry_records`, `failed_first_pickup_resolutions` | Immutable same-driver retry and explicit failed-first-pickup outcome lineage. |
| `custody_transfer_authorizations`, `recovery_route_records` | Verified reassignment handoff and old/new recovery route/execution/price lineage. |
| `storage_custody_records`, `return_handoff_records` | Complete storage or sender-return proof plus custody-ledger reconciliation. |
| `dispute_operational_controls`, `dispute_resolution_records` | Separate operational movement effect and evidence/financial/next-action resolution. |
| `workflow_resumption_records`, `terminal_shipment_reposts` | Explicit post-resolution resumption and immutable terminal-source to new-draft copy lineage. |

The private `haulvia_command` schema contains common authorization, route-plan, pricing, idempotency, execution-position, evidence, custody, ETA, receiver, dispute, payout, audit, and outbox helpers. It exposes one named entry point per approved Block A–E row. A11 exposes both `command_counter_offer` and `command_revise_offer` while remaining one approved matrix contract; E04 deliberately reuses `command_expire_listing`. The result is 70 wrappers for 70 approved rows across Blocks A–E.

## 6. Read models

| View | Purpose |
|---|---|
| `v_compliance_item_export` | Exact compliance export contract. |
| `v_compliance_blockers` | Only active, applicable, required, non-verified compliance blockers. |
| `v_route_allocation_manifest` | Human-readable route version/cargo/pickup/delivery mapping. |
| `v_cargo_custody_balance` | Actual onboard balance by stable cargo key. |
| `v_shipment_operating_context` | Current macro and independent axes plus active route/position/ETA, custody, public route outcome, review/finance summaries, active recovery/storage records, verified transfer count, terminal repost count, and resumable hold count. |

## 7. Transaction boundaries for the command layer

The following bundles must commit or roll back as one transaction:

1. **Publish partner rate card:** verify authority/fresh authentication/reason; create effective version and lines; audit before/after; notify owner.
2. **Post multi-stop route:** implemented in Block A—validate/activate route; capture policy and price snapshots; set shipment and marketplace axes; append events and outbox work.
3. **Paid route assignment:** implemented in Block A—lock shipment/reservation; verify exact secured funding and current pricing review; recheck provider resources/compliance; create assignment; convert reservation; close competitors/marketplace; update shipment; append events, audit, notices, and reminder work.
4. **Start route and first stop:** implemented in Block B—recheck funds/assignment/eligibility/holds; create execution/stops/attempt/tracking; set active position; append events, ETA update, and notice.
5. **Verify stop service:** first pickup is implemented in Block B and the reusable pickup/delivery loop in Block C—lock execution/attempt; validate baseline and accepted per-stop evidence; append LOAD/UNLOAD movement(s); preserve quantity/unit exceptions; complete only that stop; emit custody/ETA/notifications.
6. **Failed-stop continuation:** implemented in Block C—retain the failed attempt and custody snapshot; require a separately authorized route/capacity/timing/custody/customer decision; start the next eligible stop without rewriting the failure.
7. **Route amendment:** implemented in Block C—preserve prior route/execution/evidence/movements; validate stable stop/cargo/outcome lineage; create and activate the new plan and linked execution; recalculate policy/price/ETA/evidence; secure additional non-emergency payment; retain driver acceptance and approval snapshots.
8. **Live route update:** implemented in Block C—append GPS/leg/ETA/dwell/delay/connectivity/custody; propagate ETA through remaining drive and service time; notify only affected downstream contacts; do not overwrite physical state.
9. **Aggregate route resolution:** implemented in Block C—require terminal stops, full allocation outcomes, zero onboard cargo, verified evidence, and no blocking exception/hold; append unit-safe public outcome/custody/evidence reconciliation; keep contactless confirmation independent.
10. **Delivery review response:** implemented in Block D—lock the exact stop window and resolved route; verify one-use receiver authority and delivered cargo references; append the first receiver/proof/issue/exception result; never fabricate confirmation on expiry.
11. **Operational completion:** implemented in Block D—require route/evidence/window/custody/exception reconciliation and release authorization; append eligibility/completion snapshots; create READY or HELD payout; make `COMPLETED` immutable without waiting for bank settlement.
12. **Post-delivery dispute:** implemented in Block D—authorize the owning customer or retained provider; append evidence/case/history; protect only the operationally available disputed amount; preserve the physical shipment state.
13. **Payout request/result:** implemented in Block D—calculate available amount after successful, outstanding, and held allocations; append provider request and one linked success/failure outcome; recompute the payout axis; leave `COMPLETED` unchanged.
14. **Refund or adjustment:** implemented in Block D—require `FINANCIAL_ADJUST`, fresh authentication, reason, authorization snapshot, and provider idempotency; append the route/stop/cargo-linked transaction and audit without rewriting physical state.
15. **Custody transfer:** implemented in Block E—lock the positive custody ledger and current execution; require a complete manifest, eligible replacement resources, QR/PIN, photo, GPS/time, both confirmations, and sensitive authority; replace the assignment while preserving physical balance and append the transfer authorization.
16. **Recovery route:** implemented in Block E—retain prior route/execution/price; validate stable onboard cargo in a new route; require provider acceptance and separate additional funding when applicable; create a linked price, route, child execution, first attempt, and recovery record.
17. **Storage or return handoff:** implemented in Block E—verify current evidence-pending recovery stop and exact custody; append storage/return movements and allocation outcomes; record complete facility/sender evidence; hold for instruction or terminate as returned only after zero-balance reconciliation.
18. **Dispute and route control:** implemented in Block E—open evidence/financial case independently; protect only the disputed available amount; continue movement unless a retained unsafe/unlawful/formal-hold basis exists; resolve money/evidence without moving the route; resume later through an exact linked hold and new stop attempt.
19. **Terminal repost:** implemented in Block E—validate an immutable terminal source and deliberately create a linked draft with copied stops, legs, cargo, and allocations; require fresh policy/pricing/publication/funding decisions before reuse.
20. **Sensitive override:** call `assert_sensitive_authority`; execute one named allowed transition; append before/after audit and owner notification.

Every externally retryable command should first claim `command_idempotency` and use the same key on its state/history/provider records.

## 8. Deliberately deferred

The foundation does not yet decide or implement:

- production RLS policies and JWT claim mapping;
- final payment provider naming, webhook payloads, or use of the public term *escrow*;
- finalized tax calculation and accounting ledger integration;
- geospatial/PostGIS indexing and routing-provider selection;
- object-storage bucket/policy names and retention periods;
- automated consolidation across independent shipments;
- product exposure of many-pickup-to-many-delivery routes;
- operational/legal values still required to be versioned configuration rather than constants.

## 9. Verification status

All six exact migrations have been executed successfully in order in a PostgreSQL-compatible PGlite runtime. The resulting model contains 110 Haulvia base tables, 5 views, and 70 callable Block A+B+C+D+E wrappers for 70 approved rows, with zero function grants to `PUBLIC` and zero helper grants to `service_role`. All six rollback-only suites remain green. The 23-assertion `haulvia_block_e_acceptance_v1.sql` suite exercises every Block E row plus exact replay, expiry-wrapper reuse, the post-LOAD cancellation boundary, failed-attempt preservation, explicit first-pickup/continuation decisions, verified transfer, immutable recovery lineage, complete storage custody, zero-balance return, independent dispute hold/resolution/resumption, terminal-source copying, append-only records, cumulative schema shape, and wrapper-only authority.

This gives the foundation and Block A+B+C+D+E command layers executable local checks, but it does not replace the final smoke test and true multi-session concurrency tests against the selected hosted PostgreSQL/Supabase project. Provider sandbox webhooks and production RLS/API adapter tests also remain required.

## 10. Recommended next migration sequence

1. Follow `Haulvia_Database_Setup_and_Run_Guide_v1.md` to apply all six migrations to a dedicated disposable hosted Supabase project and run all rollback-only suites. Then add true concurrent assignment, route-start, cancellation, custody, retry/continuation, transfer, recovery, storage/return, dispute/hold/resumption, terminal-copy, receiver-window, and provider-callback sessions.
2. Seed the initial production policy, pricing-rule, compliance-requirement, role, and permission versions through an approved seed migration.
3. Add payment-provider signature verification and adapter/webhook tests around the trusted Block A, Block D, and Block E functions.
4. Add Supabase Auth mapping and RLS policies after actor rules are approved.
5. Add observability projections and operational dashboards from append-only events.

## 11. Acceptance checklist

- [x] Route versions, ordered stops, legs, cargo items, and allocations are first-class.
- [x] Launch multi-stop shapes are supported and many-to-many is structurally ready.
- [x] Automated cross-customer consolidation is not modeled.
- [x] Pricing source/mode/rate-card version/review/snapshot are preserved.
- [x] Funds must be secured before one active whole-route assignment.
- [x] Attempts, evidence, corrections, movements, and state/audit histories are preserved.
- [x] Stop-level receiver confirmation remains independent from macro shipment state.
- [x] Customer payment, payout, dispute, holds, claims, and route execution do not overwrite one another.
- [x] Terminal shipments cannot reopen.
- [x] Exact compliance lifecycle and export contract are represented.
- [x] Exact migration executes in a PostgreSQL-compatible engine and the 28-check foundation suite passes.
- [x] All 19 approved Block A rows have named transactional handlers and the 37-check Block A suite passes.
- [x] All 12 approved Block B rows have named transactional handlers and the 26-check Block B suite passes.
- [x] All 14 approved Block C rows have named transactional handlers and the 23-check Block C suite passes.
- [x] All 9 approved Block D rows have named transactional handlers and the 21-check Block D suite passes.
- [x] All 16 approved Block E rows are covered; E04 reuses expiry and the 15 new wrappers plus 23-assertion suite pass.
- [x] Current stop/leg/next action, route-execution version, first-custody boundary, and pre-custody financial decisions are modeled.
- [x] Verified external payment references, cancellation snapshots, and durable workflow jobs are modeled.
- [x] ETA calculations/predictions, failed-stop facts/continuations, route amendments, cargo outcomes, and route resolution are modeled append-only.
- [x] Delivery review windows/results, problem reports, payout eligibility, completion proof, provider payout outcomes, and financial adjustments are modeled independently and append-only where historical.
- [x] Retry, failed-first-pickup resolution, verified transfer, recovery, storage, return, dispute control/resolution, resumption, and terminal-copy facts are append-only.
- [x] Cumulative executable shape is 110 tables, 5 views, 70 wrappers, zero `PUBLIC` function grants, and zero `service_role` helper grants.
- [ ] Execute all six migrations and true concurrency/provider-callback checks against the selected hosted PostgreSQL project.
- [ ] Add RLS and production adapter/API tests before exposing any client write surface.
