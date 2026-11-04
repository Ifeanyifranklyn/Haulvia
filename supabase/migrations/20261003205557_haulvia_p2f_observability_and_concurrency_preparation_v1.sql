-- Haulvia P2F Observability and Concurrency Preparation v1
--
-- Frozen contract:
-- docs/Haulvia_P2F_Observability_and_Concurrency_Contract_v1.md
--
-- Frozen contract SHA-256:
-- B09E4D8E9556854FB491BC908A111A46466BCE46DEB5A8C0E844A737118AB945
--
-- Baseline:
-- P2A through P2E are complete.
--
-- P2F is additive.
-- Existing command, shipment, financial, dispute, compliance, route,
-- custody and provider-integration relations remain authoritative.
--
-- This migration is production-deployable and therefore owns exactly
-- one BEGIN and one final COMMIT.
-- ============================================================================

begin;

set local search_path =
  haulvia,
  haulvia_command,
  public;


-- ============================================================================
-- P2F-BLOCK-1-BEGIN
--
-- Observability configuration foundation and durable sanitized
-- command-failure observations.
-- ============================================================================


-- ============================================================================
-- 1. Prospective worker-authority / human-role separation hardening
--
-- Preserve every established P2E worker authority and add
-- OBSERVABILITY_WORKER as backend execution authority only.
-- ============================================================================

do $$
begin
  if exists (
    select 1
    from haulvia.roles
    where role_key =
      'OBSERVABILITY_WORKER'
  ) then
    raise exception
      'OBSERVABILITY_WORKER must not exist as a human role'
      using errcode = '23514';
  end if;
end;
$$;


create or replace function
haulvia.reject_worker_authority_role()
returns trigger
language plpgsql
set search_path =
  haulvia,
  pg_temp
as $$
begin
  if new.role_key = any (
    array[
      'COMPLETION_WORKER',
      'CUSTODY_TRANSFER_WORKER',
      'DISPUTE_RESOLUTION_WORKER',
      'ELIGIBILITY_WORKER',
      'EXPIRY_WORKER',
      'MATCHING_WORKER',
      'OBSERVABILITY_WORKER',
      'OFFER_WORKER',
      'PAYMENT_WORKER',
      'PAYMENT_PROVIDER_CALLBACK',
      'PAYOUT_PROVIDER_CALLBACK',
      'PAYOUT_WORKER',
      'RECOVERY_WORKER',
      'RETURN_VERIFICATION_WORKER',
      'ROUTE_OPERATIONS_WORKER',
      'STORAGE_WORKER',
      'TERMINAL_REPOST_WORKER'
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


-- ============================================================================
-- 2. Observability threshold definitions
--
-- Definitions only.
-- No production-effective platform_config_versions are inserted here.
-- ============================================================================

do $$
begin
  if exists (
    select 1
    from haulvia.platform_config_definitions d
    join (
      values
        (
          'OBS_COMMAND_STARTED_STALE_SECONDS',
          'OBSERVABILITY',
          'INTEGER',
          'SECONDS'
        ),
        (
          'OBS_WORKFLOW_QUEUED_LATE_SECONDS',
          'OBSERVABILITY',
          'INTEGER',
          'SECONDS'
        ),
        (
          'OBS_WORKFLOW_RUNNING_STALE_SECONDS',
          'OBSERVABILITY',
          'INTEGER',
          'SECONDS'
        ),
        (
          'OBS_PAYOUT_READY_STALE_SECONDS',
          'OBSERVABILITY',
          'INTEGER',
          'SECONDS'
        ),
        (
          'OBS_PAYOUT_PROCESSING_STALE_SECONDS',
          'OBSERVABILITY',
          'INTEGER',
          'SECONDS'
        ),
        (
          'OBS_DISPUTE_OPEN_STALE_SECONDS',
          'OBSERVABILITY',
          'INTEGER',
          'SECONDS'
        ),
        (
          'OBS_COMPLIANCE_EXPIRY_WARNING_DAYS',
          'OBSERVABILITY',
          'INTEGER',
          'DAYS'
        )
    ) as expected(
      config_key,
      category_key,
      value_type,
      unit_key
    )
      on expected.config_key = d.config_key
    where
      d.category_key <> expected.category_key
      or d.value_type::text <> expected.value_type
      or d.unit_key is distinct from expected.unit_key
  ) then
    raise exception
      'P2F observability configuration definition conflicts with existing metadata'
      using errcode = 'P0001';
  end if;
end;
$$;


insert into haulvia.platform_config_definitions (
  config_key,
  category_key,
  value_type,
  unit_key,
  name,
  description,
  is_sensitive
)
values
  (
    'OBS_COMMAND_STARTED_STALE_SECONDS',
    'OBSERVABILITY',
    'INTEGER',
    'SECONDS',
    'Command started stale threshold',
    'Age in seconds after which an unresolved STARTED command-idempotency record is classified as stale.',
    false
  ),
  (
    'OBS_WORKFLOW_QUEUED_LATE_SECONDS',
    'OBSERVABILITY',
    'INTEGER',
    'SECONDS',
    'Workflow queued lateness threshold',
    'Seconds beyond run_after after which a still-QUEUED workflow job is classified as late.',
    false
  ),
  (
    'OBS_WORKFLOW_RUNNING_STALE_SECONDS',
    'OBSERVABILITY',
    'INTEGER',
    'SECONDS',
    'Workflow running stale threshold',
    'Age in seconds since updated_at after which a RUNNING workflow job is classified as stale.',
    false
  ),
  (
    'OBS_PAYOUT_READY_STALE_SECONDS',
    'OBSERVABILITY',
    'INTEGER',
    'SECONDS',
    'Payout ready stale threshold',
    'Age in seconds after which a payout remaining READY is classified for operational attention.',
    false
  ),
  (
    'OBS_PAYOUT_PROCESSING_STALE_SECONDS',
    'OBSERVABILITY',
    'INTEGER',
    'SECONDS',
    'Payout processing stale threshold',
    'Age in seconds after which a payout remaining PROCESSING is classified for operational attention.',
    false
  ),
  (
    'OBS_DISPUTE_OPEN_STALE_SECONDS',
    'OBSERVABILITY',
    'INTEGER',
    'SECONDS',
    'Open dispute stale threshold',
    'Age in seconds after which a nonterminal dispute is classified as stale for operational attention.',
    false
  ),
  (
    'OBS_COMPLIANCE_EXPIRY_WARNING_DAYS',
    'OBSERVABILITY',
    'INTEGER',
    'DAYS',
    'Compliance expiry warning window',
    'Number of days before an applicable compliance expiry date enters the operational warning window.',
    false
  )
on conflict (config_key)
do update set
  name = excluded.name,
  description = excluded.description,
  is_sensitive = excluded.is_sensitive;


-- ============================================================================
-- 2. Durable sanitized failed-command observation evidence
--
-- This table is observability evidence only.
--
-- It is deliberately not a command state machine and does not determine
-- whether the original command committed.
--
-- Referenced actor/organization/shipment identifiers are retained as UUID
-- evidence without foreign keys. A rejected command may legitimately refer
-- to an identifier that does not exist, and observability must still be able
-- to retain that rejection safely.
-- ============================================================================

create table haulvia.command_failure_observations (
  id uuid primary key
    default gen_random_uuid(),

  observation_key text not null unique,

  observed_at timestamptz not null
    default clock_timestamp(),

  source_code text not null,

  command_name text not null,

  actor_profile_id uuid,

  organization_id uuid,

  shipment_id uuid,

  correlation_id text,

  request_sha256 text,

  idempotency_key_sha256 text,

  error_code text not null,

  sqlstate text,

  retryable boolean not null,

  check (
    length(btrim(observation_key))
      between 8 and 200
  ),

  check (
    source_code ~
      '^[A-Z][A-Z0-9_]*$'
  ),

  check (
    length(btrim(command_name))
      between 1 and 200
  ),

  check (
    correlation_id is null
    or length(btrim(correlation_id))
         between 1 and 200
  ),

  check (
    request_sha256 is null
    or request_sha256 ~
      '^[0-9a-f]{64}$'
  ),

  check (
    idempotency_key_sha256 is null
    or idempotency_key_sha256 ~
      '^[0-9a-f]{64}$'
  ),

  check (
    error_code ~
      '^[A-Z0-9_][A-Z0-9_.:-]*$'
  ),

  check (
    sqlstate is null
    or sqlstate ~
      '^[0-9A-Z]{5}$'
  )
);


create index command_failure_observations_command_time_idx
  on haulvia.command_failure_observations (
    command_name,
    observed_at desc
  );


create index command_failure_observations_error_time_idx
  on haulvia.command_failure_observations (
    error_code,
    observed_at desc
  );


comment on table haulvia.command_failure_observations is
  'Append-only sanitized evidence that a trusted backend received a database-command rejection after the failed command transaction ended; never command lifecycle truth.';


-- ============================================================================
-- 3. Append-only protection
-- ============================================================================

create trigger command_failure_observations_append_only
before update or delete
on haulvia.command_failure_observations
for each row
execute function haulvia.reject_append_only_mutation();


-- ============================================================================
-- 4. RLS and raw-table privilege closure
-- ============================================================================

alter table haulvia.command_failure_observations
  enable row level security;


revoke all
on table haulvia.command_failure_observations
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on table haulvia.command_failure_observations from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on table haulvia.command_failure_observations from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on table haulvia.command_failure_observations from service_role';
  end if;
end;
$$;


-- ============================================================================
-- 5. Trusted failure-observation writer
--
-- This wrapper intentionally does NOT use command_idempotency.
-- observationKey is its dedicated replay identity.
-- ============================================================================

create or replace function
haulvia_command.command_record_command_failure_observation(
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path =
  haulvia,
  haulvia_command,
  pg_temp
as $$
declare
  v_calling_actor uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'actorProfileId'
    );

  v_worker_authority text :=
    upper(
      haulvia_command.required_text(
        p_request,
        'workerAuthority'
      )
    );

  v_observation_key text :=
    btrim(
      haulvia_command.required_text(
        p_request,
        'observationKey'
      )
    );

  v_source_code text :=
    upper(
      btrim(
        haulvia_command.required_text(
          p_request,
          'sourceCode'
        )
      )
    );

  v_command_name text :=
    btrim(
      haulvia_command.required_text(
        p_request,
        'failedCommandName'
      )
    );

  v_failed_actor_profile_id uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'failedActorProfileId'
    );

  v_failed_organization_id uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'failedOrganizationId'
    );

  v_failed_shipment_id uuid :=
    haulvia_command.optional_uuid(
      p_request,
      'failedShipmentId'
    );

  v_correlation_id text :=
    nullif(
      btrim(
        p_request ->> 'correlationId'
      ),
      ''
    );

  v_request_sha256 text :=
    nullif(
      lower(
        btrim(
          p_request ->> 'requestSha256'
        )
      ),
      ''
    );

  v_idempotency_key_sha256 text :=
    nullif(
      lower(
        btrim(
          p_request ->> 'idempotencyKeySha256'
        )
      ),
      ''
    );

  v_error_code text :=
    upper(
      btrim(
        haulvia_command.required_text(
          p_request,
          'errorCode'
        )
      )
    );

  v_sqlstate text :=
    nullif(
      upper(
        btrim(
          p_request ->> 'sqlstate'
        )
      ),
      ''
    );

  v_retryable boolean :=
    haulvia_command.required_boolean(
      p_request,
      'retryable'
    );

  v_row
    haulvia.command_failure_observations%rowtype;

  v_inserted boolean := false;

begin
  perform haulvia_command.assert_worker(
    v_calling_actor,
    v_worker_authority,
    array[
      'OBSERVABILITY_WORKER'
    ]
  );


  if length(v_observation_key)
       not between 8 and 200 then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'observationKey must contain between 8 and 200 characters'
    );
  end if;


  if v_source_code !~
       '^[A-Z][A-Z0-9_]*$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'sourceCode must be a stable uppercase observability code'
    );
  end if;


  if length(v_command_name)
       not between 1 and 200 then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'failedCommandName is invalid'
    );
  end if;


  if v_correlation_id is not null
     and length(v_correlation_id)
           not between 1 and 200 then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'correlationId is invalid'
    );
  end if;


  if v_request_sha256 is not null
     and v_request_sha256 !~
       '^[0-9a-f]{64}$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'requestSha256 must be lowercase SHA-256 hex'
    );
  end if;


  if v_idempotency_key_sha256 is not null
     and v_idempotency_key_sha256 !~
       '^[0-9a-f]{64}$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'idempotencyKeySha256 must be lowercase SHA-256 hex'
    );
  end if;


  if v_error_code !~
       '^[A-Z0-9_][A-Z0-9_.:-]*$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'errorCode must be a sanitized stable code'
    );
  end if;


  if v_sqlstate is not null
     and v_sqlstate !~
       '^[0-9A-Z]{5}$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'sqlstate must contain exactly five uppercase alphanumeric characters'
    );
  end if;


  insert into
    haulvia.command_failure_observations (
      observation_key,
      source_code,
      command_name,
      actor_profile_id,
      organization_id,
      shipment_id,
      correlation_id,
      request_sha256,
      idempotency_key_sha256,
      error_code,
      sqlstate,
      retryable
    )
  values (
    v_observation_key,
    v_source_code,
    v_command_name,
    v_failed_actor_profile_id,
    v_failed_organization_id,
    v_failed_shipment_id,
    v_correlation_id,
    v_request_sha256,
    v_idempotency_key_sha256,
    v_error_code,
    v_sqlstate,
    v_retryable
  )
  on conflict (observation_key)
  do nothing
  returning *
  into v_row;


  v_inserted := found;


  if not v_inserted then

    select *
    into v_row
    from haulvia.command_failure_observations cfo
    where cfo.observation_key =
      v_observation_key;


    if not found then
      perform haulvia_command.fail(
        'OBSERVATION_WRITE_CONFLICT',
        'Failure observation could not be resolved after replay conflict'
      );
    end if;


    if
      v_row.source_code
        is distinct from v_source_code
      or v_row.command_name
        is distinct from v_command_name
      or v_row.actor_profile_id
        is distinct from v_failed_actor_profile_id
      or v_row.organization_id
        is distinct from v_failed_organization_id
      or v_row.shipment_id
        is distinct from v_failed_shipment_id
      or v_row.correlation_id
        is distinct from v_correlation_id
      or v_row.request_sha256
        is distinct from v_request_sha256
      or v_row.idempotency_key_sha256
        is distinct from v_idempotency_key_sha256
      or v_row.error_code
        is distinct from v_error_code
      or v_row.sqlstate
        is distinct from v_sqlstate
      or v_row.retryable
        is distinct from v_retryable
    then
      perform haulvia_command.fail(
        'OBSERVATION_KEY_REUSED',
        'observationKey was reused with different sanitized failure facts'
      );
    end if;

  end if;


  return jsonb_build_object(
    'commandFailureObservationId',
      v_row.id,
    'observationKey',
      v_row.observation_key,
    'observedAt',
      v_row.observed_at,
    'replayed',
      not v_inserted
  );
end;
$$;


revoke all
on function
  haulvia_command.command_record_command_failure_observation(jsonb)
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke execute on function haulvia_command.command_record_command_failure_observation(jsonb) from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke execute on function haulvia_command.command_record_command_failure_observation(jsonb) from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    grant usage
      on schema haulvia_command
      to service_role;

    grant execute
      on function
        haulvia_command.command_record_command_failure_observation(jsonb)
      to service_role;
  end if;
end;
$$;


-- ============================================================================
-- P2F-BLOCK-1-END
-- ============================================================================

-- ============================================================================
-- P2F-BLOCK-2-BEGIN
--
-- Fail-closed observability threshold resolution,
-- administrator-safe audit projection,
-- and failed-command attention queue.
-- ============================================================================


-- ============================================================================
-- 7. Resolve one effective positive observability integer
--
-- Zero effective APPROVED versions:
--   return NULL so threshold-dependent classification is disabled.
--
-- More than one:
--   fail closed as configuration corruption/overlap.
--
-- Invalid, non-integer, zero, or negative:
--   fail closed.
-- ============================================================================

create or replace function
haulvia.resolve_observability_positive_integer(
  p_config_key text
)
returns integer
language plpgsql
set search_path =
  haulvia,
  pg_temp
as $$
declare
  v_definition
    haulvia.platform_config_definitions%rowtype;

  v_match_count integer;

  v_value jsonb;

  v_numeric numeric;

begin
  select *
  into v_definition
  from haulvia.platform_config_definitions d
  where d.config_key =
    upper(
      btrim(
        p_config_key
      )
    );


  if not found then
    raise exception
      'Unknown observability configuration definition: %',
      p_config_key
      using errcode = 'P0001';
  end if;


  if
    v_definition.category_key <> 'OBSERVABILITY'
    or v_definition.value_type::text <> 'INTEGER'
  then
    raise exception
      'Configuration % is not an OBSERVABILITY INTEGER definition',
      v_definition.config_key
      using errcode = 'P0001';
  end if;


  select
    count(*)
  into
    v_match_count
  from haulvia.platform_config_versions v
  where v.config_definition_id =
      v_definition.id
    and v.publication_status =
      'APPROVED'
    and v.config_value is not null
    and v.effective_from is not null
    and v.effective_from <=
      statement_timestamp()
    and (
      v.effective_to is null
      or v.effective_to >
        statement_timestamp()
    );


  if v_match_count = 0 then
    return null;
  end if;


  if v_match_count > 1 then
    raise exception
      'Multiple effective APPROVED versions exist for observability configuration %',
      v_definition.config_key
      using errcode = 'P0001';
  end if;


  select
    v.config_value
  into
    v_value
  from haulvia.platform_config_versions v
  where v.config_definition_id =
      v_definition.id
    and v.publication_status =
      'APPROVED'
    and v.config_value is not null
    and v.effective_from is not null
    and v.effective_from <=
      statement_timestamp()
    and (
      v.effective_to is null
      or v.effective_to >
        statement_timestamp()
    );


  if jsonb_typeof(v_value) <> 'number' then
    raise exception
      'Effective observability configuration % is not a JSON number',
      v_definition.config_key
      using errcode = 'P0001';
  end if;


  begin
    v_numeric :=
      (
        v_value #>> '{}'
      )::numeric;

  exception
    when others then
      raise exception
        'Effective observability configuration % cannot be parsed as an integer',
        v_definition.config_key
        using errcode = 'P0001';
  end;


  if
    v_numeric <> trunc(v_numeric)
    or v_numeric <= 0
    or v_numeric > 2147483647
  then
    raise exception
      'Effective observability configuration % must be a positive 32-bit integer',
      v_definition.config_key
      using errcode = 'P0001';
  end if;


  return
    v_numeric::integer;
end;
$$;


comment on function
haulvia.resolve_observability_positive_integer(text) is
  'Resolves exactly one currently effective APPROVED positive INTEGER observability configuration; returns NULL when none exists and fails closed on overlap or invalid values.';


revoke all
on function
  haulvia.resolve_observability_positive_integer(text)
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke execute on function haulvia.resolve_observability_positive_integer(text) from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke execute on function haulvia.resolve_observability_positive_integer(text) from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke execute on function haulvia.resolve_observability_positive_integer(text) from service_role';
  end if;
end;
$$;


-- ============================================================================
-- 8. Administrator-safe audit projection
--
-- Raw reason, metadata, before/after values and raw idempotency key are
-- intentionally excluded.
-- ============================================================================

create or replace view
haulvia.v_admin_audit_projection
with (
  security_invoker = true
)
as
select
  a.id as audit_event_id,

  a.occurred_at,

  a.actor_kind,

  a.actor_profile_id,

  a.actor_provider_id,

  a.organization_id,

  a.command_name,

  a.authority_code,

  a.entity_schema,

  a.entity_table,

  a.entity_id,

  a.correlation_id,

  a.idempotency_key is not null
    as has_idempotency_key,

  case
    when a.idempotency_key is null
      then null::text

    else
      pg_catalog.encode(
        pg_catalog.sha256(
          pg_catalog.convert_to(
            a.idempotency_key,
            'UTF8'
          )
        ),
        'hex'
      )
  end
    as idempotency_key_sha256,

  a.reason is not null
    as has_reason,

  a.before_value is not null
    as has_before_value,

  a.after_value is not null
    as has_after_value

from haulvia.audit_events a;


comment on view
haulvia.v_admin_audit_projection is
  'Minimized P2F audit projection. Raw reason, metadata, before/after JSON and raw idempotency keys are intentionally excluded.';


revoke all
on haulvia.v_admin_audit_projection
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on haulvia.v_admin_audit_projection from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on haulvia.v_admin_audit_projection from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on haulvia.v_admin_audit_projection from service_role';
  end if;
end;
$$;


-- ============================================================================
-- 9. Failed-command attention queue
--
-- COMMAND_FAILED may originate from:
--   * sanitized post-rollback failure observation; or
--   * an explicitly persisted FAILED command-idempotency record.
--
-- COMMAND_STALE_STARTED exists only when a positive effective configured
-- threshold resolves successfully.
--
-- A persisted FAILED idempotency row is suppressed when an observation with
-- the same command/actor/idempotency hash already represents that failure.
-- ============================================================================

create or replace view
haulvia.v_failed_command_queue
with (
  security_invoker = true
)
as

with threshold as (
  select
    haulvia.resolve_observability_positive_integer(
      'OBS_COMMAND_STARTED_STALE_SECONDS'
    ) as stale_seconds
),

observed_failures as (
  select
    'FAILURE_OBSERVATION'::text
      as failure_source,

    'COMMAND_FAILED'::text
      as attention_code,

    cfo.id
      as failure_observation_id,

    null::uuid
      as command_idempotency_id,

    cfo.actor_profile_id,

    cfo.command_name,

    cfo.correlation_id,

    cfo.request_sha256,

    cfo.idempotency_key_sha256,

    null::text
      as canonical_idempotency_status,

    cfo.error_code,

    cfo.retryable,

    null::timestamptz
      as started_at,

    null::timestamptz
      as completed_at,

    cfo.observed_at,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - cfo.observed_at
          )
        )
      )::bigint
    )
      as age_seconds

  from haulvia.command_failure_observations cfo
),

persisted_failures as (
  select
    'PERSISTED_IDEMPOTENCY_FAILURE'::text
      as failure_source,

    'COMMAND_FAILED'::text
      as attention_code,

    null::uuid
      as failure_observation_id,

    ci.id
      as command_idempotency_id,

    ci.actor_profile_id,

    ci.command_name,

    null::text
      as correlation_id,

    lower(
      ci.request_hash
    )
      as request_sha256,

    pg_catalog.encode(
      pg_catalog.sha256(
        pg_catalog.convert_to(
          ci.idempotency_key,
          'UTF8'
        )
      ),
      'hex'
    )
      as idempotency_key_sha256,

    ci.status
      as canonical_idempotency_status,

    null::text
      as error_code,

    null::boolean
      as retryable,

    ci.started_at,

    ci.completed_at,

    null::timestamptz
      as observed_at,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - coalesce(
                ci.completed_at,
                ci.started_at
              )
          )
        )
      )::bigint
    )
      as age_seconds

  from haulvia.command_idempotency ci

  where ci.status = 'FAILED'

    and not exists (
      select 1
      from haulvia.command_failure_observations cfo
      where cfo.command_name =
          ci.command_name

        and cfo.actor_profile_id
          is not distinct from
          ci.actor_profile_id

        and cfo.idempotency_key_sha256 =
          pg_catalog.encode(
            pg_catalog.sha256(
              pg_catalog.convert_to(
                ci.idempotency_key,
                'UTF8'
              )
            ),
            'hex'
          )
    )
),

stale_started as (
  select
    'STALE_STARTED'::text
      as failure_source,

    'COMMAND_STALE_STARTED'::text
      as attention_code,

    null::uuid
      as failure_observation_id,

    ci.id
      as command_idempotency_id,

    ci.actor_profile_id,

    ci.command_name,

    null::text
      as correlation_id,

    lower(
      ci.request_hash
    )
      as request_sha256,

    pg_catalog.encode(
      pg_catalog.sha256(
        pg_catalog.convert_to(
          ci.idempotency_key,
          'UTF8'
        )
      ),
      'hex'
    )
      as idempotency_key_sha256,

    ci.status
      as canonical_idempotency_status,

    null::text
      as error_code,

    null::boolean
      as retryable,

    ci.started_at,

    ci.completed_at,

    null::timestamptz
      as observed_at,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - ci.started_at
          )
        )
      )::bigint
    )
      as age_seconds

  from haulvia.command_idempotency ci

  cross join threshold t

  where ci.status = 'STARTED'

    and t.stale_seconds is not null

    and ci.started_at <=
      statement_timestamp()
      - pg_catalog.make_interval(
          secs => t.stale_seconds
        )
)

select *
from observed_failures

union all

select *
from persisted_failures

union all

select *
from stale_started;


comment on view
haulvia.v_failed_command_queue is
  'P2F minimized failed/stale command attention queue derived from sanitized failure observations and canonical command idempotency state.';


revoke all
on haulvia.v_failed_command_queue
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on haulvia.v_failed_command_queue from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on haulvia.v_failed_command_queue from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on haulvia.v_failed_command_queue from service_role';
  end if;
end;
$$;


-- ============================================================================
-- P2F-BLOCK-2-END
-- ============================================================================

-- ============================================================================
-- P2F-BLOCK-3-BEGIN
--
-- Minimized stuck-workflow operational attention projection.
-- ============================================================================


-- ============================================================================
-- 10. Stuck-workflow attention queue
--
-- Authoritative source:
--   haulvia.workflow_jobs
--
-- Classifications:
--   WORKFLOW_JOB_FAILED
--   WORKFLOW_JOB_LATE
--   WORKFLOW_JOB_STALE_RUNNING
--
-- Raw payload, last_error text and idempotency key are intentionally excluded.
-- ============================================================================

create or replace view
haulvia.v_stuck_workflow_queue
with (
  security_invoker = true
)
as

with thresholds as (
  select
    haulvia.resolve_observability_positive_integer(
      'OBS_WORKFLOW_QUEUED_LATE_SECONDS'
    ) as queued_late_seconds,

    haulvia.resolve_observability_positive_integer(
      'OBS_WORKFLOW_RUNNING_STALE_SECONDS'
    ) as running_stale_seconds
),

failed_jobs as (
  select
    wj.id
      as workflow_job_id,

    wj.shipment_id,

    wj.job_code,

    wj.status
      as canonical_status,

    wj.run_after,

    wj.attempt_count,

    wj.created_at,

    wj.updated_at,

    wj.last_error is not null
      as has_last_error,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - wj.updated_at
          )
        )
      )::bigint
    )
      as age_seconds,

    null::integer
      as threshold_seconds,

    'WORKFLOW_JOB_FAILED'::text
      as attention_code

  from haulvia.workflow_jobs wj

  where wj.status = 'FAILED'
),

late_queued_jobs as (
  select
    wj.id
      as workflow_job_id,

    wj.shipment_id,

    wj.job_code,

    wj.status
      as canonical_status,

    wj.run_after,

    wj.attempt_count,

    wj.created_at,

    wj.updated_at,

    wj.last_error is not null
      as has_last_error,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - wj.run_after
          )
        )
      )::bigint
    )
      as age_seconds,

    t.queued_late_seconds
      as threshold_seconds,

    'WORKFLOW_JOB_LATE'::text
      as attention_code

  from haulvia.workflow_jobs wj

  cross join thresholds t

  where wj.status = 'QUEUED'

    and t.queued_late_seconds is not null

    and wj.run_after <=
      statement_timestamp()
      - pg_catalog.make_interval(
          secs => t.queued_late_seconds
        )
),

stale_running_jobs as (
  select
    wj.id
      as workflow_job_id,

    wj.shipment_id,

    wj.job_code,

    wj.status
      as canonical_status,

    wj.run_after,

    wj.attempt_count,

    wj.created_at,

    wj.updated_at,

    wj.last_error is not null
      as has_last_error,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - wj.updated_at
          )
        )
      )::bigint
    )
      as age_seconds,

    t.running_stale_seconds
      as threshold_seconds,

    'WORKFLOW_JOB_STALE_RUNNING'::text
      as attention_code

  from haulvia.workflow_jobs wj

  cross join thresholds t

  where wj.status = 'RUNNING'

    and t.running_stale_seconds is not null

    and wj.updated_at <=
      statement_timestamp()
      - pg_catalog.make_interval(
          secs => t.running_stale_seconds
        )
)

select *
from failed_jobs

union all

select *
from late_queued_jobs

union all

select *
from stale_running_jobs;


comment on view
haulvia.v_stuck_workflow_queue is
  'P2F minimized workflow-job attention queue. Raw payload, error text and idempotency keys are intentionally excluded.';


revoke all
on haulvia.v_stuck_workflow_queue
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on haulvia.v_stuck_workflow_queue from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on haulvia.v_stuck_workflow_queue from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on haulvia.v_stuck_workflow_queue from service_role';
  end if;
end;
$$;


-- ============================================================================
-- P2F-BLOCK-3-END
-- ============================================================================

-- ============================================================================
-- P2F-BLOCK-4-BEGIN
--
-- Minimized payout operational attention projection.
-- ============================================================================


-- ============================================================================
-- 11. Payout attention queue
--
-- Canonical payout truth remains haulvia.driver_payouts.
--
-- Supporting operational context is read from:
--   haulvia.payout_eligibility_records
--   haulvia.payout_transactions
--   haulvia.provider_adapter_requests
--   haulvia.provider_adapter_attempts
--
-- Classifications:
--   PAYOUT_FAILED
--   PAYOUT_HELD
--   PAYOUT_STALE_READY
--   PAYOUT_STALE_PROCESSING
--
-- Provider payloads, payout snapshots, raw idempotency values and unrestricted
-- provider metadata are intentionally excluded.
-- ============================================================================

create or replace view
haulvia.v_payout_attention_queue
with (
  security_invoker = true
)
as

with thresholds as (
  select
    haulvia.resolve_observability_positive_integer(
      'OBS_PAYOUT_READY_STALE_SECONDS'
    ) as ready_stale_seconds,

    haulvia.resolve_observability_positive_integer(
      'OBS_PAYOUT_PROCESSING_STALE_SECONDS'
    ) as processing_stale_seconds
),

payout_base as (
  select
    dp.id
      as payout_id,

    dp.shipment_id,

    dp.assignment_id,

    dp.provider_id,

    dp.driver_id,

    dp.state
      as canonical_payout_state,

    dp.state_changed_at,

    dp.gross_amount,

    dp.net_amount,

    dp.currency,

    per.releasable_amount,

    latest_tx.status
      as latest_transaction_status,

    latest_tx.occurred_at
      as latest_transaction_occurred_at,

    latest_adapter.status
      as latest_provider_request_status,

    latest_attempt.attempt_no
      as latest_provider_attempt_no,

    latest_attempt.submission_succeeded
      as latest_provider_submission_succeeded,

    latest_attempt.error_category
      as latest_provider_error_category,

    latest_attempt.retryable
      as latest_provider_retryable,

    latest_attempt.completed_at
      as latest_provider_attempt_completed_at,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - dp.state_changed_at
          )
        )
      )::bigint
    )
      as age_seconds,

    t.ready_stale_seconds,

    t.processing_stale_seconds

  from haulvia.driver_payouts dp

  cross join thresholds t

  left join haulvia.payout_eligibility_records per
    on per.id =
      dp.payout_eligibility_record_id

  left join lateral (
    select
      pt.status,
      pt.occurred_at

    from haulvia.payout_transactions pt

    where pt.payout_id =
      dp.id

    order by
      pt.occurred_at desc,
      pt.id desc

    limit 1
  ) latest_tx
    on true

  left join lateral (
    select
      par.id,
      par.status,
      par.updated_at

    from haulvia.provider_adapter_requests par

    where par.operation =
        'DRIVER_PAYOUT'

      and par.payout_id =
        dp.id

    order by
      par.updated_at desc,
      par.id desc

    limit 1
  ) latest_adapter
    on true

  left join lateral (
    select
      paa.attempt_no,
      paa.submission_succeeded,
      paa.error_category,
      paa.retryable,
      paa.completed_at

    from haulvia.provider_adapter_attempts paa

    where paa.adapter_request_id =
      latest_adapter.id

    order by
      paa.attempt_no desc

    limit 1
  ) latest_attempt
    on true
),

classified as (
  select
    pb.payout_id,

    pb.shipment_id,

    pb.assignment_id,

    pb.provider_id,

    pb.driver_id,

    pb.canonical_payout_state,

    pb.state_changed_at,

    pb.gross_amount,

    pb.net_amount,

    pb.releasable_amount,

    pb.currency,

    pb.latest_transaction_status,

    pb.latest_transaction_occurred_at,

    pb.latest_provider_request_status,

    pb.latest_provider_attempt_no,

    pb.latest_provider_submission_succeeded,

    pb.latest_provider_error_category,

    pb.latest_provider_retryable,

    pb.latest_provider_attempt_completed_at,

    pb.age_seconds,

    case
      when pb.canonical_payout_state =
        'READY'
      then pb.ready_stale_seconds

      when pb.canonical_payout_state =
        'PROCESSING'
      then pb.processing_stale_seconds

      else null::integer
    end
      as threshold_seconds,

    case
      when pb.canonical_payout_state =
        'FAILED'
      then
        'PAYOUT_FAILED'::text

      when pb.canonical_payout_state =
        'HELD'
      then
        'PAYOUT_HELD'::text

      when
        pb.canonical_payout_state =
          'READY'

        and pb.ready_stale_seconds
          is not null

        and pb.state_changed_at <=
          statement_timestamp()
          - pg_catalog.make_interval(
              secs =>
                pb.ready_stale_seconds
            )
      then
        'PAYOUT_STALE_READY'::text

      when
        pb.canonical_payout_state =
          'PROCESSING'

        and pb.processing_stale_seconds
          is not null

        and pb.state_changed_at <=
          statement_timestamp()
          - pg_catalog.make_interval(
              secs =>
                pb.processing_stale_seconds
            )
      then
        'PAYOUT_STALE_PROCESSING'::text

      else null::text
    end
      as attention_code

  from payout_base pb
)

select
  c.payout_id,

  c.shipment_id,

  c.assignment_id,

  c.provider_id,

  c.driver_id,

  c.canonical_payout_state,

  c.state_changed_at,

  c.gross_amount,

  c.net_amount,

  c.releasable_amount,

  c.currency,

  c.latest_transaction_status,

  c.latest_transaction_occurred_at,

  c.latest_provider_request_status,

  c.latest_provider_attempt_no,

  c.latest_provider_submission_succeeded,

  c.latest_provider_error_category,

  c.latest_provider_retryable,

  c.latest_provider_attempt_completed_at,

  c.age_seconds,

  c.threshold_seconds,

  c.attention_code

from classified c

where c.attention_code
  is not null;


comment on view
haulvia.v_payout_attention_queue is
  'P2F minimized payout attention queue derived from canonical payout state with safe transaction and provider-adapter context.';


revoke all
on haulvia.v_payout_attention_queue
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on haulvia.v_payout_attention_queue from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on haulvia.v_payout_attention_queue from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on haulvia.v_payout_attention_queue from service_role';
  end if;
end;
$$;


-- ============================================================================
-- P2F-BLOCK-4-END
-- ============================================================================

-- ============================================================================
-- P2F-BLOCK-5-BEGIN
--
-- Minimized dispute operational attention projection.
-- ============================================================================


-- ============================================================================
-- 12. Dispute attention queue
--
-- Canonical dispute truth remains haulvia.disputes.
--
-- Supporting operational truth:
--   haulvia.dispute_operational_controls
--   haulvia.workflow_holds
--   haulvia.financial_holds
--
-- Resolution records remain authoritative retained evidence but their JSON,
-- evidence decisions, financial allocation and unrestricted summary are not
-- exposed through this ordinary operational queue.
--
-- Classifications:
--   DISPUTE_OPEN
--   DISPUTE_BLOCKING_MOVEMENT
--   DISPUTE_STALE_OPEN
--
-- Attention codes are orthogonal. A single dispute may therefore produce
-- multiple queue rows when multiple conditions are simultaneously true.
-- ============================================================================

create or replace view
haulvia.v_dispute_attention_queue
with (
  security_invoker = true
)
as

with threshold as (
  select
    haulvia.resolve_observability_positive_integer(
      'OBS_DISPUTE_OPEN_STALE_SECONDS'
    ) as stale_open_seconds
),

open_disputes as (
  select
    d.id
      as dispute_id,

    d.shipment_id,

    d.stop_execution_id,

    d.cargo_item_id,

    d.category_code,

    d.status
      as canonical_dispute_status,

    d.opened_at,

    d.resolved_at,

    d.disputed_amount,

    d.currency,

    case
      when
        coalesce(
          doc.blocks_route_movement,
          false
        )

        and wh.id is not null

        and wh.status =
          'ACTIVE'

        and wh.blocks_route_movement
      then true

      else false
    end
      as route_movement_blocked,

    case
      when fh.id is not null
        and fh.status = 'ACTIVE'
      then true

      else false
    end
      as financial_hold_active,

    greatest(
      0::bigint,
      floor(
        extract(
          epoch from (
            statement_timestamp()
            - d.opened_at
          )
        )
      )::bigint
    )
      as age_seconds,

    t.stale_open_seconds

  from haulvia.disputes d

  cross join threshold t

  left join haulvia.dispute_operational_controls doc
    on doc.dispute_id =
      d.id

  left join haulvia.workflow_holds wh
    on wh.id =
      doc.workflow_hold_id

  left join haulvia.financial_holds fh
    on fh.id =
      d.financial_hold_id

  where d.status not in (
    'RESOLVED',
    'CLOSED'
  )
),

open_attention as (
  select
    od.dispute_id,

    od.shipment_id,

    od.stop_execution_id,

    od.cargo_item_id,

    od.category_code,

    od.canonical_dispute_status,

    od.opened_at,

    od.resolved_at,

    od.disputed_amount,

    od.currency,

    od.route_movement_blocked,

    od.financial_hold_active,

    od.age_seconds,

    null::integer
      as threshold_seconds,

    'DISPUTE_OPEN'::text
      as attention_code

  from open_disputes od
),

movement_attention as (
  select
    od.dispute_id,

    od.shipment_id,

    od.stop_execution_id,

    od.cargo_item_id,

    od.category_code,

    od.canonical_dispute_status,

    od.opened_at,

    od.resolved_at,

    od.disputed_amount,

    od.currency,

    od.route_movement_blocked,

    od.financial_hold_active,

    od.age_seconds,

    null::integer
      as threshold_seconds,

    'DISPUTE_BLOCKING_MOVEMENT'::text
      as attention_code

  from open_disputes od

  where od.route_movement_blocked
),

stale_attention as (
  select
    od.dispute_id,

    od.shipment_id,

    od.stop_execution_id,

    od.cargo_item_id,

    od.category_code,

    od.canonical_dispute_status,

    od.opened_at,

    od.resolved_at,

    od.disputed_amount,

    od.currency,

    od.route_movement_blocked,

    od.financial_hold_active,

    od.age_seconds,

    od.stale_open_seconds
      as threshold_seconds,

    'DISPUTE_STALE_OPEN'::text
      as attention_code

  from open_disputes od

  where od.stale_open_seconds
    is not null

    and od.opened_at <=
      statement_timestamp()
      - pg_catalog.make_interval(
          secs =>
            od.stale_open_seconds
        )
)

select *
from open_attention

union all

select *
from movement_attention

union all

select *
from stale_attention;


comment on view
haulvia.v_dispute_attention_queue is
  'P2F minimized dispute attention queue derived from canonical dispute, operational-control, workflow-hold and financial-hold facts.';


revoke all
on haulvia.v_dispute_attention_queue
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on haulvia.v_dispute_attention_queue from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on haulvia.v_dispute_attention_queue from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on haulvia.v_dispute_attention_queue from service_role';
  end if;
end;
$$;


-- ============================================================================
-- P2F-BLOCK-5-END
-- ============================================================================

-- ============================================================================
-- P2F-BLOCK-6-BEGIN
--
-- Minimized compliance operational attention projection.
-- ============================================================================


-- ============================================================================
-- 13. Compliance attention queue
--
-- Canonical compliance truth remains:
--   haulvia.compliance_subjects
--   haulvia.compliance_items
--
-- The canonical blocker predicate remains:
--   haulvia.v_compliance_blockers
--
-- P2F MUST NOT redefine blocker semantics independently.
--
-- Classifications:
--   COMPLIANCE_BLOCKER
--   COMPLIANCE_EXPIRING
--
-- COMPLIANCE_EXPIRING applies only to an ACTIVE, APPLICABLE, required item
-- whose expiry date is today or in the future and falls inside the configured
-- OBS_COMPLIANCE_EXPIRY_WARNING_DAYS window.
--
-- Blocker and expiry attention are orthogonal operational facts; one item may
-- therefore appear under both codes.
--
-- Credential numbers, holder/issuer details, notes, document locations,
-- document payloads, review notes and sensitive evidence are excluded.
-- ============================================================================

create or replace view
haulvia.v_compliance_attention_queue
with (
  security_invoker = true
)
as

with threshold as (
  select
    haulvia.resolve_observability_positive_integer(
      'OBS_COMPLIANCE_EXPIRY_WARNING_DAYS'
    ) as expiry_warning_days
),

blocker_attention as (
  select
    cs.id
      as compliance_subject_id,

    cs.subject_kind,

    cb.compliance_item_id,

    cb.compliance_code,

    cb.compliance_name,

    cb.review_status,

    cb.expiry_date,

    case
      when cb.expiry_date is null
      then null::integer

      else
        cb.expiry_date
        - current_date
    end
      as days_until_expiry,

    null::integer
      as threshold_days,

    'COMPLIANCE_BLOCKER'::text
      as attention_code

  from haulvia.v_compliance_blockers cb

  join haulvia.compliance_subjects cs
    on cs.id =
      cb.subject_id
),

expiring_attention as (
  select
    cs.id
      as compliance_subject_id,

    cs.subject_kind,

    ci.id
      as compliance_item_id,

    ci.compliance_code,

    ci.compliance_name,

    ci.review_status,

    ci.expiry_date,

    ci.expiry_date
      - current_date
      as days_until_expiry,

    t.expiry_warning_days
      as threshold_days,

    'COMPLIANCE_EXPIRING'::text
      as attention_code

  from haulvia.compliance_items ci

  join haulvia.compliance_subjects cs
    on cs.id =
      ci.subject_id

  cross join threshold t

  where ci.status =
      'ACTIVE'

    and ci.applicability =
      'APPLICABLE'

    and ci.is_required

    and ci.expiry_date
      is not null

    and t.expiry_warning_days
      is not null

    and ci.expiry_date >=
      current_date

    and ci.expiry_date <=
      current_date
      + t.expiry_warning_days
)

select *
from blocker_attention

union all

select *
from expiring_attention;


comment on view
haulvia.v_compliance_attention_queue is
  'P2F minimized compliance attention queue. Blocker classification reuses v_compliance_blockers; expiry warning is configuration-driven.';


revoke all
on haulvia.v_compliance_attention_queue
from public;


do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute
      'revoke all on haulvia.v_compliance_attention_queue from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute
      'revoke all on haulvia.v_compliance_attention_queue from authenticated';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'service_role'
  ) then
    execute
      'revoke all on haulvia.v_compliance_attention_queue from service_role';
  end if;
end;
$$;


-- ============================================================================
-- P2F-BLOCK-6-END
-- ============================================================================


commit;