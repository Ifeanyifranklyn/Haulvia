-- Haulvia Block D command layer v1
-- Approved source: State Transition Matrix v1.1, Block D (D01-D09)
-- Depends on: foundation v1 and Blocks A-C v1
-- Target: PostgreSQL 16; compatible with Supabase Postgres
-- Security boundary: trusted service role only; end-user RLS remains deferred.

begin;

set local search_path = haulvia, haulvia_command, public;

-- ---------------------------------------------------------------------------
-- Delivery-review, completion, and payout evidence
-- ---------------------------------------------------------------------------

create table haulvia.delivery_review_windows (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  route_execution_id uuid not null references haulvia.route_executions(id),
  route_version_id uuid not null references haulvia.route_versions(id),
  stop_execution_id uuid not null unique references haulvia.stop_executions(id),
  receiver_access_token_id uuid references haulvia.receiver_access_tokens(id),
  policy_version_id uuid references haulvia.policy_versions(id),
  review_required boolean not null,
  configured_window_seconds integer not null,
  started_at timestamptz not null,
  expires_at timestamptz not null,
  timing_window_snapshot jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  unique (id, stop_execution_id),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, route_version_id)
    references haulvia.route_versions(shipment_id, id),
  check (configured_window_seconds >= 0),
  check (expires_at >= started_at),
  check (
    (review_required and configured_window_seconds > 0 and receiver_access_token_id is not null)
    or (not review_required and configured_window_seconds = 0 and expires_at = started_at)
  ),
  check (timing_window_snapshot <> '{}'::jsonb)
);

create table haulvia.delivery_review_window_resolutions (
  id uuid primary key default gen_random_uuid(),
  delivery_review_window_id uuid not null unique,
  stop_execution_id uuid not null,
  verification_state haulvia.delivery_verification_state not null,
  resolution_source text not null check (
    resolution_source in (
      'IN_PERSON_VERIFICATION', 'RECEIVER_RESPONSE', 'PROOF_OF_DROP',
      'WINDOW_EXCEPTION', 'MIGRATION_BACKFILL'
    )
  ),
  receiver_confirmation_id uuid references haulvia.receiver_confirmations(id),
  dispute_id uuid references haulvia.disputes(id),
  route_exception_id uuid references haulvia.route_exceptions(id),
  evidence_snapshot jsonb not null,
  resolved_by_profile_id uuid references haulvia.profiles(id),
  resolved_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (stop_execution_id),
  foreign key (delivery_review_window_id, stop_execution_id)
    references haulvia.delivery_review_windows(id, stop_execution_id),
  check (
    verification_state in (
      'NOT_REQUIRED', 'RECEIVER_CONFIRMED', 'VERIFIED_BY_PROOF_OF_DROP',
      'ISSUE_REPORTED', 'EXCEPTION_REVIEW'
    )
  ),
  check (evidence_snapshot <> '{}'::jsonb)
);

create table haulvia.delivery_problem_reports (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references haulvia.shipments(id),
  stop_execution_id uuid not null references haulvia.stop_executions(id),
  delivery_review_window_id uuid not null references haulvia.delivery_review_windows(id),
  receiver_access_token_id uuid not null references haulvia.receiver_access_tokens(id),
  receiver_confirmation_id uuid not null unique references haulvia.receiver_confirmations(id),
  dispute_id uuid not null unique references haulvia.disputes(id),
  financial_hold_id uuid references haulvia.financial_holds(id),
  issue_category text not null check (
    issue_category in ('MISSING', 'DAMAGED', 'INCORRECT', 'NOT_RECEIVED')
  ),
  description text not null,
  cargo_manifest jsonb not null,
  evidence_manifest jsonb not null,
  disputed_amount numeric(14,2) not null,
  protected_amount numeric(14,2) not null,
  currency char(3) not null,
  reported_at timestamptz not null,
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  check (length(btrim(description)) >= 8),
  check (jsonb_typeof(cargo_manifest) = 'array' and jsonb_array_length(cargo_manifest) > 0),
  check (jsonb_typeof(evidence_manifest) = 'array' and jsonb_array_length(evidence_manifest) > 0),
  check (disputed_amount >= 0 and protected_amount >= 0 and protected_amount <= disputed_amount),
  check (currency ~ '^[A-Z]{3}$')
);

create table haulvia.payout_eligibility_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null unique references haulvia.shipments(id),
  assignment_id uuid not null unique references haulvia.assignments(id),
  route_resolution_record_id uuid not null unique references haulvia.route_resolution_records(id),
  price_snapshot_id uuid not null references haulvia.shipment_price_snapshots(id),
  policy_version_id uuid references haulvia.policy_versions(id),
  eligibility_state haulvia.driver_payout_state not null,
  gross_amount numeric(14,2) not null,
  platform_fee_amount numeric(14,2) not null,
  adjustment_amount numeric(14,2) not null,
  net_amount numeric(14,2) not null,
  protected_hold_amount numeric(14,2) not null,
  releasable_amount numeric(14,2) not null,
  currency char(3) not null,
  route_allocation_snapshot jsonb not null,
  evidence_window_snapshot jsonb not null,
  policy_snapshot jsonb not null,
  release_authorization jsonb not null,
  authorized_by_profile_id uuid references haulvia.profiles(id),
  authorized_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  check (eligibility_state in ('READY', 'HELD')),
  check (gross_amount >= 0 and platform_fee_amount >= 0),
  check (net_amount = gross_amount - platform_fee_amount + adjustment_amount),
  check (net_amount >= 0),
  check (protected_hold_amount >= 0 and protected_hold_amount <= net_amount),
  check (releasable_amount = net_amount - protected_hold_amount),
  check (currency ~ '^[A-Z]{3}$'),
  check (route_allocation_snapshot <> '{}'::jsonb),
  check (evidence_window_snapshot <> '{}'::jsonb),
  check (policy_snapshot <> '{}'::jsonb),
  check (release_authorization <> '{}'::jsonb)
);

create table haulvia.shipment_completion_records (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null unique references haulvia.shipments(id),
  route_execution_id uuid not null unique references haulvia.route_executions(id),
  route_resolution_record_id uuid not null unique references haulvia.route_resolution_records(id),
  assignment_id uuid not null unique references haulvia.assignments(id),
  payout_id uuid not null unique references haulvia.driver_payouts(id),
  payout_eligibility_record_id uuid not null unique references haulvia.payout_eligibility_records(id),
  release_authorization jsonb not null,
  verification_summary jsonb not null,
  financial_summary jsonb not null,
  completed_by_profile_id uuid references haulvia.profiles(id),
  completed_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references haulvia.route_executions(shipment_id, id),
  foreign key (shipment_id, assignment_id)
    references haulvia.assignments(shipment_id, id),
  check (release_authorization <> '{}'::jsonb),
  check (verification_summary <> '{}'::jsonb),
  check (financial_summary <> '{}'::jsonb)
);

alter table haulvia.receiver_confirmations
  add column delivery_review_window_id uuid references haulvia.delivery_review_windows(id);

alter table haulvia.disputes
  add column opened_by_receiver_access_token_id uuid references haulvia.receiver_access_tokens(id);

-- A verified receiver may be neither a Haulvia profile nor a provider. Replace
-- the original two-actor check with the approved three-actor form.
do $$
declare
  v_constraint text;
begin
  select c.conname into v_constraint
  from pg_constraint c
  where c.conrelid = 'haulvia.disputes'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) like '%num_nonnulls(opened_by_profile_id, opened_by_provider_id)%';
  if v_constraint is not null then
    execute format('alter table haulvia.disputes drop constraint %I', v_constraint);
  end if;
end;
$$;

alter table haulvia.disputes
  add constraint disputes_opener_ck check (
    num_nonnulls(
      opened_by_profile_id,
      opened_by_provider_id,
      opened_by_receiver_access_token_id
    ) >= 1
  );

alter table haulvia.driver_payouts
  add column payout_eligibility_record_id uuid unique
    references haulvia.payout_eligibility_records(id);

alter table haulvia.payout_transactions
  add column request_transaction_id uuid references haulvia.payout_transactions(id),
  add column allocation_snapshot jsonb not null default '{}'::jsonb;

alter table haulvia.financial_adjustments
  add column route_execution_id uuid references haulvia.route_executions(id),
  add column authorization_snapshot jsonb not null default '{}'::jsonb,
  add column provider_request_snapshot jsonb not null default '{}'::jsonb;

-- Null provider event IDs mean "request submitted, callback not received" and
-- therefore must not collide. Once an event ID exists it is globally unique
-- inside that provider.
alter table haulvia.payment_transactions
  drop constraint payment_transactions_external_provider_provider_event_id_key;
create unique index payment_transactions_provider_event_uq
  on haulvia.payment_transactions (external_provider, provider_event_id)
  where provider_event_id is not null;

alter table haulvia.payout_transactions
  drop constraint payout_transactions_external_provider_provider_event_id_key;
create unique index payout_transactions_provider_event_uq
  on haulvia.payout_transactions (external_provider, provider_event_id)
  where provider_event_id is not null;

create unique index receiver_confirmations_one_stop_result_uq
  on haulvia.receiver_confirmations (stop_execution_id);
create unique index payout_transactions_one_request_outcome_uq
  on haulvia.payout_transactions (request_transaction_id)
  where request_transaction_id is not null;
create unique index financial_holds_one_active_source_uq
  on haulvia.financial_holds (source_type, source_id)
  where status = 'ACTIVE' and source_id is not null;
create index delivery_review_windows_expiry_idx
  on haulvia.delivery_review_windows (expires_at, shipment_id);
create index delivery_problem_reports_shipment_idx
  on haulvia.delivery_problem_reports (shipment_id, reported_at, id);
create index payout_transactions_request_idx
  on haulvia.payout_transactions (request_transaction_id, occurred_at, id);

insert into haulvia.permissions(permission_key, description, is_sensitive)
values ('PAYOUT_MANAGE', 'Submit, retry, and administratively manage driver payout requests', true)
on conflict (permission_key) do nothing;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'delivery_review_windows', 'delivery_review_window_resolutions',
    'delivery_problem_reports', 'payout_eligibility_records',
    'shipment_completion_records', 'financial_adjustments'
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
-- Start the applicable stop-level review window as delivery evidence becomes
-- verified. The duration comes from the shipment's retained policy snapshot;
-- the provisional launch value is data (normally 86400), never command code.
-- ---------------------------------------------------------------------------

create or replace function haulvia.start_delivery_review_window()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_stop_type haulvia.stop_type;
  v_token haulvia.receiver_access_tokens%rowtype;
  v_snapshot haulvia.shipment_rule_snapshots%rowtype;
  v_seconds integer;
  v_window_id uuid;
begin
  if old.state = 'COMPLETED' or new.state <> 'COMPLETED' then
    return new;
  end if;

  select rs.stop_type into v_stop_type
  from haulvia.route_stops rs
  where rs.id = new.route_stop_id and rs.route_version_id = new.route_version_id;
  if v_stop_type <> 'DELIVERY' then
    return new;
  end if;

  if new.delivery_verification_state = 'PENDING_RECEIVER_CONFIRMATION' then
    select * into v_snapshot
    from haulvia.shipment_rule_snapshots srs
    where srs.shipment_id = new.shipment_id
      and srs.route_version_id = new.route_version_id;
    if not found then
      raise exception 'Contactless delivery requires a retained shipment rule snapshot'
        using errcode = '23514';
    end if;
    begin
      v_seconds := (v_snapshot.timing_windows ->> 'deliveryReviewSeconds')::integer;
    exception when invalid_text_representation then
      raise exception 'deliveryReviewSeconds must be a positive integer in the retained policy snapshot'
        using errcode = '23514';
    end;
    if v_seconds is null or v_seconds <= 0 then
      raise exception 'Contactless delivery requires configured deliveryReviewSeconds'
        using errcode = '23514';
    end if;

    select * into v_token
    from haulvia.receiver_access_tokens rat
    where rat.shipment_id = new.shipment_id
      and rat.stop_execution_id = new.id
      and rat.revoked_at is null
    order by rat.created_at desc, rat.id desc
    limit 1;
    if not found then
      raise exception 'Contactless delivery requires a receiver token before verification'
        using errcode = '23514';
    end if;
    if abs(extract(epoch from (v_token.expires_at - new.completed_at)) - v_seconds) > 5 then
      raise exception 'Receiver token expiry does not match the snapshotted delivery review duration'
        using errcode = '23514';
    end if;

    insert into haulvia.delivery_review_windows (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      receiver_access_token_id, policy_version_id, review_required,
      configured_window_seconds, started_at, expires_at, timing_window_snapshot
    ) values (
      new.shipment_id, new.route_execution_id, new.route_version_id, new.id,
      v_token.id, v_snapshot.policy_version_id, true, v_seconds,
      new.completed_at, v_token.expires_at, v_snapshot.timing_windows
    );
  else
    select * into v_snapshot
    from haulvia.shipment_rule_snapshots srs
    where srs.shipment_id = new.shipment_id
      and srs.route_version_id = new.route_version_id;
    insert into haulvia.delivery_review_windows (
      shipment_id, route_execution_id, route_version_id, stop_execution_id,
      policy_version_id, review_required, configured_window_seconds,
      started_at, expires_at, timing_window_snapshot
    ) values (
      new.shipment_id, new.route_execution_id, new.route_version_id, new.id,
      v_snapshot.policy_version_id, false, 0, new.completed_at, new.completed_at,
      coalesce(v_snapshot.timing_windows, '{}'::jsonb) ||
        jsonb_build_object('appliedWindowSeconds', 0, 'reviewRequired', false)
    ) returning id into v_window_id;

    insert into haulvia.delivery_review_window_resolutions (
      delivery_review_window_id, stop_execution_id, verification_state,
      resolution_source, evidence_snapshot, resolved_at, idempotency_key
    ) values (
      v_window_id, new.id, 'NOT_REQUIRED', 'IN_PERSON_VERIFICATION',
      jsonb_build_object('mode', 'IN_PERSON_OR_NON_CONTACTLESS', 'stopCompletedAt', new.completed_at),
      new.completed_at, 'automatic:' || new.id::text
    );
  end if;
  return new;
end;
$$;

create trigger stop_executions_start_delivery_review
after update of state, delivery_verification_state on haulvia.stop_executions
for each row
when (old.state is distinct from new.state)
execute function haulvia.start_delivery_review_window();

-- Backfill already verified delivery stops if this migration is installed
-- after operational Block C data exists. Actual retained deadlines win.
insert into haulvia.delivery_review_windows (
  shipment_id, route_execution_id, route_version_id, stop_execution_id,
  receiver_access_token_id, policy_version_id, review_required,
  configured_window_seconds, started_at, expires_at, timing_window_snapshot
)
select
  se.shipment_id, se.route_execution_id, se.route_version_id, se.id,
  rat.id, srs.policy_version_id,
  se.delivery_verification_state = 'PENDING_RECEIVER_CONFIRMATION',
  case when se.delivery_verification_state = 'PENDING_RECEIVER_CONFIRMATION'
    then greatest(1, extract(epoch from (coalesce(rat.expires_at, se.completed_at) - se.completed_at))::integer)
    else 0 end,
  se.completed_at,
  case when se.delivery_verification_state = 'PENDING_RECEIVER_CONFIRMATION'
    then coalesce(rat.expires_at, se.completed_at)
    else se.completed_at end,
  coalesce(srs.timing_windows, '{}'::jsonb) || jsonb_build_object('migrationBackfill', true)
from haulvia.stop_executions se
join haulvia.route_stops rs
  on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
left join haulvia.shipment_rule_snapshots srs
  on srs.shipment_id = se.shipment_id and srs.route_version_id = se.route_version_id
left join lateral (
  select token.* from haulvia.receiver_access_tokens token
  where token.stop_execution_id = se.id
  order by token.created_at desc, token.id desc limit 1
) rat on true
where rs.stop_type = 'DELIVERY'
  and se.state = 'COMPLETED'
  and not exists (
    select 1 from haulvia.delivery_review_windows existing
    where existing.stop_execution_id = se.id
  );

insert into haulvia.delivery_review_window_resolutions (
  delivery_review_window_id, stop_execution_id, verification_state,
  resolution_source, receiver_confirmation_id, evidence_snapshot,
  resolved_at, idempotency_key
)
select
  drw.id, drw.stop_execution_id, se.delivery_verification_state,
  'MIGRATION_BACKFILL', rc.id,
  jsonb_build_object('migrationBackfill', true, 'priorVerificationState', se.delivery_verification_state),
  coalesce(rc.responded_at, se.completed_at), 'migration:' || drw.stop_execution_id::text
from haulvia.delivery_review_windows drw
join haulvia.stop_executions se on se.id = drw.stop_execution_id
left join lateral (
  select confirmation.* from haulvia.receiver_confirmations confirmation
  where confirmation.stop_execution_id = drw.stop_execution_id
  order by confirmation.responded_at, confirmation.id limit 1
) rc on true
where se.delivery_verification_state <> 'PENDING_RECEIVER_CONFIRMATION'
  and not exists (
    select 1 from haulvia.delivery_review_window_resolutions existing
    where existing.delivery_review_window_id = drw.id
  );

-- ---------------------------------------------------------------------------
-- Block D shared helpers
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.lock_delivery_review_window(
  p_shipment_id uuid,
  p_request jsonb
)
returns haulvia.delivery_review_windows
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_window haulvia.delivery_review_windows%rowtype;
  v_window_id uuid := haulvia_command.required_uuid(p_request, 'expectedDeliveryReviewWindowId');
  v_stop_id uuid := haulvia_command.required_uuid(p_request, 'expectedStopExecutionId');
begin
  select * into v_window
  from haulvia.delivery_review_windows drw
  where drw.id = v_window_id
    and drw.shipment_id = p_shipment_id
    and drw.stop_execution_id = v_stop_id
  for update;
  if not found then
    perform haulvia_command.fail(
      'DELIVERY_REVIEW_NOT_FOUND',
      'The expected stop-level delivery review window was not found'
    );
  end if;
  if exists (
    select 1 from haulvia.delivery_review_window_resolutions drwr
    where drwr.delivery_review_window_id = v_window.id
  ) then
    perform haulvia_command.fail(
      'DELIVERY_REVIEW_ALREADY_RESOLVED',
      'This delivery review window already has its first valid resolution'
    );
  end if;
  return v_window;
end;
$$;

create or replace function haulvia_command.lock_resolved_route_execution(
  p_window haulvia.delivery_review_windows,
  p_request jsonb
)
returns haulvia.route_executions
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_execution haulvia.route_executions%rowtype;
  v_expected_id uuid := haulvia_command.required_uuid(p_request, 'expectedRouteExecutionId');
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
  where re.id = v_expected_id
    and re.id = p_window.route_execution_id
    and re.shipment_id = p_window.shipment_id
  for update;
  if not found or v_execution.state <> 'COMPLETED' then
    perform haulvia_command.fail('ROUTE_NOT_RESOLVED', 'The delivery review requires its completed route execution');
  end if;
  if v_execution.record_version <> v_expected_version then
    perform haulvia_command.fail(
      'STALE_ROUTE_EXECUTION_VERSION',
      'The resolved route execution changed after the request was prepared',
      jsonb_build_object('expected', v_expected_version, 'current', v_execution.record_version)
    );
  end if;
  return v_execution;
end;
$$;

create or replace function haulvia_command.authorize_receiver_token(
  p_window haulvia.delivery_review_windows,
  p_request jsonb,
  p_permission text,
  p_responded_at timestamptz
)
returns haulvia.receiver_access_tokens
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_token haulvia.receiver_access_tokens%rowtype;
  v_token_id uuid := haulvia_command.required_uuid(p_request, 'receiverAccessTokenId');
  v_hash text := lower(haulvia_command.required_text(p_request, 'receiverTokenHash'));
begin
  if v_hash !~ '^[0-9a-f]{64}$' then
    perform haulvia_command.fail('INVALID_REQUEST', 'receiverTokenHash must be a SHA-256 hex value');
  end if;
  select * into v_token
  from haulvia.receiver_access_tokens rat
  where rat.id = v_token_id
    and rat.id = p_window.receiver_access_token_id
    and rat.shipment_id = p_window.shipment_id
    and rat.stop_execution_id = p_window.stop_execution_id
  for update;
  if not found
     or lower(v_token.token_hash) <> v_hash
     or v_token.revoked_at is not null
     or v_token.used_at is not null
     or not coalesce((v_token.permissions ->> p_permission)::boolean, false) then
    perform haulvia_command.fail('RECEIVER_NOT_VERIFIED', 'The secure receiver authority is invalid or already used');
  end if;
  if p_responded_at > v_token.expires_at or p_responded_at > p_window.expires_at
     or clock_timestamp() > v_token.expires_at then
    perform haulvia_command.fail('DELIVERY_REVIEW_EXPIRED', 'The receiver response window has expired');
  end if;
  return v_token;
end;
$$;

create or replace function haulvia_command.assert_delivery_cargo_manifest(
  p_stop_execution_id uuid,
  p_manifest jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_expected integer;
  v_requested integer;
  v_distinct integer;
begin
  if jsonb_typeof(p_manifest) <> 'array' or jsonb_array_length(p_manifest) = 0 then
    perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'cargoManifest must be a non-empty array');
  end if;
  select count(distinct cro.cargo_allocation_id) into v_expected
  from haulvia.cargo_resolution_outcomes cro
  where cro.stop_execution_id = p_stop_execution_id and cro.outcome_code = 'DELIVERED';
  select count(*), count(distinct value ->> 'cargoAllocationId')
  into v_requested, v_distinct
  from jsonb_array_elements(p_manifest);
  if v_expected = 0 or v_requested <> v_expected or v_distinct <> v_requested then
    perform haulvia_command.fail(
      'CARGO_REFERENCE_INVALID',
      'The receiver response must reference every delivered allocation at this stop exactly once'
    );
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_manifest) item
    left join (
      select cro.cargo_allocation_id, cro.quantity_unit, sum(cro.quantity) as quantity
      from haulvia.cargo_resolution_outcomes cro
      where cro.stop_execution_id = p_stop_execution_id and cro.outcome_code = 'DELIVERED'
      group by cro.cargo_allocation_id, cro.quantity_unit
    ) actual on actual.cargo_allocation_id = (item ->> 'cargoAllocationId')::uuid
    where actual.cargo_allocation_id is null
       or actual.quantity <> (item ->> 'quantity')::numeric
       or actual.quantity_unit <> item ->> 'quantityUnit'
  ) then
    perform haulvia_command.fail(
      'CARGO_REFERENCE_INVALID',
      'The receiver cargo quantity or unit does not match verified delivery outcomes'
    );
  end if;
exception when invalid_text_representation then
  perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'cargoManifest contains an invalid UUID or quantity');
end;
$$;

create or replace function haulvia_command.assert_sensitive_command_authority(
  p_request jsonb,
  p_permission text,
  p_worker_authorities text[]
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_actor uuid := haulvia_command.optional_uuid(p_request, 'actorProfileId');
  v_org uuid := haulvia_command.optional_uuid(p_request, 'actorOrganizationId');
  v_reauth uuid := haulvia_command.optional_uuid(p_request, 'reauthSessionId');
  v_reason text := nullif(btrim(p_request ->> 'reason'), '');
begin
  if v_actor is null then
    perform haulvia_command.assert_worker(v_actor, p_request ->> 'workerAuthority', p_worker_authorities);
    return;
  end if;
  if v_org is null or not haulvia.has_permission(v_actor, v_org, p_permission) then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'The required sensitive permission is missing');
  end if;
  if v_reason is null or length(v_reason) < 8 then
    perform haulvia_command.fail('REASON_REQUIRED', 'A specific reason of at least eight characters is required');
  end if;
  if v_reauth is null or not exists (
    select 1 from haulvia.reauth_sessions rs
    where rs.id = v_reauth and rs.profile_id = v_actor
      and rs.organization_id is not distinct from v_org
      and rs.verified_at <= clock_timestamp() and rs.expires_at > clock_timestamp()
      and rs.revoked_at is null
  ) then
    perform haulvia_command.fail('FRESH_AUTH_REQUIRED', 'Fresh password, passkey, or MFA verification is required');
  end if;
  perform haulvia.assert_sensitive_authority(v_actor, v_org, p_permission, v_reauth, v_reason);
end;
$$;

create or replace function haulvia_command.append_receiver_audit(
  p_shipment haulvia.shipments,
  p_command_name text,
  p_request jsonb,
  p_receiver_token_id uuid,
  p_before jsonb,
  p_after jsonb,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  insert into haulvia.audit_events (
    actor_kind, command_name, entity_table, entity_id, before_value, after_value,
    metadata, correlation_id, idempotency_key
  ) values (
    'EXTERNAL_RECEIVER', p_command_name, 'shipments', p_shipment.id,
    p_before, p_after,
    coalesce(p_metadata, '{}'::jsonb) || jsonb_build_object('receiverAccessTokenId', p_receiver_token_id),
    haulvia_command.required_uuid(p_request, 'commandId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  );
end;
$$;

create or replace function haulvia_command.open_post_delivery_dispute_record(
  p_shipment haulvia.shipments,
  p_stop_execution_id uuid,
  p_cargo_item_id uuid,
  p_opened_by_profile_id uuid,
  p_opened_by_provider_id uuid,
  p_opened_by_receiver_token_id uuid,
  p_category_code text,
  p_description text,
  p_disputed_amount numeric,
  p_currency text,
  p_evidence_manifest jsonb,
  p_financial_allocation jsonb,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_price haulvia.shipment_price_snapshots%rowtype;
  v_payment_intent haulvia.payment_intents%rowtype;
  v_payout haulvia.driver_payouts%rowtype;
  v_dispute_id uuid := gen_random_uuid();
  v_hold_id uuid;
  v_available numeric(14,2) := 0;
  v_paid numeric(14,2) := 0;
  v_pending numeric(14,2) := 0;
  v_protected numeric(14,2) := 0;
  v_prior_dispute_state haulvia.dispute_axis_state;
  v_prior_payout_state haulvia.driver_payout_state;
  v_open_count integer;
  v_actor_kind haulvia.actor_kind;
  v_price_id uuid;
begin
  if p_disputed_amount < 0 then
    perform haulvia_command.fail('FINANCIAL_ALLOCATION_INVALID', 'Disputed amount cannot be negative');
  end if;
  if upper(p_currency) <> p_shipment.currency then
    perform haulvia_command.fail('FINANCIAL_ALLOCATION_INVALID', 'Dispute currency must match the shipment');
  end if;
  if length(btrim(p_description)) < 8 then
    perform haulvia_command.fail('INVALID_REQUEST', 'A specific dispute explanation is required');
  end if;
  if jsonb_typeof(p_evidence_manifest) <> 'array'
     or jsonb_array_length(p_evidence_manifest) = 0 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'A dispute requires a non-empty evidence manifest');
  end if;
  if jsonb_typeof(p_financial_allocation) <> 'object'
     or p_financial_allocation = '{}'::jsonb then
    perform haulvia_command.fail(
      'FINANCIAL_ALLOCATION_INVALID',
      'A route/stop/cargo-linked financial allocation is required'
    );
  end if;
  v_price_id := haulvia_command.required_uuid(p_financial_allocation, 'priceSnapshotId');
  select * into v_price
  from haulvia.shipment_price_snapshots sps
  where sps.id = v_price_id and sps.shipment_id = p_shipment.id;
  if not found or v_price.currency <> upper(p_currency)
     or p_disputed_amount > v_price.total_amount then
    perform haulvia_command.fail(
      'FINANCIAL_ALLOCATION_INVALID',
      'The disputed amount must fit the retained accepted route price snapshot'
    );
  end if;
  if nullif(btrim(p_financial_allocation ->> 'basis'), '') is null then
    perform haulvia_command.fail('FINANCIAL_ALLOCATION_INVALID', 'Financial allocation basis is required');
  end if;

  if p_stop_execution_id is not null and not exists (
    select 1 from haulvia.stop_executions se
    where se.id = p_stop_execution_id and se.shipment_id = p_shipment.id
  ) then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'Dispute stop does not belong to the shipment');
  end if;
  if p_cargo_item_id is not null and not exists (
    select 1
    from haulvia.cargo_items ci
    join haulvia.route_versions rv on rv.id = ci.route_version_id
    where ci.id = p_cargo_item_id and rv.shipment_id = p_shipment.id
  ) then
    perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Dispute cargo does not belong to the shipment');
  end if;

  select * into v_payment_intent
  from haulvia.payment_intents pi
  where pi.shipment_id = p_shipment.id and pi.status = 'SECURED'
  order by pi.secured_at desc nulls last, pi.created_at desc, pi.id desc
  limit 1;

  select * into v_payout
  from haulvia.driver_payouts dp
  where dp.shipment_id = p_shipment.id
  order by dp.created_at desc, dp.id desc
  limit 1
  for update;

  if found then
    select coalesce(sum(pt.amount), 0) into v_paid
    from haulvia.payout_transactions pt
    where pt.payout_id = v_payout.id and pt.status = 'SUCCEEDED';
    select coalesce(sum(pt.amount), 0) into v_pending
    from haulvia.payout_transactions pt
    where pt.payout_id = v_payout.id and pt.status = 'PENDING'
      and not exists (
        select 1 from haulvia.payout_transactions outcome
        where outcome.request_transaction_id = pt.id
      );
    v_available := greatest(v_payout.net_amount - v_paid - v_pending, 0);
  else
    v_available := coalesce(v_payment_intent.amount, 0);
  end if;
  v_protected := least(p_disputed_amount, v_available);

  if v_protected > 0 then
    insert into haulvia.financial_holds (
      shipment_id, payment_intent_id, payout_id, hold_code, source_type,
      source_id, amount, currency, reason
    ) values (
      p_shipment.id, v_payment_intent.id, v_payout.id, 'DISPUTED_AMOUNT',
      'POST_DELIVERY_DISPUTE', v_dispute_id, v_protected, upper(p_currency),
      'Protected disputed amount pending evidence-based resolution'
    ) returning id into v_hold_id;
  end if;

  insert into haulvia.disputes (
    id, shipment_id, stop_execution_id, cargo_item_id,
    opened_by_profile_id, opened_by_provider_id,
    opened_by_receiver_access_token_id, category_code, status, description,
    disputed_amount, currency, financial_hold_id
  ) values (
    v_dispute_id, p_shipment.id, p_stop_execution_id, p_cargo_item_id,
    p_opened_by_profile_id, p_opened_by_provider_id,
    p_opened_by_receiver_token_id, upper(p_category_code), 'OPEN', p_description,
    p_disputed_amount, upper(p_currency), v_hold_id
  );

  v_actor_kind := case
    when p_opened_by_receiver_token_id is not null then 'EXTERNAL_RECEIVER'::haulvia.actor_kind
    when p_opened_by_provider_id is not null then 'SERVICE_PROVIDER'::haulvia.actor_kind
    else 'PROFILE'::haulvia.actor_kind
  end;
  insert into haulvia.dispute_events (
    dispute_id, prior_status, current_status, event_type, actor_kind,
    actor_profile_id, actor_provider_id, note, evidence_manifest,
    financial_allocation, occurred_at, idempotency_key, metadata
  ) values (
    v_dispute_id, null, 'OPEN', 'POST_DELIVERY_DISPUTE_OPENED', v_actor_kind,
    case when v_actor_kind = 'PROFILE' then p_opened_by_profile_id end,
    p_opened_by_provider_id, p_description, p_evidence_manifest,
    p_financial_allocation || jsonb_build_object(
      'disputedAmount', p_disputed_amount,
      'protectedAmount', v_protected,
      'unprotectedAmount', p_disputed_amount - v_protected,
      'currency', upper(p_currency)
    ), clock_timestamp(), haulvia_command.required_text(p_request, 'idempotencyKey'),
    jsonb_build_object(
      'receiverAccessTokenId', p_opened_by_receiver_token_id,
      'financialHoldId', v_hold_id
    )
  );

  select state into v_prior_dispute_state
  from haulvia.shipment_dispute_axes where shipment_id = p_shipment.id for update;
  select count(*) into v_open_count
  from haulvia.disputes d
  where d.shipment_id = p_shipment.id and d.status not in ('RESOLVED', 'CLOSED');
  update haulvia.shipment_dispute_axes
  set state = 'OPEN', open_dispute_count = v_open_count,
      state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;

  insert into haulvia.workflow_axis_events (
    shipment_id, axis, axis_entity_id, prior_state, current_state, command_name,
    actor_kind, actor_profile_id, reason, correlation_id, idempotency_key, metadata
  ) values (
    p_shipment.id, 'DISPUTE', v_dispute_id, v_prior_dispute_state::text, 'OPEN',
    haulvia_command.required_text(p_request, 'commandName'), v_actor_kind,
    case when v_actor_kind = 'PROFILE' then p_opened_by_profile_id end,
    p_description, haulvia_command.required_uuid(p_request, 'commandId'),
    haulvia_command.required_text(p_request, 'idempotencyKey') || ':dispute',
    jsonb_build_object('financialHoldId', v_hold_id, 'protectedAmount', v_protected)
  );

  if v_hold_id is not null then
    select state into v_prior_payout_state
    from haulvia.shipment_driver_payout_axes
    where shipment_id = p_shipment.id for update;
    if v_payout.id is not null and v_payout.state not in ('PROCESSING', 'PAID') then
      update haulvia.driver_payouts
      set state = 'HELD', state_changed_at = clock_timestamp()
      where id = v_payout.id;
    end if;
    if v_prior_payout_state not in ('PROCESSING', 'PAID') then
      update haulvia.shipment_driver_payout_axes
      set state = 'HELD', state_changed_at = clock_timestamp()
      where shipment_id = p_shipment.id;
      perform haulvia_command.append_axis_event(
        p_shipment.id, 'DRIVER_PAYOUT', v_prior_payout_state::text, 'HELD',
        haulvia_command.required_text(p_request, 'commandName'), p_request, v_payout.id,
        jsonb_build_object('financialHoldId', v_hold_id, 'protectedAmount', v_protected)
      );
    end if;
  end if;

  return jsonb_build_object(
    'disputeId', v_dispute_id, 'financialHoldId', v_hold_id,
    'disputedAmount', p_disputed_amount, 'protectedAmount', v_protected,
    'unprotectedAmount', p_disputed_amount - v_protected,
    'openDisputeCount', v_open_count
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- D01-D03: receiver response and window expiry
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_d01_confirm_receiver_receipt(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_window haulvia.delivery_review_windows%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_token haulvia.receiver_access_tokens%rowtype;
  v_confirmation_id uuid;
  v_resolution_id uuid;
  v_manifest jsonb := p_request -> 'cargoManifest';
  v_responded_at timestamptz := coalesce(
    nullif(p_request ->> 'respondedAt', '')::timestamptz, clock_timestamp()
  );
  v_receiver_label text := haulvia_command.required_text(p_request, 'receiverLabel');
begin
  if p_shipment.shipment_state <> 'DELIVERED' then
    perform haulvia_command.fail('INVALID_STATE', 'confirmReceiverReceipt requires DELIVERED');
  end if;
  v_window := haulvia_command.lock_delivery_review_window(p_shipment.id, p_request);
  v_execution := haulvia_command.lock_resolved_route_execution(v_window, p_request);
  select * into v_stop from haulvia.stop_executions se
  where se.id = v_window.stop_execution_id for update;
  if not v_window.review_required
     or v_stop.state <> 'COMPLETED'
     or v_stop.delivery_verification_state <> 'PENDING_RECEIVER_CONFIRMATION' then
    perform haulvia_command.fail('INVALID_STATE', 'This stop is not awaiting receiver confirmation');
  end if;
  v_token := haulvia_command.authorize_receiver_token(
    v_window, p_request, 'confirmReceipt', v_responded_at
  );
  perform haulvia_command.assert_delivery_cargo_manifest(v_stop.id, v_manifest);

  insert into haulvia.receiver_confirmations (
    shipment_id, stop_execution_id, receiver_access_token_id,
    delivery_review_window_id, verification_state, receiver_label,
    cargo_manifest, response_note, responded_at, idempotency_key
  ) values (
    p_shipment.id, v_stop.id, v_token.id, v_window.id, 'RECEIVER_CONFIRMED',
    v_receiver_label, v_manifest, nullif(p_request ->> 'responseNote', ''),
    v_responded_at, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_confirmation_id;

  insert into haulvia.delivery_review_window_resolutions (
    delivery_review_window_id, stop_execution_id, verification_state,
    resolution_source, receiver_confirmation_id, evidence_snapshot,
    resolved_at, idempotency_key
  ) values (
    v_window.id, v_stop.id, 'RECEIVER_CONFIRMED', 'RECEIVER_RESPONSE',
    v_confirmation_id,
    jsonb_build_object('receiverLabel', v_receiver_label, 'cargoManifest', v_manifest),
    v_responded_at, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_resolution_id;

  update haulvia.receiver_access_tokens set used_at = v_responded_at where id = v_token.id;
  update haulvia.stop_executions
  set delivery_verification_state = 'RECEIVER_CONFIRMED'
  where id = v_stop.id;
  update haulvia.route_executions
  set next_action = case when exists (
        select 1 from haulvia.stop_executions se
        where se.shipment_id = p_shipment.id
          and se.delivery_verification_state in (
            'PENDING_RECEIVER_CONFIRMATION', 'ISSUE_REPORTED', 'EXCEPTION_REVIEW'
          )
      ) then 'AWAIT_DELIVERY_REVIEW' else 'AWAIT_SHIPMENT_COMPLETION' end,
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DELIVERY_VERIFICATION', 'PENDING_RECEIVER_CONFIRMATION',
    'RECEIVER_CONFIRMED', 'confirmReceiverReceipt', p_request, v_stop.id,
    jsonb_build_object('deliveryReviewWindowId', v_window.id, 'receiverConfirmationId', v_confirmation_id)
  );
  perform haulvia_command.append_receiver_audit(
    p_shipment, 'confirmReceiverReceipt', p_request, v_token.id,
    jsonb_build_object('deliveryVerificationState', 'PENDING_RECEIVER_CONFIRMATION'),
    jsonb_build_object('deliveryVerificationState', 'RECEIVER_CONFIRMED'),
    jsonb_build_object('deliveryReviewWindowId', v_window.id, 'receiverConfirmationId', v_confirmation_id)
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'RECEIVER_RECEIPT_CONFIRMED',
    p_request, 'receiver-confirmed-' || v_stop.id::text,
    jsonb_build_object('stopExecutionId', v_stop.id, 'receiverConfirmationId', v_confirmation_id)
  );
  return jsonb_build_object(
    'stopExecutionId', v_stop.id,
    'deliveryReviewWindowId', v_window.id,
    'deliveryReviewResolutionId', v_resolution_id,
    'receiverConfirmationId', v_confirmation_id,
    'deliveryVerificationState', 'RECEIVER_CONFIRMED',
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1
  );
end;
$$;

create or replace function haulvia_command.apply_d02_report_delivery_problem(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_window haulvia.delivery_review_windows%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_token haulvia.receiver_access_tokens%rowtype;
  v_confirmation_id uuid;
  v_resolution_id uuid;
  v_report_id uuid := gen_random_uuid();
  v_manifest jsonb := p_request -> 'cargoManifest';
  v_evidence jsonb := p_request -> 'evidenceManifest';
  v_category text := upper(haulvia_command.required_text(p_request, 'issueCategory'));
  v_description text := haulvia_command.required_text(p_request, 'description');
  v_amount numeric := coalesce(haulvia_command.optional_numeric(p_request, 'disputedAmount'), 0);
  v_responded_at timestamptz := coalesce(
    nullif(p_request ->> 'respondedAt', '')::timestamptz, clock_timestamp()
  );
  v_receiver_label text := haulvia_command.required_text(p_request, 'receiverLabel');
  v_dispute jsonb;
begin
  if p_shipment.shipment_state <> 'DELIVERED' then
    perform haulvia_command.fail('INVALID_STATE', 'reportDeliveryProblem requires DELIVERED');
  end if;
  if not (v_category = any(array['MISSING', 'DAMAGED', 'INCORRECT', 'NOT_RECEIVED'])) then
    perform haulvia_command.fail('INVALID_REQUEST', 'Unsupported delivery problem category');
  end if;
  if jsonb_typeof(v_evidence) <> 'array' or jsonb_array_length(v_evidence) = 0 then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Delivery problem evidence is required');
  end if;
  v_window := haulvia_command.lock_delivery_review_window(p_shipment.id, p_request);
  v_execution := haulvia_command.lock_resolved_route_execution(v_window, p_request);
  select * into v_stop from haulvia.stop_executions se
  where se.id = v_window.stop_execution_id for update;
  if v_stop.delivery_verification_state <> 'PENDING_RECEIVER_CONFIRMATION' then
    perform haulvia_command.fail('INVALID_STATE', 'This stop is not awaiting a receiver response');
  end if;
  v_token := haulvia_command.authorize_receiver_token(
    v_window, p_request, 'reportIssue', v_responded_at
  );
  perform haulvia_command.assert_delivery_cargo_manifest(v_stop.id, v_manifest);

  insert into haulvia.receiver_confirmations (
    shipment_id, stop_execution_id, receiver_access_token_id,
    delivery_review_window_id, verification_state, receiver_label,
    cargo_manifest, issue_category, response_note, responded_at, idempotency_key
  ) values (
    p_shipment.id, v_stop.id, v_token.id, v_window.id, 'ISSUE_REPORTED',
    v_receiver_label, v_manifest, v_category, v_description,
    v_responded_at, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_confirmation_id;

  v_dispute := haulvia_command.open_post_delivery_dispute_record(
    p_shipment, v_stop.id, haulvia_command.optional_uuid(p_request, 'cargoItemId'),
    null, null, v_token.id, 'DELIVERY_' || v_category, v_description,
    v_amount, p_shipment.currency, v_evidence,
    p_request -> 'financialAllocation',
    p_request || jsonb_build_object('commandName', 'reportDeliveryProblem')
  );

  insert into haulvia.delivery_problem_reports (
    id, shipment_id, stop_execution_id, delivery_review_window_id,
    receiver_access_token_id, receiver_confirmation_id, dispute_id,
    financial_hold_id, issue_category, description, cargo_manifest,
    evidence_manifest, disputed_amount, protected_amount, currency,
    reported_at, idempotency_key
  ) values (
    v_report_id, p_shipment.id, v_stop.id, v_window.id, v_token.id,
    v_confirmation_id, (v_dispute ->> 'disputeId')::uuid,
    nullif(v_dispute ->> 'financialHoldId', '')::uuid, v_category,
    v_description, v_manifest, v_evidence, v_amount,
    (v_dispute ->> 'protectedAmount')::numeric, p_shipment.currency,
    v_responded_at, haulvia_command.required_text(p_request, 'idempotencyKey')
  );

  insert into haulvia.delivery_review_window_resolutions (
    delivery_review_window_id, stop_execution_id, verification_state,
    resolution_source, receiver_confirmation_id, dispute_id, evidence_snapshot,
    resolved_at, idempotency_key
  ) values (
    v_window.id, v_stop.id, 'ISSUE_REPORTED', 'RECEIVER_RESPONSE',
    v_confirmation_id, (v_dispute ->> 'disputeId')::uuid,
    jsonb_build_object(
      'issueCategory', v_category, 'cargoManifest', v_manifest,
      'evidenceManifest', v_evidence, 'deliveryProblemReportId', v_report_id
    ), v_responded_at, haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_resolution_id;

  update haulvia.receiver_access_tokens set used_at = v_responded_at where id = v_token.id;
  update haulvia.stop_executions set delivery_verification_state = 'ISSUE_REPORTED'
  where id = v_stop.id;
  update haulvia.route_executions
  set next_action = 'AWAIT_DISPUTE_RESOLUTION', record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DELIVERY_VERIFICATION', 'PENDING_RECEIVER_CONFIRMATION',
    'ISSUE_REPORTED', 'reportDeliveryProblem', p_request, v_stop.id,
    jsonb_build_object('deliveryProblemReportId', v_report_id, 'disputeId', v_dispute ->> 'disputeId')
  );
  perform haulvia_command.append_receiver_audit(
    p_shipment, 'reportDeliveryProblem', p_request, v_token.id,
    jsonb_build_object('deliveryVerificationState', 'PENDING_RECEIVER_CONFIRMATION'),
    jsonb_build_object('deliveryVerificationState', 'ISSUE_REPORTED'),
    jsonb_build_object(
      'deliveryProblemReportId', v_report_id,
      'disputeId', v_dispute ->> 'disputeId',
      'protectedAmount', v_dispute ->> 'protectedAmount'
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'DELIVERY_PROBLEM_REPORTED',
    p_request, 'delivery-problem-' || v_stop.id::text,
    jsonb_build_object('stopExecutionId', v_stop.id, 'disputeId', v_dispute ->> 'disputeId')
  );
  return jsonb_build_object(
    'stopExecutionId', v_stop.id, 'deliveryReviewWindowId', v_window.id,
    'deliveryReviewResolutionId', v_resolution_id,
    'deliveryProblemReportId', v_report_id,
    'receiverConfirmationId', v_confirmation_id,
    'deliveryVerificationState', 'ISSUE_REPORTED',
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1
  ) || v_dispute;
end;
$$;

create or replace function haulvia_command.apply_d03_expire_confirmation_window(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_window haulvia.delivery_review_windows%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_stop haulvia.stop_executions%rowtype;
  v_assessment jsonb := p_request -> 'proofAssessment';
  v_eligible boolean;
  v_review_count integer;
  v_requested_count integer;
  v_state haulvia.delivery_verification_state;
  v_exception_id uuid;
  v_resolution_id uuid;
begin
  if p_shipment.shipment_state <> 'DELIVERED' then
    perform haulvia_command.fail('INVALID_STATE', 'expireConfirmationWindow requires DELIVERED');
  end if;
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    p_request ->> 'workerAuthority', array['RECEIVER_WINDOW_EXPIRY']
  );
  v_window := haulvia_command.lock_delivery_review_window(p_shipment.id, p_request);
  v_execution := haulvia_command.lock_resolved_route_execution(v_window, p_request);
  select * into v_stop from haulvia.stop_executions se
  where se.id = v_window.stop_execution_id for update;
  if v_stop.delivery_verification_state <> 'PENDING_RECEIVER_CONFIRMATION' then
    perform haulvia_command.fail('INVALID_STATE', 'This stop is not awaiting receiver confirmation');
  end if;
  if clock_timestamp() < v_window.expires_at then
    perform haulvia_command.fail('DELIVERY_REVIEW_ACTIVE', 'The configured receiver window has not expired');
  end if;
  if jsonb_typeof(v_assessment) <> 'object' or v_assessment = '{}'::jsonb
     or jsonb_typeof(v_assessment -> 'evidenceReviewIds') <> 'array'
     or not (v_assessment ? 'eligible')
     or nullif(btrim(v_assessment ->> 'reviewerLabel'), '') is null
     or nullif(btrim(v_assessment ->> 'policyRuleCode'), '') is null then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'A structured proof-of-drop assessment is required');
  end if;
  begin
    v_eligible := (v_assessment ->> 'eligible')::boolean;
  exception when invalid_text_representation then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'proofAssessment.eligible must be boolean');
  end;
  select jsonb_array_length(v_assessment -> 'evidenceReviewIds') into v_requested_count;
  select count(distinct er.id) into v_review_count
  from jsonb_array_elements_text(v_assessment -> 'evidenceReviewIds') requested(review_id)
  join haulvia.stop_evidence_reviews er on er.id = requested.review_id::uuid and er.status = 'VERIFIED'
  join haulvia.stop_evidence e on e.id = er.stop_evidence_id
  join haulvia.stop_attempts sa on sa.id = e.stop_attempt_id
  where sa.stop_execution_id = v_stop.id;
  if v_requested_count = 0 or v_review_count <> v_requested_count then
    perform haulvia_command.fail('EVIDENCE_INVALID', 'Proof assessment must reference verified evidence for this stop');
  end if;

  v_state := case when v_eligible then 'VERIFIED_BY_PROOF_OF_DROP'::haulvia.delivery_verification_state
    else 'EXCEPTION_REVIEW'::haulvia.delivery_verification_state end;
  if not v_eligible then
    insert into haulvia.route_exceptions (
      shipment_id, route_execution_id, stop_execution_id, exception_code,
      status, blocks_completion, description, metadata
    ) values (
      p_shipment.id, v_execution.id, v_stop.id,
      'DELIVERY_PROOF_INELIGIBLE_AFTER_WINDOW', 'OPEN', true,
      'Receiver window expired without eligible proof of drop', v_assessment
    ) returning id into v_exception_id;
  end if;

  insert into haulvia.delivery_review_window_resolutions (
    delivery_review_window_id, stop_execution_id, verification_state,
    resolution_source, route_exception_id, evidence_snapshot,
    resolved_at, idempotency_key
  ) values (
    v_window.id, v_stop.id, v_state,
    case when v_eligible then 'PROOF_OF_DROP' else 'WINDOW_EXCEPTION' end,
    v_exception_id,
    v_assessment || jsonb_build_object(
      'windowExpiredAt', v_window.expires_at,
      'receiverConfirmed', false
    ), clock_timestamp(), haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_resolution_id;

  update haulvia.receiver_access_tokens
  set revoked_at = coalesce(revoked_at, clock_timestamp())
  where id = v_window.receiver_access_token_id;
  update haulvia.stop_executions set delivery_verification_state = v_state
  where id = v_stop.id;
  update haulvia.route_executions
  set next_action = case when v_eligible then
        case when exists (
          select 1 from haulvia.stop_executions se
          where se.shipment_id = p_shipment.id and se.id <> v_stop.id
            and se.delivery_verification_state in (
              'PENDING_RECEIVER_CONFIRMATION', 'ISSUE_REPORTED', 'EXCEPTION_REVIEW'
            )
        ) then 'AWAIT_DELIVERY_REVIEW' else 'AWAIT_SHIPMENT_COMPLETION' end
      else 'AWAIT_EVIDENCE_REVIEW' end,
      record_version = record_version + 1
  where id = v_execution.id;
  update haulvia.shipments set updated_at = clock_timestamp() where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DELIVERY_VERIFICATION', 'PENDING_RECEIVER_CONFIRMATION',
    v_state::text, 'expireConfirmationWindow', p_request, v_stop.id,
    jsonb_build_object(
      'deliveryReviewWindowId', v_window.id, 'proofEligible', v_eligible,
      'receiverConfirmed', false, 'routeExceptionId', v_exception_id
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'expireConfirmationWindow', p_request,
    jsonb_build_object('deliveryVerificationState', 'PENDING_RECEIVER_CONFIRMATION'),
    jsonb_build_object('deliveryVerificationState', v_state),
    jsonb_build_object(
      'deliveryReviewWindowId', v_window.id, 'proofAssessment', v_assessment,
      'receiverConfirmed', false, 'routeExceptionId', v_exception_id
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id,
    case when v_eligible then 'DELIVERY_WINDOW_EXPIRED_PROOF_VERIFIED'
      else 'DELIVERY_WINDOW_EXPIRED_REVIEW_REQUIRED' end,
    p_request, 'delivery-window-expired-' || v_stop.id::text,
    jsonb_build_object(
      'stopExecutionId', v_stop.id, 'verificationState', v_state,
      'receiverConfirmed', false
    )
  );
  return jsonb_build_object(
    'stopExecutionId', v_stop.id, 'deliveryReviewWindowId', v_window.id,
    'deliveryReviewResolutionId', v_resolution_id,
    'deliveryVerificationState', v_state, 'proofEligible', v_eligible,
    'receiverConfirmed', false, 'routeExceptionId', v_exception_id,
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1
  );
exception when invalid_text_representation then
  perform haulvia_command.fail('EVIDENCE_INVALID', 'Proof assessment contains an invalid evidence review UUID');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- D04: customer/provider post-delivery dispute
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_d04_open_post_delivery_dispute(
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
  v_stop_id uuid := haulvia_command.optional_uuid(p_request, 'stopExecutionId');
  v_cargo_id uuid := haulvia_command.optional_uuid(p_request, 'cargoItemId');
  v_amount numeric := haulvia_command.required_numeric(p_request, 'disputedAmount');
  v_category text := upper(haulvia_command.required_text(p_request, 'categoryCode'));
  v_description text := haulvia_command.required_text(p_request, 'description');
  v_is_customer boolean := false;
  v_is_provider boolean := false;
  v_result jsonb;
begin
  if p_shipment.shipment_state not in ('DELIVERED', 'COMPLETED') then
    perform haulvia_command.fail('INVALID_STATE', 'Post-delivery disputes require DELIVERED or COMPLETED');
  end if;
  select * into v_assignment
  from haulvia.assignments a
  where a.id = haulvia_command.required_uuid(p_request, 'expectedAssignmentId')
    and a.shipment_id = p_shipment.id
    and a.status in ('ACTIVE', 'COMPLETED')
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
      where sp.id = v_provider_id and om.profile_id = v_actor and om.status = 'ACTIVE'
        and (om.ends_at is null or om.ends_at > clock_timestamp())
    )
  );
  if not v_is_customer and not v_is_provider then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'Only the owning customer or assigned provider may open this dispute');
  end if;

  v_result := haulvia_command.open_post_delivery_dispute_record(
    p_shipment, v_stop_id, v_cargo_id,
    case when v_is_customer then v_actor end,
    case when v_is_provider then v_provider_id end,
    null, v_category, v_description, v_amount, p_shipment.currency,
    p_request -> 'evidenceManifest', p_request -> 'financialAllocation',
    p_request || jsonb_build_object('commandName', 'openPostDeliveryDispute')
  );

  perform haulvia_command.append_audit(
    p_shipment, 'openPostDeliveryDispute', p_request,
    jsonb_build_object('shipmentState', p_shipment.shipment_state),
    jsonb_build_object('shipmentState', p_shipment.shipment_state),
    jsonb_build_object(
      'disputeId', v_result ->> 'disputeId',
      'financialHoldId', v_result ->> 'financialHoldId',
      'protectedAmount', v_result ->> 'protectedAmount',
      'operationalStateUnchanged', true
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'POST_DELIVERY_DISPUTE_OPENED',
    p_request, 'post-delivery-dispute-' || (v_result ->> 'disputeId'),
    jsonb_build_object(
      'disputeId', v_result ->> 'disputeId',
      'protectedAmount', v_result ->> 'protectedAmount'
    )
  );
  return v_result || jsonb_build_object(
    'shipmentState', p_shipment.shipment_state,
    'operationalStateUnchanged', true,
    'assignmentId', v_assignment.id
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- D05: irreversible operational completion plus independent payout eligibility
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_d05_complete_shipment(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_resolution haulvia.route_resolution_records%rowtype;
  v_execution haulvia.route_executions%rowtype;
  v_assignment haulvia.assignments%rowtype;
  v_price haulvia.shipment_price_snapshots%rowtype;
  v_rules haulvia.shipment_rule_snapshots%rowtype;
  v_allocation jsonb := p_request -> 'payoutAllocation';
  v_release jsonb := p_request -> 'releaseAuthorization';
  v_gross numeric;
  v_fee numeric;
  v_adjustment numeric;
  v_net numeric;
  v_hold numeric(14,2);
  v_state haulvia.driver_payout_state;
  v_prior_payout_state haulvia.driver_payout_state;
  v_eligibility_id uuid;
  v_payout_id uuid;
  v_completion_id uuid;
  v_review_summary jsonb;
  v_route_allocation jsonb;
begin
  if p_shipment.shipment_state <> 'DELIVERED' then
    perform haulvia_command.fail('INVALID_STATE', 'completeShipment requires DELIVERED');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'SHIPMENT_STATE_OVERRIDE', array['COMPLETION_WORKER']
  );
  if jsonb_typeof(v_release) <> 'object' or v_release = '{}'::jsonb
     or nullif(btrim(v_release ->> 'authorizationCode'), '') is null
     or nullif(btrim(v_release ->> 'authorizedReason'), '') is null then
    perform haulvia_command.fail(
      'RELEASE_AUTHORIZATION_REQUIRED',
      'Completion requires a retained release authorization code and reason'
    );
  end if;
  if jsonb_typeof(v_allocation) <> 'object' or v_allocation = '{}'::jsonb
     or nullif(btrim(v_allocation ->> 'calculationVersion'), '') is null then
    perform haulvia_command.fail('PAYOUT_ALLOCATION_INVALID', 'A versioned payout allocation is required');
  end if;

  select * into v_resolution
  from haulvia.route_resolution_records rr
  where rr.shipment_id = p_shipment.id
    and rr.id = haulvia_command.required_uuid(p_request, 'expectedRouteResolutionRecordId');
  if not found then
    perform haulvia_command.fail('ROUTE_NOT_RESOLVED', 'The immutable route resolution record was not found');
  end if;
  select * into v_execution
  from haulvia.route_executions re
  where re.id = v_resolution.route_execution_id
    and re.id = haulvia_command.required_uuid(p_request, 'expectedRouteExecutionId')
    and re.shipment_id = p_shipment.id
  for update;
  if not found or v_execution.state <> 'COMPLETED' then
    perform haulvia_command.fail('ROUTE_NOT_RESOLVED', 'The whole route execution is not complete');
  end if;
  if v_execution.record_version <>
     haulvia_command.required_text(p_request, 'expectedRouteExecutionVersion')::bigint then
    perform haulvia_command.fail('STALE_ROUTE_EXECUTION_VERSION', 'The completed route record changed');
  end if;
  select * into v_assignment
  from haulvia.assignments a
  where a.id = haulvia_command.required_uuid(p_request, 'expectedAssignmentId')
    and a.id = v_execution.assignment_id
    and a.shipment_id = p_shipment.id and a.status = 'ACTIVE'
  for update;
  if not found then
    perform haulvia_command.fail('ASSIGNMENT_NOT_ACTIVE', 'The retained whole-route assignment is not active');
  end if;
  select * into v_price
  from haulvia.shipment_price_snapshots sps
  where sps.id = v_assignment.price_snapshot_id
    and sps.id = haulvia_command.required_uuid(p_request, 'expectedPriceSnapshotId')
    and sps.shipment_id = p_shipment.id;
  if not found then
    perform haulvia_command.fail('PAYOUT_ALLOCATION_INVALID', 'The accepted assignment price snapshot was not found');
  end if;
  select * into v_rules
  from haulvia.shipment_rule_snapshots srs
  where srs.shipment_id = p_shipment.id
    and srs.route_version_id = v_execution.route_version_id;
  if not found then
    perform haulvia_command.fail('POLICY_SNAPSHOT_REQUIRED', 'The route policy snapshot was not found');
  end if;

  if exists (
    select 1
    from haulvia.stop_executions se
    join haulvia.route_stops rs
      on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
    where se.shipment_id = p_shipment.id and rs.stop_type = 'DELIVERY'
      and (
        se.state <> 'COMPLETED'
        or se.delivery_verification_state in (
          'PENDING_RECEIVER_CONFIRMATION', 'ISSUE_REPORTED', 'EXCEPTION_REVIEW'
        )
        or not exists (
          select 1
          from haulvia.delivery_review_windows drw
          join haulvia.delivery_review_window_resolutions drwr
            on drwr.delivery_review_window_id = drw.id
          where drw.stop_execution_id = se.id
            and drwr.verification_state in (
              'NOT_REQUIRED', 'RECEIVER_CONFIRMED', 'VERIFIED_BY_PROOF_OF_DROP'
            )
        )
        or not exists (
          select 1
          from haulvia.stop_attempts sa
          join haulvia.stop_evidence e on e.stop_attempt_id = sa.id
          join haulvia.stop_evidence_reviews er
            on er.stop_evidence_id = e.id and er.status = 'VERIFIED'
          where sa.stop_execution_id = se.id
        )
      )
  ) then
    perform haulvia_command.fail(
      'DELIVERY_REVIEW_UNRESOLVED',
      'Every delivery evidence package and applicable receiver window must resolve first'
    );
  end if;
  if exists (
    select 1 from haulvia.workflow_holds wh
    where wh.shipment_id = p_shipment.id and wh.status = 'ACTIVE' and wh.blocks_completion
  ) or exists (
    select 1 from haulvia.route_exceptions re
    where re.shipment_id = p_shipment.id and re.blocks_completion
      and re.status not in ('RESOLVED', 'CLOSED')
  ) then
    perform haulvia_command.fail('WORKFLOW_HELD', 'An unresolved physical-workflow exception blocks completion');
  end if;
  if exists (
    select 1 from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id = p_shipment.id and cb.onboard_quantity <> 0
  ) then
    perform haulvia_command.fail('CARGO_BALANCE_INVALID', 'Cargo custody must reconcile before completion');
  end if;

  v_gross := haulvia_command.required_numeric(v_allocation, 'grossAmount');
  v_fee := haulvia_command.required_numeric(v_allocation, 'platformFeeAmount');
  v_adjustment := haulvia_command.required_numeric(v_allocation, 'adjustmentAmount');
  v_net := haulvia_command.required_numeric(v_allocation, 'netAmount');
  if v_gross < 0 or v_fee < 0 or v_net < 0
     or v_net <> v_gross - v_fee + v_adjustment
     or v_gross > v_price.total_amount
     or upper(coalesce(nullif(v_allocation ->> 'currency', ''), p_shipment.currency)) <> p_shipment.currency then
    perform haulvia_command.fail(
      'PAYOUT_ALLOCATION_INVALID',
      'Payout amounts must reconcile to the accepted route price and shipment currency'
    );
  end if;

  select least(coalesce(sum(fh.amount), 0), v_net) into v_hold
  from haulvia.financial_holds fh
  where fh.shipment_id = p_shipment.id and fh.status = 'ACTIVE';
  v_state := case when v_hold > 0 then 'HELD'::haulvia.driver_payout_state
    else 'READY'::haulvia.driver_payout_state end;

  select jsonb_build_object(
    'deliveryStopCount', count(*),
    'resolvedWindowCount', count(drwr.id),
    'states', coalesce(jsonb_agg(jsonb_build_object(
      'stopExecutionId', se.id,
      'verificationState', se.delivery_verification_state,
      'deliveryReviewWindowId', drw.id,
      'deliveryReviewResolutionId', drwr.id
    ) order by rs.sequence_no), '[]'::jsonb)
  ) into v_review_summary
  from haulvia.stop_executions se
  join haulvia.route_stops rs
    on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
  left join haulvia.delivery_review_windows drw on drw.stop_execution_id = se.id
  left join haulvia.delivery_review_window_resolutions drwr
    on drwr.delivery_review_window_id = drw.id
  where se.shipment_id = p_shipment.id and rs.stop_type = 'DELIVERY';

  select jsonb_build_object(
    'routeResolutionRecordId', v_resolution.id,
    'publicOutcomeLabel', v_resolution.public_outcome_label,
    'outcomeSummary', v_resolution.outcome_summary,
    'priceSnapshotId', v_price.id,
    'priceTotalAmount', v_price.total_amount,
    'currency', v_price.currency
  ) into v_route_allocation;

  insert into haulvia.payout_eligibility_records (
    shipment_id, assignment_id, route_resolution_record_id, price_snapshot_id,
    policy_version_id, eligibility_state, gross_amount, platform_fee_amount,
    adjustment_amount, net_amount, protected_hold_amount, releasable_amount,
    currency, route_allocation_snapshot, evidence_window_snapshot,
    policy_snapshot, release_authorization, authorized_by_profile_id,
    idempotency_key
  ) values (
    p_shipment.id, v_assignment.id, v_resolution.id, v_price.id,
    v_rules.policy_version_id, v_state, v_gross, v_fee, v_adjustment, v_net,
    v_hold, v_net - v_hold, p_shipment.currency, v_route_allocation,
    v_review_summary,
    jsonb_build_object(
      'policyVersionId', v_rules.policy_version_id,
      'configSha256', v_rules.config_sha256,
      'timingWindows', v_rules.timing_windows,
      'refundRules', v_rules.refund_rules
    ), v_release, haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_eligibility_id;

  insert into haulvia.driver_payouts (
    shipment_id, assignment_id, provider_id, driver_id, state,
    gross_amount, platform_fee_amount, adjustment_amount, net_amount,
    currency, payout_eligibility_record_id
  ) values (
    p_shipment.id, v_assignment.id, v_assignment.provider_id, v_assignment.driver_id,
    v_state, v_gross, v_fee, v_adjustment, v_net, p_shipment.currency, v_eligibility_id
  ) returning id into v_payout_id;

  insert into haulvia.shipment_completion_records (
    shipment_id, route_execution_id, route_resolution_record_id, assignment_id,
    payout_id, payout_eligibility_record_id, release_authorization,
    verification_summary, financial_summary, completed_by_profile_id,
    idempotency_key
  ) values (
    p_shipment.id, v_execution.id, v_resolution.id, v_assignment.id,
    v_payout_id, v_eligibility_id, v_release, v_review_summary,
    jsonb_build_object(
      'fundDisposition', 'HELD_FOR_PAYOUT',
      'driverPayoutState', v_state,
      'netAmount', v_net,
      'protectedHoldAmount', v_hold,
      'releasableAmount', v_net - v_hold,
      'currency', p_shipment.currency
    ), haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_text(p_request, 'idempotencyKey')
  ) returning id into v_completion_id;

  update haulvia.assignments
  set status = 'COMPLETED', ended_at = clock_timestamp(), end_reason = 'ROUTE_COMPLETED'
  where id = v_assignment.id;
  update haulvia.route_executions
  set next_action = case when v_state = 'HELD' then 'REVIEW_PAYOUT_HOLD'
      else 'SUBMIT_DRIVER_PAYOUT' end,
      record_version = record_version + 1
  where id = v_execution.id;
  select state into v_prior_payout_state
  from haulvia.shipment_driver_payout_axes
  where shipment_id = p_shipment.id for update;
  update haulvia.shipment_driver_payout_axes
  set state = v_state, eligible_amount = v_net, currency = p_shipment.currency,
      state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  update haulvia.shipments set shipment_state = 'COMPLETED' where id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DRIVER_PAYOUT', v_prior_payout_state::text, v_state::text,
    'completeShipment', p_request, v_payout_id,
    jsonb_build_object(
      'payoutEligibilityRecordId', v_eligibility_id,
      'protectedHoldAmount', v_hold,
      'fundDisposition', 'HELD_FOR_PAYOUT'
    )
  );
  perform haulvia_command.append_shipment_event(
    p_shipment.id, 'DELIVERED', 'COMPLETED', 'completeShipment', p_request,
    v_execution.route_version_id,
    jsonb_build_object(
      'shipmentCompletionRecordId', v_completion_id,
      'payoutId', v_payout_id, 'driverPayoutState', v_state
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'completeShipment', p_request,
    jsonb_build_object('shipmentState', 'DELIVERED'),
    jsonb_build_object('shipmentState', 'COMPLETED'),
    jsonb_build_object(
      'shipmentCompletionRecordId', v_completion_id,
      'payoutEligibilityRecordId', v_eligibility_id,
      'payoutId', v_payout_id, 'releaseAuthorization', v_release
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'SHIPMENT_COMPLETED',
    p_request, 'shipment-completed',
    jsonb_build_object(
      'shipmentCompletionRecordId', v_completion_id,
      'driverPayoutState', v_state, 'fundDisposition', 'HELD_FOR_PAYOUT'
    )
  );
  return jsonb_build_object(
    'shipmentState', 'COMPLETED', 'shipmentCompletionRecordId', v_completion_id,
    'payoutEligibilityRecordId', v_eligibility_id, 'payoutId', v_payout_id,
    'driverPayoutState', v_state, 'netAmount', v_net,
    'protectedHoldAmount', v_hold, 'releasableAmount', v_net - v_hold,
    'fundDisposition', 'HELD_FOR_PAYOUT',
    'routeExecutionId', v_execution.id,
    'routeExecutionVersion', v_execution.record_version + 1
  );
exception when invalid_text_representation then
  perform haulvia_command.fail('INVALID_REQUEST', 'Completion request contains an invalid numeric or version value');
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- D06-D08: payout request and provider outcomes
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_d06_submit_driver_payout(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_payout haulvia.driver_payouts%rowtype;
  v_amount numeric := haulvia_command.required_numeric(p_request, 'payoutAmount');
  v_paid numeric(14,2);
  v_pending numeric(14,2);
  v_held numeric(14,2);
  v_available numeric(14,2);
  v_provider text := haulvia_command.required_text(p_request, 'externalProvider');
  v_provider_key text := haulvia_command.required_text(p_request, 'providerIdempotencyKey');
  v_account text := haulvia_command.required_text(p_request, 'payoutAccountReference');
  v_existing haulvia.payout_transactions%rowtype;
  v_transaction_id uuid;
  v_prior_state haulvia.driver_payout_state;
begin
  if p_shipment.shipment_state <> 'COMPLETED' then
    perform haulvia_command.fail('INVALID_STATE', 'submitDriverPayout requires COMPLETED');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'PAYOUT_MANAGE', array['PAYOUT_WORKER']
  );
  if not haulvia_command.required_boolean(p_request, 'payoutAccountValid') then
    perform haulvia_command.fail('PAYOUT_ACCOUNT_INVALID', 'A current valid provider payout account is required');
  end if;
  select * into v_payout
  from haulvia.driver_payouts dp
  where dp.id = haulvia_command.required_uuid(p_request, 'expectedPayoutId')
    and dp.shipment_id = p_shipment.id
  for update;
  if not found or v_payout.payout_eligibility_record_id is null then
    perform haulvia_command.fail('PAYOUT_NOT_ELIGIBLE', 'The whole-route payout eligibility record was not found');
  end if;
  if v_payout.state = 'PAID' then
    perform haulvia_command.fail('PAYOUT_ALREADY_PAID', 'The whole route payout is already paid');
  end if;

  select * into v_existing
  from haulvia.payout_transactions pt
  where pt.payout_id = v_payout.id and pt.idempotency_key = v_provider_key;
  if found then
    if v_existing.status <> 'PENDING' or v_existing.amount <> v_amount
       or v_existing.external_provider <> v_provider then
      perform haulvia_command.fail('IDEMPOTENCY_KEY_REUSED', 'Provider payout key was reused with different details');
    end if;
    return jsonb_build_object(
      'payoutId', v_payout.id, 'payoutTransactionId', v_existing.id,
      'driverPayoutState', v_payout.state, 'payoutAmount', v_existing.amount,
      'duplicateProviderRequest', true
    );
  end if;

  select coalesce(sum(pt.amount), 0) into v_paid
  from haulvia.payout_transactions pt
  where pt.payout_id = v_payout.id and pt.status = 'SUCCEEDED';
  select coalesce(sum(pt.amount), 0) into v_pending
  from haulvia.payout_transactions pt
  where pt.payout_id = v_payout.id and pt.status = 'PENDING'
    and not exists (
      select 1 from haulvia.payout_transactions outcome
      where outcome.request_transaction_id = pt.id
    );
  select coalesce(sum(fh.amount), 0) into v_held
  from haulvia.financial_holds fh
  where fh.shipment_id = p_shipment.id and fh.status = 'ACTIVE';
  v_available := greatest(v_payout.net_amount - v_paid - v_pending - v_held, 0);
  if v_amount <= 0 or v_amount > v_available then
    perform haulvia_command.fail(
      'PAYOUT_AMOUNT_UNAVAILABLE',
      'Payout request exceeds the eligible amount after paid, pending, and disputed allocations',
      jsonb_build_object(
        'netAmount', v_payout.net_amount, 'paidAmount', v_paid,
        'pendingAmount', v_pending, 'heldAmount', v_held,
        'availableAmount', v_available
      )
    );
  end if;

  insert into haulvia.payout_transactions (
    payout_id, status, amount, currency, external_provider,
    external_reference, response_payload, idempotency_key, allocation_snapshot
  ) values (
    v_payout.id, 'PENDING', v_amount, v_payout.currency, v_provider,
    nullif(p_request ->> 'externalReference', ''),
    jsonb_build_object(
      'requestSubmitted', true, 'payoutAccountReference', v_account,
      'providerRequest', coalesce(p_request -> 'providerRequest', '{}'::jsonb)
    ), v_provider_key,
    jsonb_build_object(
      'routeNetAmount', v_payout.net_amount, 'paidBefore', v_paid,
      'pendingBefore', v_pending, 'protectedHoldAmount', v_held,
      'submittedAmount', v_amount, 'remainingAfterSubmission', v_available - v_amount
    )
  ) returning id into v_transaction_id;

  v_prior_state := v_payout.state;
  update haulvia.driver_payouts
  set state = 'PROCESSING', state_changed_at = clock_timestamp()
  where id = v_payout.id;
  update haulvia.shipment_driver_payout_axes
  set state = 'PROCESSING', state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;
  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DRIVER_PAYOUT', v_prior_state::text, 'PROCESSING',
    'submitDriverPayout', p_request, v_payout.id,
    jsonb_build_object(
      'payoutTransactionId', v_transaction_id, 'submittedAmount', v_amount,
      'providerIdempotencyKey', v_provider_key
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, 'submitDriverPayout', p_request,
    jsonb_build_object('driverPayoutState', v_prior_state),
    jsonb_build_object('driverPayoutState', 'PROCESSING'),
    jsonb_build_object(
      'payoutId', v_payout.id, 'payoutTransactionId', v_transaction_id,
      'amount', v_amount, 'allocation', jsonb_build_object(
        'paidBefore', v_paid, 'pendingBefore', v_pending,
        'protectedHoldAmount', v_held, 'availableBefore', v_available
      )
    )
  );
  return jsonb_build_object(
    'payoutId', v_payout.id, 'payoutTransactionId', v_transaction_id,
    'driverPayoutState', 'PROCESSING', 'payoutAmount', v_amount,
    'remainingEligibleAmount', v_available - v_amount,
    'duplicateProviderRequest', false
  );
end;
$$;

create or replace function haulvia_command.apply_payout_provider_outcome(
  p_shipment haulvia.shipments,
  p_request jsonb,
  p_succeeded boolean
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_payout haulvia.driver_payouts%rowtype;
  v_request_tx haulvia.payout_transactions%rowtype;
  v_existing haulvia.payout_transactions%rowtype;
  v_amount numeric := haulvia_command.required_numeric(p_request, 'payoutAmount');
  v_provider text := haulvia_command.required_text(p_request, 'externalProvider');
  v_event text := haulvia_command.required_text(p_request, 'providerEventId');
  v_reference text := haulvia_command.required_text(p_request, 'externalReference');
  v_result_tx uuid;
  v_paid numeric(14,2);
  v_pending numeric(14,2);
  v_held numeric(14,2);
  v_new_state haulvia.driver_payout_state;
  v_prior_state haulvia.driver_payout_state;
  v_command text := case when p_succeeded then 'confirmDriverPayout' else 'handlePayoutFailure' end;
  v_status haulvia.transaction_status := case when p_succeeded then 'SUCCEEDED' else 'FAILED' end;
begin
  if p_shipment.shipment_state <> 'COMPLETED' then
    perform haulvia_command.fail('INVALID_STATE', 'Payout provider outcomes require COMPLETED');
  end if;
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(p_request, 'actorProfileId'),
    p_request ->> 'workerAuthority', array['PAYOUT_PROVIDER_CALLBACK']
  );
  select * into v_payout
  from haulvia.driver_payouts dp
  where dp.id = haulvia_command.required_uuid(p_request, 'expectedPayoutId')
    and dp.shipment_id = p_shipment.id
  for update;
  if not found then
    perform haulvia_command.fail('PAYOUT_NOT_FOUND', 'Driver payout was not found');
  end if;

  select * into v_existing
  from haulvia.payout_transactions pt
  where pt.external_provider = v_provider and pt.provider_event_id = v_event;
  if found then
    if v_existing.payout_id <> v_payout.id or v_existing.status <> v_status
       or v_existing.amount <> v_amount then
      perform haulvia_command.fail('PROVIDER_EVENT_CONFLICT', 'Provider event was already committed with different facts');
    end if;
    return jsonb_build_object(
      'payoutId', v_payout.id, 'payoutTransactionId', v_existing.id,
      'driverPayoutState', v_payout.state, 'providerEventId', v_event,
      'duplicateProviderEvent', true, 'shipmentState', p_shipment.shipment_state
    );
  end if;

  select * into v_request_tx
  from haulvia.payout_transactions pt
  where pt.id = haulvia_command.required_uuid(p_request, 'payoutRequestTransactionId')
    and pt.payout_id = v_payout.id and pt.status = 'PENDING'
  for update;
  if not found or v_request_tx.external_provider <> v_provider
     or v_request_tx.amount <> v_amount
     or exists (
       select 1 from haulvia.payout_transactions outcome
       where outcome.request_transaction_id = v_request_tx.id
     ) then
    perform haulvia_command.fail('PAYOUT_REQUEST_MISMATCH', 'Provider outcome does not match an outstanding payout request');
  end if;

  insert into haulvia.payout_transactions (
    payout_id, request_transaction_id, status, amount, currency,
    external_provider, external_reference, provider_event_id,
    response_payload, idempotency_key, occurred_at, allocation_snapshot
  ) values (
    v_payout.id, v_request_tx.id, v_status, v_amount, v_payout.currency,
    v_provider, v_reference, v_event,
    coalesce(p_request -> 'providerResponse', '{}'::jsonb),
    'provider-event:' || v_event,
    coalesce(nullif(p_request ->> 'providerOccurredAt', '')::timestamptz, clock_timestamp()),
    v_request_tx.allocation_snapshot
  ) returning id into v_result_tx;

  select coalesce(sum(pt.amount), 0) into v_paid
  from haulvia.payout_transactions pt
  where pt.payout_id = v_payout.id and pt.status = 'SUCCEEDED';
  select coalesce(sum(pt.amount), 0) into v_pending
  from haulvia.payout_transactions pt
  where pt.payout_id = v_payout.id and pt.status = 'PENDING'
    and not exists (
      select 1 from haulvia.payout_transactions outcome
      where outcome.request_transaction_id = pt.id
    );
  select coalesce(sum(fh.amount), 0) into v_held
  from haulvia.financial_holds fh
  where fh.shipment_id = p_shipment.id and fh.status = 'ACTIVE';
  if v_paid > v_payout.net_amount then
    perform haulvia_command.fail('PAYOUT_AMOUNT_INVALID', 'Provider outcomes exceed the route payout total');
  end if;

  if p_succeeded then
    v_new_state := case
      when v_paid = v_payout.net_amount then 'PAID'::haulvia.driver_payout_state
      when v_pending > 0 then 'PROCESSING'::haulvia.driver_payout_state
      when v_held > 0 then 'HELD'::haulvia.driver_payout_state
      else 'READY'::haulvia.driver_payout_state end;
  else
    v_new_state := case when v_pending > 0 then 'PROCESSING'::haulvia.driver_payout_state
      else 'FAILED'::haulvia.driver_payout_state end;
  end if;
  v_prior_state := v_payout.state;
  update haulvia.driver_payouts
  set state = v_new_state, state_changed_at = clock_timestamp()
  where id = v_payout.id;
  update haulvia.shipment_driver_payout_axes
  set state = v_new_state, state_changed_at = clock_timestamp()
  where shipment_id = p_shipment.id;

  perform haulvia_command.append_axis_event(
    p_shipment.id, 'DRIVER_PAYOUT', v_prior_state::text, v_new_state::text,
    v_command, p_request, v_payout.id,
    jsonb_build_object(
      'payoutRequestTransactionId', v_request_tx.id,
      'payoutTransactionId', v_result_tx, 'providerEventId', v_event,
      'amount', v_amount, 'paidAmount', v_paid,
      'pendingAmount', v_pending, 'protectedHoldAmount', v_held
    )
  );
  perform haulvia_command.append_audit(
    p_shipment, v_command, p_request,
    jsonb_build_object('shipmentState', p_shipment.shipment_state, 'driverPayoutState', v_prior_state),
    jsonb_build_object('shipmentState', p_shipment.shipment_state, 'driverPayoutState', v_new_state),
    jsonb_build_object(
      'payoutId', v_payout.id, 'payoutTransactionId', v_result_tx,
      'providerEventId', v_event, 'externalReference', v_reference,
      'amount', v_amount, 'operationalStateUnchanged', true
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, null,
    case when p_succeeded then 'DRIVER_PAYOUT_CONFIRMED' else 'DRIVER_PAYOUT_FAILED' end,
    p_request, lower(v_command) || '-' || v_payout.id::text,
    jsonb_build_object(
      'payoutId', v_payout.id, 'payoutTransactionId', v_result_tx,
      'driverPayoutState', v_new_state, 'amount', v_amount
    )
  );
  return jsonb_build_object(
    'payoutId', v_payout.id, 'payoutRequestTransactionId', v_request_tx.id,
    'payoutTransactionId', v_result_tx, 'driverPayoutState', v_new_state,
    'payoutAmount', v_amount, 'paidAmount', v_paid,
    'pendingAmount', v_pending, 'protectedHoldAmount', v_held,
    'providerEventId', v_event, 'externalReference', v_reference,
    'duplicateProviderEvent', false, 'shipmentState', p_shipment.shipment_state,
    'operationalStateUnchanged', true
  );
end;
$$;

create or replace function haulvia_command.apply_d07_confirm_driver_payout(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language sql
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_payout_provider_outcome(p_shipment, p_request, true);
$$;

create or replace function haulvia_command.apply_d08_handle_payout_failure(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language sql
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_payout_provider_outcome(p_shipment, p_request, false);
$$;

-- ---------------------------------------------------------------------------
-- D09: separately authorized refund, charge, credit, or driver adjustment
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.apply_d09_issue_refund_or_adjustment(
  p_shipment haulvia.shipments,
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_type haulvia.financial_adjustment_type;
  v_status haulvia.transaction_status;
  v_amount numeric := haulvia_command.required_numeric(p_request, 'amount');
  v_provider text := haulvia_command.required_text(p_request, 'externalProvider');
  v_provider_key text := haulvia_command.required_text(p_request, 'providerIdempotencyKey');
  v_provider_event text := nullif(p_request ->> 'providerEventId', '');
  v_external_reference text := nullif(p_request ->> 'externalReference', '');
  v_reason text := haulvia_command.required_text(p_request, 'reason');
  v_route_execution_id uuid := haulvia_command.optional_uuid(p_request, 'routeExecutionId');
  v_stop_id uuid := haulvia_command.optional_uuid(p_request, 'stopExecutionId');
  v_cargo_id uuid := haulvia_command.optional_uuid(p_request, 'cargoItemId');
  v_payment_intent haulvia.payment_intents%rowtype;
  v_payout haulvia.driver_payouts%rowtype;
  v_payment_tx_id uuid;
  v_payout_tx_id uuid;
  v_adjustment_id uuid;
  v_existing_adjustment haulvia.financial_adjustments%rowtype;
  v_prior_payment_state haulvia.customer_payment_state;
  v_new_payment_state haulvia.customer_payment_state;
  v_prior_payout_state haulvia.driver_payout_state;
  v_refunded numeric(14,2);
  v_new_payout_state haulvia.driver_payout_state;
begin
  if p_shipment.shipment_state not in ('DELIVERED', 'COMPLETED') then
    perform haulvia_command.fail('INVALID_STATE', 'Financial delivery adjustments require DELIVERED or COMPLETED');
  end if;
  perform haulvia_command.assert_sensitive_command_authority(
    p_request, 'FINANCIAL_ADJUST', array[]::text[]
  );
  begin
    v_type := upper(haulvia_command.required_text(p_request, 'adjustmentType'))::haulvia.financial_adjustment_type;
    v_status := upper(haulvia_command.required_text(p_request, 'providerStatus'))::haulvia.transaction_status;
  exception when invalid_text_representation then
    perform haulvia_command.fail('INVALID_REQUEST', 'Adjustment type or provider status is invalid');
  end;
  if v_amount <= 0 or upper(haulvia_command.required_text(p_request, 'currency')) <> p_shipment.currency then
    perform haulvia_command.fail('FINANCIAL_ALLOCATION_INVALID', 'Adjustment amount and currency are invalid');
  end if;
  if v_status <> 'PENDING' and (v_provider_event is null or v_external_reference is null) then
    perform haulvia_command.fail(
      'PROVIDER_RESULT_INVALID',
      'A completed provider result requires event and external references'
    );
  end if;
  if v_route_execution_id is not null and not exists (
    select 1 from haulvia.route_executions re
    where re.id = v_route_execution_id and re.shipment_id = p_shipment.id
  ) then
    perform haulvia_command.fail('ROUTE_NOT_RESOLVED', 'Adjustment route does not belong to the shipment');
  end if;
  if v_stop_id is not null and not exists (
    select 1 from haulvia.stop_executions se
    where se.id = v_stop_id and se.shipment_id = p_shipment.id
  ) then
    perform haulvia_command.fail('STOP_NOT_CURRENT', 'Adjustment stop does not belong to the shipment');
  end if;
  if v_cargo_id is not null and not exists (
    select 1 from haulvia.cargo_items ci
    join haulvia.route_versions rv on rv.id = ci.route_version_id
    where ci.id = v_cargo_id and rv.shipment_id = p_shipment.id
  ) then
    perform haulvia_command.fail('CARGO_REFERENCE_INVALID', 'Adjustment cargo does not belong to the shipment');
  end if;
  if jsonb_typeof(p_request -> 'authorizationSnapshot') <> 'object'
     or p_request -> 'authorizationSnapshot' = '{}'::jsonb then
    perform haulvia_command.fail('NOT_AUTHORIZED', 'A retained financial authorization snapshot is required');
  end if;
  if v_type = 'CUSTOMER_CHARGE' and (
    not haulvia_command.required_boolean(p_request, 'customerApproved')
    or jsonb_typeof(p_request -> 'customerApproval') <> 'object'
    or p_request -> 'customerApproval' = '{}'::jsonb
  ) then
    perform haulvia_command.fail(
      'CUSTOMER_APPROVAL_REQUIRED',
      'Additional customer charges require explicit retained customer approval'
    );
  end if;

  select * into v_existing_adjustment
  from haulvia.financial_adjustments fa
  where fa.shipment_id = p_shipment.id and fa.idempotency_key = v_provider_key;
  if found then
    if v_existing_adjustment.adjustment_type <> v_type
       or v_existing_adjustment.amount <> v_amount then
      perform haulvia_command.fail('IDEMPOTENCY_KEY_REUSED', 'Provider adjustment key was reused with different details');
    end if;
    return jsonb_build_object(
      'financialAdjustmentId', v_existing_adjustment.id,
      'paymentTransactionId', v_existing_adjustment.payment_transaction_id,
      'payoutTransactionId', v_existing_adjustment.payout_transaction_id,
      'adjustmentType', v_existing_adjustment.adjustment_type,
      'amount', v_existing_adjustment.amount,
      'providerStatus', v_status,
      'duplicateProviderRequest', true,
      'shipmentState', p_shipment.shipment_state
    );
  end if;

  if v_type in ('CUSTOMER_CHARGE', 'CUSTOMER_REFUND', 'CUSTOMER_CREDIT') then
    select * into v_payment_intent
    from haulvia.payment_intents pi
    where pi.id = haulvia_command.required_uuid(p_request, 'paymentIntentId')
      and pi.shipment_id = p_shipment.id
    for update;
    if not found then
      perform haulvia_command.fail('PAYMENT_NOT_FOUND', 'The retained customer payment intent was not found');
    end if;
    if v_type = 'CUSTOMER_REFUND' then
      select coalesce(sum(pt.amount), 0) into v_refunded
      from haulvia.payment_transactions pt
      where pt.payment_intent_id = v_payment_intent.id
        and pt.transaction_type = 'REFUND' and pt.status = 'SUCCEEDED';
      if v_refunded + (case when v_status = 'SUCCEEDED' then v_amount else 0 end) > v_payment_intent.amount
         or v_amount > v_payment_intent.amount then
        perform haulvia_command.fail('REFUND_AMOUNT_INVALID', 'Refund exceeds the original provider-collected amount');
      end if;
    end if;
    insert into haulvia.payment_transactions (
      payment_intent_id, shipment_id, transaction_type, status, amount,
      currency, external_provider, external_reference, provider_event_id,
      provider_occurred_at, response_payload, idempotency_key
    ) values (
      v_payment_intent.id, p_shipment.id,
      case when v_type = 'CUSTOMER_REFUND' then 'REFUND'::haulvia.payment_transaction_type
        else 'ADJUSTMENT'::haulvia.payment_transaction_type end,
      v_status, v_amount, p_shipment.currency, v_provider, v_external_reference,
      v_provider_event,
      case when v_provider_event is null then null else coalesce(
        nullif(p_request ->> 'providerOccurredAt', '')::timestamptz, clock_timestamp()
      ) end,
      coalesce(p_request -> 'providerResponse', '{}'::jsonb) || jsonb_build_object(
        'authorizationSnapshot', p_request -> 'authorizationSnapshot',
        'customerApproval', p_request -> 'customerApproval'
      ), v_provider_key
    ) returning id into v_payment_tx_id;
  else
    select * into v_payout
    from haulvia.driver_payouts dp
    where dp.id = haulvia_command.required_uuid(p_request, 'expectedPayoutId')
      and dp.shipment_id = p_shipment.id
    for update;
    if not found then
      perform haulvia_command.fail('PAYOUT_NOT_FOUND', 'Driver compensation requires the retained route payout');
    end if;
    insert into haulvia.payout_transactions (
      payout_id, status, amount, currency, external_provider,
      external_reference, provider_event_id, response_payload,
      idempotency_key, allocation_snapshot
    ) values (
      v_payout.id, v_status, v_amount, p_shipment.currency, v_provider,
      v_external_reference, v_provider_event,
      coalesce(p_request -> 'providerResponse', '{}'::jsonb), v_provider_key,
      jsonb_build_object(
        'adjustmentType', v_type, 'routeExecutionId', v_route_execution_id,
        'stopExecutionId', v_stop_id, 'cargoItemId', v_cargo_id
      )
    ) returning id into v_payout_tx_id;
    v_prior_payout_state := v_payout.state;
    v_new_payout_state := case
      when v_payout.state in ('PAID', 'FAILED') then 'READY'::haulvia.driver_payout_state
      else v_payout.state end;
    update haulvia.driver_payouts
    set adjustment_amount = adjustment_amount + v_amount,
        net_amount = net_amount + v_amount,
        state = v_new_payout_state,
        state_changed_at = case when state <> v_new_payout_state then clock_timestamp()
          else state_changed_at end
    where id = v_payout.id;
    update haulvia.shipment_driver_payout_axes
    set state = v_new_payout_state,
        eligible_amount = eligible_amount + v_amount,
        state_changed_at = case when state <> v_new_payout_state then clock_timestamp()
          else state_changed_at end
    where shipment_id = p_shipment.id;
    if v_new_payout_state <> v_prior_payout_state then
      perform haulvia_command.append_axis_event(
        p_shipment.id, 'DRIVER_PAYOUT', v_prior_payout_state::text,
        v_new_payout_state::text, 'issueRefundOrAdjustment', p_request, v_payout.id,
        jsonb_build_object('adjustmentAmount', v_amount, 'payoutTransactionId', v_payout_tx_id)
      );
    end if;
  end if;

  insert into haulvia.financial_adjustments (
    shipment_id, route_execution_id, stop_execution_id, cargo_item_id,
    adjustment_type, amount, currency, reason, policy_version_id,
    payment_transaction_id, payout_transaction_id, authorized_by_profile_id,
    reauth_session_id, authorization_snapshot, provider_request_snapshot,
    idempotency_key
  ) values (
    p_shipment.id, v_route_execution_id, v_stop_id, v_cargo_id,
    v_type, v_amount, p_shipment.currency, v_reason,
    haulvia_command.optional_uuid(p_request, 'policyVersionId'),
    v_payment_tx_id, v_payout_tx_id,
    haulvia_command.required_uuid(p_request, 'actorProfileId'),
    haulvia_command.required_uuid(p_request, 'reauthSessionId'),
    p_request -> 'authorizationSnapshot',
    jsonb_build_object(
      'externalProvider', v_provider, 'providerIdempotencyKey', v_provider_key,
      'providerStatus', v_status, 'providerEventId', v_provider_event,
      'externalReference', v_external_reference,
      'customerApproval', p_request -> 'customerApproval'
    ), v_provider_key
  ) returning id into v_adjustment_id;

  if v_type = 'CUSTOMER_REFUND' and v_status = 'SUCCEEDED' then
    select state into v_prior_payment_state
    from haulvia.shipment_customer_payment_axes
    where shipment_id = p_shipment.id for update;
    select coalesce(sum(pt.amount), 0) into v_refunded
    from haulvia.payment_transactions pt
    where pt.payment_intent_id = v_payment_intent.id
      and pt.transaction_type = 'REFUND' and pt.status = 'SUCCEEDED';
    v_new_payment_state := case when v_refunded >= v_payment_intent.amount
      then 'REFUNDED'::haulvia.customer_payment_state
      else 'PARTIALLY_REFUNDED'::haulvia.customer_payment_state end;
    update haulvia.shipment_customer_payment_axes
    set state = v_new_payment_state, state_changed_at = clock_timestamp()
    where shipment_id = p_shipment.id;
    perform haulvia_command.append_axis_event(
      p_shipment.id, 'CUSTOMER_PAYMENT', v_prior_payment_state::text,
      v_new_payment_state::text, 'issueRefundOrAdjustment', p_request,
      v_payment_intent.id,
      jsonb_build_object('financialAdjustmentId', v_adjustment_id, 'refundedAmount', v_refunded)
    );
  end if;

  perform haulvia_command.append_audit(
    p_shipment, 'issueRefundOrAdjustment', p_request,
    jsonb_build_object('shipmentState', p_shipment.shipment_state),
    jsonb_build_object('shipmentState', p_shipment.shipment_state),
    jsonb_build_object(
      'financialAdjustmentId', v_adjustment_id, 'adjustmentType', v_type,
      'amount', v_amount, 'currency', p_shipment.currency,
      'paymentTransactionId', v_payment_tx_id,
      'payoutTransactionId', v_payout_tx_id,
      'operationalStateUnchanged', true
    )
  );
  perform haulvia_command.queue_notification(
    p_shipment.id, p_shipment.customer_profile_id, 'FINANCIAL_ADJUSTMENT_ISSUED',
    p_request, 'financial-adjustment-' || v_adjustment_id::text,
    jsonb_build_object(
      'financialAdjustmentId', v_adjustment_id,
      'adjustmentType', v_type, 'amount', v_amount,
      'providerStatus', v_status
    )
  );
  return jsonb_build_object(
    'financialAdjustmentId', v_adjustment_id,
    'paymentTransactionId', v_payment_tx_id,
    'payoutTransactionId', v_payout_tx_id,
    'adjustmentType', v_type, 'amount', v_amount,
    'currency', p_shipment.currency, 'providerStatus', v_status,
    'shipmentState', p_shipment.shipment_state,
    'operationalStateUnchanged', true,
    'duplicateProviderRequest', false
  );
end;
$$;

-- Keep the established view column order and append Block D review/financial
-- summaries. Completed assignment/execution IDs remain available from the
-- immutable completion record returned by the command itself.
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
  coalesce(paid.paid_amount, 0) as paid_payout_amount
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
) paid on true;

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
    'paidPayoutAmount', c.paid_payout_amount
  ) || coalesce(p_affected, '{}'::jsonb)
  from haulvia.v_shipment_operating_context c
  where c.shipment_id = p_shipment_id;
$$;

-- ---------------------------------------------------------------------------
-- Trusted dispatcher and the nine approved named Block D entry points
-- ---------------------------------------------------------------------------

create or replace function haulvia_command.execute_block_d_command(
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
    when 'confirmReceiverReceipt' then
      v_affected := haulvia_command.apply_d01_confirm_receiver_receipt(v_shipment, p_request);
    when 'reportDeliveryProblem' then
      v_affected := haulvia_command.apply_d02_report_delivery_problem(v_shipment, p_request);
    when 'expireConfirmationWindow' then
      v_affected := haulvia_command.apply_d03_expire_confirmation_window(v_shipment, p_request);
    when 'openPostDeliveryDispute' then
      v_affected := haulvia_command.apply_d04_open_post_delivery_dispute(v_shipment, p_request);
    when 'completeShipment' then
      v_affected := haulvia_command.apply_d05_complete_shipment(v_shipment, p_request);
    when 'submitDriverPayout' then
      v_affected := haulvia_command.apply_d06_submit_driver_payout(v_shipment, p_request);
    when 'confirmDriverPayout' then
      v_affected := haulvia_command.apply_d07_confirm_driver_payout(v_shipment, p_request);
    when 'handlePayoutFailure' then
      v_affected := haulvia_command.apply_d08_handle_payout_failure(v_shipment, p_request);
    when 'issueRefundOrAdjustment' then
      v_affected := haulvia_command.apply_d09_issue_refund_or_adjustment(v_shipment, p_request);
    else
      perform haulvia_command.fail('INVALID_REQUEST', 'Command is not an approved Block D handler');
  end case;
  v_result := haulvia_command.operating_context(
    v_shipment.id, p_command_name, v_command_id, v_affected
  );
  return haulvia_command.complete_request(
    v_actor, p_command_name, v_idempotency_key, v_result
  );
end;
$$;

create or replace function haulvia_command.command_confirm_receiver_receipt(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('confirmReceiverReceipt', p_request); $$;

create or replace function haulvia_command.command_report_delivery_problem(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('reportDeliveryProblem', p_request); $$;

create or replace function haulvia_command.command_expire_confirmation_window(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('expireConfirmationWindow', p_request); $$;

create or replace function haulvia_command.command_open_post_delivery_dispute(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('openPostDeliveryDispute', p_request); $$;

create or replace function haulvia_command.command_complete_shipment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('completeShipment', p_request); $$;

create or replace function haulvia_command.command_submit_driver_payout(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('submitDriverPayout', p_request); $$;

create or replace function haulvia_command.command_confirm_driver_payout(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('confirmDriverPayout', p_request); $$;

create or replace function haulvia_command.command_handle_payout_failure(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('handlePayoutFailure', p_request); $$;

create or replace function haulvia_command.command_issue_refund_or_adjustment(p_request jsonb)
returns jsonb language sql security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$ select haulvia_command.execute_block_d_command('issueRefundOrAdjustment', p_request); $$;

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

comment on table haulvia.delivery_review_windows is
  'Immutable per-delivery-stop review deadline and exact versioned timing-policy snapshot; provisional launch duration is configuration data.';
comment on table haulvia.delivery_review_window_resolutions is
  'First-valid-commit-wins stop-level receiver, proof-of-drop, issue, or exception resolution; expiry never fabricates receiver confirmation.';
comment on table haulvia.delivery_problem_reports is
  'Immutable receiver-reported missing, damaged, incorrect, or not-received cargo evidence and linked disputed/protected amounts.';
comment on table haulvia.payout_eligibility_records is
  'Whole-route evidence, pricing, policy, hold, and release-authorization snapshot used to establish READY or HELD payout eligibility.';
comment on table haulvia.shipment_completion_records is
  'Read-only proof that the physical route completed irreversibly; later disputes, refunds, claims, and payout processing remain independent.';

commit;
