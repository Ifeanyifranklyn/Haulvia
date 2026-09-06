# Haulvia P2B Auth/Profile Mapping Contract v1

**Phase:** 2 - Block P2B
**Purpose:** Define the authoritative mapping between external authentication identities, Haulvia profiles, organization memberships and request-time authorization context.

**Depends on:**

- Foundation v1
- Blocks A-E v1
- P2A Authority & Configuration Seeds v1
- P2A commit `7946a4c`

**Scope:** Identity mapping, profile bootstrap/claim, invitation acceptance, membership activation, authentication trust boundaries and preparation for P2C row-level security.

---

## 1. Identity invariants

### 1.1 One Haulvia profile per authenticated person

`haulvia.profiles` remains the canonical application-level person/profile record.

The existing:

```text
profiles.auth_user_id
```

is the bridge between the external authentication provider and Haulvia.

P2B must preserve these rules:

1. One external Auth user may map to at most one Haulvia profile.
2. One Haulvia profile may map to at most one external Auth user at a time.
3. `profiles.auth_user_id` remains nullable so that an invited, manually created or pre-onboarded profile may exist before the person creates or claims an Auth account.
4. Duplicate Auth-to-profile mappings must fail closed.
5. A client may never choose an arbitrary `profile_id` and thereby become that profile.
6. A client may never replace an existing profile's Auth identity through an ordinary application request.
7. Auth linking, claiming and administrative recovery must occur only through explicit trusted commands.
8. Operational records continue to reference the Haulvia `profile_id`, not the external Auth UUID.

The Auth UUID identifies the login principal.

The Haulvia profile UUID identifies the person inside the operational system.

These identifiers have different responsibilities and must not be treated as interchangeable.

---

## 2. Profile and identity-mapping states

P2B recognizes the following logical identity states.

These are contract states and do not necessarily require a new persisted `profile_status` column.

### 2.1 UNCLAIMED

A Haulvia profile exists but:

```text
profiles.auth_user_id IS NULL
```

Typical examples:

- a business administrator invited a future member;
- Haulvia staff pre-created an internal staff profile;
- a courier organization invited a dispatcher or driver;
- an onboarding workflow created the operational profile before account registration.

An unclaimed profile:

- may retain invitations or pending memberships;
- may retain operational onboarding records;
- is not authenticated;
- receives no authenticated application authority.

### 2.2 CLAIMED

A profile becomes claimed when exactly one verified Auth principal is linked to it:

```text
profiles.auth_user_id = authenticated Auth user UUID
```

Claiming does not itself activate organization authority.

The user must additionally have the required:

- organization membership;
- membership status;
- role mapping where applicable;
- provider/driver relationship where applicable;
- compliance/assignment eligibility where applicable.

### 2.3 AUTHENTICATED BUT UNMEMBERED

A user may possess a valid Auth account and claimed Haulvia profile but have no active organization membership.

This state is valid.

Examples include:

- an individual customer;
- a user whose organization invitation has not yet been accepted;
- a former organization member;
- an account awaiting provider onboarding.

Authentication alone must never manufacture organization authority.

### 2.4 ACTIVE ORGANIZATION MEMBER

Organization-scoped authority exists only when all relevant facts resolve successfully:

```text
valid Auth principal
        ->
claimed Haulvia profile
        ->
active organization membership
        ->
approved role mapping / provider relationship
        ->
permission and domain-specific command guards
```

A role is never evaluated independently from its membership.

### 2.5 SUSPENDED OR ENDED MEMBERSHIP

A profile may remain fully valid while one organization membership becomes inactive.

Suspending or ending a membership:

- does not delete the profile;
- does not delete prior role assignments or audit evidence where retention is required;
- does not delete shipments, offers, payments, evidence, compliance history or other operational facts;
- immediately removes authority derived from that inactive membership.

Historical actions continue to identify the same `profile_id`.

### 2.6 DISABLED OR DELETED AUTH PRINCIPAL

Disabling or deleting an external Auth principal must not delete Haulvia operational history.

At minimum:

- the Haulvia profile remains;
- organization memberships remain for historical/audit purposes;
- operational records remain;
- audit events remain;
- historical actor references remain resolvable;
- no new authenticated authority may be exercised by the disabled/deleted Auth principal.

P2B must not use cascading Auth deletion to erase operational identity history.

If the Auth provider requires physical removal of its own user record, Haulvia must retain enough internal evidence to preserve the historical identity relationship.

---

## 3. Auth linking and account-claim rules

### 3.1 New self-registered user

When a person creates an Auth account without an existing invitation or pre-created profile, a trusted bootstrap command may create one Haulvia profile and link the Auth user UUID to `profiles.auth_user_id`.

The bootstrap operation must be idempotent.

Calling it repeatedly for the same Auth principal must resolve to the same profile and must never create duplicate profiles.

### 3.2 Existing unclaimed profile

If an unclaimed profile already exists because of an invitation or onboarding workflow, account claim must link the verified Auth user to that existing profile rather than create a second profile.

The claim operation must verify an approved claim mechanism such as:

- secure invitation token;
- verified email invitation flow;
- administrative recovery flow;
- another explicitly approved identity-proofing mechanism.

Matching only on a client-supplied email address is insufficient authority to claim a profile.

### 3.3 Already claimed profile

If `profiles.auth_user_id IS NOT NULL`, a second Auth principal may not claim that profile through the normal claim flow.

The operation must fail closed.

Account recovery or identity replacement requires a separate privileged recovery procedure with:

- explicit authority;
- fresh reauthentication;
- written reason;
- immutable audit evidence.

### 3.4 Auth principal already linked elsewhere

If an Auth UUID is already linked to another profile, any attempt to link it to a different profile must fail.

The system must never silently:

- merge the profiles;
- move the Auth identity;
- overwrite the prior link;
- select whichever profile was most recently requested.

### 3.5 Individual customer identity

An individual customer does not require a synthetic customer-organization role merely to act on their own shipment.

Individual authority is established by authenticated profile + shipment/profile ownership + command/state rules.

### 3.6 Business customer identity

A business user acts through an active `CUSTOMER` organization membership.

The Auth principal does not receive authority merely because the JWT names an organization.

The database must verify profile -> active organization membership -> CUSTOMER organization -> permitted BUSINESS\_\* role -> permission.

### 3.7 Courier organization identity

A courier owner, administrator, dispatcher or driver acts through an active `COURIER_PARTNER` organization membership.

For driver operational commands, membership authority alone is insufficient.

The system must additionally validate the required driver profile, provider relationship, active assignment, vehicle relationship where applicable, compliance state and route/stop command conditions.

### 3.8 Independent-driver identity

Independent providers/drivers do not receive synthetic membership roles solely to imitate courier organizations.

Their authority derives from explicit provider ownership, driver relationship, compliance status, assignment/reservation facts, vehicle eligibility and command-specific guards.

This preserves the P2A rule that `INDEPENDENT_PROVIDER` does not receive seeded human organization roles.

---

## 4. JWT and authentication trust boundary

### 4.1 JWT purpose

A valid authentication token proves only that the authentication provider issued a valid identity assertion.

The primary identity claim used by Haulvia is `sub`, representing the external Auth user UUID.

The database resolves JWT `sub` -> `profiles.auth_user_id` -> `profile.id`.

The resolved Haulvia `profile.id` becomes the internal actor identity.

### 4.2 Claims that are not authorization authority

The following client/JWT claims must never be treated as authoritative without database verification:

- `profile_id`
- `organization_id`
- `organization_kind`
- `membership_id`
- role names
- role keys
- permissions
- provider IDs
- driver IDs
- vehicle IDs
- shipment IDs
- assignment IDs
- staff/admin flags
- pricing authority
- compliance authority

Even if such claims are later included in a JWT for UI convenience or caching, they are hints only.

The database remains authoritative.

### 4.3 Request-time organization resolution

For organization-scoped actions, the application may supply the organization it intends to operate within.

That requested organization is context, not authority.

The database must verify authenticated profile -> requested organization -> active membership -> compatible organization kind -> role/permission -> domain-specific guard.

A valid membership in Organization A never authorizes access to Organization B.

### 4.4 Cross-organization claim protection

A user authenticated as Profile P must fail if the request attempts to act using Organization B without an active membership in Organization B.

The failure must occur even if the client supplies another valid organization UUID, another membership UUID, another person's role key or an administrator-looking JWT claim.

Database membership resolution controls the outcome.

### 4.5 Inactive membership protection

An authenticated user whose organization membership is invited but not active, suspended, ended, revoked or otherwise inactive must receive no authority from that membership.

Possession of an old JWT, cached client state, a previously selected organization or a previously issued role name must not restore authority.

### 4.6 Sensitive actions

P2B authentication mapping does not weaken the P2A sensitive-authority model.

Where a command requires a sensitive permission, the request must still satisfy authenticated profile + active organization membership + required sensitive permission + fresh reauthentication + written reason + command-specific invariants.

### 4.7 Service and worker identities

Backend worker authorities are not human JWT roles.

The following remain trusted execution contexts only:

- `ROUTE_OPERATIONS_WORKER`
- `TERMINAL_REPOST_WORKER`
- `CUSTODY_TRANSFER_WORKER`
- `RECOVERY_WORKER`
- `STORAGE_WORKER`
- `COMPLETION_WORKER`
- `PAYOUT_WORKER`

A user JWT may never claim one of these authorities and thereby acquire worker privileges.

---

## 5. Trusted identity and membership command contracts

P2B identity changes must occur through named trusted commands.

Direct client updates to `profiles.auth_user_id`, `profiles.status`, `organization_memberships.status`, `membership_roles`, and invitation/claim security records are prohibited.

Every externally retryable P2B command must use the existing Haulvia idempotency and audit conventions.

The authenticated Auth UUID used by a command must come from verified authentication context.

### 5.1 `bootstrapProfileFromAuth`

Purpose: resolve or create the Haulvia profile belonging to a newly authenticated Auth principal.

Rules:

1. Resolve `profiles.auth_user_id` using the verified Auth UUID.
2. If exactly one profile already exists, return that same profile.
3. If no profile exists, create exactly one profile with that Auth UUID.
4. Do not create organization, membership, role, provider, driver, vehicle or shipment records.
5. Do not accept a client-selected `profile_id`.
6. The same Auth UUID may never produce two profiles.
7. Same idempotency key + same request returns original result.
8. Same idempotency key + different request fails closed.
9. Disabled/archived access must not be restored by bootstrap.
10. Return the resolved Haulvia `profile_id`.

### 5.2 `createOrganizationInvitation`

Purpose: invite a person to an existing organization without granting active authority before acceptance.

Authority:

- CUSTOMER: `ORG_MEMBER_MANAGE`
- COURIER_PARTNER: `PROVIDER_MEMBER_MANAGE`
- HAULVIA: `SECURITY_ACCESS_REVIEW`

Rules:

1. Inviter must have active membership in target organization.
2. Inviter must possess required management permission.
3. Every requested role must be valid for target organization kind.
4. P2A role-family enforcement remains authoritative.
5. Invitation creation grants no active authority.
6. Raw invitation token must never be persisted.
7. Store only a cryptographic digest of the invitation secret.
8. Invitation secrets are single-use.
9. Invitations expire.
10. Invitations may be revoked before acceptance.
11. Raw secrets must not appear in audit metadata, logs or errors.
12. Same idempotency key must not create duplicate invitations.

### 5.3 Invitation token requirements

The implementation must generate a cryptographically random invitation secret and store only SHA-256(invitation secret) or an equivalent approved one-way digest.

Invitation metadata must retain enough information to determine target organization, intended roles, inviter, intended destination identity, creation time, expiry, revocation, consumption, consuming profile and idempotency/audit linkage.

Unknown, expired, revoked, consumed, wrong-organization or wrong-identity invitations must fail.

### 5.4 `acceptOrganizationInvitation`

Purpose: atomically convert a valid invitation into active organization membership for the authenticated person.

Rules:

1. Resolve authenticated Auth UUID from trusted context.
2. Resolve/bootstrap the Haulvia profile.
3. Lock the invitation.
4. Verify unexpired, unrevoked and unconsumed.
5. Verify identity binding using provider-verified Auth data.
6. Revalidate intended roles for organization kind.
7. Create or resolve organization membership.
8. Membership becomes `ACTIVE` only after successful acceptance.
9. Create approved `membership_roles` atomically.
10. Mark invitation consumed atomically.
11. Write immutable audit evidence atomically.
12. No partial activation is allowed.

### 5.5 Existing membership handling during invitation acceptance

- No membership: create ACTIVE membership.
- INVITED membership: activate that membership.
- ACTIVE membership: may return existing membership only if role set is not silently widened.
- SUSPENDED or ENDED: ordinary invitation acceptance fails.

Reactivation requires explicit authorized membership management.

### 5.6 `claimExistingProfile`

Purpose: link an authenticated Auth principal to a legitimate pre-existing unclaimed Haulvia profile.

Rules:

1. Auth UUID comes from verified authentication context.
2. Target profile must be unclaimed.
3. Auth UUID must not already belong to another profile.
4. Target profile must be eligible for ordinary claim.
5. Claim proof must be valid, unexpired and unused.
6. Lock profile and claim record.
7. Set `profiles.auth_user_id` exactly once.
8. Consume claim proof atomically.
9. Write immutable before/after audit evidence.
10. Claiming does not manufacture active organization membership.

### 5.7 Duplicate-link protection

The database must fail closed if one Auth UUID is linked to two profiles or one claimed profile is claimed by a second Auth UUID.

No silent merge, identity move, membership move, overwrite or client-selected profile impersonation is allowed.

### 5.8 `suspendOrganizationMembership`

Purpose: immediately remove authority derived from one organization membership while retaining history.

Rules:

1. Actor must be authorized inside same organization.
2. Lock membership.
3. `ACTIVE -> SUSPENDED` is permitted.
4. Do not delete profile.
5. Retain role mappings and audit evidence.
6. Suspended membership contributes no authority.
7. Do not delete operational history.
8. Write before/after audit evidence.

### 5.9 `endOrganizationMembership`

Purpose: permanently end the current membership relationship without deleting historical identity.

Rules:

1. Lock membership.
2. Set membership state to `ENDED`.
3. Set retained end time.
4. Ended membership contributes no authority.
5. Prior roles remain historical evidence only.
6. Do not delete profile.
7. Do not delete operational history.
8. Rejoining requires explicit approved process.

### 5.10 `replaceProfileAuthIdentity`

Purpose: recover an existing Haulvia profile when its external Auth identity must legitimately be replaced.

Required authority: `SECURITY_ACCESS_REVIEW` in the Haulvia operating organization, plus fresh reauthentication, written reason and immutable audit evidence.

Rules:

1. Lock target profile.
2. Retain previous Auth UUID in immutable audit evidence.
3. Verify replacement Auth UUID is not mapped elsewhere.
4. Verify approved recovery/identity proof.
5. Never merge profiles automatically.
6. Never move memberships or operational history.
7. Update only the external identity link.
8. Record before/after mapping.
9. Notify affected account where available.
10. Command is idempotent.

### 5.11 Disabled or deleted Auth principal handling

Disabling or deleting an external Auth principal must not cascade into Haulvia operational deletion.

The Haulvia profile, historical profile ID, memberships, operational records and audit events remain.

Reactivation or replacement requires an explicit approved process.

### 5.12 Trusted Auth synchronization

Auth-provider events such as account disabled, account deleted, identity reinstated or verified identity change must enter Haulvia only through an authenticated trusted backend path.

Such events must be authenticated, replay protected, idempotent, audited and correlated to the affected Haulvia profile where one exists.

Live provider webhook details remain outside the P2B local-only contract and will be validated during hosted integration.

---

## 6. Audit, idempotency and trusted execution requirements

### 6.1 Reuse existing Haulvia command infrastructure

P2B must reuse `command_idempotency`, `audit_events`, organization membership authority, the P2A role/permission catalog and the fresh-reauthentication model.

### 6.2 Idempotency requirements

Every externally retryable P2B command must accept an idempotency key, use a canonical request hash, replay the original result for same key/same request, fail closed for same key/different request, and avoid duplicate identity or membership facts.

### 6.3 Audit requirements

Every material identity or membership mutation must produce immutable audit evidence.

Secrets, access tokens, refresh tokens, passwords, MFA secrets and provider credentials must never appear in plaintext audit metadata.

### 6.4 Before/after identity evidence

Identity-link and recovery commands must preserve enough evidence to prove the mapping transition while operational history continues to reference the same Haulvia `profile_id`.

### 6.5 Transaction boundaries

Invitation acceptance, profile claim and Auth identity replacement must each be atomic.

### 6.6 Concurrency protection

P2B must prevent duplicate profile bootstrap, double invitation consumption, competing profile claims, duplicate memberships and unsafe identity replacement.

### 6.7 Trusted command execution

Authenticated principal identity must come from trusted authentication context, not arbitrary request JSON.

### 6.8 JWT claim minimization

The minimum authoritative JWT dependency is:

```text
sub = external Auth user UUID
```

Database state remains authoritative for authorization.

### 6.9 Authentication-context helper

P2B should provide or prepare one authoritative helper resolving trusted Auth UUID -> Haulvia profile ID.

### 6.10 Organization-context helper

P2B should provide or prepare a reusable resolver for profile ID + organization ID -> ACTIVE membership.

### 6.11 No operational-history deletion

Authentication or membership changes must not delete operational facts.

### 6.12 Notifications and outbox

P2B should emit notification/outbox intent where policy requires notice for material identity or membership changes. Live email delivery is deferred.

---

## 7. P2B acceptance requirements

### 7.1 Identity mapping

1. A new Auth UUID bootstraps exactly one Haulvia profile.
2. Repeating bootstrap for the same Auth UUID returns the same profile.
3. Concurrent or repeated bootstrap cannot create duplicate profiles.
4. One Auth UUID cannot be linked to two profiles.
5. One claimed profile cannot be claimed by a second Auth UUID through ordinary claim.
6. A client-selected `profile_id` cannot impersonate another profile.
7. Operational records continue to reference the same Haulvia profile after identity recovery.

### 7.2 Invitation security

8. Invitation creation grants no active membership authority.
9. Only an authorized organization member may create an invitation.
10. A role incompatible with the organization's kind cannot be invited.
11. Raw invitation secrets are not stored.
12. An unknown invitation secret fails.
13. An expired invitation fails.
14. A revoked invitation fails.
15. A consumed invitation cannot be accepted a second time.
16. An invitation bound to another verified identity fails.
17. Invitation acceptance is atomic.
18. Successful acceptance produces exactly one active membership.
19. Successful acceptance produces exactly the approved role mappings.
20. Successful acceptance consumes the invitation.

### 7.3 Membership lifecycle

21. An `ACTIVE` membership contributes authority.
22. An `INVITED` membership contributes no authority.
23. A `SUSPENDED` membership contributes no authority.
24. An `ENDED` membership contributes no authority.
25. Invitation acceptance cannot silently reactivate a suspended membership.
26. Invitation acceptance cannot silently reopen an ended membership.
27. Suspending a membership preserves the profile and operational history.
28. Ending a membership preserves the profile and operational history.

### 7.4 Organization isolation

29. A user active in Organization A cannot act in Organization B without a separate active membership.
30. A client-supplied organization ID does not create authority.
31. A client-supplied membership ID does not create authority.
32. A client/JWT role claim does not override database membership state.
33. A stale token cannot restore authority after membership suspension.

### 7.5 Profile claim and recovery

34. A valid claim proof can link an Auth UUID to an unclaimed profile.
35. Claiming consumes the claim proof.
36. A claim proof cannot be reused.
37. A claimed profile cannot be overwritten by ordinary claim.
38. An Auth UUID already mapped elsewhere cannot claim another profile.
39. Auth identity replacement requires Haulvia `SECURITY_ACCESS_REVIEW`.
40. Auth identity replacement requires fresh reauthentication.
41. Auth identity replacement requires a written reason.
42. Auth identity replacement fails if the replacement Auth UUID belongs to another profile.
43. Auth identity replacement retains immutable before/after audit evidence.
44. Identity replacement does not move or delete memberships or operational records.

### 7.6 Disabled/deleted Auth handling

45. A disabled Auth principal cannot exercise new authority.
46. Disabling Auth access does not delete the Haulvia profile.
47. Disabling Auth access does not delete memberships.
48. Disabling Auth access does not delete operational history.
49. Deleting the external Auth principal does not cascade-delete Haulvia operational history.
50. Reactivation/replacement requires an approved trusted path.

### 7.7 Audit and idempotency

51. Every material P2B mutation creates immutable audit evidence.
52. Invitation/claim secrets never appear in audit metadata.
53. Replaying an idempotent command with the same request returns the original result.
54. Reusing an idempotency key with a different canonical request fails closed.
55. Failed multi-row commands leave no partial membership, role, identity-link or consumption state.

### 7.8 Security surface

56. No P2B human command grants worker authority.
57. No P2B function introduces `PUBLIC`, `anon` or `authenticated` execution unless explicitly required and reviewed.
58. Auth resolution uses trusted authentication context rather than arbitrary request JSON.
59. Database membership state overrides stale JWT role/organization claims.
60. P2B creates no second canonical application-user table.

---

## 8. P2B implementation boundary

P2B local database work includes:

- additive identity/invitation/claim schema where required;
- trusted profile bootstrap and claim commands;
- invitation create/accept commands;
- membership suspend/end commands where not already provided;
- privileged Auth-link replacement/recovery command;
- current Auth-to-profile resolver;
- current active-membership resolver;
- audit/idempotency integration;
- rollback-only acceptance suite.

P2B does not yet include:

- production Supabase Auth webhook wiring;
- hosted email delivery;
- live invitation email templates;
- hosted RLS enforcement;
- storage access policies;
- production JWT customization.

Those hosted concerns are wired after the local contract and database behavior are proven.

---

## 9. Next implementation artifact

After this contract passes static review, the next artifacts are:

1. additive P2B migration;
2. rollback-only P2B acceptance suite;
3. local PostgreSQL execution against Foundation -> Blocks A-E -> P2A -> P2B;
4. only after local acceptance passes, Git checkpoint and later hosted integration.
