-- Haulvia Phase 2 Block P2A
-- Authority and configuration seeds v1
--
-- Depends on:
--   20260814000100_haulvia_foundation_v1.sql
--   20260814000200_haulvia_block_a_commands_v1.sql
--   20260814000300_haulvia_block_b_commands_v1.sql
--   20260814000400_haulvia_block_c_commands_v1.sql
--   20260814000500_haulvia_block_d_commands_v1.sql
--   20260814000600_haulvia_block_e_commands_v1.sql
--
-- Phase 2 local-only artifact.
-- No hosted Supabase changes are required to create or review this migration.

begin;

set local search_path = haulvia, public;

-- ---------------------------------------------------------------------------
-- P2A.1 Role-to-organization authority boundary
-- ---------------------------------------------------------------------------

create table haulvia.role_organization_kinds (
  role_id uuid not null references haulvia.roles(id),
  organization_kind haulvia.organization_kind not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (role_id, organization_kind)
);

comment on table haulvia.role_organization_kinds is
  'Allowed organization kinds for human membership roles. '
  'BUSINESS roles are CUSTOMER-only, COURIER roles are '
  'COURIER_PARTNER-only, and Haulvia staff roles are HAULVIA-only.';

-- ---------------------------------------------------------------------------
-- Seed manifest
-- ---------------------------------------------------------------------------

create table haulvia.seed_manifests (
  id uuid primary key default gen_random_uuid(),
  seed_key text not null,
  version_no integer not null,
  source_sha256 text not null,
  metadata jsonb not null default '{}'::jsonb,
  applied_at timestamptz not null default clock_timestamp(),

  unique (seed_key, version_no),

  check (seed_key = upper(seed_key)),
  check (version_no > 0),
  check (source_sha256 ~ '^[0-9a-fA-F]{64}$')
);

comment on table haulvia.seed_manifests is
  'Append-only evidence identifying deterministic Haulvia seed packages.';

create trigger seed_manifests_append_only
before update or delete on haulvia.seed_manifests
for each row
execute function haulvia.reject_append_only_mutation();

-- ---------------------------------------------------------------------------
-- Human roles may never use trusted worker authority codes
-- ---------------------------------------------------------------------------

create or replace function haulvia.reject_worker_authority_role()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.role_key = any (
    array[
      'ROUTE_OPERATIONS_WORKER',
      'TERMINAL_REPOST_WORKER',
      'CUSTODY_TRANSFER_WORKER',
      'RECOVERY_WORKER',
      'STORAGE_WORKER',
      'COMPLETION_WORKER',
      'PAYOUT_WORKER'
    ]
  ) then
    raise exception
      'Worker authority % cannot be created as a human membership role',
      new.role_key
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger roles_reject_worker_authority
before insert or update of role_key on haulvia.roles
for each row
execute function haulvia.reject_worker_authority_role();

-- ---------------------------------------------------------------------------
-- Membership roles must match their organization's role scope
-- ---------------------------------------------------------------------------

create or replace function haulvia.enforce_membership_role_organization_kind()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_organization_kind haulvia.organization_kind;
  v_role_key text;
begin
  select o.kind
    into v_organization_kind
  from haulvia.organization_memberships om
  join haulvia.organizations o
    on o.id = om.organization_id
  where om.id = new.membership_id;

  if not found then
    raise exception
      'Membership % does not resolve to an organization',
      new.membership_id
      using errcode = '23503';
  end if;

  select r.role_key
    into v_role_key
  from haulvia.roles r
  where r.id = new.role_id;

  if not found then
    raise exception
      'Role % does not exist',
      new.role_id
      using errcode = '23503';
  end if;

  if not exists (
    select 1
    from haulvia.role_organization_kinds rok
    where rok.role_id = new.role_id
      and rok.organization_kind = v_organization_kind
  ) then
    raise exception
      'Role % is not permitted for organization kind %',
      v_role_key,
      v_organization_kind
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger membership_roles_enforce_organization_kind
before insert or update of membership_id, role_id
on haulvia.membership_roles
for each row
execute function haulvia.enforce_membership_role_organization_kind();

-- ---------------------------------------------------------------------------
-- P2A.2A Approved permission catalogue
-- ---------------------------------------------------------------------------

-- Existing Phase 1 permissions are authoritative by natural key.
-- P2A may correct their approved description/sensitivity without replacing IDs.

insert into haulvia.permissions (
  permission_key,
  description,
  is_sensitive
)
values
  (
    'COMPLIANCE_REVIEW',
    'Review and decide provider compliance items.',
    true
  ),
  (
    'PRICING_MANAGE',
    'Publish Haulvia pricing rules or partner rate cards.',
    true
  ),
  (
    'SHIPMENT_STATE_OVERRIDE',
    'Execute an approved administrative shipment transition.',
    true
  ),
  (
    'CUSTODY_TRANSFER_AUTHORIZE',
    'Authorize a post-pickup custody transfer.',
    true
  ),
  (
    'DISPUTE_RESOLVE',
    'Resolve a dispute and allocate protected funds.',
    true
  ),
  (
    'FINANCIAL_ADJUST',
    'Issue a refund, charge, credit or driver compensation.',
    true
  ),
  (
    'ROUTE_OPERATIONS_MANAGE',
    'Correct stop execution and manage route exceptions.',
    false
  ),
  (
    'STOP_EVIDENCE_REVIEW',
    'Review and verify stop evidence and custody movements.',
    false
  ),
  (
    'PAYOUT_MANAGE',
    'Submit, retry and administratively manage driver payouts.',
    true
  )
on conflict (permission_key)
do update set
  description = excluded.description,
  is_sensitive = excluded.is_sensitive;

-- ---------------------------------------------------------------------------
-- New P2A permissions must fail closed if an existing natural key has a
-- different sensitivity classification.
-- ---------------------------------------------------------------------------

do $$
declare
  v_conflict text;
begin
  with approved(permission_key, is_sensitive) as (
    values
      -- Customer organization
      ('ORG_MEMBER_VIEW', false),
      ('ORG_MEMBER_MANAGE', true),
      ('SHIPMENT_VIEW', false),
      ('SHIPMENT_CREATE', false),
      ('SHIPMENT_MANAGE', false),
      ('SHIPMENT_CANCEL', false),
      ('BILLING_VIEW', false),
      ('BILLING_MANAGE', true),
      ('SHIPMENT_DOCUMENT_VIEW', false),
      ('SHIPMENT_DOCUMENT_UPLOAD', false),
      ('ORG_AUDIT_VIEW', false),

      -- Courier provider
      ('PROVIDER_PROFILE_VIEW', false),
      ('PROVIDER_PROFILE_MANAGE', true),
      ('PROVIDER_MEMBER_VIEW', false),
      ('PROVIDER_MEMBER_MANAGE', true),
      ('DRIVER_ROSTER_VIEW', false),
      ('DRIVER_ROSTER_MANAGE', true),
      ('VEHICLE_VIEW', false),
      ('VEHICLE_MANAGE', true),
      ('RATE_CARD_VIEW', false),
      ('RATE_CARD_DRAFT', false),
      ('RATE_CARD_SUBMIT', true),
      ('OFFER_VIEW', false),
      ('OFFER_MANAGE', false),
      ('PROVIDER_ASSIGNMENT_VIEW', false),
      ('PROVIDER_ASSIGNMENT_MANAGE', true),
      ('PROVIDER_DOCUMENT_VIEW', false),
      ('PROVIDER_DOCUMENT_UPLOAD', false),

      -- Haulvia staff
      ('PLATFORM_CONFIGURATION_VIEW', false),
      ('PLATFORM_CONFIGURATION_MANAGE', true),
      ('INTERNAL_SHIPMENT_VIEW', false),
      ('INTERNAL_SHIPMENT_DOCUMENT_VIEW', false),
      ('INTERNAL_PROVIDER_VIEW', false),
      ('INTERNAL_PROVIDER_RATE_CARD_VIEW', false),
      ('INTERNAL_PAYMENT_VIEW', false),
      ('SENSITIVE_DOCUMENT_VIEW', true),
      ('SUPPORT_CASE_MANAGE', false),
      ('AUDIT_VIEW', false),
      ('AUDIT_EXPORT', true),
      ('SECURITY_ACCESS_REVIEW', true),
      ('POLICY_PUBLISH', true)
  )
  select p.permission_key
    into v_conflict
  from haulvia.permissions p
  join approved a
    on a.permission_key = p.permission_key
  where p.is_sensitive <> a.is_sensitive
  order by p.permission_key
  limit 1;

  if v_conflict is not null then
    raise exception
      'Existing permission % conflicts with the approved P2A sensitivity classification',
      v_conflict
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Customer-organization permissions
-- ---------------------------------------------------------------------------

insert into haulvia.permissions (
  permission_key,
  description,
  is_sensitive
)
values
  (
    'ORG_MEMBER_VIEW',
    'View active and invited members in the current organization.',
    false
  ),
  (
    'ORG_MEMBER_MANAGE',
    'Invite, activate, suspend, end or role-assign organization members.',
    true
  ),
  (
    'SHIPMENT_VIEW',
    'View shipments owned by the current customer organization.',
    false
  ),
  (
    'SHIPMENT_CREATE',
    'Create a shipment for the current customer organization.',
    false
  ),
  (
    'SHIPMENT_MANAGE',
    'Edit or progress an authorized nonterminal customer shipment.',
    false
  ),
  (
    'SHIPMENT_CANCEL',
    'Request an allowed cancellation for an owned shipment.',
    false
  ),
  (
    'BILLING_VIEW',
    'View customer payment, invoice, refund and adjustment projections.',
    false
  ),
  (
    'BILLING_MANAGE',
    'Add/remove payment references and approve customer-side payment actions.',
    true
  ),
  (
    'SHIPMENT_DOCUMENT_VIEW',
    'View authorized shipment documents for the current customer organization.',
    false
  ),
  (
    'SHIPMENT_DOCUMENT_UPLOAD',
    'Upload a document to an authorized shipment/document request.',
    false
  ),
  (
    'ORG_AUDIT_VIEW',
    'View the organization-safe activity projection, never raw internal audit metadata.',
    false
  )
on conflict (permission_key)
do update set
  description = excluded.description;

-- ---------------------------------------------------------------------------
-- Courier-provider permissions
-- ---------------------------------------------------------------------------

insert into haulvia.permissions (
  permission_key,
  description,
  is_sensitive
)
values
  (
    'PROVIDER_PROFILE_VIEW',
    'View the current provider''s approved profile and capabilities.',
    false
  ),
  (
    'PROVIDER_PROFILE_MANAGE',
    'Propose allowed provider-profile changes; compliance-impacting changes re-enter review.',
    true
  ),
  (
    'PROVIDER_MEMBER_VIEW',
    'View provider members and active driver relationships.',
    false
  ),
  (
    'PROVIDER_MEMBER_MANAGE',
    'Invite, suspend or end provider-organization memberships.',
    true
  ),
  (
    'DRIVER_ROSTER_VIEW',
    'View drivers attached to the current provider.',
    false
  ),
  (
    'DRIVER_ROSTER_MANAGE',
    'Add/remove drivers subject to onboarding and compliance gates.',
    true
  ),
  (
    'VEHICLE_VIEW',
    'View the current provider''s vehicles.',
    false
  ),
  (
    'VEHICLE_MANAGE',
    'Add/update/remove vehicles subject to compliance gates.',
    true
  ),
  (
    'RATE_CARD_VIEW',
    'View current provider rate-card drafts and effective versions.',
    false
  ),
  (
    'RATE_CARD_DRAFT',
    'Create or edit a provider rate-card draft.',
    false
  ),
  (
    'RATE_CARD_SUBMIT',
    'Submit a provider rate-card version for Haulvia review.',
    true
  ),
  (
    'OFFER_VIEW',
    'View provider-eligible marketplace opportunities and own offer threads.',
    false
  ),
  (
    'OFFER_MANAGE',
    'Submit, revise, counter or withdraw an offer on behalf of the provider.',
    false
  ),
  (
    'PROVIDER_ASSIGNMENT_VIEW',
    'View the provider''s reservations and assignments.',
    false
  ),
  (
    'PROVIDER_ASSIGNMENT_MANAGE',
    'Select eligible provider drivers/vehicles and request controlled reassignment.',
    true
  ),
  (
    'PROVIDER_DOCUMENT_VIEW',
    'View non-sensitive provider documents and explicitly authorized compliance-document projections.',
    false
  ),
  (
    'PROVIDER_DOCUMENT_UPLOAD',
    'Upload documents through an active provider/compliance document request.',
    false
  )
on conflict (permission_key)
do update set
  description = excluded.description;

-- ---------------------------------------------------------------------------
-- Haulvia staff permissions
-- ---------------------------------------------------------------------------

insert into haulvia.permissions (
  permission_key,
  description,
  is_sensitive
)
values
  (
    'PLATFORM_CONFIGURATION_VIEW',
    'View effective platform configuration and version metadata.',
    false
  ),
  (
    'PLATFORM_CONFIGURATION_MANAGE',
    'Draft/submit administrator-controlled configuration changes.',
    true
  ),
  (
    'INTERNAL_SHIPMENT_VIEW',
    'View operations-safe shipment and route projections across authorized tenant boundaries.',
    false
  ),
  (
    'INTERNAL_SHIPMENT_DOCUMENT_VIEW',
    'View non-sensitive internal shipment-document projections; protected objects still require specialized authority.',
    false
  ),
  (
    'INTERNAL_PROVIDER_VIEW',
    'View internal provider, driver, vehicle and assignment projections.',
    false
  ),
  (
    'INTERNAL_PROVIDER_RATE_CARD_VIEW',
    'View courier rate-card drafts, submissions and effective versions for review.',
    false
  ),
  (
    'INTERNAL_PAYMENT_VIEW',
    'View minimized internal payment, payout, refund and adjustment projections.',
    false
  ),
  (
    'SENSITIVE_DOCUMENT_VIEW',
    'View compliance, insurance or protected evidence documents with access auditing.',
    true
  ),
  (
    'SUPPORT_CASE_MANAGE',
    'Manage support cases without protected-document access.',
    false
  ),
  (
    'AUDIT_VIEW',
    'View approved audit projections for authorized organizations/entities.',
    false
  ),
  (
    'AUDIT_EXPORT',
    'Export an approved, minimized audit dataset with reason and access event.',
    true
  ),
  (
    'SECURITY_ACCESS_REVIEW',
    'Review memberships, roles, permission grants and sensitive access events.',
    true
  ),
  (
    'POLICY_PUBLISH',
    'Approve/publish non-pricing platform policy versions under dual control.',
    true
  )
on conflict (permission_key)
do update set
  description = excluded.description;

-- ---------------------------------------------------------------------------
-- P2A.2B Human role catalogue, organization boundaries and permission sets
-- ---------------------------------------------------------------------------

create temporary table p2a_role_seed (
  role_key text primary key,
  name text not null,
  description text not null,
  organization_kind haulvia.organization_kind not null,
  permission_keys text[] not null
) on commit drop;

insert into p2a_role_seed (
  role_key,
  name,
  description,
  organization_kind,
  permission_keys
)
values

  -- -------------------------------------------------------------------------
  -- Customer business roles
  -- -------------------------------------------------------------------------

  (
    'BUSINESS_OWNER',
    'Business Owner',
    'Customer-organization owner with the complete approved customer permission set.',
    'CUSTOMER',
    array[
      'ORG_MEMBER_VIEW',
      'ORG_MEMBER_MANAGE',
      'SHIPMENT_VIEW',
      'SHIPMENT_CREATE',
      'SHIPMENT_MANAGE',
      'SHIPMENT_CANCEL',
      'BILLING_VIEW',
      'BILLING_MANAGE',
      'SHIPMENT_DOCUMENT_VIEW',
      'SHIPMENT_DOCUMENT_UPLOAD',
      'ORG_AUDIT_VIEW'
    ]
  ),

  (
    'BUSINESS_ADMIN',
    'Business Administrator',
    'Customer-organization administrator excluding billing-management authority.',
    'CUSTOMER',
    array[
      'ORG_MEMBER_VIEW',
      'ORG_MEMBER_MANAGE',
      'SHIPMENT_VIEW',
      'SHIPMENT_CREATE',
      'SHIPMENT_MANAGE',
      'SHIPMENT_CANCEL',
      'BILLING_VIEW',
      'SHIPMENT_DOCUMENT_VIEW',
      'SHIPMENT_DOCUMENT_UPLOAD',
      'ORG_AUDIT_VIEW'
    ]
  ),

  (
    'BUSINESS_SHIPMENT_MANAGER',
    'Business Shipment Manager',
    'Customer role responsible for creating and managing shipments and shipment documents.',
    'CUSTOMER',
    array[
      'SHIPMENT_VIEW',
      'SHIPMENT_CREATE',
      'SHIPMENT_MANAGE',
      'SHIPMENT_CANCEL',
      'SHIPMENT_DOCUMENT_VIEW',
      'SHIPMENT_DOCUMENT_UPLOAD'
    ]
  ),

  (
    'BUSINESS_BILLING',
    'Business Billing',
    'Customer billing role with shipment visibility and customer billing-management authority.',
    'CUSTOMER',
    array[
      'SHIPMENT_VIEW',
      'BILLING_VIEW',
      'BILLING_MANAGE',
      'SHIPMENT_DOCUMENT_VIEW'
    ]
  ),

  (
    'BUSINESS_VIEWER',
    'Business Viewer',
    'Read-only customer role for shipments, billing, shipment documents and organization-safe activity.',
    'CUSTOMER',
    array[
      'SHIPMENT_VIEW',
      'BILLING_VIEW',
      'SHIPMENT_DOCUMENT_VIEW',
      'ORG_AUDIT_VIEW'
    ]
  ),

  -- -------------------------------------------------------------------------
  -- Courier partner roles
  -- -------------------------------------------------------------------------

  (
    'COURIER_OWNER',
    'Courier Owner',
    'Courier-partner owner with the complete approved courier-provider permission set.',
    'COURIER_PARTNER',
    array[
      'PROVIDER_PROFILE_VIEW',
      'PROVIDER_PROFILE_MANAGE',
      'PROVIDER_MEMBER_VIEW',
      'PROVIDER_MEMBER_MANAGE',
      'DRIVER_ROSTER_VIEW',
      'DRIVER_ROSTER_MANAGE',
      'VEHICLE_VIEW',
      'VEHICLE_MANAGE',
      'RATE_CARD_VIEW',
      'RATE_CARD_DRAFT',
      'RATE_CARD_SUBMIT',
      'OFFER_VIEW',
      'OFFER_MANAGE',
      'PROVIDER_ASSIGNMENT_VIEW',
      'PROVIDER_ASSIGNMENT_MANAGE',
      'PROVIDER_DOCUMENT_VIEW',
      'PROVIDER_DOCUMENT_UPLOAD'
    ]
  ),

  (
    'COURIER_ADMIN',
    'Courier Administrator',
    'Courier administrator for provider, members, drivers, vehicles, rates, offers, assignments and documents.',
    'COURIER_PARTNER',
    array[
      'PROVIDER_PROFILE_VIEW',
      'PROVIDER_PROFILE_MANAGE',
      'PROVIDER_MEMBER_VIEW',
      'PROVIDER_MEMBER_MANAGE',
      'DRIVER_ROSTER_VIEW',
      'DRIVER_ROSTER_MANAGE',
      'VEHICLE_VIEW',
      'VEHICLE_MANAGE',
      'RATE_CARD_VIEW',
      'RATE_CARD_DRAFT',
      'RATE_CARD_SUBMIT',
      'OFFER_VIEW',
      'OFFER_MANAGE',
      'PROVIDER_ASSIGNMENT_VIEW',
      'PROVIDER_ASSIGNMENT_MANAGE',
      'PROVIDER_DOCUMENT_VIEW',
      'PROVIDER_DOCUMENT_UPLOAD'
    ]
  ),

  (
    'COURIER_DISPATCHER',
    'Courier Dispatcher',
    'Courier dispatcher for operational offers and assignments without rate-card drafting or publication authority.',
    'COURIER_PARTNER',
    array[
      'PROVIDER_PROFILE_VIEW',
      'DRIVER_ROSTER_VIEW',
      'VEHICLE_VIEW',
      'RATE_CARD_VIEW',
      'OFFER_VIEW',
      'OFFER_MANAGE',
      'PROVIDER_ASSIGNMENT_VIEW',
      'PROVIDER_ASSIGNMENT_MANAGE',
      'PROVIDER_DOCUMENT_VIEW'
    ]
  ),

  (
    'COURIER_DRIVER',
    'Courier Driver',
    'Courier driver role with provider and assignment visibility; route execution still requires active driver assignment.',
    'COURIER_PARTNER',
    array[
      'PROVIDER_PROFILE_VIEW',
      'DRIVER_ROSTER_VIEW',
      'VEHICLE_VIEW',
      'PROVIDER_ASSIGNMENT_VIEW',
      'PROVIDER_DOCUMENT_UPLOAD'
    ]
  ),

  -- -------------------------------------------------------------------------
  -- Haulvia staff roles
  -- -------------------------------------------------------------------------

  (
    'PLATFORM_ADMIN',
    'Platform Administrator',
    'Top-level Haulvia administrative role; dual control, reauthentication and reason requirements still apply.',
    'HAULVIA',
    array[
      -- Existing specialized administrative permissions
      'COMPLIANCE_REVIEW',
      'PRICING_MANAGE',
      'SHIPMENT_STATE_OVERRIDE',
      'CUSTODY_TRANSFER_AUTHORIZE',
      'DISPUTE_RESOLVE',
      'FINANCIAL_ADJUST',
      'ROUTE_OPERATIONS_MANAGE',
      'STOP_EVIDENCE_REVIEW',
      'PAYOUT_MANAGE',

      -- Phase 2 Haulvia staff permissions
      'PLATFORM_CONFIGURATION_VIEW',
      'PLATFORM_CONFIGURATION_MANAGE',
      'INTERNAL_SHIPMENT_VIEW',
      'INTERNAL_SHIPMENT_DOCUMENT_VIEW',
      'INTERNAL_PROVIDER_VIEW',
      'INTERNAL_PROVIDER_RATE_CARD_VIEW',
      'INTERNAL_PAYMENT_VIEW',
      'SENSITIVE_DOCUMENT_VIEW',
      'SUPPORT_CASE_MANAGE',
      'AUDIT_VIEW',
      'AUDIT_EXPORT',
      'SECURITY_ACCESS_REVIEW',
      'POLICY_PUBLISH'
    ]
  ),

  (
    'OPERATIONS_MANAGER',
    'Operations Manager',
    'Haulvia operations role for shipment, route, stop-evidence and custody exception management.',
    'HAULVIA',
    array[
      'INTERNAL_SHIPMENT_VIEW',
      'INTERNAL_SHIPMENT_DOCUMENT_VIEW',
      'INTERNAL_PROVIDER_VIEW',
      'ROUTE_OPERATIONS_MANAGE',
      'STOP_EVIDENCE_REVIEW',
      'SHIPMENT_STATE_OVERRIDE',
      'CUSTODY_TRANSFER_AUTHORIZE',
      'AUDIT_VIEW'
    ]
  ),

  (
    'COMPLIANCE_REVIEWER',
    'Compliance Reviewer',
    'Haulvia compliance reviewer with protected-document access.',
    'HAULVIA',
    array[
      'COMPLIANCE_REVIEW',
      'SENSITIVE_DOCUMENT_VIEW',
      'INTERNAL_PROVIDER_VIEW',
      'AUDIT_VIEW'
    ]
  ),

  (
    'PRICING_MANAGER',
    'Pricing Manager',
    'Haulvia pricing role for platform pricing and courier rate-card review.',
    'HAULVIA',
    array[
      'PRICING_MANAGE',
      'PLATFORM_CONFIGURATION_VIEW',
      'INTERNAL_PROVIDER_VIEW',
      'INTERNAL_PROVIDER_RATE_CARD_VIEW',
      'AUDIT_VIEW'
    ]
  ),

  (
    'FINANCE_MANAGER',
    'Finance Manager',
    'Haulvia finance role for payment projections, payout management and financial adjustments.',
    'HAULVIA',
    array[
      'INTERNAL_SHIPMENT_VIEW',
      'INTERNAL_PAYMENT_VIEW',
      'PAYOUT_MANAGE',
      'FINANCIAL_ADJUST',
      'AUDIT_VIEW',
      'AUDIT_EXPORT'
    ]
  ),

  (
    'DISPUTE_REVIEWER',
    'Dispute Reviewer',
    'Haulvia dispute reviewer with shipment evidence and protected-document access.',
    'HAULVIA',
    array[
      'DISPUTE_RESOLVE',
      'STOP_EVIDENCE_REVIEW',
      'INTERNAL_SHIPMENT_VIEW',
      'INTERNAL_SHIPMENT_DOCUMENT_VIEW',
      'SENSITIVE_DOCUMENT_VIEW',
      'AUDIT_VIEW'
    ]
  ),

  (
    'SUPPORT_AGENT',
    'Support Agent',
    'Haulvia support role without sensitive-document authority.',
    'HAULVIA',
    array[
      'SUPPORT_CASE_MANAGE',
      'INTERNAL_SHIPMENT_VIEW',
      'INTERNAL_SHIPMENT_DOCUMENT_VIEW',
      'INTERNAL_PROVIDER_VIEW'
    ]
  ),

  (
    'AUDITOR_READ_ONLY',
    'Read-only Auditor',
    'Read-only Haulvia audit role without raw protected-document or mutation authority.',
    'HAULVIA',
    array[
      'AUDIT_VIEW',
      'PLATFORM_CONFIGURATION_VIEW',
      'INTERNAL_SHIPMENT_VIEW',
      'INTERNAL_PROVIDER_VIEW',
      'INTERNAL_PROVIDER_RATE_CARD_VIEW',
      'INTERNAL_PAYMENT_VIEW'
    ]
  );

-- ---------------------------------------------------------------------------
-- Seed human role definitions by stable natural key.
-- Existing role identifiers are retained.
-- ---------------------------------------------------------------------------

insert into haulvia.roles (
  role_key,
  name,
  description
)
select
  s.role_key,
  s.name,
  s.description
from p2a_role_seed s
on conflict (role_key)
do update set
  name = excluded.name,
  description = excluded.description;

-- ---------------------------------------------------------------------------
-- Fail closed if an approved human role already has an incompatible
-- organization-kind boundary.
-- ---------------------------------------------------------------------------

do $$
declare
  v_conflicting_role text;
  v_existing_kind haulvia.organization_kind;
  v_expected_kind haulvia.organization_kind;
begin
  select
    r.role_key,
    rok.organization_kind,
    s.organization_kind
  into
    v_conflicting_role,
    v_existing_kind,
    v_expected_kind
  from haulvia.roles r
  join p2a_role_seed s
    on s.role_key = r.role_key
  join haulvia.role_organization_kinds rok
    on rok.role_id = r.id
  where rok.organization_kind <> s.organization_kind
  order by r.role_key
  limit 1;

  if v_conflicting_role is not null then
    raise exception
      'Role % is scoped to organization kind %, but P2A requires %',
      v_conflicting_role,
      v_existing_kind,
      v_expected_kind
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Install the approved role-family boundaries.
-- ---------------------------------------------------------------------------

insert into haulvia.role_organization_kinds (
  role_id,
  organization_kind
)
select
  r.id,
  s.organization_kind
from p2a_role_seed s
join haulvia.roles r
  on r.role_key = s.role_key
on conflict (role_id, organization_kind)
do nothing;

-- ---------------------------------------------------------------------------
-- Verify every permission referenced by a seeded role exists.
-- This prevents a typo or incomplete permission catalogue from silently
-- producing a weaker role than the approved contract.
-- ---------------------------------------------------------------------------

do $$
declare
  v_role_key text;
  v_permission_key text;
begin
  select
    s.role_key,
    requested.permission_key
  into
    v_role_key,
    v_permission_key
  from p2a_role_seed s
  cross join lateral unnest(s.permission_keys)
    as requested(permission_key)
  left join haulvia.permissions p
    on p.permission_key = requested.permission_key
  where p.id is null
  order by s.role_key, requested.permission_key
  limit 1;

  if v_permission_key is not null then
    raise exception
      'Approved role % references missing permission %',
      v_role_key,
      v_permission_key
      using errcode = '23503';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Existing extra permission mappings on approved roles are conflicts.
-- P2A never silently removes authority to make the database appear compliant.
-- ---------------------------------------------------------------------------

do $$
declare
  v_role_key text;
  v_permission_key text;
begin
  select
    r.role_key,
    p.permission_key
  into
    v_role_key,
    v_permission_key
  from haulvia.role_permissions rp
  join haulvia.roles r
    on r.id = rp.role_id
  join haulvia.permissions p
    on p.id = rp.permission_id
  join p2a_role_seed s
    on s.role_key = r.role_key
  where not (p.permission_key = any (s.permission_keys))
  order by r.role_key, p.permission_key
  limit 1;

  if v_permission_key is not null then
    raise exception
      'Role % already has unapproved permission %',
      v_role_key,
      v_permission_key
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Insert every approved role-permission mapping.
-- Existing correct mappings retain their identifiers and timestamps.
-- ---------------------------------------------------------------------------

insert into haulvia.role_permissions (
  role_id,
  permission_id
)
select distinct
  r.id,
  p.id
from p2a_role_seed s
join haulvia.roles r
  on r.role_key = s.role_key
cross join lateral unnest(s.permission_keys)
  as requested(permission_key)
join haulvia.permissions p
  on p.permission_key = requested.permission_key
on conflict (role_id, permission_id)
do nothing;

-- ---------------------------------------------------------------------------
-- Defensive worker-role assertion.
-- The earlier trigger prevents new worker roles; this also fails if a worker
-- authority somehow existed before P2A.
-- ---------------------------------------------------------------------------

do $$
declare
  v_worker_role text;
begin
  select r.role_key
    into v_worker_role
  from haulvia.roles r
  where r.role_key = any (
    array[
      'ROUTE_OPERATIONS_WORKER',
      'TERMINAL_REPOST_WORKER',
      'CUSTODY_TRANSFER_WORKER',
      'RECOVERY_WORKER',
      'STORAGE_WORKER',
      'COMPLETION_WORKER',
      'PAYOUT_WORKER'
    ]
  )
  order by r.role_key
  limit 1;

  if v_worker_role is not null then
    raise exception
      'Backend worker authority % exists as a human role',
      v_worker_role
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- P2A.3A Platform policy catalog shells
-- ---------------------------------------------------------------------------

create temporary table p2a_policy_seed (
  policy_key text primary key,
  name text not null,
  description text not null
) on commit drop;

insert into p2a_policy_seed (
  policy_key,
  name,
  description
)
values
  (
    'MARKETPLACE_POLICY',
    'Marketplace Policy',
    'Versioned marketplace publication, pause, expiry and visibility policy.'
  ),
  (
    'NEGOTIATION_POLICY',
    'Negotiation Policy',
    'Versioned Flex negotiation, offer, counter and pricing-guardrail policy.'
  ),
  (
    'CANCELLATION_POLICY',
    'Cancellation Policy',
    'Versioned cancellation, rematching and cancellation-compensation policy.'
  ),
  (
    'EVIDENCE_POD_POLICY',
    'Evidence and Proof of Delivery Policy',
    'Versioned pickup, delivery, evidence, PIN, QR and proof-of-delivery policy.'
  ),
  (
    'CUSTODY_POLICY',
    'Custody Policy',
    'Versioned cargo custody, transfer, storage and recovery policy.'
  ),
  (
    'RECEIVER_REVIEW_POLICY',
    'Receiver Review Policy',
    'Versioned receiver confirmation, delivery review and issue-reporting policy.'
  ),
  (
    'PAYOUT_DISPUTE_POLICY',
    'Payout and Dispute Policy',
    'Versioned payout release, dispute handling and financial-resolution policy.'
  ),
  (
    'RETENTION_POLICY',
    'Retention Policy',
    'Versioned retention, archival, legal-hold and deletion-governance policy.'
  );

insert into haulvia.policy_sets (
  policy_key,
  name,
  description
)
select
  s.policy_key,
  s.name,
  s.description
from p2a_policy_seed s
on conflict (policy_key)
do update set
  name = excluded.name,
  description = excluded.description;

-- Existing version 1 rows for these seed shells must already match the
-- approved non-effective P2A definition. Never overwrite an effective or
-- independently modified version in order to make the seed pass.

do $$
declare
  v_policy_key text;
begin
  select ps.policy_key
    into v_policy_key
  from haulvia.policy_versions pv
  join haulvia.policy_sets ps
    on ps.id = pv.policy_set_id
  join p2a_policy_seed s
    on s.policy_key = ps.policy_key
  where pv.version_no = 1
    and (
      pv.publication_status <> 'DRAFT'
      or pv.effective_from is not null
      or pv.effective_to is not null
      or pv.config <> '{}'::jsonb
      or lower(pv.config_sha256)
         <> '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
      or pv.approved_by_profile_id is not null
      or pv.approved_at is not null
    )
  order by ps.policy_key
  limit 1;

  if v_policy_key is not null then
    raise exception
      'Existing policy shell % version 1 conflicts with the approved P2A draft definition',
      v_policy_key
      using errcode = '23514';
  end if;
end;
$$;

insert into haulvia.policy_versions (
  policy_set_id,
  version_no,
  publication_status,
  config,
  config_sha256,
  legal_review_required
)
select
  ps.id,
  1,
  'DRAFT',
  '{}'::jsonb,
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
  true
from p2a_policy_seed s
join haulvia.policy_sets ps
  on ps.policy_key = s.policy_key
where not exists (
  select 1
  from haulvia.policy_versions pv
  where pv.policy_set_id = ps.id
    and pv.version_no = 1
);

-- ---------------------------------------------------------------------------
-- P2A.3A Haulvia pricing rule-set shells
-- ---------------------------------------------------------------------------

create temporary table p2a_pricing_rule_seed (
  rule_key text primary key,
  name text not null,
  pricing_source haulvia.pricing_source not null,
  service_level haulvia.service_level not null,
  currency char(3) not null
) on commit drop;

insert into p2a_pricing_rule_seed (
  rule_key,
  name,
  pricing_source,
  service_level,
  currency
)
values
  (
    'HAULVIA_FLEX_GUARDRAIL_CAD',
    'Haulvia Flex Guardrails - CAD',
    'HAULVIA_GUARDRAIL',
    'FLEX',
    'CAD'
  ),
  (
    'HAULVIA_EXPEDITED_FIXED_CAD',
    'Haulvia Expedited Fixed Pricing - CAD',
    'HAULVIA_FIXED',
    'EXPEDITED',
    'CAD'
  );

-- A stable pricing natural key may never silently change pricing branch,
-- service level or currency.

do $$
declare
  v_rule_key text;
begin
  select prs.rule_key
    into v_rule_key
  from haulvia.pricing_rule_sets prs
  join p2a_pricing_rule_seed s
    on s.rule_key = prs.rule_key
  where prs.pricing_source <> s.pricing_source
     or prs.service_level <> s.service_level
     or prs.currency <> s.currency
  order by prs.rule_key
  limit 1;

  if v_rule_key is not null then
    raise exception
      'Existing pricing rule set % conflicts with the approved P2A pricing branch',
      v_rule_key
      using errcode = '23514';
  end if;
end;
$$;

insert into haulvia.pricing_rule_sets (
  rule_key,
  name,
  pricing_source,
  service_level,
  currency
)
select
  s.rule_key,
  s.name,
  s.pricing_source,
  s.service_level,
  s.currency
from p2a_pricing_rule_seed s
on conflict (rule_key)
do update set
  name = excluded.name;

-- Version 1 is deliberately an empty DRAFT shell.
-- No floor, ceiling, cap, percentage, base rate, distance rate,
-- waiting amount or other operational price is seeded here.

do $$
declare
  v_rule_key text;
begin
  select prs.rule_key
    into v_rule_key
  from haulvia.pricing_rule_versions prv
  join haulvia.pricing_rule_sets prs
    on prs.id = prv.pricing_rule_set_id
  join p2a_pricing_rule_seed s
    on s.rule_key = prs.rule_key
  where prv.version_no = 1
    and (
      prv.publication_status <> 'DRAFT'
      or prv.effective_from is not null
      or prv.effective_to is not null
      or prv.rule_config <> '{}'::jsonb
      or lower(prv.rule_sha256)
         <> '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
      or prv.approved_by_profile_id is not null
      or prv.approved_at is not null
    )
  order by prs.rule_key
  limit 1;

  if v_rule_key is not null then
    raise exception
      'Existing pricing shell % version 1 conflicts with the approved P2A draft definition',
      v_rule_key
      using errcode = '23514';
  end if;
end;
$$;

insert into haulvia.pricing_rule_versions (
  pricing_rule_set_id,
  version_no,
  publication_status,
  rule_config,
  rule_sha256
)
select
  prs.id,
  1,
  'DRAFT',
  '{}'::jsonb,
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
from p2a_pricing_rule_seed s
join haulvia.pricing_rule_sets prs
  on prs.rule_key = s.rule_key
where not exists (
  select 1
  from haulvia.pricing_rule_versions prv
  where prv.pricing_rule_set_id = prs.id
    and prv.version_no = 1
);

-- ---------------------------------------------------------------------------
-- P2A.3B Canadian tax jurisdiction registry
-- ---------------------------------------------------------------------------

create table haulvia.tax_jurisdictions (
  id uuid primary key default gen_random_uuid(),
  jurisdiction_key text not null unique,
  country_code char(2) not null,
  subdivision_code text,
  jurisdiction_level text not null,
  name text not null,
  created_at timestamptz not null default clock_timestamp(),

  check (jurisdiction_key = upper(jurisdiction_key)),
  check (country_code ~ '^[A-Z]{2}$'),
  check (
    subdivision_code is null
    or subdivision_code ~ '^[A-Z]{2,3}$'
  ),
  check (
    jurisdiction_level in (
      'FEDERAL',
      'PROVINCE',
      'TERRITORY'
    )
  ),
  check (
    (jurisdiction_level = 'FEDERAL' and subdivision_code is null)
    or
    (jurisdiction_level in ('PROVINCE', 'TERRITORY')
      and subdivision_code is not null)
  )
);

comment on table haulvia.tax_jurisdictions is
  'Stable jurisdiction identity registry. P2A contains no tax rates, '
  'taxability decisions or effective tax advice.';

create unique index tax_jurisdictions_country_subdivision_uq
  on haulvia.tax_jurisdictions (
    country_code,
    subdivision_code
  )
  where subdivision_code is not null;

-- ---------------------------------------------------------------------------
-- Version container for future accounting-approved tax configuration.
--
-- P2A creates only empty DRAFT shells. Later migrations/commands may add
-- effective tax rules after accounting/legal review.
-- ---------------------------------------------------------------------------

create table haulvia.tax_rule_versions (
  id uuid primary key default gen_random_uuid(),
  jurisdiction_id uuid not null
    references haulvia.tax_jurisdictions(id),
  version_no integer not null,
  publication_status haulvia.publication_status
    not null default 'DRAFT',
  effective_from timestamptz,
  effective_to timestamptz,
  rule_config jsonb not null default '{}'::jsonb,
  rule_sha256 text not null,
  created_by_profile_id uuid references haulvia.profiles(id),
  approved_by_profile_id uuid references haulvia.profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),

  unique (jurisdiction_id, version_no),

  check (version_no > 0),
  check (rule_sha256 ~ '^[0-9a-fA-F]{64}$'),
  check (
    effective_to is null
    or effective_from is null
    or effective_to > effective_from
  ),
  check (
    approved_at is null
    or approved_by_profile_id is not null
  ),
  check (
    publication_status <> 'APPROVED'
    or (
      effective_from is not null
      and approved_by_profile_id is not null
      and approved_at is not null
    )
  ),
  check (
    created_by_profile_id is null
    or approved_by_profile_id is null
    or created_by_profile_id <> approved_by_profile_id
  )
);

comment on table haulvia.tax_rule_versions is
  'Versioned tax configuration container. P2A seeds empty DRAFT shells only; '
  'rates and taxability rules require later accounting-approved publication.';

create trigger tax_rule_versions_guard
before update or delete on haulvia.tax_rule_versions
for each row
execute function haulvia.guard_published_version();

-- ---------------------------------------------------------------------------
-- Stable Canadian jurisdiction identities
-- ---------------------------------------------------------------------------

create temporary table p2a_tax_jurisdiction_seed (
  jurisdiction_key text primary key,
  country_code char(2) not null,
  subdivision_code text,
  jurisdiction_level text not null,
  name text not null
) on commit drop;

insert into p2a_tax_jurisdiction_seed (
  jurisdiction_key,
  country_code,
  subdivision_code,
  jurisdiction_level,
  name
)
values
  (
    'CA_FEDERAL',
    'CA',
    null,
    'FEDERAL',
    'Canada'
  ),

  -- Provinces
  (
    'CA_AB',
    'CA',
    'AB',
    'PROVINCE',
    'Alberta'
  ),
  (
    'CA_BC',
    'CA',
    'BC',
    'PROVINCE',
    'British Columbia'
  ),
  (
    'CA_MB',
    'CA',
    'MB',
    'PROVINCE',
    'Manitoba'
  ),
  (
    'CA_NB',
    'CA',
    'NB',
    'PROVINCE',
    'New Brunswick'
  ),
  (
    'CA_NL',
    'CA',
    'NL',
    'PROVINCE',
    'Newfoundland and Labrador'
  ),
  (
    'CA_NS',
    'CA',
    'NS',
    'PROVINCE',
    'Nova Scotia'
  ),
  (
    'CA_ON',
    'CA',
    'ON',
    'PROVINCE',
    'Ontario'
  ),
  (
    'CA_PE',
    'CA',
    'PE',
    'PROVINCE',
    'Prince Edward Island'
  ),
  (
    'CA_QC',
    'CA',
    'QC',
    'PROVINCE',
    'Quebec'
  ),
  (
    'CA_SK',
    'CA',
    'SK',
    'PROVINCE',
    'Saskatchewan'
  ),

  -- Territories
  (
    'CA_NT',
    'CA',
    'NT',
    'TERRITORY',
    'Northwest Territories'
  ),
  (
    'CA_NU',
    'CA',
    'NU',
    'TERRITORY',
    'Nunavut'
  ),
  (
    'CA_YT',
    'CA',
    'YT',
    'TERRITORY',
    'Yukon'
  );

-- A stable jurisdiction key may not silently change geographic identity.

do $$
declare
  v_jurisdiction_key text;
begin
  select tj.jurisdiction_key
    into v_jurisdiction_key
  from haulvia.tax_jurisdictions tj
  join p2a_tax_jurisdiction_seed s
    on s.jurisdiction_key = tj.jurisdiction_key
  where tj.country_code <> s.country_code
     or tj.subdivision_code is distinct from s.subdivision_code
     or tj.jurisdiction_level <> s.jurisdiction_level
  order by tj.jurisdiction_key
  limit 1;

  if v_jurisdiction_key is not null then
    raise exception
      'Existing tax jurisdiction % conflicts with the approved P2A identity',
      v_jurisdiction_key
      using errcode = '23514';
  end if;
end;
$$;

insert into haulvia.tax_jurisdictions (
  jurisdiction_key,
  country_code,
  subdivision_code,
  jurisdiction_level,
  name
)
select
  s.jurisdiction_key,
  s.country_code,
  s.subdivision_code,
  s.jurisdiction_level,
  s.name
from p2a_tax_jurisdiction_seed s
on conflict (jurisdiction_key)
do update set
  name = excluded.name;

-- ---------------------------------------------------------------------------
-- Empty version-1 shells only.
--
-- SHA-256 below is the digest of the literal JSON object: {}
-- No GST, HST, PST, QST or other rate is being asserted here.
-- ---------------------------------------------------------------------------

do $$
declare
  v_jurisdiction_key text;
begin
  select tj.jurisdiction_key
    into v_jurisdiction_key
  from haulvia.tax_rule_versions trv
  join haulvia.tax_jurisdictions tj
    on tj.id = trv.jurisdiction_id
  join p2a_tax_jurisdiction_seed s
    on s.jurisdiction_key = tj.jurisdiction_key
  where trv.version_no = 1
    and (
      trv.publication_status <> 'DRAFT'
      or trv.effective_from is not null
      or trv.effective_to is not null
      or trv.rule_config <> '{}'::jsonb
      or lower(trv.rule_sha256)
         <> '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
      or trv.approved_by_profile_id is not null
      or trv.approved_at is not null
    )
  order by tj.jurisdiction_key
  limit 1;

  if v_jurisdiction_key is not null then
    raise exception
      'Existing tax jurisdiction % version 1 conflicts with the approved P2A draft shell',
      v_jurisdiction_key
      using errcode = '23514';
  end if;
end;
$$;

insert into haulvia.tax_rule_versions (
  jurisdiction_id,
  version_no,
  publication_status,
  rule_config,
  rule_sha256
)
select
  tj.id,
  1,
  'DRAFT',
  '{}'::jsonb,
  '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
from p2a_tax_jurisdiction_seed s
join haulvia.tax_jurisdictions tj
  on tj.jurisdiction_key = s.jurisdiction_key
where not exists (
  select 1
  from haulvia.tax_rule_versions trv
  where trv.jurisdiction_id = tj.id
    and trv.version_no = 1
);

-- ---------------------------------------------------------------------------
-- P2A.3C Compliance requirement category shells
--
-- These rows define only the four approved compliance subject/catalog scopes.
-- They do NOT create any effective compliance requirement.
--
-- Exact requirements such as licence, insurance, maintenance, TDG,
-- safety credentials, review documents or custom requirements remain
-- deliberately unseeded until separately approved.
-- ---------------------------------------------------------------------------

create table haulvia.compliance_requirement_categories (
  id uuid primary key default gen_random_uuid(),
  category_key text not null unique,
  subject_kind haulvia.compliance_subject_kind not null,
  name text not null,
  description text not null,
  created_at timestamptz not null default clock_timestamp(),

  check (category_key = upper(category_key))
);

comment on table haulvia.compliance_requirement_categories is
  'Stable top-level compliance catalog scopes. These definitions do not '
  'themselves make any compliance item required or effective. Exact '
  'requirements remain in compliance_requirements and '
  'compliance_requirement_versions after separate approval.';

-- ---------------------------------------------------------------------------
-- Deterministic P2A compliance-category seed
-- ---------------------------------------------------------------------------

create temporary table p2a_compliance_category_seed (
  category_key text primary key,
  subject_kind haulvia.compliance_subject_kind not null,
  name text not null,
  description text not null
) on commit drop;

insert into p2a_compliance_category_seed (
  category_key,
  subject_kind,
  name,
  description
)
values
  (
    'APPLICATION_REQUIREMENTS',
    'APPLICATION',
    'Application Requirements',
    'Catalog scope for compliance requirements evaluated during provider application and onboarding.'
  ),
  (
    'PROVIDER_REQUIREMENTS',
    'PROVIDER',
    'Provider Requirements',
    'Catalog scope for compliance requirements attached to an approved or pending service provider.'
  ),
  (
    'DRIVER_REQUIREMENTS',
    'DRIVER',
    'Driver Requirements',
    'Catalog scope for compliance requirements attached to an individual driver.'
  ),
  (
    'VEHICLE_REQUIREMENTS',
    'VEHICLE',
    'Vehicle Requirements',
    'Catalog scope for compliance requirements attached to a provider vehicle.'
  );

-- ---------------------------------------------------------------------------
-- A stable category key may never silently change subject ownership.
-- ---------------------------------------------------------------------------

do $$
declare
  v_category_key text;
  v_existing_kind haulvia.compliance_subject_kind;
  v_expected_kind haulvia.compliance_subject_kind;
begin
  select
    crc.category_key,
    crc.subject_kind,
    s.subject_kind
  into
    v_category_key,
    v_existing_kind,
    v_expected_kind
  from haulvia.compliance_requirement_categories crc
  join p2a_compliance_category_seed s
    on s.category_key = crc.category_key
  where crc.subject_kind <> s.subject_kind
  order by crc.category_key
  limit 1;

  if v_category_key is not null then
    raise exception
      'Compliance category % belongs to subject kind %, but P2A requires %',
      v_category_key,
      v_existing_kind,
      v_expected_kind
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Insert/update descriptive metadata only.
--
-- IDs and subject ownership remain stable.
-- ---------------------------------------------------------------------------

insert into haulvia.compliance_requirement_categories (
  category_key,
  subject_kind,
  name,
  description
)
select
  s.category_key,
  s.subject_kind,
  s.name,
  s.description
from p2a_compliance_category_seed s
on conflict (category_key)
do update set
  name = excluded.name,
  description = excluded.description;

-- ---------------------------------------------------------------------------
-- Defensive assertion:
-- P2A.3C must not create an actual compliance requirement merely because
-- a category exists.
-- ---------------------------------------------------------------------------

do $$
declare
  v_shell_code text;
begin
  select cr.compliance_code
    into v_shell_code
  from haulvia.compliance_requirements cr
  where cr.requirement_key = any (
    array[
      'APPLICATION_REQUIREMENTS',
      'PROVIDER_REQUIREMENTS',
      'DRIVER_REQUIREMENTS',
      'VEHICLE_REQUIREMENTS'
    ]
  )
     or cr.compliance_code = any (
    array[
      'APPLICATION_REQUIREMENTS',
      'PROVIDER_REQUIREMENTS',
      'DRIVER_REQUIREMENTS',
      'VEHICLE_REQUIREMENTS'
    ]
  )
  order by cr.compliance_code
  limit 1;

  if v_shell_code is not null then
    raise exception
      'Compliance catalog shell % must not exist as an operational compliance requirement',
      v_shell_code
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- P2A.3D Typed administrator-controlled configuration registry
--
-- P2A creates:
--   1. Stable configuration definitions.
--   2. Expected value types and units.
--   3. A version container for future approved values.
--
-- P2A DOES NOT seed effective configuration values.
-- ---------------------------------------------------------------------------

create type haulvia.configuration_value_type as enum (
  'BOOLEAN',
  'INTEGER',
  'NUMERIC',
  'TEXT',
  'TEXT_ARRAY',
  'JSON_OBJECT'
);

create table haulvia.platform_config_definitions (
  id uuid primary key default gen_random_uuid(),
  config_key text not null unique,
  category_key text not null,
  value_type haulvia.configuration_value_type not null,
  unit_key text,
  name text not null,
  description text not null,
  is_sensitive boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),

  check (config_key = upper(config_key)),
  check (category_key = upper(category_key)),
  check (
    unit_key is null
    or unit_key = upper(unit_key)
  )
);

comment on table haulvia.platform_config_definitions is
  'Stable administrator-controlled configuration definitions. '
  'Definitions contain type/unit metadata only and no effective value.';

create table haulvia.platform_config_versions (
  id uuid primary key default gen_random_uuid(),
  config_definition_id uuid not null
    references haulvia.platform_config_definitions(id),
  version_no integer not null,
  publication_status haulvia.publication_status
    not null default 'DRAFT',

  -- NULL is deliberate and means that no value has been configured yet.
  config_value jsonb,

  value_sha256 text,
  effective_from timestamptz,
  effective_to timestamptz,

  created_by_profile_id uuid references haulvia.profiles(id),
  approved_by_profile_id uuid references haulvia.profiles(id),
  approval_reason text,
  approved_at timestamptz,

  created_at timestamptz not null default clock_timestamp(),

  unique (config_definition_id, version_no),

  check (version_no > 0),

  check (
    value_sha256 is null
    or value_sha256 ~ '^[0-9a-fA-F]{64}$'
  ),

  check (
    effective_to is null
    or effective_from is null
    or effective_to > effective_from
  ),

  check (
    approved_at is null
    or approved_by_profile_id is not null
  ),

  check (
    approved_by_profile_id is null
    or created_by_profile_id is null
    or approved_by_profile_id <> created_by_profile_id
  ),

  check (
    publication_status <> 'APPROVED'
    or (
      config_value is not null
      and value_sha256 is not null
      and effective_from is not null
      and approved_by_profile_id is not null
      and approved_at is not null
      and nullif(btrim(approval_reason), '') is not null
    )
  )
);

comment on table haulvia.platform_config_versions is
  'Versioned administrator-controlled configuration values. '
  'P2A seeds no rows here; future publication requires approval and '
  'an effective date.';

create trigger platform_config_versions_guard
before update or delete on haulvia.platform_config_versions
for each row
execute function haulvia.guard_published_version();

-- ---------------------------------------------------------------------------
-- Validate a future configured value against its declared data type.
-- NULL remains valid for an unconfigured DRAFT only.
-- ---------------------------------------------------------------------------

create or replace function haulvia.validate_platform_config_value()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_value_type haulvia.configuration_value_type;
begin
  select pcd.value_type
    into v_value_type
  from haulvia.platform_config_definitions pcd
  where pcd.id = new.config_definition_id;

  if not found then
    raise exception
      'Configuration definition % does not exist',
      new.config_definition_id
      using errcode = '23503';
  end if;

  if new.config_value is null then
    if new.publication_status = 'APPROVED' then
      raise exception
        'Approved configuration versions require a value'
        using errcode = '23514';
    end if;

    return new;
  end if;

  case v_value_type

    when 'BOOLEAN' then
      if jsonb_typeof(new.config_value) <> 'boolean' then
        raise exception
          'Configuration value must be BOOLEAN'
          using errcode = '23514';
      end if;

    when 'INTEGER' then
      if jsonb_typeof(new.config_value) <> 'number'
         or (new.config_value #>> '{}')::numeric
            <> trunc((new.config_value #>> '{}')::numeric)
      then
        raise exception
          'Configuration value must be INTEGER'
          using errcode = '23514';
      end if;

    when 'NUMERIC' then
      if jsonb_typeof(new.config_value) <> 'number' then
        raise exception
          'Configuration value must be NUMERIC'
          using errcode = '23514';
      end if;

    when 'TEXT' then
      if jsonb_typeof(new.config_value) <> 'string' then
        raise exception
          'Configuration value must be TEXT'
          using errcode = '23514';
      end if;

    when 'TEXT_ARRAY' then
      if jsonb_typeof(new.config_value) <> 'array'
         or exists (
           select 1
           from jsonb_array_elements(new.config_value) element
           where jsonb_typeof(element) <> 'string'
         )
      then
        raise exception
          'Configuration value must be an array of text values'
          using errcode = '23514';
      end if;

    when 'JSON_OBJECT' then
      if jsonb_typeof(new.config_value) <> 'object' then
        raise exception
          'Configuration value must be a JSON object'
          using errcode = '23514';
      end if;

  end case;

  return new;
end;
$$;

create trigger platform_config_versions_validate
before insert or update of
  config_definition_id,
  config_value,
  publication_status
on haulvia.platform_config_versions
for each row
execute function haulvia.validate_platform_config_value();

-- ---------------------------------------------------------------------------
-- Approved P2A configuration-key catalog
--
-- IMPORTANT:
-- These are definitions only.
-- No seconds, counts, bytes, distances or operational thresholds are seeded.
-- ---------------------------------------------------------------------------

create temporary table p2a_platform_config_seed (
  config_key text primary key,
  category_key text not null,
  value_type haulvia.configuration_value_type not null,
  unit_key text,
  name text not null,
  description text not null,
  is_sensitive boolean not null
) on commit drop;

insert into p2a_platform_config_seed (
  config_key,
  category_key,
  value_type,
  unit_key,
  name,
  description,
  is_sensitive
)
values

  -- -------------------------------------------------------------------------
  -- Security / session
  -- -------------------------------------------------------------------------

  (
    'SECURITY_SESSION_MAX_AGE_SECONDS',
    'SECURITY_SESSION',
    'INTEGER',
    'SECONDS',
    'Maximum Session Age',
    'Maximum permitted authenticated-session lifetime.',
    true
  ),
  (
    'SECURITY_SESSION_IDLE_TIMEOUT_SECONDS',
    'SECURITY_SESSION',
    'INTEGER',
    'SECONDS',
    'Session Idle Timeout',
    'Maximum permitted inactivity period before session expiry.',
    true
  ),
  (
    'SECURITY_REAUTH_MAX_AGE_SECONDS',
    'SECURITY_SESSION',
    'INTEGER',
    'SECONDS',
    'Sensitive Action Reauthentication Age',
    'Maximum age of a qualifying reauthentication event for a sensitive action.',
    true
  ),

  -- -------------------------------------------------------------------------
  -- Marketplace / offer expiry
  -- -------------------------------------------------------------------------

  (
    'MARKETPLACE_ASAP_LISTING_EXPIRY_SECONDS',
    'OFFER_EXPIRY',
    'INTEGER',
    'SECONDS',
    'ASAP Listing Expiry',
    'Maximum active marketplace lifetime for an ASAP listing.',
    false
  ),
  (
    'MARKETPLACE_SCHEDULED_LISTING_EXPIRY_SECONDS',
    'OFFER_EXPIRY',
    'INTEGER',
    'SECONDS',
    'Scheduled Listing Expiry',
    'Maximum active marketplace lifetime for a scheduled listing.',
    false
  ),
  (
    'OFFER_RESPONSE_TIMEOUT_SECONDS',
    'OFFER_EXPIRY',
    'INTEGER',
    'SECONDS',
    'Offer Response Timeout',
    'Response window associated with a live offer where policy requires one.',
    false
  ),
  (
    'COUNTER_RESPONSE_TIMEOUT_SECONDS',
    'OFFER_EXPIRY',
    'INTEGER',
    'SECONDS',
    'Counter Response Timeout',
    'Response window associated with an active negotiated counter.',
    false
  ),
  (
    'OFFER_RESERVATION_TIMEOUT_SECONDS',
    'OFFER_EXPIRY',
    'INTEGER',
    'SECONDS',
    'Offer Reservation Timeout',
    'Maximum reservation period while assignment prerequisites are being completed.',
    false
  ),

  -- -------------------------------------------------------------------------
  -- Receiver / delivery review
  -- -------------------------------------------------------------------------

  (
    'RECEIVER_CONFIRMATION_WINDOW_SECONDS',
    'RECEIVER_WINDOW',
    'INTEGER',
    'SECONDS',
    'Receiver Confirmation Window',
    'Window during which an authorized receiver may confirm receipt or report an immediate issue.',
    false
  ),
  (
    'DELIVERY_RESOLUTION_MINIMUM_SECONDS',
    'RECEIVER_WINDOW',
    'INTEGER',
    'SECONDS',
    'Minimum Delivery Resolution Window',
    'Minimum resolution period applied to an eligible failed-delivery workflow.',
    false
  ),

  -- -------------------------------------------------------------------------
  -- Upload controls
  -- -------------------------------------------------------------------------

  (
    'UPLOAD_MAX_FILE_BYTES',
    'UPLOAD_LIMIT',
    'INTEGER',
    'BYTES',
    'Maximum Upload File Size',
    'Maximum permitted size for one uploaded object.',
    true
  ),
  (
    'UPLOAD_MAX_FILES_PER_REQUEST',
    'UPLOAD_LIMIT',
    'INTEGER',
    'COUNT',
    'Maximum Files Per Upload Request',
    'Maximum number of files permitted in one authorized upload request.',
    true
  ),
  (
    'UPLOAD_ALLOWED_MEDIA_TYPES',
    'UPLOAD_LIMIT',
    'TEXT_ARRAY',
    null,
    'Allowed Upload Media Types',
    'Approved MIME/media types accepted by protected upload workflows.',
    true
  ),

  -- -------------------------------------------------------------------------
  -- Notification controls
  -- -------------------------------------------------------------------------

  (
    'NOTIFICATION_RETRY_MAX_ATTEMPTS',
    'NOTIFICATION',
    'INTEGER',
    'COUNT',
    'Notification Retry Limit',
    'Maximum delivery attempts for a retryable notification.',
    false
  ),
  (
    'NOTIFICATION_RETRY_BACKOFF_SECONDS',
    'NOTIFICATION',
    'INTEGER',
    'SECONDS',
    'Notification Retry Backoff',
    'Configured retry delay used by notification delivery workers.',
    false
  ),
  (
    'NOTIFICATION_ESCALATION_DELAY_SECONDS',
    'NOTIFICATION',
    'INTEGER',
    'SECONDS',
    'Notification Escalation Delay',
    'Delay before an eligible unresolved action-required notification escalates.',
    false
  ),

  -- -------------------------------------------------------------------------
  -- Operational thresholds
  -- -------------------------------------------------------------------------

  (
    'CUSTOMER_ASSIGNMENT_GRACE_SECONDS',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'SECONDS',
    'Customer Assignment Grace Period',
    'Grace period associated with an eligible assignment workflow.',
    false
  ),
  (
    'DRIVER_START_DEADLINE_SECONDS',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'SECONDS',
    'Driver Start Deadline',
    'Maximum allowed interval for an assigned driver to begin required dispatch activity.',
    false
  ),
  (
    'LATE_ARRIVAL_THRESHOLD_SECONDS',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'SECONDS',
    'Late Arrival Threshold',
    'Threshold used to classify an arrival as operationally late.',
    false
  ),
  (
    'NO_SHOW_THRESHOLD_SECONDS',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'SECONDS',
    'No-show Threshold',
    'Threshold used by policy to determine an eligible no-show condition.',
    false
  ),
  (
    'PICKUP_FREE_WAIT_SECONDS',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'SECONDS',
    'Pickup Free Waiting Period',
    'Configured free waiting interval at an eligible pickup stop.',
    false
  ),
  (
    'PICKUP_GEOFENCE_RADIUS_METRES',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'METRES',
    'Pickup Geofence Radius',
    'Configured geofence radius used as one signal for verified pickup arrival.',
    false
  ),
  (
    'DELIVERY_GEOFENCE_RADIUS_METRES',
    'OPERATIONAL_THRESHOLD',
    'INTEGER',
    'METRES',
    'Delivery Geofence Radius',
    'Configured geofence radius used as one signal for verified delivery arrival.',
    false
  );

-- ---------------------------------------------------------------------------
-- Fail closed if a stable configuration key already has incompatible
-- category, type, unit or sensitivity metadata.
-- ---------------------------------------------------------------------------

do $$
declare
  v_config_key text;
begin
  select pcd.config_key
    into v_config_key
  from haulvia.platform_config_definitions pcd
  join p2a_platform_config_seed s
    on s.config_key = pcd.config_key
  where pcd.category_key <> s.category_key
     or pcd.value_type <> s.value_type
     or pcd.unit_key is distinct from s.unit_key
     or pcd.is_sensitive <> s.is_sensitive
  order by pcd.config_key
  limit 1;

  if v_config_key is not null then
    raise exception
      'Existing platform configuration definition % conflicts with the approved P2A contract',
      v_config_key
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Insert stable definitions.
-- Descriptive labels may be corrected; authority/type semantics may not.
-- ---------------------------------------------------------------------------

insert into haulvia.platform_config_definitions (
  config_key,
  category_key,
  value_type,
  unit_key,
  name,
  description,
  is_sensitive
)
select
  s.config_key,
  s.category_key,
  s.value_type,
  s.unit_key,
  s.name,
  s.description,
  s.is_sensitive
from p2a_platform_config_seed s
on conflict (config_key)
do update set
  name = excluded.name,
  description = excluded.description;

-- ---------------------------------------------------------------------------
-- P2A must leave the configuration registry non-effective.
--
-- Definitions exist, but the seed must not introduce even a DRAFT numeric
-- value because doing so could accidentally become an application default.
-- ---------------------------------------------------------------------------

do $$
declare
  v_seeded_value_key text;
begin
  select pcd.config_key
    into v_seeded_value_key
  from haulvia.platform_config_versions pcv
  join haulvia.platform_config_definitions pcd
    on pcd.id = pcv.config_definition_id
  join p2a_platform_config_seed s
    on s.config_key = pcd.config_key
  where pcv.config_value is not null
  order by pcd.config_key
  limit 1;

  if v_seeded_value_key is not null then
    raise exception
      'P2A configuration key % already has a value; P2A requires definitions only',
      v_seeded_value_key
      using errcode = '23514';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- P2A.4A Publication dual-control invariants
--
-- Sensitive publication requires:
--   * an identified creator,
--   * a different approver,
--   * an effective date,
--   * fresh reauthentication,
--   * a specific written approval reason,
--   * the appropriate sensitive Haulvia permission.
--
-- PLATFORM_ADMIN remains subject to the same rules.
-- ---------------------------------------------------------------------------

alter table haulvia.policy_versions
  add column reauth_session_id uuid
    references haulvia.reauth_sessions(id),
  add column approval_reason text,

  add constraint policy_versions_dual_control_ck
    check (
      created_by_profile_id is null
      or approved_by_profile_id is null
      or created_by_profile_id <> approved_by_profile_id
    ),

  add constraint policy_versions_p2a_approval_ck
    check (
      publication_status <> 'APPROVED'
      or (
        created_by_profile_id is not null
        and reauth_session_id is not null
        and approval_reason is not null
        and length(btrim(approval_reason)) >= 8
      )
    );


alter table haulvia.pricing_rule_versions
  add column reauth_session_id uuid
    references haulvia.reauth_sessions(id),
  add column approval_reason text,

  add constraint pricing_rule_versions_dual_control_ck
    check (
      created_by_profile_id is null
      or approved_by_profile_id is null
      or created_by_profile_id <> approved_by_profile_id
    ),

  add constraint pricing_rule_versions_p2a_approval_ck
    check (
      publication_status <> 'APPROVED'
      or (
        created_by_profile_id is not null
        and reauth_session_id is not null
        and approval_reason is not null
        and length(btrim(approval_reason)) >= 8
      )
    );


alter table haulvia.compliance_requirement_versions
  add column reauth_session_id uuid
    references haulvia.reauth_sessions(id),
  add column approval_reason text,

  add constraint compliance_requirement_versions_dual_control_ck
    check (
      created_by_profile_id is null
      or approved_by_profile_id is null
      or created_by_profile_id <> approved_by_profile_id
    ),

  add constraint compliance_requirement_versions_p2a_approval_ck
    check (
      publication_status <> 'APPROVED'
      or (
        created_by_profile_id is not null
        and reauth_session_id is not null
        and approval_reason is not null
        and length(btrim(approval_reason)) >= 8
      )
    );


-- Partner rate-card versions already contain reauth_session_id and review_note.
-- Add only the missing creator/approver separation and stronger approval reason
-- requirement instead of duplicating those existing columns.

alter table haulvia.partner_rate_card_versions
  add constraint partner_rate_card_versions_dual_control_ck
    check (
      created_by_profile_id is null
      or approved_by_profile_id is null
      or created_by_profile_id <> approved_by_profile_id
    ),

  add constraint partner_rate_card_versions_p2a_approval_ck
    check (
      publication_status <> 'APPROVED'
      or (
        created_by_profile_id is not null
        and review_note is not null
        and length(btrim(review_note)) >= 8
      )
    );

-- ---------------------------------------------------------------------------
-- One publication authority guard is shared by the four version tables.
--
-- Existing guard_published_version() continues to enforce post-publication
-- immutability. This function governs the transition INTO APPROVED.
-- ---------------------------------------------------------------------------

create or replace function haulvia.enforce_publication_dual_control()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_permission_key text;
  v_reason text;
  v_reauth_session_id uuid;
  v_organization_id uuid;
begin
  -- Nothing to do unless this row is entering APPROVED status.
  if new.publication_status <> 'APPROVED' then
    return new;
  end if;

  -- An already-approved row may later be superseded/expired through the
  -- existing immutable-version guard. Do not demand a second approval here.
  if tg_op = 'UPDATE'
     and old.publication_status = 'APPROVED'
  then
    return new;
  end if;

  if new.created_by_profile_id is null then
    raise exception
      'Approved % requires an identified creator',
      tg_table_name
      using errcode = '23514';
  end if;

  if new.approved_by_profile_id is null then
    raise exception
      'Approved % requires an identified approver',
      tg_table_name
      using errcode = '23514';
  end if;

  if new.created_by_profile_id = new.approved_by_profile_id then
    raise exception
      'Creator may not approve their own % version',
      tg_table_name
      using errcode = '42501';
  end if;

  if new.effective_from is null then
    raise exception
      'Approved % requires an effective date',
      tg_table_name
      using errcode = '23514';
  end if;

  if new.approved_at is null then
    raise exception
      'Approved % requires an approval timestamp',
      tg_table_name
      using errcode = '23514';
  end if;

  -- All four tables expose reauth_session_id after the alterations above.
  v_reauth_session_id :=
    nullif(to_jsonb(new) ->> 'reauth_session_id', '')::uuid;

  -- Partner rate cards already use review_note. The other publication
  -- families use the explicit P2A approval_reason column.
  v_reason := coalesce(
    nullif(btrim(to_jsonb(new) ->> 'approval_reason'), ''),
    nullif(btrim(to_jsonb(new) ->> 'review_note'), '')
  );

  if v_reauth_session_id is null then
    raise exception
      'Approved % requires fresh reauthentication',
      tg_table_name
      using errcode = '42501';
  end if;

  if v_reason is null or length(v_reason) < 8 then
    raise exception
      'Approved % requires a specific written approval reason',
      tg_table_name
      using errcode = '22023';
  end if;

  -- Publication authority is always exercised inside the Haulvia operating
  -- organization. A customer/courier reauth context can never publish these
  -- platform-controlled versions.
  select rs.organization_id
    into v_organization_id
  from haulvia.reauth_sessions rs
  join haulvia.organizations o
    on o.id = rs.organization_id
  where rs.id = v_reauth_session_id
    and o.kind = 'HAULVIA';

  if v_organization_id is null then
    raise exception
      'Sensitive publication requires a Haulvia organization reauthentication context'
      using errcode = '42501';
  end if;

  v_permission_key :=
    case tg_table_name

      when 'policy_versions'
        then 'POLICY_PUBLISH'

      when 'pricing_rule_versions'
        then 'PRICING_MANAGE'

      when 'partner_rate_card_versions'
        then 'PRICING_MANAGE'

      when 'compliance_requirement_versions'
        then 'COMPLIANCE_REVIEW'

      else null
    end;

  if v_permission_key is null then
    raise exception
      'Unsupported dual-control publication table %',
      tg_table_name
      using errcode = '55000';
  end if;

  perform haulvia.assert_sensitive_authority(
    new.approved_by_profile_id,
    v_organization_id,
    v_permission_key,
    v_reauth_session_id,
    v_reason
  );

  return new;
end;
$$;

revoke all
  on function haulvia.enforce_publication_dual_control()
  from public;

-- ---------------------------------------------------------------------------
-- Publication guards
-- ---------------------------------------------------------------------------

create trigger p2a_policy_versions_approval_guard
before insert or update
on haulvia.policy_versions
for each row
execute function haulvia.enforce_publication_dual_control();


create trigger p2a_pricing_rule_versions_approval_guard
before insert or update
on haulvia.pricing_rule_versions
for each row
execute function haulvia.enforce_publication_dual_control();


create trigger p2a_partner_rate_card_versions_approval_guard
before insert or update
on haulvia.partner_rate_card_versions
for each row
execute function haulvia.enforce_publication_dual_control();


create trigger p2a_compliance_requirement_versions_approval_guard
before insert or update
on haulvia.compliance_requirement_versions
for each row
execute function haulvia.enforce_publication_dual_control();

-- ---------------------------------------------------------------------------
-- P2A.4B Financial-adjustment dual-control preparation
--
-- Phase 1 financial_adjustments remain append-only executed financial facts.
--
-- P2A adds an explicit approval-request / approval-decision layer for
-- adjustments that policy requires to receive second-person approval.
--
-- The existing D09 command remains compatible for adjustment classes that
-- do not require this additional approval step.
-- ---------------------------------------------------------------------------

create table haulvia.financial_adjustment_approval_requests (
  id uuid primary key default gen_random_uuid(),

  shipment_id uuid not null
    references haulvia.shipments(id),

  route_execution_id uuid
    references haulvia.route_executions(id),

  stop_execution_id uuid
    references haulvia.stop_executions(id),

  cargo_item_id uuid
    references haulvia.cargo_items(id),

  adjustment_type haulvia.financial_adjustment_type not null,

  amount numeric(14,2) not null,

  currency char(3) not null default 'CAD',

  reason text not null,

  policy_version_id uuid
    references haulvia.policy_versions(id),

  requested_by_profile_id uuid not null
    references haulvia.profiles(id),

  -- Exact retained authority/policy context used to request approval.
  authorization_snapshot jsonb not null,

  -- Explicit before/after values are retained so an approver cannot approve
  -- an ambiguous or subsequently rewritten financial proposal.
  before_value jsonb not null,
  proposed_after_value jsonb not null,

  idempotency_key text not null,

  requested_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),

  unique (shipment_id, idempotency_key),

  check (amount > 0),

  check (currency ~ '^[A-Z]{3}$'),

  check (length(btrim(reason)) >= 8),

  check (authorization_snapshot <> '{}'::jsonb),

  check (before_value <> '{}'::jsonb),

  check (proposed_after_value <> '{}'::jsonb)
);

comment on table haulvia.financial_adjustment_approval_requests is
  'Append-only proposed financial adjustments requiring an explicit '
  'second-person Haulvia decision before execution.';


create table haulvia.financial_adjustment_approval_decisions (
  id uuid primary key default gen_random_uuid(),

  approval_request_id uuid not null unique
    references haulvia.financial_adjustment_approval_requests(id),

  decision text not null
    check (decision in ('APPROVED', 'REJECTED')),

  organization_id uuid not null
    references haulvia.organizations(id),

  reviewed_by_profile_id uuid not null
    references haulvia.profiles(id),

  reauth_session_id uuid not null
    references haulvia.reauth_sessions(id),

  reason text not null,

  -- APPROVED decisions become usable only from this timestamp.
  effective_at timestamptz,

  before_value jsonb not null,
  after_value jsonb not null,

  decision_metadata jsonb not null default '{}'::jsonb,

  decided_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),

  check (length(btrim(reason)) >= 8),

  check (before_value <> '{}'::jsonb),

  check (after_value <> '{}'::jsonb),

  check (
    (decision = 'APPROVED' and effective_at is not null)
    or
    (decision = 'REJECTED' and effective_at is null)
  )
);

comment on table haulvia.financial_adjustment_approval_decisions is
  'Immutable second-person financial-adjustment approval or rejection. '
  'APPROVED decisions require Haulvia FINANCIAL_ADJUST authority, fresh '
  'reauthentication and creator/approver separation.';


-- ---------------------------------------------------------------------------
-- Request/decision records are immutable evidence.
-- ---------------------------------------------------------------------------

create trigger financial_adjustment_approval_requests_append_only
before update or delete
on haulvia.financial_adjustment_approval_requests
for each row
execute function haulvia.reject_append_only_mutation();


create trigger financial_adjustment_approval_decisions_append_only
before update or delete
on haulvia.financial_adjustment_approval_decisions
for each row
execute function haulvia.reject_append_only_mutation();


-- ---------------------------------------------------------------------------
-- Validate the second-person financial decision.
--
-- Both approval and rejection are Haulvia financial decisions and therefore
-- require FINANCIAL_ADJUST + fresh reauthentication + written reason.
--
-- APPROVAL additionally cannot be performed by the request creator.
-- ---------------------------------------------------------------------------

create or replace function haulvia.enforce_financial_adjustment_decision()
returns trigger
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_request haulvia.financial_adjustment_approval_requests%rowtype;
  v_organization_kind haulvia.organization_kind;
begin
  select *
    into v_request
  from haulvia.financial_adjustment_approval_requests far
  where far.id = new.approval_request_id;

  if not found then
    raise exception
      'Financial adjustment approval request % does not exist',
      new.approval_request_id
      using errcode = '23503';
  end if;

  select o.kind
    into v_organization_kind
  from haulvia.organizations o
  where o.id = new.organization_id;

  if v_organization_kind is distinct from 'HAULVIA' then
    raise exception
      'Financial adjustment decisions require a Haulvia organization context'
      using errcode = '42501';
  end if;

  if new.decision = 'APPROVED'
     and new.reviewed_by_profile_id = v_request.requested_by_profile_id
  then
    raise exception
      'A financial adjustment request may not be approved by its creator'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    new.reviewed_by_profile_id,
    new.organization_id,
    'FINANCIAL_ADJUST',
    new.reauth_session_id,
    new.reason
  );

  if new.before_value is distinct from v_request.before_value then
    raise exception
      'Financial adjustment decision before-value differs from the retained request'
      using errcode = '23514';
  end if;

  if new.decision = 'APPROVED' then

    if new.after_value is distinct from v_request.proposed_after_value then
      raise exception
        'Approved financial adjustment differs from the retained proposal'
        using errcode = '23514';
    end if;

  else

    -- A rejection leaves the proposed financial state unapplied.
    if new.after_value is distinct from v_request.before_value then
      raise exception
        'Rejected financial adjustment must preserve the prior financial state'
        using errcode = '23514';
    end if;

  end if;

  return new;
end;
$$;

revoke all
  on function haulvia.enforce_financial_adjustment_decision()
  from public;


create trigger financial_adjustment_approval_decisions_guard
before insert
on haulvia.financial_adjustment_approval_decisions
for each row
execute function haulvia.enforce_financial_adjustment_decision();


-- ---------------------------------------------------------------------------
-- Every approval/rejection receives immutable audit evidence.
-- ---------------------------------------------------------------------------

create or replace function haulvia.audit_financial_adjustment_decision()
returns trigger
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_request haulvia.financial_adjustment_approval_requests%rowtype;
begin
  select *
    into v_request
  from haulvia.financial_adjustment_approval_requests far
  where far.id = new.approval_request_id;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_schema,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    idempotency_key
  )
  values (
    'PROFILE',
    new.reviewed_by_profile_id,
    new.organization_id,

    case
      when new.decision = 'APPROVED'
        then 'approveFinancialAdjustmentRequest'
      else 'rejectFinancialAdjustmentRequest'
    end,

    'FINANCIAL_ADJUST',
    new.reauth_session_id,
    new.reason,
    'haulvia',
    'financial_adjustment_approval_requests',
    new.approval_request_id,
    new.before_value,
    new.after_value,

    coalesce(new.decision_metadata, '{}'::jsonb)
      || jsonb_build_object(
        'financialAdjustmentApprovalDecisionId', new.id,
        'decision', new.decision,
        'requestedByProfileId', v_request.requested_by_profile_id,
        'reviewedByProfileId', new.reviewed_by_profile_id,
        'effectiveAt', new.effective_at
      ),

    v_request.idempotency_key
  );

  return new;
end;
$$;

revoke all
  on function haulvia.audit_financial_adjustment_decision()
  from public;


create trigger financial_adjustment_approval_decisions_audit
after insert
on haulvia.financial_adjustment_approval_decisions
for each row
execute function haulvia.audit_financial_adjustment_decision();


-- ---------------------------------------------------------------------------
-- Optional execution link.
--
-- Existing Phase 1 D09 adjustments remain valid with NULL.
-- When a policy requires dual control, the future trusted command must supply
-- the APPROVED decision and this trigger verifies exact correspondence.
-- ---------------------------------------------------------------------------

alter table haulvia.financial_adjustments
  add column approval_decision_id uuid unique
    references haulvia.financial_adjustment_approval_decisions(id);


create or replace function haulvia.validate_financial_adjustment_approval_link()
returns trigger
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_decision haulvia.financial_adjustment_approval_decisions%rowtype;
  v_request haulvia.financial_adjustment_approval_requests%rowtype;
begin
  if new.approval_decision_id is null then
    return new;
  end if;

  select *
    into v_decision
  from haulvia.financial_adjustment_approval_decisions fad
  where fad.id = new.approval_decision_id;

  if not found or v_decision.decision <> 'APPROVED' then
    raise exception
      'Financial adjustment requires an APPROVED approval decision'
      using errcode = '42501';
  end if;

  if v_decision.effective_at > clock_timestamp() then
    raise exception
      'Financial adjustment approval is not yet effective'
      using errcode = '42501';
  end if;

  select *
    into v_request
  from haulvia.financial_adjustment_approval_requests far
  where far.id = v_decision.approval_request_id;

  if not found then
    raise exception
      'Financial adjustment approval request is missing'
      using errcode = '23503';
  end if;

  if new.shipment_id <> v_request.shipment_id
     or new.adjustment_type <> v_request.adjustment_type
     or new.amount <> v_request.amount
     or new.currency <> v_request.currency
     or new.route_execution_id is distinct from v_request.route_execution_id
     or new.stop_execution_id is distinct from v_request.stop_execution_id
     or new.cargo_item_id is distinct from v_request.cargo_item_id
     or new.policy_version_id is distinct from v_request.policy_version_id
  then
    raise exception
      'Executed financial adjustment does not match the approved request'
      using errcode = '23514';
  end if;

  if new.authorized_by_profile_id <> v_decision.reviewed_by_profile_id then
    raise exception
      'Executed financial adjustment approver does not match the retained approval'
      using errcode = '42501';
  end if;

  if new.reauth_session_id <> v_decision.reauth_session_id then
    raise exception
      'Executed financial adjustment reauthentication does not match the retained approval'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

revoke all
  on function haulvia.validate_financial_adjustment_approval_link()
  from public;


create trigger financial_adjustments_approval_link_guard
before insert
on haulvia.financial_adjustments
for each row
execute function haulvia.validate_financial_adjustment_approval_link();


-- ---------------------------------------------------------------------------
-- P2A function-execution cleanup
--
-- PostgreSQL grants EXECUTE on newly created functions to PUBLIC by default.
-- Revoke the P2A trigger/helper functions created earlier in this migration
-- so the seed migration introduces no public callable authority.
-- ---------------------------------------------------------------------------

revoke all
  on function haulvia.reject_worker_authority_role()
  from public;

revoke all
  on function haulvia.enforce_membership_role_organization_kind()
  from public;

revoke all
  on function haulvia.validate_platform_config_value()
  from public;

revoke all
  on function haulvia.enforce_publication_dual_control()
  from public;

-- ---------------------------------------------------------------------------
-- P2A.5 Seed manifest
-- ---------------------------------------------------------------------------

do $$
declare
  v_existing_sha text;
begin
  select sm.source_sha256
    into v_existing_sha
  from haulvia.seed_manifests sm
  where sm.seed_key = 'P2A_AUTHORITY_AND_SEED_CONTRACT'
    and sm.version_no = 1;

  if v_existing_sha is not null
     and lower(v_existing_sha)
       <> '9a5812be5fd19076ff339a87a05a30300dcf001aa765e613957430d44da45bdb'
  then
    raise exception
      'P2A seed manifest version 1 exists with conflicting SHA-256 %',
      v_existing_sha
      using errcode = '23514';
  end if;
end;
$$;


insert into haulvia.seed_manifests (
  seed_key,
  version_no,
  source_sha256,
  metadata
)
values (
  'P2A_AUTHORITY_AND_SEED_CONTRACT',
  1,
  '9a5812be5fd19076ff339a87a05a30300dcf001aa765e613957430d44da45bdb',
  jsonb_build_object(
    'contractFile',
      'docs/Haulvia_P2A_Authority_and_Seed_Contract_v1.md',
    'baselineCommit',
      'd901412',
    'migration',
      '20260830055339_haulvia_p2a_authority_and_config_seeds_v1.sql',
    'phase',
      'P2A',
    'scope',
      'AUTHORITY_AND_CONFIGURATION_SEEDS'
  )
)
on conflict (seed_key, version_no)
do nothing;


-- ---------------------------------------------------------------------------
-- P2A.5 Final authority/catalog assertions
--
-- These assertions deliberately run before COMMIT so any structural mismatch
-- rolls back the entire P2A migration.
-- ---------------------------------------------------------------------------

do $$
declare
  v_count integer;

  v_sensitive_permissions constant text[] := array[
    -- Existing specialized sensitive permissions
    'COMPLIANCE_REVIEW',
    'PRICING_MANAGE',
    'SHIPMENT_STATE_OVERRIDE',
    'CUSTODY_TRANSFER_AUTHORIZE',
    'DISPUTE_RESOLVE',
    'FINANCIAL_ADJUST',
    'PAYOUT_MANAGE',

    -- Customer organization
    'ORG_MEMBER_MANAGE',
    'BILLING_MANAGE',

    -- Courier provider
    'PROVIDER_PROFILE_MANAGE',
    'PROVIDER_MEMBER_MANAGE',
    'DRIVER_ROSTER_MANAGE',
    'VEHICLE_MANAGE',
    'RATE_CARD_SUBMIT',
    'PROVIDER_ASSIGNMENT_MANAGE',

    -- Haulvia staff
    'PLATFORM_CONFIGURATION_MANAGE',
    'SENSITIVE_DOCUMENT_VIEW',
    'AUDIT_EXPORT',
    'SECURITY_ACCESS_REVIEW',
    'POLICY_PUBLISH'
  ];

  v_worker_roles constant text[] := array[
    'ROUTE_OPERATIONS_WORKER',
    'TERMINAL_REPOST_WORKER',
    'CUSTODY_TRANSFER_WORKER',
    'RECOVERY_WORKER',
    'STORAGE_WORKER',
    'COMPLETION_WORKER',
    'PAYOUT_WORKER'
  ];

begin

  -- -------------------------------------------------------------------------
  -- 1. Approved human-role count
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from haulvia.roles r
  join p2a_role_seed s
    on s.role_key = r.role_key;

  if v_count <> 17 then
    raise exception
      'P2A expected 17 approved human roles; found %',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 2. Approved permission catalog contains exactly 50 distinct permissions.
  --
  -- The expected permission universe is derived from the approved role seed.
  -- -------------------------------------------------------------------------

  with expected_permissions as (
    select distinct requested.permission_key
    from p2a_role_seed s
    cross join lateral unnest(s.permission_keys)
      as requested(permission_key)
  )
  select count(*)
    into v_count
  from expected_permissions;

  if v_count <> 50 then
    raise exception
      'P2A expected 50 distinct approved permissions; role contract contains %',
      v_count
      using errcode = '23514';
  end if;


  with expected_permissions as (
    select distinct requested.permission_key
    from p2a_role_seed s
    cross join lateral unnest(s.permission_keys)
      as requested(permission_key)
  )
  select count(*)
    into v_count
  from expected_permissions ep
  join haulvia.permissions p
    on p.permission_key = ep.permission_key;

  if v_count <> 50 then
    raise exception
      'P2A expected all 50 approved permissions to exist; found %',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 3. Sensitivity classification must exactly match the approved contract.
  -- -------------------------------------------------------------------------

  with expected_permissions as (
    select distinct requested.permission_key
    from p2a_role_seed s
    cross join lateral unnest(s.permission_keys)
      as requested(permission_key)
  )
  select count(*)
    into v_count
  from expected_permissions ep
  join haulvia.permissions p
    on p.permission_key = ep.permission_key
  where p.is_sensitive
        <> (p.permission_key = any(v_sensitive_permissions));

  if v_count <> 0 then
    raise exception
      'P2A detected % permission sensitivity mismatch(es)',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 4. Every role has exactly its approved permission set.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_role_seed s
  join haulvia.roles r
    on r.role_key = s.role_key
  where (
    select count(*)
    from haulvia.role_permissions rp
    where rp.role_id = r.id
  ) <> cardinality(s.permission_keys);

  if v_count <> 0 then
    raise exception
      'P2A detected % role(s) with an incorrect permission count',
      v_count
      using errcode = '23514';
  end if;


  select count(*)
    into v_count
  from p2a_role_seed s
  join haulvia.roles r
    on r.role_key = s.role_key
  join haulvia.role_permissions rp
    on rp.role_id = r.id
  join haulvia.permissions p
    on p.id = rp.permission_id
  where not (p.permission_key = any(s.permission_keys));

  if v_count <> 0 then
    raise exception
      'P2A detected % unapproved role-permission mapping(s)',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 5. Every seeded human role has exactly one approved organization family.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_role_seed s
  join haulvia.roles r
    on r.role_key = s.role_key
  where (
    select count(*)
    from haulvia.role_organization_kinds rok
    where rok.role_id = r.id
  ) <> 1;

  if v_count <> 0 then
    raise exception
      'P2A detected % role(s) without exactly one organization-kind boundary',
      v_count
      using errcode = '23514';
  end if;


  select count(*)
    into v_count
  from p2a_role_seed s
  join haulvia.roles r
    on r.role_key = s.role_key
  join haulvia.role_organization_kinds rok
    on rok.role_id = r.id
  where rok.organization_kind <> s.organization_kind;

  if v_count <> 0 then
    raise exception
      'P2A detected % incompatible role organization-kind boundary/boundaries',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 6. Worker authority codes may never exist as human roles.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from haulvia.roles r
  where r.role_key = any(v_worker_roles);

  if v_count <> 0 then
    raise exception
      'P2A detected % backend worker authority code(s) installed as human roles',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 7. Customer/courier roles may not receive Haulvia administrative powers.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from haulvia.roles r
  join haulvia.role_permissions rp
    on rp.role_id = r.id
  join haulvia.permissions p
    on p.id = rp.permission_id
  where (
      r.role_key like 'BUSINESS\_%' escape '\'
      or r.role_key like 'COURIER\_%' escape '\'
    )
    and p.permission_key = any (
      array[
        'COMPLIANCE_REVIEW',
        'PRICING_MANAGE',
        'SHIPMENT_STATE_OVERRIDE',
        'CUSTODY_TRANSFER_AUTHORIZE',
        'DISPUTE_RESOLVE',
        'FINANCIAL_ADJUST',
        'ROUTE_OPERATIONS_MANAGE',
        'STOP_EVIDENCE_REVIEW',
        'PAYOUT_MANAGE',
        'PLATFORM_CONFIGURATION_VIEW',
        'PLATFORM_CONFIGURATION_MANAGE',
        'INTERNAL_SHIPMENT_VIEW',
        'INTERNAL_SHIPMENT_DOCUMENT_VIEW',
        'INTERNAL_PROVIDER_VIEW',
        'INTERNAL_PROVIDER_RATE_CARD_VIEW',
        'INTERNAL_PAYMENT_VIEW',
        'SENSITIVE_DOCUMENT_VIEW',
        'SUPPORT_CASE_MANAGE',
        'AUDIT_VIEW',
        'AUDIT_EXPORT',
        'SECURITY_ACCESS_REVIEW',
        'POLICY_PUBLISH'
      ]
    );

  if v_count <> 0 then
    raise exception
      'P2A detected % customer/courier administrative permission leak(s)',
      v_count
      using errcode = '42501';
  end if;


  -- -------------------------------------------------------------------------
  -- 8. Explicit negative-role assertions.
  -- -------------------------------------------------------------------------

  if exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key = 'SUPPORT_AGENT'
      and p.permission_key = 'SENSITIVE_DOCUMENT_VIEW'
  ) then
    raise exception
      'SUPPORT_AGENT must not receive SENSITIVE_DOCUMENT_VIEW'
      using errcode = '42501';
  end if;


  if exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key = 'COURIER_DISPATCHER'
      and p.permission_key = any (
        array[
          'RATE_CARD_DRAFT',
          'RATE_CARD_SUBMIT',
          'PRICING_MANAGE'
        ]
      )
  ) then
    raise exception
      'COURIER_DISPATCHER has prohibited rate-card authority'
      using errcode = '42501';
  end if;


  -- -------------------------------------------------------------------------
  -- 9. Platform-policy shell assertions.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_policy_seed s
  join haulvia.policy_sets ps
    on ps.policy_key = s.policy_key
  join haulvia.policy_versions pv
    on pv.policy_set_id = ps.id
   and pv.version_no = 1
  where pv.publication_status = 'DRAFT'
    and pv.effective_from is null
    and pv.effective_to is null
    and pv.config = '{}'::jsonb
    and lower(pv.config_sha256)
      = '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
    and pv.approved_by_profile_id is null
    and pv.approved_at is null;

  if v_count <> 8 then
    raise exception
      'P2A expected 8 non-effective policy shells; found %',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 10. Haulvia pricing shell assertions.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_pricing_rule_seed s
  join haulvia.pricing_rule_sets prs
    on prs.rule_key = s.rule_key
  join haulvia.pricing_rule_versions prv
    on prv.pricing_rule_set_id = prs.id
   and prv.version_no = 1
  where prv.publication_status = 'DRAFT'
    and prv.effective_from is null
    and prv.effective_to is null
    and prv.rule_config = '{}'::jsonb
    and lower(prv.rule_sha256)
      = '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
    and prv.approved_by_profile_id is null
    and prv.approved_at is null;

  if v_count <> 2 then
    raise exception
      'P2A expected 2 non-effective Haulvia pricing shells; found %',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 11. Canadian jurisdiction identities and empty tax shells.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_tax_jurisdiction_seed s
  join haulvia.tax_jurisdictions tj
    on tj.jurisdiction_key = s.jurisdiction_key;

  if v_count <> 14 then
    raise exception
      'P2A expected 14 Canadian tax jurisdiction identities; found %',
      v_count
      using errcode = '23514';
  end if;


  select count(*)
    into v_count
  from p2a_tax_jurisdiction_seed s
  join haulvia.tax_jurisdictions tj
    on tj.jurisdiction_key = s.jurisdiction_key
  join haulvia.tax_rule_versions trv
    on trv.jurisdiction_id = tj.id
   and trv.version_no = 1
  where trv.publication_status = 'DRAFT'
    and trv.effective_from is null
    and trv.effective_to is null
    and trv.rule_config = '{}'::jsonb
    and lower(trv.rule_sha256)
      = '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a'
    and trv.approved_by_profile_id is null
    and trv.approved_at is null;

  if v_count <> 14 then
    raise exception
      'P2A expected 14 empty Canadian tax-rule shells; found %',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 12. Compliance categories only; no fake requirement rows.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_compliance_category_seed s
  join haulvia.compliance_requirement_categories crc
    on crc.category_key = s.category_key
   and crc.subject_kind = s.subject_kind;

  if v_count <> 4 then
    raise exception
      'P2A expected 4 compliance catalog categories; found %',
      v_count
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 13. Typed configuration definitions exist with zero seeded values.
  -- -------------------------------------------------------------------------

  select count(*)
    into v_count
  from p2a_platform_config_seed s
  join haulvia.platform_config_definitions pcd
    on pcd.config_key = s.config_key
   and pcd.category_key = s.category_key
   and pcd.value_type = s.value_type
   and pcd.unit_key is not distinct from s.unit_key
   and pcd.is_sensitive = s.is_sensitive;

  if v_count <> 23 then
    raise exception
      'P2A expected 23 typed platform configuration definitions; found %',
      v_count
      using errcode = '23514';
  end if;


  select count(*)
    into v_count
  from haulvia.platform_config_versions pcv
  join haulvia.platform_config_definitions pcd
    on pcd.id = pcv.config_definition_id
  join p2a_platform_config_seed s
    on s.config_key = pcd.config_key;

  if v_count <> 0 then
    raise exception
      'P2A configuration definitions must not contain seeded production values'
      using errcode = '23514';
  end if;


  -- -------------------------------------------------------------------------
  -- 14. Seed manifest evidence must match the approved contract digest.
  -- -------------------------------------------------------------------------

  if not exists (
    select 1
    from haulvia.seed_manifests sm
    where sm.seed_key = 'P2A_AUTHORITY_AND_SEED_CONTRACT'
      and sm.version_no = 1
      and lower(sm.source_sha256)
        = '9a5812be5fd19076ff339a87a05a30300dcf001aa765e613957430d44da45bdb'
  ) then
    raise exception
      'P2A seed manifest evidence is missing or incorrect'
      using errcode = '23514';
  end if;

end;
$$;


-- ---------------------------------------------------------------------------
-- P2A.5 Final function-execution security sweep
--
-- PostgreSQL grants EXECUTE to PUBLIC by default for newly created functions.
-- Every P2A helper/trigger function must have that default removed.
-- No explicit anon/authenticated grant is introduced by this migration.
-- ---------------------------------------------------------------------------

revoke all
  on function haulvia.reject_worker_authority_role()
  from public;

revoke all
  on function haulvia.enforce_membership_role_organization_kind()
  from public;

revoke all
  on function haulvia.validate_platform_config_value()
  from public;

revoke all
  on function haulvia.enforce_publication_dual_control()
  from public;

revoke all
  on function haulvia.enforce_financial_adjustment_decision()
  from public;

revoke all
  on function haulvia.audit_financial_adjustment_decision()
  from public;

revoke all
  on function haulvia.validate_financial_adjustment_approval_link()
  from public;


do $$
declare
  v_public_function_grants integer;
begin
  select count(*)
    into v_public_function_grants
  from information_schema.routine_privileges rp
  where rp.routine_schema = 'haulvia'
    and rp.routine_name = any (
      array[
        'reject_worker_authority_role',
        'enforce_membership_role_organization_kind',
        'validate_platform_config_value',
        'enforce_publication_dual_control',
        'enforce_financial_adjustment_decision',
        'audit_financial_adjustment_decision',
        'validate_financial_adjustment_approval_link'
      ]
    )
    and rp.grantee in (
      'PUBLIC',
      'anon',
      'authenticated'
    );

  if v_public_function_grants <> 0 then
    raise exception
      'P2A detected % prohibited PUBLIC/anon/authenticated function grant(s)',
      v_public_function_grants
      using errcode = '42501';
  end if;
end;
$$;


-- ---------------------------------------------------------------------------
-- P2A migration complete.
--
-- Effective prices, tax rates, operational durations, compliance requirements,
-- legal rules and production configuration values remain deliberately absent.
-- ---------------------------------------------------------------------------

commit;