begin;

-- ============================================================================
-- Haulvia P2D Private Storage and Retention v1
--
-- Frozen contract SHA-256:
-- 7BF893FB425A236691C158EF10B07EE64365A53289C5EC224138283FF7E7EFAF
-- ============================================================================


-- ============================================================================
-- 1. Private-storage types
-- ============================================================================

create type haulvia.private_storage_lifecycle_status as enum (
  'RESERVED',
  'AVAILABLE',
  'QUARANTINED',
  'DELETION_PENDING',
  'PURGED',
  'ABANDONED'
);


create type haulvia.private_storage_hold_category as enum (
  'LEGAL',
  'DISPUTE',
  'COMPLIANCE',
  'SECURITY',
  'OPERATIONAL'
);


create type haulvia.private_storage_deletion_decision as enum (
  'PENDING',
  'APPROVED',
  'REJECTED',
  'CANCELLED'
);


create type haulvia.private_storage_access_result as enum (
  'ALLOWED',
  'DENIED',
  'ERROR'
);


create type haulvia.private_storage_event_type as enum (
  'RESERVED',
  'FINALIZED',
  'QUARANTINED',
  'QUARANTINE_RELEASED',
  'ABANDONED',
  'HOLD_PLACED',
  'HOLD_RELEASED',
  'DELETION_REQUESTED',
  'DELETION_APPROVED',
  'DELETION_REJECTED',
  'DELETION_CANCELLED',
  'DELETION_PENDING',
  'PURGED'
);


-- ============================================================================
-- 2. Canonical private-object registry
-- ============================================================================

create table haulvia.private_storage_objects (
  id uuid primary key default gen_random_uuid(),

  storage_provider text not null,
  bucket_key text not null,
  object_key text not null,

  original_file_name text not null,

  media_type text,
  byte_size bigint,
  content_sha256 text,

  lifecycle_status haulvia.private_storage_lifecycle_status
    not null
    default 'RESERVED',

  retention_policy_version_id uuid
    references haulvia.policy_versions(id),

  retention_class text,
  retention_snapshot jsonb,
  retain_until timestamptz,

  reserved_by_profile_id uuid
    references haulvia.profiles(id),

  reserved_by_worker_authority text,

  reserved_at timestamptz
    not null
    default clock_timestamp(),

  finalized_at timestamptz,

  quarantined_at timestamptz,

  deletion_pending_at timestamptz,

  purged_at timestamptz,

  abandoned_at timestamptz,

  purge_provider_reference text,
  purge_correlation_id uuid,

  created_at timestamptz
    not null
    default clock_timestamp(),

  updated_at timestamptz
    not null
    default clock_timestamp(),

  constraint private_storage_objects_provider_not_blank
    check (btrim(storage_provider) <> ''),

  constraint private_storage_objects_bucket_not_blank
    check (btrim(bucket_key) <> ''),

  constraint private_storage_objects_object_key_not_blank
    check (btrim(object_key) <> ''),

  constraint private_storage_objects_file_name_not_blank
    check (btrim(original_file_name) <> ''),

  constraint private_storage_objects_byte_size_nonnegative
    check (
      byte_size is null
      or byte_size >= 0
    ),

  constraint private_storage_objects_sha256_format
    check (
      content_sha256 is null
      or content_sha256 ~ '^[0-9a-f]{64}$'
    ),

  constraint private_storage_objects_retention_complete
    check (
      (
        retention_policy_version_id is null
        and retention_class is null
        and retention_snapshot is null
        and retain_until is null
      )
      or
      (
        retention_policy_version_id is not null
        and nullif(btrim(retention_class), '') is not null
        and retention_snapshot is not null
        and retain_until is not null
      )
    ),

  constraint private_storage_objects_available_metadata
    check (
      lifecycle_status not in (
        'AVAILABLE',
        'QUARANTINED',
        'DELETION_PENDING',
        'PURGED'
      )
      or
      (
        nullif(btrim(media_type), '') is not null
        and byte_size is not null
        and content_sha256 is not null
        and finalized_at is not null
        and retention_policy_version_id is not null
        and retention_class is not null
        and retention_snapshot is not null
        and retain_until is not null
      )
    ),

  constraint private_storage_objects_reserved_not_finalized
    check (
      lifecycle_status <> 'RESERVED'
      or finalized_at is null
    ),

  constraint private_storage_objects_abandoned_timestamp
    check (
      lifecycle_status <> 'ABANDONED'
      or abandoned_at is not null
    ),

  constraint private_storage_objects_purged_timestamp
    check (
      lifecycle_status <> 'PURGED'
      or purged_at is not null
    ),

  constraint private_storage_objects_provider_locator_unique
    unique (
      storage_provider,
      bucket_key,
      object_key
    )
);


-- ============================================================================
-- 3. Append-only storage lifecycle events
-- ============================================================================

create table haulvia.private_storage_object_events (
  id uuid primary key default gen_random_uuid(),

  private_storage_object_id uuid
    not null
    references haulvia.private_storage_objects(id),

  event_type haulvia.private_storage_event_type
    not null,

  prior_status haulvia.private_storage_lifecycle_status,

  current_status haulvia.private_storage_lifecycle_status,

  actor_profile_id uuid
    references haulvia.profiles(id),

  worker_authority text,

  organization_id uuid
    references haulvia.organizations(id),

  reason text,

  correlation_id uuid,

  metadata jsonb
    not null
    default '{}'::jsonb,

  created_at timestamptz
    not null
    default clock_timestamp()
);


-- ============================================================================
-- 4. Object holds
-- ============================================================================

create table haulvia.private_storage_object_holds (
  id uuid primary key default gen_random_uuid(),

  private_storage_object_id uuid
    not null
    references haulvia.private_storage_objects(id),

  hold_category haulvia.private_storage_hold_category
    not null,

  reason text
    not null,

  placed_by_profile_id uuid
    references haulvia.profiles(id),

  placed_by_worker_authority text,

  placed_at timestamptz
    not null
    default clock_timestamp(),

  released_by_profile_id uuid
    references haulvia.profiles(id),

  released_by_worker_authority text,

  release_reason text,

  released_at timestamptz,

  correlation_id uuid,

  created_at timestamptz
    not null
    default clock_timestamp(),

  constraint private_storage_object_holds_reason_not_blank
    check (btrim(reason) <> ''),

  constraint private_storage_object_holds_release_consistency
    check (
      (
        released_at is null
        and released_by_profile_id is null
        and released_by_worker_authority is null
        and release_reason is null
      )
      or
      (
        released_at is not null
        and nullif(btrim(release_reason), '') is not null
      )
    )
);


create unique index private_storage_object_holds_active_unique
on haulvia.private_storage_object_holds (
  private_storage_object_id,
  hold_category
)
where released_at is null;


-- ============================================================================
-- 5. Deletion requests
-- ============================================================================

create table haulvia.private_storage_deletion_requests (
  id uuid primary key default gen_random_uuid(),

  private_storage_object_id uuid
    not null
    references haulvia.private_storage_objects(id),

  requested_by_profile_id uuid
    references haulvia.profiles(id),

  requested_by_worker_authority text,

  reason text
    not null,

  requested_at timestamptz
    not null
    default clock_timestamp(),

  decision haulvia.private_storage_deletion_decision
    not null
    default 'PENDING',

  decided_by_profile_id uuid
    references haulvia.profiles(id),

  decided_by_worker_authority text,

  decision_reason text,

  decided_at timestamptz,

  provider_purge_correlation_id uuid,

  correlation_id uuid,

  created_at timestamptz
    not null
    default clock_timestamp(),

  constraint private_storage_deletion_requests_reason_not_blank
    check (btrim(reason) <> ''),

  constraint private_storage_deletion_requests_decision_consistency
    check (
      (
        decision = 'PENDING'
        and decided_at is null
        and decided_by_profile_id is null
        and decided_by_worker_authority is null
        and decision_reason is null
      )
      or
      (
        decision <> 'PENDING'
        and decided_at is not null
        and nullif(btrim(decision_reason), '') is not null
      )
    )
);


-- ============================================================================
-- 6. Protected-object access audit
-- ============================================================================

create table haulvia.private_storage_access_events (
  id uuid primary key default gen_random_uuid(),

  private_storage_object_id uuid
    not null
    references haulvia.private_storage_objects(id),

  actor_profile_id uuid
    references haulvia.profiles(id),

  organization_id uuid
    references haulvia.organizations(id),

  worker_authority text,

  access_action text
    not null,

  purpose text
    not null,

  result haulvia.private_storage_access_result
    not null,

  correlation_id uuid,

  metadata jsonb
    not null
    default '{}'::jsonb,

  created_at timestamptz
    not null
    default clock_timestamp(),

  constraint private_storage_access_events_action_not_blank
    check (btrim(access_action) <> ''),

  constraint private_storage_access_events_purpose_not_blank
    check (btrim(purpose) <> '')
);


-- ============================================================================
-- 7. Append-only guards
-- ============================================================================

create trigger private_storage_object_events_append_only
before update or delete
on haulvia.private_storage_object_events
for each row
execute function haulvia.reject_append_only_mutation();


create trigger private_storage_access_events_append_only
before update or delete
on haulvia.private_storage_access_events
for each row
execute function haulvia.reject_append_only_mutation();


-- ============================================================================
-- 8. RLS baseline
-- ============================================================================

alter table haulvia.private_storage_objects
  enable row level security;

alter table haulvia.private_storage_object_events
  enable row level security;

alter table haulvia.private_storage_object_holds
  enable row level security;

alter table haulvia.private_storage_deletion_requests
  enable row level security;

alter table haulvia.private_storage_access_events
  enable row level security;


-- ============================================================================
-- P2D implementation continues below.
-- ============================================================================

-- ============================================================================
-- 9. Retention-policy resolution
--
-- Expected RETENTION_POLICY v1 configuration shape:
--
-- {
--   "retentionClasses": {
--     "<CLASS>": {
--       "durationSeconds": <positive integer>
--     }
--   }
-- }
--
-- P2D does not provide or invent legal retention durations.
-- ============================================================================

create or replace function haulvia.resolve_private_storage_retention(
  p_retention_class text,
  p_anchor_at timestamptz
)
returns table (
  retention_policy_version_id uuid,
  resolved_retention_class text,
  retention_snapshot jsonb,
  retain_until timestamptz
)
language plpgsql
set search_path = haulvia, pg_temp
as $function$
declare
  v_policy_set_id uuid;
  v_policy_version_id uuid;
  v_config jsonb;
  v_config_sha256 text;
  v_version_no integer;
  v_rule jsonb;
  v_duration_seconds bigint;
  v_retain_until timestamptz;
begin
  if nullif(btrim(p_retention_class), '') is null then
    raise exception
      'Retention class is required'
      using errcode = '22023';
  end if;

  if p_anchor_at is null then
    raise exception
      'Retention anchor timestamp is required'
      using errcode = '22023';
  end if;

  select
    ps.id,
    pv.id,
    pv.config,
    pv.config_sha256,
    pv.version_no
  into
    v_policy_set_id,
    v_policy_version_id,
    v_config,
    v_config_sha256,
    v_version_no
  from haulvia.policy_sets ps
  join haulvia.policy_versions pv
    on pv.policy_set_id = ps.id
  where ps.policy_key = 'RETENTION_POLICY'
    and pv.publication_status = 'APPROVED'
    and pv.effective_from is not null
    and pv.effective_from <= p_anchor_at
    and (
      pv.effective_to is null
      or pv.effective_to > p_anchor_at
    )
  order by
    pv.effective_from desc,
    pv.version_no desc
  limit 1;

  if v_policy_version_id is null then
    raise exception
      'No approved and effective RETENTION_POLICY is available'
      using errcode = '55000';
  end if;

  v_rule :=
    v_config
    -> 'retentionClasses'
    -> p_retention_class;

  if v_rule is null
     or jsonb_typeof(v_rule) <> 'object' then
    raise exception
      'Retention class % is not defined by the effective RETENTION_POLICY',
      p_retention_class
      using errcode = '22023';
  end if;

  if jsonb_typeof(v_rule -> 'durationSeconds') <> 'number'
     or coalesce(
       v_rule ->> 'durationSeconds',
       ''
     ) !~ '^[1-9][0-9]*$' then
    raise exception
      'Retention class % must define a positive integer durationSeconds',
      p_retention_class
      using errcode = '22023';
  end if;

  begin
    v_duration_seconds :=
      (v_rule ->> 'durationSeconds')::bigint;
  exception
    when numeric_value_out_of_range then
      raise exception
        'Retention durationSeconds is outside the supported integer range'
        using errcode = '22003';
  end;

  begin
    v_retain_until :=
      p_anchor_at
      + make_interval(
          secs => v_duration_seconds::double precision
        );
  exception
    when datetime_field_overflow then
      raise exception
        'Retention duration produces an invalid retain-until timestamp'
        using errcode = '22008';
  end;

  return query
  select
    v_policy_version_id,
    p_retention_class,
    jsonb_build_object(
      'policyKey',
      'RETENTION_POLICY',
      'policySetId',
      v_policy_set_id,
      'policyVersionId',
      v_policy_version_id,
      'policyVersionNo',
      v_version_no,
      'configSha256',
      v_config_sha256,
      'retentionClass',
      p_retention_class,
      'resolvedRule',
      v_rule,
      'anchorAt',
      p_anchor_at,
      'retainUntil',
      v_retain_until
    ),
    v_retain_until;
end;
$function$;


-- ============================================================================
-- 10. Private-object lifecycle guard
-- ============================================================================

create or replace function haulvia.guard_private_storage_object_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  if new.id is distinct from old.id
     or new.storage_provider is distinct from old.storage_provider
     or new.bucket_key is distinct from old.bucket_key
     or new.object_key is distinct from old.object_key
     or new.original_file_name is distinct from old.original_file_name
     or new.reserved_by_profile_id is distinct from old.reserved_by_profile_id
     or new.reserved_by_worker_authority is distinct from old.reserved_by_worker_authority
     or new.reserved_at is distinct from old.reserved_at
     or new.created_at is distinct from old.created_at then
    raise exception
      'Private storage object reservation identity is immutable'
      using errcode = '55000';
  end if;

  if old.lifecycle_status in (
    'PURGED',
    'ABANDONED'
  )
  and new is distinct from old then
    raise exception
      'Private storage object in % status is terminal',
      old.lifecycle_status
      using errcode = '55000';
  end if;

  if old.lifecycle_status = new.lifecycle_status
     and new is distinct from old then
    raise exception
      'Private storage object updates require a valid lifecycle transition'
      using errcode = '55000';
  end if;

  if not (
       (
         old.lifecycle_status = 'RESERVED'
         and new.lifecycle_status in (
           'AVAILABLE',
           'ABANDONED'
         )
       )
    or (
         old.lifecycle_status = 'AVAILABLE'
         and new.lifecycle_status in (
           'QUARANTINED',
           'DELETION_PENDING'
         )
       )
    or (
         old.lifecycle_status = 'QUARANTINED'
         and new.lifecycle_status in (
           'AVAILABLE',
           'DELETION_PENDING'
         )
       )
    or (
         old.lifecycle_status = 'DELETION_PENDING'
         and new.lifecycle_status = 'PURGED'
       )
    or old.lifecycle_status = new.lifecycle_status
  ) then
    raise exception
      'Invalid private storage lifecycle transition: % -> %',
      old.lifecycle_status,
      new.lifecycle_status
      using errcode = '55000';
  end if;

  if old.lifecycle_status <> 'RESERVED' then
    if new.media_type is distinct from old.media_type
       or new.byte_size is distinct from old.byte_size
       or new.content_sha256 is distinct from old.content_sha256
       or new.retention_policy_version_id
            is distinct from old.retention_policy_version_id
       or new.retention_class
            is distinct from old.retention_class
       or new.retention_snapshot
            is distinct from old.retention_snapshot
       or new.retain_until
            is distinct from old.retain_until
       or new.finalized_at
            is distinct from old.finalized_at then
      raise exception
        'Finalized private storage metadata is immutable'
        using errcode = '55000';
    end if;
  end if;

  if old.lifecycle_status = 'RESERVED'
     and new.lifecycle_status = 'AVAILABLE'
     and new.finalized_at is null then
    raise exception
      'Finalization timestamp is required for AVAILABLE storage objects'
      using errcode = '55000';
  end if;

  if new.lifecycle_status = 'QUARANTINED'
     and new.quarantined_at is null then
    raise exception
      'Quarantine timestamp is required'
      using errcode = '55000';
  end if;

  if new.lifecycle_status = 'ABANDONED'
     and new.abandoned_at is null then
    raise exception
      'Abandonment timestamp is required'
      using errcode = '55000';
  end if;

  if new.lifecycle_status = 'DELETION_PENDING' then
    if new.deletion_pending_at is null then
      raise exception
        'Deletion-pending timestamp is required'
        using errcode = '55000';
    end if;

    if new.retain_until is null
       or new.retain_until > clock_timestamp() then
      raise exception
        'Private storage object is not yet retention-eligible for deletion'
        using errcode = '55000';
    end if;

    if exists (
      select 1
      from haulvia.private_storage_object_holds h
      where h.private_storage_object_id = old.id
        and h.released_at is null
    ) then
      raise exception
        'Private storage object has an active hold'
        using errcode = '55000';
    end if;

    if not exists (
      select 1
      from haulvia.private_storage_deletion_requests d
      where d.private_storage_object_id = old.id
        and d.decision = 'APPROVED'
    ) then
      raise exception
        'Approved deletion request is required'
        using errcode = '55000';
    end if;
  end if;

  if new.lifecycle_status = 'PURGED' then
    if new.purged_at is null
       or nullif(
         btrim(new.purge_provider_reference),
         ''
       ) is null
       or new.purge_correlation_id is null then
      raise exception
        'Purge confirmation metadata is required'
        using errcode = '55000';
    end if;

    if exists (
      select 1
      from haulvia.private_storage_object_holds h
      where h.private_storage_object_id = old.id
        and h.released_at is null
    ) then
      raise exception
        'Private storage object has an active hold'
        using errcode = '55000';
    end if;

    if old.retain_until is null
       or old.retain_until > clock_timestamp() then
      raise exception
        'Private storage object is not retention-eligible for purge'
        using errcode = '55000';
    end if;

    if not exists (
      select 1
      from haulvia.private_storage_deletion_requests d
      where d.private_storage_object_id = old.id
        and d.decision = 'APPROVED'
    ) then
      raise exception
        'Approved deletion request is required for purge'
        using errcode = '55000';
    end if;
  end if;

  new.updated_at := clock_timestamp();

  return new;
end;
$function$;


create trigger private_storage_objects_guard_update
before update
on haulvia.private_storage_objects
for each row
execute function haulvia.guard_private_storage_object_update();


create trigger private_storage_objects_reject_delete
before delete
on haulvia.private_storage_objects
for each row
execute function haulvia.reject_delete();


-- ============================================================================
-- 11. Hold-history guard
-- ============================================================================

create or replace function haulvia.guard_private_storage_hold_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  if old.released_at is not null
     and new is distinct from old then
    raise exception
      'Released private storage holds are immutable'
      using errcode = '55000';
  end if;

  if new.id is distinct from old.id
     or new.private_storage_object_id
          is distinct from old.private_storage_object_id
     or new.hold_category
          is distinct from old.hold_category
     or new.reason
          is distinct from old.reason
     or new.placed_by_profile_id
          is distinct from old.placed_by_profile_id
     or new.placed_by_worker_authority
          is distinct from old.placed_by_worker_authority
     or new.placed_at
          is distinct from old.placed_at
     or new.correlation_id
          is distinct from old.correlation_id
     or new.created_at
          is distinct from old.created_at then
    raise exception
      'Private storage hold placement history is immutable'
      using errcode = '55000';
  end if;

  if old.released_at is null
     and new.released_at is null
     and new is distinct from old then
    raise exception
      'Private storage hold may only be updated by releasing it'
      using errcode = '55000';
  end if;

  return new;
end;
$function$;


create trigger private_storage_object_holds_guard_update
before update
on haulvia.private_storage_object_holds
for each row
execute function haulvia.guard_private_storage_hold_update();


create trigger private_storage_object_holds_reject_delete
before delete
on haulvia.private_storage_object_holds
for each row
execute function haulvia.reject_delete();


-- ============================================================================
-- 12. Deletion-request decision guard
-- ============================================================================

create or replace function haulvia.guard_private_storage_deletion_request_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  if old.decision <> 'PENDING'
     and new is distinct from old then
    raise exception
      'Decided private storage deletion requests are immutable'
      using errcode = '55000';
  end if;

  if new.id is distinct from old.id
     or new.private_storage_object_id
          is distinct from old.private_storage_object_id
     or new.requested_by_profile_id
          is distinct from old.requested_by_profile_id
     or new.requested_by_worker_authority
          is distinct from old.requested_by_worker_authority
     or new.reason
          is distinct from old.reason
     or new.requested_at
          is distinct from old.requested_at
     or new.correlation_id
          is distinct from old.correlation_id
     or new.created_at
          is distinct from old.created_at then
    raise exception
      'Private storage deletion-request origin is immutable'
      using errcode = '55000';
  end if;

  if old.decision = 'PENDING'
     and new.decision = 'PENDING'
     and new is distinct from old then
    raise exception
      'Pending deletion request may only be updated by making a decision'
      using errcode = '55000';
  end if;

  return new;
end;
$function$;


create trigger private_storage_deletion_requests_guard_update
before update
on haulvia.private_storage_deletion_requests
for each row
execute function haulvia.guard_private_storage_deletion_request_update();


create trigger private_storage_deletion_requests_reject_delete
before delete
on haulvia.private_storage_deletion_requests
for each row
execute function haulvia.reject_delete();


-- ============================================================================
-- 13. Additional purge-confirmation invariant
-- ============================================================================

alter table haulvia.private_storage_objects
add constraint private_storage_objects_purge_confirmation
check (
  lifecycle_status <> 'PURGED'
  or (
    purged_at is not null
    and nullif(
      btrim(purge_provider_reference),
      ''
    ) is not null
    and purge_correlation_id is not null
  )
);


-- ============================================================================
-- P2D implementation continues below.
-- ============================================================================


-- ============================================================================
-- 14. Private-storage lifecycle authority
-- ============================================================================

insert into haulvia.permissions (
  permission_key,
  description,
  is_sensitive
)
values (
  'PRIVATE_STORAGE_LIFECYCLE_MANAGE',
  'Manage exceptional private-storage lifecycle operations including holds, quarantine release, deletion approval, and purge administration',
  true
)
on conflict (permission_key) do nothing;


do $block$
declare
  v_permission haulvia.permissions%rowtype;
begin
  select *
  into v_permission
  from haulvia.permissions
  where permission_key = 'PRIVATE_STORAGE_LIFECYCLE_MANAGE';

  if v_permission.id is null then
    raise exception
      'PRIVATE_STORAGE_LIFECYCLE_MANAGE permission seed failed'
      using errcode = '55000';
  end if;

  if v_permission.is_sensitive is distinct from true then
    raise exception
      'PRIVATE_STORAGE_LIFECYCLE_MANAGE must be sensitive'
      using errcode = '55000';
  end if;
end;
$block$;


insert into haulvia.role_permissions (
  role_id,
  permission_id
)
select
  r.id,
  p.id
from haulvia.roles r
join haulvia.permissions p
  on p.permission_key = 'PRIVATE_STORAGE_LIFECYCLE_MANAGE'
where r.role_key = 'PLATFORM_ADMIN'
on conflict (role_id, permission_id) do nothing;


do $block$
declare
  v_count integer;
begin
  select count(*)
  into v_count
  from haulvia.role_permissions rp
  join haulvia.roles r
    on r.id = rp.role_id
  join haulvia.permissions p
    on p.id = rp.permission_id
  where p.permission_key = 'PRIVATE_STORAGE_LIFECYCLE_MANAGE';

  if v_count <> 1 then
    raise exception
      'PRIVATE_STORAGE_LIFECYCLE_MANAGE must be assigned to exactly one human role in P2D v1'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from haulvia.role_permissions rp
    join haulvia.roles r
      on r.id = rp.role_id
    join haulvia.permissions p
      on p.id = rp.permission_id
    where p.permission_key = 'PRIVATE_STORAGE_LIFECYCLE_MANAGE'
      and r.role_key = 'PLATFORM_ADMIN'
  ) then
    raise exception
      'PRIVATE_STORAGE_LIFECYCLE_MANAGE must be assigned to PLATFORM_ADMIN'
      using errcode = '55000';
  end if;
end;
$block$;


-- ============================================================================
-- 15. Compliance-document canonical object linkage
-- ============================================================================

alter table haulvia.compliance_documents
add column private_storage_object_id uuid
  not null
  references haulvia.private_storage_objects(id);


alter table haulvia.compliance_documents
add constraint compliance_documents_private_storage_object_id_key
unique (private_storage_object_id);


alter table haulvia.compliance_documents
drop constraint compliance_documents_storage_object_key_key;


alter table haulvia.compliance_documents
drop constraint compliance_documents_content_sha256_check;


alter table haulvia.compliance_documents
drop column storage_object_key;


alter table haulvia.compliance_documents
drop column content_sha256;


-- ============================================================================
-- 16. Stop-evidence canonical object linkage
-- ============================================================================

alter table haulvia.stop_evidence
add column private_storage_object_id uuid
  references haulvia.private_storage_objects(id);


alter table haulvia.stop_evidence
drop constraint stop_evidence_check;


alter table haulvia.stop_evidence
drop constraint stop_evidence_content_sha256_check;


alter table haulvia.stop_evidence
drop column storage_object_key;


alter table haulvia.stop_evidence
drop column content_sha256;


alter table haulvia.stop_evidence
add constraint stop_evidence_private_object_or_structured_check
check (
  private_storage_object_id is not null
  or structured_value <> '{}'::jsonb
);


create unique index stop_evidence_private_storage_object_id_key
on haulvia.stop_evidence (
  private_storage_object_id
)
where private_storage_object_id is not null;


-- ============================================================================
-- 17. Canonical object attachment guard
--
-- Every binary-backed domain attachment:
--   * locks the private object row;
--   * requires AVAILABLE state at attachment time;
--   * prevents reuse across compliance documents and stop evidence.
--
-- Historical domain references remain valid after later lifecycle changes
-- such as quarantine, deletion pending, or purge.
-- ============================================================================

create or replace function haulvia.assert_private_storage_object_attachable(
  p_private_storage_object_id uuid,
  p_consumer_table text
)
returns void
language plpgsql
set search_path = haulvia, pg_temp
as $function$
declare
  v_object haulvia.private_storage_objects%rowtype;
begin
  if p_private_storage_object_id is null then
    raise exception
      'Private storage object ID is required'
      using errcode = '22023';
  end if;

  if p_consumer_table not in (
    'compliance_documents',
    'stop_evidence'
  ) then
    raise exception
      'Unsupported private-storage consumer: %',
      p_consumer_table
      using errcode = '22023';
  end if;

  select *
  into v_object
  from haulvia.private_storage_objects
  where id = p_private_storage_object_id
  for update;

  if v_object.id is null then
    raise exception
      'Private storage object % does not exist',
      p_private_storage_object_id
      using errcode = '23503';
  end if;

  if v_object.lifecycle_status <> 'AVAILABLE' then
    raise exception
      'Private storage object % is not AVAILABLE',
      p_private_storage_object_id
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from haulvia.compliance_documents cd
    where cd.private_storage_object_id = p_private_storage_object_id
  ) then
    raise exception
      'Private storage object % is already attached to a compliance document',
      p_private_storage_object_id
      using errcode = '23505';
  end if;

  if exists (
    select 1
    from haulvia.stop_evidence se
    where se.private_storage_object_id = p_private_storage_object_id
  ) then
    raise exception
      'Private storage object % is already attached to stop evidence',
      p_private_storage_object_id
      using errcode = '23505';
  end if;
end;
$function$;


create or replace function haulvia.guard_compliance_document_private_object()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  perform haulvia.assert_private_storage_object_attachable(
    new.private_storage_object_id,
    'compliance_documents'
  );

  return new;
end;
$function$;


create trigger compliance_documents_private_object_guard
before insert
on haulvia.compliance_documents
for each row
execute function haulvia.guard_compliance_document_private_object();


create or replace function haulvia.guard_stop_evidence_private_object()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  if new.private_storage_object_id is not null then
    perform haulvia.assert_private_storage_object_attachable(
      new.private_storage_object_id,
      'stop_evidence'
    );
  end if;

  return new;
end;
$function$;


create trigger stop_evidence_private_object_guard
before insert
on haulvia.stop_evidence
for each row
execute function haulvia.guard_stop_evidence_private_object();


-- ============================================================================
-- P2D implementation continues below.
-- ============================================================================


-- ============================================================================
-- 18. P2D stop-evidence ingestion contract
--
-- Binary evidence uses privateStorageObjectId.
-- storageObjectKey/contentSha256 are no longer accepted as client-declared
-- canonical storage identity.
-- ============================================================================

create or replace function haulvia_command.insert_evidence_array(
  p_attempt_id uuid,
  p_request jsonb,
  p_array_key text default 'evidence'::text
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_item jsonb;
  v_index integer := 0;
  v_id uuid;
  v_ids jsonb := '[]'::jsonb;
  v_actor uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'actorProfileId'
    );
  v_items jsonb :=
    p_request -> p_array_key;

  v_private_storage_object_id uuid;
  v_structured_value jsonb;
begin
  if jsonb_typeof(v_items) <> 'array'
     or jsonb_array_length(v_items) = 0 then
    perform haulvia_command.fail(
      'EVIDENCE_INVALID',
      format(
        '%s must be a non-empty evidence array',
        p_array_key
      )
    );
  end if;

  for v_item in
    select value
    from jsonb_array_elements(v_items)
  loop
    v_index := v_index + 1;

    if v_item ? 'storageObjectKey'
       or v_item ? 'contentSha256' then
      perform haulvia_command.fail(
        'EVIDENCE_INVALID',
        'Legacy storageObjectKey/contentSha256 evidence fields are not accepted; use privateStorageObjectId'
      );
    end if;

    v_private_storage_object_id := null;

    if nullif(
      btrim(v_item ->> 'privateStorageObjectId'),
      ''
    ) is not null then
      begin
        v_private_storage_object_id :=
          (v_item ->> 'privateStorageObjectId')::uuid;
      exception
        when invalid_text_representation then
          perform haulvia_command.fail(
            'EVIDENCE_INVALID',
            'privateStorageObjectId must be a valid UUID'
          );
      end;
    end if;

    v_structured_value :=
      coalesce(
        v_item -> 'structuredValue',
        '{}'::jsonb
      );

    if v_private_storage_object_id is null
       and v_structured_value = '{}'::jsonb then
      perform haulvia_command.fail(
        'EVIDENCE_INVALID',
        'Evidence must contain privateStorageObjectId or structuredValue'
      );
    end if;

    insert into haulvia.stop_evidence (
      stop_attempt_id,
      evidence_type,
      private_storage_object_id,
      structured_value,
      captured_at,
      captured_latitude,
      captured_longitude,
      captured_accuracy_m,
      submitted_by_profile_id,
      synced_at,
      idempotency_key
    )
    values (
      p_attempt_id,

      haulvia_command.required_text(
        v_item,
        'type'
      )::haulvia.evidence_type,

      v_private_storage_object_id,

      v_structured_value,

      haulvia_command.required_timestamptz(
        v_item,
        'capturedAt'
      ),

      haulvia_command.optional_numeric(
        v_item,
        'latitude'
      ),

      haulvia_command.optional_numeric(
        v_item,
        'longitude'
      ),

      haulvia_command.optional_numeric(
        v_item,
        'accuracyM'
      ),

      v_actor,

      nullif(
        v_item ->> 'syncedAt',
        ''
      )::timestamptz,

      coalesce(
        nullif(
          v_item ->> 'idempotencyKey',
          ''
        ),
        haulvia_command.required_text(
          p_request,
          'idempotencyKey'
        )
        || ':evidence:'
        || v_index::text
      )
    )
    returning id
    into v_id;

    v_ids :=
      v_ids || jsonb_build_array(v_id);
  end loop;

  return jsonb_build_object(
    'count',
    v_index,
    'ids',
    v_ids
  );

exception
  when invalid_text_representation
    or invalid_datetime_format
    or datetime_field_overflow
    or not_null_violation
    or check_violation
    or foreign_key_violation
    or unique_violation
  then
    perform haulvia_command.fail(
      'EVIDENCE_INVALID',
      'Evidence did not satisfy the approved immutable evidence contract',
      jsonb_build_object(
        'databaseMessage',
        sqlerrm
      )
    );

    return null;
end;
$function$;


-- ============================================================================
-- P2D implementation continues below.
-- ============================================================================


-- ============================================================================
-- 19. Custody-transfer retained-photo canonicalization
-- ============================================================================
CREATE OR REPLACE FUNCTION haulvia_command.apply_e09_authorize_custody_transfer(p_shipment haulvia.shipments, p_request jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'haulvia', 'haulvia_command', 'pg_temp'
AS $function$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_to_provider uuid := haulvia_command.required_uuid(p_request, 'replacementProviderId');
  v_to_driver uuid := haulvia_command.required_uuid(p_request, 'replacementDriverId');
  v_to_vehicle uuid := haulvia_command.required_uuid(p_request, 'replacementVehicleId');
  v_to_assignment uuid;
  v_transfer_id uuid;
  v_authorization_id uuid;
  v_manifest jsonb := p_request -> 'transferItems';
  v_handoff jsonb := p_request -> 'handoffSnapshot';
  v_evidence jsonb := p_request -> 'handoffEvidenceManifest';
  v_authority jsonb := p_request -> 'authorizationSnapshot';
  v_custody jsonb;
  v_item jsonb;
  v_from_driver_profile uuid;
  v_to_driver_profile uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'authorizeCustodyTransfer requires ROUTE_IN_PROGRESS');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'CUSTODY_TRANSFER_AUTHORIZE', array['CUSTODY_TRANSFER_WORKER']
  );
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state not in ('ACTIVE', 'HELD', 'RECOVERY_ACTIVE') then
    perform haulvia_command.fail('INVALID_STATE', 'Custody transfer requires the current moving or held route');
  end if;
  if v_to_driver = v_assignment.driver_id then
    perform haulvia_command.fail('INVALID_REQUEST', 'Custody transfer requires a different replacement driver');
  end if;
  perform haulvia_command.assert_replacement_provider_eligible(v_to_provider, v_to_driver, v_to_vehicle);
  v_custody := haulvia_command.assert_transfer_manifest(
    p_shipment.id, v_execution.route_version_id, v_manifest
  );
  if jsonb_typeof(v_handoff) <> 'object' or v_handoff = '{}'::jsonb
     or not coalesce((v_handoff ->> 'fromDriverConfirmed')::boolean, false)
     or not coalesce((v_handoff ->> 'toDriverConfirmed')::boolean, false)
     or not coalesce((v_handoff ->> 'qrOrPinVerified')::boolean, false)
     or nullif(v_handoff ->> 'capturedAt', '') is null
     or nullif(v_handoff ->> 'latitude', '') is null
     or nullif(v_handoff ->> 'longitude', '') is null then
    perform haulvia_command.fail(
      'CUSTODY_HANDOFF_INVALID',
      'Handoff requires QR/PIN, GPS/time, and both driver confirmations'
    );
  end if;
  if jsonb_typeof(v_evidence) <> 'array' or jsonb_array_length(v_evidence) = 0
     or exists (
       select 1
       from jsonb_array_elements(v_evidence) x
       where x ? 'storageObjectKey'
          or x ? 'contentSha256'
     )
     or not exists (
       select 1 from jsonb_array_elements(v_evidence) x
       where upper(coalesce(x ->> 'type', '')) = 'PHOTO'
         and nullif(x ->> 'privateStorageObjectId', '') is not null
         and exists (
           select 1
           from haulvia.private_storage_objects pso
           where pso.id::text = lower(x ->> 'privateStorageObjectId')
             and pso.lifecycle_status = 'AVAILABLE'
         )
     ) then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Custody transfer requires retained photo evidence');
  end if;
  if jsonb_typeof(v_authority) <> 'object' or v_authority = '{}'::jsonb
     or nullif(v_authority ->> 'authorityCode', '') is null then
    perform haulvia_command.fail('INVALID_REQUEST', 'authorizationSnapshot is required');
  end if;

  -- Retire the original active assignment first so the one-active-assignment
  -- index makes the handoff transaction first-valid-commit-wins.
  update haulvia.assignments
  set status = 'TRANSFERRED', ended_at = clock_timestamp(),
      end_reason = haulvia_command.required_text(p_request, 'reason')
  where id = v_assignment.id;
  insert into haulvia.assignment_events (
    assignment_id, shipment_id, prior_status, current_status, command_name,
    actor_kind, actor_profile_id, reason, idempotency_key, metadata
  ) values (
    v_assignment.id, p_shipment.id, 'ACTIVE', 'TRANSFERRED',
    'authorizeCustodyTransfer',
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'reason'),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object('replacementDriverId', v_to_driver, 'custodyBalance', v_custody)
  );
  insert into haulvia.assignments (
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    price_snapshot_id, status, agreement_snapshot
  ) values (
    p_shipment.id, v_execution.route_version_id, v_to_provider, v_to_driver, v_to_vehicle,
    v_assignment.price_snapshot_id, 'ACTIVE',
    v_assignment.agreement_snapshot || jsonb_build_object(
      'custodyTransferredFromAssignmentId', v_assignment.id,
      'handoffSnapshot', v_handoff,
      'authoritySnapshot', v_authority
    )
  ) returning id into v_to_assignment;
  insert into haulvia.assignment_events (
    assignment_id, shipment_id, prior_status, current_status, command_name,
    actor_kind, actor_profile_id, reason, idempotency_key, metadata
  ) values (
    v_to_assignment, p_shipment.id, null, 'ACTIVE', 'authorizeCustodyTransfer',
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'reason'),
    haulvia_command.required_text(p_request, 'idempotencyKey') || ':replacement-assignment',
    jsonb_build_object('replacesAssignmentId', v_assignment.id)
  );
  insert into haulvia.custody_transfers (
    shipment_id, route_execution_id, from_assignment_id, to_assignment_id,
    from_driver_id, to_driver_id, from_vehicle_id, to_vehicle_id,
    status, handoff_snapshot, transferred_at, verified_by_profile_id
  ) values (
    p_shipment.id, v_execution.id, v_assignment.id, v_to_assignment,
    v_assignment.driver_id, v_to_driver, v_assignment.vehicle_id, v_to_vehicle,
    'VERIFIED', v_handoff || jsonb_build_object(
      'custodyBalance', v_custody, 'evidenceManifest', v_evidence
    ), coalesce(nullif(v_handoff ->> 'capturedAt', '')::timestamptz, clock_timestamp()),
    haulvia_command.optional_uuid(p_request, 'actorProfileId')
  ) returning id into v_transfer_id;
  for v_item in select value from jsonb_array_elements(v_manifest)
  loop
    insert into haulvia.custody_transfer_items (
      custody_transfer_id, cargo_allocation_id, quantity, quantity_unit
    ) values (
      v_transfer_id, haulvia_command.required_uuid(v_item, 'cargoAllocationId'),
      haulvia_command.required_numeric(v_item, 'quantity'),
      haulvia_command.required_text(v_item, 'quantityUnit')
    );
  end loop;
  insert into haulvia.custody_transfer_authorizations (
    shipment_id, route_execution_id, route_version_id, custody_transfer_id,
    from_assignment_id, to_assignment_id, custody_balance_snapshot,
    handoff_evidence_manifest, authority_snapshot, authorized_by_profile_id,
    reauth_session_id, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_execution.route_version_id, v_transfer_id,
    v_assignment.id, v_to_assignment, v_custody, v_evidence, v_authority,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.optional_uuid(p_request, 'reauthSessionId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_authorization_id;
  update haulvia.route_executions
  set assignment_id = v_to_assignment,
      next_action = 'RESUME_AFTER_CUSTODY_TRANSFER', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  select d.profile_id into v_from_driver_profile from haulvia.drivers d
  where d.id = v_assignment.driver_id;
  select d.profile_id into v_to_driver_profile from haulvia.drivers d
  where d.id = v_to_driver;
  perform haulvia_command.append_audit(
    p_shipment, 'authorizeCustodyTransfer', p_request,
    jsonb_build_object(
      'assignmentId', v_assignment.id, 'driverId', v_assignment.driver_id,
      'vehicleId', v_assignment.vehicle_id, 'custodyBalance', v_custody
    ),
    jsonb_build_object(
      'assignmentId', v_to_assignment, 'driverId', v_to_driver,
      'vehicleId', v_to_vehicle, 'custodyBalance', v_custody
    ),
    jsonb_build_object(
      'custodyTransferId', v_transfer_id,
      'custodyTransferAuthorizationId', v_authorization_id,
      'physicalCustodyBalanceUnchanged', true
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, v_from_driver_profile, 'CUSTODY_TRANSFER_COMPLETED',
    p_request, 'custody-transfer-from-' || v_transfer_id::text,
    jsonb_build_object('custodyTransferId', v_transfer_id, 'replacementDriverId', v_to_driver)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, v_to_driver_profile, 'CUSTODY_TRANSFER_ACCEPTED',
    p_request, 'custody-transfer-to-' || v_transfer_id::text,
    jsonb_build_object('custodyTransferId', v_transfer_id, 'fromDriverId', v_assignment.driver_id)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'fromAssignmentId', v_assignment.id, 'assignmentId', v_to_assignment,
    'custodyTransferId', v_transfer_id,
    'custodyTransferAuthorizationId', v_authorization_id,
    'custodySummary', v_custody, 'physicalCustodyBalanceUnchanged', true
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail('CUSTODY_HANDOFF_INVALID', 'Custody handoff contains an invalid value');
  return null;
end;
$function$;


-- ============================================================================
-- 20. Legacy storage implementation guard
--
-- Legacy JSON names may remain only for explicit input rejection.
-- No live routine may depend on the retired database columns.
-- ============================================================================

do $block$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'haulvia'
      and table_name in (
        'compliance_documents',
        'stop_evidence'
      )
      and column_name in (
        'storage_object_key',
        'content_sha256'
      )
  ) then
    raise exception
      'P2D left retired storage columns on a domain consumer table'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and p.prokind = 'f'
      and p.prosrc like '%storage_object_key%'
  ) then
    raise exception
      'P2D left a live function referencing retired storage_object_key'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname = 'insert_evidence_array'
      and p.prosrc like '%content_sha256%'
  ) then
    raise exception
      'insert_evidence_array still references retired stop-evidence content_sha256'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname = 'apply_e09_authorize_custody_transfer'
      and p.prosrc like '%nullif(x ->> ''storageObjectKey'', '''') is not null%'
  ) then
    raise exception
      'E09 still positively accepts legacy storageObjectKey evidence'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname = 'insert_evidence_array'
      and p.prosrc like '%privateStorageObjectId%'
  ) then
    raise exception
      'insert_evidence_array does not contain the P2D private object contract'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname = 'apply_e09_authorize_custody_transfer'
      and p.prosrc like '%privateStorageObjectId%'
      and p.prosrc like '%private_storage_objects%'
  ) then
    raise exception
      'E09 does not contain canonical private-storage validation'
      using errcode = '55000';
  end if;
end;
$block$;


-- ============================================================================
-- P2D implementation continues below.
-- ============================================================================


-- ============================================================================
-- 21. P2D storage authority derivation helpers
-- ============================================================================

create or replace function haulvia_command.assert_compliance_document_upload_authority(
  p_compliance_item_id uuid,
  p_request jsonb
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid := haulvia_command.required_uuid(
    p_request,
    'actorProfileId'
  );

  v_actor_organization_id uuid := haulvia_command.required_uuid(
    p_request,
    'actorOrganizationId'
  );

  v_subject haulvia.compliance_subjects%rowtype;
  v_expected_organization_id uuid;
begin
  select cs.*
    into v_subject
  from haulvia.compliance_items ci
  join haulvia.compliance_subjects cs
    on cs.id = ci.subject_id
  where ci.id = p_compliance_item_id;

  if not found then
    perform haulvia_command.fail(
      'COMPLIANCE_ITEM_NOT_FOUND',
      'Compliance item does not exist',
      jsonb_build_object(
        'complianceItemId',
        p_compliance_item_id
      )
    );
  end if;

  case v_subject.subject_kind

    when 'APPLICATION' then
      select pa.applicant_organization_id
        into v_expected_organization_id
      from haulvia.provider_applications pa
      where pa.id = v_subject.application_id;

      if v_expected_organization_id is null then
        perform haulvia_command.fail(
          'COMPLIANCE_SUBJECT_INVALID',
          'Application compliance subject has no resolvable organization',
          jsonb_build_object(
            'complianceItemId',
            p_compliance_item_id,
            'subjectId',
            v_subject.id
          )
        );
      end if;

      if v_actor_organization_id <> v_expected_organization_id then
        perform haulvia_command.fail(
          'NOT_AUTHORIZED',
          'Actor organization does not own this compliance subject'
        );
      end if;


    when 'PROVIDER' then
      select sp.organization_id
        into v_expected_organization_id
      from haulvia.service_providers sp
      where sp.id = v_subject.provider_id;

      if v_expected_organization_id is null then
        perform haulvia_command.fail(
          'COMPLIANCE_SUBJECT_INVALID',
          'Provider compliance subject has no resolvable organization',
          jsonb_build_object(
            'complianceItemId',
            p_compliance_item_id,
            'subjectId',
            v_subject.id
          )
        );
      end if;

      if v_actor_organization_id <> v_expected_organization_id then
        perform haulvia_command.fail(
          'NOT_AUTHORIZED',
          'Actor organization does not own this compliance subject'
        );
      end if;


    when 'VEHICLE' then
      select sp.organization_id
        into v_expected_organization_id
      from haulvia.vehicles v
      join haulvia.service_providers sp
        on sp.id = v.provider_id
      where v.id = v_subject.vehicle_id;

      if v_expected_organization_id is null then
        perform haulvia_command.fail(
          'COMPLIANCE_SUBJECT_INVALID',
          'Vehicle compliance subject has no resolvable organization',
          jsonb_build_object(
            'complianceItemId',
            p_compliance_item_id,
            'subjectId',
            v_subject.id
          )
        );
      end if;

      if v_actor_organization_id <> v_expected_organization_id then
        perform haulvia_command.fail(
          'NOT_AUTHORIZED',
          'Actor organization does not own this compliance subject'
        );
      end if;


    when 'DRIVER' then
      if not exists (
        select 1
        from haulvia.provider_drivers pd
        join haulvia.service_providers sp
          on sp.id = pd.provider_id
        where pd.driver_id = v_subject.driver_id
          and sp.organization_id = v_actor_organization_id
          and pd.status = 'ACTIVE'
          and pd.starts_at <= clock_timestamp()
          and (
            pd.ends_at is null
            or pd.ends_at > clock_timestamp()
          )
      ) then
        perform haulvia_command.fail(
          'NOT_AUTHORIZED',
          'Actor organization does not have an active relationship with this driver'
        );
      end if;


    else
      perform haulvia_command.fail(
        'COMPLIANCE_SUBJECT_INVALID',
        'Compliance subject kind is not supported for document upload',
        jsonb_build_object(
          'complianceItemId',
          p_compliance_item_id,
          'subjectId',
          v_subject.id,
          'subjectKind',
          v_subject.subject_kind
        )
      );

  end case;

  if not haulvia.has_permission(
    v_actor,
    v_actor_organization_id,
    'PROVIDER_DOCUMENT_UPLOAD'
  ) then
    perform haulvia_command.fail(
      'NOT_AUTHORIZED',
      'Provider document upload permission is required'
    );
  end if;

  return v_actor_organization_id;
end;
$function$;


create or replace function haulvia_command.assert_stop_evidence_storage_authority(
  p_stop_attempt_id uuid,
  p_request jsonb
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_assignment haulvia.assignments%rowtype;
  v_actor uuid := haulvia_command.required_uuid(
    p_request,
    'actorProfileId'
  );
begin
  select a.*
    into v_assignment
  from haulvia.stop_attempts sa
  join haulvia.stop_executions se
    on se.id = sa.stop_execution_id
  join haulvia.route_executions re
    on re.id = se.route_execution_id
  join haulvia.assignments a
    on a.id = re.assignment_id
   and a.shipment_id = re.shipment_id
  where sa.id = p_stop_attempt_id;

  if not found then
    perform haulvia_command.fail(
      'STOP_ATTEMPT_NOT_FOUND',
      'Stop attempt does not exist',
      jsonb_build_object(
        'stopAttemptId',
        p_stop_attempt_id
      )
    );
  end if;

  perform haulvia_command.authorize_assigned_driver(
    v_assignment,
    p_request
  );

  return v_actor;
end;
$function$;


create or replace function haulvia_command.assert_storage_worker(
  p_request jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid := haulvia_command.optional_uuid(
    p_request,
    'actorProfileId'
  );
begin
  perform haulvia_command.assert_worker(
    v_actor,
    p_request ->> 'workerAuthority',
    array['STORAGE_WORKER']::text[]
  );
end;
$function$;


create or replace function haulvia_command.assert_private_storage_lifecycle_manager(
  p_request jsonb
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid := haulvia_command.required_uuid(
    p_request,
    'actorProfileId'
  );
begin
  perform haulvia_command.assert_sensitive_command_authority(
    p_request,
    'PRIVATE_STORAGE_LIFECYCLE_MANAGE',
    array[]::text[]
  );

  return v_actor;
end;
$function$;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 22. P2D reserve and finalize commands
-- ============================================================================

create or replace function haulvia_command.apply_p2d_reserve_private_storage_object(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid := haulvia_command.required_uuid(
    p_request,
    'actorProfileId'
  );

  v_command_id uuid := haulvia_command.required_uuid(
    p_request,
    'commandId'
  );

  v_storage_purpose text := upper(
    haulvia_command.required_text(
      p_request,
      'storagePurpose'
    )
  );

  v_storage_provider text := btrim(
    haulvia_command.required_text(
      p_request,
      'storageProvider'
    )
  );

  v_bucket_key text := btrim(
    haulvia_command.required_text(
      p_request,
      'bucketKey'
    )
  );

  v_object_key text := btrim(
    haulvia_command.required_text(
      p_request,
      'objectKey'
    )
  );

  v_original_file_name text := btrim(
    haulvia_command.required_text(
      p_request,
      'originalFileName'
    )
  );

  v_compliance_item_id uuid;
  v_stop_attempt_id uuid;
  v_organization_id uuid;

  v_object haulvia.private_storage_objects%rowtype;
  v_event_metadata jsonb;
begin
  case v_storage_purpose

    when 'COMPLIANCE_DOCUMENT' then
      v_compliance_item_id :=
        haulvia_command.required_uuid(
          p_request,
          'complianceItemId'
        );

      v_organization_id :=
        haulvia_command.assert_compliance_document_upload_authority(
          v_compliance_item_id,
          p_request
        );

      v_event_metadata :=
        jsonb_build_object(
          'storagePurpose',
          v_storage_purpose,
          'complianceItemId',
          v_compliance_item_id
        );


    when 'STOP_EVIDENCE' then
      v_stop_attempt_id :=
        haulvia_command.required_uuid(
          p_request,
          'stopAttemptId'
        );

      perform
        haulvia_command.assert_stop_evidence_storage_authority(
          v_stop_attempt_id,
          p_request
        );

      v_event_metadata :=
        jsonb_build_object(
          'storagePurpose',
          v_storage_purpose,
          'stopAttemptId',
          v_stop_attempt_id
        );


    else
      perform haulvia_command.fail(
        'INVALID_STORAGE_PURPOSE',
        'storagePurpose must be COMPLIANCE_DOCUMENT or STOP_EVIDENCE',
        jsonb_build_object(
          'storagePurpose',
          v_storage_purpose
        )
      );

  end case;

  insert into haulvia.private_storage_objects (
    storage_provider,
    bucket_key,
    object_key,
    original_file_name,
    lifecycle_status,
    reserved_by_profile_id
  )
  values (
    v_storage_provider,
    v_bucket_key,
    v_object_key,
    v_original_file_name,
    'RESERVED',
    v_actor
  )
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'RESERVED',
    null,
    'RESERVED',
    v_actor,
    v_organization_id,
    v_command_id,
    v_event_metadata
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'storageProvider',
    v_object.storage_provider,
    'bucketKey',
    v_object.bucket_key,
    'objectKey',
    v_object.object_key,
    'originalFileName',
    v_object.original_file_name,
    'reservedAt',
    v_object.reserved_at
  );

exception
  when unique_violation then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_CONFLICT',
      'The private storage object locator is already reserved or registered',
      jsonb_build_object(
        'storageProvider',
        v_storage_provider,
        'bucketKey',
        v_bucket_key,
        'objectKey',
        v_object_key
      )
    );

    return null;
end;
$function$;


create or replace function haulvia_command.apply_p2d_finalize_private_storage_object(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_media_type text := btrim(
    haulvia_command.required_text(
      p_request,
      'mediaType'
    )
  );

  v_byte_size_text text := btrim(
    haulvia_command.required_text(
      p_request,
      'byteSize'
    )
  );

  v_content_sha256 text := lower(
    btrim(
      haulvia_command.required_text(
        p_request,
        'contentSha256'
      )
    )
  );

  v_retention_class text := btrim(
    haulvia_command.required_text(
      p_request,
      'retentionClass'
    )
  );

  v_byte_size bigint;
  v_finalized_at timestamptz := clock_timestamp();

  v_object haulvia.private_storage_objects%rowtype;

  v_retention_policy_version_id uuid;
  v_resolved_retention_class text;
  v_retention_snapshot jsonb;
  v_retain_until timestamptz;
begin
  perform haulvia_command.assert_storage_worker(
    p_request
  );

  if v_byte_size_text !~ '^[0-9]+$' then
    perform haulvia_command.fail(
      'INVALID_STORAGE_METADATA',
      'byteSize must be a non-negative integer',
      jsonb_build_object(
        'field',
        'byteSize'
      )
    );
  end if;

  begin
    v_byte_size := v_byte_size_text::bigint;
  exception
    when numeric_value_out_of_range then
      perform haulvia_command.fail(
        'INVALID_STORAGE_METADATA',
        'byteSize is outside the supported integer range',
        jsonb_build_object(
          'field',
          'byteSize'
        )
      );
  end;

  if v_content_sha256 !~ '^[0-9a-f]{64}$' then
    perform haulvia_command.fail(
      'INVALID_STORAGE_METADATA',
      'contentSha256 must be a 64-character SHA-256 hexadecimal value',
      jsonb_build_object(
        'field',
        'contentSha256'
      )
    );
  end if;

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status <> 'RESERVED' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_RESERVED',
      'Only a RESERVED private storage object may be finalized',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  select
    r.retention_policy_version_id,
    r.resolved_retention_class,
    r.retention_snapshot,
    r.retain_until
  into
    v_retention_policy_version_id,
    v_resolved_retention_class,
    v_retention_snapshot,
    v_retain_until
  from haulvia.resolve_private_storage_retention(
    v_retention_class,
    v_finalized_at
  ) r;

  update haulvia.private_storage_objects
  set
    media_type = v_media_type,
    byte_size = v_byte_size,
    content_sha256 = v_content_sha256,
    lifecycle_status = 'AVAILABLE',
    retention_policy_version_id =
      v_retention_policy_version_id,
    retention_class =
      v_resolved_retention_class,
    retention_snapshot =
      v_retention_snapshot,
    retain_until =
      v_retain_until,
    finalized_at =
      v_finalized_at
  where id = v_private_storage_object_id
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    worker_authority,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'FINALIZED',
    'RESERVED',
    'AVAILABLE',
    'STORAGE_WORKER',
    v_command_id,
    jsonb_build_object(
      'mediaType',
      v_object.media_type,
      'byteSize',
      v_object.byte_size,
      'contentSha256',
      v_object.content_sha256,
      'retentionClass',
      v_object.retention_class,
      'retentionPolicyVersionId',
      v_object.retention_policy_version_id,
      'retainUntil',
      v_object.retain_until
    )
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'mediaType',
    v_object.media_type,
    'byteSize',
    v_object.byte_size,
    'contentSha256',
    v_object.content_sha256,
    'retentionClass',
    v_object.retention_class,
    'retentionPolicyVersionId',
    v_object.retention_policy_version_id,
    'retainUntil',
    v_object.retain_until,
    'finalizedAt',
    v_object.finalized_at
  );
end;
$function$;


-- ============================================================================
-- 23. P2D storage command dispatcher
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;
  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject' then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;

  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;

  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

  end case;

  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


-- ============================================================================
-- 24. Service-role command wrappers
-- ============================================================================

create or replace function haulvia_command.command_reserve_private_storage_object(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'reservePrivateStorageObject',
    p_request
  );
$function$;


create or replace function haulvia_command.command_finalize_private_storage_object(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'finalizePrivateStorageObject',
    p_request
  );
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


revoke all
on function haulvia_command.command_reserve_private_storage_object(
  jsonb
)
from public, anon, authenticated;


revoke all
on function haulvia_command.command_finalize_private_storage_object(
  jsonb
)
from public, anon, authenticated;


grant execute
on function haulvia_command.command_reserve_private_storage_object(
  jsonb
)
to service_role;


grant execute
on function haulvia_command.command_finalize_private_storage_object(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 25. P2D abandonment and quarantine lifecycle commands
-- ============================================================================

create or replace function haulvia_command.apply_p2d_abandon_private_storage_object(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_object haulvia.private_storage_objects%rowtype;
begin
  perform haulvia_command.assert_storage_worker(
    p_request
  );

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status <> 'RESERVED' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_RESERVED',
      'Only a RESERVED private storage object may be abandoned',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  update haulvia.private_storage_objects
  set
    lifecycle_status = 'ABANDONED',
    abandoned_at = clock_timestamp()
  where id = v_private_storage_object_id
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    worker_authority,
    reason,
    correlation_id
  )
  values (
    v_object.id,
    'ABANDONED',
    'RESERVED',
    'ABANDONED',
    'STORAGE_WORKER',
    v_reason,
    v_command_id
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'abandonedAt',
    v_object.abandoned_at
  );
end;
$function$;


create or replace function haulvia_command.apply_p2d_quarantine_private_storage_object(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;
  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_object haulvia.private_storage_objects%rowtype;
begin
  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status <> 'AVAILABLE' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_AVAILABLE',
      'Only an AVAILABLE private storage object may be quarantined',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  update haulvia.private_storage_objects
  set
    lifecycle_status = 'QUARANTINED',
    quarantined_at = clock_timestamp()
  where id = v_private_storage_object_id
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id
  )
  values (
    v_object.id,
    'QUARANTINED',
    'AVAILABLE',
    'QUARANTINED',
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'quarantinedAt',
    v_object.quarantined_at
  );
end;
$function$;


create or replace function haulvia_command.apply_p2d_release_private_storage_quarantine(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;
  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_object haulvia.private_storage_objects%rowtype;
begin
  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status <> 'QUARANTINED' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_QUARANTINED',
      'Only a QUARANTINED private storage object may be released',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  update haulvia.private_storage_objects
  set
    lifecycle_status = 'AVAILABLE'
  where id = v_private_storage_object_id
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id
  )
  values (
    v_object.id,
    'QUARANTINE_RELEASED',
    'QUARANTINED',
    'AVAILABLE',
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'originalQuarantinedAt',
    v_object.quarantined_at
  );
end;
$function$;


-- ============================================================================
-- 26. Extend P2D storage dispatcher
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject' then
      v_actor := null;

    when 'abandonPrivateStorageObject' then
      v_actor := null;

    when 'quarantinePrivateStorageObject' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'releasePrivateStorageQuarantine' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;

  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;

  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

  end case;

  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


-- Reassert dispatcher isolation after replacement.
revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 27. Additional lifecycle service-role wrappers
-- ============================================================================

create or replace function haulvia_command.command_abandon_private_storage_object(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'abandonPrivateStorageObject',
    p_request
  );
$function$;


create or replace function haulvia_command.command_quarantine_private_storage_object(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'quarantinePrivateStorageObject',
    p_request
  );
$function$;


create or replace function haulvia_command.command_release_private_storage_quarantine(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'releasePrivateStorageQuarantine',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_abandon_private_storage_object(
  jsonb
)
from public, anon, authenticated;


revoke all
on function haulvia_command.command_quarantine_private_storage_object(
  jsonb
)
from public, anon, authenticated;


revoke all
on function haulvia_command.command_release_private_storage_quarantine(
  jsonb
)
from public, anon, authenticated;


grant execute
on function haulvia_command.command_abandon_private_storage_object(
  jsonb
)
to service_role;


grant execute
on function haulvia_command.command_quarantine_private_storage_object(
  jsonb
)
to service_role;


grant execute
on function haulvia_command.command_release_private_storage_quarantine(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 28. P2D storage hold commands
-- ============================================================================

create or replace function haulvia_command.apply_p2d_place_private_storage_hold(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;

  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_hold_category_text text :=
    upper(
      haulvia_command.required_text(
        p_request,
        'holdCategory'
      )
    );

  v_hold_category haulvia.private_storage_hold_category;

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_object haulvia.private_storage_objects%rowtype;
  v_hold haulvia.private_storage_object_holds%rowtype;
begin
  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  begin
    v_hold_category :=
      v_hold_category_text::haulvia.private_storage_hold_category;
  exception
    when invalid_text_representation then
      perform haulvia_command.fail(
        'INVALID_HOLD_CATEGORY',
        'holdCategory is not a supported private-storage hold category',
        jsonb_build_object(
          'holdCategory',
          v_hold_category_text
        )
      );
  end;

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status not in (
    'AVAILABLE',
    'QUARANTINED',
    'DELETION_PENDING'
  ) then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_HOLD_NOT_ALLOWED',
      'A hold may only be placed on an AVAILABLE, QUARANTINED, or DELETION_PENDING object',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  begin
    insert into haulvia.private_storage_object_holds (
      private_storage_object_id,
      hold_category,
      reason,
      placed_by_profile_id,
      correlation_id
    )
    values (
      v_private_storage_object_id,
      v_hold_category,
      v_reason,
      v_actor,
      v_command_id
    )
    returning *
    into v_hold;

  exception
    when unique_violation then
      perform haulvia_command.fail(
        'PRIVATE_STORAGE_HOLD_ALREADY_ACTIVE',
        'An active hold of this category already exists for the private storage object',
        jsonb_build_object(
          'privateStorageObjectId',
          v_private_storage_object_id,
          'holdCategory',
          v_hold_category
        )
      );
  end;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'HOLD_PLACED',
    v_object.lifecycle_status,
    v_object.lifecycle_status,
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id,
    jsonb_build_object(
      'holdId',
      v_hold.id,
      'holdCategory',
      v_hold.hold_category
    )
  );

  return jsonb_build_object(
    'holdId',
    v_hold.id,
    'privateStorageObjectId',
    v_hold.private_storage_object_id,
    'holdCategory',
    v_hold.hold_category,
    'reason',
    v_hold.reason,
    'placedAt',
    v_hold.placed_at,
    'lifecycleStatus',
    v_object.lifecycle_status
  );
end;
$function$;


create or replace function haulvia_command.apply_p2d_release_private_storage_hold(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_hold_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'holdId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;

  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_hold haulvia.private_storage_object_holds%rowtype;
  v_object haulvia.private_storage_objects%rowtype;
begin
  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  select h.*
    into v_hold
  from haulvia.private_storage_object_holds h
  where h.id = v_hold_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_HOLD_NOT_FOUND',
      'Private storage hold does not exist',
      jsonb_build_object(
        'holdId',
        v_hold_id
      )
    );
  end if;

  if v_hold.released_at is not null then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_HOLD_ALREADY_RELEASED',
      'Private storage hold has already been released',
      jsonb_build_object(
        'holdId',
        v_hold_id,
        'releasedAt',
        v_hold.released_at
      )
    );
  end if;

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_hold.private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object for the hold does not exist',
      jsonb_build_object(
        'holdId',
        v_hold_id,
        'privateStorageObjectId',
        v_hold.private_storage_object_id
      )
    );
  end if;

  update haulvia.private_storage_object_holds
  set
    released_by_profile_id = v_actor,
    release_reason = v_reason,
    released_at = clock_timestamp()
  where id = v_hold_id
  returning *
  into v_hold;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'HOLD_RELEASED',
    v_object.lifecycle_status,
    v_object.lifecycle_status,
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id,
    jsonb_build_object(
      'holdId',
      v_hold.id,
      'holdCategory',
      v_hold.hold_category
    )
  );

  return jsonb_build_object(
    'holdId',
    v_hold.id,
    'privateStorageObjectId',
    v_hold.private_storage_object_id,
    'holdCategory',
    v_hold.hold_category,
    'releasedAt',
    v_hold.released_at,
    'releaseReason',
    v_hold.release_reason,
    'lifecycleStatus',
    v_object.lifecycle_status
  );
end;
$function$;


-- ============================================================================
-- 29. Extend P2D dispatcher with hold commands
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject' then
      v_actor := null;

    when 'abandonPrivateStorageObject' then
      v_actor := null;

    when 'quarantinePrivateStorageObject' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'releasePrivateStorageQuarantine' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'placePrivateStorageHold' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'releasePrivateStorageHold' then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;

  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;

  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

  end case;

  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 30. Hold service-role wrappers
-- ============================================================================

create or replace function haulvia_command.command_place_private_storage_hold(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'placePrivateStorageHold',
    p_request
  );
$function$;


create or replace function haulvia_command.command_release_private_storage_hold(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'releasePrivateStorageHold',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_place_private_storage_hold(
  jsonb
)
from public, anon, authenticated;


revoke all
on function haulvia_command.command_release_private_storage_hold(
  jsonb
)
from public, anon, authenticated;


grant execute
on function haulvia_command.command_place_private_storage_hold(
  jsonb
)
to service_role;


grant execute
on function haulvia_command.command_release_private_storage_hold(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 31. P2D deletion-request commands
-- ============================================================================

-- Only one undecided deletion request may exist for an object at a time.
create unique index private_storage_deletion_requests_pending_unique
on haulvia.private_storage_deletion_requests (
  private_storage_object_id
)
where decision = 'PENDING';


create or replace function haulvia_command.apply_p2d_request_private_storage_deletion(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;

  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_object haulvia.private_storage_objects%rowtype;
  v_request haulvia.private_storage_deletion_requests%rowtype;
begin
  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status not in (
    'AVAILABLE',
    'QUARANTINED'
  ) then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_REQUEST_NOT_ALLOWED',
      'Deletion may only be requested for an AVAILABLE or QUARANTINED object',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  begin
    insert into haulvia.private_storage_deletion_requests (
      private_storage_object_id,
      requested_by_profile_id,
      reason,
      correlation_id
    )
    values (
      v_private_storage_object_id,
      v_actor,
      v_reason,
      v_command_id
    )
    returning *
    into v_request;

  exception
    when unique_violation then
      perform haulvia_command.fail(
        'PRIVATE_STORAGE_DELETION_REQUEST_ALREADY_PENDING',
        'A pending deletion request already exists for this private storage object',
        jsonb_build_object(
          'privateStorageObjectId',
          v_private_storage_object_id
        )
      );
  end;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'DELETION_REQUESTED',
    v_object.lifecycle_status,
    v_object.lifecycle_status,
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id,
    jsonb_build_object(
      'deletionRequestId',
      v_request.id,
      'decision',
      v_request.decision
    )
  );

  return jsonb_build_object(
    'deletionRequestId',
    v_request.id,
    'privateStorageObjectId',
    v_request.private_storage_object_id,
    'decision',
    v_request.decision,
    'requestedAt',
    v_request.requested_at,
    'lifecycleStatus',
    v_object.lifecycle_status
  );
end;
$function$;


create or replace function haulvia_command.apply_p2d_decide_private_storage_deletion(
  p_request jsonb,
  p_decision haulvia.private_storage_deletion_decision
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_deletion_request_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'deletionRequestId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;

  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_provider_purge_correlation_id uuid;

  v_request haulvia.private_storage_deletion_requests%rowtype;
  v_object haulvia.private_storage_objects%rowtype;
  v_event_type haulvia.private_storage_event_type;
begin
  if p_decision not in (
    'APPROVED',
    'REJECTED',
    'CANCELLED'
  ) then
    perform haulvia_command.fail(
      'INVALID_DELETION_DECISION',
      'Deletion decision must be APPROVED, REJECTED, or CANCELLED'
    );
  end if;

  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  select dr.*
    into v_request
  from haulvia.private_storage_deletion_requests dr
  where dr.id = v_deletion_request_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_REQUEST_NOT_FOUND',
      'Private storage deletion request does not exist',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request_id
      )
    );
  end if;

  if v_request.decision <> 'PENDING' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_REQUEST_ALREADY_DECIDED',
      'Private storage deletion request has already been decided',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request_id,
        'decision',
        v_request.decision
      )
    );
  end if;

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_request.private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object for the deletion request does not exist',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request_id,
        'privateStorageObjectId',
        v_request.private_storage_object_id
      )
    );
  end if;

  if p_decision = 'APPROVED' then
    v_provider_purge_correlation_id := gen_random_uuid();
  else
    v_provider_purge_correlation_id := null;
  end if;

  update haulvia.private_storage_deletion_requests
  set
    decision = p_decision,
    decided_by_profile_id = v_actor,
    decision_reason = v_reason,
    decided_at = clock_timestamp(),
    provider_purge_correlation_id =
      v_provider_purge_correlation_id
  where id = v_deletion_request_id
  returning *
  into v_request;

  v_event_type :=
    case p_decision
      when 'APPROVED' then 'DELETION_APPROVED'
      when 'REJECTED' then 'DELETION_REJECTED'
      when 'CANCELLED' then 'DELETION_CANCELLED'
    end;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    v_event_type,
    v_object.lifecycle_status,
    v_object.lifecycle_status,
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'deletionRequestId',
        v_request.id,
        'decision',
        v_request.decision,
        'providerPurgeCorrelationId',
        v_request.provider_purge_correlation_id
      )
    )
  );

  return jsonb_strip_nulls(
    jsonb_build_object(
      'deletionRequestId',
      v_request.id,
      'privateStorageObjectId',
      v_request.private_storage_object_id,
      'decision',
      v_request.decision,
      'decidedAt',
      v_request.decided_at,
      'providerPurgeCorrelationId',
      v_request.provider_purge_correlation_id,
      'lifecycleStatus',
      v_object.lifecycle_status
    )
  );
end;
$function$;


-- 32. Extend P2D dispatcher with deletion-request commands
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject',
         'quarantinePrivateStorageObject',
         'releasePrivateStorageQuarantine',
         'placePrivateStorageHold',
         'releasePrivateStorageHold',
         'requestPrivateStorageDeletion',
         'approvePrivateStorageDeletion',
         'rejectPrivateStorageDeletion',
         'cancelPrivateStorageDeletion'
    then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject',
         'abandonPrivateStorageObject'
    then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;

  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;

  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

    when 'requestPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_request_private_storage_deletion(
          p_request
        );

    when 'approvePrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'APPROVED'
        );

    when 'rejectPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'REJECTED'
        );

    when 'cancelPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'CANCELLED'
        );

  end case;

  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 33. Deletion-request service-role wrappers
-- ============================================================================

create or replace function haulvia_command.command_request_private_storage_deletion(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'requestPrivateStorageDeletion',
    p_request
  );
$function$;


create or replace function haulvia_command.command_approve_private_storage_deletion(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'approvePrivateStorageDeletion',
    p_request
  );
$function$;


create or replace function haulvia_command.command_reject_private_storage_deletion(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'rejectPrivateStorageDeletion',
    p_request
  );
$function$;


create or replace function haulvia_command.command_cancel_private_storage_deletion(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'cancelPrivateStorageDeletion',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_request_private_storage_deletion(jsonb)
from public, anon, authenticated;

revoke all
on function haulvia_command.command_approve_private_storage_deletion(jsonb)
from public, anon, authenticated;

revoke all
on function haulvia_command.command_reject_private_storage_deletion(jsonb)
from public, anon, authenticated;

revoke all
on function haulvia_command.command_cancel_private_storage_deletion(jsonb)
from public, anon, authenticated;


grant execute
on function haulvia_command.command_request_private_storage_deletion(jsonb)
to service_role;

grant execute
on function haulvia_command.command_approve_private_storage_deletion(jsonb)
to service_role;

grant execute
on function haulvia_command.command_reject_private_storage_deletion(jsonb)
to service_role;

grant execute
on function haulvia_command.command_cancel_private_storage_deletion(jsonb)
to service_role;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 34. P2D deletion-pending transition
-- ============================================================================

create or replace function haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_deletion_request_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'deletionRequestId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid;

  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_reason text :=
    haulvia_command.required_text(
      p_request,
      'reason'
    );

  v_deletion_request
    haulvia.private_storage_deletion_requests%rowtype;

  v_object
    haulvia.private_storage_objects%rowtype;

  v_prior_status
    haulvia.private_storage_lifecycle_status;

  v_deletion_pending_at timestamptz :=
    clock_timestamp();
begin
  v_actor :=
    haulvia_command.assert_private_storage_lifecycle_manager(
      p_request
    );

  select dr.*
    into v_deletion_request
  from haulvia.private_storage_deletion_requests dr
  where dr.id = v_deletion_request_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_REQUEST_NOT_FOUND',
      'Private storage deletion request does not exist',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request_id
      )
    );
  end if;

  if v_deletion_request.decision <> 'APPROVED' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_NOT_APPROVED',
      'Deletion request must be APPROVED before the object can enter deletion pending',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request.id,
        'decision',
        v_deletion_request.decision
      )
    );
  end if;

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id =
    v_deletion_request.private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object for the deletion request does not exist',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request.id,
        'privateStorageObjectId',
        v_deletion_request.private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status not in (
    'AVAILABLE',
    'QUARANTINED'
  ) then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_PENDING_NOT_ALLOWED',
      'Only an AVAILABLE or QUARANTINED object may enter deletion pending',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  if v_object.retain_until is null
     or v_object.retain_until > v_deletion_pending_at then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_RETENTION_NOT_ELAPSED',
      'Private storage retention period has not yet elapsed',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id,
        'retainUntil',
        v_object.retain_until
      )
    );
  end if;

  if exists (
    select 1
    from haulvia.private_storage_object_holds h
    where h.private_storage_object_id = v_object.id
      and h.released_at is null
  ) then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_ACTIVE_HOLD',
      'Private storage object has an active hold and cannot enter deletion pending',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id
      )
    );
  end if;

  v_prior_status := v_object.lifecycle_status;

  update haulvia.private_storage_objects
  set
    lifecycle_status = 'DELETION_PENDING',
    deletion_pending_at = v_deletion_pending_at
  where id = v_object.id
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    actor_profile_id,
    organization_id,
    reason,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'DELETION_PENDING',
    v_prior_status,
    'DELETION_PENDING',
    v_actor,
    v_organization_id,
    v_reason,
    v_command_id,
    jsonb_build_object(
      'deletionRequestId',
      v_deletion_request.id,
      'decision',
      v_deletion_request.decision,
      'retainUntil',
      v_object.retain_until
    )
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'deletionRequestId',
    v_deletion_request.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'deletionPendingAt',
    v_object.deletion_pending_at,
    'retainUntil',
    v_object.retain_until
  );
end;
$function$;


-- ============================================================================
-- 35. Extend P2D dispatcher with deletion-pending transition
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject',
         'quarantinePrivateStorageObject',
         'releasePrivateStorageQuarantine',
         'placePrivateStorageHold',
         'releasePrivateStorageHold',
         'requestPrivateStorageDeletion',
         'approvePrivateStorageDeletion',
         'rejectPrivateStorageDeletion',
         'cancelPrivateStorageDeletion',
         'markPrivateStorageDeletionPending'
    then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject',
         'abandonPrivateStorageObject'
    then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;

  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;

  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

    when 'requestPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_request_private_storage_deletion(
          p_request
        );

    when 'approvePrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'APPROVED'
        );

    when 'rejectPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'REJECTED'
        );

    when 'cancelPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'CANCELLED'
        );

    when 'markPrivateStorageDeletionPending' then
      v_result :=
        haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
          p_request
        );

  end case;

  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 36. Deletion-pending service-role wrapper
-- ============================================================================

create or replace function haulvia_command.command_mark_private_storage_deletion_pending(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'markPrivateStorageDeletionPending',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_mark_private_storage_deletion_pending(
  jsonb
)
from public, anon, authenticated;


grant execute
on function haulvia_command.command_mark_private_storage_deletion_pending(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 37. P2D physical purge confirmation
-- ============================================================================

create or replace function haulvia_command.apply_p2d_confirm_private_storage_purge(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_deletion_request_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'deletionRequestId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_provider_purge_correlation_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'providerPurgeCorrelationId'
    );

  v_purge_provider_reference text :=
    btrim(
      haulvia_command.required_text(
        p_request,
        'purgeProviderReference'
      )
    );

  v_purged_at timestamptz :=
    clock_timestamp();

  v_deletion_request
    haulvia.private_storage_deletion_requests%rowtype;

  v_object
    haulvia.private_storage_objects%rowtype;
begin
  perform haulvia_command.assert_storage_worker(
    p_request
  );

  select dr.*
    into v_deletion_request
  from haulvia.private_storage_deletion_requests dr
  where dr.id = v_deletion_request_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_REQUEST_NOT_FOUND',
      'Private storage deletion request does not exist',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request_id
      )
    );
  end if;

  if v_deletion_request.decision <> 'APPROVED' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_DELETION_NOT_APPROVED',
      'Only an APPROVED deletion request may be physically purged',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request.id,
        'decision',
        v_deletion_request.decision
      )
    );
  end if;

  if v_deletion_request.provider_purge_correlation_id is null then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_PURGE_CORRELATION_MISSING',
      'Approved deletion request does not contain a provider purge correlation',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request.id
      )
    );
  end if;

  if v_provider_purge_correlation_id
       <> v_deletion_request.provider_purge_correlation_id then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_PURGE_CORRELATION_MISMATCH',
      'Provider purge correlation does not match the approved deletion request',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request.id,
        'providerPurgeCorrelationId',
        v_provider_purge_correlation_id
      )
    );
  end if;

  select pso.*
    into v_object
  from haulvia.private_storage_objects pso
  where pso.id =
    v_deletion_request.private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object for the deletion request does not exist',
      jsonb_build_object(
        'deletionRequestId',
        v_deletion_request.id,
        'privateStorageObjectId',
        v_deletion_request.private_storage_object_id
      )
    );
  end if;

  if v_object.lifecycle_status <> 'DELETION_PENDING' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_DELETION_PENDING',
      'Only a DELETION_PENDING private storage object may be purged',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;

  if v_object.retain_until is null
     or v_object.retain_until > v_purged_at then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_RETENTION_NOT_ELAPSED',
      'Private storage retention period has not elapsed',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id,
        'retainUntil',
        v_object.retain_until
      )
    );
  end if;

  if exists (
    select 1
    from haulvia.private_storage_object_holds h
    where h.private_storage_object_id = v_object.id
      and h.released_at is null
  ) then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_ACTIVE_HOLD',
      'Private storage object has an active hold and cannot be purged',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id
      )
    );
  end if;

  update haulvia.private_storage_objects
  set
    lifecycle_status = 'PURGED',
    purged_at = v_purged_at,
    purge_provider_reference =
      v_purge_provider_reference,
    purge_correlation_id =
      v_provider_purge_correlation_id
  where id = v_object.id
  returning *
  into v_object;

  insert into haulvia.private_storage_object_events (
    private_storage_object_id,
    event_type,
    prior_status,
    current_status,
    worker_authority,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    'PURGED',
    'DELETION_PENDING',
    'PURGED',
    'STORAGE_WORKER',
    v_command_id,
    jsonb_build_object(
      'deletionRequestId',
      v_deletion_request.id,
      'providerPurgeCorrelationId',
      v_deletion_request.provider_purge_correlation_id,
      'purgeProviderReference',
      v_object.purge_provider_reference
    )
  );

  return jsonb_build_object(
    'privateStorageObjectId',
    v_object.id,
    'deletionRequestId',
    v_deletion_request.id,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'purgedAt',
    v_object.purged_at,
    'providerPurgeCorrelationId',
    v_object.purge_correlation_id,
    'purgeProviderReference',
    v_object.purge_provider_reference
  );
end;
$function$;


-- ============================================================================
-- 38. Extend P2D dispatcher with purge confirmation
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject',
         'quarantinePrivateStorageObject',
         'releasePrivateStorageQuarantine',
         'placePrivateStorageHold',
         'releasePrivateStorageHold',
         'requestPrivateStorageDeletion',
         'approvePrivateStorageDeletion',
         'rejectPrivateStorageDeletion',
         'cancelPrivateStorageDeletion',
         'markPrivateStorageDeletionPending'
    then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject',
         'abandonPrivateStorageObject',
         'confirmPrivateStoragePurge'
    then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;

  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;

  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

    when 'requestPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_request_private_storage_deletion(
          p_request
        );

    when 'approvePrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'APPROVED'
        );

    when 'rejectPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'REJECTED'
        );

    when 'cancelPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'CANCELLED'
        );

    when 'markPrivateStorageDeletionPending' then
      v_result :=
        haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
          p_request
        );

    when 'confirmPrivateStoragePurge' then
      v_result :=
        haulvia_command.apply_p2d_confirm_private_storage_purge(
          p_request
        );

  end case;

  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 39. Purge-confirmation service-role wrapper
-- ============================================================================

create or replace function haulvia_command.command_confirm_private_storage_purge(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'confirmPrivateStoragePurge',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_confirm_private_storage_purge(
  jsonb
)
from public, anon, authenticated;


grant execute
on function haulvia_command.command_confirm_private_storage_purge(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D command implementation continues below.
-- ============================================================================


-- ============================================================================
-- 40. P2D compliance-document protected access
--
-- This command does NOT create a signed provider URL.
--
-- It:
--   * resolves the canonical private-storage object;
--   * authorizes provider-side or sensitive Haulvia-staff access;
--   * requires the object to remain AVAILABLE;
--   * writes an immutable ALLOWED or DENIED access event;
--   * returns provider locator data only for ALLOWED access.
--
-- The backend storage adapter uses the returned provider locator to create the
-- short-lived provider access mechanism outside the database.
--
-- Expected authorization/lifecycle denials are returned rather than raised so
-- the DENIED audit event remains committed with the command.
-- ============================================================================

create or replace function haulvia_command.apply_p2d_prepare_compliance_document_access(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_compliance_document_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'complianceDocumentId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorProfileId'
    );

  v_organization_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_purpose text :=
    haulvia_command.required_text(
      p_request,
      'purpose'
    );

  v_context record;

  v_object
    haulvia.private_storage_objects%rowtype;

  v_provider_subject_owned boolean := false;
  v_provider_authorized boolean := false;
  v_sensitive_authorized boolean := false;

  v_access_result
    haulvia.private_storage_access_result;

  v_authority_path text;
  v_denial_reason text;

  v_access_event_id uuid;
begin
  -- --------------------------------------------------------------------------
  -- Resolve the domain consumer and canonical object.
  -- --------------------------------------------------------------------------

  select
    cd.id as compliance_document_id,
    cd.compliance_item_id,
    ci.subject_id,
    cs.subject_kind,
    cs.application_id,
    cs.provider_id,
    cs.driver_id,
    cs.vehicle_id,
    cd.private_storage_object_id
  into v_context
  from haulvia.compliance_documents cd
  join haulvia.compliance_items ci
    on ci.id = cd.compliance_item_id
  join haulvia.compliance_subjects cs
    on cs.id = ci.subject_id
  where cd.id = v_compliance_document_id;

  if not found then
    perform haulvia_command.fail(
      'COMPLIANCE_DOCUMENT_NOT_FOUND',
      'Compliance document does not exist',
      jsonb_build_object(
        'complianceDocumentId',
        v_compliance_document_id
      )
    );
  end if;


  select pso.*
  into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_context.private_storage_object_id
  for share;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Canonical private storage object for the compliance document does not exist',
      jsonb_build_object(
        'complianceDocumentId',
        v_compliance_document_id
      )
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Provider-side ownership derivation.
  --
  -- APPLICATION -> applicant organization
  -- PROVIDER    -> provider organization
  -- VEHICLE     -> vehicle provider organization
  -- DRIVER      -> active/effective provider-driver organization
  -- --------------------------------------------------------------------------

  if v_context.subject_kind = 'APPLICATION' then

    select exists (
      select 1
      from haulvia.provider_applications pa
      where pa.id = v_context.application_id
        and pa.applicant_organization_id = v_organization_id
    )
    into v_provider_subject_owned;

  elsif v_context.subject_kind = 'PROVIDER' then

    select exists (
      select 1
      from haulvia.service_providers sp
      where sp.id = v_context.provider_id
        and sp.organization_id = v_organization_id
    )
    into v_provider_subject_owned;

  elsif v_context.subject_kind = 'VEHICLE' then

    select exists (
      select 1
      from haulvia.vehicles v
      join haulvia.service_providers sp
        on sp.id = v.provider_id
      where v.id = v_context.vehicle_id
        and sp.organization_id = v_organization_id
    )
    into v_provider_subject_owned;

  elsif v_context.subject_kind = 'DRIVER' then

    select exists (
      select 1
      from haulvia.provider_drivers pd
      join haulvia.service_providers sp
        on sp.id = pd.provider_id
      where pd.driver_id = v_context.driver_id
        and sp.organization_id = v_organization_id
        and pd.status = 'ACTIVE'
        and pd.starts_at <= clock_timestamp()
        and (
          pd.ends_at is null
          or pd.ends_at > clock_timestamp()
        )
    )
    into v_provider_subject_owned;

  else
    v_provider_subject_owned := false;

  end if;


  v_provider_authorized :=
    v_provider_subject_owned
    and haulvia.has_permission(
      v_actor,
      v_organization_id,
      'PROVIDER_DOCUMENT_VIEW'
    );


  -- --------------------------------------------------------------------------
  -- Sensitive Haulvia-staff access.
  --
  -- Reuse the existing sensitive-command authority exactly:
  --   * SENSITIVE_DOCUMENT_VIEW
  --   * active organization authority
  --   * written reason
  --   * fresh reauthentication
  --
  -- The nested block is a subtransaction. Expected authority failures are
  -- absorbed here so the outer command can persist a DENIED access event.
  -- --------------------------------------------------------------------------

  if not v_provider_authorized then
    begin
      perform haulvia_command.assert_sensitive_command_authority(
        p_request,
        'SENSITIVE_DOCUMENT_VIEW',
        array[]::text[]
      );

      v_sensitive_authorized := true;

    exception
      when sqlstate 'P0001'
        or sqlstate '42501'
      then
        v_sensitive_authorized := false;
    end;
  end if;


  -- --------------------------------------------------------------------------
  -- Determine access result.
  --
  -- Quarantined, deletion-pending, purged, abandoned, or still-reserved
  -- objects never produce provider locator information.
  -- --------------------------------------------------------------------------

  if v_provider_authorized then
    v_authority_path := 'PROVIDER_DOCUMENT_VIEW';

  elsif v_sensitive_authorized then
    v_authority_path := 'SENSITIVE_DOCUMENT_VIEW';

  else
    v_access_result := 'DENIED';
    v_denial_reason := 'NOT_AUTHORIZED';
  end if;


  if v_access_result is null
     and v_object.lifecycle_status <> 'AVAILABLE' then

    v_access_result := 'DENIED';
    v_denial_reason := 'OBJECT_NOT_AVAILABLE';

  end if;


  if v_access_result is null then
    v_access_result := 'ALLOWED';
  end if;


  -- --------------------------------------------------------------------------
  -- Immutable access audit.
  -- --------------------------------------------------------------------------

  insert into haulvia.private_storage_access_events (
    private_storage_object_id,
    actor_profile_id,
    organization_id,
    access_action,
    purpose,
    result,
    correlation_id,
    metadata
  )
  values (
    v_object.id,
    v_actor,
    v_organization_id,
    'PREPARE_DOWNLOAD',
    v_purpose,
    v_access_result,
    v_command_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'consumerType',
        'COMPLIANCE_DOCUMENT',
        'complianceDocumentId',
        v_compliance_document_id,
        'complianceItemId',
        v_context.compliance_item_id,
        'subjectKind',
        v_context.subject_kind,
        'authorityPath',
        v_authority_path,
        'denialReason',
        v_denial_reason,
        'objectLifecycleStatus',
        v_object.lifecycle_status
      )
    )
  )
  returning id
  into v_access_event_id;


  -- --------------------------------------------------------------------------
  -- Denied access deliberately returns no provider locator.
  -- --------------------------------------------------------------------------

  if v_access_result = 'DENIED' then
    return jsonb_build_object(
      'accessResult',
      'DENIED',
      'reasonCode',
      v_denial_reason,
      'accessEventId',
      v_access_event_id,
      'complianceDocumentId',
      v_compliance_document_id
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Trusted-backend locator.
  --
  -- This result is reachable only through the service-role wrapper below.
  -- It is input to the provider adapter, not a public object URL.
  -- --------------------------------------------------------------------------

  return jsonb_build_object(
    'accessResult',
    'ALLOWED',
    'accessEventId',
    v_access_event_id,
    'complianceDocumentId',
    v_compliance_document_id,
    'privateStorageObjectId',
    v_object.id,
    'storageProvider',
    v_object.storage_provider,
    'bucketKey',
    v_object.bucket_key,
    'objectKey',
    v_object.object_key,
    'originalFileName',
    v_object.original_file_name,
    'mediaType',
    v_object.media_type,
    'byteSize',
    v_object.byte_size,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'authorityPath',
    v_authority_path
  );
end;
$function$;


revoke all
on function haulvia_command.apply_p2d_prepare_compliance_document_access(
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 41. Extend P2D dispatcher with compliance-document access
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject',
         'quarantinePrivateStorageObject',
         'releasePrivateStorageQuarantine',
         'placePrivateStorageHold',
         'releasePrivateStorageHold',
         'requestPrivateStorageDeletion',
         'approvePrivateStorageDeletion',
         'rejectPrivateStorageDeletion',
         'cancelPrivateStorageDeletion',
         'markPrivateStorageDeletionPending',
         'prepareComplianceDocumentAccess'
    then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject',
         'abandonPrivateStorageObject',
         'confirmPrivateStoragePurge'
    then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;


  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;


  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

    when 'requestPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_request_private_storage_deletion(
          p_request
        );

    when 'approvePrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'APPROVED'
        );

    when 'rejectPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'REJECTED'
        );

    when 'cancelPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'CANCELLED'
        );

    when 'markPrivateStorageDeletionPending' then
      v_result :=
        haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
          p_request
        );

    when 'confirmPrivateStoragePurge' then
      v_result :=
        haulvia_command.apply_p2d_confirm_private_storage_purge(
          p_request
        );

    when 'prepareComplianceDocumentAccess' then
      v_result :=
        haulvia_command.apply_p2d_prepare_compliance_document_access(
          p_request
        );

  end case;


  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 42. Compliance-document access service-role wrapper
-- ============================================================================

create or replace function haulvia_command.command_prepare_compliance_document_access(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'prepareComplianceDocumentAccess',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_prepare_compliance_document_access(
  jsonb
)
from public, anon, authenticated, service_role;


grant execute
on function haulvia_command.command_prepare_compliance_document_access(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D protected-object access implementation continues below.
-- ============================================================================

-- ============================================================================
-- 43. P2D stop-evidence protected access
--
-- Binary stop evidence may be accessed by:
--   * the driver tied to the evidence's assignment; or
--   * an authorized STOP_EVIDENCE_REVIEW reviewer; or
--   * the trusted EVIDENCE_REVIEWER worker.
--
-- The canonical private object must remain AVAILABLE.
--
-- Expected authorization/lifecycle denials are returned instead of raised so
-- the immutable DENIED access event remains committed.
-- ============================================================================

create or replace function haulvia_command.apply_p2d_prepare_stop_evidence_access(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_stop_evidence_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'stopEvidenceId'
    );

  v_command_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'commandId'
    );

  v_actor uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'actorProfileId'
    );

  v_organization_id uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'actorOrganizationId'
    );

  v_worker_authority text :=
    nullif(
      upper(
        btrim(
          coalesce(
            p_request ->> 'workerAuthority',
            ''
          )
        )
      ),
      ''
    );

  v_purpose text :=
    haulvia_command.required_text(
      p_request,
      'purpose'
    );

  v_context record;

  v_assignment
    haulvia.assignments%rowtype;

  v_object
    haulvia.private_storage_objects%rowtype;

  v_driver_authorized boolean := false;
  v_reviewer_authorized boolean := false;

  v_access_result
    haulvia.private_storage_access_result;

  v_authority_path text;
  v_denial_reason text;

  v_access_event_id uuid;
begin
  -- --------------------------------------------------------------------------
  -- Resolve evidence -> stop attempt -> stop execution -> route execution ->
  -- assignment and the canonical private-storage object.
  -- --------------------------------------------------------------------------

  select
    e.id as stop_evidence_id,
    e.stop_attempt_id,
    e.evidence_type,
    e.private_storage_object_id,

    sa.stop_execution_id,

    se.shipment_id,
    se.route_execution_id,
    se.route_version_id,
    se.route_stop_id,

    re.assignment_id
  into v_context
  from haulvia.stop_evidence e
  join haulvia.stop_attempts sa
    on sa.id = e.stop_attempt_id
  join haulvia.stop_executions se
    on se.id = sa.stop_execution_id
  join haulvia.route_executions re
    on re.id = se.route_execution_id
  where e.id = v_stop_evidence_id;

  if not found then
    perform haulvia_command.fail(
      'STOP_EVIDENCE_NOT_FOUND',
      'Stop evidence does not exist',
      jsonb_build_object(
        'stopEvidenceId',
        v_stop_evidence_id
      )
    );
  end if;


  -- Structured-only evidence has no private binary object to retrieve.
  if v_context.private_storage_object_id is null then
    perform haulvia_command.fail(
      'STOP_EVIDENCE_HAS_NO_PRIVATE_OBJECT',
      'Stop evidence is structured-only and has no private binary object',
      jsonb_build_object(
        'stopEvidenceId',
        v_stop_evidence_id,
        'evidenceType',
        v_context.evidence_type
      )
    );
  end if;


  select a.*
  into v_assignment
  from haulvia.assignments a
  where a.id = v_context.assignment_id;

  if not found then
    perform haulvia_command.fail(
      'ASSIGNMENT_NOT_FOUND',
      'Assignment for stop evidence does not exist',
      jsonb_build_object(
        'stopEvidenceId',
        v_stop_evidence_id,
        'assignmentId',
        v_context.assignment_id
      )
    );
  end if;


  select pso.*
  into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_context.private_storage_object_id
  for share;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Canonical private storage object for stop evidence does not exist',
      jsonb_build_object(
        'stopEvidenceId',
        v_stop_evidence_id,
        'privateStorageObjectId',
        v_context.private_storage_object_id
      )
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Assigned-driver authorization.
  --
  -- Expected authorization failure is absorbed so a reviewer path may still
  -- authorize the same request.
  -- --------------------------------------------------------------------------

  if v_actor is not null then
    begin
      perform haulvia_command.authorize_assigned_driver(
        v_assignment,
        p_request
      );

      v_driver_authorized := true;

    exception
      when sqlstate 'P0001'
        or sqlstate '42501'
      then
        v_driver_authorized := false;
    end;
  end if;


  -- --------------------------------------------------------------------------
  -- Reviewer authorization.
  --
  -- Existing authority:
  --   human -> STOP_EVIDENCE_REVIEW in actorOrganizationId
  --   worker -> EVIDENCE_REVIEWER
  --
  -- Again, expected denial is absorbed so it can be persistently audited.
  -- --------------------------------------------------------------------------

  if not v_driver_authorized then
    begin
      perform haulvia_command.authorize_evidence_reviewer(
        p_request
      );

      v_reviewer_authorized := true;

    exception
      when sqlstate 'P0001'
        or sqlstate '42501'
      then
        v_reviewer_authorized := false;
    end;
  end if;


  -- --------------------------------------------------------------------------
  -- Determine authorization path and object eligibility.
  -- --------------------------------------------------------------------------

  if v_driver_authorized then
    v_authority_path := 'ASSIGNED_DRIVER';

  elsif v_reviewer_authorized
        and v_actor is not null then
    v_authority_path := 'STOP_EVIDENCE_REVIEW';

  elsif v_reviewer_authorized
        and v_actor is null then
    v_authority_path := 'EVIDENCE_REVIEWER';

  else
    v_access_result := 'DENIED';
    v_denial_reason := 'NOT_AUTHORIZED';
  end if;


  if v_access_result is null
     and v_object.lifecycle_status <> 'AVAILABLE' then

    v_access_result := 'DENIED';
    v_denial_reason := 'OBJECT_NOT_AVAILABLE';

  end if;


  if v_access_result is null then
    v_access_result := 'ALLOWED';
  end if;


  -- --------------------------------------------------------------------------
  -- Immutable access audit.
  -- --------------------------------------------------------------------------

  insert into haulvia.private_storage_access_events (
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
    v_object.id,
    v_actor,
    v_organization_id,
    case
      when v_actor is null
        then v_worker_authority
      else null
    end,
    'PREPARE_DOWNLOAD',
    v_purpose,
    v_access_result,
    v_command_id,
    jsonb_strip_nulls(
      jsonb_build_object(
        'consumerType',
        'STOP_EVIDENCE',
        'stopEvidenceId',
        v_stop_evidence_id,
        'stopAttemptId',
        v_context.stop_attempt_id,
        'stopExecutionId',
        v_context.stop_execution_id,
        'routeExecutionId',
        v_context.route_execution_id,
        'assignmentId',
        v_context.assignment_id,
        'shipmentId',
        v_context.shipment_id,
        'evidenceType',
        v_context.evidence_type,
        'authorityPath',
        v_authority_path,
        'denialReason',
        v_denial_reason,
        'objectLifecycleStatus',
        v_object.lifecycle_status
      )
    )
  )
  returning id
  into v_access_event_id;


  -- --------------------------------------------------------------------------
  -- Denied access deliberately returns no provider locator.
  -- --------------------------------------------------------------------------

  if v_access_result = 'DENIED' then
    return jsonb_build_object(
      'accessResult',
      'DENIED',
      'reasonCode',
      v_denial_reason,
      'accessEventId',
      v_access_event_id,
      'stopEvidenceId',
      v_stop_evidence_id
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Trusted-backend provider locator.
  -- --------------------------------------------------------------------------

  return jsonb_build_object(
    'accessResult',
    'ALLOWED',
    'accessEventId',
    v_access_event_id,
    'stopEvidenceId',
    v_stop_evidence_id,
    'privateStorageObjectId',
    v_object.id,
    'storageProvider',
    v_object.storage_provider,
    'bucketKey',
    v_object.bucket_key,
    'objectKey',
    v_object.object_key,
    'originalFileName',
    v_object.original_file_name,
    'mediaType',
    v_object.media_type,
    'byteSize',
    v_object.byte_size,
    'lifecycleStatus',
    v_object.lifecycle_status,
    'authorityPath',
    v_authority_path
  );
end;
$function$;


revoke all
on function haulvia_command.apply_p2d_prepare_stop_evidence_access(
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 44. Extend P2D dispatcher with stop-evidence protected access
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject',
         'quarantinePrivateStorageObject',
         'releasePrivateStorageQuarantine',
         'placePrivateStorageHold',
         'releasePrivateStorageHold',
         'requestPrivateStorageDeletion',
         'approvePrivateStorageDeletion',
         'rejectPrivateStorageDeletion',
         'cancelPrivateStorageDeletion',
         'markPrivateStorageDeletionPending',
         'prepareComplianceDocumentAccess'
    then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'prepareStopEvidenceAccess' then
      v_actor :=
        haulvia_command.optional_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject',
         'abandonPrivateStorageObject',
         'confirmPrivateStoragePurge'
    then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;


  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;


  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

    when 'requestPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_request_private_storage_deletion(
          p_request
        );

    when 'approvePrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'APPROVED'
        );

    when 'rejectPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'REJECTED'
        );

    when 'cancelPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'CANCELLED'
        );

    when 'markPrivateStorageDeletionPending' then
      v_result :=
        haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
          p_request
        );

    when 'confirmPrivateStoragePurge' then
      v_result :=
        haulvia_command.apply_p2d_confirm_private_storage_purge(
          p_request
        );

    when 'prepareComplianceDocumentAccess' then
      v_result :=
        haulvia_command.apply_p2d_prepare_compliance_document_access(
          p_request
        );

    when 'prepareStopEvidenceAccess' then
      v_result :=
        haulvia_command.apply_p2d_prepare_stop_evidence_access(
          p_request
        );

  end case;


  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 45. Stop-evidence access service-role wrapper
-- ============================================================================

create or replace function haulvia_command.command_prepare_stop_evidence_access(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'prepareStopEvidenceAccess',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_prepare_stop_evidence_access(
  jsonb
)
from public, anon, authenticated, service_role;


grant execute
on function haulvia_command.command_prepare_stop_evidence_access(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D protected-object access implementation continues below.
-- ============================================================================

-- ============================================================================
-- 46. P2D canonical consumer-link immutability
--
-- Once a domain record references a canonical private-storage object, that
-- object reference is historical identity and must not be replaced.
--
-- Other legitimate updates to the consumer records remain unaffected.
-- ============================================================================

create or replace function haulvia.guard_compliance_document_private_object_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  if new.private_storage_object_id
       is distinct from old.private_storage_object_id then

    raise exception
      'Compliance document private storage object is immutable'
      using errcode = '55000';

  end if;

  return new;
end;
$function$;


create trigger compliance_documents_private_object_update_guard
before update of private_storage_object_id
on haulvia.compliance_documents
for each row
execute function haulvia.guard_compliance_document_private_object_update();


create or replace function haulvia.guard_stop_evidence_private_object_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $function$
begin
  if new.private_storage_object_id
       is distinct from old.private_storage_object_id then

    raise exception
      'Stop evidence private storage object is immutable'
      using errcode = '55000';

  end if;

  return new;
end;
$function$;


create trigger stop_evidence_private_object_update_guard
before update of private_storage_object_id
on haulvia.stop_evidence
for each row
execute function haulvia.guard_stop_evidence_private_object_update();


-- ============================================================================
-- P2D domain registration implementation continues below.
-- ============================================================================

-- ============================================================================
-- 47. P2D compliance-document registration
--
-- Registration is the domain attachment step after storage finalization.
--
-- Invariants:
--   * human actor must retain PROVIDER_DOCUMENT_UPLOAD authority;
--   * object must be AVAILABLE;
--   * object must have been reserved by this actor/org;
--   * immutable RESERVED event must bind the object to this compliance item;
--   * object must not already be attached to another consumer;
--   * compliance-item version allocation is serialized by locking the item;
--   * file name/media type are taken from canonical finalized storage metadata.
-- ============================================================================

create or replace function haulvia_command.apply_p2d_register_compliance_document(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid :=
    haulvia_command.required_uuid(
      p_request,
      'actorProfileId'
    );

  v_compliance_item_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'complianceItemId'
    );

  v_private_storage_object_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'privateStorageObjectId'
    );

  v_organization_id uuid;

  v_object
    haulvia.private_storage_objects%rowtype;

  v_document
    haulvia.compliance_documents%rowtype;

  v_version_no integer;

  v_reservation_found boolean := false;
begin
  -- --------------------------------------------------------------------------
  -- Reassert upload authority at the actual domain attachment boundary.
  -- --------------------------------------------------------------------------

  v_organization_id :=
    haulvia_command.assert_compliance_document_upload_authority(
      v_compliance_item_id,
      p_request
    );


  -- --------------------------------------------------------------------------
  -- Serialize version allocation for this compliance item.
  -- --------------------------------------------------------------------------

  perform 1
  from haulvia.compliance_items ci
  where ci.id = v_compliance_item_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'COMPLIANCE_ITEM_NOT_FOUND',
      'Compliance item does not exist',
      jsonb_build_object(
        'complianceItemId',
        v_compliance_item_id
      )
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Lock and validate canonical private object.
  -- --------------------------------------------------------------------------

  select pso.*
  into v_object
  from haulvia.private_storage_objects pso
  where pso.id = v_private_storage_object_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_FOUND',
      'Private storage object does not exist',
      jsonb_build_object(
        'privateStorageObjectId',
        v_private_storage_object_id
      )
    );
  end if;


  if v_object.lifecycle_status <> 'AVAILABLE' then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_NOT_AVAILABLE',
      'Compliance document registration requires an AVAILABLE private storage object',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id,
        'lifecycleStatus',
        v_object.lifecycle_status
      )
    );
  end if;


  if v_object.reserved_by_profile_id is distinct from v_actor then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_RESERVATION_ACTOR_MISMATCH',
      'Private storage object was not reserved by the registering actor',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id
      )
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Verify immutable reservation provenance.
  --
  -- The RESERVED event is the canonical purpose/consumer binding established
  -- before binary upload begins.
  -- --------------------------------------------------------------------------

  select exists (
    select 1
    from haulvia.private_storage_object_events e
    where e.private_storage_object_id = v_object.id
      and e.event_type = 'RESERVED'
      and e.actor_profile_id = v_actor
      and e.organization_id = v_organization_id
      and e.metadata ->> 'storagePurpose' = 'COMPLIANCE_DOCUMENT'
      and e.metadata ->> 'complianceItemId' =
            v_compliance_item_id::text
  )
  into v_reservation_found;


  if not v_reservation_found then
    perform haulvia_command.fail(
      'PRIVATE_STORAGE_RESERVATION_MISMATCH',
      'Private storage object was not reserved for this compliance item',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id,
        'complianceItemId',
        v_compliance_item_id
      )
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Reject reuse explicitly before the table attachment guard runs.
  -- --------------------------------------------------------------------------

  if exists (
    select 1
    from haulvia.compliance_documents cd
    where cd.private_storage_object_id = v_object.id
  )
  or exists (
    select 1
    from haulvia.stop_evidence se
    where se.private_storage_object_id = v_object.id
  ) then

    perform haulvia_command.fail(
      'PRIVATE_STORAGE_OBJECT_ALREADY_ATTACHED',
      'Private storage object is already attached to a domain record',
      jsonb_build_object(
        'privateStorageObjectId',
        v_object.id
      )
    );
  end if;


  -- --------------------------------------------------------------------------
  -- Version allocation is safe because the compliance_item row is locked.
  -- --------------------------------------------------------------------------

  select
    coalesce(max(cd.version_no), 0) + 1
  into v_version_no
  from haulvia.compliance_documents cd
  where cd.compliance_item_id = v_compliance_item_id;


  -- --------------------------------------------------------------------------
  -- Register canonical compliance document.
  --
  -- status defaults to SUBMITTED.
  -- uploaded_at / created_at use their table defaults.
  -- --------------------------------------------------------------------------

  insert into haulvia.compliance_documents (
    compliance_item_id,
    version_no,
    file_name,
    media_type,
    uploaded_by_profile_id,
    private_storage_object_id
  )
  values (
    v_compliance_item_id,
    v_version_no,
    v_object.original_file_name,
    v_object.media_type,
    v_actor,
    v_object.id
  )
  returning *
  into v_document;


  return jsonb_build_object(
    'complianceDocumentId',
    v_document.id,
    'complianceItemId',
    v_document.compliance_item_id,
    'privateStorageObjectId',
    v_document.private_storage_object_id,
    'versionNo',
    v_document.version_no,
    'fileName',
    v_document.file_name,
    'mediaType',
    v_document.media_type,
    'status',
    v_document.status,
    'uploadedByProfileId',
    v_document.uploaded_by_profile_id,
    'uploadedAt',
    v_document.uploaded_at
  );
end;
$function$;


revoke all
on function haulvia_command.apply_p2d_register_compliance_document(
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 48. Extend P2D dispatcher with compliance-document registration
-- ============================================================================

create or replace function haulvia_command.execute_p2d_storage_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
declare
  v_actor uuid;

  v_idempotency_key text :=
    haulvia_command.required_text(
      p_request,
      'idempotencyKey'
    );

  v_request_hash text :=
    haulvia_command.required_text(
      p_request,
      'requestHash'
    );

  v_replay jsonb;
  v_result jsonb;
begin
  case p_command_name

    when 'reservePrivateStorageObject',
         'quarantinePrivateStorageObject',
         'releasePrivateStorageQuarantine',
         'placePrivateStorageHold',
         'releasePrivateStorageHold',
         'requestPrivateStorageDeletion',
         'approvePrivateStorageDeletion',
         'rejectPrivateStorageDeletion',
         'cancelPrivateStorageDeletion',
         'markPrivateStorageDeletionPending',
         'prepareComplianceDocumentAccess',
         'registerComplianceDocument'
    then
      v_actor :=
        haulvia_command.required_uuid(
          p_request,
          'actorProfileId'
        );

    when 'prepareStopEvidenceAccess' then
      v_actor :=
        haulvia_command.optional_uuid(
          p_request,
          'actorProfileId'
        );

    when 'finalizePrivateStorageObject',
         'abandonPrivateStorageObject',
         'confirmPrivateStoragePurge'
    then
      v_actor := null;

    else
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Command is not an approved P2D storage handler'
      );

  end case;


  v_replay :=
    haulvia_command.begin_request(
      v_actor,
      p_command_name,
      v_idempotency_key,
      v_request_hash
    );

  if v_replay is not null then
    return v_replay;
  end if;


  case p_command_name

    when 'reservePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_reserve_private_storage_object(
          p_request
        );

    when 'finalizePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_finalize_private_storage_object(
          p_request
        );

    when 'abandonPrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_abandon_private_storage_object(
          p_request
        );

    when 'quarantinePrivateStorageObject' then
      v_result :=
        haulvia_command.apply_p2d_quarantine_private_storage_object(
          p_request
        );

    when 'releasePrivateStorageQuarantine' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_quarantine(
          p_request
        );

    when 'placePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_place_private_storage_hold(
          p_request
        );

    when 'releasePrivateStorageHold' then
      v_result :=
        haulvia_command.apply_p2d_release_private_storage_hold(
          p_request
        );

    when 'requestPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_request_private_storage_deletion(
          p_request
        );

    when 'approvePrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'APPROVED'
        );

    when 'rejectPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'REJECTED'
        );

    when 'cancelPrivateStorageDeletion' then
      v_result :=
        haulvia_command.apply_p2d_decide_private_storage_deletion(
          p_request,
          'CANCELLED'
        );

    when 'markPrivateStorageDeletionPending' then
      v_result :=
        haulvia_command.apply_p2d_mark_private_storage_deletion_pending(
          p_request
        );

    when 'confirmPrivateStoragePurge' then
      v_result :=
        haulvia_command.apply_p2d_confirm_private_storage_purge(
          p_request
        );

    when 'prepareComplianceDocumentAccess' then
      v_result :=
        haulvia_command.apply_p2d_prepare_compliance_document_access(
          p_request
        );

    when 'prepareStopEvidenceAccess' then
      v_result :=
        haulvia_command.apply_p2d_prepare_stop_evidence_access(
          p_request
        );

    when 'registerComplianceDocument' then
      v_result :=
        haulvia_command.apply_p2d_register_compliance_document(
          p_request
        );

  end case;


  return haulvia_command.complete_request(
    v_actor,
    p_command_name,
    v_idempotency_key,
    v_result
  );
end;
$function$;


revoke all
on function haulvia_command.execute_p2d_storage_command(
  text,
  jsonb
)
from public, anon, authenticated, service_role;


-- ============================================================================
-- 49. Compliance-document registration service-role wrapper
-- ============================================================================

create or replace function haulvia_command.command_register_compliance_document(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $function$
  select haulvia_command.execute_p2d_storage_command(
    'registerComplianceDocument',
    p_request
  );
$function$;


revoke all
on function haulvia_command.command_register_compliance_document(
  jsonb
)
from public, anon, authenticated, service_role;


grant execute
on function haulvia_command.command_register_compliance_document(
  jsonb
)
to service_role;


-- ============================================================================
-- P2D security closure and acceptance preparation continues below.
-- ============================================================================

-- ============================================================================
-- 50. P2D security closure
--
-- P2C already hardened future-object defaults. This section explicitly closes
-- the complete P2D surface and asserts the resulting security boundary.
--
-- Rules:
--   * all five P2D storage tables remain RLS-enabled;
--   * PUBLIC, anon, authenticated and service_role receive no raw table access;
--   * internal P2D functions are not directly executable by client roles or
--     service_role;
--   * only the 16 intended command_* wrappers are executable by service_role;
--   * P2D SECURITY DEFINER entry points must retain a controlled search_path.
-- ============================================================================


-- --------------------------------------------------------------------------
-- 50.1 RLS remains enabled on every P2D base table.
-- --------------------------------------------------------------------------

alter table haulvia.private_storage_objects
  enable row level security;

alter table haulvia.private_storage_object_events
  enable row level security;

alter table haulvia.private_storage_object_holds
  enable row level security;

alter table haulvia.private_storage_deletion_requests
  enable row level security;

alter table haulvia.private_storage_access_events
  enable row level security;


-- --------------------------------------------------------------------------
-- 50.2 Explicitly remove raw-table privileges.
-- --------------------------------------------------------------------------

revoke all privileges
on table
  haulvia.private_storage_objects,
  haulvia.private_storage_object_events,
  haulvia.private_storage_object_holds,
  haulvia.private_storage_deletion_requests,
  haulvia.private_storage_access_events
from public;


do $$
declare
  v_role text;
begin
  foreach v_role in array array[
    'anon',
    'authenticated',
    'service_role'
  ]
  loop
    if exists (
      select 1
      from pg_roles
      where rolname = v_role
    ) then
      execute format(
        'revoke all privileges on table
           haulvia.private_storage_objects,
           haulvia.private_storage_object_events,
           haulvia.private_storage_object_holds,
           haulvia.private_storage_deletion_requests,
           haulvia.private_storage_access_events
         from %I',
        v_role
      );
    end if;
  end loop;
end
$$;


-- --------------------------------------------------------------------------
-- 50.3 Remove direct EXECUTE from the complete P2D function surface.
--
-- Existing Phase 1/P2A/P2B/P2C functions outside this list are untouched.
-- Intended wrappers are re-granted to service_role immediately afterward.
-- --------------------------------------------------------------------------

do $$
declare
  v_signature text;
  v_role text;

  v_wrapper_names text[] := array[
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
  ];
begin
  for v_signature in
    select format(
      '%I.%I(%s)',
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid)
    )
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where
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
          or p.proname = 'execute_p2d_storage_command'
          or p.proname in (
            'assert_compliance_document_upload_authority',
            'assert_stop_evidence_storage_authority',
            'assert_storage_worker',
            'assert_private_storage_lifecycle_manager'
          )
          or p.proname = any(v_wrapper_names)
        )
      )
  loop
    execute format(
      'revoke all privileges on function %s from public',
      v_signature
    );

    foreach v_role in array array[
      'anon',
      'authenticated',
      'service_role'
    ]
    loop
      if exists (
        select 1
        from pg_roles
        where rolname = v_role
      ) then
        execute format(
          'revoke all privileges on function %s from %I',
          v_signature,
          v_role
        );
      end if;
    end loop;
  end loop;
end
$$;


-- --------------------------------------------------------------------------
-- 50.4 Re-grant only the intended trusted P2D wrappers.
-- --------------------------------------------------------------------------

do $$
declare
  v_wrapper_name text;

  v_wrapper_names text[] := array[
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
  ];
begin
  if not exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    raise exception
      'P2D security closure requires service_role to exist';
  end if;

  foreach v_wrapper_name in array v_wrapper_names
  loop
    if to_regprocedure(
      'haulvia_command.' ||
      v_wrapper_name ||
      '(jsonb)'
    ) is null then
      raise exception
        'P2D expected wrapper % does not exist',
        v_wrapper_name;
    end if;

    execute format(
      'grant execute on function haulvia_command.%I(jsonb) to service_role',
      v_wrapper_name
    );
  end loop;
end
$$;


-- --------------------------------------------------------------------------
-- 50.5 Assert all five P2D base tables remain RLS-enabled.
-- --------------------------------------------------------------------------

do $$
declare
  v_missing_rls_count bigint;
begin
  select count(*)
  into v_missing_rls_count
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
    and not c.relrowsecurity;

  if v_missing_rls_count <> 0 then
    raise exception
      'P2D security closure detected % storage table(s) without RLS',
      v_missing_rls_count;
  end if;
end
$$;


-- --------------------------------------------------------------------------
-- 50.6 Assert prohibited raw-table ACLs are absent.
-- --------------------------------------------------------------------------

do $$
declare
  v_bad_table_acl_count bigint;
begin
  with target_tables as (
    select
      c.oid,
      c.relacl,
      c.relowner
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
  expanded_acl as (
    select
      a.grantee,
      r.rolname
    from target_tables t
    cross join lateral aclexplode(
      coalesce(
        t.relacl,
        acldefault('r', t.relowner)
      )
    ) a
    left join pg_roles r
      on r.oid = a.grantee
  )
  select count(*)
  into v_bad_table_acl_count
  from expanded_acl
  where grantee = 0
     or rolname in (
       'anon',
       'authenticated',
       'service_role'
     );

  if v_bad_table_acl_count <> 0 then
    raise exception
      'P2D security closure detected % prohibited raw-table ACL grant(s)',
      v_bad_table_acl_count;
  end if;
end
$$;


-- --------------------------------------------------------------------------
-- 50.7 Assert P2D function EXECUTE surface.
-- --------------------------------------------------------------------------

do $$
declare
  v_bad_function_acl_count bigint;
  v_missing_wrapper_count bigint;

  v_wrapper_names text[] := array[
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
  ];
begin
  with target_functions as (
    select
      p.oid,
      p.proname,
      p.proacl,
      p.proowner
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where
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
          or p.proname = 'execute_p2d_storage_command'
          or p.proname in (
            'assert_compliance_document_upload_authority',
            'assert_stop_evidence_storage_authority',
            'assert_storage_worker',
            'assert_private_storage_lifecycle_manager'
          )
          or p.proname = any(v_wrapper_names)
        )
      )
  ),
  expanded_acl as (
    select
      tf.proname,
      a.grantee,
      r.rolname,
      a.privilege_type
    from target_functions tf
    cross join lateral aclexplode(
      coalesce(
        tf.proacl,
        acldefault('f', tf.proowner)
      )
    ) a
    left join pg_roles r
      on r.oid = a.grantee
  )
  select count(*)
  into v_bad_function_acl_count
  from expanded_acl
  where privilege_type = 'EXECUTE'
    and (
      grantee = 0
      or rolname in (
        'anon',
        'authenticated'
      )
      or (
        rolname = 'service_role'
        and not (
          proname = any(v_wrapper_names)
        )
      )
    );

  if v_bad_function_acl_count <> 0 then
    raise exception
      'P2D security closure detected % prohibited function EXECUTE grant(s)',
      v_bad_function_acl_count;
  end if;


  select count(*)
  into v_missing_wrapper_count
  from unnest(v_wrapper_names) w(wrapper_name)
  where not has_function_privilege(
    'service_role',
    to_regprocedure(
      'haulvia_command.' ||
      wrapper_name ||
      '(jsonb)'
    ),
    'EXECUTE'
  );

  if v_missing_wrapper_count <> 0 then
    raise exception
      'P2D security closure detected % wrapper(s) missing service_role EXECUTE',
      v_missing_wrapper_count;
  end if;
end
$$;


-- --------------------------------------------------------------------------
-- 50.8 Assert P2D SECURITY DEFINER entry-point hardening.
-- --------------------------------------------------------------------------

do $$
declare
  v_bad_security_definer_count bigint;

  v_wrapper_names text[] := array[
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
  ];
begin
  select count(*)
  into v_bad_security_definer_count
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and (
      p.proname = 'execute_p2d_storage_command'
      or p.proname = any(v_wrapper_names)
    )
    and (
      not p.prosecdef

      or pg_get_userbyid(p.proowner) in (
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
          and cfg like '%haulvia%'
          and cfg like '%haulvia_command%'
          and cfg like '%pg_temp%'
          and cfg not like '%public%'
      )
    );

  if v_bad_security_definer_count <> 0 then
    raise exception
      'P2D security closure detected % unsafe SECURITY DEFINER entry point(s)',
      v_bad_security_definer_count;
  end if;
end
$$;


-- ============================================================================
-- P2D implementation complete.
--
-- COMMIT intentionally remains absent until the rollback-only P2D acceptance
-- suite passes against the cumulative Foundation -> P2A -> P2B -> P2C -> P2D
-- chain.
-- ============================================================================