-- Haulvia Block E command acceptance suite v1
-- Requires foundation v1 plus Blocks A, B, C, D, and E.
-- Pure PostgreSQL, no pgTAP dependency. All fixtures are rolled back.

begin;
set local search_path = haulvia, haulvia_command, public;

create or replace function pg_temp.assert_true(p_condition boolean, p_message text)
returns void language plpgsql as $$
begin
  if p_condition is distinct from true then
    raise exception 'ASSERT_TRUE failed: %', p_message;
  end if;
end;
$$;

create or replace function pg_temp.expect_error_code(p_sql text, p_code text, p_message text)
returns void language plpgsql as $$
declare
  v_detail text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
    if coalesce(v_detail, '') like '%"code": "' || p_code || '"%' then
      return;
    end if;
    raise exception 'EXPECT_ERROR failed (%): expected %, got detail %, message %',
      p_message, p_code, v_detail, sqlerrm;
  end;
  raise exception 'EXPECT_ERROR failed (%): statement succeeded', p_message;
end;
$$;

create or replace function pg_temp.envelope(
  p_shipment_id uuid, p_actor_profile_id uuid, p_key text, p_hash_character text
)
returns jsonb language sql as $$
  select jsonb_build_object(
    'commandId', gen_random_uuid(),
    'idempotencyKey', p_key,
    'requestHash', repeat(p_hash_character, 64),
    'actorProfileId', p_actor_profile_id,
    'shipmentId', p_shipment_id,
    'expectedShipmentVersion', s.lock_version,
    'requestedAt', clock_timestamp()
  )
  from haulvia.shipments s where s.id = p_shipment_id;
$$;

-- Shared customer, two eligible providers, policy, pricing, and fresh-admin fixtures.
do $$
declare
  v_customer_org uuid := 'e1000000-0000-0000-0000-000000000001';
  v_customer uuid := 'e1000000-0000-0000-0000-000000000002';
  v_provider_org_1 uuid := 'e2000000-0000-0000-0000-000000000001';
  v_driver_profile_1 uuid := 'e2000000-0000-0000-0000-000000000002';
  v_provider_1 uuid := 'e2000000-0000-0000-0000-000000000003';
  v_driver_1 uuid := 'e2000000-0000-0000-0000-000000000004';
  v_vehicle_1 uuid := 'e2000000-0000-0000-0000-000000000005';
  v_provider_org_2 uuid := 'e2100000-0000-0000-0000-000000000001';
  v_driver_profile_2 uuid := 'e2100000-0000-0000-0000-000000000002';
  v_provider_2 uuid := 'e2100000-0000-0000-0000-000000000003';
  v_driver_2 uuid := 'e2100000-0000-0000-0000-000000000004';
  v_vehicle_2 uuid := 'e2100000-0000-0000-0000-000000000005';
  v_admin_org uuid := 'e3000000-0000-0000-0000-000000000001';
  v_admin uuid := 'e3000000-0000-0000-0000-000000000002';
  v_role uuid := 'e3000000-0000-0000-0000-000000000003';
  v_membership uuid;
  v_policy_set uuid := 'e4000000-0000-0000-0000-000000000001';
  v_policy uuid := 'e4000000-0000-0000-0000-000000000002';
  v_pricing_set uuid := 'e5000000-0000-0000-0000-000000000001';
  v_pricing_version uuid := 'e5000000-0000-0000-0000-000000000002';
begin
  insert into organizations(id, organization_key, kind, legal_name, display_name) values
    (v_customer_org, 'block-e-customer', 'CUSTOMER', 'Block E Customer Ltd.', 'Block E Customer'),
    (v_provider_org_1, 'block-e-provider-one', 'INDEPENDENT_PROVIDER', 'Block E Driver One Ltd.', 'Driver One'),
    (v_provider_org_2, 'block-e-provider-two', 'INDEPENDENT_PROVIDER', 'Block E Driver Two Ltd.', 'Driver Two'),
    (v_admin_org, 'block-e-haulvia', 'HAULVIA', 'Haulvia Block E Admin', 'Haulvia Admin');
  insert into profiles(id, display_name) values
    (v_customer, 'Block E Customer'),
    (v_driver_profile_1, 'Block E Assigned Driver'),
    (v_driver_profile_2, 'Block E Replacement Driver'),
    (v_admin, 'Block E Operations Administrator');
  insert into organization_memberships(organization_id, profile_id, status) values
    (v_customer_org, v_customer, 'ACTIVE'),
    (v_provider_org_1, v_driver_profile_1, 'ACTIVE'),
    (v_provider_org_2, v_driver_profile_2, 'ACTIVE');
  insert into organization_memberships(organization_id, profile_id, status)
  values (v_admin_org, v_admin, 'ACTIVE') returning id into v_membership;
  insert into roles(id, role_key, name, description)
  values (v_role, 'BLOCK_E_ADMIN', 'Block E administrator', 'Acceptance-only recovery and dispute role');
  insert into role_permissions(role_id, permission_id)
  select v_role, p.id from permissions p
  where p.permission_key in (
    'SHIPMENT_STATE_OVERRIDE', 'CUSTODY_TRANSFER_AUTHORIZE',
    'DISPUTE_RESOLVE', 'ROUTE_OPERATIONS_MANAGE', 'STOP_EVIDENCE_REVIEW'
  );
  insert into membership_roles(membership_id, role_id, granted_by_profile_id)
  values (v_membership, v_role, v_admin);
  insert into reauth_sessions(
    id, profile_id, organization_id, method, verified_at, expires_at, provider_reference
  ) values (
    'e3000000-0000-0000-0000-000000000004', v_admin, v_admin_org, 'MFA',
    clock_timestamp() - interval '1 minute', clock_timestamp() + interval '30 minutes',
    'block-e-fresh-auth'
  );

  insert into service_providers(id, organization_id, kind, status, approved_at) values
    (v_provider_1, v_provider_org_1, 'INDEPENDENT_DRIVER', 'ACTIVE', clock_timestamp()),
    (v_provider_2, v_provider_org_2, 'INDEPENDENT_DRIVER', 'ACTIVE', clock_timestamp());
  insert into drivers(id, profile_id, status, public_label) values
    (v_driver_1, v_driver_profile_1, 'ACTIVE', 'Block E Driver One'),
    (v_driver_2, v_driver_profile_2, 'ACTIVE', 'Block E Driver Two');
  insert into provider_drivers(provider_id, driver_id, status) values
    (v_provider_1, v_driver_1, 'ACTIVE'),
    (v_provider_2, v_driver_2, 'ACTIVE');
  insert into vehicles(
    id, provider_id, vehicle_key, status, vehicle_class, capacity_weight_kg
  ) values
    (v_vehicle_1, v_provider_1, 'block-e-van-one', 'ACTIVE', 'CARGO_VAN', 1000),
    (v_vehicle_2, v_provider_2, 'block-e-van-two', 'ACTIVE', 'CARGO_VAN', 1000);

  insert into policy_sets(id, policy_key, name)
  values (v_policy_set, 'BLOCK_E_POLICY', 'Block E test policy');
  insert into policy_versions(
    id, policy_set_id, version_no, publication_status, effective_from, config,
    config_sha256, legal_review_required, created_by_profile_id,
    approved_by_profile_id, approved_at
  ) values (
    v_policy, v_policy_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object(
      'evidenceRequirements', jsonb_build_object('photo', true),
      'cancellationRules', jsonb_build_object('preCustody', 'versioned'),
      'refundRules', jsonb_build_object('originalMethod', true),
      'timingWindows', jsonb_build_object('etaNotificationThresholdSeconds', 60),
      'riskRules', jsonb_build_object('recovery', 'explicit')
    ), repeat('e', 64), false, v_admin, v_admin, clock_timestamp()
  );
  insert into pricing_rule_sets(
    id, rule_key, name, pricing_source, service_level, currency
  ) values (
    v_pricing_set, 'BLOCK_E_FLEX_GUARD', 'Block E Flex guardrail',
    'HAULVIA_GUARDRAIL', 'FLEX', 'CAD'
  );
  insert into pricing_rule_versions(
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values (
    v_pricing_version, v_pricing_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object('floorAmount', 0, 'ceilingAmount', 500, 'absoluteCapAmount', 1000),
    repeat('5', 64), v_admin, v_admin, clock_timestamp()
  );
end;
$$;


-- A two-stop immutable route fixture. The returned identifiers are used to
-- seed assignment/execution facts directly so each command gets one concern.
create or replace function pg_temp.seed_route(
  p_label text,
  p_shipment_state haulvia.shipment_state,
  p_second_stop_type haulvia.stop_type default 'DELIVERY',
  p_activate boolean default true,
  p_deadline timestamptz default null
)
returns jsonb language plpgsql as $$
declare
  v_customer_org uuid := 'e1000000-0000-0000-0000-000000000001';
  v_customer uuid := 'e1000000-0000-0000-0000-000000000002';
  v_policy uuid := 'e4000000-0000-0000-0000-000000000002';
  v_rule uuid := 'e5000000-0000-0000-0000-000000000002';
  v_shipment uuid;
  v_route uuid := gen_random_uuid();
  v_pickup uuid := gen_random_uuid();
  v_endpoint uuid := gen_random_uuid();
  v_pickup_key uuid := gen_random_uuid();
  v_endpoint_key uuid := gen_random_uuid();
  v_leg uuid := gen_random_uuid();
  v_cargo uuid := gen_random_uuid();
  v_cargo_key uuid := gen_random_uuid();
  v_allocation uuid := gen_random_uuid();
  v_review uuid;
  v_price uuid;
  v_payment uuid;
begin
  insert into shipments(
    customer_organization_id, customer_profile_id, shipment_state,
    pickup_timing, service_level, currency, marketplace_deadline, terminal_at
  ) values (
    v_customer_org, v_customer, p_shipment_state, 'ASAP', 'FLEX', 'CAD', p_deadline,
    case when p_shipment_state in ('COMPLETED','CANCELLED','EXPIRED','RETURNED_TO_SENDER')
      then clock_timestamp() else null end
  ) returning id into v_shipment;
  update shipment_marketplace_axes
  set state = case
    when p_shipment_state in ('POSTED','NEGOTIATING') then 'ACTIVE'::haulvia.marketplace_state
    when p_shipment_state = 'DRIVER_ASSIGNED' then 'RESERVED'::haulvia.marketplace_state
    else 'CLOSED'::haulvia.marketplace_state end
  where shipment_id = v_shipment;
  if p_shipment_state in ('DRIVER_ASSIGNED','ROUTE_IN_PROGRESS','DELIVERED','COMPLETED') then
    update shipment_customer_payment_axes
    set state = 'SECURED', secured_amount = 100 where shipment_id = v_shipment;
  end if;

  insert into route_versions(
    id, shipment_id, version_no, status, change_reason,
    planned_distance_km, planned_duration_seconds, created_by_profile_id
  ) values (
    v_route, v_shipment, 1, 'DRAFT', 'Block E fixture ' || p_label,
    25, 1800, v_customer
  );
  insert into route_stops(
    id, route_version_id, stable_stop_key, sequence_no, stop_type,
    address_line1, city, region_code, country_code, latitude, longitude,
    geofence_radius_m, planned_service_seconds, verification_profile
  ) values
    (v_pickup, v_route, v_pickup_key, 1, 'PICKUP', '100 Origin Road',
     'Saskatoon', 'SK', 'CA', 52.1332, -106.6700, 200, 300,
     jsonb_build_object('photo', true)),
    (v_endpoint, v_route, v_endpoint_key, 2, p_second_stop_type, '200 Endpoint Road',
     'Regina', 'SK', 'CA', 50.4452, -104.6189, 200, 300,
     jsonb_build_object('photo', true));
  insert into route_legs(
    id, route_version_id, sequence_no, from_stop_id, to_stop_id,
    planned_distance_km, planned_duration_seconds
  ) values (v_leg, v_route, 1, v_pickup, v_endpoint, 25, 1800);
  insert into cargo_items(
    id, route_version_id, stable_cargo_key, cargo_line_no, description,
    quantity, quantity_unit, total_weight_kg, declared_value, currency
  ) values (v_cargo, v_route, v_cargo_key, 1, 'Block E cargo', 1, 'piece', 10, 100, 'CAD');
  insert into cargo_allocations(
    id, route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id,
    quantity, quantity_unit
  ) values (v_allocation, v_route, v_cargo, v_pickup, v_endpoint, 1, 'piece');

  if p_activate then
    update route_versions set status = 'ACTIVE' where id = v_route;
    insert into shipment_rule_snapshots(
      shipment_id, route_version_id, policy_version_id, evidence_requirements,
      cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
    ) values (
      v_shipment, v_route, v_policy, jsonb_build_object('photo', true),
      jsonb_build_object('preCustody', 'versioned'),
      jsonb_build_object('originalMethod', true),
      jsonb_build_object('etaNotificationThresholdSeconds', 60),
      jsonb_build_object('recovery', 'explicit'), repeat('e', 64)
    );
    insert into pricing_reviews(
      shipment_id, route_version_id, pricing_source, pricing_mode,
      status, reviewed_amount, currency, reviewed_at
    ) values (
      v_shipment, v_route, 'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE',
      'PASSED', 100, 'CAD', clock_timestamp()
    ) returning id into v_review;
    insert into shipment_price_snapshots(
      shipment_id, route_version_id, purpose, pricing_source, pricing_mode,
      pricing_rule_version_id, pricing_review_id, subtotal, tax_amount,
      total_amount, currency, breakdown, snapshot_sha256, accepted_at
    ) values (
      v_shipment, v_route, 'ASSIGNMENT', 'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE',
      v_rule, v_review, 100, 0, 100, 'CAD',
      jsonb_build_array(jsonb_build_object('component', 'ROUTE', 'amount', 100)),
      repeat('f', 64), clock_timestamp()
    ) returning id into v_price;
    insert into payment_intents(
      shipment_id, status, amount, currency, external_provider,
      external_reference, provider_idempotency_key, secured_at
    ) values (
      v_shipment, 'SECURED', 100, 'CAD', 'block-e-payments',
      'payment-' || p_label, 'fund-' || p_label, clock_timestamp()
    ) returning id into v_payment;
  end if;
  return jsonb_build_object(
    'shipmentId', v_shipment, 'routeVersionId', v_route,
    'pickupStopId', v_pickup, 'endpointStopId', v_endpoint,
    'pickupStableKey', v_pickup_key, 'endpointStableKey', v_endpoint_key,
    'routeLegId', v_leg, 'cargoItemId', v_cargo,
    'cargoStableKey', v_cargo_key, 'cargoAllocationId', v_allocation,
    'priceSnapshotId', v_price, 'paymentIntentId', v_payment
  );
end;
$$;

create or replace function pg_temp.seed_execution(
  p_label text,
  p_current_sequence integer,
  p_current_state haulvia.stop_state,
  p_second_stop_type haulvia.stop_type default 'DELIVERY',
  p_with_custody boolean default false,
  p_with_failure_report boolean default false
)
returns jsonb language plpgsql as $$
declare
  v_f jsonb := pg_temp.seed_route(p_label, 'ROUTE_IN_PROGRESS', p_second_stop_type, true);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_pickup uuid := (v_f ->> 'pickupStopId')::uuid;
  v_endpoint uuid := (v_f ->> 'endpointStopId')::uuid;
  v_leg uuid := (v_f ->> 'routeLegId')::uuid;
  v_allocation uuid := (v_f ->> 'cargoAllocationId')::uuid;
  v_provider uuid := 'e2000000-0000-0000-0000-000000000003';
  v_driver uuid := 'e2000000-0000-0000-0000-000000000004';
  v_vehicle uuid := 'e2000000-0000-0000-0000-000000000005';
  v_assignment uuid;
  v_execution uuid;
  v_pickup_execution uuid := gen_random_uuid();
  v_endpoint_execution uuid := gen_random_uuid();
  v_current_execution uuid;
  v_current_attempt uuid;
  v_pickup_attempt uuid;
  v_load uuid;
  v_exception uuid;
  v_report uuid;
  v_custody jsonb;
  v_evidence_type haulvia.evidence_type;
begin
  insert into assignments(
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    price_snapshot_id, status, agreement_snapshot
  ) values (
    v_shipment, v_route, v_provider, v_driver, v_vehicle,
    (v_f ->> 'priceSnapshotId')::uuid, 'ACTIVE', jsonb_build_object('fixture', p_label)
  ) returning id into v_assignment;
  insert into route_executions(
    shipment_id, route_version_id, assignment_id, execution_kind, state,
    started_at, active_stop_execution_id, active_route_leg_id, next_action, record_version
  ) values (
    v_shipment, v_route, v_assignment, 'PRIMARY', 'ACTIVE', clock_timestamp(),
    null, null, 'FIXTURE_SETUP', 0
  ) returning id into v_execution;
  insert into stop_executions(
    id, shipment_id, route_execution_id, route_version_id, route_stop_id,
    state, current_attempt_no, completed_at
  ) values
    (v_pickup_execution, v_shipment, v_execution, v_route, v_pickup,
     case when p_current_sequence = 1 then p_current_state else 'COMPLETED' end,
     1, case when p_current_sequence = 1 and p_current_state <> 'COMPLETED'
       then null else clock_timestamp() end),
    (v_endpoint_execution, v_shipment, v_execution, v_route, v_endpoint,
     case when p_current_sequence = 2 then p_current_state else 'PENDING' end,
     case when p_current_sequence = 2 then 1 else 0 end,
     case when p_current_sequence = 2 and p_current_state = 'COMPLETED'
       then clock_timestamp() else null end);
  v_current_execution := case when p_current_sequence = 1
    then v_pickup_execution else v_endpoint_execution end;
  update route_executions
  set active_stop_execution_id = v_current_execution,
      active_route_leg_id = v_leg,
      next_action = case p_current_state
        when 'FAILED' then 'AWAIT_FAILED_STOP_DECISION'
        when 'EVIDENCE_PENDING' then 'VERIFY_STOP_EVIDENCE'
        when 'EXCEPTION_REVIEW' then 'AWAIT_EXCEPTION_RESOLUTION'
        else 'CONTINUE_ROUTE' end
  where id = v_execution;
  insert into tracking_sessions(route_execution_id, driver_id, started_at)
  values (v_execution, v_driver, clock_timestamp());

  if p_current_sequence = 2 then
    insert into stop_attempts(
      id, stop_execution_id, attempt_no, state, arrived_at,
      service_started_at, evidence_submitted_at, ended_at
    ) values (
      gen_random_uuid(), v_pickup_execution, 1, 'COMPLETED',
      clock_timestamp(), clock_timestamp(), clock_timestamp(), clock_timestamp()
    ) returning id into v_pickup_attempt;
  end if;
  insert into stop_attempts(
    stop_execution_id, attempt_no, state, arrived_at,
    service_started_at, evidence_submitted_at, ended_at,
    responsibility_code, failure_reason
  ) values (
    v_current_execution, 1, p_current_state,
    case when p_current_state <> 'PENDING' then clock_timestamp() end,
    case when p_current_state in ('SERVICE_IN_PROGRESS','EVIDENCE_PENDING','FAILED','EXCEPTION_REVIEW')
      then clock_timestamp() end,
    case when p_current_state = 'EVIDENCE_PENDING' then clock_timestamp() end,
    case when p_current_state = 'FAILED' then clock_timestamp() end,
    case when p_current_state = 'FAILED' then 'FIXTURE' end,
    case when p_current_state = 'FAILED' then 'Acceptance fixture failed stop' end
  ) returning id into v_current_attempt;

  if p_current_state = 'EVIDENCE_PENDING' then
    foreach v_evidence_type in array array[
      'GPS'::haulvia.evidence_type, 'TIMESTAMP'::haulvia.evidence_type,
      'PHOTO'::haulvia.evidence_type, 'QUANTITY'::haulvia.evidence_type
    ] loop
      insert into stop_evidence(
        stop_attempt_id, evidence_type, storage_object_key, structured_value,
        captured_at, captured_latitude, captured_longitude, idempotency_key
      ) values (
        v_current_attempt, v_evidence_type,
        case when v_evidence_type = 'PHOTO' then p_label || '/photo.jpg' end,
        case when v_evidence_type = 'PHOTO' then '{}'::jsonb
          else jsonb_build_object('verified', true) end,
        clock_timestamp(), 50.4452, -104.6189,
        p_label || ':evidence:' || v_evidence_type::text
      );
    end loop;
  end if;

  if p_with_custody then
    if v_pickup_attempt is null then
      insert into stop_attempts(
        stop_execution_id, attempt_no, state, arrived_at,
        service_started_at, evidence_submitted_at, ended_at
      ) values (
        v_pickup_execution, 2, 'COMPLETED', clock_timestamp(),
        clock_timestamp(), clock_timestamp(), clock_timestamp()
      ) returning id into v_pickup_attempt;
    end if;
    insert into cargo_movements(
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, movement_type, quantity, quantity_unit,
      stop_attempt_id, evidence_bundle, occurred_at, recorded_by_profile_id,
      idempotency_key
    ) values (
      v_shipment, v_execution, v_route, v_pickup_execution, v_allocation,
      'LOAD', 1, 'piece', v_pickup_attempt,
      jsonb_build_object('fixture', p_label), clock_timestamp(),
      'e2000000-0000-0000-0000-000000000002', p_label || ':load'
    ) returning id into v_load;
    insert into shipment_custody_milestones(
      shipment_id, route_execution_id, first_stop_execution_id,
      first_cargo_movement_id, first_custody_at, metadata
    ) values (
      v_shipment, v_execution, v_pickup_execution, v_load,
      clock_timestamp(), jsonb_build_object('fixture', p_label)
    );
  end if;
  v_custody := haulvia_command.current_custody_summary(v_shipment);

  if p_current_state = 'FAILED' then
    insert into route_exceptions(
      shipment_id, route_execution_id, stop_execution_id, exception_code,
      status, responsibility_code, blocks_completion, description,
      opened_by_profile_id
    ) values (
      v_shipment, v_execution, v_current_execution, 'STOP_FAILED',
      'OPEN', 'FIXTURE', true, 'Acceptance fixture route exception',
      'e2000000-0000-0000-0000-000000000002'
    ) returning id into v_exception;
    if p_with_failure_report then
      insert into stop_failure_reports(
        shipment_id, route_execution_id, route_version_id, stop_execution_id,
        stop_attempt_id, route_exception_id, command_name, reported_stop_state,
        responsibility_code, failure_reason, affected_cargo,
        custody_balance_snapshot, downstream_impact, approved_next_route_decision,
        grace_period_ended_at, reported_by_profile_id, idempotency_key
      ) values (
        v_shipment, v_execution, v_route, v_current_execution,
        v_current_attempt, v_exception,
        case when p_current_sequence = 1 then 'reportFailedPickupStop'
          else 'reportFailedDeliveryStop' end,
        'FAILED', 'FIXTURE', 'Acceptance fixture failure has been finalized',
        jsonb_build_array(jsonb_build_object(
          'cargoAllocationId', v_allocation, 'quantity', 1, 'quantityUnit', 'piece'
        )), v_custody, jsonb_build_object('routeCanContinue', true),
        jsonb_build_object('decisionCode', 'SKIP', 'approved', true),
        clock_timestamp() - interval '1 minute',
        'e2000000-0000-0000-0000-000000000002', p_label || ':failure-report'
      ) returning id into v_report;
    end if;
  end if;
  return v_f || jsonb_build_object(
    'assignmentId', v_assignment, 'routeExecutionId', v_execution,
    'routeExecutionVersion', 0, 'pickupStopExecutionId', v_pickup_execution,
    'endpointStopExecutionId', v_endpoint_execution,
    'currentStopExecutionId', v_current_execution,
    'currentStopAttemptId', v_current_attempt,
    'routeExceptionId', v_exception, 'stopFailureReportId', v_report,
    'custodyBalance', v_custody
  );
end;
$$;
-- E01 and E16: cancellation is terminal and replay-safe; reposting copies into
-- a distinct linked draft without touching the source shipment or route.
do $$
declare
  v_f jsonb := pg_temp.seed_route('e01-e16', 'DRAFT', 'DELIVERY', false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_customer uuid := 'e1000000-0000-0000-0000-000000000002';
  v_cancel_request jsonb;
  v_cancelled jsonb;
  v_replay jsonb;
  v_copy_request jsonb;
  v_copied jsonb;
  v_new_shipment uuid;
  v_new_route uuid;
begin
  v_cancel_request := pg_temp.envelope(v_shipment, v_customer, 'e01-cancel', '1') ||
    jsonb_build_object(
      'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
      'reason', 'Customer abandoned the unposted draft',
      'cancellationSnapshot', jsonb_build_object('displayedState', 'DRAFT')
    );
  select haulvia_command.command_cancel_draft(v_cancel_request) into v_cancelled;
  select haulvia_command.command_cancel_draft(v_cancel_request) into v_replay;
  perform pg_temp.assert_true(
    (v_cancelled - 'replayed') = (v_replay - 'replayed')
    and (v_cancelled ->> 'replayed')::boolean is false
    and (v_replay ->> 'replayed')::boolean is true
    and v_cancelled ->> 'shipmentState' = 'CANCELLED'
    and (select count(*) = 1 from shipment_cancellation_snapshots where shipment_id = v_shipment),
    'E01 makes one terminal cancellation fact and exact idempotent replay'
  );

  v_copy_request := pg_temp.envelope(v_shipment, v_customer, 'e16-copy', '2') ||
    jsonb_build_object(
      'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId', v_route,
      'reason', 'Customer chose to repost the cancelled route as a new draft',
      'eligibilitySnapshot', jsonb_build_object(
        'terminalStateVerified', true, 'customerConfirmed', true,
        'requiresFreshPricing', true, 'requiresFreshPolicySnapshot', true
      )
    );
  select haulvia_command.command_copy_terminal_shipment_for_repost(v_copy_request) into v_copied;
  v_new_shipment := (v_copied ->> 'newShipmentId')::uuid;
  v_new_route := (v_copied ->> 'newRouteVersionId')::uuid;
  perform pg_temp.assert_true(
    v_new_shipment <> v_shipment and v_new_route <> v_route
    and (select shipment_state = 'CANCELLED' from shipments where id = v_shipment)
    and (select shipment_state = 'DRAFT' and source_shipment_id = v_shipment
         from shipments where id = v_new_shipment)
    and (select status = 'DRAFT' from route_versions where id = v_new_route)
    and (select count(*) = 2 from route_stops where route_version_id = v_new_route)
    and (select count(*) = 1 from cargo_allocations where route_version_id = v_new_route),
    'E16 preserves terminal source and copies a complete linked route into a new draft'
  );
  begin
    update shipments set shipment_state = 'DRAFT' where id = v_shipment;
    raise exception 'terminal source unexpectedly reopened';
  exception when sqlstate '55000' then
    null;
  end;
end;
$$;

-- E02: marketplace cancellation closes listing/payment axes before custody.
do $$
declare
  v_f jsonb := pg_temp.seed_route('e02-marketplace', 'POSTED');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e02-cancel', '3'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'reason', 'Customer cancelled before any assignment or custody',
    'cancellationSnapshot', jsonb_build_object('marketplaceWasVisible', true)
  );
  select haulvia_command.command_cancel_marketplace_shipment(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'shipmentState' = 'CANCELLED'
    and (select state = 'CLOSED' from shipment_marketplace_axes where shipment_id = v_shipment)
    and (select state = 'RELEASED' from shipment_customer_payment_axes where shipment_id = v_shipment),
    'E02 closes marketplace and releases the pre-assignment payment axis'
  );
end;
$$;

-- E03: assigned cancellation records the complete versioned financial decision.
do $$
declare
  v_f jsonb := pg_temp.seed_route('e03-assigned', 'DRIVER_ASSIGNED');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_assignment uuid;
  v_request jsonb;
  v_result jsonb;
begin
  insert into assignments(
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    price_snapshot_id, status, agreement_snapshot
  ) values (
    v_shipment, (v_f ->> 'routeVersionId')::uuid,
    'e2000000-0000-0000-0000-000000000003',
    'e2000000-0000-0000-0000-000000000004',
    'e2000000-0000-0000-0000-000000000005',
    (v_f ->> 'priceSnapshotId')::uuid, 'ACTIVE', jsonb_build_object('accepted', true)
  ) returning id into v_assignment;
  v_request := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e03-cancel', '4'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_assignment,
    'policyVersionId', 'e4000000-0000-0000-0000-000000000002',
    'reason', 'Customer cancelled after assignment but before verified pickup',
    'responsibilityCode', 'CUSTOMER',
    'cancellationChargeAmount', 10, 'customerRefundAmount', 90,
    'driverCompensationAmount', 5, 'currency', 'CAD',
    'decisionSnapshot', jsonb_build_object('policyVersion', 1, 'customerAccepted', true)
  );
  select haulvia_command.command_cancel_assigned_before_custody(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'shipmentState' = 'CANCELLED'
    and (select status = 'CANCELLED' from assignments where id = v_assignment)
    and (select cancellation_charge_amount = 10 and customer_refund_amount = 90
         from pre_custody_financial_decisions
         where id = (v_result ->> 'financialDecisionId')::uuid),
    'E03 closes assignment and retains the reconciled pre-custody financial decision'
  );
end;
$$;

-- E04: approved existing expireListing behavior remains the only expiry path.
do $$
declare
  v_f jsonb := pg_temp.seed_route(
    'e04-expiry', 'POSTED', 'DELIVERY', true, clock_timestamp() - interval '1 minute'
  );
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_result jsonb;
begin
  select haulvia_command.command_expire_listing(
    pg_temp.envelope(v_shipment, null, 'e04-expire', '5') ||
    jsonb_build_object('workerAuthority', 'EXPIRY_WORKER', 'reason', 'Listing deadline elapsed')
  ) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'shipmentState' = 'EXPIRED'
    and (select state = 'EXPIRED' from shipment_marketplace_axes where shipment_id = v_shipment),
    'E04 reuses the deadline-checked expireListing command without adding another wrapper'
  );
end;
$$;

-- E05: retry creates a new attempt and never rewrites the failed attempt.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e05-retry', 1, 'FAILED', 'DELIVERY', false, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(
    v_shipment, 'e2000000-0000-0000-0000-000000000002', 'e05-retry', '6'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e2000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'expectedStopExecutionId', v_f ->> 'currentStopExecutionId',
    'routeExceptionId', v_f ->> 'routeExceptionId',
    'reason', 'Same driver can safely retry the failed pickup',
    'serviceabilitySnapshot', jsonb_build_object(
      'serviceable', true, 'assignmentValid', true, 'assessmentCode', 'RETRY_SAFE'
    )
  );
  select haulvia_command.command_retry_failed_stop_same_driver(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'stopState' = 'ARRIVED'
    and (select state = 'FAILED' and ended_at is not null from stop_attempts
         where id = (v_f ->> 'currentStopAttemptId')::uuid)
    and (select state = 'ARRIVED' from stop_attempts
         where id = (v_result ->> 'retryStopAttemptId')::uuid)
    and (select count(*) = 1 from stop_retry_records where shipment_id = v_shipment),
    'E05 preserves the failed attempt and links a distinct retry attempt'
  );
end;
$$;

-- E06 and E07: a failed first pickup requires an explicit repost-review or
-- terminal-close decision; neither branch automatically republishes.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e06-repost', 1, 'FAILED', 'DELIVERY', false, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e06-repost', '7'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'expectedStopExecutionId', v_f ->> 'currentStopExecutionId',
    'routeExceptionId', v_f ->> 'routeExceptionId',
    'routeCannotContinue', true,
    'policyVersionId', 'e4000000-0000-0000-0000-000000000002',
    'reason', 'First pickup failed and customer review is required before repost',
    'responsibilityCode', 'PROVIDER_UNAVAILABLE',
    'cancellationChargeAmount', 0, 'customerRefundAmount', 100,
    'driverCompensationAmount', 0, 'currency', 'CAD',
    'decisionSnapshot', jsonb_build_object('routeCannotContinue', true, 'automaticRepublish', false)
  );
  select haulvia_command.command_prepare_failed_first_pickup_repost(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'shipmentState' = 'POSTED'
    and v_result ->> 'marketplaceState' = 'PAUSED'
    and (v_result ->> 'automaticRepublish')::boolean is false
    and (select status = 'CANCELLED' from assignments where id = (v_f ->> 'assignmentId')::uuid),
    'E06 prepares a paused customer-review branch without automatic reposting'
  );
end;
$$;

do $$
declare
  v_f jsonb := pg_temp.seed_execution('e07-close', 1, 'FAILED', 'DELIVERY', false, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e07-close', '8'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'expectedStopExecutionId', v_f ->> 'currentStopExecutionId',
    'routeExceptionId', v_f ->> 'routeExceptionId',
    'closeOutcome', 'CANCELLED',
    'policyVersionId', 'e4000000-0000-0000-0000-000000000002',
    'reason', 'Customer closed the shipment after the failed first pickup',
    'responsibilityCode', 'CUSTOMER_CANCELLED',
    'cancellationChargeAmount', 0, 'customerRefundAmount', 100,
    'driverCompensationAmount', 0, 'currency', 'CAD',
    'decisionSnapshot', jsonb_build_object('closeOutcome', 'CANCELLED', 'automaticRepublish', false)
  );
  select haulvia_command.command_close_failed_first_pickup(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'shipmentState' = 'CANCELLED'
    and (select resolution_code = 'CANCELLED' from failed_first_pickup_resolutions
         where id = (v_result ->> 'failedFirstPickupResolutionId')::uuid),
    'E07 terminally closes a failed first pickup using a retained explicit outcome'
  );
end;
$$;

-- E08: continuation keeps the failure immutable and starts the next stop.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e08-continue', 1, 'FAILED', 'DELIVERY', false, true);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e08-continue', '9'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'expectedStopExecutionId', v_f ->> 'currentStopExecutionId',
    'stopFailureReportId', v_f ->> 'stopFailureReportId',
    'decisionCode', 'SKIP', 'routeFeasible', true,
    'capacityValidated', true, 'timingValidated', true, 'custodyValidated', true,
    'routeFeasibilitySnapshot', jsonb_build_object('remainingStopsReachable', true),
    'capacitySnapshot', jsonb_build_object('capacityRemainingKg', 900),
    'timingSnapshot', jsonb_build_object('serviceWindowsValid', true),
    'customerInstructions', jsonb_build_object('skipFailedPickup', true),
    'custodyBalance', v_f -> 'custodyBalance',
    'nextStopEtaAt', clock_timestamp() + interval '1 hour',
    'etaNotificationThresholdSeconds', 60,
    'reason', 'Customer authorized skipping failed pickup and continuing route'
  );
  select haulvia_command.command_continue_route_after_failed_stop(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'failedStopState' = 'FAILED'
    and (select state = 'FAILED' from stop_executions
         where id = (v_f ->> 'currentStopExecutionId')::uuid)
    and (select state = 'EN_ROUTE' from stop_executions
         where id = (v_result ->> 'stopExecutionId')::uuid)
    and (select count(*) = 1 from stop_continuation_authorizations
         where id = (v_result ->> 'stopContinuationAuthorizationId')::uuid),
    'E08 retains the failed stop and separately authorizes the next stop'
  );
end;
$$;

-- E09: verified transfer changes the assignment holder but not the physical
-- custody balance or the original route/pricing facts.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e09-transfer', 2, 'EN_ROUTE', 'DELIVERY', true, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
  v_before jsonb := v_f -> 'custodyBalance';
begin
  v_request := pg_temp.envelope(
    v_shipment, 'e3000000-0000-0000-0000-000000000002', 'e09-transfer', 'a'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e3000000-0000-0000-0000-000000000001',
    'reauthSessionId', 'e3000000-0000-0000-0000-000000000004',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'replacementProviderId', 'e2100000-0000-0000-0000-000000000003',
    'replacementDriverId', 'e2100000-0000-0000-0000-000000000004',
    'replacementVehicleId', 'e2100000-0000-0000-0000-000000000005',
    'reason', 'Operations authorized a verified custody transfer after breakdown',
    'transferItems', jsonb_build_array(jsonb_build_object(
      'cargoAllocationId', v_f ->> 'cargoAllocationId',
      'quantity', 1, 'quantityUnit', 'piece'
    )),
    'handoffSnapshot', jsonb_build_object(
      'fromDriverConfirmed', true, 'toDriverConfirmed', true,
      'qrOrPinVerified', true, 'capturedAt', clock_timestamp(),
      'latitude', 50.4452, 'longitude', -104.6189
    ),
    'handoffEvidenceManifest', jsonb_build_array(jsonb_build_object(
      'type', 'PHOTO', 'storageObjectKey', 'e09/handoff.jpg',
      'contentSha256', repeat('a', 64)
    )),
    'authorizationSnapshot', jsonb_build_object(
      'authorityCode', 'CUSTODY_TRANSFER_AUTHORIZE', 'reasonCode', 'VEHICLE_BREAKDOWN'
    )
  );
  select haulvia_command.command_authorize_custody_transfer(v_request) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'physicalCustodyBalanceUnchanged')::boolean
    and v_result -> 'custodySummary' = v_before
    and (select status = 'TRANSFERRED' from assignments
         where id = (v_f ->> 'assignmentId')::uuid)
    and (select status = 'ACTIVE' from assignments
         where id = (v_result ->> 'assignmentId')::uuid)
    and (select assignment_id = (v_result ->> 'assignmentId')::uuid
         from route_executions where id = (v_f ->> 'routeExecutionId')::uuid)
    and (select count(*) = 1 from custody_transfer_authorizations
         where id = (v_result ->> 'custodyTransferAuthorizationId')::uuid),
    'E09 records both confirmations/evidence, replaces assignment, and preserves custody balance'
  );
end;
$$;

-- E10: recovery creates a new linked route, execution, and price snapshot;
-- the original route/execution remain immutable historical records.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e10-recovery', 2, 'EN_ROUTE', 'DELIVERY', true, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_new_pickup uuid := gen_random_uuid();
  v_new_return uuid := gen_random_uuid();
  v_new_cargo uuid := gen_random_uuid();
  v_new_allocation uuid := gen_random_uuid();
  v_plan jsonb;
  v_request jsonb;
  v_result jsonb;
begin
  v_plan := jsonb_build_object(
    'plannedDistanceKm', 30, 'plannedDurationSeconds', 2400,
    'stops', jsonb_build_array(
      jsonb_build_object(
        'id', v_new_pickup, 'stableStopKey', (v_f ->> 'pickupStableKey')::uuid,
        'sequenceNo', 1, 'stopType', 'PICKUP', 'addressLine1', '100 Origin Road',
        'city', 'Saskatoon', 'regionCode', 'SK', 'countryCode', 'CA',
        'verificationProfile', jsonb_build_object('photo', true)
      ),
      jsonb_build_object(
        'id', v_new_return, 'stableStopKey', gen_random_uuid(),
        'sequenceNo', 2, 'stopType', 'RETURN', 'addressLine1', '100 Return Road',
        'city', 'Saskatoon', 'regionCode', 'SK', 'countryCode', 'CA',
        'verificationProfile', jsonb_build_object('photo', true)
      )
    ),
    'legs', jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid(), 'sequenceNo', 1,
      'fromStopId', v_new_pickup, 'toStopId', v_new_return,
      'plannedDistanceKm', 30, 'plannedDurationSeconds', 2400
    )),
    'cargoItems', jsonb_build_array(jsonb_build_object(
      'id', v_new_cargo, 'stableCargoKey', (v_f ->> 'cargoStableKey')::uuid,
      'cargoLineNo', 1, 'description', 'Block E cargo',
      'quantity', 1, 'quantityUnit', 'piece', 'totalWeightKg', 10,
      'declaredValue', 100, 'currency', 'CAD'
    )),
    'allocations', jsonb_build_array(jsonb_build_object(
      'id', v_new_allocation, 'cargoItemId', v_new_cargo,
      'pickupStopId', v_new_pickup, 'deliveryStopId', v_new_return,
      'quantity', 1, 'quantityUnit', 'piece'
    ))
  );
  v_request := pg_temp.envelope(
    v_shipment, 'e3000000-0000-0000-0000-000000000002', 'e10-recovery', 'b'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e3000000-0000-0000-0000-000000000001',
    'reauthSessionId', 'e3000000-0000-0000-0000-000000000004',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'reason', 'Cargo must return after the destination became unavailable',
    'recoveryKind', 'RETURN', 'recoveryActionCode', 'RETURN',
    'providerAcceptance', jsonb_build_object(
      'accepted', true, 'driverId', 'e2000000-0000-0000-0000-000000000004',
      'acceptedAt', clock_timestamp()
    ),
    'recoverySnapshot', jsonb_build_object(
      'approvedDestination', 'ORIGINAL_SENDER', 'reasonCode', 'DESTINATION_UNAVAILABLE'
    ),
    'custodyBalance', v_f -> 'custodyBalance', 'routePlan', v_plan,
    'pricingSource', 'HAULVIA_GUARDRAIL', 'pricingMode', 'NOT_APPLICABLE',
    'pricingRuleVersionId', 'e5000000-0000-0000-0000-000000000002',
    'amount', 0, 'subtotal', 0, 'taxAmount', 0,
    'additionalPaymentAmount', 0, 'currency', 'CAD',
    'breakdown', '[]'::jsonb, 'snapshotSha256', repeat('b', 64),
    'emergencyWaiver', false,
    'nextStopEtaAt', clock_timestamp() + interval '2 hours'
  );
  select haulvia_command.command_start_recovery_leg(v_request) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'routeVersionId')::uuid <> (v_f ->> 'routeVersionId')::uuid
    and (v_result ->> 'routeExecutionId')::uuid <> (v_f ->> 'routeExecutionId')::uuid
    and (select status = 'SUPERSEDED' from route_versions
         where id = (v_f ->> 'routeVersionId')::uuid)
    and (select status = 'ACTIVE' from route_versions
         where id = (v_result ->> 'routeVersionId')::uuid)
    and (select state = 'COMPLETED' from route_executions
         where id = (v_f ->> 'routeExecutionId')::uuid)
    and (select state = 'RECOVERY_ACTIVE'
         and parent_route_execution_id = (v_f ->> 'routeExecutionId')::uuid
         from route_executions where id = (v_result ->> 'routeExecutionId')::uuid)
    and (select count(*) = 1 from recovery_route_records
         where id = (v_result ->> 'recoveryRouteRecordId')::uuid),
    'E10 links a new accepted/repriced recovery segment without overwriting original route history'
  );
end;
$$;

-- E11: storage captures facility, condition, expense, access, release, notice,
-- evidence, custody movement, and a blocking workflow hold.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e11-storage', 2, 'EVIDENCE_PENDING', 'STORAGE', true, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(v_shipment, null, 'e11-storage', 'c') ||
    jsonb_build_object(
      'workerAuthority', 'STORAGE_WORKER',
      'expectedRouteVersionId', v_f ->> 'routeVersionId',
      'expectedAssignmentId', v_f ->> 'assignmentId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', 0,
      'expectedStopExecutionId', v_f ->> 'currentStopExecutionId',
      'reason', 'Cargo secured at approved storage pending customer instruction',
      'storageItems', jsonb_build_array(jsonb_build_object(
        'cargoAllocationId', v_f ->> 'cargoAllocationId',
        'quantity', 1, 'quantityUnit', 'piece'
      )),
      'custodyBalance', v_f -> 'custodyBalance',
      'storageLocation', jsonb_build_object(
        'facilityName', 'Prairie Secure Storage', 'address', '500 Storage Way',
        'accessAuthority', 'HAULVIA_CASE_TEAM', 'latitude', 50.45, 'longitude', -104.62
      ),
      'custodyProof', jsonb_build_object(
        'facilityAccepted', true, 'capturedAt', clock_timestamp(),
        'condition', 'SEALED_AND_UNDAMAGED', 'identifier', 'LOCKER-E11'
      ),
      'expenseSnapshot', jsonb_build_object(
        'currency', 'CAD', 'dailyCharge', 25, 'responsibilityNoticeSent', true
      ),
      'releaseConditions', jsonb_build_object(
        'verificationRequired', true, 'authorizedRoles', jsonb_build_array('CASE_TEAM')
      ),
      'responsiblePartyCode', 'CUSTOMER_PENDING_DECISION',
      'resolutionDeadline', clock_timestamp() + interval '1 day',
      'reviewerLabel', 'SYSTEM:STORAGE_EVIDENCE_REVIEWER'
    );
  select haulvia_command.command_secure_cargo_in_storage(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'routeExecutionState' = 'HELD'
    and v_result ->> 'stopState' = 'COMPLETED'
    and (select status = 'ACTIVE' and blocks_route_movement
         from workflow_holds where id = (v_result ->> 'workflowHoldId')::uuid)
    and (select storage_location_snapshot ->> 'facilityName' = 'Prairie Secure Storage'
         and custody_proof ->> 'condition' = 'SEALED_AND_UNDAMAGED'
         from storage_custody_records where id = (v_result ->> 'storageCustodyRecordId')::uuid)
    and not exists (
      select 1 from v_cargo_custody_balance
      where shipment_id = v_shipment and onboard_quantity <> 0
    ),
    'E11 records complete storage custody and holds movement after the ledgered handoff'
  );
end;
$$;

-- E12: verified return reconciles the final custody balance and terminates the
-- shipment only when every onboard quantity reaches zero.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e12-return', 2, 'EVIDENCE_PENDING', 'RETURN', true, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(v_shipment, null, 'e12-return', 'd') ||
    jsonb_build_object(
      'workerAuthority', 'RETURN_VERIFICATION_WORKER',
      'expectedRouteVersionId', v_f ->> 'routeVersionId',
      'expectedAssignmentId', v_f ->> 'assignmentId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', 0,
      'expectedStopExecutionId', v_f ->> 'currentStopExecutionId',
      'reason', 'Original sender accepted the complete returned cargo',
      'returnItems', jsonb_build_array(jsonb_build_object(
        'cargoAllocationId', v_f ->> 'cargoAllocationId',
        'quantity', 1, 'quantityUnit', 'piece'
      )),
      'custodyBalance', v_f -> 'custodyBalance',
      'returnEvidenceSnapshot', jsonb_build_object(
        'senderAccepted', true, 'receiverLabel', 'ORIGINAL_SENDER',
        'capturedAt', clock_timestamp(), 'condition', 'UNALTERED'
      ),
      'mixedOutcomeSnapshot', jsonb_build_object(
        'hasMixedOutcomes', false, 'allCargoReturned', true
      ),
      'reviewerLabel', 'SYSTEM:RETURN_EVIDENCE_REVIEWER'
    );
  select haulvia_command.command_verify_return_handoff(v_request) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'terminalReturn')::boolean
    and v_result ->> 'shipmentState' = 'RETURNED_TO_SENDER'
    and (select state = 'COMPLETED' from route_executions
         where id = (v_f ->> 'routeExecutionId')::uuid)
    and (select status = 'COMPLETED' from assignments
         where id = (v_f ->> 'assignmentId')::uuid)
    and (select status = 'FROZEN' from route_versions
         where id = (v_f ->> 'routeVersionId')::uuid)
    and not exists (
      select 1 from v_cargo_custody_balance
      where shipment_id = v_shipment and onboard_quantity <> 0
    ),
    'E12 reaches RETURNED_TO_SENDER only after evidence and exact zero-custody reconciliation'
  );
end;
$$;

-- E13-E15: dispute finance is independent from physical movement; an explicit
-- justified hold may pause movement, resolution allocates only protected funds,
-- and a separate authorized command resumes with a new stop attempt.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e13-e15-dispute', 2, 'EXCEPTION_REVIEW', 'DELIVERY', false, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_open_request jsonb;
  v_opened jsonb;
  v_resolve_request jsonb;
  v_resolved jsonb;
  v_resume_request jsonb;
  v_resumed jsonb;
  v_dispute uuid;
  v_hold uuid;
begin
  v_open_request := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e13-open', 'e'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'stopExecutionId', v_f ->> 'currentStopExecutionId',
    'categoryCode', 'DELIVERY_ACCESS_DISPUTE',
    'description', 'Formal receiver hold prevents lawful delivery until evidence review completes',
    'disputedAmount', 20,
    'evidenceManifest', jsonb_build_array(jsonb_build_object(
      'type', 'PHOTO', 'storageObjectKey', 'e13/formal-hold.jpg'
    )),
    'financialAllocation', jsonb_build_object(
      'priceSnapshotId', v_f ->> 'priceSnapshotId',
      'basis', 'Twenty dollars of the accepted route price is disputed'
    ),
    'blocksRouteMovement', true,
    'operationalControl', jsonb_build_object(
      'movementStopBasis', 'FORMAL_HOLD', 'authorityReference', 'CASE-E13',
      'movementContinues', false
    ),
    'reason', 'Customer opened a formal route-blocking dispute'
  );
  select haulvia_command.command_open_dispute(v_open_request) into v_opened;
  v_dispute := (v_opened ->> 'disputeId')::uuid;
  v_hold := (v_opened ->> 'workflowHoldId')::uuid;
  perform pg_temp.assert_true(
    (v_opened ->> 'protectedAmount')::numeric = 20
    and v_opened ->> 'routeExecutionState' = 'HELD'
    and (select state = 'HELD' from route_executions
         where id = (v_f ->> 'routeExecutionId')::uuid)
    and (select amount = 20 and source_type = 'DISPUTE' and status = 'ACTIVE'
         from financial_holds where id = (v_opened ->> 'financialHoldId')::uuid),
    'E13 protects only the disputed amount and records the justified movement hold separately'
  );

  v_resolve_request := pg_temp.envelope(
    v_shipment, 'e3000000-0000-0000-0000-000000000002', 'e14-resolve', 'f'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e3000000-0000-0000-0000-000000000001',
    'reauthSessionId', 'e3000000-0000-0000-0000-000000000004',
    'expectedDisputeId', v_dispute,
    'decisionCode', 'NO_MONETARY_CHANGE',
    'resolutionSummary', 'Evidence confirms movement may resume and no protected amount remains held',
    'financialAllocation', jsonb_build_object(
      'releaseHeldAmount', 20, 'retainHeldAmount', 0,
      'currency', 'CAD', 'basis', 'All protected value released after evidence review'
    ),
    'nextRouteAction', jsonb_build_object(
      'code', 'RESUME_CURRENT_STOP', 'requiresSeparateCommand', true
    ),
    'evidenceDecision', jsonb_build_object(
      'finding', 'FORMAL_HOLD_CLEARED', 'evidenceSufficient', true
    ),
    'reason', 'Authorized administrator resolved the dispute after fresh authentication'
  );
  select haulvia_command.command_resolve_dispute(v_resolve_request) into v_resolved;
  perform pg_temp.assert_true(
    v_resolved ->> 'disputeStatus' = 'RESOLVED'
    and (v_resolved ->> 'physicalMovementChanged')::boolean is false
    and (select state = 'HELD' from route_executions
         where id = (v_f ->> 'routeExecutionId')::uuid)
    and (select status = 'RELEASED' from financial_holds
         where id = (v_opened ->> 'financialHoldId')::uuid)
    and (select status = 'ACTIVE' from workflow_holds where id = v_hold),
    'E14 allocates protected funds but leaves the physical hold for explicit resumption'
  );

  v_resume_request := pg_temp.envelope(
    v_shipment, 'e3000000-0000-0000-0000-000000000002', 'e15-resume', '0'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e3000000-0000-0000-0000-000000000001',
    'reauthSessionId', 'e3000000-0000-0000-0000-000000000004',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 1,
    'expectedActiveRouteLegId', v_f ->> 'routeLegId',
    'expectedNextStopExecutionId', v_f ->> 'currentStopExecutionId',
    'expectedWorkflowHoldId', v_hold,
    'sourceType', 'DISPUTE', 'sourceId', v_dispute,
    'resumeStopState', 'ARRIVED', 'nextAction', 'START_STOP_SERVICE',
    'custodyBalanceSnapshot', v_f -> 'custodyBalance',
    'authorizationSnapshot', jsonb_build_object(
      'authorityCode', 'SHIPMENT_STATE_OVERRIDE', 'formalHoldCleared', true
    ),
    'reason', 'Freshly authorized route resumption after dispute resolution'
  );
  select haulvia_command.command_resume_after_resolution(v_resume_request) into v_resumed;
  perform pg_temp.assert_true(
    v_resumed ->> 'routeExecutionState' = 'ACTIVE'
    and v_resumed ->> 'stopState' = 'ARRIVED'
    and (select status = 'RELEASED' from workflow_holds where id = v_hold)
    and (select state = 'EXCEPTION_REVIEW' and ended_at is not null
         from stop_attempts where id = (v_f ->> 'currentStopAttemptId')::uuid)
    and (select state = 'ARRIVED' from stop_attempts
         where id = (v_resumed ->> 'stopAttemptId')::uuid)
    and (select count(*) = 1 from workflow_resumption_records
         where id = (v_resumed ->> 'workflowResumptionRecordId')::uuid),
    'E15 releases the exact resolved hold and resumes through a new immutable stop attempt'
  );
end;
$$;

-- Post-custody ordinary cancellation is rejected; custody must be resolved by
-- transfer, recovery, return, or storage instead.
do $$
declare
  v_f jsonb := pg_temp.seed_execution('e-boundary-custody', 2, 'EN_ROUTE', 'DELIVERY', true, false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_bad jsonb;
begin
  v_bad := pg_temp.envelope(
    v_shipment, 'e1000000-0000-0000-0000-000000000002', 'e-boundary-cancel', '1'
  ) || jsonb_build_object(
    'actorOrganizationId', 'e1000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId', v_f ->> 'routeVersionId',
    'expectedAssignmentId', v_f ->> 'assignmentId',
    'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
    'expectedRouteExecutionVersion', 0,
    'policyVersionId', 'e4000000-0000-0000-0000-000000000002',
    'reason', 'Attempted ordinary cancellation after verified custody',
    'responsibilityCode', 'CUSTOMER',
    'cancellationChargeAmount', 0, 'customerRefundAmount', 100,
    'driverCompensationAmount', 0, 'currency', 'CAD',
    'decisionSnapshot', jsonb_build_object('invalidAfterCustody', true)
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_cancel_assigned_before_custody(%L::jsonb)', v_bad::text),
    'CUSTODY_EXISTS',
    'ordinary cancellation must reject the first verified LOAD boundary'
  );
end;
$$;

-- Structural, append-only, context, vocabulary, and execution-boundary checks.
do $$
declare
  v_tables integer;
  v_views integer;
  v_wrappers integer;
  v_public integer;
  v_service_wrappers integer;
  v_service_helpers integer;
  v_append_triggers integer;
  v_retry uuid;
begin
  select count(*) into v_tables
  from information_schema.tables
  where table_schema = 'haulvia' and table_type = 'BASE TABLE';
  select count(*) into v_views
  from information_schema.views where table_schema = 'haulvia';
  select count(*) into v_wrappers
  from information_schema.routines
  where routine_schema = 'haulvia_command' and routine_name like 'command_%';
  select count(*) into v_public
  from information_schema.routine_privileges
  where routine_schema = 'haulvia_command'
    and routine_name like 'command_%' and grantee = 'PUBLIC';
  select count(*) into v_service_wrappers
  from information_schema.routine_privileges
  where routine_schema = 'haulvia_command'
    and routine_name like 'command_%' and grantee = 'service_role';
  select count(*) into v_service_helpers
  from information_schema.routine_privileges
  where routine_schema = 'haulvia_command'
    and left(routine_name, 8) <> 'command_' and grantee = 'service_role';
  select count(*) into v_append_triggers
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'haulvia' and not t.tgisinternal
    and c.relname in (
      'stop_retry_records', 'failed_first_pickup_resolutions',
      'custody_transfer_authorizations', 'recovery_route_records',
      'storage_custody_records', 'return_handoff_records',
      'dispute_operational_controls', 'dispute_resolution_records',
      'workflow_resumption_records', 'terminal_shipment_reposts'
    ) and t.tgname like '%append_only';

  perform pg_temp.assert_true(
    v_tables = 110 and v_views = 5 and v_wrappers = 70,
    'Foundation through Block E installs 110 tables, 5 views, and 70 wrappers'
  );
  perform pg_temp.assert_true(
    v_public = 0 and v_service_wrappers = 70 and v_service_helpers = 0,
    'PUBLIC has no wrappers and service_role receives wrappers only'
  );
  perform pg_temp.assert_true(
    v_append_triggers = 10,
    'all ten Block E retry/recovery/custody/dispute/repost facts are append-only'
  );
  perform pg_temp.assert_true(
    (select count(*) = 1 from information_schema.routines
     where routine_schema = 'haulvia_command' and routine_name = 'command_expire_listing')
    and not exists (
      select 1 from information_schema.routines
      where routine_schema = 'haulvia_command' and routine_name = 'command_e04_expire_listing'
    ),
    'E04 reuses the existing expireListing wrapper instead of duplicating it'
  );
  perform pg_temp.assert_true(
    (select count(*) = 5 from information_schema.columns
     where table_schema = 'haulvia' and table_name = 'v_shipment_operating_context'
       and column_name in (
         'active_recovery_route_record_id', 'active_storage_custody_record_id',
         'verified_custody_transfer_count', 'terminal_repost_count',
         'resumable_workflow_hold_count'
       )),
    'operating context exposes all five appended Block E recovery summaries'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from pg_constraint c
      where c.conrelid = 'haulvia.pre_custody_financial_decisions'::regclass
        and c.contype = 'c'
        and pg_get_constraintdef(c.oid) like '%cancelAssignedBeforeCustody%'
        and pg_get_constraintdef(c.oid) like '%prepareFailedFirstPickupRepost%'
        and pg_get_constraintdef(c.oid) like '%closeFailedFirstPickup%'
    ),
    'pre-custody financial vocabulary includes all approved Block E decision commands'
  );

  select id into v_retry from stop_retry_records limit 1;
  begin
    update stop_retry_records set serviceability_snapshot = jsonb_build_object('changed', true)
    where id = v_retry;
    raise exception 'retry record unexpectedly changed';
  exception when sqlstate '55000' then
    null;
  end;
end;
$$;

rollback;
