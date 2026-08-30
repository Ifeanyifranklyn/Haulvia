-- Haulvia Block A command acceptance suite v1
-- Requires foundation v1 and Block A command migration v1.
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

create or replace function pg_temp.make_plan(p_destination_city text default 'Regina')
returns jsonb language plpgsql as $$
declare
  v_pickup uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_cargo uuid := gen_random_uuid();
begin
  return jsonb_build_object(
    'plannedDistanceKm', 260,
    'plannedDurationSeconds', 10800,
    'stops', jsonb_build_array(
      jsonb_build_object(
        'id', v_pickup, 'stableStopKey', gen_random_uuid(), 'sequenceNo', 1,
        'stopType', 'PICKUP', 'addressLine1', '100 Test Avenue',
        'city', 'Saskatoon', 'regionCode', 'SK', 'countryCode', 'CA',
        'verificationProfile', jsonb_build_object('photo', true)
      ),
      jsonb_build_object(
        'id', v_delivery, 'stableStopKey', gen_random_uuid(), 'sequenceNo', 2,
        'stopType', 'DELIVERY', 'addressLine1', '200 Test Street',
        'city', p_destination_city, 'regionCode', 'SK', 'countryCode', 'CA',
        'verificationProfile', jsonb_build_object('pin', true)
      )
    ),
    'legs', jsonb_build_array(
      jsonb_build_object(
        'id', gen_random_uuid(), 'sequenceNo', 1,
        'fromStopId', v_pickup, 'toStopId', v_delivery,
        'plannedDistanceKm', 260, 'plannedDurationSeconds', 10800
      )
    ),
    'cargoItems', jsonb_build_array(
      jsonb_build_object(
        'id', v_cargo, 'stableCargoKey', gen_random_uuid(), 'cargoLineNo', 1,
        'description', 'Acceptance test parcel', 'quantity', 2,
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

-- Shared authority, policy, pricing, payment, and provider fixtures.
do $$
declare
  v_customer_org uuid := '10000000-0000-0000-0000-000000000001';
  v_customer uuid := '10000000-0000-0000-0000-000000000002';
  v_ind_org uuid := '20000000-0000-0000-0000-000000000001';
  v_ind_profile uuid := '20000000-0000-0000-0000-000000000002';
  v_ind_provider uuid := '20000000-0000-0000-0000-000000000003';
  v_ind_driver uuid := '20000000-0000-0000-0000-000000000004';
  v_ind_vehicle uuid := '20000000-0000-0000-0000-000000000005';
  v_partner_org uuid := '30000000-0000-0000-0000-000000000001';
  v_partner_profile uuid := '30000000-0000-0000-0000-000000000002';
  v_partner_provider uuid := '30000000-0000-0000-0000-000000000003';
  v_partner_driver uuid := '30000000-0000-0000-0000-000000000004';
  v_partner_vehicle uuid := '30000000-0000-0000-0000-000000000005';
  v_policy_set uuid := '40000000-0000-0000-0000-000000000001';
  v_policy_version uuid := '40000000-0000-0000-0000-000000000002';
  v_guard_set uuid := '50000000-0000-0000-0000-000000000001';
  v_guard_version uuid := '50000000-0000-0000-0000-000000000002';
  v_fixed_set uuid := '50000000-0000-0000-0000-000000000003';
  v_fixed_version uuid := '50000000-0000-0000-0000-000000000004';
  v_rate_card uuid := '60000000-0000-0000-0000-000000000001';
  v_rate_version uuid := '60000000-0000-0000-0000-000000000002';
  v_reauth uuid := '60000000-0000-0000-0000-000000000003';
begin
  insert into organizations (id, organization_key, kind, legal_name, display_name) values
    (v_customer_org, 'block-a-customer', 'CUSTOMER', 'Block A Customer Ltd.', 'Block A Customer'),
    (v_ind_org, 'block-a-independent', 'INDEPENDENT_PROVIDER', 'Independent Test Driver Ltd.', 'Independent Test Driver'),
    (v_partner_org, 'block-a-partner', 'COURIER_PARTNER', 'Partner Test Courier Ltd.', 'Partner Test Courier');
  insert into profiles (id, display_name) values
    (v_customer, 'Block A Customer'),
    (v_ind_profile, 'Independent Driver'),
    (v_partner_profile, 'Partner Driver');
  insert into organization_memberships (organization_id, profile_id, status) values
    (v_customer_org, v_customer, 'ACTIVE'),
    (v_ind_org, v_ind_profile, 'ACTIVE'),
    (v_partner_org, v_partner_profile, 'ACTIVE');
  insert into service_providers (id, organization_id, kind, status, approved_at) values
    (v_ind_provider, v_ind_org, 'INDEPENDENT_DRIVER', 'ACTIVE', clock_timestamp()),
    (v_partner_provider, v_partner_org, 'COURIER_PARTNER', 'ACTIVE', clock_timestamp());
  insert into drivers (id, profile_id, status, public_label) values
    (v_ind_driver, v_ind_profile, 'ACTIVE', 'Independent Driver'),
    (v_partner_driver, v_partner_profile, 'ACTIVE', 'Partner Driver');
  insert into provider_drivers (provider_id, driver_id, status) values
    (v_ind_provider, v_ind_driver, 'ACTIVE'),
    (v_partner_provider, v_partner_driver, 'ACTIVE');
  insert into vehicles (id, provider_id, vehicle_key, status, vehicle_class, capacity_weight_kg) values
    (v_ind_vehicle, v_ind_provider, 'ind-test-van', 'ACTIVE', 'CARGO_VAN', 1000),
    (v_partner_vehicle, v_partner_provider, 'partner-test-van', 'ACTIVE', 'CARGO_VAN', 1000);

  insert into policy_sets (id, policy_key, name) values
    (v_policy_set, 'BLOCK_A_POLICY', 'Block A test policy');
  insert into policy_versions (
    id, policy_set_id, version_no, publication_status, effective_from, config,
    config_sha256, legal_review_required, created_by_profile_id,
    approved_by_profile_id, approved_at
  ) values (
    v_policy_version, v_policy_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object(
      'evidenceRequirements', jsonb_build_object('photo', true),
      'cancellationRules', jsonb_build_object('preAssignment', 'allowed'),
      'refundRules', '{}'::jsonb, 'timingWindows', '{}'::jsonb, 'riskRules', '{}'::jsonb
    ), repeat('1', 64), false, v_customer, v_customer, clock_timestamp()
  );
  insert into pricing_rule_sets (id, rule_key, name, pricing_source, service_level, currency) values
    (v_guard_set, 'BLOCK_A_FLEX_GUARD', 'Block A Flex guardrail', 'HAULVIA_GUARDRAIL', 'FLEX', 'CAD'),
    (v_fixed_set, 'BLOCK_A_FLEX_FIXED', 'Block A Flex fixed', 'HAULVIA_FIXED', 'FLEX', 'CAD');
  insert into pricing_rule_versions (
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values
    (v_guard_version, v_guard_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('floorAmount', 50, 'ceilingAmount', 200, 'absoluteCapAmount', 300),
      repeat('2', 64), v_customer, v_customer, clock_timestamp()),
    (v_fixed_version, v_fixed_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('fixedAmount', 150), repeat('3', 64), v_customer, v_customer, clock_timestamp());
  insert into reauth_sessions (
    id, profile_id, organization_id, method, verified_at, expires_at
  ) values (
    v_reauth, v_partner_profile, v_partner_org, 'MFA',
    clock_timestamp() - interval '1 minute', clock_timestamp() + interval '1 hour'
  );
  insert into partner_rate_cards (
    id, provider_id, rate_card_key, name, service_level, pricing_mode,
    region_code, vehicle_class, currency
  ) values (
    v_rate_card, v_partner_provider, 'partner-flex-sk', 'Partner Flex SK',
    'FLEX', 'FLEX_NEGOTIABLE', 'SK', 'CARGO_VAN', 'CAD'
  );
  insert into partner_rate_card_versions (
    id, rate_card_id, version_no, publication_status, effective_from,
    review_note, source_sha256, created_by_profile_id, approved_by_profile_id,
    approved_at, reauth_session_id
  ) values (
    v_rate_version, v_rate_card, 1, 'DRAFT', clock_timestamp() - interval '1 day',
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    v_partner_profile, clock_timestamp(), v_reauth
  );
  insert into partner_rate_card_lines (
    rate_card_version_id, line_no, component_type, label, amount, unit
  ) values (v_rate_version, 1, 'BASE', 'Base route amount', 140, 'route');
  update partner_rate_card_versions
  set publication_status = 'APPROVED'
  where id = v_rate_version;
  insert into customer_payment_method_refs (
    id, customer_organization_id, customer_profile_id, external_provider,
    external_reference, verified_at
  ) values (
    '70000000-0000-0000-0000-000000000001', v_customer_org, v_customer,
    'TESTPAY', 'pm-block-a', clock_timestamp()
  );
end;
$$;

-- Main independent-driver path covers A01-A04, A06-A08, A11, A13-A17.
do $$
declare
  v_customer uuid := '10000000-0000-0000-0000-000000000002';
  v_customer_org uuid := '10000000-0000-0000-0000-000000000001';
  v_provider_org uuid := '20000000-0000-0000-0000-000000000001';
  v_provider_profile uuid := '20000000-0000-0000-0000-000000000002';
  v_provider uuid := '20000000-0000-0000-0000-000000000003';
  v_driver uuid := '20000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '20000000-0000-0000-0000-000000000005';
  v_policy uuid := '40000000-0000-0000-0000-000000000002';
  v_rule uuid := '50000000-0000-0000-0000-000000000002';
  v_payment_method uuid := '70000000-0000-0000-0000-000000000001';
  v_shipment uuid;
  v_route uuid;
  v_new_route uuid;
  v_thread uuid;
  v_revision uuid;
  v_reservation uuid;
  v_intent uuid;
  v_result jsonb;
  v_request jsonb;
  v_bad jsonb;
  v_lock bigint;
begin
  insert into shipments (
    customer_organization_id, customer_profile_id, pickup_timing, service_level, currency
  ) values (v_customer_org, v_customer, 'ASAP', 'FLEX', 'CAD') returning id into v_shipment;

  v_request := jsonb_build_object(
    'commandId', gen_random_uuid(), 'idempotencyKey', 'a01-main', 'requestHash', repeat('a',64),
    'actorProfileId', v_customer, 'actorOrganizationId', v_customer_org,
    'shipmentId', v_shipment, 'expectedShipmentVersion', 0,
    'requestedAt', clock_timestamp(), 'routePlan', pg_temp.make_plan()
  );
  select haulvia_command.command_save_draft(v_request) into v_result;
  v_route := (v_result ->> 'routeVersionId')::uuid;
  perform pg_temp.assert_true(v_route is not null and (v_result ->> 'replayed')::boolean = false, 'A01 saves a new draft route');
  select haulvia_command.command_save_draft(v_request) into v_result;
  perform pg_temp.assert_true((v_result ->> 'replayed')::boolean, 'A01 retry replays before stale-version evaluation');
  v_bad := v_request || jsonb_build_object('requestHash', repeat('f',64));
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_save_draft(%L::jsonb)',v_bad::text),
    'IDEMPOTENCY_KEY_REUSED','same idempotency key cannot carry a different payload hash'
  );

  select lock_version into v_lock from shipments where id = v_shipment;
  v_request := jsonb_build_object(
    'commandId', gen_random_uuid(), 'idempotencyKey', 'a03-main', 'requestHash', repeat('b',64),
    'actorProfileId', v_customer, 'actorOrganizationId', v_customer_org,
    'shipmentId', v_shipment, 'expectedShipmentVersion', v_lock,
    'expectedRouteVersionId', v_route, 'requestedAt', clock_timestamp(),
    'allocations', (
      select jsonb_agg(jsonb_build_object(
        'id', gen_random_uuid(), 'cargoItemId', ci.id,
        'pickupStopId', p.id, 'deliveryStopId', d.id,
        'quantity', ci.quantity, 'quantityUnit', ci.quantity_unit
      ))
      from cargo_items ci
      cross join lateral (select id from route_stops where route_version_id=v_route and stop_type='PICKUP' limit 1) p
      cross join lateral (select id from route_stops where route_version_id=v_route and stop_type='DELIVERY' limit 1) d
      where ci.route_version_id = v_route
    )
  );
  select haulvia_command.command_assign_cargo_to_stops(v_request) into v_result;
  perform pg_temp.assert_true((v_result ->> 'allocationCount')::integer = 1, 'A03 replaces and balances allocations');

  select lock_version into v_lock from shipments where id = v_shipment;
  v_request := jsonb_build_object(
    'commandId', gen_random_uuid(), 'idempotencyKey', 'a02-main', 'requestHash', repeat('c',64),
    'actorProfileId', v_customer, 'actorOrganizationId', v_customer_org,
    'shipmentId', v_shipment, 'expectedShipmentVersion', v_lock,
    'expectedRouteVersionId', v_route, 'requestedAt', clock_timestamp(),
    'reason', 'Customer changed the draft route', 'routePlan', pg_temp.make_plan('Moose Jaw')
  );
  select haulvia_command.command_edit_draft_route(v_request) into v_result;
  v_new_route := (v_result ->> 'routeVersionId')::uuid;
  perform pg_temp.assert_true(
    (select status='SUPERSEDED' from route_versions where id=v_route)
    and (select status='DRAFT' from route_versions where id=v_new_route),
    'A02 retains superseded draft and creates the next draft'
  );
  v_route := v_new_route;

  select lock_version into v_lock from shipments where id = v_shipment;
  v_request := jsonb_build_object(
    'commandId', gen_random_uuid(), 'idempotencyKey', 'a04-main', 'requestHash', repeat('d',64),
    'actorProfileId', v_customer, 'actorOrganizationId', v_customer_org,
    'shipmentId', v_shipment, 'expectedShipmentVersion', v_lock,
    'expectedRouteVersionId', v_route, 'requestedAt', clock_timestamp(),
    'paymentMethodId', v_payment_method, 'policyVersionId', v_policy,
    'marketplaceDeadline', clock_timestamp()+interval '4 hours',
    'pricingSource', 'HAULVIA_GUARDRAIL', 'pricingMode', 'NOT_APPLICABLE',
    'pricingRuleVersionId', v_rule, 'amount', 120, 'subtotal', 120,
    'taxAmount', 0, 'currency', 'CAD', 'breakdown', '[]'::jsonb,
    'snapshotSha256', repeat('d',64)
  );
  select haulvia_command.command_post_shipment(v_request) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState') = 'POSTED' and (v_result ->> 'marketplaceState') = 'ACTIVE',
    'A04 atomically activates route, posting, payment method, and marketplace'
  );

  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-unauthorized-pause','requestHash',repeat('0',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp(),
    'reason','Provider cannot pause customer marketplace'
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_pause_marketplace(%L::jsonb)',v_bad::text),
    'NOT_AUTHORIZED','provider cannot exercise customer ownership'
  );

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_pause_marketplace(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a06-main','requestHash',repeat('e',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp(),
    'reason','Customer reviewing marketplace options'
  )) into v_result;
  perform pg_temp.assert_true((v_result->>'marketplaceState')='PAUSED','A06 pauses without changing macro state');
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_resume_marketplace(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a07-main','requestHash',repeat('f',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp()
  )) into v_result;
  perform pg_temp.assert_true((v_result->>'marketplaceState')='ACTIVE','A07 revalidates and resumes');

  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-below-floor','requestHash',repeat('1',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'providerId',v_provider,'driverId',v_driver,'vehicleId',v_vehicle,
    'coversWholeRoute',true,'validUntil',clock_timestamp()+interval '1 hour',
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_rule,
    'amount',40,'subtotal',40,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('1',64)
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_submit_independent_flex_offer(%L::jsonb)',v_bad::text),
    'PRICING_REVIEW_REQUIRED','offer below approved floor is rejected atomically'
  );
  perform pg_temp.assert_true(
    not exists(select 1 from command_idempotency where idempotency_key='neg-below-floor'),
    'failed command leaves no partial idempotency row'
  );

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_submit_independent_flex_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a08-main','requestHash',repeat('0',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'providerId',v_provider,'driverId',v_driver,'vehicleId',v_vehicle,
    'coversWholeRoute',true,'validUntil',clock_timestamp()+interval '2 hours',
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_rule,
    'amount',125,'subtotal',125,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('5',64)
  )) into v_result;
  v_thread := (v_result->>'offerThreadId')::uuid;
  v_revision := (v_result->>'offerRevisionId')::uuid;
  perform pg_temp.assert_true((v_result->>'shipmentState')='NEGOTIATING','A08 first offer starts negotiation');

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_counter_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a11-counter-main','requestHash',repeat('6',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'responseToRevisionId',v_revision,
    'validUntil',clock_timestamp()+interval '90 minutes','pricingRuleVersionId',v_rule,
    'amount',115,'subtotal',115,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('6',64)
  )) into v_result;
  v_revision := (v_result->>'offerRevisionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_revise_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a11-revise-main','requestHash',repeat('7',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'responseToRevisionId',v_revision,
    'validUntil',clock_timestamp()+interval '80 minutes','pricingRuleVersionId',v_rule,
    'amount',118,'subtotal',118,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('7',64)
  )) into v_result;
  v_revision := (v_result->>'offerRevisionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_counter_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a11-counter-two','requestHash',repeat('2',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'responseToRevisionId',v_revision,
    'validUntil',clock_timestamp()+interval '70 minutes','pricingRuleVersionId',v_rule,
    'amount',116,'subtotal',116,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('2',64)
  )) into v_result;
  v_revision := (v_result->>'offerRevisionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_revise_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a11-revise-two','requestHash',repeat('3',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'responseToRevisionId',v_revision,
    'validUntil',clock_timestamp()+interval '60 minutes','pricingRuleVersionId',v_rule,
    'amount',118,'subtotal',118,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('3',64)
  )) into v_result;
  v_revision := (v_result->>'offerRevisionId')::uuid;
  perform pg_temp.assert_true((select count(*)=5 from offer_revisions where offer_thread_id=v_thread),'A11 retains two counters and two revisions');
  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-third-counter','requestHash',repeat('4',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'responseToRevisionId',v_revision,
    'validUntil',clock_timestamp()+interval '50 minutes','pricingRuleVersionId',v_rule,
    'amount',117,'subtotal',117,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('4',64)
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_counter_offer(%L::jsonb)',v_bad::text),
    'COUNTER_LIMIT_REACHED','third customer counter is rejected'
  );

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_materially_edit_negotiation(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a13-main','requestHash',repeat('8',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'reason','Customer materially changed delivery route',
    'routePlan',pg_temp.make_plan('Prince Albert'),'policyVersionId',v_policy,
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_rule,
    'amount',120,'subtotal',120,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,
    'snapshotSha256',repeat('8',64)
  )) into v_result;
  v_route := (v_result->>'routeVersionId')::uuid;
  perform pg_temp.assert_true(
    (v_result->>'shipmentState')='POSTED' and (v_result->>'marketplaceState')='PAUSED'
    and (select status='RECONFIRMATION_REQUIRED' from offer_threads where id=v_thread),
    'A13 pauses, versions route, and requires reconfirmation'
  );

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_reconfirm_offer_or_firm_match(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a14-main','requestHash',repeat('9',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'validUntil',clock_timestamp()+interval '1 hour',
    'pricingRuleVersionId',v_rule,'amount',118,'subtotal',118,'taxAmount',0,'currency','CAD',
    'breakdown','[]'::jsonb,'snapshotSha256',repeat('a',64)
  )) into v_result;
  v_revision := (v_result->>'offerRevisionId')::uuid;
  perform pg_temp.assert_true((v_result->>'shipmentState')='NEGOTIATING' and (v_result->>'marketplaceState')='PAUSED','A14 reconfirms while preserving pause');

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_reserve_selection(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a15-first','requestHash',repeat('b',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'selectedRevisionId',v_revision,
    'paymentMethodId',v_payment_method,'reservationExpiresAt',clock_timestamp()+interval '30 minutes',
    'reservationSnapshotSha256',repeat('b',64),'paymentProvider','TESTPAY',
    'paymentProviderIdempotencyKey','pay-a15-first'
  )) into v_result;
  v_reservation := (v_result->>'reservationId')::uuid;
  v_intent := (v_result->>'paymentIntentId')::uuid;
  perform pg_temp.assert_true((v_result->>'marketplaceState')='RESERVED','A15 creates the single reservation and intent');

  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-reservation-conflict','requestHash',repeat('5',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'selectedRevisionId',v_revision,
    'paymentMethodId',v_payment_method,'reservationExpiresAt',clock_timestamp()+interval '20 minutes',
    'reservationSnapshotSha256',repeat('5',64),'paymentProvider','TESTPAY',
    'paymentProviderIdempotencyKey','pay-conflict'
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_reserve_selection(%L::jsonb)',v_bad::text),
    'RESERVATION_CONFLICT','second active reservation loses'
  );

  select lock_version into v_lock from shipments where id=v_shipment;
  v_request := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a17-main','requestHash',repeat('c',64),
    'actorProfileId',null,'workerAuthority','PAYMENT_WORKER','shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp(),
    'paymentIntentId',v_intent,'reservationId',v_reservation,
    'providerEventId','evt-a17-main','failureCategory','DECLINED'
  );
  select haulvia_command.command_release_failed_reservation(v_request) into v_result;
  perform pg_temp.assert_true(
    (v_result->>'marketplaceState')='PAUSED'
    and (select status='RELEASED' from offer_reservations where id=v_reservation),
    'A17 releases payment failure and restores PAUSED'
  );
  select haulvia_command.command_release_failed_reservation(v_request) into v_result;
  perform pg_temp.assert_true((v_result->>'replayed')::boolean,'A17 duplicate worker event replays safely');

  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_reserve_selection(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a15-second','requestHash',repeat('d',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_customer_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'offerThreadId',v_thread,'selectedRevisionId',v_revision,
    'paymentMethodId',v_payment_method,'reservationExpiresAt',clock_timestamp()+interval '30 minutes',
    'reservationSnapshotSha256',repeat('d',64),'paymentProvider','TESTPAY',
    'paymentProviderIdempotencyKey','pay-a15-second'
  )) into v_result;
  v_reservation := (v_result->>'reservationId')::uuid;
  v_intent := (v_result->>'paymentIntentId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-partial-funding','requestHash',repeat('6',64),
    'actorProfileId',null,'workerAuthority','PAYMENT_WORKER','shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'paymentIntentId',v_intent,'reservationId',v_reservation,
    'providerEventId','evt-partial-funding','securedAmount',117,'currency','CAD',
    'transactionType','CAPTURE','assignmentSnapshotSha256',repeat('6',64)
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_confirm_paid_assignment(%L::jsonb)',v_bad::text),
    'FUNDING_NOT_SECURED','partial funding cannot create assignment'
  );
  perform pg_temp.assert_true(
    not exists(select 1 from assignments where shipment_id=v_shipment),
    'failed funding attempt leaves no orphan assignment'
  );
  select haulvia_command.command_confirm_paid_assignment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a16-main','requestHash',repeat('e',64),
    'actorProfileId',null,'workerAuthority','PAYMENT_WORKER','shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'paymentIntentId',v_intent,'reservationId',v_reservation,
    'providerEventId','evt-a16-main','securedAmount',118,'currency','CAD',
    'transactionType','CAPTURE','assignmentSnapshotSha256',repeat('e',64),
    'agreementSnapshot',jsonb_build_object('termsVersion','v1')
  )) into v_result;
  perform pg_temp.assert_true(
    (v_result->>'shipmentState')='DRIVER_ASSIGNED'
    and (v_result->>'customerPaymentState')='SECURED'
    and (select count(*)=1 from assignments where shipment_id=v_shipment and status='ACTIVE'),
    'A16 commits exact funding and exactly one active whole-route assignment'
  );
end;
$$;

-- A05 is isolated so posted-route editing cannot interfere with offer tests.
do $$
declare
  v_customer uuid := '10000000-0000-0000-0000-000000000002';
  v_org uuid := '10000000-0000-0000-0000-000000000001';
  v_policy uuid := '40000000-0000-0000-0000-000000000002';
  v_rule uuid := '50000000-0000-0000-0000-000000000002';
  v_pm uuid := '70000000-0000-0000-0000-000000000001';
  v_shipment uuid; v_route uuid; v_result jsonb; v_lock bigint;
begin
  insert into shipments(customer_organization_id,customer_profile_id,pickup_timing,service_level,currency)
  values(v_org,v_customer,'ASAP','FLEX','CAD') returning id into v_shipment;
  select haulvia_command.command_save_draft(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a05-seed-save','requestHash',repeat('1',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',0,'requestedAt',clock_timestamp(),'routePlan',pg_temp.make_plan()
  )) into v_result; v_route := (v_result->>'routeVersionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_post_shipment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a05-seed-post','requestHash',repeat('2',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'paymentMethodId',v_pm,'policyVersionId',v_policy,'marketplaceDeadline',clock_timestamp()+interval '3 hours',
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_rule,
    'amount',120,'subtotal',120,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('3',64)
  )) into v_result;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_edit_posted_shipment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a05-main','requestHash',repeat('4',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'reason','Customer changed posted delivery details','routePlan',pg_temp.make_plan('Yorkton'),
    'policyVersionId',v_policy,'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE',
    'pricingRuleVersionId',v_rule,'amount',130,'subtotal',130,'taxAmount',0,'currency','CAD',
    'breakdown','[]'::jsonb,'snapshotSha256',repeat('4',64)
  )) into v_result;
  perform pg_temp.assert_true(
    (v_result->>'shipmentState')='POSTED'
    and (v_result->>'routeVersionId')::uuid<>v_route
    and (select status='SUPERSEDED' from route_versions where id=v_route),
    'A05 versions a posted route without changing macro state'
  );
end;
$$;

-- Partner offer, last-offer close, and pre-assignment cancellation: A09/A12/A18.
do $$
declare
  v_customer uuid := '10000000-0000-0000-0000-000000000002';
  v_org uuid := '10000000-0000-0000-0000-000000000001';
  v_partner_org uuid := '30000000-0000-0000-0000-000000000001';
  v_partner_profile uuid := '30000000-0000-0000-0000-000000000002';
  v_provider uuid := '30000000-0000-0000-0000-000000000003';
  v_driver uuid := '30000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '30000000-0000-0000-0000-000000000005';
  v_policy uuid := '40000000-0000-0000-0000-000000000002';
  v_rule uuid := '50000000-0000-0000-0000-000000000002';
  v_rate uuid := '60000000-0000-0000-0000-000000000002';
  v_pm uuid := '70000000-0000-0000-0000-000000000001';
  v_shipment uuid; v_route uuid; v_thread uuid; v_result jsonb; v_bad jsonb; v_lock bigint;
begin
  insert into shipments(customer_organization_id,customer_profile_id,pickup_timing,service_level,currency)
  values(v_org,v_customer,'ASAP','FLEX','CAD') returning id into v_shipment;
  select haulvia_command.command_save_draft(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a09-seed-save','requestHash',repeat('5',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',0,'requestedAt',clock_timestamp(),'routePlan',pg_temp.make_plan()
  )) into v_result; v_route := (v_result->>'routeVersionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_post_shipment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a09-seed-post','requestHash',repeat('6',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'paymentMethodId',v_pm,'policyVersionId',v_policy,'marketplaceDeadline',clock_timestamp()+interval '3 hours',
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_rule,
    'amount',120,'subtotal',120,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('6',64)
  )) into v_result;
  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-partner-scope','requestHash',repeat('6',64),
    'actorProfileId',v_partner_profile,'actorOrganizationId',v_partner_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'providerId',v_provider,'driverId',v_driver,'vehicleId',v_vehicle,
    'coversWholeRoute',true,'validUntil',clock_timestamp()+interval '1 hour',
    'pricingSource','PARTNER_RATE_CARD','pricingMode','FLEX_NEGOTIABLE','rateCardVersionId',v_rate,
    'regionCode','AB','calculationSha256',repeat('6',64),'amount',140,'subtotal',140,
    'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('6',64)
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_submit_partner_flex_offer(%L::jsonb)',v_bad::text),
    'PRICING_REVIEW_REQUIRED','partner rate card route scope mismatch is rejected'
  );
  select haulvia_command.command_submit_partner_flex_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a09-main','requestHash',repeat('7',64),
    'actorProfileId',v_partner_profile,'actorOrganizationId',v_partner_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'providerId',v_provider,'driverId',v_driver,'vehicleId',v_vehicle,
    'coversWholeRoute',true,'validUntil',clock_timestamp()+interval '1 hour',
    'pricingSource','PARTNER_RATE_CARD','pricingMode','FLEX_NEGOTIABLE','rateCardVersionId',v_rate,
    'regionCode','SK','calculationSha256',repeat('7',64),'amount',140,'subtotal',140,
    'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('7',64)
  )) into v_result; v_thread := (v_result->>'offerThreadId')::uuid;
  perform pg_temp.assert_true(v_thread is not null,'A09 accepts an effective scoped partner Flex rate card');
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_close_last_active_offer(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a12-main','requestHash',repeat('8',64),
    'actorProfileId',null,'workerAuthority','OFFER_WORKER','shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp(),'offerThreadId',v_thread,
    'closeCause','PROVIDER_WITHDREW'
  )) into v_result;
  perform pg_temp.assert_true((v_result->>'shipmentState')='POSTED','A12 returns to POSTED when the last offer closes');
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_cancel_pre_assignment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a18-main','requestHash',repeat('9',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'reason','Customer no longer requires delivery','policyVersionId',v_policy,
    'cancellationSnapshot',jsonb_build_object('source','acceptance')
  )) into v_result;
  perform pg_temp.assert_true(
    (v_result->>'shipmentState')='CANCELLED'
    and (select count(*)=1 from shipment_cancellation_snapshots where shipment_id=v_shipment),
    'A18 closes axes and retains cancellation evidence'
  );
end;
$$;

-- Firm match and cancellation of its active reservation: A10 plus A18 race side.
do $$
declare
  v_customer uuid := '10000000-0000-0000-0000-000000000002';
  v_org uuid := '10000000-0000-0000-0000-000000000001';
  v_provider_org uuid := '20000000-0000-0000-0000-000000000001';
  v_provider_profile uuid := '20000000-0000-0000-0000-000000000002';
  v_provider uuid := '20000000-0000-0000-0000-000000000003';
  v_driver uuid := '20000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '20000000-0000-0000-0000-000000000005';
  v_policy uuid := '40000000-0000-0000-0000-000000000002';
  v_guard uuid := '50000000-0000-0000-0000-000000000002';
  v_fixed uuid := '50000000-0000-0000-0000-000000000004';
  v_pm uuid := '70000000-0000-0000-0000-000000000001';
  v_shipment uuid; v_route uuid; v_result jsonb; v_lock bigint;
begin
  insert into shipments(customer_organization_id,customer_profile_id,pickup_timing,service_level,currency)
  values(v_org,v_customer,'ASAP','FLEX','CAD') returning id into v_shipment;
  select haulvia_command.command_save_draft(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a10-seed-save','requestHash',repeat('a',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',0,'requestedAt',clock_timestamp(),'routePlan',pg_temp.make_plan()
  )) into v_result; v_route := (v_result->>'routeVersionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_post_shipment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a10-seed-post','requestHash',repeat('b',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'paymentMethodId',v_pm,'policyVersionId',v_policy,'marketplaceDeadline',clock_timestamp()+interval '3 hours',
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_guard,
    'amount',120,'subtotal',120,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('b',64)
  )) into v_result;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_accept_firm_route_match(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a10-main','requestHash',repeat('c',64),
    'actorProfileId',v_provider_profile,'actorOrganizationId',v_provider_org,
    'shipmentId',v_shipment,'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,
    'requestedAt',clock_timestamp(),'providerId',v_provider,'driverId',v_driver,'vehicleId',v_vehicle,
    'coversWholeRoute',true,'pricingSource','HAULVIA_FIXED','pricingMode','NOT_APPLICABLE',
    'pricingRuleVersionId',v_fixed,'amount',150,'subtotal',150,'taxAmount',0,'currency','CAD',
    'breakdown','[]'::jsonb,'snapshotSha256',repeat('c',64),
    'reservationSnapshotSha256',repeat('d',64),'paymentMethodId',v_pm,
    'reservationExpiresAt',clock_timestamp()+interval '30 minutes',
    'paymentProvider','TESTPAY','paymentProviderIdempotencyKey','pay-a10-main'
  )) into v_result;
  perform pg_temp.assert_true(
    (v_result->>'marketplaceState')='RESERVED'
    and (select revision_kind='FIRM_MATCH' from offer_revisions where id=(v_result->>'offerRevisionId')::uuid),
    'A10 creates a non-counterable firm match reservation'
  );
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_cancel_pre_assignment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a18-firm','requestHash',repeat('d',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'reason','Customer cancelled before firm assignment','policyVersionId',v_policy
  )) into v_result;
  perform pg_temp.assert_true((v_result->>'shipmentState')='CANCELLED','A18 can atomically release a pre-assignment firm reservation');
end;
$$;

-- Worker expiry plus representative authorization, stale, pricing, and terminal negatives.
do $$
declare
  v_customer uuid := '10000000-0000-0000-0000-000000000002';
  v_org uuid := '10000000-0000-0000-0000-000000000001';
  v_policy uuid := '40000000-0000-0000-0000-000000000002';
  v_rule uuid := '50000000-0000-0000-0000-000000000002';
  v_pm uuid := '70000000-0000-0000-0000-000000000001';
  v_shipment uuid; v_route uuid; v_result jsonb; v_lock bigint;
  v_bad jsonb;
begin
  insert into shipments(customer_organization_id,customer_profile_id,pickup_timing,service_level,currency)
  values(v_org,v_customer,'ASAP','FLEX','CAD') returning id into v_shipment;
  select haulvia_command.command_save_draft(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a19-seed-save','requestHash',repeat('e',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',0,'requestedAt',clock_timestamp(),'routePlan',pg_temp.make_plan()
  )) into v_result; v_route := (v_result->>'routeVersionId')::uuid;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_post_shipment(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a19-seed-post','requestHash',repeat('f',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'expectedRouteVersionId',v_route,'requestedAt',clock_timestamp(),
    'paymentMethodId',v_pm,'policyVersionId',v_policy,'marketplaceDeadline',clock_timestamp()+interval '3 hours',
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE','pricingRuleVersionId',v_rule,
    'amount',120,'subtotal',120,'taxAmount',0,'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('f',64)
  )) into v_result;

  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-early-expiry','requestHash',repeat('f',64),
    'actorProfileId',null,'workerAuthority','EXPIRY_WORKER','shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp()
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_expire_listing(%L::jsonb)',v_bad::text),
    'DEADLINE_EXPIRED','early scheduler call cannot expire an active listing'
  );

  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-stale','requestHash',repeat('0',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock-1,'requestedAt',clock_timestamp(),'reason','Stale pause request'
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_pause_marketplace(%L::jsonb)',v_bad::text),
    'STALE_SHIPMENT_VERSION','stale version is rejected'
  );

  update shipments set marketplace_deadline=clock_timestamp()-interval '1 minute' where id=v_shipment;
  select lock_version into v_lock from shipments where id=v_shipment;
  select haulvia_command.command_expire_listing(jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','a19-main','requestHash',repeat('1',64),
    'actorProfileId',null,'workerAuthority','EXPIRY_WORKER','shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp()
  )) into v_result;
  perform pg_temp.assert_true((v_result->>'shipmentState')='EXPIRED' and (v_result->>'marketplaceState')='EXPIRED','A19 terminally expires an elapsed listing');

  select lock_version into v_lock from shipments where id=v_shipment;
  v_bad := jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey','neg-terminal','requestHash',repeat('2',64),
    'actorProfileId',v_customer,'actorOrganizationId',v_org,'shipmentId',v_shipment,
    'expectedShipmentVersion',v_lock,'requestedAt',clock_timestamp(),'reason','Cannot pause terminal shipment'
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_pause_marketplace(%L::jsonb)',v_bad::text),
    'INVALID_STATE','terminal shipment cannot reopen'
  );
end;
$$;

select pg_temp.assert_true(
  (select count(*) = 19 from (
    values
      ('command_save_draft'),('command_edit_draft_route'),('command_assign_cargo_to_stops'),
      ('command_post_shipment'),('command_edit_posted_shipment'),('command_pause_marketplace'),
      ('command_resume_marketplace'),('command_submit_independent_flex_offer'),
      ('command_submit_partner_flex_offer'),('command_accept_firm_route_match'),
      ('command_counter_offer'),('command_close_last_active_offer'),
      ('command_materially_edit_negotiation'),('command_reconfirm_offer_or_firm_match'),
      ('command_reserve_selection'),('command_confirm_paid_assignment'),
      ('command_release_failed_reservation'),('command_cancel_pre_assignment'),
      ('command_expire_listing')
  ) expected(name)
  where exists (
    select 1 from information_schema.routines r
    where r.routine_schema='haulvia_command' and r.routine_name=expected.name
  )),
  'all 19 matrix rows have named command entry points (A11 also exposes reviseOffer)'
);

select pg_temp.assert_true(
  (select count(*) >= 1 from notification_events)
  and (select count(*) >= 1 from workflow_jobs)
  and (select count(*) >= 1 from audit_events where command_name <> 'createShipment'),
  'commands atomically retain notifications, jobs, and audit evidence'
);

select pg_temp.assert_true(
  not exists (
    select 1 from information_schema.routine_privileges
    where routine_schema = 'haulvia_command' and grantee = 'PUBLIC'
  ),
  'trusted command routines are not executable by PUBLIC'
);

rollback;
