-- Haulvia foundation acceptance suite v1
-- Run only against a disposable PostgreSQL 16 / Supabase test database.
-- Prerequisite: 20260814000100_haulvia_foundation_v1.sql has completed.
-- The entire suite rolls back; psql should be started with ON_ERROR_STOP=1.

begin;
set local search_path = haulvia, public;

create temporary table haulvia_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text
) on commit drop;

create schema haulvia_test;

create or replace function haulvia_test.assert_true(
  p_test_name text,
  p_condition boolean,
  p_detail text default null
)
returns void
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if p_condition is distinct from true then
    raise exception 'TEST FAILED: % (%)', p_test_name, coalesce(p_detail, 'condition was not true')
      using errcode = 'P0001';
  end if;
  insert into pg_temp.haulvia_test_results values (p_test_name, true, p_detail);
end;
$$;

create or replace function haulvia_test.expect_error(
  p_test_name text,
  p_sql text,
  p_expected_sqlstate text default null,
  p_message_fragment text default null
)
returns void
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_caught boolean := false;
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;
  exception when others then
    v_caught := true;
    get stacked diagnostics
      v_state = returned_sqlstate,
      v_message = message_text;
  end;

  if not v_caught then
    raise exception 'TEST FAILED: % (expected an error)', p_test_name
      using errcode = 'P0001';
  end if;

  if p_expected_sqlstate is not null and v_state <> p_expected_sqlstate then
    raise exception 'TEST FAILED: % (expected SQLSTATE %, received %: %)',
      p_test_name, p_expected_sqlstate, v_state, v_message
      using errcode = 'P0001';
  end if;

  if p_message_fragment is not null and position(lower(p_message_fragment) in lower(v_message)) = 0 then
    raise exception 'TEST FAILED: % (message did not contain "%": %)',
      p_test_name, p_message_fragment, v_message
      using errcode = 'P0001';
  end if;

  insert into pg_temp.haulvia_test_results
  values (p_test_name, true, v_state || ': ' || v_message);
end;
$$;

-- -----------------------------------------------------------------------------
-- Schema shape and stable public reference
-- -----------------------------------------------------------------------------

select haulvia_test.assert_true(
  'schema retains all 83 foundation base tables',
  (select count(*) >= 83
   from information_schema.tables
   where table_schema = 'haulvia' and table_type = 'BASE TABLE')
);

select haulvia_test.assert_true(
  'schema has 5 views',
  (select count(*) = 5
   from information_schema.views
   where table_schema = 'haulvia')
);

select haulvia_test.assert_true(
  'compliance export has exact ordered fields',
  (
    select array_agg(column_name::text order by ordinal_position) = array[
      'itemCategory', 'complianceCode', 'complianceName', 'relatedServiceCode',
      'holderName', 'credentialNumber', 'issuingAuthority', 'issueDate',
      'effectiveDate', 'expiryDate', 'reviewStatus', 'isRequired', 'notes',
      'reviewedAt', 'reviewerLabel', 'status', 'documentCount',
      'acceptedDocumentCount'
    ]::text[]
    from information_schema.columns
    where table_schema = 'haulvia' and table_name = 'v_compliance_item_export'
  )
);

delete from shipment_reference_counters where reference_date = date '2099-12-31';

select haulvia_test.assert_true(
  'daily shipment reference starts at 0001',
  next_shipment_reference(date '2099-12-31') = 'HV-20991231-0001'
);

select haulvia_test.assert_true(
  'daily shipment reference increments',
  next_shipment_reference(date '2099-12-31') = 'HV-20991231-0002'
);

-- -----------------------------------------------------------------------------
-- Deterministic customer/provider/authority fixtures
-- -----------------------------------------------------------------------------

insert into organizations (id, organization_key, kind, legal_name, display_name) values
  ('10000000-0000-0000-0000-000000000001', 'test-customer', 'CUSTOMER', 'Test Customer Ltd.', 'Test Customer'),
  ('20000000-0000-0000-0000-000000000001', 'test-provider', 'INDEPENDENT_PROVIDER', 'Test Carrier Ltd.', 'Test Carrier'),
  ('30000000-0000-0000-0000-000000000001', 'haulvia-test', 'HAULVIA', 'Haulvia Test', 'Haulvia Test');

insert into profiles (id, display_name) values
  ('11000000-0000-0000-0000-000000000001', 'Test Customer User'),
  ('21000000-0000-0000-0000-000000000001', 'Test Driver'),
  ('31000000-0000-0000-0000-000000000001', 'Test Haulvia Admin');

insert into organization_memberships (
  id, organization_id, profile_id, status
) values (
  '32000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  '31000000-0000-0000-0000-000000000001',
  'ACTIVE'
);

insert into roles (id, role_key, name) values
  ('33000000-0000-0000-0000-000000000001', 'TEST_PRICING_ADMIN', 'Test Pricing Admin');

insert into role_permissions (role_id, permission_id)
select '33000000-0000-0000-0000-000000000001', id
from permissions where permission_key = 'PRICING_MANAGE';

insert into membership_roles (membership_id, role_id, granted_by_profile_id) values (
  '32000000-0000-0000-0000-000000000001',
  '33000000-0000-0000-0000-000000000001',
  '31000000-0000-0000-0000-000000000001'
);

insert into reauth_sessions (
  id, profile_id, organization_id, method, verified_at, expires_at
) values (
  '34000000-0000-0000-0000-000000000001',
  '31000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'MFA', clock_timestamp() - interval '1 minute', clock_timestamp() + interval '10 minutes'
), (
  '34000000-0000-0000-0000-000000000002',
  '31000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'PASSWORD', clock_timestamp() - interval '2 hours', clock_timestamp() - interval '1 hour'
);

select assert_sensitive_authority(
  '31000000-0000-0000-0000-000000000001',
  '30000000-0000-0000-0000-000000000001',
  'PRICING_MANAGE',
  '34000000-0000-0000-0000-000000000001',
  'Acceptance test publication authority'
);

select haulvia_test.assert_true('fresh sensitive authority succeeds', true);

select haulvia_test.expect_error(
  'expired reauthentication is rejected',
  $sql$
    select assert_sensitive_authority(
      '31000000-0000-0000-0000-000000000001',
      '30000000-0000-0000-0000-000000000001',
      'PRICING_MANAGE',
      '34000000-0000-0000-0000-000000000002',
      'Acceptance test expired authority'
    )
  $sql$,
  '42501',
  'Fresh password, passkey, or MFA'
);

insert into service_providers (
  id, organization_id, kind, status, approved_at
) values (
  '22000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000001',
  'INDEPENDENT_DRIVER', 'ACTIVE', clock_timestamp()
);

insert into drivers (id, profile_id, status, public_label) values (
  '23000000-0000-0000-0000-000000000001',
  '21000000-0000-0000-0000-000000000001',
  'ACTIVE', 'Test Driver'
);

insert into provider_drivers (id, provider_id, driver_id, status) values (
  '23100000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000001',
  '23000000-0000-0000-0000-000000000001',
  'ACTIVE'
);

insert into vehicles (
  id, provider_id, vehicle_key, status, vehicle_class, capacity_weight_kg
) values (
  '24000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000001',
  'TEST-VAN-1', 'ACTIVE', 'CARGO_VAN', 1500
);

-- -----------------------------------------------------------------------------
-- Shipment axis initialization and a valid multi-stop-ready route plan
-- -----------------------------------------------------------------------------

insert into shipments (
  id, shipment_reference, customer_organization_id, customer_profile_id,
  shipment_state, pickup_timing, service_level, currency, marketplace_deadline
) values (
  '40000000-0000-0000-0000-000000000001',
  'HV-20991231-9001',
  '10000000-0000-0000-0000-000000000001',
  '11000000-0000-0000-0000-000000000001',
  'DRAFT', 'ASAP', 'FLEX', 'CAD', clock_timestamp() + interval '4 hours'
);

select haulvia_test.assert_true(
  'shipment insert initializes four independent axes',
  (select count(*) = 4 from (
    select shipment_id from shipment_marketplace_axes where shipment_id = '40000000-0000-0000-0000-000000000001'
    union all
    select shipment_id from shipment_customer_payment_axes where shipment_id = '40000000-0000-0000-0000-000000000001'
    union all
    select shipment_id from shipment_driver_payout_axes where shipment_id = '40000000-0000-0000-0000-000000000001'
    union all
    select shipment_id from shipment_dispute_axes where shipment_id = '40000000-0000-0000-0000-000000000001'
  ) axes)
);

select haulvia_test.assert_true(
  'shipment insert appends initial DRAFT event',
  (select count(*) = 1 from shipment_state_events
   where shipment_id = '40000000-0000-0000-0000-000000000001'
     and current_state = 'DRAFT' and command_name = 'createShipment')
);

insert into route_versions (
  id, shipment_id, version_no, status, change_reason, created_by_profile_id
) values (
  '50000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  1, 'DRAFT', 'Initial acceptance route',
  '11000000-0000-0000-0000-000000000001'
);

insert into route_stops (
  id, route_version_id, stable_stop_key, sequence_no, stop_type,
  address_line1, city, region_code, country_code
) values (
  '51000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '51100000-0000-0000-0000-000000000001',
  1, 'PICKUP', '1 Origin Street', 'Regina', 'SK', 'CA'
), (
  '51000000-0000-0000-0000-000000000002',
  '50000000-0000-0000-0000-000000000001',
  '51100000-0000-0000-0000-000000000002',
  2, 'DELIVERY', '2 Destination Avenue', 'Saskatoon', 'SK', 'CA'
);

insert into route_legs (
  id, route_version_id, sequence_no, from_stop_id, to_stop_id,
  planned_distance_km, planned_duration_seconds
) values (
  '52000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  1,
  '51000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000002',
  260, 10800
);

insert into cargo_items (
  id, route_version_id, stable_cargo_key, cargo_line_no,
  description, quantity, quantity_unit, total_weight_kg
) values (
  '53000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '53100000-0000-0000-0000-000000000001',
  1, 'Acceptance cartons', 10, 'carton', 100
);

insert into cargo_allocations (
  id, route_version_id, cargo_item_id, pickup_stop_id,
  delivery_stop_id, quantity, quantity_unit
) values (
  '54000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '53000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000002',
  10, 'carton'
);

insert into cargo_items (
  id, route_version_id, stable_cargo_key, cargo_line_no,
  description, quantity, quantity_unit
) values (
  '53000000-0000-0000-0000-000000000002',
  '50000000-0000-0000-0000-000000000001',
  '53100000-0000-0000-0000-000000000002',
  2, 'Invalid-order probe', 1, 'item'
);

select haulvia_test.expect_error(
  'cargo pickup must precede delivery',
  $sql$
    insert into cargo_allocations (
      id, route_version_id, cargo_item_id, pickup_stop_id,
      delivery_stop_id, quantity, quantity_unit
    ) values (
      '54000000-0000-0000-0000-000000000002',
      '50000000-0000-0000-0000-000000000001',
      '53000000-0000-0000-0000-000000000002',
      '51000000-0000-0000-0000-000000000002',
      '51000000-0000-0000-0000-000000000001',
      1, 'item'
    )
  $sql$,
  '23514',
  'pickup stop must precede'
);

delete from cargo_items where id = '53000000-0000-0000-0000-000000000002';

update route_versions
set status = 'ACTIVE'
where id = '50000000-0000-0000-0000-000000000001';

select haulvia_test.assert_true(
  'valid ordered route activates',
  (select status = 'ACTIVE' and activated_at is not null
   from route_versions where id = '50000000-0000-0000-0000-000000000001')
);

select haulvia_test.expect_error(
  'active route plan is immutable',
  $sql$
    update route_stops set city = 'Changed City'
    where id = '51000000-0000-0000-0000-000000000001'
  $sql$,
  '55000',
  'plan is immutable'
);

-- -----------------------------------------------------------------------------
-- Pricing publication, review, snapshots, negotiation, and reservation
-- -----------------------------------------------------------------------------

insert into pricing_rule_sets (
  id, rule_key, name, pricing_source, service_level, currency
) values (
  '60000000-0000-0000-0000-000000000001',
  'TEST_FLEX_GUARDRAIL', 'Test Flex Guardrail',
  'HAULVIA_GUARDRAIL', 'FLEX', 'CAD'
);

insert into pricing_rule_versions (
  id, pricing_rule_set_id, version_no, publication_status,
  effective_from, rule_config, rule_sha256,
  created_by_profile_id, approved_by_profile_id, approved_at
) values (
  '61000000-0000-0000-0000-000000000001',
  '60000000-0000-0000-0000-000000000001',
  1, 'APPROVED', clock_timestamp() - interval '1 day',
  '{"floor":80,"ceiling":120}'::jsonb, repeat('a', 64),
  '31000000-0000-0000-0000-000000000001',
  '31000000-0000-0000-0000-000000000001',
  clock_timestamp()
);

select haulvia_test.expect_error(
  'approved pricing version content is immutable',
  $sql$
    update pricing_rule_versions
    set rule_config = '{"floor":1}'::jsonb
    where id = '61000000-0000-0000-0000-000000000001'
  $sql$,
  '55000',
  'publish a new version'
);

update shipment_customer_payment_axes
set state = 'METHOD_VERIFIED'
where shipment_id = '40000000-0000-0000-0000-000000000001';

update shipments
set shipment_state = 'POSTED'
where id = '40000000-0000-0000-0000-000000000001';

update shipment_marketplace_axes
set state = 'ACTIVE'
where shipment_id = '40000000-0000-0000-0000-000000000001';

insert into pricing_reviews (
  id, shipment_id, route_version_id, pricing_source, pricing_mode,
  status, reviewed_amount, currency, reviewed_at, expires_at
) values (
  '62000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE', 'PASSED', 100, 'CAD',
  clock_timestamp(), clock_timestamp() + interval '2 hours'
);

insert into shipment_price_snapshots (
  id, shipment_id, route_version_id, purpose, pricing_source, pricing_mode,
  pricing_rule_version_id, pricing_review_id,
  subtotal, tax_amount, total_amount, currency, breakdown,
  snapshot_sha256, accepted_at
) values (
  '63000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  'RESERVATION', 'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE',
  '61000000-0000-0000-0000-000000000001',
  '62000000-0000-0000-0000-000000000001',
  100, 0, 100, 'CAD', '{"route":100}'::jsonb,
  repeat('b', 64), clock_timestamp()
);

select haulvia_test.expect_error(
  'price snapshot rejects mismatched source',
  $sql$
    insert into shipment_price_snapshots (
      id, shipment_id, route_version_id, purpose, pricing_source, pricing_mode,
      pricing_rule_version_id, pricing_review_id,
      subtotal, tax_amount, total_amount, currency, breakdown,
      snapshot_sha256, accepted_at
    ) values (
      '63000000-0000-0000-0000-000000000002',
      '40000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001',
      'RESERVATION', 'HAULVIA_FIXED', 'NOT_APPLICABLE',
      '61000000-0000-0000-0000-000000000001',
      '62000000-0000-0000-0000-000000000001',
      100, 0, 100, 'CAD', '{"route":100}'::jsonb,
      repeat('c', 64), clock_timestamp()
    )
  $sql$,
  '23514',
  'does not match its rule source'
);

insert into offer_threads (
  id, shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
  pricing_source, pricing_mode, status, expires_at
) values (
  '70000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000001',
  '23000000-0000-0000-0000-000000000001',
  '24000000-0000-0000-0000-000000000001',
  'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE', 'ACTIVE',
  clock_timestamp() + interval '1 hour'
);

insert into offer_revisions (
  id, offer_thread_id, revision_no, revision_kind, proposed_by,
  amount, currency, valid_until, pricing_snapshot_id, route_version_id
) values
  ('71000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 1, 'INITIAL', 'PROVIDER', 100, 'CAD', clock_timestamp() + interval '30 minutes', '63000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000001', 2, 'CUSTOMER_COUNTER', 'CUSTOMER', 100, 'CAD', clock_timestamp() + interval '30 minutes', '63000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000003', '70000000-0000-0000-0000-000000000001', 3, 'CUSTOMER_COUNTER', 'CUSTOMER', 100, 'CAD', clock_timestamp() + interval '30 minutes', '63000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000004', '70000000-0000-0000-0000-000000000001', 4, 'PROVIDER_REVISION', 'PROVIDER', 100, 'CAD', clock_timestamp() + interval '30 minutes', '63000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000001', 5, 'PROVIDER_REVISION', 'PROVIDER', 100, 'CAD', clock_timestamp() + interval '30 minutes', '63000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001');

select haulvia_test.expect_error(
  'third customer counter is rejected',
  $sql$
    insert into offer_revisions (
      id, offer_thread_id, revision_no, revision_kind, proposed_by,
      amount, currency, valid_until, pricing_snapshot_id, route_version_id
    ) values (
      '71000000-0000-0000-0000-000000000006',
      '70000000-0000-0000-0000-000000000001',
      6, 'CUSTOMER_COUNTER', 'CUSTOMER', 100, 'CAD',
      clock_timestamp() + interval '30 minutes',
      '63000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001'
    )
  $sql$,
  '23514',
  'at most two customer counters'
);

update shipments
set shipment_state = 'NEGOTIATING'
where id = '40000000-0000-0000-0000-000000000001';

insert into offer_reservations (
  id, shipment_id, offer_thread_id, selected_revision_id,
  status, reserved_by_profile_id, expires_at
) values (
  '72000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '70000000-0000-0000-0000-000000000001',
  '71000000-0000-0000-0000-000000000001',
  'ACTIVE', '11000000-0000-0000-0000-000000000001',
  clock_timestamp() + interval '15 minutes'
);

-- -----------------------------------------------------------------------------
-- Funding, compliance, assignment, stop loop, custody, and terminal behavior
-- -----------------------------------------------------------------------------

select haulvia_test.expect_error(
  'assignment is rejected before full funding',
  $sql$
    insert into assignments (
      id, shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
      offer_reservation_id, selected_offer_revision_id, price_snapshot_id,
      status, agreement_snapshot
    ) values (
      '80000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001',
      '22000000-0000-0000-0000-000000000001',
      '23000000-0000-0000-0000-000000000001',
      '24000000-0000-0000-0000-000000000001',
      '72000000-0000-0000-0000-000000000001',
      '71000000-0000-0000-0000-000000000001',
      '63000000-0000-0000-0000-000000000001',
      'ACTIVE', '{"terms":"acceptance"}'::jsonb
    )
  $sql$,
  '23514',
  'Full route amount must be secured'
);

update shipment_customer_payment_axes
set state = 'SECURED', secured_amount = 100
where shipment_id = '40000000-0000-0000-0000-000000000001';

insert into compliance_subjects (
  id, subject_kind, driver_id
) values (
  '81000000-0000-0000-0000-000000000001',
  'DRIVER', '23000000-0000-0000-0000-000000000001'
);

insert into compliance_items (
  id, subject_id, item_category, compliance_code, compliance_name,
  review_status, applicability, is_required
) values (
  '81100000-0000-0000-0000-000000000001',
  '81000000-0000-0000-0000-000000000001',
  'SAFETY', 'BASE_SAFETY', 'Base Safety Credential',
  'UNDER_REVIEW', 'APPLICABLE', true
), (
  '81100000-0000-0000-0000-000000000002',
  '81000000-0000-0000-0000-000000000001',
  'CARGO', 'TDG', 'Transportation of Dangerous Goods',
  'CLAIMED', 'NOT_APPLICABLE', false
);

select haulvia_test.assert_true(
  'non-applicable compliance item does not block',
  (select count(*) = 1 from v_compliance_blockers
   where subject_id = '81000000-0000-0000-0000-000000000001')
);

select haulvia_test.expect_error(
  'assignment rechecks compliance blockers',
  $sql$
    insert into assignments (
      id, shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
      offer_reservation_id, selected_offer_revision_id, price_snapshot_id,
      status, agreement_snapshot
    ) values (
      '80000000-0000-0000-0000-000000000001',
      '40000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001',
      '22000000-0000-0000-0000-000000000001',
      '23000000-0000-0000-0000-000000000001',
      '24000000-0000-0000-0000-000000000001',
      '72000000-0000-0000-0000-000000000001',
      '71000000-0000-0000-0000-000000000001',
      '63000000-0000-0000-0000-000000000001',
      'ACTIVE', '{"terms":"acceptance"}'::jsonb
    )
  $sql$,
  '23514',
  'unresolved required compliance item'
);

update compliance_items
set review_status = 'VERIFIED',
    reviewer_profile_id = '31000000-0000-0000-0000-000000000001',
    reviewer_label = 'Test Haulvia Admin',
    review_action_note = 'Verified by acceptance fixture'
where id = '81100000-0000-0000-0000-000000000001';

select haulvia_test.assert_true(
  'compliance transition appends exact prior/current history',
  (select count(*) = 1 from compliance_item_history
   where compliance_item_id = '81100000-0000-0000-0000-000000000001'
     and prior_status = 'UNDER_REVIEW' and current_status = 'VERIFIED'
     and reviewer_label = 'Test Haulvia Admin'
     and note = 'Verified by acceptance fixture')
);

select haulvia_test.expect_error(
  'illegal compliance backward transition is rejected',
  $sql$
    update compliance_items
    set review_status = 'CLAIMED',
        review_action_note = 'Attempt invalid backward transition'
    where id = '81100000-0000-0000-0000-000000000001'
  $sql$,
  '23514',
  'not approved'
);

insert into assignments (
  id, shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
  offer_reservation_id, selected_offer_revision_id, price_snapshot_id,
  status, agreement_snapshot
) values (
  '80000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '22000000-0000-0000-0000-000000000001',
  '23000000-0000-0000-0000-000000000001',
  '24000000-0000-0000-0000-000000000001',
  '72000000-0000-0000-0000-000000000001',
  '71000000-0000-0000-0000-000000000001',
  '63000000-0000-0000-0000-000000000001',
  'ACTIVE', '{"terms":"acceptance"}'::jsonb
);

select haulvia_test.expect_error(
  'second active whole-route assignment is rejected',
  $sql$
    insert into assignments (
      id, shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
      price_snapshot_id, status, agreement_snapshot
    ) values (
      '80000000-0000-0000-0000-000000000002',
      '40000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001',
      '22000000-0000-0000-0000-000000000001',
      '23000000-0000-0000-0000-000000000001',
      '24000000-0000-0000-0000-000000000001',
      '63000000-0000-0000-0000-000000000001',
      'ACTIVE', '{"terms":"duplicate"}'::jsonb
    )
  $sql$,
  '23505',
  'assignments_one_active_uq'
);

update shipments
set shipment_state = 'DRIVER_ASSIGNED'
where id = '40000000-0000-0000-0000-000000000001';

insert into route_executions (
  id, shipment_id, route_version_id, assignment_id,
  execution_kind, state, started_at
) values (
  '82000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '80000000-0000-0000-0000-000000000001',
  'PRIMARY', 'ACTIVE', clock_timestamp()
);

insert into stop_executions (
  id, shipment_id, route_execution_id, route_version_id, route_stop_id
) values (
  '83000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '82000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000001'
), (
  '83000000-0000-0000-0000-000000000002',
  '40000000-0000-0000-0000-000000000001',
  '82000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '51000000-0000-0000-0000-000000000002'
);

update stop_executions set state = 'EN_ROUTE' where id = '83000000-0000-0000-0000-000000000001';
update stop_executions set state = 'ARRIVED' where id = '83000000-0000-0000-0000-000000000001';
update stop_executions set state = 'SERVICE_IN_PROGRESS' where id = '83000000-0000-0000-0000-000000000001';
update stop_executions set state = 'EVIDENCE_PENDING' where id = '83000000-0000-0000-0000-000000000001';

insert into stop_attempts (
  id, stop_execution_id, attempt_no, state, arrived_at, service_started_at, evidence_submitted_at
) values (
  '84000000-0000-0000-0000-000000000001',
  '83000000-0000-0000-0000-000000000001',
  1, 'EVIDENCE_PENDING', clock_timestamp(), clock_timestamp(), clock_timestamp()
);

insert into stop_evidence (
  id, stop_attempt_id, evidence_type, structured_value,
  captured_at, submitted_by_profile_id, idempotency_key
) values (
  '85000000-0000-0000-0000-000000000001',
  '84000000-0000-0000-0000-000000000001',
  'QUANTITY', '{"quantity":10,"unit":"carton"}'::jsonb,
  clock_timestamp(), '21000000-0000-0000-0000-000000000001', 'pickup-evidence-1'
);

insert into cargo_movements (
  id, shipment_id, route_execution_id, route_version_id, stop_execution_id,
  cargo_allocation_id, movement_type, quantity, quantity_unit,
  stop_attempt_id, occurred_at, recorded_by_profile_id, idempotency_key
) values (
  '86000000-0000-0000-0000-000000000001',
  '40000000-0000-0000-0000-000000000001',
  '82000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '83000000-0000-0000-0000-000000000001',
  '54000000-0000-0000-0000-000000000001',
  'LOAD', 10, 'carton',
  '84000000-0000-0000-0000-000000000001',
  clock_timestamp(), '21000000-0000-0000-0000-000000000001', 'load-1'
);

update stop_executions set state = 'COMPLETED' where id = '83000000-0000-0000-0000-000000000001';

update shipments
set shipment_state = 'ROUTE_IN_PROGRESS'
where id = '40000000-0000-0000-0000-000000000001';

select haulvia_test.expect_error(
  'ordinary cancellation is rejected after first LOAD',
  $sql$
    update shipments set shipment_state = 'CANCELLED'
    where id = '40000000-0000-0000-0000-000000000001'
  $sql$,
  '23514',
  'unavailable after first verified custody'
);

select haulvia_test.expect_error(
  'evidence is append-only',
  $sql$
    update stop_evidence set structured_value = '{"quantity":9}'::jsonb
    where id = '85000000-0000-0000-0000-000000000001'
  $sql$,
  '55000',
  'append-only'
);

select haulvia_test.expect_error(
  'cargo movement is append-only',
  $sql$
    update cargo_movements set quantity = 9
    where id = '86000000-0000-0000-0000-000000000001'
  $sql$,
  '55000',
  'append-only'
);

update stop_executions set state = 'EN_ROUTE' where id = '83000000-0000-0000-0000-000000000002';
update stop_executions set state = 'ARRIVED' where id = '83000000-0000-0000-0000-000000000002';
update stop_executions set state = 'SERVICE_IN_PROGRESS' where id = '83000000-0000-0000-0000-000000000002';
update stop_executions set state = 'EVIDENCE_PENDING' where id = '83000000-0000-0000-0000-000000000002';

select haulvia_test.expect_error(
  'LOAD movement is rejected at a delivery stop',
  $sql$
    insert into cargo_movements (
      id, shipment_id, route_execution_id, route_version_id, stop_execution_id,
      cargo_allocation_id, movement_type, quantity, quantity_unit,
      occurred_at, recorded_by_profile_id, idempotency_key
    ) values (
      '86000000-0000-0000-0000-000000000002',
      '40000000-0000-0000-0000-000000000001',
      '82000000-0000-0000-0000-000000000001',
      '50000000-0000-0000-0000-000000000001',
      '83000000-0000-0000-0000-000000000002',
      '54000000-0000-0000-0000-000000000001',
      'LOAD', 1, 'carton', clock_timestamp(),
      '21000000-0000-0000-0000-000000000001', 'invalid-load-at-delivery'
    )
  $sql$,
  '23514',
  'not valid at stop type'
);

insert into cargo_movements (
  id, shipment_id, route_execution_id, route_version_id, stop_execution_id,
  cargo_allocation_id, movement_type, quantity, quantity_unit,
  occurred_at, recorded_by_profile_id, idempotency_key
) values (
  '86000000-0000-0000-0000-000000000003',
  '40000000-0000-0000-0000-000000000001',
  '82000000-0000-0000-0000-000000000001',
  '50000000-0000-0000-0000-000000000001',
  '83000000-0000-0000-0000-000000000002',
  '54000000-0000-0000-0000-000000000001',
  'UNLOAD', 10, 'carton', clock_timestamp(),
  '21000000-0000-0000-0000-000000000001', 'unload-1'
);

update stop_executions set state = 'COMPLETED' where id = '83000000-0000-0000-0000-000000000002';
update route_executions set state = 'COMPLETED', completed_at = clock_timestamp()
where id = '82000000-0000-0000-0000-000000000001';

select haulvia_test.assert_true(
  'custody ledger balances to zero',
  (select onboard_quantity = 0 from v_cargo_custody_balance
   where shipment_id = '40000000-0000-0000-0000-000000000001'
     and stable_cargo_key = '53100000-0000-0000-0000-000000000001')
);

update shipments
set shipment_state = 'DELIVERED'
where id = '40000000-0000-0000-0000-000000000001';

update shipments
set shipment_state = 'COMPLETED'
where id = '40000000-0000-0000-0000-000000000001';

select haulvia_test.expect_error(
  'completed shipment is immutable',
  $sql$
    update shipments set currency = 'USD'
    where id = '40000000-0000-0000-0000-000000000001'
  $sql$,
  '55000',
  'Terminal shipment'
);

select haulvia_test.expect_error(
  'shipment state history is append-only',
  $sql$
    update shipment_state_events set command_name = 'tampered'
    where shipment_id = '40000000-0000-0000-0000-000000000001'
  $sql$,
  '55000',
  'append-only'
);

select
  count(*) as passed_tests,
  min(test_name) as first_test,
  max(test_name) as last_test
from haulvia_test_results;

rollback;
