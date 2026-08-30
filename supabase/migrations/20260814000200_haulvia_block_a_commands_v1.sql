-- Haulvia Block A command layer v1
-- Approved source: State Transition Matrix v1.1, Block A (A01-A19)
-- Depends on: 20260814000100_haulvia_foundation_v1.sql
-- Target: PostgreSQL 16; compatible with Supabase Postgres
-- Security boundary: trusted service role only; end-user RLS remains deferred.

begin;

create schema if not exists haulvia_command;
revoke all on schema haulvia_command from public;
set local search_path = haulvia, haulvia_command, public;

-- System-worker calls have a null actor_profile_id. The foundation constraint
-- intentionally permits that value, so this expression index closes the null
-- idempotency gap without changing the retained foundation table identity.
create unique index command_idempotency_actor_scope_uq
  on haulvia.command_idempotency (
    coalesce(actor_profile_id, '00000000-0000-0000-0000-000000000000'::uuid),
    command_name,
    idempotency_key
  );

drop index haulvia.audit_events_idempotency_uq;
create unique index audit_events_actor_scope_idempotency_uq
  on haulvia.audit_events (
    coalesce(actor_profile_id, '00000000-0000-0000-0000-000000000000'::uuid),
    command_name,
    idempotency_key
  )
  where idempotency_key is not null;

-- More than one payment intent may be created before a provider assigns its
-- external reference. Once present, the provider/reference pair is unique.
alter table haulvia.payment_intents
  drop constraint payment_intents_external_provider_external_reference_key;
create unique index payment_intents_provider_reference_uq
  on haulvia.payment_intents (external_provider, external_reference)
  where external_reference is not null;

-- A verified external payment-method reference is evidence, not card data.
create table haulvia.customer_payment_method_refs (
  id uuid primary key default gen_random_uuid(),
  customer_organization_id uuid references haulvia.organizations(id),
  customer_profile_id uuid references haulvia.profiles(id),
  external_provider text not null,
  external_reference text not null,
  status haulvia.record_status not null default 'ACTIVE',
  verified_at timestamptz not null,
  revoked_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (external_provider, external_reference),
  check (num_nonnulls(customer_organization_id, customer_profile_id) >= 1),
  check (revoked_at is null or revoked_at >= verified_at)
);

-- Durable internal outbox for expiry, timeout, void/refund, and reminder work.
create table haulvia.workflow_jobs (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid references haulvia.shipments(id),
  job_code text not null,
  status text not null default 'QUEUED'
    check (status in ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED')),
  run_after timestamptz not null default clock_timestamp(),
  payload jsonb not null default '{}'::jsonb,
  attempt_count integer not null default 0,
  last_error text,
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (job_code, idempotency_key),
  check (attempt_count >= 0)
);

-- Pre-assignment cancellation decisions are immutable retained evidence.
create table haulvia.shipment_cancellation_snapshots (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_version_id uuid references haulvia.route_versions(id),
  policy_version_id uuid references haulvia.policy_versions(id),
  cancelled_by_profile_id uuid references haulvia.profiles(id),
  reason text not null,
  prior_shipment_state haulvia.shipment_state not null,
  prior_marketplace_state haulvia.marketplace_state not null,
  prior_payment_state haulvia.customer_payment_state not null,
  financial_action text not null,
  snapshot jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  unique (shipment_id, idempotency_key),
  check (length(btrim(reason)) >= 3)
);

-- Reservation release must restore PAUSED instead of silently reopening the
-- listing. Retain the pre-reservation marketplace state on the reservation.
alter table haulvia.offer_reservations
  add column marketplace_state_before_reservation haulvia.marketplace_state;

alter table haulvia.offer_reservations
  add constraint offer_reservations_prior_marketplace_ck check (
    marketplace_state_before_reservation is null
    or marketplace_state_before_reservation in ('ACTIVE', 'PAUSED')
  );

create trigger customer_payment_method_refs_touch_updated_at
before update on haulvia.customer_payment_method_refs
for each row execute function haulvia.touch_updated_at();

create trigger workflow_jobs_touch_updated_at
before update on haulvia.workflow_jobs
for each row execute function haulvia.touch_updated_at();

create trigger shipment_cancellation_snapshots_append_only
before update or delete on haulvia.shipment_cancellation_snapshots
for each row execute function haulvia.reject_append_only_mutation();

-- ---------------------------------------------------------------------------
-- Stable request/error/idempotency helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.fail(
  p_code text,
  p_message text,
  p_context jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  raise exception using
    errcode = 'P0001',
    message = p_message,
    detail = jsonb_build_object('code', p_code, 'context', coalesce(p_context, '{}'::jsonb))::text;
end;
$$;

create or replace function haulvia_command.required_text(p_request jsonb, p_key text)
returns text
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_value text;
begin
  v_value := nullif(btrim(p_request ->> p_key), '');
  if v_value is null then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      format('Required request field %s is missing', p_key),
      jsonb_build_object('field', p_key)
    );
  end if;
  return v_value;
end;
$$;

create or replace function haulvia_command.optional_uuid(p_request jsonb, p_key text)
returns uuid
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
  return v_text::uuid;
exception when invalid_text_representation then
  perform haulvia_command.fail(
    'INVALID_REQUEST',
    format('Request field %s must be a UUID', p_key),
    jsonb_build_object('field', p_key)
  );
  return null;
end;
$$;

create or replace function haulvia_command.required_uuid(p_request jsonb, p_key text)
returns uuid
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_value uuid;
begin
  v_value := haulvia_command.optional_uuid(p_request, p_key);
  if v_value is null then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      format('Required request field %s is missing', p_key),
      jsonb_build_object('field', p_key)
    );
  end if;
  return v_value;
end;
$$;

create or replace function haulvia_command.required_timestamptz(p_request jsonb, p_key text)
returns timestamptz
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  return haulvia_command.required_text(p_request, p_key)::timestamptz;
exception when invalid_datetime_format or datetime_field_overflow then
  perform haulvia_command.fail(
    'INVALID_REQUEST',
    format('Request field %s must be a timestamp with time zone', p_key),
    jsonb_build_object('field', p_key)
  );
  return null;
end;
$$;

create or replace function haulvia_command.required_numeric(p_request jsonb, p_key text)
returns numeric
language plpgsql
immutable
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  return haulvia_command.required_text(p_request, p_key)::numeric;
exception when invalid_text_representation then
  perform haulvia_command.fail(
    'INVALID_REQUEST',
    format('Request field %s must be numeric', p_key),
    jsonb_build_object('field', p_key)
  );
  return null;
end;
$$;

create or replace function haulvia_command.begin_request(
  p_actor_profile_id uuid,
  p_command_name text,
  p_idempotency_key text,
  p_request_hash text
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_row haulvia.command_idempotency%rowtype;
begin
  if p_request_hash !~ '^[0-9a-fA-F]{64}$' then
    perform haulvia_command.fail('INVALID_REQUEST', 'requestHash must be a 64-character SHA-256 hex value');
  end if;

  insert into haulvia.command_idempotency (
    actor_profile_id, command_name, idempotency_key, request_hash
  ) values (
    p_actor_profile_id, p_command_name, p_idempotency_key, lower(p_request_hash)
  )
  on conflict do nothing;

  select * into v_row
  from haulvia.command_idempotency ci
  where ci.actor_profile_id is not distinct from p_actor_profile_id
    and ci.command_name = p_command_name
    and ci.idempotency_key = p_idempotency_key
  for update;

  if v_row.request_hash <> lower(p_request_hash) then
    perform haulvia_command.fail(
      'IDEMPOTENCY_KEY_REUSED',
      'The idempotency key was already used with a different request',
      jsonb_build_object('commandName', p_command_name, 'idempotencyKey', p_idempotency_key)
    );
  end if;

  if v_row.status = 'COMPLETED' then
    return coalesce(v_row.result, '{}'::jsonb) || jsonb_build_object('replayed', true);
  end if;

  return null;
end;
$$;

create or replace function haulvia_command.complete_request(
  p_actor_profile_id uuid,
  p_command_name text,
  p_idempotency_key text,
  p_result jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_result jsonb;
begin
  v_result := coalesce(p_result, '{}'::jsonb) || jsonb_build_object('replayed', false);
  update haulvia.command_idempotency
  set status = 'COMPLETED', result = v_result, completed_at = clock_timestamp()
  where actor_profile_id is not distinct from p_actor_profile_id
    and command_name = p_command_name
    and idempotency_key = p_idempotency_key;
  return v_result;
end;
$$;

create or replace function haulvia_command.lock_shipment(p_request jsonb)
returns haulvia.shipments
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_shipment haulvia.shipments%rowtype;
  v_shipment_id uuid;
  v_expected_version bigint;
begin
  v_shipment_id := haulvia_command.required_uuid(p_request, 'shipmentId');
  v_expected_version := haulvia_command.required_text(p_request, 'expectedShipmentVersion')::bigint;

  select * into v_shipment
  from haulvia.shipments s
  where s.id = v_shipment_id
  for update;

  if not found then
    perform haulvia_command.fail('NOT_FOUND', 'Shipment was not found');
  end if;

  if v_shipment.lock_version <> v_expected_version then
    perform haulvia_command.fail(
      'STALE_SHIPMENT_VERSION',
      'The shipment changed after the request was prepared',
      jsonb_build_object('expected', v_expected_version, 'current', v_shipment.lock_version)
    );
  end if;

  return v_shipment;
exception when invalid_text_representation then
  perform haulvia_command.fail('INVALID_REQUEST', 'expectedShipmentVersion must be an integer');
  return null;
end;
$$;

create or replace function haulvia_command.authorize_customer(
  p_shipment haulvia.shipments,
  p_actor_profile_id uuid,
  p_actor_organization_id uuid
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if p_actor_profile_id is null or not (
    p_shipment.customer_profile_id = p_actor_profile_id
    or (
      p_shipment.customer_organization_id is not null
      and p_shipment.customer_organization_id = p_actor_organization_id
      and exists (
        select 1
        from haulvia.organization_memberships om
        where om.organization_id = p_actor_organization_id
          and om.profile_id = p_actor_profile_id
          and om.status = 'ACTIVE'
          and (om.ends_at is null or om.ends_at > clock_timestamp())
      )
    )
  ) then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'Actor does not own this shipment');
  end if;
end;
$$;

create or replace function haulvia_command.assert_worker(
  p_actor_profile_id uuid,
  p_worker_authority text,
  p_allowed text[]
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if p_actor_profile_id is not null
     or p_worker_authority is null
     or not (upper(p_worker_authority) = any(p_allowed)) then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'Trusted worker authority is required');
  end if;
end;
$$;

create or replace function haulvia_command.assert_provider_eligible(
  p_actor_profile_id uuid,
  p_actor_organization_id uuid,
  p_provider_id uuid,
  p_driver_id uuid,
  p_vehicle_id uuid,
  p_expected_kind haulvia.provider_kind default null
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
    where sp.id = p_provider_id
      and sp.organization_id = p_actor_organization_id
      and sp.status = 'ACTIVE'
      and (p_expected_kind is null or sp.kind = p_expected_kind)
      and pd.status = 'ACTIVE'
      and (pd.ends_at is null or pd.ends_at > clock_timestamp())
      and d.status = 'ACTIVE'
      and v.status = 'ACTIVE'
      and (
        d.profile_id = p_actor_profile_id
        or exists (
          select 1 from haulvia.organization_memberships om
          where om.organization_id = sp.organization_id
            and om.profile_id = p_actor_profile_id
            and om.status = 'ACTIVE'
            and (om.ends_at is null or om.ends_at > clock_timestamp())
        )
      )
  ) then
    perform haulvia_command.fail(
      'NOT_AUTHORIZED',
      'Provider actor or provider/driver/vehicle eligibility failed'
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
      'Provider, driver, or vehicle has an unresolved required compliance item'
    );
  end if;
end;
$$;

create or replace function haulvia_command.assert_expected_route(
  p_shipment_id uuid,
  p_request jsonb,
  p_allowed_statuses haulvia.route_version_status[]
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_route_id uuid;
begin
  v_route_id := haulvia_command.required_uuid(p_request, 'expectedRouteVersionId');
  if not exists (
    select 1 from haulvia.route_versions rv
    where rv.id = v_route_id
      and rv.shipment_id = p_shipment_id
      and rv.status = any(p_allowed_statuses)
  ) then
    perform haulvia_command.fail(
      'STALE_ROUTE_VERSION',
      'The request does not reference the shipment current route version',
      jsonb_build_object('routeVersionId', v_route_id)
    );
  end if;
  return v_route_id;
end;
$$;

create or replace function haulvia_command.assert_no_reservation_or_assignment(p_shipment_id uuid)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if exists (
    select 1 from haulvia.offer_reservations r
    where r.shipment_id = p_shipment_id and r.status = 'ACTIVE'
  ) then
    perform haulvia_command.fail('RESERVATION_CONFLICT', 'An active reservation already exists');
  end if;
  if exists (
    select 1 from haulvia.assignments a
    where a.shipment_id = p_shipment_id and a.status = 'ACTIVE'
  ) then
    perform haulvia_command.fail('ASSIGNMENT_CONFLICT', 'An active assignment already exists');
  end if;
end;
$$;

create or replace function haulvia_command.assert_payment_method(
  p_shipment haulvia.shipments,
  p_payment_method_id uuid
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if not exists (
    select 1 from haulvia.customer_payment_method_refs pm
    where pm.id = p_payment_method_id
      and pm.status = 'ACTIVE'
      and pm.revoked_at is null
      and (pm.customer_profile_id is null or pm.customer_profile_id = p_shipment.customer_profile_id)
      and (pm.customer_organization_id is null or pm.customer_organization_id = p_shipment.customer_organization_id)
  ) then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'A current verified payment method is required');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Route-plan import and validation helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.replace_draft_plan(
  p_route_version_id uuid,
  p_plan jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if jsonb_typeof(p_plan) <> 'object'
     or jsonb_typeof(p_plan -> 'stops') <> 'array'
     or jsonb_typeof(p_plan -> 'legs') <> 'array'
     or jsonb_typeof(p_plan -> 'cargoItems') <> 'array'
     or jsonb_typeof(p_plan -> 'allocations') <> 'array' then
    perform haulvia_command.fail('INVALID_REQUEST', 'routePlan must contain stops, legs, cargoItems, and allocations arrays');
  end if;

  if not exists (
    select 1 from haulvia.route_versions rv
    where rv.id = p_route_version_id and rv.status = 'DRAFT'
    for update
  ) then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Only a draft route plan may be replaced');
  end if;

  delete from haulvia.cargo_allocations where route_version_id = p_route_version_id;
  delete from haulvia.route_legs where route_version_id = p_route_version_id;
  delete from haulvia.cargo_items where route_version_id = p_route_version_id;
  delete from haulvia.route_stops where route_version_id = p_route_version_id;

  insert into haulvia.route_stops (
    id, route_version_id, stable_stop_key, sequence_no, stop_type,
    address_label, address_line1, address_line2, city, region_code, postal_code,
    country_code, latitude, longitude, geofence_radius_m, contact_name,
    contact_phone, contact_email, service_window_start, service_window_end,
    planned_service_seconds, instructions, verification_profile
  )
  select
    (x ->> 'id')::uuid,
    p_route_version_id,
    (x ->> 'stableStopKey')::uuid,
    (x ->> 'sequenceNo')::integer,
    (x ->> 'stopType')::haulvia.stop_type,
    nullif(x ->> 'addressLabel', ''),
    x ->> 'addressLine1',
    nullif(x ->> 'addressLine2', ''),
    x ->> 'city',
    upper(x ->> 'regionCode'),
    nullif(x ->> 'postalCode', ''),
    upper(coalesce(nullif(x ->> 'countryCode', ''), 'CA')),
    nullif(x ->> 'latitude', '')::numeric,
    nullif(x ->> 'longitude', '')::numeric,
    nullif(x ->> 'geofenceRadiusM', '')::integer,
    nullif(x ->> 'contactName', ''),
    nullif(x ->> 'contactPhone', ''),
    nullif(x ->> 'contactEmail', ''),
    nullif(x ->> 'serviceWindowStart', '')::timestamptz,
    nullif(x ->> 'serviceWindowEnd', '')::timestamptz,
    coalesce(nullif(x ->> 'plannedServiceSeconds', '')::integer, 0),
    nullif(x ->> 'instructions', ''),
    coalesce(x -> 'verificationProfile', '{}'::jsonb)
  from jsonb_array_elements(p_plan -> 'stops') x;

  insert into haulvia.cargo_items (
    id, route_version_id, stable_cargo_key, cargo_line_no, description,
    quantity, quantity_unit, total_weight_kg, total_volume_m3, declared_value,
    currency, handling_requirements, risk_attributes
  )
  select
    (x ->> 'id')::uuid,
    p_route_version_id,
    (x ->> 'stableCargoKey')::uuid,
    (x ->> 'cargoLineNo')::integer,
    x ->> 'description',
    (x ->> 'quantity')::numeric,
    x ->> 'quantityUnit',
    nullif(x ->> 'totalWeightKg', '')::numeric,
    nullif(x ->> 'totalVolumeM3', '')::numeric,
    nullif(x ->> 'declaredValue', '')::numeric,
    nullif(upper(x ->> 'currency'), ''),
    coalesce(x -> 'handlingRequirements', '{}'::jsonb),
    coalesce(x -> 'riskAttributes', '{}'::jsonb)
  from jsonb_array_elements(p_plan -> 'cargoItems') x;

  insert into haulvia.route_legs (
    id, route_version_id, sequence_no, from_stop_id, to_stop_id,
    planned_distance_km, planned_duration_seconds, route_provider_payload
  )
  select
    (x ->> 'id')::uuid,
    p_route_version_id,
    (x ->> 'sequenceNo')::integer,
    (x ->> 'fromStopId')::uuid,
    (x ->> 'toStopId')::uuid,
    nullif(x ->> 'plannedDistanceKm', '')::numeric,
    nullif(x ->> 'plannedDurationSeconds', '')::integer,
    coalesce(x -> 'routeProviderPayload', '{}'::jsonb)
  from jsonb_array_elements(p_plan -> 'legs') x;

  insert into haulvia.cargo_allocations (
    id, route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id,
    quantity, quantity_unit, allocation_note
  )
  select
    (x ->> 'id')::uuid,
    p_route_version_id,
    (x ->> 'cargoItemId')::uuid,
    (x ->> 'pickupStopId')::uuid,
    (x ->> 'deliveryStopId')::uuid,
    (x ->> 'quantity')::numeric,
    x ->> 'quantityUnit',
    nullif(x ->> 'allocationNote', '')
  from jsonb_array_elements(p_plan -> 'allocations') x;

  update haulvia.route_versions
  set planned_distance_km = nullif(p_plan ->> 'plannedDistanceKm', '')::numeric,
      planned_duration_seconds = nullif(p_plan ->> 'plannedDurationSeconds', '')::integer
  where id = p_route_version_id;
exception
  when invalid_text_representation or not_null_violation or check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'ROUTE_INVALID',
      'The route plan payload violates a route, stop, cargo, or allocation rule',
      jsonb_build_object('databaseMessage', sqlerrm)
    );
end;
$$;

create or replace function haulvia_command.validate_route_plan(p_route_version_id uuid)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_stop_count integer;
  v_leg_count integer;
  v_cargo_count integer;
  v_min_sequence integer;
  v_max_sequence integer;
begin
  select count(*), min(sequence_no), max(sequence_no)
  into v_stop_count, v_min_sequence, v_max_sequence
  from haulvia.route_stops where route_version_id = p_route_version_id;

  select count(*) into v_leg_count
  from haulvia.route_legs where route_version_id = p_route_version_id;

  select count(*) into v_cargo_count
  from haulvia.cargo_items where route_version_id = p_route_version_id;

  if v_stop_count < 2 or v_min_sequence <> 1 or v_max_sequence <> v_stop_count then
    perform haulvia_command.fail('ROUTE_INVALID', 'Stops must be contiguous and begin at sequence 1');
  end if;

  if not exists (
    select 1 from haulvia.route_stops where route_version_id = p_route_version_id and stop_type = 'PICKUP'
  ) or not exists (
    select 1 from haulvia.route_stops
    where route_version_id = p_route_version_id and stop_type in ('DELIVERY', 'RETURN', 'STORAGE')
  ) then
    perform haulvia_command.fail('ROUTE_INVALID', 'Route requires pickup and delivery/recovery endpoints');
  end if;

  if v_leg_count <> v_stop_count - 1 or exists (
    select 1
    from haulvia.route_legs rl
    join haulvia.route_stops f on f.route_version_id = rl.route_version_id and f.id = rl.from_stop_id
    join haulvia.route_stops t on t.route_version_id = rl.route_version_id and t.id = rl.to_stop_id
    where rl.route_version_id = p_route_version_id
      and (t.sequence_no <> f.sequence_no + 1 or rl.sequence_no <> f.sequence_no)
  ) then
    perform haulvia_command.fail('ROUTE_INVALID', 'Legs must connect every adjacent ordered stop exactly once');
  end if;

  if v_cargo_count < 1 or exists (
    select 1
    from haulvia.cargo_items ci
    left join haulvia.cargo_allocations ca
      on ca.route_version_id = ci.route_version_id and ca.cargo_item_id = ci.id
    where ci.route_version_id = p_route_version_id
    group by ci.id, ci.quantity
    having coalesce(sum(ca.quantity), 0) <> ci.quantity
  ) then
    perform haulvia_command.fail('ROUTE_INVALID', 'Every cargo line must be allocated in full');
  end if;
end;
$$;

create or replace function haulvia_command.create_route_from_plan(
  p_shipment_id uuid,
  p_prior_route_version_id uuid,
  p_actor_profile_id uuid,
  p_reason text,
  p_plan jsonb
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_route_id uuid;
  v_version_no integer;
begin
  select coalesce(max(version_no), 0) + 1
  into v_version_no
  from haulvia.route_versions
  where shipment_id = p_shipment_id;

  insert into haulvia.route_versions (
    shipment_id, version_no, status, prior_route_version_id, change_reason,
    created_by_profile_id
  ) values (
    p_shipment_id, v_version_no, 'DRAFT', p_prior_route_version_id,
    coalesce(nullif(btrim(p_reason), ''), 'Route plan created'), p_actor_profile_id
  ) returning id into v_route_id;

  perform haulvia_command.replace_draft_plan(v_route_id, p_plan);
  perform haulvia_command.validate_route_plan(v_route_id);
  return v_route_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Pricing snapshots, events, outbox, and response helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.create_price_snapshot(
  p_shipment haulvia.shipments,
  p_route_version_id uuid,
  p_purpose haulvia.price_snapshot_purpose,
  p_request jsonb,
  p_actor_profile_id uuid
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_source haulvia.pricing_source;
  v_mode haulvia.partner_pricing_mode;
  v_rule_version_id uuid;
  v_rate_card_version_id uuid;
  v_amount numeric(14,2);
  v_tax numeric(14,2);
  v_subtotal numeric(14,2);
  v_currency char(3);
  v_review_status haulvia.pricing_review_status := 'PASSED';
  v_review_id uuid;
  v_snapshot_id uuid;
  v_rule_config jsonb;
  v_floor numeric;
  v_ceiling numeric;
  v_absolute_cap numeric;
  v_fixed numeric;
  v_reason text;
  v_snapshot_hash text;
begin
  v_source := haulvia_command.required_text(p_request, 'pricingSource')::haulvia.pricing_source;
  v_mode := coalesce(nullif(p_request ->> 'pricingMode', ''), 'NOT_APPLICABLE')::haulvia.partner_pricing_mode;
  v_amount := haulvia_command.required_numeric(p_request, 'amount');
  v_tax := coalesce(nullif(p_request ->> 'taxAmount', '')::numeric, 0);
  v_subtotal := coalesce(nullif(p_request ->> 'subtotal', '')::numeric, v_amount - v_tax);
  v_currency := upper(coalesce(nullif(p_request ->> 'currency', ''), p_shipment.currency))::char(3);
  v_reason := nullif(btrim(p_request ->> 'structuredReason'), '');
  v_snapshot_hash := haulvia_command.required_text(p_request, 'snapshotSha256');

  if v_snapshot_hash !~ '^[0-9a-fA-F]{64}$' or v_amount < 0 or v_tax < 0
     or v_subtotal < 0 or v_subtotal + v_tax <> v_amount
     or v_currency <> p_shipment.currency then
    perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Price amount, currency, tax, subtotal, or snapshot hash is invalid');
  end if;

  if v_source in ('HAULVIA_GUARDRAIL', 'HAULVIA_FIXED') then
    if v_mode <> 'NOT_APPLICABLE' then
      perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Haulvia pricing cannot use a partner pricing mode');
    end if;
    v_rule_version_id := haulvia_command.required_uuid(p_request, 'pricingRuleVersionId');
    select prv.rule_config
    into v_rule_config
    from haulvia.pricing_rule_versions prv
    join haulvia.pricing_rule_sets prs on prs.id = prv.pricing_rule_set_id
    where prv.id = v_rule_version_id
      and prv.publication_status = 'APPROVED'
      and prv.effective_from <= clock_timestamp()
      and (prv.effective_to is null or prv.effective_to > clock_timestamp())
      and prs.pricing_source = v_source
      and prs.service_level = p_shipment.service_level
      and prs.currency = v_currency;

    if not found then
      perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Pricing rule version is not current for this shipment branch');
    end if;

    v_floor := nullif(v_rule_config ->> 'floorAmount', '')::numeric;
    v_ceiling := nullif(v_rule_config ->> 'ceilingAmount', '')::numeric;
    v_absolute_cap := nullif(v_rule_config ->> 'absoluteCapAmount', '')::numeric;
    v_fixed := nullif(v_rule_config ->> 'fixedAmount', '')::numeric;

    if v_source = 'HAULVIA_GUARDRAIL' and p_purpose = 'OFFER' then
      if v_floor is not null and v_amount < v_floor then
        perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Offer is below the approved pricing floor');
      end if;
      if v_absolute_cap is not null and v_amount > v_absolute_cap then
        perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Offer exceeds the approved absolute cap');
      end if;
      if v_ceiling is not null and v_amount > v_ceiling then
        if v_reason is null or length(v_reason) < 8 then
          perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Above-ceiling offers require a structured reason');
        end if;
        v_review_status := 'APPROVED';
      end if;
    elsif v_source = 'HAULVIA_FIXED' and v_fixed is not null and v_amount <> v_fixed then
      perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Firm price must equal the approved fixed amount');
    end if;
  else
    v_rate_card_version_id := haulvia_command.required_uuid(p_request, 'rateCardVersionId');
    select prcv.id
    into v_rate_card_version_id
    from haulvia.partner_rate_card_versions prcv
    join haulvia.partner_rate_cards prc on prc.id = prcv.rate_card_id
    join haulvia.service_providers sp on sp.id = prc.provider_id
    left join haulvia.vehicles v
      on v.id = haulvia_command.optional_uuid(p_request, 'vehicleId')
    where prcv.id = v_rate_card_version_id
      and prcv.publication_status = 'APPROVED'
      and prcv.effective_from <= clock_timestamp()
      and (prcv.effective_to is null or prcv.effective_to > clock_timestamp())
      and sp.status = 'ACTIVE'
      and (
        haulvia_command.optional_uuid(p_request, 'providerId') is null
        or sp.id = haulvia_command.optional_uuid(p_request, 'providerId')
      )
      and prc.service_level = p_shipment.service_level
      and prc.pricing_mode = v_mode
      and prc.currency = v_currency
      and (nullif(p_request ->> 'regionCode', '') is null or prc.region_code = p_request ->> 'regionCode')
      and (prc.vehicle_class is null or (v.id is not null and prc.vehicle_class = v.vehicle_class));

    if not found or v_mode = 'NOT_APPLICABLE' then
      perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Partner rate-card version or its route scope is not current');
    end if;
    if coalesce(p_request ->> 'calculationSha256', '') !~ '^[0-9a-fA-F]{64}$' then
      perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Partner rate-card calculation SHA-256 evidence is required');
    end if;
  end if;

  insert into haulvia.pricing_reviews (
    shipment_id, route_version_id, pricing_source, pricing_mode, status,
    reviewed_amount, currency, flags, rationale, reviewed_by_profile_id,
    reviewed_at, expires_at
  ) values (
    p_shipment.id, p_route_version_id, v_source, v_mode, v_review_status,
    v_amount, v_currency,
    coalesce(p_request -> 'pricingFlags', '[]'::jsonb), v_reason,
    p_actor_profile_id, clock_timestamp(),
    nullif(p_request ->> 'pricingReviewExpiresAt', '')::timestamptz
  ) returning id into v_review_id;

  insert into haulvia.shipment_price_snapshots (
    shipment_id, route_version_id, purpose, pricing_source, pricing_mode,
    pricing_rule_version_id, rate_card_version_id, pricing_review_id,
    subtotal, tax_amount, total_amount, currency, breakdown, snapshot_sha256,
    accepted_at
  ) values (
    p_shipment.id, p_route_version_id, p_purpose, v_source, v_mode,
    v_rule_version_id, v_rate_card_version_id, v_review_id,
    v_subtotal, v_tax, v_amount, v_currency,
    coalesce(p_request -> 'breakdown', '[]'::jsonb), lower(v_snapshot_hash),
    case when p_purpose in ('RESERVATION', 'ASSIGNMENT') then clock_timestamp() end
  ) returning id into v_snapshot_id;

  return v_snapshot_id;
exception
  when invalid_text_representation or check_violation or foreign_key_violation then
    perform haulvia_command.fail(
      'PRICING_REVIEW_REQUIRED',
      'Pricing request did not satisfy the approved source and snapshot rules',
      jsonb_build_object('databaseMessage', sqlerrm)
    );
  return null;
end;
$$;

create or replace function haulvia_command.clone_price_snapshot(
  p_source_snapshot_id uuid,
  p_purpose haulvia.price_snapshot_purpose,
  p_snapshot_sha256 text
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_snapshot_sha256 !~ '^[0-9a-fA-F]{64}$' then
    perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Accepted snapshot hash must be SHA-256 hex');
  end if;
  insert into haulvia.shipment_price_snapshots (
    shipment_id, route_version_id, purpose, pricing_source, pricing_mode,
    pricing_rule_version_id, rate_card_version_id, pricing_review_id,
    subtotal, tax_amount, total_amount, currency, breakdown, snapshot_sha256,
    accepted_at
  )
  select shipment_id, route_version_id, p_purpose, pricing_source, pricing_mode,
         pricing_rule_version_id, rate_card_version_id, pricing_review_id,
         subtotal, tax_amount, total_amount, currency, breakdown,
         lower(p_snapshot_sha256), clock_timestamp()
  from haulvia.shipment_price_snapshots
  where id = p_source_snapshot_id
  returning id into v_id;

  if v_id is null then
    perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Source price snapshot was not found');
  end if;
  return v_id;
end;
$$;

create or replace function haulvia_command.append_audit(
  p_shipment haulvia.shipments,
  p_command_name text,
  p_request jsonb,
  p_before jsonb,
  p_after jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
begin
  insert into haulvia.audit_events (
    actor_kind, actor_profile_id, actor_provider_id, organization_id, command_name, reason,
    entity_table, entity_id, before_value, after_value, metadata,
    correlation_id, idempotency_key
  ) values (
    case when v_actor is null then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    v_actor, haulvia_command.optional_uuid(p_request, 'providerId'),
    haulvia_command.optional_uuid(p_request, 'actorOrganizationId'),
    p_command_name, nullif(p_request ->> 'reason', ''), 'shipments', p_shipment.id,
    p_before, p_after, coalesce(p_metadata, '{}'::jsonb),
    haulvia_command.required_uuid(p_request, 'commandId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  );
end;
$$;

create or replace function haulvia_command.append_shipment_event(
  p_shipment_id uuid,
  p_prior_state haulvia.shipment_state,
  p_current_state haulvia.shipment_state,
  p_command_name text,
  p_request jsonb,
  p_route_version_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
begin
  insert into haulvia.shipment_state_events (
    shipment_id, prior_state, current_state, command_name, actor_kind,
    actor_profile_id, actor_provider_id, reason, route_version_id,
    correlation_id, idempotency_key, metadata
  ) values (
    p_shipment_id, p_prior_state, p_current_state, p_command_name,
    case when v_actor is null then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    v_actor, haulvia_command.optional_uuid(p_request, 'providerId'),
    nullif(p_request ->> 'reason', ''), p_route_version_id,
    haulvia_command.required_uuid(p_request, 'commandId'),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    coalesce(p_metadata, '{}'::jsonb)
  );
end;
$$;

create or replace function haulvia_command.append_axis_event(
  p_shipment_id uuid,
  p_axis haulvia.workflow_axis,
  p_prior_state text,
  p_current_state text,
  p_command_name text,
  p_request jsonb,
  p_axis_entity_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
begin
  insert into haulvia.workflow_axis_events (
    shipment_id, axis, axis_entity_id, prior_state, current_state, command_name,
    actor_kind, actor_profile_id, reason, correlation_id, idempotency_key, metadata
  ) values (
    p_shipment_id, p_axis, p_axis_entity_id, p_prior_state, p_current_state,
    p_command_name,
    case when v_actor is null then 'SYSTEM'::haulvia.actor_kind else 'PROFILE'::haulvia.actor_kind end,
    v_actor, nullif(p_request ->> 'reason', ''),
    haulvia_command.required_uuid(p_request, 'commandId'),
    haulvia_command.required_text(p_request, 'idempotencyKey') || ':' || lower(p_axis::text),
    coalesce(p_metadata, '{}'::jsonb)
  );
end;
$$;

create or replace function haulvia_command.queue_notification(
  p_shipment_id uuid,
  p_profile_id uuid,
  p_event_code text,
  p_request jsonb,
  p_suffix text,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into haulvia.notification_events (
    shipment_id, profile_id, event_code, channel, template_version, payload,
    idempotency_key
  ) values (
    p_shipment_id, p_profile_id, p_event_code, 'PUSH', 'v1',
    coalesce(p_payload, '{}'::jsonb),
    p_shipment_id::text || ':' || haulvia_command.required_text(p_request, 'idempotencyKey') || ':' || p_suffix
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function haulvia_command.queue_job(
  p_shipment_id uuid,
  p_job_code text,
  p_run_after timestamptz,
  p_request jsonb,
  p_suffix text,
  p_payload jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_id uuid;
begin
  insert into haulvia.workflow_jobs (
    shipment_id, job_code, run_after, payload, idempotency_key
  ) values (
    p_shipment_id, p_job_code, p_run_after, coalesce(p_payload, '{}'::jsonb),
    p_shipment_id::text || ':' || haulvia_command.required_text(p_request, 'idempotencyKey') || ':' || p_suffix
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
    'activeAssignmentId', c.active_assignment_id
  ) || coalesce(p_affected, '{}'::jsonb)
  from haulvia.v_shipment_operating_context c
  where c.shipment_id = p_shipment_id;
$$;

-- ---------------------------------------------------------------------------
-- A01-A07: draft, route, posting, and marketplace control
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_a01_save_draft(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_actor_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
  v_route_id uuid;
  v_before jsonb := to_jsonb(p_shipment);
begin
  perform haulvia_command.authorize_customer(p_shipment, v_actor, v_actor_org);
  if p_shipment.shipment_state <> 'DRAFT' then
    perform haulvia_command.fail('INVALID_STATE', 'saveDraft requires shipment state DRAFT');
  end if;

  v_route_id := haulvia_command.optional_uuid(p_request, 'expectedRouteVersionId');
  if v_route_id is not null then
    if not exists (
      select 1 from haulvia.route_versions rv
      where rv.id = v_route_id and rv.shipment_id = p_shipment.id and rv.status = 'DRAFT'
      for update
    ) then
      perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Draft route is no longer current');
    end if;
    if p_request ? 'routePlan' then
      perform haulvia_command.replace_draft_plan(v_route_id, p_request -> 'routePlan');
    end if;
  elsif p_request ? 'routePlan' then
    v_route_id := haulvia_command.create_route_from_plan(
      p_shipment.id, null, v_actor, coalesce(p_request ->> 'reason', 'Initial draft route'),
      p_request -> 'routePlan'
    );
  end if;

  update haulvia.shipments
  set pickup_timing = coalesce(nullif(p_request ->> 'pickupTiming', '')::haulvia.pickup_timing_type, pickup_timing),
      service_level = coalesce(nullif(p_request ->> 'serviceLevel', '')::haulvia.service_level, service_level),
      currency = coalesce(nullif(upper(p_request ->> 'currency'), '')::char(3), currency)
  where id = p_shipment.id;

  perform haulvia_command.append_audit(
    p_shipment, 'saveDraft', p_request, v_before,
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('routeVersionId', v_route_id, 'changedFields', coalesce(p_request -> 'changedFields', '[]'::jsonb))
  );
  return jsonb_build_object('routeVersionId', v_route_id);
end;
$$;

create or replace function haulvia_command.apply_a02_edit_draft_route(
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
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'DRAFT' then
    perform haulvia_command.fail('INVALID_STATE', 'editDraftRoute requires shipment state DRAFT');
  end if;
  v_old_route := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['DRAFT']::haulvia.route_version_status[]
  );

  v_new_route := haulvia_command.create_route_from_plan(
    p_shipment.id, v_old_route, v_actor,
    haulvia_command.required_text(p_request, 'reason'), p_request -> 'routePlan'
  );
  update haulvia.route_versions set status = 'SUPERSEDED' where id = v_old_route;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_audit(
    p_shipment, 'editDraftRoute', p_request,
    jsonb_build_object('routeVersionId', v_old_route),
    jsonb_build_object('routeVersionId', v_new_route),
    jsonb_build_object('priorRouteVersionId', v_old_route, 'newRouteVersionId', v_new_route)
  );
  return jsonb_build_object('routeVersionId', v_new_route, 'priorRouteVersionId', v_old_route);
end;
$$;

create or replace function haulvia_command.apply_a03_assign_cargo_to_stops(
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
  v_count integer;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'DRAFT' then
    perform haulvia_command.fail('INVALID_STATE', 'assignCargoToStops requires shipment state DRAFT');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['DRAFT']::haulvia.route_version_status[]
  );
  if jsonb_typeof(p_request -> 'allocations') <> 'array' then
    perform haulvia_command.fail('INVALID_REQUEST', 'allocations must be a complete JSON array');
  end if;

  delete from haulvia.cargo_allocations where route_version_id = v_route_id;
  insert into haulvia.cargo_allocations (
    id, route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id,
    quantity, quantity_unit, allocation_note
  )
  select
    (x ->> 'id')::uuid, v_route_id, (x ->> 'cargoItemId')::uuid,
    (x ->> 'pickupStopId')::uuid, (x ->> 'deliveryStopId')::uuid,
    (x ->> 'quantity')::numeric, x ->> 'quantityUnit',
    nullif(x ->> 'allocationNote', '')
  from jsonb_array_elements(p_request -> 'allocations') x;

  perform haulvia_command.validate_route_plan(v_route_id);
  select count(*) into v_count from haulvia.cargo_allocations where route_version_id = v_route_id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  perform haulvia_command.append_audit(
    p_shipment, 'assignCargoToStops', p_request, null,
    jsonb_build_object('allocationCount', v_count),
    jsonb_build_object('routeVersionId', v_route_id, 'allocationCount', v_count)
  );
  return jsonb_build_object('routeVersionId', v_route_id, 'allocationCount', v_count);
exception
  when invalid_text_representation or check_violation or foreign_key_violation or unique_violation then
    perform haulvia_command.fail(
      'ROUTE_INVALID', 'Cargo allocation set is invalid',
      jsonb_build_object('databaseMessage', sqlerrm)
    );
  return null;
end;
$$;

create or replace function haulvia_command.apply_a04_post_shipment(
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
  v_payment_method_id uuid;
  v_policy_version_id uuid;
  v_price_snapshot_id uuid;
  v_rule_snapshot_id uuid;
  v_deadline timestamptz;
  v_policy haulvia.policy_versions%rowtype;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'DRAFT' then
    perform haulvia_command.fail('INVALID_STATE', 'postShipment requires shipment state DRAFT');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['DRAFT']::haulvia.route_version_status[]
  );
  v_payment_method_id := haulvia_command.required_uuid(p_request, 'paymentMethodId');
  perform haulvia_command.assert_payment_method(p_shipment, v_payment_method_id);
  perform haulvia_command.validate_route_plan(v_route_id);
  v_deadline := haulvia_command.required_timestamptz(p_request, 'marketplaceDeadline');
  if v_deadline <= clock_timestamp() then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Marketplace deadline must be in the future');
  end if;

  v_policy_version_id := haulvia_command.required_uuid(p_request, 'policyVersionId');
  select * into v_policy from haulvia.policy_versions pv
  where pv.id = v_policy_version_id
    and pv.publication_status = 'APPROVED'
    and pv.effective_from <= clock_timestamp()
    and (pv.effective_to is null or pv.effective_to > clock_timestamp());
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'A current approved policy version is required');
  end if;

  update haulvia.route_versions set status = 'ACTIVE' where id = v_route_id;
  insert into haulvia.shipment_rule_snapshots (
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  ) values (
    p_shipment.id, v_route_id, v_policy_version_id,
    coalesce(v_policy.config -> 'evidenceRequirements', '{}'::jsonb),
    coalesce(v_policy.config -> 'cancellationRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'refundRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'timingWindows', '{}'::jsonb),
    coalesce(v_policy.config -> 'riskRules', '{}'::jsonb),
    v_policy.config_sha256
  ) returning id into v_rule_snapshot_id;
  v_price_snapshot_id := haulvia_command.create_price_snapshot(
    p_shipment, v_route_id, 'POSTING', p_request, v_actor
  );

  update haulvia.shipment_customer_payment_axes
  set state = 'METHOD_VERIFIED', state_changed_at = clock_timestamp(), currency = p_shipment.currency
  where shipment_id = p_shipment.id;
  update haulvia.shipment_marketplace_axes
  set state = 'ACTIVE', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments
  set shipment_state = 'POSTED', marketplace_deadline = v_deadline
  where id = p_shipment.id;

  perform haulvia_command.append_shipment_event(
    p_shipment.id, 'DRAFT', 'POSTED', 'postShipment', p_request, v_route_id,
    jsonb_build_object('priceSnapshotId', v_price_snapshot_id, 'ruleSnapshotId', v_rule_snapshot_id)
  );
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', 'INACTIVE', 'ACTIVE', 'postShipment', p_request);
  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', 'UNFUNDED', 'METHOD_VERIFIED', 'postShipment', p_request);
  perform haulvia_command.append_audit(
    p_shipment, 'postShipment', p_request, to_jsonb(p_shipment),
    (select to_jsonb(s) from haulvia.shipments s where s.id = p_shipment.id),
    jsonb_build_object('paymentMethodId', v_payment_method_id, 'priceSnapshotId', v_price_snapshot_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_POSTED', p_request,
    'shipment-posted', jsonb_build_object('shipmentReference', p_shipment.shipment_reference)
  );
  perform haulvia_command.queue_job(
    p_shipment.id, 'EXPIRE_MARKETPLACE_LISTING', v_deadline, p_request,
    'marketplace-expiry', jsonb_build_object('observedRouteVersionId', v_route_id)
  );
  return jsonb_build_object(
    'routeVersionId', v_route_id,
    'priceSnapshotId', v_price_snapshot_id,
    'ruleSnapshotId', v_rule_snapshot_id
  );
end;
$$;

create or replace function haulvia_command.apply_a05_edit_posted_shipment(
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
  v_price_snapshot_id uuid;
  v_policy_version_id uuid;
  v_policy haulvia.policy_versions%rowtype;
  v_affected_offers integer;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'POSTED' then
    perform haulvia_command.fail('INVALID_STATE', 'editPostedShipment requires shipment state POSTED');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  v_old_route := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_new_route := haulvia_command.create_route_from_plan(
    p_shipment.id, v_old_route, v_actor,
    haulvia_command.required_text(p_request, 'reason'), p_request -> 'routePlan'
  );

  v_policy_version_id := haulvia_command.required_uuid(p_request, 'policyVersionId');
  select * into v_policy from haulvia.policy_versions pv
  where pv.id = v_policy_version_id and pv.publication_status = 'APPROVED'
    and pv.effective_from <= clock_timestamp()
    and (pv.effective_to is null or pv.effective_to > clock_timestamp());
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'A current approved policy version is required');
  end if;

  update haulvia.offer_threads
  set status = 'RECONFIRMATION_REQUIRED', reconfirmation_route_version_id = v_new_route
  where shipment_id = p_shipment.id
    and route_version_id = v_old_route
    and status = 'ACTIVE';
  get diagnostics v_affected_offers = row_count;
  if v_affected_offers > 0 then
    update haulvia.shipment_marketplace_axes
    set state = 'PAUSED', paused_reason = 'ROUTE_CHANGED', state_changed_at = clock_timestamp()
    where shipment_id = p_shipment.id;
  end if;

  update haulvia.route_versions set status = 'SUPERSEDED' where id = v_old_route;
  update haulvia.route_versions set status = 'ACTIVE' where id = v_new_route;
  insert into haulvia.shipment_rule_snapshots (
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  ) values (
    p_shipment.id, v_new_route, v_policy_version_id,
    coalesce(v_policy.config -> 'evidenceRequirements', '{}'::jsonb),
    coalesce(v_policy.config -> 'cancellationRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'refundRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'timingWindows', '{}'::jsonb),
    coalesce(v_policy.config -> 'riskRules', '{}'::jsonb), v_policy.config_sha256
  );
  v_price_snapshot_id := haulvia_command.create_price_snapshot(
    p_shipment, v_new_route, 'POSTING', p_request, v_actor
  );
  update haulvia.shipments
  set marketplace_deadline = coalesce(nullif(p_request ->> 'marketplaceDeadline', '')::timestamptz, marketplace_deadline)
  where id = p_shipment.id;

  perform haulvia_command.append_audit(
    p_shipment, 'editPostedShipment', p_request,
    jsonb_build_object('routeVersionId', v_old_route),
    jsonb_build_object('routeVersionId', v_new_route),
    jsonb_build_object('affectedOfferCount', v_affected_offers, 'priceSnapshotId', v_price_snapshot_id)
  );
  if v_affected_offers > 0 then
    perform haulvia_command.queue_notification(
      p_shipment.id, p_shipment.customer_profile_id, 'POSTED_SHIPMENT_UPDATED', p_request,
      'posted-update', jsonb_build_object('affectedOfferCount', v_affected_offers)
    );
  end if;
  return jsonb_build_object(
    'routeVersionId', v_new_route,
    'priorRouteVersionId', v_old_route,
    'priceSnapshotId', v_price_snapshot_id,
    'affectedOfferCount', v_affected_offers
  );
end;
$$;

create or replace function haulvia_command.apply_a06_pause_marketplace(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_prior haulvia.marketplace_state;
  v_reason text := haulvia_command.required_text(p_request, 'reason');
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'pauseMarketplace requires POSTED or NEGOTIATING');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  select state into v_prior from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;
  if v_prior <> 'ACTIVE' then
    perform haulvia_command.fail('INVALID_STATE', 'Only an active marketplace can be paused');
  end if;

  update haulvia.shipment_marketplace_axes
  set state = 'PAUSED', paused_reason = v_reason, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', v_prior::text, 'PAUSED', 'pauseMarketplace', p_request);
  perform haulvia_command.append_audit(p_shipment, 'pauseMarketplace', p_request, jsonb_build_object('state', v_prior), jsonb_build_object('state', 'PAUSED'));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'MARKETPLACE_PAUSED', p_request, 'paused');
  return jsonb_build_object('pauseReason', v_reason);
end;
$$;

create or replace function haulvia_command.apply_a07_resume_marketplace(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_route_id uuid;
  v_new_market haulvia.marketplace_state;
begin
  if v_actor is null then
    perform haulvia_command.assert_worker(v_actor, p_request ->> 'workerAuthority', array['EXPIRY_WORKER']);
  else
    perform haulvia_command.authorize_customer(
      p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
    );
  end if;
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'resumeMarketplace requires POSTED or NEGOTIATING');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  if not exists (
    select 1 from haulvia.shipment_marketplace_axes ma
    where ma.shipment_id = p_shipment.id and ma.state = 'PAUSED' for update
  ) then
    perform haulvia_command.fail('INVALID_STATE', 'Marketplace is not paused');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  if not exists (
    select 1 from haulvia.pricing_reviews pr
    where pr.shipment_id = p_shipment.id and pr.route_version_id = v_route_id
      and pr.status in ('PASSED', 'APPROVED')
      and (pr.expires_at is null or pr.expires_at > clock_timestamp())
  ) then
    perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Current route pricing review is missing or expired');
  end if;

  update haulvia.offer_threads
  set status = 'EXPIRED', closed_at = clock_timestamp()
  where shipment_id = p_shipment.id and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED')
    and expires_at <= clock_timestamp();

  if p_shipment.marketplace_deadline <= clock_timestamp() then
    update haulvia.offer_threads
    set status = 'EXPIRED', closed_at = clock_timestamp()
    where shipment_id = p_shipment.id and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED');
    update haulvia.shipment_marketplace_axes
    set state = 'EXPIRED', paused_reason = null, state_changed_at = clock_timestamp()
    where shipment_id = p_shipment.id;
    update haulvia.shipments set shipment_state = 'EXPIRED' where id = p_shipment.id;
    perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', 'PAUSED', 'EXPIRED', 'resumeMarketplace', p_request);
    perform haulvia_command.append_shipment_event(p_shipment.id, p_shipment.shipment_state, 'EXPIRED', 'expireListing', p_request, v_route_id);
    perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_EXPIRED', p_request, 'resume-expired');
    v_new_market := 'EXPIRED';
  else
    update haulvia.shipment_marketplace_axes
    set state = 'ACTIVE', paused_reason = null, state_changed_at = clock_timestamp()
    where shipment_id = p_shipment.id;
    update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
    perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', 'PAUSED', 'ACTIVE', 'resumeMarketplace', p_request);
    perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'MARKETPLACE_RESUMED', p_request, 'resumed');
    v_new_market := 'ACTIVE';
  end if;
  perform haulvia_command.append_audit(p_shipment, 'resumeMarketplace', p_request, jsonb_build_object('state', 'PAUSED'), jsonb_build_object('state', v_new_market));
  return jsonb_build_object('routeVersionId', v_route_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- A08-A14: offers, counters, expiry, material edit, and reconfirmation
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.create_initial_offer(
  p_shipment haulvia.shipments,
  p_request jsonb,
  p_command_name text,
  p_expected_provider_kind haulvia.provider_kind,
  p_expected_source haulvia.pricing_source,
  p_expected_mode haulvia.partner_pricing_mode
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_provider uuid := haulvia_command.required_uuid(p_request, 'providerId');
  v_driver uuid := haulvia_command.required_uuid(p_request, 'driverId');
  v_vehicle uuid := haulvia_command.required_uuid(p_request, 'vehicleId');
  v_route_id uuid;
  v_snapshot_id uuid;
  v_thread_id uuid;
  v_revision_id uuid;
  v_expires timestamptz;
  v_amount numeric(14,2);
  v_currency char(3);
begin
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'An offer requires POSTED or NEGOTIATING');
  end if;
  if p_shipment.service_level <> 'FLEX' then
    perform haulvia_command.fail('INVALID_STATE', 'Negotiable offers require Flex service');
  end if;
  if (p_request ->> 'coversWholeRoute')::boolean is distinct from true then
    perform haulvia_command.fail('ROUTE_INVALID', 'Offer must cover the complete current route');
  end if;
  if (p_request ->> 'pricingSource')::haulvia.pricing_source <> p_expected_source
     or coalesce(nullif(p_request ->> 'pricingMode', ''), 'NOT_APPLICABLE')::haulvia.partner_pricing_mode <> p_expected_mode then
    perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Offer uses the wrong approved pricing branch');
  end if;
  perform haulvia_command.assert_provider_eligible(
    v_actor, haulvia_command.required_uuid(p_request, 'actorOrganizationId'),
    v_provider, v_driver, v_vehicle, p_expected_provider_kind
  );
  if not exists (
    select 1 from haulvia.shipment_marketplace_axes ma
    where ma.shipment_id = p_shipment.id and ma.state = 'ACTIVE' for update
  ) then
    perform haulvia_command.fail('MARKETPLACE_PAUSED', 'Marketplace is not accepting new offers');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  v_expires := haulvia_command.required_timestamptz(p_request, 'validUntil');
  if v_expires <= clock_timestamp()
     or (p_shipment.marketplace_deadline is not null and v_expires > p_shipment.marketplace_deadline) then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Offer validity is outside the active listing window');
  end if;

  v_snapshot_id := haulvia_command.create_price_snapshot(
    p_shipment, v_route_id, 'OFFER', p_request, v_actor
  );
  v_amount := haulvia_command.required_numeric(p_request, 'amount');
  v_currency := upper(coalesce(nullif(p_request ->> 'currency', ''), p_shipment.currency))::char(3);
  insert into haulvia.offer_threads (
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    pricing_source, pricing_mode, status, expires_at
  ) values (
    p_shipment.id, v_route_id, v_provider, v_driver, v_vehicle,
    p_expected_source, p_expected_mode, 'ACTIVE', v_expires
  ) returning id into v_thread_id;
  insert into haulvia.offer_revisions (
    offer_thread_id, revision_no, revision_kind, proposed_by, amount, currency,
    valid_until, pricing_snapshot_id, route_version_id, reason,
    created_by_profile_id, idempotency_key
  ) values (
    v_thread_id, 1, 'INITIAL', 'PROVIDER', v_amount, v_currency,
    v_expires, v_snapshot_id, v_route_id, nullif(p_request ->> 'structuredReason', ''),
    v_actor, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_revision_id;

  if p_shipment.shipment_state = 'POSTED' then
    update haulvia.shipments set shipment_state = 'NEGOTIATING' where id = p_shipment.id;
    perform haulvia_command.append_shipment_event(
      p_shipment.id, 'POSTED', 'NEGOTIATING', p_command_name, p_request, v_route_id,
      jsonb_build_object('offerThreadId', v_thread_id)
    );
  else
    update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  end if;

  perform haulvia_command.append_audit(
    p_shipment, p_command_name, p_request, null,
    jsonb_build_object('offerThreadId', v_thread_id, 'offerRevisionId', v_revision_id),
    jsonb_build_object('priceSnapshotId', v_snapshot_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'OFFER_RECEIVED', p_request,
    'offer-received', jsonb_build_object('offerThreadId', v_thread_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, v_actor, 'OFFER_SUBMITTED', p_request,
    'offer-submitted', jsonb_build_object('offerThreadId', v_thread_id)
  );
  perform haulvia_command.queue_job(
    p_shipment.id, 'EXPIRE_OFFER_THREAD', v_expires, p_request,
    'offer-expiry', jsonb_build_object('offerThreadId', v_thread_id)
  );
  return jsonb_build_object(
    'routeVersionId', v_route_id,
    'priceSnapshotId', v_snapshot_id,
    'offerThreadId', v_thread_id,
    'offerRevisionId', v_revision_id
  );
end;
$$;

create or replace function haulvia_command.apply_a08_submit_independent_flex_offer(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language sql
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.create_initial_offer(
    p_shipment, p_request, 'submitIndependentFlexOffer',
    'INDEPENDENT_DRIVER', 'HAULVIA_GUARDRAIL', 'NOT_APPLICABLE'
  );
$$;

create or replace function haulvia_command.apply_a09_submit_partner_flex_offer(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language sql
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.create_initial_offer(
    p_shipment, p_request, 'submitPartnerFlexOffer',
    'COURIER_PARTNER', 'PARTNER_RATE_CARD', 'FLEX_NEGOTIABLE'
  );
$$;

create or replace function haulvia_command.apply_a10_accept_firm_route_match(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_provider uuid := haulvia_command.required_uuid(p_request, 'providerId');
  v_driver uuid := haulvia_command.required_uuid(p_request, 'driverId');
  v_vehicle uuid := haulvia_command.required_uuid(p_request, 'vehicleId');
  v_route_id uuid;
  v_offer_snapshot uuid;
  v_reservation_snapshot uuid;
  v_thread uuid;
  v_revision uuid;
  v_reservation uuid;
  v_intent uuid;
  v_expires timestamptz;
  v_source haulvia.pricing_source;
  v_mode haulvia.partner_pricing_mode;
  v_prior_market haulvia.marketplace_state;
begin
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'Firm route match requires POSTED or NEGOTIATING');
  end if;
  if (p_request ->> 'coversWholeRoute')::boolean is distinct from true then
    perform haulvia_command.fail('ROUTE_INVALID', 'Firm match must cover the complete current route');
  end if;
  v_source := haulvia_command.required_text(p_request, 'pricingSource')::haulvia.pricing_source;
  v_mode := coalesce(nullif(p_request ->> 'pricingMode', ''), 'NOT_APPLICABLE')::haulvia.partner_pricing_mode;
  if not (v_source = 'HAULVIA_FIXED' or (v_source = 'PARTNER_RATE_CARD' and v_mode in ('FLEX_FIRM', 'EXPEDITED_FIRM'))) then
    perform haulvia_command.fail('PRICING_REVIEW_REQUIRED', 'Firm match requires a fixed or firm pricing branch');
  end if;
  perform haulvia_command.assert_provider_eligible(
    v_actor, haulvia_command.required_uuid(p_request, 'actorOrganizationId'),
    v_provider, v_driver, v_vehicle, null
  );
  select state into v_prior_market from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;
  if v_prior_market <> 'ACTIVE' then
    perform haulvia_command.fail('MARKETPLACE_PAUSED', 'Marketplace is not accepting a firm match');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform haulvia_command.assert_payment_method(
    p_shipment, haulvia_command.required_uuid(p_request, 'paymentMethodId')
  );
  v_expires := haulvia_command.required_timestamptz(p_request, 'reservationExpiresAt');
  if v_expires <= clock_timestamp() then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Reservation window has already elapsed');
  end if;

  v_offer_snapshot := haulvia_command.create_price_snapshot(
    p_shipment, v_route_id, 'OFFER', p_request, v_actor
  );
  insert into haulvia.offer_threads (
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    pricing_source, pricing_mode, status, expires_at
  ) values (
    p_shipment.id, v_route_id, v_provider, v_driver, v_vehicle,
    v_source, v_mode, 'ACTIVE', v_expires
  ) returning id into v_thread;
  insert into haulvia.offer_revisions (
    offer_thread_id, revision_no, revision_kind, proposed_by, amount, currency,
    valid_until, pricing_snapshot_id, route_version_id, created_by_profile_id,
    idempotency_key
  ) values (
    v_thread, 1, 'FIRM_MATCH', 'PROVIDER',
    haulvia_command.required_numeric(p_request, 'amount'), p_shipment.currency,
    v_expires, v_offer_snapshot, v_route_id, v_actor,
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_revision;
  v_reservation_snapshot := haulvia_command.clone_price_snapshot(
    v_offer_snapshot, 'RESERVATION', haulvia_command.required_text(p_request, 'reservationSnapshotSha256')
  );
  insert into haulvia.offer_reservations (
    shipment_id, offer_thread_id, selected_revision_id, status,
    reserved_by_profile_id, expires_at, marketplace_state_before_reservation
  ) values (
    p_shipment.id, v_thread, v_revision, 'ACTIVE', v_actor, v_expires, v_prior_market
  ) returning id into v_reservation;
  update haulvia.offer_threads set status = 'RESERVED' where id = v_thread;
  insert into haulvia.payment_intents (
    shipment_id, offer_reservation_id, status, amount, currency,
    external_provider, provider_idempotency_key, funding_deadline
  ) values (
    p_shipment.id, v_reservation, 'AUTHORIZING',
    haulvia_command.required_numeric(p_request, 'amount'), p_shipment.currency,
    haulvia_command.required_text(p_request, 'paymentProvider'),
    haulvia_command.required_text(p_request, 'paymentProviderIdempotencyKey'), v_expires
  ) returning id into v_intent;
  update haulvia.shipment_marketplace_axes
  set state = 'RESERVED', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_customer_payment_axes set state = 'AUTHORIZING', state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'NEGOTIATING' where id = p_shipment.id;

  if p_shipment.shipment_state = 'POSTED' then
    perform haulvia_command.append_shipment_event(p_shipment.id, 'POSTED', 'NEGOTIATING', 'acceptFirmRouteMatch', p_request, v_route_id);
  end if;
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', v_prior_market::text, 'RESERVED', 'acceptFirmRouteMatch', p_request, v_reservation);
  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', 'METHOD_VERIFIED', 'AUTHORIZING', 'acceptFirmRouteMatch', p_request, v_intent);
  perform haulvia_command.append_audit(p_shipment, 'acceptFirmRouteMatch', p_request, null, jsonb_build_object('reservationId', v_reservation, 'paymentIntentId', v_intent));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'FIRM_MATCH_RESERVED', p_request, 'firm-reserved');
  perform haulvia_command.queue_job(p_shipment.id, 'PAYMENT_RESERVATION_TIMEOUT', v_expires, p_request, 'firm-timeout', jsonb_build_object('paymentIntentId', v_intent));
  return jsonb_build_object(
    'routeVersionId', v_route_id, 'offerThreadId', v_thread,
    'offerRevisionId', v_revision, 'reservationId', v_reservation,
    'priceSnapshotId', v_reservation_snapshot, 'paymentIntentId', v_intent
  );
end;
$$;

create or replace function haulvia_command.apply_a11_counter_or_revise_offer(
  p_shipment haulvia.shipments,
  p_request jsonb,
  p_action text
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_thread_id uuid := haulvia_command.required_uuid(p_request, 'offerThreadId');
  v_response_id uuid := haulvia_command.required_uuid(p_request, 'responseToRevisionId');
  v_thread haulvia.offer_threads%rowtype;
  v_route_id uuid;
  v_latest_revision uuid;
  v_revision_no integer;
  v_snapshot_id uuid;
  v_revision_id uuid;
  v_kind haulvia.offer_revision_kind;
  v_proposer haulvia.proposal_actor_kind;
  v_price_request jsonb;
begin
  if p_shipment.shipment_state <> 'NEGOTIATING' then
    perform haulvia_command.fail('INVALID_STATE', 'Counter or revision requires NEGOTIATING');
  end if;
  select * into v_thread from haulvia.offer_threads ot
  where ot.id = v_thread_id and ot.shipment_id = p_shipment.id for update;
  if not found or v_thread.status <> 'ACTIVE' or v_thread.expires_at <= clock_timestamp() then
    perform haulvia_command.fail('OFFER_NOT_ACTIONABLE', 'Offer thread is not active');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  if v_thread.route_version_id <> v_route_id then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Offer does not cover the current route');
  end if;
  select id, revision_no into v_latest_revision, v_revision_no
  from haulvia.offer_revisions
  where offer_thread_id = v_thread_id
  order by revision_no desc limit 1 for update;
  if v_latest_revision <> v_response_id then
    perform haulvia_command.fail('OFFER_NOT_ACTIONABLE', 'Response does not target the latest offer revision');
  end if;

  if p_action = 'counterOffer' then
    perform haulvia_command.authorize_customer(
      p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
    );
    v_kind := 'CUSTOMER_COUNTER';
    v_proposer := 'CUSTOMER';
    if (select count(*) from haulvia.offer_revisions r
        where r.offer_thread_id = v_thread_id and r.revision_kind = 'CUSTOMER_COUNTER') >= 2 then
      perform haulvia_command.fail('COUNTER_LIMIT_REACHED', 'A negotiation permits at most two customer counters');
    end if;
  elsif p_action = 'reviseOffer' then
    perform haulvia_command.assert_provider_eligible(
      v_actor, haulvia_command.required_uuid(p_request, 'actorOrganizationId'),
      v_thread.provider_id, v_thread.driver_id, v_thread.vehicle_id, null
    );
    v_kind := 'PROVIDER_REVISION';
    v_proposer := 'PROVIDER';
    if (select count(*) from haulvia.offer_revisions r
        where r.offer_thread_id = v_thread_id and r.revision_kind = 'PROVIDER_REVISION') >= 2 then
      perform haulvia_command.fail('COUNTER_LIMIT_REACHED', 'A negotiation permits at most two provider revisions');
    end if;
  else
    perform haulvia_command.fail('INVALID_REQUEST', 'Unknown A11 action');
  end if;

  v_price_request := p_request || jsonb_build_object(
    'pricingSource', v_thread.pricing_source,
    'pricingMode', v_thread.pricing_mode,
    'providerId', v_thread.provider_id,
    'driverId', v_thread.driver_id,
    'vehicleId', v_thread.vehicle_id
  );
  v_snapshot_id := haulvia_command.create_price_snapshot(
    p_shipment, v_route_id, 'OFFER', v_price_request, v_actor
  );
  insert into haulvia.offer_revisions (
    offer_thread_id, revision_no, revision_kind, proposed_by, amount, currency,
    valid_until, response_to_revision_id, pricing_snapshot_id, route_version_id,
    reason, created_by_profile_id, idempotency_key
  ) values (
    v_thread_id, v_revision_no + 1, v_kind, v_proposer,
    haulvia_command.required_numeric(p_request, 'amount'), p_shipment.currency,
    haulvia_command.required_timestamptz(p_request, 'validUntil'), v_response_id,
    v_snapshot_id, v_route_id, nullif(p_request ->> 'structuredReason', ''),
    v_actor, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_revision_id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  perform haulvia_command.append_audit(
    p_shipment, p_action, p_request, jsonb_build_object('responseToRevisionId', v_response_id),
    jsonb_build_object('offerRevisionId', v_revision_id),
    jsonb_build_object('offerThreadId', v_thread_id, 'priceSnapshotId', v_snapshot_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id,
    case when p_action = 'counterOffer' then
      (select d.profile_id from haulvia.drivers d where d.id = v_thread.driver_id)
    else p_shipment.customer_profile_id end,
    case when p_action = 'counterOffer' then 'OFFER_COUNTERED' else 'OFFER_REVISED' end,
    p_request, 'revision-notice', jsonb_build_object('offerThreadId', v_thread_id)
  );
  return jsonb_build_object(
    'routeVersionId', v_route_id, 'offerThreadId', v_thread_id,
    'offerRevisionId', v_revision_id, 'priceSnapshotId', v_snapshot_id
  );
end;
$$;

create or replace function haulvia_command.apply_a12_close_last_active_offer(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_thread_id uuid := haulvia_command.required_uuid(p_request, 'offerThreadId');
  v_route_id uuid;
  v_market haulvia.marketplace_state;
  v_has_actionable boolean;
  v_new_state haulvia.shipment_state := p_shipment.shipment_state;
begin
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    p_request ->> 'workerAuthority', array['EXPIRY_WORKER', 'OFFER_WORKER']
  );
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'Offer closure requires POSTED or NEGOTIATING');
  end if;
  perform 1 from haulvia.offer_threads ot
  where ot.shipment_id = p_shipment.id
  order by ot.id for update;
  if not exists (
    select 1 from haulvia.offer_threads ot
    where ot.id = v_thread_id and ot.shipment_id = p_shipment.id
  ) then
    perform haulvia_command.fail('NOT_FOUND', 'Offer thread was not found');
  end if;
  update haulvia.offer_threads
  set status = case when expires_at <= clock_timestamp() then 'EXPIRED'::haulvia.offer_status else 'CLOSED'::haulvia.offer_status end,
      closed_at = clock_timestamp()
  where id = v_thread_id and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED');
  select exists (
    select 1 from haulvia.offer_threads ot
    where ot.shipment_id = p_shipment.id
      and ot.status in ('ACTIVE', 'RECONFIRMATION_REQUIRED')
      and ot.expires_at > clock_timestamp()
  ) into v_has_actionable;
  select state into v_market from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;
  select id into v_route_id from haulvia.route_versions
  where shipment_id = p_shipment.id and status = 'ACTIVE';

  if not v_has_actionable then
    if p_shipment.marketplace_deadline <= clock_timestamp() then
      v_new_state := 'EXPIRED';
      update haulvia.shipment_marketplace_axes set state = 'EXPIRED', paused_reason = null, state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
    elsif p_shipment.shipment_state = 'NEGOTIATING' then
      v_new_state := 'POSTED';
    end if;
  end if;

  if v_new_state <> p_shipment.shipment_state then
    update haulvia.shipments set shipment_state = v_new_state where id = p_shipment.id;
    perform haulvia_command.append_shipment_event(p_shipment.id, p_shipment.shipment_state, v_new_state, 'closeLastActiveOffer', p_request, v_route_id);
  else
    update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  end if;
  perform haulvia_command.append_audit(p_shipment, 'closeLastActiveOffer', p_request, null, jsonb_build_object('closedThreadId', v_thread_id, 'actionableRemain', v_has_actionable));
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id,
    case when v_new_state = 'EXPIRED' then 'SHIPMENT_EXPIRED' else 'NO_ACTIVE_OFFERS' end,
    p_request, 'offer-closed'
  );
  return jsonb_build_object('closedOfferThreadId', v_thread_id, 'actionableOffersRemain', v_has_actionable);
end;
$$;

create or replace function haulvia_command.apply_a13_materially_edit_negotiation(
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
  v_policy_version uuid;
  v_policy haulvia.policy_versions%rowtype;
  v_snapshot uuid;
  v_count integer;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state <> 'NEGOTIATING' then
    perform haulvia_command.fail('INVALID_STATE', 'materiallyEditNegotiation requires NEGOTIATING');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  v_old_route := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  perform 1 from haulvia.offer_threads ot
  where ot.shipment_id = p_shipment.id order by ot.id for update;
  v_new_route := haulvia_command.create_route_from_plan(
    p_shipment.id, v_old_route, v_actor,
    haulvia_command.required_text(p_request, 'reason'), p_request -> 'routePlan'
  );
  v_policy_version := haulvia_command.required_uuid(p_request, 'policyVersionId');
  select * into v_policy from haulvia.policy_versions pv
  where pv.id = v_policy_version and pv.publication_status = 'APPROVED'
    and pv.effective_from <= clock_timestamp()
    and (pv.effective_to is null or pv.effective_to > clock_timestamp());
  if not found then
    perform haulvia_command.fail('INVALID_STATE', 'A current approved policy version is required');
  end if;

  update haulvia.offer_threads
  set status = 'RECONFIRMATION_REQUIRED', reconfirmation_route_version_id = v_new_route
  where shipment_id = p_shipment.id and status = 'ACTIVE';
  get diagnostics v_count = row_count;
  update haulvia.shipment_marketplace_axes
  set state = 'PAUSED', paused_reason = 'MATERIAL_ROUTE_EDIT', state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.route_versions set status = 'SUPERSEDED' where id = v_old_route;
  update haulvia.route_versions set status = 'ACTIVE' where id = v_new_route;
  insert into haulvia.shipment_rule_snapshots (
    shipment_id, route_version_id, policy_version_id, evidence_requirements,
    cancellation_rules, refund_rules, timing_windows, risk_rules, config_sha256
  ) values (
    p_shipment.id, v_new_route, v_policy_version,
    coalesce(v_policy.config -> 'evidenceRequirements', '{}'::jsonb),
    coalesce(v_policy.config -> 'cancellationRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'refundRules', '{}'::jsonb),
    coalesce(v_policy.config -> 'timingWindows', '{}'::jsonb),
    coalesce(v_policy.config -> 'riskRules', '{}'::jsonb), v_policy.config_sha256
  );
  v_snapshot := haulvia_command.create_price_snapshot(p_shipment, v_new_route, 'POSTING', p_request, v_actor);
  update haulvia.shipments set shipment_state = 'POSTED' where id = p_shipment.id;
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', 'ACTIVE', 'PAUSED', 'materiallyEditNegotiation', p_request);
  perform haulvia_command.append_shipment_event(p_shipment.id, 'NEGOTIATING', 'POSTED', 'materiallyEditNegotiation', p_request, v_new_route);
  perform haulvia_command.append_audit(p_shipment, 'materiallyEditNegotiation', p_request, jsonb_build_object('routeVersionId', v_old_route), jsonb_build_object('routeVersionId', v_new_route), jsonb_build_object('reconfirmationCount', v_count));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_EDITED', p_request, 'material-edit');
  return jsonb_build_object('routeVersionId', v_new_route, 'priorRouteVersionId', v_old_route, 'priceSnapshotId', v_snapshot, 'reconfirmationCount', v_count);
end;
$$;

create or replace function haulvia_command.apply_a14_reconfirm_offer_or_firm_match(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.required_uuid(p_request, 'actorProfileId');
  v_thread_id uuid := haulvia_command.required_uuid(p_request, 'offerThreadId');
  v_thread haulvia.offer_threads%rowtype;
  v_route_id uuid;
  v_snapshot uuid;
  v_revision uuid;
  v_revision_no integer;
  v_price_request jsonb;
begin
  if p_shipment.shipment_state <> 'POSTED' then
    perform haulvia_command.fail('INVALID_STATE', 'Reconfirmation requires shipment state POSTED');
  end if;
  select * into v_thread from haulvia.offer_threads
  where id = v_thread_id and shipment_id = p_shipment.id for update;
  if not found or v_thread.status <> 'RECONFIRMATION_REQUIRED'
     or v_thread.expires_at <= clock_timestamp() then
    perform haulvia_command.fail('OFFER_NOT_ACTIONABLE', 'Offer is not awaiting a current reconfirmation');
  end if;
  perform haulvia_command.assert_provider_eligible(
    v_actor, haulvia_command.required_uuid(p_request, 'actorOrganizationId'),
    v_thread.provider_id, v_thread.driver_id, v_thread.vehicle_id, null
  );
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  if v_thread.reconfirmation_route_version_id <> v_route_id then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Thread does not request reconfirmation for this route');
  end if;
  select coalesce(max(revision_no), 0) + 1 into v_revision_no
  from haulvia.offer_revisions where offer_thread_id = v_thread_id;
  v_price_request := p_request || jsonb_build_object(
    'pricingSource', v_thread.pricing_source, 'pricingMode', v_thread.pricing_mode,
    'providerId', v_thread.provider_id, 'driverId', v_thread.driver_id,
    'vehicleId', v_thread.vehicle_id
  );
  v_snapshot := haulvia_command.create_price_snapshot(p_shipment, v_route_id, 'OFFER', v_price_request, v_actor);
  insert into haulvia.offer_revisions (
    offer_thread_id, revision_no, revision_kind, proposed_by, amount, currency,
    valid_until, pricing_snapshot_id, route_version_id, reason,
    created_by_profile_id, idempotency_key
  ) values (
    v_thread_id, v_revision_no, 'RECONFIRMATION', 'PROVIDER',
    haulvia_command.required_numeric(p_request, 'amount'), p_shipment.currency,
    haulvia_command.required_timestamptz(p_request, 'validUntil'), v_snapshot,
    v_route_id, nullif(p_request ->> 'structuredReason', ''), v_actor,
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_revision;
  update haulvia.offer_threads
  set route_version_id = v_route_id, reconfirmation_route_version_id = null, status = 'ACTIVE'
  where id = v_thread_id;
  update haulvia.shipments set shipment_state = 'NEGOTIATING' where id = p_shipment.id;
  perform haulvia_command.append_shipment_event(p_shipment.id, 'POSTED', 'NEGOTIATING', 'reconfirmOfferOrFirmMatch', p_request, v_route_id);
  perform haulvia_command.append_audit(p_shipment, 'reconfirmOfferOrFirmMatch', p_request, jsonb_build_object('routeVersionId', v_thread.route_version_id), jsonb_build_object('routeVersionId', v_route_id), jsonb_build_object('offerThreadId', v_thread_id, 'offerRevisionId', v_revision));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'OFFER_RECONFIRMED', p_request, 'reconfirmed');
  return jsonb_build_object('routeVersionId', v_route_id, 'offerThreadId', v_thread_id, 'offerRevisionId', v_revision, 'priceSnapshotId', v_snapshot);
end;
$$;

-- ---------------------------------------------------------------------------
-- A15-A19: reservation, funding, assignment, release, cancellation, expiry
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_a15_reserve_selection(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_thread_id uuid := haulvia_command.required_uuid(p_request, 'offerThreadId');
  v_revision_id uuid := haulvia_command.required_uuid(p_request, 'selectedRevisionId');
  v_thread haulvia.offer_threads%rowtype;
  v_revision haulvia.offer_revisions%rowtype;
  v_route_id uuid;
  v_prior_market haulvia.marketplace_state;
  v_reservation_snapshot uuid;
  v_reservation uuid;
  v_intent uuid;
  v_expires timestamptz;
begin
  if v_actor is null then
    perform haulvia_command.assert_worker(v_actor, p_request ->> 'workerAuthority', array['MATCHING_WORKER']);
  else
    perform haulvia_command.authorize_customer(
      p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
    );
  end if;
  if p_shipment.shipment_state <> 'NEGOTIATING' then
    perform haulvia_command.fail('INVALID_STATE', 'reserveSelection requires NEGOTIATING');
  end if;
  perform haulvia_command.assert_no_reservation_or_assignment(p_shipment.id);
  select state into v_prior_market from haulvia.shipment_marketplace_axes
  where shipment_id = p_shipment.id for update;
  if v_prior_market not in ('ACTIVE', 'PAUSED') then
    perform haulvia_command.fail('INVALID_STATE', 'Marketplace cannot reserve from its current state');
  end if;
  select * into v_thread from haulvia.offer_threads
  where id = v_thread_id and shipment_id = p_shipment.id for update;
  if not found or v_thread.status <> 'ACTIVE' or v_thread.expires_at <= clock_timestamp() then
    perform haulvia_command.fail('OFFER_NOT_ACTIONABLE', 'Selected offer is not active');
  end if;
  select * into v_revision from haulvia.offer_revisions
  where id = v_revision_id and offer_thread_id = v_thread_id for update;
  if not found or v_revision.valid_until <= clock_timestamp()
     or v_revision.route_version_id <> v_thread.route_version_id
     or exists (
       select 1 from haulvia.offer_revisions newer
       where newer.offer_thread_id = v_thread_id and newer.revision_no > v_revision.revision_no
     ) then
    perform haulvia_command.fail('OFFER_NOT_ACTIONABLE', 'Selected revision is stale, expired, or superseded');
  end if;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  if v_route_id <> v_revision.route_version_id then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Selected revision does not cover the current route');
  end if;
  perform haulvia_command.assert_payment_method(
    p_shipment, haulvia_command.required_uuid(p_request, 'paymentMethodId')
  );
  v_expires := haulvia_command.required_timestamptz(p_request, 'reservationExpiresAt');
  if v_expires <= clock_timestamp() or v_expires > v_revision.valid_until then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Reservation window is invalid for the selected revision');
  end if;

  v_reservation_snapshot := haulvia_command.clone_price_snapshot(
    v_revision.pricing_snapshot_id, 'RESERVATION',
    haulvia_command.required_text(p_request, 'reservationSnapshotSha256')
  );
  insert into haulvia.offer_reservations (
    shipment_id, offer_thread_id, selected_revision_id, status,
    reserved_by_profile_id, expires_at, marketplace_state_before_reservation
  ) values (
    p_shipment.id, v_thread_id, v_revision_id, 'ACTIVE', v_actor,
    v_expires, v_prior_market
  ) returning id into v_reservation;
  update haulvia.offer_threads set status = 'RESERVED' where id = v_thread_id;
  insert into haulvia.payment_intents (
    shipment_id, offer_reservation_id, status, amount, currency,
    external_provider, provider_idempotency_key, funding_deadline
  ) values (
    p_shipment.id, v_reservation, 'AUTHORIZING', v_revision.amount,
    v_revision.currency, haulvia_command.required_text(p_request, 'paymentProvider'),
    haulvia_command.required_text(p_request, 'paymentProviderIdempotencyKey'), v_expires
  ) returning id into v_intent;
  update haulvia.shipment_marketplace_axes
  set state = 'RESERVED', paused_reason = null, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipment_customer_payment_axes set state = 'AUTHORIZING', state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', v_prior_market::text, 'RESERVED', 'reserveSelection', p_request, v_reservation);
  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', 'METHOD_VERIFIED', 'AUTHORIZING', 'reserveSelection', p_request, v_intent);
  perform haulvia_command.append_audit(p_shipment, 'reserveSelection', p_request, null, jsonb_build_object('reservationId', v_reservation, 'paymentIntentId', v_intent));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'SELECTION_RESERVED', p_request, 'selection-reserved');
  perform haulvia_command.queue_job(p_shipment.id, 'PAYMENT_RESERVATION_TIMEOUT', v_expires, p_request, 'selection-timeout', jsonb_build_object('paymentIntentId', v_intent));
  return jsonb_build_object(
    'routeVersionId', v_route_id, 'offerThreadId', v_thread_id,
    'offerRevisionId', v_revision_id, 'reservationId', v_reservation,
    'priceSnapshotId', v_reservation_snapshot, 'paymentIntentId', v_intent
  );
end;
$$;

create or replace function haulvia_command.apply_a16_confirm_paid_assignment(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_intent_id uuid := haulvia_command.required_uuid(p_request, 'paymentIntentId');
  v_reservation_id uuid := haulvia_command.required_uuid(p_request, 'reservationId');
  v_intent haulvia.payment_intents%rowtype;
  v_reservation haulvia.offer_reservations%rowtype;
  v_thread haulvia.offer_threads%rowtype;
  v_revision haulvia.offer_revisions%rowtype;
  v_route_id uuid;
  v_assignment_snapshot uuid;
  v_payment_tx uuid;
  v_assignment uuid;
  v_provider_event text := haulvia_command.required_text(p_request, 'providerEventId');
  v_amount numeric(14,2) := haulvia_command.required_numeric(p_request, 'securedAmount');
  v_currency char(3) := upper(haulvia_command.required_text(p_request, 'currency'))::char(3);
begin
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    p_request ->> 'workerAuthority', array['PAYMENT_WORKER']
  );
  if p_shipment.shipment_state <> 'NEGOTIATING' then
    perform haulvia_command.fail('INVALID_STATE', 'Paid assignment requires NEGOTIATING');
  end if;
  select * into v_intent from haulvia.payment_intents pi
  where pi.id = v_intent_id and pi.shipment_id = p_shipment.id for update;
  if not found or v_intent.status <> 'AUTHORIZING' then
    perform haulvia_command.fail('FUNDING_NOT_SECURED', 'Payment intent is no longer authorizing');
  end if;
  select * into v_reservation from haulvia.offer_reservations r
  where r.id = v_reservation_id and r.shipment_id = p_shipment.id for update;
  if not found or v_reservation.status <> 'ACTIVE'
     or v_reservation.expires_at <= clock_timestamp()
     or v_intent.offer_reservation_id <> v_reservation.id
     or (v_intent.funding_deadline is not null and v_intent.funding_deadline <= clock_timestamp()) then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Reservation or funding window is no longer active');
  end if;
  if v_amount <> v_intent.amount or v_currency <> v_intent.currency then
    perform haulvia_command.fail('FUNDING_NOT_SECURED', 'Funding must exactly match the accepted route amount and currency');
  end if;
  if exists (
    select 1 from haulvia.assignments a where a.shipment_id = p_shipment.id and a.status = 'ACTIVE'
  ) then
    perform haulvia_command.fail('ASSIGNMENT_CONFLICT', 'Shipment already has an active assignment');
  end if;
  select * into v_thread from haulvia.offer_threads
  where id = v_reservation.offer_thread_id for update;
  select * into v_revision from haulvia.offer_revisions
  where id = v_reservation.selected_revision_id for update;
  v_route_id := haulvia_command.assert_expected_route(
    p_shipment.id, p_request, array['ACTIVE']::haulvia.route_version_status[]
  );
  if v_revision.route_version_id <> v_route_id or v_thread.route_version_id <> v_route_id then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Reservation pricing does not cover the current route');
  end if;
  perform haulvia_command.assert_provider_eligible(
    (select d.profile_id from haulvia.drivers d where d.id = v_thread.driver_id),
    (select sp.organization_id from haulvia.service_providers sp where sp.id = v_thread.provider_id),
    v_thread.provider_id, v_thread.driver_id, v_thread.vehicle_id, null
  );

  insert into haulvia.payment_transactions (
    payment_intent_id, shipment_id, transaction_type, status, amount, currency,
    external_provider, external_reference, provider_event_id,
    provider_occurred_at, response_payload, idempotency_key
  ) values (
    v_intent.id, p_shipment.id,
    coalesce(nullif(p_request ->> 'transactionType', ''), 'CAPTURE')::haulvia.payment_transaction_type,
    'SUCCEEDED', v_amount, v_currency, v_intent.external_provider,
    nullif(p_request ->> 'externalReference', ''), v_provider_event,
    coalesce(nullif(p_request ->> 'providerOccurredAt', '')::timestamptz, clock_timestamp()),
    coalesce(p_request -> 'providerPayload', '{}'::jsonb),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_payment_tx;
  update haulvia.payment_intents
  set status = 'SECURED', external_reference = coalesce(nullif(p_request ->> 'externalReference', ''), external_reference), secured_at = clock_timestamp()
  where id = v_intent.id;
  update haulvia.shipment_customer_payment_axes
  set state = 'SECURED', secured_amount = v_amount, currency = v_currency, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  v_assignment_snapshot := haulvia_command.clone_price_snapshot(
    v_revision.pricing_snapshot_id, 'ASSIGNMENT',
    haulvia_command.required_text(p_request, 'assignmentSnapshotSha256')
  );
  insert into haulvia.assignments (
    shipment_id, route_version_id, provider_id, driver_id, vehicle_id,
    offer_reservation_id, selected_offer_revision_id, price_snapshot_id,
    status, agreement_snapshot
  ) values (
    p_shipment.id, v_route_id, v_thread.provider_id, v_thread.driver_id,
    v_thread.vehicle_id, v_reservation.id, v_revision.id, v_assignment_snapshot,
    'ACTIVE', coalesce(p_request -> 'agreementSnapshot', '{}'::jsonb)
  ) returning id into v_assignment;
  insert into haulvia.assignment_events (
    assignment_id, shipment_id, prior_status, current_status, command_name,
    actor_kind, reason, idempotency_key, metadata
  ) values (
    v_assignment, p_shipment.id, null, 'ACTIVE', 'confirmPaidAssignment',
    'SYSTEM', nullif(p_request ->> 'reason', ''),
    haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object('paymentTransactionId', v_payment_tx)
  );
  update haulvia.offer_reservations set status = 'CONVERTED' where id = v_reservation.id;
  update haulvia.offer_threads set status = 'ACCEPTED', closed_at = clock_timestamp() where id = v_thread.id;
  update haulvia.offer_threads set status = 'CLOSED', closed_at = clock_timestamp()
  where shipment_id = p_shipment.id and id <> v_thread.id and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED', 'RESERVED');
  update haulvia.shipment_marketplace_axes set state = 'CLOSED', paused_reason = null, state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'DRIVER_ASSIGNED' where id = p_shipment.id;

  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', 'AUTHORIZING', 'SECURED', 'confirmPaidAssignment', p_request, v_intent.id);
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', 'RESERVED', 'CLOSED', 'confirmPaidAssignment', p_request, v_assignment);
  perform haulvia_command.append_shipment_event(p_shipment.id, 'NEGOTIATING', 'DRIVER_ASSIGNED', 'confirmPaidAssignment', p_request, v_route_id, jsonb_build_object('assignmentId', v_assignment));
  perform haulvia_command.append_audit(p_shipment, 'confirmPaidAssignment', p_request, null, jsonb_build_object('assignmentId', v_assignment), jsonb_build_object('paymentTransactionId', v_payment_tx));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'ASSIGNMENT_CONFIRMED', p_request, 'assignment-customer');
  perform haulvia_command.queue_notification(p_shipment.id, (select d.profile_id from haulvia.drivers d where d.id = v_thread.driver_id), 'ASSIGNMENT_CONFIRMED', p_request, 'assignment-driver');
  perform haulvia_command.queue_job(p_shipment.id, 'TRIP_START_REMINDER', clock_timestamp(), p_request, 'trip-start', jsonb_build_object('assignmentId', v_assignment));
  return jsonb_build_object(
    'routeVersionId', v_route_id, 'assignmentId', v_assignment,
    'priceSnapshotId', v_assignment_snapshot, 'paymentTransactionId', v_payment_tx,
    'reservationId', v_reservation.id, 'paymentIntentId', v_intent.id
  );
end;
$$;

create or replace function haulvia_command.apply_a17_release_failed_reservation(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_intent_id uuid := haulvia_command.required_uuid(p_request, 'paymentIntentId');
  v_reservation_id uuid := haulvia_command.required_uuid(p_request, 'reservationId');
  v_intent haulvia.payment_intents%rowtype;
  v_reservation haulvia.offer_reservations%rowtype;
  v_thread haulvia.offer_threads%rowtype;
  v_route_id uuid;
  v_payment_state haulvia.customer_payment_state;
  v_market haulvia.marketplace_state;
  v_new_shipment haulvia.shipment_state;
  v_tx uuid;
  v_late_success boolean := coalesce((p_request ->> 'lateSuccess')::boolean, false);
begin
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    p_request ->> 'workerAuthority', array['PAYMENT_WORKER']
  );
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'Reservation release requires a pre-assignment shipment');
  end if;
  if exists (select 1 from haulvia.assignments a where a.shipment_id = p_shipment.id and a.status = 'ACTIVE') then
    perform haulvia_command.fail('ASSIGNMENT_CONFLICT', 'Paid assignment already committed');
  end if;
  select * into v_intent from haulvia.payment_intents pi
  where pi.id = v_intent_id and pi.shipment_id = p_shipment.id for update;
  select * into v_reservation from haulvia.offer_reservations r
  where r.id = v_reservation_id and r.shipment_id = p_shipment.id for update;
  if v_intent.id is null or v_reservation.id is null
     or v_intent.offer_reservation_id <> v_reservation.id then
    perform haulvia_command.fail('NOT_FOUND', 'Payment intent and reservation do not match');
  end if;
  select * into v_thread from haulvia.offer_threads where id = v_reservation.offer_thread_id for update;
  select id into v_route_id from haulvia.route_versions where shipment_id = p_shipment.id and status = 'ACTIVE';

  insert into haulvia.payment_transactions (
    payment_intent_id, shipment_id, transaction_type, status, amount, currency,
    external_provider, external_reference, provider_event_id,
    provider_occurred_at, response_payload, idempotency_key
  ) values (
    v_intent.id, p_shipment.id, 'AUTHORIZE',
    case when v_late_success then 'SUCCEEDED'::haulvia.transaction_status else 'FAILED'::haulvia.transaction_status end,
    coalesce(nullif(p_request ->> 'amount', '')::numeric, v_intent.amount), v_intent.currency,
    v_intent.external_provider, nullif(p_request ->> 'externalReference', ''),
    haulvia_command.required_text(p_request, 'providerEventId'),
    coalesce(nullif(p_request ->> 'providerOccurredAt', '')::timestamptz, clock_timestamp()),
    coalesce(p_request -> 'providerPayload', '{}'::jsonb),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_tx;
  update haulvia.payment_intents
  set status = case
      when v_late_success then 'VOIDED'::haulvia.payment_intent_status
      when upper(coalesce(p_request ->> 'failureCategory', 'FAILED')) = 'TIMEOUT' then 'TIMED_OUT'::haulvia.payment_intent_status
      else 'FAILED'::haulvia.payment_intent_status end,
      timed_out_at = case when upper(coalesce(p_request ->> 'failureCategory', '')) = 'TIMEOUT' then clock_timestamp() end
  where id = v_intent.id;
  update haulvia.offer_reservations
  set status = 'RELEASED', released_at = clock_timestamp(),
      release_reason = coalesce(nullif(p_request ->> 'failureCategory', ''), 'PAYMENT_FAILED')
  where id = v_reservation.id and status = 'ACTIVE';

  if v_thread.route_version_id = v_route_id and v_thread.expires_at > clock_timestamp()
     and p_shipment.marketplace_deadline > clock_timestamp() then
    update haulvia.offer_threads set status = 'ACTIVE', closed_at = null where id = v_thread.id;
  else
    update haulvia.offer_threads set status = 'EXPIRED', closed_at = clock_timestamp() where id = v_thread.id;
  end if;
  v_market := case
    when p_shipment.marketplace_deadline <= clock_timestamp() then 'EXPIRED'::haulvia.marketplace_state
    when v_reservation.marketplace_state_before_reservation = 'PAUSED' then 'PAUSED'::haulvia.marketplace_state
    else 'ACTIVE'::haulvia.marketplace_state end;
  update haulvia.shipment_marketplace_axes
  set state = v_market,
      paused_reason = case when v_market = 'PAUSED' then 'RESTORED_AFTER_PAYMENT_FAILURE' end,
      state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  v_payment_state := case when v_late_success then 'RELEASED'::haulvia.customer_payment_state else 'FAILED'::haulvia.customer_payment_state end;
  update haulvia.shipment_customer_payment_axes
  set state = v_payment_state, secured_amount = 0, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  if v_market = 'EXPIRED' then
    v_new_shipment := 'EXPIRED';
  elsif exists (
    select 1 from haulvia.offer_threads ot
    where ot.shipment_id = p_shipment.id and ot.status = 'ACTIVE' and ot.expires_at > clock_timestamp()
  ) then
    v_new_shipment := 'NEGOTIATING';
  else
    v_new_shipment := 'POSTED';
  end if;
  if v_new_shipment <> p_shipment.shipment_state then
    update haulvia.shipments set shipment_state = v_new_shipment where id = p_shipment.id;
    perform haulvia_command.append_shipment_event(p_shipment.id, p_shipment.shipment_state, v_new_shipment, 'releaseFailedReservation', p_request, v_route_id);
  else
    update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;
  end if;
  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', 'AUTHORIZING', v_payment_state::text, 'releaseFailedReservation', p_request, v_intent.id);
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', 'RESERVED', v_market::text, 'releaseFailedReservation', p_request, v_reservation.id);
  perform haulvia_command.append_audit(p_shipment, 'releaseFailedReservation', p_request, null, jsonb_build_object('reservationId', v_reservation.id, 'paymentTransactionId', v_tx), jsonb_build_object('lateSuccess', v_late_success));
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'PAYMENT_FAILED_OR_TIMED_OUT', p_request, 'payment-failed');
  if v_late_success then
    perform haulvia_command.queue_job(p_shipment.id, 'VOID_OR_REFUND_LATE_SUCCESS', clock_timestamp(), p_request, 'late-success', jsonb_build_object('paymentTransactionId', v_tx));
  end if;
  return jsonb_build_object('reservationId', v_reservation.id, 'paymentIntentId', v_intent.id, 'paymentTransactionId', v_tx, 'lateSuccessQueuedForReversal', v_late_success);
end;
$$;

create or replace function haulvia_command.apply_a18_cancel_pre_assignment(
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
  v_snapshot uuid;
begin
  perform haulvia_command.authorize_customer(
    p_shipment, v_actor, haulvia_command.optional_uuid(p_request, 'actorOrganizationId')
  );
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'cancelPreAssignment requires POSTED or NEGOTIATING');
  end if;
  if exists (select 1 from haulvia.assignments a where a.shipment_id = p_shipment.id and a.status = 'ACTIVE') then
    perform haulvia_command.fail('ASSIGNMENT_CONFLICT', 'Active assignment already committed');
  end if;
  select id into v_route_id from haulvia.route_versions where shipment_id = p_shipment.id and status = 'ACTIVE';
  if haulvia_command.optional_uuid(p_request, 'expectedRouteVersionId') is distinct from v_route_id then
    perform haulvia_command.fail('STALE_ROUTE_VERSION', 'Cancellation route context is stale');
  end if;
  select state into v_market from haulvia.shipment_marketplace_axes where shipment_id = p_shipment.id for update;
  select state into v_payment from haulvia.shipment_customer_payment_axes where shipment_id = p_shipment.id for update;
  select id into v_reservation from haulvia.offer_reservations
  where shipment_id = p_shipment.id and status = 'ACTIVE' for update;
  select id into v_intent from haulvia.payment_intents
  where shipment_id = p_shipment.id and status in ('CREATED', 'AUTHORIZING')
  order by created_at desc limit 1 for update;

  update haulvia.offer_threads set status = 'CLOSED', closed_at = clock_timestamp()
  where shipment_id = p_shipment.id and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED', 'RESERVED');
  update haulvia.offer_reservations
  set status = 'RELEASED', released_at = clock_timestamp(), release_reason = 'CUSTOMER_CANCELLED'
  where id = v_reservation;
  update haulvia.payment_intents set status = 'VOIDED' where id = v_intent;
  update haulvia.shipment_marketplace_axes set state = 'CLOSED', paused_reason = null, state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  update haulvia.shipment_customer_payment_axes set state = 'RELEASED', secured_amount = 0, state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  insert into haulvia.shipment_cancellation_snapshots (
    shipment_id, route_version_id, policy_version_id, cancelled_by_profile_id,
    reason, prior_shipment_state, prior_marketplace_state, prior_payment_state,
    financial_action, snapshot, idempotency_key
  ) values (
    p_shipment.id, v_route_id, haulvia_command.optional_uuid(p_request, 'policyVersionId'), v_actor,
    haulvia_command.required_text(p_request, 'reason'), p_shipment.shipment_state,
    v_market, v_payment, case when v_intent is null then 'NONE' else 'VOID_QUEUED' end,
    coalesce(p_request -> 'cancellationSnapshot', '{}'::jsonb),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_snapshot;
  update haulvia.shipments set shipment_state = 'CANCELLED' where id = p_shipment.id;
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', v_market::text, 'CLOSED', 'cancelPreAssignment', p_request);
  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', v_payment::text, 'RELEASED', 'cancelPreAssignment', p_request, v_intent);
  perform haulvia_command.append_shipment_event(p_shipment.id, p_shipment.shipment_state, 'CANCELLED', 'cancelPreAssignment', p_request, v_route_id);
  perform haulvia_command.append_audit(p_shipment, 'cancelPreAssignment', p_request, to_jsonb(p_shipment), jsonb_build_object('shipmentState', 'CANCELLED'), jsonb_build_object('cancellationSnapshotId', v_snapshot));
  if v_intent is not null then
    perform haulvia_command.queue_job(p_shipment.id, 'VOID_PAYMENT_AUTHORIZATION', clock_timestamp(), p_request, 'cancel-void', jsonb_build_object('paymentIntentId', v_intent));
  end if;
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_CANCELLED', p_request, 'cancelled');
  return jsonb_build_object('routeVersionId', v_route_id, 'cancellationSnapshotId', v_snapshot, 'releasedReservationId', v_reservation, 'paymentIntentId', v_intent);
end;
$$;

create or replace function haulvia_command.apply_a19_expire_listing(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_route_id uuid;
  v_market haulvia.marketplace_state;
  v_payment haulvia.customer_payment_state;
  v_reservation uuid;
  v_intent uuid;
begin
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    p_request ->> 'workerAuthority', array['EXPIRY_WORKER']
  );
  if p_shipment.shipment_state not in ('POSTED', 'NEGOTIATING') then
    perform haulvia_command.fail('INVALID_STATE', 'expireListing requires POSTED or NEGOTIATING');
  end if;
  if p_shipment.marketplace_deadline is null or p_shipment.marketplace_deadline > clock_timestamp() then
    perform haulvia_command.fail('DEADLINE_EXPIRED', 'Listing deadline has not elapsed');
  end if;
  if exists (select 1 from haulvia.assignments a where a.shipment_id = p_shipment.id and a.status = 'ACTIVE') then
    perform haulvia_command.fail('ASSIGNMENT_CONFLICT', 'Paid assignment already committed');
  end if;
  select id into v_route_id from haulvia.route_versions where shipment_id = p_shipment.id and status = 'ACTIVE';
  select state into v_market from haulvia.shipment_marketplace_axes where shipment_id = p_shipment.id for update;
  select state into v_payment from haulvia.shipment_customer_payment_axes where shipment_id = p_shipment.id for update;
  select id into v_reservation from haulvia.offer_reservations
  where shipment_id = p_shipment.id and status = 'ACTIVE' for update;
  select id into v_intent from haulvia.payment_intents
  where shipment_id = p_shipment.id and status in ('CREATED', 'AUTHORIZING')
  order by created_at desc limit 1 for update;
  update haulvia.offer_threads set status = 'EXPIRED', closed_at = clock_timestamp()
  where shipment_id = p_shipment.id and status in ('ACTIVE', 'RECONFIRMATION_REQUIRED', 'RESERVED');
  update haulvia.offer_reservations
  set status = 'EXPIRED', released_at = clock_timestamp(), release_reason = 'LISTING_EXPIRED'
  where id = v_reservation;
  update haulvia.payment_intents set status = 'TIMED_OUT', timed_out_at = clock_timestamp() where id = v_intent;
  update haulvia.shipment_marketplace_axes set state = 'EXPIRED', paused_reason = null, state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  update haulvia.shipment_customer_payment_axes set state = 'RELEASED', secured_amount = 0, state_changed_at = clock_timestamp() where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'EXPIRED' where id = p_shipment.id;
  perform haulvia_command.append_axis_event(p_shipment.id, 'MARKETPLACE', v_market::text, 'EXPIRED', 'expireListing', p_request);
  perform haulvia_command.append_axis_event(p_shipment.id, 'CUSTOMER_PAYMENT', v_payment::text, 'RELEASED', 'expireListing', p_request, v_intent);
  perform haulvia_command.append_shipment_event(p_shipment.id, p_shipment.shipment_state, 'EXPIRED', 'expireListing', p_request, v_route_id);
  perform haulvia_command.append_audit(p_shipment, 'expireListing', p_request, to_jsonb(p_shipment), jsonb_build_object('shipmentState', 'EXPIRED'));
  if v_intent is not null then
    perform haulvia_command.queue_job(p_shipment.id, 'VOID_PAYMENT_AUTHORIZATION', clock_timestamp(), p_request, 'expiry-void', jsonb_build_object('paymentIntentId', v_intent));
  end if;
  perform haulvia_command.queue_notification(p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_EXPIRED', p_request, 'expired');
  return jsonb_build_object('routeVersionId', v_route_id, 'expiredReservationId', v_reservation, 'paymentIntentId', v_intent);
end;
$$;

-- ---------------------------------------------------------------------------
-- Trusted dispatcher and the 19 approved named command entry points
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.execute_block_a_command(
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
    when 'saveDraft' then
      v_affected := haulvia_command.apply_a01_save_draft(v_shipment, p_request);
    when 'editDraftRoute' then
      v_affected := haulvia_command.apply_a02_edit_draft_route(v_shipment, p_request);
    when 'assignCargoToStops' then
      v_affected := haulvia_command.apply_a03_assign_cargo_to_stops(v_shipment, p_request);
    when 'postShipment' then
      v_affected := haulvia_command.apply_a04_post_shipment(v_shipment, p_request);
    when 'editPostedShipment' then
      v_affected := haulvia_command.apply_a05_edit_posted_shipment(v_shipment, p_request);
    when 'pauseMarketplace' then
      v_affected := haulvia_command.apply_a06_pause_marketplace(v_shipment, p_request);
    when 'resumeMarketplace' then
      v_affected := haulvia_command.apply_a07_resume_marketplace(v_shipment, p_request);
    when 'submitIndependentFlexOffer' then
      v_affected := haulvia_command.apply_a08_submit_independent_flex_offer(v_shipment, p_request);
    when 'submitPartnerFlexOffer' then
      v_affected := haulvia_command.apply_a09_submit_partner_flex_offer(v_shipment, p_request);
    when 'acceptFirmRouteMatch' then
      v_affected := haulvia_command.apply_a10_accept_firm_route_match(v_shipment, p_request);
    when 'counterOffer', 'reviseOffer' then
      v_affected := haulvia_command.apply_a11_counter_or_revise_offer(v_shipment, p_request, p_command_name);
    when 'closeLastActiveOffer' then
      v_affected := haulvia_command.apply_a12_close_last_active_offer(v_shipment, p_request);
    when 'materiallyEditNegotiation' then
      v_affected := haulvia_command.apply_a13_materially_edit_negotiation(v_shipment, p_request);
    when 'reconfirmOfferOrFirmMatch' then
      v_affected := haulvia_command.apply_a14_reconfirm_offer_or_firm_match(v_shipment, p_request);
    when 'reserveSelection' then
      v_affected := haulvia_command.apply_a15_reserve_selection(v_shipment, p_request);
    when 'confirmPaidAssignment' then
      v_affected := haulvia_command.apply_a16_confirm_paid_assignment(v_shipment, p_request);
    when 'releaseFailedReservation' then
      v_affected := haulvia_command.apply_a17_release_failed_reservation(v_shipment, p_request);
    when 'cancelPreAssignment' then
      v_affected := haulvia_command.apply_a18_cancel_pre_assignment(v_shipment, p_request);
    when 'expireListing' then
      v_affected := haulvia_command.apply_a19_expire_listing(v_shipment, p_request);
    else
      perform haulvia_command.fail('INVALID_REQUEST', 'Command is not an approved Block A handler');
  end case;

  v_result := haulvia_command.operating_context(
    v_shipment.id, p_command_name, v_command_id, v_affected
  );
  return haulvia_command.complete_request(
    v_actor, p_command_name, v_idempotency_key, v_result
  );
end;
$$;

create or replace function haulvia_command.command_save_draft(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('saveDraft', p_request); $$;

create or replace function haulvia_command.command_edit_draft_route(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('editDraftRoute', p_request); $$;

create or replace function haulvia_command.command_assign_cargo_to_stops(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('assignCargoToStops', p_request); $$;

create or replace function haulvia_command.command_post_shipment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('postShipment', p_request); $$;

create or replace function haulvia_command.command_edit_posted_shipment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('editPostedShipment', p_request); $$;

create or replace function haulvia_command.command_pause_marketplace(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('pauseMarketplace', p_request); $$;

create or replace function haulvia_command.command_resume_marketplace(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('resumeMarketplace', p_request); $$;

create or replace function haulvia_command.command_submit_independent_flex_offer(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('submitIndependentFlexOffer', p_request); $$;

create or replace function haulvia_command.command_submit_partner_flex_offer(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('submitPartnerFlexOffer', p_request); $$;

create or replace function haulvia_command.command_accept_firm_route_match(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('acceptFirmRouteMatch', p_request); $$;

create or replace function haulvia_command.command_counter_offer(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('counterOffer', p_request); $$;

create or replace function haulvia_command.command_revise_offer(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('reviseOffer', p_request); $$;

create or replace function haulvia_command.command_close_last_active_offer(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('closeLastActiveOffer', p_request); $$;

create or replace function haulvia_command.command_materially_edit_negotiation(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('materiallyEditNegotiation', p_request); $$;

create or replace function haulvia_command.command_reconfirm_offer_or_firm_match(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('reconfirmOfferOrFirmMatch', p_request); $$;

create or replace function haulvia_command.command_reserve_selection(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('reserveSelection', p_request); $$;

create or replace function haulvia_command.command_confirm_paid_assignment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('confirmPaidAssignment', p_request); $$;

create or replace function haulvia_command.command_release_failed_reservation(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('releaseFailedReservation', p_request); $$;

create or replace function haulvia_command.command_cancel_pre_assignment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('cancelPreAssignment', p_request); $$;

create or replace function haulvia_command.command_expire_listing(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_a_command('expireListing', p_request); $$;

revoke all on all functions in schema haulvia_command from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema haulvia_command to service_role;
    grant execute on all functions in schema haulvia_command to service_role;
  end if;
end;
$$;

comment on schema haulvia_command is
  'Trusted transactional command boundary for Haulvia; not an end-user write surface.';
comment on table haulvia.customer_payment_method_refs is
  'Verified external payment method references only; no raw card or bank credentials.';
comment on table haulvia.workflow_jobs is
  'Durable internal outbox for delayed Block A work such as expiry, timeout, void, and reminders.';
comment on table haulvia.shipment_cancellation_snapshots is
  'Append-only pre-assignment cancellation evidence retained with the governing policy and financial action.';

commit;
