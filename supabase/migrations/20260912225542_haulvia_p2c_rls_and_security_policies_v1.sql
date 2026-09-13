-- ============================================================================
-- Haulvia Phase 2C
-- RLS and Security Policies v1
--
-- Contract:
--   docs/Haulvia_P2C_RLS_and_Security_Policy_Contract_v1.md
--
-- Contract SHA-256:
--   95F81FFFCEFB9902210F06AA1E718E2FD94694B98FBA901F2C7543A397FF828F
--
-- Scope:
--   - enable RLS across the Haulvia core schema
--   - preserve default-deny raw client access
--   - harden schema/table/view/function privileges
--   - convert existing views to security-invoker
--   - harden future-object default privileges
--   - verify SECURITY DEFINER search-path/ownership safety
--
-- P2C intentionally creates no anon/authenticated raw-table policies.
-- Mutating business operations remain command-mediated.
-- ============================================================================

begin;

-- ============================================================================
-- 1. Enable RLS on every current Haulvia base table.
--
-- The migration deliberately discovers the catalog rather than maintaining a
-- hand-written table list. This protects indirectly tenant-linked tables as
-- well as directly organization/profile/shipment-keyed tables.
--
-- P2C v1 explicitly does NOT use FORCE ROW LEVEL SECURITY.
-- ============================================================================

do $$
declare
  v_relation record;
begin
  for v_relation in
    select
      n.nspname as schema_name,
      c.relname as relation_name
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
    order by c.relname
  loop
    execute format(
      'alter table %I.%I enable row level security',
      v_relation.schema_name,
      v_relation.relation_name
    );

    execute format(
      'alter table %I.%I no force row level security',
      v_relation.schema_name,
      v_relation.relation_name
    );
  end loop;
end
$$;


-- ============================================================================
-- 2. Existing views are internal and must execute with invoker semantics.
--
-- None of these views is approved as a direct client API in P2C v1.
-- ============================================================================

alter view haulvia.v_cargo_custody_balance
  set (security_invoker = true);

alter view haulvia.v_compliance_blockers
  set (security_invoker = true);

alter view haulvia.v_compliance_item_export
  set (security_invoker = true);

alter view haulvia.v_route_allocation_manifest
  set (security_invoker = true);

alter view haulvia.v_shipment_operating_context
  set (security_invoker = true);


-- ============================================================================
-- 3. Existing core-schema object privileges.
--
-- PUBLIC receives no raw relation, sequence, or function access.
--
-- Revoking PUBLIC function EXECUTE also closes the discovered exposure on:
--   haulvia.next_shipment_reference(date)
--
-- Explicit grants to trusted roles such as service_role are not removed by
-- revoking PUBLIC.
-- ============================================================================

revoke all privileges on schema haulvia
  from public;

revoke all privileges on schema haulvia_command
  from public;

revoke all privileges on all tables in schema haulvia
  from public;

revoke all privileges on all sequences in schema haulvia
  from public;

revoke all privileges on all functions in schema haulvia
  from public;

revoke all privileges on all functions in schema haulvia_command
  from public;


-- ============================================================================
-- 4. Supabase client-role revocation.
--
-- The migration remains portable to a pure PostgreSQL database where one or
-- both Supabase client roles might not exist.
-- ============================================================================

do $$
declare
  v_role text;
begin
  foreach v_role in array array['anon', 'authenticated']
  loop
    if exists (
      select 1
      from pg_roles
      where rolname = v_role
    ) then
      execute format(
        'revoke all privileges on schema haulvia from %I',
        v_role
      );

      execute format(
        'revoke all privileges on schema haulvia_command from %I',
        v_role
      );

      execute format(
        'revoke all privileges on all tables in schema haulvia from %I',
        v_role
      );

      execute format(
        'revoke all privileges on all sequences in schema haulvia from %I',
        v_role
      );

      execute format(
        'revoke all privileges on all functions in schema haulvia from %I',
        v_role
      );

      execute format(
        'revoke all privileges on all functions in schema haulvia_command from %I',
        v_role
      );
    end if;
  end loop;
end
$$;


-- ============================================================================
-- 5. Default privileges for future objects created by this migration owner.
--
-- PostgreSQL grants EXECUTE on newly created functions to PUBLIC by default.
--
-- That built-in function privilege is a global default. A schema-specific
-- default-privilege REVOKE cannot override it, so P2C revokes PUBLIC EXECUTE
-- globally for functions subsequently created by the migration owner.
--
-- Tables/views and sequences remain explicitly hardened in the Haulvia
-- schemas.
-- ============================================================================

do $$
declare
  v_owner name := current_user;
  v_role text;
begin
  -- --------------------------------------------------------------------------
  -- PUBLIC defaults
  -- --------------------------------------------------------------------------

  execute format(
    'alter default privileges for role %I in schema haulvia
       revoke all privileges on tables from public',
    v_owner
  );

  execute format(
    'alter default privileges for role %I in schema haulvia
       revoke all privileges on sequences from public',
    v_owner
  );

  execute format(
    'alter default privileges for role %I
       revoke execute on functions from public',
    v_owner
  );

  execute format(
    'alter default privileges for role %I in schema haulvia_command
       revoke all privileges on tables from public',
    v_owner
  );

  execute format(
    'alter default privileges for role %I in schema haulvia_command
       revoke all privileges on sequences from public',
    v_owner
  );



  -- --------------------------------------------------------------------------
  -- Client-role defaults.
  --
  -- These are defensive. A REVOKE remains harmless even if no grant currently
  -- exists, and makes the intended future-object boundary explicit.
  -- --------------------------------------------------------------------------

  foreach v_role in array array['anon', 'authenticated']
  loop
    if exists (
      select 1
      from pg_roles
      where rolname = v_role
    ) then
      execute format(
        'alter default privileges for role %I in schema haulvia
           revoke all privileges on tables from %I',
        v_owner,
        v_role
      );

      execute format(
        'alter default privileges for role %I in schema haulvia
           revoke all privileges on sequences from %I',
        v_owner,
        v_role
      );

      execute format(
        'alter default privileges for role %I in schema haulvia
           revoke all privileges on functions from %I',
        v_owner,
        v_role
      );

      execute format(
        'alter default privileges for role %I in schema haulvia_command
           revoke all privileges on tables from %I',
        v_owner,
        v_role
      );

      execute format(
        'alter default privileges for role %I in schema haulvia_command
           revoke all privileges on sequences from %I',
        v_owner,
        v_role
      );

      execute format(
        'alter default privileges for role %I in schema haulvia_command
           revoke all privileges on functions from %I',
        v_owner,
        v_role
      );
    end if;
  end loop;
end
$$;


-- ============================================================================
-- 6. SECURITY DEFINER hardening assertions.
--
-- Discovery before P2C found:
--   SECURITY DEFINER functions:              99
--   unset search paths:                       0
--   unsafe search paths:                      0
--   client-owned SECURITY DEFINER functions:  0
--
-- Existing safe functions are not rewritten merely for P2C.
-- If an unsafe function appears in the cumulative migration chain, P2C fails
-- rather than silently accepting it.
-- ============================================================================

do $$
declare
  v_unset_search_path_count bigint;
  v_unsafe_search_path_count bigint;
  v_client_owned_count bigint;
begin
  with security_definers as (
    select
      p.oid,
      owner_role.rolname as owner_name,
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
    join pg_roles owner_role
      on owner_role.oid = p.proowner
    where n.nspname in ('haulvia', 'haulvia_command')
      and p.prosecdef
  )
  select
    count(*) filter (
      where search_path_setting is null
    ),

    count(*) filter (
      where search_path_setting is not null
        and (
          search_path_setting
            ~* '(^|[,=[:space:]])public([,[:space:]]|$)'
          or search_path_setting like '%$user%'
          or search_path_setting
            !~* 'pg_temp[[:space:]]*$'
        )
    ),

    count(*) filter (
      where owner_name in ('anon', 'authenticated')
    )

  into
    v_unset_search_path_count,
    v_unsafe_search_path_count,
    v_client_owned_count

  from security_definers;

  if v_unset_search_path_count <> 0 then
    raise exception
      'P2C detected % SECURITY DEFINER function(s) with unset search_path',
      v_unset_search_path_count;
  end if;

  if v_unsafe_search_path_count <> 0 then
    raise exception
      'P2C detected % SECURITY DEFINER function(s) with unsafe search_path',
      v_unsafe_search_path_count;
  end if;

  if v_client_owned_count <> 0 then
    raise exception
      'P2C detected % SECURITY DEFINER function(s) owned by anon/authenticated',
      v_client_owned_count;
  end if;
end
$$;


-- ============================================================================
-- 7. Verify no SECURITY DEFINER function remains executable by client/PUBLIC.
-- ============================================================================

do $$
declare
  v_exposed_function_count bigint;
begin
  with privileged_functions as (
    select
      p.oid,
      p.proowner,
      p.proacl
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname in ('haulvia', 'haulvia_command')
      and p.prosecdef
  ),
  execute_acl as (
    select
      f.oid,
      coalesce(r.rolname, 'PUBLIC') as grantee
    from privileged_functions f
    cross join lateral aclexplode(
      coalesce(
        f.proacl,
        acldefault('f', f.proowner)
      )
    ) acl
    left join pg_roles r
      on r.oid = acl.grantee
    where acl.privilege_type = 'EXECUTE'
  )
  select count(*)
  into v_exposed_function_count
  from execute_acl
  where grantee in (
    'PUBLIC',
    'anon',
    'authenticated'
  );

  if v_exposed_function_count <> 0 then
    raise exception
      'P2C detected % prohibited PUBLIC/anon/authenticated SECURITY DEFINER EXECUTE grant(s)',
      v_exposed_function_count;
  end if;
end
$$;


-- ============================================================================
-- 8. Verify the complete current Haulvia base-table RLS surface.
-- ============================================================================

do $$
declare
  v_base_table_count bigint;
  v_rls_enabled_count bigint;
  v_forced_rls_count bigint;
begin
  select
    count(*),
    count(*) filter (where c.relrowsecurity),
    count(*) filter (where c.relforcerowsecurity)
  into
    v_base_table_count,
    v_rls_enabled_count,
    v_forced_rls_count
  from pg_class c
  join pg_namespace n
    on n.oid = c.relnamespace
  where n.nspname = 'haulvia'
    and c.relkind in ('r', 'p');

  if v_rls_enabled_count <> v_base_table_count then
    raise exception
      'P2C RLS coverage failure: % of % Haulvia base tables protected',
      v_rls_enabled_count,
      v_base_table_count;
  end if;

  if v_forced_rls_count <> 0 then
    raise exception
      'P2C detected % unexpectedly FORCE-RLS-protected table(s)',
      v_forced_rls_count;
  end if;
end
$$;


-- ============================================================================
-- 9. Contract fingerprint.
-- ============================================================================

comment on schema haulvia is
  'Haulvia canonical application schema. P2C contract SHA-256: 95F81FFFCEFB9902210F06AA1E718E2FD94694B98FBA901F2C7543A397FF828F';

comment on schema haulvia_command is
  'Haulvia trusted command schema. P2C contract SHA-256: 95F81FFFCEFB9902210F06AA1E718E2FD94694B98FBA901F2C7543A397FF828F';


-- ============================================================================
-- End P2C migration.
-- ============================================================================

commit;