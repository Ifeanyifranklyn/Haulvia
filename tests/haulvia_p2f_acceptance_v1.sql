\set ON_ERROR_STOP on

-- ============================================================================
-- Haulvia P2F Permanent Local Acceptance v1
--
-- Frozen contract:
-- B09E4D8E9556854FB491BC908A111A46466BCE46DEB5A8C0E844A737118AB945
--
-- Production P2F migration checkpoint:
-- 7E54F82F26841252BD8EAA93935B6344F029CED564B942CE4E92B60D1FAE5A7E
--
-- This acceptance file is rollback-only.
-- It must never seed production observability thresholds.
-- ============================================================================

begin;

set local search_path =
  haulvia,
  haulvia_command,
  pg_temp;


-- ============================================================================
-- Result recorder
-- ============================================================================

create temporary table
p2f_acceptance_results (
  requirement_id text primary key,
  test_name text not null,
  passed boolean not null,
  detail text not null
)
on commit drop;


create or replace function
pg_temp.record_requirement(
  p_requirement_id text,
  p_test_name text,
  p_condition boolean,
  p_failure_detail text
)
returns void
language plpgsql
as $$
begin
  insert into p2f_acceptance_results (
    requirement_id,
    test_name,
    passed,
    detail
  )
  values (
    p_requirement_id,
    p_test_name,
    coalesce(
      p_condition,
      false
    ),
    case
      when coalesce(
        p_condition,
        false
      )
      then 'passed'
      else p_failure_detail
    end
  );
end;
$$;


-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-A-BEGIN
--
-- Global observability structure, configuration, audit minimization,
-- failure-observation evidence and failed-command queue.
-- ============================================================================


-- ============================================================================
-- A01. Exact command/writer surface
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A01',

  'P2F exposes exactly 92 command wrappers including the dedicated failure-observation writer',

  (
    select count(*)
    from pg_proc p
    join pg_namespace n
      on n.oid =
        p.pronamespace
    where n.nspname =
        'haulvia_command'
      and left(
        p.proname,
        8
      ) =
        'command_'
  ) = 92

  and

  to_regprocedure(
    'haulvia_command.command_record_command_failure_observation(jsonb)'
  ) is not null,

  'Expected 92 haulvia_command.command_* wrappers and the dedicated P2F writer.'
);


-- ============================================================================
-- A02. Six minimized P2F views
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A02',

  'All six required P2F projections exist as views rather than lifecycle tables',

  (
    select count(*)
    from pg_class c
    join pg_namespace n
      on n.oid =
        c.relnamespace
    where n.nspname =
        'haulvia'

      and c.relkind =
        'v'

      and c.relname in (
        'v_admin_audit_projection',
        'v_failed_command_queue',
        'v_stuck_workflow_queue',
        'v_payout_attention_queue',
        'v_dispute_attention_queue',
        'v_compliance_attention_queue'
      )
  ) = 6,

  'Expected exactly six P2F projection views.'
);


-- ============================================================================
-- A03. security_invoker
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A03',

  'All six P2F projections use security_invoker',

  (
    select count(*)
    from pg_class c
    join pg_namespace n
      on n.oid =
        c.relnamespace
    where n.nspname =
        'haulvia'

      and c.relname in (
        'v_admin_audit_projection',
        'v_failed_command_queue',
        'v_stuck_workflow_queue',
        'v_payout_attention_queue',
        'v_dispute_attention_queue',
        'v_compliance_attention_queue'
      )

      and coalesce(
        c.reloptions,
        array[]::text[]
      ) @> array[
        'security_invoker=true'
      ]
  ) = 6,

  'One or more P2F views are missing security_invoker=true.'
);


-- ============================================================================
-- A04. Projection privilege closure
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A04',

  'P2F projections expose no broad direct read privileges',

  not exists (
    select 1
    from information_schema.table_privileges tp
    where tp.table_schema =
        'haulvia'

      and tp.table_name in (
        'v_admin_audit_projection',
        'v_failed_command_queue',
        'v_stuck_workflow_queue',
        'v_payout_attention_queue',
        'v_dispute_attention_queue',
        'v_compliance_attention_queue'
      )

      and tp.grantee in (
        'PUBLIC',
        'anon',
        'authenticated',
        'service_role'
      )
  ),

  'A P2F projection has an unexpected broad direct grant.'
);


-- ============================================================================
-- A05. Failure-observation relation/RLS
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A05',

  'command_failure_observations exists as an RLS-protected observability relation',

  to_regclass(
    'haulvia.command_failure_observations'
  ) is not null

  and

  exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid =
        c.relnamespace
    where n.nspname =
        'haulvia'

      and c.relname =
        'command_failure_observations'

      and c.relkind =
        'r'

      and c.relrowsecurity
  ),

  'Failure-observation relation is missing, not a table, or lacks RLS.'
);


-- ============================================================================
-- A06. Raw failure-observation privilege closure
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A06',

  'Raw command-failure observations have no broad table privileges',

  not exists (
    select 1
    from information_schema.table_privileges tp
    where tp.table_schema =
        'haulvia'

      and tp.table_name =
        'command_failure_observations'

      and tp.grantee in (
        'PUBLIC',
        'anon',
        'authenticated',
        'service_role'
      )
  ),

  'Raw observation-table privilege was granted to a broad/client role.'
);


-- ============================================================================
-- A07. Writer security-definer/search-path boundary
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A07',

  'Failure-observation writer is SECURITY DEFINER with pinned search_path',

  exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid =
        p.pronamespace
    where n.nspname =
        'haulvia_command'

      and p.proname =
        'command_record_command_failure_observation'

      and p.prosecdef

      and array_to_string(
        coalesce(
          p.proconfig,
          array[]::text[]
        ),
        ','
      ) like
        '%search_path=haulvia, haulvia_command, pg_temp%'
  ),

  'Failure-observation writer security/search-path boundary is incorrect.'
);


-- ============================================================================
-- A08. Writer execution privilege closure
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A08',

  'Failure-observation writer execution is service-role only',

  exists (
    select 1
    from information_schema.routine_privileges rp
    where rp.routine_schema =
        'haulvia_command'

      and rp.routine_name =
        'command_record_command_failure_observation'

      and rp.grantee =
        'service_role'

      and rp.privilege_type =
        'EXECUTE'
  )

  and

  not exists (
    select 1
    from information_schema.routine_privileges rp
    where rp.routine_schema =
        'haulvia_command'

      and rp.routine_name =
        'command_record_command_failure_observation'

      and rp.grantee in (
        'PUBLIC',
        'anon',
        'authenticated'
      )

      and rp.privilege_type =
        'EXECUTE'
  ),

  'Writer execute privilege is not closed to the trusted backend role.'
);


-- ============================================================================
-- A09. Backend-only worker authority
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A09',

  'OBSERVABILITY_WORKER remains backend-only and is rejected as a human role family',

  not exists (
    select 1
    from haulvia.roles r
    where r.role_key =
      'OBSERVABILITY_WORKER'
  )

  and

  position(
    'OBSERVABILITY_WORKER'
    in pg_get_functiondef(
      'haulvia.reject_worker_authority_role()'::regprocedure
    )
  ) > 0,

  'OBSERVABILITY_WORKER appeared as a human role or is absent from the worker-role rejection guard.'
);


-- ============================================================================
-- A10. Seven exact config definitions, zero production values
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A10',

  'All seven observability configuration definitions exist with exact metadata and no effective value is seeded',

  (
    select count(*)
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
      on d.config_key =
        expected.config_key

     and d.category_key =
        expected.category_key

     and d.value_type::text =
        expected.value_type

     and d.unit_key =
        expected.unit_key
  ) = 7

  and

  not exists (
    select 1
    from haulvia.platform_config_versions v
    join haulvia.platform_config_definitions d
      on d.id =
        v.config_definition_id
    where d.category_key =
      'OBSERVABILITY'
  ),

  'P2F observability definitions are missing/mismatched or production values were seeded.'
);


-- ============================================================================
-- A11. Missing configuration fails safe
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A11',

  'All seven observability threshold resolvers return NULL when no effective version exists',

  (
    select bool_and(
      haulvia.resolve_observability_positive_integer(
        expected.config_key
      ) is null
    )
    from (
      values
        ('OBS_COMMAND_STARTED_STALE_SECONDS'),
        ('OBS_WORKFLOW_QUEUED_LATE_SECONDS'),
        ('OBS_WORKFLOW_RUNNING_STALE_SECONDS'),
        ('OBS_PAYOUT_READY_STALE_SECONDS'),
        ('OBS_PAYOUT_PROCESSING_STALE_SECONDS'),
        ('OBS_DISPUTE_OPEN_STALE_SECONDS'),
        ('OBS_COMPLIANCE_EXPIRY_WARNING_DAYS')
    ) as expected(
      config_key
    )
  ),

  'A missing effective observability threshold produced a non-NULL value.'
);


-- ============================================================================
-- A12. Minimized projection column boundary
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A12',

  'Ordinary P2F projections exclude protected raw columns and retain only safe audit idempotency evidence',

  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name in (
        'v_admin_audit_projection',
        'v_failed_command_queue',
        'v_stuck_workflow_queue',
        'v_payout_attention_queue',
        'v_dispute_attention_queue',
        'v_compliance_attention_queue'
      )

      and c.column_name in (
        'reason',
        'metadata',
        'before_value',
        'after_value',
        'idempotency_key',
        'result',
        'payload',
        'last_error',
        'request_snapshot',
        'normalized_result',
        'response_snapshot',
        'verification_context',
        'normalized_event_snapshot',
        'command_result',
        'error_context',
        'response_payload',
        'storage_object_key',
        'credential_number',
        'notes',
        'review_action_note',
        'control_snapshot',
        'resolution_summary',
        'financial_allocation',
        'evidence_decision'
      )
  )

  and

  exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name =
        'v_admin_audit_projection'

      and c.column_name =
        'idempotency_key_sha256'
  )

  and

  exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name =
        'v_admin_audit_projection'

      and c.column_name =
        'has_idempotency_key'
  ),

  'A protected raw field leaked into a P2F projection or safe audit hash/presence fields are missing.'
);


-- ============================================================================
-- A13. Functional audit minimization
-- ============================================================================

insert into haulvia.audit_events (
  id,
  actor_kind,
  command_name,
  authority_code,
  reason,
  entity_table,
  entity_id,
  before_value,
  after_value,
  metadata,
  correlation_id,
  idempotency_key
)
values (
  'f2fa0000-0000-0000-0000-000000000101'::uuid,
  'SYSTEM',
  'command_p2f_acceptance_audit_probe',
  'P2F_ACCEPTANCE',
  'Protected acceptance reason',
  'shipments',
  'f2fa0000-0000-0000-0000-000000000102'::uuid,
  '{"protected":"before"}'::jsonb,
  '{"protected":"after"}'::jsonb,
  '{"protected":"metadata"}'::jsonb,
  'f2fa0000-0000-0000-0000-000000000103'::uuid,
  'p2f-acceptance-raw-idempotency-key'
);


select pg_temp.record_requirement(
  'P2F-A13',

  'Admin audit projection exposes presence flags and SHA-256 rather than protected audit payloads',

  exists (
    select 1
    from haulvia.v_admin_audit_projection a
    where a.audit_event_id =
        'f2fa0000-0000-0000-0000-000000000101'::uuid

      and a.command_name =
        'command_p2f_acceptance_audit_probe'

      and a.has_idempotency_key

      and a.idempotency_key_sha256 =
        pg_catalog.encode(
          pg_catalog.sha256(
            pg_catalog.convert_to(
              'p2f-acceptance-raw-idempotency-key',
              'UTF8'
            )
          ),
          'hex'
        )

      and a.has_reason

      and a.has_before_value

      and a.has_after_value
  ),

  'Audit minimization/hash projection did not represent the protected audit fact correctly.'
);


-- ============================================================================
-- A14. Dedicated failure-observation writer behavior
-- ============================================================================

do $$
declare
  v_first jsonb;
  v_replay jsonb;
  v_conflict_rejected boolean :=
    false;
begin
  v_first :=
    haulvia_command.command_record_command_failure_observation(
      jsonb_build_object(
        'workerAuthority',
          'OBSERVABILITY_WORKER',

        'observationKey',
          'p2f-acceptance-observation-0001',

        'sourceCode',
          'COMMAND_ADAPTER',

        'failedCommandName',
          'command_p2f_acceptance_rejected_probe',

        'failedActorProfileId',
          'f2fa0000-0000-0000-0000-000000000111',

        'failedOrganizationId',
          'f2fa0000-0000-0000-0000-000000000112',

        'failedShipmentId',
          'f2fa0000-0000-0000-0000-000000000113',

        'correlationId',
          'p2f-acceptance-correlation-0001',

        'requestSha256',
          repeat(
            'a',
            64
          ),

        'idempotencyKeySha256',
          repeat(
            'b',
            64
          ),

        'errorCode',
          'NOT_AUTHORIZED',

        'sqlstate',
          'P0001',

        'retryable',
          false
      )
    );


  v_replay :=
    haulvia_command.command_record_command_failure_observation(
      jsonb_build_object(
        'workerAuthority',
          'OBSERVABILITY_WORKER',

        'observationKey',
          'p2f-acceptance-observation-0001',

        'sourceCode',
          'COMMAND_ADAPTER',

        'failedCommandName',
          'command_p2f_acceptance_rejected_probe',

        'failedActorProfileId',
          'f2fa0000-0000-0000-0000-000000000111',

        'failedOrganizationId',
          'f2fa0000-0000-0000-0000-000000000112',

        'failedShipmentId',
          'f2fa0000-0000-0000-0000-000000000113',

        'correlationId',
          'p2f-acceptance-correlation-0001',

        'requestSha256',
          repeat(
            'a',
            64
          ),

        'idempotencyKeySha256',
          repeat(
            'b',
            64
          ),

        'errorCode',
          'NOT_AUTHORIZED',

        'sqlstate',
          'P0001',

        'retryable',
          false
      )
    );


  begin
    perform
      haulvia_command.command_record_command_failure_observation(
        jsonb_build_object(
          'workerAuthority',
            'OBSERVABILITY_WORKER',

          'observationKey',
            'p2f-acceptance-observation-0001',

          'sourceCode',
            'COMMAND_ADAPTER',

          'failedCommandName',
            'command_p2f_acceptance_rejected_probe',

          'correlationId',
            'p2f-acceptance-correlation-0001',

          'requestSha256',
            repeat(
              'a',
              64
            ),

          'idempotencyKeySha256',
            repeat(
              'b',
              64
            ),

          'errorCode',
            'DIFFERENT_ERROR',

          'sqlstate',
            'P0001',

          'retryable',
            false
        )
      );

  exception
    when sqlstate 'P0001' then
      v_conflict_rejected :=
        true;
  end;


  perform pg_temp.record_requirement(
    'P2F-A14',

    'Failure-observation writer supports exact replay but rejects same-key different-fact reuse without creating command lifecycle state',

    coalesce(
      (
        v_first ->> 'replayed'
      )::boolean,
      true
    ) = false

    and

    coalesce(
      (
        v_replay ->> 'replayed'
      )::boolean,
      false
    ) = true

    and

    (
      select count(*)
      from haulvia.command_failure_observations cfo
      where cfo.observation_key =
        'p2f-acceptance-observation-0001'
    ) = 1

    and

    not exists (
      select 1
      from haulvia.command_idempotency ci
      where ci.command_name =
        'command_record_command_failure_observation'
    )

    and

    v_conflict_rejected,

    'Failure-observation replay/conflict or command-lifecycle isolation failed.'
  );
end;
$$;


-- ============================================================================
-- A15. Append-only observation evidence
-- ============================================================================

do $$
declare
  v_update_rejected boolean :=
    false;

  v_delete_rejected boolean :=
    false;
begin
  begin
    update haulvia.command_failure_observations
    set retryable =
      true
    where observation_key =
      'p2f-acceptance-observation-0001';

  exception
    when others then
      v_update_rejected :=
        true;
  end;


  begin
    delete from haulvia.command_failure_observations
    where observation_key =
      'p2f-acceptance-observation-0001';

  exception
    when others then
      v_delete_rejected :=
        true;
  end;


  perform pg_temp.record_requirement(
    'P2F-A15',

    'Command-failure observations are append-only',

    v_update_rejected
    and
    v_delete_rejected,

    'Observation UPDATE or DELETE was not rejected.'
  );
end;
$$;


-- ============================================================================
-- A16. Observed rejected command becomes COMMAND_FAILED
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-A16',

  'Post-rollback failure observation appears as COMMAND_FAILED without creating canonical command state',

  exists (
    select 1
    from haulvia.v_failed_command_queue q
    where q.failure_source =
        'FAILURE_OBSERVATION'

      and q.attention_code =
        'COMMAND_FAILED'

      and q.command_name =
        'command_p2f_acceptance_rejected_probe'

      and q.failure_observation_id is not null

      and q.command_idempotency_id
        is null

      and q.error_code =
        'NOT_AUTHORIZED'

      and q.retryable =
        false
  )

  and

  not exists (
    select 1
    from haulvia.command_idempotency ci
    where ci.command_name =
      'command_p2f_acceptance_rejected_probe'
  ),

  'Observed rejected command was not represented correctly by the failed-command queue.'
);


-- ============================================================================
-- A17. Persisted FAILED command remains a second valid source
-- ============================================================================

insert into haulvia.command_idempotency (
  id,
  actor_profile_id,
  command_name,
  idempotency_key,
  request_hash,
  status,
  result,
  started_at,
  completed_at
)
values (
  'f2fa0000-0000-0000-0000-000000000121'::uuid,
  null,
  'command_p2f_acceptance_persisted_failure',
  'p2f-acceptance-persisted-failure-key',
  repeat(
    'c',
    64
  ),
  'FAILED',
  '{"protectedResult":"must-not-project"}'::jsonb,
  clock_timestamp() - interval '2 minutes',
  clock_timestamp() - interval '1 minute'
);


select pg_temp.record_requirement(
  'P2F-A17',

  'Persisted FAILED command state produces COMMAND_FAILED without projecting stored result',

  exists (
    select 1
    from haulvia.v_failed_command_queue q
    where q.command_idempotency_id =
        'f2fa0000-0000-0000-0000-000000000121'::uuid

      and q.failure_source =
        'PERSISTED_IDEMPOTENCY_FAILURE'

      and q.attention_code =
        'COMMAND_FAILED'

      and q.canonical_idempotency_status =
        'FAILED'
  )

  and

  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name =
        'v_failed_command_queue'

      and c.column_name =
        'result'
  ),

  'Persisted FAILED classification or result-field exclusion failed.'
);


-- ============================================================================
-- A18. Stale STARTED is disabled while threshold is absent
-- ============================================================================

insert into haulvia.command_idempotency (
  id,
  actor_profile_id,
  command_name,
  idempotency_key,
  request_hash,
  status,
  started_at
)
values (
  'f2fa0000-0000-0000-0000-000000000122'::uuid,
  null,
  'command_p2f_acceptance_stale_probe',
  'p2f-acceptance-stale-probe-key',
  repeat(
    'd',
    64
  ),
  'STARTED',
  clock_timestamp() - interval '2 hours'
);


select pg_temp.record_requirement(
  'P2F-A18',

  'Missing command stale threshold suppresses COMMAND_STALE_STARTED',

  not exists (
    select 1
    from haulvia.v_failed_command_queue q
    where q.command_idempotency_id =
        'f2fa0000-0000-0000-0000-000000000122'::uuid

      and q.attention_code =
        'COMMAND_STALE_STARTED'
  ),

  'A stale STARTED command was classified despite missing effective configuration.'
);


-- ============================================================================
-- Transaction-local configuration actors
-- ============================================================================

insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'f2fa0000-0000-0000-0000-000000000131'::uuid,
    'P2F acceptance config creator'
  ),
  (
    'f2fa0000-0000-0000-0000-000000000132'::uuid,
    'P2F acceptance config approver'
  );


-- ============================================================================
-- A19. Positive effective threshold enables stale classification
-- ============================================================================

insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  950001,
  'APPROVED',
  '60'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        (
          '60'::jsonb
        )::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fa0000-0000-0000-0000-000000000131'::uuid,
  'f2fa0000-0000-0000-0000-000000000132'::uuid,
  'P2F permanent acceptance command-stale threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_COMMAND_STARTED_STALE_SECONDS';


select pg_temp.record_requirement(
  'P2F-A19',

  'Exactly one approved effective positive threshold enables deterministic COMMAND_STALE_STARTED classification',

  haulvia.resolve_observability_positive_integer(
    'OBS_COMMAND_STARTED_STALE_SECONDS'
  ) = 60

  and

  exists (
    select 1
    from haulvia.v_failed_command_queue q
    where q.command_idempotency_id =
        'f2fa0000-0000-0000-0000-000000000122'::uuid

      and q.failure_source =
        'STALE_STARTED'

      and q.attention_code =
        'COMMAND_STALE_STARTED'

      and q.canonical_idempotency_status =
        'STARTED'

      and q.age_seconds >=
        60
  ),

  'Effective command threshold did not resolve/classify stale STARTED state correctly.'
);


-- ============================================================================
-- A20. Overlapping effective versions fail closed
-- ============================================================================

do $$
declare
  v_failed_closed boolean :=
    false;
begin
  begin
    insert into haulvia.platform_config_versions (
      config_definition_id,
      version_no,
      publication_status,
      config_value,
      value_sha256,
      effective_from,
      created_by_profile_id,
      approved_by_profile_id,
      approval_reason,
      approved_at
    )
    select
      d.id,
      950002,
      'APPROVED',
      '120'::jsonb,
      pg_catalog.encode(
        pg_catalog.sha256(
          pg_catalog.convert_to(
            (
              '120'::jsonb
            )::text,
            'UTF8'
          )
        ),
        'hex'
      ),
      clock_timestamp() - interval '30 minutes',
      'f2fa0000-0000-0000-0000-000000000131'::uuid,
      'f2fa0000-0000-0000-0000-000000000132'::uuid,
      'P2F overlapping-threshold rejection fixture',
      clock_timestamp()
    from haulvia.platform_config_definitions d
    where d.config_key =
      'OBS_COMMAND_STARTED_STALE_SECONDS';


    perform
      haulvia.resolve_observability_positive_integer(
        'OBS_COMMAND_STARTED_STALE_SECONDS'
      );

  exception
    when sqlstate 'P0001' then
      v_failed_closed :=
        true;
  end;


  perform pg_temp.record_requirement(
    'P2F-A20',

    'Multiple simultaneously effective approved thresholds fail closed',

    v_failed_closed

    and

    haulvia.resolve_observability_positive_integer(
      'OBS_COMMAND_STARTED_STALE_SECONDS'
    ) = 60,

    'Overlapping configuration did not fail closed or its failed subtransaction leaked.'
  );
end;
$$;


-- ============================================================================
-- A21. Non-positive effective values fail closed
-- ============================================================================

do $$
declare
  v_failed_closed boolean :=
    false;
begin
  begin
    insert into haulvia.platform_config_versions (
      config_definition_id,
      version_no,
      publication_status,
      config_value,
      value_sha256,
      effective_from,
      created_by_profile_id,
      approved_by_profile_id,
      approval_reason,
      approved_at
    )
    select
      d.id,
      950003,
      'APPROVED',
      '0'::jsonb,
      pg_catalog.encode(
        pg_catalog.sha256(
          pg_catalog.convert_to(
            (
              '0'::jsonb
            )::text,
            'UTF8'
          )
        ),
        'hex'
      ),
      clock_timestamp() - interval '1 hour',
      'f2fa0000-0000-0000-0000-000000000131'::uuid,
      'f2fa0000-0000-0000-0000-000000000132'::uuid,
      'P2F zero-threshold rejection fixture',
      clock_timestamp()
    from haulvia.platform_config_definitions d
    where d.config_key =
      'OBS_WORKFLOW_QUEUED_LATE_SECONDS';


    perform
      haulvia.resolve_observability_positive_integer(
        'OBS_WORKFLOW_QUEUED_LATE_SECONDS'
      );

  exception
    when sqlstate 'P0001' then
      v_failed_closed :=
        true;
  end;


  perform pg_temp.record_requirement(
    'P2F-A21',

    'Zero/non-positive observability thresholds fail closed',

    v_failed_closed

    and

    haulvia.resolve_observability_positive_integer(
      'OBS_WORKFLOW_QUEUED_LATE_SECONDS'
    ) is null,

    'Non-positive threshold was accepted or failed subtransaction leaked.'
  );
end;
$$;


-- ============================================================================
-- A22. OBSERVABILITY_WORKER cannot become a human role
-- ============================================================================

do $$
declare
  v_rejected boolean :=
    false;
begin
  begin
    insert into haulvia.roles (
      role_key,
      name,
      description
    )
    values (
      'OBSERVABILITY_WORKER',
      'Invalid P2F Human Role',
      'Permanent P2F acceptance must reject this role.'
    );

  exception
    when check_violation then
      v_rejected :=
        true;
  end;


  perform pg_temp.record_requirement(
    'P2F-A22',

    'OBSERVABILITY_WORKER is actively rejected from the human-role table',

    v_rejected

    and

    not exists (
      select 1
      from haulvia.roles r
      where r.role_key =
        'OBSERVABILITY_WORKER'
    ),

    'OBSERVABILITY_WORKER was accepted as a human RBAC role.'
  );
end;
$$;


-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-A-END
-- ============================================================================


-- ============================================================================
-- Temporary finalization
--
-- Later acceptance blocks will be inserted before this marker.
-- ============================================================================



-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-B-BEGIN
--
-- Permanent workflow-attention acceptance.
-- ============================================================================


-- ============================================================================
-- B01. FAILED remains visible without age configuration
-- ============================================================================

insert into haulvia.workflow_jobs (
  id,
  shipment_id,
  job_code,
  status,
  run_after,
  payload,
  attempt_count,
  last_error,
  idempotency_key,
  created_at,
  updated_at
)
values
  (
    'f2fb0000-0000-0000-0000-000000000201'::uuid,
    null,
    'P2F_ACCEPTANCE_FAILED',
    'FAILED',
    clock_timestamp() - interval '1 hour',
    '{"protected":"failed-payload"}'::jsonb,
    3,
    'Protected workflow error',
    'p2f-acceptance-workflow-failed',
    clock_timestamp() - interval '2 hours',
    clock_timestamp() - interval '1 hour'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000202'::uuid,
    null,
    'P2F_ACCEPTANCE_OLD_QUEUED',
    'QUEUED',
    clock_timestamp() - interval '2 hours',
    '{"protected":"old-queued"}'::jsonb,
    1,
    null,
    'p2f-acceptance-workflow-old-queued',
    clock_timestamp() - interval '3 hours',
    clock_timestamp() - interval '2 hours'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000203'::uuid,
    null,
    'P2F_ACCEPTANCE_OLD_RUNNING',
    'RUNNING',
    clock_timestamp() - interval '3 hours',
    '{"protected":"old-running"}'::jsonb,
    2,
    'Protected running error',
    'p2f-acceptance-workflow-old-running',
    clock_timestamp() - interval '3 hours',
    clock_timestamp() - interval '2 hours'
  );


select pg_temp.record_requirement(
  'P2F-B01',

  'FAILED workflow job remains visible independently of threshold configuration',

  exists (
    select 1
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id =
        'f2fb0000-0000-0000-0000-000000000201'::uuid

      and q.attention_code =
        'WORKFLOW_JOB_FAILED'

      and q.canonical_status =
        'FAILED'

      and q.attempt_count =
        3

      and q.has_last_error

      and q.threshold_seconds
        is null
  ),

  'FAILED workflow job was not represented correctly.'
);


-- ============================================================================
-- B02. Missing thresholds suppress age classifications
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B02',

  'Missing workflow thresholds suppress old QUEUED and RUNNING age alerts',

  not exists (
    select 1
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id in (
      'f2fb0000-0000-0000-0000-000000000202'::uuid,
      'f2fb0000-0000-0000-0000-000000000203'::uuid
    )
  ),

  'Age-based workflow attention appeared without effective thresholds.'
);


-- ============================================================================
-- Workflow threshold publication identities
-- ============================================================================

insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'f2fb0000-0000-0000-0000-000000000211'::uuid,
    'P2F workflow config creator'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000212'::uuid,
    'P2F workflow config approver'
  );


insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  951001,
  'APPROVED',
  '60'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        ('60'::jsonb)::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fb0000-0000-0000-0000-000000000211'::uuid,
  'f2fb0000-0000-0000-0000-000000000212'::uuid,
  'P2F permanent workflow queued-late threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_WORKFLOW_QUEUED_LATE_SECONDS';


insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  951002,
  'APPROVED',
  '120'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        ('120'::jsonb)::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fb0000-0000-0000-0000-000000000211'::uuid,
  'f2fb0000-0000-0000-0000-000000000212'::uuid,
  'P2F permanent workflow running-stale threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_WORKFLOW_RUNNING_STALE_SECONDS';


-- ============================================================================
-- B03. Exact threshold resolution
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B03',

  'Workflow queued-late and running-stale thresholds resolve exactly',

  haulvia.resolve_observability_positive_integer(
    'OBS_WORKFLOW_QUEUED_LATE_SECONDS'
  ) = 60

  and

  haulvia.resolve_observability_positive_integer(
    'OBS_WORKFLOW_RUNNING_STALE_SECONDS'
  ) = 120,

  'Expected queued-late=60 and running-stale=120 seconds.'
);


-- ============================================================================
-- Threshold-driven fixtures
-- ============================================================================

insert into haulvia.workflow_jobs (
  id,
  shipment_id,
  job_code,
  status,
  run_after,
  payload,
  attempt_count,
  last_error,
  idempotency_key,
  created_at,
  updated_at
)
values
  (
    'f2fb0000-0000-0000-0000-000000000221'::uuid,
    null,
    'P2F_ACCEPTANCE_LATE_QUEUED',
    'QUEUED',
    clock_timestamp() - interval '10 minutes',
    '{"protected":"late-queued"}'::jsonb,
    1,
    null,
    'p2f-acceptance-workflow-late-queued',
    clock_timestamp() - interval '20 minutes',
    clock_timestamp() - interval '20 minutes'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000222'::uuid,
    null,
    'P2F_ACCEPTANCE_FRESH_QUEUED',
    'QUEUED',
    clock_timestamp() - interval '10 seconds',
    '{}'::jsonb,
    0,
    null,
    'p2f-acceptance-workflow-fresh-queued',
    clock_timestamp() - interval '1 minute',
    clock_timestamp() - interval '1 minute'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000223'::uuid,
    null,
    'P2F_ACCEPTANCE_STALE_RUNNING',
    'RUNNING',
    clock_timestamp() - interval '30 minutes',
    '{"protected":"stale-running"}'::jsonb,
    4,
    'Protected running failure text',
    'p2f-acceptance-workflow-stale-running',
    clock_timestamp() - interval '30 minutes',
    clock_timestamp() - interval '10 minutes'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000224'::uuid,
    null,
    'P2F_ACCEPTANCE_FRESH_RUNNING',
    'RUNNING',
    clock_timestamp() - interval '5 minutes',
    '{}'::jsonb,
    1,
    null,
    'p2f-acceptance-workflow-fresh-running',
    clock_timestamp() - interval '5 minutes',
    clock_timestamp() - interval '10 seconds'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000225'::uuid,
    null,
    'P2F_ACCEPTANCE_SUCCEEDED_EXCLUDED',
    'SUCCEEDED',
    clock_timestamp() - interval '1 hour',
    '{}'::jsonb,
    1,
    null,
    'p2f-acceptance-workflow-succeeded',
    clock_timestamp() - interval '2 hours',
    clock_timestamp() - interval '1 hour'
  ),
  (
    'f2fb0000-0000-0000-0000-000000000226'::uuid,
    null,
    'P2F_ACCEPTANCE_CANCELLED_EXCLUDED',
    'CANCELLED',
    clock_timestamp() - interval '1 hour',
    '{}'::jsonb,
    1,
    null,
    'p2f-acceptance-workflow-cancelled',
    clock_timestamp() - interval '2 hours',
    clock_timestamp() - interval '1 hour'
  );


-- ============================================================================
-- B04. Late QUEUED
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B04',

  'Late QUEUED workflow job uses configured queued threshold',

  exists (
    select 1
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id =
        'f2fb0000-0000-0000-0000-000000000221'::uuid

      and q.attention_code =
        'WORKFLOW_JOB_LATE'

      and q.canonical_status =
        'QUEUED'

      and q.threshold_seconds =
        60

      and q.age_seconds >=
        60

      and not q.has_last_error
  ),

  'Late QUEUED workflow classification is incorrect.'
);


-- ============================================================================
-- B05. Stale RUNNING
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B05',

  'Stale RUNNING workflow job uses updated_at and configured running threshold',

  exists (
    select 1
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id =
        'f2fb0000-0000-0000-0000-000000000223'::uuid

      and q.attention_code =
        'WORKFLOW_JOB_STALE_RUNNING'

      and q.canonical_status =
        'RUNNING'

      and q.threshold_seconds =
        120

      and q.age_seconds >=
        120

      and q.attempt_count =
        4

      and q.has_last_error
  ),

  'Stale RUNNING workflow classification is incorrect.'
);


-- ============================================================================
-- B06. Fresh QUEUED/RUNNING exclusions
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B06',

  'Fresh QUEUED and RUNNING workflow jobs remain outside attention queue',

  not exists (
    select 1
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id in (
      'f2fb0000-0000-0000-0000-000000000222'::uuid,
      'f2fb0000-0000-0000-0000-000000000224'::uuid
    )
  ),

  'Fresh QUEUED or RUNNING workflow job was classified prematurely.'
);


-- ============================================================================
-- B07. Terminal workflow exclusions
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B07',

  'SUCCEEDED and CANCELLED workflow jobs remain outside operational attention',

  not exists (
    select 1
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id in (
      'f2fb0000-0000-0000-0000-000000000225'::uuid,
      'f2fb0000-0000-0000-0000-000000000226'::uuid
    )
  ),

  'Terminal-success or cancelled workflow job appeared in attention queue.'
);


-- ============================================================================
-- B08. Exact workflow fixture cardinality
--
-- Expected after configuration:
--   201 FAILED
--   202 old QUEUED -> LATE
--   203 old RUNNING -> STALE
--   221 LATE QUEUED
--   223 STALE RUNNING
-- = 5 rows
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-B08',

  'Workflow fixture attention cardinality is exact',

  (
    select count(*)
    from haulvia.v_stuck_workflow_queue q
    where q.workflow_job_id in (
      'f2fb0000-0000-0000-0000-000000000201'::uuid,
      'f2fb0000-0000-0000-0000-000000000202'::uuid,
      'f2fb0000-0000-0000-0000-000000000203'::uuid,
      'f2fb0000-0000-0000-0000-000000000221'::uuid,
      'f2fb0000-0000-0000-0000-000000000222'::uuid,
      'f2fb0000-0000-0000-0000-000000000223'::uuid,
      'f2fb0000-0000-0000-0000-000000000224'::uuid,
      'f2fb0000-0000-0000-0000-000000000225'::uuid,
      'f2fb0000-0000-0000-0000-000000000226'::uuid
    )
  ) = 5,

  'Expected exactly five workflow attention rows from the permanent fixture set.'
);


-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-B-END
-- ============================================================================



-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-C-BEGIN
--
-- Permanent payout-attention acceptance.
-- ============================================================================


-- ============================================================================
-- Shared payout fixture identities
-- ============================================================================

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values
  (
    'f2fc0000-0000-0000-0000-000000000001'::uuid,
    'p2f-acceptance-customer',
    'CUSTOMER',
    'P2F Acceptance Customer Ltd.',
    'P2F Acceptance Customer'
  ),
  (
    'f2fc0000-0000-0000-0000-000000000002'::uuid,
    'p2f-acceptance-provider',
    'INDEPENDENT_PROVIDER',
    'P2F Acceptance Provider Ltd.',
    'P2F Acceptance Provider'
  );


insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'f2fc0000-0000-0000-0000-000000000011'::uuid,
    'P2F payout customer'
  ),
  (
    'f2fc0000-0000-0000-0000-000000000012'::uuid,
    'P2F payout driver'
  ),
  (
    'f2fc0000-0000-0000-0000-000000000013'::uuid,
    'P2F payout config creator'
  ),
  (
    'f2fc0000-0000-0000-0000-000000000014'::uuid,
    'P2F payout config approver'
  );


insert into haulvia.service_providers (
  id,
  organization_id,
  kind,
  status,
  approved_at
)
values (
  'f2fc0000-0000-0000-0000-000000000021'::uuid,
  'f2fc0000-0000-0000-0000-000000000002'::uuid,
  'INDEPENDENT_DRIVER',
  'ACTIVE',
  clock_timestamp()
);


insert into haulvia.drivers (
  id,
  profile_id,
  status,
  public_label
)
values (
  'f2fc0000-0000-0000-0000-000000000022'::uuid,
  'f2fc0000-0000-0000-0000-000000000012'::uuid,
  'ACTIVE',
  'P2F Acceptance Driver'
);


insert into haulvia.provider_drivers (
  provider_id,
  driver_id,
  status
)
values (
  'f2fc0000-0000-0000-0000-000000000021'::uuid,
  'f2fc0000-0000-0000-0000-000000000022'::uuid,
  'ACTIVE'
);


insert into haulvia.vehicles (
  id,
  provider_id,
  vehicle_key,
  status,
  vehicle_class,
  capacity_weight_kg
)
values (
  'f2fc0000-0000-0000-0000-000000000023'::uuid,
  'f2fc0000-0000-0000-0000-000000000021'::uuid,
  'p2f-acceptance-payout-vehicle',
  'ACTIVE',
  'CARGO_VAN',
  1000
);


insert into haulvia.pricing_rule_sets (
  id,
  rule_key,
  name,
  pricing_source,
  service_level,
  currency
)
values (
  'f2fc0000-0000-0000-0000-000000000031'::uuid,
  'P2F_ACCEPTANCE_PAYOUT_RULE',
  'P2F Acceptance Payout Rule',
  'HAULVIA_GUARDRAIL',
  'FLEX',
  'CAD'
);


insert into haulvia.pricing_rule_versions (
  id,
  pricing_rule_set_id,
  version_no,
  publication_status,
  rule_config,
  rule_sha256,
  created_by_profile_id
)
values (
  'f2fc0000-0000-0000-0000-000000000032'::uuid,
  'f2fc0000-0000-0000-0000-000000000031'::uuid,
  1,
  'DRAFT',
  '{"fixture":true}'::jsonb,
  repeat(
    'c',
    64
  ),
  'f2fc0000-0000-0000-0000-000000000013'::uuid
);


create temporary table
p2f_acceptance_payout_ids (
  label text primary key,
  payout_id uuid not null,
  shipment_id uuid not null
)
on commit drop;


create or replace function
pg_temp.seed_p2f_acceptance_payout(
  p_label text,
  p_state haulvia.driver_payout_state,
  p_state_changed_at timestamptz
)
returns uuid
language plpgsql
as $$
declare
  v_shipment_id uuid :=
    gen_random_uuid();

  v_route_id uuid :=
    gen_random_uuid();

  v_review_id uuid :=
    gen_random_uuid();

  v_price_id uuid :=
    gen_random_uuid();

  v_assignment_id uuid :=
    gen_random_uuid();

  v_payout_id uuid :=
    gen_random_uuid();
begin
  insert into haulvia.shipments (
    id,
    customer_organization_id,
    customer_profile_id,
    shipment_state,
    pickup_timing,
    service_level,
    currency
  )
  values (
    v_shipment_id,
    'f2fc0000-0000-0000-0000-000000000001'::uuid,
    'f2fc0000-0000-0000-0000-000000000011'::uuid,
    'DRAFT',
    'ASAP',
    'FLEX',
    'CAD'
  );


  -- This fixture is not testing customer-payment behavior. Establish only the
  -- canonical prerequisite required by the ACTIVE assignment guard.

  update haulvia.shipment_customer_payment_axes
  set
    state =
      'SECURED',

    secured_amount =
      100,

    currency =
      'CAD',

    state_changed_at =
      clock_timestamp()

  where shipment_id =
    v_shipment_id;


  -- ACTIVE assignments must reference the shipment's active route.

  insert into haulvia.route_versions (
    id,
    shipment_id,
    version_no,
    status,
    change_reason,
    created_by_profile_id,
    activated_at
  )
  values (
    v_route_id,
    v_shipment_id,
    1,
    'ACTIVE',
    'P2F payout fixture ' ||
      p_label,
    'f2fc0000-0000-0000-0000-000000000011'::uuid,
    clock_timestamp()
  );


  -- ASSIGNMENT snapshots require a current PASSED/APPROVED pricing review for
  -- the same route, pricing branch, currency and total amount.

  insert into haulvia.pricing_reviews (
    id,
    shipment_id,
    route_version_id,
    pricing_source,
    pricing_mode,
    status,
    reviewed_amount,
    currency,
    reviewed_by_profile_id,
    reviewed_at
  )
  values (
    v_review_id,
    v_shipment_id,
    v_route_id,
    'HAULVIA_GUARDRAIL',
    'NOT_APPLICABLE',
    'PASSED',
    100,
    'CAD',
    'f2fc0000-0000-0000-0000-000000000013'::uuid,
    clock_timestamp()
  );


  insert into haulvia.shipment_price_snapshots (
    id,
    shipment_id,
    route_version_id,
    purpose,
    pricing_source,
    pricing_mode,
    pricing_rule_version_id,
    pricing_review_id,
    subtotal,
    tax_amount,
    total_amount,
    currency,
    breakdown,
    snapshot_sha256,
    accepted_at
  )
  values (
    v_price_id,
    v_shipment_id,
    v_route_id,
    'ASSIGNMENT',
    'HAULVIA_GUARDRAIL',
    'NOT_APPLICABLE',
    'f2fc0000-0000-0000-0000-000000000032'::uuid,
    v_review_id,
    100,
    0,
    100,
    'CAD',
    jsonb_build_array(
      jsonb_build_object(
        'component',
        'P2F_ACCEPTANCE',
        'amount',
        100
      )
    ),
    repeat(
      'd',
      64
    ),
    clock_timestamp()
  );


  insert into haulvia.assignments (
    id,
    shipment_id,
    route_version_id,
    provider_id,
    driver_id,
    vehicle_id,
    price_snapshot_id,
    status,
    agreement_snapshot
  )
  values (
    v_assignment_id,
    v_shipment_id,
    v_route_id,
    'f2fc0000-0000-0000-0000-000000000021'::uuid,
    'f2fc0000-0000-0000-0000-000000000022'::uuid,
    'f2fc0000-0000-0000-0000-000000000023'::uuid,
    v_price_id,
    'ACTIVE',
    jsonb_build_object(
      'p2fBlockC',
      p_label
    )
  );


  insert into haulvia.driver_payouts (
    id,
    shipment_id,
    assignment_id,
    provider_id,
    driver_id,
    state,
    gross_amount,
    platform_fee_amount,
    adjustment_amount,
    net_amount,
    currency,
    state_changed_at
  )
  values (
    v_payout_id,
    v_shipment_id,
    v_assignment_id,
    'f2fc0000-0000-0000-0000-000000000021'::uuid,
    'f2fc0000-0000-0000-0000-000000000022'::uuid,
    p_state,
    100,
    10,
    0,
    90,
    'CAD',
    p_state_changed_at
  );


  insert into p2f_acceptance_payout_ids (
    label,
    payout_id,
    shipment_id
  )
  values (
    p_label,
    v_payout_id,
    v_shipment_id
  );


  return v_payout_id;
end;
$$;


-- ============================================================================
-- C01-C03. Threshold-independent and missing-config behavior
-- ============================================================================

select pg_temp.seed_p2f_acceptance_payout(
  'failed',
  'FAILED',
  clock_timestamp() - interval '30 minutes'
);

select pg_temp.seed_p2f_acceptance_payout(
  'held',
  'HELD',
  clock_timestamp() - interval '30 minutes'
);

select pg_temp.seed_p2f_acceptance_payout(
  'ready-no-config',
  'READY',
  clock_timestamp() - interval '2 hours'
);

select pg_temp.seed_p2f_acceptance_payout(
  'processing-no-config',
  'PROCESSING',
  clock_timestamp() - interval '2 hours'
);


select pg_temp.record_requirement(
  'P2F-C01',

  'FAILED payout is visible independently of threshold configuration',

  exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label =
        'failed'

      and q.attention_code =
        'PAYOUT_FAILED'

      and q.canonical_payout_state =
        'FAILED'

      and q.threshold_seconds
        is null
  ),

  'FAILED payout was not represented correctly.'
);


select pg_temp.record_requirement(
  'P2F-C02',

  'HELD payout is visible independently of threshold configuration',

  exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label =
        'held'

      and q.attention_code =
        'PAYOUT_HELD'

      and q.canonical_payout_state =
        'HELD'

      and q.threshold_seconds
        is null
  ),

  'HELD payout was not represented correctly.'
);


select pg_temp.record_requirement(
  'P2F-C03',

  'Missing payout thresholds suppress old READY and PROCESSING age alerts',

  not exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label in (
      'ready-no-config',
      'processing-no-config'
    )
  ),

  'READY or PROCESSING payout was age-classified without configured threshold.'
);


-- ============================================================================
-- Effective payout thresholds
-- ============================================================================

insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  952001,
  'APPROVED',
  '60'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        ('60'::jsonb)::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fc0000-0000-0000-0000-000000000013'::uuid,
  'f2fc0000-0000-0000-0000-000000000014'::uuid,
  'P2F permanent payout READY stale threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_PAYOUT_READY_STALE_SECONDS';


insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  952002,
  'APPROVED',
  '120'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        ('120'::jsonb)::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fc0000-0000-0000-0000-000000000013'::uuid,
  'f2fc0000-0000-0000-0000-000000000014'::uuid,
  'P2F permanent payout PROCESSING stale threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_PAYOUT_PROCESSING_STALE_SECONDS';


select pg_temp.record_requirement(
  'P2F-C04',

  'Payout READY and PROCESSING stale thresholds resolve exactly',

  haulvia.resolve_observability_positive_integer(
    'OBS_PAYOUT_READY_STALE_SECONDS'
  ) = 60

  and

  haulvia.resolve_observability_positive_integer(
    'OBS_PAYOUT_PROCESSING_STALE_SECONDS'
  ) = 120,

  'Expected READY=60 and PROCESSING=120 seconds.'
);


-- The two missing-config probes have already proven suppression.
-- Refresh their state-change timestamps so they remain nonattention fixtures
-- after effective threshold publication.

update haulvia.driver_payouts dp
set state_changed_at =
  clock_timestamp()
from p2f_acceptance_payout_ids i
where i.payout_id =
    dp.id

  and i.label in (
    'ready-no-config',
    'processing-no-config'
  );


-- ============================================================================
-- Threshold-driven fixtures
-- ============================================================================

select pg_temp.seed_p2f_acceptance_payout(
  'stale-ready',
  'READY',
  clock_timestamp() - interval '10 minutes'
);

select pg_temp.seed_p2f_acceptance_payout(
  'stale-processing',
  'PROCESSING',
  clock_timestamp() - interval '10 minutes'
);

select pg_temp.seed_p2f_acceptance_payout(
  'fresh-ready',
  'READY',
  clock_timestamp() - interval '10 seconds'
);

select pg_temp.seed_p2f_acceptance_payout(
  'fresh-processing',
  'PROCESSING',
  clock_timestamp() - interval '10 seconds'
);

select pg_temp.seed_p2f_acceptance_payout(
  'paid',
  'PAID',
  clock_timestamp() - interval '10 minutes'
);

select pg_temp.seed_p2f_acceptance_payout(
  'cancelled',
  'CANCELLED',
  clock_timestamp() - interval '10 minutes'
);

select pg_temp.seed_p2f_acceptance_payout(
  'not-ready',
  'NOT_READY',
  clock_timestamp() - interval '10 minutes'
);


select pg_temp.record_requirement(
  'P2F-C05',

  'Old READY payout receives PAYOUT_STALE_READY',

  exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label =
        'stale-ready'

      and q.attention_code =
        'PAYOUT_STALE_READY'

      and q.canonical_payout_state =
        'READY'

      and q.threshold_seconds =
        60

      and q.age_seconds >=
        60
  ),

  'Old READY payout was not classified stale.'
);


select pg_temp.record_requirement(
  'P2F-C06',

  'Old PROCESSING payout receives PAYOUT_STALE_PROCESSING',

  exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label =
        'stale-processing'

      and q.attention_code =
        'PAYOUT_STALE_PROCESSING'

      and q.canonical_payout_state =
        'PROCESSING'

      and q.threshold_seconds =
        120

      and q.age_seconds >=
        120
  ),

  'Old PROCESSING payout was not classified stale.'
);


select pg_temp.record_requirement(
  'P2F-C07',

  'Fresh READY and PROCESSING payouts remain outside stale attention',

  not exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label in (
      'ready-no-config',
      'processing-no-config',
      'fresh-ready',
      'fresh-processing'
    )
  ),

  'Fresh READY or PROCESSING payout appeared in stale attention.'
);


select pg_temp.record_requirement(
  'P2F-C08',

  'PAID CANCELLED and NOT_READY payouts remain outside payout attention',

  not exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label in (
      'paid',
      'cancelled',
      'not-ready'
    )
  ),

  'Nonattention canonical payout state appeared in the queue.'
);


-- ============================================================================
-- Safe latest payout transaction context
-- ============================================================================

insert into haulvia.payout_transactions (
  id,
  payout_id,
  status,
  amount,
  currency,
  external_provider,
  response_payload,
  idempotency_key,
  occurred_at
)
select
  'f2fc0000-0000-0000-0000-000000000601'::uuid,
  i.payout_id,
  'FAILED',
  90,
  'CAD',
  'p2f-acceptance-payout-rail',
  jsonb_build_object(
    'protectedProviderPayload',
    'older-must-not-project'
  ),
  'p2f-acceptance-payout-tx-1',
  clock_timestamp() - interval '20 minutes'
from p2f_acceptance_payout_ids i
where i.label =
  'stale-processing';


insert into haulvia.payout_transactions (
  id,
  payout_id,
  status,
  amount,
  currency,
  external_provider,
  response_payload,
  idempotency_key,
  occurred_at
)
select
  'f2fc0000-0000-0000-0000-000000000602'::uuid,
  i.payout_id,
  'PENDING',
  90,
  'CAD',
  'p2f-acceptance-payout-rail',
  jsonb_build_object(
    'protectedProviderPayload',
    'newer-must-not-project'
  ),
  'p2f-acceptance-payout-tx-2',
  clock_timestamp() - interval '10 minutes'
from p2f_acceptance_payout_ids i
where i.label =
  'stale-processing';


select pg_temp.record_requirement(
  'P2F-C09',

  'Latest payout transaction is selected deterministically by occurred_at then id',

  exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label =
        'stale-processing'

      and q.latest_transaction_status =
        'PENDING'

      and q.latest_transaction_occurred_at
        is not null
  ),

  'Latest safe payout-transaction context was not selected correctly.'
);


-- ============================================================================
-- Safe latest provider-adapter context
-- ============================================================================

insert into haulvia.provider_adapter_requests (
  id,
  shipment_id,
  operation,
  external_provider,
  provider_idempotency_key,
  correlation_id,
  payout_id,
  payout_transaction_id,
  request_fingerprint_sha256,
  request_snapshot,
  status,
  prepared_at,
  submitted_at,
  updated_at
)
select
  'f2fc0000-0000-0000-0000-000000000611'::uuid,
  i.shipment_id,
  'DRIVER_PAYOUT',
  'p2f-acceptance-adapter',
  'p2f-acceptance-adapter-old',
  'f2fc0000-0000-0000-0000-000000000621'::uuid,
  i.payout_id,
  'f2fc0000-0000-0000-0000-000000000601'::uuid,
  repeat(
    'e',
    64
  ),
  '{}'::jsonb,
  'SUBMITTED',
  clock_timestamp() - interval '31 minutes',
  clock_timestamp() - interval '30 minutes',
  clock_timestamp() - interval '30 minutes'
from p2f_acceptance_payout_ids i
where i.label =
  'stale-processing';


insert into haulvia.provider_adapter_requests (
  id,
  shipment_id,
  operation,
  external_provider,
  provider_idempotency_key,
  correlation_id,
  payout_id,
  payout_transaction_id,
  request_fingerprint_sha256,
  request_snapshot,
  status,
  prepared_at,
  submission_failed_at,
  updated_at
)
select
  'f2fc0000-0000-0000-0000-000000000612'::uuid,
  i.shipment_id,
  'DRIVER_PAYOUT',
  'p2f-acceptance-adapter',
  'p2f-acceptance-adapter-new',
  'f2fc0000-0000-0000-0000-000000000622'::uuid,
  i.payout_id,
  'f2fc0000-0000-0000-0000-000000000602'::uuid,
  repeat(
    'f',
    64
  ),
  '{}'::jsonb,
  'SUBMISSION_FAILED',
  clock_timestamp() - interval '15 minutes',
  clock_timestamp() - interval '5 minutes',
  clock_timestamp() - interval '5 minutes'
from p2f_acceptance_payout_ids i
where i.label =
  'stale-processing';


insert into haulvia.provider_adapter_attempts (
  id,
  adapter_request_id,
  attempt_no,
  correlation_id,
  started_at,
  completed_at,
  submission_succeeded,
  normalized_result,
  error_category,
  provider_status,
  provider_reference,
  provider_error_code,
  retryable,
  response_snapshot
)
values
  (
    'f2fc0000-0000-0000-0000-000000000631'::uuid,
    'f2fc0000-0000-0000-0000-000000000612'::uuid,
    1,
    'f2fc0000-0000-0000-0000-000000000622'::uuid,
    clock_timestamp() - interval '8 minutes',
    clock_timestamp() - interval '7 minutes',
    false,
    '{}'::jsonb,
    'NETWORK_ERROR',
    'NETWORK_FAILURE',
    null,
    'NETWORK',
    true,
    '{}'::jsonb
  ),
  (
    'f2fc0000-0000-0000-0000-000000000632'::uuid,
    'f2fc0000-0000-0000-0000-000000000612'::uuid,
    2,
    'f2fc0000-0000-0000-0000-000000000622'::uuid,
    clock_timestamp() - interval '6 minutes',
    clock_timestamp() - interval '5 minutes',
    false,
    '{}'::jsonb,
    'TEMPORARY_PROVIDER_ERROR',
    'TEMPORARY_FAILURE',
    null,
    'TEMPORARY',
    true,
    '{}'::jsonb
  );


select pg_temp.record_requirement(
  'P2F-C10',

  'Latest provider request and latest attempt expose only normalized safe operational context',

  exists (
    select 1
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
    where i.label =
        'stale-processing'

      and q.latest_provider_request_status =
        'SUBMISSION_FAILED'

      and q.latest_provider_attempt_no =
        2

      and q.latest_provider_submission_succeeded =
        false

      and q.latest_provider_error_category =
        'TEMPORARY_PROVIDER_ERROR'

      and q.latest_provider_retryable =
        true

      and q.latest_provider_attempt_completed_at
        is not null
  ),

  'Latest normalized provider-adapter context was not projected correctly.'
);


select pg_temp.record_requirement(
  'P2F-C11',

  'Payout attention projection excludes raw payout and provider payload fields',

  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name =
        'v_payout_attention_queue'

      and c.column_name in (
        'response_payload',
        'request_snapshot',
        'normalized_result',
        'response_snapshot',
        'provider_idempotency_key',
        'provider_reference',
        'provider_error_code',
        'allocation_snapshot'
      )
  ),

  'Payout queue exposes protected provider or payout payload material.'
);


-- ============================================================================
-- C12. Exact fixture cardinality
--
-- Expected:
--   FAILED
--   HELD
--   stale READY
--   stale PROCESSING
-- = 4
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-C12',

  'Payout fixture attention cardinality is exact',

  (
    select count(*)
    from haulvia.v_payout_attention_queue q
    join p2f_acceptance_payout_ids i
      on i.payout_id =
        q.payout_id
  ) = 4,

  'Expected exactly four payout attention rows from permanent payout fixtures.'
);


-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-C-END
-- ============================================================================



-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-D-BEGIN
--
-- Permanent dispute-attention acceptance.
--
-- Reuses one transaction-local shipment created by payout Block C only as a
-- parent record. Dispute state, holds and controls below are independent
-- dedicated fixtures.
-- ============================================================================


create temporary table
p2f_acceptance_dispute_context (
  shipment_id uuid primary key
)
on commit drop;


insert into p2f_acceptance_dispute_context (
  shipment_id
)
select shipment_id
from p2f_acceptance_payout_ids
where label =
  'failed';


-- ============================================================================
-- D01. Missing stale-open threshold fails safe
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D01',

  'Missing dispute stale-open threshold resolves NULL',

  haulvia.resolve_observability_positive_integer(
    'OBS_DISPUTE_OPEN_STALE_SECONDS'
  ) is null,

  'Dispute stale-open threshold should be NULL before a transaction-local value is published.'
);


-- ============================================================================
-- Financial holds
--
-- 720 remains ACTIVE.
-- 721 is inserted ACTIVE and then transitioned canonically to RELEASED.
-- ============================================================================

insert into haulvia.financial_holds (
  id,
  shipment_id,
  hold_code,
  source_type,
  source_id,
  status,
  amount,
  currency,
  reason,
  opened_at
)
select
  'f2fd0000-0000-0000-0000-000000000720'::uuid,
  ctx.shipment_id,
  'P2F_ACTIVE_DISPUTE_HOLD',
  'DISPUTE',
  'f2fd0000-0000-0000-0000-000000000742'::uuid,
  'ACTIVE',
  25,
  'CAD',
  'P2F protected active financial hold reason',
  clock_timestamp()
from p2f_acceptance_dispute_context ctx;


insert into haulvia.financial_holds (
  id,
  shipment_id,
  hold_code,
  source_type,
  source_id,
  status,
  amount,
  currency,
  reason,
  opened_at
)
select
  'f2fd0000-0000-0000-0000-000000000721'::uuid,
  ctx.shipment_id,
  'P2F_RELEASED_DISPUTE_HOLD',
  'DISPUTE',
  'f2fd0000-0000-0000-0000-000000000744'::uuid,
  'ACTIVE',
  15,
  'CAD',
  'P2F protected historical financial hold reason',
  clock_timestamp() - interval '15 minutes'
from p2f_acceptance_dispute_context ctx;


update haulvia.financial_holds
set
  status =
    'RELEASED',

  released_at =
    clock_timestamp() - interval '5 minutes',

  released_by_profile_id =
    'f2fc0000-0000-0000-0000-000000000011'::uuid,

  release_reason =
    'P2F permanent dispute released-hold fixture'

where id =
  'f2fd0000-0000-0000-0000-000000000721'::uuid;


-- ============================================================================
-- Workflow movement holds
--
-- 730 remains ACTIVE.
-- 731 is inserted ACTIVE and then transitioned canonically to RELEASED.
-- ============================================================================

insert into haulvia.workflow_holds (
  id,
  shipment_id,
  hold_code,
  status,
  blocks_marketplace,
  blocks_route_movement,
  blocks_completion,
  reason,
  opened_by_profile_id,
  opened_at
)
select
  'f2fd0000-0000-0000-0000-000000000730'::uuid,
  ctx.shipment_id,
  'P2F_ACTIVE_DISPUTE_ROUTE_HOLD',
  'ACTIVE',
  false,
  true,
  true,
  'P2F protected active workflow-hold reason',
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  clock_timestamp()
from p2f_acceptance_dispute_context ctx;


insert into haulvia.workflow_holds (
  id,
  shipment_id,
  hold_code,
  status,
  blocks_marketplace,
  blocks_route_movement,
  blocks_completion,
  reason,
  opened_by_profile_id,
  opened_at
)
select
  'f2fd0000-0000-0000-0000-000000000731'::uuid,
  ctx.shipment_id,
  'P2F_RELEASED_DISPUTE_ROUTE_HOLD',
  'ACTIVE',
  false,
  true,
  true,
  'P2F protected historical workflow-hold reason',
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  clock_timestamp() - interval '15 minutes'
from p2f_acceptance_dispute_context ctx;


update haulvia.workflow_holds
set
  status =
    'RELEASED',

  released_at =
    clock_timestamp() - interval '5 minutes',

  released_by_profile_id =
    'f2fc0000-0000-0000-0000-000000000011'::uuid,

  release_reason =
    'P2F permanent dispute released workflow-hold fixture'

where id =
  'f2fd0000-0000-0000-0000-000000000731'::uuid;


-- ============================================================================
-- Canonical dispute fixtures
--
-- 741 OPEN                  fresh, no controls
-- 742 UNDER_REVIEW          fresh, ACTIVE movement + financial holds
-- 743 EVIDENCE_COLLECTION   old; stale only after threshold publication
-- 744 OPEN                  fresh, historical control + RELEASED holds
-- 745 RESOLVED              terminal exclusion
-- 746 CLOSED                terminal exclusion
-- ============================================================================

insert into haulvia.disputes (
  id,
  shipment_id,
  opened_by_profile_id,
  category_code,
  status,
  description,
  disputed_amount,
  currency,
  financial_hold_id,
  opened_at,
  created_at,
  updated_at
)
select
  'f2fd0000-0000-0000-0000-000000000741'::uuid,
  ctx.shipment_id,
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  'P2F_SIMPLE_OPEN',
  'OPEN'::haulvia.dispute_status,
  'P2F protected simple dispute description',
  10,
  'CAD',
  null,
  clock_timestamp(),
  clock_timestamp(),
  clock_timestamp()
from p2f_acceptance_dispute_context ctx

union all

select
  'f2fd0000-0000-0000-0000-000000000742'::uuid,
  ctx.shipment_id,
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  'P2F_ACTIVE_BLOCK',
  'UNDER_REVIEW'::haulvia.dispute_status,
  'P2F protected blocking dispute description',
  25,
  'CAD',
  'f2fd0000-0000-0000-0000-000000000720'::uuid,
  clock_timestamp(),
  clock_timestamp(),
  clock_timestamp()
from p2f_acceptance_dispute_context ctx

union all

select
  'f2fd0000-0000-0000-0000-000000000743'::uuid,
  ctx.shipment_id,
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  'P2F_OLD_OPEN',
  'EVIDENCE_COLLECTION'::haulvia.dispute_status,
  'P2F protected old dispute description',
  30,
  'CAD',
  null,
  clock_timestamp() - interval '3 hours',
  clock_timestamp() - interval '3 hours',
  clock_timestamp() - interval '3 hours'
from p2f_acceptance_dispute_context ctx

union all

select
  'f2fd0000-0000-0000-0000-000000000744'::uuid,
  ctx.shipment_id,
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  'P2F_RELEASED_BLOCK',
  'OPEN'::haulvia.dispute_status,
  'P2F protected released-control dispute description',
  15,
  'CAD',
  'f2fd0000-0000-0000-0000-000000000721'::uuid,
  clock_timestamp(),
  clock_timestamp(),
  clock_timestamp()
from p2f_acceptance_dispute_context ctx;


insert into haulvia.disputes (
  id,
  shipment_id,
  opened_by_profile_id,
  category_code,
  status,
  description,
  disputed_amount,
  currency,
  resolution_code,
  resolution_summary,
  resolved_by_profile_id,
  opened_at,
  resolved_at,
  created_at,
  updated_at
)
select
  'f2fd0000-0000-0000-0000-000000000745'::uuid,
  ctx.shipment_id,
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  'P2F_RESOLVED',
  'RESOLVED'::haulvia.dispute_status,
  'P2F protected resolved dispute description',
  5,
  'CAD',
  'NO_MONETARY_CHANGE',
  'P2F resolved dispute fixture summary',
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour',
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour'
from p2f_acceptance_dispute_context ctx

union all

select
  'f2fd0000-0000-0000-0000-000000000746'::uuid,
  ctx.shipment_id,
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  'P2F_CLOSED',
  'CLOSED'::haulvia.dispute_status,
  'P2F protected closed dispute description',
  5,
  'CAD',
  'NO_MONETARY_CHANGE',
  'P2F closed dispute fixture summary',
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour',
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour'
from p2f_acceptance_dispute_context ctx;


-- ============================================================================
-- Operational controls
-- ============================================================================

insert into haulvia.dispute_operational_controls (
  id,
  shipment_id,
  dispute_id,
  workflow_hold_id,
  blocks_route_movement,
  control_snapshot,
  created_by_profile_id,
  created_at,
  idempotency_key
)
select
  'f2fd0000-0000-0000-0000-000000000750'::uuid,
  ctx.shipment_id,
  'f2fd0000-0000-0000-0000-000000000742'::uuid,
  'f2fd0000-0000-0000-0000-000000000730'::uuid,
  true,
  jsonb_build_object(
    'protectedControl',
    'active-movement-block'
  ),
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  clock_timestamp(),
  'p2f-acceptance-dispute-control-active'
from p2f_acceptance_dispute_context ctx

union all

select
  'f2fd0000-0000-0000-0000-000000000751'::uuid,
  ctx.shipment_id,
  'f2fd0000-0000-0000-0000-000000000744'::uuid,
  'f2fd0000-0000-0000-0000-000000000731'::uuid,
  true,
  jsonb_build_object(
    'protectedControl',
    'historical-released-block'
  ),
  'f2fc0000-0000-0000-0000-000000000011'::uuid,
  clock_timestamp(),
  'p2f-acceptance-dispute-control-released'
from p2f_acceptance_dispute_context ctx;


-- ============================================================================
-- D02. All nonterminal disputes receive DISPUTE_OPEN
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D02',

  'All four nonterminal disputes receive DISPUTE_OPEN',

  (
    select count(*)
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id in (
      'f2fd0000-0000-0000-0000-000000000741'::uuid,
      'f2fd0000-0000-0000-0000-000000000742'::uuid,
      'f2fd0000-0000-0000-0000-000000000743'::uuid,
      'f2fd0000-0000-0000-0000-000000000744'::uuid
    )

      and q.attention_code =
        'DISPUTE_OPEN'
  ) = 4,

  'Expected OPEN, UNDER_REVIEW and EVIDENCE_COLLECTION disputes to remain nonterminal.'
);


-- ============================================================================
-- D03. Terminal disputes excluded
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D03',

  'RESOLVED and CLOSED disputes are excluded',

  not exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id in (
      'f2fd0000-0000-0000-0000-000000000745'::uuid,
      'f2fd0000-0000-0000-0000-000000000746'::uuid
    )
  ),

  'Terminal dispute appeared in operational attention.'
);


-- ============================================================================
-- D04. Current movement block requires ACTIVE linked workflow hold
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D04',

  'Active linked movement hold produces DISPUTE_BLOCKING_MOVEMENT',

  exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000742'::uuid

      and q.attention_code =
        'DISPUTE_BLOCKING_MOVEMENT'

      and q.route_movement_blocked
  ),

  'Current movement-blocking dispute was not classified correctly.'
);


-- ============================================================================
-- D05. Current financial hold is exposed only as a safe boolean
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D05',

  'Active dispute financial hold is represented as financial_hold_active',

  exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000742'::uuid

      and q.attention_code =
        'DISPUTE_OPEN'

      and q.financial_hold_active
  ),

  'Active financial-hold state was not represented correctly.'
);


-- ============================================================================
-- D06. Released holds are historical, not active
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D06',

  'Released workflow and financial holds do not remain operationally active',

  exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000744'::uuid

      and q.attention_code =
        'DISPUTE_OPEN'

      and not q.route_movement_blocked

      and not q.financial_hold_active
  )

  and

  not exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000744'::uuid

      and q.attention_code =
        'DISPUTE_BLOCKING_MOVEMENT'
  ),

  'Released historical hold still appears operationally active.'
);


-- ============================================================================
-- D07. Exact pre-threshold cardinality
--
-- Four OPEN rows + one current BLOCKING row = five.
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D07',

  'Pre-threshold dispute attention cardinality is exact',

  (
    select count(*)
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id in (
      'f2fd0000-0000-0000-0000-000000000741'::uuid,
      'f2fd0000-0000-0000-0000-000000000742'::uuid,
      'f2fd0000-0000-0000-0000-000000000743'::uuid,
      'f2fd0000-0000-0000-0000-000000000744'::uuid,
      'f2fd0000-0000-0000-0000-000000000745'::uuid,
      'f2fd0000-0000-0000-0000-000000000746'::uuid
    )
  ) = 5,

  'Expected exactly four OPEN rows plus one current movement-block row before threshold configuration.'
);


-- ============================================================================
-- Publish transaction-local stale-open threshold
-- ============================================================================

insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  953001,
  'APPROVED',
  '3600'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        ('3600'::jsonb)::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fc0000-0000-0000-0000-000000000013'::uuid,
  'f2fc0000-0000-0000-0000-000000000014'::uuid,
  'P2F permanent dispute stale-open threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_DISPUTE_OPEN_STALE_SECONDS';


-- ============================================================================
-- D08. Exact threshold resolution
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D08',

  'Dispute stale-open threshold resolves exactly',

  haulvia.resolve_observability_positive_integer(
    'OBS_DISPUTE_OPEN_STALE_SECONDS'
  ) = 3600,

  'Expected transaction-local dispute stale threshold of 3600 seconds.'
);


-- ============================================================================
-- D09. Old nonterminal dispute becomes stale
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D09',

  'Old nonterminal dispute receives DISPUTE_STALE_OPEN',

  exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000743'::uuid

      and q.attention_code =
        'DISPUTE_STALE_OPEN'

      and q.canonical_dispute_status =
        'EVIDENCE_COLLECTION'

      and q.threshold_seconds =
        3600

      and q.age_seconds >=
        3600
  ),

  'Old EVIDENCE_COLLECTION dispute did not become stale.'
);


-- ============================================================================
-- D10. Fresh nonterminal disputes do not become stale
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D10',

  'Fresh nonterminal disputes remain outside stale-open attention',

  not exists (
    select 1
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id in (
      'f2fd0000-0000-0000-0000-000000000741'::uuid,
      'f2fd0000-0000-0000-0000-000000000742'::uuid,
      'f2fd0000-0000-0000-0000-000000000744'::uuid
    )

      and q.attention_code =
        'DISPUTE_STALE_OPEN'
  ),

  'Fresh dispute was classified stale prematurely.'
);


-- ============================================================================
-- D11. OPEN and BLOCKING_MOVEMENT coexist
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D11',

  'DISPUTE_OPEN and DISPUTE_BLOCKING_MOVEMENT coexist for one dispute',

  (
    select count(*)
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000742'::uuid

      and q.attention_code in (
        'DISPUTE_OPEN',
        'DISPUTE_BLOCKING_MOVEMENT'
      )
  ) = 2,

  'OPEN and BLOCKING_MOVEMENT were not represented as orthogonal attention codes.'
);


-- ============================================================================
-- D12. OPEN and STALE_OPEN coexist
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D12',

  'DISPUTE_OPEN and DISPUTE_STALE_OPEN coexist for one dispute',

  (
    select count(*)
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id =
        'f2fd0000-0000-0000-0000-000000000743'::uuid

      and q.attention_code in (
        'DISPUTE_OPEN',
        'DISPUTE_STALE_OPEN'
      )
  ) = 2,

  'OPEN and STALE_OPEN were not represented as orthogonal attention codes.'
);


-- ============================================================================
-- D13. Exact post-threshold cardinality
--
-- Four OPEN + one BLOCKING + one STALE = six.
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D13',

  'Post-threshold dispute attention cardinality is exact',

  (
    select count(*)
    from haulvia.v_dispute_attention_queue q
    where q.dispute_id in (
      'f2fd0000-0000-0000-0000-000000000741'::uuid,
      'f2fd0000-0000-0000-0000-000000000742'::uuid,
      'f2fd0000-0000-0000-0000-000000000743'::uuid,
      'f2fd0000-0000-0000-0000-000000000744'::uuid,
      'f2fd0000-0000-0000-0000-000000000745'::uuid,
      'f2fd0000-0000-0000-0000-000000000746'::uuid
    )
  ) = 6,

  'Expected exactly six dispute attention rows after threshold publication.'
);


-- ============================================================================
-- D14. Raw dispute/hold/control material remains excluded
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-D14',

  'Dispute attention projection excludes protected raw dispute hold and control fields',

  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name =
        'v_dispute_attention_queue'

      and c.column_name in (
        'description',
        'resolution_code',
        'resolution_summary',
        'control_snapshot',
        'idempotency_key',
        'reason',
        'release_reason',
        'financial_allocation',
        'next_route_action',
        'evidence_decision'
      )
  ),

  'Protected dispute, hold, control or resolution material is exposed by the ordinary attention queue.'
);


-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-D-END
-- ============================================================================



-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-E-BEGIN
--
-- Permanent compliance-attention acceptance.
--
-- Canonical blocker truth must continue to come from
-- haulvia.v_compliance_blockers.
-- ============================================================================


-- ============================================================================
-- Dedicated compliance subject
-- ============================================================================

insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'f2fe0000-0000-0000-0000-000000000601'::uuid,
    'P2F compliance driver'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000603'::uuid,
    'P2F compliance config creator'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000604'::uuid,
    'P2F compliance config approver'
  );


insert into haulvia.drivers (
  id,
  profile_id,
  status,
  public_label
)
values (
  'f2fe0000-0000-0000-0000-000000000610'::uuid,
  'f2fe0000-0000-0000-0000-000000000601'::uuid,
  'ACTIVE',
  'P2F Compliance Driver'
);


insert into haulvia.compliance_subjects (
  id,
  subject_kind,
  driver_id
)
values (
  'f2fe0000-0000-0000-0000-000000000611'::uuid,
  'DRIVER',
  'f2fe0000-0000-0000-0000-000000000610'::uuid
);


-- ============================================================================
-- Ten compliance fixtures
--
-- 621 required CLAIMED, +5 days       -> blocker + expiring
-- 622 required VERIFIED, +5 days      -> expiring only
-- 623 required VERIFIED, today        -> expiring only
-- 624 required VERIFIED, +31 days     -> no attention
-- 625 required CLAIMED, yesterday     -> blocker only
-- 626 ARCHIVED required CLAIMED +5    -> no attention
-- 627 NOT_APPLICABLE optional +5      -> no attention
-- 628 APPLICABLE optional +5          -> no attention
-- 629 required CLAIMED, no expiry     -> blocker only
-- 630 required VERIFIED, +30 days     -> expiring only
-- ============================================================================

insert into haulvia.compliance_items (
  id,
  subject_id,
  item_category,
  compliance_code,
  compliance_name,
  expiry_date,
  review_status,
  applicability,
  is_required,
  notes,
  status
)
values
  (
    'f2fe0000-0000-0000-0000-000000000621'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_OVERLAP',
    'P2F Block E overlap item',
    current_date + 5,
    'CLAIMED',
    'APPLICABLE',
    true,
    'Protected overlap compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000622'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_VERIFIED_NEAR',
    'P2F Block E verified near-expiry item',
    current_date + 5,
    'VERIFIED',
    'APPLICABLE',
    true,
    'Protected verified-near compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000623'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_EXPIRES_TODAY',
    'P2F Block E expires-today item',
    current_date,
    'VERIFIED',
    'APPLICABLE',
    true,
    'Protected current-date compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000624'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_BEYOND_WINDOW',
    'P2F Block E beyond-window item',
    current_date + 31,
    'VERIFIED',
    'APPLICABLE',
    true,
    'Protected beyond-window compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000625'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_PAST_EXPIRY',
    'P2F Block E past-expiry item',
    current_date - 1,
    'CLAIMED',
    'APPLICABLE',
    true,
    'Protected past-expiry compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000626'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_ARCHIVED',
    'P2F Block E archived item',
    current_date + 5,
    'CLAIMED',
    'APPLICABLE',
    true,
    'Protected archived compliance note',
    'ARCHIVED'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000627'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_NOT_APPLICABLE',
    'P2F Block E non-applicable item',
    current_date + 5,
    'CLAIMED',
    'NOT_APPLICABLE',
    false,
    'Protected non-applicable compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000628'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_OPTIONAL',
    'P2F Block E optional item',
    current_date + 5,
    'CLAIMED',
    'APPLICABLE',
    false,
    'Protected optional compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000629'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_NO_EXPIRY',
    'P2F Block E no-expiry item',
    null,
    'CLAIMED',
    'APPLICABLE',
    true,
    'Protected no-expiry compliance note',
    'ACTIVE'
  ),
  (
    'f2fe0000-0000-0000-0000-000000000630'::uuid,
    'f2fe0000-0000-0000-0000-000000000611'::uuid,
    'SAFETY',
    'P2F_E_UPPER_BOUNDARY',
    'P2F Block E upper-boundary item',
    current_date + 30,
    'VERIFIED',
    'APPLICABLE',
    true,
    'Protected upper-boundary compliance note',
    'ACTIVE'
  );


-- ============================================================================
-- E01. Missing threshold
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E01',

  'Missing compliance expiry-warning threshold resolves NULL',

  haulvia.resolve_observability_positive_integer(
    'OBS_COMPLIANCE_EXPIRY_WARNING_DAYS'
  ) is null,

  'Compliance expiry-warning threshold should be NULL before transaction-local publication.'
);


-- ============================================================================
-- E02. Blocker branch exactly reuses canonical blocker set
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E02',

  'Compliance blocker queue set exactly matches canonical v_compliance_blockers',

  not exists (
    (
      select cb.compliance_item_id
      from haulvia.v_compliance_blockers cb
      where cb.subject_id =
        'f2fe0000-0000-0000-0000-000000000611'::uuid

      except

      select q.compliance_item_id
      from haulvia.v_compliance_attention_queue q
      where q.compliance_subject_id =
          'f2fe0000-0000-0000-0000-000000000611'::uuid

        and q.attention_code =
          'COMPLIANCE_BLOCKER'
    )

    union all

    (
      select q.compliance_item_id
      from haulvia.v_compliance_attention_queue q
      where q.compliance_subject_id =
          'f2fe0000-0000-0000-0000-000000000611'::uuid

        and q.attention_code =
          'COMPLIANCE_BLOCKER'

      except

      select cb.compliance_item_id
      from haulvia.v_compliance_blockers cb
      where cb.subject_id =
        'f2fe0000-0000-0000-0000-000000000611'::uuid
    )
  ),

  'P2F compliance blocker branch diverges from canonical blocker truth.'
);


-- ============================================================================
-- E03. Missing threshold suppresses expiry warnings
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E03',

  'Missing warning configuration suppresses every COMPLIANCE_EXPIRING row',

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_subject_id =
        'f2fe0000-0000-0000-0000-000000000611'::uuid

      and q.attention_code =
        'COMPLIANCE_EXPIRING'
  ),

  'COMPLIANCE_EXPIRING appeared without effective warning configuration.'
);


-- ============================================================================
-- E04. Safe blocker projection
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E04',

  'Compliance blocker projects safe subject and item fields correctly',

  exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000621'::uuid

      and q.attention_code =
        'COMPLIANCE_BLOCKER'

      and q.subject_kind =
        'DRIVER'

      and q.compliance_code =
        'P2F_E_OVERLAP'

      and q.compliance_name =
        'P2F Block E overlap item'

      and q.review_status =
        'CLAIMED'

      and q.expiry_date =
        current_date + 5

      and q.days_until_expiry =
        5

      and q.threshold_days
        is null
  ),

  'Safe blocker projection fields are incorrect.'
);


-- ============================================================================
-- Publish transaction-local 30-day warning window
-- ============================================================================

insert into haulvia.platform_config_versions (
  config_definition_id,
  version_no,
  publication_status,
  config_value,
  value_sha256,
  effective_from,
  created_by_profile_id,
  approved_by_profile_id,
  approval_reason,
  approved_at
)
select
  d.id,
  954001,
  'APPROVED',
  '30'::jsonb,
  pg_catalog.encode(
    pg_catalog.sha256(
      pg_catalog.convert_to(
        ('30'::jsonb)::text,
        'UTF8'
      )
    ),
    'hex'
  ),
  clock_timestamp() - interval '1 hour',
  'f2fe0000-0000-0000-0000-000000000603'::uuid,
  'f2fe0000-0000-0000-0000-000000000604'::uuid,
  'P2F permanent compliance expiry-warning threshold',
  clock_timestamp()
from haulvia.platform_config_definitions d
where d.config_key =
  'OBS_COMPLIANCE_EXPIRY_WARNING_DAYS';


-- ============================================================================
-- E05. Threshold resolves exactly
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E05',

  'Compliance expiry-warning threshold resolves exactly',

  haulvia.resolve_observability_positive_integer(
    'OBS_COMPLIANCE_EXPIRY_WARNING_DAYS'
  ) = 30,

  'Expected transaction-local compliance warning window of 30 days.'
);


-- ============================================================================
-- E06. Verified near-expiry warning without blocker
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E06',

  'Verified near-expiry item warns without becoming a blocker',

  exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000622'::uuid

      and q.attention_code =
        'COMPLIANCE_EXPIRING'

      and q.review_status =
        'VERIFIED'

      and q.days_until_expiry =
        5

      and q.threshold_days =
        30
  )

  and

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000622'::uuid

      and q.attention_code =
        'COMPLIANCE_BLOCKER'
  ),

  'Verified near-expiry item was not classified correctly.'
);


-- ============================================================================
-- E07. Current-date lower boundary
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E07',

  'Expiry equal to current_date is inside compliance warning window',

  exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000623'::uuid

      and q.attention_code =
        'COMPLIANCE_EXPIRING'

      and q.days_until_expiry =
        0

      and q.threshold_days =
        30
  ),

  'Current-date expiry was excluded from warning attention.'
);


-- ============================================================================
-- E08. Configured upper boundary is inclusive
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E08',

  'Expiry exactly at configured upper warning boundary is included',

  exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000630'::uuid

      and q.attention_code =
        'COMPLIANCE_EXPIRING'

      and q.days_until_expiry =
        30

      and q.threshold_days =
        30
  ),

  'Configured compliance warning upper boundary was not inclusive.'
);


-- ============================================================================
-- E09. Beyond-window exclusion
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E09',

  'Expiry beyond configured warning window is excluded',

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
      'f2fe0000-0000-0000-0000-000000000624'::uuid
  ),

  'Beyond-window verified compliance item appeared in attention.'
);


-- ============================================================================
-- E10. Past expiry is blocker only
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E10',

  'Past-expiry unresolved required item remains blocker but is not mislabeled expiring',

  exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000625'::uuid

      and q.attention_code =
        'COMPLIANCE_BLOCKER'

      and q.days_until_expiry =
        -1
  )

  and

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000625'::uuid

      and q.attention_code =
        'COMPLIANCE_EXPIRING'
  ),

  'Past-expiry compliance semantics are incorrect.'
);


-- ============================================================================
-- E11. Archived exclusion
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E11',

  'Archived compliance item is excluded from both attention classifications',

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
      'f2fe0000-0000-0000-0000-000000000626'::uuid
  ),

  'Archived compliance item appeared in operational attention.'
);


-- ============================================================================
-- E12. Non-applicable and optional exclusions
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E12',

  'Non-applicable and optional compliance items remain outside attention',

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id in (
      'f2fe0000-0000-0000-0000-000000000627'::uuid,
      'f2fe0000-0000-0000-0000-000000000628'::uuid
    )
  ),

  'Non-applicable or optional compliance item appeared in attention.'
);


-- ============================================================================
-- E13. No-expiry required blocker
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E13',

  'Required unresolved item without expiry remains blocker only',

  exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000629'::uuid

      and q.attention_code =
        'COMPLIANCE_BLOCKER'

      and q.expiry_date
        is null

      and q.days_until_expiry
        is null

      and q.threshold_days
        is null
  )

  and

  not exists (
    select 1
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000629'::uuid

      and q.attention_code =
        'COMPLIANCE_EXPIRING'
  ),

  'No-expiry unresolved required compliance item is classified incorrectly.'
);


-- ============================================================================
-- E14. Orthogonal blocker + expiring attention
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E14',

  'COMPLIANCE_BLOCKER and COMPLIANCE_EXPIRING coexist when both facts are true',

  (
    select count(*)
    from haulvia.v_compliance_attention_queue q
    where q.compliance_item_id =
        'f2fe0000-0000-0000-0000-000000000621'::uuid

      and q.attention_code in (
        'COMPLIANCE_BLOCKER',
        'COMPLIANCE_EXPIRING'
      )
  ) = 2,

  'Overlap compliance item did not expose both independent attention codes.'
);


-- ============================================================================
-- E15. Exact cardinality and privacy boundary
--
-- Blockers: 621, 625, 629 = 3
-- Expiring: 621, 622, 623, 630 = 4
-- Total = 7
-- ============================================================================

select pg_temp.record_requirement(
  'P2F-E15',

  'Compliance fixture cardinality is seven and projection excludes sensitive compliance fields',

  (
    select count(*)
    from haulvia.v_compliance_attention_queue q
    where q.compliance_subject_id =
      'f2fe0000-0000-0000-0000-000000000611'::uuid
  ) = 7

  and

  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema =
        'haulvia'

      and c.table_name =
        'v_compliance_attention_queue'

      and c.column_name in (
        'holder_name',
        'credential_number',
        'issuing_authority',
        'notes',
        'review_action_note',
        'reviewer_label',
        'reviewer_profile_id',
        'file_name',
        'storage_object_key',
        'content_sha256',
        'applicability_rules',
        'evidence_requirements',
        'item_metadata'
      )
  ),

  'Compliance attention cardinality or sensitive-field minimization is incorrect.'
);


-- ============================================================================
-- P2F-ACCEPTANCE-BLOCK-E-END
-- ============================================================================

-- P2F-ACCEPTANCE-FINALIZATION-BEGIN

\echo
\echo ================ P2F ACCEPTANCE BLOCK A+B+C+D+E RESULTS ================
\echo

select
  requirement_id,
  test_name,
  passed,
  detail
from p2f_acceptance_results
order by requirement_id;


\echo
\echo ================ P2F ACCEPTANCE BLOCK A+B+C+D+E SUMMARY ================
\echo

select
  count(*)
    as total_tests,

  count(*) filter (
    where passed
  )
    as passed_tests,

  count(*) filter (
    where not passed
  )
    as failed_tests

from p2f_acceptance_results;


do $$
declare
  v_total integer;
  v_passed integer;
  v_failed integer;
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
    v_total,
    v_passed,
    v_failed
  from p2f_acceptance_results;


  if
    v_total <> 71
    or v_passed <> 71
    or v_failed <> 0
  then
    raise exception
      'P2F acceptance Block A+B+C+D+E failed: total=% passed=% failed=%',
      v_total,
      v_passed,
      v_failed;
  end if;
end;
$$;


\echo
\echo P2F_ACCEPTANCE_BLOCK_A_B_C_D_E_PASSED
\echo

rollback;

-- P2F-ACCEPTANCE-FINALIZATION-END
