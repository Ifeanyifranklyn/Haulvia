# Haulvia P2A Authority and Seed Contract v1

**Purpose:** Define the deterministic role, permission, configuration and catalog seeds for the first local-only Phase 2 migration.

**Baseline:** Foundation through Block E, commit `d901412`.

## 1. Non-negotiable authority rules

1. Permissions are evaluated through an active `organization_membership`; a role never grants cross-organization authority.
2. Individual customers use shipment/profile ownership rules. They are not assigned synthetic business roles.
3. Independent-driver eligibility and assigned-route execution use provider/driver/vehicle/compliance facts. They do not receive unrestricted pricing or synthetic worker roles.
4. Courier roles apply only inside the courier provider organization. Driver execution additionally requires the active assigned driver profile.
5. Haulvia staff roles apply only inside the Haulvia operating organization.
6. Backend worker-authority codes are not inserted into `roles`, `membership_roles` or JWTs.
7. JWT or client-supplied organization, role and permission claims are never authoritative; the database verifies active membership and role mappings.
8. Direct client writes to command-owned operational facts remain prohibited.
9. A sensitive permission never bypasses fresh reauthentication, written reason, effective-date or immutable-audit requirements.
10. `PLATFORM_ADMIN` is not a bypass role. Self-approval remains prohibited for pricing publication, compliance-policy publication and financial adjustment.

## 2. Existing permissions retained unchanged

| Permission | Sensitive | Existing purpose |
| --- | --- | --- |
| `COMPLIANCE_REVIEW` | Yes | Review and decide provider compliance items. |
| `PRICING_MANAGE` | Yes | Publish Haulvia pricing rules or partner rate cards. |
| `SHIPMENT_STATE_OVERRIDE` | Yes | Execute an approved administrative shipment transition. |
| `CUSTODY_TRANSFER_AUTHORIZE` | Yes | Authorize a post-pickup custody transfer. |
| `DISPUTE_RESOLVE` | Yes | Resolve a dispute and allocate protected funds. |
| `FINANCIAL_ADJUST` | Yes | Issue a refund, charge, credit or driver compensation. |
| `ROUTE_OPERATIONS_MANAGE` | No | Correct stop execution and manage route exceptions. |
| `STOP_EVIDENCE_REVIEW` | No | Review and verify stop evidence and custody movements. |
| `PAYOUT_MANAGE` | Yes | Submit, retry and administratively manage driver payouts. |

P2A must use `ON CONFLICT ... DO UPDATE` only to correct the description or `is_sensitive` value to this approved contract. It must never replace permission identifiers.

## 3. New permission catalog

### 3.1 Customer-organization permissions

| Permission | Sensitive | Scope |
| --- | --- | --- |
| `ORG_MEMBER_VIEW` | No | View active and invited members in the current organization. |
| `ORG_MEMBER_MANAGE` | Yes | Invite, activate, suspend, end or role-assign organization members. |
| `SHIPMENT_VIEW` | No | View shipments owned by the current customer organization. |
| `SHIPMENT_CREATE` | No | Create a shipment for the current customer organization. |
| `SHIPMENT_MANAGE` | No | Edit or progress an authorized nonterminal customer shipment. |
| `SHIPMENT_CANCEL` | No | Request an allowed cancellation for an owned shipment. |
| `BILLING_VIEW` | No | View customer payment, invoice, refund and adjustment projections. |
| `BILLING_MANAGE` | Yes | Add/remove payment references and approve customer-side payment actions. |
| `SHIPMENT_DOCUMENT_VIEW` | No | View authorized shipment documents for the current customer organization. |
| `SHIPMENT_DOCUMENT_UPLOAD` | No | Upload a document to an authorized shipment/document request. |
| `ORG_AUDIT_VIEW` | No | View the organization-safe activity projection, never raw internal audit metadata. |

### 3.2 Courier-provider permissions

| Permission | Sensitive | Scope |
| --- | --- | --- |
| `PROVIDER_PROFILE_VIEW` | No | View the current provider’s approved profile and capabilities. |
| `PROVIDER_PROFILE_MANAGE` | Yes | Propose allowed provider-profile changes; compliance-impacting changes re-enter review. |
| `PROVIDER_MEMBER_VIEW` | No | View provider members and active driver relationships. |
| `PROVIDER_MEMBER_MANAGE` | Yes | Invite, suspend or end provider-organization memberships. |
| `DRIVER_ROSTER_VIEW` | No | View drivers attached to the current provider. |
| `DRIVER_ROSTER_MANAGE` | Yes | Add/remove drivers subject to onboarding and compliance gates. |
| `VEHICLE_VIEW` | No | View the current provider’s vehicles. |
| `VEHICLE_MANAGE` | Yes | Add/update/remove vehicles subject to compliance gates. |
| `RATE_CARD_VIEW` | No | View current provider rate-card drafts and effective versions. |
| `RATE_CARD_DRAFT` | No | Create or edit a provider rate-card draft. |
| `RATE_CARD_SUBMIT` | Yes | Submit a provider rate-card version for Haulvia review. |
| `OFFER_VIEW` | No | View provider-eligible marketplace opportunities and own offer threads. |
| `OFFER_MANAGE` | No | Submit, revise, counter or withdraw an offer on behalf of the provider. |
| `PROVIDER_ASSIGNMENT_VIEW` | No | View the provider’s reservations and assignments. |
| `PROVIDER_ASSIGNMENT_MANAGE` | Yes | Select eligible provider drivers/vehicles and request controlled reassignment. |
| `PROVIDER_DOCUMENT_VIEW` | No | View non-sensitive provider documents and explicitly authorized compliance-document projections. |
| `PROVIDER_DOCUMENT_UPLOAD` | No | Upload documents through an active provider/compliance document request. |

`RATE_CARD_SUBMIT` does not approve or publish a rate card. Only Haulvia `PRICING_MANAGE` may approve/publish an effective version, with dual control.

### 3.3 Haulvia staff permissions

| Permission | Sensitive | Scope |
| --- | --- | --- |
| `PLATFORM_CONFIGURATION_VIEW` | No | View effective platform configuration and version metadata. |
| `PLATFORM_CONFIGURATION_MANAGE` | Yes | Draft/submit administrator-controlled configuration changes. |
| `INTERNAL_SHIPMENT_VIEW` | No | View operations-safe shipment and route projections across authorized tenant boundaries. |
| `INTERNAL_SHIPMENT_DOCUMENT_VIEW` | No | View non-sensitive internal shipment-document projections; protected objects still require specialized authority. |
| `INTERNAL_PROVIDER_VIEW` | No | View internal provider, driver, vehicle and assignment projections. |
| `INTERNAL_PROVIDER_RATE_CARD_VIEW` | No | View courier rate-card drafts, submissions and effective versions for review. |
| `INTERNAL_PAYMENT_VIEW` | No | View minimized internal payment, payout, refund and adjustment projections. |
| `SENSITIVE_DOCUMENT_VIEW` | Yes | View compliance, insurance or protected evidence documents with access auditing. |
| `SUPPORT_CASE_MANAGE` | No | Manage support cases without protected-document access. |
| `AUDIT_VIEW` | No | View approved audit projections for authorized organizations/entities. |
| `AUDIT_EXPORT` | Yes | Export an approved, minimized audit dataset with reason and access event. |
| `SECURITY_ACCESS_REVIEW` | Yes | Review memberships, roles, permission grants and sensitive access events. |
| `POLICY_PUBLISH` | Yes | Approve/publish non-pricing platform policy versions under dual control. |

The existing sensitive permissions remain the specialized authority for compliance, pricing, overrides, custody transfer, disputes, adjustments and payouts.

## 4. Human role seeds

### 4.1 Customer organization

| Role | Granted permissions |
| --- | --- |
| `BUSINESS_OWNER` | All customer-organization permissions. Ownership does not permit bypassing sensitive reauthentication or self-approval rules. |
| `BUSINESS_ADMIN` | `ORG_MEMBER_VIEW`, `ORG_MEMBER_MANAGE`, all shipment permissions, `BILLING_VIEW`, both shipment-document permissions and `ORG_AUDIT_VIEW`; excludes `BILLING_MANAGE`. |
| `BUSINESS_SHIPMENT_MANAGER` | `SHIPMENT_VIEW`, `SHIPMENT_CREATE`, `SHIPMENT_MANAGE`, `SHIPMENT_CANCEL`, both shipment-document permissions. |
| `BUSINESS_BILLING` | `SHIPMENT_VIEW`, `BILLING_VIEW`, `BILLING_MANAGE`, `SHIPMENT_DOCUMENT_VIEW`. |
| `BUSINESS_VIEWER` | `SHIPMENT_VIEW`, `BILLING_VIEW`, `SHIPMENT_DOCUMENT_VIEW`, `ORG_AUDIT_VIEW`. |

One person may hold more than one role. Separate billing and shipment permissions remain available even for a small business.

### 4.2 Courier provider organization

| Role | Granted permissions |
| --- | --- |
| `COURIER_OWNER` | All courier-provider permissions. Does not receive Haulvia approval/publication permissions. |
| `COURIER_ADMIN` | Provider/member/driver/vehicle management, rate view/draft/submit, offers, assignments and provider documents. |
| `COURIER_DISPATCHER` | Provider/driver/vehicle view, `RATE_CARD_VIEW`, `OFFER_VIEW`, `OFFER_MANAGE`, assignment view/manage and non-sensitive document view. Cannot draft, submit, approve or publish rate cards. |
| `COURIER_DRIVER` | Provider/driver/vehicle view limited by later RLS, `PROVIDER_ASSIGNMENT_VIEW`, `PROVIDER_DOCUMENT_UPLOAD`. Route actions still require active assignment to that driver. |

Controlled courier reassignment remains command-gated: the replacement driver must be Haulvia-verified; the customer is notified; a post-pickup transfer requires both drivers’ confirmations, GPS, timestamps, photos and PIN/QR; the courier remains responsible.

### 4.3 Haulvia operating organization

| Role | Granted permissions |
| --- | --- |
| `PLATFORM_ADMIN` | All Haulvia staff and existing administrative permissions, plus organization/member visibility. Still subject to dual control, fresh authentication and reason. |
| `OPERATIONS_MANAGER` | `INTERNAL_SHIPMENT_VIEW`, `INTERNAL_SHIPMENT_DOCUMENT_VIEW`, `INTERNAL_PROVIDER_VIEW`, `ROUTE_OPERATIONS_MANAGE`, `STOP_EVIDENCE_REVIEW`, `SHIPMENT_STATE_OVERRIDE`, `CUSTODY_TRANSFER_AUTHORIZE`, `AUDIT_VIEW`. |
| `COMPLIANCE_REVIEWER` | `COMPLIANCE_REVIEW`, `SENSITIVE_DOCUMENT_VIEW`, `INTERNAL_PROVIDER_VIEW`, `AUDIT_VIEW`. |
| `PRICING_MANAGER` | `PRICING_MANAGE`, `PLATFORM_CONFIGURATION_VIEW`, `INTERNAL_PROVIDER_VIEW`, `INTERNAL_PROVIDER_RATE_CARD_VIEW`, `AUDIT_VIEW`. |
| `FINANCE_MANAGER` | `INTERNAL_SHIPMENT_VIEW`, `INTERNAL_PAYMENT_VIEW`, `PAYOUT_MANAGE`, `FINANCIAL_ADJUST`, `AUDIT_VIEW`, `AUDIT_EXPORT`. |
| `DISPUTE_REVIEWER` | `DISPUTE_RESOLVE`, `STOP_EVIDENCE_REVIEW`, `INTERNAL_SHIPMENT_VIEW`, `INTERNAL_SHIPMENT_DOCUMENT_VIEW`, `SENSITIVE_DOCUMENT_VIEW`, `AUDIT_VIEW`. |
| `SUPPORT_AGENT` | `SUPPORT_CASE_MANAGE`, `INTERNAL_SHIPMENT_VIEW`, `INTERNAL_SHIPMENT_DOCUMENT_VIEW`, `INTERNAL_PROVIDER_VIEW`. No `SENSITIVE_DOCUMENT_VIEW`. |
| `AUDITOR_READ_ONLY` | `AUDIT_VIEW`, `PLATFORM_CONFIGURATION_VIEW`, `INTERNAL_SHIPMENT_VIEW`, `INTERNAL_PROVIDER_VIEW`, `INTERNAL_PROVIDER_RATE_CARD_VIEW`, `INTERNAL_PAYMENT_VIEW`. No raw document access and no mutation permission. |

## 5. Worker authorities explicitly excluded from human roles

The following codes remain trusted backend execution contexts and are never inserted as ordinary membership roles:

- `ROUTE_OPERATIONS_WORKER`
- `TERMINAL_REPOST_WORKER`
- `CUSTODY_TRANSFER_WORKER`
- `RECOVERY_WORKER`
- `STORAGE_WORKER`
- `COMPLETION_WORKER`
- `PAYOUT_WORKER`

Worker authority is accepted only by the specific trusted command that names it. It is not a general permission claim.

## 6. Role-to-organization-kind boundary

P2A must add a normalized role-scope relation, such as `role_organization_kinds`, and enforce it when `membership_roles` are inserted:

| Role family | Allowed `organization_kind` |
| --- | --- |
| `BUSINESS_*` | `CUSTOMER` |
| `COURIER_*` | `COURIER_PARTNER` |
| Haulvia staff roles | `HAULVIA` |

No seeded human role is assignable to `INDEPENDENT_PROVIDER`. Independent providers and their driver profiles use explicit provider ownership, eligibility, compliance and assignment rules. A database trigger or trusted grant command must reject a role whose allowed kind does not match the membership organization.

## 7. Deterministic seed rules

P2A SQL must:

1. Use stable uppercase keys and natural-key upserts.
2. Be idempotent on repeat execution.
3. Fail if a pre-existing role or permission conflicts with the approved sensitivity or family boundary.
4. Insert missing role-permission mappings and remove no mappings silently.
5. Seed no real profile, Auth user, organization, membership, provider, driver, vehicle, payment method or document.
6. Seed no monetary amount, tax rate, negotiation threshold, expiry duration or legal/compliance rule as effective production data.
7. Create versioned catalog shells as `DRAFT` or inactive definitions only.
8. Record a seed manifest/version and SHA-256 evidence so later changes are additive and reviewable.
9. Run inside one transaction and expose a rollback-only acceptance suite.
10. Grant no new function execution to `PUBLIC`, `anon` or `authenticated` during P2A.

## 8. Configuration catalog shells

The seed contract will create stable, non-effective keys for:

| Catalog | Keys/scope | Initial state |
| --- | --- | --- |
| Platform policies | marketplace, negotiation, cancellation, evidence/POD, custody, receiver review, payout/dispute, retention | Definition only; no effective config. |
| Haulvia pricing | Flex guardrail and fixed/Expedited rule-set shells in CAD | Draft shells; no amounts. |
| Tax | Canada federal and province/territory jurisdiction registry | Jurisdiction identity only; no rates or effective tax advice. |
| Compliance | Application/provider/driver/vehicle requirement categories | Catalog shells; exact required items remain unapproved. |
| Feature/config | Security/session, offer expiry, receiver window, upload limits, notification and operational thresholds | Keys and expected data types only; no production values. |

Tax and pricing remain administrator/accounting-controlled, versioned and auditable. Application code consumes effective versions; it never embeds rates or guardrail amounts.

## 9. Dual-control invariants required in P2A

P2A must add or prepare constraints/commands ensuring:

1. Creator and approver are different profiles for pricing-rule versions, partner-rate-card versions, compliance-requirement versions, platform-policy versions and financial adjustments where an approval step applies.
2. Approval requires the appropriate sensitive permission, active organization membership, fresh reauthentication and a written reason.
3. Approval captures effective date, before/after values and immutable audit metadata.
4. A material change after approval creates a new version and cannot mutate the effective version.
5. Owners/affected parties receive an outbox notification where the approved policy requires notice.

## 10. P2A acceptance requirements

The rollback-only suite must prove:

1. Every approved role and permission exists once.
2. Every role has exactly the approved permission set.
3. No worker code exists as a human role.
4. Role assignment across an incompatible organization kind fails.
5. No customer or courier role receives a Haulvia administrative permission.
6. `SUPPORT_AGENT` lacks `SENSITIVE_DOCUMENT_VIEW`.
7. `COURIER_DISPATCHER` lacks rate-card draft/submit/publish authority.
8. Existing sensitive permissions remain sensitive.
9. Repeat seed execution is idempotent.
10. Conflicting pre-existing sensitivity or role-family data fails closed.
11. Seed execution creates no real tenant or person data.
12. No self-approval path succeeds.
13. No `PUBLIC`, `anon` or `authenticated` function grant is introduced.

## 11. Next implementation artifact

The next file is the additive P2A migration. It will implement the permission and role catalog, role mappings, seed manifest and non-effective catalog shells. Effective pricing amounts, tax rates and exact compliance requirements will remain deliberately absent until separately approved.
