-- Haulvia Block B command acceptance suite v1
-- Requires foundation v1, Block A v1, and Block B v1 migrations.
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
  p_shipment_id uuid,
  p_actor_profile_id uuid,
  p_idempotency_key text,
  p_hash_character text
)
returns jsonb language sql as $$
  select jsonb_build_object(
    'commandId', gen_random_uuid(),
    'idempotencyKey', p_idempotency_key,
    'requestHash', repeat(p_hash_character, 64),
    'actorProfileId', p_actor_profile_id,
    'shipmentId', p_shipment_id,
    'expectedShipmentVersion', s.lock_version,
    'requestedAt', clock_timestamp()
  )
  from haulvia.shipments s where s.id = p_shipment_id;
$$;

create or replace function pg_temp.make_block_b_plan(p_destination_city text default 'Moose Jaw')
returns jsonb language plpgsql as $$
declare
  v_pickup uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_cargo uuid := gen_random_uuid();
begin
  return jsonb_build_object(
    'plannedDistanceKm', 235,
    'plannedDurationSeconds', 9000,
    'stops', jsonb_build_array(
      jsonb_build_object(
        'id', v_pickup, 'stableStopKey', gen_random_uuid(), 'sequenceNo', 1,
        'stopType', 'PICKUP', 'addressLine1', '300 Edited Pickup Road',
        'city', 'Saskatoon', 'regionCode', 'SK', 'countryCode', 'CA',
        'latitude', 52.1332, 'longitude', -106.6700, 'geofenceRadiusM', 200,
        'verificationProfile', jsonb_build_object('photo', true)
      ),
      jsonb_build_object(
        'id', v_delivery, 'stableStopKey', gen_random_uuid(), 'sequenceNo', 2,
        'stopType', 'DELIVERY', 'addressLine1', '400 Edited Delivery Road',
        'city', p_destination_city, 'regionCode', 'SK', 'countryCode', 'CA',
        'verificationProfile', jsonb_build_object('pin', true)
      )
    ),
    'legs', jsonb_build_array(
      jsonb_build_object(
        'id', gen_random_uuid(), 'sequenceNo', 1,
        'fromStopId', v_pickup, 'toStopId', v_delivery,
        'plannedDistanceKm', 235, 'plannedDurationSeconds', 9000
      )
    ),
    'cargoItems', jsonb_build_array(
      jsonb_build_object(
        'id', v_cargo, 'stableCargoKey', gen_random_uuid(), 'cargoLineNo', 1,
        'description', 'Edited Block B parcel', 'quantity', 2,
        'quantityUnit', 'piece', 'totalWeightKg', 20, 'currency', 'CAD'
      )
    ),
    'allocations', jsonb_build_array(
      jsonb_build_object(
        'id', gen_random_uuid(), 'cargoItemId', v_cargo,
        'pickupStopId', v_pickup, 'deliveryStopId', v_delivery,
        'quantity', 2, 'quantityUnit', 'piece'
      )
    )
  );
end;
$$;

-- Shared customer, provider, policy, pricing, and payment-method fixtures.
do $$
declare
  v_customer_org uuid := '81000000-0000-0000-0000-000000000001';
  v_customer uuid := '81000000-0000-0000-0000-000000000002';
  v_provider_org uuid := '82000000-0000-0000-0000-000000000001';
  v_driver_profile uuid := '82000000-0000-0000-0000-000000000002';
  v_provider uuid := '82000000-0000-0000-0000-000000000003';
  v_driver uuid := '82000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '82000000-0000-0000-0000-000000000005';
  v_policy_set uuid := '83000000-0000-0000-0000-000000000001';
  v_policy uuid := '83000000-0000-0000-0000-000000000002';
  v_pricing_set uuid := '84000000-0000-0000-0000-000000000001';
  v_pricing_version uuid := '84000000-0000-0000-0000-000000000002';
begin
  insert into organizations (id, organization_key, kind, legal_name, display_name) values
    (v_customer_org, 'block-b-customer', 'CUSTOMER', 'Block B Customer Ltd.', 'Block B Customer'),
    (v_provider_org, 'block-b-provider', 'INDEPENDENT_PROVIDER', 'Block B Driver Ltd.', 'Block B Driver');
  insert into profiles (id, display_name) values
    (v_customer, 'Block B Customer'),
    (v_driver_profile, 'Block B Assigned Driver');
  insert into organization_memberships (organization_id, profile_id, status) values
    (v_customer_org, v_customer, 'ACTIVE'),
    (v_provider_org, v_driver_profile, 'ACTIVE');
  insert into service_providers (id, organization_id, kind, status, approved_at) values
    (v_provider, v_provider_org, 'INDEPENDENT_DRIVER', 'ACTIVE', clock_timestamp());
  insert into drivers (id, profile_id, status, public_label) values
    (v_driver, v_driver_profile, 'ACTIVE', 'Block B Driver');
  insert into provider_drivers (provider_id, driver_id, status) values
    (v_provider, v_driver, 'ACTIVE');
  insert into vehicles (id, provider_id, vehicle_key, status, vehicle_class, capacity_weight_kg) values
    (v_vehicle, v_provider, 'block-b-van', 'ACTIVE', 'CARGO_VAN', 1000);
  insert into policy_sets (id, policy_key, name) values
    (v_policy_set, 'BLOCK_B_POLICY', 'Block B test policy');
  insert into policy_versions (
    id, policy_set_id, version_no, publication_status, effective_from,
    config, config_sha256, legal_review_required,
    created_by_profile_id, approved_by_profile_id, approved_at
  ) values (
    v_policy, v_policy_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object(
      'evidenceRequirements', jsonb_build_object('photo', true),
      'cancellationRules', jsonb_build_object('preCustody', 'versioned'),
      'refundRules', jsonb_build_object('driverShare', 0.80),
      'timingWindows', jsonb_build_object('pickupGraceSeconds', 1800),
      'riskRules', '{}'::jsonb
    ), repeat('8', 64), false, v_customer, v_customer, clock_timestamp()
  );
  insert into pricing_rule_sets (
    id, rule_key, name, pricing_source, service_level, currency
  ) values (
    v_pricing_set, 'BLOCK_B_FLEX_GUARD', 'Block B Flex guardrail',
    'HAULVIA_GUARDRAIL', 'FLEX', 'CAD'
  );
  insert into pricing_rule_versions (
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values (
    v_pricing_version, v_pricing_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object('floorAmount', 50, 'ceilingAmount', 200, 'absoluteCapAmount', 300),
    repeat('9', 64), v_customer, v_customer, clock_timestamp()
  );
  insert into customer_payment_method_refs (
    id, customer_organization_id, customer_profile_id,
    external_provider, external_reference, verified_at
  ) values (
    '85000000-0000-0000-0000-000000000001', v_customer_org, v_customer,
    'TESTPAY', 'pm-block-b', clock_timestamp()
  );
end;
$$;

create or replace function pg_temp.seed_assigned(p_label text)
returns jsonb language plpgsql as $$
declare
  v_customer_org uuid := '81000000-0000-0000-0000-000000000001';
  v_customer uuid := '81000000-0000-0000-0000-000000000002';
  v_provider uuid := '82000000-0000-0000-0000-000000000003';
  v_driver uuid := '82000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '82000000-0000-0000-0000-000000000005';
  v_policy uuid := '83000000-0000-0000-0000-000000000002';
  v_rule uuid := '84000000-0000-0000-0000-000000000002';
  v_shipment uuid;
  v_route uuid := gen_random_uuid();
  v_pickup uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_leg uuid := gen_random_uuid();
  v_cargo uuid := gen_random_uuid();
  v_allocation uuid := gen_random_uuid();
  v_review uuid;
  v_snapshot uuid;
  v_assignment uuid;
begin
  insert into shipments (
    customer_organization_id, customer_profile_id, shipment_state,
    pickup_timing, service_level, currency, marketplace_deadline
  ) values (
    v_customer_org, v_customer, 'DRIVER_ASSIGNED',
    'ASAP', 'FLEX', 'CAD', clock_timestamp() + interval '1 day'
  ) returning id into v_shipment;
  update shipment_marketplace_axes set state = 'CLOSED' where shipment_id = v_shipment;
  update shipment_customer_payment_axes
  set state = 'SECURED', secured_amount = 120, currency = 'CAD'
  where shipment_id = v_shipment;

  insert into route_versions (
    id, shipment_id, version_no, status, change_reason, created_by_profile_id
  ) values (v_route, v_shipment, 1, 'DRAFT', 'Block B fixture ' || p_label, v_customer);
  insert into route_stops (
    id, route_version_id, sequence_no, stop_type, address_line1, city,
    region_code, country_code, latitude, longitude, geofence_radius_m,
    verification_profile
  ) values
    (v_pickup, v_route, 1, 'PICKUP', '100 Pickup Avenue', 'Saskatoon',
     'SK', 'CA', 52.1332, -106.6700, 200, jsonb_build_object('photo', true)),
    (v_delivery, v_route, 2, 'DELIVERY', '200 Delivery Street', 'Regina',
     'SK', 'CA', 50.4452, -104.6189, 200, jsonb_build_object('pin', true));
  insert into route_legs (
    id, route_version_id, sequence_no, from_stop_id, to_stop_id,
    planned_distance_km, planned_duration_seconds
  ) values (v_leg, v_route, 1, v_pickup, v_delivery, 260, 10800);
  insert into cargo_items (
    id, route_version_id, cargo_line_no, description, quantity,
    quantity_unit, total_weight_kg, currency
  ) values (v_cargo, v_route, 1, 'Block B parcel', 2, 'piece', 20, 'CAD');
  insert into cargo_allocations (
    id, route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id,
    quantity, quantity_unit
  ) values (v_allocation, v_route, v_cargo, v_pickup, v_delivery, 2, 'piece');
  update route_versions set status = 'ACTIVE' where id = v_route;

  insert into shipment_rule_snapshots (
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  ) values (
    v_shipment, v_route, v_policy, jsonb_build_object('photo', true),
    jsonb_build_object('preCustody', 'versioned'),
    jsonb_build_object('driverShare', 0.80),
    jsonb_build_object('pickupGraceSeconds', 1800), '{}'::jsonb, repeat('8',64)
  );
  insert into pricing_reviews (
    shipment_id, route_version_id, pricing_source, pricing_mode, status,
    reviewed_amount, currency, reviewed_at
  ) values (
    v_shipment, v_route, 'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE',
    'PASSED', 120, 'CAD', clock_timestamp()
  ) returning id into v_review;
  insert into shipment_price_snapshots (
    shipment_id, route_version_id, purpose, pricing_source, pricing_mode,
    pricing_rule_version_id, pricing_review_id, subtotal, tax_amount,
    total_amount, currency, breakdown, snapshot_sha256, accepted_at
  ) values (
    v_shipment, v_route, 'ASSIGNMENT', 'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE',
    v_rule, v_review, 120, 0, 120, 'CAD', '[]'::jsonb, repeat('a',64), clock_timestamp()
  ) returning id into v_snapshot;
  insert into assignments (
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    price_snapshot_id, status, agreement_snapshot
  ) values (
    v_shipment, v_route, v_provider, v_driver, v_vehicle,
    v_snapshot, 'ACTIVE', jsonb_build_object('fixture', p_label)
  ) returning id into v_assignment;

  return jsonb_build_object(
    'shipmentId', v_shipment, 'routeVersionId', v_route,
    'pickupStopId', v_pickup, 'deliveryStopId', v_delivery,
    'routeLegId', v_leg, 'cargoItemId', v_cargo,
    'cargoAllocationId', v_allocation, 'assignmentId', v_assignment
  );
end;
$$;

-- B07 failed first pickup requires elapsed grace, contacts, evidence, cargo, and zero custody.
do $$
declare
  v_fixture jsonb := pg_temp.seed_assigned('failed-first-pickup');
  v_shipment uuid := (v_fixture ->> 'shipmentId')::uuid;
  v_route uuid := (v_fixture ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_fixture ->> 'assignmentId')::uuid;
  v_allocation uuid := (v_fixture ->> 'cargoAllocationId')::uuid;
  v_driver uuid := '82000000-0000-0000-0000-000000000002';
  v_result jsonb;
  v_request jsonb;
  v_bad jsonb;
  v_execution uuid;
  v_stop uuid;
  v_execution_version bigint;
begin
  select haulvia_command.command_start_route(
    pg_temp.envelope(v_shipment, v_driver, 'b07-seed-start', 'a')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'occurredAt', clock_timestamp() - interval '2 hours'
    )
  ) into v_result;
  v_execution := (v_result ->> 'routeExecutionId')::uuid;
  v_stop := (v_result ->> 'stopExecutionId')::uuid;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_confirm_arrival_at_first_pickup(
    pg_temp.envelope(v_shipment, v_driver, 'b07-seed-arrival', 'b')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'latitude', 52.1332, 'longitude', -106.6700, 'accuracyM', 5,
      'capturedAt', clock_timestamp() - interval '2 hours',
      'waitingFreeUntil', clock_timestamp() - interval '1 hour',
      'occurredAt', clock_timestamp() - interval '2 hours'
    )
  ) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;

  v_bad := pg_temp.envelope(v_shipment, v_driver, 'neg-b07-grace', 'c')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'targetStopState', 'FAILED', 'occurredAt', clock_timestamp() - interval '90 minutes',
      'gracePeriodEndedAt', clock_timestamp() + interval '1 minute',
      'failureReason', 'Sender did not make the cargo available',
      'responsibilityCode', 'SENDER',
      'contactAttempts', jsonb_build_array(jsonb_build_object('method','PHONE','capturedAt',clock_timestamp())),
      'affectedCargo', jsonb_build_array(jsonb_build_object('cargoAllocationId',v_allocation)),
      'custodyBalance', jsonb_build_object('onboardQuantity',0),
      'evidence', jsonb_build_array(jsonb_build_object(
        'type','PHOTO','storageObjectKey','block-b/failure/closed.jpg',
        'contentSha256',repeat('c',64),'capturedAt',clock_timestamp()
      ))
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_report_failed_first_pickup(%L::jsonb)', v_bad::text),
    'WAITING_PERIOD_ACTIVE', 'B07 cannot report failure before the grace period is complete'
  );

  v_request := pg_temp.envelope(v_shipment, v_driver, 'b07-main', 'd')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'targetStopState', 'EXCEPTION_REVIEW', 'occurredAt', clock_timestamp(),
      'gracePeriodEndedAt', clock_timestamp() - interval '1 hour',
      'failureReason', 'Sender did not make the cargo available',
      'responsibilityCode', 'SENDER',
      'contactAttempts', jsonb_build_array(
        jsonb_build_object('method','PHONE','outcome','NO_ANSWER','capturedAt',clock_timestamp()-interval '50 minutes')
      ),
      'affectedCargo', jsonb_build_array(jsonb_build_object('cargoAllocationId',v_allocation,'quantity',2)),
      'custodyBalance', jsonb_build_object('onboardQuantity',0,'quantityUnit','piece'),
      'evidence', jsonb_build_array(jsonb_build_object(
        'type','PHOTO','storageObjectKey','block-b/failure/unavailable.jpg',
        'contentSha256',repeat('d',64),'capturedAt',clock_timestamp()
      ))
    );
  select haulvia_command.command_report_failed_first_pickup(v_request) into v_result;
  perform pg_temp.assert_true(
    (select state = 'EXCEPTION_REVIEW' from stop_executions where id = v_stop)
    and (select count(*) = 1 from route_exceptions where id = (v_result ->> 'routeExceptionId')::uuid)
    and (select count(*) = 1 from workflow_holds where id = (v_result ->> 'workflowHoldId')::uuid and status = 'ACTIVE')
    and not exists(select 1 from cargo_movements where shipment_id = v_shipment),
    'B07 retains the failed attempt, evidence, affected cargo, exception, hold, and zero custody'
  );
end;
$$;

-- B08 customer cancellation before route start records the displayed financial decision.
do $$
declare
  v_fixture jsonb := pg_temp.seed_assigned('customer-cancel');
  v_shipment uuid := (v_fixture ->> 'shipmentId')::uuid;
  v_route uuid := (v_fixture ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_fixture ->> 'assignmentId')::uuid;
  v_customer uuid := '81000000-0000-0000-0000-000000000002';
  v_result jsonb;
begin
  select haulvia_command.command_cancel_before_any_custody(
    pg_temp.envelope(v_shipment, v_customer, 'b08-main', 'e')
    || jsonb_build_object(
      'actorOrganizationId', '81000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'policyVersionId', '83000000-0000-0000-0000-000000000002',
      'reason', 'Customer no longer needs this route',
      'responsibilityCode', 'CUSTOMER',
      'cancellationChargeAmount', 20, 'customerRefundAmount', 100,
      'driverCompensationAmount', 16, 'currency', 'CAD',
      'decisionSnapshot', jsonb_build_object('displayedCharge',20,'driverSharePercent',80)
    )
  ) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState') = 'CANCELLED'
    and (select status = 'CANCELLED' from assignments where id = v_assignment)
    and (select state = 'PARTIALLY_REFUNDED' and secured_amount = 20 from shipment_customer_payment_axes where shipment_id = v_shipment)
    and (select count(*) = 1 from pre_custody_financial_decisions where shipment_id = v_shipment)
    and (select count(*) = 1 from workflow_jobs where shipment_id = v_shipment and job_code = 'SETTLE_PRE_CUSTODY_CANCELLATION'),
    'B08 cancels before custody and records versioned charge/refund/compensation plus settlement work'
  );
end;
$$;

-- B09-B11 driver release remains paused until customer edit and deliberate repost.
do $$
declare
  v_fixture jsonb := pg_temp.seed_assigned('driver-release-edit-repost');
  v_shipment uuid := (v_fixture ->> 'shipmentId')::uuid;
  v_route uuid := (v_fixture ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_fixture ->> 'assignmentId')::uuid;
  v_driver uuid := '82000000-0000-0000-0000-000000000002';
  v_customer uuid := '81000000-0000-0000-0000-000000000002';
  v_result jsonb;
  v_execution uuid;
  v_execution_version bigint;
  v_new_route uuid;
begin
  select haulvia_command.command_start_route(
    pg_temp.envelope(v_shipment, v_driver, 'b09-seed-start', 'f')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'occurredAt', clock_timestamp()
    )
  ) into v_result;
  v_execution := (v_result ->> 'routeExecutionId')::uuid;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;

  select haulvia_command.command_release_driver_before_any_custody(
    pg_temp.envelope(v_shipment, null, 'b09-main', '0')
    || jsonb_build_object(
      'workerAuthority', 'ROUTE_OPERATIONS_WORKER',
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'policyVersionId', '83000000-0000-0000-0000-000000000002',
      'releaseOutcome', 'POSTED_PAUSED',
      'reason', 'Assigned driver became unavailable before pickup',
      'responsibilityCode', 'DRIVER',
      'cancellationChargeAmount', 0, 'customerRefundAmount', 120,
      'driverCompensationAmount', 0, 'currency', 'CAD',
      'decisionSnapshot', jsonb_build_object('customerCost',0,'automaticRepublish',false)
    )
  ) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState') = 'POSTED'
    and (v_result ->> 'marketplaceState') = 'PAUSED'
    and (v_result ->> 'automaticRepublish')::boolean = false
    and (select status = 'CANCELLED' from assignments where id = v_assignment)
    and (select state = 'CANCELLED' from route_executions where id = v_execution)
    and (select state = 'RELEASED' from shipment_customer_payment_axes where shipment_id = v_shipment),
    'B09 closes assignment/execution, releases funds, and pauses without automatic repost'
  );

  select haulvia_command.command_edit_paused_after_driver_cancellation(
    pg_temp.envelope(v_shipment, v_customer, 'b10-main', '1')
    || jsonb_build_object(
      'actorOrganizationId', '81000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId', v_route,
      'reason', 'Customer changed destination after driver cancellation',
      'routePlan', pg_temp.make_block_b_plan('Moose Jaw'),
      'policyVersionId', '83000000-0000-0000-0000-000000000002',
      'marketplaceDeadline', clock_timestamp() + interval '8 hours',
      'pricingSource', 'HAULVIA_GUARDRAIL', 'pricingMode', 'NOT_APPLICABLE',
      'pricingRuleVersionId', '84000000-0000-0000-0000-000000000002',
      'amount', 130, 'subtotal', 130, 'taxAmount', 0, 'currency', 'CAD',
      'breakdown', '[]'::jsonb, 'snapshotSha256', repeat('1',64)
    )
  ) into v_result;
  v_new_route := (v_result ->> 'routeVersionId')::uuid;
  perform pg_temp.assert_true(
    v_new_route <> v_route
    and (select status = 'SUPERSEDED' from route_versions where id = v_route)
    and (select status = 'ACTIVE' from route_versions where id = v_new_route)
    and (select state = 'PAUSED' from shipment_marketplace_axes where shipment_id = v_shipment)
    and (select count(*) = 1 from assignments where id = v_assignment and status = 'CANCELLED'),
    'B10 versions and reprices the edited route while preserving PAUSED and old assignment history'
  );

  select haulvia_command.command_repost_paused_shipment(
    pg_temp.envelope(v_shipment, v_customer, 'b11-main', '2')
    || jsonb_build_object(
      'actorOrganizationId', '81000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId', v_new_route,
      'policyVersionId', '83000000-0000-0000-0000-000000000002',
      'paymentMethodId', '85000000-0000-0000-0000-000000000001',
      'marketplaceDeadline', clock_timestamp() + interval '8 hours',
      'pricingSource', 'HAULVIA_GUARDRAIL', 'pricingMode', 'NOT_APPLICABLE',
      'pricingRuleVersionId', '84000000-0000-0000-0000-000000000002',
      'amount', 130, 'subtotal', 130, 'taxAmount', 0, 'currency', 'CAD',
      'breakdown', '[]'::jsonb, 'snapshotSha256', repeat('2',64)
    )
  ) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState') = 'POSTED'
    and (v_result ->> 'marketplaceState') = 'ACTIVE'
    and (v_result ->> 'customerPaymentState') = 'METHOD_VERIFIED'
    and (v_result ->> 'oldOffersAndAssignmentsPreserved')::boolean
    and not exists(select 1 from assignments where shipment_id = v_shipment and status = 'ACTIVE'),
    'B11 deliberately revalidates route/policy/price/payment and reopens marketplace only'
  );
end;
$$;

-- B12 issue/hold is append-only business evidence and does not move physical state.
do $$
declare
  v_fixture jsonb := pg_temp.seed_assigned('pre-custody-issue');
  v_shipment uuid := (v_fixture ->> 'shipmentId')::uuid;
  v_route uuid := (v_fixture ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_fixture ->> 'assignmentId')::uuid;
  v_driver uuid := '82000000-0000-0000-0000-000000000002';
  v_result jsonb;
  v_bad jsonb;
begin
  select haulvia_command.command_report_pre_custody_issue(
    pg_temp.envelope(v_shipment, v_driver, 'b12-main', '3')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'exceptionCode', 'PICKUP_ACCESS_BLOCKED',
      'description', 'Road closure prevents safe access to the pickup',
      'responsibilityCode', 'EXTERNAL', 'blocksCompletion', true,
      'issueEvidence', jsonb_build_object('reportedAt',clock_timestamp(),'source','driver'),
      'workflowHold', jsonb_build_object(
        'holdCode','ROUTE_ACCESS_REVIEW','reason','Road closure requires route review',
        'blocksMarketplace',false,'blocksRouteMovement',true,'blocksCompletion',true
      )
    )
  ) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState') = 'DRIVER_ASSIGNED'
    and (v_result ->> 'physicalPositionChanged')::boolean = false
    and (select count(*) = 1 from route_exceptions where id = (v_result ->> 'routeExceptionId')::uuid)
    and (select count(*) = 1 from workflow_holds where id = (v_result ->> 'workflowHoldId')::uuid and blocks_route_movement),
    'B12 creates an optional hold and exception without changing shipment or stop position'
  );

  v_bad := pg_temp.envelope(v_shipment, v_driver, 'neg-start-held', '4')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'occurredAt', clock_timestamp()
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_start_route(%L::jsonb)', v_bad::text),
    'WORKFLOW_HELD', 'B01 respects an independent route-movement hold'
  );
end;
$$;

-- Representative authorization, geofence, stale-version, and atomic rollback guards.
do $$
declare
  v_fixture jsonb := pg_temp.seed_assigned('negative-guards');
  v_shipment uuid := (v_fixture ->> 'shipmentId')::uuid;
  v_route uuid := (v_fixture ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_fixture ->> 'assignmentId')::uuid;
  v_driver uuid := '82000000-0000-0000-0000-000000000002';
  v_customer uuid := '81000000-0000-0000-0000-000000000002';
  v_result jsonb;
  v_bad jsonb;
  v_execution uuid;
  v_stop uuid;
  v_execution_version bigint;
begin
  v_bad := pg_temp.envelope(v_shipment, v_customer, 'neg-start-customer', '5')
    || jsonb_build_object('expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment);
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_start_route(%L::jsonb)', v_bad::text),
    'NOT_AUTHORIZED', 'customer cannot perform the assigned-driver route start'
  );
  select haulvia_command.command_start_route(
    pg_temp.envelope(v_shipment, v_driver, 'negative-seed-start', '6')
    || jsonb_build_object('expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment)
  ) into v_result;
  v_execution := (v_result ->> 'routeExecutionId')::uuid;
  v_stop := (v_result ->> 'stopExecutionId')::uuid;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;

  v_bad := pg_temp.envelope(v_shipment, v_driver, 'neg-arrival-stale', '7')
    || jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_execution_version-1,
      'expectedStopExecutionId',v_stop,'latitude',52.1332,'longitude',-106.6700,
      'capturedAt',clock_timestamp(),'waitingFreeUntil',clock_timestamp()+interval '30 minutes'
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_confirm_arrival_at_first_pickup(%L::jsonb)', v_bad::text),
    'STALE_ROUTE_EXECUTION_VERSION', 'stale execution position loses before any stop write'
  );

  v_bad := pg_temp.envelope(v_shipment, v_driver, 'neg-arrival-radius', '8')
    || jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_execution_version,
      'expectedStopExecutionId',v_stop,'latitude',50.4452,'longitude',-104.6189,
      'accuracyM',5,'capturedAt',clock_timestamp(),
      'waitingFreeUntil',clock_timestamp()+interval '30 minutes'
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_confirm_arrival_at_first_pickup(%L::jsonb)', v_bad::text),
    'LOCATION_NOT_VERIFIED', 'out-of-radius arrival needs a documented exception'
  );
  perform pg_temp.assert_true(
    (select state = 'EN_ROUTE' from stop_executions where id = v_stop)
    and not exists(select 1 from stop_evidence e join stop_attempts a on a.id=e.stop_attempt_id where a.stop_execution_id=v_stop),
    'failed arrival leaves stop and evidence unchanged'
  );
end;
$$;

-- B01-B06 main path, including correction, replay, evidence, and first custody.
do $$
declare
  v_fixture jsonb := pg_temp.seed_assigned('main-custody');
  v_shipment uuid := (v_fixture ->> 'shipmentId')::uuid;
  v_route uuid := (v_fixture ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_fixture ->> 'assignmentId')::uuid;
  v_allocation uuid := (v_fixture ->> 'cargoAllocationId')::uuid;
  v_driver uuid := '82000000-0000-0000-0000-000000000002';
  v_result jsonb;
  v_start_request jsonb;
  v_request jsonb;
  v_bad jsonb;
  v_execution uuid;
  v_stop uuid;
  v_attempt uuid;
  v_execution_version bigint;
begin
  v_start_request := pg_temp.envelope(v_shipment, v_driver, 'b01-main', '1')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'occurredAt', clock_timestamp(), 'etaAt', clock_timestamp() + interval '30 minutes'
    );
  select haulvia_command.command_start_route(v_start_request) into v_result;
  v_execution := (v_result ->> 'routeExecutionId')::uuid;
  v_stop := (v_result ->> 'stopExecutionId')::uuid;
  v_attempt := (v_result ->> 'stopAttemptId')::uuid;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState') = 'ROUTE_IN_PROGRESS'
    and (select state = 'ACTIVE' from route_executions where id = v_execution)
    and (select state = 'EN_ROUTE' from stop_executions where id = v_stop)
    and (select count(*) = 1 from tracking_sessions where route_execution_id = v_execution and ended_at is null),
    'B01 starts one active route, first stop, attempt, position, and tracking session'
  );
  select haulvia_command.command_start_route(v_start_request) into v_result;
  perform pg_temp.assert_true((v_result ->> 'replayed')::boolean, 'B01 duplicate retry returns the original result');

  v_request := pg_temp.envelope(v_shipment, v_driver, 'b02-first', '2')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'latitude', 52.1332, 'longitude', -106.6700, 'accuracyM', 5,
      'capturedAt', clock_timestamp() - interval '2 hours',
      'waitingFreeUntil', clock_timestamp() - interval '1 hour',
      'occurredAt', clock_timestamp() - interval '2 hours'
    );
  select haulvia_command.command_confirm_arrival_at_first_pickup(v_request) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state = 'ARRIVED' from stop_executions where id = v_stop)
    and (select count(*) = 2 from stop_evidence where stop_attempt_id = v_attempt and evidence_type in ('GPS','TIMESTAMP'))
    and (select count(*) = 1 from workflow_jobs where shipment_id = v_shipment and job_code = 'STOP_WAITING_GRACE_EXPIRES'),
    'B02 verifies arrival evidence and starts the waiting timer job'
  );

  v_request := pg_temp.envelope(v_shipment, v_driver, 'b03-main', '3')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'reason', 'Driver tapped Arrived at the wrong entrance'
    );
  select haulvia_command.command_correct_first_stop_arrival(v_request) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state = 'EN_ROUTE' from stop_executions where id = v_stop)
    and (select status = 'CANCELLED' from workflow_jobs where shipment_id = v_shipment and job_code = 'STOP_WAITING_GRACE_EXPIRES' limit 1)
    and (select count(*) = 1 from stop_attempt_events where stop_attempt_id = v_attempt and command_name = 'confirmArrivalAtFirstPickup'),
    'B03 reverses current arrival without erasing the original event/evidence'
  );

  v_request := pg_temp.envelope(v_shipment, v_driver, 'b02-second', '4')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'latitude', 52.1332, 'longitude', -106.6700, 'accuracyM', 5,
      'capturedAt', clock_timestamp(),
      'waitingFreeUntil', clock_timestamp() + interval '30 minutes',
      'occurredAt', clock_timestamp()
    );
  select haulvia_command.command_confirm_arrival_at_first_pickup(v_request) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;

  v_request := pg_temp.envelope(v_shipment, v_driver, 'b04-main', '5')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'contactConfirmed', true, 'locationConfirmed', true, 'cargoAvailable', true,
      'occurredAt', clock_timestamp()
    );
  select haulvia_command.command_start_first_pickup_service(v_request) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state = 'SERVICE_IN_PROGRESS' from stop_executions where id = v_stop),
    'B04 starts service only after contact/location/cargo checks'
  );

  v_bad := pg_temp.envelope(v_shipment, v_driver, 'neg-correct-after-service', '6')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop, 'reason', 'Too late to correct'
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_correct_first_stop_arrival(%L::jsonb)', v_bad::text),
    'INVALID_STATE', 'arrival correction is unavailable after service starts'
  );

  v_request := pg_temp.envelope(v_shipment, v_driver, 'b05-main', '7')
    || jsonb_build_object(
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop,
      'driverConfirmed', true, 'releasingPersonName', 'Test Sender',
      'occurredAt', clock_timestamp(),
      'evidence', jsonb_build_array(
        jsonb_build_object(
          'type', 'PHOTO', 'storageObjectKey', 'block-b/main/cargo.jpg',
          'contentSha256', repeat('b',64), 'capturedAt', clock_timestamp()
        ),
        jsonb_build_object(
          'type', 'QUANTITY', 'structuredValue', jsonb_build_object('quantity',2,'unit','piece'),
          'capturedAt', clock_timestamp()
        ),
        jsonb_build_object(
          'type', 'CONDITION', 'structuredValue', jsonb_build_object('condition','GOOD'),
          'capturedAt', clock_timestamp()
        ),
        jsonb_build_object(
          'type', 'PIN', 'structuredValue', jsonb_build_object('verified',true),
          'capturedAt', clock_timestamp()
        )
      )
    );
  select haulvia_command.command_submit_first_pickup_evidence(v_request) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state = 'EVIDENCE_PENDING' from stop_executions where id = v_stop)
    and (select count(*) = 8 from stop_evidence where stop_attempt_id = v_attempt)
    and (select count(*) = 2 from stop_evidence where stop_attempt_id = v_attempt and evidence_type = 'GPS'),
    'B05 appends the complete baseline bundle while retaining both arrival evidence sets'
  );

  v_request := pg_temp.envelope(v_shipment, null, 'b06-main', '8')
    || jsonb_build_object(
      'workerAuthority', 'EVIDENCE_REVIEWER',
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'expectedStopExecutionId', v_stop, 'reviewerLabel', 'Acceptance reviewer',
      'loads', jsonb_build_array(
        jsonb_build_object(
          'cargoAllocationId', v_allocation, 'quantity', 2, 'quantityUnit', 'piece',
          'occurredAt', clock_timestamp(),
          'evidenceBundle', jsonb_build_object('stopAttemptId', v_attempt)
        )
      )
    );
  select haulvia_command.command_verify_first_pickup(v_request) into v_result;
  v_execution_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state = 'COMPLETED' from stop_executions where id = v_stop)
    and (select count(*) = 1 from cargo_movements where shipment_id = v_shipment and movement_type = 'LOAD')
    and (select count(*) = 1 from shipment_custody_milestones where shipment_id = v_shipment)
    and (select onboard_quantity = 2 from v_cargo_custody_balance where shipment_id = v_shipment),
    'B06 verifies evidence, posts one LOAD, and establishes immutable first custody'
  );

  v_bad := pg_temp.envelope(v_shipment, '81000000-0000-0000-0000-000000000002', 'neg-cancel-after-custody', '9')
    || jsonb_build_object(
      'actorOrganizationId', '81000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId', v_route, 'expectedAssignmentId', v_assignment,
      'expectedRouteExecutionId', v_execution,
      'expectedRouteExecutionVersion', v_execution_version,
      'policyVersionId', '83000000-0000-0000-0000-000000000002',
      'reason', 'Customer tries to cancel after custody',
      'responsibilityCode', 'CUSTOMER',
      'cancellationChargeAmount', 20, 'customerRefundAmount', 100,
      'driverCompensationAmount', 16, 'currency', 'CAD',
      'decisionSnapshot', jsonb_build_object('displayed', true)
    );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_cancel_before_any_custody(%L::jsonb)', v_bad::text),
    'CUSTODY_EXISTS', 'ordinary cancellation is blocked after first verified LOAD'
  );
  perform pg_temp.assert_true(
    not exists(select 1 from pre_custody_financial_decisions where shipment_id = v_shipment),
    'failed post-custody cancellation leaves no financial decision'
  );
end;
$$;

select pg_temp.assert_true(
  (select count(*) = 12 from (
    values
      ('command_start_route'),
      ('command_confirm_arrival_at_first_pickup'),
      ('command_correct_first_stop_arrival'),
      ('command_start_first_pickup_service'),
      ('command_submit_first_pickup_evidence'),
      ('command_verify_first_pickup'),
      ('command_report_failed_first_pickup'),
      ('command_cancel_before_any_custody'),
      ('command_release_driver_before_any_custody'),
      ('command_edit_paused_after_driver_cancellation'),
      ('command_repost_paused_shipment'),
      ('command_report_pre_custody_issue')
  ) expected(name)
  where exists (
    select 1 from information_schema.routines r
    where r.routine_schema = 'haulvia_command' and r.routine_name = expected.name
  )),
  'all 12 Block B matrix rows have named trusted command entry points'
);

select pg_temp.assert_true(
  (select count(*) >= 32 from information_schema.routines
   where routine_schema = 'haulvia_command' and routine_name like 'command_%'),
  'Block A and Block B expose at least their 32 named wrappers in total'
);

select pg_temp.assert_true(
  not exists (
    select 1 from information_schema.routine_privileges
    where routine_schema = 'haulvia_command' and grantee = 'PUBLIC'
  ),
  'trusted command routines remain unavailable to PUBLIC'
);

select pg_temp.assert_true(
  (select count(*) >= 1 from shipment_custody_milestones)
  and (select count(*) >= 2 from pre_custody_financial_decisions)
  and (select count(*) >= 1 from route_exceptions)
  and (select count(*) >= 1 from workflow_holds)
  and (select count(*) >= 1 from route_updates),
  'Block B retains custody, financial decision, exception, hold, and position evidence'
);

rollback;
