-- Haulvia Phase 2 Block P2D acceptance suite v1
--
-- Contract:
--   docs/Haulvia_P2D_Private_Storage_and_Retention_Contract_v1.md
--
-- Contract SHA-256:
--   7BF893FB425A236691C158EF10B07EE64365A53289C5EC224138283FF7E7EFAF
--
-- Requires cumulative migrations:
--   Foundation
--   Blocks A-E
--   P2A
--   P2B
--   P2C
--   P2D
--
-- This suite is rollback-only.
--
-- IMPORTANT:
-- The P2D migration intentionally has no COMMIT while this suite is under
-- construction. During development, run the P2D migration and this acceptance
-- file in the same psql session so all P2D objects remain visible and the final
-- acceptance ROLLBACK removes the entire P2D test transaction.


begin;


set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


-- ============================================================================
-- Test harness
-- ============================================================================

create temp table p2d_test_results (
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
as $function$
begin
  insert into p2d_test_results (
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
      'P2D acceptance failure: % -- %',
      p_test_name,
      coalesce(
        p_detail,
        'condition evaluated false'
      );
  end if;
end;
$function$;


-- Execute arbitrary SQL and return true only when it raises the expected
-- SQLSTATE and, when supplied, contains the expected message fragment.
create or replace function pg_temp.expect_error(
  p_sql text,
  p_expected_sqlstate text default null,
  p_message_contains text default null
)
returns boolean
language plpgsql
as $function$
declare
  v_sqlstate text;
  v_message text;
begin
  begin
    execute p_sql;

    return false;

  exception
    when others then
      get stacked diagnostics
        v_sqlstate = returned_sqlstate,
        v_message = message_text;

      if p_expected_sqlstate is not null
         and v_sqlstate <> p_expected_sqlstate then
        return false;
      end if;

      if p_message_contains is not null
         and position(
           lower(p_message_contains)
           in lower(coalesce(v_message, ''))
         ) = 0 then
        return false;
      end if;

      return true;
  end;
end;
$function$;


-- Returns true only when the named role has no ordinary raw relation
-- privileges across the five P2D private-storage base tables.
create or replace function pg_temp.p2d_storage_tables_denied(
  p_role_name text
)
returns boolean
language plpgsql
as $function$
declare
  v_role_oid oid;
begin
  select oid
  into v_role_oid
  from pg_roles
  where rolname = p_role_name;

  if v_role_oid is null then
    return false;
  end if;

  return not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind = 'r'
      and c.relname in (
        'private_storage_objects',
        'private_storage_object_events',
        'private_storage_object_holds',
        'private_storage_deletion_requests',
        'private_storage_access_events'
      )
      and (
        has_table_privilege(
          v_role_oid,
          c.oid,
          'SELECT'
        )
        or has_table_privilege(
          v_role_oid,
          c.oid,
          'INSERT'
        )
        or has_table_privilege(
          v_role_oid,
          c.oid,
          'UPDATE'
        )
        or has_table_privilege(
          v_role_oid,
          c.oid,
          'DELETE'
        )
        or has_table_privilege(
          v_role_oid,
          c.oid,
          'TRUNCATE'
        )
        or has_table_privilege(
          v_role_oid,
          c.oid,
          'REFERENCES'
        )
        or has_table_privilege(
          v_role_oid,
          c.oid,
          'TRIGGER'
        )
      )
  );
end;
$function$;


-- ============================================================================
-- P2D-01
-- Provider-neutral storage model
-- ============================================================================

select pg_temp.assert_true(
  'P2D-01 migration does not depend on Supabase storage schema',

  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and (
        p.proname like '%private_storage%'
        or p.proname in (
          'insert_evidence_array',
          'apply_e09_authorize_custody_transfer'
        )
      )
      and pg_get_functiondef(p.oid)
            ~ '(^|[^a-zA-Z0-9_])storage\.'
  ),

  'P2D private-storage functions must remain provider-neutral and must not reference storage.*.'
);


-- ============================================================================
-- P2D-02
-- Canonical private-storage relation
-- ============================================================================

select pg_temp.assert_true(
  'P2D-02 private_storage_objects exists',

  to_regclass(
    'haulvia.private_storage_objects'
  ) is not null,

  'Expected haulvia.private_storage_objects.'
);


-- ============================================================================
-- P2D-03
-- Canonical UUID identity
-- ============================================================================

select pg_temp.assert_true(
  'P2D-03 private storage objects use UUID primary-key identity',

  exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
            'private_storage_objects'
      and c.column_name = 'id'
      and c.data_type = 'uuid'
      and c.is_nullable = 'NO'
  )

  and exists (
    select 1
    from pg_constraint con
    join pg_class c
      on c.oid = con.conrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    join pg_attribute a
      on a.attrelid = c.oid
     and a.attname = 'id'
    where n.nspname = 'haulvia'
      and c.relname =
            'private_storage_objects'
      and con.contype = 'p'
      and a.attnum = any(
        con.conkey
      )
  ),

  'private_storage_objects.id must be the canonical non-null UUID primary key.'
);


-- ============================================================================
-- P2D-04
-- Provider locator uniqueness
-- ============================================================================

select pg_temp.assert_true(
  'P2D-04 provider bucket and object key are unique',

  exists (
    select 1
    from pg_indexes i
    where i.schemaname = 'haulvia'
      and i.tablename =
            'private_storage_objects'
      and lower(i.indexdef)
            like '%unique%'
      and regexp_replace(
            lower(i.indexdef),
            '\s+',
            ' ',
            'g'
          )
          like '%(storage_provider, bucket_key, object_key)%'
  ),

  'Expected a unique provider/bucket/object locator constraint or index.'
);


-- ============================================================================
-- P2D-07
-- Frozen lifecycle vocabulary
-- ============================================================================

select pg_temp.assert_true(
  'P2D-07 private storage lifecycle contains exactly the six frozen states',

  (
    select array_agg(
      e.enumlabel::text
      order by e.enumsortorder
    )
    from pg_type t
    join pg_namespace n
      on n.oid = t.typnamespace
    join pg_enum e
      on e.enumtypid = t.oid
    where n.nspname = 'haulvia'
      and t.typname =
            'private_storage_lifecycle_status'
  ) = array[
    'RESERVED',
    'AVAILABLE',
    'QUARANTINED',
    'DELETION_PENDING',
    'PURGED',
    'ABANDONED'
  ]::text[],

  'Lifecycle enum must match the frozen P2D state vocabulary exactly.'
);


-- ============================================================================
-- P2D-19
-- Explicit deletion-request representation
-- ============================================================================

select pg_temp.assert_true(
  'P2D-19 deletion requests are explicit domain records',

  to_regclass(
    'haulvia.private_storage_deletion_requests'
  ) is not null

  and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
            'private_storage_deletion_requests'
      and c.column_name = 'decision'
  ),

  'Expected explicit private_storage_deletion_requests records with a decision state.'
);


-- ============================================================================
-- P2D-28
-- PUBLIC raw-table denial
-- ============================================================================

select pg_temp.assert_true(
  'P2D-28 PUBLIC has no raw P2D relation privileges',

  not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    cross join lateral aclexplode(
      coalesce(
        c.relacl,
        acldefault(
          'r',
          c.relowner
        )
      )
    ) acl
    where n.nspname = 'haulvia'
      and c.relkind = 'r'
      and c.relname in (
        'private_storage_objects',
        'private_storage_object_events',
        'private_storage_object_holds',
        'private_storage_deletion_requests',
        'private_storage_access_events'
      )
      and acl.grantee = 0
  ),

  'PUBLIC must have no ACL entry on the five P2D storage tables.'
);


-- ============================================================================
-- P2D-29
-- anon raw-table denial
-- ============================================================================

select pg_temp.assert_true(
  'P2D-29 anon has no raw P2D relation privileges',

  pg_temp.p2d_storage_tables_denied(
    'anon'
  ),

  'anon must have no effective raw privilege on P2D storage tables.'
);


-- ============================================================================
-- P2D-30
-- authenticated raw-table denial
-- ============================================================================

select pg_temp.assert_true(
  'P2D-30 authenticated has no raw P2D relation privileges',

  pg_temp.p2d_storage_tables_denied(
    'authenticated'
  ),

  'authenticated must have no effective raw privilege on P2D storage tables.'
);


-- ============================================================================
-- P2D-31
-- No broad raw service-role grant
-- ============================================================================

select pg_temp.assert_true(
  'P2D-31 service_role has no broad raw P2D table grant',

  pg_temp.p2d_storage_tables_denied(
    'service_role'
  ),

  'P2D storage access must remain command-mediated even for service_role.'
);


-- ============================================================================
-- P2D-32
-- RLS coverage
-- ============================================================================

select pg_temp.assert_true(
  'P2D-32 all five P2D base tables have RLS enabled',

  (
    select
      count(*) = 5
      and count(*) filter (
        where c.relrowsecurity
      ) = 5
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind = 'r'
      and c.relname in (
        'private_storage_objects',
        'private_storage_object_events',
        'private_storage_object_holds',
        'private_storage_deletion_requests',
        'private_storage_access_events'
      )
  ),

  'Every P2D private-storage base table must have relrowsecurity=true.'
);


-- ============================================================================
-- P2D-33
-- No permissive client raw-table policy
-- ============================================================================

select pg_temp.assert_true(
  'P2D-33 no P2D raw-table policy grants anon or authenticated access',

  not exists (
    select 1
    from pg_policy pol
    join pg_class c
      on c.oid = pol.polrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname in (
        'private_storage_objects',
        'private_storage_object_events',
        'private_storage_object_holds',
        'private_storage_deletion_requests',
        'private_storage_access_events'
      )
      and (
        0::oid = any(
          pol.polroles
        )
        or exists (
          select 1
          from pg_roles r
          where r.rolname in (
            'anon',
            'authenticated'
          )
            and r.oid = any(
              pol.polroles
            )
        )
      )
  ),

  'P2D must not create a PUBLIC/anon/authenticated raw-table policy.'
);


-- ============================================================================
-- P2D-34
-- SECURITY DEFINER pinned search paths
-- ============================================================================

select pg_temp.assert_true(
  'P2D-34 P2D SECURITY DEFINER entry points use controlled pinned search paths',

  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname =
            'haulvia_command'
      and (
        p.proname =
          'execute_p2d_storage_command'
        or p.proname in (
          'command_reserve_private_storage_object',
          'command_finalize_private_storage_object',
          'command_abandon_private_storage_object',
          'command_quarantine_private_storage_object',
          'command_release_private_storage_quarantine',
          'command_place_private_storage_hold',
          'command_release_private_storage_hold',
          'command_request_private_storage_deletion',
          'command_approve_private_storage_deletion',
          'command_reject_private_storage_deletion',
          'command_cancel_private_storage_deletion',
          'command_mark_private_storage_deletion_pending',
          'command_confirm_private_storage_purge',
          'command_prepare_compliance_document_access',
          'command_prepare_stop_evidence_access',
          'command_register_compliance_document'
        )
      )
      and (
        not p.prosecdef
        or not exists (
          select 1
          from unnest(
            coalesce(
              p.proconfig,
              array[]::text[]
            )
          ) cfg
          where cfg like 'search_path=%'
            and cfg like '%haulvia%'
            and cfg like '%haulvia_command%'
            and cfg like '%pg_temp%'
            and cfg not like '%public%'
        )
      )
  ),

  'Every P2D trusted entry point must be SECURITY DEFINER with a pinned non-public search_path.'
);


-- ============================================================================
-- P2D-35
-- Privileged-function ownership
-- ============================================================================

select pg_temp.assert_true(
  'P2D-35 P2D privileged functions are not owned by client roles',

  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname =
            'haulvia_command'
      and (
        p.proname =
          'execute_p2d_storage_command'
        or p.proname like 'command_%private_storage%'
        or p.proname in (
          'command_prepare_compliance_document_access',
          'command_prepare_stop_evidence_access',
          'command_register_compliance_document'
        )
      )
      and pg_get_userbyid(
        p.proowner
      ) in (
        'anon',
        'authenticated'
      )
  ),

  'P2D SECURITY DEFINER functions must not be client-role owned.'
);


-- ============================================================================
-- P2D-36
-- Exact service-role wrapper surface
-- ============================================================================

select pg_temp.assert_true(
  'P2D-36 only the 16 intended P2D wrappers are executable by service_role',

  (
    select count(*) = 16
    from (
      values
        ('command_reserve_private_storage_object'),
        ('command_finalize_private_storage_object'),
        ('command_abandon_private_storage_object'),
        ('command_quarantine_private_storage_object'),
        ('command_release_private_storage_quarantine'),
        ('command_place_private_storage_hold'),
        ('command_release_private_storage_hold'),
        ('command_request_private_storage_deletion'),
        ('command_approve_private_storage_deletion'),
        ('command_reject_private_storage_deletion'),
        ('command_cancel_private_storage_deletion'),
        ('command_mark_private_storage_deletion_pending'),
        ('command_confirm_private_storage_purge'),
        ('command_prepare_compliance_document_access'),
        ('command_prepare_stop_evidence_access'),
        ('command_register_compliance_document')
    ) expected(function_name)
    where has_function_privilege(
      'service_role',
      to_regprocedure(
        'haulvia_command.' ||
        expected.function_name ||
        '(jsonb)'
      ),
      'EXECUTE'
    )
  )

  and not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where (
      (
        n.nspname = 'haulvia'
        and p.proname in (
          'resolve_private_storage_retention',
          'guard_private_storage_object_update',
          'guard_private_storage_hold_update',
          'guard_private_storage_deletion_request_update',
          'assert_private_storage_object_attachable',
          'guard_compliance_document_private_object',
          'guard_stop_evidence_private_object',
          'guard_compliance_document_private_object_update',
          'guard_stop_evidence_private_object_update'
        )
      )
      or
      (
        n.nspname = 'haulvia_command'
        and (
          p.proname like 'apply_p2d_%'
          or p.proname =
               'execute_p2d_storage_command'
          or p.proname in (
            'assert_compliance_document_upload_authority',
            'assert_stop_evidence_storage_authority',
            'assert_storage_worker',
            'assert_private_storage_lifecycle_manager'
          )
        )
      )
    )
      and has_function_privilege(
        'service_role',
        p.oid,
        'EXECUTE'
      )
  ),

  'service_role must receive only the 16 explicit P2D command wrappers.'
);


-- ============================================================================
-- P2D-37
-- Internal helper closure
-- ============================================================================

select pg_temp.assert_true(
  'P2D-37 internal P2D helpers are unavailable to PUBLIC client roles and direct service_role invocation',

  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where (
      (
        n.nspname = 'haulvia'
        and p.proname in (
          'resolve_private_storage_retention',
          'guard_private_storage_object_update',
          'guard_private_storage_hold_update',
          'guard_private_storage_deletion_request_update',
          'assert_private_storage_object_attachable',
          'guard_compliance_document_private_object',
          'guard_stop_evidence_private_object',
          'guard_compliance_document_private_object_update',
          'guard_stop_evidence_private_object_update'
        )
      )
      or
      (
        n.nspname = 'haulvia_command'
        and (
          p.proname like 'apply_p2d_%'
          or p.proname =
               'execute_p2d_storage_command'
          or p.proname in (
            'assert_compliance_document_upload_authority',
            'assert_stop_evidence_storage_authority',
            'assert_storage_worker',
            'assert_private_storage_lifecycle_manager'
          )
        )
      )
    )
      and (
        exists (
          select 1
          from aclexplode(
            coalesce(
              p.proacl,
              acldefault(
                'f',
                p.proowner
              )
            )
          ) acl
          where acl.grantee = 0
            and acl.privilege_type = 'EXECUTE'
        )
        or has_function_privilege(
          'anon',
          p.oid,
          'EXECUTE'
        )
        or has_function_privilege(
          'authenticated',
          p.oid,
          'EXECUTE'
        )
        or has_function_privilege(
          'service_role',
          p.oid,
          'EXECUTE'
        )
      )
  ),

  'Internal P2D functions must not be directly executable by PUBLIC, anon, authenticated, or service_role.'
);


-- ============================================================================
-- P2D-42
-- No independent consumer storage locator/hash
-- ============================================================================

select pg_temp.assert_true(
  'P2D-42 compliance documents no longer store independent storage key or content hash',

  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
            'compliance_documents'
      and c.column_name in (
        'storage_object_key',
        'content_sha256'
      )
  )

  and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
            'compliance_documents'
      and c.column_name =
            'private_storage_object_id'
  ),

  'Compliance documents must reference canonical private storage instead of maintaining an independent key/hash.'
);


-- ============================================================================
-- P2D-45
-- Canonical stop-evidence binary identity
-- ============================================================================

select pg_temp.assert_true(
  'P2D-45 stop-evidence command uses privateStorageObjectId and rejects legacy raw storage identity',

  (
    select
      pg_get_functiondef(p.oid)
        like '%privateStorageObjectId%'
      and pg_get_functiondef(p.oid)
        like '%storageObjectKey%'
      and pg_get_functiondef(p.oid)
        like '%contentSha256%'
      and pg_get_functiondef(p.oid)
        like '%EVIDENCE_INVALID%'
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname =
            'haulvia_command'
      and p.proname =
            'insert_evidence_array'
    limit 1
  ),

  'insert_evidence_array must use the canonical private object ID while explicitly rejecting legacy key/hash input.'
);


-- ============================================================================
-- Remaining P2D behavioral and authority checks are appended below.
-- ============================================================================

-- ============================================================================
-- P2D ACCEPTANCE PART 2A
-- Retention resolution and private-object lifecycle invariants
-- ============================================================================


-- ============================================================================
-- Authority fixture used only inside this rollback-only acceptance transaction.
--
-- Creator and approver are deliberately separate. The approver receives the
-- existing PLATFORM_ADMIN role inside a HAULVIA organization and performs the
-- publication using a fresh MFA reauthentication session.
-- ============================================================================

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  'd2d00000-0000-0000-0000-000000000001'::uuid,
  'p2d-test-haulvia',
  'HAULVIA',
  'P2D Test Haulvia Operations',
  'P2D Test Haulvia'
);


insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'd2d00000-0000-0000-0000-000000000011'::uuid,
    'P2D Retention Policy Creator'
  ),
  (
    'd2d00000-0000-0000-0000-000000000012'::uuid,
    'P2D Retention Policy Approver'
  );


insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status
)
values (
  'd2d00000-0000-0000-0000-000000000021'::uuid,
  'd2d00000-0000-0000-0000-000000000001'::uuid,
  'd2d00000-0000-0000-0000-000000000012'::uuid,
  'ACTIVE'
);


insert into haulvia.membership_roles (
  membership_id,
  role_id
)
select
  'd2d00000-0000-0000-0000-000000000021'::uuid,
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
  'd2d00000-0000-0000-0000-000000000031'::uuid,
  'd2d00000-0000-0000-0000-000000000012'::uuid,
  'd2d00000-0000-0000-0000-000000000001'::uuid,
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes'
);


-- Prove the approval fixture actually carries the authority P2A expects.
do $$
begin
  if not haulvia.has_permission(
    'd2d00000-0000-0000-0000-000000000012'::uuid,
    'd2d00000-0000-0000-0000-000000000001'::uuid,
    'POLICY_PUBLISH'
  ) then
    raise exception
      'P2D acceptance fixture approver does not hold POLICY_PUBLISH';
  end if;
end
$$;


-- ============================================================================
-- RESERVED fixtures
-- ============================================================================

insert into haulvia.private_storage_objects (
  id,
  storage_provider,
  bucket_key,
  object_key,
  original_file_name,
  lifecycle_status,
  reserved_by_worker_authority
)
values
  (
    'd2d00000-0000-0000-0000-000000000101'::uuid,
    'P2D_TEST_PROVIDER',
    'p2d-private',
    'retention/no-policy.pdf',
    'no-policy.pdf',
    'RESERVED',
    'STORAGE_WORKER'
  ),
  (
    'd2d00000-0000-0000-0000-000000000102'::uuid,
    'P2D_TEST_PROVIDER',
    'p2d-private',
    'retention/finalized-v2.pdf',
    'finalized-v2.pdf',
    'RESERVED',
    'STORAGE_WORKER'
  ),
  (
    'd2d00000-0000-0000-0000-000000000103'::uuid,
    'P2D_TEST_PROVIDER',
    'p2d-private',
    'retention/abandoned.pdf',
    'abandoned.pdf',
    'RESERVED',
    'STORAGE_WORKER'
  );


-- ============================================================================
-- P2D-12
-- Finalization fails closed without an approved/effective retention policy.
--
-- P2A intentionally provides only the DRAFT version-1 RETENTION_POLICY shell
-- at this point.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-12 finalization fails closed without approved effective retention policy',

  pg_temp.expect_error(
    $sql$
      select haulvia_command.apply_p2d_finalize_private_storage_object(
        jsonb_build_object(
          'privateStorageObjectId',
          'd2d00000-0000-0000-0000-000000000101'::uuid,

          'commandId',
          'd2d00000-0000-0000-0000-000000000201'::uuid,

          'workerAuthority',
          'STORAGE_WORKER',

          'mediaType',
          'application/pdf',

          'byteSize',
          '128',

          'contentSha256',
          repeat('a', 64),

          'retentionClass',
          'P2D_TEST'
        )
      )
    $sql$,
    '55000',
    'No approved and effective RETENTION_POLICY'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000101'::uuid
      and pso.lifecycle_status = 'RESERVED'
      and pso.finalized_at is null
      and pso.retention_policy_version_id is null
      and pso.retention_class is null
      and pso.retention_snapshot is null
      and pso.retain_until is null
  ),

  'Failed finalization must leave the object RESERVED and must not invent retention metadata.'
);


-- ============================================================================
-- Publish RETENTION_POLICY version 2 through the P2A dual-control rules.
--
-- 37 seconds is deliberately arbitrary. It proves P2D derives duration from
-- approved configuration rather than a built-in legal duration.
-- ============================================================================

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
  clock_timestamp() - interval '5 minutes',
  jsonb_build_object(
    'retentionClasses',
    jsonb_build_object(
      'P2D_TEST',
      jsonb_build_object(
        'durationSeconds',
        37
      )
    )
  ),
  repeat('b', 64),
  true,
  'd2d00000-0000-0000-0000-000000000011'::uuid,
  'd2d00000-0000-0000-0000-000000000012'::uuid,
  clock_timestamp(),
  'd2d00000-0000-0000-0000-000000000031'::uuid,
  'P2D acceptance retention policy version two'
from haulvia.policy_sets ps
where ps.policy_key = 'RETENTION_POLICY';


-- ============================================================================
-- Finalize the principal test object under version 2.
-- ============================================================================

select haulvia_command.apply_p2d_finalize_private_storage_object(
  jsonb_build_object(
    'privateStorageObjectId',
    'd2d00000-0000-0000-0000-000000000102'::uuid,

    'commandId',
    'd2d00000-0000-0000-0000-000000000202'::uuid,

    'workerAuthority',
    'STORAGE_WORKER',

    'mediaType',
    'application/pdf',

    'byteSize',
    '4096',

    'contentSha256',
    repeat('c', 64),

    'retentionClass',
    'P2D_TEST'
  )
);


-- Freeze the object's version-2 retention facts so P2D-15 can verify that a
-- subsequently published policy version does not rewrite history.

create temporary table p2d_v2_object_snapshot
on commit drop
as
select
  id,
  retention_policy_version_id,
  retention_class,
  retention_snapshot,
  retain_until,
  finalized_at
from haulvia.private_storage_objects
where id =
  'd2d00000-0000-0000-0000-000000000102'::uuid;


-- ============================================================================
-- P2D-05
-- AVAILABLE metadata completeness
-- ============================================================================

select pg_temp.assert_true(
  'P2D-05 AVAILABLE objects contain complete canonical binary metadata',

  exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000102'::uuid

      and pso.lifecycle_status = 'AVAILABLE'

      and nullif(
        btrim(pso.storage_provider),
        ''
      ) is not null

      and nullif(
        btrim(pso.bucket_key),
        ''
      ) is not null

      and nullif(
        btrim(pso.object_key),
        ''
      ) is not null

      and nullif(
        btrim(pso.media_type),
        ''
      ) is not null

      and pso.byte_size = 4096

      and pso.content_sha256 = repeat('c', 64)

      and pso.content_sha256
        ~ '^[0-9a-f]{64}$'
  ),

  'Finalized AVAILABLE object must retain provider/bucket/key/media/size/lowercase SHA-256 metadata.'
);


-- ============================================================================
-- P2D-06
-- Digest immutability after availability
-- ============================================================================

select pg_temp.assert_true(
  'P2D-06 content digest cannot change after availability',

  pg_temp.expect_error(
    $sql$
      update haulvia.private_storage_objects
      set content_sha256 = repeat('d', 64)
      where id =
        'd2d00000-0000-0000-0000-000000000102'::uuid
    $sql$,
    '55000'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000102'::uuid
      and pso.content_sha256 = repeat('c', 64)
  ),

  'An AVAILABLE object digest must remain the finalized digest.'
);


-- ============================================================================
-- P2D-08
-- Invalid lifecycle transition rejection
-- ============================================================================

select pg_temp.assert_true(
  'P2D-08 invalid private storage lifecycle transitions are rejected',

  pg_temp.expect_error(
    $sql$
      update haulvia.private_storage_objects
      set
        lifecycle_status = 'ABANDONED',
        abandoned_at = clock_timestamp()
      where id =
        'd2d00000-0000-0000-0000-000000000102'::uuid
    $sql$,
    '55000'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000102'::uuid
      and pso.lifecycle_status = 'AVAILABLE'
  ),

  'AVAILABLE -> ABANDONED is not an approved P2D transition.'
);


-- ============================================================================
-- P2D-10
-- ABANDONED is terminal
-- ============================================================================

update haulvia.private_storage_objects
set
  lifecycle_status = 'ABANDONED',
  abandoned_at = clock_timestamp()
where id =
  'd2d00000-0000-0000-0000-000000000103'::uuid;


select pg_temp.assert_true(
  'P2D-10 ABANDONED private storage objects are terminal',

  exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000103'::uuid
      and pso.lifecycle_status = 'ABANDONED'
  )

  and pg_temp.expect_error(
    $sql$
      update haulvia.private_storage_objects
      set lifecycle_status = 'RESERVED'
      where id =
        'd2d00000-0000-0000-0000-000000000103'::uuid
    $sql$,
    '55000'
  ),

  'Once ABANDONED, a private-storage object must not return to an active lifecycle state.'
);


-- ============================================================================
-- P2D-11
-- RESERVED objects cannot back ordinary binary evidence
-- ============================================================================

select pg_temp.assert_true(
  'P2D-11 RESERVED objects cannot be attached as ordinary binary evidence',

  pg_temp.expect_error(
    $sql$
      select haulvia.assert_private_storage_object_attachable(
        'd2d00000-0000-0000-0000-000000000101'::uuid,
        'stop_evidence'
      )
    $sql$
  )

  and exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000101'::uuid
      and pso.lifecycle_status = 'RESERVED'
  ),

  'Only AVAILABLE canonical private objects may back binary domain evidence.'
);


-- ============================================================================
-- P2D-14
-- Exact policy version/class snapshot
-- ============================================================================

select pg_temp.assert_true(
  'P2D-14 finalization snapshots the exact retention policy version and class',

  exists (
    select 1
    from haulvia.private_storage_objects pso
    join haulvia.policy_versions pv
      on pv.id =
         pso.retention_policy_version_id
    join haulvia.policy_sets ps
      on ps.id = pv.policy_set_id
    where pso.id =
      'd2d00000-0000-0000-0000-000000000102'::uuid

      and ps.policy_key = 'RETENTION_POLICY'
      and pv.version_no = 2

      and pso.retention_class =
          'P2D_TEST'

      and pso.retention_snapshot
            ->> 'policyKey'
          = 'RETENTION_POLICY'

      and pso.retention_snapshot
            ->> 'policyVersionId'
          = pv.id::text

      and pso.retention_snapshot
            ->> 'policyVersionNo'
          = '2'

      and pso.retention_snapshot
            ->> 'configSha256'
          = repeat('b', 64)

      and pso.retention_snapshot
            ->> 'retentionClass'
          = 'P2D_TEST'

      and pso.retention_snapshot
            -> 'resolvedRule'
            ->> 'durationSeconds'
          = '37'
  ),

  'Retention snapshot must identify the exact approved version, hash, class and resolved rule.'
);


-- ============================================================================
-- P2D-16
-- Persisted retain_until
-- ============================================================================

select pg_temp.assert_true(
  'P2D-16 retain_until is persisted for finalized objects',

  exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000102'::uuid

      and pso.retain_until is not null

      and pso.finalized_at is not null

      and pso.retain_until =
          pso.finalized_at
          + interval '37 seconds'

      and pso.retention_snapshot
            ->> 'retainUntil'
          = to_jsonb(
              pso.retain_until
            ) #>> '{}'
  ),

  'Finalization must persist the resolver-derived retain_until timestamp.'
);


-- ============================================================================
-- Publish a later RETENTION_POLICY version.
--
-- It becomes effective in the future relative to the already-finalized object,
-- and uses a different arbitrary duration (91 seconds).
-- ============================================================================

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
  3,
  'APPROVED',
  clock_timestamp() + interval '10 minutes',
  jsonb_build_object(
    'retentionClasses',
    jsonb_build_object(
      'P2D_TEST',
      jsonb_build_object(
        'durationSeconds',
        91
      )
    )
  ),
  repeat('e', 64),
  true,
  'd2d00000-0000-0000-0000-000000000011'::uuid,
  'd2d00000-0000-0000-0000-000000000012'::uuid,
  clock_timestamp(),
  'd2d00000-0000-0000-0000-000000000031'::uuid,
  'P2D acceptance retention policy version three'
from haulvia.policy_sets ps
where ps.policy_key = 'RETENTION_POLICY';


-- ============================================================================
-- P2D-13
-- No hard-coded legal duration
--
-- Version 2 resolves to 37 seconds while the later version resolves to
-- 91 seconds using the same retention class.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-13 retention duration is derived from approved policy configuration',

  exists (
    select 1
    from p2d_v2_object_snapshot s
    cross join lateral
      haulvia.resolve_private_storage_retention(
        'P2D_TEST',
        s.finalized_at
      ) r
    where r.retention_policy_version_id =
          s.retention_policy_version_id
      and r.retain_until =
          s.finalized_at
          + interval '37 seconds'
  )

  and exists (
    select 1
    from haulvia.policy_versions pv
    join haulvia.policy_sets ps
      on ps.id = pv.policy_set_id
    cross join lateral
      haulvia.resolve_private_storage_retention(
        'P2D_TEST',
        pv.effective_from
        + interval '1 minute'
      ) r
    where ps.policy_key = 'RETENTION_POLICY'
      and pv.version_no = 3
      and r.retention_policy_version_id = pv.id
      and r.retain_until =
          pv.effective_from
          + interval '1 minute'
          + interval '91 seconds'
  ),

  'Different approved policy versions must drive different configured retention durations.'
);


-- ============================================================================
-- P2D-15
-- Historical retention decisions remain stable
-- ============================================================================

select pg_temp.assert_true(
  'P2D-15 newer policy versions do not rewrite historical retention decisions',

  exists (
    select 1
    from haulvia.private_storage_objects pso
    join p2d_v2_object_snapshot s
      on s.id = pso.id
    where pso.id =
      'd2d00000-0000-0000-0000-000000000102'::uuid

      and pso.retention_policy_version_id
          is not distinct from
          s.retention_policy_version_id

      and pso.retention_class
          is not distinct from
          s.retention_class

      and pso.retention_snapshot
          is not distinct from
          s.retention_snapshot

      and pso.retain_until
          is not distinct from
          s.retain_until

      and pso.finalized_at
          is not distinct from
          s.finalized_at
  )

  and exists (
    select 1
    from p2d_v2_object_snapshot s
    cross join lateral
      haulvia.resolve_private_storage_retention(
        'P2D_TEST',
        s.finalized_at
      ) r
    where r.retention_policy_version_id =
          s.retention_policy_version_id

      and r.retention_snapshot
            ->> 'policyVersionNo'
          = '2'

      and r.retain_until =
          s.retain_until
  ),

  'Publishing a later retention policy must not alter or reinterpret an earlier finalized object.'
);


-- ============================================================================
-- P2D-09 is intentionally deferred to the deletion/purge acceptance block.
-- That block will produce a legitimate PURGED object through the approved
-- deletion lifecycle and then prove PURGED is terminal.
-- ============================================================================


-- ============================================================================
-- P2D ACCEPTANCE PART 2B
-- Holds, deletion eligibility, physical purge and terminal lifecycle
-- ============================================================================


-- ============================================================================
-- Part 2B retention fixture.
--
-- Version 4 defines:
--   * P2D_EXPIRED = 1 second
--   * P2D_FUTURE  = 3600 seconds
--
-- The short duration allows the acceptance transaction to exercise the real
-- deletion lifecycle without mutating immutable retention metadata.
-- ============================================================================

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
  4,
  'APPROVED',
  clock_timestamp() - interval '1 minute',

  jsonb_build_object(
    'retentionClasses',
    jsonb_build_object(
      'P2D_EXPIRED',
      jsonb_build_object(
        'durationSeconds',
        1
      ),
      'P2D_FUTURE',
      jsonb_build_object(
        'durationSeconds',
        3600
      )
    )
  ),

  repeat('f', 64),
  true,

  'd2d00000-0000-0000-0000-000000000011'::uuid,
  'd2d00000-0000-0000-0000-000000000012'::uuid,

  clock_timestamp(),

  'd2d00000-0000-0000-0000-000000000031'::uuid,

  'P2D acceptance deletion lifecycle retention policy'
from haulvia.policy_sets ps
where ps.policy_key = 'RETENTION_POLICY';


-- ============================================================================
-- Private-object fixtures
--
-- 201 = deletion-request-only test, retention still active.
-- 203 = normal full deletion lifecycle, one-second retention.
-- ============================================================================

insert into haulvia.private_storage_objects (
  id,
  storage_provider,
  bucket_key,
  object_key,
  original_file_name,
  lifecycle_status,
  reserved_by_worker_authority
)
values
  (
    'd2d00000-0000-0000-0000-000000000201'::uuid,
    'P2D_TEST_PROVIDER',
    'p2d-private',
    'deletion/request-only.pdf',
    'request-only.pdf',
    'RESERVED',
    'STORAGE_WORKER'
  ),
  (
    'd2d00000-0000-0000-0000-000000000203'::uuid,
    'P2D_TEST_PROVIDER',
    'p2d-private',
    'deletion/full-lifecycle.pdf',
    'full-lifecycle.pdf',
    'RESERVED',
    'STORAGE_WORKER'
  );


-- Finalize 201 under a long, still-active retention class.

select haulvia_command.apply_p2d_finalize_private_storage_object(
  jsonb_build_object(
    'privateStorageObjectId',
    'd2d00000-0000-0000-0000-000000000201'::uuid,

    'commandId',
    'd2d00000-0000-0000-0000-000000000601'::uuid,

    'workerAuthority',
    'STORAGE_WORKER',

    'mediaType',
    'application/pdf',

    'byteSize',
    '501',

    'contentSha256',
    repeat('1', 64),

    'retentionClass',
    'P2D_FUTURE'
  )
);


-- Finalize 203 under the one-second acceptance retention class.

select haulvia_command.apply_p2d_finalize_private_storage_object(
  jsonb_build_object(
    'privateStorageObjectId',
    'd2d00000-0000-0000-0000-000000000203'::uuid,

    'commandId',
    'd2d00000-0000-0000-0000-000000000603'::uuid,

    'workerAuthority',
    'STORAGE_WORKER',

    'mediaType',
    'application/pdf',

    'byteSize',
    '503',

    'contentSha256',
    repeat('3', 64),

    'retentionClass',
    'P2D_EXPIRED'
  )
);


-- IDs returned by the command layer are kept here rather than guessed.

create temporary table p2d_part2b_ids (
  key text primary key,
  id uuid not null
) on commit drop;


-- ============================================================================
-- P2D-20
-- A deletion request is governance intent, not physical deletion.
-- ============================================================================

insert into p2d_part2b_ids (
  key,
  id
)
select
  'request-only-deletion',
  (
    haulvia_command.apply_p2d_request_private_storage_deletion(
      jsonb_build_object(
        'privateStorageObjectId',
        'd2d00000-0000-0000-0000-000000000201'::uuid,

        'commandId',
        'd2d00000-0000-0000-0000-000000000701'::uuid,

        'actorProfileId',
        'd2d00000-0000-0000-0000-000000000012'::uuid,

        'actorOrganizationId',
        'd2d00000-0000-0000-0000-000000000001'::uuid,

        'reauthSessionId',
        'd2d00000-0000-0000-0000-000000000031'::uuid,

        'reason',
        'P2D acceptance deletion request only'
      )
    )
    ->> 'deletionRequestId'
  )::uuid;


select pg_temp.assert_true(
  'P2D-20 deletion request alone does not mark the object PURGED',

  exists (
    select 1
    from haulvia.private_storage_deletion_requests dr
    where dr.id = (
      select id
      from p2d_part2b_ids
      where key = 'request-only-deletion'
    )
      and dr.private_storage_object_id =
          'd2d00000-0000-0000-0000-000000000201'::uuid
      and dr.decision = 'PENDING'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000201'::uuid
      and pso.lifecycle_status = 'AVAILABLE'
      and pso.purged_at is null
      and pso.purge_provider_reference is null
      and pso.purge_correlation_id is null
  ),

  'Creating a deletion request must not claim that provider deletion occurred.'
);


-- Allow the normal full-lifecycle object's one-second retention to expire.

select pg_sleep(1.20);


-- ============================================================================
-- Create and approve the deletion request for object 203.
-- ============================================================================

insert into p2d_part2b_ids (
  key,
  id
)
select
  'full-lifecycle-deletion',
  (
    haulvia_command.apply_p2d_request_private_storage_deletion(
      jsonb_build_object(
        'privateStorageObjectId',
        'd2d00000-0000-0000-0000-000000000203'::uuid,

        'commandId',
        'd2d00000-0000-0000-0000-000000000703'::uuid,

        'actorProfileId',
        'd2d00000-0000-0000-0000-000000000012'::uuid,

        'actorOrganizationId',
        'd2d00000-0000-0000-0000-000000000001'::uuid,

        'reauthSessionId',
        'd2d00000-0000-0000-0000-000000000031'::uuid,

        'reason',
        'P2D acceptance full deletion lifecycle request'
      )
    )
    ->> 'deletionRequestId'
  )::uuid;


select haulvia_command.apply_p2d_decide_private_storage_deletion(
  jsonb_build_object(
    'deletionRequestId',
    (
      select id
      from p2d_part2b_ids
      where key = 'full-lifecycle-deletion'
    ),

    'commandId',
    'd2d00000-0000-0000-0000-000000000713'::uuid,

    'actorProfileId',
    'd2d00000-0000-0000-0000-000000000012'::uuid,

    'actorOrganizationId',
    'd2d00000-0000-0000-0000-000000000001'::uuid,

    'reauthSessionId',
    'd2d00000-0000-0000-0000-000000000031'::uuid,

    'reason',
    'P2D acceptance deletion approval'
  ),
  'APPROVED'::haulvia.private_storage_deletion_decision
);


-- ============================================================================
-- P2D-17
-- Active hold blocks deletion / purge eligibility.
-- ============================================================================

insert into p2d_part2b_ids (
  key,
  id
)
select
  'first-hold',
  (
    haulvia_command.apply_p2d_place_private_storage_hold(
      jsonb_build_object(
        'privateStorageObjectId',
        'd2d00000-0000-0000-0000-000000000203'::uuid,

        'commandId',
        'd2d00000-0000-0000-0000-000000000723'::uuid,

        'actorProfileId',
        'd2d00000-0000-0000-0000-000000000012'::uuid,

        'actorOrganizationId',
        'd2d00000-0000-0000-0000-000000000001'::uuid,

        'reauthSessionId',
        'd2d00000-0000-0000-0000-000000000031'::uuid,

        'holdCategory',
        'LEGAL',

        'reason',
        'P2D acceptance active legal hold'
      )
    )
    ->> 'holdId'
  )::uuid;


select pg_temp.assert_true(
  'P2D-17 active hold blocks deletion eligibility',

  pg_temp.expect_error(
    $sql$
      select haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
        jsonb_build_object(
          'deletionRequestId',
          (
            select id
            from p2d_part2b_ids
            where key = 'full-lifecycle-deletion'
          ),

          'commandId',
          'd2d00000-0000-0000-0000-000000000733'::uuid,

          'actorProfileId',
          'd2d00000-0000-0000-0000-000000000012'::uuid,

          'actorOrganizationId',
          'd2d00000-0000-0000-0000-000000000001'::uuid,

          'reauthSessionId',
          'd2d00000-0000-0000-0000-000000000031'::uuid,

          'reason',
          'P2D acceptance blocked by active hold'
        )
      )
    $sql$,
    'P0001',
    'Private storage object has an active hold and cannot enter deletion pending'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects
    where id =
      'd2d00000-0000-0000-0000-000000000203'::uuid
      and lifecycle_status = 'AVAILABLE'
  ),

  'An active hold must prevent an otherwise eligible object from entering DELETION_PENDING.'
);


-- ============================================================================
-- Release the first hold.
-- ============================================================================

select haulvia_command.apply_p2d_release_private_storage_hold(
  jsonb_build_object(
    'holdId',
    (
      select id
      from p2d_part2b_ids
      where key = 'first-hold'
    ),

    'commandId',
    'd2d00000-0000-0000-0000-000000000743'::uuid,

    'actorProfileId',
    'd2d00000-0000-0000-0000-000000000012'::uuid,

    'actorOrganizationId',
    'd2d00000-0000-0000-0000-000000000001'::uuid,

    'reauthSessionId',
    'd2d00000-0000-0000-0000-000000000031'::uuid,

    'reason',
    'P2D acceptance legal hold release'
  )
);


-- ============================================================================
-- P2D-18
-- Hold placement and release are attributable.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-18 hold placement and release remain attributable',

  exists (
    select 1
    from haulvia.private_storage_object_holds h
    where h.id = (
      select id
      from p2d_part2b_ids
      where key = 'first-hold'
    )

      and h.private_storage_object_id =
          'd2d00000-0000-0000-0000-000000000203'::uuid

      and h.hold_category = 'LEGAL'

      and h.placed_by_profile_id =
          'd2d00000-0000-0000-0000-000000000012'::uuid

      and h.placed_at is not null

      and h.released_by_profile_id =
          'd2d00000-0000-0000-0000-000000000012'::uuid

      and h.release_reason =
          'P2D acceptance legal hold release'

      and h.released_at is not null
  )

  and exists (
    select 1
    from haulvia.private_storage_object_events e
    where e.private_storage_object_id =
      'd2d00000-0000-0000-0000-000000000203'::uuid

      and e.event_type = 'HOLD_PLACED'

      and e.actor_profile_id =
          'd2d00000-0000-0000-0000-000000000012'::uuid

      and e.organization_id =
          'd2d00000-0000-0000-0000-000000000001'::uuid
  )

  and exists (
    select 1
    from haulvia.private_storage_object_events e
    where e.private_storage_object_id =
      'd2d00000-0000-0000-0000-000000000203'::uuid

      and e.event_type = 'HOLD_RELEASED'

      and e.actor_profile_id =
          'd2d00000-0000-0000-0000-000000000012'::uuid

      and e.organization_id =
          'd2d00000-0000-0000-0000-000000000001'::uuid
  ),

  'Both sides of a hold lifecycle must identify the authorized human actor.'
);


-- ============================================================================
-- With retention elapsed, approved deletion and no active hold, object 203 may
-- now enter DELETION_PENDING.
-- ============================================================================

select haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
  jsonb_build_object(
    'deletionRequestId',
    (
      select id
      from p2d_part2b_ids
      where key = 'full-lifecycle-deletion'
    ),

    'commandId',
    'd2d00000-0000-0000-0000-000000000753'::uuid,

    'actorProfileId',
    'd2d00000-0000-0000-0000-000000000012'::uuid,

    'actorOrganizationId',
    'd2d00000-0000-0000-0000-000000000001'::uuid,

    'reauthSessionId',
    'd2d00000-0000-0000-0000-000000000031'::uuid,

    'reason',
    'P2D acceptance enter deletion pending'
  )
);


-- ============================================================================
-- P2D-21 fixture
--
-- This synthetic DELETION_PENDING row intentionally has future retention.
-- It isolates the physical-purge defensive check independently of the earlier
-- transition guard. The fixture exists only in this rollback transaction.
-- ============================================================================

insert into haulvia.private_storage_objects (
  id,
  storage_provider,
  bucket_key,
  object_key,
  original_file_name,
  media_type,
  byte_size,
  content_sha256,
  lifecycle_status,
  retention_policy_version_id,
  retention_class,
  retention_snapshot,
  retain_until,
  reserved_by_worker_authority,
  reserved_at,
  finalized_at,
  deletion_pending_at
)
select
  'd2d00000-0000-0000-0000-000000000204'::uuid,
  'P2D_TEST_PROVIDER',
  'p2d-private',
  'deletion/future-retention-pending.pdf',
  'future-retention-pending.pdf',
  'application/pdf',
  504,
  repeat('4', 64),
  'DELETION_PENDING',
  pv.id,
  'P2D_FUTURE',
  jsonb_build_object(
    'policyKey',
    'RETENTION_POLICY',
    'policyVersionId',
    pv.id,
    'policyVersionNo',
    pv.version_no,
    'retentionClass',
    'P2D_FUTURE',
    'resolvedRule',
    jsonb_build_object(
      'durationSeconds',
      3600
    )
  ),
  clock_timestamp() + interval '1 hour',
  'STORAGE_WORKER',
  clock_timestamp() - interval '2 minutes',
  clock_timestamp() - interval '1 minute',
  clock_timestamp()
from haulvia.policy_versions pv
join haulvia.policy_sets ps
  on ps.id = pv.policy_set_id
where ps.policy_key = 'RETENTION_POLICY'
  and pv.version_no = 4;


insert into haulvia.private_storage_deletion_requests (
  id,
  private_storage_object_id,
  requested_by_profile_id,
  reason,
  requested_at,
  decision,
  decided_by_profile_id,
  decision_reason,
  decided_at,
  provider_purge_correlation_id,
  correlation_id
)
values (
  'd2d00000-0000-0000-0000-000000000304'::uuid,
  'd2d00000-0000-0000-0000-000000000204'::uuid,
  'd2d00000-0000-0000-0000-000000000012'::uuid,
  'P2D acceptance future-retention deletion fixture',
  clock_timestamp() - interval '30 seconds',
  'APPROVED',
  'd2d00000-0000-0000-0000-000000000012'::uuid,
  'P2D acceptance approved synthetic purge fixture',
  clock_timestamp() - interval '20 seconds',
  'd2d00000-0000-0000-0000-000000000404'::uuid,
  'd2d00000-0000-0000-0000-000000000504'::uuid
);


select pg_temp.assert_true(
  'P2D-21 physical purge is rejected before retention eligibility',

  pg_temp.expect_error(
    $sql$
      select haulvia_command.apply_p2d_confirm_private_storage_purge(
        jsonb_build_object(
          'deletionRequestId',
          'd2d00000-0000-0000-0000-000000000304'::uuid,

          'commandId',
          'd2d00000-0000-0000-0000-000000000604'::uuid,

          'providerPurgeCorrelationId',
          'd2d00000-0000-0000-0000-000000000404'::uuid,

          'purgeProviderReference',
          'p2d-test-provider-purge-too-early',

          'workerAuthority',
          'STORAGE_WORKER'
        )
      )
    $sql$,
    'P0001',
    'Private storage retention period has not elapsed'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects
    where id =
      'd2d00000-0000-0000-0000-000000000204'::uuid
      and lifecycle_status = 'DELETION_PENDING'
      and purged_at is null
  ),

  'The physical purge path must independently enforce retain_until.'
);


-- ============================================================================
-- P2D-22
-- Active hold also blocks the physical purge itself.
-- ============================================================================

insert into p2d_part2b_ids (
  key,
  id
)
select
  'purge-hold',
  (
    haulvia_command.apply_p2d_place_private_storage_hold(
      jsonb_build_object(
        'privateStorageObjectId',
        'd2d00000-0000-0000-0000-000000000203'::uuid,

        'commandId',
        'd2d00000-0000-0000-0000-000000000763'::uuid,

        'actorProfileId',
        'd2d00000-0000-0000-0000-000000000012'::uuid,

        'actorOrganizationId',
        'd2d00000-0000-0000-0000-000000000001'::uuid,

        'reauthSessionId',
        'd2d00000-0000-0000-0000-000000000031'::uuid,

        'holdCategory',
        'DISPUTE',

        'reason',
        'P2D acceptance purge-blocking dispute hold'
      )
    )
    ->> 'holdId'
  )::uuid;


select pg_temp.assert_true(
  'P2D-22 physical purge is rejected while an active hold exists',

  pg_temp.expect_error(
    $sql$
      select haulvia_command.apply_p2d_confirm_private_storage_purge(
        jsonb_build_object(
          'deletionRequestId',
          (
            select id
            from p2d_part2b_ids
            where key = 'full-lifecycle-deletion'
          ),

          'commandId',
          'd2d00000-0000-0000-0000-000000000773'::uuid,

          'providerPurgeCorrelationId',
          (
            select dr.provider_purge_correlation_id
            from haulvia.private_storage_deletion_requests dr
            where dr.id = (
              select id
              from p2d_part2b_ids
              where key = 'full-lifecycle-deletion'
            )
          ),

          'purgeProviderReference',
          'p2d-test-provider-blocked-by-hold',

          'workerAuthority',
          'STORAGE_WORKER'
        )
      )
    $sql$,
    'P0001',
    'Private storage object has an active hold and cannot be purged'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects
    where id =
      'd2d00000-0000-0000-0000-000000000203'::uuid
      and lifecycle_status = 'DELETION_PENDING'
      and purged_at is null
  ),

  'A provider purge acknowledgement must not override an active hold.'
);


-- Release the purge-blocking hold.

select haulvia_command.apply_p2d_release_private_storage_hold(
  jsonb_build_object(
    'holdId',
    (
      select id
      from p2d_part2b_ids
      where key = 'purge-hold'
    ),

    'commandId',
    'd2d00000-0000-0000-0000-000000000783'::uuid,

    'actorProfileId',
    'd2d00000-0000-0000-0000-000000000012'::uuid,

    'actorOrganizationId',
    'd2d00000-0000-0000-0000-000000000001'::uuid,

    'reauthSessionId',
    'd2d00000-0000-0000-0000-000000000031'::uuid,

    'reason',
    'P2D acceptance release purge-blocking hold'
  )
);


-- ============================================================================
-- P2D-23
-- Only the trusted storage worker may confirm physical provider purge.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-23 human lifecycle manager cannot confirm physical purge',

  pg_temp.expect_error(
    $sql$
      select haulvia_command.apply_p2d_confirm_private_storage_purge(
        jsonb_build_object(
          'deletionRequestId',
          (
            select id
            from p2d_part2b_ids
            where key = 'full-lifecycle-deletion'
          ),

          'commandId',
          'd2d00000-0000-0000-0000-000000000793'::uuid,

          'providerPurgeCorrelationId',
          (
            select dr.provider_purge_correlation_id
            from haulvia.private_storage_deletion_requests dr
            where dr.id = (
              select id
              from p2d_part2b_ids
              where key = 'full-lifecycle-deletion'
            )
          ),

          'purgeProviderReference',
          'p2d-human-must-not-confirm-purge',

          'actorProfileId',
          'd2d00000-0000-0000-0000-000000000012'::uuid,

          'actorOrganizationId',
          'd2d00000-0000-0000-0000-000000000001'::uuid,

          'reauthSessionId',
          'd2d00000-0000-0000-0000-000000000031'::uuid,

          'reason',
          'P2D acceptance human purge must fail'
        )
      )
    $sql$
  )

  and exists (
    select 1
    from haulvia.private_storage_objects
    where id =
      'd2d00000-0000-0000-0000-000000000203'::uuid
      and lifecycle_status = 'DELETION_PENDING'
      and purged_at is null
  ),

  'Human lifecycle authority must not substitute for STORAGE_WORKER physical purge confirmation.'
);


-- Trusted worker confirmation now succeeds.

select haulvia_command.apply_p2d_confirm_private_storage_purge(
  jsonb_build_object(
    'deletionRequestId',
    (
      select id
      from p2d_part2b_ids
      where key = 'full-lifecycle-deletion'
    ),

    'commandId',
    'd2d00000-0000-0000-0000-000000000803'::uuid,

    'providerPurgeCorrelationId',
    (
      select dr.provider_purge_correlation_id
      from haulvia.private_storage_deletion_requests dr
      where dr.id = (
        select id
        from p2d_part2b_ids
        where key = 'full-lifecycle-deletion'
      )
    ),

    'purgeProviderReference',
    'p2d-test-provider-purge-confirmed-203',

    'workerAuthority',
    'STORAGE_WORKER'
  )
);


-- ============================================================================
-- P2D-24
-- Physical purge preserves the canonical metadata/audit row.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-24 purge preserves the canonical private-storage metadata row',

  exists (
    select 1
    from haulvia.private_storage_objects pso
    where pso.id =
      'd2d00000-0000-0000-0000-000000000203'::uuid

      and pso.lifecycle_status = 'PURGED'

      and pso.storage_provider =
          'P2D_TEST_PROVIDER'

      and pso.bucket_key =
          'p2d-private'

      and pso.object_key =
          'deletion/full-lifecycle.pdf'

      and pso.original_file_name =
          'full-lifecycle.pdf'

      and pso.media_type =
          'application/pdf'

      and pso.byte_size = 503

      and pso.content_sha256 =
          repeat('3', 64)

      and pso.retention_policy_version_id is not null

      and pso.retention_class =
          'P2D_EXPIRED'

      and pso.retention_snapshot is not null

      and pso.retain_until is not null

      and pso.finalized_at is not null

      and pso.deletion_pending_at is not null

      and pso.purged_at is not null

      and pso.purge_provider_reference =
          'p2d-test-provider-purge-confirmed-203'

      and pso.purge_correlation_id is not null
  ),

  'PURGED is a lifecycle state on preserved metadata, not deletion of the database row.'
);


-- ============================================================================
-- P2D-09
-- PURGED is terminal.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-09 PURGED private storage objects are terminal',

  pg_temp.expect_error(
    $sql$
      update haulvia.private_storage_objects
      set lifecycle_status = 'AVAILABLE'
      where id =
        'd2d00000-0000-0000-0000-000000000203'::uuid
    $sql$,
    '55000'
  )

  and exists (
    select 1
    from haulvia.private_storage_objects
    where id =
      'd2d00000-0000-0000-0000-000000000203'::uuid
      and lifecycle_status = 'PURGED'
  ),

  'A physically purged object must never return to an active lifecycle state.'
);


-- ============================================================================
-- P2D-19 was already implemented in Part 1 and is intentionally not duplicated.
-- ============================================================================


-- ============================================================================
-- P2D ACCEPTANCE PART 2C
-- Immutable lifecycle/access audit and protected-access audit contents
-- ============================================================================


-- ============================================================================
-- Part 2C fixture IDs
-- ============================================================================

create temporary table p2d_part2c_ids (
  key text primary key,
  id uuid not null
) on commit drop;


-- Capture one real lifecycle event already produced by the Part 2B workflow.

insert into p2d_part2c_ids (
  key,
  id
)
select
  'lifecycle-event',
  e.id
from haulvia.private_storage_object_events e
where e.private_storage_object_id =
  'd2d00000-0000-0000-0000-000000000203'::uuid
order by
  e.created_at,
  e.id
limit 1;


-- ============================================================================
-- P2D-25
-- Private-storage lifecycle events are append-only.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-25 private storage lifecycle events are append-only',

  exists (
    select 1
    from p2d_part2c_ids
    where key = 'lifecycle-event'
  )

  and pg_temp.expect_error(
    $sql$
      update haulvia.private_storage_object_events
      set reason = 'P2D acceptance illegal lifecycle-event mutation'
      where id = (
        select id
        from p2d_part2c_ids
        where key = 'lifecycle-event'
      )
    $sql$
  )

  and pg_temp.expect_error(
    $sql$
      delete from haulvia.private_storage_object_events
      where id = (
        select id
        from p2d_part2c_ids
        where key = 'lifecycle-event'
      )
    $sql$
  )

  and exists (
    select 1
    from haulvia.private_storage_object_events e
    where e.id = (
      select id
      from p2d_part2c_ids
      where key = 'lifecycle-event'
    )
  ),

  'Lifecycle audit rows must reject UPDATE and DELETE and remain preserved.'
);


-- ============================================================================
-- Create a representative protected-access audit record.
--
-- The protected-access commands use this exact audit relation and field model:
-- actor/organization or worker, PREPARE_DOWNLOAD, purpose, result,
-- correlation ID, consumer context metadata, and created_at.
-- ============================================================================

insert into haulvia.private_storage_access_events (
  id,
  private_storage_object_id,
  actor_profile_id,
  organization_id,
  worker_authority,
  access_action,
  purpose,
  result,
  correlation_id,
  metadata
)
values (
  'd2d00000-0000-0000-0000-000000000901'::uuid,

  'd2d00000-0000-0000-0000-000000000201'::uuid,

  'd2d00000-0000-0000-0000-000000000012'::uuid,

  'd2d00000-0000-0000-0000-000000000001'::uuid,

  null,

  'PREPARE_DOWNLOAD',

  'P2D acceptance protected document review',

  'ALLOWED',

  'd2d00000-0000-0000-0000-000000000902'::uuid,

  jsonb_build_object(
    'consumerType',
    'P2D_ACCEPTANCE',
    'contextId',
    'part-2c',
    'authorityPath',
    'SENSITIVE_DOCUMENT_VIEW',
    'objectLifecycleStatus',
    'AVAILABLE'
  )
);


-- ============================================================================
-- P2D-26
-- Protected-access events are append-only.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-26 private storage access events are append-only',

  pg_temp.expect_error(
    $sql$
      update haulvia.private_storage_access_events
      set purpose =
        'P2D acceptance illegal access-event mutation'
      where id =
        'd2d00000-0000-0000-0000-000000000901'::uuid
    $sql$
  )

  and pg_temp.expect_error(
    $sql$
      delete from haulvia.private_storage_access_events
      where id =
        'd2d00000-0000-0000-0000-000000000901'::uuid
    $sql$
  )

  and exists (
    select 1
    from haulvia.private_storage_access_events ae
    where ae.id =
      'd2d00000-0000-0000-0000-000000000901'::uuid

      and ae.purpose =
          'P2D acceptance protected document review'
  ),

  'Protected-access audit rows must reject UPDATE and DELETE and remain preserved.'
);


-- ============================================================================
-- P2D-27
-- Access records preserve actor/context/action/purpose/result/time without
-- persisting signed URLs, bearer tokens, credentials, or other secrets.
--
-- This verifies:
--   1. the canonical audit record contains the required attribution fields;
--   2. the access-audit relation has no raw locator/credential columns;
--   3. both protected-access command implementations write this audit relation;
--   4. neither protected-access implementation contains signed-URL/token/secret
--      material in its command definition.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-27 protected access audit captures attribution without signed URLs or secrets',

  exists (
    select 1
    from haulvia.private_storage_access_events ae
    where ae.id =
      'd2d00000-0000-0000-0000-000000000901'::uuid

      and ae.private_storage_object_id =
          'd2d00000-0000-0000-0000-000000000201'::uuid

      and ae.actor_profile_id =
          'd2d00000-0000-0000-0000-000000000012'::uuid

      and ae.organization_id =
          'd2d00000-0000-0000-0000-000000000001'::uuid

      and ae.worker_authority is null

      and ae.access_action =
          'PREPARE_DOWNLOAD'

      and ae.purpose =
          'P2D acceptance protected document review'

      and ae.result =
          'ALLOWED'

      and ae.correlation_id =
          'd2d00000-0000-0000-0000-000000000902'::uuid

      and ae.created_at is not null

      and ae.metadata
            ->> 'consumerType'
          = 'P2D_ACCEPTANCE'

      and ae.metadata
            ->> 'contextId'
          = 'part-2c'

      and ae.metadata
            ->> 'authorityPath'
          = 'SENSITIVE_DOCUMENT_VIEW'

      and ae.metadata
            ->> 'objectLifecycleStatus'
          = 'AVAILABLE'

      and lower(ae.metadata::text)
          not like '%signedurl%'

      and lower(ae.metadata::text)
          not like '%signed_url%'

      and lower(ae.metadata::text)
          not like '%secret%'

      and lower(ae.metadata::text)
          not like '%token%'
  )

  and not exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
          'private_storage_access_events'
      and (
        lower(c.column_name) like '%signed%url%'
        or lower(c.column_name) like '%secret%'
        or lower(c.column_name) like '%token%'
        or lower(c.column_name) = 'storage_object_key'
        or lower(c.column_name) = 'object_key'
        or lower(c.column_name) = 'bucket_key'
      )
  )

  and position(
    'private_storage_access_events'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_compliance_document_access(jsonb)'::regprocedure
      )
    )
  ) > 0

  and position(
    'private_storage_access_events'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_stop_evidence_access(jsonb)'::regprocedure
      )
    )
  ) > 0

  and position(
    'signedurl'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_compliance_document_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'signed_url'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_compliance_document_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'secret'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_compliance_document_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'token'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_compliance_document_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'signedurl'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_stop_evidence_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'signed_url'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_stop_evidence_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'secret'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_stop_evidence_access(jsonb)'::regprocedure
      )
    )
  ) = 0

  and position(
    'token'
    in lower(
      pg_get_functiondef(
        'haulvia_command.apply_p2d_prepare_stop_evidence_access(jsonb)'::regprocedure
      )
    )
  ) = 0,

  'Protected-access audit must record attribution and outcome without persisting signed URLs, tokens, secrets, or raw provider locator columns.'
);



-- P2D ACCEPTANCE PART 2D


-- ============================================================================
-- P2D-38
-- Lifecycle-management permission exists and is sensitive.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-38 private storage lifecycle management permission exists and is sensitive',

  (
    select count(*) = 1
    from haulvia.permissions p
    where p.permission_key =
          'PRIVATE_STORAGE_LIFECYCLE_MANAGE'
      and p.is_sensitive
  ),

  'PRIVATE_STORAGE_LIFECYCLE_MANAGE must exist exactly once and remain a sensitive permission.'
);


-- ============================================================================
-- P2D-39
-- Lifecycle-management authority remains narrowly assigned.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-39 lifecycle management permission is not granted to customer or provider driver roles',

  (
    select count(*) = 1
    from haulvia.role_permissions rp
    join haulvia.permissions p
      on p.id = rp.permission_id
    where p.permission_key =
          'PRIVATE_STORAGE_LIFECYCLE_MANAGE'
  )

  and exists (
    select 1
    from haulvia.role_permissions rp
    join haulvia.permissions p
      on p.id = rp.permission_id
    join haulvia.roles r
      on r.id = rp.role_id
    where p.permission_key =
          'PRIVATE_STORAGE_LIFECYCLE_MANAGE'
      and r.role_key =
          'PLATFORM_ADMIN'
  )

  and not exists (
    select 1
    from haulvia.role_permissions rp
    join haulvia.permissions p
      on p.id = rp.permission_id
    join haulvia.roles r
      on r.id = rp.role_id
    where p.permission_key =
          'PRIVATE_STORAGE_LIFECYCLE_MANAGE'
      and r.role_key <>
          'PLATFORM_ADMIN'
  ),

  'P2D v1 permits only PLATFORM_ADMIN to hold PRIVATE_STORAGE_LIFECYCLE_MANAGE.'
);


-- ============================================================================
-- P2D-40
-- STORAGE_WORKER remains trusted worker authority rather than human RBAC role.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-40 STORAGE_WORKER remains worker authority rather than a human role',

  not exists (
    select 1
    from haulvia.roles r
    where r.role_key = 'STORAGE_WORKER'
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
          'reject_worker_authority_role'
      and position(
            'STORAGE_WORKER'
            in pg_get_functiondef(p.oid)
          ) > 0
  )

  and exists (
    select 1
    from pg_trigger t
    join pg_class c
      on c.oid = t.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname = 'roles'
      and t.tgname =
          'roles_reject_worker_authority'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  ),

  'STORAGE_WORKER must remain outside the human-role catalog and protected by the worker-role rejection guard.'
);


-- ============================================================================
-- P2D-41
-- Compliance-document attachment requires an AVAILABLE canonical object.
--
-- Historical references may remain after a later lifecycle transition.
-- The invariant tested here is the attachment boundary.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-41 every compliance document attaches through an AVAILABLE canonical private storage object',

  exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
          'compliance_documents'
      and c.column_name =
          'private_storage_object_id'
      and c.data_type = 'uuid'
      and c.is_nullable = 'NO'
  )

  and exists (
    select 1
    from pg_constraint con
    join pg_class child
      on child.oid = con.conrelid
    join pg_namespace child_ns
      on child_ns.oid = child.relnamespace
    join pg_class parent
      on parent.oid = con.confrelid
    join pg_namespace parent_ns
      on parent_ns.oid = parent.relnamespace
    where con.contype = 'f'
      and child_ns.nspname = 'haulvia'
      and child.relname =
          'compliance_documents'
      and parent_ns.nspname = 'haulvia'
      and parent.relname =
          'private_storage_objects'
      and pg_get_constraintdef(con.oid)
            like '%private_storage_object_id%'
  )

  and exists (
    select 1
    from pg_trigger t
    join pg_class c
      on c.oid = t.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname =
          'compliance_documents'
      and t.tgname =
          'compliance_documents_private_object_guard'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  )

  and exists (
    select 1
    from pg_trigger t
    join pg_class c
      on c.oid = t.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname =
          'compliance_documents'
      and t.tgname =
          'compliance_documents_private_object_update_guard'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
          'assert_private_storage_object_attachable'
      and position(
            'lifecycle_status <> ''AVAILABLE'''
            in pg_get_functiondef(p.oid)
          ) > 0
  ),

  'Compliance documents must use a non-null canonical private object whose attachment guard requires AVAILABLE state.'
);


-- ============================================================================
-- P2D-43
-- Stop evidence may remain structured-only.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-43 stop evidence may be structured-only without a binary private object',

  exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name = 'stop_evidence'
      and c.column_name =
          'private_storage_object_id'
      and c.is_nullable = 'YES'
  )

  and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name = 'stop_evidence'
      and c.column_name =
          'structured_value'
      and c.is_nullable = 'NO'
  )

  and exists (
    select 1
    from pg_constraint con
    join pg_class c
      on c.oid = con.conrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname = 'stop_evidence'
      and con.conname =
          'stop_evidence_private_object_or_structured_check'
      and con.contype = 'c'
      and position(
            'private_storage_object_id IS NOT NULL'
            in pg_get_constraintdef(con.oid)
          ) > 0
      and position(
            'structured_value <> ''{}''::jsonb'
            in pg_get_constraintdef(con.oid)
          ) > 0
  ),

  'Stop evidence must allow nonempty structured evidence without forcing a binary object.'
);


-- ============================================================================
-- P2D-44
-- Binary-backed stop evidence attaches through the canonical AVAILABLE object.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-44 binary stop evidence references an AVAILABLE canonical private storage object',

  exists (
    select 1
    from pg_constraint con
    join pg_class child
      on child.oid = con.conrelid
    join pg_namespace child_ns
      on child_ns.oid = child.relnamespace
    join pg_class parent
      on parent.oid = con.confrelid
    join pg_namespace parent_ns
      on parent_ns.oid = parent.relnamespace
    where con.contype = 'f'
      and child_ns.nspname = 'haulvia'
      and child.relname = 'stop_evidence'
      and parent_ns.nspname = 'haulvia'
      and parent.relname =
          'private_storage_objects'
      and pg_get_constraintdef(con.oid)
            like '%private_storage_object_id%'
  )

  and exists (
    select 1
    from pg_trigger t
    join pg_class c
      on c.oid = t.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname = 'stop_evidence'
      and t.tgname =
          'stop_evidence_private_object_guard'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  )

  and exists (
    select 1
    from pg_trigger t
    join pg_class c
      on c.oid = t.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname = 'stop_evidence'
      and t.tgname =
          'stop_evidence_private_object_update_guard'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
          'guard_stop_evidence_private_object'
      and position(
            'assert_private_storage_object_attachable'
            in pg_get_functiondef(p.oid)
          ) > 0
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname =
          'assert_private_storage_object_attachable'
      and position(
            'lifecycle_status <> ''AVAILABLE'''
            in pg_get_functiondef(p.oid)
          ) > 0
  ),

  'Binary stop evidence must pass through the canonical AVAILABLE-object attachment guard.'
);


-- ============================================================================
-- P2D-46
-- Compliance registration is command-mediated and authority checked.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-46 compliance document registration is command-mediated and authority checked',

  exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname =
          'apply_p2d_register_compliance_document'
      and position(
            'assert_compliance_document_upload_authority'
            in pg_get_functiondef(p.oid)
          ) > 0
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname =
          'command_register_compliance_document'
      and position(
            'execute_p2d_storage_command'
            in pg_get_functiondef(p.oid)
          ) > 0
      and position(
            'registerComplianceDocument'
            in pg_get_functiondef(p.oid)
          ) > 0
  )

  and exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname =
          'execute_p2d_storage_command'
      and position(
            'apply_p2d_register_compliance_document'
            in pg_get_functiondef(p.oid)
          ) > 0
  )

  and has_function_privilege(
        'service_role',
        'haulvia_command.command_register_compliance_document(jsonb)',
        'EXECUTE'
      )

  and not has_function_privilege(
        'service_role',
        'haulvia_command.apply_p2d_register_compliance_document(jsonb)',
        'EXECUTE'
      ),

  'External compliance registration must enter through the trusted wrapper/dispatcher and reassert provider-document upload authority.'
);


-- ============================================================================
-- P2D-47
-- Externally callable P2D mutations preserve command idempotency.
--
-- This exercises a STORAGE_WORKER command because its actor_profile_id is NULL.
-- P2B actor-scope idempotency must still collapse the retry to one command fact.
-- ============================================================================

insert into haulvia.private_storage_objects (
  id,
  storage_provider,
  bucket_key,
  object_key,
  original_file_name,
  lifecycle_status,
  reserved_by_worker_authority
)
values (
  'd2d00000-0000-0000-0000-000000000910'::uuid,
  'P2D_TEST_PROVIDER',
  'p2d-private',
  'idempotency/finalize-replay-910.pdf',
  'finalize-replay-910.pdf',
  'RESERVED',
  'STORAGE_WORKER'
);


create temporary table p2d_part2d_replay_results (
  sequence_no integer primary key,
  result jsonb not null
) on commit drop;


insert into p2d_part2d_replay_results (
  sequence_no,
  result
)
select
  1,
  haulvia_command.command_finalize_private_storage_object(
    jsonb_build_object(
      'privateStorageObjectId',
      'd2d00000-0000-0000-0000-000000000910'::uuid,

      'commandId',
      'd2d00000-0000-0000-0000-000000000911'::uuid,

      'idempotencyKey',
      'p2d-47-worker-finalize-replay',

      'requestHash',
      repeat('8', 64),

      'workerAuthority',
      'STORAGE_WORKER',

      'mediaType',
      'application/pdf',

      'byteSize',
      '910',

      'contentSha256',
      repeat('9', 64),

      'retentionClass',
      'P2D_EXPIRED'
    )
  );


insert into p2d_part2d_replay_results (
  sequence_no,
  result
)
select
  2,
  haulvia_command.command_finalize_private_storage_object(
    jsonb_build_object(
      'privateStorageObjectId',
      'd2d00000-0000-0000-0000-000000000910'::uuid,

      'commandId',
      'd2d00000-0000-0000-0000-000000000911'::uuid,

      'idempotencyKey',
      'p2d-47-worker-finalize-replay',

      'requestHash',
      repeat('8', 64),

      'workerAuthority',
      'STORAGE_WORKER',

      'mediaType',
      'application/pdf',

      'byteSize',
      '910',

      'contentSha256',
      repeat('9', 64),

      'retentionClass',
      'P2D_EXPIRED'
    )
  );


select pg_temp.assert_true(
  'P2D-47 externally callable P2D mutations preserve command idempotency',

  (
    select result ->> 'replayed' = 'false'
    from p2d_part2d_replay_results
    where sequence_no = 1
  )

  and (
    select result ->> 'replayed' = 'true'
    from p2d_part2d_replay_results
    where sequence_no = 2
  )

  and (
    select
      (first_result.result - 'replayed')
      =
      (second_result.result - 'replayed')
    from p2d_part2d_replay_results first_result
    cross join p2d_part2d_replay_results second_result
    where first_result.sequence_no = 1
      and second_result.sequence_no = 2
  )

  and (
    select count(*) = 1
    from haulvia.command_idempotency ci
    where ci.actor_profile_id is null
      and ci.actor_auth_user_id is null
      and ci.command_name =
          'finalizePrivateStorageObject'
      and ci.idempotency_key =
          'p2d-47-worker-finalize-replay'
      and ci.status = 'COMPLETED'
  )

  and (
    select count(*) = 1
    from haulvia.private_storage_object_events e
    where e.private_storage_object_id =
          'd2d00000-0000-0000-0000-000000000910'::uuid
      and e.event_type = 'FINALIZED'
  )

  and pg_temp.expect_error(
    $sql$
      select haulvia_command.command_finalize_private_storage_object(
        jsonb_build_object(
          'privateStorageObjectId',
          'd2d00000-0000-0000-0000-000000000910'::uuid,

          'commandId',
          'd2d00000-0000-0000-0000-000000000911'::uuid,

          'idempotencyKey',
          'p2d-47-worker-finalize-replay',

          'requestHash',
          repeat('7', 64),

          'workerAuthority',
          'STORAGE_WORKER',

          'mediaType',
          'application/pdf',

          'byteSize',
          '910',

          'contentSha256',
          repeat('9', 64),

          'retentionClass',
          'P2D_EXPIRED'
        )
      )
    $sql$,
    'P0001',
    'The idempotency key was already used with a different request'
  ),

  'Same key/same request must replay one mutation; same key/different request must fail closed.'
);


-- ============================================================================
-- P2D-48
-- Preserve the established P2A/P2B/P2C security and authority invariants.
-- ============================================================================

select pg_temp.assert_true(
  'P2D-48 P2D preserves P2A P2B and P2C authority identity and security invariants',

  -- P2A human-role baseline remains unchanged.
  (
    select count(*) = 17
    from haulvia.roles
  )

  -- P2A had 50 permissions; P2D intentionally adds exactly one.
  and (
    select count(*) = 51
    from haulvia.permissions
  )

  -- Core authority / membership / reauthentication structures survive.
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

  -- P2B identity and invitation structures survive.
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

  -- Canonical profile/Auth bridge remains intact.
  and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name = 'profiles'
      and c.column_name = 'auth_user_id'
  )

  and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name = 'profiles'
      and c.column_name =
          'auth_access_status'
  )

  and exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name =
          'command_idempotency'
      and c.column_name =
          'actor_auth_user_id'
  )

  -- One Auth UUID still maps to at most one profile.
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

  -- P2B request-time authority helpers remain present.
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
  )

  -- P2B null/profile/Auth/system idempotency scope remains protected.
  and exists (
    select 1
    from pg_indexes i
    where i.schemaname = 'haulvia'
      and i.tablename =
          'command_idempotency'
      and i.indexname =
          'command_idempotency_actor_scope_uq'
      and lower(i.indexdef) like
          '%unique%'
  )

  -- Worker authorities remain segregated from human RBAC.
  and not exists (
    select 1
    from haulvia.roles r
    where r.role_key = 'STORAGE_WORKER'
  )

  and exists (
    select 1
    from pg_trigger t
    join pg_class c
      on c.oid = t.tgrelid
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relname = 'roles'
      and t.tgname =
          'roles_reject_worker_authority'
      and not t.tgisinternal
      and t.tgenabled <> 'D'
  )

  -- P2C RLS baseline remains true for every current Haulvia base table.
  and not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and not c.relrowsecurity
  )

  -- P2C v1 still does not require FORCE RLS.
  and not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and c.relforcerowsecurity
  )

  -- PUBLIC receives no raw Haulvia base-table privileges.
  and not exists (
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
  )

  -- Supabase client roles still have no effective raw-table authority.
  and not exists (
    select 1
    from pg_roles r
    cross join pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where r.rolname in (
            'anon',
            'authenticated'
          )
      and n.nspname = 'haulvia'
      and c.relkind in ('r', 'p')
      and (
        has_table_privilege(
          r.oid,
          c.oid,
          'SELECT'
        )
        or has_table_privilege(
          r.oid,
          c.oid,
          'INSERT'
        )
        or has_table_privilege(
          r.oid,
          c.oid,
          'UPDATE'
        )
        or has_table_privilege(
          r.oid,
          c.oid,
          'DELETE'
        )
        or has_table_privilege(
          r.oid,
          c.oid,
          'TRUNCATE'
        )
        or has_table_privilege(
          r.oid,
          c.oid,
          'REFERENCES'
        )
        or has_table_privilege(
          r.oid,
          c.oid,
          'TRIGGER'
        )
      )
  )

  -- service_role still receives command execution, not raw-table grants.
  and not exists (
    select 1
    from information_schema.table_privileges tp
    where tp.table_schema = 'haulvia'
      and tp.grantee = 'service_role'
  )

  -- SECURITY DEFINER ownership and search-path hardening remain intact.
  and not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname in (
            'haulvia',
            'haulvia_command'
          )
      and p.prosecdef
      and (
        pg_get_userbyid(
          p.proowner
        ) in (
          'anon',
          'authenticated'
        )

        or not exists (
          select 1
          from unnest(
            coalesce(
              p.proconfig,
              array[]::text[]
            )
          ) cfg
          where cfg like 'search_path=%'
        )

        or exists (
          select 1
          from unnest(
            coalesce(
              p.proconfig,
              array[]::text[]
            )
          ) cfg
          where cfg like 'search_path=%'
            and cfg like '%public%'
        )

        or not exists (
          select 1
          from unnest(
            coalesce(
              p.proconfig,
              array[]::text[]
            )
          ) cfg
          where cfg like 'search_path=%'
            and cfg like '%pg_temp%'
        )
      )
  ),

  'P2D must extend private storage without weakening identity, membership, reauthentication, worker separation, idempotency, RLS, privilege, or SECURITY DEFINER protections.'
);


-- ============================================================================
-- All 48 P2D contract requirements are now represented.
-- Final acceptance gate/report/ROLLBACK will be appended only after this block
-- executes successfully.
-- ============================================================================


-- ============================================================================
-- P2D FINAL ACCEPTANCE GATE
-- ============================================================================

do $function$
declare
  v_total  integer;
  v_passed integer;
  v_failed integer;
begin
  select
    count(*),
    count(*) filter (where passed),
    count(*) filter (where not passed)
  into
    v_total,
    v_passed,
    v_failed
  from p2d_test_results;

  if v_total <> 48 then
    raise exception
      'P2D final acceptance expected 48 checks but found %',
      v_total;
  end if;

  if v_passed <> 48 then
    raise exception
      'P2D final acceptance expected 48 passing checks but found %',
      v_passed;
  end if;

  if v_failed <> 0 then
    raise exception
      'P2D final acceptance expected 0 failures but found %',
      v_failed;
  end if;
end;
$function$;


-- ============================================================================
-- Detailed acceptance report
-- ============================================================================

select
  test_name,
  passed,
  detail
from p2d_test_results
order by test_name;


-- ============================================================================
-- Final totals
-- ============================================================================

select
  count(*) as total_checks,
  count(*) filter (
    where passed
  ) as passed_checks,
  count(*) filter (
    where not passed
  ) as failed_checks
from p2d_test_results;


-- ============================================================================
-- Roll back the complete P2D development transaction.
--
-- The P2D migration intentionally remains without COMMIT at this stage.
-- This ROLLBACK removes the migration and all acceptance fixtures from the
-- disposable local database after proving the complete contract.
-- ============================================================================

rollback;