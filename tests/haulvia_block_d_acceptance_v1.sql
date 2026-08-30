-- Haulvia Block D command acceptance suite v1
-- Requires foundation v1 plus Block A, Block B, Block C, and Block D.
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

-- Shared customer, provider, policy, pricing, and sensitive-admin fixtures.
do $$
declare
  v_customer_org uuid := 'd1000000-0000-0000-0000-000000000001';
  v_customer uuid := 'd1000000-0000-0000-0000-000000000002';
  v_provider_org uuid := 'd2000000-0000-0000-0000-000000000001';
  v_driver_profile uuid := 'd2000000-0000-0000-0000-000000000002';
  v_provider uuid := 'd2000000-0000-0000-0000-000000000003';
  v_driver uuid := 'd2000000-0000-0000-0000-000000000004';
  v_vehicle uuid := 'd2000000-0000-0000-0000-000000000005';
  v_haulvia_org uuid := 'd3000000-0000-0000-0000-000000000001';
  v_admin uuid := 'd3000000-0000-0000-0000-000000000002';
  v_role uuid := 'd3000000-0000-0000-0000-000000000003';
  v_admin_membership uuid;
  v_policy_set uuid := 'd4000000-0000-0000-0000-000000000001';
  v_policy uuid := 'd4000000-0000-0000-0000-000000000002';
  v_pricing_set uuid := 'd5000000-0000-0000-0000-000000000001';
  v_pricing_version uuid := 'd5000000-0000-0000-0000-000000000002';
begin
  insert into organizations(id, organization_key, kind, legal_name, display_name) values
    (v_customer_org, 'block-d-customer', 'CUSTOMER', 'Block D Customer Ltd.', 'Block D Customer'),
    (v_provider_org, 'block-d-provider', 'INDEPENDENT_PROVIDER', 'Block D Driver Ltd.', 'Block D Driver'),
    (v_haulvia_org, 'block-d-haulvia', 'HAULVIA', 'Haulvia Block D Admin', 'Haulvia Admin');
  insert into profiles(id, display_name) values
    (v_customer, 'Block D Customer'),
    (v_driver_profile, 'Block D Assigned Driver'),
    (v_admin, 'Block D Financial Administrator');
  insert into organization_memberships(organization_id, profile_id, status) values
    (v_customer_org, v_customer, 'ACTIVE'),
    (v_provider_org, v_driver_profile, 'ACTIVE');
  insert into organization_memberships(organization_id, profile_id, status)
  values (v_haulvia_org, v_admin, 'ACTIVE') returning id into v_admin_membership;
  insert into roles(id, role_key, name, description)
  values (v_role, 'BLOCK_D_ADMIN', 'Block D administrator', 'Acceptance-only sensitive role');
  insert into role_permissions(role_id, permission_id)
  select v_role, p.id from permissions p
  where p.permission_key in ('SHIPMENT_STATE_OVERRIDE', 'PAYOUT_MANAGE', 'FINANCIAL_ADJUST');
  insert into membership_roles(membership_id, role_id, granted_by_profile_id)
  values (v_admin_membership, v_role, v_admin);
  insert into reauth_sessions(
    id, profile_id, organization_id, method, verified_at, expires_at, provider_reference
  ) values (
    'd3000000-0000-0000-0000-000000000004', v_admin, v_haulvia_org, 'MFA',
    clock_timestamp() - interval '1 minute', clock_timestamp() + interval '30 minutes',
    'block-d-fresh-auth'
  );

  insert into service_providers(id, organization_id, kind, status, approved_at)
  values (v_provider, v_provider_org, 'INDEPENDENT_DRIVER', 'ACTIVE', clock_timestamp());
  insert into drivers(id, profile_id, status, public_label)
  values (v_driver, v_driver_profile, 'ACTIVE', 'Block D Driver');
  insert into provider_drivers(provider_id, driver_id, status)
  values (v_provider, v_driver, 'ACTIVE');
  insert into vehicles(
    id, provider_id, vehicle_key, status, vehicle_class, capacity_weight_kg
  ) values (v_vehicle, v_provider, 'block-d-van', 'ACTIVE', 'CARGO_VAN', 1000);

  insert into policy_sets(id, policy_key, name)
  values (v_policy_set, 'BLOCK_D_POLICY', 'Block D test policy');
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
      'timingWindows', jsonb_build_object('deliveryReviewSeconds', 86400),
      'riskRules', jsonb_build_object('contactless', 'versioned')
    ), repeat('d', 64), false, v_admin, v_admin, clock_timestamp()
  );
  insert into pricing_rule_sets(
    id, rule_key, name, pricing_source, service_level, currency
  ) values (
    v_pricing_set, 'BLOCK_D_FLEX_GUARD', 'Block D Flex guardrail',
    'HAULVIA_GUARDRAIL', 'FLEX', 'CAD'
  );
  insert into pricing_rule_versions(
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values (
    v_pricing_version, v_pricing_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object('floorAmount', 0, 'ceilingAmount', 200),
    repeat('e', 64), v_admin, v_admin, clock_timestamp()
  );
end;
$$;

create or replace function pg_temp.seed_delivered(
  p_label text,
  p_window_started_at timestamptz default clock_timestamp()
)
returns jsonb language plpgsql as $$
declare
  v_customer_org uuid := 'd1000000-0000-0000-0000-000000000001';
  v_customer uuid := 'd1000000-0000-0000-0000-000000000002';
  v_provider uuid := 'd2000000-0000-0000-0000-000000000003';
  v_driver uuid := 'd2000000-0000-0000-0000-000000000004';
  v_vehicle uuid := 'd2000000-0000-0000-0000-000000000005';
  v_policy uuid := 'd4000000-0000-0000-0000-000000000002';
  v_rule uuid := 'd5000000-0000-0000-0000-000000000002';
  v_shipment uuid;
  v_route uuid := gen_random_uuid();
  v_pickup uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_leg uuid := gen_random_uuid();
  v_cargo uuid := gen_random_uuid();
  v_allocation uuid := gen_random_uuid();
  v_review uuid;
  v_price uuid;
  v_payment uuid;
  v_assignment uuid;
  v_execution uuid;
  v_pickup_execution uuid := gen_random_uuid();
  v_delivery_execution uuid := gen_random_uuid();
  v_pickup_attempt uuid := gen_random_uuid();
  v_delivery_attempt uuid := gen_random_uuid();
  v_evidence uuid;
  v_evidence_review uuid;
  v_load uuid;
  v_unload uuid;
  v_outcome uuid;
  v_token uuid;
  v_window uuid;
  v_resolution uuid;
begin
  insert into shipments(
    customer_organization_id, customer_profile_id, shipment_state,
    pickup_timing, service_level, currency
  ) values (
    v_customer_org, v_customer, 'ROUTE_IN_PROGRESS', 'ASAP', 'FLEX', 'CAD'
  ) returning id into v_shipment;
  update shipment_customer_payment_axes
  set state = 'SECURED', secured_amount = 100, currency = 'CAD'
  where shipment_id = v_shipment;

  insert into route_versions(
    id, shipment_id, version_no, status, change_reason,
    planned_distance_km, planned_duration_seconds, created_by_profile_id
  ) values (v_route, v_shipment, 1, 'DRAFT', 'Block D fixture ' || p_label, 20, 1800, v_customer);
  insert into route_stops(
    id, route_version_id, stable_stop_key, sequence_no, stop_type,
    address_line1, city, region_code, country_code, latitude, longitude,
    geofence_radius_m, planned_service_seconds, verification_profile
  ) values
    (v_pickup, v_route, gen_random_uuid(), 1, 'PICKUP', '100 Origin Road',
     'Saskatoon', 'SK', 'CA', 52.1332, -106.6700, 200, 300,
     jsonb_build_object('photo', true)),
    (v_delivery, v_route, gen_random_uuid(), 2, 'DELIVERY', '200 Destination Road',
     'Regina', 'SK', 'CA', 50.4452, -104.6189, 200, 300,
     jsonb_build_object('photo', true, 'contactless', true));
  insert into route_legs(
    id, route_version_id, sequence_no, from_stop_id, to_stop_id,
    planned_distance_km, planned_duration_seconds
  ) values (v_leg, v_route, 1, v_pickup, v_delivery, 20, 1800);
  insert into cargo_items(
    id, route_version_id, stable_cargo_key, cargo_line_no, description,
    quantity, quantity_unit, total_weight_kg, declared_value, currency
  ) values (v_cargo, v_route, gen_random_uuid(), 1, 'Block D cargo', 1, 'piece', 10, 100, 'CAD');
  insert into cargo_allocations(
    id, route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id,
    quantity, quantity_unit
  ) values (v_allocation, v_route, v_cargo, v_pickup, v_delivery, 1, 'piece');
  update route_versions set status = 'ACTIVE' where id = v_route;

  insert into shipment_rule_snapshots(
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  ) values (
    v_shipment, v_route, v_policy, jsonb_build_object('photo', true),
    jsonb_build_object('preCustody', 'versioned'),
    jsonb_build_object('originalMethod', true),
    jsonb_build_object('deliveryReviewSeconds', 86400),
    jsonb_build_object('contactless', 'versioned'), repeat('d', 64)
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
    v_shipment, 'SECURED', 100, 'CAD', 'block-d-payments',
    'payment-' || p_label, 'fund-' || p_label, clock_timestamp()
  ) returning id into v_payment;
  insert into assignments(
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    price_snapshot_id, status, agreement_snapshot
  ) values (
    v_shipment, v_route, v_provider, v_driver, v_vehicle,
    v_price, 'ACTIVE', jsonb_build_object('fixture', p_label)
  ) returning id into v_assignment;
  insert into route_executions(
    id, shipment_id, route_version_id, assignment_id, execution_kind,
    state, started_at, next_action, record_version
  ) values (
    gen_random_uuid(), v_shipment, v_route, v_assignment, 'PRIMARY',
    'ACTIVE', p_window_started_at - interval '2 hours', 'VERIFY_DELIVERY', 0
  ) returning id into v_execution;

  insert into stop_executions(
    id, shipment_id, route_execution_id, route_version_id, route_stop_id,
    state, delivery_verification_state, current_attempt_no, completed_at
  ) values (
    v_pickup_execution, v_shipment, v_execution, v_route, v_pickup,
    'COMPLETED', 'NOT_REQUIRED', 1, p_window_started_at - interval '90 minutes'
  );
  insert into stop_attempts(
    id, stop_execution_id, attempt_no, state, arrived_at, service_started_at,
    evidence_submitted_at, ended_at
  ) values (
    v_pickup_attempt, v_pickup_execution, 1, 'COMPLETED',
    p_window_started_at - interval '110 minutes',
    p_window_started_at - interval '100 minutes',
    p_window_started_at - interval '95 minutes',
    p_window_started_at - interval '90 minutes'
  );
  insert into stop_executions(
    id, shipment_id, route_execution_id, route_version_id, route_stop_id,
    state, delivery_verification_state, current_attempt_no
  ) values (
    v_delivery_execution, v_shipment, v_execution, v_route, v_delivery,
    'EVIDENCE_PENDING', 'NOT_REQUIRED', 1
  );
  insert into stop_attempts(
    id, stop_execution_id, attempt_no, state, arrived_at, service_started_at,
    evidence_submitted_at
  ) values (
    v_delivery_attempt, v_delivery_execution, 1, 'EVIDENCE_PENDING',
    p_window_started_at - interval '20 minutes',
    p_window_started_at - interval '15 minutes',
    p_window_started_at - interval '5 minutes'
  );
  update route_executions
  set active_stop_execution_id = v_delivery_execution, active_route_leg_id = v_leg
  where id = v_execution;

  insert into stop_evidence(
    stop_attempt_id, evidence_type, storage_object_key, content_sha256,
    structured_value, captured_at, captured_latitude, captured_longitude,
    captured_accuracy_m, idempotency_key
  ) values (
    v_delivery_attempt, 'PHOTO', p_label || '/proof.jpg', repeat('a', 64),
    jsonb_build_object('dropLocation', 'AUTHORIZED_FRONT_DESK', 'notes', 'Secure drop'),
    p_window_started_at - interval '5 minutes', 50.4452, -104.6189, 5,
    p_label || '-proof'
  ) returning id into v_evidence;
  insert into stop_evidence_reviews(
    stop_evidence_id, status, reviewer_label, reviewed_at,
    metadata
  ) values (
    v_evidence, 'VERIFIED', 'SYSTEM:BLOCK_D_FIXTURE', p_window_started_at,
    jsonb_build_object('policyRuleCode', 'CONTACTLESS_PROOF_V1')
  ) returning id into v_evidence_review;

  insert into cargo_movements(
    shipment_id, route_execution_id, route_version_id, stop_execution_id,
    cargo_allocation_id, movement_type, quantity, quantity_unit,
    stop_attempt_id, evidence_bundle, occurred_at, idempotency_key
  ) values (
    v_shipment, v_execution, v_route, v_pickup_execution, v_allocation,
    'LOAD', 1, 'piece', v_pickup_attempt, jsonb_build_object('fixture', p_label),
    p_window_started_at - interval '90 minutes', p_label || '-load'
  ) returning id into v_load;
  insert into cargo_movements(
    shipment_id, route_execution_id, route_version_id, stop_execution_id,
    cargo_allocation_id, movement_type, quantity, quantity_unit,
    stop_attempt_id, evidence_bundle, occurred_at, idempotency_key
  ) values (
    v_shipment, v_execution, v_route, v_delivery_execution, v_allocation,
    'UNLOAD', 1, 'piece', v_delivery_attempt, jsonb_build_object('proofEvidenceId', v_evidence),
    p_window_started_at, p_label || '-unload'
  ) returning id into v_unload;
  insert into cargo_resolution_outcomes(
    shipment_id, route_execution_id, route_version_id, stop_execution_id,
    cargo_allocation_id, cargo_movement_id, outcome_code, quantity,
    quantity_unit, approval_snapshot, occurred_at, idempotency_key
  ) values (
    v_shipment, v_execution, v_route, v_delivery_execution, v_allocation,
    v_unload, 'DELIVERED', 1, 'piece',
    jsonb_build_object('proofEvidenceId', v_evidence, 'contactless', true),
    p_window_started_at, p_label || '-outcome'
  ) returning id into v_outcome;

  insert into receiver_access_tokens(
    shipment_id, stop_execution_id, token_hash, permissions,
    expires_at, created_at
  ) values (
    v_shipment, v_delivery_execution, encode(sha256(p_label::bytea), 'hex'),
    jsonb_build_object(
      'track', true, 'confirmReceipt', true, 'reportIssue', true,
      'pricing', false, 'edit', false, 'cancel', false
    ), p_window_started_at + interval '24 hours', p_window_started_at
  ) returning id into v_token;

  update stop_executions
  set state = 'COMPLETED',
      delivery_verification_state = 'PENDING_RECEIVER_CONFIRMATION',
      completed_at = p_window_started_at
  where id = v_delivery_execution;
  update stop_attempts
  set state = 'COMPLETED', ended_at = p_window_started_at
  where id = v_delivery_attempt;
  select id into v_window from delivery_review_windows
  where stop_execution_id = v_delivery_execution;

  insert into route_resolution_records(
    shipment_id, route_execution_id, route_version_id, public_outcome_label,
    outcome_summary, custody_reconciliation, evidence_reconciliation,
    idempotency_key, resolved_at
  ) values (
    v_shipment, v_execution, v_route, 'DELIVERED',
    jsonb_build_object('byOutcomeAndUnit', jsonb_build_array(jsonb_build_object(
      'outcomeCode', 'DELIVERED', 'quantity', 1, 'quantityUnit', 'piece', 'outcomeCount', 1
    )), 'outcomeCount', 1),
    jsonb_build_object('onboardQuantity', 0, 'quantityUnit', 'piece'),
    jsonb_build_object('verifiedEvidenceReviewId', v_evidence_review),
    p_label || '-route-resolution', p_window_started_at
  ) returning id into v_resolution;
  update route_executions
  set state = 'COMPLETED', completed_at = p_window_started_at,
      next_action = 'AWAIT_RECEIVER_CONFIRMATION', record_version = 1
  where id = v_execution;
  update shipments set shipment_state = 'DELIVERED' where id = v_shipment;

  return jsonb_build_object(
    'shipmentId', v_shipment, 'routeVersionId', v_route,
    'assignmentId', v_assignment, 'routeExecutionId', v_execution,
    'routeExecutionVersion', 1, 'pickupStopExecutionId', v_pickup_execution,
    'deliveryStopExecutionId', v_delivery_execution,
    'deliveryReviewWindowId', v_window, 'receiverAccessTokenId', v_token,
    'receiverTokenHash', encode(sha256(p_label::bytea), 'hex'),
    'evidenceReviewId', v_evidence_review,
    'cargoItemId', v_cargo, 'cargoAllocationId', v_allocation,
    'priceSnapshotId', v_price, 'paymentIntentId', v_payment,
    'routeResolutionRecordId', v_resolution
  );
end;
$$;

create or replace function pg_temp.cargo_manifest(p_fixture jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_array(jsonb_build_object(
    'cargoAllocationId', p_fixture ->> 'cargoAllocationId',
    'quantity', 1, 'quantityUnit', 'piece'
  ));
$$;

create or replace function pg_temp.resolve_and_complete(p_label text)
returns jsonb language plpgsql as $$
declare
  v_f jsonb := pg_temp.seed_delivered(p_label);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_receipt jsonb;
  v_result jsonb;
  v_execution_version bigint;
begin
  v_request := pg_temp.envelope(v_shipment, null, p_label || '-receipt', '1') ||
    jsonb_build_object(
      'expectedDeliveryReviewWindowId', v_f ->> 'deliveryReviewWindowId',
      'expectedStopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_f ->> 'routeExecutionVersion',
      'receiverAccessTokenId', v_f ->> 'receiverAccessTokenId',
      'receiverTokenHash', v_f ->> 'receiverTokenHash',
      'receiverLabel', 'Verified Receiver ' || p_label,
      'cargoManifest', pg_temp.cargo_manifest(v_f),
      'respondedAt', clock_timestamp()
    );
  select haulvia_command.command_confirm_receiver_receipt(v_request) into v_receipt;
  v_execution_version := (v_receipt ->> 'routeExecutionVersion')::bigint;
  v_request := pg_temp.envelope(v_shipment, null, p_label || '-complete', '2') ||
    jsonb_build_object(
      'workerAuthority', 'COMPLETION_WORKER',
      'expectedRouteResolutionRecordId', v_f ->> 'routeResolutionRecordId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedAssignmentId', v_f ->> 'assignmentId',
      'expectedPriceSnapshotId', v_f ->> 'priceSnapshotId',
      'releaseAuthorization', jsonb_build_object(
        'authorizationCode', 'ROUTE_RELEASED',
        'authorizedReason', 'All physical evidence and review windows resolved'
      ),
      'payoutAllocation', jsonb_build_object(
        'grossAmount', 100, 'platformFeeAmount', 10,
        'adjustmentAmount', 0, 'netAmount', 90,
        'currency', 'CAD', 'calculationVersion', 'payout-allocation-v1'
      )
    );
  select haulvia_command.command_complete_shipment(v_request) into v_result;
  return v_f || jsonb_build_object(
    'payoutId', v_result ->> 'payoutId',
    'shipmentCompletionRecordId', v_result ->> 'shipmentCompletionRecordId',
    'payoutEligibilityRecordId', v_result ->> 'payoutEligibilityRecordId',
    'completedShipmentVersion', v_result ->> 'lockVersion',
    'completedRouteExecutionVersion', v_result ->> 'routeExecutionVersion'
  );
end;
$$;

-- D01: verified receiver result is stop-scoped, first-valid, and replay-safe.
do $$
declare
  v_f jsonb := pg_temp.seed_delivered('d01');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
  v_replay jsonb;
begin
  v_request := pg_temp.envelope(v_shipment, null, 'd01-confirm', '3') ||
    jsonb_build_object(
      'expectedDeliveryReviewWindowId', v_f ->> 'deliveryReviewWindowId',
      'expectedStopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_f ->> 'routeExecutionVersion',
      'receiverAccessTokenId', v_f ->> 'receiverAccessTokenId',
      'receiverTokenHash', v_f ->> 'receiverTokenHash',
      'receiverLabel', 'Verified D01 Receiver',
      'cargoManifest', pg_temp.cargo_manifest(v_f),
      'respondedAt', clock_timestamp()
    );
  select haulvia_command.command_confirm_receiver_receipt(v_request) into v_result;
  select haulvia_command.command_confirm_receiver_receipt(v_request) into v_replay;
  perform pg_temp.assert_true(
    v_result ->> 'deliveryVerificationState' = 'RECEIVER_CONFIRMED'
    and (v_result ->> 'replayed')::boolean = false
    and (v_replay ->> 'replayed')::boolean = true
    and (select delivery_verification_state = 'RECEIVER_CONFIRMED'
         from stop_executions where id = (v_f ->> 'deliveryStopExecutionId')::uuid)
    and (select used_at is not null from receiver_access_tokens
         where id = (v_f ->> 'receiverAccessTokenId')::uuid)
    and (select count(*) = 1 from receiver_confirmations
         where stop_execution_id = (v_f ->> 'deliveryStopExecutionId')::uuid)
    and (select count(*) = 1 from delivery_review_window_resolutions
         where delivery_review_window_id = (v_f ->> 'deliveryReviewWindowId')::uuid),
    'D01 commits exactly one verified receiver response and replays without duplication'
  );
  perform pg_temp.assert_true(
    (select configured_window_seconds = 86400
       and timing_window_snapshot ->> 'deliveryReviewSeconds' = '86400'
     from delivery_review_windows where id = (v_f ->> 'deliveryReviewWindowId')::uuid),
    'delivery evidence starts the configured versioned 24-hour launch window'
  );
end;
$$;

-- D02: a receiver problem preserves evidence, opens a dispute, and protects
-- only the disputed allocation while leaving operational state DELIVERED.
do $$
declare
  v_f jsonb := pg_temp.seed_delivered('d02');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
  v_complete jsonb;
begin
  v_request := pg_temp.envelope(v_shipment, null, 'd02-problem', '4') ||
    jsonb_build_object(
      'expectedDeliveryReviewWindowId', v_f ->> 'deliveryReviewWindowId',
      'expectedStopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_f ->> 'routeExecutionVersion',
      'receiverAccessTokenId', v_f ->> 'receiverAccessTokenId',
      'receiverTokenHash', v_f ->> 'receiverTokenHash',
      'receiverLabel', 'Verified D02 Receiver',
      'cargoManifest', pg_temp.cargo_manifest(v_f),
      'issueCategory', 'DAMAGED',
      'description', 'Outer packaging and cargo were visibly damaged at receipt',
      'evidenceManifest', jsonb_build_array(jsonb_build_object(
        'type', 'PHOTO', 'storageObjectKey', 'd02/receiver-damage.jpg',
        'contentSha256', repeat('b', 64)
      )),
      'cargoItemId', v_f ->> 'cargoItemId',
      'disputedAmount', 25,
      'financialAllocation', jsonb_build_object(
        'priceSnapshotId', v_f ->> 'priceSnapshotId',
        'basis', 'DAMAGED_CARGO_SHARE'
      ),
      'respondedAt', clock_timestamp()
    );
  select haulvia_command.command_report_delivery_problem(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'deliveryVerificationState' = 'ISSUE_REPORTED'
    and v_result ->> 'shipmentState' = 'DELIVERED'
    and (v_result ->> 'protectedAmount')::numeric = 25
    and (select count(*) = 1 from delivery_problem_reports
         where id = (v_result ->> 'deliveryProblemReportId')::uuid)
    and (select amount = 25 and hold_code = 'DISPUTED_AMOUNT'
         from financial_holds where id = (v_result ->> 'financialHoldId')::uuid)
    and (select state = 'OPEN' and open_dispute_count = 1
         from shipment_dispute_axes where shipment_id = v_shipment),
    'D02 preserves receiver problem evidence and protects only its disputed amount'
  );

  v_complete := pg_temp.envelope(v_shipment, null, 'd02-completion-blocked', '5') ||
    jsonb_build_object(
      'workerAuthority', 'COMPLETION_WORKER',
      'expectedRouteResolutionRecordId', v_f ->> 'routeResolutionRecordId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_result ->> 'routeExecutionVersion',
      'expectedAssignmentId', v_f ->> 'assignmentId',
      'expectedPriceSnapshotId', v_f ->> 'priceSnapshotId',
      'releaseAuthorization', jsonb_build_object(
        'authorizationCode', 'ROUTE_RELEASED',
        'authorizedReason', 'Attempted before receiver issue resolution'
      ),
      'payoutAllocation', jsonb_build_object(
        'grossAmount', 100, 'platformFeeAmount', 10,
        'adjustmentAmount', 0, 'netAmount', 90,
        'currency', 'CAD', 'calculationVersion', 'payout-allocation-v1'
      )
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_complete_shipment(%L::jsonb)', v_complete::text),
    'DELIVERY_REVIEW_UNRESOLVED',
    'receiver-reported problem blocks operational completion until resolved'
  );
end;
$$;

-- D03: expiry uses retained proof, never receiver confirmation; ineligible
-- proof opens an exception instead of inventing success.
do $$
declare
  v_f jsonb := pg_temp.seed_delivered('d03-proof', clock_timestamp() - interval '25 hours');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(v_shipment, null, 'd03-proof-expiry', '6') ||
    jsonb_build_object(
      'workerAuthority', 'RECEIVER_WINDOW_EXPIRY',
      'expectedDeliveryReviewWindowId', v_f ->> 'deliveryReviewWindowId',
      'expectedStopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_f ->> 'routeExecutionVersion',
      'proofAssessment', jsonb_build_object(
        'eligible', true,
        'reviewerLabel', 'SYSTEM:PROOF_ENGINE',
        'policyRuleCode', 'CONTACTLESS_PROOF_V1',
        'evidenceReviewIds', jsonb_build_array(v_f ->> 'evidenceReviewId')
      )
    );
  select haulvia_command.command_expire_confirmation_window(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'deliveryVerificationState' = 'VERIFIED_BY_PROOF_OF_DROP'
    and (v_result ->> 'receiverConfirmed')::boolean = false
    and (select count(*) = 0 from receiver_confirmations
         where stop_execution_id = (v_f ->> 'deliveryStopExecutionId')::uuid)
    and (select resolution_source = 'PROOF_OF_DROP'
         from delivery_review_window_resolutions
         where delivery_review_window_id = (v_f ->> 'deliveryReviewWindowId')::uuid),
    'D03 eligible proof resolves expiry without fabricating receiver confirmation'
  );
end;
$$;

do $$
declare
  v_f jsonb := pg_temp.seed_delivered('d03-exception', clock_timestamp() - interval '25 hours');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_request jsonb;
  v_result jsonb;
begin
  v_request := pg_temp.envelope(v_shipment, null, 'd03-exception-expiry', '7') ||
    jsonb_build_object(
      'workerAuthority', 'RECEIVER_WINDOW_EXPIRY',
      'expectedDeliveryReviewWindowId', v_f ->> 'deliveryReviewWindowId',
      'expectedStopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'expectedRouteExecutionId', v_f ->> 'routeExecutionId',
      'expectedRouteExecutionVersion', v_f ->> 'routeExecutionVersion',
      'proofAssessment', jsonb_build_object(
        'eligible', false,
        'reviewerLabel', 'SYSTEM:PROOF_ENGINE',
        'policyRuleCode', 'CONTACTLESS_PROOF_V1',
        'evidenceReviewIds', jsonb_build_array(v_f ->> 'evidenceReviewId'),
        'reason', 'Secure drop criteria could not be fully verified'
      )
    );
  select haulvia_command.command_expire_confirmation_window(v_request) into v_result;
  perform pg_temp.assert_true(
    v_result ->> 'deliveryVerificationState' = 'EXCEPTION_REVIEW'
    and (v_result ->> 'receiverConfirmed')::boolean = false
    and (select blocks_completion and status = 'OPEN'
         from route_exceptions where id = (v_result ->> 'routeExceptionId')::uuid),
    'D03 ineligible proof opens completion-blocking review without changing route outcome'
  );
end;
$$;

-- D05-D07: physical completion is irreversible; payout request and provider
-- confirmation proceed independently with retained amount/allocation details.
do $$
declare
  v_f jsonb := pg_temp.resolve_and_complete('d-payout-success');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_submit jsonb;
  v_submitted jsonb;
  v_confirm jsonb;
  v_confirmed jsonb;
  v_duplicate jsonb;
  v_adjustment jsonb;
  v_adjusted jsonb;
begin
  perform pg_temp.assert_true(
    (select shipment_state = 'COMPLETED' and terminal_at is not null
       from shipments where id = v_shipment)
    and (select state = 'READY' and net_amount = 90
         from driver_payouts where id = (v_f ->> 'payoutId')::uuid)
    and (select count(*) = 1 from shipment_completion_records
         where id = (v_f ->> 'shipmentCompletionRecordId')::uuid)
    and (select release_authorization ->> 'authorizationCode' = 'ROUTE_RELEASED'
         from payout_eligibility_records
         where id = (v_f ->> 'payoutEligibilityRecordId')::uuid),
    'D05 records irreversible completion and a separate READY payout eligibility snapshot'
  );

  v_submit := pg_temp.envelope(v_shipment, null, 'd06-submit-full', '8') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_WORKER',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutAmount', 90, 'externalProvider', 'block-d-payouts',
      'providerIdempotencyKey', 'd06-provider-request',
      'payoutAccountReference', 'acct_driver_d_success',
      'payoutAccountValid', true,
      'providerRequest', jsonb_build_object('rail', 'EFT')
    );
  select haulvia_command.command_submit_driver_payout(v_submit) into v_submitted;
  perform pg_temp.assert_true(
    v_submitted ->> 'driverPayoutState' = 'PROCESSING'
    and (select status = 'PENDING' and amount = 90
         from payout_transactions where id = (v_submitted ->> 'payoutTransactionId')::uuid),
    'D06 submits one idempotent provider request only after whole-route eligibility'
  );

  v_confirm := pg_temp.envelope(v_shipment, null, 'd07-confirm-full', '9') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_PROVIDER_CALLBACK',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutRequestTransactionId', v_submitted ->> 'payoutTransactionId',
      'payoutAmount', 90, 'externalProvider', 'block-d-payouts',
      'providerEventId', 'evt-d07-paid', 'externalReference', 'payout-d07-paid',
      'providerOccurredAt', clock_timestamp(),
      'providerResponse', jsonb_build_object('status', 'paid')
    );
  select haulvia_command.command_confirm_driver_payout(v_confirm) into v_confirmed;
  perform pg_temp.assert_true(
    v_confirmed ->> 'driverPayoutState' = 'PAID'
    and v_confirmed ->> 'shipmentState' = 'COMPLETED'
    and (select state = 'PAID' from driver_payouts where id = (v_f ->> 'payoutId')::uuid)
    and (select external_reference = 'payout-d07-paid' and amount = 90
         from payout_transactions where id = (v_confirmed ->> 'payoutTransactionId')::uuid),
    'D07 retains provider reference, amount, allocation, and timestamp without changing COMPLETED'
  );

  v_confirm := jsonb_set(
    pg_temp.envelope(v_shipment, null, 'd07-duplicate-event', 'a') ||
      (v_confirm - array['commandId', 'idempotencyKey', 'requestHash', 'expectedShipmentVersion']),
    '{expectedShipmentVersion}',
    to_jsonb((select lock_version from shipments where id = v_shipment))
  );
  select haulvia_command.command_confirm_driver_payout(v_confirm) into v_duplicate;
  perform pg_temp.assert_true(
    (v_duplicate ->> 'duplicateProviderEvent')::boolean
    and (select count(*) = 1 from payout_transactions
         where external_provider = 'block-d-payouts' and provider_event_id = 'evt-d07-paid'),
    'duplicate provider callback cannot duplicate a payout outcome'
  );

  v_adjustment := pg_temp.envelope(
      v_shipment, 'd3000000-0000-0000-0000-000000000002',
      'd09-refund-success', 'b'
    ) || jsonb_build_object(
      'actorOrganizationId', 'd3000000-0000-0000-0000-000000000001',
      'reauthSessionId', 'd3000000-0000-0000-0000-000000000004',
      'reason', 'Approved partial refund for verified delivery damage',
      'adjustmentType', 'CUSTOMER_REFUND', 'amount', 10, 'currency', 'CAD',
      'policyVersionId', 'd4000000-0000-0000-0000-000000000002',
      'paymentIntentId', v_f ->> 'paymentIntentId',
      'routeExecutionId', v_f ->> 'routeExecutionId',
      'stopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'cargoItemId', v_f ->> 'cargoItemId',
      'authorizationSnapshot', jsonb_build_object(
        'authorityCode', 'FINANCIAL_ADJUST', 'decision', 'PARTIAL_REFUND'
      ),
      'externalProvider', 'block-d-payments',
      'providerIdempotencyKey', 'd09-refund-provider-key',
      'providerStatus', 'SUCCEEDED', 'providerEventId', 'evt-d09-refund',
      'externalReference', 'refund-d09-001',
      'providerOccurredAt', clock_timestamp(),
      'providerResponse', jsonb_build_object('status', 'succeeded')
    );
  perform pg_temp.expect_error_code(
    format(
      'select haulvia_command.command_issue_refund_or_adjustment(%L::jsonb)',
      jsonb_set(v_adjustment, '{reauthSessionId}', to_jsonb(gen_random_uuid()::text))::text
    ),
    'FRESH_AUTH_REQUIRED',
    'financial override requires fresh authentication'
  );
  select haulvia_command.command_issue_refund_or_adjustment(v_adjustment) into v_adjusted;
  perform pg_temp.assert_true(
    v_adjusted ->> 'adjustmentType' = 'CUSTOMER_REFUND'
    and v_adjusted ->> 'shipmentState' = 'COMPLETED'
    and (select adjustment_type = 'CUSTOMER_REFUND' and amount = 10
         from financial_adjustments where id = (v_adjusted ->> 'financialAdjustmentId')::uuid)
    and (select state = 'PARTIALLY_REFUNDED'
         from shipment_customer_payment_axes where shipment_id = v_shipment),
    'D09 uses permission, fresh auth, reason, audit, and idempotent provider transaction independently'
  );
end;
$$;

-- D04 after completion protects exactly the disputable remainder, and D06-D07
-- may release the undisputed share while the aggregate payout remains HELD.
do $$
declare
  v_f jsonb := pg_temp.resolve_and_complete('d04-partial-hold');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_open jsonb;
  v_dispute jsonb;
  v_submit jsonb;
  v_submitted jsonb;
  v_confirm jsonb;
  v_confirmed jsonb;
begin
  v_open := pg_temp.envelope(
      v_shipment, 'd1000000-0000-0000-0000-000000000002',
      'd04-open-after-completion', 'c'
    ) || jsonb_build_object(
      'actorOrganizationId', 'd1000000-0000-0000-0000-000000000001',
      'expectedAssignmentId', v_f ->> 'assignmentId',
      'stopExecutionId', v_f ->> 'deliveryStopExecutionId',
      'cargoItemId', v_f ->> 'cargoItemId',
      'categoryCode', 'POST_DELIVERY_DAMAGE',
      'description', 'Customer found concealed damage after opening the retained package',
      'disputedAmount', 20,
      'evidenceManifest', jsonb_build_array(jsonb_build_object(
        'type', 'PHOTO', 'storageObjectKey', 'd04/concealed-damage.jpg',
        'contentSha256', repeat('c', 64)
      )),
      'financialAllocation', jsonb_build_object(
        'priceSnapshotId', v_f ->> 'priceSnapshotId',
        'basis', 'CARGO_DAMAGE_SHARE'
      )
    );
  select haulvia_command.command_open_post_delivery_dispute(v_open) into v_dispute;
  perform pg_temp.assert_true(
    v_dispute ->> 'shipmentState' = 'COMPLETED'
    and (v_dispute ->> 'operationalStateUnchanged')::boolean
    and (v_dispute ->> 'protectedAmount')::numeric = 20
    and (select state = 'HELD' from driver_payouts where id = (v_f ->> 'payoutId')::uuid)
    and (select sum(amount) = 20 from financial_holds
         where shipment_id = v_shipment and status = 'ACTIVE'),
    'D04 keeps COMPLETED immutable and protects exactly the disputed amount'
  );

  v_submit := pg_temp.envelope(v_shipment, null, 'd04-submit-undisputed', 'd') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_WORKER',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutAmount', 70, 'externalProvider', 'block-d-payouts',
      'providerIdempotencyKey', 'd04-undisputed-provider-key',
      'payoutAccountReference', 'acct_driver_d_dispute',
      'payoutAccountValid', true
    );
  select haulvia_command.command_submit_driver_payout(v_submit) into v_submitted;
  v_confirm := pg_temp.envelope(v_shipment, null, 'd04-confirm-undisputed', 'e') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_PROVIDER_CALLBACK',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutRequestTransactionId', v_submitted ->> 'payoutTransactionId',
      'payoutAmount', 70, 'externalProvider', 'block-d-payouts',
      'providerEventId', 'evt-d04-undisputed',
      'externalReference', 'payout-d04-undisputed',
      'providerOccurredAt', clock_timestamp()
    );
  select haulvia_command.command_confirm_driver_payout(v_confirm) into v_confirmed;
  perform pg_temp.assert_true(
    v_confirmed ->> 'driverPayoutState' = 'HELD'
    and (v_confirmed ->> 'paidAmount')::numeric = 70
    and (v_confirmed ->> 'protectedHoldAmount')::numeric = 20
    and (select shipment_state = 'COMPLETED' from shipments where id = v_shipment),
    'undisputed payout can settle while the separately disputed amount remains held'
  );
end;
$$;

-- D08: failed provider outcome is retained, shipment stays complete, and a
-- new idempotent request may retry the available amount.
do $$
declare
  v_f jsonb := pg_temp.resolve_and_complete('d08-failure');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_submit jsonb;
  v_submitted jsonb;
  v_failure jsonb;
  v_failed jsonb;
  v_retry jsonb;
  v_retried jsonb;
begin
  v_submit := pg_temp.envelope(v_shipment, null, 'd08-submit', 'f') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_WORKER',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutAmount', 90, 'externalProvider', 'block-d-payouts',
      'providerIdempotencyKey', 'd08-provider-request-1',
      'payoutAccountReference', 'acct_driver_d_failure',
      'payoutAccountValid', true
    );
  select haulvia_command.command_submit_driver_payout(v_submit) into v_submitted;
  v_failure := pg_temp.envelope(v_shipment, null, 'd08-failed-callback', '0') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_PROVIDER_CALLBACK',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutRequestTransactionId', v_submitted ->> 'payoutTransactionId',
      'payoutAmount', 90, 'externalProvider', 'block-d-payouts',
      'providerEventId', 'evt-d08-failed', 'externalReference', 'payout-d08-failed',
      'providerOccurredAt', clock_timestamp(),
      'providerResponse', jsonb_build_object('failureCode', 'ACCOUNT_TEMPORARILY_UNAVAILABLE')
    );
  select haulvia_command.command_handle_payout_failure(v_failure) into v_failed;
  perform pg_temp.assert_true(
    v_failed ->> 'driverPayoutState' = 'FAILED'
    and v_failed ->> 'shipmentState' = 'COMPLETED'
    and (select status = 'FAILED' from payout_transactions
         where id = (v_failed ->> 'payoutTransactionId')::uuid),
    'D08 retains provider failure without moving COMPLETED backward'
  );
  v_retry := pg_temp.envelope(v_shipment, null, 'd08-retry', '1') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_WORKER',
      'expectedPayoutId', v_f ->> 'payoutId',
      'payoutAmount', 90, 'externalProvider', 'block-d-payouts',
      'providerIdempotencyKey', 'd08-provider-request-2',
      'payoutAccountReference', 'acct_driver_d_failure',
      'payoutAccountValid', true
    );
  select haulvia_command.command_submit_driver_payout(v_retry) into v_retried;
  perform pg_temp.assert_true(
    v_retried ->> 'driverPayoutState' = 'PROCESSING'
    and (select count(*) = 2 from payout_transactions
         where payout_id = (v_f ->> 'payoutId')::uuid and status = 'PENDING'),
    'D08 failure supports a new retained retry request without deleting the failed attempt'
  );
end;
$$;

-- Structural, append-only, vocabulary, and execution-boundary checks.
do $$
declare
  v_tables integer;
  v_views integer;
  v_wrappers integer;
  v_public integer;
  v_service_wrappers integer;
  v_service_helpers integer;
  v_append_triggers integer;
  v_completed uuid;
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
      'delivery_review_windows', 'delivery_review_window_resolutions',
      'delivery_problem_reports', 'payout_eligibility_records',
      'shipment_completion_records', 'financial_adjustments'
    ) and t.tgname like '%append_only';

  perform pg_temp.assert_true(
    v_tables >= 100 and v_views = 5 and v_wrappers >= 55,
    'Foundation through Block D and later additive blocks retain at least 100 tables, 5 views, and 55 wrappers'
  );
  perform pg_temp.assert_true(
    v_public = 0 and v_service_wrappers = v_wrappers and v_service_helpers = 0,
    'PUBLIC has no wrappers and service_role receives every installed wrapper only'
  );
  perform pg_temp.assert_true(
    v_append_triggers = 6,
    'Block D review, completion, payout eligibility, problem, and adjustment facts are append-only'
  );
  perform pg_temp.assert_true(
    exists (
      select 1 from information_schema.columns
      where table_schema = 'haulvia' and table_name = 'v_shipment_operating_context'
        and column_name = 'pending_delivery_review_count'
    ) and exists (
      select 1 from information_schema.columns
      where table_schema = 'haulvia' and table_name = 'v_shipment_operating_context'
        and column_name = 'active_disputed_amount'
    ),
    'operating context exposes independent review and disputed-fund summaries'
  );
  perform pg_temp.assert_true(
    not exists (
      select 1 from pg_description d
      where lower(coalesce(d.description, '')) like '%escrow%'
        and d.objoid in (
          'haulvia.delivery_review_windows'::regclass,
          'haulvia.payout_eligibility_records'::regclass,
          'haulvia.shipment_completion_records'::regclass
        )
    ),
    'Block D public-facing database comments use held-for-payout language, not escrow'
  );

  select shipment_id into v_completed from shipment_completion_records limit 1;
  begin
    update shipments set shipment_state = 'DELIVERED' where id = v_completed;
    raise exception 'terminal shipment unexpectedly reopened';
  exception when sqlstate '55000' then
    null;
  end;
  begin
    update shipment_completion_records set financial_summary = jsonb_build_object('changed', true)
    where shipment_id = v_completed;
    raise exception 'completion record unexpectedly changed';
  exception when sqlstate '55000' then
    null;
  end;
end;
$$;

rollback;
