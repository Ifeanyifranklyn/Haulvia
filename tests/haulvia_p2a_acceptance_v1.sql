-- Haulvia Phase 2 Block P2A acceptance suite v1
--
-- Requires:
--   Foundation v1
--   Blocks A-E command migrations v1
--   P2A authority and configuration seed migration v1
--
-- Pure PostgreSQL. No pgTAP dependency.
-- All acceptance fixtures are rolled back.
--
-- Run only against a disposable/local test database with ON_ERROR_STOP=1.

begin;

set local search_path = haulvia, public;

-- ---------------------------------------------------------------------------
-- Acceptance helpers
-- ---------------------------------------------------------------------------

create temporary table p2a_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text
) on commit drop;


create or replace function pg_temp.assert_true(
  p_test_name text,
  p_condition boolean,
  p_detail text default null
)
returns void
language plpgsql
as $$
begin
  if p_condition is distinct from true then
    raise exception
      'P2A TEST FAILED: % (%)',
      p_test_name,
      coalesce(p_detail, 'condition was not true')
      using errcode = 'P0001';
  end if;

  insert into pg_temp.p2a_test_results (
    test_name,
    passed,
    detail
  )
  values (
    p_test_name,
    true,
    p_detail
  );
end;
$$;


create or replace function pg_temp.expect_error(
  p_test_name text,
  p_sql text,
  p_expected_sqlstate text default null,
  p_message_fragment text default null
)
returns void
language plpgsql
as $$
declare
  v_caught boolean := false;
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;

  exception when others then
    v_caught := true;

    get stacked diagnostics
      v_state = returned_sqlstate,
      v_message = message_text;
  end;

  if not v_caught then
    raise exception
      'P2A TEST FAILED: % (expected an error)',
      p_test_name
      using errcode = 'P0001';
  end if;

  if p_expected_sqlstate is not null
     and v_state <> p_expected_sqlstate
  then
    raise exception
      'P2A TEST FAILED: % (expected SQLSTATE %, received %: %)',
      p_test_name,
      p_expected_sqlstate,
      v_state,
      v_message
      using errcode = 'P0001';
  end if;

  if p_message_fragment is not null
     and position(
       lower(p_message_fragment)
       in lower(coalesce(v_message, ''))
     ) = 0
  then
    raise exception
      'P2A TEST FAILED: % (message did not contain "%": %)',
      p_test_name,
      p_message_fragment,
      v_message
      using errcode = 'P0001';
  end if;

  insert into pg_temp.p2a_test_results (
    test_name,
    passed,
    detail
  )
  values (
    p_test_name,
    true,
    coalesce(v_state, '') || ': ' || coalesce(v_message, '')
  );
end;
$$;


-- ---------------------------------------------------------------------------
-- Approved role contract used only by this rollback-only acceptance suite.
-- ---------------------------------------------------------------------------

create temporary table p2a_expected_roles (
  role_key text primary key,
  organization_kind haulvia.organization_kind not null,
  permission_keys text[] not null
) on commit drop;


insert into p2a_expected_roles (
  role_key,
  organization_kind,
  permission_keys
)
values

  -- Customer organization
  (
    'BUSINESS_OWNER',
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
    'CUSTOMER',
    array[
      'SHIPMENT_VIEW',
      'BILLING_VIEW',
      'SHIPMENT_DOCUMENT_VIEW',
      'ORG_AUDIT_VIEW'
    ]
  ),

  -- Courier partner
  (
    'COURIER_OWNER',
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
    'COURIER_PARTNER',
    array[
      'PROVIDER_PROFILE_VIEW',
      'DRIVER_ROSTER_VIEW',
      'VEHICLE_VIEW',
      'PROVIDER_ASSIGNMENT_VIEW',
      'PROVIDER_DOCUMENT_UPLOAD'
    ]
  ),

  -- Haulvia operating organization
  (
    'PLATFORM_ADMIN',
    'HAULVIA',
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
  ),

  (
    'OPERATIONS_MANAGER',
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


-- Materialize the exact approved role-permission relation.

create temporary table p2a_expected_role_permissions
on commit drop
as
select
  er.role_key,
  requested.permission_key
from p2a_expected_roles er
cross join lateral unnest(er.permission_keys)
  as requested(permission_key);


-- Materialize the complete 50-permission approved catalog.

create temporary table p2a_expected_permissions
on commit drop
as
select distinct
  permission_key
from p2a_expected_role_permissions;


-- ---------------------------------------------------------------------------
-- TEST 1
-- Every approved role and permission exists exactly once.
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2A has 17 approved human role definitions',
  (
    select count(*)
    from p2a_expected_roles
  ) = 17
);


select pg_temp.assert_true(
  'all 17 approved human roles exist exactly once',
  (
    select count(*)
    from haulvia.roles r
    join p2a_expected_roles er
      on er.role_key = r.role_key
  ) = 17
);


select pg_temp.assert_true(
  'P2A contract contains 50 distinct permissions',
  (
    select count(*)
    from p2a_expected_permissions
  ) = 50
);


select pg_temp.assert_true(
  'all 50 approved permissions exist exactly once',
  (
    select count(*)
    from haulvia.permissions p
    join p2a_expected_permissions ep
      on ep.permission_key = p.permission_key
  ) = 50
);


select pg_temp.assert_true(
  'no approved role is missing from the database',
  not exists (
    select er.role_key
    from p2a_expected_roles er

    except

    select r.role_key
    from haulvia.roles r
  )
);


select pg_temp.assert_true(
  'no approved permission is missing from the database',
  not exists (
    select ep.permission_key
    from p2a_expected_permissions ep

    except

    select p.permission_key
    from haulvia.permissions p
  )
);


-- ---------------------------------------------------------------------------
-- TEST 2
-- Every seeded role has exactly the approved permission set.
--
-- This performs a symmetric-difference check:
--   expected EXCEPT actual
--   actual   EXCEPT expected
--
-- Either direction returning a row is a failure.
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'no approved role-permission mapping is missing',
  not exists (
    select
      erp.role_key,
      erp.permission_key
    from p2a_expected_role_permissions erp

    except

    select
      r.role_key,
      p.permission_key
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    join p2a_expected_roles er
      on er.role_key = r.role_key
  )
);


select pg_temp.assert_true(
  'no approved role contains an extra permission',
  not exists (
    select
      r.role_key,
      p.permission_key
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    join p2a_expected_roles er
      on er.role_key = r.role_key

    except

    select
      erp.role_key,
      erp.permission_key
    from p2a_expected_role_permissions erp
  )
);


select pg_temp.assert_true(
  'every approved role has exactly its approved mapping count',
  not exists (
    select 1
    from p2a_expected_roles er
    join haulvia.roles r
      on r.role_key = er.role_key
    where (
      select count(*)
      from haulvia.role_permissions rp
      where rp.role_id = r.id
    ) <> cardinality(er.permission_keys)
  )
);


-- ---------------------------------------------------------------------------
-- TEST 3
-- Backend worker authorities never exist as human roles.
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'no backend worker authority exists as a human role',
  not exists (
    select 1
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
  )
);


select pg_temp.assert_true(
  'no membership can reference a backend worker authority role',
  not exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
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
  )
);

-- ---------------------------------------------------------------------------
-- TEST 4
-- Role assignment across an incompatible organization kind fails.
-- Also prove that a compatible role assignment succeeds.
-- ---------------------------------------------------------------------------

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values
  (
    'a2a00000-0000-0000-0000-000000000001',
    'p2a-test-customer',
    'CUSTOMER',
    'P2A Test Customer Ltd.',
    'P2A Test Customer'
  ),
  (
    'a2a00000-0000-0000-0000-000000000002',
    'p2a-test-independent-provider',
    'INDEPENDENT_PROVIDER',
    'P2A Test Independent Provider Ltd.',
    'P2A Test Independent Provider'
  );


insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'a2a00000-0000-0000-0000-000000000011',
    'P2A Test Customer User'
  ),
  (
    'a2a00000-0000-0000-0000-000000000012',
    'P2A Test Independent Provider User'
  );


insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status
)
values
  (
    'a2a00000-0000-0000-0000-000000000021',
    'a2a00000-0000-0000-0000-000000000001',
    'a2a00000-0000-0000-0000-000000000011',
    'ACTIVE'
  ),
  (
    'a2a00000-0000-0000-0000-000000000022',
    'a2a00000-0000-0000-0000-000000000002',
    'a2a00000-0000-0000-0000-000000000012',
    'ACTIVE'
  );


-- CUSTOMER membership must reject a COURIER role.

select pg_temp.expect_error(
  'CUSTOMER membership rejects COURIER_DISPATCHER',
  $sql$
    insert into haulvia.membership_roles (
      membership_id,
      role_id
    )
    select
      'a2a00000-0000-0000-0000-000000000021'::uuid,
      r.id
    from haulvia.roles r
    where r.role_key = 'COURIER_DISPATCHER'
  $sql$,
  '42501'
);


-- INDEPENDENT_PROVIDER receives no synthetic human membership role.

select pg_temp.expect_error(
  'INDEPENDENT_PROVIDER membership rejects BUSINESS_VIEWER',
  $sql$
    insert into haulvia.membership_roles (
      membership_id,
      role_id
    )
    select
      'a2a00000-0000-0000-0000-000000000022'::uuid,
      r.id
    from haulvia.roles r
    where r.role_key = 'BUSINESS_VIEWER'
  $sql$,
  '42501'
);


-- A correct CUSTOMER -> BUSINESS role mapping must still succeed.

insert into haulvia.membership_roles (
  membership_id,
  role_id
)
select
  'a2a00000-0000-0000-0000-000000000021'::uuid,
  r.id
from haulvia.roles r
where r.role_key = 'BUSINESS_VIEWER';


select pg_temp.assert_true(
  'compatible CUSTOMER to BUSINESS role assignment succeeds',
  exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id
      = 'a2a00000-0000-0000-0000-000000000021'::uuid
      and r.role_key = 'BUSINESS_VIEWER'
  )
);


-- ---------------------------------------------------------------------------
-- TEST 5
-- No customer or courier role receives a Haulvia administrative permission.
-- ---------------------------------------------------------------------------

create temporary table p2a_haulvia_admin_permissions (
  permission_key text primary key
) on commit drop;


insert into p2a_haulvia_admin_permissions (
  permission_key
)
values
  ('COMPLIANCE_REVIEW'),
  ('PRICING_MANAGE'),
  ('SHIPMENT_STATE_OVERRIDE'),
  ('CUSTODY_TRANSFER_AUTHORIZE'),
  ('DISPUTE_RESOLVE'),
  ('FINANCIAL_ADJUST'),
  ('ROUTE_OPERATIONS_MANAGE'),
  ('STOP_EVIDENCE_REVIEW'),
  ('PAYOUT_MANAGE'),
  ('PLATFORM_CONFIGURATION_VIEW'),
  ('PLATFORM_CONFIGURATION_MANAGE'),
  ('INTERNAL_SHIPMENT_VIEW'),
  ('INTERNAL_SHIPMENT_DOCUMENT_VIEW'),
  ('INTERNAL_PROVIDER_VIEW'),
  ('INTERNAL_PROVIDER_RATE_CARD_VIEW'),
  ('INTERNAL_PAYMENT_VIEW'),
  ('SENSITIVE_DOCUMENT_VIEW'),
  ('SUPPORT_CASE_MANAGE'),
  ('AUDIT_VIEW'),
  ('AUDIT_EXPORT'),
  ('SECURITY_ACCESS_REVIEW'),
  ('POLICY_PUBLISH');


select pg_temp.assert_true(
  'customer and courier roles contain no Haulvia administrative permissions',
  not exists (
    select 1
    from p2a_expected_roles er
    join haulvia.roles r
      on r.role_key = er.role_key
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    join p2a_haulvia_admin_permissions hap
      on hap.permission_key = p.permission_key
    where er.organization_kind in (
      'CUSTOMER',
      'COURIER_PARTNER'
    )
  )
);


-- Explicitly ensure customer roles cannot publish policy/pricing.

select pg_temp.assert_true(
  'customer roles have no platform publication authority',
  not exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key like 'BUSINESS\_%' escape '\'
      and p.permission_key in (
        'PRICING_MANAGE',
        'POLICY_PUBLISH',
        'PLATFORM_CONFIGURATION_MANAGE'
      )
  )
);


-- Explicitly ensure courier roles cannot approve/publish Haulvia pricing.

select pg_temp.assert_true(
  'courier roles have no Haulvia pricing publication authority',
  not exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key like 'COURIER\_%' escape '\'
      and p.permission_key = 'PRICING_MANAGE'
  )
);


-- ---------------------------------------------------------------------------
-- TEST 6
-- SUPPORT_AGENT must not receive protected-document authority.
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'SUPPORT_AGENT lacks SENSITIVE_DOCUMENT_VIEW',
  not exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key = 'SUPPORT_AGENT'
      and p.permission_key = 'SENSITIVE_DOCUMENT_VIEW'
  )
);


select pg_temp.assert_true(
  'SUPPORT_AGENT retains ordinary support authority',
  exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key = 'SUPPORT_AGENT'
      and p.permission_key = 'SUPPORT_CASE_MANAGE'
  )
);


-- ---------------------------------------------------------------------------
-- TEST 7
-- COURIER_DISPATCHER may view rates but cannot draft, submit, approve or
-- publish them.
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'COURIER_DISPATCHER retains RATE_CARD_VIEW',
  exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key = 'COURIER_DISPATCHER'
      and p.permission_key = 'RATE_CARD_VIEW'
  )
);


select pg_temp.assert_true(
  'COURIER_DISPATCHER lacks rate-card draft submit and publication authority',
  not exists (
    select 1
    from haulvia.roles r
    join haulvia.role_permissions rp
      on rp.role_id = r.id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where r.role_key = 'COURIER_DISPATCHER'
      and p.permission_key in (
        'RATE_CARD_DRAFT',
        'RATE_CARD_SUBMIT',
        'PRICING_MANAGE'
      )
  )
);


-- ---------------------------------------------------------------------------
-- TEST 8
-- Permission sensitivity classification exactly matches the approved contract.
--
-- There are 20 sensitive permissions in the complete 50-permission P2A
-- catalog. Every other approved permission must remain non-sensitive.
-- ---------------------------------------------------------------------------

create temporary table p2a_expected_sensitive_permissions (
  permission_key text primary key
) on commit drop;


insert into p2a_expected_sensitive_permissions (
  permission_key
)
values

  -- Existing Phase 1 sensitive permissions
  ('COMPLIANCE_REVIEW'),
  ('PRICING_MANAGE'),
  ('SHIPMENT_STATE_OVERRIDE'),
  ('CUSTODY_TRANSFER_AUTHORIZE'),
  ('DISPUTE_RESOLVE'),
  ('FINANCIAL_ADJUST'),
  ('PAYOUT_MANAGE'),

  -- Customer organization
  ('ORG_MEMBER_MANAGE'),
  ('BILLING_MANAGE'),

  -- Courier provider
  ('PROVIDER_PROFILE_MANAGE'),
  ('PROVIDER_MEMBER_MANAGE'),
  ('DRIVER_ROSTER_MANAGE'),
  ('VEHICLE_MANAGE'),
  ('RATE_CARD_SUBMIT'),
  ('PROVIDER_ASSIGNMENT_MANAGE'),

  -- Haulvia staff
  ('PLATFORM_CONFIGURATION_MANAGE'),
  ('SENSITIVE_DOCUMENT_VIEW'),
  ('AUDIT_EXPORT'),
  ('SECURITY_ACCESS_REVIEW'),
  ('POLICY_PUBLISH');


select pg_temp.assert_true(
  'approved contract contains 20 sensitive permissions',
  (
    select count(*)
    from p2a_expected_sensitive_permissions
  ) = 20
);


select pg_temp.assert_true(
  'all 20 approved sensitive permissions are marked sensitive',
  (
    select count(*)
    from haulvia.permissions p
    join p2a_expected_sensitive_permissions esp
      on esp.permission_key = p.permission_key
    where p.is_sensitive = true
  ) = 20
);


select pg_temp.assert_true(
  'no approved non-sensitive permission is marked sensitive',
  not exists (
    select 1
    from p2a_expected_permissions ep
    join haulvia.permissions p
      on p.permission_key = ep.permission_key
    left join p2a_expected_sensitive_permissions esp
      on esp.permission_key = ep.permission_key
    where esp.permission_key is null
      and p.is_sensitive = true
  )
);


select pg_temp.assert_true(
  'existing ROUTE_OPERATIONS_MANAGE remains non-sensitive',
  exists (
    select 1
    from haulvia.permissions p
    where p.permission_key = 'ROUTE_OPERATIONS_MANAGE'
      and p.is_sensitive = false
  )
);


select pg_temp.assert_true(
  'existing STOP_EVIDENCE_REVIEW remains non-sensitive',
  exists (
    select 1
    from haulvia.permissions p
    where p.permission_key = 'STOP_EVIDENCE_REVIEW'
      and p.is_sensitive = false
  )
);


select pg_temp.assert_true(
  'existing sensitive Phase 1 permissions remain sensitive',
  not exists (
    select 1
    from haulvia.permissions p
    where p.permission_key in (
      'COMPLIANCE_REVIEW',
      'PRICING_MANAGE',
      'SHIPMENT_STATE_OVERRIDE',
      'CUSTODY_TRANSFER_AUTHORIZE',
      'DISPUTE_RESOLVE',
      'FINANCIAL_ADJUST',
      'PAYOUT_MANAGE'
    )
      and p.is_sensitive = false
  )
);

-- ---------------------------------------------------------------------------
-- TEST 9
-- Repeat deterministic seed-data execution is idempotent.
--
-- The schema migration itself is one-time DDL. This test replays the
-- natural-key seed operations and proves that no duplicate catalog,
-- authority, version-shell or manifest rows are created.
-- ---------------------------------------------------------------------------

create temporary table p2a_seed_counts_before (
  seed_area text primary key,
  row_count bigint not null
) on commit drop;


insert into p2a_seed_counts_before (
  seed_area,
  row_count
)

select
  'roles',
  count(*)
from haulvia.roles r
join p2a_expected_roles er
  on er.role_key = r.role_key

union all

select
  'permissions',
  count(*)
from haulvia.permissions p
join p2a_expected_permissions ep
  on ep.permission_key = p.permission_key

union all

select
  'role_permissions',
  count(*)
from haulvia.role_permissions rp
join haulvia.roles r
  on r.id = rp.role_id
join p2a_expected_roles er
  on er.role_key = r.role_key

union all

select
  'role_organization_kinds',
  count(*)
from haulvia.role_organization_kinds rok
join haulvia.roles r
  on r.id = rok.role_id
join p2a_expected_roles er
  on er.role_key = r.role_key

union all

select
  'policy_sets',
  count(*)
from haulvia.policy_sets ps
where ps.policy_key = any (
  array[
    'MARKETPLACE_POLICY',
    'NEGOTIATION_POLICY',
    'CANCELLATION_POLICY',
    'EVIDENCE_POD_POLICY',
    'CUSTODY_POLICY',
    'RECEIVER_REVIEW_POLICY',
    'PAYOUT_DISPUTE_POLICY',
    'RETENTION_POLICY'
  ]
)

union all

select
  'policy_versions',
  count(*)
from haulvia.policy_versions pv
join haulvia.policy_sets ps
  on ps.id = pv.policy_set_id
where ps.policy_key = any (
  array[
    'MARKETPLACE_POLICY',
    'NEGOTIATION_POLICY',
    'CANCELLATION_POLICY',
    'EVIDENCE_POD_POLICY',
    'CUSTODY_POLICY',
    'RECEIVER_REVIEW_POLICY',
    'PAYOUT_DISPUTE_POLICY',
    'RETENTION_POLICY'
  ]
)
and pv.version_no = 1

union all

select
  'pricing_rule_sets',
  count(*)
from haulvia.pricing_rule_sets prs
where prs.rule_key in (
  'HAULVIA_FLEX_GUARDRAIL_CAD',
  'HAULVIA_EXPEDITED_FIXED_CAD'
)

union all

select
  'pricing_rule_versions',
  count(*)
from haulvia.pricing_rule_versions prv
join haulvia.pricing_rule_sets prs
  on prs.id = prv.pricing_rule_set_id
where prs.rule_key in (
  'HAULVIA_FLEX_GUARDRAIL_CAD',
  'HAULVIA_EXPEDITED_FIXED_CAD'
)
and prv.version_no = 1

union all

select
  'tax_jurisdictions',
  count(*)
from haulvia.tax_jurisdictions tj
where tj.jurisdiction_key = any (
  array[
    'CA_FEDERAL',
    'CA_AB',
    'CA_BC',
    'CA_MB',
    'CA_NB',
    'CA_NL',
    'CA_NS',
    'CA_ON',
    'CA_PE',
    'CA_QC',
    'CA_SK',
    'CA_NT',
    'CA_NU',
    'CA_YT'
  ]
)

union all

select
  'tax_rule_versions',
  count(*)
from haulvia.tax_rule_versions trv
join haulvia.tax_jurisdictions tj
  on tj.id = trv.jurisdiction_id
where tj.jurisdiction_key = any (
  array[
    'CA_FEDERAL',
    'CA_AB',
    'CA_BC',
    'CA_MB',
    'CA_NB',
    'CA_NL',
    'CA_NS',
    'CA_ON',
    'CA_PE',
    'CA_QC',
    'CA_SK',
    'CA_NT',
    'CA_NU',
    'CA_YT'
  ]
)
and trv.version_no = 1

union all

select
  'compliance_requirement_categories',
  count(*)
from haulvia.compliance_requirement_categories crc
where crc.category_key in (
  'APPLICATION_REQUIREMENTS',
  'PROVIDER_REQUIREMENTS',
  'DRIVER_REQUIREMENTS',
  'VEHICLE_REQUIREMENTS'
)

union all

select
  'platform_config_definitions',
  count(*)
from haulvia.platform_config_definitions pcd
where pcd.config_key = any (
  array[
    'SECURITY_SESSION_MAX_AGE_SECONDS',
    'SECURITY_SESSION_IDLE_TIMEOUT_SECONDS',
    'SECURITY_REAUTH_MAX_AGE_SECONDS',
    'MARKETPLACE_ASAP_LISTING_EXPIRY_SECONDS',
    'MARKETPLACE_SCHEDULED_LISTING_EXPIRY_SECONDS',
    'OFFER_RESPONSE_TIMEOUT_SECONDS',
    'COUNTER_RESPONSE_TIMEOUT_SECONDS',
    'OFFER_RESERVATION_TIMEOUT_SECONDS',
    'RECEIVER_CONFIRMATION_WINDOW_SECONDS',
    'DELIVERY_RESOLUTION_MINIMUM_SECONDS',
    'UPLOAD_MAX_FILE_BYTES',
    'UPLOAD_MAX_FILES_PER_REQUEST',
    'UPLOAD_ALLOWED_MEDIA_TYPES',
    'NOTIFICATION_RETRY_MAX_ATTEMPTS',
    'NOTIFICATION_RETRY_BACKOFF_SECONDS',
    'NOTIFICATION_ESCALATION_DELAY_SECONDS',
    'CUSTOMER_ASSIGNMENT_GRACE_SECONDS',
    'DRIVER_START_DEADLINE_SECONDS',
    'LATE_ARRIVAL_THRESHOLD_SECONDS',
    'NO_SHOW_THRESHOLD_SECONDS',
    'PICKUP_FREE_WAIT_SECONDS',
    'PICKUP_GEOFENCE_RADIUS_METRES',
    'DELIVERY_GEOFENCE_RADIUS_METRES'
  ]
)

union all

select
  'seed_manifest',
  count(*)
from haulvia.seed_manifests sm
where sm.seed_key = 'P2A_AUTHORITY_AND_SEED_CONTRACT'
  and sm.version_no = 1;


-- ---------------------------------------------------------------------------
-- Replay the authority natural-key seeds.
-- ---------------------------------------------------------------------------

insert into haulvia.roles (
  role_key,
  name,
  description
)
select
  r.role_key,
  r.name,
  r.description
from haulvia.roles r
join p2a_expected_roles er
  on er.role_key = r.role_key
on conflict (role_key)
do update set
  name = excluded.name,
  description = excluded.description;


insert into haulvia.permissions (
  permission_key,
  description,
  is_sensitive
)
select
  p.permission_key,
  p.description,
  p.is_sensitive
from haulvia.permissions p
join p2a_expected_permissions ep
  on ep.permission_key = p.permission_key
on conflict (permission_key)
do update set
  description = excluded.description,
  is_sensitive = excluded.is_sensitive;


insert into haulvia.role_organization_kinds (
  role_id,
  organization_kind
)
select
  r.id,
  er.organization_kind
from p2a_expected_roles er
join haulvia.roles r
  on r.role_key = er.role_key
on conflict (role_id, organization_kind)
do nothing;


insert into haulvia.role_permissions (
  role_id,
  permission_id
)
select
  r.id,
  p.id
from p2a_expected_role_permissions erp
join haulvia.roles r
  on r.role_key = erp.role_key
join haulvia.permissions p
  on p.permission_key = erp.permission_key
on conflict (role_id, permission_id)
do nothing;


-- ---------------------------------------------------------------------------
-- Replay policy shells.
-- ---------------------------------------------------------------------------

insert into haulvia.policy_sets (
  policy_key,
  name,
  description
)
select
  ps.policy_key,
  ps.name,
  ps.description
from haulvia.policy_sets ps
where ps.policy_key = any (
  array[
    'MARKETPLACE_POLICY',
    'NEGOTIATION_POLICY',
    'CANCELLATION_POLICY',
    'EVIDENCE_POD_POLICY',
    'CUSTODY_POLICY',
    'RECEIVER_REVIEW_POLICY',
    'PAYOUT_DISPUTE_POLICY',
    'RETENTION_POLICY'
  ]
)
on conflict (policy_key)
do update set
  name = excluded.name,
  description = excluded.description;


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
from haulvia.policy_sets ps
where ps.policy_key = any (
  array[
    'MARKETPLACE_POLICY',
    'NEGOTIATION_POLICY',
    'CANCELLATION_POLICY',
    'EVIDENCE_POD_POLICY',
    'CUSTODY_POLICY',
    'RECEIVER_REVIEW_POLICY',
    'PAYOUT_DISPUTE_POLICY',
    'RETENTION_POLICY'
  ]
)
and not exists (
  select 1
  from haulvia.policy_versions pv
  where pv.policy_set_id = ps.id
    and pv.version_no = 1
);


-- ---------------------------------------------------------------------------
-- Replay pricing shells.
-- ---------------------------------------------------------------------------

insert into haulvia.pricing_rule_sets (
  rule_key,
  name,
  pricing_source,
  service_level,
  currency
)
select
  prs.rule_key,
  prs.name,
  prs.pricing_source,
  prs.service_level,
  prs.currency
from haulvia.pricing_rule_sets prs
where prs.rule_key in (
  'HAULVIA_FLEX_GUARDRAIL_CAD',
  'HAULVIA_EXPEDITED_FIXED_CAD'
)
on conflict (rule_key)
do update set
  name = excluded.name;


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
from haulvia.pricing_rule_sets prs
where prs.rule_key in (
  'HAULVIA_FLEX_GUARDRAIL_CAD',
  'HAULVIA_EXPEDITED_FIXED_CAD'
)
and not exists (
  select 1
  from haulvia.pricing_rule_versions prv
  where prv.pricing_rule_set_id = prs.id
    and prv.version_no = 1
);


-- ---------------------------------------------------------------------------
-- Replay Canadian jurisdiction/tax shells.
-- ---------------------------------------------------------------------------

insert into haulvia.tax_jurisdictions (
  jurisdiction_key,
  country_code,
  subdivision_code,
  jurisdiction_level,
  name
)
select
  tj.jurisdiction_key,
  tj.country_code,
  tj.subdivision_code,
  tj.jurisdiction_level,
  tj.name
from haulvia.tax_jurisdictions tj
where tj.jurisdiction_key = any (
  array[
    'CA_FEDERAL',
    'CA_AB',
    'CA_BC',
    'CA_MB',
    'CA_NB',
    'CA_NL',
    'CA_NS',
    'CA_ON',
    'CA_PE',
    'CA_QC',
    'CA_SK',
    'CA_NT',
    'CA_NU',
    'CA_YT'
  ]
)
on conflict (jurisdiction_key)
do update set
  name = excluded.name;


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
from haulvia.tax_jurisdictions tj
where tj.jurisdiction_key = any (
  array[
    'CA_FEDERAL',
    'CA_AB',
    'CA_BC',
    'CA_MB',
    'CA_NB',
    'CA_NL',
    'CA_NS',
    'CA_ON',
    'CA_PE',
    'CA_QC',
    'CA_SK',
    'CA_NT',
    'CA_NU',
    'CA_YT'
  ]
)
and not exists (
  select 1
  from haulvia.tax_rule_versions trv
  where trv.jurisdiction_id = tj.id
    and trv.version_no = 1
);


-- ---------------------------------------------------------------------------
-- Replay compliance-category shells.
-- ---------------------------------------------------------------------------

insert into haulvia.compliance_requirement_categories (
  category_key,
  subject_kind,
  name,
  description
)
select
  crc.category_key,
  crc.subject_kind,
  crc.name,
  crc.description
from haulvia.compliance_requirement_categories crc
where crc.category_key in (
  'APPLICATION_REQUIREMENTS',
  'PROVIDER_REQUIREMENTS',
  'DRIVER_REQUIREMENTS',
  'VEHICLE_REQUIREMENTS'
)
on conflict (category_key)
do update set
  name = excluded.name,
  description = excluded.description;


-- ---------------------------------------------------------------------------
-- Replay typed configuration definitions.
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
  pcd.config_key,
  pcd.category_key,
  pcd.value_type,
  pcd.unit_key,
  pcd.name,
  pcd.description,
  pcd.is_sensitive
from haulvia.platform_config_definitions pcd
where pcd.config_key = any (
  array[
    'SECURITY_SESSION_MAX_AGE_SECONDS',
    'SECURITY_SESSION_IDLE_TIMEOUT_SECONDS',
    'SECURITY_REAUTH_MAX_AGE_SECONDS',
    'MARKETPLACE_ASAP_LISTING_EXPIRY_SECONDS',
    'MARKETPLACE_SCHEDULED_LISTING_EXPIRY_SECONDS',
    'OFFER_RESPONSE_TIMEOUT_SECONDS',
    'COUNTER_RESPONSE_TIMEOUT_SECONDS',
    'OFFER_RESERVATION_TIMEOUT_SECONDS',
    'RECEIVER_CONFIRMATION_WINDOW_SECONDS',
    'DELIVERY_RESOLUTION_MINIMUM_SECONDS',
    'UPLOAD_MAX_FILE_BYTES',
    'UPLOAD_MAX_FILES_PER_REQUEST',
    'UPLOAD_ALLOWED_MEDIA_TYPES',
    'NOTIFICATION_RETRY_MAX_ATTEMPTS',
    'NOTIFICATION_RETRY_BACKOFF_SECONDS',
    'NOTIFICATION_ESCALATION_DELAY_SECONDS',
    'CUSTOMER_ASSIGNMENT_GRACE_SECONDS',
    'DRIVER_START_DEADLINE_SECONDS',
    'LATE_ARRIVAL_THRESHOLD_SECONDS',
    'NO_SHOW_THRESHOLD_SECONDS',
    'PICKUP_FREE_WAIT_SECONDS',
    'PICKUP_GEOFENCE_RADIUS_METRES',
    'DELIVERY_GEOFENCE_RADIUS_METRES'
  ]
)
on conflict (config_key)
do update set
  name = excluded.name,
  description = excluded.description;


-- ---------------------------------------------------------------------------
-- Replay manifest evidence.
-- ---------------------------------------------------------------------------

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


create temporary table p2a_seed_counts_after (
  seed_area text primary key,
  row_count bigint not null
) on commit drop;


insert into p2a_seed_counts_after (
  seed_area,
  row_count
)

select
  'roles',
  count(*)
from haulvia.roles r
join p2a_expected_roles er
  on er.role_key = r.role_key

union all

select
  'permissions',
  count(*)
from haulvia.permissions p
join p2a_expected_permissions ep
  on ep.permission_key = p.permission_key

union all

select
  'role_permissions',
  count(*)
from haulvia.role_permissions rp
join haulvia.roles r
  on r.id = rp.role_id
join p2a_expected_roles er
  on er.role_key = r.role_key

union all

select
  'role_organization_kinds',
  count(*)
from haulvia.role_organization_kinds rok
join haulvia.roles r
  on r.id = rok.role_id
join p2a_expected_roles er
  on er.role_key = r.role_key

union all

select
  'policy_sets',
  count(*)
from haulvia.policy_sets ps
where ps.policy_key = any (
  array[
    'MARKETPLACE_POLICY',
    'NEGOTIATION_POLICY',
    'CANCELLATION_POLICY',
    'EVIDENCE_POD_POLICY',
    'CUSTODY_POLICY',
    'RECEIVER_REVIEW_POLICY',
    'PAYOUT_DISPUTE_POLICY',
    'RETENTION_POLICY'
  ]
)

union all

select
  'policy_versions',
  count(*)
from haulvia.policy_versions pv
join haulvia.policy_sets ps
  on ps.id = pv.policy_set_id
where ps.policy_key = any (
  array[
    'MARKETPLACE_POLICY',
    'NEGOTIATION_POLICY',
    'CANCELLATION_POLICY',
    'EVIDENCE_POD_POLICY',
    'CUSTODY_POLICY',
    'RECEIVER_REVIEW_POLICY',
    'PAYOUT_DISPUTE_POLICY',
    'RETENTION_POLICY'
  ]
)
and pv.version_no = 1

union all

select
  'pricing_rule_sets',
  count(*)
from haulvia.pricing_rule_sets prs
where prs.rule_key in (
  'HAULVIA_FLEX_GUARDRAIL_CAD',
  'HAULVIA_EXPEDITED_FIXED_CAD'
)

union all

select
  'pricing_rule_versions',
  count(*)
from haulvia.pricing_rule_versions prv
join haulvia.pricing_rule_sets prs
  on prs.id = prv.pricing_rule_set_id
where prs.rule_key in (
  'HAULVIA_FLEX_GUARDRAIL_CAD',
  'HAULVIA_EXPEDITED_FIXED_CAD'
)
and prv.version_no = 1

union all

select
  'tax_jurisdictions',
  count(*)
from haulvia.tax_jurisdictions tj
where tj.jurisdiction_key = any (
  array[
    'CA_FEDERAL',
    'CA_AB',
    'CA_BC',
    'CA_MB',
    'CA_NB',
    'CA_NL',
    'CA_NS',
    'CA_ON',
    'CA_PE',
    'CA_QC',
    'CA_SK',
    'CA_NT',
    'CA_NU',
    'CA_YT'
  ]
)

union all

select
  'tax_rule_versions',
  count(*)
from haulvia.tax_rule_versions trv
join haulvia.tax_jurisdictions tj
  on tj.id = trv.jurisdiction_id
where tj.jurisdiction_key = any (
  array[
    'CA_FEDERAL',
    'CA_AB',
    'CA_BC',
    'CA_MB',
    'CA_NB',
    'CA_NL',
    'CA_NS',
    'CA_ON',
    'CA_PE',
    'CA_QC',
    'CA_SK',
    'CA_NT',
    'CA_NU',
    'CA_YT'
  ]
)
and trv.version_no = 1

union all

select
  'compliance_requirement_categories',
  count(*)
from haulvia.compliance_requirement_categories crc
where crc.category_key in (
  'APPLICATION_REQUIREMENTS',
  'PROVIDER_REQUIREMENTS',
  'DRIVER_REQUIREMENTS',
  'VEHICLE_REQUIREMENTS'
)

union all

select
  'platform_config_definitions',
  count(*)
from haulvia.platform_config_definitions pcd
where pcd.config_key = any (
  array[
    'SECURITY_SESSION_MAX_AGE_SECONDS',
    'SECURITY_SESSION_IDLE_TIMEOUT_SECONDS',
    'SECURITY_REAUTH_MAX_AGE_SECONDS',
    'MARKETPLACE_ASAP_LISTING_EXPIRY_SECONDS',
    'MARKETPLACE_SCHEDULED_LISTING_EXPIRY_SECONDS',
    'OFFER_RESPONSE_TIMEOUT_SECONDS',
    'COUNTER_RESPONSE_TIMEOUT_SECONDS',
    'OFFER_RESERVATION_TIMEOUT_SECONDS',
    'RECEIVER_CONFIRMATION_WINDOW_SECONDS',
    'DELIVERY_RESOLUTION_MINIMUM_SECONDS',
    'UPLOAD_MAX_FILE_BYTES',
    'UPLOAD_MAX_FILES_PER_REQUEST',
    'UPLOAD_ALLOWED_MEDIA_TYPES',
    'NOTIFICATION_RETRY_MAX_ATTEMPTS',
    'NOTIFICATION_RETRY_BACKOFF_SECONDS',
    'NOTIFICATION_ESCALATION_DELAY_SECONDS',
    'CUSTOMER_ASSIGNMENT_GRACE_SECONDS',
    'DRIVER_START_DEADLINE_SECONDS',
    'LATE_ARRIVAL_THRESHOLD_SECONDS',
    'NO_SHOW_THRESHOLD_SECONDS',
    'PICKUP_FREE_WAIT_SECONDS',
    'PICKUP_GEOFENCE_RADIUS_METRES',
    'DELIVERY_GEOFENCE_RADIUS_METRES'
  ]
)

union all

select
  'seed_manifest',
  count(*)
from haulvia.seed_manifests sm
where sm.seed_key = 'P2A_AUTHORITY_AND_SEED_CONTRACT'
  and sm.version_no = 1;


select pg_temp.assert_true(
  'repeat deterministic seed-data execution creates no duplicate rows',
  not exists (
    select 1
    from p2a_seed_counts_before b
    full join p2a_seed_counts_after a
      using (seed_area)
    where b.row_count is distinct from a.row_count
  )
);


-- ---------------------------------------------------------------------------
-- TEST 10
-- Conflicting pre-existing sensitivity or role-family data fails closed.
--
-- Each dynamic statement runs as a subtransaction inside expect_error().
-- The deliberately introduced conflict is therefore rolled back after the
-- required error is captured.
-- ---------------------------------------------------------------------------

select pg_temp.expect_error(
  'conflicting P2A permission sensitivity fails closed',
  $sql$
    do $conflict$
    declare
      v_conflict text;
    begin
      update haulvia.permissions
      set is_sensitive = false
      where permission_key = 'SENSITIVE_DOCUMENT_VIEW';

      select p.permission_key
        into v_conflict
      from haulvia.permissions p
      where p.permission_key = 'SENSITIVE_DOCUMENT_VIEW'
        and p.is_sensitive <> true;

      if v_conflict is not null then
        raise exception
          'Existing permission % conflicts with the approved P2A sensitivity classification',
          v_conflict
          using errcode = '23514';
      end if;
    end;
    $conflict$
  $sql$,
  '23514',
  'conflicts with the approved P2A sensitivity'
);


select pg_temp.assert_true(
  'sensitivity conflict fixture was rolled back',
  exists (
    select 1
    from haulvia.permissions p
    where p.permission_key = 'SENSITIVE_DOCUMENT_VIEW'
      and p.is_sensitive = true
  )
);


select pg_temp.expect_error(
  'conflicting role organization family fails closed',
  $sql$
    do $conflict$
    declare
      v_conflicting_role text;
    begin
      insert into haulvia.role_organization_kinds (
        role_id,
        organization_kind
      )
      select
        r.id,
        'COURIER_PARTNER'::haulvia.organization_kind
      from haulvia.roles r
      where r.role_key = 'BUSINESS_VIEWER'
      on conflict (role_id, organization_kind)
      do nothing;

      select r.role_key
        into v_conflicting_role
      from haulvia.roles r
      join haulvia.role_organization_kinds rok
        on rok.role_id = r.id
      where r.role_key = 'BUSINESS_VIEWER'
        and rok.organization_kind <> 'CUSTOMER'
      limit 1;

      if v_conflicting_role is not null then
        raise exception
          'Role % conflicts with the approved P2A organization family',
          v_conflicting_role
          using errcode = '23514';
      end if;
    end;
    $conflict$
  $sql$,
  '23514',
  'conflicts with the approved P2A organization family'
);


select pg_temp.assert_true(
  'role-family conflict fixture was rolled back',
  not exists (
    select 1
    from haulvia.roles r
    join haulvia.role_organization_kinds rok
      on rok.role_id = r.id
    where r.role_key = 'BUSINESS_VIEWER'
      and rok.organization_kind <> 'CUSTOMER'
  )
);


-- ---------------------------------------------------------------------------
-- TEST 11
-- P2A seeded no real tenant, person, provider, driver, vehicle, payment
-- method, document or shipment data.
--
-- The only organization/profile/membership rows permitted at this point are
-- the deterministic Test 4 fixtures created by this rollback-only suite.
--
-- customer_payment_method_refs is the Phase 1 table that stores verified
-- provider-neutral payment-method references without raw card/bank data.
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'only the two P2A acceptance organizations exist',
  (
    select count(*)
    from haulvia.organizations
  ) = 2
  and not exists (
    select 1
    from haulvia.organizations o
    where o.id not in (
      'a2a00000-0000-0000-0000-000000000001'::uuid,
      'a2a00000-0000-0000-0000-000000000002'::uuid
    )
  )
);


select pg_temp.assert_true(
  'only the two P2A acceptance profiles exist',
  (
    select count(*)
    from haulvia.profiles
  ) = 2
  and not exists (
    select 1
    from haulvia.profiles p
    where p.id not in (
      'a2a00000-0000-0000-0000-000000000011'::uuid,
      'a2a00000-0000-0000-0000-000000000012'::uuid
    )
  )
);


select pg_temp.assert_true(
  'P2A seeded no Auth identity',
  not exists (
    select 1
    from haulvia.profiles p
    where p.auth_user_id is not null
  )
);


select pg_temp.assert_true(
  'only the two P2A acceptance memberships exist',
  (
    select count(*)
    from haulvia.organization_memberships
  ) = 2
  and not exists (
    select 1
    from haulvia.organization_memberships om
    where om.id not in (
      'a2a00000-0000-0000-0000-000000000021'::uuid,
      'a2a00000-0000-0000-0000-000000000022'::uuid
    )
  )
);


select pg_temp.assert_true(
  'P2A seeded no provider application',
  not exists (
    select 1
    from haulvia.provider_applications
  )
);


select pg_temp.assert_true(
  'P2A seeded no service provider',
  not exists (
    select 1
    from haulvia.service_providers
  )
);


select pg_temp.assert_true(
  'P2A seeded no driver',
  not exists (
    select 1
    from haulvia.drivers
  )
);


select pg_temp.assert_true(
  'P2A seeded no vehicle',
  not exists (
    select 1
    from haulvia.vehicles
  )
);


select pg_temp.assert_true(
  'P2A seeded no customer payment-method reference',
  not exists (
    select 1
    from haulvia.customer_payment_method_refs
  )
);


select pg_temp.assert_true(
  'P2A seeded no compliance document',
  not exists (
    select 1
    from haulvia.compliance_documents
  )
);


select pg_temp.assert_true(
  'P2A seeded no stop evidence object',
  not exists (
    select 1
    from haulvia.stop_evidence
  )
);


select pg_temp.assert_true(
  'P2A seeded no shipment',
  not exists (
    select 1
    from haulvia.shipments
  )
);

-- ---------------------------------------------------------------------------
-- TEST 12
-- No self-approval path succeeds.
--
-- Build one valid Haulvia administrative identity so the tests cannot pass
-- merely because authority context is missing. Each attempted approval uses
-- that same profile as both creator/requester and approver.
-- ---------------------------------------------------------------------------

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  'a2a00000-0000-0000-0000-000000000003',
  'p2a-test-haulvia',
  'HAULVIA',
  'P2A Test Haulvia Operations',
  'P2A Test Haulvia'
);


insert into haulvia.profiles (
  id,
  display_name
)
values (
  'a2a00000-0000-0000-0000-000000000013',
  'P2A Test Platform Administrator'
);


insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status
)
values (
  'a2a00000-0000-0000-0000-000000000023',
  'a2a00000-0000-0000-0000-000000000003',
  'a2a00000-0000-0000-0000-000000000013',
  'ACTIVE'
);


insert into haulvia.membership_roles (
  membership_id,
  role_id
)
select
  'a2a00000-0000-0000-0000-000000000023'::uuid,
  r.id
from haulvia.roles r
where r.role_key = 'PLATFORM_ADMIN';


insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at
)
values (
  'a2a00000-0000-0000-0000-000000000031',
  'a2a00000-0000-0000-0000-000000000013',
  'a2a00000-0000-0000-0000-000000000003',
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes'
);


select pg_temp.assert_true(
  'P2A platform-admin test identity holds POLICY_PUBLISH',
  haulvia.has_permission(
    'a2a00000-0000-0000-0000-000000000013',
    'a2a00000-0000-0000-0000-000000000003',
    'POLICY_PUBLISH'
  )
);


select pg_temp.assert_true(
  'P2A platform-admin test identity holds PRICING_MANAGE',
  haulvia.has_permission(
    'a2a00000-0000-0000-0000-000000000013',
    'a2a00000-0000-0000-0000-000000000003',
    'PRICING_MANAGE'
  )
);


select pg_temp.assert_true(
  'P2A platform-admin test identity holds COMPLIANCE_REVIEW',
  haulvia.has_permission(
    'a2a00000-0000-0000-0000-000000000013',
    'a2a00000-0000-0000-0000-000000000003',
    'COMPLIANCE_REVIEW'
  )
);


select pg_temp.assert_true(
  'P2A platform-admin test identity holds FINANCIAL_ADJUST',
  haulvia.has_permission(
    'a2a00000-0000-0000-0000-000000000013',
    'a2a00000-0000-0000-0000-000000000003',
    'FINANCIAL_ADJUST'
  )
);


-- ---------------------------------------------------------------------------
-- TEST 12A
-- Platform-policy creator cannot approve their own version.
-- ---------------------------------------------------------------------------

select pg_temp.expect_error(
  'platform policy self-approval fails',
  $sql$
    insert into haulvia.policy_versions (
      policy_set_id,
      version_no,
      publication_status,
      effective_from,
      config,
      config_sha256,
      legal_review_required,
      created_by_profile_id,
      approved_by_profile_id,
      approved_at,
      reauth_session_id,
      approval_reason
    )
    select
      ps.id,
      2,
      'APPROVED',
      clock_timestamp(),
      '{}'::jsonb,
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      true,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      clock_timestamp(),
      'a2a00000-0000-0000-0000-000000000031'::uuid,
      'P2A self approval must fail'
    from haulvia.policy_sets ps
    where ps.policy_key = 'MARKETPLACE_POLICY'
    $sql$,
  '42501',
  'may not approve their own'
);


select pg_temp.assert_true(
  'failed platform-policy self-approval inserted no version',
  not exists (
    select 1
    from haulvia.policy_versions pv
    join haulvia.policy_sets ps
      on ps.id = pv.policy_set_id
    where ps.policy_key = 'MARKETPLACE_POLICY'
      and pv.version_no = 2
  )
);


-- ---------------------------------------------------------------------------
-- TEST 12B
-- Haulvia pricing-rule creator cannot approve their own version.
-- ---------------------------------------------------------------------------

select pg_temp.expect_error(
  'pricing rule self-approval fails',
  $sql$
    insert into haulvia.pricing_rule_versions (
      pricing_rule_set_id,
      version_no,
      publication_status,
      effective_from,
      rule_config,
      rule_sha256,
      created_by_profile_id,
      approved_by_profile_id,
      approved_at,
      reauth_session_id,
      approval_reason
    )
    select
      prs.id,
      2,
      'APPROVED',
      clock_timestamp(),
      '{}'::jsonb,
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      clock_timestamp(),
      'a2a00000-0000-0000-0000-000000000031'::uuid,
      'P2A self approval must fail'
    from haulvia.pricing_rule_sets prs
    where prs.rule_key = 'HAULVIA_FLEX_GUARDRAIL_CAD'
   $sql$,
  '42501',
  'may not approve their own'
);


select pg_temp.assert_true(
  'failed pricing-rule self-approval inserted no version',
  not exists (
    select 1
    from haulvia.pricing_rule_versions prv
    join haulvia.pricing_rule_sets prs
      on prs.id = prv.pricing_rule_set_id
    where prs.rule_key = 'HAULVIA_FLEX_GUARDRAIL_CAD'
      and prv.version_no = 2
  )
);


-- ---------------------------------------------------------------------------
-- TEST 12C
-- Compliance requirement creator cannot approve their own version.
-- ---------------------------------------------------------------------------

insert into haulvia.compliance_requirements (
  id,
  requirement_key,
  item_category,
  compliance_code,
  compliance_name,
  subject_kind,
  default_required,
  permits_not_applicable
)
values (
  'a2a00000-0000-0000-0000-000000000041',
  'P2A_TEST_COMPLIANCE_REQUIREMENT',
  'P2A_TEST',
  'P2A_TEST_COMPLIANCE',
  'P2A Test Compliance Requirement',
  'PROVIDER',
  false,
  true
);


select pg_temp.expect_error(
  'compliance requirement self-approval fails',
  $sql$
    insert into haulvia.compliance_requirement_versions (
      requirement_id,
      version_no,
      publication_status,
      effective_from,
      applicability_rules,
      evidence_requirements,
      created_by_profile_id,
      approved_by_profile_id,
      approved_at,
      reauth_session_id,
      approval_reason
    )
    values (
      'a2a00000-0000-0000-0000-000000000041'::uuid,
      1,
      'APPROVED',
      clock_timestamp(),
      '{}'::jsonb,
      '{}'::jsonb,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      clock_timestamp(),
      'a2a00000-0000-0000-0000-000000000031'::uuid,
      'P2A self approval must fail'
    )
   $sql$,
  '42501',
  'may not approve their own'
);


select pg_temp.assert_true(
  'failed compliance self-approval inserted no version',
  not exists (
    select 1
    from haulvia.compliance_requirement_versions crv
    where crv.requirement_id
      = 'a2a00000-0000-0000-0000-000000000041'::uuid
  )
);


-- ---------------------------------------------------------------------------
-- TEST 12D
-- Partner rate-card creator cannot approve their own version.
-- ---------------------------------------------------------------------------

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  'a2a00000-0000-0000-0000-000000000004',
  'p2a-test-courier-provider',
  'COURIER_PARTNER',
  'P2A Test Courier Provider Ltd.',
  'P2A Test Courier Provider'
);


insert into haulvia.service_providers (
  id,
  organization_id,
  kind,
  status
)
values (
  'a2a00000-0000-0000-0000-000000000051',
  'a2a00000-0000-0000-0000-000000000004',
  'COURIER_PARTNER',
  'ACTIVE'
);


insert into haulvia.partner_rate_cards (
  id,
  provider_id,
  rate_card_key,
  name,
  service_level,
  pricing_mode,
  region_code,
  currency
)
values (
  'a2a00000-0000-0000-0000-000000000052',
  'a2a00000-0000-0000-0000-000000000051',
  'P2A_TEST_FLEX_RATE_CARD',
  'P2A Test Flex Rate Card',
  'FLEX',
  'FLEX_NEGOTIABLE',
  'CA-SK',
  'CAD'
);


select pg_temp.expect_error(
  'partner rate-card self-approval fails',
  $sql$
    insert into haulvia.partner_rate_card_versions (
      rate_card_id,
      version_no,
      publication_status,
      effective_from,
      review_note,
      source_sha256,
      created_by_profile_id,
      approved_by_profile_id,
      approved_at,
      reauth_session_id
    )
    values (
      'a2a00000-0000-0000-0000-000000000052'::uuid,
      1,
      'APPROVED',
      clock_timestamp(),
      'P2A self approval must fail',
      '44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      clock_timestamp(),
      'a2a00000-0000-0000-0000-000000000031'::uuid
    )
   $sql$,
  '42501',
  'may not approve their own'
);


select pg_temp.assert_true(
  'failed partner-rate-card self-approval inserted no version',
  not exists (
    select 1
    from haulvia.partner_rate_card_versions prcv
    where prcv.rate_card_id
      = 'a2a00000-0000-0000-0000-000000000052'::uuid
  )
);


-- ---------------------------------------------------------------------------
-- TEST 12E
-- Financial-adjustment requester cannot approve their own request.
-- ---------------------------------------------------------------------------

insert into haulvia.shipments (
  id,
  shipment_reference,
  customer_organization_id,
  customer_profile_id,
  pickup_timing,
  service_level,
  currency
)
values (
  'a2a00000-0000-0000-0000-000000000061',
  'HV-20990101-0001',
  'a2a00000-0000-0000-0000-000000000001',
  'a2a00000-0000-0000-0000-000000000011',
  'ASAP',
  'FLEX',
  'CAD'
);


insert into haulvia.financial_adjustment_approval_requests (
  id,
  shipment_id,
  adjustment_type,
  amount,
  currency,
  reason,
  requested_by_profile_id,
  authorization_snapshot,
  before_value,
  proposed_after_value,
  idempotency_key
)
values (
  'a2a00000-0000-0000-0000-000000000062',
  'a2a00000-0000-0000-0000-000000000061',
  'CUSTOMER_CREDIT',
  1.00,
  'CAD',
  'P2A financial approval test',
  'a2a00000-0000-0000-0000-000000000013',
  '{"test":"p2a"}'::jsonb,
  '{"balance":0}'::jsonb,
  '{"balance":1}'::jsonb,
  'p2a-self-approval-test'
);


select pg_temp.expect_error(
  'financial adjustment self-approval fails',
  $sql$
    insert into haulvia.financial_adjustment_approval_decisions (
      approval_request_id,
      decision,
      organization_id,
      reviewed_by_profile_id,
      reauth_session_id,
      reason,
      effective_at,
      before_value,
      after_value
    )
    values (
      'a2a00000-0000-0000-0000-000000000062'::uuid,
      'APPROVED',
      'a2a00000-0000-0000-0000-000000000003'::uuid,
      'a2a00000-0000-0000-0000-000000000013'::uuid,
      'a2a00000-0000-0000-0000-000000000031'::uuid,
      'P2A self approval must fail',
      clock_timestamp(),
      '{"balance":0}'::jsonb,
      '{"balance":1}'::jsonb
    )
  $sql$,
  '42501',
  'may not be approved by its creator'
);


select pg_temp.assert_true(
  'failed financial self-approval inserted no decision',
  not exists (
    select 1
    from haulvia.financial_adjustment_approval_decisions fad
    where fad.approval_request_id
      = 'a2a00000-0000-0000-0000-000000000062'::uuid
  )
);


-- ---------------------------------------------------------------------------
-- TEST 13
-- P2A introduces no PUBLIC, anon or authenticated function execution.
--
-- Phase 1 already removed PUBLIC execution from the trusted authority helpers.
-- This test focuses on every function created by the P2A migration.
-- ---------------------------------------------------------------------------

create temporary table p2a_created_functions (
  function_name text primary key
) on commit drop;


insert into p2a_created_functions (
  function_name
)
values
  ('reject_worker_authority_role'),
  ('enforce_membership_role_organization_kind'),
  ('validate_platform_config_value'),
  ('enforce_publication_dual_control'),
  ('enforce_financial_adjustment_decision'),
  ('audit_financial_adjustment_decision'),
  ('validate_financial_adjustment_approval_link');


select pg_temp.assert_true(
  'every expected P2A helper function exists',
  (
    select count(distinct p.proname)
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    join p2a_created_functions f
      on f.function_name = p.proname
    where n.nspname = 'haulvia'
  ) = (
    select count(*)
    from p2a_created_functions
  )
);


select pg_temp.assert_true(
  'P2A helper functions grant no EXECUTE to PUBLIC anon or authenticated',
  not exists (
    select 1
    from information_schema.routine_privileges rp
    join p2a_created_functions f
      on f.function_name = rp.routine_name
    where rp.routine_schema = 'haulvia'
      and rp.privilege_type = 'EXECUTE'
      and rp.grantee in (
        'PUBLIC',
        'anon',
        'authenticated'
      )
  )
);


-- Explicit PostgreSQL ACL check for PUBLIC.
-- Grantee OID zero represents PUBLIC in aclexplode().

select pg_temp.assert_true(
  'P2A helper function ACLs contain no PUBLIC EXECUTE grant',
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    join p2a_created_functions f
      on f.function_name = p.proname
    cross join lateral aclexplode(
      coalesce(
        p.proacl,
        acldefault('f', p.proowner)
      )
    ) acl
    where n.nspname = 'haulvia'
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  )
);


-- If Supabase roles exist in the target database, neither may have EXECUTE.

select pg_temp.assert_true(
  'P2A helper function ACLs contain no anon/authenticated EXECUTE grant',
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    join p2a_created_functions f
      on f.function_name = p.proname
    cross join lateral aclexplode(
      coalesce(
        p.proacl,
        acldefault('f', p.proowner)
      )
    ) acl
    join pg_roles grantee_role
      on grantee_role.oid = acl.grantee
    where n.nspname = 'haulvia'
      and grantee_role.rolname in (
        'anon',
        'authenticated'
      )
      and acl.privilege_type = 'EXECUTE'
  )
);


-- ---------------------------------------------------------------------------
-- Final P2A acceptance evidence
-- ---------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2A seed manifest SHA-256 matches the approved contract',
  exists (
    select 1
    from haulvia.seed_manifests sm
    where sm.seed_key = 'P2A_AUTHORITY_AND_SEED_CONTRACT'
      and sm.version_no = 1
      and lower(sm.source_sha256)
        = '9a5812be5fd19076ff339a87a05a30300dcf001aa765e613957430d44da45bdb'
  )
);


select
  test_name,
  passed,
  detail
from pg_temp.p2a_test_results
order by test_name;


select
  count(*) as recorded_p2a_acceptance_checks,
  bool_and(passed) as all_recorded_checks_passed
from pg_temp.p2a_test_results;


-- ---------------------------------------------------------------------------
-- Acceptance suite is intentionally non-persistent.
-- ---------------------------------------------------------------------------

rollback;