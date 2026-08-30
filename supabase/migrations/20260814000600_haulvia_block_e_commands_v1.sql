-- Haulvia Block E command layer v1
-- Approved source: State Transition Matrix v1.1, Block E (E01-E16)
-- Depends on: foundation v1 and Blocks A-D v1
-- Target: PostgreSQL 16; compatible with Supabase Postgres
-- Security boundary: trusted service role only; end-user RLS remains deferred.

begin;

set local search_path = haulvia, haulvia_command, public;

alter table haulvia.pre_custody_financial_decisions
  drop constraint pre_custody_financial_decisions_command_name_check;
alter table haulvia.pre_custody_financial_decisions
  add constraint pre_custody_financial_decisions_command_name_check check (
    command_name in (
      'cancelBeforeAnyCustody', 'releaseDriverBeforeAnyCustody',
      'cancelAssignedBeforeCustody', 'prepareFailedFirstPickupRepost',
      'closeFailedFirstPickup'
    )
  );

-- ---------------------------------------------------------------------------
-- Immutable retry, recovery, custody, dispute-resolution, and repost evidence
-- ---------------------------------------------------------------------------

create table haulvia.stop_retry_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  failed_stop_attempt_id uuid not null references haulvia.stop_attempts(id),
  retry_stop_attempt_id uuid not null unique references haulvia.stop_attempts(id),
  stop_failure_report_id uuid references haulvia.stop_failure_reports(id),
  serviceability_snapshot jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_execution_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, route_version_id)
    references haulvia.route_versions(shipment_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  check (failed_stop_attempt_id <> retry_stop_attempt_id),
  check (serviceability_snapshot <> '{}'::jsonb)
);

create table haulvia.failed_first_pickup_resolutions (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null unique references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  assignment_id uuid not null references haulvia.assignments(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  stop_failure_report_id uuid references haulvia.stop_failure_reports(id),
  route_exception_id uuid not null references haulvia.route_exceptions(id),
  pre_custody_financial_decision_id uuid references haulvia.pre_custody_financial_decisions(id),
  resolution_code text not null check (
    resolution_code in ('PREPARED_FOR_REPOST', 'CANCELLED', 'EXPIRED')
  ),
  responsibility_code text not null,
  decision_snapshot jsonb not null,
  resolved_by_profile_id uuid references haulvia.profiles(id),
  resolved_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, assignment_id)
    references haulvia.assignments(shipment_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  check (decision_snapshot <> '{}'::jsonb)
);

create table haulvia.custody_transfer_authorizations (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  custody_transfer_id uuid not null unique references haulvia.custody_transfers(id),
  from_assignment_id uuid not null references haulvia.assignments(id),
  to_assignment_id uuid not null unique references haulvia.assignments(id),
  custody_balance_snapshot jsonb not null,
  handoff_evidence_manifest jsonb not null,
  authority_snapshot jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  reauth_session_id uuid references haulvia.reauth_sessions(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  check (from_assignment_id <> to_assignment_id),
  check (custody_balance_snapshot <> '{}'::jsonb),
  check (jsonb_typeof(handoff_evidence_manifest) = 'array'
         and jsonb_array_length(handoff_evidence_manifest) > 0),
  check (authority_snapshot <> '{}'::jsonb)
);

create table haulvia.recovery_route_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  prior_route_version_id uuid not null references haulvia.route_versions(id),
  recovery_route_version_id uuid not null unique references haulvia.route_versions(id),
  prior_route_execution_id uuid not null references haulvia.route_executions(id),
  recovery_route_execution_id uuid not null unique references haulvia.route_executions(id),
  assignment_id uuid not null references haulvia.assignments(id),
  price_snapshot_id uuid not null references haulvia.shipment_price_snapshots(id),
  additional_payment_intent_id uuid references haulvia.payment_intents(id),
  recovery_kind haulvia.route_execution_kind not null check (
    recovery_kind in ('RECOVERY', 'RETURN', 'REDELIVERY')
  ),
  recovery_action_code text not null check (
    recovery_action_code in ('RETURN', 'ALTERNATE_DELIVERY', 'REDELIVERY', 'STORAGE', 'TRANSFER', 'OTHER_RECOVERY')
  ),
  additional_payment_amount numeric(14,2) not null default 0,
  currency char(3) not null,
  emergency_waiver boolean not null default false,
  provider_acceptance_snapshot jsonb not null,
  custody_balance_snapshot jsonb not null,
  recovery_snapshot jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  reauth_session_id uuid references haulvia.reauth_sessions(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  foreign key (shipment_id, prior_route_version_id)
    references haulvia.route_versions(shipment_id, id),
  foreign key (shipment_id, recovery_route_version_id)
    references haulvia.route_versions(shipment_id, id),
  foreign key (shipment_id, prior_route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, recovery_route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, assignment_id)
    references haulvia.assignments(shipment_id, id),
  foreign key (shipment_id, price_snapshot_id)
    references haulvia.shipment_price_snapshots(shipment_id, id),
  foreign key (shipment_id, additional_payment_intent_id)
    references haulvia.payment_intents(shipment_id, id),
  check (prior_route_version_id <> recovery_route_version_id),
  check (prior_route_execution_id <> recovery_route_execution_id),
  check (additional_payment_amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check (provider_acceptance_snapshot <> '{}'::jsonb),
  check (custody_balance_snapshot <> '{}'::jsonb),
  check (recovery_snapshot <> '{}'::jsonb)
);

create table haulvia.storage_custody_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  workflow_hold_id uuid not null unique references haulvia.workflow_holds(id),
  storage_location_snapshot jsonb not null,
  cargo_manifest jsonb not null,
  custody_proof jsonb not null,
  expense_snapshot jsonb not null,
  responsible_party_code text not null,
  release_conditions jsonb not null,
  resolution_deadline timestamptz,
  secured_by_profile_id uuid references haulvia.profiles(id),
  secured_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  check (storage_location_snapshot <> '{}'::jsonb),
  check (jsonb_typeof(cargo_manifest) = 'array' and jsonb_array_length(cargo_manifest) > 0),
  check (custody_proof <> '{}'::jsonb),
  check (expense_snapshot <> '{}'::jsonb),
  check (release_conditions <> '{}'::jsonb),
  check (resolution_deadline is null or resolution_deadline > secured_at)
);

create table haulvia.return_handoff_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  stop_attempt_id uuid not null references haulvia.stop_attempts(id),
  terminal_return boolean not null,
  cargo_manifest jsonb not null,
  movement_ids jsonb not null,
  evidence_snapshot jsonb not null,
  custody_reconciliation jsonb not null,
  mixed_outcome_snapshot jsonb not null,
  verified_by_profile_id uuid references haulvia.profiles(id),
  verified_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_execution_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references haulvia.stop_executions(id, route_execution_id, route_version_id),
  check (jsonb_typeof(cargo_manifest) = 'array' and jsonb_array_length(cargo_manifest) > 0),
  check (jsonb_typeof(movement_ids) = 'array' and jsonb_array_length(movement_ids) > 0),
  check (evidence_snapshot <> '{}'::jsonb),
  check (custody_reconciliation <> '{}'::jsonb),
  check (mixed_outcome_snapshot <> '{}'::jsonb)
);

create table haulvia.dispute_operational_controls (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  dispute_id uuid not null unique references haulvia.disputes(id),
  route_execution_id uuid references haulvia.route_executions(id),
  stop_execution_id uuid references haulvia.stop_executions(id),
  workflow_hold_id uuid unique references haulvia.workflow_holds(id),
  blocks_route_movement boolean not null,
  control_snapshot jsonb not null,
  created_by_profile_id uuid references haulvia.profiles(id),
  created_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  unique (shipment_id, idempotency_key),
  check ((blocks_route_movement and workflow_hold_id is not null)
         or (not blocks_route_movement and workflow_hold_id is null)),
  check (control_snapshot <> '{}'::jsonb)
);

create table haulvia.dispute_resolution_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  dispute_id uuid not null unique references haulvia.disputes(id),
  prior_financial_hold_id uuid references haulvia.financial_holds(id),
  retained_financial_hold_id uuid references haulvia.financial_holds(id),
  decision_code text not null check (
    decision_code in (
      'FULL_PAYOUT', 'FULL_REFUND', 'PARTIAL_SPLIT', 'EXTRA_PAYMENT',
      'REDELIVERY', 'RETURN', 'STORAGE', 'NO_MONETARY_CHANGE',
      'INSURER_REFERRAL', 'PAYMENT_PROVIDER_REFERRAL', 'AUTHORITY_REFERRAL'
    )
  ),
  financial_allocation jsonb not null,
  next_route_action jsonb not null,
  evidence_decision jsonb not null,
  resolution_summary text not null,
  resolved_by_profile_id uuid not null references haulvia.profiles(id),
  reauth_session_id uuid not null references haulvia.reauth_sessions(id),
  resolved_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  check (financial_allocation <> '{}'::jsonb),
  check (next_route_action <> '{}'::jsonb),
  check (evidence_decision <> '{}'::jsonb),
  check (length(btrim(resolution_summary)) >= 8)
);

create table haulvia.workflow_resumption_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  source_type text not null check (source_type in ('DISPUTE', 'ROUTE_EXCEPTION')),
  source_id uuid not null,
  workflow_hold_id uuid not null unique references haulvia.workflow_holds(id),
  next_stop_execution_id uuid not null references haulvia.stop_executions(id),
  prior_route_state haulvia.route_execution_state not null,
  resumed_route_state haulvia.route_execution_state not null check (
    resumed_route_state in ('ACTIVE', 'RECOVERY_ACTIVE')
  ),
  prior_stop_state haulvia.stop_state not null,
  resumed_stop_state haulvia.stop_state not null check (
    resumed_stop_state in ('EN_ROUTE', 'ARRIVED')
  ),
  custody_balance_snapshot jsonb not null,
  next_action text not null,
  authorization_snapshot jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_execution_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, route_version_id)
    references haulvia.route_versions(shipment_id, id),
  check (custody_balance_snapshot <> '{}'::jsonb),
  check (authorization_snapshot <> '{}'::jsonb)
);

create table haulvia.terminal_shipment_reposts (
  id uuid primary key default gen_random_uuid(),
  source_shipment_id uuid not null references haulvia.shipments(id),
  new_shipment_id uuid not null unique references haulvia.shipments(id),
  source_route_version_id uuid not null references haulvia.route_versions(id),
  new_route_version_id uuid not null unique references haulvia.route_versions(id),
  source_terminal_state haulvia.shipment_state not null check (
    source_terminal_state in ('CANCELLED', 'EXPIRED', 'COMPLETED', 'RETURNED_TO_SENDER')
  ),
  copied_stop_count integer not null,
  copied_leg_count integer not null,
  copied_cargo_count integer not null,
  copied_allocation_count integer not null,
  eligibility_snapshot jsonb not null,
  copied_by_profile_id uuid references haulvia.profiles(id),
  copied_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (source_shipment_id, idempotency_key),
  check (source_shipment_id <> new_shipment_id),
  check (source_route_version_id <> new_route_version_id),
  check (copied_stop_count >= 2 and copied_leg_count >= 1
         and copied_cargo_count >= 1 and copied_allocation_count >= 1),
  check (eligibility_snapshot <> '{}'::jsonb)
);

create index stop_retry_records_stop_idx
  on haulvia.stop_retry_records (stop_execution_id, authorized_at, id);
create index recovery_route_records_shipment_idx
  on haulvia.recovery_route_records (shipment_id, authorized_at, id);
create index storage_custody_records_active_idx
  on haulvia.storage_custody_records (shipment_id, secured_at, id);
create index dispute_resolution_records_shipment_idx
  on haulvia.dispute_resolution_records (shipment_id, resolved_at, id);
create index terminal_shipment_reposts_source_idx
  on haulvia.terminal_shipment_reposts (source_shipment_id, copied_at, id);

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'stop_retry_records', 'failed_first_pickup_resolutions',
    'custody_transfer_authorizations', 'recovery_route_records',
    'storage_custody_records', 'return_handoff_records',
    'dispute_operational_controls', 'dispute_resolution_records',
    'workflow_resumption_records', 'terminal_shipment_reposts'
  ]
  loop
    execute format(
      'create trigger %I before update or delete on haulvia.%I for each row execute function haulvia.reject_append_only_mutation()',
      v_table || '_append_only', v_table
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- E13-E15: dispute controls, evidence-based resolution, and explicit resume
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_e13_open_dispute(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
  v_provider_id uuid := haulvia_command.optional_uuid(p_request, 'providerId');
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop_id uuid := haulvia_command.optional_uuid(p_request, 'stopExecutionId');
  v_cargo_id uuid := haulvia_command.optional_uuid(p_request, 'cargoItemId');
  v_amount numeric := haulvia_command.required_numeric(p_request, 'disputedAmount');
  v_category text := upper(haulvia_command.required_text(p_request, 'categoryCode'));
  v_description text := haulvia_command.required_text(p_request, 'description');
  v_blocks_movement boolean := coalesce(
    nullif(p_request ->> 'blocksRouteMovement', '')::boolean, false
  );
  v_control jsonb := coalesce(p_request -> 'operationalControl', '{}'::jsonb);
  v_basis text := upper(coalesce(v_control ->> 'movementStopBasis', 'CONTINUE'));
  v_is_customer boolean := false;
  v_is_provider boolean := false;
  v_result jsonb;
  v_dispute_id uuid;
  v_hold_id uuid;
  v_route_id uuid;
  v_prior_route_state haulvia.route_execution_state;
begin
  if p_shipment.shipment_state = 'DRAFT' then
    perform haulvia_command.fail('INVALID_STATE', 'A draft shipment has no disputable service event');
  end if;
  select * into v_assignment
  from haulvia.assignments a
  where a.id = haulvia_command.required_uuid(p_request, 'expectedAssignmentId')
    and a.shipment_id = p_shipment.id
    and a.status in ('ACTIVE', 'COMPLETED', 'CANCELLED', 'TRANSFERRED', 'REPLACED')
  for update;
  if not found then
    perform haulvia_command.fail('ASSIGNMENT_NOT_FOUND', 'The retained whole-route assignment was not found');
  end if;

  v_is_customer := p_shipment.customer_profile_id = v_actor or (
    p_shipment.customer_organization_id is not null
    and p_shipment.customer_organization_id = v_org
    and exists (
      select 1 from haulvia.organization_memberships om
      where om.organization_id = v_org and om.profile_id = v_actor
        and om.status = 'ACTIVE'
        and (om.ends_at is null or om.ends_at > clock_timestamp())
    )
  );
  v_is_provider := v_provider_id = v_assignment.provider_id and (
    exists (
      select 1 from haulvia.drivers d
      where d.id = v_assignment.driver_id and d.profile_id = v_actor
    ) or exists (
      select 1
      from haulvia.service_providers sp
      join haulvia.organization_memberships om on om.organization_id = sp.organization_id
      where sp.id = v_provider_id and om.profile_id = v_actor
        and om.status = 'ACTIVE'
        and (om.ends_at is null or om.ends_at > clock_timestamp())
    )
  );
  if not v_is_customer and not v_is_provider then
    perform haulvia_command.fail(
      'NOT_AUTHORIZED', 'Only the owning customer or retained assigned provider may open this dispute'
    );
  end if;
  if jsonb_typeof(v_control) <> 'object' or v_control = '{}'::jsonb then
    perform haulvia_command.fail(
      'OPERATIONAL_CONTROL_REQUIRED',
      'operationalControl must state whether physical movement continues'
    );
  end if;
  if v_blocks_movement and v_basis not in ('UNSAFE', 'UNLAWFUL', 'FORMAL_HOLD') then
    perform haulvia_command.fail(
      'ROUTE_HOLD_NOT_JUSTIFIED',
      'A dispute may stop physical movement only when unsafe, unlawful, or formally held'
    );
  end if;
  if not v_blocks_movement and coalesce((v_control ->> 'movementContinues')::boolean, false) is not true then
    perform haulvia_command.fail(
      'OPERATIONAL_CONTROL_REQUIRED',
      'A non-blocking dispute must explicitly preserve physical movement'
    );
  end if;

  v_result := haulvia_command.open_post_delivery_dispute_record(
    p_shipment, v_stop_id, v_cargo_id,
    case when v_is_customer then v_actor end,
    case when v_is_provider then v_provider_id end,
    null, v_category, v_description, v_amount, p_shipment.currency,
    p_request -> 'evidenceManifest', p_request -> 'financialAllocation',
    p_request || jsonb_build_object('commandName', 'openDispute')
  );
  v_dispute_id := (v_result ->> 'disputeId')::uuid;
  if nullif(v_result ->> 'financialHoldId', '') is not null then
    update haulvia.financial_holds
    set source_type = 'DISPUTE'
    where id = (v_result ->> 'financialHoldId')::uuid;
  end if;

  if v_blocks_movement then
    v_route_id := haulvia_command.assert_expected_route(
      p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
    );
    v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
    if v_execution.route_version_id <> v_route_id
       or v_execution.state not in ('ACTIVE', 'RECOVERY_ACTIVE', 'HELD') then
      perform haulvia_command.fail(
        'INVALID_STATE', 'The route to hold must be the current moving or already-held execution'
      );
    end if;
    if v_stop_id is not null and not exists (
      select 1 from haulvia.stop_executions se
      where se.id = v_stop_id and se.route_execution_id = v_execution.id
    ) then
      perform haulvia_command.fail('STOP_NOT_CURRENT', 'Dispute stop is not part of the held execution');
    end if;
    v_prior_route_state := v_execution.state;
    insert into haulvia.workflow_holds (
      shipment_id, route_execution_id, stop_execution_id, hold_code,
      blocks_route_movement, blocks_completion, reason, opened_by_profile_id
    ) values (
      p_shipment.id, v_execution.id, v_stop_id, 'DISPUTE_ROUTE_HOLD',
      true, true, v_description, v_actor
    ) returning id into v_hold_id;
    update haulvia.route_executions
    set state = 'HELD', next_action = 'AWAIT_DISPUTE_RESOLUTION',
        record_version = record_version + 1
    where id = v_execution.id;
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'ROUTE_EXECUTION', v_prior_route_state::text, 'HELD',
      'openDispute', p_request, v_execution.id,
      jsonb_build_object('disputeId', v_dispute_id, 'workflowHoldId', v_hold_id)
    );
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'WORKFLOW_HOLD', null, 'ACTIVE',
      'openDispute', p_request, v_hold_id,
      jsonb_build_object('disputeId', v_dispute_id, 'movementStopBasis', v_basis)
    );
  end if;

  insert into haulvia.dispute_operational_controls (
    shipment_id, dispute_id, route_execution_id, stop_execution_id,
    workflow_hold_id, blocks_route_movement, control_snapshot,
    created_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_dispute_id, v_execution.id, v_stop_id,
    v_hold_id, v_blocks_movement, v_control, v_actor,
    haulvia_command.required_text(p_request, 'idempotencyKey')
  );
  perform haulvia_command.append_audit(
    p_shipment, 'openDispute', p_request,
    jsonb_build_object(
      'shipmentState', p_shipment.shipment_state,
      'routeExecutionState', v_prior_route_state
    ),
    jsonb_build_object(
      'shipmentState', p_shipment.shipment_state,
      'routeExecutionState', case when v_blocks_movement then 'HELD' else null end
    ),
    jsonb_build_object(
      'disputeId', v_dispute_id, 'financialHoldId', v_result -> 'financialHoldId',
      'workflowHoldId', v_hold_id, 'blocksRouteMovement', v_blocks_movement,
      'operationalHistoryRewritten', false
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'DISPUTE_OPENED',
    p_request, 'dispute-' || v_dispute_id::text,
    jsonb_build_object(
      'disputeId', v_dispute_id, 'protectedAmount', v_result -> 'protectedAmount',
      'blocksRouteMovement', v_blocks_movement
    )
  );
  return v_result || jsonb_build_object(
    'shipmentState', p_shipment.shipment_state,
    'assignmentId', v_assignment.id,
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', case
      when v_blocks_movement then v_execution.record_version + 1 else null end,
    'workflowHoldId', v_hold_id,
    'blocksRouteMovement', v_blocks_movement,
    'operationalHistoryRewritten', false
  );
exception when invalid_text_representation then
  perform haulvia_command.fail('INVALID_REQUEST', 'Dispute request contains an invalid value');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Operating context: preserve prior columns and append Block E summaries
-- ---------------------------------------------------------------------------

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
  rr.public_outcome_label as route_public_outcome_label,
  coalesce(review.pending_count, 0) as pending_delivery_review_count,
  coalesce(holds.active_amount, 0) as active_disputed_amount,
  coalesce(paid.paid_amount, 0) as paid_payout_amount,
  recovery.record_id as active_recovery_route_record_id,
  storage.record_id as active_storage_custody_record_id,
  coalesce(transfer.verified_count, 0) as verified_custody_transfer_count,
  coalesce(reposts.repost_count, 0) as terminal_repost_count,
  coalesce(resumable.resumable_count, 0) as resumable_workflow_hold_count
from haulvia.shipments s
left join haulvia.shipment_marketplace_axes ma on ma.shipment_id = s.id
left join haulvia.shipment_customer_payment_axes pa on pa.shipment_id = s.id
left join haulvia.shipment_driver_payout_axes po on po.shipment_id = s.id
left join haulvia.shipment_dispute_axes da on da.shipment_id = s.id
left join haulvia.route_versions rv on rv.shipment_id = s.id and rv.status = 'ACTIVE'
left join haulvia.assignments a on a.shipment_id = s.id and a.status = 'ACTIVE'
left join haulvia.route_executions re
  on re.shipment_id = s.id and re.state in ('ACTIVE', 'HELD', 'RECOVERY_ACTIVE')
left join haulvia.stop_executions active_se on active_se.id = re.active_stop_execution_id
left join haulvia.route_resolution_records rr on rr.shipment_id = s.id
left join lateral (
  select jsonb_build_object(
    'hasVerifiedCustody', exists (
      select 1 from haulvia.shipment_custody_milestones scm where scm.shipment_id = s.id
    ),
    'balances', coalesce(
      jsonb_agg(jsonb_build_object(
        'stableCargoKey', cb.stable_cargo_key,
        'quantityUnit', cb.quantity_unit,
        'onboardQuantity', cb.onboard_quantity
      ) order by cb.stable_cargo_key, cb.quantity_unit)
      filter (where cb.stable_cargo_key is not null), '[]'::jsonb
    )
  ) as summary
  from haulvia.v_cargo_custody_balance cb where cb.shipment_id = s.id
) custody on true
left join lateral (
  select count(*)::integer as pending_count
  from haulvia.delivery_review_windows drw
  where drw.shipment_id = s.id
    and not exists (
      select 1 from haulvia.delivery_review_window_resolutions drwr
      where drwr.delivery_review_window_id = drw.id
    )
) review on true
left join lateral (
  select coalesce(sum(fh.amount), 0) as active_amount
  from haulvia.financial_holds fh
  where fh.shipment_id = s.id and fh.status = 'ACTIVE'
) holds on true
left join lateral (
  select coalesce(sum(pt.amount), 0) as paid_amount
  from haulvia.driver_payouts dp
  join haulvia.payout_transactions pt on pt.payout_id = dp.id and pt.status = 'SUCCEEDED'
  where dp.shipment_id = s.id
) paid on true
left join lateral (
  select rrr.id as record_id
  from haulvia.recovery_route_records rrr
  join haulvia.route_executions rre on rre.id = rrr.recovery_route_execution_id
  where rrr.shipment_id = s.id and rre.state in ('ACTIVE', 'HELD', 'RECOVERY_ACTIVE')
  order by rrr.authorized_at desc, rrr.id desc limit 1
) recovery on true
left join lateral (
  select scr.id as record_id
  from haulvia.storage_custody_records scr
  join haulvia.workflow_holds wh on wh.id = scr.workflow_hold_id and wh.status = 'ACTIVE'
  where scr.shipment_id = s.id
  order by scr.secured_at desc, scr.id desc limit 1
) storage on true
left join lateral (
  select count(*)::integer as verified_count
  from haulvia.custody_transfer_authorizations cta where cta.shipment_id = s.id
) transfer on true
left join lateral (
  select count(*)::integer as repost_count
  from haulvia.terminal_shipment_reposts tsr where tsr.source_shipment_id = s.id
) reposts on true
left join lateral (
  select count(*)::integer as resumable_count
  from haulvia.workflow_holds wh
  where wh.shipment_id = s.id and wh.status = 'ACTIVE' and wh.blocks_route_movement
    and (
      exists (
        select 1
        from haulvia.dispute_operational_controls doc
        join haulvia.disputes d on d.id = doc.dispute_id
        where doc.workflow_hold_id = wh.id and d.status in ('RESOLVED', 'CLOSED')
      ) or exists (
        select 1 from haulvia.route_exceptions rex
        where rex.workflow_hold_id = wh.id and rex.status in ('RESOLVED', 'CLOSED')
      )
    )
) resumable on true;

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
    'custodySummary', c.custody_summary,
    'activeStopEtaAt', c.active_stop_eta_at,
    'routePublicOutcomeLabel', c.route_public_outcome_label,
    'pendingDeliveryReviewCount', c.pending_delivery_review_count,
    'activeDisputedAmount', c.active_disputed_amount,
    'paidPayoutAmount', c.paid_payout_amount,
    'activeRecoveryRouteRecordId', c.active_recovery_route_record_id,
    'activeStorageCustodyRecordId', c.active_storage_custody_record_id,
    'verifiedCustodyTransferCount', c.verified_custody_transfer_count,
    'terminalRepostCount', c.terminal_repost_count,
    'resumableWorkflowHoldCount', c.resumable_workflow_hold_count
  ) || coalesce(p_affected, '{}'::jsonb)
  from haulvia.v_shipment_operating_context c
  where c.shipment_id = p_shipment_id;
$$;

-- ---------------------------------------------------------------------------
-- Trusted dispatcher and the fifteen new named Block E entry points
-- E04 intentionally reuses the existing command_expire_listing wrapper.
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.execute_block_e_command(
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
    when 'cancelDraft' then
      v_affected := haulvia_command.apply_e01_cancel_draft(v_shipment, p_request);
    when 'cancelMarketplaceShipment' then
      v_affected := haulvia_command.apply_e02_cancel_marketplace_shipment(v_shipment, p_request);
    when 'cancelAssignedBeforeCustody' then
      v_affected := haulvia_command.apply_e03_cancel_assigned_before_custody(v_shipment, p_request);
    when 'expireListing' then
      v_affected := haulvia_command.apply_a19_expire_listing(v_shipment, p_request);
    when 'retryFailedStopSameDriver' then
      v_affected := haulvia_command.apply_e05_retry_failed_stop_same_driver(v_shipment, p_request);
    when 'prepareFailedFirstPickupRepost' then
      v_affected := haulvia_command.apply_e06_prepare_failed_first_pickup_repost(v_shipment, p_request);
    when 'closeFailedFirstPickup' then
      v_affected := haulvia_command.apply_e07_close_failed_first_pickup(v_shipment, p_request);
    when 'continueRouteAfterFailedStop' then
      v_affected := haulvia_command.apply_e08_continue_route_after_failed_stop(v_shipment, p_request);
    when 'authorizeCustodyTransfer' then
      v_affected := haulvia_command.apply_e09_authorize_custody_transfer(v_shipment, p_request);
    when 'startRecoveryLeg' then
      v_affected := haulvia_command.apply_e10_start_recovery_leg(v_shipment, p_request);
    when 'secureCargoInStorage' then
      v_affected := haulvia_command.apply_e11_secure_cargo_in_storage(v_shipment, p_request);
    when 'verifyReturnHandoff' then
      v_affected := haulvia_command.apply_e12_verify_return_handoff(v_shipment, p_request);
    when 'openDispute' then
      v_affected := haulvia_command.apply_e13_open_dispute(v_shipment, p_request);
    when 'resolveDispute' then
      v_affected := haulvia_command.apply_e14_resolve_dispute(v_shipment, p_request);
    when 'resumeAfterResolution' then
      v_affected := haulvia_command.apply_e15_resume_after_resolution(v_shipment, p_request);
    when 'copyTerminalShipmentForRepost' then
      v_affected := haulvia_command.apply_e16_copy_terminal_shipment_for_repost(v_shipment, p_request);
    else
      perform haulvia_command.fail('INVALID_REQUEST', 'Command is not an approved Block E handler');
  end case;
  v_result := haulvia_command.operating_context(
    v_shipment.id, p_command_name, v_command_id, v_affected
  );
  return haulvia_command.complete_request(
    v_actor, p_command_name, v_idempotency_key, v_result
  );
end;
$$;

create or replace function haulvia_command.command_cancel_draft(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('cancelDraft', p_request); $$;

create or replace function haulvia_command.command_cancel_marketplace_shipment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('cancelMarketplaceShipment', p_request); $$;

create or replace function haulvia_command.command_cancel_assigned_before_custody(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('cancelAssignedBeforeCustody', p_request); $$;

create or replace function haulvia_command.command_retry_failed_stop_same_driver(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('retryFailedStopSameDriver', p_request); $$;

create or replace function haulvia_command.command_prepare_failed_first_pickup_repost(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('prepareFailedFirstPickupRepost', p_request); $$;

create or replace function haulvia_command.command_close_failed_first_pickup(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('closeFailedFirstPickup', p_request); $$;

create or replace function haulvia_command.command_continue_route_after_failed_stop(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('continueRouteAfterFailedStop', p_request); $$;

create or replace function haulvia_command.command_authorize_custody_transfer(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('authorizeCustodyTransfer', p_request); $$;

create or replace function haulvia_command.command_start_recovery_leg(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('startRecoveryLeg', p_request); $$;

create or replace function haulvia_command.command_secure_cargo_in_storage(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('secureCargoInStorage', p_request); $$;

create or replace function haulvia_command.command_verify_return_handoff(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('verifyReturnHandoff', p_request); $$;

create or replace function haulvia_command.command_open_dispute(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('openDispute', p_request); $$;

create or replace function haulvia_command.command_resolve_dispute(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('resolveDispute', p_request); $$;

create or replace function haulvia_command.command_resume_after_resolution(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('resumeAfterResolution', p_request); $$;

create or replace function haulvia_command.command_copy_terminal_shipment_for_repost(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_e_command('copyTerminalShipmentForRepost', p_request); $$;

revoke all on all functions in schema haulvia_command from public;

do $$
declare
  v_signature text;
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema haulvia_command to service_role;
    execute 'revoke execute on all functions in schema haulvia_command from service_role';
    for v_signature in
      select format(
        '%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
      )
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'haulvia_command' and left(p.proname, 8) = 'command_'
      order by p.proname, p.oid
    loop
      execute 'grant execute on function ' || v_signature || ' to service_role';
    end loop;
  end if;
end;
$$;

comment on table haulvia.stop_retry_records is
  'Immutable link from a failed stop attempt to a newly authorized same-driver retry attempt.';
comment on table haulvia.failed_first_pickup_resolutions is
  'Immutable explicit pre-custody resolution of a failed first pickup; repost and closure are never inferred.';
comment on table haulvia.custody_transfer_authorizations is
  'Verified provider-to-provider custody transfer with complete cargo balance, handoff evidence, and authority snapshots.';
comment on table haulvia.recovery_route_records is
  'Immutable recovery, return, redelivery, storage, or transfer segment linked to—but never overwriting—the original route and price.';
comment on table haulvia.storage_custody_records is
  'Storage facility, cargo condition, custody proof, access, charges, notices, and release conditions captured at secure handoff.';
comment on table haulvia.return_handoff_records is
  'Verified sender return handoff and exact custody-ledger reconciliation; terminal return requires zero remaining onboard balance.';
comment on table haulvia.dispute_operational_controls is
  'Explicit operational effect of a dispute; physical movement continues unless an unsafe, unlawful, or formal-hold basis is recorded.';
comment on table haulvia.dispute_resolution_records is
  'Immutable evidence decision, exact protected-fund allocation, next route action, and fresh sensitive authority for a dispute resolution.';
comment on table haulvia.workflow_resumption_records is
  'Explicit authorized resumption after a resolved dispute or route exception, preserving the prior hold and stop attempt history.';
comment on table haulvia.terminal_shipment_reposts is
  'Immutable linkage from a terminal source shipment and route to a distinct copied draft; the terminal source remains unchanged.';

create or replace function haulvia_command.apply_e14_resolve_dispute(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_reauth uuid := haulvia_command.required_uuid(p_request, 'reauthSessionId');
  v_dispute haulvia.disputes%rowtype;
  v_prior_hold haulvia.financial_holds%rowtype;
  v_retained_hold_id uuid;
  v_resolution_id uuid;
  v_decision text := upper(haulvia_command.required_text(p_request, 'decisionCode'));
  v_summary text := haulvia_command.required_text(p_request, 'resolutionSummary');
  v_allocation jsonb := coalesce(p_request -> 'financialAllocation', '{}'::jsonb);
  v_next_action jsonb := coalesce(p_request -> 'nextRouteAction', '{}'::jsonb);
  v_evidence jsonb := coalesce(p_request -> 'evidenceDecision', '{}'::jsonb);
  v_release numeric;
  v_retain numeric;
  v_open_count integer;
  v_prior_axis haulvia.dispute_axis_state;
  v_prior_payout_axis haulvia.driver_payout_state;
  v_new_payout_axis haulvia.driver_payout_state;
  v_payout haulvia.driver_payouts%rowtype;
begin
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'DISPUTE_RESOLVE', array['DISPUTE_RESOLUTION_WORKER']
  );
  if length(btrim(v_summary)) < 8
     or jsonb_typeof(v_allocation) <> 'object' or v_allocation = '{}'::jsonb
     or jsonb_typeof(v_next_action) <> 'object' or v_next_action = '{}'::jsonb
     or jsonb_typeof(v_evidence) <> 'object' or v_evidence = '{}'::jsonb then
    perform haulvia_command.fail(
      'RESOLUTION_INVALID',
      'Resolution summary, financial allocation, next route action, and evidence decision are required'
    );
  end if;
  if v_decision not in (
    'FULL_PAYOUT', 'FULL_REFUND', 'PARTIAL_SPLIT', 'EXTRA_PAYMENT',
    'REDELIVERY', 'RETURN', 'STORAGE', 'NO_MONETARY_CHANGE',
    'INSURER_REFERRAL', 'PAYMENT_PROVIDER_REFERRAL', 'AUTHORITY_REFERRAL'
  ) then
    perform haulvia_command.fail('RESOLUTION_INVALID', 'decisionCode is not an approved dispute outcome');
  end if;
  if nullif(btrim(v_allocation ->> 'basis'), '') is null then
    perform haulvia_command.fail('FINANCIAL_ALLOCATION_INVALID', 'Financial allocation basis is required');
  end if;
  v_release := coalesce(nullif(v_allocation ->> 'releaseHeldAmount', '')::numeric, 0);
  v_retain := coalesce(nullif(v_allocation ->> 'retainHeldAmount', '')::numeric, 0);
  if v_release < 0 or v_retain < 0
     or upper(coalesce(v_allocation ->> 'currency', p_shipment.currency)) <> p_shipment.currency then
    perform haulvia_command.fail(
      'FINANCIAL_ALLOCATION_INVALID', 'Held amounts must be nonnegative and use shipment currency'
    );
  end if;

  select * into v_dispute
  from haulvia.disputes d
  where d.id = haulvia_command.required_uuid(p_request, 'expectedDisputeId')
    and d.shipment_id = p_shipment.id
  for update;
  if not found then
    perform haulvia_command.fail('DISPUTE_NOT_FOUND', 'The expected dispute was not found');
  end if;
  if v_dispute.status not in ('OPEN', 'EVIDENCE_COLLECTION', 'UNDER_REVIEW') then
    perform haulvia_command.fail('DISPUTE_ALREADY_RESOLVED', 'The dispute is already terminal');
  end if;

  if v_dispute.financial_hold_id is not null then
    select * into v_prior_hold
    from haulvia.financial_holds fh
    where fh.id = v_dispute.financial_hold_id and fh.status = 'ACTIVE'
    for update;
    if not found then
      perform haulvia_command.fail(
        'FINANCIAL_ALLOCATION_INVALID', 'The dispute protected hold is no longer active'
      );
    end if;
    if v_release + v_retain <> v_prior_hold.amount then
      perform haulvia_command.fail(
        'FINANCIAL_ALLOCATION_INVALID',
        'Released plus retained value must exactly allocate the protected amount'
      );
    end if;
    update haulvia.financial_holds
    set status = 'RELEASED', released_at = clock_timestamp(),
        released_by_profile_id = v_actor,
        release_reason = 'Superseded by evidence-based dispute resolution'
    where id = v_prior_hold.id;
    if v_retain > 0 then
      insert into haulvia.financial_holds (
        shipment_id, payment_intent_id, payout_id, hold_code, source_type,
        source_id, amount, currency, reason
      ) values (
        p_shipment.id, v_prior_hold.payment_intent_id, v_prior_hold.payout_id,
        'RESOLUTION_RETAINED_AMOUNT', 'DISPUTE_RESOLUTION', v_dispute.id,
        v_retain, p_shipment.currency,
        'Amount retained by authorized evidence-based dispute resolution'
      ) returning id into v_retained_hold_id;
    end if;
  elsif v_release <> 0 or v_retain <> 0 then
    perform haulvia_command.fail(
      'FINANCIAL_ALLOCATION_INVALID', 'A dispute without a protected hold must allocate zero held funds'
    );
  end if;

  update haulvia.disputes
  set status = 'RESOLVED', resolution_code = v_decision,
      resolution_summary = v_summary, resolved_by_profile_id = v_actor,
      resolved_at = clock_timestamp(), financial_hold_id = v_retained_hold_id
  where id = v_dispute.id;
  insert into haulvia.dispute_events (
    dispute_id, prior_status, current_status, event_type, actor_kind,
    actor_profile_id, note, evidence_manifest, financial_allocation,
    authority_code, reauth_session_id, occurred_at, idempotency_key, metadata
  ) values (
    v_dispute.id, v_dispute.status, 'RESOLVED', 'DISPUTE_RESOLVED', 'PROFILE',
    v_actor, v_summary, jsonb_build_array(v_evidence),
    v_allocation || jsonb_build_object(
      'priorFinancialHoldId', v_prior_hold.id,
      'retainedFinancialHoldId', v_retained_hold_id
    ), 'DISPUTE_RESOLVE', v_reauth, clock_timestamp(),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object('decisionCode', v_decision, 'nextRouteAction', v_next_action)
  );
  insert into haulvia.dispute_resolution_records (
    shipment_id, dispute_id, prior_financial_hold_id, retained_financial_hold_id,
    decision_code, financial_allocation, next_route_action, evidence_decision,
    resolution_summary, resolved_by_profile_id, reauth_session_id, idempotency_key
  ) values (
    p_shipment.id, v_dispute.id, v_prior_hold.id, v_retained_hold_id,
    v_decision, v_allocation, v_next_action, v_evidence, v_summary,
    v_actor, v_reauth, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_resolution_id;

  select state into v_prior_axis
  from haulvia.shipment_dispute_axes where shipment_id = p_shipment.id for update;
  select count(*) into v_open_count
  from haulvia.disputes d
  where d.shipment_id = p_shipment.id and d.status not in ('RESOLVED', 'CLOSED');
  update haulvia.shipment_dispute_axes
  set state = case when v_open_count = 0
        then 'NONE'::haulvia.dispute_axis_state
        else 'OPEN'::haulvia.dispute_axis_state end,
      open_dispute_count = v_open_count, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DISPUTE', v_prior_axis::text,
    case when v_open_count = 0 then 'NONE' else 'OPEN' end,
    'resolveDispute', p_request, v_dispute.id,
    jsonb_build_object('disputeResolutionRecordId', v_resolution_id, 'openDisputeCount', v_open_count)
  );

  select * into v_payout
  from haulvia.driver_payouts dp
  where dp.shipment_id = p_shipment.id
  order by dp.created_at desc, dp.id desc
  limit 1 for update;
  if found and v_payout.state not in ('PROCESSING', 'PAID', 'CANCELLED') then
    select state into v_prior_payout_axis
    from haulvia.shipment_driver_payout_axes
    where shipment_id = p_shipment.id for update;
    v_new_payout_axis := case when exists (
      select 1 from haulvia.financial_holds fh
      where fh.shipment_id = p_shipment.id and fh.status = 'ACTIVE'
    ) then 'HELD'::haulvia.driver_payout_state else 'READY'::haulvia.driver_payout_state end;
    update haulvia.driver_payouts
    set state = v_new_payout_axis, state_changed_at = clock_timestamp()
    where id = v_payout.id;
    update haulvia.shipment_driver_payout_axes
    set state = v_new_payout_axis, state_changed_at = clock_timestamp()
    where shipment_id = p_shipment.id;
    if v_prior_payout_axis is distinct from v_new_payout_axis then
      perform haulvia_command.append_axis_event(
        p_shipment.id, 'DRIVER_PAYOUT', v_prior_payout_axis::text,
        v_new_payout_axis::text, 'resolveDispute', p_request, v_payout.id,
        jsonb_build_object('retainedFinancialHoldId', v_retained_hold_id)
      );
    end if;
  end if;
  perform haulvia_command.append_audit(
    p_shipment, 'resolveDispute', p_request,
    jsonb_build_object('disputeStatus', v_dispute.status, 'shipmentState', p_shipment.shipment_state),
    jsonb_build_object('disputeStatus', 'RESOLVED', 'shipmentState', p_shipment.shipment_state),
    jsonb_build_object(
      'disputeId', v_dispute.id, 'disputeResolutionRecordId', v_resolution_id,
      'priorFinancialHoldId', v_prior_hold.id,
      'retainedFinancialHoldId', v_retained_hold_id,
      'physicalMovementChanged', false
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'DISPUTE_RESOLVED',
    p_request, 'dispute-resolution-' || v_dispute.id::text,
    jsonb_build_object(
      'disputeId', v_dispute.id, 'decisionCode', v_decision,
      'nextRouteAction', v_next_action
    )
  );
  return jsonb_build_object(
    'disputeId', v_dispute.id, 'disputeStatus', 'RESOLVED',
    'disputeResolutionRecordId', v_resolution_id,
    'priorFinancialHoldId', v_prior_hold.id,
    'retainedFinancialHoldId', v_retained_hold_id,
    'releasedHeldAmount', v_release, 'retainedHeldAmount', v_retain,
    'openDisputeCount', v_open_count, 'nextRouteAction', v_next_action,
    'shipmentState', p_shipment.shipment_state,
    'physicalMovementChanged', false
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail('RESOLUTION_INVALID', 'Dispute resolution contains an invalid value');
  return null;
end;
$$;

create or replace function haulvia_command.apply_e15_resume_after_resolution(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_prior_attempt haulvia.stop_attempts%rowtype;
  v_new_attempt_id uuid;
  v_hold haulvia.workflow_holds%rowtype;
  v_route_id uuid;
  v_leg_id uuid := haulvia_command.required_uuid(p_request, 'expectedActiveRouteLegId');
  v_source_type text := upper(haulvia_command.required_text(p_request, 'sourceType'));
  v_source_id uuid := haulvia_command.required_uuid(p_request, 'sourceId');
  v_resume_stop_state haulvia.stop_state := upper(
    haulvia_command.required_text(p_request, 'resumeStopState')
  )::haulvia.stop_state;
  v_resume_route_state haulvia.route_execution_state;
  v_next_action text := upper(haulvia_command.required_text(p_request, 'nextAction'));
  v_custody jsonb := coalesce(p_request -> 'custodyBalanceSnapshot', '{}'::jsonb);
  v_authority jsonb := coalesce(p_request -> 'authorizationSnapshot', '{}'::jsonb);
  v_record_id uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'Only an in-progress shipment can resume physical movement');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'SHIPMENT_STATE_OVERRIDE', array['ROUTE_OPERATIONS_WORKER']
  );
  if v_source_type not in ('DISPUTE', 'ROUTE_EXCEPTION')
     or v_resume_stop_state not in ('EN_ROUTE', 'ARRIVED')
     or jsonb_typeof(v_custody) <> 'object' or v_custody = '{}'::jsonb
     or jsonb_typeof(v_authority) <> 'object' or v_authority = '{}'::jsonb then
    perform haulvia_command.fail(
      'RESUMPTION_INVALID',
      'Approved source, stop state, custody snapshot, and authorization snapshot are required'
    );
  end if;
  perform haulvia_command.assert_custody_snapshot(p_shipment.id, v_custody);
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.route_version_id <> v_route_id or v_execution.state <> 'HELD' then
    perform haulvia_command.fail('INVALID_STATE', 'The expected current route execution must be HELD');
  end if;
  if v_execution.active_route_leg_id is distinct from v_leg_id or not exists (
    select 1 from haulvia.route_legs rl
    where rl.id = v_leg_id and rl.route_version_id = v_route_id
  ) then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'The active route leg changed before resumption');
  end if;
  select * into v_stop
  from haulvia.stop_executions se
  where se.id = haulvia_command.required_uuid(p_request, 'expectedNextStopExecutionId')
    and se.route_execution_id = v_execution.id
  for update;
  if not found or v_execution.active_stop_execution_id is distinct from v_stop.id
     or v_stop.state not in ('PENDING', 'EXCEPTION_REVIEW') then
    perform haulvia_command.fail(
      'STOP_NOT_CURRENT', 'The next stop must be the held execution current pending or reviewed stop'
    );
  end if;
  if v_stop.state = 'PENDING' and v_resume_stop_state <> 'EN_ROUTE' then
    perform haulvia_command.fail('RESUMPTION_INVALID', 'A pending stop resumes EN_ROUTE');
  end if;
  if v_stop.state = 'EXCEPTION_REVIEW' and v_resume_stop_state <> 'ARRIVED' then
    perform haulvia_command.fail('RESUMPTION_INVALID', 'A reviewed stop resumes at ARRIVED');
  end if;

  select * into v_hold
  from haulvia.workflow_holds wh
  where wh.id = haulvia_command.required_uuid(p_request, 'expectedWorkflowHoldId')
    and wh.shipment_id = p_shipment.id and wh.route_execution_id = v_execution.id
    and wh.status = 'ACTIVE' and wh.blocks_route_movement
  for update;
  if not found then
    perform haulvia_command.fail('HOLD_NOT_ACTIVE', 'The expected route-movement hold is not active');
  end if;
  if v_source_type = 'DISPUTE' then
    if not exists (
      select 1
      from haulvia.disputes d
      join haulvia.dispute_operational_controls doc on doc.dispute_id = d.id
      where d.id = v_source_id and d.shipment_id = p_shipment.id
        and d.status in ('RESOLVED', 'CLOSED') and doc.workflow_hold_id = v_hold.id
    ) then
      perform haulvia_command.fail(
        'SOURCE_NOT_RESOLVED', 'The dispute linked to this movement hold is not resolved'
      );
    end if;
  elsif not exists (
    select 1 from haulvia.route_exceptions rex
    where rex.id = v_source_id and rex.shipment_id = p_shipment.id
      and rex.status in ('RESOLVED', 'CLOSED') and rex.workflow_hold_id = v_hold.id
  ) then
    perform haulvia_command.fail(
      'SOURCE_NOT_RESOLVED', 'The route exception linked to this movement hold is not resolved'
    );
  end if;

  if v_stop.current_attempt_no > 0 then
    select * into v_prior_attempt
    from haulvia.stop_attempts sa
    where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
    for update;
    if found and v_prior_attempt.ended_at is null then
      update haulvia.stop_attempts
      set ended_at = clock_timestamp(), updated_at = clock_timestamp()
      where id = v_prior_attempt.id;
    end if;
  end if;
  insert into haulvia.stop_attempts (stop_execution_id, attempt_no, state, arrived_at)
  values (
    v_stop.id, v_stop.current_attempt_no + 1, v_resume_stop_state,
    case when v_resume_stop_state = 'ARRIVED' then clock_timestamp() end
  ) returning id into v_new_attempt_id;
  update haulvia.stop_executions
  set state = v_resume_stop_state, current_attempt_no = current_attempt_no + 1,
      state_changed_at = clock_timestamp()
  where id = v_stop.id;
  v_resume_route_state := case
    when v_execution.execution_kind in ('RECOVERY', 'RETURN', 'REDELIVERY')
      then 'RECOVERY_ACTIVE'::haulvia.route_execution_state
    else 'ACTIVE'::haulvia.route_execution_state
  end;
  update haulvia.route_executions
  set state = v_resume_route_state, next_action = v_next_action,
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.workflow_holds
  set status = 'RELEASED', released_by_profile_id = v_actor,
      released_at = clock_timestamp(),
      release_reason = haulvia_command.required_text(p_request, 'reason')
  where id = v_hold.id;

  insert into haulvia.workflow_resumption_records (
    shipment_id, route_execution_id, route_version_id, source_type, source_id,
    workflow_hold_id, next_stop_execution_id, prior_route_state,
    resumed_route_state, prior_stop_state, resumed_stop_state,
    custody_balance_snapshot, next_action, authorization_snapshot,
    authorized_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_route_id, v_source_type, v_source_id,
    v_hold.id, v_stop.id, v_execution.state, v_resume_route_state,
    v_stop.state, v_resume_stop_state, v_custody, v_next_action,
    v_authority || jsonb_build_object(
      'reauthSessionId', haulvia_command.optional_uuid(p_request, 'reauthSessionId'),
      'workerAuthority', p_request ->> 'workerAuthority'
    ), v_actor, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_record_id;
  perform haulvia_command.append_stop_event(
    v_new_attempt_id, v_stop.id, v_stop.state, v_resume_stop_state,
    'resumeAfterResolution', p_request,
    jsonb_build_object(
      'workflowResumptionRecordId', v_record_id,
      'sourceType', v_source_type, 'sourceId', v_source_id,
      'priorStopAttemptId', v_prior_attempt.id
    )
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'WORKFLOW_HOLD', 'ACTIVE', 'RELEASED',
    'resumeAfterResolution', p_request, v_hold.id,
    jsonb_build_object('workflowResumptionRecordId', v_record_id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'ROUTE_EXECUTION', 'HELD', v_resume_route_state::text,
    'resumeAfterResolution', p_request, v_execution.id,
    jsonb_build_object('workflowResumptionRecordId', v_record_id, 'nextAction', v_next_action)
  );
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  perform haulvia_command.append_audit(
    p_shipment, 'resumeAfterResolution', p_request,
    jsonb_build_object('routeExecutionState', 'HELD', 'stopState', v_stop.state),
    jsonb_build_object('routeExecutionState', v_resume_route_state, 'stopState', v_resume_stop_state),
    jsonb_build_object(
      'workflowResumptionRecordId', v_record_id, 'workflowHoldId', v_hold.id,
      'newStopAttemptId', v_new_attempt_id, 'custodyBalanceSnapshot', v_custody
    )
  );
  return jsonb_build_object(
    'workflowResumptionRecordId', v_record_id,
    'routeExecutionId', v_execution.id,
    'routeExecutionState', v_resume_route_state,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id, 'stopAttemptId', v_new_attempt_id,
    'stopState', v_resume_stop_state, 'workflowHoldId', v_hold.id,
    'workflowHoldState', 'RELEASED', 'nextAction', v_next_action
  );
exception when invalid_text_representation then
  perform haulvia_command.fail('RESUMPTION_INVALID', 'Resumption request contains an invalid value');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- E16: terminal shipments remain immutable; reposting creates a linked draft
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_e16_copy_terminal_shipment_for_repost(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
  v_source_route_id uuid;
  v_source_route haulvia.route_versions%rowtype;
  v_new_shipment_id uuid;
  v_new_route_id uuid;
  v_repost_id uuid;
  v_stop_map jsonb := '{}'::jsonb;
  v_cargo_map jsonb := '{}'::jsonb;
  v_new_id uuid;
  v_stop_count integer := 0;
  v_leg_count integer := 0;
  v_cargo_count integer := 0;
  v_allocation_count integer := 0;
  v_eligibility jsonb := coalesce(p_request -> 'eligibilitySnapshot', '{}'::jsonb);
  v_is_customer boolean := false;
  r record;
begin
  if p_shipment.shipment_state not in ('CANCELLED', 'EXPIRED', 'COMPLETED', 'RETURNED_TO_SENDER') then
    perform haulvia_command.fail(
      'INVALID_STATE', 'Only a terminal shipment may be copied into a linked repost draft'
    );
  end if;
  if jsonb_typeof(v_eligibility) <> 'object' or v_eligibility = '{}'::jsonb
     or nullif(btrim(p_request ->> 'reason'), '') is null then
    perform haulvia_command.fail(
      'REPOST_NOT_ELIGIBLE', 'A reason and non-empty eligibility snapshot are required'
    );
  end if;
  v_is_customer := v_actor is not null and (
    p_shipment.customer_profile_id = v_actor or (
      p_shipment.customer_organization_id is not null
      and p_shipment.customer_organization_id = v_org
      and exists (
        select 1 from haulvia.organization_memberships om
        where om.organization_id = v_org and om.profile_id = v_actor
          and om.status = 'ACTIVE'
          and (om.ends_at is null or om.ends_at > clock_timestamp())
      )
    )
  );
  if not v_is_customer then
    perform haulvia_command.assert_sensitive_command_authority(
      p_request, 'SHIPMENT_STATE_OVERRIDE', array['TERMINAL_REPOST_WORKER']
    );
  end if;
  v_source_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request,
    array['DRAFT', 'ACTIVE', 'SUPERSEDED', 'FROZEN']::haulvia.route_version_status[]
  );
  select * into v_source_route
  from haulvia.route_versions rv where rv.id = v_source_route_id;
  perform haulvia_command.validate_route_plan(v_source_route_id);

  insert into haulvia.shipments (
    customer_organization_id, customer_profile_id, source_shipment_id,
    shipment_state, pickup_timing, service_level, currency
  ) values (
    p_shipment.customer_organization_id, p_shipment.customer_profile_id, p_shipment.id,
    'DRAFT', p_shipment.pickup_timing, p_shipment.service_level, p_shipment.currency
  ) returning id into v_new_shipment_id;
  insert into haulvia.route_versions (
    shipment_id, version_no, status, change_reason,
    planned_distance_km, planned_duration_seconds, created_by_profile_id
  ) values (
    v_new_shipment_id, 1, 'DRAFT',
    'Copied from terminal shipment ' || p_shipment.shipment_reference || ': '
      || haulvia_command.required_text(p_request, 'reason'),
    v_source_route.planned_distance_km, v_source_route.planned_duration_seconds, v_actor
  ) returning id into v_new_route_id;

  for r in
    select * from haulvia.route_stops rs
    where rs.route_version_id = v_source_route_id order by rs.sequence_no
  loop
    v_new_id := gen_random_uuid();
    v_stop_map := v_stop_map || jsonb_build_object(r.id::text, v_new_id::text);
    insert into haulvia.route_stops (
      id, route_version_id, stable_stop_key, sequence_no, stop_type,
      address_label, address_line1, address_line2, city, region_code,
      postal_code, country_code, latitude, longitude, geofence_radius_m,
      contact_name, contact_phone, contact_email, service_window_start,
      service_window_end, planned_service_seconds, instructions, verification_profile
    ) values (
      v_new_id, v_new_route_id, r.stable_stop_key, r.sequence_no, r.stop_type,
      r.address_label, r.address_line1, r.address_line2, r.city, r.region_code,
      r.postal_code, r.country_code, r.latitude, r.longitude, r.geofence_radius_m,
      r.contact_name, r.contact_phone, r.contact_email, r.service_window_start,
      r.service_window_end, r.planned_service_seconds, r.instructions, r.verification_profile
    );
    v_stop_count := v_stop_count + 1;
  end loop;

  for r in
    select * from haulvia.cargo_items ci
    where ci.route_version_id = v_source_route_id order by ci.cargo_line_no
  loop
    v_new_id := gen_random_uuid();
    v_cargo_map := v_cargo_map || jsonb_build_object(r.id::text, v_new_id::text);
    insert into haulvia.cargo_items (
      id, route_version_id, stable_cargo_key, cargo_line_no, description,
      quantity, quantity_unit, total_weight_kg, total_volume_m3,
      declared_value, currency, handling_requirements, risk_attributes
    ) values (
      v_new_id, v_new_route_id, r.stable_cargo_key, r.cargo_line_no, r.description,
      r.quantity, r.quantity_unit, r.total_weight_kg, r.total_volume_m3,
      r.declared_value, r.currency, r.handling_requirements, r.risk_attributes
    );
    v_cargo_count := v_cargo_count + 1;
  end loop;

  for r in
    select * from haulvia.route_legs rl
    where rl.route_version_id = v_source_route_id order by rl.sequence_no
  loop
    insert into haulvia.route_legs (
      route_version_id, sequence_no, from_stop_id, to_stop_id,
      planned_distance_km, planned_duration_seconds, route_provider_payload
    ) values (
      v_new_route_id, r.sequence_no,
      (v_stop_map ->> r.from_stop_id::text)::uuid,
      (v_stop_map ->> r.to_stop_id::text)::uuid,
      r.planned_distance_km, r.planned_duration_seconds, r.route_provider_payload
    );
    v_leg_count := v_leg_count + 1;
  end loop;

  for r in
    select * from haulvia.cargo_allocations ca
    where ca.route_version_id = v_source_route_id order by ca.created_at, ca.id
  loop
    insert into haulvia.cargo_allocations (
      route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id,
      quantity, quantity_unit, allocation_note
    ) values (
      v_new_route_id,
      (v_cargo_map ->> r.cargo_item_id::text)::uuid,
      (v_stop_map ->> r.pickup_stop_id::text)::uuid,
      (v_stop_map ->> r.delivery_stop_id::text)::uuid,
      r.quantity, r.quantity_unit, r.allocation_note
    );
    v_allocation_count := v_allocation_count + 1;
  end loop;
  perform haulvia_command.validate_route_plan(v_new_route_id);

  insert into haulvia.terminal_shipment_reposts (
    source_shipment_id, new_shipment_id, source_route_version_id,
    new_route_version_id, source_terminal_state, copied_stop_count,
    copied_leg_count, copied_cargo_count, copied_allocation_count,
    eligibility_snapshot, copied_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_new_shipment_id, v_source_route_id, v_new_route_id,
    p_shipment.shipment_state, v_stop_count, v_leg_count, v_cargo_count,
    v_allocation_count, v_eligibility, v_actor,
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_repost_id;
  perform haulvia_command.append_shipment_event(
    v_new_shipment_id, 'DRAFT', 'DRAFT', 'copyTerminalShipmentForRepost',
    p_request || jsonb_build_object(
      'idempotencyKey', haulvia_command.required_text(p_request, 'idempotencyKey') || ':new'
    ), v_new_route_id,
    jsonb_build_object(
      'terminalShipmentRepostId', v_repost_id,
      'sourceShipmentId', p_shipment.id, 'sourceRouteVersionId', v_source_route_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'copyTerminalShipmentForRepost', p_request,
    jsonb_build_object('shipmentState', p_shipment.shipment_state, 'sourceUnchanged', true),
    jsonb_build_object('shipmentState', p_shipment.shipment_state, 'sourceUnchanged', true),
    jsonb_build_object(
      'terminalShipmentRepostId', v_repost_id,
      'newShipmentId', v_new_shipment_id, 'newRouteVersionId', v_new_route_id,
      'copiedStopCount', v_stop_count, 'copiedLegCount', v_leg_count,
      'copiedCargoCount', v_cargo_count, 'copiedAllocationCount', v_allocation_count
    )
  );
  perform haulvia_command.queue_notification(
    v_new_shipment_id, p_shipment.customer_profile_id, 'TERMINAL_SHIPMENT_COPIED_TO_DRAFT',
    p_request, 'terminal-repost-' || v_repost_id::text,
    jsonb_build_object(
      'sourceShipmentId', p_shipment.id, 'newShipmentId', v_new_shipment_id,
      'newRouteVersionId', v_new_route_id
    )
  );
  return jsonb_build_object(
    'terminalShipmentRepostId', v_repost_id,
    'sourceShipmentId', p_shipment.id, 'sourceShipmentState', p_shipment.shipment_state,
    'sourceRouteVersionId', v_source_route_id, 'sourceUnchanged', true,
    'newShipmentId', v_new_shipment_id, 'newShipmentState', 'DRAFT',
    'newRouteVersionId', v_new_route_id, 'newRouteVersionStatus', 'DRAFT',
    'copiedStopCount', v_stop_count, 'copiedLegCount', v_leg_count,
    'copiedCargoCount', v_cargo_count, 'copiedAllocationCount', v_allocation_count
  );
exception when invalid_text_representation then
  perform haulvia_command.fail('REPOST_NOT_ELIGIBLE', 'Terminal repost request contains an invalid value');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block E shared validation helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.assert_nonterminal_shipment(
  p_shipment haulvia.shipments,
  p_command_name text
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if p_shipment.shipment_state in ('COMPLETED', 'CANCELLED', 'EXPIRED', 'RETURNED_TO_SENDER') then
    perform haulvia_command.fail(
      'TERMINAL_SHIPMENT_IMMUTABLE',
      format('%s cannot reopen or edit a terminal shipment; create a linked draft instead', p_command_name),
      jsonb_build_object('shipmentState', p_shipment.shipment_state)
    );
  end if;
end;
$$;

create or replace function haulvia_command.assert_positive_custody(p_shipment_id uuid)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_summary jsonb := haulvia_command.current_custody_summary(p_shipment_id);
begin
  if not coalesce((v_summary ->> 'hasVerifiedCustody')::boolean, false)
     or not exists (
       select 1 from haulvia.v_cargo_custody_balance cb
       where cb.shipment_id = p_shipment_id and cb.onboard_quantity > 0
     ) then
    perform haulvia_command.fail(
      'CUSTODY_REQUIRED',
      'This recovery action requires verified cargo currently in custody'
    );
  end if;
  return v_summary;
end;
$$;

create or replace function haulvia_command.assert_replacement_provider_eligible(
  p_provider_id uuid,
  p_driver_id uuid,
  p_vehicle_id uuid
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if not exists (
    select 1
    from haulvia.service_providers sp
    join haulvia.provider_drivers pd
      on pd.provider_id = sp.id and pd.driver_id = p_driver_id
    join haulvia.drivers d on d.id = pd.driver_id
    join haulvia.vehicles v on v.id = p_vehicle_id and v.provider_id = sp.id
    where sp.id = p_provider_id and sp.status = 'ACTIVE'
      and pd.status = 'ACTIVE' and (pd.ends_at is null or pd.ends_at > clock_timestamp())
      and d.status = 'ACTIVE' and v.status = 'ACTIVE'
  ) then
    perform haulvia_command.fail(
      'REPLACEMENT_NOT_ELIGIBLE',
      'Replacement provider, driver, or vehicle is not active and eligible'
    );
  end if;
  if exists (
    select 1
    from haulvia.compliance_subjects cs
    join haulvia.v_compliance_blockers cb on cb.subject_id = cs.id
    where cs.provider_id = p_provider_id
       or cs.driver_id = p_driver_id
       or cs.vehicle_id = p_vehicle_id
  ) then
    perform haulvia_command.fail(
      'COMPLIANCE_BLOCKED',
      'Replacement provider, driver, or vehicle has an unresolved compliance blocker'
    );
  end if;
end;
$$;

create or replace function haulvia_command.assert_transfer_manifest(
  p_shipment_id uuid,
  p_route_version_id uuid,
  p_manifest jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_expected_count integer;
  v_requested_count integer;
begin
  if jsonb_typeof(p_manifest) <> 'array' or jsonb_array_length(p_manifest) = 0 then
    perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'transferItems must be a non-empty array');
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_manifest) item
    left join haulvia.cargo_allocations ca
      on ca.id = (item ->> 'cargoAllocationId')::uuid
     and ca.route_version_id = p_route_version_id
    where ca.id is null
       or (item ->> 'quantity')::numeric <= 0
       or ca.quantity_unit <> item ->> 'quantityUnit'
  ) then
    perform haulvia_command.fail(
      'CARGO_REFERENCE_INVALID',
      'Transfer cargo must reference current-route allocations with positive matching units'
    );
  end if;
  select count(*) into v_requested_count from jsonb_array_elements(p_manifest);
  if v_requested_count <> (
    select count(distinct item ->> 'cargoAllocationId')
    from jsonb_array_elements(p_manifest) item
  ) then
    perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Transfer allocations must appear exactly once');
  end if;

  select count(*) into v_expected_count
  from haulvia.v_cargo_custody_balance cb
  where cb.shipment_id = p_shipment_id and cb.onboard_quantity > 0;
  if v_requested_count <> v_expected_count or exists (
    select 1
    from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id = p_shipment_id and cb.onboard_quantity > 0
      and not exists (
        select 1
        from jsonb_array_elements(p_manifest) item
        join haulvia.cargo_allocations ca
          on ca.id = (item ->> 'cargoAllocationId')::uuid
         and ca.route_version_id = p_route_version_id
        join haulvia.cargo_items ci
          on ci.id = ca.cargo_item_id and ci.route_version_id = ca.route_version_id
        where ci.stable_cargo_key = cb.stable_cargo_key
          and item ->> 'quantityUnit' = cb.quantity_unit
          and (item ->> 'quantity')::numeric = cb.onboard_quantity
      )
  ) then
    perform haulvia_command.fail(
      'CUSTODY_SNAPSHOT_STALE',
      'Transfer items must exactly match every current onboard cargo balance'
    );
  end if;
  return haulvia_command.current_custody_summary(p_shipment_id);
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'transferItems contains an invalid UUID or quantity');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- E01-E04: terminal cancellation boundaries and listing expiry
-- E04 deliberately reuses the existing Block A command_expire_listing wrapper;
-- its deadline, reservation, late-payment, and idempotency rules are unchanged.
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_e01_cancel_draft(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_market haulvia.marketplace_state;
  v_payment haulvia.customer_payment_state;
  v_route_id uuid;
  v_snapshot_id uuid;
  v_reason text := haulvia_command.required_text(p_request, 'reason');
begin
  if p_shipment.shipment_state <> 'DRAFT' then
    perform haulvia_command.fail('INVALID_STATE', 'cancelDraft requires DRAFT');
  end if;
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  if exists (
    select 1 from haulvia.assignments a
    where a.shipment_id = p_shipment.id and a.status in ('ACTIVE', 'COMPLETED')
  ) then
    perform haulvia_command.fail('ASSIGNMENT_CONFLICT', 'A draft with assignment history cannot be cancelled as a draft');
  end if;
  select rv.id into v_route_id
  from haulvia.route_versions rv
  where rv.shipment_id = p_shipment.id and rv.status = 'DRAFT'
  order by rv.version_no desc limit 1;
  select state into v_market from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;
  select state into v_payment from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id for update;

  insert into haulvia.shipment_cancellation_snapshots (
    shipment_id, route_version_id, policy_version_id, cancelled_by_profile_id,
    reason, prior_shipment_state, prior_marketplace_state, prior_payment_state,
    financial_action, snapshot, idempotency_key
  ) values (
    p_shipment.id, v_route_id, haulvia_command.optional_uuid(p_request, 'policyVersionId'),
    v_actor, v_reason, 'DRAFT', v_market, v_payment, 'NONE',
    coalesce(p_request -> 'cancellationSnapshot', '{}'::jsonb),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_snapshot_id;

  update haulvia.shipment_marketplace_axes
  set state = 'CLOSED', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_customer_payment_axes
  set state = 'RELEASED', secured_amount = 0, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'CANCELLED' where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'MARKETPLACE', v_market::text, 'CLOSED',
    'cancelDraft', p_request, null,
    jsonb_build_object('cancellationSnapshotId', v_snapshot_id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment::text, 'RELEASED',
    'cancelDraft', p_request, null,
    jsonb_build_object('financialAction', 'NONE')
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id, 'DRAFT', 'CANCELLED', 'cancelDraft', p_request, v_route_id,
    jsonb_build_object('cancellationSnapshotId', v_snapshot_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'cancelDraft', p_request, to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('cancellationSnapshotId', v_snapshot_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'DRAFT_CANCELLED',
    p_request, 'draft-cancelled', jsonb_build_object('reason', v_reason)
  );
  return jsonb_build_object(
    'shipmentState', 'CANCELLED', 'cancellationSnapshotId', v_snapshot_id,
    'routeVersionId', v_route_id
  );
end;
$$;

create or replace function haulvia_command.apply_e02_cancel_marketplace_shipment(
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
  v_market haulvia.marketplace_state;
  v_payment haulvia.customer_payment_state;
  v_reservation uuid;
  v_intent uuid;
  v_snapshot_id uuid;
begin
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail(
      'INVALID_STATE', 'cancelMarketplaceShipment requires POSTED or NEGOTIATING'
    );
  end if;
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  if exists (
    select 1 from haulvia.assignments a
    where a.shipment_id = p_shipment.id and a.status in ('ACTIVE', 'COMPLETED')
  ) then
    perform haulvia_command.fail(
      'ASSIGNMENT_CONFLICT', 'A committed or completed assignment prevents marketplace cancellation'
    );
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  select state into v_market from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;
  select state into v_payment from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id for update;
  select id into v_reservation from haulvia.offer_reservations
  where shipment_id = p_shipment.id and status = 'ACTIVE' for update;
  select id into v_intent from haulvia.payment_intents
  where shipment_id = p_shipment.id and status in ('CREATED', 'AUTHORIZING')
  order by created_at desc limit 1 for update;

  update haulvia.offer_threads
  set status = 'CLOSED', closed_at = clock_timestamp()
  where shipment_id = p_shipment.id
    and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED', 'RESERVED');
  update haulvia.offer_reservations
  set status = 'RELEASED', released_at = clock_timestamp(),
      release_reason = 'CUSTOMER_CANCELLED_MARKETPLACE'
  where id = v_reservation;
  update haulvia.payment_intents set status = 'VOIDED' where id = v_intent;
  update haulvia.shipment_marketplace_axes
  set state = 'CLOSED', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_customer_payment_axes
  set state = 'RELEASED', secured_amount = 0, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;

  insert into haulvia.shipment_cancellation_snapshots (
    shipment_id, route_version_id, policy_version_id, cancelled_by_profile_id,
    reason, prior_shipment_state, prior_marketplace_state, prior_payment_state,
    financial_action, snapshot, idempotency_key
  ) values (
    p_shipment.id, v_route_id, haulvia_command.optional_uuid(p_request, 'policyVersionId'),
    v_actor, haulvia_command.required_text(p_request, 'reason'),
    p_shipment.shipment_state, v_market, v_payment,
    case when v_intent is null then 'NONE' else 'VOID_QUEUED' end,
    coalesce(p_request -> 'cancellationSnapshot', '{}'::jsonb),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_snapshot_id;
  update haulvia.shipments set shipment_state = 'CANCELLED' where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'MARKETPLACE', v_market::text, 'CLOSED',
    'cancelMarketplaceShipment', p_request, v_reservation
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment::text, 'RELEASED',
    'cancelMarketplaceShipment', p_request, v_intent
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id, p_shipment.shipment_state, 'CANCELLED',
    'cancelMarketplaceShipment', p_request, v_route_id,
    jsonb_build_object('cancellationSnapshotId', v_snapshot_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'cancelMarketplaceShipment', p_request, to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object(
      'cancellationSnapshotId', v_snapshot_id,
      'releasedReservationId', v_reservation,
      'paymentIntentId', v_intent
    )
  );
  if v_intent is not null then
    perform haulvia_command.queue_job(
      p_shipment.id, 'VOID_PAYMENT_AUTHORIZATION', clock_timestamp(),
      p_request, 'marketplace-cancel-void', jsonb_build_object('paymentIntentId', v_intent)
    );
  end if;
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'MARKETPLACE_SHIPMENT_CANCELLED',
    p_request, 'marketplace-cancelled'
  );
  return jsonb_build_object(
    'shipmentState', 'CANCELLED', 'routeVersionId', v_route_id,
    'cancellationSnapshotId', v_snapshot_id,
    'releasedReservationId', v_reservation, 'paymentIntentId', v_intent
  );
end;
$$;

create or replace function haulvia_command.apply_e03_cancel_assigned_before_custody(
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
      'INVALID_STATE', 'cancelAssignedBeforeCustody requires DRIVER_ASSIGNED or ROUTE_IN_PROGRESS'
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
    perform haulvia_command.fail(
      'INVALID_REQUEST', 'DRIVER_ASSIGNED cancellation must not name a route execution'
    );
  end if;
  v_decision_id := haulvia_command.record_pre_custody_decision(
    p_shipment, v_assignment, v_execution_id,
    'cancelAssignedBeforeCustody', p_request, false
  );
  select state, secured_amount into v_payment_prior, v_secured
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id for update;
  v_payment_after := case when v_refund = v_secured
    then 'REFUNDED'::haulvia.customer_payment_state
    else 'PARTIALLY_REFUNDED'::haulvia.customer_payment_state end;

  if v_execution_id is not null then
    update haulvia.stop_attempts sa
    set state = 'CANCELLED', ended_at = coalesce(ended_at, clock_timestamp())
    where sa.stop_execution_id in (
      select se.id from haulvia.stop_executions se
      where se.route_execution_id = v_execution_id
        and se.state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED')
    ) and sa.ended_at is null;
    update haulvia.stop_executions set state = 'CANCELLED'
    where route_execution_id = v_execution_id
      and state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED');
    update haulvia.route_executions
    set state = 'CANCELLED', next_action = 'NONE', record_version = record_version + 1
    where id = v_execution_id;
    update haulvia.tracking_sessions set ended_at = clock_timestamp()
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
    'cancelAssignedBeforeCustody', 'PROFILE', v_actor,
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
    p_request, 'e03-cancellation-settlement',
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment_prior::text, v_payment_after::text,
    'cancelAssignedBeforeCustody', p_request, v_decision_id,
    jsonb_build_object('chargeAmount', v_charge, 'refundAmount', v_refund)
  );
  if v_execution_id is not null then
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'CANCELLED',
      'cancelAssignedBeforeCustody', p_request, v_execution_id
    );
  end if;
  perform haulvia_command.append_shipment_event(
    p_shipment.id, p_shipment.shipment_state, 'CANCELLED',
    'cancelAssignedBeforeCustody', p_request, v_assignment.route_version_id,
    jsonb_build_object(
      'assignmentId', v_assignment.id, 'routeExecutionId', v_execution_id,
      'financialDecisionId', v_decision_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'cancelAssignedBeforeCustody', p_request, to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id,
    'SHIPMENT_CANCELLED_ASSIGNED_BEFORE_CUSTODY', p_request,
    'assigned-before-custody-cancelled',
    jsonb_build_object('financialDecisionId', v_decision_id)
  );
  return jsonb_build_object(
    'shipmentState', 'CANCELLED', 'routeVersionId', v_assignment.route_version_id,
    'assignmentId', v_assignment.id, 'routeExecutionId', v_execution_id,
    'financialDecisionId', v_decision_id,
    'customerPaymentState', v_payment_after
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- E05-E08: immutable failed-stop retry and explicit continuation decisions
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_e05_retry_failed_stop_same_driver(
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
  v_failed_attempt haulvia.stop_attempts%rowtype;
  v_retry_attempt_id uuid;
  v_exception haulvia.route_exceptions%rowtype;
  v_report_id uuid := haulvia_command.optional_uuid(p_request, 'stopFailureReportId');
  v_snapshot jsonb := p_request -> 'serviceabilitySnapshot';
  v_hold_id uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'retryFailedStopSameDriver requires ROUTE_IN_PROGRESS');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_route_operator(v_assignment, p_request, true);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state not in ('ACTIVE', 'HELD') then
    perform haulvia_command.fail('INVALID_STATE', 'Retry requires the current active or held execution');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state <> 'FAILED' then
    perform haulvia_command.fail('INVALID_STATE', 'Only an immutable FAILED stop may be retried');
  end if;
  select * into v_failed_attempt from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id
    and sa.attempt_no = v_stop.current_attempt_no
    and sa.state = 'FAILED' and sa.ended_at is not null
  for share;
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'The failed stop attempt is not finalized');
  end if;
  if jsonb_typeof(v_snapshot) <> 'object' or v_snapshot = '{}'::jsonb
     or not coalesce((v_snapshot ->> 'serviceable')::boolean, false)
     or not coalesce((v_snapshot ->> 'assignmentValid')::boolean, false)
     or nullif(btrim(v_snapshot ->> 'assessmentCode'), '') is null then
    perform haulvia_command.fail(
      'STOP_NOT_SERVICEABLE',
      'Retry requires a retained serviceable and still-valid assignment assessment'
    );
  end if;
  select * into v_exception from haulvia.route_exceptions re
  where re.id = haulvia_command.required_uuid(p_request, 'routeExceptionId')
    and re.shipment_id = p_shipment.id and re.stop_execution_id = v_stop.id
    and re.status not in ('RESOLVED', 'CLOSED')
  for update;
  if not found then
    perform haulvia_command.fail('NOT_FOUND', 'The unresolved failed-stop exception was not found');
  end if;
  if v_report_id is not null and not exists (
    select 1 from haulvia.stop_failure_reports sfr
    where sfr.id = v_report_id and sfr.stop_execution_id = v_stop.id
      and sfr.route_execution_id = v_execution.id
  ) then
    perform haulvia_command.fail('NOT_FOUND', 'The failed-stop report was not found');
  end if;
  v_hold_id := v_exception.workflow_hold_id;
  if v_hold_id is not null and exists (
    select 1 from haulvia.workflow_holds wh where wh.id = v_hold_id and wh.status = 'ACTIVE'
  ) then
    if haulvia_command.optional_uuid(p_request, 'releasedWorkflowHoldId') is distinct from v_hold_id then
      perform haulvia_command.fail(
        'WORKFLOW_HELD', 'The failed-stop movement hold must be explicitly released for retry'
      );
    end if;
    update haulvia.workflow_holds
    set status = 'RELEASED', released_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
        released_at = clock_timestamp(), release_reason = 'Same-driver retry authorized'
    where id = v_hold_id;
  end if;

  insert into haulvia.stop_attempts (
    stop_execution_id, attempt_no, state, arrived_at
  ) values (
    v_stop.id, v_stop.current_attempt_no + 1, 'ARRIVED', clock_timestamp()
  ) returning id into v_retry_attempt_id;
  update haulvia.stop_executions
  set state = 'ARRIVED', current_attempt_no = current_attempt_no + 1,
      state_changed_at = clock_timestamp(), completed_at = null
  where id = v_stop.id;
  update haulvia.route_executions
  set state = case when execution_kind in ('RECOVERY', 'RETURN', 'REDELIVERY')
      then 'RECOVERY_ACTIVE'::haulvia.route_execution_state
      else 'ACTIVE'::haulvia.route_execution_state end,
      next_action = 'START_STOP_SERVICE', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.route_exceptions
  set status = 'RESOLVED', blocks_completion = false,
      resolution = 'Same assigned driver authorized for a new immutable stop attempt',
      resolved_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      resolved_at = clock_timestamp()
  where id = v_exception.id;
  insert into haulvia.stop_retry_records (
    shipment_id, route_execution_id, route_version_id, stop_execution_id,
    failed_stop_attempt_id, retry_stop_attempt_id, stop_failure_report_id,
    serviceability_snapshot, authorized_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
    v_failed_attempt.id, v_retry_attempt_id, v_report_id, v_snapshot,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  );
  perform haulvia_command.append_stop_event(
    v_retry_attempt_id, v_stop.id, 'FAILED', 'ARRIVED',
    'retryFailedStopSameDriver', p_request,
    jsonb_build_object(
      'failedStopAttemptId', v_failed_attempt.id,
      'routeExceptionId', v_exception.id,
      'releasedWorkflowHoldId', v_hold_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'retryFailedStopSameDriver', p_request,
    jsonb_build_object('stopState', 'FAILED', 'stopAttemptId', v_failed_attempt.id),
    jsonb_build_object('stopState', 'ARRIVED', 'stopAttemptId', v_retry_attempt_id),
    jsonb_build_object('routeExceptionId', v_exception.id, 'serviceabilitySnapshot', v_snapshot)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'FAILED_STOP_RETRY_STARTED',
    p_request, 'stop-retry-' || v_retry_attempt_id::text,
    jsonb_build_object('stopExecutionId', v_stop.id, 'retryStopAttemptId', v_retry_attempt_id)
  );
  return jsonb_build_object(
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'stopExecutionId', v_stop.id, 'failedStopAttemptId', v_failed_attempt.id,
    'retryStopAttemptId', v_retry_attempt_id, 'stopState', 'ARRIVED',
    'historicalFailurePreserved', true
  );
end;
$$;

create or replace function haulvia_command.apply_e06_prepare_failed_first_pickup_repost(
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
  v_exception haulvia.route_exceptions%rowtype;
  v_financial_id uuid;
  v_resolution_id uuid;
  v_payment_prior haulvia.customer_payment_state;
  v_refund numeric := haulvia_command.required_numeric(p_request, 'customerRefundAmount');
  v_secured numeric;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail(
      'INVALID_STATE', 'prepareFailedFirstPickupRepost requires ROUTE_IN_PROGRESS'
    );
  end if;
  if not haulvia_command.required_boolean(p_request, 'routeCannotContinue') then
    perform haulvia_command.fail(
      'CONTINUATION_STILL_FEASIBLE', 'Repost preparation requires a retained route-cannot-continue decision'
    );
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_customer_or_route_workflow(p_shipment, v_assignment, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state not in ('ACTIVE', 'HELD') then
    perform haulvia_command.fail('INVALID_STATE', 'The failed first-pickup execution is not current');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state <> 'FAILED' or not exists (
    select 1 from haulvia.route_stops rs
    where rs.id = v_stop.route_stop_id and rs.route_version_id = v_stop.route_version_id
      and rs.sequence_no = 1 and rs.stop_type = 'PICKUP'
  ) then
    perform haulvia_command.fail('INVALID_STATE', 'Repost preparation requires the FAILED first pickup');
  end if;
  select * into v_exception from haulvia.route_exceptions re
  where re.id = haulvia_command.required_uuid(p_request, 'routeExceptionId')
    and re.shipment_id = p_shipment.id and re.stop_execution_id = v_stop.id
    and re.status not in ('RESOLVED', 'CLOSED')
  for update;
  if not found then
    perform haulvia_command.fail('NOT_FOUND', 'The failed first-pickup exception was not found');
  end if;
  v_financial_id := haulvia_command.record_pre_custody_decision(
    p_shipment, v_assignment, v_execution.id,
    'prepareFailedFirstPickupRepost', p_request, false
  );
  select state, secured_amount into v_payment_prior, v_secured
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id for update;

  update haulvia.stop_executions set state = 'CANCELLED'
  where route_execution_id = v_execution.id
    and state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED');
  update haulvia.route_executions
  set state = 'CANCELLED', active_stop_execution_id = null, active_route_leg_id = null,
      next_action = 'CUSTOMER_REVIEW_BEFORE_REPOST', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.tracking_sessions set ended_at = clock_timestamp()
  where route_execution_id = v_execution.id and ended_at is null;
  update haulvia.assignments
  set status = 'CANCELLED', ended_at = clock_timestamp(),
      end_reason = 'FAILED_FIRST_PICKUP_PREPARED_FOR_REPOST'
  where id = v_assignment.id;
  insert into haulvia.assignment_events (
    assignment_id, shipment_id, prior_status, current_status, command_name,
    actor_kind, actor_profile_id, reason, idempotency_key, metadata
  ) values (
    v_assignment.id, p_shipment.id, 'ACTIVE', 'CANCELLED',
    'prepareFailedFirstPickupRepost',
    case when haulvia_command.optional_uuid(p_request, 'actorProfileId') is null
      then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'reason'),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object('financialDecisionId', v_financial_id)
  );
  if v_exception.workflow_hold_id is not null then
    update haulvia.workflow_holds
    set status = 'RELEASED', released_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
        released_at = clock_timestamp(), release_reason = 'Assignment closed for deliberate customer review'
    where id = v_exception.workflow_hold_id and status = 'ACTIVE';
  end if;
  update haulvia.route_exceptions
  set status = 'RESOLVED', blocks_completion = false,
      resolution = 'First pickup failed with zero custody; shipment prepared but not automatically reposted',
      resolved_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      resolved_at = clock_timestamp()
  where id = v_exception.id;
  update haulvia.shipment_customer_payment_axes
  set state = case when v_refund = v_secured
        then 'REFUNDED'::haulvia.customer_payment_state
        else 'PARTIALLY_REFUNDED'::haulvia.customer_payment_state end,
      secured_amount = greatest(v_secured - v_refund, 0), state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_marketplace_axes
  set state = 'PAUSED', paused_reason = 'FAILED_FIRST_PICKUP_CUSTOMER_REVIEW',
      state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'POSTED' where id = p_shipment.id;

  insert into haulvia.failed_first_pickup_resolutions (
    shipment_id, route_execution_id, route_version_id, assignment_id,
    stop_execution_id, stop_failure_report_id, route_exception_id,
    pre_custody_financial_decision_id, resolution_code, responsibility_code,
    decision_snapshot, resolved_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_execution.route_version_id, v_assignment.id,
    v_stop.id, haulvia_command.optional_uuid(p_request, 'stopFailureReportId'),
    v_exception.id, v_financial_id, 'PREPARED_FOR_REPOST',
    haulvia_command.required_text(p_request, 'responsibilityCode'),
    p_request -> 'decisionSnapshot', haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_resolution_id;
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'MARKETPLACE', 'CLOSED', 'PAUSED',
    'prepareFailedFirstPickupRepost', p_request, null,
    jsonb_build_object('automaticRepublish', false)
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'CANCELLED',
    'prepareFailedFirstPickupRepost', p_request, v_execution.id
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id, 'ROUTE_IN_PROGRESS', 'POSTED',
    'prepareFailedFirstPickupRepost', p_request, v_execution.route_version_id,
    jsonb_build_object(
      'failedFirstPickupResolutionId', v_resolution_id,
      'automaticRepublish', false
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'prepareFailedFirstPickupRepost', p_request,
    jsonb_build_object('shipmentState', 'ROUTE_IN_PROGRESS', 'stopState', 'FAILED'),
    jsonb_build_object('shipmentState', 'POSTED', 'marketplaceState', 'PAUSED'),
    jsonb_build_object(
      'failedFirstPickupResolutionId', v_resolution_id,
      'financialDecisionId', v_financial_id, 'automaticRepublish', false
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id,
    'FAILED_FIRST_PICKUP_REPOST_REVIEW_REQUIRED', p_request,
    'failed-first-pickup-review',
    jsonb_build_object('failedFirstPickupResolutionId', v_resolution_id)
  );
  return jsonb_build_object(
    'shipmentState', 'POSTED', 'marketplaceState', 'PAUSED',
    'assignmentId', v_assignment.id, 'routeExecutionId', v_execution.id,
    'failedFirstPickupResolutionId', v_resolution_id,
    'financialDecisionId', v_financial_id, 'automaticRepublish', false
  );
end;
$$;

create or replace function haulvia_command.apply_e07_close_failed_first_pickup(
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
  v_exception haulvia.route_exceptions%rowtype;
  v_target haulvia.shipment_state;
  v_financial_id uuid;
  v_resolution_id uuid;
  v_payment_prior haulvia.customer_payment_state;
  v_market_prior haulvia.marketplace_state;
  v_refund numeric := haulvia_command.required_numeric(p_request, 'customerRefundAmount');
  v_secured numeric;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'closeFailedFirstPickup requires ROUTE_IN_PROGRESS');
  end if;
  begin
    v_target := upper(haulvia_command.required_text(p_request, 'closeOutcome'))::haulvia.shipment_state;
  exception when invalid_text_representation then
    perform haulvia_command.fail('INVALID_REQUEST', 'closeOutcome must be CANCELLED or EXPIRED');
  end;
  if v_target not in ('CANCELLED', 'EXPIRED') then
    perform haulvia_command.fail('INVALID_REQUEST', 'closeOutcome must be CANCELLED or EXPIRED');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  if v_target = 'CANCELLED' then
    perform haulvia_command.authorize_customer(
      p_shipment, haulvia_command.required_uuid(p_request, 'actorProfileId'),
      haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
    );
  else
    perform haulvia_command.assert_worker(
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      p_request ->> 'workerAuthority', array['EXPIRY_WORKER', 'ROUTE_OPERATIONS_WORKER']
    );
    if p_shipment.marketplace_deadline is null
       or p_shipment.marketplace_deadline > clock_timestamp() then
      perform haulvia_command.fail('DEADLINE_NOT_EXPIRED', 'EXPIRED closure requires an elapsed shipment deadline');
    end if;
  end if;
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.assert_no_verified_custody(p_shipment.id);
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state <> 'FAILED' or not exists (
    select 1 from haulvia.route_stops rs
    where rs.id = v_stop.route_stop_id and rs.sequence_no = 1 and rs.stop_type = 'PICKUP'
  ) then
    perform haulvia_command.fail('INVALID_STATE', 'Closure requires the immutable failed first pickup');
  end if;
  select * into v_exception from haulvia.route_exceptions re
  where re.id = haulvia_command.required_uuid(p_request, 'routeExceptionId')
    and re.stop_execution_id = v_stop.id and re.shipment_id = p_shipment.id
    and re.status not in ('RESOLVED', 'CLOSED')
  for update;
  if not found then
    perform haulvia_command.fail('NOT_FOUND', 'The failed first-pickup exception was not found');
  end if;
  v_financial_id := haulvia_command.record_pre_custody_decision(
    p_shipment, v_assignment, v_execution.id,
    'closeFailedFirstPickup', p_request, false
  );
  select state, secured_amount into v_payment_prior, v_secured
  from haulvia.shipment_customer_payment_axes
  where shipment_id = p_shipment.id for update;
  select state into v_market_prior from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;

  update haulvia.stop_executions set state = 'CANCELLED'
  where route_execution_id = v_execution.id
    and state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED');
  update haulvia.route_executions
  set state = 'CANCELLED', active_stop_execution_id = null, active_route_leg_id = null,
      next_action = 'NONE', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.tracking_sessions set ended_at = clock_timestamp()
  where route_execution_id = v_execution.id and ended_at is null;
  update haulvia.assignments
  set status = 'CANCELLED', ended_at = clock_timestamp(),
      end_reason = 'FAILED_FIRST_PICKUP_' || v_target::text
  where id = v_assignment.id;
  if v_exception.workflow_hold_id is not null then
    update haulvia.workflow_holds
    set status = 'RELEASED', released_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
        released_at = clock_timestamp(), release_reason = 'Failed first pickup closed'
    where id = v_exception.workflow_hold_id and status = 'ACTIVE';
  end if;
  update haulvia.route_exceptions
  set status = 'CLOSED', blocks_completion = false,
      resolution = 'Failed first pickup closed as ' || v_target::text,
      resolved_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      resolved_at = clock_timestamp()
  where id = v_exception.id;
  update haulvia.shipment_customer_payment_axes
  set state = case when v_refund = v_secured
        then 'REFUNDED'::haulvia.customer_payment_state
        else 'PARTIALLY_REFUNDED'::haulvia.customer_payment_state end,
      secured_amount = greatest(v_secured - v_refund, 0), state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_marketplace_axes
  set state = case when v_target = 'EXPIRED'
        then 'EXPIRED'::haulvia.marketplace_state else 'CLOSED'::haulvia.marketplace_state end,
      paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = v_target where id = p_shipment.id;
  insert into haulvia.failed_first_pickup_resolutions (
    shipment_id, route_execution_id, route_version_id, assignment_id,
    stop_execution_id, stop_failure_report_id, route_exception_id,
    pre_custody_financial_decision_id, resolution_code, responsibility_code,
    decision_snapshot, resolved_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_execution.route_version_id, v_assignment.id,
    v_stop.id, haulvia_command.optional_uuid(p_request, 'stopFailureReportId'),
    v_exception.id, v_financial_id, v_target::text,
    haulvia_command.required_text(p_request, 'responsibilityCode'),
    p_request -> 'decisionSnapshot', haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_resolution_id;
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'CANCELLED',
    'closeFailedFirstPickup', p_request, v_execution.id
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'MARKETPLACE', v_market_prior::text,
    case when v_target = 'EXPIRED' then 'EXPIRED' else 'CLOSED' end,
    'closeFailedFirstPickup', p_request
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'CUSTOMER_PAYMENT', v_payment_prior::text,
    case when v_refund = v_secured then 'REFUNDED' else 'PARTIALLY_REFUNDED' end,
    'closeFailedFirstPickup', p_request, v_financial_id
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id, 'ROUTE_IN_PROGRESS', v_target,
    'closeFailedFirstPickup', p_request, v_execution.route_version_id,
    jsonb_build_object('failedFirstPickupResolutionId', v_resolution_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'closeFailedFirstPickup', p_request,
    jsonb_build_object('shipmentState', 'ROUTE_IN_PROGRESS', 'stopState', 'FAILED'),
    jsonb_build_object('shipmentState', v_target),
    jsonb_build_object(
      'failedFirstPickupResolutionId', v_resolution_id,
      'financialDecisionId', v_financial_id
    )
  );
  return jsonb_build_object(
    'shipmentState', v_target, 'assignmentId', v_assignment.id,
    'routeExecutionId', v_execution.id,
    'failedFirstPickupResolutionId', v_resolution_id,
    'financialDecisionId', v_financial_id
  );
end;
$$;

create or replace function haulvia_command.apply_e08_continue_route_after_failed_stop(
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
  v_decision text := upper(haulvia_command.required_text(p_request, 'decisionCode'));
  v_custody jsonb;
  v_advance jsonb;
  v_authorization_id uuid;
  v_item jsonb;
  v_allocation haulvia.cargo_allocations%rowtype;
  v_quantity numeric;
  v_outcome_id uuid;
  v_outcomes jsonb := '[]'::jsonb;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'continueRouteAfterFailedStop requires ROUTE_IN_PROGRESS');
  end if;
  if v_decision not in ('SKIP', 'RECOVERY', 'AMENDMENT', 'RETURN', 'REDELIVERY',
                        'ALTERNATE_DESTINATION', 'TRANSFER', 'STORAGE') then
    perform haulvia_command.fail('INVALID_REQUEST', 'decisionCode is not an approved failed-stop action');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.authorize_customer_or_route_workflow(p_shipment, v_assignment, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Only the ACTIVE current route may continue');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state <> 'FAILED' then
    perform haulvia_command.fail('INVALID_STATE', 'The current stop must remain FAILED');
  end if;
  select * into v_report from haulvia.stop_failure_reports sfr
  where sfr.id = haulvia_command.required_uuid(p_request, 'stopFailureReportId')
    and sfr.route_execution_id = v_execution.id and sfr.stop_execution_id = v_stop.id
  for share;
  if not found then
    perform haulvia_command.fail('NOT_FOUND', 'The failed-stop report was not found');
  end if;
  if not haulvia_command.required_boolean(p_request, 'routeFeasible')
     or not haulvia_command.required_boolean(p_request, 'capacityValidated')
     or not haulvia_command.required_boolean(p_request, 'timingValidated')
     or not haulvia_command.required_boolean(p_request, 'custodyValidated') then
    perform haulvia_command.fail(
      'CONTINUATION_NOT_FEASIBLE',
      'Capacity, timing, custody, and remaining-route feasibility must all be revalidated'
    );
  end if;
  if jsonb_typeof(p_request -> 'routeFeasibilitySnapshot') <> 'object'
     or p_request -> 'routeFeasibilitySnapshot' = '{}'::jsonb
     or jsonb_typeof(p_request -> 'capacitySnapshot') <> 'object'
     or p_request -> 'capacitySnapshot' = '{}'::jsonb
     or jsonb_typeof(p_request -> 'timingSnapshot') <> 'object'
     or p_request -> 'timingSnapshot' = '{}'::jsonb
     or jsonb_typeof(p_request -> 'customerInstructions') <> 'object'
     or p_request -> 'customerInstructions' = '{}'::jsonb then
    perform haulvia_command.fail(
      'INVALID_REQUEST', 'Continuation validation and customer instructions must be retained'
    );
  end if;
  if v_report.command_name = 'reportFailedDeliveryStop'
     and coalesce(v_report.approved_next_route_decision ->> 'decisionCode', '') <> v_decision then
    perform haulvia_command.fail(
      'NEXT_ROUTE_DECISION_REQUIRED', 'Continuation must match the approved failed-delivery decision'
    );
  end if;
  v_custody := haulvia_command.assert_custody_snapshot(p_shipment.id, p_request -> 'custodyBalance');
  perform haulvia_command.assert_route_movement_unheld(p_shipment.id);
  v_advance := haulvia_command.advance_after_terminal_stop(
    p_shipment, v_execution, v_stop, p_request, 'continueRouteAfterFailedStop'
  );
  insert into haulvia.stop_continuation_authorizations (
    shipment_id, route_execution_id, stop_failure_report_id, failed_stop_execution_id,
    next_stop_execution_id, decision_code, route_feasibility_snapshot, capacity_snapshot,
    timing_snapshot, custody_balance_snapshot, customer_instructions,
    authorized_by_profile_id, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_report.id, v_stop.id,
    (v_advance ->> 'stopExecutionId')::uuid, v_decision,
    p_request -> 'routeFeasibilitySnapshot', p_request -> 'capacitySnapshot',
    p_request -> 'timingSnapshot', v_custody, p_request -> 'customerInstructions',
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_authorization_id;

  if v_report.command_name = 'reportFailedPickupStop' and v_decision = 'SKIP' then
    for v_item in select value from jsonb_array_elements(v_report.affected_cargo)
    loop
      select * into v_allocation from haulvia.cargo_allocations ca
      where ca.id = haulvia_command.required_uuid(v_item, 'cargoAllocationId')
        and ca.route_version_id = v_execution.route_version_id
        and ca.pickup_stop_id = v_stop.route_stop_id;
      if not found then
        perform haulvia_command.fail(
          'CARGO_BALANCE_INVALID', 'Failed-pickup skip references an invalid allocation'
        );
      end if;
      v_quantity := coalesce(haulvia_command.optional_numeric(v_item, 'quantity'), v_allocation.quantity);
      if v_quantity <= 0 or v_quantity > v_allocation.quantity then
        perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'Approved skipped quantity is invalid');
      end if;
      insert into haulvia.cargo_resolution_outcomes (
        shipment_id, route_execution_id, route_version_id, stop_execution_id,
        cargo_allocation_id, outcome_code, quantity, quantity_unit, approval_snapshot,
        approved_by_profile_id, occurred_at, idempotency_key
      ) values (
        p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
        v_allocation.id, 'APPROVED_NOT_LOADED', v_quantity, v_allocation.quantity_unit,
        jsonb_build_object(
          'stopContinuationAuthorizationId', v_authorization_id,
          'customerInstructions', p_request -> 'customerInstructions'
        ), haulvia_command.optional_uuid(p_request, 'actorProfileId'), clock_timestamp(),
        haulvia_command.required_text(p_request, 'idempotencyKey') || ':skipped-outcome:' || v_allocation.id::text
      ) returning id into v_outcome_id;
      v_outcomes := v_outcomes || jsonb_build_array(v_outcome_id);
    end loop;
    update haulvia.route_exceptions
    set status = 'RESOLVED', blocks_completion = false,
        resolution = 'Authorized failed-pickup skip and route continuation',
        resolved_by_profile_id = haulvia_command.optional_uuid(p_request, 'actorProfileId'),
        resolved_at = clock_timestamp()
    where id = v_report.route_exception_id;
  end if;
  perform haulvia_command.append_audit(
    p_shipment, 'continueRouteAfterFailedStop', p_request,
    jsonb_build_object('activeStopExecutionId', v_stop.id, 'stopState', 'FAILED'),
    jsonb_build_object(
      'activeStopExecutionId', v_advance ->> 'stopExecutionId',
      'failedStopState', 'FAILED'
    ),
    jsonb_build_object(
      'stopContinuationAuthorizationId', v_authorization_id,
      'decisionCode', v_decision, 'cargoOutcomeIds', v_outcomes,
      'custodyBalance', v_custody
    )
  );
  return v_advance || jsonb_build_object(
    'failedStopExecutionId', v_stop.id, 'failedStopState', 'FAILED',
    'stopFailureReportId', v_report.id,
    'stopContinuationAuthorizationId', v_authorization_id,
    'decisionCode', v_decision, 'cargoOutcomeIds', v_outcomes,
    'custodySummary', v_custody
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- E09-E10: verified custody transfer and linked recovery route creation
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_e09_authorize_custody_transfer(
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
     or not exists (
       select 1 from jsonb_array_elements(v_evidence) x
       where upper(coalesce(x ->> 'type', '')) = 'PHOTO'
         and nullif(x ->> 'storageObjectKey', '') is not null
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
$$;

create or replace function haulvia_command.apply_e10_start_recovery_leg(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_assignment haulvia.assignments%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_prior_route uuid;
  v_new_route uuid;
  v_new_execution uuid;
  v_new_stop uuid;
  v_new_leg uuid;
  v_new_attempt uuid;
  v_tracking uuid;
  v_price uuid;
  v_record_id uuid;
  v_payment_intent uuid := haulvia_command.optional_uuid(p_request, 'additionalPaymentIntentId');
  v_additional numeric := haulvia_command.required_numeric(p_request, 'additionalPaymentAmount');
  v_currency char(3) := upper(haulvia_command.required_text(p_request, 'currency'))::char(3);
  v_emergency boolean := coalesce(haulvia_command.required_boolean(p_request, 'emergencyWaiver'), false);
  v_kind haulvia.route_execution_kind;
  v_action text := upper(haulvia_command.required_text(p_request, 'recoveryActionCode'));
  v_acceptance jsonb := p_request -> 'providerAcceptance';
  v_snapshot jsonb := p_request -> 'recoverySnapshot';
  v_custody jsonb;
  v_sequence integer;
  v_payment_hold uuid;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'startRecoveryLeg requires ROUTE_IN_PROGRESS');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'SHIPMENT_STATE_OVERRIDE', array['RECOVERY_WORKER']
  );
  begin
    v_kind := upper(haulvia_command.required_text(p_request, 'recoveryKind'))::haulvia.route_execution_kind;
  exception when invalid_text_representation then
    perform haulvia_command.fail('INVALID_REQUEST', 'recoveryKind must be RECOVERY, RETURN, or REDELIVERY');
  end;
  if v_kind not in ('RECOVERY', 'RETURN', 'REDELIVERY')
     or v_action not in ('RETURN', 'ALTERNATE_DELIVERY', 'REDELIVERY', 'STORAGE', 'TRANSFER', 'OTHER_RECOVERY') then
    perform haulvia_command.fail('INVALID_REQUEST', 'Recovery kind or action is not approved');
  end if;
  if v_currency <> p_shipment.currency or v_additional < 0 then
    perform haulvia_command.fail('FINANCIAL_DECISION_INVALID', 'Recovery amount or currency is invalid');
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  v_prior_route := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.route_version_id <> v_prior_route
     or v_execution.state not in ('ACTIVE', 'HELD', 'RECOVERY_ACTIVE') then
    perform haulvia_command.fail('INVALID_STATE', 'Recovery requires the current route execution and route version');
  end if;
  v_custody := haulvia_command.assert_custody_snapshot(p_shipment.id, p_request -> 'custodyBalance');
  perform haulvia_command.assert_positive_custody(p_shipment.id);
  if jsonb_typeof(v_acceptance) <> 'object' or v_acceptance = '{}'::jsonb
     or not coalesce((v_acceptance ->> 'accepted')::boolean, false)
     or (v_acceptance ->> 'driverId')::uuid <> v_assignment.driver_id then
    perform haulvia_command.fail(
      'PROVIDER_ACCEPTANCE_REQUIRED', 'Current provider must accept the linked recovery work'
    );
  end if;
  if jsonb_typeof(v_snapshot) <> 'object' or v_snapshot = '{}'::jsonb
     or nullif(v_snapshot ->> 'approvedDestination', '') is null
     or nullif(v_snapshot ->> 'reasonCode', '') is null then
    perform haulvia_command.fail('INVALID_REQUEST', 'A complete recoverySnapshot is required');
  end if;

  v_new_route := haulvia_command.create_route_from_plan(
    p_shipment.id, v_prior_route, v_actor,
    haulvia_command.required_text(p_request, 'reason'), p_request -> 'routePlan'
  );
  if exists (
    select 1 from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id = p_shipment.id and cb.onboard_quantity > 0
      and not exists (
        select 1 from haulvia.cargo_items ci
        where ci.route_version_id = v_new_route
          and ci.stable_cargo_key = cb.stable_cargo_key
          and ci.quantity_unit = cb.quantity_unit
          and ci.quantity >= cb.onboard_quantity
      )
  ) then
    perform haulvia_command.fail(
      'CARGO_BALANCE_INVALID',
      'Recovery route must retain every onboard stable cargo key, unit, and quantity'
    );
  end if;
  insert into haulvia.shipment_rule_snapshots (
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  )
  select p_shipment.id, v_new_route, srs.policy_version_id,
         srs.evidence_requirements, srs.cancellation_rules, srs.refund_rules,
         srs.timing_windows,
         srs.risk_rules || jsonb_build_object(
           'recoveryActionCode', v_action,
           'sourceRouteVersionId', v_prior_route,
           'recoverySnapshot', v_snapshot
         ), srs.config_sha256
  from haulvia.shipment_rule_snapshots srs
  where srs.shipment_id = p_shipment.id and srs.route_version_id = v_prior_route;
  if not found then
    perform haulvia_command.fail('POLICY_SNAPSHOT_MISMATCH', 'Recovery requires the retained route policy snapshot');
  end if;
  v_price := haulvia_command.create_price_snapshot(
    p_shipment, v_new_route, 'ADJUSTMENT', p_request, v_actor
  );
  if (select total_amount from haulvia.shipment_price_snapshots where id = v_price) <> v_additional then
    perform haulvia_command.fail(
      'FINANCIAL_DECISION_INVALID', 'Recovery price snapshot must equal additionalPaymentAmount'
    );
  end if;
  if v_additional > 0 and not v_emergency then
    if v_payment_intent is null or not exists (
      select 1 from haulvia.payment_intents pi
      where pi.id = v_payment_intent and pi.shipment_id = p_shipment.id
        and pi.status = 'SECURED' and pi.amount >= v_additional and pi.currency = v_currency
        and pi.offer_reservation_id is null
    ) then
      perform haulvia_command.fail(
        'ADDITIONAL_PAYMENT_NOT_SECURED', 'Non-emergency recovery work requires secured additional payment'
      );
    end if;
    update haulvia.shipment_customer_payment_axes
    set secured_amount = secured_amount + v_additional, state = 'SECURED',
        state_changed_at = clock_timestamp()
    where shipment_id = p_shipment.id;
  elsif v_additional > 0 and v_emergency and v_payment_intent is null then
    insert into haulvia.workflow_holds (
      shipment_id, route_execution_id, hold_code, status,
      blocks_marketplace, blocks_route_movement, blocks_completion,
      reason, opened_by_profile_id
    ) values (
      p_shipment.id, v_execution.id, 'EMERGENCY_RECOVERY_PAYMENT_DUE', 'ACTIVE',
      false, false, true, 'Emergency recovery additional payment remains due',
      v_actor
    ) returning id into v_payment_hold;
  elsif v_additional = 0 and v_payment_intent is not null then
    perform haulvia_command.fail(
      'FINANCIAL_DECISION_INVALID', 'Zero-price recovery cannot consume a payment intent'
    );
  end if;

  update haulvia.stop_attempts sa
  set state = 'CANCELLED', ended_at = coalesce(ended_at, clock_timestamp())
  where sa.stop_execution_id in (
    select se.id from haulvia.stop_executions se
    where se.route_execution_id = v_execution.id
      and se.state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED')
  ) and sa.ended_at is null;
  update haulvia.stop_executions set state = 'CANCELLED'
  where route_execution_id = v_execution.id
    and state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED');
  update haulvia.tracking_sessions set ended_at = clock_timestamp()
  where route_execution_id = v_execution.id and ended_at is null;
  update haulvia.route_executions
  set state = 'COMPLETED', completed_at = clock_timestamp(),
      active_stop_execution_id = null, active_route_leg_id = null,
      next_action = 'RECOVERY_LINKED', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.route_versions set status = 'SUPERSEDED' where id = v_prior_route;
  update haulvia.route_versions set status = 'ACTIVE' where id = v_new_route;
  insert into haulvia.route_executions (
    shipment_id, route_version_id, assignment_id, parent_route_execution_id,
    execution_kind, state, started_at, next_action, record_version
  ) values (
    p_shipment.id, v_new_route, v_assignment.id, v_execution.id,
    v_kind, 'RECOVERY_ACTIVE', clock_timestamp(), 'START_RECOVERY_ROUTE', 0
  ) returning id into v_new_execution;
  insert into haulvia.stop_executions (
    shipment_id, route_execution_id, route_version_id, route_stop_id,
    state, delivery_verification_state, current_attempt_no, completed_at
  )
  select p_shipment.id, v_new_execution, v_new_route, new_rs.id,
         coalesce(old_se.state, 'PENDING'::haulvia.stop_state),
         coalesce(old_se.delivery_verification_state, 'NOT_REQUIRED'::haulvia.delivery_verification_state),
         0, case when old_se.state = 'COMPLETED' then old_se.completed_at end
  from haulvia.route_stops new_rs
  left join lateral (
    select se.state, se.delivery_verification_state, se.completed_at
    from haulvia.stop_executions se
    join haulvia.route_stops old_rs
      on old_rs.id = se.route_stop_id and old_rs.route_version_id = se.route_version_id
    where se.route_execution_id = v_execution.id
      and old_rs.stable_stop_key = new_rs.stable_stop_key
      and se.state in ('COMPLETED', 'SKIPPED')
    limit 1
  ) old_se on true
  where new_rs.route_version_id = v_new_route
  order by new_rs.sequence_no;
  select se.id, rs.sequence_no into v_new_stop, v_sequence
  from haulvia.stop_executions se
  join haulvia.route_stops rs on rs.id = se.route_stop_id
  where se.route_execution_id = v_new_execution and se.state = 'PENDING'
  order by rs.sequence_no limit 1 for update of se;
  if v_new_stop is null then
    perform haulvia_command.fail('ROUTE_INVALID', 'Recovery route has no eligible remaining stop');
  end if;
  select rl.id into v_new_leg from haulvia.route_legs rl
  where rl.route_version_id = v_new_route
    and rl.sequence_no = case when v_sequence = 1 then 1 else v_sequence - 1 end;
  if v_new_leg is null then
    perform haulvia_command.fail('ROUTE_INVALID', 'Recovery route has no active leg for its next stop');
  end if;
  insert into haulvia.stop_attempts (stop_execution_id, attempt_no, state)
  values (v_new_stop, 1, 'EN_ROUTE') returning id into v_new_attempt;
  update haulvia.stop_executions
  set state = 'EN_ROUTE', current_attempt_no = 1,
      current_eta_at = coalesce(nullif(p_request ->> 'nextStopEtaAt', '')::timestamptz, clock_timestamp()),
      eta_updated_at = clock_timestamp()
  where id = v_new_stop;
  update haulvia.route_executions
  set active_stop_execution_id = v_new_stop, active_route_leg_id = v_new_leg,
      next_action = 'CONFIRM_ARRIVAL_AT_STOP', record_version = 1
  where id = v_new_execution;
  insert into haulvia.tracking_sessions (route_execution_id, driver_id, started_at)
  values (v_new_execution, v_assignment.driver_id, clock_timestamp()) returning id into v_tracking;
  insert into haulvia.recovery_route_records (
    shipment_id, prior_route_version_id, recovery_route_version_id,
    prior_route_execution_id, recovery_route_execution_id, assignment_id,
    price_snapshot_id, additional_payment_intent_id, recovery_kind,
    recovery_action_code, additional_payment_amount, currency, emergency_waiver,
    provider_acceptance_snapshot, custody_balance_snapshot, recovery_snapshot,
    authorized_by_profile_id, reauth_session_id, idempotency_key
  ) values (
    p_shipment.id, v_prior_route, v_new_route, v_execution.id, v_new_execution,
    v_assignment.id, v_price, v_payment_intent, v_kind, v_action,
    v_additional, v_currency, v_emergency, v_acceptance, v_custody, v_snapshot,
    v_actor, haulvia_command.optional_uuid(p_request, 'reauthSessionId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_record_id;
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'RECOVERY_ACTIVE',
    'startRecoveryLeg', p_request, v_new_execution,
    jsonb_build_object(
      'priorRouteExecutionId', v_execution.id,
      'recoveryRouteRecordId', v_record_id, 'recoveryActionCode', v_action
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'startRecoveryLeg', p_request,
    jsonb_build_object(
      'routeVersionId', v_prior_route, 'routeExecutionId', v_execution.id,
      'custodyBalance', v_custody
    ),
    jsonb_build_object(
      'routeVersionId', v_new_route, 'routeExecutionId', v_new_execution,
      'routeExecutionState', 'RECOVERY_ACTIVE', 'custodyBalance', v_custody
    ),
    jsonb_build_object(
      'recoveryRouteRecordId', v_record_id, 'priceSnapshotId', v_price,
      'additionalPaymentIntentId', v_payment_intent,
      'emergencyPaymentHoldId', v_payment_hold
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'RECOVERY_ROUTE_STARTED',
    p_request, 'recovery-route-' || v_record_id::text,
    jsonb_build_object(
      'recoveryRouteRecordId', v_record_id, 'recoveryActionCode', v_action,
      'additionalPaymentAmount', v_additional, 'currency', v_currency
    )
  );
  return jsonb_build_object(
    'recoveryRouteRecordId', v_record_id,
    'priorRouteVersionId', v_prior_route, 'routeVersionId', v_new_route,
    'priorRouteExecutionId', v_execution.id,
    'routeExecutionId', v_new_execution, 'routeExecutionVersion', 1,
    'routeExecutionState', 'RECOVERY_ACTIVE',
    'stopExecutionId', v_new_stop, 'stopAttemptId', v_new_attempt,
    'activeRouteLegId', v_new_leg, 'trackingSessionId', v_tracking,
    'priceSnapshotId', v_price, 'custodySummary', v_custody
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail('INVALID_REQUEST', 'Recovery request contains an invalid value');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- E11-E12: storage custody and verified return handoff
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_e11_secure_cargo_in_storage(
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
  v_manifest jsonb := p_request -> 'storageItems';
  v_location jsonb := p_request -> 'storageLocation';
  v_proof jsonb := p_request -> 'custodyProof';
  v_expenses jsonb := p_request -> 'expenseSnapshot';
  v_release jsonb := p_request -> 'releaseConditions';
  v_before_custody jsonb;
  v_after_custody jsonb;
  v_item jsonb;
  v_allocation haulvia.cargo_allocations%rowtype;
  v_quantity numeric;
  v_balance numeric;
  v_movement uuid;
  v_outcome uuid;
  v_movement_ids jsonb := '[]'::jsonb;
  v_outcome_ids jsonb := '[]'::jsonb;
  v_hold_id uuid;
  v_record_id uuid;
  v_review_count integer;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'secureCargoInStorage requires ROUTE_IN_PROGRESS');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'SHIPMENT_STATE_OVERRIDE', array['RECOVERY_WORKER', 'STORAGE_WORKER']
  );
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state not in ('ACTIVE', 'RECOVERY_ACTIVE') then
    perform haulvia_command.fail('INVALID_STATE', 'Storage intake requires an active current route');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state <> 'EVIDENCE_PENDING' or not exists (
    select 1 from haulvia.route_stops rs
    where rs.id = v_stop.route_stop_id and rs.route_version_id = v_stop.route_version_id
      and rs.stop_type = 'STORAGE'
  ) then
    perform haulvia_command.fail(
      'INVALID_STATE', 'Storage intake requires the current STORAGE stop in EVIDENCE_PENDING'
    );
  end if;
  select * into v_attempt from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
    and sa.state = 'EVIDENCE_PENDING' and sa.ended_at is null
  for update;
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'Storage stop has no active evidence-pending attempt');
  end if;
  if jsonb_typeof(v_manifest) <> 'array' or jsonb_array_length(v_manifest) = 0 then
    perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'storageItems must be a non-empty array');
  end if;
  if jsonb_typeof(v_location) <> 'object' or v_location = '{}'::jsonb
     or nullif(v_location ->> 'facilityName', '') is null
     or nullif(v_location ->> 'address', '') is null
     or nullif(v_location ->> 'accessAuthority', '') is null
     or jsonb_typeof(v_proof) <> 'object' or v_proof = '{}'::jsonb
     or not coalesce((v_proof ->> 'facilityAccepted')::boolean, false)
     or nullif(v_proof ->> 'capturedAt', '') is null
     or nullif(v_proof ->> 'condition', '') is null
     or jsonb_typeof(v_expenses) <> 'object' or v_expenses = '{}'::jsonb
     or jsonb_typeof(v_release) <> 'object' or v_release = '{}'::jsonb
     or nullif(v_release ->> 'verificationRequired', '') is null then
    perform haulvia_command.fail(
      'STORAGE_CUSTODY_INVALID',
      'Storage requires facility, condition, custody proof, expenses, access authority, and release conditions'
    );
  end if;
  v_before_custody := haulvia_command.assert_custody_snapshot(
    p_shipment.id, p_request -> 'custodyBalance'
  );
  perform haulvia_command.assert_positive_custody(p_shipment.id);
  perform haulvia_command.assert_stop_evidence(
    p_shipment.id, v_execution.route_version_id, v_stop.route_stop_id, v_attempt.id
  );
  v_review_count := haulvia_command.verify_stop_evidence_reviews(v_attempt.id, p_request);
  if v_review_count = 0 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Storage custody requires retained stop evidence');
  end if;

  for v_item in select value from jsonb_array_elements(v_manifest)
  loop
    select * into v_allocation from haulvia.cargo_allocations ca
    where ca.id = haulvia_command.required_uuid(v_item, 'cargoAllocationId')
      and ca.route_version_id = v_execution.route_version_id;
    if not found then
      perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Storage item is outside the current route');
    end if;
    v_quantity := haulvia_command.required_numeric(v_item, 'quantity');
    if v_quantity <= 0 or v_allocation.quantity_unit <> haulvia_command.required_text(v_item, 'quantityUnit') then
      perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Storage quantity or unit is invalid');
    end if;
    select coalesce(sum(
      case cm.movement_type
        when 'LOAD' then cm.quantity when 'TRANSFER_IN' then cm.quantity
        when 'STORAGE_OUT' then cm.quantity when 'UNLOAD' then -cm.quantity
        when 'TRANSFER_OUT' then -cm.quantity when 'STORAGE_IN' then -cm.quantity
      end
    ), 0) into v_balance
    from haulvia.cargo_movements cm
    join haulvia.cargo_allocations ca on ca.id = cm.cargo_allocation_id
      and ca.route_version_id = cm.route_version_id
    join haulvia.cargo_items ci on ci.id = ca.cargo_item_id
      and ci.route_version_id = ca.route_version_id
    where cm.shipment_id = p_shipment.id
      and ci.stable_cargo_key = (
        select current_ci.stable_cargo_key from haulvia.cargo_items current_ci
        where current_ci.id = v_allocation.cargo_item_id
      ) and cm.quantity_unit = v_allocation.quantity_unit;
    if v_quantity > v_balance then
      perform haulvia_command.fail(
        'CARGO_BALANCE_INVALID', 'Storage quantity cannot exceed the current onboard balance'
      );
    end if;
    insert into haulvia.cargo_movements (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, movement_type, quantity, quantity_unit,
      stop_attempt_id, evidence_bundle, occurred_at, recorded_by_profile_id,
      idempotency_key
    ) values (
      p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
      v_allocation.id, 'STORAGE_IN', v_quantity, v_allocation.quantity_unit,
      v_attempt.id, jsonb_build_object(
        'storageLocation', v_location, 'custodyProof', v_proof
      ), coalesce(nullif(v_proof ->> 'capturedAt', '')::timestamptz, clock_timestamp()),
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':storage-in:' || v_allocation.id::text
    ) returning id into v_movement;
    insert into haulvia.cargo_resolution_outcomes (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, cargo_movement_id, outcome_code, quantity,
      quantity_unit, approval_snapshot, approved_by_profile_id,
      occurred_at, idempotency_key
    ) values (
      p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
      v_allocation.id, v_movement, 'STORED', v_quantity, v_allocation.quantity_unit,
      jsonb_build_object(
        'storageLocation', v_location, 'releaseConditions', v_release,
        'expenseSnapshot', v_expenses
      ), haulvia_command.optional_uuid(p_request, 'actorProfileId'), clock_timestamp(),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':stored-outcome:' || v_allocation.id::text
    ) returning id into v_outcome;
    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement);
    v_outcome_ids := v_outcome_ids || jsonb_build_array(v_outcome);
  end loop;
  v_after_custody := haulvia_command.current_custody_summary(p_shipment.id);
  update haulvia.stop_executions
  set state = 'COMPLETED', completed_at = clock_timestamp(), state_changed_at = clock_timestamp()
  where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'COMPLETED', ended_at = clock_timestamp()
  where id = v_attempt.id;
  insert into haulvia.workflow_holds (
    shipment_id, route_execution_id, stop_execution_id, hold_code,
    status, blocks_marketplace, blocks_route_movement, blocks_completion,
    reason, opened_by_profile_id
  ) values (
    p_shipment.id, v_execution.id, v_stop.id, 'CARGO_IN_APPROVED_STORAGE',
    'ACTIVE', false, true, true,
    haulvia_command.required_text(p_request, 'reason'),
    haulvia_command.optional_uuid(p_request, 'actorProfileId')
  ) returning id into v_hold_id;
  update haulvia.route_executions
  set state = 'HELD', next_action = 'AWAIT_STORAGE_RELEASE_INSTRUCTION',
      record_version = record_version + 1
  where id = v_execution.id;
  insert into haulvia.storage_custody_records (
    shipment_id, route_execution_id, route_version_id, stop_execution_id,
    workflow_hold_id, storage_location_snapshot, cargo_manifest,
    custody_proof, expense_snapshot, responsible_party_code,
    release_conditions, resolution_deadline, secured_by_profile_id,
    secured_at, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
    v_hold_id, v_location, v_manifest, v_proof, v_expenses,
    haulvia_command.required_text(p_request, 'responsiblePartyCode'), v_release,
    nullif(p_request ->> 'resolutionDeadline', '')::timestamptz,
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    coalesce(nullif(v_proof ->> 'capturedAt', '')::timestamptz, clock_timestamp()),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_record_id;
  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'EVIDENCE_PENDING', 'COMPLETED',
    'secureCargoInStorage', p_request,
    jsonb_build_object(
      'storageCustodyRecordId', v_record_id, 'workflowHoldId', v_hold_id,
      'cargoMovementIds', v_movement_ids
    )
  );
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'WORKFLOW_HOLD', null, 'ACTIVE',
    'secureCargoInStorage', p_request, v_hold_id,
    jsonb_build_object('storageCustodyRecordId', v_record_id)
  );
  perform haulvia_command.append_audit(
    p_shipment, 'secureCargoInStorage', p_request,
    jsonb_build_object('custodyBalance', v_before_custody, 'stopState', 'EVIDENCE_PENDING'),
    jsonb_build_object('custodyBalance', v_after_custody, 'stopState', 'COMPLETED'),
    jsonb_build_object(
      'storageCustodyRecordId', v_record_id, 'workflowHoldId', v_hold_id,
      'cargoMovementIds', v_movement_ids, 'cargoOutcomeIds', v_outcome_ids
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'CARGO_SECURED_IN_STORAGE',
    p_request, 'storage-' || v_record_id::text,
    jsonb_build_object(
      'storageCustodyRecordId', v_record_id,
      'resolutionDeadline', p_request ->> 'resolutionDeadline'
    )
  );
  return jsonb_build_object(
    'storageCustodyRecordId', v_record_id, 'workflowHoldId', v_hold_id,
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'routeExecutionState', 'HELD', 'stopExecutionId', v_stop.id,
    'stopState', 'COMPLETED', 'cargoMovementIds', v_movement_ids,
    'cargoOutcomeIds', v_outcome_ids, 'custodySummary', v_after_custody
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail('STORAGE_CUSTODY_INVALID', 'Storage request contains an invalid value');
  return null;
end;
$$;

create or replace function haulvia_command.apply_e12_verify_return_handoff(
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
  v_manifest jsonb := p_request -> 'returnItems';
  v_evidence jsonb := p_request -> 'returnEvidenceSnapshot';
  v_mixed jsonb := p_request -> 'mixedOutcomeSnapshot';
  v_before_custody jsonb;
  v_after_custody jsonb;
  v_item jsonb;
  v_allocation haulvia.cargo_allocations%rowtype;
  v_quantity numeric;
  v_balance numeric;
  v_movement uuid;
  v_outcome uuid;
  v_movement_ids jsonb := '[]'::jsonb;
  v_outcome_ids jsonb := '[]'::jsonb;
  v_record_id uuid;
  v_terminal boolean;
  v_review_count integer;
begin
  if p_shipment.shipment_state <> 'ROUTE_IN_PROGRESS' then
    perform haulvia_command.fail('INVALID_STATE', 'verifyReturnHandoff requires ROUTE_IN_PROGRESS');
  end if;
  if haulvia_command.optional_uuid(p_request, 'actorProfileId') is null then
    perform haulvia_command.assert_worker(
      null, p_request ->> 'workerAuthority', array['EVIDENCE_REVIEWER', 'RETURN_VERIFICATION_WORKER']
    );
  else
    perform haulvia_command.authorize_evidence_reviewer(p_request);
  end if;
  v_assignment := haulvia_command.lock_active_assignment(p_shipment.id, p_request);
  perform haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_execution := haulvia_command.lock_route_execution(p_shipment.id, v_assignment.id, p_request);
  if v_execution.state not in ('ACTIVE', 'RECOVERY_ACTIVE') then
    perform haulvia_command.fail('INVALID_STATE', 'Return verification requires an active current route');
  end if;
  v_stop := haulvia_command.lock_current_stop_execution(v_execution, p_request, false);
  if v_stop.state <> 'EVIDENCE_PENDING' or not exists (
    select 1 from haulvia.route_stops rs
    where rs.id = v_stop.route_stop_id and rs.route_version_id = v_stop.route_version_id
      and rs.stop_type = 'RETURN'
  ) then
    perform haulvia_command.fail(
      'INVALID_STATE', 'Return handoff requires the current RETURN stop in EVIDENCE_PENDING'
    );
  end if;
  select * into v_attempt from haulvia.stop_attempts sa
  where sa.stop_execution_id = v_stop.id and sa.attempt_no = v_stop.current_attempt_no
    and sa.state = 'EVIDENCE_PENDING' and sa.ended_at is null
  for update;
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'Return stop has no active evidence-pending attempt');
  end if;
  if jsonb_typeof(v_manifest) <> 'array' or jsonb_array_length(v_manifest) = 0
     or jsonb_typeof(v_evidence) <> 'object' or v_evidence = '{}'::jsonb
     or not coalesce((v_evidence ->> 'senderAccepted')::boolean, false)
     or nullif(v_evidence ->> 'receiverLabel', '') is null
     or nullif(v_evidence ->> 'capturedAt', '') is null
     or jsonb_typeof(v_mixed) <> 'object' or v_mixed = '{}'::jsonb then
    perform haulvia_command.fail(
      'RETURN_HANDOFF_INVALID',
      'Return handoff requires cargo, verified receiver evidence, and mixed-outcome disclosure'
    );
  end if;
  v_before_custody := haulvia_command.assert_custody_snapshot(
    p_shipment.id, p_request -> 'custodyBalance'
  );
  perform haulvia_command.assert_positive_custody(p_shipment.id);
  perform haulvia_command.assert_stop_evidence(
    p_shipment.id, v_execution.route_version_id, v_stop.route_stop_id, v_attempt.id
  );
  v_review_count := haulvia_command.verify_stop_evidence_reviews(v_attempt.id, p_request);
  if v_review_count = 0 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Return handoff requires retained stop evidence');
  end if;

  for v_item in select value from jsonb_array_elements(v_manifest)
  loop
    select * into v_allocation from haulvia.cargo_allocations ca
    where ca.id = haulvia_command.required_uuid(v_item, 'cargoAllocationId')
      and ca.route_version_id = v_execution.route_version_id;
    if not found then
      perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Return item is outside the current route');
    end if;
    v_quantity := haulvia_command.required_numeric(v_item, 'quantity');
    if v_quantity <= 0 or v_allocation.quantity_unit <> haulvia_command.required_text(v_item, 'quantityUnit') then
      perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Return quantity or unit is invalid');
    end if;
    select coalesce(sum(
      case cm.movement_type
        when 'LOAD' then cm.quantity when 'TRANSFER_IN' then cm.quantity
        when 'STORAGE_OUT' then cm.quantity when 'UNLOAD' then -cm.quantity
        when 'TRANSFER_OUT' then -cm.quantity when 'STORAGE_IN' then -cm.quantity
      end
    ), 0) into v_balance
    from haulvia.cargo_movements cm
    join haulvia.cargo_allocations ca on ca.id = cm.cargo_allocation_id
      and ca.route_version_id = cm.route_version_id
    join haulvia.cargo_items ci on ci.id = ca.cargo_item_id
      and ci.route_version_id = ca.route_version_id
    where cm.shipment_id = p_shipment.id
      and ci.stable_cargo_key = (
        select current_ci.stable_cargo_key from haulvia.cargo_items current_ci
        where current_ci.id = v_allocation.cargo_item_id
      ) and cm.quantity_unit = v_allocation.quantity_unit;
    if v_quantity > v_balance then
      perform haulvia_command.fail(
        'CARGO_BALANCE_INVALID', 'Return quantity cannot exceed current onboard custody'
      );
    end if;
    insert into haulvia.cargo_movements (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, movement_type, quantity, quantity_unit,
      stop_attempt_id, evidence_bundle, occurred_at, recorded_by_profile_id,
      idempotency_key
    ) values (
      p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
      v_allocation.id, 'UNLOAD', v_quantity, v_allocation.quantity_unit,
      v_attempt.id, v_evidence,
      coalesce(nullif(v_evidence ->> 'capturedAt', '')::timestamptz, clock_timestamp()),
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':return-unload:' || v_allocation.id::text
    ) returning id into v_movement;
    insert into haulvia.cargo_resolution_outcomes (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, cargo_movement_id, outcome_code, quantity,
      quantity_unit, approval_snapshot, approved_by_profile_id,
      occurred_at, idempotency_key
    ) values (
      p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
      v_allocation.id, v_movement, 'RETURNED', v_quantity, v_allocation.quantity_unit,
      jsonb_build_object(
        'returnEvidenceSnapshot', v_evidence,
        'mixedOutcomeSnapshot', v_mixed
      ), haulvia_command.optional_uuid(p_request, 'actorProfileId'), clock_timestamp(),
      haulvia_command.required_text(p_request, 'idempotencyKey') || ':returned-outcome:' || v_allocation.id::text
    ) returning id into v_outcome;
    v_movement_ids := v_movement_ids || jsonb_build_array(v_movement);
    v_outcome_ids := v_outcome_ids || jsonb_build_array(v_outcome);
  end loop;
  v_after_custody := haulvia_command.current_custody_summary(p_shipment.id);
  v_terminal := not exists (
    select 1 from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id = p_shipment.id and cb.onboard_quantity <> 0
  );
  update haulvia.stop_executions
  set state = 'COMPLETED', completed_at = clock_timestamp(), state_changed_at = clock_timestamp()
  where id = v_stop.id;
  update haulvia.stop_attempts
  set state = 'COMPLETED', ended_at = clock_timestamp()
  where id = v_attempt.id;

  if v_terminal then
    update haulvia.stop_attempts sa
    set state = 'CANCELLED', ended_at = coalesce(ended_at, clock_timestamp())
    where sa.stop_execution_id in (
      select se.id from haulvia.stop_executions se
      where se.shipment_id = p_shipment.id and se.id <> v_stop.id
        and se.state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED')
    ) and sa.ended_at is null;
    update haulvia.stop_executions set state = 'CANCELLED'
    where shipment_id = p_shipment.id and id <> v_stop.id
      and state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED');
    update haulvia.route_executions
    set state = 'COMPLETED', completed_at = clock_timestamp(),
        active_stop_execution_id = null, active_route_leg_id = null,
        next_action = 'NONE', record_version = record_version + 1
    where id = v_execution.id;
    update haulvia.tracking_sessions set ended_at = clock_timestamp()
    where route_execution_id = v_execution.id and ended_at is null;
    update haulvia.assignments
    set status = 'COMPLETED', ended_at = clock_timestamp(),
        end_reason = 'ALL_CARGO_RETURNED_TO_SENDER'
    where id = v_assignment.id;
    update haulvia.route_versions set status = 'FROZEN' where id = v_execution.route_version_id;
    update haulvia.shipments set shipment_state = 'RETURNED_TO_SENDER' where id = p_shipment.id;
  else
    update haulvia.route_executions
    set next_action = 'RESOLVE_REMAINING_CARGO', record_version = record_version + 1
    where id = v_execution.id;
    update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  end if;
  insert into haulvia.return_handoff_records (
    shipment_id, route_execution_id, route_version_id, stop_execution_id,
    stop_attempt_id, terminal_return, cargo_manifest, movement_ids,
    evidence_snapshot, custody_reconciliation, mixed_outcome_snapshot,
    verified_by_profile_id, verified_at, idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_execution.route_version_id, v_stop.id,
    v_attempt.id, v_terminal, v_manifest, v_movement_ids, v_evidence,
    jsonb_build_object('before', v_before_custody, 'after', v_after_custody),
    v_mixed, haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    coalesce(nullif(v_evidence ->> 'capturedAt', '')::timestamptz, clock_timestamp()),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_record_id;
  perform haulvia_command.append_stop_event(
    v_attempt.id, v_stop.id, 'EVIDENCE_PENDING', 'COMPLETED',
    'verifyReturnHandoff', p_request,
    jsonb_build_object(
      'returnHandoffRecordId', v_record_id, 'terminalReturn', v_terminal,
      'cargoMovementIds', v_movement_ids
    )
  );
  if v_terminal then
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'ROUTE_EXECUTION', v_execution.state::text, 'COMPLETED',
      'verifyReturnHandoff', p_request, v_execution.id,
      jsonb_build_object('returnHandoffRecordId', v_record_id)
    );
    perform haulvia_command.append_shipment_event(
      p_shipment.id, 'ROUTE_IN_PROGRESS', 'RETURNED_TO_SENDER',
      'verifyReturnHandoff', p_request, v_execution.route_version_id,
      jsonb_build_object('returnHandoffRecordId', v_record_id)
    );
  end if;
  perform haulvia_command.append_audit(
    p_shipment, 'verifyReturnHandoff', p_request,
    jsonb_build_object('shipmentState', 'ROUTE_IN_PROGRESS', 'custodyBalance', v_before_custody),
    jsonb_build_object(
      'shipmentState', case when v_terminal then 'RETURNED_TO_SENDER' else 'ROUTE_IN_PROGRESS' end,
      'custodyBalance', v_after_custody
    ),
    jsonb_build_object(
      'returnHandoffRecordId', v_record_id, 'terminalReturn', v_terminal,
      'cargoMovementIds', v_movement_ids, 'cargoOutcomeIds', v_outcome_ids
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id,
    case when v_terminal then 'SHIPMENT_RETURNED_TO_SENDER' else 'PARTIAL_RETURN_HANDOFF_VERIFIED' end,
    p_request, 'return-handoff-' || v_record_id::text,
    jsonb_build_object('returnHandoffRecordId', v_record_id, 'terminalReturn', v_terminal)
  );
  return jsonb_build_object(
    'returnHandoffRecordId', v_record_id,
    'shipmentState', case when v_terminal then 'RETURNED_TO_SENDER' else 'ROUTE_IN_PROGRESS' end,
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1,
    'terminalReturn', v_terminal, 'stopExecutionId', v_stop.id,
    'stopState', 'COMPLETED', 'cargoMovementIds', v_movement_ids,
    'cargoOutcomeIds', v_outcome_ids, 'custodySummary', v_after_custody
  );
exception when invalid_text_representation or numeric_value_out_of_range then
  perform haulvia_command.fail('RETURN_HANDOFF_INVALID', 'Return request contains an invalid value');
  return null;
end;
$$;

-- Re-apply the execution boundary after every helper/handler has been created.
-- Block E is intentionally ordered around its policy groups, so this final pass
-- is the authoritative privilege state.
revoke all on all functions in schema haulvia_command from public;

do $$
declare
  v_signature text;
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema haulvia_command to service_role;
    execute 'revoke execute on all functions in schema haulvia_command from service_role';
    for v_signature in
      select format(
        '%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)
      )
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'haulvia_command' and left(p.proname, 8) = 'command_'
      order by p.proname, p.oid
    loop
      execute 'grant execute on function ' || v_signature || ' to service_role';
    end loop;
  end if;
end;
$$;

commit;
