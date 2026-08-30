-- Haulvia Block B command layer v1
-- Approved source: State Transition Matrix v1.1, Block B (B01-B12)
-- Depends on: foundation v1 and Block A command migration v1
-- Target: PostgreSQL 16; compatible with Supabase Postgres
-- Security boundary: trusted service role only; end-user RLS remains deferred.

begin;

set local search_path = haulvia, haulvia_command, public;

-- Block B adds current execution position to the retained route execution.
-- Route updates and stop-attempt events remain the append-only position history.
alter table haulvia.route_executions
  add column active_stop_execution_id uuid,
  add column active_route_leg_id uuid,
  add column next_action text,
  add column record_version bigint not null default 0,
  add constraint route_executions_record_version_ck check (record_version >= 0),
  add constraint route_executions_active_stop_fk
    foreign key (active_stop_execution_id, id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  add constraint route_executions_active_leg_fk
    foreign key (route_version_id, active_route_leg_id)
    references haulvia.route_legs(route_version_id, id);

alter table haulvia.route_exceptions
  add column metadata jsonb not null default '{}'::jsonb;

alter table haulvia.workflow_holds
  add column metadata jsonb not null default '{}'::jsonb;

drop index haulvia.route_executions_one_moving_uq;
create unique index route_executions_one_current_uq
  on haulvia.route_executions (shipment_id)
  where state in ('NOT_STARTED', 'ACTIVE', 'HELD', 'RECOVERY_ACTIVE');

create unique index tracking_sessions_one_active_uq
  on haulvia.tracking_sessions (route_execution_id)
  where ended_at is null;

-- The first verified LOAD is an immutable operational boundary. It provides a
-- direct cancellation guard while the cargo movement ledger remains authority
-- for quantities and current onboard balance.
create table haulvia.shipment_custody_milestones (
  shipment_id uuid primary key references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  first_stop_execution_id uuid not null references haulvia.stop_executions(id),
  first_cargo_movement_id uuid not null unique references haulvia.cargo_movements(id),
  first_custody_at timestamptz not null,
  recorded_at timestamptz not null default clock_timestamp(),
  metadata jsonb not null default '{}'::jsonb
);

-- This is the immutable, versioned financial decision. Provider settlement is
-- dispatched through workflow_jobs and can complete on its own payment axis.
create table haulvia.pre_custody_financial_decisions (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  assignment_id uuid not null references haulvia.assignments(id),
  route_execution_id uuid references haulvia.route_executions(id),
  policy_version_id uuid not null references haulvia.policy_versions(id),
  command_name text not null check (
    command_name in ('cancelBeforeAnyCustody', 'releaseDriverBeforeAnyCustody')
  ),
  responsibility_code text not null,
  cancellation_charge_amount numeric(14,2) not null default 0,
  customer_refund_amount numeric(14,2) not null default 0,
  driver_compensation_amount numeric(14,2) not null default 0,
  currency char(3) not null,
  reason text not null,
  decision_snapshot jsonb not null,
  requested_by_profile_id uuid references haulvia.profiles(id),
  requested_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, command_name, idempotency_key),
  check (cancellation_charge_amount >= 0),
  check (customer_refund_amount >= 0),
  check (driver_compensation_amount >= 0),
  check (driver_compensation_amount <= cancellation_charge_amount),
  check (currency ~ '^[A-Z]{3}$'),
  check (length(btrim(reason)) >= 3),
  check (decision_snapshot <> '{}'::jsonb)
);

create trigger shipment_custody_milestones_append_only
before update or delete on haulvia.shipment_custody_milestones
for each row execute function haulvia.reject_append_only_mutation();

create trigger pre_custody_financial_decisions_append_only
before update or delete on haulvia.pre_custody_financial_decisions
for each row execute function haulvia.reject_append_only_mutation();

insert into haulvia.permissions (permission_key, description, is_sensitive) values
  ('ROUTE_OPERATIONS_MANAGE', 'Correct stop execution and manage pre-custody route exceptions', false),
  ('STOP_EVIDENCE_REVIEW', 'Review and verify stop evidence and custody movements', false)
on conflict (permission_key) do nothing;

-- Block B terminal/release paths can close a nonterminal stop before custody.
insert into haulvia.stop_state_transition_rules (from_state, to_state, command_name) values
  ('EN_ROUTE', 'CANCELLED', 'cancelBeforeAnyCustody'),
  ('ARRIVED', 'CANCELLED', 'cancelBeforeAnyCustody'),
  ('SERVICE_IN_PROGRESS', 'CANCELLED', 'cancelBeforeAnyCustody'),
  ('EVIDENCE_PENDING', 'CANCELLED', 'cancelBeforeAnyCustody'),
  ('EN_ROUTE', 'CANCELLED', 'releaseDriverBeforeAnyCustody'),
  ('ARRIVED', 'CANCELLED', 'releaseDriverBeforeAnyCustody'),
  ('SERVICE_IN_PROGRESS', 'CANCELLED', 'releaseDriverBeforeAnyCustody'),
  ('EVIDENCE_PENDING', 'CANCELLED', 'releaseDriverBeforeAnyCustody')
on conflict do nothing;

insert into haulvia.shipment_state_transition_rules (
  from_state, to_state, command_name, requires_zero_custody
) values
  ('DRIVER_ASSIGNED', 'POSTED', 'releaseDriverBeforeAnyCustody', true),
  ('DRIVER_ASSIGNED', 'EXPIRED', 'releaseDriverBeforeAnyCustody', true),
  ('ROUTE_IN_PROGRESS', 'POSTED', 'releaseDriverBeforeAnyCustody', true),
  ('ROUTE_IN_PROGRESS', 'EXPIRED', 'releaseDriverBeforeAnyCustody', true)
on conflict do nothing;

-- Keep the original view column order and append Block B position/custody data.
create or replace view haulvia.v_shipment_operating_context as
select
  s.id as shipment_id,
  s.shipment_reference,
  s.shipment_state,
  ma.state as marketplace_state,
  pa.state as customer_payment_state,
  pa.secured_amount,
  po.state as driver_payout_state,
  da.state as dispute_state,
  rv.id as active_route_version_id,
  rv.version_no as active_route_version_no,
  a.id as active_assignment_id,
  re.id as active_route_execution_id,
  re.state as route_execution_state,
  s.lock_version,
  re.active_stop_execution_id,
  re.active_route_leg_id,
  re.next_action,
  re.record_version as route_execution_record_version,
  coalesce(custody.summary, '{}'::jsonb) as custody_summary
from haulvia.shipments s
left join haulvia.shipment_marketplace_axes ma on ma.shipment_id = s.id
left join haulvia.shipment_customer_payment_axes pa on pa.shipment_id = s.id
left join haulvia.shipment_driver_payout_axes po on po.shipment_id = s.id
left join haulvia.shipment_dispute_axes da on da.shipment_id = s.id
left join haulvia.route_versions rv on rv.shipment_id = s.id and rv.status = 'ACTIVE'
left join haulvia.assignments a on a.shipment_id = s.id and a.status = 'ACTIVE'
left join haulvia.route_executions re
  on re.shipment_id = s.id and re.state in ('ACTIVE', 'HELD', 'RECOVERY_ACTIVE')
left join lateral (
  select jsonb_build_object(
    'hasVerifiedCustody', exists (
      select 1 from haulvia.shipment_custody_milestones scm where scm.shipment_id = s.id
    ),
    'balances', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'stableCargoKey', cb.stable_cargo_key,
          'quantityUnit', cb.quantity_unit,
          'onboardQuantity', cb.onboard_quantity
        ) order by cb.stable_cargo_key, cb.quantity_unit
      ) filter (where cb.stable_cargo_key is not null),
      '[]'::jsonb
    )
  ) as summary
  from haulvia.v_cargo_custody_balance cb
  where cb.shipment_id = s.id
) custody on true;

-- ---------------------------------------------------------------------------
-- Block B request, authority, execution, evidence, and custody helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.required_boolean(p_request jsonb, p_key text)
returns boolean
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_value jsonb;
begin
  v_value := p_request -> p_key;
  if v_value is null or jsonb_typeof(v_value) <> 'boolean' then
    perform haulvia_command.fail(
      'INVALID_REQUEST', format('Required request field %s must be boolean', p_key),
      jsonb_build_object('field', p_key)
    );
  end if;
  return (v_value::text)::boolean;
end;
$$;

create or replace function haulvia_command.optional_numeric(p_request jsonb, p_key text)
returns numeric
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_text text;
begin
  v_text := nullif(btrim(p_request ->> p_key), '');
  if v_text is null then
    return null;
  end if;
  return v_text::numeric;
exception when invalid_text_representation then
  perform haulvia_command.fail(
    'INVALID_REQUEST', format('Request field %s must be numeric', p_key),
    jsonb_build_object('field', p_key)
  );
  return null;
end;
$$;

create or replace function haulvia_command.lock_active_assignment(
  p_shipment_id uuid,
  p_request jsonb
)
returns haulvia.assignments
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_expected uuid := haulvia_command.required_uuid(p_request, 'expectedAssignmentId');
begin
  select * into v_assignment
  from haulvia.assignments a
  where a.id = v_expected
    and a.shipment_id = p_shipment_id
    and a.status = 'ACTIVE'
  for update;

  if not found then
    perform haulvia_command.fail(
      'ASSIGNMENT_NOT_ACTIVE', 'The expected whole-route assignment is not active',
      jsonb_build_object('assignmentId', v_expected)
    );
  end if;
  return v_assignment;
end;
$$;

create or replace function haulvia_command.authorize_assigned_driver(
  p_assignment haulvia.assignments,
  p_request jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
begin
  if not exists (
    select 1 from haulvia.drivers d
    where d.id = p_assignment.driver_id
      and d.profile_id = v_actor
      and d.status = 'ACTIVE'
  ) then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'Only the currently assigned driver may perform this action');
  end if;
end;
$$;

create or replace function haulvia_command.authorize_route_operator(
  p_assignment haulvia.assignments,
  p_request jsonb,
  p_allow_driver boolean default true
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
begin
  if v_actor is null then
    perform haulvia_command.assert_worker(
      v_actor, p_request ->> 'workerAuthority',
      array['ROUTE_OPERATIONS_WORKER', 'ELIGIBILITY_WORKER']
    );
    return;
  end if;

  if p_allow_driver and exists (
    select 1 from haulvia.drivers d
    where d.id = p_assignment.driver_id and d.profile_id = v_actor
  ) then
    return;
  end if;

  if v_org is null or not haulvia.has_permission(v_actor, v_org, 'ROUTE_OPERATIONS_MANAGE') then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'Assigned-driver or route-operations authority is required');
  end if;
end;
$$;

create or replace function haulvia_command.authorize_evidence_reviewer(p_request jsonb)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
begin
  if v_actor is null then
    perform haulvia_command.assert_worker(
      v_actor, p_request ->> 'workerAuthority', array['EVIDENCE_REVIEWER']
    );
  elsif v_org is null or not haulvia.has_permission(v_actor, v_org, 'STOP_EVIDENCE_REVIEW') then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'Authorized stop-evidence reviewer is required');
  end if;
end;
$$;

create or replace function haulvia_command.lock_route_execution(
  p_shipment_id uuid,
  p_assignment_id uuid,
  p_request jsonb
)
returns haulvia.route_executions
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_execution haulvia.route_executions%rowtype;
  v_execution_id uuid := haulvia_command.required_uuid(p_request, 'expectedRouteExecutionId');
  v_expected_version bigint;
begin
  begin
    v_expected_version := haulvia_command.required_text(
      p_request, 'expectedRouteExecutionVersion'
    )::bigint;
  exception when invalid_text_representation then
    perform haulvia_command.fail('INVALID_REQUEST', 'expectedRouteExecutionVersion must be an integer');
  end;

  select * into v_execution
  from haulvia.route_executions re
  where re.id = v_execution_id
    and re.shipment_id = p_shipment_id
    and re.assignment_id = p_assignment_id
  for update;

  if not found then
    perform haulvia_command.fail('ROUTE_EXECUTION_NOT_FOUND', 'The expected route execution was not found');
  end if;
  if v_execution.record_version <> v_expected_version then
    perform haulvia_command.fail(
      'STALE_ROUTE_EXECUTION_VERSION', 'The route execution changed after the request was prepared',
      jsonb_build_object('expected', v_expected_version, 'current', v_execution.record_version)
    );
  end if;
  return v_execution;
end;
$$;

create or replace function haulvia_command.lock_first_stop_execution(
  p_execution haulvia.route_executions,
  p_request jsonb
)
returns haulvia.stop_executions
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_stop haulvia.stop_executions%rowtype;
  v_stop_id uuid := haulvia_command.required_uuid(p_request, 'expectedStopExecutionId');
begin
  select se.* into v_stop
  from haulvia.stop_executions se
  join haulvia.route_stops rs
    on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
  where se.id = v_stop_id
    and se.route_execution_id = p_execution.id
    and rs.sequence_no = 1
    and rs.stop_type = 'PICKUP'
  for update of se;

  if not found then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'The expected first pickup stop is not current');
  end if;
  if p_execution.active_stop_execution_id is distinct from v_stop.id then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'The expected first pickup is not the active stop');
  end if;
  return v_stop;
end;
$$;

create or replace function haulvia_command.assert_no_verified_custody(p_shipment_id uuid)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if exists (
    select 1 from haulvia.shipment_custody_milestones scm
    where scm.shipment_id = p_shipment_id
  ) or exists (
    select 1 from haulvia.cargo_movements cm
    where cm.shipment_id = p_shipment_id and cm.movement_type = 'LOAD'
  ) then
    perform haulvia_command.fail(
      'CUSTODY_EXISTS',
      'Ordinary cancellation, release, repost, or pre-custody handling is unavailable after verified LOAD custody'
    );
  end if;
end;
$$;

create or replace function haulvia_command.append_stop_event(
  p_attempt_id uuid,
  p_stop_execution_id uuid,
  p_prior_state haulvia.stop_state,
  p_current_state haulvia.stop_state,
  p_command_name text,
  p_request jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
begin
  insert into haulvia.stop_attempt_events (
    stop_attempt_id, stop_execution_id, prior_state, current_state,
    command_name, actor_kind, actor_profile_id, reason, occurred_at,
    captured_at, synced_at, idempotency_key, metadata
  ) values (
    p_attempt_id, p_stop_execution_id, p_prior_state, p_current_state,
    p_command_name,
    case when v_actor is null then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    v_actor, nullif(p_request ->> 'reason', ''),
    coalesce(nullif(p_request ->> 'occurredAt', '')::timestamptz, clock_timestamp()),
    nullif(p_request ->> 'capturedAt', '')::timestamptz,
    nullif(p_request ->> 'syncedAt', '')::timestamptz,
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    coalesce(p_metadata, '{}'::jsonb)
  );
end;
$$;

create or replace function haulvia_command.distance_metres(
  p_latitude_a numeric,
  p_longitude_a numeric,
  p_latitude_b numeric,
  p_longitude_b numeric
)
returns numeric
language sql
immutable
strict
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select 6371000::numeric * 2 * asin(
    least(1::numeric, sqrt(
      power(sin(radians((p_latitude_b - p_latitude_a)::double precision) / 2), 2)
      + cos(radians(p_latitude_a::double precision))
        * cos(radians(p_latitude_b::double precision))
        * power(sin(radians((p_longitude_b - p_longitude_a)::double precision) / 2), 2)
    )::numeric)
  )::numeric;
$$;

create or replace function haulvia_command.insert_evidence_array(
  p_attempt_id uuid,
  p_request jsonb,
  p_array_key text default 'evidence'
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_item jsonb;
  v_index integer := 0;
  v_id uuid;
  v_ids jsonb := '[]'::jsonb;
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_items jsonb := p_request -> p_array_key;
begin
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
    perform haulvia_command.fail(
      'EVIDENCE_INVALID', format('%s must be a non-empty evidence array', p_array_key)
    );
  end if;

  for v_item in select value from jsonb_array_elements(v_items)
  loop
    v_index := v_index + 1;
    insert into haulvia.stop_evidence (
      stop_attempt_id, evidence_type, storage_object_key, content_sha256,
      structured_value, captured_at, captured_latitude, captured_longitude,
      captured_accuracy_m, submitted_by_profile_id, synced_at, idempotency_key
    ) values (
      p_attempt_id,
      haulvia_command.required_text(v_item, 'type')::haulvia.evidence_type,
      nullif(v_item ->> 'storageObjectKey', ''),
      nullif(v_item ->> 'contentSha256', ''),
      coalesce(v_item -> 'structuredValue', '{}'::jsonb),
      haulvia_command.required_timestamptz(v_item, 'capturedAt'),
      haulvia_command.optional_numeric(v_item, 'latitude'),
      haulvia_command.optional_numeric(v_item, 'longitude'),
      haulvia_command.optional_numeric(v_item, 'accuracyM'),
      v_actor,
      nullif(v_item ->> 'syncedAt', '')::timestamptz,
      coalesce(
        nullif(v_item ->> 'idempotencyKey', ''),
        haulvia_command.required_text(p_request, 'idempotencyKey') || ':evidence:' || v_index::text
      )
    ) returning id into v_id;
    v_ids := v_ids || jsonb_build_array(v_id);
  end loop;

  return jsonb_build_object('count', v_index, 'ids', v_ids);
exception
  when invalid_text_representation or invalid_datetime_format or datetime_field_overflow
    or not_null_violation or check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'EVIDENCE_INVALID', 'Evidence did not satisfy the approved immutable evidence contract',
      jsonb_build_object('databaseMessage', sqlerrm)
    );
  return null;
end;
$$;

create or replace function haulvia_command.assert_first_pickup_evidence(
  p_shipment_id uuid,
  p_route_version_id uuid,
  p_route_stop_id uuid,
  p_attempt_id uuid
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_rules jsonb := '{}'::jsonb;
  v_key text;
  v_value jsonb;
  v_type haulvia.evidence_type;
begin
  select
    coalesce(rs.verification_profile, '{}'::jsonb)
    || coalesce(srs.evidence_requirements, '{}'::jsonb)
    || coalesce(srs.evidence_requirements -> 'pickup', '{}'::jsonb)
    || coalesce(srs.evidence_requirements -> 'PICKUP', '{}'::jsonb)
  into v_rules
  from haulvia.route_stops rs
  left join haulvia.shipment_rule_snapshots srs
    on srs.shipment_id = p_shipment_id and srs.route_version_id = p_route_version_id
  where rs.id = p_route_stop_id and rs.route_version_id = p_route_version_id;

  if not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id = p_attempt_id and e.evidence_type = 'GPS'
  ) or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id = p_attempt_id and e.evidence_type = 'TIMESTAMP'
  ) or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id = p_attempt_id and e.evidence_type = 'PHOTO'
  ) or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id = p_attempt_id and e.evidence_type = 'QUANTITY'
  ) or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id = p_attempt_id and e.evidence_type = 'CONDITION'
  ) or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id = p_attempt_id and e.evidence_type in ('PIN', 'QR')
  ) then
    perform haulvia_command.fail(
      'EVIDENCE_INVALID',
      'First pickup requires GPS, timestamp, photo, quantity, condition, and PIN or QR evidence'
    );
  end if;

  for v_key, v_value in select key, value from jsonb_each(v_rules)
  loop
    if jsonb_typeof(v_value) = 'boolean' and v_value = 'true'::jsonb then
      v_type := case lower(v_key)
        when 'photo' then 'PHOTO'::haulvia.evidence_type
        when 'signature' then 'SIGNATURE'::haulvia.evidence_type
        when 'pin' then 'PIN'::haulvia.evidence_type
        when 'qr' then 'QR'::haulvia.evidence_type
        when 'gps' then 'GPS'::haulvia.evidence_type
        when 'timestamp' then 'TIMESTAMP'::haulvia.evidence_type
        when 'contact' then 'CONTACT_ATTEMPT'::haulvia.evidence_type
        when 'contactattempt' then 'CONTACT_ATTEMPT'::haulvia.evidence_type
        when 'quantity' then 'QUANTITY'::haulvia.evidence_type
        when 'condition' then 'CONDITION'::haulvia.evidence_type
        when 'identifier' then 'IDENTIFIER'::haulvia.evidence_type
        when 'seal' then 'SEAL'::haulvia.evidence_type
        when 'securement' then 'SECUREMENT'::haulvia.evidence_type
        when 'note' then 'NOTE'::haulvia.evidence_type
        else null
      end;
      if v_type is not null and not exists (
        select 1 from haulvia.stop_evidence e
        where e.stop_attempt_id = p_attempt_id and e.evidence_type = v_type
      ) then
        perform haulvia_command.fail(
          'EVIDENCE_INVALID', format('Snapshot-required %s evidence is missing', v_type::text)
        );
      end if;
    end if;
  end loop;
end;
$$;

create or replace function haulvia_command.record_pre_custody_decision(
  p_shipment haulvia.shipments,
  p_assignment haulvia.assignments,
  p_route_execution_id uuid,
  p_command_name text,
  p_request jsonb,
  p_provider_release boolean
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_id uuid;
  v_policy_id uuid := haulvia_command.required_uuid(p_request, 'policyVersionId');
  v_charge numeric := haulvia_command.required_numeric(p_request, 'cancellationChargeAmount');
  v_refund numeric := haulvia_command.required_numeric(p_request, 'customerRefundAmount');
  v_compensation numeric := haulvia_command.required_numeric(p_request, 'driverCompensationAmount');
  v_currency char(3) := upper(haulvia_command.required_text(p_request, 'currency'))::char(3);
  v_reason text := haulvia_command.required_text(p_request, 'reason');
  v_secured numeric;
  v_payment_currency char(3);
begin
  select secured_amount, currency into v_secured, v_payment_currency
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id
  for update;

  if not exists (
    select 1 from haulvia.shipment_rule_snapshots srs
    where srs.shipment_id = p_shipment.id
      and srs.route_version_id = p_assignment.route_version_id
      and srs.policy_version_id = v_policy_id
  ) then
    perform haulvia_command.fail('POLICY_SNAPSHOT_MISMATCH', 'Cancellation must use the route accepted policy snapshot');
  end if;
  if v_currency <> p_shipment.currency or v_currency <> v_payment_currency
     or v_charge < 0 or v_refund < 0 or v_compensation < 0
     or v_charge + v_refund <> v_secured
     or v_compensation > v_charge then
    perform haulvia_command.fail(
      'FINANCIAL_DECISION_INVALID',
      'Charge, refund, compensation, currency, and secured amount do not reconcile'
    );
  end if;
  if p_provider_release and (v_charge <> 0 or v_refund <> v_secured or v_compensation <> 0) then
    perform haulvia_command.fail(
      'FINANCIAL_DECISION_INVALID',
      'Driver-caused pre-custody release must cost the customer nothing and refund the secured amount'
    );
  end if;
  if jsonb_typeof(p_request -> 'decisionSnapshot') <> 'object'
     or p_request -> 'decisionSnapshot' = '{}'::jsonb then
    perform haulvia_command.fail('INVALID_REQUEST', 'decisionSnapshot must preserve the displayed versioned decision');
  end if;

  insert into haulvia.pre_custody_financial_decisions (
    shipment_id, assignment_id, route_execution_id, policy_version_id,
    command_name, responsibility_code, cancellation_charge_amount,
    customer_refund_amount, driver_compensation_amount, currency, reason,
    decision_snapshot, requested_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, p_assignment.id, p_route_execution_id, v_policy_id,
    p_command_name, haulvia_command.required_text(p_request, 'responsibilityCode'),
    v_charge, v_refund, v_compensation, v_currency, v_reason,
    p_request -> 'decisionSnapshot',
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function haulvia_command.operating_context(
  p_shipment_id uuid,
  p_command_name text,
  p_command_id uuid,
  p_affected jsonb default '{}'::jsonb
)
returns jsonb
language sql
stable
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select jsonb_build_object(
    'commandId', p_command_id,
    'commandName', p_command_name,
    'shipmentId', c.shipment_id,
    'shipmentReference', c.shipment_reference,
    'shipmentState', c.shipment_state,
    'marketplaceState', c.marketplace_state,
    'customerPaymentState', c.customer_payment_state,
    'driverPayoutState', c.driver_payout_state,
    'disputeState', c.dispute_state,
    'lockVersion', c.lock_version,
    'currentRouteVersionId', c.active_route_version_id,
    'activeAssignmentId', c.active_assignment_id,
    'activeRouteExecutionId', c.active_route_execution_id,
    'routeExecutionState', c.route_execution_state,
    'activeStopExecutionId', c.active_stop_execution_id,
    'activeRouteLegId', c.active_route_leg_id,
    'nextAction', c.next_action,
    'routeExecutionVersion', c.route_execution_record_version,
    'custodySummary', c.custody_summary
  ) || coalesce(p_affected, '{}'::jsonb)
  from haulvia.v_shipment_operating_context c
  where c.shipment_id = p_shipment_id;
$$;

-- ---------------------------------------------------------------------------
-- B01-B04: route start, first arrival, correction, and pickup service
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_b01_start_route(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_assignment haulvia.assignments%rowtype;
  v_route_id uuid;
  v_execution_id uuid;
  v_first_stop_id uuid;
  v_first_attempt_id uuid;
  v_first_leg_id uuid;
  v_tracking_id uuid;
  v_provider_org uuid;
  v_secured_amount numeric;
  v_price_amount numeric;
  v_started_at timestamptz := coalesce(
    nullif(p_request ->> 'occurredAt', '')::timestamptz, clock_timestamp()
  );
begin
  if p_shipment.shipment_state <> 'DRIVER_ASSIGNED' then
    perform haulvia_command.fail('INVALID_STATE', 'startRoute requires DRIVER_ASSIGNED');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_assigned_driver(v_assignment, p_request);
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  if v_route_id <> v_assignment.route_version_id then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Assignment does not cover the current active route');
  end if;

  select sp.organization_id into v_provider_org
  from haulvia.service_providers sp where sp.id = v_assignment.provider_id;
  perform haulvia_command.assert_provider_eligible(
    v_actor, v_provider_org, v_assignment.provider_id, v_assignment.driver_id,
    v_assignment.vehicle_id, null
  );

  select pa.secured_amount, ps.total_amount
  into v_secured_amount, v_price_amount
  from haulvia.shipment_customer_payment_axes pa
  join haulvia.shipment_price_snapshots ps on ps.id = v_assignment.price_snapshot_id
  where pa.shipment_id = p_shipment.id and pa.state = 'SECURED'
  for update of pa;
  if not found or v_secured_amount < v_price_amount then
    perform haulvia_command.fail('FUNDING_NOT_SECURED', 'Full route funds must remain secured at route start');
  end if;
  if exists (
    select 1 from haulvia.workflow_holds wh
    where wh.shipment_id = p_shipment.id
      and wh.status = 'ACTIVE'
      and wh.blocks_route_movement
  ) then
    perform haulvia_command.fail('WORKFLOW_HELD', 'An active workflow hold blocks route movement');
  end if;
  if exists (
    select 1 from haulvia.route_executions re
    where re.shipment_id = p_shipment.id
      and re.state in ('NOT_STARTED', 'ACTIVE', 'HELD', 'RECOVERY_ACTIVE')
  ) then
    perform haulvia_command.fail('ROUTE_EXECUTION_CONFLICT', 'A current route execution already exists');
  end if;

  select rl.id into v_first_leg_id
  from haulvia.route_legs rl
  where rl.route_version_id = v_route_id
  order by rl.sequence_no
  limit 1;
  if v_first_leg_id is null then
    perform haulvia_command.fail('ROUTE_INVALID', 'The assigned route has no first route leg');
  end if;

  insert into haulvia.route_executions (
    shipment_id, route_version_id, assignment_id, execution_kind, state,
    started_at, next_action, record_version
  ) values (
    p_shipment.id, v_route_id, v_assignment.id, 'PRIMARY', 'NOT_STARTED',
    null, 'START_ROUTE', 0
  ) returning id into v_execution_id;

  insert into haulvia.stop_executions (
    shipment_id, route_execution_id, route_version_id, route_stop_id,
    state, delivery_verification_state
  )
  select
    p_shipment.id, v_execution_id, v_route_id, rs.id, 'PENDING',
    case when rs.stop_type = 'DELIVERY'
      then 'PENDING_RECEIVER_CONFIRMATION'::haulvia.delivery_verification_state
      else 'NOT_REQUIRED'::haulvia.delivery_verification_state
    end
  from haulvia.route_stops rs
  where rs.route_version_id = v_route_id
  order by rs.sequence_no;

  select se.id into v_first_stop_id
  from haulvia.stop_executions se
  join haulvia.route_stops rs on rs.id = se.route_stop_id
  where se.route_execution_id = v_execution_id and rs.sequence_no = 1 and rs.stop_type = 'PICKUP'
  for update of se;
  if v_first_stop_id is null then
    perform haulvia_command.fail('ROUTE_INVALID', 'The first ordered stop must be a pickup for Block B');
  end if;

  insert into haulvia.stop_attempts (
    stop_execution_id, attempt_no, state
  ) values (
    v_first_stop_id, 1, 'EN_ROUTE'
  ) returning id into v_first_attempt_id;

  update haulvia.stop_executions
  set state = 'EN_ROUTE', current_attempt_no = 1
  where id = v_first_stop_id;

  update haulvia.route_executions
  set state = 'ACTIVE', started_at = v_started_at,
      active_stop_execution_id = v_first_stop_id,
      active_route_leg_id = v_first_leg_id,
      next_action = 'CONFIRM_ARRIVAL_AT_FIRST_PICKUP',
      record_version = 1
  where id = v_execution_id;

  insert into haulvia.tracking_sessions (
    route_execution_id, driver_id, started_at
  ) values (
    v_execution_id, v_assignment.driver_id, v_started_at
  ) returning id into v_tracking_id;

  insert into haulvia.route_updates (
    route_execution_id, active_route_leg_id, active_stop_execution_id,
    eta_at, custody_summary, captured_at, source
  ) values (
    v_execution_id, v_first_leg_id, v_first_stop_id,
    nullif(p_request ->> 'etaAt', '')::timestamptz,
    jsonb_build_object('hasVerifiedCustody', false, 'balances', '[]'::jsonb),
    v_started_at, 'DEVICE'
  );

  update haulvia.shipments
  set shipment_state = 'ROUTE_IN_PROGRESS'
  where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_first_attempt_id, v_first_stop_id, 'PENDING', 'EN_ROUTE',
    'startRoute', p_request,
    jsonb_build_object('routeExecutionId', v_execution_id, 'activeRouteLegId', v_first_leg_id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'ROUTE_EXECUTION', 'NOT_STARTED', 'ACTIVE',
    'startRoute', p_request, v_execution_id,
    jsonb_build_object('activeStopExecutionId', v_first_stop_id)
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id, 'DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS', 'startRoute',
    p_request, v_route_id,
    jsonb_build_object('routeExecutionId', v_execution_id, 'firstStopExecutionId', v_first_stop_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'startRoute', p_request, to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('routeExecutionId', v_execution_id, 'trackingSessionId', v_tracking_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'ROUTE_STARTED', p_request,
    'route-started-customer', jsonb_build_object('etaAt', p_request ->> 'etaAt')
  );

  return jsonb_build_object(
    'routeVersionId', v_route_id,
    'assignmentId', v_assignment.id,
    'routeExecutionId', v_execution_id,
    'routeExecutionVersion', 1,
    'stopExecutionId', v_first_stop_id,
    'stopAttemptId', v_first_attempt_id,
    'activeRouteLegId', v_first_leg_id,
    'trackingSessionId', v_tracking_id
  );
end;
$$;

create or replace function haulvia_command.apply_b02_confirm_first_arrival(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_attempt haulvia.stop_attempts%rowtype;
  v_route_stop haulvia.route_stops%rowtype;
  v_lat numeric := haulvia_command.required_numeric(p_request, 'latitude');
  v_lon numeric := haulvia_command.required_numeric(p_request, 'longitude');
  v_accuracy numeric := coalesce(haulvia_command.optional_numeric(p_request, 'accuracyM'), 0);
  v_captured timestamptz := haulvia_command.required_timestamptz(p_request, 'capturedAt');
  v_free_until timestamptz := haulvia_command.required_timestamptz(p_request, 'waitingFreeUntil');
  v_distance numeric;
  v_exception_reason text := nullif(btrim(p_request ->> 'gpsExceptionReason'), '');
  v_within boolean := false;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'confirmArrivalAtFirstPickup requires ROUTE_IN_PROGRESS');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_assigned_driver(v_assignment, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_first_stop_execution(v_execution, p_request);
  if v_stop.state <> 'EN_ROUTE' then
    perform haulvia_command.fail('INVALID_STATE', 'First pickup must be EN_ROUTE before arrival');
  end if;
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
  for update;
  if not found or v_attempt.state <> 'EN_ROUTE' or v_attempt.ended_at is not null then
    perform haulvia_command.fail('INVALID_STATE', 'The first pickup attempt is not active en route');
  end if;
  select * into v_route_stop from haulvia.route_stops where id = v_stop.route_stop_id;

  if v_lat not between -90 and 90 or v_lon not between -180 and 180 or v_accuracy < 0 then
    perform haulvia_command.fail('LOCATION_NOT_VERIFIED', 'Arrival coordinates or accuracy are invalid');
  end if;
  if v_route_stop.latitude is not null and v_route_stop.longitude is not null
     and v_route_stop.geofence_radius_m is not null then
    v_distance := haulvia_command.distance_metres(
      v_route_stop.latitude, v_route_stop.longitude, v_lat, v_lon
    );
    v_within := v_distance <= v_route_stop.geofence_radius_m + v_accuracy;
  end if;
  if not v_within and (
    v_exception_reason is null
    or length(v_exception_reason) < 8
    or jsonb_typeof(p_request -> 'gpsExceptionEvidence') <> 'object'
    or p_request -> 'gpsExceptionEvidence' = '{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'LOCATION_NOT_VERIFIED',
      'Arrival must be within the configured radius or carry a documented GPS exception'
    );
  end if;
  if v_free_until <= v_captured then
    perform haulvia_command.fail('INVALID_REQUEST', 'waitingFreeUntil must be after verified arrival');
  end if;

  insert into haulvia.stop_evidence (
    stop_attempt_id, evidence_type, structured_value, captured_at,
    captured_latitude, captured_longitude, captured_accuracy_m,
    submitted_by_profile_id, idempotency_key
  ) values
    (
      v_attempt.id, 'GPS',
      jsonb_build_object(
        'distanceMetres', v_distance, 'withinRadius', v_within,
        'geofenceRadiusMetres', v_route_stop.geofence_radius_m,
        'exceptionReason', v_exception_reason,
        'exceptionEvidence', coalesce(p_request -> 'gpsExceptionEvidence', '{}'::jsonb)
      ),
      v_captured, v_lat, v_lon, v_accuracy,
      haulvia_command.required_uuid(p_request, 'actorProfileId'),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':arrival-gps'
    ),
    (
      v_attempt.id, 'TIMESTAMP', jsonb_build_object('verifiedArrivalAt', v_captured),
      v_captured, v_lat, v_lon, v_accuracy,
      haulvia_command.required_uuid(p_request, 'actorProfileId'),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':arrival-time'
    );

  update haulvia.stop_executions set state = 'ARRIVED' where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'ARRIVED', arrived_at = v_captured
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'START_FIRST_PICKUP_SERVICE',
      record_version = record_version + 1
  where id = v_execution.id;
  insert into haulvia.route_updates (
    route_execution_id, active_route_leg_id, active_stop_execution_id,
    eta_at, dwell_seconds, custody_summary, captured_at, source
  ) values (
    v_execution.id, v_execution.active_route_leg_id, v_stop.id,
    nullif(p_request ->> 'etaAt', '')::timestamptz, 0,
    jsonb_build_object('hasVerifiedCustody', false, 'balances', '[]'::jsonb),
    v_captured, 'DEVICE'
  );
  perform haulvia_command.queue_job(
    p_shipment.id, 'STOP_WAITING_GRACE_EXPIRES', v_free_until, p_request,
    'first-pickup-waiting',
    jsonb_build_object(
      'routeExecutionId', v_execution.id,
      'stopExecutionId', v_stop.id,
      'stopAttemptId', v_attempt.id,
      'verifiedArrivalAt', v_captured,
      'freeUntil', v_free_until
    )
  );
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'EN_ROUTE', 'ARRIVED',
    'confirmArrivalAtFirstPickup', p_request,
    jsonb_build_object(
      'distanceMetres', v_distance, 'withinRadius', v_within,
      'waitingFreeUntil', v_free_until
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'confirmArrivalAtFirstPickup', p_request,
    jsonb_build_object('stopState', 'EN_ROUTE'),
    jsonb_build_object('stopState', 'ARRIVED'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'withinRadius', v_within)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'DRIVER_ARRIVED_FIRST_PICKUP',
    p_request, 'first-pickup-arrival',
    jsonb_build_object('stopExecutionId', v_stop.id, 'waitingFreeUntil', v_free_until)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'distanceMetres', v_distance,
    'withinRadius', v_within,
    'waitingFreeUntil', v_free_until
  );
end;
$$;

create or replace function haulvia_command.apply_b03_correct_first_arrival(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_attempt haulvia.stop_attempts%rowtype;
  v_reason text := haulvia_command.required_text(p_request, 'reason');
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'correctFirstStopArrival requires ROUTE_IN_PROGRESS');
  end if;
  if length(v_reason) < 3 then
    perform haulvia_command.fail('INVALID_REQUEST', 'Arrival correction requires a specific reason');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_route_operator(v_assignment, p_request, true);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_first_stop_execution(v_execution, p_request);
  if v_stop.state <> 'ARRIVED' then
    perform haulvia_command.fail('INVALID_STATE', 'Only an ARRIVED first stop can be corrected');
  end if;
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
  for update;
  if not found or v_attempt.service_started_at is not null or v_attempt.ended_at is not null
     or exists (
       select 1 from haulvia.financial_adjustments fa
       where fa.stop_execution_id = v_stop.id
     ) then
    perform haulvia_command.fail(
      'ARRIVAL_CORRECTION_BLOCKED',
      'Arrival cannot be corrected after service, failure, or a finalized waiting charge'
    );
  end if;

  update haulvia.workflow_jobs
  set status = 'CANCELLED'
  where shipment_id = p_shipment.id
    and job_code = 'STOP_WAITING_GRACE_EXPIRES'
    and status = 'QUEUED'
    and payload ->> 'stopExecutionId' = v_stop.id::text;
  update haulvia.stop_executions set state = 'EN_ROUTE' where id = v_stop.id;
  update haulvia.stop_attempts set state = 'EN_ROUTE' where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'CONFIRM_ARRIVAL_AT_FIRST_PICKUP',
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'ARRIVED', 'EN_ROUTE',
    'correctFirstStopArrival', p_request,
    jsonb_build_object('originalArrivalPreserved', true)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'correctFirstStopArrival', p_request,
    jsonb_build_object('stopState', 'ARRIVED'),
    jsonb_build_object('stopState', 'EN_ROUTE'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'reason', v_reason)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'FIRST_PICKUP_ARRIVAL_CORRECTED',
    p_request, 'first-arrival-corrected', jsonb_build_object('reason', v_reason)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'originalArrivalPreserved', true
  );
end;
$$;

create or replace function haulvia_command.apply_b04_start_first_pickup_service(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_attempt haulvia.stop_attempts%rowtype;
  v_cargo_available boolean := haulvia_command.required_boolean(p_request, 'cargoAvailable');
  v_service_started timestamptz := coalesce(
    nullif(p_request ->> 'occurredAt', '')::timestamptz, clock_timestamp()
  );
  v_exception_id uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'startFirstPickupService requires ROUTE_IN_PROGRESS');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_assigned_driver(v_assignment, p_request);
  if not haulvia_command.required_boolean(p_request, 'contactConfirmed')
     or not haulvia_command.required_boolean(p_request, 'locationConfirmed') then
    perform haulvia_command.fail('STOP_DETAILS_MISMATCH', 'Pickup contact and location must both be confirmed');
  end if;
  if not v_cargo_available and (
    jsonb_typeof(p_request -> 'cargoDiscrepancy') <> 'object'
    or p_request -> 'cargoDiscrepancy' = '{}'::jsonb
  ) then
    perform haulvia_command.fail('CARGO_DISCREPANCY_REQUIRED', 'Unavailable cargo requires a structured discrepancy');
  end if;
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_first_stop_execution(v_execution, p_request);
  if v_stop.state <> 'ARRIVED' then
    perform haulvia_command.fail('INVALID_STATE', 'First pickup service requires ARRIVED');
  end if;
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
  for update;
  if not found or v_attempt.state <> 'ARRIVED' or v_attempt.ended_at is not null then
    perform haulvia_command.fail('INVALID_STATE', 'The first pickup attempt is not active at arrival');
  end if;

  if not v_cargo_available then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id, exception_code,
      status, blocks_completion, description, opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id,
      'FIRST_PICKUP_CARGO_DISCREPANCY', 'OPEN', true,
      'Cargo discrepancy recorded before first pickup service',
      haulvia_command.required_uuid(p_request, 'actorProfileId'),
      p_request -> 'cargoDiscrepancy'
    ) returning id into v_exception_id;
  end if;

  update haulvia.workflow_jobs
  set status = 'CANCELLED'
  where shipment_id = p_shipment.id
    and job_code = 'STOP_WAITING_GRACE_EXPIRES'
    and status = 'QUEUED'
    and payload ->> 'stopExecutionId' = v_stop.id::text;
  update haulvia.stop_executions set state = 'SERVICE_IN_PROGRESS' where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'SERVICE_IN_PROGRESS', service_started_at = v_service_started
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'SUBMIT_FIRST_PICKUP_EVIDENCE',
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'ARRIVED', 'SERVICE_IN_PROGRESS',
    'startFirstPickupService', p_request,
    jsonb_build_object('cargoAvailable', v_cargo_available, 'routeExceptionId', v_exception_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'startFirstPickupService', p_request,
    jsonb_build_object('stopState', 'ARRIVED'),
    jsonb_build_object('stopState', 'SERVICE_IN_PROGRESS'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'routeExceptionId', v_exception_id)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'routeExceptionId', v_exception_id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- B05-B07: evidence submission, verified first custody, and failed pickup
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_b05_submit_first_pickup_evidence(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_attempt haulvia.stop_attempts%rowtype;
  v_evidence jsonb;
  v_submitted_at timestamptz := coalesce(
    nullif(p_request ->> 'occurredAt', '')::timestamptz, clock_timestamp()
  );
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'submitFirstPickupEvidence requires ROUTE_IN_PROGRESS');
  end if;
  if not haulvia_command.required_boolean(p_request, 'driverConfirmed') then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Assigned driver confirmation is required');
  end if;
  if length(haulvia_command.required_text(p_request, 'releasingPersonName')) < 2 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Releasing-person name is required');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_assigned_driver(v_assignment, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_first_stop_execution(v_execution, p_request);
  if v_stop.state <> 'SERVICE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'First pickup evidence requires SERVICE_IN_PROGRESS');
  end if;
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
  for update;
  if not found or v_attempt.state <> 'SERVICE_IN_PROGRESS' or v_attempt.ended_at is not null then
    perform haulvia_command.fail('INVALID_STATE', 'The first pickup service attempt is not active');
  end if;

  v_evidence := haulvia_command.insert_evidence_array(v_attempt.id, p_request, 'evidence');
  perform haulvia_command.assert_first_pickup_evidence(
    p_shipment.id, v_execution.route_version_id, v_stop.route_stop_id, v_attempt.id
  );

  update haulvia.stop_executions set state = 'EVIDENCE_PENDING' where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'EVIDENCE_PENDING', evidence_submitted_at = v_submitted_at
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'VERIFY_FIRST_PICKUP',
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING',
    'submitFirstPickupEvidence', p_request,
    jsonb_build_object(
      'evidence', v_evidence,
      'releasingPersonName', p_request ->> 'releasingPersonName',
      'driverConfirmed', true
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'submitFirstPickupEvidence', p_request,
    jsonb_build_object('stopState', 'SERVICE_IN_PROGRESS'),
    jsonb_build_object('stopState', 'EVIDENCE_PENDING'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'evidence', v_evidence)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'FIRST_PICKUP_EVIDENCE_SUBMITTED',
    p_request, 'first-pickup-evidence', jsonb_build_object('stopExecutionId', v_stop.id)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'evidence', v_evidence
  );
end;
$$;

create or replace function haulvia_command.apply_b06_verify_first_pickup(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_attempt haulvia.stop_attempts%rowtype;
  v_item jsonb;
  v_allocation haulvia.cargo_allocations%rowtype;
  v_expected_count integer;
  v_request_count integer;
  v_distinct_count integer;
  v_quantity numeric;
  v_movement_id uuid;
  v_first_movement_id uuid;
  v_first_custody_at timestamptz;
  v_movement_ids jsonb := '[]'::jsonb;
  v_custody jsonb;
  v_partial boolean := false;
  v_partial_exception_id uuid;
  v_reviewer_label text;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'verifyFirstPickup requires ROUTE_IN_PROGRESS');
  end if;
  perform haulvia_command.authorize_evidence_reviewer(p_request);
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_first_stop_execution(v_execution, p_request);
  if v_stop.state <> 'EVIDENCE_PENDING' then
    perform haulvia_command.fail('INVALID_STATE', 'First pickup must be EVIDENCE_PENDING');
  end if;
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
  for update;
  if not found or v_attempt.state <> 'EVIDENCE_PENDING' or v_attempt.ended_at is not null then
    perform haulvia_command.fail('INVALID_STATE', 'First pickup evidence attempt is not reviewable');
  end if;
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  perform haulvia_command.assert_first_pickup_evidence(
    p_shipment.id, v_execution.route_version_id, v_stop.route_stop_id, v_attempt.id
  );

  if jsonb_typeof(p_request -> 'loads') <> 'array'
     or jsonb_array_length(p_request -> 'loads') = 0 then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'loads must be a non-empty array');
  end if;
  select count(*) into v_expected_count
  from haulvia.cargo_allocations ca
  where ca.route_version_id = v_execution.route_version_id
    and ca.pickup_stop_id = v_stop.route_stop_id;
  select count(*), count(distinct value ->> 'cargoAllocationId')
  into v_request_count, v_distinct_count
  from jsonb_array_elements(p_request -> 'loads');
  if v_expected_count = 0 or v_request_count <> v_expected_count
     or v_distinct_count <> v_request_count then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'Verified pickup must provide exactly one actual LOAD for every allocation at the first stop'
    );
  end if;

  for v_item in select value from jsonb_array_elements(p_request -> 'loads')
  loop
    select * into v_allocation
    from haulvia.cargo_allocations ca
    where ca.id = haulvia_command.required_uuid(v_item, 'cargoAllocationId')
      and ca.route_version_id = v_execution.route_version_id
      and ca.pickup_stop_id = v_stop.route_stop_id
    for update;
    if not found then
      perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'LOAD references cargo outside the first pickup');
    end if;
    v_quantity := haulvia_command.required_numeric(v_item, 'quantity');
    if v_quantity <= 0 or v_quantity > v_allocation.quantity
       or haulvia_command.required_text(v_item, 'quantityUnit') <> v_allocation.quantity_unit then
      perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'LOAD quantity or unit is invalid for its allocation');
    end if;
    if v_quantity < v_allocation.quantity then
      v_partial := true;
    end if;

    insert into haulvia.cargo_movements (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, movement_type, quantity, quantity_unit,
      stop_attempt_id, evidence_bundle, occurred_at, recorded_by_profile_id,
      idempotency_key
    ) values (
      p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
      v_allocation.id, 'LOAD', v_quantity, v_allocation.quantity_unit,
      v_attempt.id, coalesce(v_item -> 'evidenceBundle', '{}'::jsonb),
      coalesce(nullif(v_item ->> 'occurredAt', '')::timestamptz, clock_timestamp()),
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      coalesce(
        nullif(v_item ->> 'idempotencyKey', ''),
        haulvia_command.required_text(p_request, 'idempotencyKey') || ':load:' || v_allocation.id::text
      )
    ) returning id, occurred_at into v_movement_id, v_first_custody_at;
    if v_first_movement_id is null then
      v_first_movement_id := v_movement_id;
    end if;
    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement_id);
  end loop;

  if v_partial and (
    jsonb_typeof(p_request -> 'quantityDiscrepancy') <> 'object'
    or p_request -> 'quantityDiscrepancy' = '{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'A partial actual pickup requires a structured quantity discrepancy'
    );
  end if;
  if v_partial then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id, exception_code,
      status, blocks_completion, description, opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id,
      'FIRST_PICKUP_QUANTITY_DISCREPANCY', 'OPEN', true,
      'Verified first pickup quantity differs from the planned allocation',
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      p_request -> 'quantityDiscrepancy'
    ) returning id into v_partial_exception_id;
  end if;

  v_reviewer_label := coalesce(
    nullif(p_request ->> 'reviewerLabel', ''),
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SYSTEM:EVIDENCE_REVIEWER'
      else 'PROFILE:' || haulvia_command.optional_uuid(p_request, 'actorProfileId')::text
    end
  );
  insert into haulvia.stop_evidence_reviews (
    stop_evidence_id, status, reviewer_profile_id, reviewer_label, note, metadata
  )
  select
    e.id, 'VERIFIED', haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    v_reviewer_label, nullif(p_request ->> 'reviewNote', ''),
    jsonb_build_object('commandId', haulvia_command.required_uuid(p_request, 'commandId'))
  from haulvia.stop_evidence e
  where e.stop_attempt_id = v_attempt.id;

  update haulvia.stop_executions set state = 'COMPLETED' where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'COMPLETED', ended_at = clock_timestamp()
  where id = v_attempt.id;
  insert into haulvia.shipment_custody_milestones (
    shipment_id, route_execution_id, first_stop_execution_id,
    first_cargo_movement_id, first_custody_at, metadata
  ) values (
    p_shipment.id, v_execution.id, v_stop.id,
    v_first_movement_id,
    (select min(cm.occurred_at) from haulvia.cargo_movements cm
     where cm.id in (select (value #>> '{}')::uuid from jsonb_array_elements(v_movement_ids))),
    jsonb_build_object('movementIds', v_movement_ids, 'stopAttemptId', v_attempt.id)
  );
  update haulvia.route_executions
  set next_action = 'ADVANCE_TO_NEXT_STOP',
      record_version = record_version + 1
  where id = v_execution.id;

  select jsonb_build_object(
    'hasVerifiedCustody', true,
    'balances', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'stableCargoKey', cb.stable_cargo_key,
          'quantityUnit', cb.quantity_unit,
          'onboardQuantity', cb.onboard_quantity
        ) order by cb.stable_cargo_key, cb.quantity_unit
      ), '[]'::jsonb
    )
  ) into v_custody
  from haulvia.v_cargo_custody_balance cb
  where cb.shipment_id = p_shipment.id;
  insert into haulvia.route_updates (
    route_execution_id, active_route_leg_id, active_stop_execution_id,
    custody_summary, captured_at, source
  ) values (
    v_execution.id, v_execution.active_route_leg_id, v_stop.id,
    coalesce(v_custody, jsonb_build_object('hasVerifiedCustody', true, 'balances', '[]'::jsonb)),
    clock_timestamp(), 'SERVER'
  );
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'EVIDENCE_PENDING', 'COMPLETED',
    'verifyFirstPickup', p_request,
    jsonb_build_object(
      'movementIds', v_movement_ids,
      'firstCustodyAt', (select first_custody_at from haulvia.shipment_custody_milestones where shipment_id = p_shipment.id),
      'quantityDiscrepancyExceptionId', v_partial_exception_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'verifyFirstPickup', p_request,
    jsonb_build_object('stopState', 'EVIDENCE_PENDING', 'hasVerifiedCustody', false),
    jsonb_build_object('stopState', 'COMPLETED', 'hasVerifiedCustody', true),
    jsonb_build_object('movementIds', v_movement_ids, 'custodySummary', v_custody)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'FIRST_PICKUP_VERIFIED',
    p_request, 'first-pickup-verified', jsonb_build_object('custodySummary', v_custody)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'cargoMovementIds', v_movement_ids,
    'firstCustodyAt', (select first_custody_at from haulvia.shipment_custody_milestones where shipment_id = p_shipment.id),
    'custodySummary', v_custody,
    'routeExceptionId', v_partial_exception_id
  );
exception
  when check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'Verified LOAD movements violated an allocation, custody, or idempotency invariant',
      jsonb_build_object('databaseMessage', sqlerrm)
    );
  return null;
end;
$$;

create or replace function haulvia_command.apply_b07_report_failed_first_pickup(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_attempt haulvia.stop_attempts%rowtype;
  v_target haulvia.stop_state;
  v_occurred timestamptz := coalesce(
    nullif(p_request ->> 'occurredAt', '')::timestamptz, clock_timestamp()
  );
  v_grace_end timestamptz := haulvia_command.required_timestamptz(p_request, 'gracePeriodEndedAt');
  v_contacts jsonb := p_request -> 'contactAttempts';
  v_affected jsonb := p_request -> 'affectedCargo';
  v_evidence jsonb;
  v_contact jsonb;
  v_contact_index integer := 0;
  v_hold_id uuid;
  v_exception_id uuid;
  v_open_hold boolean := coalesce(nullif(p_request ->> 'openWorkflowHold', '')::boolean, false);
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'reportFailedFirstPickup requires ROUTE_IN_PROGRESS');
  end if;
  begin
    v_target := upper(haulvia_command.required_text(p_request, 'targetStopState'))::haulvia.stop_state;
  exception when invalid_text_representation then
    perform haulvia_command.fail('INVALID_REQUEST', 'targetStopState must be FAILED or EXCEPTION_REVIEW');
  end;
  if v_target not in ('FAILED', 'EXCEPTION_REVIEW') then
    perform haulvia_command.fail('INVALID_REQUEST', 'targetStopState must be FAILED or EXCEPTION_REVIEW');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_route_operator(v_assignment, p_request, true);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_first_stop_execution(v_execution, p_request);
  if v_stop.state not in ('ARRIVED', 'SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING') then
    perform haulvia_command.fail('INVALID_STATE', 'First pickup must have a verified arrival before failure');
  end if;
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
  for update;
  if not found or v_attempt.arrived_at is null or v_attempt.ended_at is not null then
    perform haulvia_command.fail('INVALID_STATE', 'The first pickup attempt lacks an active verified arrival');
  end if;
  if v_grace_end < v_attempt.arrived_at or v_grace_end > v_occurred then
    perform haulvia_command.fail('WAITING_PERIOD_ACTIVE', 'The configured first-pickup grace period is not complete');
  end if;
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  if jsonb_typeof(v_contacts) <> 'array' or jsonb_array_length(v_contacts) = 0
     or jsonb_typeof(v_affected) <> 'array' or jsonb_array_length(v_affected) = 0
     or jsonb_typeof(p_request -> 'custodyBalance') <> 'object'
     or coalesce(nullif(p_request #>> '{custodyBalance,onboardQuantity}', '')::numeric, 0) <> 0 then
    perform haulvia_command.fail(
      'FAILED_STOP_EVIDENCE_REQUIRED',
      'Failed pickup requires contacts, affected cargo, and a zero custody-balance snapshot'
    );
  end if;
  if exists (
    select 1
    from jsonb_array_elements(v_affected) x
    where not exists (
      select 1 from haulvia.cargo_allocations ca
      where ca.id = (x ->> 'cargoAllocationId')::uuid
        and ca.route_version_id = v_execution.route_version_id
        and ca.pickup_stop_id = v_stop.route_stop_id
    )
  ) then
    perform haulvia_command.fail('FAILED_STOP_EVIDENCE_REQUIRED', 'Affected cargo is outside the first pickup');
  end if;

  v_evidence := haulvia_command.insert_evidence_array(v_attempt.id, p_request, 'evidence');
  for v_contact in select value from jsonb_array_elements(v_contacts)
  loop
    v_contact_index := v_contact_index + 1;
    insert into haulvia.stop_evidence (
      stop_attempt_id, evidence_type, structured_value, captured_at,
      submitted_by_profile_id, idempotency_key
    ) values (
      v_attempt.id, 'CONTACT_ATTEMPT', v_contact,
      coalesce(nullif(v_contact ->> 'capturedAt', '')::timestamptz, v_occurred),
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':contact:' || v_contact_index::text
    );
  end loop;

  if v_target = 'EXCEPTION_REVIEW' or v_open_hold then
    insert into haulvia.workflow_holds (
      shipment_id, route_execution_id, stop_execution_id, hold_code,
      status, blocks_route_movement, blocks_completion, reason,
      opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id,
      coalesce(nullif(p_request ->> 'holdCode', ''), 'FIRST_PICKUP_EXCEPTION_REVIEW'),
      'ACTIVE', true, true,
      haulvia_command.required_text(p_request, 'failureReason'),
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      jsonb_build_object('gracePeriodEndedAt', v_grace_end)
    ) returning id into v_hold_id;
  end if;
  insert into haulvia.route_exceptions (
    shipment_id, route_execution_id, stop_execution_id, workflow_hold_id,
    exception_code, status, responsibility_code, blocks_completion,
    description, opened_by_profile_id, metadata
  ) values (
    p_shipment.id, v_execution.id, v_stop.id, v_hold_id,
    'FAILED_FIRST_PICKUP',
    case when v_target = 'EXCEPTION_REVIEW'
      then 'UNDER_REVIEW'::haulvia.exception_status
      else 'OPEN'::haulvia.exception_status
    end,
    haulvia_command.required_text(p_request, 'responsibilityCode'), true,
    haulvia_command.required_text(p_request, 'failureReason'),
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    jsonb_build_object(
      'contactAttempts', v_contacts,
      'affectedCargo', v_affected,
      'custodyBalance', p_request -> 'custodyBalance',
      'evidence', v_evidence,
      'gracePeriodEndedAt', v_grace_end
    )
  ) returning id into v_exception_id;

  update haulvia.stop_executions set state = v_target where id = v_stop.id;
  update haulvia.stop_attempts
  set state = v_target, ended_at = v_occurred,
      responsibility_code = haulvia_command.required_text(p_request, 'responsibilityCode'),
      failure_reason = haulvia_command.required_text(p_request, 'failureReason')
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'RESOLVE_FIRST_PICKUP_FAILURE',
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, v_stop.state, v_target,
    'reportFailedFirstPickup', p_request,
    jsonb_build_object(
      'routeExceptionId', v_exception_id,
      'workflowHoldId', v_hold_id,
      'custodyBalance', p_request -> 'custodyBalance'
    )
  );
  if v_hold_id is not null then
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'WORKFLOW_HOLD', null, 'ACTIVE',
      'reportFailedFirstPickup', p_request, v_hold_id,
      jsonb_build_object('stopExecutionId', v_stop.id)
    );
  end if;
  perform haulvia_command.append_audit(
    p_shipment, 'reportFailedFirstPickup', p_request,
    jsonb_build_object('stopState', v_stop.state),
    jsonb_build_object('stopState', v_target),
    jsonb_build_object('routeExceptionId', v_exception_id, 'workflowHoldId', v_hold_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'FIRST_PICKUP_FAILED',
    p_request, 'first-pickup-failed',
    jsonb_build_object('targetStopState', v_target, 'routeExceptionId', v_exception_id)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'targetStopState', v_target,
    'routeExceptionId', v_exception_id,
    'workflowHoldId', v_hold_id
  );
exception when invalid_text_representation then
  perform haulvia_command.fail(
    'FAILED_STOP_EVIDENCE_REQUIRED',
    'Failed pickup cargo, custody, or evidence identifiers are invalid'
  );
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- B08-B12: pre-custody cancellation/release, deliberate repost, and issues
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_b08_cancel_before_any_custody(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_execution_id uuid;
  v_decision_id uuid;
  v_payment_prior haulvia.customer_payment_state;
  v_payment_after haulvia.customer_payment_state;
  v_secured numeric;
  v_charge numeric := haulvia_command.required_numeric(p_request, 'cancellationChargeAmount');
  v_refund numeric := haulvia_command.required_numeric(p_request, 'customerRefundAmount');
begin
  if p_shipment.shipment_state not in ('DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS') then
    perform haulvia_command.fail(
      'INVALID_STATE', 'cancelBeforeAnyCustody requires DRIVER_ASSIGNED or ROUTE_IN_PROGRESS'
    );
  end if;
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);

  if p_shipment.shipment_state = 'ROUTE_IN_PROGRESS' then
    v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
    if v_execution.state not in ('ACTIVE', 'HELD') then
      perform haulvia_command.fail('INVALID_STATE', 'Current route execution is not cancellable');
    end if;
    v_execution_id := v_execution.id;
  elsif p_request ? 'expectedRouteExecutionId' then
    perform haulvia_command.fail('INVALID_REQUEST', 'DRIVER_ASSIGNED cancellation must not name a route execution');
  end if;

  v_decision_id := haulvia_command.record_pre_custody_decision(
    p_shipment, v_assignment, v_execution_id,
    'cancelBeforeAnyCustody', p_request, false
  );
  select state, secured_amount into v_payment_prior, v_secured
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id
  for update;
  v_payment_after := case
    when v_refund = v_secured then 'REFUNDED'::haulvia.customer_payment_state
    else 'PARTIALLY_REFUNDED'::haulvia.customer_payment_state
  end;

  if v_execution_id is not null then
    update haulvia.stop_executions
    set state = 'CANCELLED'
    where route_execution_id = v_execution_id
      and state in ('PENDING', 'EN_ROUTE', 'ARRIVED', 'SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING');
    update haulvia.route_executions
    set state = 'CANCELLED', next_action = 'NONE',
        record_version = record_version + 1
    where id = v_execution_id;
    update haulvia.tracking_sessions
    set ended_at = clock_timestamp()
    where route_execution_id = v_execution_id and ended_at is null;
  end if;
  update haulvia.assignments
  set status = 'CANCELLED', ended_at = clock_timestamp(),
      end_reason = haulvia_command.required_text(p_request, 'reason')
  where id = v_assignment.id;
  insert into haulvia.assignment_events (
    assignment_id, shipment_id, prior_status, current_status, command_name,
    actor_kind, actor_profile_id, reason, idempotency_key, metadata
  ) values (
    v_assignment.id, p_shipment.id, 'ACTIVE', 'CANCELLED',
    'cancelBeforeAnyCustody', 'PROFILE', v_actor,
    haulvia_command.required_text(p_request, 'reason'),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  update haulvia.shipment_customer_payment_axes
  set state = v_payment_after, secured_amount = v_charge,
      state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_marketplace_axes
  set state = 'CLOSED', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'CANCELLED' where id = p_shipment.id;

  perform haulvia_command.queue_job(
    p_shipment.id, 'SETTLE_PRE_CUSTODY_CANCELLATION', clock_timestamp(),
    p_request, 'pre-custody-customer-settlement',
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment_prior::text, v_payment_after::text,
    'cancelBeforeAnyCustody', p_request, v_decision_id,
    jsonb_build_object('chargeAmount', v_charge, 'refundAmount', v_refund)
  );
  if v_execution_id is not null then
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'CANCELLED',
      'cancelBeforeAnyCustody', p_request, v_execution_id
    );
  end if;
  perform haulvia_command.append_shipment_event(
    p_shipment.id, p_shipment.shipment_state, 'CANCELLED',
    'cancelBeforeAnyCustody', p_request, v_assignment.route_version_id,
    jsonb_build_object(
      'assignmentId', v_assignment.id,
      'routeExecutionId', v_execution_id,
      'financialDecisionId', v_decision_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'cancelBeforeAnyCustody', p_request,
    to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_CANCELLED_BEFORE_CUSTODY',
    p_request, 'cancel-before-custody-customer',
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,
    (select d.profile_id from haulvia.drivers d where d.id = v_assignment.driver_id),
    'ASSIGNMENT_CANCELLED_BEFORE_CUSTODY', p_request,
    'cancel-before-custody-driver',
    jsonb_build_object('driverCompensationAmount', p_request ->> 'driverCompensationAmount')
  );
  return jsonb_build_object(
    'routeVersionId', v_assignment.route_version_id,
    'assignmentId', v_assignment.id,
    'routeExecutionId', v_execution_id,
    'financialDecisionId', v_decision_id,
    'customerPaymentState', v_payment_after
  );
end;
$$;

create or replace function haulvia_command.apply_b09_release_driver_before_any_custody(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_execution_id uuid;
  v_decision_id uuid;
  v_outcome text := upper(haulvia_command.required_text(p_request, 'releaseOutcome'));
  v_target_shipment haulvia.shipment_state;
  v_target_market haulvia.marketplace_state;
  v_payment_prior haulvia.customer_payment_state;
begin
  if p_shipment.shipment_state not in ('DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS') then
    perform haulvia_command.fail(
      'INVALID_STATE', 'releaseDriverBeforeAnyCustody requires DRIVER_ASSIGNED or ROUTE_IN_PROGRESS'
    );
  end if;
  if v_outcome = 'POSTED_PAUSED' then
    v_target_shipment := 'POSTED';
    v_target_market := 'PAUSED';
  elsif v_outcome = 'EXPIRED' then
    v_target_shipment := 'EXPIRED';
    v_target_market := 'EXPIRED';
  else
    perform haulvia_command.fail('INVALID_REQUEST', 'releaseOutcome must be POSTED_PAUSED or EXPIRED');
  end if;

  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_route_operator(v_assignment, p_request, false);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  if p_shipment.shipment_state = 'ROUTE_IN_PROGRESS' then
    v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
    if v_execution.state not in ('ACTIVE', 'HELD') then
      perform haulvia_command.fail('INVALID_STATE', 'Current route execution cannot be released');
    end if;
    v_execution_id := v_execution.id;
  elsif p_request ? 'expectedRouteExecutionId' then
    perform haulvia_command.fail('INVALID_REQUEST', 'DRIVER_ASSIGNED release must not name a route execution');
  end if;
  v_decision_id := haulvia_command.record_pre_custody_decision(
    p_shipment, v_assignment, v_execution_id,
    'releaseDriverBeforeAnyCustody', p_request, true
  );

  select state into v_payment_prior
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id
  for update;
  if v_execution_id is not null then
    update haulvia.stop_executions
    set state = 'CANCELLED'
    where route_execution_id = v_execution_id
      and state in ('PENDING', 'EN_ROUTE', 'ARRIVED', 'SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING');
    update haulvia.route_executions
    set state = 'CANCELLED', next_action = 'CUSTOMER_REVIEW_REQUIRED',
        record_version = record_version + 1
    where id = v_execution_id;
    update haulvia.tracking_sessions
    set ended_at = clock_timestamp()
    where route_execution_id = v_execution_id and ended_at is null;
  end if;
  update haulvia.assignments
  set status = 'CANCELLED', ended_at = clock_timestamp(),
      end_reason = haulvia_command.required_text(p_request, 'reason')
  where id = v_assignment.id;
  insert into haulvia.assignment_events (
    assignment_id, shipment_id, prior_status, current_status, command_name,
    actor_kind, actor_profile_id, reason, idempotency_key, metadata
  ) values (
    v_assignment.id, p_shipment.id, 'ACTIVE', 'CANCELLED',
    'releaseDriverBeforeAnyCustody',
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'reason'),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object('financialDecisionId', v_decision_id, 'releaseOutcome', v_outcome)
  );
  update haulvia.shipment_customer_payment_axes
  set state = 'RELEASED', secured_amount = 0, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_marketplace_axes
  set state = v_target_market,
      paused_reason = case when v_target_market = 'PAUSED' then 'DRIVER_RELEASED_BEFORE_CUSTODY' end,
      state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = v_target_shipment where id = p_shipment.id;

  perform haulvia_command.queue_job(
    p_shipment.id, 'SETTLE_DRIVER_RELEASE_BEFORE_CUSTODY', clock_timestamp(),
    p_request, 'pre-custody-driver-release-settlement',
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment_prior::text, 'RELEASED',
    'releaseDriverBeforeAnyCustody', p_request, v_decision_id
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'MARKETPLACE', 'CLOSED', v_target_market::text,
    'releaseDriverBeforeAnyCustody', p_request
  );
  if v_execution_id is not null then
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'CANCELLED',
      'releaseDriverBeforeAnyCustody', p_request, v_execution_id
    );
  end if;
  perform haulvia_command.append_shipment_event(
    p_shipment.id, p_shipment.shipment_state, v_target_shipment,
    'releaseDriverBeforeAnyCustody', p_request, v_assignment.route_version_id,
    jsonb_build_object(
      'assignmentId', v_assignment.id,
      'routeExecutionId', v_execution_id,
      'financialDecisionId', v_decision_id,
      'automaticRepublish', false
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'releaseDriverBeforeAnyCustody', p_request,
    to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('financialDecisionId', v_decision_id, 'releaseOutcome', v_outcome)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'DRIVER_RELEASED_BEFORE_CUSTODY',
    p_request, 'driver-released-customer',
    jsonb_build_object('releaseOutcome', v_outcome, 'automaticRepublish', false)
  );
  return jsonb_build_object(
    'routeVersionId', v_assignment.route_version_id,
    'assignmentId', v_assignment.id,
    'routeExecutionId', v_execution_id,
    'financialDecisionId', v_decision_id,
    'releaseOutcome', v_outcome,
    'automaticRepublish', false
  );
end;
$$;

create or replace function haulvia_command.apply_b10_edit_paused_after_driver_cancellation(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_old_route uuid;
  v_new_route uuid;
  v_policy_id uuid := haulvia_command.required_uuid(p_request, 'policyVersionId');
  v_policy haulvia.policy_versions%rowtype;
  v_rule_snapshot_id uuid;
  v_price_snapshot_id uuid;
  v_deadline timestamptz;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'POSTED' then
    perform haulvia_command.fail('INVALID_STATE', 'editPausedAfterDriverCancellation requires POSTED');
  end if;
  if not exists (
    select 1 from haulvia.shipment_marketplace_axes ma
    where ma.shipment_id = p_shipment.id and ma.state = 'PAUSED'
    for update
  ) then
    perform haulvia_command.fail('INVALID_STATE', 'Marketplace must remain PAUSED after driver release');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  v_old_route := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_new_route := haulvia_command.create_route_from_plan(
    p_shipment.id, v_old_route, v_actor,
    haulvia_command.required_text(p_request, 'reason'), p_request -> 'routePlan'
  );

  select * into v_policy from haulvia.policy_versions pv
  where pv.id = v_policy_id
    and pv.publication_status = 'APPROVED'
    and pv.effective_from <= clock_timestamp()
    and (pv.effective_to is null or pv.effective_to > clock_timestamp());
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'A current approved policy version is required');
  end if;
  insert into haulvia.shipment_rule_snapshots (
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  ) values (
    p_shipment.id, v_new_route, v_policy_id,
    coalesce(v_policy.config -> 'evidenceRequirements', '{}'::jsonb),
    coalesce(v_policy.config -> 'cancellationRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'refundRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'timingWindows', '{}'::jsonb),
    coalesce(v_policy.config -> 'riskRules', '{}'::jsonb),
    v_policy.config_sha256
  ) returning id into v_rule_snapshot_id;
  v_price_snapshot_id := haulvia_command.create_price_snapshot(
    p_shipment, v_new_route, 'POSTING', p_request, v_actor
  );

  update haulvia.route_versions set status = 'SUPERSEDED' where id = v_old_route;
  update haulvia.route_versions set status = 'ACTIVE' where id = v_new_route;
  v_deadline := nullif(p_request ->> 'marketplaceDeadline', '')::timestamptz;
  if v_deadline is not null and v_deadline <= clock_timestamp() then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Edited marketplace deadline must be in the future');
  end if;
  update haulvia.shipments
  set marketplace_deadline = coalesce(v_deadline, marketplace_deadline),
      updated_at = clock_timestamp()
  where id = p_shipment.id;

  perform haulvia_command.append_audit(
    p_shipment, 'editPausedAfterDriverCancellation', p_request,
    jsonb_build_object('routeVersionId', v_old_route, 'marketplaceState', 'PAUSED'),
    jsonb_build_object('routeVersionId', v_new_route, 'marketplaceState', 'PAUSED'),
    jsonb_build_object(
      'ruleSnapshotId', v_rule_snapshot_id,
      'priceSnapshotId', v_price_snapshot_id,
      'oldAssignmentHistoryPreserved', true
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'PAUSED_SHIPMENT_EDITED',
    p_request, 'paused-shipment-edited',
    jsonb_build_object('routeVersionId', v_new_route, 'repostRequired', true)
  );
  return jsonb_build_object(
    'routeVersionId', v_new_route,
    'priorRouteVersionId', v_old_route,
    'ruleSnapshotId', v_rule_snapshot_id,
    'priceSnapshotId', v_price_snapshot_id,
    'repostRequired', true
  );
end;
$$;

create or replace function haulvia_command.apply_b11_repost_paused_shipment(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_route_id uuid;
  v_policy_id uuid := haulvia_command.required_uuid(p_request, 'policyVersionId');
  v_payment_method_id uuid := haulvia_command.required_uuid(p_request, 'paymentMethodId');
  v_deadline timestamptz := haulvia_command.required_timestamptz(p_request, 'marketplaceDeadline');
  v_price_snapshot_id uuid;
  v_payment_prior haulvia.customer_payment_state;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'POSTED' then
    perform haulvia_command.fail('INVALID_STATE', 'repostPausedShipment requires POSTED');
  end if;
  if not exists (
    select 1 from haulvia.shipment_marketplace_axes ma
    where ma.shipment_id = p_shipment.id and ma.state = 'PAUSED'
    for update
  ) then
    perform haulvia_command.fail('INVALID_STATE', 'Customer may repost only from PAUSED');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  if exists (
    select 1 from haulvia.workflow_holds wh
    where wh.shipment_id = p_shipment.id and wh.status = 'ACTIVE' and wh.blocks_marketplace
  ) then
    perform haulvia_command.fail('WORKFLOW_HELD', 'An active workflow hold blocks marketplace repost');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.validate_route_plan(v_route_id);
  if not exists (
    select 1 from haulvia.shipment_rule_snapshots srs
    join haulvia.policy_versions pv on pv.id = srs.policy_version_id
    where srs.shipment_id = p_shipment.id
      and srs.route_version_id = v_route_id
      and srs.policy_version_id = v_policy_id
      and pv.publication_status = 'APPROVED'
      and pv.effective_from <= clock_timestamp()
      and (pv.effective_to is null or pv.effective_to > clock_timestamp())
  ) then
    perform haulvia_command.fail(
      'POLICY_SNAPSHOT_MISMATCH',
      'Repost requires the current route accepted and still-effective evidence policy snapshot'
    );
  end if;
  perform haulvia_command.assert_payment_method(p_shipment, v_payment_method_id);
  if v_deadline <= clock_timestamp() then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Repost marketplace deadline must be in the future');
  end if;
  v_price_snapshot_id := haulvia_command.create_price_snapshot(
    p_shipment, v_route_id, 'POSTING', p_request, v_actor
  );

  select state into v_payment_prior
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id
  for update;
  update haulvia.shipment_customer_payment_axes
  set state = 'METHOD_VERIFIED', secured_amount = 0,
      currency = p_shipment.currency, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_marketplace_axes
  set state = 'ACTIVE', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments
  set marketplace_deadline = v_deadline, updated_at = clock_timestamp()
  where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'MARKETPLACE', 'PAUSED', 'ACTIVE',
    'repostPausedShipment', p_request, null,
    jsonb_build_object('automaticRepublish', false)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment_prior::text, 'METHOD_VERIFIED',
    'repostPausedShipment', p_request, v_payment_method_id
  );
  perform haulvia_command.append_audit(
    p_shipment, 'repostPausedShipment', p_request,
    jsonb_build_object('marketplaceState', 'PAUSED'),
    jsonb_build_object('marketplaceState', 'ACTIVE'),
    jsonb_build_object(
      'routeVersionId', v_route_id,
      'priceSnapshotId', v_price_snapshot_id,
      'paymentMethodId', v_payment_method_id,
      'oldOffersAndAssignmentsPreserved', true
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'PAUSED_SHIPMENT_REPOSTED',
    p_request, 'paused-shipment-reposted',
    jsonb_build_object('routeVersionId', v_route_id, 'marketplaceDeadline', v_deadline)
  );
  perform haulvia_command.queue_job(
    p_shipment.id, 'EXPIRE_MARKETPLACE_LISTING', v_deadline, p_request,
    'reposted-marketplace-expiry', jsonb_build_object('observedRouteVersionId', v_route_id)
  );
  return jsonb_build_object(
    'routeVersionId', v_route_id,
    'priceSnapshotId', v_price_snapshot_id,
    'paymentMethodId', v_payment_method_id,
    'marketplaceDeadline', v_deadline,
    'oldOffersAndAssignmentsPreserved', true
  );
end;
$$;

create or replace function haulvia_command.apply_b12_report_pre_custody_issue(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_actor_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_execution_id uuid;
  v_stop_id uuid := haulvia_command.optional_uuid(p_request, 'stopExecutionId');
  v_cargo_item_id uuid := haulvia_command.optional_uuid(p_request, 'cargoItemId');
  v_hold jsonb := p_request -> 'workflowHold';
  v_hold_id uuid;
  v_exception_id uuid;
  v_is_customer boolean := false;
  v_is_driver boolean := false;
begin
  if p_shipment.shipment_state not in ('DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS') then
    perform haulvia_command.fail(
      'INVALID_STATE', 'reportPreCustodyIssue requires DRIVER_ASSIGNED or ROUTE_IN_PROGRESS'
    );
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  if v_actor is null then
    perform haulvia_command.assert_worker(
      v_actor, p_request ->> 'workerAuthority', array['ROUTE_OPERATIONS_WORKER']
    );
  else
    v_is_customer := (
      p_shipment.customer_profile_id = v_actor
      or (
        p_shipment.customer_organization_id = v_actor_org
        and exists (
          select 1 from haulvia.organization_memberships om
          where om.organization_id = v_actor_org and om.profile_id = v_actor
            and om.status = 'ACTIVE'
            and (om.ends_at is null or om.ends_at > clock_timestamp())
        )
      )
    );
    v_is_driver := exists (
      select 1 from haulvia.drivers d
      where d.id = v_assignment.driver_id and d.profile_id = v_actor
    );
    if not v_is_customer and not v_is_driver then
      perform haulvia_command.fail(
        'NOT_AUTHORIZED', 'Only the customer, assigned driver, or trusted system may report this issue'
      );
    end if;
  end if;
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  if v_cargo_item_id is not null and not exists (
    select 1 from haulvia.cargo_items ci
    where ci.id = v_cargo_item_id and ci.route_version_id = v_assignment.route_version_id
  ) then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'Issue cargo item is outside the current route');
  end if;

  if p_shipment.shipment_state = 'ROUTE_IN_PROGRESS' then
    v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
    v_execution_id := v_execution.id;
    if v_stop_id is not null and not exists (
      select 1 from haulvia.stop_executions se
      where se.id = v_stop_id and se.route_execution_id = v_execution_id
    ) then
      perform haulvia_command.fail('STOP_NOT_CURRENT', 'Issue stop does not belong to the current route execution');
    end if;
  elsif p_request ? 'expectedRouteExecutionId' or v_stop_id is not null then
    perform haulvia_command.fail('INVALID_REQUEST', 'A pre-start issue cannot name an execution stop');
  end if;

  if v_hold is not null and jsonb_typeof(v_hold) <> 'null' then
    if jsonb_typeof(v_hold) <> 'object' or v_hold = '{}'::jsonb then
      perform haulvia_command.fail('INVALID_REQUEST', 'workflowHold must be a non-empty object when supplied');
    end if;
    insert into haulvia.workflow_holds (
      shipment_id, route_execution_id, stop_execution_id, hold_code, status,
      blocks_marketplace, blocks_route_movement, blocks_completion,
      reason, opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution_id, v_stop_id,
      haulvia_command.required_text(v_hold, 'holdCode'), 'ACTIVE',
      coalesce(nullif(v_hold ->> 'blocksMarketplace', '')::boolean, false),
      coalesce(nullif(v_hold ->> 'blocksRouteMovement', '')::boolean, false),
      coalesce(nullif(v_hold ->> 'blocksCompletion', '')::boolean, false),
      haulvia_command.required_text(v_hold, 'reason'), v_actor,
      coalesce(v_hold -> 'metadata', '{}'::jsonb)
    ) returning id into v_hold_id;
  end if;

  insert into haulvia.route_exceptions (
    shipment_id, route_execution_id, stop_execution_id, cargo_item_id,
    workflow_hold_id, exception_code, status, responsibility_code,
    blocks_completion, description, opened_by_profile_id, metadata
  ) values (
    p_shipment.id, v_execution_id, v_stop_id,
    v_cargo_item_id, v_hold_id,
    haulvia_command.required_text(p_request, 'exceptionCode'), 'OPEN',
    nullif(p_request ->> 'responsibilityCode', ''),
    coalesce(nullif(p_request ->> 'blocksCompletion', '')::boolean, false),
    haulvia_command.required_text(p_request, 'description'), v_actor,
    coalesce(p_request -> 'issueEvidence', '{}'::jsonb)
  ) returning id into v_exception_id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  if v_hold_id is not null then
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'WORKFLOW_HOLD', null, 'ACTIVE',
      'reportPreCustodyIssue', p_request, v_hold_id,
      jsonb_build_object('routeExceptionId', v_exception_id)
    );
  end if;
  perform haulvia_command.append_audit(
    p_shipment, 'reportPreCustodyIssue', p_request,
    jsonb_build_object(
      'shipmentState', p_shipment.shipment_state,
      'stopState', case when v_stop_id is null then null else (select state::text from haulvia.stop_executions where id = v_stop_id) end
    ),
    jsonb_build_object(
      'shipmentState', p_shipment.shipment_state,
      'stopState', case when v_stop_id is null then null else (select state::text from haulvia.stop_executions where id = v_stop_id) end
    ),
    jsonb_build_object('routeExceptionId', v_exception_id, 'workflowHoldId', v_hold_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'PRE_CUSTODY_ISSUE_REPORTED',
    p_request, 'pre-custody-issue-customer',
    jsonb_build_object('routeExceptionId', v_exception_id, 'workflowHoldId', v_hold_id)
  );
  return jsonb_build_object(
    'routeVersionId', v_assignment.route_version_id,
    'assignmentId', v_assignment.id,
    'routeExecutionId', v_execution_id,
    'stopExecutionId', v_stop_id,
    'routeExceptionId', v_exception_id,
    'workflowHoldId', v_hold_id,
    'physicalPositionChanged', false
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Trusted dispatcher and the 12 approved named Block B command entry points
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.execute_block_b_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_command_id uuid := haulvia_command.required_uuid(p_request, 'commandId');
  v_idempotency_key text := haulvia_command.required_text(p_request, 'idempotencyKey');
  v_request_hash text := haulvia_command.required_text(p_request, 'requestHash');
  v_replay jsonb;
  v_shipment haulvia.shipments%rowtype;
  v_affected jsonb;
  v_result jsonb;
begin
  v_replay := haulvia_command.begin_request(
    v_actor, p_command_name, v_idempotency_key, v_request_hash
  );
  if v_replay is not null then
    return v_replay;
  end if;

  v_shipment := haulvia_command.lock_shipment(p_request);
  case p_command_name
    when 'startRoute' then
      v_affected := haulvia_command.apply_b01_start_route(v_shipment, p_request);
    when 'confirmArrivalAtFirstPickup' then
      v_affected := haulvia_command.apply_b02_confirm_first_arrival(v_shipment, p_request);
    when 'correctFirstStopArrival' then
      v_affected := haulvia_command.apply_b03_correct_first_arrival(v_shipment, p_request);
    when 'startFirstPickupService' then
      v_affected := haulvia_command.apply_b04_start_first_pickup_service(v_shipment, p_request);
    when 'submitFirstPickupEvidence' then
      v_affected := haulvia_command.apply_b05_submit_first_pickup_evidence(v_shipment, p_request);
    when 'verifyFirstPickup' then
      v_affected := haulvia_command.apply_b06_verify_first_pickup(v_shipment, p_request);
    when 'reportFailedFirstPickup' then
      v_affected := haulvia_command.apply_b07_report_failed_first_pickup(v_shipment, p_request);
    when 'cancelBeforeAnyCustody' then
      v_affected := haulvia_command.apply_b08_cancel_before_any_custody(v_shipment, p_request);
    when 'releaseDriverBeforeAnyCustody' then
      v_affected := haulvia_command.apply_b09_release_driver_before_any_custody(v_shipment, p_request);
    when 'editPausedAfterDriverCancellation' then
      v_affected := haulvia_command.apply_b10_edit_paused_after_driver_cancellation(v_shipment, p_request);
    when 'repostPausedShipment' then
      v_affected := haulvia_command.apply_b11_repost_paused_shipment(v_shipment, p_request);
    when 'reportPreCustodyIssue' then
      v_affected := haulvia_command.apply_b12_report_pre_custody_issue(v_shipment, p_request);
    else
      perform haulvia_command.fail('INVALID_REQUEST', 'Command is not an approved Block B handler');
  end case;

  v_result := haulvia_command.operating_context(
    v_shipment.id, p_command_name, v_command_id, v_affected
  );
  return haulvia_command.complete_request(
    v_actor, p_command_name, v_idempotency_key, v_result
  );
end;
$$;

create or replace function haulvia_command.command_start_route(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('startRoute', p_request); $$;

create or replace function haulvia_command.command_confirm_arrival_at_first_pickup(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('confirmArrivalAtFirstPickup', p_request); $$;

create or replace function haulvia_command.command_correct_first_stop_arrival(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('correctFirstStopArrival', p_request); $$;

create or replace function haulvia_command.command_start_first_pickup_service(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('startFirstPickupService', p_request); $$;

create or replace function haulvia_command.command_submit_first_pickup_evidence(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('submitFirstPickupEvidence', p_request); $$;

create or replace function haulvia_command.command_verify_first_pickup(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('verifyFirstPickup', p_request); $$;

create or replace function haulvia_command.command_report_failed_first_pickup(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('reportFailedFirstPickup', p_request); $$;

create or replace function haulvia_command.command_cancel_before_any_custody(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('cancelBeforeAnyCustody', p_request); $$;

create or replace function haulvia_command.command_release_driver_before_any_custody(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('releaseDriverBeforeAnyCustody', p_request); $$;

create or replace function haulvia_command.command_edit_paused_after_driver_cancellation(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('editPausedAfterDriverCancellation', p_request); $$;

create or replace function haulvia_command.command_repost_paused_shipment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('repostPausedShipment', p_request); $$;

create or replace function haulvia_command.command_report_pre_custody_issue(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_b_command('reportPreCustodyIssue', p_request); $$;

revoke all on all functions in schema haulvia_command from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema haulvia_command to service_role;
    grant execute on all functions in schema haulvia_command to service_role;
  end if;
end;
$$;

comment on table haulvia.shipment_custody_milestones is
  'Immutable first verified LOAD boundary. Cargo movements remain the quantity and onboard-balance authority.';
comment on table haulvia.pre_custody_financial_decisions is
  'Versioned charge, refund, and driver-compensation decision for Block B cancellation/release; provider settlement remains independent.';
comment on column haulvia.route_executions.active_stop_execution_id is
  'Current physical stop pointer; append-only stop attempt events and route updates preserve its history.';
comment on column haulvia.route_executions.record_version is
  'Optimistic concurrency version for route/stop/custody commands.';

commit;
