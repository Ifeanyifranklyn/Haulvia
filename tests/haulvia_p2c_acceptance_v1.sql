-- Haulvia Phase 2 Block P2C acceptance suite v1
--
-- Contract:
--   docs/Haulvia_P2C_RLS_and_Security_Policy_Contract_v1.md
--
-- Contract SHA-256:
--   95F81FFFCEFB9902210F06AA1E718E2FD94694B98FBA901F2C7543A397FF828F
--
-- Requires cumulative migrations:
--   Foundation
--   Blocks A-E
--   P2A
--   P2B
--   P2C
--
-- This suite is rollback-only.

begin;

set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


-- ============================================================================
-- Test harness
-- ============================================================================

create temp table p2c_test_results (
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
  insert into p2c_test_results (
    test_name,
    passed,
    detail
  )
  values (
    p_test_name,
    coalesce(p_condition, false),
    p_detail
  );

  if not coalesce(p_condition, false) then
    raise exception
      'P2C acceptance failure: % -- %',
      p_test_name,
      coalesce(p_detail, 'condition evaluated false');
  end if;
end
$$;


-- Returns true only when a relation exists and neither PUBLIC nor the
-- Supabase client roles have direct relation privileges.
create or replace function pg_temp.relation_client_denied(
  p_relation_name text
)
returns boolean
language plpgsql
as $$
declare
  v_relation_oid oid;
begin
  select c.oid
  into v_relation_oid
  from pg_class c
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname = 'haulvia'
    and c.relname = p_relation_name
    and c.relkind in ('r', 'p', 'v')
  limit 1;

  if v_relation_oid is null then
    return false;
  end if;

  -- Explicit PUBLIC relation privileges.
  if exists (
    select 1
    from pg_class c
    cross join lateral aclexplode(c.relacl) acl
    where c.oid = v_relation_oid
      and acl.grantee = 0
      and acl.privilege_type in (
        'SELECT',
        'INSERT',
        'UPDATE',
        'DELETE',
        'TRUNCATE',
        'REFERENCES',
        'TRIGGER'
      )
  ) then
    return false;
  end if;

  -- Effective client-role relation privileges.
  if exists (
    select 1
    from pg_roles r
    where r.rolname in ('anon', 'authenticated')
      and (
        has_table_privilege(r.oid, v_relation_oid, 'SELECT')
        or has_table_privilege(r.oid, v_relation_oid, 'INSERT')
        or has_table_privilege(r.oid, v_relation_oid, 'UPDATE')
        or has_table_privilege(r.oid, v_relation_oid, 'DELETE')
        or has_table_privilege(r.oid, v_relation_oid, 'TRUNCATE')
        or has_table_privilege(r.oid, v_relation_oid, 'REFERENCES')
        or has_table_privilege(r.oid, v_relation_oid, 'TRIGGER')
      )
  ) then
    return false;
  end if;

  return true;
end
$$;


-- ============================================================================
-- P2C-01 through P2C-03
-- RLS coverage
-- ============================================================================

select pg_temp.assert_true(
  'P2C-01 all existing Haulvia base tables have RLS enabled',
  (
    select
      count(*) = count(*) filter (
        where c.relrowsecurity
      )
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
  ),
  'Every current haulvia base table must have relrowsecurity=true.'
);


select pg_temp.assert_true(
  'P2C-02 the P2C baseline covers all 123 currently discovered base tables',
  (
    select count(*) = 123
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
  ),
  'Expected the frozen P2C baseline of exactly 123 core base tables.'
);


select pg_temp.assert_true(
  'P2C-03 P2C does not require FORCE RLS on the core tables',
  not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and c.relforcerowsecurity
  ),
  'No current Haulvia core base table may use FORCE RLS in P2C v1.'
);


-- ============================================================================
-- P2C-04 through P2C-07
-- Raw relation grants
-- ============================================================================

select pg_temp.assert_true(
  'P2C-04 PUBLIC has no raw Haulvia table privileges',
  not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) acl
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and acl.grantee = 0
      and acl.privilege_type in (
        'SELECT',
        'INSERT',
        'UPDATE',
        'DELETE',
        'TRUNCATE',
        'REFERENCES',
        'TRIGGER'
      )
  ),
  'PUBLIC must have no direct privilege on raw Haulvia base tables.'
);


select pg_temp.assert_true(
  'P2C-05 anon has no raw Haulvia table privileges',
  not exists (
    select 1
    from pg_roles r
    cross join pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where r.rolname = 'anon'
      and n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and (
        has_table_privilege(r.oid, c.oid, 'SELECT')
        or has_table_privilege(r.oid, c.oid, 'INSERT')
        or has_table_privilege(r.oid, c.oid, 'UPDATE')
        or has_table_privilege(r.oid, c.oid, 'DELETE')
        or has_table_privilege(r.oid, c.oid, 'TRUNCATE')
        or has_table_privilege(r.oid, c.oid, 'REFERENCES')
        or has_table_privilege(r.oid, c.oid, 'TRIGGER')
      )
  ),
  'anon must have no effective raw-table privilege.'
);


select pg_temp.assert_true(
  'P2C-06 authenticated has no raw Haulvia table privileges',
  not exists (
    select 1
    from pg_roles r
    cross join pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where r.rolname = 'authenticated'
      and n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and (
        has_table_privilege(r.oid, c.oid, 'SELECT')
        or has_table_privilege(r.oid, c.oid, 'INSERT')
        or has_table_privilege(r.oid, c.oid, 'UPDATE')
        or has_table_privilege(r.oid, c.oid, 'DELETE')
        or has_table_privilege(r.oid, c.oid, 'TRUNCATE')
        or has_table_privilege(r.oid, c.oid, 'REFERENCES')
        or has_table_privilege(r.oid, c.oid, 'TRIGGER')
      )
  ),
  'authenticated must have no effective raw-table privilege.'
);


select pg_temp.assert_true(
  'P2C-07 P2C introduces no new broad service_role raw-table grants',
  not exists (
    select 1
    from information_schema.table_privileges tp
    where tp.table_schema = 'haulvia'
      and tp.grantee = 'service_role'
  ),
  'service_role must not receive direct broad relation grants from P2C.'
);


-- ============================================================================
-- P2C-08 through P2C-11
-- Existing view boundary
-- ============================================================================

select pg_temp.assert_true(
  'P2C-08 PUBLIC has no direct privilege on the existing Haulvia views',
  not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    cross join lateral aclexplode(c.relacl) acl
    where n.nspname = 'haulvia'
      and c.relkind = 'v'
      and acl.grantee = 0
  ),
  'PUBLIC must have no direct ACL entry on a Haulvia view.'
);


select pg_temp.assert_true(
  'P2C-09 anon has no direct privilege on the existing Haulvia views',
  not exists (
    select 1
    from pg_roles r
    cross join pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where r.rolname = 'anon'
      and n.nspname = 'haulvia'
      and c.relkind = 'v'
      and (
        has_table_privilege(r.oid, c.oid, 'SELECT')
        or has_table_privilege(r.oid, c.oid, 'INSERT')
        or has_table_privilege(r.oid, c.oid, 'UPDATE')
        or has_table_privilege(r.oid, c.oid, 'DELETE')
      )
  ),
  'anon must have no effective privilege on existing Haulvia views.'
);


select pg_temp.assert_true(
  'P2C-10 authenticated has no direct privilege on the existing Haulvia views',
  not exists (
    select 1
    from pg_roles r
    cross join pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where r.rolname = 'authenticated'
      and n.nspname = 'haulvia'
      and c.relkind = 'v'
      and (
        has_table_privilege(r.oid, c.oid, 'SELECT')
        or has_table_privilege(r.oid, c.oid, 'INSERT')
        or has_table_privilege(r.oid, c.oid, 'UPDATE')
        or has_table_privilege(r.oid, c.oid, 'DELETE')
      )
  ),
  'authenticated must have no effective privilege on existing Haulvia views.'
);


select pg_temp.assert_true(
  'P2C-11 all five existing Haulvia views are security-invoker views',
  (
    select
      count(*) = 5
      and count(*) filter (
        where coalesce(c.reloptions, array[]::text[])
          @> array['security_invoker=true']
      ) = 5
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind = 'v'
      and c.relname in (
        'v_cargo_custody_balance',
        'v_compliance_blockers',
        'v_compliance_item_export',
        'v_route_allocation_manifest',
        'v_shipment_operating_context'
      )
  ),
  'All five frozen P2C views must have security_invoker=true.'
);


-- ============================================================================
-- P2C-12 through P2C-16
-- Individual internal views
-- ============================================================================

select pg_temp.assert_true(
  'P2C-12 v_cargo_custody_balance remains client-denied',
  pg_temp.relation_client_denied(
    'v_cargo_custody_balance'
  )
);


select pg_temp.assert_true(
  'P2C-13 v_compliance_blockers remains client-denied',
  pg_temp.relation_client_denied(
    'v_compliance_blockers'
  )
);


select pg_temp.assert_true(
  'P2C-14 v_compliance_item_export remains client-denied',
  pg_temp.relation_client_denied(
    'v_compliance_item_export'
  )
);


select pg_temp.assert_true(
  'P2C-15 v_route_allocation_manifest remains client-denied',
  pg_temp.relation_client_denied(
    'v_route_allocation_manifest'
  )
);


select pg_temp.assert_true(
  'P2C-16 v_shipment_operating_context remains client-denied',
  pg_temp.relation_client_denied(
    'v_shipment_operating_context'
  )
);

-- ============================================================================
-- Additional acceptance helpers
-- ============================================================================

create or replace function pg_temp.no_client_base_table_privilege(
  p_privilege text
)
returns boolean
language plpgsql
as $$
begin
  return not exists (
    select 1
    from pg_roles r
    cross join pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where r.rolname in ('anon', 'authenticated')
      and n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and has_table_privilege(
        r.oid,
        c.oid,
        p_privilege
      )
  );
end
$$;


create or replace function pg_temp.all_relations_client_denied(
  p_relation_names text[]
)
returns boolean
language plpgsql
as $$
declare
  v_relation_name text;
begin
  foreach v_relation_name in array p_relation_names
  loop
    if not pg_temp.relation_client_denied(
      v_relation_name
    ) then
      return false;
    end if;
  end loop;

  return true;
end
$$;


-- ============================================================================
-- P2C-17 through P2C-20
-- Trusted command boundary
-- ============================================================================

select pg_temp.assert_true(
  'P2C-17 anon has no command-schema function execution',
  not exists (
    select 1
    from pg_roles r
    cross join pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where r.rolname = 'anon'
      and n.nspname = 'haulvia_command'
      and has_function_privilege(
        r.oid,
        p.oid,
        'EXECUTE'
      )
  ),
  'anon must not execute functions in haulvia_command.'
);


select pg_temp.assert_true(
  'P2C-18 authenticated has no command-schema function execution',
  not exists (
    select 1
    from pg_roles r
    cross join pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where r.rolname = 'authenticated'
      and n.nspname = 'haulvia_command'
      and has_function_privilege(
        r.oid,
        p.oid,
        'EXECUTE'
      )
  ),
  'authenticated must not execute functions in haulvia_command.'
);


select pg_temp.assert_true(
  'P2C-19 PUBLIC has no command-schema function execution',
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and (
        p.proacl is null
        or exists (
          select 1
          from aclexplode(p.proacl) acl
          where acl.grantee = 0
            and acl.privilege_type = 'EXECUTE'
        )
      )
  ),
  'No haulvia_command function may retain effective PUBLIC EXECUTE.'
);


select pg_temp.assert_true(
  'P2C-20 intended service_role command execution remains available',
  (
    select
      count(*) filter (
        where has_function_privilege(
          'service_role',
          p.oid,
          'EXECUTE'
        )
      ) = 70
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
  ),
  'Expected the existing allowlist of exactly 70 service_role executable command functions.'
);


-- ============================================================================
-- P2C-21 through P2C-24
-- No raw client mutations
-- ============================================================================

select pg_temp.assert_true(
  'P2C-21 clients have no raw Haulvia INSERT privilege',
  pg_temp.no_client_base_table_privilege(
    'INSERT'
  ),
  'anon/authenticated must not INSERT directly into raw Haulvia tables.'
);


select pg_temp.assert_true(
  'P2C-22 clients have no raw Haulvia UPDATE privilege',
  pg_temp.no_client_base_table_privilege(
    'UPDATE'
  ),
  'anon/authenticated must not UPDATE raw Haulvia tables.'
);


select pg_temp.assert_true(
  'P2C-23 clients have no raw Haulvia DELETE privilege',
  pg_temp.no_client_base_table_privilege(
    'DELETE'
  ),
  'anon/authenticated must not DELETE from raw Haulvia tables.'
);


select pg_temp.assert_true(
  'P2C-24 clients have no raw Haulvia TRUNCATE privilege',
  pg_temp.no_client_base_table_privilege(
    'TRUNCATE'
  ),
  'anon/authenticated must not TRUNCATE raw Haulvia tables.'
);


-- ============================================================================
-- P2C-25 through P2C-26
-- No permissive raw client RLS policies
-- ============================================================================

select pg_temp.assert_true(
  'P2C-25 no permissive anon raw-table RLS policy exists',
  not exists (
    select 1
    from pg_policy pol
    join pg_class c
      on c.oid = pol.polrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    cross join pg_roles r
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and r.rolname = 'anon'
      and pol.polpermissive
      and (
        0::oid = any(pol.polroles)
        or r.oid = any(pol.polroles)
      )
  ),
  'No permissive policy may expose a raw Haulvia table to anon.'
);


select pg_temp.assert_true(
  'P2C-26 no permissive authenticated raw-table RLS policy exists',
  not exists (
    select 1
    from pg_policy pol
    join pg_class c
      on c.oid = pol.polrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    cross join pg_roles r
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and r.rolname = 'authenticated'
      and pol.polpermissive
      and (
        0::oid = any(pol.polroles)
        or r.oid = any(pol.polroles)
      )
  ),
  'No permissive policy may expose a raw Haulvia table to authenticated.'
);


-- ============================================================================
-- P2C-27 through P2C-33
-- Identity, secret, audit, and payment-reference containment
-- ============================================================================

select pg_temp.assert_true(
  'P2C-27 profile claim proofs remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'profile_claim_proofs'
    ]
  )
);


select pg_temp.assert_true(
  'P2C-28 profile auth recovery proofs remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'profile_auth_recovery_proofs'
    ]
  )
);


select pg_temp.assert_true(
  'P2C-29 reauth sessions remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'reauth_sessions'
    ]
  )
);


select pg_temp.assert_true(
  'P2C-30 organization invitation records remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'organization_invitations',
      'organization_invitation_roles'
    ]
  )
);


select pg_temp.assert_true(
  'P2C-31 command idempotency records remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'command_idempotency'
    ]
  )
);


select pg_temp.assert_true(
  'P2C-32 audit events remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'audit_events'
    ]
  )
);


select pg_temp.assert_true(
  'P2C-33 customer payment method references remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'customer_payment_method_refs'
    ]
  )
);


-- ============================================================================
-- P2C-34
-- Raw payment and payout containment
-- ============================================================================

select pg_temp.assert_true(
  'P2C-34 raw payment and payout tables remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'driver_payouts',
      'payment_intents',
      'payment_transactions',
      'payout_eligibility_records',
      'payout_transactions',
      'shipment_customer_payment_axes',
      'shipment_driver_payout_axes'
    ]
  ),
  'Raw payment/payout state must remain behind trusted backend boundaries.'
);


-- ============================================================================
-- P2C-35
-- Raw financial adjustments and holds
-- ============================================================================

select pg_temp.assert_true(
  'P2C-35 raw financial adjustment and hold tables remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'financial_adjustment_approval_decisions',
      'financial_adjustment_approval_requests',
      'financial_adjustments',
      'financial_holds',
      'workflow_holds'
    ]
  ),
  'Financial adjustment, approval, and hold state must remain internal.'
);


-- ============================================================================
-- P2C-36
-- Compliance document containment
-- ============================================================================

select pg_temp.assert_true(
  'P2C-36 raw compliance document tables remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'compliance_documents',
      'compliance_document_reviews'
    ]
  ),
  'Compliance document metadata and review records must remain internal.'
);


-- ============================================================================
-- P2C-37
-- Compliance credential/item containment
-- ============================================================================

select pg_temp.assert_true(
  'P2C-37 raw compliance credential and item tables remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'compliance_item_history',
      'compliance_items',
      'compliance_requirement_categories',
      'compliance_requirement_versions',
      'compliance_requirements',
      'compliance_state_transition_rules',
      'compliance_subjects'
    ]
  ),
  'Raw compliance credential, subject, requirement, and item state must remain internal.'
);


-- ============================================================================
-- P2C-38
-- Receiver access secrets
-- ============================================================================

select pg_temp.assert_true(
  'P2C-38 receiver access tokens remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'receiver_access_tokens'
    ]
  ),
  'Receiver access-token material must never be directly client-readable.'
);


-- ============================================================================
-- P2C-39
-- Configuration and RBAC administration containment
-- ============================================================================

select pg_temp.assert_true(
  'P2C-39 configuration and RBAC administration tables remain client-denied',
  pg_temp.all_relations_client_denied(
    array[
      'membership_roles',
      'organization_memberships',
      'partner_rate_card_lines',
      'partner_rate_card_versions',
      'partner_rate_cards',
      'permissions',
      'platform_config_definitions',
      'platform_config_versions',
      'policy_sets',
      'policy_versions',
      'role_organization_kinds',
      'role_permissions',
      'roles'
    ]
  ),
  'Raw configuration, pricing administration, and RBAC authority tables must remain internal.'
);

-- ============================================================================
-- P2C-40
-- SECURITY DEFINER search-path hardening
-- ============================================================================

select pg_temp.assert_true(
  'P2C-40 SECURITY DEFINER functions use controlled pinned search paths',
  (
    with security_definers as (
      select
        p.oid,
        (
          select setting
          from unnest(
            coalesce(
              p.proconfig,
              array[]::text[]
            )
          ) as setting
          where setting like 'search_path=%'
          limit 1
        ) as search_path_setting
      from pg_proc p
      join pg_namespace n
        on n.oid = p.pronamespace
      where n.nspname in (
        'haulvia',
        'haulvia_command'
      )
        and p.prosecdef
    )
    select
      count(*) > 0
      and bool_and(
        search_path_setting is not null

        and search_path_setting
          !~* '(^|[,=[:space:]])public([,[:space:]]|$)'

        and search_path_setting not like '%$user%'

        and search_path_setting
          ~* 'pg_temp[[:space:]]*$'

        and not exists (
          select 1
          from unnest(
            string_to_array(
              regexp_replace(
                search_path_setting,
                '^search_path=',
                ''
              ),
              ','
            )
          ) as path_part
          where btrim(path_part) not in (
            'haulvia',
            'haulvia_command',
            'pg_catalog',
            'pg_temp'
          )
        )
      )
    from security_definers
  ),
  'Every SECURITY DEFINER function must have a pinned search_path restricted to approved schemas and terminating in pg_temp.'
);


-- ============================================================================
-- P2C-41
-- SECURITY DEFINER ownership
-- ============================================================================

select pg_temp.assert_true(
  'P2C-41 privileged SECURITY DEFINER functions are not owned by client roles',
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    join pg_roles owner_role
      on owner_role.oid = p.proowner
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and p.prosecdef
      and owner_role.rolname in (
        'anon',
        'authenticated'
      )
  ),
  'anon/authenticated may not own SECURITY DEFINER functions.'
);


-- ============================================================================
-- P2C-42
-- Future table/view default privileges
--
-- These objects are created after P2C by the migration/test owner and are
-- removed by the suite-level ROLLBACK.
-- ============================================================================

create table haulvia.p2c_future_relation_acl_probe (
  id bigint primary key
);

create view haulvia.p2c_future_relation_acl_probe_view as
select id
from haulvia.p2c_future_relation_acl_probe;


select pg_temp.assert_true(
  'P2C-42 future tables and views created by the migration owner remain client-denied',
  (
    select
      count(*) = 2
      and bool_and(
        pg_get_userbyid(c.relowner) = current_user
      )
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname in (
        'p2c_future_relation_acl_probe',
        'p2c_future_relation_acl_probe_view'
      )
  )
  and pg_temp.all_relations_client_denied(
    array[
      'p2c_future_relation_acl_probe',
      'p2c_future_relation_acl_probe_view'
    ]
  ),
  'Post-P2C tables/views created by the migration owner must not expose privileges to PUBLIC, anon, or authenticated.'
);


-- ============================================================================
-- P2C-43
-- Future function default privileges
--
-- Use SECURITY DEFINER probes because privileged functions are the material
-- security case. Both are rollback-only.
-- ============================================================================

create function haulvia.p2c_future_function_acl_probe()
returns integer
language sql
security definer
set search_path = pg_catalog, pg_temp
as $$
  select 1;
$$;


create function haulvia_command.p2c_future_command_function_acl_probe()
returns integer
language sql
security definer
set search_path = pg_catalog, pg_temp
as $$
  select 1;
$$;


select pg_temp.assert_true(
  'P2C-43 future privileged functions created by the migration owner deny PUBLIC and client execution',
  (
    with probe_functions as (
      select
        p.oid,
        p.proacl,
        pg_get_userbyid(p.proowner) as owner_name
      from pg_proc p
      join pg_namespace n
        on n.oid = p.pronamespace
      where (
        n.nspname = 'haulvia'
        and p.proname = 'p2c_future_function_acl_probe'
      )
      or (
        n.nspname = 'haulvia_command'
        and p.proname = 'p2c_future_command_function_acl_probe'
      )
    )
    select
      count(*) = 2

      and bool_and(
        owner_name = current_user
      )

      and bool_and(
        proacl is not null
      )

      and not exists (
        select 1
        from probe_functions pf
        cross join lateral aclexplode(pf.proacl) acl
        where acl.grantee = 0
          and acl.privilege_type = 'EXECUTE'
      )

      and not exists (
        select 1
        from probe_functions pf
        cross join pg_roles r
        where r.rolname in (
          'anon',
          'authenticated'
        )
          and has_function_privilege(
            r.oid,
            pf.oid,
            'EXECUTE'
          )
      )

    from probe_functions
  ),
  'Future privileged functions must not inherit PUBLIC/anon/authenticated EXECUTE.'
);


-- ============================================================================
-- P2C-44
-- Preserve P2A/P2B authority and identity invariants
-- ============================================================================

select pg_temp.assert_true(
  'P2C-44 P2C preserves the P2A and P2B authority and Auth-profile mapping invariants',

  -- P2A authority seed baseline.
  (
    select count(*) = 17
    from haulvia.roles
  )

  and (
    select count(*) = 50
    from haulvia.permissions
  )

  -- Core P2A/P2B authority and identity structures still exist.
  and to_regclass(
    'haulvia.role_organization_kinds'
  ) is not null

  and to_regclass(
    'haulvia.organization_memberships'
  ) is not null

  and to_regclass(
    'haulvia.membership_roles'
  ) is not null

  and to_regclass(
    'haulvia.reauth_sessions'
  ) is not null

  and to_regclass(
    'haulvia.organization_invitations'
  ) is not null

  and to_regclass(
    'haulvia.organization_invitation_roles'
  ) is not null

  and to_regclass(
    'haulvia.profile_claim_proofs'
  ) is not null

  and to_regclass(
    'haulvia.profile_auth_recovery_proofs'
  ) is not null

  -- P2B profile/Auth bridge columns remain present.
  and exists (
    select 1
    from information_schema.columns
    where table_schema = 'haulvia'
      and table_name = 'profiles'
      and column_name = 'auth_user_id'
  )

  and exists (
    select 1
    from information_schema.columns
    where table_schema = 'haulvia'
      and table_name = 'profiles'
      and column_name = 'auth_access_status'
  )

  and exists (
    select 1
    from information_schema.columns
    where table_schema = 'haulvia'
      and table_name = 'command_idempotency'
      and column_name = 'actor_auth_user_id'
  )

  -- One Auth UUID may map to at most one profile.
  and exists (
    select 1
    from pg_index i
    join pg_class c
      on c.oid = i.indrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    join pg_attribute a
      on a.attrelid = c.oid
     and a.attname = 'auth_user_id'
    where n.nspname = 'haulvia'
      and c.relname = 'profiles'
      and i.indisunique
      and i.indnkeyatts = 1
      and a.attnum = any(
        i.indkey::smallint[]
      )
  )

  -- P2B identity/authority resolution helpers remain available.
  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
        'resolve_authenticated_profile_id'
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
        'resolve_active_membership_id'
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
        'assert_membership_management_authority'
  ),

  'P2C must not weaken or remove the established P2A/P2B authority, membership, proof, invitation, or Auth/profile mapping structures.'
);


-- ============================================================================
-- Final acceptance gate
-- ============================================================================

do $$
declare
  v_total_checks integer;
  v_passed_checks integer;
  v_failed_checks integer;
begin
  select
    count(*),
    count(*) filter (
      where passed
    ),
    count(*) filter (
      where not passed
    )
  into
    v_total_checks,
    v_passed_checks,
    v_failed_checks
  from p2c_test_results;

  if v_total_checks <> 44 then
    raise exception
      'P2C acceptance suite expected 44 contract checks but recorded %',
      v_total_checks;
  end if;

  if v_passed_checks <> 44
     or v_failed_checks <> 0 then
    raise exception
      'P2C acceptance suite failed: total=%, passed=%, failed=%',
      v_total_checks,
      v_passed_checks,
      v_failed_checks;
  end if;
end
$$;


-- ============================================================================
-- Acceptance report
-- ============================================================================

select
  test_name,
  passed,
  detail
from p2c_test_results
order by test_name;


select
  count(*) as total_contract_checks,
  count(*) filter (
    where passed
  ) as passed_contract_checks,
  count(*) filter (
    where not passed
  ) as failed_contract_checks
from p2c_test_results;


rollback;