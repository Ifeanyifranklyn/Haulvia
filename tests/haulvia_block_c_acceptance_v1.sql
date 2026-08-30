-- Haulvia Block C command acceptance suite v1
-- Requires foundation v1 plus Block A, Block B, and Block C migrations.
-- Pure PostgreSQL, no pgTAP dependency. All fixtures are rolled back.

begin;
set local search_path = haulvia, haulvia_command, public;

create or replace function pg_temp.assert_true(p_condition boolean,p_message text)
returns void language plpgsql as $$
begin
  if p_condition is distinct from true then
    raise exception 'ASSERT_TRUE failed: %',p_message;
  end if;
end;
$$;

create or replace function pg_temp.expect_error_code(p_sql text,p_code text,p_message text)
returns void language plpgsql as $$
declare
  v_detail text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_detail=pg_exception_detail;
    if coalesce(v_detail,'') like '%"code": "'||p_code||'"%' then
      return;
    end if;
    raise exception 'EXPECT_ERROR failed (%): expected %, got detail %, message %',
      p_message,p_code,v_detail,sqlerrm;
  end;
  raise exception 'EXPECT_ERROR failed (%): statement succeeded',p_message;
end;
$$;

create or replace function pg_temp.envelope(
  p_shipment_id uuid,p_actor_profile_id uuid,p_key text,p_hash_character text
)
returns jsonb language sql as $$
  select jsonb_build_object(
    'commandId',gen_random_uuid(),'idempotencyKey',p_key,
    'requestHash',repeat(p_hash_character,64),'actorProfileId',p_actor_profile_id,
    'shipmentId',p_shipment_id,'expectedShipmentVersion',s.lock_version,
    'requestedAt',clock_timestamp()
  ) from haulvia.shipments s where s.id=p_shipment_id;
$$;

-- Shared customer, provider, policy, pricing, and payment fixtures.
do $$
declare
  v_customer_org uuid := '91000000-0000-0000-0000-000000000001';
  v_customer uuid := '91000000-0000-0000-0000-000000000002';
  v_provider_org uuid := '92000000-0000-0000-0000-000000000001';
  v_driver_profile uuid := '92000000-0000-0000-0000-000000000002';
  v_provider uuid := '92000000-0000-0000-0000-000000000003';
  v_driver uuid := '92000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '92000000-0000-0000-0000-000000000005';
  v_policy_set uuid := '93000000-0000-0000-0000-000000000001';
  v_policy uuid := '93000000-0000-0000-0000-000000000002';
  v_pricing_set uuid := '94000000-0000-0000-0000-000000000001';
  v_pricing_version uuid := '94000000-0000-0000-0000-000000000002';
begin
  insert into organizations(id,organization_key,kind,legal_name,display_name) values
    (v_customer_org,'block-c-customer','CUSTOMER','Block C Customer Ltd.','Block C Customer'),
    (v_provider_org,'block-c-provider','INDEPENDENT_PROVIDER','Block C Driver Ltd.','Block C Driver');
  insert into profiles(id,display_name) values
    (v_customer,'Block C Customer'),(v_driver_profile,'Block C Assigned Driver');
  insert into organization_memberships(organization_id,profile_id,status) values
    (v_customer_org,v_customer,'ACTIVE'),(v_provider_org,v_driver_profile,'ACTIVE');
  insert into service_providers(id,organization_id,kind,status,approved_at) values
    (v_provider,v_provider_org,'INDEPENDENT_DRIVER','ACTIVE',clock_timestamp());
  insert into drivers(id,profile_id,status,public_label) values
    (v_driver,v_driver_profile,'ACTIVE','Block C Driver');
  insert into provider_drivers(provider_id,driver_id,status) values
    (v_provider,v_driver,'ACTIVE');
  insert into vehicles(
    id,provider_id,vehicle_key,status,vehicle_class,capacity_weight_kg
  ) values (v_vehicle,v_provider,'block-c-van','ACTIVE','CARGO_VAN',1000);
  insert into policy_sets(id,policy_key,name) values
    (v_policy_set,'BLOCK_C_POLICY','Block C test policy');
  insert into policy_versions(
    id,policy_set_id,version_no,publication_status,effective_from,config,
    config_sha256,legal_review_required,created_by_profile_id,
    approved_by_profile_id,approved_at
  ) values (
    v_policy,v_policy_set,1,'APPROVED',clock_timestamp()-interval '1 day',
    jsonb_build_object(
      'evidenceRequirements',jsonb_build_object('photo',true),
      'cancellationRules',jsonb_build_object('preCustody','versioned'),
      'refundRules',jsonb_build_object('driverShare',0.8),
      'timingWindows',jsonb_build_object(
        'pickupGraceSeconds',1800,'etaNotificationThresholdSeconds',60,
        'deliveryReviewSeconds',86400
      ),'riskRules','{}'::jsonb
    ),repeat('8',64),false,v_customer,v_customer,clock_timestamp()
  );
  insert into pricing_rule_sets(
    id,rule_key,name,pricing_source,service_level,currency
  ) values (
    v_pricing_set,'BLOCK_C_FLEX_GUARD','Block C Flex guardrail',
    'HAULVIA_GUARDRAIL','FLEX','CAD'
  );
  insert into pricing_rule_versions(
    id,pricing_rule_set_id,version_no,publication_status,effective_from,
    rule_config,rule_sha256,created_by_profile_id,approved_by_profile_id,approved_at
  ) values (
    v_pricing_version,v_pricing_set,1,'APPROVED',clock_timestamp()-interval '1 day',
    jsonb_build_object('floorAmount',0,'ceilingAmount',300,'absoluteCapAmount',500),
    repeat('9',64),v_customer,v_customer,clock_timestamp()
  );
end;
$$;

create or replace function pg_temp.seed_assigned(p_label text,p_contactless boolean default true)
returns jsonb language plpgsql as $$
declare
  v_customer_org uuid := '91000000-0000-0000-0000-000000000001';
  v_customer uuid := '91000000-0000-0000-0000-000000000002';
  v_provider uuid := '92000000-0000-0000-0000-000000000003';
  v_driver uuid := '92000000-0000-0000-0000-000000000004';
  v_vehicle uuid := '92000000-0000-0000-0000-000000000005';
  v_policy uuid := '93000000-0000-0000-0000-000000000002';
  v_rule uuid := '94000000-0000-0000-0000-000000000002';
  v_shipment uuid;
  v_route uuid := gen_random_uuid();
  v_pickup1 uuid := gen_random_uuid();
  v_pickup2 uuid := gen_random_uuid();
  v_delivery uuid := gen_random_uuid();
  v_pickup1_key uuid := gen_random_uuid();
  v_pickup2_key uuid := gen_random_uuid();
  v_delivery_key uuid := gen_random_uuid();
  v_leg1 uuid := gen_random_uuid();
  v_leg2 uuid := gen_random_uuid();
  v_cargo1 uuid := gen_random_uuid();
  v_cargo2 uuid := gen_random_uuid();
  v_cargo1_key uuid := gen_random_uuid();
  v_cargo2_key uuid := gen_random_uuid();
  v_allocation1 uuid := gen_random_uuid();
  v_allocation2 uuid := gen_random_uuid();
  v_review uuid;
  v_snapshot uuid;
  v_assignment uuid;
begin
  insert into shipments(
    customer_organization_id,customer_profile_id,shipment_state,pickup_timing,
    service_level,currency,marketplace_deadline
  ) values (
    v_customer_org,v_customer,'DRIVER_ASSIGNED','ASAP','FLEX','CAD',
    clock_timestamp()+interval '1 day'
  ) returning id into v_shipment;
  update shipment_marketplace_axes set state='CLOSED' where shipment_id=v_shipment;
  update shipment_customer_payment_axes
  set state='SECURED',secured_amount=180,currency='CAD' where shipment_id=v_shipment;
  insert into route_versions(
    id,shipment_id,version_no,status,change_reason,planned_distance_km,
    planned_duration_seconds,created_by_profile_id
  ) values (v_route,v_shipment,1,'DRAFT','Block C fixture '||p_label,300,12000,v_customer);
  insert into route_stops(
    id,route_version_id,stable_stop_key,sequence_no,stop_type,address_line1,city,
    region_code,country_code,latitude,longitude,geofence_radius_m,
    planned_service_seconds,verification_profile
  ) values
    (v_pickup1,v_route,v_pickup1_key,1,'PICKUP','100 First Pickup Road','Saskatoon',
     'SK','CA',52.1332,-106.6700,200,600,jsonb_build_object('photo',true)),
    (v_pickup2,v_route,v_pickup2_key,2,'PICKUP','200 Second Pickup Road','Saskatoon',
     'SK','CA',52.1400,-106.6800,200,900,jsonb_build_object('photo',true)),
    (v_delivery,v_route,v_delivery_key,3,'DELIVERY','300 Delivery Road','Regina',
     'SK','CA',50.4452,-104.6189,200,600,
     jsonb_build_object('photo',true,'contactless',p_contactless,'identifier',p_contactless));
  insert into route_legs(
    id,route_version_id,sequence_no,from_stop_id,to_stop_id,
    planned_distance_km,planned_duration_seconds
  ) values
    (v_leg1,v_route,1,v_pickup1,v_pickup2,10,1200),
    (v_leg2,v_route,2,v_pickup2,v_delivery,250,10800);
  insert into cargo_items(
    id,route_version_id,stable_cargo_key,cargo_line_no,description,quantity,
    quantity_unit,total_weight_kg,currency
  ) values
    (v_cargo1,v_route,v_cargo1_key,1,'First pickup cargo',2,'piece',20,'CAD'),
    (v_cargo2,v_route,v_cargo2_key,2,'Second pickup cargo',1,'piece',15,'CAD');
  insert into cargo_allocations(
    id,route_version_id,cargo_item_id,pickup_stop_id,delivery_stop_id,quantity,quantity_unit
  ) values
    (v_allocation1,v_route,v_cargo1,v_pickup1,v_delivery,2,'piece'),
    (v_allocation2,v_route,v_cargo2,v_pickup2,v_delivery,1,'piece');
  update route_versions set status='ACTIVE' where id=v_route;
  insert into shipment_rule_snapshots(
    shipment_id,route_version_id,policy_version_id,evidence_requirements,
    cancellation_rules,refund_rules,timing_windows,risk_rules,config_sha256
  ) values (
    v_shipment,v_route,v_policy,jsonb_build_object('photo',true),
    jsonb_build_object('preCustody','versioned'),jsonb_build_object('driverShare',0.8),
    jsonb_build_object(
      'pickupGraceSeconds',1800,'etaNotificationThresholdSeconds',60,
      'deliveryReviewSeconds',86400
    ),
    '{}'::jsonb,repeat('8',64)
  );
  insert into pricing_reviews(
    shipment_id,route_version_id,pricing_source,pricing_mode,status,
    reviewed_amount,currency,reviewed_at
  ) values (
    v_shipment,v_route,'HAULVIA_GUARDRAIL','NOT_APPLICABLE','PASSED',180,'CAD',clock_timestamp()
  ) returning id into v_review;
  insert into shipment_price_snapshots(
    shipment_id,route_version_id,purpose,pricing_source,pricing_mode,
    pricing_rule_version_id,pricing_review_id,subtotal,tax_amount,total_amount,
    currency,breakdown,snapshot_sha256,accepted_at
  ) values (
    v_shipment,v_route,'ASSIGNMENT','HAULVIA_GUARDRAIL','NOT_APPLICABLE',
    v_rule,v_review,180,0,180,'CAD','[]'::jsonb,repeat('a',64),clock_timestamp()
  ) returning id into v_snapshot;
  insert into assignments(
    shipment_id,route_version_id,provider_id,driver_id,vehicle_id,
    price_snapshot_id,status,agreement_snapshot
  ) values (
    v_shipment,v_route,v_provider,v_driver,v_vehicle,v_snapshot,'ACTIVE',
    jsonb_build_object('fixture',p_label)
  ) returning id into v_assignment;
  return jsonb_build_object(
    'shipmentId',v_shipment,'routeVersionId',v_route,'assignmentId',v_assignment,
    'pickup1StopId',v_pickup1,'pickup2StopId',v_pickup2,'deliveryStopId',v_delivery,
    'pickup1StableKey',v_pickup1_key,'pickup2StableKey',v_pickup2_key,
    'deliveryStableKey',v_delivery_key,'leg1Id',v_leg1,'leg2Id',v_leg2,
    'cargo1Id',v_cargo1,'cargo2Id',v_cargo2,
    'cargo1StableKey',v_cargo1_key,'cargo2StableKey',v_cargo2_key,
    'allocation1Id',v_allocation1,'allocation2Id',v_allocation2
  );
end;
$$;

create or replace function pg_temp.seed_after_first_pickup(
  p_label text,p_contactless boolean default true
)
returns jsonb language plpgsql as $$
declare
  v_f jsonb := pg_temp.seed_assigned(p_label,p_contactless);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_f ->> 'assignmentId')::uuid;
  v_allocation uuid := (v_f ->> 'allocation1Id')::uuid;
  v_driver uuid := '92000000-0000-0000-0000-000000000002';
  v_result jsonb;
  v_execution uuid;
  v_stop uuid;
  v_version bigint;
begin
  select haulvia_command.command_start_route(
    pg_temp.envelope(v_shipment,v_driver,p_label||'-start','1')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'occurredAt',clock_timestamp()-interval '2 hours','etaAt',clock_timestamp()-interval '110 minutes'
    )
  ) into v_result;
  v_execution := (v_result ->> 'routeExecutionId')::uuid;
  v_stop := (v_result ->> 'stopExecutionId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_confirm_arrival_at_first_pickup(
    pg_temp.envelope(v_shipment,v_driver,p_label||'-arrival1','2')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_stop,'latitude',52.1332,'longitude',-106.6700,
      'accuracyM',5,'capturedAt',clock_timestamp()-interval '100 minutes',
      'waitingFreeUntil',clock_timestamp()-interval '70 minutes',
      'occurredAt',clock_timestamp()-interval '100 minutes'
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_start_first_pickup_service(
    pg_temp.envelope(v_shipment,v_driver,p_label||'-service1','3')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_stop,'contactConfirmed',true,
      'locationConfirmed',true,'cargoAvailable',true
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_submit_first_pickup_evidence(
    pg_temp.envelope(v_shipment,v_driver,p_label||'-evidence1','4')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_stop,'driverConfirmed',true,
      'releasingPersonName','First Sender','evidence',jsonb_build_array(
        jsonb_build_object('type','PHOTO','storageObjectKey',p_label||'/first.jpg','contentSha256',repeat('b',64),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','QUANTITY','structuredValue',jsonb_build_object('quantity',2,'unit','piece'),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','CONDITION','structuredValue',jsonb_build_object('condition','GOOD'),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','PIN','structuredValue',jsonb_build_object('verified',true),'capturedAt',clock_timestamp())
      )
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_verify_first_pickup(
    pg_temp.envelope(v_shipment,null,p_label||'-verify1','5')||jsonb_build_object(
      'workerAuthority','EVIDENCE_REVIEWER','expectedRouteVersionId',v_route,
      'expectedAssignmentId',v_assignment,'expectedRouteExecutionId',v_execution,
      'expectedRouteExecutionVersion',v_version,'expectedStopExecutionId',v_stop,
      'reviewerLabel','Block C acceptance reviewer','loads',jsonb_build_array(
        jsonb_build_object('cargoAllocationId',v_allocation,'quantity',2,
          'quantityUnit','piece','occurredAt',clock_timestamp())
      )
    )
  ) into v_result;
  return v_f||jsonb_build_object(
    'routeExecutionId',v_execution,'routeExecutionVersion',(v_result ->> 'routeExecutionVersion')::bigint,
    'firstStopExecutionId',v_stop,'custodySummary',v_result -> 'custodySummary'
  );
end;
$$;

-- Main ordered-stop path: C01-C07, C12-C14, contactless pending, and route resolution.
do $$
declare
  v_f jsonb := pg_temp.seed_after_first_pickup('c-main',true);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_f ->> 'assignmentId')::uuid;
  v_execution uuid := (v_f ->> 'routeExecutionId')::uuid;
  v_first_stop uuid := (v_f ->> 'firstStopExecutionId')::uuid;
  v_allocation2 uuid := (v_f ->> 'allocation2Id')::uuid;
  v_allocation1 uuid := (v_f ->> 'allocation1Id')::uuid;
  v_driver uuid := '92000000-0000-0000-0000-000000000002';
  v_version bigint := (v_f ->> 'routeExecutionVersion')::bigint;
  v_request jsonb;
  v_result jsonb;
  v_pickup2_stop uuid;
  v_pickup2_attempt uuid;
  v_delivery_stop uuid;
  v_leg uuid;
begin
  v_request := pg_temp.envelope(v_shipment,v_driver,'c01-main','6')||jsonb_build_object(
    'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
    'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
    'expectedStopExecutionId',v_first_stop,'nextStopEtaAt',clock_timestamp()+interval '20 minutes',
    'etaNotificationThresholdSeconds',60
  );
  select haulvia_command.command_advance_to_next_stop(v_request) into v_result;
  v_pickup2_stop := (v_result ->> 'stopExecutionId')::uuid;
  v_pickup2_attempt := (v_result ->> 'stopAttemptId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='EN_ROUTE' from stop_executions where id=v_pickup2_stop)
    and (select count(*)=1 from route_eta_calculations where id=(v_result ->> 'routeEtaCalculationId')::uuid)
    and (select count(*)>=1 from route_stop_eta_predictions where route_execution_id=v_execution),
    'C01 advances the next ordered stop and begins leg plus downstream ETA tracking'
  );
  select haulvia_command.command_advance_to_next_stop(v_request) into v_result;
  perform pg_temp.assert_true((v_result ->> 'replayed')::boolean,'C01 safely replays an identical retry');

  select haulvia_command.command_confirm_arrival_at_stop(
    pg_temp.envelope(v_shipment,v_driver,'c02-first','7')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2_stop,'latitude',52.1400,'longitude',-106.6800,
      'accuracyM',5,'capturedAt',clock_timestamp()-interval '50 minutes',
      'waitingFreeUntil',clock_timestamp()-interval '20 minutes','etaNotificationThresholdSeconds',60
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='ARRIVED' and waiting_free_until is not null from stop_executions where id=v_pickup2_stop)
    and (select count(*)=2 from stop_evidence where stop_attempt_id=v_pickup2_attempt and evidence_type in ('GPS','TIMESTAMP')),
    'C02 records per-stop geofence evidence, arrival, grace deadline, and downstream ETA'
  );

  select haulvia_command.command_correct_stop_arrival(
    pg_temp.envelope(v_shipment,v_driver,'c03-main','8')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2_stop,
      'reason','Driver selected Arrived at the incorrect entrance'
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='EN_ROUTE' and waiting_free_until is null from stop_executions where id=v_pickup2_stop)
    and (select count(*)=1 from stop_attempt_events where stop_attempt_id=v_pickup2_attempt and command_name='confirmArrivalAtStop'),
    'C03 corrects current state while preserving the original arrival event and evidence'
  );

  select haulvia_command.command_confirm_arrival_at_stop(
    pg_temp.envelope(v_shipment,v_driver,'c02-second','9')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2_stop,'latitude',52.1400,'longitude',-106.6800,
      'accuracyM',5,'capturedAt',clock_timestamp()-interval '40 minutes',
      'waitingFreeUntil',clock_timestamp()-interval '10 minutes','etaNotificationThresholdSeconds',60
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_start_stop_service(
    pg_temp.envelope(v_shipment,v_driver,'c04-pickup','a')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2_stop,'contactConfirmed',true,
      'locationConfirmed',true,'cargoAvailable',true
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='SERVICE_IN_PROGRESS' from stop_executions where id=v_pickup2_stop),
    'C04 starts later pickup service after contact, location, movement, and custody checks'
  );

  select haulvia_command.command_submit_stop_evidence(
    pg_temp.envelope(v_shipment,v_driver,'c05-pickup','b')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2_stop,'driverConfirmed',true,
      'releasingPersonName','Second Sender','evidence',jsonb_build_array(
        jsonb_build_object('type','PHOTO','storageObjectKey','c-main/second.jpg','contentSha256',repeat('c',64),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','QUANTITY','structuredValue',jsonb_build_object('quantity',1,'unit','piece'),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','CONDITION','structuredValue',jsonb_build_object('condition','GOOD'),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','PIN','structuredValue',jsonb_build_object('verified',true),'capturedAt',clock_timestamp())
      )
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='EVIDENCE_PENDING' from stop_executions where id=v_pickup2_stop)
    and (select count(*)=8 from stop_evidence where stop_attempt_id=v_pickup2_attempt),
    'C05 preserves the independent later-stop evidence package'
  );

  select haulvia_command.command_verify_pickup_stop(
    pg_temp.envelope(v_shipment,null,'c06-main','c')||jsonb_build_object(
      'workerAuthority','EVIDENCE_REVIEWER','expectedRouteVersionId',v_route,
      'expectedAssignmentId',v_assignment,'expectedRouteExecutionId',v_execution,
      'expectedRouteExecutionVersion',v_version,'expectedStopExecutionId',v_pickup2_stop,
      'reviewerLabel','Block C pickup reviewer','completedAt',clock_timestamp(),
      'etaNotificationThresholdSeconds',60,'loads',jsonb_build_array(
        jsonb_build_object('cargoAllocationId',v_allocation2,'quantity',1,'quantityUnit','piece','occurredAt',clock_timestamp())
      )
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='COMPLETED' from stop_executions where id=v_pickup2_stop)
    and (select count(*)=2 from cargo_movements where shipment_id=v_shipment and movement_type='LOAD')
    and (select sum(onboard_quantity)=3 from v_cargo_custody_balance where shipment_id=v_shipment),
    'C06 atomically verifies pickup evidence, posts LOAD, and updates capacity/custody'
  );
  perform pg_temp.assert_true(
    (select count(*)=1 and min(service_seconds_before)=0 and min(drive_seconds_before)=10800
       from route_stop_eta_predictions
       where route_eta_calculation_id=(v_result ->> 'routeEtaCalculationId')::uuid),
    'C06 downstream ETA excludes service time already completed at the verified pickup'
  );

  select haulvia_command.command_advance_to_next_stop(
    pg_temp.envelope(v_shipment,v_driver,'c01-delivery','d')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2_stop,'nextStopEtaAt',clock_timestamp()+interval '3 hours',
      'etaNotificationThresholdSeconds',60
    )
  ) into v_result;
  v_delivery_stop := (v_result ->> 'stopExecutionId')::uuid;
  v_leg := (v_result ->> 'activeRouteLegId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;

  select haulvia_command.command_record_route_update(
    pg_temp.envelope(v_shipment,v_driver,'c12-main','e')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery_stop,'activeRouteLegId',v_leg,
      'latitude',51.2000,'longitude',-105.5000,'accuracyM',10,'speedKph',90,
      'headingDegrees',140,'capturedAt',clock_timestamp(),'syncedAt',clock_timestamp(),
      'etaAt',clock_timestamp()+interval '3 hours 10 minutes','dwellSeconds',0,
      'delaySeconds',600,'connectivityStatus','ONLINE','source','DEVICE',
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment),
      'etaNotificationThresholdSeconds',60
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select count(*)=1 and bool_and(not is_offline_capture)
       from tracking_points where id=(v_result ->> 'trackingPointId')::bigint)
    and (select delay_seconds=600 from route_updates where id=(v_result ->> 'routeUpdateId')::uuid)
    and (select count(*)>=1 from route_stop_eta_predictions where route_eta_calculation_id=(v_result ->> 'routeEtaCalculationId')::uuid),
    'C12 appends GPS, leg, ETA, dwell/delay/connectivity, custody, and ETA evidence without treating ordinary sync latency as offline capture'
  );

  select haulvia_command.command_report_transit_issue(
    pg_temp.envelope(v_shipment,v_driver,'c13-main','f')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery_stop,'exceptionCode','WEATHER_DELAY',
      'description','Severe rain reduced safe travel speed','responsibilityCode','EXTERNAL',
      'blocksCompletion',false,'issueEvidence',jsonb_build_object('reportedAt',clock_timestamp(),'safeSpeedKph',70),
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment)
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (v_result ->> 'physicalPositionChanged')::boolean=false
    and (select state='EN_ROUTE' from stop_executions where id=v_delivery_stop)
    and (select count(*)=1 from route_exceptions where id=(v_result ->> 'routeExceptionId')::uuid),
    'C13 opens an independent transit exception without erasing stop or cargo position'
  );

  select haulvia_command.command_confirm_arrival_at_stop(
    pg_temp.envelope(v_shipment,v_driver,'c02-delivery','0')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery_stop,'latitude',50.4452,'longitude',-104.6189,
      'accuracyM',5,'capturedAt',clock_timestamp()-interval '40 minutes',
      'waitingFreeUntil',clock_timestamp()-interval '10 minutes','etaNotificationThresholdSeconds',60
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_start_stop_service(
    pg_temp.envelope(v_shipment,v_driver,'c04-delivery','1')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery_stop,'contactConfirmed',true,'locationConfirmed',true
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_submit_stop_evidence(
    pg_temp.envelope(v_shipment,v_driver,'c05-delivery','2')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery_stop,'driverConfirmed',true,
      'evidence',jsonb_build_array(
        jsonb_build_object('type','PHOTO','storageObjectKey','c-main/drop.jpg','contentSha256',repeat('d',64),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','QUANTITY','structuredValue',jsonb_build_object('quantity',3,'unit','piece'),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','IDENTIFIER','structuredValue',jsonb_build_object('packageCount',3),'capturedAt',clock_timestamp()),
        jsonb_build_object('type','CONDITION','structuredValue',jsonb_build_object('condition','GOOD'),'capturedAt',clock_timestamp())
      )
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_verify_delivery_stop(
    pg_temp.envelope(v_shipment,null,'c07-main','3')||jsonb_build_object(
      'workerAuthority','EVIDENCE_REVIEWER','expectedRouteVersionId',v_route,
      'expectedAssignmentId',v_assignment,'expectedRouteExecutionId',v_execution,
      'expectedRouteExecutionVersion',v_version,'expectedStopExecutionId',v_delivery_stop,
      'reviewerLabel','Block C delivery reviewer','completedAt',clock_timestamp(),
      'contactlessDelivery',true,'contactlessAuthorization',jsonb_build_object(
        'preapproved',true,'exactDropLocation','Front secure box','verifiedPhoneIdentity',true,'instructions','Leave inside box'
      ),'receiverTokenHash',repeat('e',64),
      'receiverConfirmationExpiresAt',clock_timestamp()+interval '24 hours',
      'etaNotificationThresholdSeconds',60,'unloads',jsonb_build_array(
        jsonb_build_object('cargoAllocationId',v_allocation1,'quantity',2,'quantityUnit','piece','occurredAt',clock_timestamp()),
        jsonb_build_object('cargoAllocationId',v_allocation2,'quantity',1,'quantityUnit','piece','occurredAt',clock_timestamp())
      )
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='COMPLETED' and delivery_verification_state='PENDING_RECEIVER_CONFIRMATION' from stop_executions where id=v_delivery_stop)
    and (select count(*)=2 from cargo_movements where shipment_id=v_shipment and movement_type='UNLOAD')
    and (select count(*)=2 from cargo_resolution_outcomes where shipment_id=v_shipment and outcome_code='DELIVERED')
    and (select coalesce(sum(onboard_quantity),0)=0 from v_cargo_custody_balance where shipment_id=v_shipment)
    and (select count(*)=1 from receiver_access_tokens where id=(v_result ->> 'receiverAccessTokenId')::uuid),
    'C07 posts UNLOAD/outcomes and starts only this contactless stop receiver window'
  );

  select haulvia_command.command_complete_planned_route(
    pg_temp.envelope(v_shipment,null,'c14-main','4')||jsonb_build_object(
      'workerAuthority','EVIDENCE_REVIEWER','expectedRouteVersionId',v_route,
      'expectedAssignmentId',v_assignment,'expectedRouteExecutionId',v_execution,
      'expectedRouteExecutionVersion',v_version
    )
  ) into v_result;
  perform pg_temp.assert_true(
    (v_result ->> 'shipmentState')='DELIVERED'
    and (v_result ->> 'publicOutcomeLabel')='DELIVERED'
    and (v_result ->> 'pendingReceiverConfirmations')::integer=1
    and (select state='COMPLETED' from route_executions where id=v_execution)
    and (select count(*)=1 from route_resolution_records
         where shipment_id=v_shipment and public_outcome_label='DELIVERED'
           and jsonb_array_length(outcome_summary -> 'byOutcomeAndUnit')=1
           and outcome_summary #>> '{byOutcomeAndUnit,0,quantityUnit}'='piece'),
    'C14 resolves the route with unit-safe outcome disclosure while contactless confirmation remains independent'
  );
end;
$$;

-- Failed later pickup retains onboard cargo and advances only after explicit authorization.
do $$
declare
  v_f jsonb := pg_temp.seed_after_first_pickup('c-failed-pickup',false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_f ->> 'assignmentId')::uuid;
  v_execution uuid := (v_f ->> 'routeExecutionId')::uuid;
  v_first_stop uuid := (v_f ->> 'firstStopExecutionId')::uuid;
  v_allocation2 uuid := (v_f ->> 'allocation2Id')::uuid;
  v_driver uuid := '92000000-0000-0000-0000-000000000002';
  v_customer uuid := '91000000-0000-0000-0000-000000000002';
  v_version bigint := (v_f ->> 'routeExecutionVersion')::bigint;
  v_result jsonb;
  v_pickup2 uuid;
  v_report uuid;
  v_bad jsonb;
begin
  select haulvia_command.command_advance_to_next_stop(
    pg_temp.envelope(v_shipment,v_driver,'c08-advance','5')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_first_stop,'nextStopEtaAt',clock_timestamp()+interval '10 minutes'
    )
  ) into v_result;
  v_pickup2 := (v_result ->> 'stopExecutionId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_confirm_arrival_at_stop(
    pg_temp.envelope(v_shipment,v_driver,'c08-arrival','6')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2,'latitude',52.1400,'longitude',-106.6800,
      'capturedAt',clock_timestamp()-interval '1 hour',
      'waitingFreeUntil',clock_timestamp()-interval '30 minutes'
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_report_failed_pickup_stop(
    pg_temp.envelope(v_shipment,v_driver,'c08-main','7')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2,'targetStopState','FAILED',
      'occurredAt',clock_timestamp(),'gracePeriodEndedAt',clock_timestamp()-interval '30 minutes',
      'failureReason','Sender did not provide the second cargo after repeated contact',
      'responsibilityCode','SENDER','contactAttempts',jsonb_build_array(
        jsonb_build_object('method','PHONE','outcome','NO_ANSWER','capturedAt',clock_timestamp()-interval '40 minutes')
      ),'affectedCargo',jsonb_build_array(
        jsonb_build_object('cargoAllocationId',v_allocation2,'quantity',1,'quantityUnit','piece')
      ),'downstreamImpact',jsonb_build_object('deliveryStillFeasible',true,'delaySeconds',1800),
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment),
      'evidence',jsonb_build_array(
        jsonb_build_object('type','PHOTO','storageObjectKey','c-failed-pickup/closed.jpg','contentSha256',repeat('f',64),'capturedAt',clock_timestamp())
      )
    )
  ) into v_result;
  v_report := (v_result ->> 'stopFailureReportId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  perform pg_temp.assert_true(
    (select state='FAILED' from stop_executions where id=v_pickup2)
    and (select count(*)=1 from stop_failure_reports where id=v_report)
    and (select sum(onboard_quantity)=2 from v_cargo_custody_balance where shipment_id=v_shipment),
    'C08 records failed pickup evidence without treating earlier onboard cargo as absent'
  );

  v_bad := pg_temp.envelope(v_shipment,v_customer,'c10-stale-custody','8')||jsonb_build_object(
    'actorOrganizationId','91000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
    'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
    'expectedStopExecutionId',v_pickup2,'stopFailureReportId',v_report,'decisionCode','SKIP',
    'routeFeasible',true,'capacityValidated',true,'timingValidated',true,'custodyValidated',true,
    'routeFeasibilitySnapshot',jsonb_build_object('feasible',true),
    'capacitySnapshot',jsonb_build_object('valid',true),
    'timingSnapshot',jsonb_build_object('valid',true),
    'customerInstructions',jsonb_build_object('skipUnavailablePickup',true),
    'custodyBalance',jsonb_build_object('balances','[]'::jsonb),
    'nextStopEtaAt',clock_timestamp()+interval '3 hours'
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_authorize_continue_after_stop_failure(%L::jsonb)',v_bad::text),
    'CUSTODY_SNAPSHOT_STALE','C10 cannot continue from a stale onboard-cargo snapshot'
  );

  select haulvia_command.command_authorize_continue_after_stop_failure(
    pg_temp.envelope(v_shipment,v_customer,'c10-main','9')||jsonb_build_object(
      'actorOrganizationId','91000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2,'stopFailureReportId',v_report,'decisionCode','SKIP',
      'routeFeasible',true,'capacityValidated',true,'timingValidated',true,'custodyValidated',true,
      'routeFeasibilitySnapshot',jsonb_build_object('feasible',true,'remainingStops',1),
      'capacitySnapshot',jsonb_build_object('onboardWeightKg',20,'capacityWeightKg',1000),
      'timingSnapshot',jsonb_build_object('deliveryWindowValid',true),
      'customerInstructions',jsonb_build_object('skipUnavailablePickup',true,'continueDelivery',true),
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment),
      'nextStopEtaAt',clock_timestamp()+interval '3 hours'
    )
  ) into v_result;
  perform pg_temp.assert_true(
    (select state='FAILED' from stop_executions where id=v_pickup2)
    and (select state='EN_ROUTE' from stop_executions where id=(v_result ->> 'stopExecutionId')::uuid)
    and (select count(*)=1 from stop_continuation_authorizations where id=(v_result ->> 'stopContinuationAuthorizationId')::uuid)
    and (select count(*)=1 from cargo_resolution_outcomes where cargo_allocation_id=v_allocation2 and outcome_code='APPROVED_NOT_LOADED'),
    'C10 leaves the failure immutable and separately authorizes the next eligible stop'
  );
end;
$$;

-- Failed delivery requires an approved next-route decision and preserves custody.
do $$
declare
  v_f jsonb := pg_temp.seed_after_first_pickup('c-failed-delivery',false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_f ->> 'assignmentId')::uuid;
  v_execution uuid := (v_f ->> 'routeExecutionId')::uuid;
  v_first_stop uuid := (v_f ->> 'firstStopExecutionId')::uuid;
  v_allocation2 uuid := (v_f ->> 'allocation2Id')::uuid;
  v_allocation1 uuid := (v_f ->> 'allocation1Id')::uuid;
  v_driver uuid := '92000000-0000-0000-0000-000000000002';
  v_version bigint := (v_f ->> 'routeExecutionVersion')::bigint;
  v_result jsonb;
  v_pickup2 uuid;
  v_delivery uuid;
  v_report uuid;
begin
  -- Explicitly skip the second pickup, then continue to its later delivery.
  select haulvia_command.command_advance_to_next_stop(
    pg_temp.envelope(v_shipment,v_driver,'c09-advance-pickup','a')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_first_stop,'nextStopEtaAt',clock_timestamp()+interval '10 minutes'
    )
  ) into v_result;
  v_pickup2 := (v_result ->> 'stopExecutionId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_confirm_arrival_at_stop(
    pg_temp.envelope(v_shipment,v_driver,'c09-arrive-pickup','b')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2,'latitude',52.1400,'longitude',-106.6800,
      'capturedAt',clock_timestamp()-interval '1 hour','waitingFreeUntil',clock_timestamp()-interval '30 minutes'
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_report_failed_pickup_stop(
    pg_temp.envelope(v_shipment,v_driver,'c09-fail-pickup','c')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2,'targetStopState','FAILED',
      'gracePeriodEndedAt',clock_timestamp()-interval '30 minutes',
      'failureReason','Second sender location was closed after the full grace period',
      'responsibilityCode','SENDER','contactAttempts',jsonb_build_array(jsonb_build_object('method','PHONE','outcome','NO_ANSWER')),
      'affectedCargo',jsonb_build_array(jsonb_build_object('cargoAllocationId',v_allocation2,'quantity',1,'quantityUnit','piece')),
      'downstreamImpact',jsonb_build_object('deliveryStillFeasible',true),
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment),
      'evidence',jsonb_build_array(jsonb_build_object('type','PHOTO','storageObjectKey','c09/closed.jpg','contentSha256',repeat('a',64),'capturedAt',clock_timestamp()))
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_authorize_continue_after_stop_failure(
    pg_temp.envelope(v_shipment,'91000000-0000-0000-0000-000000000002','c09-continue','d')||jsonb_build_object(
      'actorOrganizationId','91000000-0000-0000-0000-000000000001',
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_pickup2,'stopFailureReportId',(v_result ->> 'stopFailureReportId')::uuid,
      'decisionCode','SKIP','routeFeasible',true,'capacityValidated',true,
      'timingValidated',true,'custodyValidated',true,
      'routeFeasibilitySnapshot',jsonb_build_object('feasible',true),
      'capacitySnapshot',jsonb_build_object('valid',true),
      'timingSnapshot',jsonb_build_object('valid',true),
      'customerInstructions',jsonb_build_object('continueDelivery',true),
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment),
      'nextStopEtaAt',clock_timestamp()+interval '3 hours'
    )
  ) into v_result;
  v_delivery := (v_result ->> 'stopExecutionId')::uuid;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_confirm_arrival_at_stop(
    pg_temp.envelope(v_shipment,v_driver,'c09-arrive-delivery','e')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery,'latitude',50.4452,'longitude',-104.6189,
      'capturedAt',clock_timestamp()-interval '1 hour','waitingFreeUntil',clock_timestamp()-interval '30 minutes'
    )
  ) into v_result;
  v_version := (v_result ->> 'routeExecutionVersion')::bigint;
  select haulvia_command.command_report_failed_delivery_stop(
    pg_temp.envelope(v_shipment,v_driver,'c09-main','f')||jsonb_build_object(
      'expectedRouteVersionId',v_route,'expectedAssignmentId',v_assignment,
      'expectedRouteExecutionId',v_execution,'expectedRouteExecutionVersion',v_version,
      'expectedStopExecutionId',v_delivery,'targetStopState','FAILED',
      'gracePeriodEndedAt',clock_timestamp()-interval '30 minutes',
      'failureReason','Receiver was unavailable and secure delivery was not authorized',
      'responsibilityCode','RECEIVER','contactAttempts',jsonb_build_array(jsonb_build_object('method','PHONE','outcome','NO_ANSWER')),
      'affectedCargo',jsonb_build_array(jsonb_build_object('cargoAllocationId',v_allocation1,'quantity',2,'quantityUnit','piece')),
      'downstreamImpact',jsonb_build_object('recoveryRequired',true),
      'approvedNextRouteDecision',jsonb_build_object('decisionCode','STORAGE','approved',true),
      'custodyBalance',haulvia_command.current_custody_summary(v_shipment),
      'evidence',jsonb_build_array(jsonb_build_object('type','PHOTO','storageObjectKey','c09/no-receiver.jpg','contentSha256',repeat('b',64),'capturedAt',clock_timestamp()))
    )
  ) into v_result;
  v_report := (v_result ->> 'stopFailureReportId')::uuid;
  perform pg_temp.assert_true(
    (select state='FAILED' from stop_executions where id=v_delivery)
    and (select approved_next_route_decision ->> 'decisionCode'='STORAGE' from stop_failure_reports where id=v_report)
    and (select sum(onboard_quantity)=2 from v_cargo_custody_balance where shipment_id=v_shipment),
    'C09 retains failed delivery, approved next decision, and continuing custody without automatic route resolution'
  );
end;
$$;

-- Post-custody amendment creates a new immutable route and execution segment.
do $$
declare
  v_f jsonb := pg_temp.seed_after_first_pickup('c-amendment',false);
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_old_route uuid := (v_f ->> 'routeVersionId')::uuid;
  v_assignment uuid := (v_f ->> 'assignmentId')::uuid;
  v_old_execution uuid := (v_f ->> 'routeExecutionId')::uuid;
  v_version bigint := (v_f ->> 'routeExecutionVersion')::bigint;
  v_customer uuid := '91000000-0000-0000-0000-000000000002';
  v_new_pickup uuid := gen_random_uuid();
  v_new_delivery uuid := gen_random_uuid();
  v_new_cargo uuid := gen_random_uuid();
  v_new_allocation uuid := gen_random_uuid();
  v_plan jsonb;
  v_request jsonb;
  v_bad jsonb;
  v_result jsonb;
  v_new_route uuid;
  v_new_execution uuid;
begin
  v_plan := jsonb_build_object(
    'plannedDistanceKm',270,'plannedDurationSeconds',11000,
    'stops',jsonb_build_array(
      jsonb_build_object(
        'id',v_new_pickup,'stableStopKey',(v_f ->> 'pickup1StableKey')::uuid,
        'sequenceNo',1,'stopType','PICKUP','addressLine1','100 First Pickup Road',
        'city','Saskatoon','regionCode','SK','countryCode','CA',
        'verificationProfile',jsonb_build_object('photo',true)
      ),
      jsonb_build_object(
        'id',v_new_delivery,'stableStopKey',(v_f ->> 'deliveryStableKey')::uuid,
        'sequenceNo',2,'stopType','DELIVERY','addressLine1','350 Amended Delivery Road',
        'city','Regina','regionCode','SK','countryCode','CA',
        'latitude',50.4452,'longitude',-104.6189,'geofenceRadiusM',200,
        'verificationProfile',jsonb_build_object('photo',true,'pin',true)
      )
    ),
    'legs',jsonb_build_array(jsonb_build_object(
      'id',gen_random_uuid(),'sequenceNo',1,'fromStopId',v_new_pickup,
      'toStopId',v_new_delivery,'plannedDistanceKm',270,'plannedDurationSeconds',11000
    )),
    'cargoItems',jsonb_build_array(jsonb_build_object(
      'id',v_new_cargo,'stableCargoKey',(v_f ->> 'cargo1StableKey')::uuid,
      'cargoLineNo',1,'description','First pickup cargo','quantity',2,
      'quantityUnit','piece','totalWeightKg',20,'currency','CAD'
    )),
    'allocations',jsonb_build_array(jsonb_build_object(
      'id',v_new_allocation,'cargoItemId',v_new_cargo,'pickupStopId',v_new_pickup,
      'deliveryStopId',v_new_delivery,'quantity',2,'quantityUnit','piece'
    ))
  );
  v_bad := pg_temp.envelope(v_shipment,v_customer,'c11-unfunded','0')||jsonb_build_object(
    'actorOrganizationId','91000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId',v_old_route,'expectedAssignmentId',v_assignment,
    'expectedRouteExecutionId',v_old_execution,'expectedRouteExecutionVersion',v_version,
    'reason','Customer approved a changed delivery after the first pickup',
    'routePlan',v_plan,'driverAcceptance',jsonb_build_object(
      'accepted',true,'driverId','92000000-0000-0000-0000-000000000004','acceptedAt',clock_timestamp()
    ),'amendmentSnapshot',jsonb_build_object('changedDestination',true),
    'policyVersionId','93000000-0000-0000-0000-000000000002',
    'evidenceRequirements',jsonb_build_object('photo',true),
    'cancellationRules',jsonb_build_object('preCustody','versioned'),
    'refundRules',jsonb_build_object('driverShare',0.8),
    'timingWindows',jsonb_build_object('etaNotificationThresholdSeconds',60),
    'riskRules','{}'::jsonb,'policyConfigSha256',repeat('8',64),
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE',
    'pricingRuleVersionId','94000000-0000-0000-0000-000000000002',
    'amount',10,'subtotal',10,'taxAmount',0,'additionalPaymentAmount',10,
    'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('1',64),
    'nextStopEtaAt',clock_timestamp()+interval '3 hours'
  );
  perform pg_temp.expect_error_code(
    format('select haulvia_command.command_authorize_route_amendment(%L::jsonb)',v_bad::text),
    'ADDITIONAL_PAYMENT_NOT_SECURED','C11 blocks non-emergency extra work without secured additional payment'
  );

  v_request := pg_temp.envelope(v_shipment,v_customer,'c11-main','1')||jsonb_build_object(
    'actorOrganizationId','91000000-0000-0000-0000-000000000001',
    'expectedRouteVersionId',v_old_route,'expectedAssignmentId',v_assignment,
    'expectedRouteExecutionId',v_old_execution,'expectedRouteExecutionVersion',v_version,
    'reason','Customer approved a changed delivery after the first pickup',
    'routePlan',v_plan,'driverAcceptance',jsonb_build_object(
      'accepted',true,'driverId','92000000-0000-0000-0000-000000000004','acceptedAt',clock_timestamp()
    ),'amendmentSnapshot',jsonb_build_object('changedDestination',true,'oldRoutePreserved',true),
    'policyVersionId','93000000-0000-0000-0000-000000000002',
    'evidenceRequirements',jsonb_build_object('photo',true),
    'cancellationRules',jsonb_build_object('preCustody','versioned'),
    'refundRules',jsonb_build_object('driverShare',0.8),
    'timingWindows',jsonb_build_object('etaNotificationThresholdSeconds',60),
    'riskRules','{}'::jsonb,'policyConfigSha256',repeat('8',64),
    'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE',
    'pricingRuleVersionId','94000000-0000-0000-0000-000000000002',
    'amount',0,'subtotal',0,'taxAmount',0,'additionalPaymentAmount',0,
    'currency','CAD','breakdown','[]'::jsonb,'snapshotSha256',repeat('2',64),
    'nextStopEtaAt',clock_timestamp()+interval '3 hours'
  );
  select haulvia_command.command_authorize_route_amendment(v_request) into v_result;
  v_new_route := (v_result ->> 'routeVersionId')::uuid;
  v_new_execution := (v_result ->> 'routeExecutionId')::uuid;
  perform pg_temp.assert_true(
    v_new_route<>v_old_route and v_new_execution<>v_old_execution
    and (select status='SUPERSEDED' from route_versions where id=v_old_route)
    and (select status='ACTIVE' from route_versions where id=v_new_route)
    and (select state='COMPLETED' from route_executions where id=v_old_execution)
    and (select state='ACTIVE' and parent_route_execution_id=v_old_execution from route_executions where id=v_new_execution)
    and (select count(*)=1 from route_amendments where id=(v_result ->> 'routeAmendmentId')::uuid)
    and (select state='COMPLETED' from stop_executions se join route_stops rs on rs.id=se.route_stop_id where se.route_execution_id=v_new_execution and rs.stable_stop_key=(v_f ->> 'pickup1StableKey')::uuid),
    'C11 preserves old route/attempts and starts an accepted, repriced, versioned amendment segment'
  );
end;
$$;

select pg_temp.assert_true(
  (select count(*)=14 from (values
    ('command_advance_to_next_stop'),('command_confirm_arrival_at_stop'),
    ('command_correct_stop_arrival'),('command_start_stop_service'),
    ('command_submit_stop_evidence'),('command_verify_pickup_stop'),
    ('command_verify_delivery_stop'),('command_report_failed_pickup_stop'),
    ('command_report_failed_delivery_stop'),('command_authorize_continue_after_stop_failure'),
    ('command_authorize_route_amendment'),('command_record_route_update'),
    ('command_report_transit_issue'),('command_complete_planned_route')
  ) expected(name)
  where exists(
    select 1 from information_schema.routines r
    where r.routine_schema='haulvia_command' and r.routine_name=expected.name
  )),
  'all 14 Block C matrix rows have named trusted command entry points'
);

select pg_temp.assert_true(
  (select count(*)>=46 from information_schema.routines
   where routine_schema='haulvia_command' and routine_name like 'command_%'),
  'Blocks A, B, and C expose at least their 46 named wrappers in total'
);

select pg_temp.assert_true(
  not exists(
    select 1 from information_schema.routine_privileges
    where routine_schema='haulvia_command' and grantee='PUBLIC'
  ),
  'trusted command routines remain unavailable to PUBLIC'
);

select pg_temp.assert_true(
  not exists(
    select 1 from information_schema.routine_privileges
    where routine_schema='haulvia_command' and grantee='service_role'
      and left(routine_name,8)<>'command_'
  )
  and (
    not exists(select 1 from pg_roles where rolname='service_role')
    or (select count(*)>=46 from information_schema.routine_privileges
        where routine_schema='haulvia_command' and grantee='service_role'
          and left(routine_name,8)='command_')
  ),
  'service_role receives named command wrappers but no internal helper execution'
);

select pg_temp.assert_true(
  (select count(*)>=1 from route_eta_calculations)
  and (select count(*)>=1 from route_stop_eta_predictions)
  and (select count(*)>=2 from stop_failure_reports)
  and (select count(*)>=1 from stop_continuation_authorizations)
  and (select count(*)>=1 from route_amendments)
  and (select count(*)>=1 from cargo_resolution_outcomes)
  and (select count(*)>=1 from route_resolution_records),
  'Block C retains ETA, failure, continuation, amendment, cargo-outcome, and route-resolution evidence'
);

rollback;
