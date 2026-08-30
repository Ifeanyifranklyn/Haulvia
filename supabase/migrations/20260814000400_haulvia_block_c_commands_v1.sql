-- Haulvia Block C command layer v1
-- Approved source: State Transition Matrix v1.1, Block C (C01-C14)
-- Depends on: foundation v1, Block A v1, and Block B v1
-- Target: PostgreSQL 16; compatible with Supabase Postgres
-- Security boundary: trusted service role only; end-user RLS remains deferred.

begin;

set local search_path = haulvia, haulvia_command, public;

-- Block C retains a mutable ETA pointer on each stop while every calculation
-- and downstream prediction remains append-only.
alter table haulvia.stop_executions
  add column current_eta_at timestamptz,
  add column eta_updated_at timestamptz,
  add column waiting_free_until timestamptz,
  add constraint stop_executions_eta_pair_ck check (
    (current_eta_at is null and eta_updated_at is null)
    or (current_eta_at is not null and eta_updated_at is not null)
  );

create table haulvia.route_eta_calculations (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  trigger_stop_execution_id uuid references haulvia.stop_executions(id),
  source_route_update_id uuid references haulvia.route_updates(id),
  command_name text not null,
  base_eta_at timestamptz not null,
  delay_seconds integer not null default 0,
  calculation_snapshot jsonb not null,
  calculated_by_profile_id uuid references haulvia.profiles(id),
  idempotency_key text not null,
  calculated_at timestamptz not null default clock_timestamp(),
  unique (route_execution_id, command_name, idempotency_key),
  unique (id, route_execution_id),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, route_version_id)
    references haulvia.route_versions(shipment_id, id),
  check (calculation_snapshot <> '{}'::jsonb)
);

create table haulvia.route_stop_eta_predictions (
  id uuid primary key default gen_random_uuid(),
  route_eta_calculation_id uuid not null,
  route_execution_id uuid not null,
  stop_execution_id uuid not null,
  prior_eta_at timestamptz,
  eta_at timestamptz not null,
  drive_seconds_before integer not null,
  service_seconds_before integer not null,
  changed_seconds integer,
  notification_event_id uuid references haulvia.notification_events(id),
  created_at timestamptz not null default clock_timestamp(),
  unique (route_eta_calculation_id, stop_execution_id),
  foreign key (route_eta_calculation_id, route_execution_id)
    references haulvia.route_eta_calculations(id, route_execution_id),
  foreign key (stop_execution_id)
    references haulvia.stop_executions(id),
  check (drive_seconds_before >= 0),
  check (service_seconds_before >= 0)
);

-- A failure report is the immutable attempt-level fact. Continuing the route
-- is a separate authorization so a failed stop is never rewritten as success.
create table haulvia.stop_failure_reports (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  stop_attempt_id uuid not null references haulvia.stop_attempts(id),
  route_exception_id uuid not null references haulvia.route_exceptions(id),
  command_name text not null check (
    command_name in ('reportFailedPickupStop', 'reportFailedDeliveryStop')
  ),
  reported_stop_state haulvia.stop_state not null check (
    reported_stop_state in ('FAILED', 'EXCEPTION_REVIEW')
  ),
  responsibility_code text not null,
  failure_reason text not null,
  affected_cargo jsonb not null,
  custody_balance_snapshot jsonb not null,
  downstream_impact jsonb not null,
  approved_next_route_decision jsonb,
  grace_period_ended_at timestamptz not null,
  reported_by_profile_id uuid references haulvia.profiles(id),
  reported_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  unique (stop_attempt_id, command_name, idempotency_key),
  unique (id, route_execution_id),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, route_version_id)
    references haulvia.route_versions(shipment_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  check (length(btrim(failure_reason)) >= 8),
  check (affected_cargo <> '[]'::jsonb),
  check (custody_balance_snapshot <> '{}'::jsonb),
  check (downstream_impact <> '{}'::jsonb)
);

create table haulvia.stop_continuation_authorizations (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  stop_failure_report_id uuid not null unique,
  failed_stop_execution_id uuid not null references haulvia.stop_executions(id),
  next_stop_execution_id uuid not null references haulvia.stop_executions(id),
  decision_code text not null check (
    decision_code in ('SKIP', 'RECOVERY', 'AMENDMENT', 'RETURN', 'REDELIVERY',
                      'ALTERNATE_DESTINATION', 'TRANSFER', 'STORAGE')
  ),
  route_feasibility_snapshot jsonb not null,
  capacity_snapshot jsonb not null,
  timing_snapshot jsonb not null,
  custody_balance_snapshot jsonb not null,
  customer_instructions jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  unique (route_execution_id, idempotency_key),
  foreign key (stop_failure_report_id, route_execution_id)
    references haulvia.stop_failure_reports(id, route_execution_id),
  check (route_feasibility_snapshot <> '{}'::jsonb),
  check (capacity_snapshot <> '{}'::jsonb),
  check (timing_snapshot <> '{}'::jsonb),
  check (custody_balance_snapshot <> '{}'::jsonb),
  check (customer_instructions <> '{}'::jsonb)
);

-- A post-assignment material change creates both a new immutable route version
-- and a new execution segment while retaining the original plan and attempts.
create table haulvia.route_amendments (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  assignment_id uuid not null references haulvia.assignments(id),
  prior_route_version_id uuid not null references haulvia.route_versions(id),
  amended_route_version_id uuid not null references haulvia.route_versions(id),
  prior_route_execution_id uuid not null references haulvia.route_executions(id),
  amended_route_execution_id uuid not null references haulvia.route_executions(id),
  price_snapshot_id uuid not null references haulvia.shipment_price_snapshots(id),
  additional_payment_intent_id uuid references haulvia.payment_intents(id),
  additional_payment_amount numeric(14,2) not null default 0,
  currency char(3) not null,
  emergency_waiver boolean not null default false,
  reason text not null,
  driver_acceptance_snapshot jsonb not null,
  amendment_snapshot jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  unique (shipment_id, idempotency_key),
  unique (amended_route_version_id),
  unique (amended_route_execution_id),
  foreign key (shipment_id, assignment_id)
    references haulvia.assignments(shipment_id, id),
  foreign key (shipment_id, prior_route_version_id)
    references haulvia.route_versions(shipment_id, id),
  foreign key (shipment_id, amended_route_version_id)
    references haulvia.route_versions(shipment_id, id),
  foreign key (shipment_id, prior_route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, amended_route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, price_snapshot_id)
    references haulvia.shipment_price_snapshots(shipment_id, id),
  foreign key (shipment_id, additional_payment_intent_id)
    references haulvia.payment_intents(shipment_id, id),
  check (prior_route_version_id <> amended_route_version_id),
  check (prior_route_execution_id <> amended_route_execution_id),
  check (additional_payment_amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check (length(btrim(reason)) >= 8),
  check (driver_acceptance_snapshot <> '{}'::jsonb),
  check (amendment_snapshot <> '{}'::jsonb)
);

-- These rows make aggregate DELIVERED explainable: each quantity is tied to
-- verified delivery or an approved recovery outcome rather than a vague flag.
create table haulvia.cargo_resolution_outcomes (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  cargo_allocation_id uuid not null references haulvia.cargo_allocations(id),
  cargo_movement_id uuid references haulvia.cargo_movements(id),
  outcome_code text not null check (
    outcome_code in ('DELIVERED', 'RETURNED', 'STORED', 'TRANSFERRED',
                     'APPROVED_NOT_LOADED', 'OTHER_APPROVED_RECOVERY')
  ),
  quantity numeric(14,3) not null,
  quantity_unit text not null,
  approval_snapshot jsonb not null,
  approved_by_profile_id uuid references haulvia.profiles(id),
  occurred_at timestamptz not null,
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_execution_id, idempotency_key),
  unique (cargo_movement_id),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (route_version_id, cargo_allocation_id)
    references haulvia.cargo_allocations(route_version_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  check (quantity > 0),
  check (approval_snapshot <> '{}'::jsonb)
);

create table haulvia.route_resolution_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null unique references haulvia.shipments(id),
  route_execution_id uuid not null unique references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  public_outcome_label text not null check (
    public_outcome_label ~
      '^(DELIVERED|RETURNED|STORED|TRANSFERRED|APPROVED NOT LOADED|OTHER APPROVED RECOVERY)( \\+ (DELIVERED|RETURNED|STORED|TRANSFERRED|APPROVED NOT LOADED|OTHER APPROVED RECOVERY))*$'
  ),
  outcome_summary jsonb not null,
  custody_reconciliation jsonb not null,
  evidence_reconciliation jsonb not null,
  resolved_by_profile_id uuid references haulvia.profiles(id),
  resolved_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, route_version_id)
    references haulvia.route_versions(shipment_id, id),
  check (outcome_summary <> '{}'::jsonb),
  check (custody_reconciliation <> '{}'::jsonb),
  check (evidence_reconciliation <> '{}'::jsonb)
);

create index route_eta_calculations_timeline_idx
  on haulvia.route_eta_calculations (route_execution_id, calculated_at, id);
create index route_stop_eta_predictions_stop_idx
  on haulvia.route_stop_eta_predictions (stop_execution_id, created_at desc);
create index stop_failure_reports_open_idx
  on haulvia.stop_failure_reports (shipment_id, route_execution_id, reported_at desc);
create index cargo_resolution_outcomes_allocation_idx
  on haulvia.cargo_resolution_outcomes (cargo_allocation_id, occurred_at, id);

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'route_eta_calculations', 'route_stop_eta_predictions',
    'stop_failure_reports', 'stop_continuation_authorizations',
    'route_amendments', 'cargo_resolution_outcomes', 'route_resolution_records'
  ]
  loop
    execute format(
      'create trigger %I before update or delete on haulvia.%I for each row execute function haulvia.reject_append_only_mutation()',
      v_table || '_append_only', v_table
    );
  end loop;
end;
$$;

-- Retain the exact named Block C edges alongside the reusable foundation rules.
insert into haulvia.stop_state_transition_rules (from_state, to_state, command_name) values
  ('PENDING', 'EN_ROUTE', 'authorizeContinueAfterStopFailure'),
  ('EVIDENCE_PENDING', 'COMPLETED', 'verifyPickupStop'),
  ('EVIDENCE_PENDING', 'COMPLETED', 'verifyDeliveryStop'),
  ('EN_ROUTE', 'FAILED', 'reportFailedPickupStop'),
  ('ARRIVED', 'FAILED', 'reportFailedPickupStop'),
  ('SERVICE_IN_PROGRESS', 'FAILED', 'reportFailedPickupStop'),
  ('EVIDENCE_PENDING', 'FAILED', 'reportFailedPickupStop'),
  ('EN_ROUTE', 'EXCEPTION_REVIEW', 'reportFailedPickupStop'),
  ('ARRIVED', 'EXCEPTION_REVIEW', 'reportFailedPickupStop'),
  ('SERVICE_IN_PROGRESS', 'EXCEPTION_REVIEW', 'reportFailedPickupStop'),
  ('EVIDENCE_PENDING', 'EXCEPTION_REVIEW', 'reportFailedPickupStop'),
  ('EN_ROUTE', 'FAILED', 'reportFailedDeliveryStop'),
  ('ARRIVED', 'FAILED', 'reportFailedDeliveryStop'),
  ('SERVICE_IN_PROGRESS', 'FAILED', 'reportFailedDeliveryStop'),
  ('EVIDENCE_PENDING', 'FAILED', 'reportFailedDeliveryStop'),
  ('EN_ROUTE', 'EXCEPTION_REVIEW', 'reportFailedDeliveryStop'),
  ('ARRIVED', 'EXCEPTION_REVIEW', 'reportFailedDeliveryStop'),
  ('SERVICE_IN_PROGRESS', 'EXCEPTION_REVIEW', 'reportFailedDeliveryStop'),
  ('EVIDENCE_PENDING', 'EXCEPTION_REVIEW', 'reportFailedDeliveryStop'),
  ('EXCEPTION_REVIEW', 'CANCELLED', 'authorizeRouteAmendment')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Block C shared stop, custody, ETA, and authorization helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.optional_integer(p_request jsonb, p_key text)
returns integer
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_text text := nullif(btrim(p_request ->> p_key), '');
begin
  if v_text is null then
    return null;
  end if;
  return v_text::integer;
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail(
    'INVALID_REQUEST', format('Request field %s must be an integer', p_key),
    jsonb_build_object('field', p_key)
  );
  return null;
end;
$$;

create or replace function haulvia_command.current_custody_summary(p_shipment_id uuid)
returns jsonb
language sql
stable
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select jsonb_build_object(
    'hasVerifiedCustody', exists (
      select 1 from haulvia.shipment_custody_milestones scm
      where scm.shipment_id = p_shipment_id
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
  )
  from haulvia.v_cargo_custody_balance cb
  where cb.shipment_id = p_shipment_id;
$$;

create or replace function haulvia_command.assert_custody_snapshot(
  p_shipment_id uuid,
  p_snapshot jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_current jsonb := haulvia_command.current_custody_summary(p_shipment_id);
begin
  if jsonb_typeof(p_snapshot) <> 'object'
     or jsonb_typeof(p_snapshot -> 'balances') <> 'array'
     or p_snapshot -> 'balances' is distinct from v_current -> 'balances'
     or (
       p_snapshot ? 'hasVerifiedCustody'
       and p_snapshot -> 'hasVerifiedCustody' is distinct from v_current -> 'hasVerifiedCustody'
     ) then
    perform haulvia_command.fail(
      'CUSTODY_SNAPSHOT_STALE',
      'The supplied custody balance does not match the immutable movement ledger',
      jsonb_build_object('current', v_current)
    );
  end if;
  return v_current;
end;
$$;

create or replace function haulvia_command.assert_route_movement_unheld(p_shipment_id uuid)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if exists (
    select 1 from haulvia.workflow_holds wh
    where wh.shipment_id = p_shipment_id
      and wh.status = 'ACTIVE'
      and wh.blocks_route_movement
  ) then
    perform haulvia_command.fail('WORKFLOW_HELD', 'An active workflow hold blocks route movement');
  end if;
end;
$$;

create or replace function haulvia_command.lock_current_stop_execution(
  p_execution haulvia.route_executions,
  p_request jsonb,
  p_require_later_stop boolean default true
)
returns haulvia.stop_executions
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_stop haulvia.stop_executions%rowtype;
  v_stop_id uuid := haulvia_command.required_uuid(p_request, 'expectedStopExecutionId');
  v_sequence integer;
begin
  select se.* into v_stop
  from haulvia.stop_executions se
  join haulvia.route_stops rs
    on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
  where se.id = v_stop_id
    and se.route_execution_id = p_execution.id
    and se.route_version_id = p_execution.route_version_id
  for update of se;

  if not found or p_execution.active_stop_execution_id is distinct from v_stop.id then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'The expected stop is not the active route stop');
  end if;
  select rs.sequence_no into v_sequence
  from haulvia.route_stops rs
  where rs.id=v_stop.route_stop_id and rs.route_version_id=v_stop.route_version_id;
  if p_require_later_stop and v_sequence <= 1 then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'Block C reusable stop commands require a later ordered stop');
  end if;
  return v_stop;
end;
$$;

create or replace function haulvia_command.lock_current_stop_attempt(
  p_stop haulvia.stop_executions
)
returns haulvia.stop_attempts
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_attempt haulvia.stop_attempts%rowtype;
begin
  select * into v_attempt
  from haulvia.stop_attempts sa
  where sa.stop_execution_id = p_stop.id
    and sa.attempt_no = p_stop.current_attempt_no
  for update;
  if not found or v_attempt.ended_at is not null then
    perform haulvia_command.fail('INVALID_STATE', 'The current stop has no active attempt');
  end if;
  return v_attempt;
end;
$$;

create or replace function haulvia_command.authorize_customer_or_route_workflow(
  p_shipment haulvia.shipments,
  p_assignment haulvia.assignments,
  p_request jsonb
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
      v_actor, p_request ->> 'workerAuthority', array['ROUTE_OPERATIONS_WORKER']
    );
    return;
  end if;
  if p_shipment.customer_profile_id = v_actor
     or (p_shipment.customer_organization_id is not null
         and p_shipment.customer_organization_id = v_org
         and exists (
           select 1 from haulvia.organization_memberships om
           where om.organization_id = v_org and om.profile_id = v_actor
             and om.status = 'ACTIVE'
             and (om.ends_at is null or om.ends_at > clock_timestamp())
         )) then
    return;
  end if;
  perform haulvia_command.authorize_route_operator(p_assignment, p_request, false);
end;
$$;

create or replace function haulvia_command.assert_stop_evidence(
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
  v_stop_type haulvia.stop_type;
  v_contactless boolean := false;
  v_key text;
  v_value jsonb;
  v_type haulvia.evidence_type;
begin
  select rs.stop_type,
         coalesce((rs.verification_profile ->> 'contactless')::boolean, false),
         coalesce(rs.verification_profile, '{}'::jsonb)
           || coalesce(srs.evidence_requirements, '{}'::jsonb)
           || coalesce(srs.evidence_requirements -> lower(rs.stop_type::text), '{}'::jsonb)
           || coalesce(srs.evidence_requirements -> rs.stop_type::text, '{}'::jsonb)
  into v_stop_type, v_contactless, v_rules
  from haulvia.route_stops rs
  left join haulvia.shipment_rule_snapshots srs
    on srs.shipment_id = p_shipment_id and srs.route_version_id = p_route_version_id
  where rs.id = p_route_stop_id and rs.route_version_id = p_route_version_id;

  if not found then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'Route stop was not found for evidence review');
  end if;
  if not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='GPS')
     or not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='TIMESTAMP')
     or not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='PHOTO')
     or not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='QUANTITY') then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Every verified stop requires GPS, timestamp, photo, and quantity evidence');
  end if;

  if v_stop_type = 'PICKUP' and (
    not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='CONDITION')
    or not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type in ('PIN','QR'))
  ) then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Pickup verification requires condition and PIN or QR evidence');
  end if;
  if v_stop_type = 'DELIVERY' and not v_contactless and not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id=p_attempt_id and e.evidence_type in ('PIN','QR','SIGNATURE')
  ) then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Standard delivery requires PIN, QR, or signature evidence');
  end if;
  if v_stop_type = 'DELIVERY' and v_contactless and (
    not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='IDENTIFIER')
    or not exists (select 1 from haulvia.stop_evidence e where e.stop_attempt_id=p_attempt_id and e.evidence_type='CONDITION')
  ) then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Contactless delivery requires identifier/count and condition evidence');
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
        perform haulvia_command.fail('EVIDENCE_INVALID', format('Snapshot-required %s evidence is missing', v_type::text));
      end if;
    end if;
  end loop;

  if exists (
    select 1 from haulvia.stop_attempts sa
    where sa.id = p_attempt_id and sa.offline_started_at is not null and sa.synced_at is null
  ) then
    perform haulvia_command.fail('EVIDENCE_NOT_SYNCED', 'Offline stop evidence must synchronize before custody changes');
  end if;
end;
$$;

create or replace function haulvia_command.verify_stop_evidence_reviews(
  p_attempt_id uuid,
  p_request jsonb
)
returns integer
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_label text := coalesce(
    nullif(p_request ->> 'reviewerLabel', ''),
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SYSTEM:EVIDENCE_REVIEWER'
      else 'PROFILE:' || haulvia_command.optional_uuid(p_request, 'actorProfileId')::text
    end
  );
  v_count integer;
begin
  insert into haulvia.stop_evidence_reviews (
    stop_evidence_id, status, reviewer_profile_id, reviewer_label, note, metadata
  )
  select e.id, 'VERIFIED', haulvia_command.optional_uuid(p_request, 'actorProfileId'),
         v_label, nullif(p_request ->> 'reviewNote', ''),
         jsonb_build_object('commandId', haulvia_command.required_uuid(p_request, 'commandId'))
  from haulvia.stop_evidence e
  where e.stop_attempt_id = p_attempt_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function haulvia_command.recalculate_downstream_etas(
  p_shipment_id uuid,
  p_route_execution_id uuid,
  p_trigger_stop_execution_id uuid,
  p_command_name text,
  p_request jsonb,
  p_base_eta_at timestamptz,
  p_source_route_update_id uuid default null,
  p_delay_seconds integer default 0
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_execution haulvia.route_executions%rowtype;
  v_trigger_sequence integer;
  v_threshold integer;
  v_calculation_id uuid;
  v_row record;
  v_drive integer;
  v_service integer;
  v_eta timestamptz;
  v_changed integer;
  v_notification_id uuid;
  v_idempotency text := haulvia_command.required_text(p_request, 'idempotencyKey');
begin
  if p_base_eta_at is null then
    perform haulvia_command.fail('ETA_INVALID', 'A base ETA is required for downstream calculation');
  end if;
  select * into v_execution
  from haulvia.route_executions re
  where re.id = p_route_execution_id and re.shipment_id = p_shipment_id;
  if not found then
    perform haulvia_command.fail('ROUTE_EXECUTION_NOT_FOUND', 'ETA calculation route execution was not found');
  end if;
  select rs.sequence_no into v_trigger_sequence
  from haulvia.stop_executions se
  join haulvia.route_stops rs
    on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
  where se.id = p_trigger_stop_execution_id
    and se.route_execution_id = p_route_execution_id;
  if not found then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'ETA trigger stop does not belong to the execution');
  end if;

  v_threshold := haulvia_command.optional_integer(p_request, 'etaNotificationThresholdSeconds');
  if v_threshold is null then
    select nullif(srs.timing_windows ->> 'etaNotificationThresholdSeconds', '')::integer
    into v_threshold
    from haulvia.shipment_rule_snapshots srs
    where srs.shipment_id = p_shipment_id
      and srs.route_version_id = v_execution.route_version_id;
  end if;
  v_threshold := coalesce(v_threshold, 0);
  if v_threshold < 0 then
    perform haulvia_command.fail('ETA_INVALID', 'ETA notification threshold cannot be negative');
  end if;

  insert into haulvia.route_eta_calculations (
    shipment_id, route_execution_id, route_version_id,
    trigger_stop_execution_id, source_route_update_id, command_name,
    base_eta_at, delay_seconds, calculation_snapshot,
    calculated_by_profile_id, idempotency_key
  ) values (
    p_shipment_id, p_route_execution_id, v_execution.route_version_id,
    p_trigger_stop_execution_id, p_source_route_update_id, p_command_name,
    p_base_eta_at, coalesce(p_delay_seconds, 0),
    jsonb_build_object(
      'formula', 'BASE_ETA_PLUS_REMAINING_LEGS_AND_EXPECTED_SERVICE',
      'triggerSequence', v_trigger_sequence,
      'notificationThresholdSeconds', v_threshold,
      'custodySummary', haulvia_command.current_custody_summary(p_shipment_id)
    ),
    haulvia_command.optional_uuid(p_request, 'actorProfileId'), v_idempotency
  ) returning id into v_calculation_id;

  for v_row in
    select se.id as stop_execution_id, se.current_eta_at,
           rs.sequence_no, rs.planned_service_seconds
    from haulvia.stop_executions se
    join haulvia.route_stops rs
      on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
    where se.route_execution_id = p_route_execution_id
      and rs.sequence_no >= v_trigger_sequence
      and se.state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED')
    order by rs.sequence_no
  loop
    select coalesce(sum(coalesce(rl.planned_duration_seconds, 0)), 0)::integer
    into v_drive
    from haulvia.route_legs rl
    where rl.route_version_id = v_execution.route_version_id
      and rl.sequence_no >= v_trigger_sequence
      and rl.sequence_no < v_row.sequence_no;

    select coalesce(sum(rs.planned_service_seconds), 0)::integer
    into v_service
    from haulvia.route_stops rs
    join haulvia.stop_executions service_se
      on service_se.route_stop_id=rs.id
     and service_se.route_version_id=rs.route_version_id
     and service_se.route_execution_id=p_route_execution_id
    where rs.route_version_id = v_execution.route_version_id
      and rs.sequence_no >= v_trigger_sequence
      and rs.sequence_no < v_row.sequence_no
      and service_se.state not in ('COMPLETED','FAILED','SKIPPED','CANCELLED');

    v_eta := p_base_eta_at + make_interval(secs => v_drive + v_service);
    v_changed := case when v_row.current_eta_at is null then null
      else extract(epoch from (v_eta - v_row.current_eta_at))::integer end;
    v_notification_id := null;

    if v_row.sequence_no > v_trigger_sequence
       and (v_changed is null or abs(v_changed) >= v_threshold) then
      insert into haulvia.notification_events (
        shipment_id, event_code, channel, template_version, payload,
        idempotency_key
      ) values (
        p_shipment_id, 'DOWNSTREAM_STOP_ETA_UPDATED', 'SYSTEM', 'v1',
        jsonb_build_object(
          'stopExecutionId', v_row.stop_execution_id,
          'etaAt', v_eta,
          'changedSeconds', v_changed,
          'routeEtaCalculationId', v_calculation_id
        ),
        p_shipment_id::text || ':' || v_idempotency || ':eta:' || v_row.stop_execution_id::text
      ) returning id into v_notification_id;
    end if;

    insert into haulvia.route_stop_eta_predictions (
      route_eta_calculation_id, route_execution_id, stop_execution_id,
      prior_eta_at, eta_at, drive_seconds_before, service_seconds_before,
      changed_seconds, notification_event_id
    ) values (
      v_calculation_id, p_route_execution_id, v_row.stop_execution_id,
      v_row.current_eta_at, v_eta, v_drive, v_service,
      v_changed, v_notification_id
    );

    update haulvia.stop_executions
    set current_eta_at = v_eta, eta_updated_at = clock_timestamp()
    where id = v_row.stop_execution_id;
  end loop;

  return v_calculation_id;
exception
  when invalid_text_representation or datetime_field_overflow then
    perform haulvia_command.fail('ETA_INVALID', 'ETA configuration or calculation is invalid');
  return null;
end;
$$;

create or replace function haulvia_command.advance_after_terminal_stop(
  p_shipment haulvia.shipments,
  p_execution haulvia.route_executions,
  p_current_stop haulvia.stop_executions,
  p_request jsonb,
  p_command_name text
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_current_sequence integer;
  v_next_stop haulvia.stop_executions%rowtype;
  v_next_sequence integer;
  v_next_attempt_id uuid;
  v_next_attempt_no integer;
  v_leg_id uuid;
  v_route_update_id uuid;
  v_eta_calculation_id uuid;
  v_next_eta timestamptz := haulvia_command.required_timestamptz(p_request, 'nextStopEtaAt');
  v_custody jsonb := haulvia_command.current_custody_summary(p_shipment.id);
begin
  select sequence_no into v_current_sequence
  from haulvia.route_stops
  where id = p_current_stop.route_stop_id
    and route_version_id = p_execution.route_version_id;

  select se.* into v_next_stop
  from haulvia.stop_executions se
  join haulvia.route_stops rs
    on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
  where se.route_execution_id = p_execution.id
    and rs.sequence_no > v_current_sequence
    and se.state = 'PENDING'
  order by rs.sequence_no
  limit 1
  for update of se;

  if not found then
    perform haulvia_command.fail(
      'NO_NEXT_STOP',
      'No eligible pending stop remains; resolve the route instead of advancing'
    );
  end if;
  select rs.sequence_no into v_next_sequence
  from haulvia.route_stops rs
  where rs.id=v_next_stop.route_stop_id and rs.route_version_id=v_next_stop.route_version_id;

  select rl.id into v_leg_id
  from haulvia.route_legs rl
  where rl.route_version_id = p_execution.route_version_id
    and rl.from_stop_id = p_current_stop.route_stop_id
    and rl.to_stop_id = v_next_stop.route_stop_id;
  if v_leg_id is null then
    perform haulvia_command.fail(
      'ROUTE_AMENDMENT_REQUIRED',
      'The next eligible stop is not connected by the current immutable route version'
    );
  end if;

  v_next_attempt_no := v_next_stop.current_attempt_no + 1;
  insert into haulvia.stop_attempts (stop_execution_id, attempt_no, state)
  values (v_next_stop.id, v_next_attempt_no, 'EN_ROUTE')
  returning id into v_next_attempt_id;

  update haulvia.stop_executions
  set state = 'EN_ROUTE', current_attempt_no = v_next_attempt_no,
      current_eta_at = v_next_eta, eta_updated_at = clock_timestamp()
  where id = v_next_stop.id;
  update haulvia.route_executions
  set active_stop_execution_id = v_next_stop.id,
      active_route_leg_id = v_leg_id,
      next_action = 'CONFIRM_ARRIVAL_AT_STOP',
      record_version = record_version + 1
  where id = p_execution.id;

  insert into haulvia.route_updates (
    route_execution_id, active_route_leg_id, active_stop_execution_id,
    eta_at, custody_summary, captured_at, source
  ) values (
    p_execution.id, v_leg_id, v_next_stop.id, v_next_eta, v_custody,
    coalesce(nullif(p_request ->> 'occurredAt', '')::timestamptz, clock_timestamp()),
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SERVER'::haulvia.tracking_source else 'DEVICE'::haulvia.tracking_source end
  ) returning id into v_route_update_id;

  perform haulvia_command.append_stop_event(
    v_next_attempt_id, v_next_stop.id, 'PENDING', 'EN_ROUTE',
    p_command_name, p_request,
    jsonb_build_object(
      'priorStopExecutionId', p_current_stop.id,
      'activeRouteLegId', v_leg_id,
      'nextSequence', v_next_sequence
    )
  );
  v_eta_calculation_id := haulvia_command.recalculate_downstream_etas(
    p_shipment.id, p_execution.id, v_next_stop.id, p_command_name,
    p_request, v_next_eta, v_route_update_id, 0
  );

  insert into haulvia.notification_events (
    shipment_id, event_code, channel, template_version, payload,
    idempotency_key
  ) values (
    p_shipment.id, 'DRIVER_EN_ROUTE_TO_STOP', 'SYSTEM', 'v1',
    jsonb_build_object(
      'stopExecutionId', v_next_stop.id,
      'routeStopSequence', v_next_sequence,
      'etaAt', v_next_eta
    ),
    p_shipment.id::text || ':' || haulvia_command.required_text(p_request, 'idempotencyKey')
      || ':stop-en-route:' || v_next_stop.id::text
  );

  return jsonb_build_object(
    'priorStopExecutionId', p_current_stop.id,
    'stopExecutionId', v_next_stop.id,
    'stopAttemptId', v_next_attempt_id,
    'activeRouteLegId', v_leg_id,
    'routeExecutionId', p_execution.id,
    'routeExecutionVersion', p_execution.record_version + 1,
    'routeEtaCalculationId', v_eta_calculation_id,
    'nextStopEtaAt', v_next_eta
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- C01-C05: reusable advance, arrival, correction, service, and evidence loop
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_c01_advance_to_next_stop(
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
  v_result jsonb;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'advanceToNextStop requires ROUTE_IN_PROGRESS');
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
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state not in ('COMPLETED', 'SKIPPED', 'CANCELLED') then
    perform haulvia_command.fail(
      'CURRENT_STOP_UNRESOLVED',
      'The current stop must be completed or carry an authorized terminal outcome before advancing'
    );
  end if;
  perform haulvia_command.assert_route_movement_unheld(p_shipment.id);

  v_result := haulvia_command.advance_after_terminal_stop(
    p_shipment, v_execution, v_stop, p_request, 'advanceToNextStop'
  );
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'ROUTE_EXECUTION', 'ACTIVE', 'ACTIVE',
    'advanceToNextStop', p_request, v_execution.id,
    jsonb_build_object(
      'priorStopExecutionId', v_stop.id,
      'nextStopExecutionId', v_result ->> 'stopExecutionId'
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'advanceToNextStop', p_request,
    jsonb_build_object('activeStopExecutionId', v_stop.id),
    jsonb_build_object('activeStopExecutionId', v_result ->> 'stopExecutionId'),
    v_result
  );
  return v_result;
end;
$$;

create or replace function haulvia_command.apply_c02_confirm_arrival_at_stop(
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
  v_within boolean := false;
  v_exception_reason text := nullif(btrim(p_request ->> 'gpsExceptionReason'), '');
  v_route_update_id uuid;
  v_eta_calculation_id uuid;
  v_exception_id uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'confirmArrivalAtStop requires ROUTE_IN_PROGRESS');
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
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, true);
  if v_stop.state <> 'EN_ROUTE' then
    perform haulvia_command.fail('INVALID_STATE', 'The current stop must be EN_ROUTE before arrival');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  if v_attempt.state <> 'EN_ROUTE' then
    perform haulvia_command.fail('INVALID_STATE', 'The current stop attempt is not en route');
  end if;
  select * into v_route_stop
  from haulvia.route_stops rs
  where rs.id = v_stop.route_stop_id and rs.route_version_id = v_stop.route_version_id;

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
    v_exception_reason is null or length(v_exception_reason) < 8
    or jsonb_typeof(p_request -> 'gpsExceptionEvidence') <> 'object'
    or p_request -> 'gpsExceptionEvidence' = '{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'LOCATION_NOT_VERIFIED',
      'Arrival must be inside the configured radius or carry a documented exception'
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

  if not v_within then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id,
      exception_code, status, blocks_completion, description,
      opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id,
      'DOCUMENTED_ARRIVAL_LOCATION_EXCEPTION', 'OPEN', false,
      v_exception_reason, haulvia_command.required_uuid(p_request, 'actorProfileId'),
      p_request -> 'gpsExceptionEvidence'
    ) returning id into v_exception_id;
  end if;

  update haulvia.stop_executions
  set state = 'ARRIVED', waiting_free_until = v_free_until,
      current_eta_at = v_captured, eta_updated_at = clock_timestamp()
  where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'ARRIVED', arrived_at = v_captured
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'START_STOP_SERVICE', record_version = record_version + 1
  where id = v_execution.id;
  insert into haulvia.route_updates (
    route_execution_id, active_route_leg_id, active_stop_execution_id,
    eta_at, dwell_seconds, custody_summary, captured_at, source
  ) values (
    v_execution.id, v_execution.active_route_leg_id, v_stop.id,
    v_captured, 0, haulvia_command.current_custody_summary(p_shipment.id),
    v_captured, 'DEVICE'
  ) returning id into v_route_update_id;
  v_eta_calculation_id := haulvia_command.recalculate_downstream_etas(
    p_shipment.id, v_execution.id, v_stop.id, 'confirmArrivalAtStop',
    p_request, v_captured, v_route_update_id, 0
  );
  perform haulvia_command.queue_job(
    p_shipment.id, 'STOP_WAITING_GRACE_EXPIRES', v_free_until, p_request,
    'stop-waiting-' || v_stop.id::text,
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
    'confirmArrivalAtStop', p_request,
    jsonb_build_object(
      'distanceMetres', v_distance, 'withinRadius', v_within,
      'waitingFreeUntil', v_free_until,
      'routeEtaCalculationId', v_eta_calculation_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'confirmArrivalAtStop', p_request,
    jsonb_build_object('stopState', 'EN_ROUTE'),
    jsonb_build_object('stopState', 'ARRIVED'),
    jsonb_build_object(
      'stopExecutionId', v_stop.id, 'withinRadius', v_within,
      'routeExceptionId', v_exception_id
    )
  );
  insert into haulvia.notification_events (
    shipment_id, event_code, channel, template_version, payload, idempotency_key
  ) values (
    p_shipment.id, 'DRIVER_ARRIVED_AT_STOP', 'SYSTEM', 'v1',
    jsonb_build_object('stopExecutionId', v_stop.id, 'waitingFreeUntil', v_free_until),
    p_shipment.id::text || ':' || haulvia_command.required_text(p_request, 'idempotencyKey')
      || ':arrival:' || v_stop.id::text
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'distanceMetres', v_distance,
    'withinRadius', v_within,
    'waitingFreeUntil', v_free_until,
    'routeExceptionId', v_exception_id,
    'routeEtaCalculationId', v_eta_calculation_id
  );
end;
$$;

create or replace function haulvia_command.apply_c03_correct_stop_arrival(
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
    perform haulvia_command.fail('INVALID_STATE', 'correctStopArrival requires ROUTE_IN_PROGRESS');
  end if;
  if length(v_reason) < 8 then
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
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, true);
  if v_stop.state <> 'ARRIVED' then
    perform haulvia_command.fail('INVALID_STATE', 'Only an ARRIVED stop can be corrected');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  if v_attempt.service_started_at is not null
     or exists (select 1 from haulvia.financial_adjustments fa where fa.stop_execution_id = v_stop.id) then
    perform haulvia_command.fail(
      'ARRIVAL_CORRECTION_BLOCKED',
      'Arrival cannot be corrected after service, failure, or a finalized stop charge'
    );
  end if;

  update haulvia.workflow_jobs
  set status = 'CANCELLED'
  where shipment_id = p_shipment.id
    and job_code = 'STOP_WAITING_GRACE_EXPIRES'
    and status = 'QUEUED'
    and payload ->> 'stopExecutionId' = v_stop.id::text;
  update haulvia.stop_executions
  set state = 'EN_ROUTE', waiting_free_until = null
  where id = v_stop.id;
  update haulvia.stop_attempts set state = 'EN_ROUTE' where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'CONFIRM_ARRIVAL_AT_STOP', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'ARRIVED', 'EN_ROUTE',
    'correctStopArrival', p_request,
    jsonb_build_object('originalArrivalPreserved', true)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'correctStopArrival', p_request,
    jsonb_build_object('stopState', 'ARRIVED'),
    jsonb_build_object('stopState', 'EN_ROUTE'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'reason', v_reason)
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

create or replace function haulvia_command.apply_c04_start_stop_service(
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
  v_stop_type haulvia.stop_type;
  v_contact_confirmed boolean := haulvia_command.required_boolean(p_request, 'contactConfirmed');
  v_location_confirmed boolean := haulvia_command.required_boolean(p_request, 'locationConfirmed');
  v_has_discrepancy boolean := false;
  v_exception_id uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'startStopService requires ROUTE_IN_PROGRESS');
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
  perform haulvia_command.assert_route_movement_unheld(p_shipment.id);
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, true);
  if v_stop.state <> 'ARRIVED' then
    perform haulvia_command.fail('INVALID_STATE', 'The current stop must be ARRIVED before service');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  select rs.stop_type into v_stop_type
  from haulvia.route_stops rs where rs.id = v_stop.route_stop_id;
  if v_stop_type not in ('PICKUP', 'DELIVERY') then
    perform haulvia_command.fail('INVALID_STATE', 'Block C service handler supports pickup and delivery stops');
  end if;
  if not v_contact_confirmed or not v_location_confirmed then
    perform haulvia_command.fail('SERVICE_GUARD_FAILED', 'Correct stop contact and location must be confirmed');
  end if;

  if v_stop_type = 'PICKUP' then
    v_has_discrepancy := not haulvia_command.required_boolean(p_request, 'cargoAvailable');
  else
    select exists (
      select 1
      from haulvia.cargo_allocations ca
      join haulvia.cargo_items ci
        on ci.id = ca.cargo_item_id and ci.route_version_id = ca.route_version_id
      left join haulvia.v_cargo_custody_balance cb
        on cb.shipment_id = p_shipment.id
       and cb.stable_cargo_key = ci.stable_cargo_key
       and cb.quantity_unit = ca.quantity_unit
      where ca.route_version_id = v_execution.route_version_id
        and ca.delivery_stop_id = v_stop.route_stop_id
        and coalesce(cb.onboard_quantity, 0) < ca.quantity
    ) into v_has_discrepancy;
  end if;

  if v_has_discrepancy and (
    jsonb_typeof(p_request -> 'cargoDiscrepancy') <> 'object'
    or p_request -> 'cargoDiscrepancy' = '{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'A cargo availability or onboard-balance mismatch requires a structured discrepancy'
    );
  end if;
  if v_has_discrepancy then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id,
      exception_code, status, blocks_completion, description,
      opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id,
      case when v_stop_type='PICKUP' then 'PICKUP_CARGO_DISCREPANCY'
           else 'DELIVERY_CUSTODY_DISCREPANCY' end,
      'OPEN', true, 'Cargo position differs from the planned stop movement',
      haulvia_command.required_uuid(p_request, 'actorProfileId'),
      p_request -> 'cargoDiscrepancy'
    ) returning id into v_exception_id;
  end if;

  update haulvia.workflow_jobs
  set status = 'CANCELLED'
  where shipment_id = p_shipment.id and job_code = 'STOP_WAITING_GRACE_EXPIRES'
    and status = 'QUEUED' and payload ->> 'stopExecutionId' = v_stop.id::text;
  update haulvia.stop_executions set state = 'SERVICE_IN_PROGRESS' where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'SERVICE_IN_PROGRESS', service_started_at = clock_timestamp()
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = 'SUBMIT_STOP_EVIDENCE', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'ARRIVED', 'SERVICE_IN_PROGRESS',
    'startStopService', p_request,
    jsonb_build_object('stopType', v_stop_type, 'routeExceptionId', v_exception_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'startStopService', p_request,
    jsonb_build_object('stopState', 'ARRIVED'),
    jsonb_build_object('stopState', 'SERVICE_IN_PROGRESS'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'routeExceptionId', v_exception_id)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'stopType', v_stop_type,
    'routeExceptionId', v_exception_id
  );
end;
$$;

create or replace function haulvia_command.apply_c05_submit_stop_evidence(
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
  v_evidence jsonb;
  v_offline boolean := coalesce((p_request ->> 'offlineCapture')::boolean, false);
  v_synced_at timestamptz := nullif(p_request ->> 'syncedAt', '')::timestamptz;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'submitStopEvidence requires ROUTE_IN_PROGRESS');
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
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, true);
  if v_stop.state <> 'SERVICE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'The current stop must be in service before evidence submission');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  select * into v_route_stop from haulvia.route_stops where id = v_stop.route_stop_id;
  if not haulvia_command.required_boolean(p_request, 'driverConfirmed') then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Driver confirmation is required');
  end if;
  if v_route_stop.stop_type = 'PICKUP'
     and length(haulvia_command.required_text(p_request, 'releasingPersonName')) < 2 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Pickup requires the releasing person name');
  end if;
  if v_route_stop.stop_type = 'DELIVERY'
     and not coalesce((v_route_stop.verification_profile ->> 'contactless')::boolean, false)
     and length(haulvia_command.required_text(p_request, 'receiverName')) < 2 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Standard delivery requires the receiver name');
  end if;
  if v_offline and v_synced_at is null then
    -- Submission may be retained, but custody verification remains blocked until
    -- a synchronization workflow supplies the immutable sync time.
    null;
  elsif v_offline and v_synced_at < coalesce(
    nullif(p_request ->> 'offlineCapturedAt', '')::timestamptz,
    clock_timestamp()
  ) then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Offline sync time cannot precede capture time');
  end if;

  v_evidence := haulvia_command.insert_evidence_array(v_attempt.id, p_request, 'evidence');
  update haulvia.stop_executions set state = 'EVIDENCE_PENDING' where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'EVIDENCE_PENDING', evidence_submitted_at = clock_timestamp(),
      offline_started_at = case when v_offline then coalesce(
        nullif(p_request ->> 'offlineCapturedAt', '')::timestamptz,
        clock_timestamp()
      ) else null end,
      synced_at = case when v_offline then v_synced_at else null end
  where id = v_attempt.id;
  update haulvia.route_executions
  set next_action = case when v_route_stop.stop_type='PICKUP'
      then 'VERIFY_PICKUP_STOP' else 'VERIFY_DELIVERY_STOP' end,
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING',
    'submitStopEvidence', p_request,
    jsonb_build_object(
      'stopType', v_route_stop.stop_type,
      'evidenceCount', v_evidence -> 'count',
      'offlineCapture', v_offline,
      'syncedAt', v_synced_at
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'submitStopEvidence', p_request,
    jsonb_build_object('stopState', 'SERVICE_IN_PROGRESS'),
    jsonb_build_object('stopState', 'EVIDENCE_PENDING'),
    jsonb_build_object('stopExecutionId', v_stop.id, 'evidence', v_evidence)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id,
    'stopAttemptId', v_attempt.id,
    'stopType', v_route_stop.stop_type,
    'evidence', v_evidence,
    'offlineCapture', v_offline,
    'syncedAt', v_synced_at
  );
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
  perform haulvia_command.fail('EVIDENCE_INVALID', 'Offline evidence metadata is invalid');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- C06-C07: verified pickup/delivery movements and per-stop contactless state
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_c06_verify_pickup_stop(
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
  v_movement_ids jsonb := '[]'::jsonb;
  v_partial boolean := false;
  v_exception_id uuid;
  v_damage_exception_id uuid;
  v_capacity numeric;
  v_onboard_weight numeric;
  v_route_update_id uuid;
  v_eta_calculation_id uuid;
  v_custody jsonb;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'verifyPickupStop requires ROUTE_IN_PROGRESS');
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
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, true);
  if v_stop.state <> 'EVIDENCE_PENDING' or not exists (
    select 1 from haulvia.route_stops rs
    where rs.id=v_stop.route_stop_id and rs.stop_type='PICKUP'
  ) then
    perform haulvia_command.fail('INVALID_STATE', 'A later pickup must be EVIDENCE_PENDING');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  perform haulvia_command.assert_stop_evidence(
    p_shipment.id, v_execution.route_version_id, v_stop.route_stop_id, v_attempt.id
  );
  if jsonb_typeof(p_request -> 'loads') <> 'array'
     or jsonb_array_length(p_request -> 'loads') = 0 then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'loads must be a non-empty array');
  end if;
  select count(*) into v_expected_count
  from haulvia.cargo_allocations ca
  where ca.route_version_id=v_execution.route_version_id
    and ca.pickup_stop_id=v_stop.route_stop_id;
  select count(*), count(distinct value ->> 'cargoAllocationId')
  into v_request_count, v_distinct_count
  from jsonb_array_elements(p_request -> 'loads');
  if v_expected_count = 0 or v_request_count <> v_expected_count
     or v_distinct_count <> v_request_count then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'Verified pickup must provide one actual LOAD for every allocation at that stop'
    );
  end if;

  for v_item in select value from jsonb_array_elements(p_request -> 'loads')
  loop
    select * into v_allocation
    from haulvia.cargo_allocations ca
    where ca.id=haulvia_command.required_uuid(v_item,'cargoAllocationId')
      and ca.route_version_id=v_execution.route_version_id
      and ca.pickup_stop_id=v_stop.route_stop_id
    for update;
    if not found then
      perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'LOAD references cargo outside the current pickup');
    end if;
    v_quantity := haulvia_command.required_numeric(v_item, 'quantity');
    if v_quantity <= 0 or v_quantity > v_allocation.quantity
       or haulvia_command.required_text(v_item,'quantityUnit') <> v_allocation.quantity_unit then
      perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'LOAD quantity or unit is invalid');
    end if;
    v_partial := v_partial or v_quantity < v_allocation.quantity;
    insert into haulvia.cargo_movements (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, movement_type, quantity, quantity_unit,
      stop_attempt_id, evidence_bundle, occurred_at, recorded_by_profile_id,
      idempotency_key
    ) values (
      p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
      v_allocation.id, 'LOAD', v_quantity, v_allocation.quantity_unit,
      v_attempt.id, coalesce(v_item -> 'evidenceBundle','{}'::jsonb),
      coalesce(nullif(v_item ->> 'occurredAt','')::timestamptz,clock_timestamp()),
      haulvia_command.optional_uuid(p_request,'actorProfileId'),
      haulvia_command.required_text(p_request,'idempotencyKey') || ':load:' || v_allocation.id::text
    ) returning id into v_movement_id;
    v_first_movement_id := coalesce(v_first_movement_id, v_movement_id);
    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement_id);
  end loop;

  if v_partial and (
    jsonb_typeof(p_request -> 'quantityDiscrepancy') <> 'object'
    or p_request -> 'quantityDiscrepancy' = '{}'::jsonb
  ) then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'A partial pickup requires a structured shortage discrepancy');
  end if;
  if v_partial then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id, exception_code,
      status, blocks_completion, description, opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id, 'PICKUP_QUANTITY_DISCREPANCY',
      'OPEN', true, 'Verified pickup quantity differs from its planned allocations',
      haulvia_command.optional_uuid(p_request,'actorProfileId'), p_request -> 'quantityDiscrepancy'
    ) returning id into v_exception_id;
  end if;
  if jsonb_typeof(p_request -> 'damageDiscrepancy')='object'
     and p_request -> 'damageDiscrepancy' <> '{}'::jsonb then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id, exception_code,
      status, blocks_completion, description, opened_by_profile_id, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id, 'PICKUP_DAMAGE_REPORTED',
      'OPEN', true, 'Damage or condition discrepancy was recorded at pickup',
      haulvia_command.optional_uuid(p_request,'actorProfileId'), p_request -> 'damageDiscrepancy'
    ) returning id into v_damage_exception_id;
  end if;

  select v.capacity_weight_kg into v_capacity
  from haulvia.vehicles v where v.id=v_assignment.vehicle_id;
  select coalesce(sum(
    cb.onboard_quantity * coalesce(ci.total_weight_kg / nullif(ci.quantity,0),0)
  ),0)
  into v_onboard_weight
  from haulvia.v_cargo_custody_balance cb
  join haulvia.cargo_items ci
    on ci.route_version_id=v_execution.route_version_id
   and ci.stable_cargo_key=cb.stable_cargo_key
  where cb.shipment_id=p_shipment.id and cb.onboard_quantity > 0;
  if v_capacity is not null and v_onboard_weight > v_capacity then
    perform haulvia_command.fail(
      'CAPACITY_EXCEEDED',
      'Verified pickup would exceed the assigned vehicle weight capacity',
      jsonb_build_object('onboardWeightKg',v_onboard_weight,'capacityWeightKg',v_capacity)
    );
  end if;

  perform haulvia_command.verify_stop_evidence_reviews(v_attempt.id, p_request);
  update haulvia.stop_executions set state='COMPLETED' where id=v_stop.id;
  update haulvia.stop_attempts set state='COMPLETED', ended_at=clock_timestamp() where id=v_attempt.id;
  if not exists (
    select 1 from haulvia.shipment_custody_milestones where shipment_id=p_shipment.id
  ) then
    insert into haulvia.shipment_custody_milestones (
      shipment_id, route_execution_id, first_stop_execution_id,
      first_cargo_movement_id, first_custody_at, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id, v_first_movement_id,
      (select occurred_at from haulvia.cargo_movements where id=v_first_movement_id),
      jsonb_build_object('movementIds',v_movement_ids,'stopAttemptId',v_attempt.id)
    );
  end if;
  update haulvia.route_executions
  set next_action='ADVANCE_TO_NEXT_STOP', record_version=record_version+1
  where id=v_execution.id;
  v_custody := haulvia_command.current_custody_summary(p_shipment.id);
  insert into haulvia.route_updates (
    route_execution_id, active_route_leg_id, active_stop_execution_id,
    custody_summary, captured_at, source
  ) values (
    v_execution.id, v_execution.active_route_leg_id, v_stop.id,
    v_custody, clock_timestamp(), 'SERVER'
  ) returning id into v_route_update_id;
  v_eta_calculation_id := haulvia_command.recalculate_downstream_etas(
    p_shipment.id, v_execution.id, v_stop.id, 'verifyPickupStop', p_request,
    coalesce(nullif(p_request ->> 'completedAt','')::timestamptz,clock_timestamp()),
    v_route_update_id, 0
  );
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'EVIDENCE_PENDING', 'COMPLETED',
    'verifyPickupStop', p_request,
    jsonb_build_object(
      'movementIds',v_movement_ids,'custodySummary',v_custody,
      'quantityExceptionId',v_exception_id,'damageExceptionId',v_damage_exception_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment,'verifyPickupStop',p_request,
    jsonb_build_object('stopState','EVIDENCE_PENDING'),
    jsonb_build_object('stopState','COMPLETED'),
    jsonb_build_object('movementIds',v_movement_ids,'custodySummary',v_custody)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,p_shipment.customer_profile_id,'PICKUP_STOP_VERIFIED',p_request,
    'pickup-stop-'||v_stop.id::text,
    jsonb_build_object('stopExecutionId',v_stop.id,'custodySummary',v_custody)
  );
  return jsonb_build_object(
    'routeExecutionId',v_execution.id,
    'routeExecutionVersion',v_execution.record_version+1,
    'stopExecutionId',v_stop.id,'stopAttemptId',v_attempt.id,
    'cargoMovementIds',v_movement_ids,'custodySummary',v_custody,
    'routeExceptionId',v_exception_id,'damageExceptionId',v_damage_exception_id,
    'routeEtaCalculationId',v_eta_calculation_id
  );
exception
  when check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID','Verified pickup violated an allocation, custody, capacity, or idempotency invariant',
      jsonb_build_object('databaseMessage',sqlerrm)
    );
  return null;
end;
$$;

create or replace function haulvia_command.apply_c07_verify_delivery_stop(
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
  v_item jsonb;
  v_allocation haulvia.cargo_allocations%rowtype;
  v_expected_count integer;
  v_request_count integer;
  v_distinct_count integer;
  v_quantity numeric;
  v_movement_id uuid;
  v_movement_ids jsonb := '[]'::jsonb;
  v_outcome_ids jsonb := '[]'::jsonb;
  v_outcome_id uuid;
  v_partial boolean := false;
  v_exception_id uuid;
  v_contactless boolean := false;
  v_token_id uuid;
  v_token_hash text;
  v_confirmation_expires timestamptz;
  v_route_update_id uuid;
  v_eta_calculation_id uuid;
  v_custody jsonb;
  v_completed_at timestamptz := coalesce(
    nullif(p_request ->> 'completedAt','')::timestamptz,clock_timestamp()
  );
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'verifyDeliveryStop requires ROUTE_IN_PROGRESS');
  end if;
  perform haulvia_command.authorize_evidence_reviewer(p_request);
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE','Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution,p_request,true);
  select * into v_route_stop from haulvia.route_stops
  where id=v_stop.route_stop_id and route_version_id=v_stop.route_version_id;
  if v_stop.state <> 'EVIDENCE_PENDING' or v_route_stop.stop_type <> 'DELIVERY' then
    perform haulvia_command.fail('INVALID_STATE','A later delivery must be EVIDENCE_PENDING');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  perform haulvia_command.assert_stop_evidence(
    p_shipment.id,v_execution.route_version_id,v_stop.route_stop_id,v_attempt.id
  );
  v_contactless := coalesce((v_route_stop.verification_profile ->> 'contactless')::boolean,false);
  if coalesce((p_request ->> 'contactlessDelivery')::boolean,false) is distinct from v_contactless then
    perform haulvia_command.fail('CONTACTLESS_NOT_ELIGIBLE','Contactless execution must match the accepted stop snapshot');
  end if;
  if v_contactless and exists (
    select 1
    from haulvia.cargo_allocations ca
    join haulvia.cargo_items ci
      on ci.id=ca.cargo_item_id and ci.route_version_id=ca.route_version_id
    where ca.route_version_id=v_execution.route_version_id
      and ca.delivery_stop_id=v_stop.route_stop_id
      and (
        coalesce((ci.risk_attributes ->> 'highValue')::boolean,false)
        or coalesce((ci.risk_attributes ->> 'sensitive')::boolean,false)
        or coalesce((ci.risk_attributes ->> 'dangerousControlled')::boolean,false)
        or coalesce((ci.risk_attributes ->> 'temperatureSensitive')::boolean,false)
        or coalesce((ci.risk_attributes ->> 'signatureRequired')::boolean,false)
      )
  ) then
    perform haulvia_command.fail('CONTACTLESS_NOT_ELIGIBLE','Cargo risk attributes prohibit contactless delivery');
  end if;
  if v_contactless and (
    jsonb_typeof(p_request -> 'contactlessAuthorization') <> 'object'
    or p_request -> 'contactlessAuthorization' = '{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'CONTACTLESS_NOT_ELIGIBLE',
      'Contactless delivery requires preapproval, exact drop location, verified identity, and instructions'
    );
  end if;

  if jsonb_typeof(p_request -> 'unloads') <> 'array'
     or jsonb_array_length(p_request -> 'unloads')=0 then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID','unloads must be a non-empty array');
  end if;
  select count(*) into v_expected_count from haulvia.cargo_allocations ca
  where ca.route_version_id=v_execution.route_version_id
    and ca.delivery_stop_id=v_stop.route_stop_id;
  select count(*),count(distinct value ->> 'cargoAllocationId')
  into v_request_count,v_distinct_count
  from jsonb_array_elements(p_request -> 'unloads');
  if v_expected_count=0 or v_request_count<>v_expected_count or v_distinct_count<>v_request_count then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'Verified delivery must provide one actual UNLOAD for every allocation at that stop'
    );
  end if;

  for v_item in select value from jsonb_array_elements(p_request -> 'unloads')
  loop
    select * into v_allocation from haulvia.cargo_allocations ca
    where ca.id=haulvia_command.required_uuid(v_item,'cargoAllocationId')
      and ca.route_version_id=v_execution.route_version_id
      and ca.delivery_stop_id=v_stop.route_stop_id
    for update;
    if not found then
      perform haulvia_command.fail('CARGO_BALANCE_INVALID','UNLOAD references cargo outside the current delivery');
    end if;
    v_quantity := haulvia_command.required_numeric(v_item,'quantity');
    if v_quantity<=0 or v_quantity>v_allocation.quantity
       or haulvia_command.required_text(v_item,'quantityUnit')<>v_allocation.quantity_unit then
      perform haulvia_command.fail('CARGO_BALANCE_INVALID','UNLOAD quantity or unit is invalid');
    end if;
    v_partial := v_partial or v_quantity<v_allocation.quantity;
    insert into haulvia.cargo_movements (
      shipment_id,route_execution_id,route_version_id,stop_execution_id,
      cargo_allocation_id,movement_type,quantity,quantity_unit,
      stop_attempt_id,evidence_bundle,occurred_at,recorded_by_profile_id,idempotency_key
    ) values (
      p_shipment.id,v_execution.id,v_execution.route_version_id,v_stop.id,
      v_allocation.id,'UNLOAD',v_quantity,v_allocation.quantity_unit,
      v_attempt.id,coalesce(v_item -> 'evidenceBundle','{}'::jsonb),
      coalesce(nullif(v_item ->> 'occurredAt','')::timestamptz,v_completed_at),
      haulvia_command.optional_uuid(p_request,'actorProfileId'),
      haulvia_command.required_text(p_request,'idempotencyKey')||':unload:'||v_allocation.id::text
    ) returning id into v_movement_id;
    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement_id);

    insert into haulvia.cargo_resolution_outcomes (
      shipment_id,route_execution_id,route_version_id,stop_execution_id,
      cargo_allocation_id,cargo_movement_id,outcome_code,quantity,quantity_unit,
      approval_snapshot,approved_by_profile_id,occurred_at,idempotency_key
    ) values (
      p_shipment.id,v_execution.id,v_execution.route_version_id,v_stop.id,
      v_allocation.id,v_movement_id,'DELIVERED',v_quantity,v_allocation.quantity_unit,
      jsonb_build_object(
        'evidenceBundle',coalesce(v_item -> 'evidenceBundle','{}'::jsonb),
        'contactless',v_contactless,'stopAttemptId',v_attempt.id
      ),haulvia_command.optional_uuid(p_request,'actorProfileId'),v_completed_at,
      haulvia_command.required_text(p_request,'idempotencyKey')||':outcome:'||v_allocation.id::text
    ) returning id into v_outcome_id;
    v_outcome_ids := v_outcome_ids || jsonb_build_array(v_outcome_id);
  end loop;

  if v_partial and (
    jsonb_typeof(p_request -> 'deliveryDiscrepancy')<>'object'
    or p_request -> 'deliveryDiscrepancy'='{}'::jsonb
  ) then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID','A partial delivery requires a structured discrepancy');
  end if;
  if v_partial then
    insert into haulvia.route_exceptions (
      shipment_id,route_execution_id,stop_execution_id,exception_code,status,
      blocks_completion,description,opened_by_profile_id,metadata
    ) values (
      p_shipment.id,v_execution.id,v_stop.id,'DELIVERY_QUANTITY_DISCREPANCY','OPEN',
      true,'Verified delivery quantity differs from its planned allocations',
      haulvia_command.optional_uuid(p_request,'actorProfileId'),p_request -> 'deliveryDiscrepancy'
    ) returning id into v_exception_id;
  end if;

  perform haulvia_command.verify_stop_evidence_reviews(v_attempt.id,p_request);
  if v_contactless then
    v_token_hash := lower(haulvia_command.required_text(p_request,'receiverTokenHash'));
    v_confirmation_expires := haulvia_command.required_timestamptz(p_request,'receiverConfirmationExpiresAt');
    if v_token_hash !~ '^[0-9a-fA-F]{64}$' or v_confirmation_expires<=clock_timestamp() then
      perform haulvia_command.fail('CONTACTLESS_NOT_ELIGIBLE','Contactless receiver token or confirmation window is invalid');
    end if;
    insert into haulvia.receiver_access_tokens (
      shipment_id,stop_execution_id,token_hash,permissions,expires_at
    ) values (
      p_shipment.id,v_stop.id,v_token_hash,
      jsonb_build_object(
        'track',true,'confirmReceipt',true,'reportIssue',true,
        'pricing',false,'edit',false,'cancel',false
      ),v_confirmation_expires
    ) returning id into v_token_id;
  end if;
  update haulvia.stop_executions
  set state='COMPLETED',
      delivery_verification_state=case when v_contactless
        then 'PENDING_RECEIVER_CONFIRMATION'::haulvia.delivery_verification_state
        else 'NOT_REQUIRED'::haulvia.delivery_verification_state end
  where id=v_stop.id;
  update haulvia.stop_attempts set state='COMPLETED',ended_at=v_completed_at where id=v_attempt.id;
  update haulvia.route_executions
  set next_action=case when exists (
        select 1 from haulvia.stop_executions se
        join haulvia.route_stops rs on rs.id=se.route_stop_id
        join haulvia.route_stops current_rs on current_rs.id=v_stop.route_stop_id
        where se.route_execution_id=v_execution.id and se.state='PENDING'
          and rs.sequence_no>current_rs.sequence_no
      ) then 'ADVANCE_TO_NEXT_STOP' else 'COMPLETE_PLANNED_ROUTE' end,
      record_version=record_version+1
  where id=v_execution.id;
  v_custody := haulvia_command.current_custody_summary(p_shipment.id);
  insert into haulvia.route_updates (
    route_execution_id,active_route_leg_id,active_stop_execution_id,
    custody_summary,captured_at,source
  ) values (
    v_execution.id,v_execution.active_route_leg_id,v_stop.id,v_custody,v_completed_at,'SERVER'
  ) returning id into v_route_update_id;
  v_eta_calculation_id := haulvia_command.recalculate_downstream_etas(
    p_shipment.id,v_execution.id,v_stop.id,'verifyDeliveryStop',p_request,
    v_completed_at,v_route_update_id,0
  );
  if v_contactless then
    insert into haulvia.notification_events (
      shipment_id,receiver_access_token_id,event_code,channel,template_version,payload,idempotency_key
    ) values (
      p_shipment.id,v_token_id,'CONTACTLESS_RECEIVER_CONFIRMATION_REQUESTED','SECURE_LINK','v1',
      jsonb_build_object(
        'stopExecutionId',v_stop.id,
        'responseOptions',jsonb_build_array(
          'RECEIVED_GOOD','RECEIVED_DAMAGE_OR_MISSING','NOT_RECEIVED','CANNOT_VERIFY_YET'
        )
      ),p_shipment.id::text||':'||haulvia_command.required_text(p_request,'idempotencyKey')||':receiver-confirmation'
    );
    perform haulvia_command.queue_job(
      p_shipment.id,'RECEIVER_CONFIRMATION_EXPIRES',v_confirmation_expires,p_request,
      'receiver-confirmation-'||v_stop.id::text,
      jsonb_build_object('stopExecutionId',v_stop.id,'receiverAccessTokenId',v_token_id)
    );
  end if;
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id,v_stop.id,'EVIDENCE_PENDING','COMPLETED','verifyDeliveryStop',p_request,
    jsonb_build_object(
      'movementIds',v_movement_ids,'cargoOutcomeIds',v_outcome_ids,
      'contactless',v_contactless,'receiverAccessTokenId',v_token_id,
      'custodySummary',v_custody
    )
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id,'DELIVERY_VERIFICATION',v_stop.delivery_verification_state::text,
    case when v_contactless then 'PENDING_RECEIVER_CONFIRMATION' else 'NOT_REQUIRED' end,
    'verifyDeliveryStop',p_request,v_stop.id,
    jsonb_build_object('contactless',v_contactless,'receiverAccessTokenId',v_token_id)
  );
  perform haulvia_command.append_audit(
    p_shipment,'verifyDeliveryStop',p_request,
    jsonb_build_object('stopState','EVIDENCE_PENDING'),
    jsonb_build_object('stopState','COMPLETED'),
    jsonb_build_object('movementIds',v_movement_ids,'cargoOutcomeIds',v_outcome_ids,'custodySummary',v_custody)
  );
  return jsonb_build_object(
    'routeExecutionId',v_execution.id,'routeExecutionVersion',v_execution.record_version+1,
    'stopExecutionId',v_stop.id,'stopAttemptId',v_attempt.id,
    'cargoMovementIds',v_movement_ids,'cargoOutcomeIds',v_outcome_ids,
    'contactless',v_contactless,'receiverAccessTokenId',v_token_id,
    'deliveryVerificationState',case when v_contactless then 'PENDING_RECEIVER_CONFIRMATION' else 'NOT_REQUIRED' end,
    'custodySummary',v_custody,'routeExceptionId',v_exception_id,
    'routeEtaCalculationId',v_eta_calculation_id
  );
exception
  when check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID','Verified delivery violated an allocation, custody, contactless, or idempotency invariant',
      jsonb_build_object('databaseMessage',sqlerrm)
    );
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- C08-C10: immutable failed-stop facts and explicit continuation authority
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_c_failure_report(
  p_shipment haulvia.shipments,
  p_request jsonb,
  p_command_name text,
  p_expected_stop_type haulvia.stop_type
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
  v_target haulvia.stop_state := haulvia_command.required_text(p_request,'targetStopState')::haulvia.stop_state;
  v_grace_end timestamptz := haulvia_command.required_timestamptz(p_request,'gracePeriodEndedAt');
  v_occurred timestamptz := coalesce(nullif(p_request ->> 'occurredAt','')::timestamptz,clock_timestamp());
  v_reason text := haulvia_command.required_text(p_request,'failureReason');
  v_responsibility text := haulvia_command.required_text(p_request,'responsibilityCode');
  v_custody jsonb;
  v_evidence jsonb;
  v_exception_id uuid;
  v_hold_id uuid;
  v_report_id uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE',p_command_name||' requires ROUTE_IN_PROGRESS');
  end if;
  if v_target not in ('FAILED','EXCEPTION_REVIEW') or length(v_reason)<8 then
    perform haulvia_command.fail('INVALID_REQUEST','Failure requires FAILED/EXCEPTION_REVIEW and a specific reason');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  perform haulvia_command.authorize_route_operator(v_assignment,p_request,true);
  perform haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE','Route execution must be ACTIVE');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution,p_request,true);
  select * into v_route_stop from haulvia.route_stops
  where id=v_stop.route_stop_id and route_version_id=v_stop.route_version_id;
  if v_route_stop.stop_type<>p_expected_stop_type
     or v_stop.state not in ('ARRIVED','SERVICE_IN_PROGRESS','EVIDENCE_PENDING') then
    perform haulvia_command.fail('INVALID_STATE','Failure must target the active arrived/service/evidence stop of the requested type');
  end if;
  v_attempt := haulvia_command.lock_current_stop_attempt(v_stop);
  if v_attempt.arrived_at is null or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id=v_attempt.id and e.evidence_type='GPS'
  ) or not exists (
    select 1 from haulvia.stop_evidence e
    where e.stop_attempt_id=v_attempt.id and e.evidence_type='TIMESTAMP'
  ) then
    perform haulvia_command.fail('LOCATION_NOT_VERIFIED','Failed stop requires retained GPS and arrival-time evidence');
  end if;
  if v_grace_end>v_occurred
     or (v_stop.waiting_free_until is not null and v_grace_end<v_stop.waiting_free_until) then
    perform haulvia_command.fail('WAITING_PERIOD_ACTIVE','The configured per-stop grace period has not ended');
  end if;
  if jsonb_typeof(p_request -> 'contactAttempts')<>'array'
     or jsonb_array_length(p_request -> 'contactAttempts')=0
     or jsonb_typeof(p_request -> 'affectedCargo')<>'array'
     or jsonb_array_length(p_request -> 'affectedCargo')=0
     or jsonb_typeof(p_request -> 'downstreamImpact')<>'object'
     or p_request -> 'downstreamImpact'='{}'::jsonb then
    perform haulvia_command.fail(
      'FAILURE_EVIDENCE_INCOMPLETE',
      'Failure requires contacts, affected cargo, and downstream impact'
    );
  end if;
  if p_expected_stop_type='DELIVERY' and (
    jsonb_typeof(p_request -> 'approvedNextRouteDecision')<>'object'
    or p_request -> 'approvedNextRouteDecision'='{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'NEXT_ROUTE_DECISION_REQUIRED',
      'Failed delivery requires an approved next-route decision snapshot'
    );
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_request -> 'affectedCargo') item
    where not exists (
      select 1 from haulvia.cargo_allocations ca
      where ca.id=haulvia_command.required_uuid(item,'cargoAllocationId')
        and ca.route_version_id=v_execution.route_version_id
        and case when p_expected_stop_type='PICKUP'
          then ca.pickup_stop_id=v_stop.route_stop_id
          else ca.delivery_stop_id=v_stop.route_stop_id end
    )
  ) then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID','Affected cargo is outside the failed stop');
  end if;
  v_custody := haulvia_command.assert_custody_snapshot(
    p_shipment.id,p_request -> 'custodyBalance'
  );
  v_evidence := haulvia_command.insert_evidence_array(v_attempt.id,p_request,'evidence');

  insert into haulvia.route_exceptions (
    shipment_id,route_execution_id,stop_execution_id,exception_code,status,
    responsibility_code,blocks_completion,description,opened_by_profile_id,metadata
  ) values (
    p_shipment.id,v_execution.id,v_stop.id,
    case when p_expected_stop_type='PICKUP' then 'FAILED_PICKUP_STOP' else 'FAILED_DELIVERY_STOP' end,
    case when v_target='EXCEPTION_REVIEW' then 'UNDER_REVIEW'::haulvia.exception_status
         else 'ACTION_REQUIRED'::haulvia.exception_status end,
    v_responsibility,true,v_reason,haulvia_command.optional_uuid(p_request,'actorProfileId'),
    jsonb_build_object(
      'affectedCargo',p_request -> 'affectedCargo',
      'downstreamImpact',p_request -> 'downstreamImpact',
      'custodyBalance',v_custody,
      'contactAttempts',p_request -> 'contactAttempts',
      'approvedNextRouteDecision',p_request -> 'approvedNextRouteDecision'
    )
  ) returning id into v_exception_id;

  if v_target='EXCEPTION_REVIEW' then
    insert into haulvia.workflow_holds (
      shipment_id,route_execution_id,stop_execution_id,hold_code,status,
      blocks_marketplace,blocks_route_movement,blocks_completion,reason,
      opened_by_profile_id,metadata
    ) values (
      p_shipment.id,v_execution.id,v_stop.id,'FAILED_STOP_REVIEW','ACTIVE',
      false,true,true,'Failed stop requires authorized route review',
      haulvia_command.optional_uuid(p_request,'actorProfileId'),
      jsonb_build_object('routeExceptionId',v_exception_id,'custodyBalance',v_custody)
    ) returning id into v_hold_id;
    update haulvia.route_exceptions set workflow_hold_id=v_hold_id where id=v_exception_id;
  end if;

  update haulvia.stop_executions set state=v_target where id=v_stop.id;
  update haulvia.stop_attempts
  set state=v_target,ended_at=v_occurred,responsibility_code=v_responsibility,
      failure_reason=v_reason
  where id=v_attempt.id;
  update haulvia.route_executions
  set next_action=case when v_target='FAILED' then 'AUTHORIZE_CONTINUE_AFTER_STOP_FAILURE'
                       else 'RESOLVE_FAILED_STOP_REVIEW' end,
      state=case when v_target='EXCEPTION_REVIEW'
        then 'HELD'::haulvia.route_execution_state else state end,
      record_version=record_version+1
  where id=v_execution.id;

  insert into haulvia.stop_failure_reports (
    shipment_id,route_execution_id,route_version_id,stop_execution_id,
    stop_attempt_id,route_exception_id,command_name,reported_stop_state,
    responsibility_code,failure_reason,affected_cargo,custody_balance_snapshot,
    downstream_impact,approved_next_route_decision,grace_period_ended_at,
    reported_by_profile_id,reported_at,idempotency_key
  ) values (
    p_shipment.id,v_execution.id,v_execution.route_version_id,v_stop.id,
    v_attempt.id,v_exception_id,p_command_name,v_target,v_responsibility,v_reason,
    p_request -> 'affectedCargo',v_custody,p_request -> 'downstreamImpact',
    p_request -> 'approvedNextRouteDecision',v_grace_end,
    haulvia_command.optional_uuid(p_request,'actorProfileId'),v_occurred,
    haulvia_command.required_text(p_request,'idempotencyKey')
  ) returning id into v_report_id;
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;

  perform haulvia_command.append_stop_event(
    v_attempt.id,v_stop.id,v_stop.state,v_target,p_command_name,p_request,
    jsonb_build_object(
      'stopFailureReportId',v_report_id,'routeExceptionId',v_exception_id,
      'workflowHoldId',v_hold_id,'evidence',v_evidence,'custodyBalance',v_custody
    )
  );
  perform haulvia_command.append_audit(
    p_shipment,p_command_name,p_request,
    jsonb_build_object('stopState',v_stop.state),jsonb_build_object('stopState',v_target),
    jsonb_build_object('stopFailureReportId',v_report_id,'routeExceptionId',v_exception_id,'workflowHoldId',v_hold_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,p_shipment.customer_profile_id,
    case when p_expected_stop_type='PICKUP' then 'PICKUP_STOP_FAILED' else 'DELIVERY_STOP_FAILED' end,
    p_request,'failed-stop-'||v_stop.id::text,
    jsonb_build_object('stopExecutionId',v_stop.id,'targetStopState',v_target,'custodyBalance',v_custody)
  );
  return jsonb_build_object(
    'routeExecutionId',v_execution.id,'routeExecutionVersion',v_execution.record_version+1,
    'routeExecutionState',case when v_target='EXCEPTION_REVIEW' then 'HELD' else v_execution.state::text end,
    'stopExecutionId',v_stop.id,'stopAttemptId',v_attempt.id,'stopState',v_target,
    'stopFailureReportId',v_report_id,'routeExceptionId',v_exception_id,
    'workflowHoldId',v_hold_id,'custodySummary',v_custody
  );
end;
$$;

create or replace function haulvia_command.apply_c08_report_failed_pickup_stop(
  p_shipment haulvia.shipments,p_request jsonb
)
returns jsonb
language sql
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_c_failure_report(
    p_shipment,p_request,'reportFailedPickupStop','PICKUP'
  );
$$;

create or replace function haulvia_command.apply_c09_report_failed_delivery_stop(
  p_shipment haulvia.shipments,p_request jsonb
)
returns jsonb
language sql
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_c_failure_report(
    p_shipment,p_request,'reportFailedDeliveryStop','DELIVERY'
  );
$$;

create or replace function haulvia_command.apply_c10_authorize_continue_after_failure(
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
  v_report haulvia.stop_failure_reports%rowtype;
  v_decision text := upper(haulvia_command.required_text(p_request,'decisionCode'));
  v_custody jsonb;
  v_advance jsonb;
  v_authorization_id uuid;
  v_item jsonb;
  v_allocation haulvia.cargo_allocations%rowtype;
  v_quantity numeric;
  v_outcome_id uuid;
  v_outcomes jsonb := '[]'::jsonb;
begin
  if p_shipment.shipment_state<>'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE','authorizeContinueAfterStopFailure requires ROUTE_IN_PROGRESS');
  end if;
  if v_decision not in ('SKIP','RECOVERY','AMENDMENT','RETURN','REDELIVERY','ALTERNATE_DESTINATION','TRANSFER','STORAGE') then
    perform haulvia_command.fail('INVALID_REQUEST','decisionCode is not an approved failed-stop route action');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  perform haulvia_command.authorize_customer_or_route_workflow(p_shipment,v_assignment,p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.state<>'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE','Only an ACTIVE failed-stop execution may continue');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution,p_request,true);
  if v_stop.state<>'FAILED' then
    perform haulvia_command.fail('INVALID_STATE','The active stop must remain FAILED for explicit continuation');
  end if;
  select * into v_report from haulvia.stop_failure_reports sfr
  where sfr.id=haulvia_command.required_uuid(p_request,'stopFailureReportId')
    and sfr.route_execution_id=v_execution.id and sfr.stop_execution_id=v_stop.id
  for share;
  if not found then
    perform haulvia_command.fail('NOT_FOUND','The failed-stop report was not found');
  end if;
  if not haulvia_command.required_boolean(p_request,'routeFeasible')
     or not haulvia_command.required_boolean(p_request,'capacityValidated')
     or not haulvia_command.required_boolean(p_request,'timingValidated')
     or not haulvia_command.required_boolean(p_request,'custodyValidated') then
    perform haulvia_command.fail(
      'CONTINUATION_NOT_FEASIBLE',
      'Capacity, timing, custody, and remaining-route feasibility must all be revalidated'
    );
  end if;
  if jsonb_typeof(p_request -> 'routeFeasibilitySnapshot')<>'object'
     or p_request -> 'routeFeasibilitySnapshot'='{}'::jsonb
     or jsonb_typeof(p_request -> 'capacitySnapshot')<>'object'
     or p_request -> 'capacitySnapshot'='{}'::jsonb
     or jsonb_typeof(p_request -> 'timingSnapshot')<>'object'
     or p_request -> 'timingSnapshot'='{}'::jsonb
     or jsonb_typeof(p_request -> 'customerInstructions')<>'object'
     or p_request -> 'customerInstructions'='{}'::jsonb then
    perform haulvia_command.fail('INVALID_REQUEST','Continuation validation and customer instructions must be retained');
  end if;
  if v_report.command_name='reportFailedDeliveryStop'
     and coalesce(v_report.approved_next_route_decision ->> 'decisionCode','')<>v_decision then
    perform haulvia_command.fail('NEXT_ROUTE_DECISION_REQUIRED','Continuation does not match the approved failed-delivery decision');
  end if;
  v_custody := haulvia_command.assert_custody_snapshot(p_shipment.id,p_request -> 'custodyBalance');
  perform haulvia_command.assert_route_movement_unheld(p_shipment.id);

  v_advance := haulvia_command.advance_after_terminal_stop(
    p_shipment,v_execution,v_stop,p_request,'authorizeContinueAfterStopFailure'
  );
  insert into haulvia.stop_continuation_authorizations (
    shipment_id,route_execution_id,stop_failure_report_id,failed_stop_execution_id,
    next_stop_execution_id,decision_code,route_feasibility_snapshot,capacity_snapshot,
    timing_snapshot,custody_balance_snapshot,customer_instructions,
    authorized_by_profile_id,idempotency_key
  ) values (
    p_shipment.id,v_execution.id,v_report.id,v_stop.id,
    (v_advance ->> 'stopExecutionId')::uuid,v_decision,
    p_request -> 'routeFeasibilitySnapshot',p_request -> 'capacitySnapshot',
    p_request -> 'timingSnapshot',v_custody,p_request -> 'customerInstructions',
    haulvia_command.optional_uuid(p_request,'actorProfileId'),
    haulvia_command.required_text(p_request,'idempotencyKey')
  ) returning id into v_authorization_id;

  if v_report.command_name='reportFailedPickupStop' and v_decision='SKIP' then
    for v_item in select value from jsonb_array_elements(v_report.affected_cargo)
    loop
      select * into v_allocation from haulvia.cargo_allocations ca
      where ca.id=haulvia_command.required_uuid(v_item,'cargoAllocationId')
        and ca.route_version_id=v_execution.route_version_id
        and ca.pickup_stop_id=v_stop.route_stop_id;
      if not found then
        perform haulvia_command.fail('CARGO_BALANCE_INVALID','Failed-pickup skip references an invalid allocation');
      end if;
      v_quantity := coalesce(haulvia_command.optional_numeric(v_item,'quantity'),v_allocation.quantity);
      if v_quantity<=0 or v_quantity>v_allocation.quantity then
        perform haulvia_command.fail('CARGO_BALANCE_INVALID','Approved skipped quantity is invalid');
      end if;
      insert into haulvia.cargo_resolution_outcomes (
        shipment_id,route_execution_id,route_version_id,stop_execution_id,
        cargo_allocation_id,outcome_code,quantity,quantity_unit,approval_snapshot,
        approved_by_profile_id,occurred_at,idempotency_key
      ) values (
        p_shipment.id,v_execution.id,v_execution.route_version_id,v_stop.id,
        v_allocation.id,'APPROVED_NOT_LOADED',v_quantity,v_allocation.quantity_unit,
        jsonb_build_object(
          'stopContinuationAuthorizationId',v_authorization_id,
          'customerInstructions',p_request -> 'customerInstructions'
        ),haulvia_command.optional_uuid(p_request,'actorProfileId'),clock_timestamp(),
        haulvia_command.required_text(p_request,'idempotencyKey')||':skipped-outcome:'||v_allocation.id::text
      ) returning id into v_outcome_id;
      v_outcomes := v_outcomes || jsonb_build_array(v_outcome_id);
    end loop;
    update haulvia.route_exceptions
    set status='RESOLVED',blocks_completion=false,
        resolution='Customer/workflow authorized failed-pickup skip and route continuation',
        resolved_by_profile_id=haulvia_command.optional_uuid(p_request,'actorProfileId'),
        resolved_at=clock_timestamp()
    where id=v_report.route_exception_id;
  end if;
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;
  perform haulvia_command.append_audit(
    p_shipment,'authorizeContinueAfterStopFailure',p_request,
    jsonb_build_object('activeStopExecutionId',v_stop.id,'stopState','FAILED'),
    jsonb_build_object('activeStopExecutionId',v_advance ->> 'stopExecutionId','failedStopState','FAILED'),
    jsonb_build_object(
      'stopContinuationAuthorizationId',v_authorization_id,
      'decisionCode',v_decision,'cargoOutcomeIds',v_outcomes,'custodyBalance',v_custody
    )
  );
  return v_advance || jsonb_build_object(
    'failedStopExecutionId',v_stop.id,'failedStopState','FAILED',
    'stopFailureReportId',v_report.id,
    'stopContinuationAuthorizationId',v_authorization_id,
    'decisionCode',v_decision,'cargoOutcomeIds',v_outcomes,
    'custodySummary',v_custody
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- C11: immutable post-assignment route amendment and new execution segment
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_c11_authorize_route_amendment(
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
  v_old_route uuid;
  v_new_route uuid;
  v_new_execution uuid;
  v_new_stop uuid;
  v_new_attempt uuid;
  v_new_leg uuid;
  v_new_sequence integer;
  v_tracking uuid;
  v_route_update uuid;
  v_eta_calculation uuid;
  v_price_snapshot uuid;
  v_payment_intent uuid := haulvia_command.optional_uuid(p_request,'additionalPaymentIntentId');
  v_additional numeric := haulvia_command.required_numeric(p_request,'additionalPaymentAmount');
  v_currency char(3) := upper(haulvia_command.required_text(p_request,'currency'))::char(3);
  v_emergency boolean := coalesce((p_request ->> 'emergencyWaiver')::boolean,false);
  v_reason text := haulvia_command.required_text(p_request,'reason');
  v_actor uuid := haulvia_command.optional_uuid(p_request,'actorProfileId');
  v_policy uuid := haulvia_command.required_uuid(p_request,'policyVersionId');
  v_amendment_id uuid;
  v_payment_hold uuid;
  v_copied_outcomes integer;
  v_eta timestamptz := haulvia_command.required_timestamptz(p_request,'nextStopEtaAt');
  v_idempotency text := haulvia_command.required_text(p_request,'idempotencyKey');
begin
  if p_shipment.shipment_state<>'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE','authorizeRouteAmendment requires ROUTE_IN_PROGRESS');
  end if;
  if length(v_reason)<8 or v_additional<0 or v_currency<>p_shipment.currency then
    perform haulvia_command.fail('INVALID_REQUEST','Amendment reason, amount, or currency is invalid');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  perform haulvia_command.authorize_customer_or_route_workflow(p_shipment,v_assignment,p_request);
  v_old_route := haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.route_version_id<>v_old_route or v_execution.state not in ('ACTIVE','HELD') then
    perform haulvia_command.fail('INVALID_STATE','Amendment requires the current active or held execution and route');
  end if;
  if jsonb_typeof(p_request -> 'driverAcceptance')<>'object'
     or p_request -> 'driverAcceptance'='{}'::jsonb
     or not coalesce((p_request -> 'driverAcceptance' ->> 'accepted')::boolean,false)
     or (p_request -> 'driverAcceptance' ->> 'driverId')::uuid<>v_assignment.driver_id then
    perform haulvia_command.fail('DRIVER_ACCEPTANCE_REQUIRED','The assigned driver/courier must accept the amendment');
  end if;
  if jsonb_typeof(p_request -> 'amendmentSnapshot')<>'object'
     or p_request -> 'amendmentSnapshot'='{}'::jsonb then
    perform haulvia_command.fail('INVALID_REQUEST','amendmentSnapshot must preserve the approved change');
  end if;
  if exists (
    select 1 from haulvia.workflow_holds wh
    where wh.shipment_id=p_shipment.id and wh.status='ACTIVE'
      and wh.blocks_route_movement
      and not (
        jsonb_typeof(p_request -> 'releasedWorkflowHoldIds')='array'
        and wh.id in (
          select value::uuid
          from jsonb_array_elements_text(p_request -> 'releasedWorkflowHoldIds')
        )
      )
  ) then
    perform haulvia_command.fail(
      'WORKFLOW_HELD','Every movement-blocking hold must be explicitly released by the approved amendment'
    );
  end if;

  v_new_route := haulvia_command.create_route_from_plan(
    p_shipment.id,v_old_route,v_actor,v_reason,p_request -> 'routePlan'
  );

  -- Previously terminal stop facts must remain addressable by the same stable
  -- stop key in the full amended plan. The former route itself remains retained.
  if exists (
    select 1
    from haulvia.stop_executions old_se
    join haulvia.route_stops old_rs on old_rs.id=old_se.route_stop_id
    where old_se.route_execution_id=v_execution.id
      and old_se.state in ('COMPLETED','FAILED','SKIPPED')
      and not exists (
        select 1 from haulvia.route_stops new_rs
        where new_rs.route_version_id=v_new_route
          and new_rs.stable_stop_key=old_rs.stable_stop_key
      )
  ) then
    perform haulvia_command.fail(
      'ROUTE_INVALID','Amended route must retain stable keys for every completed, failed, or skipped stop'
    );
  end if;
  if exists (
    select 1
    from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id=p_shipment.id and cb.onboard_quantity>0
      and not exists (
        select 1 from haulvia.cargo_items ci
        where ci.route_version_id=v_new_route
          and ci.stable_cargo_key=cb.stable_cargo_key
          and ci.quantity_unit=cb.quantity_unit
          and ci.quantity>=cb.onboard_quantity
      )
  ) then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID','Amended route must retain every onboard stable cargo key, unit, and quantity'
    );
  end if;
  if exists (
    select 1
    from (
      select old_ci.stable_cargo_key,
             old_p.stable_stop_key as pickup_stable_stop_key,
             old_d.stable_stop_key as delivery_stable_stop_key,
             old_o.quantity_unit,sum(old_o.quantity) as resolved_quantity
      from haulvia.cargo_resolution_outcomes old_o
      join haulvia.cargo_allocations old_ca
        on old_ca.id=old_o.cargo_allocation_id
       and old_ca.route_version_id=old_o.route_version_id
      join haulvia.cargo_items old_ci
        on old_ci.id=old_ca.cargo_item_id
       and old_ci.route_version_id=old_ca.route_version_id
      join haulvia.route_stops old_p on old_p.id=old_ca.pickup_stop_id
      join haulvia.route_stops old_d on old_d.id=old_ca.delivery_stop_id
      where old_o.shipment_id=p_shipment.id
        and old_o.route_version_id=v_old_route
      group by old_ci.stable_cargo_key,old_p.stable_stop_key,
               old_d.stable_stop_key,old_o.quantity_unit
    ) old_resolution
    where not exists (
        select 1
        from haulvia.cargo_allocations new_ca
        join haulvia.cargo_items new_ci
          on new_ci.id=new_ca.cargo_item_id and new_ci.route_version_id=new_ca.route_version_id
        join haulvia.route_stops new_p on new_p.id=new_ca.pickup_stop_id
        join haulvia.route_stops new_d on new_d.id=new_ca.delivery_stop_id
        where new_ca.route_version_id=v_new_route
          and new_ci.stable_cargo_key=old_resolution.stable_cargo_key
          and new_p.stable_stop_key=old_resolution.pickup_stable_stop_key
          and new_d.stable_stop_key=old_resolution.delivery_stable_stop_key
          and new_ca.quantity>=old_resolution.resolved_quantity
          and new_ca.quantity_unit=old_resolution.quantity_unit
      )
  ) then
    perform haulvia_command.fail(
      'ROUTE_INVALID','Amended route cannot erase a previously approved cargo outcome'
    );
  end if;

  if not exists (
    select 1 from haulvia.policy_versions pv
    where pv.id=v_policy and pv.publication_status='APPROVED'
      and pv.effective_from<=clock_timestamp()
      and (pv.effective_to is null or pv.effective_to>clock_timestamp())
  ) or jsonb_typeof(p_request -> 'evidenceRequirements')<>'object'
     or jsonb_typeof(p_request -> 'timingWindows')<>'object'
     or jsonb_typeof(p_request -> 'riskRules')<>'object'
     or haulvia_command.required_text(p_request,'policyConfigSha256') !~ '^[0-9a-fA-F]{64}$' then
    perform haulvia_command.fail('POLICY_SNAPSHOT_MISMATCH','Amendment requires a current recalculated evidence/policy snapshot');
  end if;
  insert into haulvia.shipment_rule_snapshots (
    shipment_id,route_version_id,policy_version_id,evidence_requirements,
    cancellation_rules,refund_rules,timing_windows,risk_rules,config_sha256
  ) values (
    p_shipment.id,v_new_route,v_policy,p_request -> 'evidenceRequirements',
    coalesce(p_request -> 'cancellationRules','{}'::jsonb),
    coalesce(p_request -> 'refundRules','{}'::jsonb),
    p_request -> 'timingWindows',p_request -> 'riskRules',
    lower(haulvia_command.required_text(p_request,'policyConfigSha256'))
  );

  v_price_snapshot := haulvia_command.create_price_snapshot(
    p_shipment,v_new_route,'ADJUSTMENT',p_request,v_actor
  );
  if (select total_amount from haulvia.shipment_price_snapshots where id=v_price_snapshot)<>v_additional then
    perform haulvia_command.fail('FINANCIAL_DECISION_INVALID','Amendment price snapshot must equal the additional payment amount');
  end if;
  if v_additional>0 and not v_emergency then
    if v_payment_intent is null or not exists (
      select 1 from haulvia.payment_intents pi
      where pi.id=v_payment_intent and pi.shipment_id=p_shipment.id
        and pi.offer_reservation_id is null and pi.status='SECURED'
        and pi.amount>=v_additional and pi.currency=v_currency
        and not exists (
          select 1 from haulvia.route_amendments ra
          where ra.additional_payment_intent_id=pi.id
        )
    ) then
      perform haulvia_command.fail(
        'ADDITIONAL_PAYMENT_NOT_SECURED','Non-emergency amendment work requires a separate secured payment intent'
      );
    end if;
    update haulvia.shipment_customer_payment_axes
    set secured_amount=secured_amount+v_additional,state='SECURED'
    where shipment_id=p_shipment.id;
  elsif v_additional>0 and v_emergency and v_payment_intent is null then
    insert into haulvia.workflow_holds (
      shipment_id,route_execution_id,hold_code,status,blocks_marketplace,
      blocks_route_movement,blocks_completion,reason,opened_by_profile_id,metadata
    ) values (
      p_shipment.id,v_execution.id,'EMERGENCY_AMENDMENT_PAYMENT_DUE','ACTIVE',
      false,false,true,'Emergency amendment additional payment remains due',v_actor,
      jsonb_build_object('amount',v_additional,'currency',v_currency,'priceSnapshotId',v_price_snapshot)
    ) returning id into v_payment_hold;
  elsif v_additional=0 and v_payment_intent is not null then
    perform haulvia_command.fail('FINANCIAL_DECISION_INVALID','Zero-price amendment cannot consume a payment intent');
  end if;

  -- Close only the old execution segment. All its events/evidence/movements stay retained.
  update haulvia.stop_attempts sa
  set state='CANCELLED',ended_at=coalesce(ended_at,clock_timestamp())
  where sa.stop_execution_id in (
    select se.id from haulvia.stop_executions se
    where se.route_execution_id=v_execution.id
      and se.state not in ('COMPLETED','FAILED','SKIPPED','CANCELLED')
  ) and sa.ended_at is null;
  update haulvia.stop_executions
  set state='CANCELLED'
  where route_execution_id=v_execution.id
    and state not in ('COMPLETED','FAILED','SKIPPED','CANCELLED');
  update haulvia.tracking_sessions set ended_at=clock_timestamp()
  where route_execution_id=v_execution.id and ended_at is null;
  update haulvia.route_executions
  set state='COMPLETED',completed_at=clock_timestamp(),
      active_stop_execution_id=null,active_route_leg_id=null,
      next_action='AMENDED_TO_NEW_ROUTE_VERSION',record_version=record_version+1
  where id=v_execution.id;

  update haulvia.route_versions set status='SUPERSEDED' where id=v_old_route;
  update haulvia.route_versions set status='ACTIVE' where id=v_new_route;
  insert into haulvia.route_executions (
    shipment_id,route_version_id,assignment_id,parent_route_execution_id,
    execution_kind,state,started_at,next_action,record_version
  ) values (
    p_shipment.id,v_new_route,v_assignment.id,v_execution.id,
    'AMENDMENT','ACTIVE',clock_timestamp(),'START_AMENDED_ROUTE',0
  ) returning id into v_new_execution;

  insert into haulvia.stop_executions (
    shipment_id,route_execution_id,route_version_id,route_stop_id,state,
    delivery_verification_state,current_attempt_no,completed_at
  )
  select p_shipment.id,v_new_execution,v_new_route,new_rs.id,
         coalesce(old_se.state,'PENDING'::haulvia.stop_state),
         coalesce(old_se.delivery_verification_state,'NOT_REQUIRED'::haulvia.delivery_verification_state),
         0,case when old_se.state='COMPLETED' then old_se.completed_at end
  from haulvia.route_stops new_rs
  left join lateral (
    select se.state,se.delivery_verification_state,se.completed_at
    from haulvia.stop_executions se
    join haulvia.route_stops old_rs on old_rs.id=se.route_stop_id
    where se.route_execution_id=v_execution.id
      and old_rs.stable_stop_key=new_rs.stable_stop_key
      and se.state in ('COMPLETED','FAILED','SKIPPED')
    limit 1
  ) old_se on true
  where new_rs.route_version_id=v_new_route
  order by new_rs.sequence_no;

  select se.id,rs.sequence_no into v_new_stop,v_new_sequence
  from haulvia.stop_executions se
  join haulvia.route_stops rs on rs.id=se.route_stop_id
  where se.route_execution_id=v_new_execution and se.state='PENDING'
  order by rs.sequence_no limit 1 for update of se;
  if v_new_stop is null then
    perform haulvia_command.fail('ROUTE_INVALID','Amended route has no eligible remaining stop');
  end if;
  select rl.id into v_new_leg from haulvia.route_legs rl
  where rl.route_version_id=v_new_route
    and rl.sequence_no=case when v_new_sequence=1 then 1 else v_new_sequence-1 end;
  if v_new_leg is null then
    perform haulvia_command.fail('ROUTE_INVALID','Amended route has no active leg for its first remaining stop');
  end if;
  insert into haulvia.stop_attempts(stop_execution_id,attempt_no,state)
  values(v_new_stop,1,'EN_ROUTE') returning id into v_new_attempt;
  update haulvia.stop_executions
  set state='EN_ROUTE',current_attempt_no=1,current_eta_at=v_eta,eta_updated_at=clock_timestamp()
  where id=v_new_stop;
  update haulvia.route_executions
  set active_stop_execution_id=v_new_stop,active_route_leg_id=v_new_leg,
      next_action='CONFIRM_ARRIVAL_AT_STOP',record_version=1
  where id=v_new_execution;
  insert into haulvia.tracking_sessions(route_execution_id,driver_id,started_at)
  values(v_new_execution,v_assignment.driver_id,clock_timestamp()) returning id into v_tracking;

  -- Carry earlier verified/approved outcomes to their corresponding allocation
  -- in the new route version without duplicating the original custody movement.
  insert into haulvia.cargo_resolution_outcomes (
    shipment_id,route_execution_id,route_version_id,stop_execution_id,
    cargo_allocation_id,outcome_code,quantity,quantity_unit,approval_snapshot,
    approved_by_profile_id,occurred_at,idempotency_key
  )
  select p_shipment.id,v_new_execution,v_new_route,new_se.id,new_ca.id,
         old_o.outcome_code,old_o.quantity,old_o.quantity_unit,
         jsonb_build_object('carriedFromCargoOutcomeId',old_o.id,'priorRouteVersionId',v_old_route),
         v_actor,old_o.occurred_at,v_idempotency||':carry-outcome:'||old_o.id::text
  from haulvia.cargo_resolution_outcomes old_o
  join haulvia.cargo_allocations old_ca
    on old_ca.id=old_o.cargo_allocation_id and old_ca.route_version_id=old_o.route_version_id
  join haulvia.stop_executions old_outcome_se
    on old_outcome_se.id=old_o.stop_execution_id
   and old_outcome_se.route_execution_id=old_o.route_execution_id
   and old_outcome_se.route_version_id=old_o.route_version_id
  join haulvia.route_stops old_outcome_rs
    on old_outcome_rs.id=old_outcome_se.route_stop_id
   and old_outcome_rs.route_version_id=old_o.route_version_id
  join haulvia.cargo_items old_ci
    on old_ci.id=old_ca.cargo_item_id and old_ci.route_version_id=old_ca.route_version_id
  join haulvia.route_stops old_p on old_p.id=old_ca.pickup_stop_id
  join haulvia.route_stops old_d on old_d.id=old_ca.delivery_stop_id
  join haulvia.cargo_items new_ci
    on new_ci.route_version_id=v_new_route and new_ci.stable_cargo_key=old_ci.stable_cargo_key
  join haulvia.cargo_allocations new_ca
    on new_ca.route_version_id=v_new_route and new_ca.cargo_item_id=new_ci.id
  join haulvia.route_stops new_p
    on new_p.id=new_ca.pickup_stop_id and new_p.stable_stop_key=old_p.stable_stop_key
  join haulvia.route_stops new_d
    on new_d.id=new_ca.delivery_stop_id and new_d.stable_stop_key=old_d.stable_stop_key
  join haulvia.route_stops new_outcome_rs
    on new_outcome_rs.route_version_id=v_new_route
   and new_outcome_rs.stable_stop_key=old_outcome_rs.stable_stop_key
  join haulvia.stop_executions new_se
    on new_se.route_execution_id=v_new_execution
   and new_se.route_stop_id=new_outcome_rs.id
  where old_o.shipment_id=p_shipment.id
    and old_o.route_version_id=v_old_route;
  get diagnostics v_copied_outcomes=row_count;

  insert into haulvia.route_updates (
    route_execution_id,active_route_leg_id,active_stop_execution_id,eta_at,
    custody_summary,captured_at,source
  ) values (
    v_new_execution,v_new_leg,v_new_stop,v_eta,
    haulvia_command.current_custody_summary(p_shipment.id),clock_timestamp(),'SERVER'
  ) returning id into v_route_update;
  v_eta_calculation := haulvia_command.recalculate_downstream_etas(
    p_shipment.id,v_new_execution,v_new_stop,'authorizeRouteAmendment',p_request,
    v_eta,v_route_update,0
  );

  insert into haulvia.route_amendments (
    shipment_id,assignment_id,prior_route_version_id,amended_route_version_id,
    prior_route_execution_id,amended_route_execution_id,price_snapshot_id,
    additional_payment_intent_id,additional_payment_amount,currency,
    emergency_waiver,reason,driver_acceptance_snapshot,amendment_snapshot,
    authorized_by_profile_id,idempotency_key
  ) values (
    p_shipment.id,v_assignment.id,v_old_route,v_new_route,v_execution.id,v_new_execution,
    v_price_snapshot,v_payment_intent,v_additional,v_currency,v_emergency,v_reason,
    p_request -> 'driverAcceptance',p_request -> 'amendmentSnapshot',v_actor,v_idempotency
  ) returning id into v_amendment_id;

  if jsonb_typeof(p_request -> 'resolvedRouteExceptionIds')='array' then
    update haulvia.route_exceptions re
    set status='RESOLVED',blocks_completion=false,
        resolution='Resolved by approved route amendment '||v_amendment_id::text,
        resolved_by_profile_id=v_actor,resolved_at=clock_timestamp()
    where re.shipment_id=p_shipment.id and re.id in (
      select value::uuid from jsonb_array_elements_text(p_request -> 'resolvedRouteExceptionIds')
    );
  end if;
  if jsonb_typeof(p_request -> 'releasedWorkflowHoldIds')='array' then
    update haulvia.workflow_holds wh
    set status='RELEASED',released_by_profile_id=v_actor,released_at=clock_timestamp(),
        release_reason='Released by approved route amendment '||v_amendment_id::text
    where wh.shipment_id=p_shipment.id and wh.status='ACTIVE' and wh.id in (
      select value::uuid from jsonb_array_elements_text(p_request -> 'releasedWorkflowHoldIds')
    );
  end if;
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;
  perform haulvia_command.append_stop_event(
    v_new_attempt,v_new_stop,'PENDING','EN_ROUTE','authorizeRouteAmendment',p_request,
    jsonb_build_object('routeAmendmentId',v_amendment_id,'priorRouteExecutionId',v_execution.id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id,'ROUTE_EXECUTION',v_execution.state::text,'ACTIVE',
    'authorizeRouteAmendment',p_request,v_new_execution,
    jsonb_build_object('priorRouteExecutionId',v_execution.id,'routeAmendmentId',v_amendment_id)
  );
  perform haulvia_command.append_audit(
    p_shipment,'authorizeRouteAmendment',p_request,
    jsonb_build_object('routeVersionId',v_old_route,'routeExecutionId',v_execution.id),
    jsonb_build_object('routeVersionId',v_new_route,'routeExecutionId',v_new_execution),
    jsonb_build_object(
      'routeAmendmentId',v_amendment_id,'priceSnapshotId',v_price_snapshot,
      'additionalPaymentAmount',v_additional,'emergencyWaiver',v_emergency,
      'carriedCargoOutcomes',v_copied_outcomes,'paymentHoldId',v_payment_hold
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,p_shipment.customer_profile_id,'ROUTE_AMENDMENT_ACTIVATED',p_request,
    'route-amendment',jsonb_build_object(
      'routeAmendmentId',v_amendment_id,'routeVersionId',v_new_route,
      'nextStopExecutionId',v_new_stop,'etaAt',v_eta
    )
  );
  return jsonb_build_object(
    'routeAmendmentId',v_amendment_id,'priorRouteVersionId',v_old_route,
    'routeVersionId',v_new_route,'priorRouteExecutionId',v_execution.id,
    'routeExecutionId',v_new_execution,'routeExecutionVersion',1,
    'stopExecutionId',v_new_stop,'stopAttemptId',v_new_attempt,
    'activeRouteLegId',v_new_leg,'trackingSessionId',v_tracking,
    'priceSnapshotId',v_price_snapshot,'additionalPaymentAmount',v_additional,
    'additionalPaymentIntentId',v_payment_intent,'emergencyWaiver',v_emergency,
    'paymentHoldId',v_payment_hold,'carriedCargoOutcomes',v_copied_outcomes,
    'routeEtaCalculationId',v_eta_calculation
  );
exception
  when invalid_text_representation or check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'ROUTE_AMENDMENT_INVALID','Route amendment violated route, custody, payment, or lineage rules',
      jsonb_build_object('databaseMessage',sqlerrm)
    );
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- C12-C14: live route updates, transit issues, and aggregate route resolution
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_c12_record_route_update(
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
  v_leg uuid := haulvia_command.required_uuid(p_request,'activeRouteLegId');
  v_lat numeric := haulvia_command.required_numeric(p_request,'latitude');
  v_lon numeric := haulvia_command.required_numeric(p_request,'longitude');
  v_accuracy numeric := haulvia_command.optional_numeric(p_request,'accuracyM');
  v_speed numeric := haulvia_command.optional_numeric(p_request,'speedKph');
  v_heading numeric := haulvia_command.optional_numeric(p_request,'headingDegrees');
  v_captured timestamptz := haulvia_command.required_timestamptz(p_request,'capturedAt');
  v_synced timestamptz := coalesce(nullif(p_request ->> 'syncedAt','')::timestamptz,clock_timestamp());
  v_eta timestamptz := haulvia_command.required_timestamptz(p_request,'etaAt');
  v_dwell integer := haulvia_command.optional_integer(p_request,'dwellSeconds');
  v_delay integer := haulvia_command.optional_integer(p_request,'delaySeconds');
  v_connectivity text := haulvia_command.required_text(p_request,'connectivityStatus');
  v_offline boolean := coalesce((p_request ->> 'isOfflineCapture')::boolean,false);
  v_source haulvia.tracking_source := coalesce(
    nullif(p_request ->> 'source',''),'DEVICE'
  )::haulvia.tracking_source;
  v_tracking uuid;
  v_point bigint;
  v_update uuid;
  v_calculation uuid;
  v_custody jsonb;
begin
  if p_shipment.shipment_state<>'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE','recordRouteUpdate requires ROUTE_IN_PROGRESS');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  perform haulvia_command.authorize_route_operator(v_assignment,p_request,true);
  perform haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.state not in ('ACTIVE','HELD') then
    perform haulvia_command.fail('INVALID_STATE','Route update requires an ACTIVE or HELD execution');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution,p_request,false);
  if v_execution.active_route_leg_id is distinct from v_leg or not exists (
    select 1 from haulvia.route_legs rl
    where rl.id=v_leg and rl.route_version_id=v_execution.route_version_id
  ) then
    perform haulvia_command.fail('STALE_ROUTE_POSITION','Route update active leg does not match the current execution');
  end if;
  if v_lat not between -90 and 90 or v_lon not between -180 and 180
     or (v_accuracy is not null and v_accuracy<0)
     or (v_speed is not null and v_speed<0)
     or (v_heading is not null and v_heading not between 0 and 360)
     or v_synced<v_captured or coalesce(v_dwell,0)<0 then
    perform haulvia_command.fail('INVALID_REQUEST','Tracking, time, speed, heading, or dwell values are invalid');
  end if;
  v_custody := haulvia_command.assert_custody_snapshot(p_shipment.id,p_request -> 'custodyBalance');
  select ts.id into v_tracking from haulvia.tracking_sessions ts
  where ts.route_execution_id=v_execution.id and ts.ended_at is null
  for update;
  if v_tracking is null then
    perform haulvia_command.fail('TRACKING_NOT_ACTIVE','The current execution has no active tracking session');
  end if;
  insert into haulvia.tracking_points (
    tracking_session_id,source,latitude,longitude,accuracy_m,speed_kph,
    heading_degrees,captured_at,synced_at,is_offline_capture
  ) values (
    v_tracking,v_source,v_lat,v_lon,v_accuracy,v_speed,v_heading,
    v_captured,v_synced,v_offline
  ) returning id into v_point;
  insert into haulvia.route_updates (
    route_execution_id,active_route_leg_id,active_stop_execution_id,
    eta_at,dwell_seconds,delay_seconds,connectivity_status,custody_summary,
    captured_at,synced_at,source
  ) values (
    v_execution.id,v_leg,v_stop.id,v_eta,v_dwell,v_delay,v_connectivity,v_custody,
    v_captured,v_synced,v_source
  ) returning id into v_update;
  v_calculation := haulvia_command.recalculate_downstream_etas(
    p_shipment.id,v_execution.id,v_stop.id,'recordRouteUpdate',p_request,
    v_eta,v_update,coalesce(v_delay,0)
  );
  update haulvia.route_executions set record_version=record_version+1 where id=v_execution.id;
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;
  perform haulvia_command.append_audit(
    p_shipment,'recordRouteUpdate',p_request,
    jsonb_build_object('routeExecutionVersion',v_execution.record_version),
    jsonb_build_object('routeExecutionVersion',v_execution.record_version+1),
    jsonb_build_object(
      'trackingPointId',v_point,'routeUpdateId',v_update,
      'routeEtaCalculationId',v_calculation,'custodyBalance',v_custody
    )
  );
  return jsonb_build_object(
    'routeExecutionId',v_execution.id,'routeExecutionVersion',v_execution.record_version+1,
    'stopExecutionId',v_stop.id,'activeRouteLegId',v_leg,
    'trackingPointId',v_point,'routeUpdateId',v_update,
    'routeEtaCalculationId',v_calculation,'etaAt',v_eta,
    'dwellSeconds',v_dwell,'delaySeconds',v_delay,
    'connectivityStatus',v_connectivity,'custodySummary',v_custody,
    'physicalPositionChanged',false
  );
exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
  perform haulvia_command.fail('INVALID_REQUEST','Route update contains an invalid typed value');
  return null;
end;
$$;

create or replace function haulvia_command.apply_c13_report_transit_issue(
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
  v_actor uuid := haulvia_command.optional_uuid(p_request,'actorProfileId');
  v_exception uuid;
  v_hold uuid;
  v_hold_request jsonb := p_request -> 'workflowHold';
  v_blocks_movement boolean := false;
  v_custody jsonb;
begin
  if p_shipment.shipment_state<>'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE','reportTransitIssue requires ROUTE_IN_PROGRESS');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  if v_actor is null then
    perform haulvia_command.assert_worker(v_actor,p_request ->> 'workerAuthority',array['ROUTE_OPERATIONS_WORKER']);
  elsif exists (
    select 1 from haulvia.drivers d where d.id=v_assignment.driver_id and d.profile_id=v_actor
  ) then
    null;
  else
    perform haulvia_command.authorize_customer(
      p_shipment,v_actor,haulvia_command.optional_uuid(p_request,'actorOrganizationId')
    );
  end if;
  perform haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.state not in ('ACTIVE','HELD') then
    perform haulvia_command.fail('INVALID_STATE','Transit issue requires an ACTIVE or HELD route execution');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution,p_request,false);
  if jsonb_typeof(p_request -> 'issueEvidence')<>'object'
     or p_request -> 'issueEvidence'='{}'::jsonb then
    perform haulvia_command.fail('INVALID_REQUEST','Transit issue requires structured evidence');
  end if;
  v_custody := haulvia_command.assert_custody_snapshot(p_shipment.id,p_request -> 'custodyBalance');
  insert into haulvia.route_exceptions (
    shipment_id,route_execution_id,stop_execution_id,cargo_item_id,
    exception_code,status,responsibility_code,blocks_completion,description,
    opened_by_profile_id,metadata
  ) values (
    p_shipment.id,v_execution.id,v_stop.id,
    haulvia_command.optional_uuid(p_request,'cargoItemId'),
    haulvia_command.required_text(p_request,'exceptionCode'),'OPEN',
    nullif(p_request ->> 'responsibilityCode',''),
    coalesce((p_request ->> 'blocksCompletion')::boolean,false),
    haulvia_command.required_text(p_request,'description'),v_actor,
    jsonb_build_object('issueEvidence',p_request -> 'issueEvidence','custodyBalance',v_custody)
  ) returning id into v_exception;
  if jsonb_typeof(v_hold_request)='object' and v_hold_request<>'{}'::jsonb then
    v_blocks_movement := coalesce((v_hold_request ->> 'blocksRouteMovement')::boolean,false);
    insert into haulvia.workflow_holds (
      shipment_id,route_execution_id,stop_execution_id,hold_code,status,
      blocks_marketplace,blocks_route_movement,blocks_completion,reason,
      opened_by_profile_id,metadata
    ) values (
      p_shipment.id,v_execution.id,v_stop.id,
      haulvia_command.required_text(v_hold_request,'holdCode'),'ACTIVE',
      coalesce((v_hold_request ->> 'blocksMarketplace')::boolean,false),
      v_blocks_movement,
      coalesce((v_hold_request ->> 'blocksCompletion')::boolean,false),
      haulvia_command.required_text(v_hold_request,'reason'),v_actor,
      jsonb_build_object('routeExceptionId',v_exception,'custodyBalance',v_custody)
    ) returning id into v_hold;
    update haulvia.route_exceptions set workflow_hold_id=v_hold where id=v_exception;
  end if;
  update haulvia.route_executions
  set state=case when v_blocks_movement then 'HELD'::haulvia.route_execution_state else state end,
      next_action=case when v_blocks_movement then 'RESOLVE_TRANSIT_ISSUE' else next_action end,
      record_version=record_version+1
  where id=v_execution.id;
  update haulvia.shipments set updated_at=clock_timestamp() where id=p_shipment.id;
  if v_hold is not null then
    perform haulvia_command.append_axis_event(
      p_shipment.id,'WORKFLOW_HOLD',null,'ACTIVE','reportTransitIssue',p_request,v_hold,
      jsonb_build_object('routeExceptionId',v_exception,'blocksRouteMovement',v_blocks_movement)
    );
  end if;
  perform haulvia_command.append_audit(
    p_shipment,'reportTransitIssue',p_request,
    jsonb_build_object('shipmentState',p_shipment.shipment_state,'activeStopExecutionId',v_stop.id),
    jsonb_build_object('shipmentState',p_shipment.shipment_state,'activeStopExecutionId',v_stop.id),
    jsonb_build_object('routeExceptionId',v_exception,'workflowHoldId',v_hold,'custodyBalance',v_custody)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,p_shipment.customer_profile_id,'TRANSIT_ISSUE_REPORTED',p_request,
    'transit-issue',jsonb_build_object(
      'routeExceptionId',v_exception,'workflowHoldId',v_hold,
      'blocksRouteMovement',v_blocks_movement
    )
  );
  return jsonb_build_object(
    'routeExecutionId',v_execution.id,'routeExecutionVersion',v_execution.record_version+1,
    'routeExecutionState',case when v_blocks_movement then 'HELD' else v_execution.state::text end,
    'stopExecutionId',v_stop.id,'routeExceptionId',v_exception,'workflowHoldId',v_hold,
    'custodySummary',v_custody,'physicalPositionChanged',false
  );
exception when invalid_text_representation then
  perform haulvia_command.fail('INVALID_REQUEST','Transit issue contains an invalid typed value');
  return null;
end;
$$;

create or replace function haulvia_command.apply_c14_complete_planned_route(
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
  v_route uuid;
  v_custody jsonb;
  v_summary jsonb;
  v_label text;
  v_resolution uuid;
  v_pending_confirmations integer;
begin
  if p_shipment.shipment_state<>'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE','completePlannedRoute requires ROUTE_IN_PROGRESS');
  end if;
  perform haulvia_command.authorize_evidence_reviewer(p_request);
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id,p_request);
  v_route := haulvia_command.assert_expected_route(
    p_shipment.id,p_request,array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id,v_assignment.id,p_request);
  if v_execution.route_version_id<>v_route or v_execution.state<>'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE','Current active route execution is required for resolution');
  end if;
  if exists (
    select 1 from haulvia.stop_executions se
    where se.route_execution_id=v_execution.id
      and se.state not in ('COMPLETED','FAILED','SKIPPED','CANCELLED')
  ) then
    perform haulvia_command.fail('ROUTE_NOT_RESOLVED','Every planned or authorized stop must have a terminal outcome');
  end if;
  if exists (
    select 1 from haulvia.workflow_holds wh
    where wh.shipment_id=p_shipment.id and wh.status='ACTIVE' and wh.blocks_completion
  ) or exists (
    select 1 from haulvia.route_exceptions re
    where re.shipment_id=p_shipment.id and re.blocks_completion
      and re.status not in ('RESOLVED','CLOSED')
  ) then
    perform haulvia_command.fail('WORKFLOW_HELD','Completion is blocked by an unresolved hold or route exception');
  end if;
  if exists (
    select 1
    from haulvia.cargo_allocations ca
    left join haulvia.cargo_resolution_outcomes cro
      on cro.route_version_id=ca.route_version_id and cro.cargo_allocation_id=ca.id
    where ca.route_version_id=v_route
    group by ca.id,ca.quantity,ca.quantity_unit
    having coalesce(sum(cro.quantity),0)<>ca.quantity
       or count(*) filter(
            where cro.id is not null and cro.quantity_unit<>ca.quantity_unit
          )>0
  ) then
    perform haulvia_command.fail(
      'CARGO_OUTCOME_INCOMPLETE',
      'Every active-route cargo allocation requires verified delivery or an approved recovery outcome'
    );
  end if;
  if exists (
    select 1 from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id=p_shipment.id and cb.onboard_quantity<>0
  ) then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID','Route cannot resolve with cargo remaining onboard');
  end if;
  if exists (
    select 1
    from haulvia.stop_executions se
    join haulvia.route_stops rs on rs.id=se.route_stop_id
    where se.route_execution_id=v_execution.id and se.state='COMPLETED'
      and not exists (
        select 1
        from haulvia.stop_executions evidence_se
        join haulvia.route_stops evidence_rs on evidence_rs.id=evidence_se.route_stop_id
        join haulvia.stop_attempts sa on sa.stop_execution_id=evidence_se.id
        join haulvia.stop_evidence e on e.stop_attempt_id=sa.id
        join haulvia.stop_evidence_reviews er on er.stop_evidence_id=e.id and er.status='VERIFIED'
        where evidence_se.shipment_id=p_shipment.id
          and evidence_rs.stable_stop_key=rs.stable_stop_key
      )
  ) then
    perform haulvia_command.fail('EVIDENCE_INVALID','Every completed stop requires retained verified evidence');
  end if;

  select jsonb_build_object(
    'byOutcomeAndUnit',coalesce(
      jsonb_agg(
        jsonb_build_object(
          'outcomeCode',summary.outcome_code,
          'quantity',summary.quantity,
          'quantityUnit',summary.quantity_unit,
          'outcomeCount',summary.outcome_count
        ) order by summary.outcome_code,summary.quantity_unit
      ),
      '[]'::jsonb
    ),
    'outcomeCount',coalesce(sum(summary.outcome_count),0)
  ) into v_summary
  from (
    select cro.outcome_code,cro.quantity_unit,
           sum(cro.quantity) as quantity,count(*) as outcome_count
    from haulvia.cargo_resolution_outcomes cro
    where cro.route_version_id=v_route
    group by cro.outcome_code,cro.quantity_unit
  ) summary;

  -- The public label enumerates every distinct outcome. It never combines
  -- quantities that use different units and never hides returned/stored cargo
  -- behind the shipment's aggregate internal DELIVERED state.
  select string_agg(labels.public_label,' + ' order by labels.sort_order)
  into v_label
  from (
    select distinct
      case cro.outcome_code
        when 'DELIVERED' then 'DELIVERED'
        when 'RETURNED' then 'RETURNED'
        when 'STORED' then 'STORED'
        when 'TRANSFERRED' then 'TRANSFERRED'
        when 'APPROVED_NOT_LOADED' then 'APPROVED NOT LOADED'
        when 'OTHER_APPROVED_RECOVERY' then 'OTHER APPROVED RECOVERY'
      end as public_label,
      case cro.outcome_code
        when 'DELIVERED' then 1
        when 'RETURNED' then 2
        when 'STORED' then 3
        when 'TRANSFERRED' then 4
        when 'APPROVED_NOT_LOADED' then 5
        when 'OTHER_APPROVED_RECOVERY' then 6
      end as sort_order
    from haulvia.cargo_resolution_outcomes cro
    where cro.route_version_id=v_route
  ) labels;
  v_custody := haulvia_command.current_custody_summary(p_shipment.id);
  select count(*) into v_pending_confirmations
  from haulvia.stop_executions se
  where se.shipment_id=p_shipment.id
    and se.delivery_verification_state='PENDING_RECEIVER_CONFIRMATION';
  insert into haulvia.route_resolution_records (
    shipment_id,route_execution_id,route_version_id,public_outcome_label,
    outcome_summary,custody_reconciliation,evidence_reconciliation,
    resolved_by_profile_id,idempotency_key
  ) values (
    p_shipment.id,v_execution.id,v_route,v_label,v_summary,v_custody,
    jsonb_build_object(
      'allCompletedStopsVerified',true,
      'pendingReceiverConfirmations',v_pending_confirmations,
      'pendingConfirmationDoesNotFabricateReceipt',true
    ),haulvia_command.optional_uuid(p_request,'actorProfileId'),
    haulvia_command.required_text(p_request,'idempotencyKey')
  ) returning id into v_resolution;
  update haulvia.tracking_sessions set ended_at=clock_timestamp()
  where route_execution_id=v_execution.id and ended_at is null;
  update haulvia.route_executions
  set state='COMPLETED',completed_at=clock_timestamp(),
      active_stop_execution_id=null,active_route_leg_id=null,
      next_action=case when v_pending_confirmations>0
        then 'AWAIT_RECEIVER_CONFIRMATION' else 'COMPLETE_SHIPMENT' end,
      record_version=record_version+1
  where id=v_execution.id;
  update haulvia.shipments set shipment_state='DELIVERED' where id=p_shipment.id;
  perform haulvia_command.append_axis_event(
    p_shipment.id,'ROUTE_EXECUTION','ACTIVE','COMPLETED','completePlannedRoute',p_request,
    v_execution.id,jsonb_build_object('routeResolutionId',v_resolution,'publicOutcomeLabel',v_label)
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id,'ROUTE_IN_PROGRESS','DELIVERED','completePlannedRoute',p_request,v_route,
    jsonb_build_object(
      'routeResolutionId',v_resolution,'publicOutcomeLabel',v_label,
      'pendingReceiverConfirmations',v_pending_confirmations
    )
  );
  perform haulvia_command.append_audit(
    p_shipment,'completePlannedRoute',p_request,
    jsonb_build_object('shipmentState','ROUTE_IN_PROGRESS'),
    jsonb_build_object('shipmentState','DELIVERED'),
    jsonb_build_object('routeResolutionId',v_resolution,'publicOutcomeLabel',v_label,'outcomeSummary',v_summary)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,p_shipment.customer_profile_id,'PLANNED_ROUTE_RESOLVED',p_request,
    'route-resolved',jsonb_build_object(
      'routeResolutionId',v_resolution,'publicOutcomeLabel',v_label,
      'pendingReceiverConfirmations',v_pending_confirmations
    )
  );
  return jsonb_build_object(
    'routeExecutionId',v_execution.id,'routeExecutionVersion',v_execution.record_version+1,
    'routeVersionId',v_route,'routeResolutionId',v_resolution,
    'shipmentState','DELIVERED','routeExecutionState','COMPLETED',
    'publicOutcomeLabel',v_label,'outcomeSummary',v_summary,
    'custodySummary',v_custody,'pendingReceiverConfirmations',v_pending_confirmations
  );
end;
$$;

-- Keep the established view column order and append Block C ETA/outcome data.
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
  coalesce(custody.summary, '{}'::jsonb) as custody_summary,
  active_se.current_eta_at as active_stop_eta_at,
  rr.public_outcome_label as route_public_outcome_label
from haulvia.shipments s
left join haulvia.shipment_marketplace_axes ma on ma.shipment_id=s.id
left join haulvia.shipment_customer_payment_axes pa on pa.shipment_id=s.id
left join haulvia.shipment_driver_payout_axes po on po.shipment_id=s.id
left join haulvia.shipment_dispute_axes da on da.shipment_id=s.id
left join haulvia.route_versions rv on rv.shipment_id=s.id and rv.status='ACTIVE'
left join haulvia.assignments a on a.shipment_id=s.id and a.status='ACTIVE'
left join haulvia.route_executions re
  on re.shipment_id=s.id and re.state in ('ACTIVE','HELD','RECOVERY_ACTIVE')
left join haulvia.stop_executions active_se on active_se.id=re.active_stop_execution_id
left join haulvia.route_resolution_records rr on rr.shipment_id=s.id
left join lateral (
  select jsonb_build_object(
    'hasVerifiedCustody',exists (
      select 1 from haulvia.shipment_custody_milestones scm where scm.shipment_id=s.id
    ),
    'balances',coalesce(
      jsonb_agg(jsonb_build_object(
        'stableCargoKey',cb.stable_cargo_key,
        'quantityUnit',cb.quantity_unit,
        'onboardQuantity',cb.onboard_quantity
      ) order by cb.stable_cargo_key,cb.quantity_unit)
      filter(where cb.stable_cargo_key is not null),'[]'::jsonb
    )
  ) as summary
  from haulvia.v_cargo_custody_balance cb where cb.shipment_id=s.id
) custody on true;

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
    'commandId',p_command_id,
    'commandName',p_command_name,
    'shipmentId',c.shipment_id,
    'shipmentReference',c.shipment_reference,
    'shipmentState',c.shipment_state,
    'marketplaceState',c.marketplace_state,
    'customerPaymentState',c.customer_payment_state,
    'driverPayoutState',c.driver_payout_state,
    'disputeState',c.dispute_state,
    'lockVersion',c.lock_version,
    'currentRouteVersionId',c.active_route_version_id,
    'activeAssignmentId',c.active_assignment_id,
    'activeRouteExecutionId',c.active_route_execution_id,
    'routeExecutionState',c.route_execution_state,
    'activeStopExecutionId',c.active_stop_execution_id,
    'activeRouteLegId',c.active_route_leg_id,
    'nextAction',c.next_action,
    'routeExecutionVersion',c.route_execution_record_version,
    'custodySummary',c.custody_summary,
    'activeStopEtaAt',c.active_stop_eta_at,
    'routePublicOutcomeLabel',c.route_public_outcome_label
  ) || coalesce(p_affected,'{}'::jsonb)
  from haulvia.v_shipment_operating_context c
  where c.shipment_id=p_shipment_id;
$$;

-- ---------------------------------------------------------------------------
-- Trusted dispatcher and the 14 approved named Block C command entry points
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.execute_block_c_command(
  p_command_name text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request,'actorProfileId');
  v_command_id uuid := haulvia_command.required_uuid(p_request,'commandId');
  v_idempotency_key text := haulvia_command.required_text(p_request,'idempotencyKey');
  v_request_hash text := haulvia_command.required_text(p_request,'requestHash');
  v_replay jsonb;
  v_shipment haulvia.shipments%rowtype;
  v_affected jsonb;
  v_result jsonb;
begin
  v_replay := haulvia_command.begin_request(
    v_actor,p_command_name,v_idempotency_key,v_request_hash
  );
  if v_replay is not null then
    return v_replay;
  end if;
  v_shipment := haulvia_command.lock_shipment(p_request);
  case p_command_name
    when 'advanceToNextStop' then
      v_affected := haulvia_command.apply_c01_advance_to_next_stop(v_shipment,p_request);
    when 'confirmArrivalAtStop' then
      v_affected := haulvia_command.apply_c02_confirm_arrival_at_stop(v_shipment,p_request);
    when 'correctStopArrival' then
      v_affected := haulvia_command.apply_c03_correct_stop_arrival(v_shipment,p_request);
    when 'startStopService' then
      v_affected := haulvia_command.apply_c04_start_stop_service(v_shipment,p_request);
    when 'submitStopEvidence' then
      v_affected := haulvia_command.apply_c05_submit_stop_evidence(v_shipment,p_request);
    when 'verifyPickupStop' then
      v_affected := haulvia_command.apply_c06_verify_pickup_stop(v_shipment,p_request);
    when 'verifyDeliveryStop' then
      v_affected := haulvia_command.apply_c07_verify_delivery_stop(v_shipment,p_request);
    when 'reportFailedPickupStop' then
      v_affected := haulvia_command.apply_c08_report_failed_pickup_stop(v_shipment,p_request);
    when 'reportFailedDeliveryStop' then
      v_affected := haulvia_command.apply_c09_report_failed_delivery_stop(v_shipment,p_request);
    when 'authorizeContinueAfterStopFailure' then
      v_affected := haulvia_command.apply_c10_authorize_continue_after_failure(v_shipment,p_request);
    when 'authorizeRouteAmendment' then
      v_affected := haulvia_command.apply_c11_authorize_route_amendment(v_shipment,p_request);
    when 'recordRouteUpdate' then
      v_affected := haulvia_command.apply_c12_record_route_update(v_shipment,p_request);
    when 'reportTransitIssue' then
      v_affected := haulvia_command.apply_c13_report_transit_issue(v_shipment,p_request);
    when 'completePlannedRoute' then
      v_affected := haulvia_command.apply_c14_complete_planned_route(v_shipment,p_request);
    else
      perform haulvia_command.fail('INVALID_REQUEST','Command is not an approved Block C handler');
  end case;
  v_result := haulvia_command.operating_context(
    v_shipment.id,p_command_name,v_command_id,v_affected
  );
  return haulvia_command.complete_request(
    v_actor,p_command_name,v_idempotency_key,v_result
  );
end;
$$;

create or replace function haulvia_command.command_advance_to_next_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('advanceToNextStop',p_request); $$;

create or replace function haulvia_command.command_confirm_arrival_at_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('confirmArrivalAtStop',p_request); $$;

create or replace function haulvia_command.command_correct_stop_arrival(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('correctStopArrival',p_request); $$;

create or replace function haulvia_command.command_start_stop_service(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('startStopService',p_request); $$;

create or replace function haulvia_command.command_submit_stop_evidence(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('submitStopEvidence',p_request); $$;

create or replace function haulvia_command.command_verify_pickup_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('verifyPickupStop',p_request); $$;

create or replace function haulvia_command.command_verify_delivery_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('verifyDeliveryStop',p_request); $$;

create or replace function haulvia_command.command_report_failed_pickup_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('reportFailedPickupStop',p_request); $$;

create or replace function haulvia_command.command_report_failed_delivery_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('reportFailedDeliveryStop',p_request); $$;

create or replace function haulvia_command.command_authorize_continue_after_stop_failure(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('authorizeContinueAfterStopFailure',p_request); $$;

create or replace function haulvia_command.command_authorize_route_amendment(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('authorizeRouteAmendment',p_request); $$;

create or replace function haulvia_command.command_record_route_update(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('recordRouteUpdate',p_request); $$;

create or replace function haulvia_command.command_report_transit_issue(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('reportTransitIssue',p_request); $$;

create or replace function haulvia_command.command_complete_planned_route(p_request jsonb)
returns jsonb language sql security definer
set search_path=haulvia,haulvia_command,pg_temp
as $$ select haulvia_command.execute_block_c_command('completePlannedRoute',p_request); $$;

revoke all on all functions in schema haulvia_command from public;

do $$
declare
  v_signature text;
begin
  if exists(select 1 from pg_roles where rolname='service_role') then
    grant usage on schema haulvia_command to service_role;
    execute 'revoke execute on all functions in schema haulvia_command from service_role';
    for v_signature in
      select format(
        '%I.%I(%s)',n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)
      )
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='haulvia_command' and left(p.proname,8)='command_'
      order by p.proname,p.oid
    loop
      execute 'grant execute on function '||v_signature||' to service_role';
    end loop;
  end if;
end;
$$;

comment on table haulvia.route_eta_calculations is
  'Append-only downstream ETA calculation header using remaining legs plus expected stop-service time.';
comment on table haulvia.route_stop_eta_predictions is
  'Append-only per-stop ETA predictions and affected-contact notification linkage.';
comment on table haulvia.stop_failure_reports is
  'Immutable failed pickup/delivery fact with evidence, cargo, custody, responsibility, grace, and downstream impact.';
comment on table haulvia.stop_continuation_authorizations is
  'Separate authorization to continue after a failed stop; the failed stop itself remains unchanged.';
comment on table haulvia.route_amendments is
  'Immutable link between retained prior and newly active route/execution versions, driver acceptance, price, and funding.';
comment on table haulvia.cargo_resolution_outcomes is
  'Quantity-level verified delivery or approved recovery outcome used by aggregate route resolution.';
comment on table haulvia.route_resolution_records is
  'Aggregate internal DELIVERED evidence plus accurate public delivered/returned/stored/recovery label.';

commit;
