-- ============================================================================
-- Haulvia P2E
-- Provider Adapters and Webhooks v1
--
-- Frozen contract:
-- docs/Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md
--
-- Contract SHA-256:
-- 60C0408922C0474B3338C5E1274B6C74B570F57B18F01ACE62E7E718EBB7140A
--
-- DEPLOYMENT READY.
--
-- The production migration owns its transaction and commits at the end.
-- Rollback-only regression runners must strip that final COMMIT from their
-- temporary test copy before appending ROLLBACK.
-- ============================================================================

BEGIN;

SET LOCAL search_path = haulvia, haulvia_command, pg_temp;


-- ============================================================================
-- 1. Prospective worker-authority / human-role separation hardening
--
-- Historical migrations remain unchanged.
--
-- P2E preserves all established worker authorities and adds the dedicated
-- inbound payment-provider callback authority.
-- ============================================================================

create or replace function haulvia.reject_worker_authority_role()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.role_key = any (
    array[
      'COMPLETION_WORKER',
      'CUSTODY_TRANSFER_WORKER',
      'DISPUTE_RESOLUTION_WORKER',
      'ELIGIBILITY_WORKER',
      'EXPIRY_WORKER',
      'MATCHING_WORKER',
      'OFFER_WORKER',
      'PAYMENT_WORKER',
      'PAYMENT_PROVIDER_CALLBACK',
      'PAYOUT_PROVIDER_CALLBACK',
      'PAYOUT_WORKER',
      'RECOVERY_WORKER',
      'RETURN_VERIFICATION_WORKER',
      'ROUTE_OPERATIONS_WORKER',
      'STORAGE_WORKER',
      'TERMINAL_REPOST_WORKER'
    ]
  ) then
    raise exception
      'Worker authority % cannot be created as a human membership role',
      new.role_key
      using errcode = '23514';
  end if;

  return new;
end;
$$;


-- ============================================================================
-- 2. Provider-neutral P2E types
-- ============================================================================

create type haulvia.provider_adapter_operation as enum (
  'PAYMENT_AUTHORIZE',
  'PAYMENT_CAPTURE',
  'PAYMENT_VOID',
  'CUSTOMER_REFUND',
  'DRIVER_PAYOUT',
  'FINANCIAL_ADJUSTMENT'
);

create type haulvia.provider_adapter_request_status as enum (
  'PREPARED',
  'SUBMITTED',
  'SUBMISSION_FAILED',
  'CANCELLED'
);

create type haulvia.provider_adapter_error_category as enum (
  'AUTHENTICATION_ERROR',
  'INVALID_PROVIDER_REQUEST',
  'INVALID_PROVIDER_RESPONSE',
  'RATE_LIMITED',
  'TEMPORARY_PROVIDER_ERROR',
  'PERMANENT_PROVIDER_ERROR',
  'TIMEOUT',
  'NETWORK_ERROR',
  'UNKNOWN_PROVIDER_ERROR'
);

create type haulvia.provider_webhook_dispatch_status as enum (
  'COMMITTED',
  'FAILED',
  'SKIPPED_UNSUPPORTED'
);


-- ============================================================================
-- 3. Outbound provider adapter requests
--
-- Integration evidence only.
-- These rows do not replace payment_intents, payment_transactions,
-- driver_payouts, payout_transactions, or financial_adjustments.
-- ============================================================================

create table haulvia.provider_adapter_requests (
  id uuid primary key default gen_random_uuid(),

  shipment_id uuid not null
    references haulvia.shipments(id),

  operation haulvia.provider_adapter_operation not null,

  external_provider text not null,

  provider_idempotency_key text not null,

  correlation_id uuid not null,

  payment_intent_id uuid
    references haulvia.payment_intents(id),

  payment_transaction_id uuid
    references haulvia.payment_transactions(id),

  payout_id uuid
    references haulvia.driver_payouts(id),

  payout_transaction_id uuid
    references haulvia.payout_transactions(id),

  financial_adjustment_id uuid
    references haulvia.financial_adjustments(id),

  request_fingerprint_sha256 text not null,

  request_snapshot jsonb not null
    default '{}'::jsonb,

  status haulvia.provider_adapter_request_status not null
    default 'PREPARED',

  prepared_at timestamptz not null
    default clock_timestamp(),

  submitted_at timestamptz,

  submission_failed_at timestamptz,

  cancelled_at timestamptz,

  updated_at timestamptz not null
    default clock_timestamp(),

  unique (
    external_provider,
    operation,
    provider_idempotency_key
  ),

  check (
    length(btrim(external_provider)) > 0
  ),

  check (
    length(btrim(provider_idempotency_key)) > 0
  ),

  check (
    request_fingerprint_sha256 ~ '^[0-9a-f]{64}$'
  ),

  check (
    jsonb_typeof(request_snapshot) = 'object'
  ),

  check (
    (
      status = 'PREPARED'
      and submitted_at is null
      and submission_failed_at is null
      and cancelled_at is null
    )
    or (
      status = 'SUBMITTED'
      and submitted_at is not null
      and submission_failed_at is null
      and cancelled_at is null
    )
    or (
      status = 'SUBMISSION_FAILED'
      and submission_failed_at is not null
      and cancelled_at is null
    )
    or (
      status = 'CANCELLED'
      and cancelled_at is not null
    )
  )
);


-- ============================================================================
-- 4. Provider adapter execution attempts
--
-- Append-only execution evidence.
-- ============================================================================

create table haulvia.provider_adapter_attempts (
  id uuid primary key default gen_random_uuid(),

  adapter_request_id uuid not null
    references haulvia.provider_adapter_requests(id),

  attempt_no integer not null,

  correlation_id uuid not null,

  started_at timestamptz not null,

  completed_at timestamptz not null,

  submission_succeeded boolean not null,

  normalized_result jsonb not null
    default '{}'::jsonb,

  error_category haulvia.provider_adapter_error_category,

  provider_status text,

  provider_reference text,

  provider_error_code text,

  retryable boolean not null
    default false,

  response_snapshot jsonb not null
    default '{}'::jsonb,

  created_at timestamptz not null
    default clock_timestamp(),

  unique (
    adapter_request_id,
    attempt_no
  ),

  check (
    attempt_no > 0
  ),

  check (
    completed_at >= started_at
  ),

  check (
    jsonb_typeof(normalized_result) = 'object'
  ),

  check (
    jsonb_typeof(response_snapshot) = 'object'
  ),

  check (
    (
      submission_succeeded
      and error_category is null
    )
    or (
      not submission_succeeded
      and error_category is not null
    )
  )
);


-- ============================================================================
-- 5. Provider webhook/event ingress
--
-- Provider event identity and body digest are immutable after acceptance.
-- Signature verification is supplied only by a trusted backend boundary.
-- ============================================================================

create table haulvia.provider_webhook_events (
  id uuid primary key default gen_random_uuid(),

  external_provider text not null,

  provider_event_id text,

  provider_event_type text not null,

  received_at timestamptz not null
    default clock_timestamp(),

  provider_occurred_at timestamptz,

  body_sha256 text not null,

  signature_verified boolean not null,

  verifier_authority text not null,

  verification_context jsonb not null
    default '{}'::jsonb,

  normalized_event_snapshot jsonb not null
    default '{}'::jsonb,

  correlation_id uuid not null,

  created_at timestamptz not null
    default clock_timestamp(),

  check (
    length(btrim(external_provider)) > 0
  ),

  check (
    provider_event_id is null
    or length(btrim(provider_event_id)) > 0
  ),

  check (
    length(btrim(provider_event_type)) > 0
  ),

  check (
    body_sha256 ~ '^[0-9a-f]{64}$'
  ),

  check (
    length(btrim(verifier_authority)) > 0
  ),

  check (
    jsonb_typeof(verification_context) = 'object'
  ),

  check (
    jsonb_typeof(normalized_event_snapshot) = 'object'
  )
);

create unique index provider_webhook_events_provider_event_uq
  on haulvia.provider_webhook_events (
    external_provider,
    provider_event_id
  )
  where provider_event_id is not null;


-- ============================================================================
-- 6. Provider webhook dispatch history
--
-- Final append-only dispatch outcomes.
-- One provider event may have multiple failed attempts but at most one
-- successfully committed financial-domain dispatch.
-- ============================================================================

create table haulvia.provider_webhook_dispatches (
  id uuid primary key default gen_random_uuid(),

  provider_webhook_event_id uuid not null
    references haulvia.provider_webhook_events(id),

  dispatch_attempt_no integer not null,

  normalized_operation haulvia.provider_adapter_operation,

  normalized_outcome text not null,

  target_command text,

  command_idempotency_key text,

  command_request_hash text,

  correlation_id uuid not null,

  status haulvia.provider_webhook_dispatch_status not null,

  command_result jsonb not null
    default '{}'::jsonb,

  haulvia_error_code text,

  error_context jsonb not null
    default '{}'::jsonb,

  started_at timestamptz not null,

  completed_at timestamptz not null,

  created_at timestamptz not null
    default clock_timestamp(),

  unique (
    provider_webhook_event_id,
    dispatch_attempt_no
  ),

  check (
    dispatch_attempt_no > 0
  ),

  check (
    length(btrim(normalized_outcome)) > 0
  ),

  check (
    command_request_hash is null
    or command_request_hash ~ '^[0-9a-f]{64}$'
  ),

  check (
    jsonb_typeof(command_result) = 'object'
  ),

  check (
    jsonb_typeof(error_context) = 'object'
  ),

  check (
    completed_at >= started_at
  )
);

create unique index provider_webhook_dispatches_one_commit_uq
  on haulvia.provider_webhook_dispatches (
    provider_webhook_event_id
  )
  where status = 'COMMITTED';


-- ============================================================================
-- 7. RLS baseline
-- ============================================================================

alter table haulvia.provider_adapter_requests
  enable row level security;

alter table haulvia.provider_adapter_attempts
  enable row level security;

alter table haulvia.provider_webhook_events
  enable row level security;

alter table haulvia.provider_webhook_dispatches
  enable row level security;


-- ============================================================================
-- 8. Append-only integration evidence
-- ============================================================================

create or replace function haulvia_command.reject_p2e_append_only_mutation()
returns trigger
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  perform haulvia_command.fail(
    'IMMUTABLE_RECORD',
    'P2E integration evidence is append-only'
  );

  return null;
end;
$$;

revoke all
on function haulvia_command.reject_p2e_append_only_mutation()
from public;

create trigger provider_adapter_attempts_append_only
before update or delete
on haulvia.provider_adapter_attempts
for each row
execute function haulvia_command.reject_p2e_append_only_mutation();

create trigger provider_webhook_events_append_only
before update or delete
on haulvia.provider_webhook_events
for each row
execute function haulvia_command.reject_p2e_append_only_mutation();

create trigger provider_webhook_dispatches_append_only
before update or delete
on haulvia.provider_webhook_dispatches
for each row
execute function haulvia_command.reject_p2e_append_only_mutation();


-- ============================================================================
-- P2E implementation continues after this scaffold.
--
-- Still required:
--   * payload sanitization guard
--   * adapter-request lifecycle guard
--   * command-adapter manifest
--   * outbound request/attempt commands
--   * webhook ingress replay/conflict command
--   * webhook dispatch commands
--   * PAYMENT_PROVIDER_CALLBACK prospective payment-path changes
--   * result/error normalization
--   * service-role wrapper allowlist
--   * privilege closure
--   * P2E acceptance suite
--
-- No COMMIT yet.
-- ============================================================================
-- ============================================================================
-- P2E-BLOCK-1-BEGIN
-- Payload sanitization, adapter request lifecycle, idempotency, and attempts
-- ============================================================================


-- ============================================================================
-- 9. Recursive sensitive-provider-data guard
--
-- P2E persistence may retain sanitized provider evidence, but it must never
-- become a credential or raw payment-data store.
--
-- Key matching is normalized by removing punctuation/underscores and lowering
-- case. Safe opaque references such as paymentMethodReference,
-- payoutAccountReference, providerReference, and *Last4 are not prohibited.
-- ============================================================================

create or replace function haulvia_command.assert_p2e_safe_json(
  p_payload jsonb,
  p_label text default 'provider payload'
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_key text;
  v_value jsonb;
  v_normalized_key text;
begin
  if p_payload is null then
    return;
  end if;

  if jsonb_typeof(p_payload) = 'object' then
    for v_key, v_value in
      select e.key, e.value
      from pg_catalog.jsonb_each(p_payload) e
    loop
      v_normalized_key :=
        pg_catalog.regexp_replace(
          pg_catalog.lower(v_key),
          '[^a-z0-9]',
          '',
          'g'
        );

      if v_normalized_key = any (
        array[
          'authorization',
          'authorizationheader',
          'authheader',
          'apikey',
          'apisecret',
          'secret',
          'secretkey',
          'clientsecret',
          'webhooksecret',
          'signingsecret',
          'signingkey',
          'privatekey',
          'accesstoken',
          'refreshtoken',
          'bearertoken',
          'password',
          'passphrase',
          'cardnumber',
          'primaryaccountnumber',
          'pan',
          'cvv',
          'cvv2',
          'cvc',
          'cvc2',
          'bankaccountnumber',
          'accountnumber',
          'routingnumber',
          'transitnumber',
          'institutionnumber',
          'iban'
        ]::text[]
      ) then
        perform haulvia_command.fail(
          'SENSITIVE_PROVIDER_DATA',
          'Sensitive provider authentication or payment data cannot be persisted',
          jsonb_build_object(
            'payload', coalesce(p_label, 'provider payload'),
            'forbiddenKey', v_key
          )
        );
      end if;

      perform haulvia_command.assert_p2e_safe_json(
        v_value,
        p_label
      );
    end loop;

  elsif jsonb_typeof(p_payload) = 'array' then
    for v_value in
      select a.value
      from pg_catalog.jsonb_array_elements(p_payload) a
    loop
      perform haulvia_command.assert_p2e_safe_json(
        v_value,
        p_label
      );
    end loop;
  end if;
end;
$$;

revoke all
on function haulvia_command.assert_p2e_safe_json(jsonb, text)
from public;


-- ============================================================================
-- 10. P2E persisted-payload sanitization trigger
-- ============================================================================

create or replace function haulvia_command.guard_p2e_safe_payloads()
returns trigger
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_row jsonb;
begin
  v_row := to_jsonb(new);

  if tg_table_name = 'provider_adapter_requests' then
    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'request_snapshot',
      'provider_adapter_requests.request_snapshot'
    );

  elsif tg_table_name = 'provider_adapter_attempts' then
    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'normalized_result',
      'provider_adapter_attempts.normalized_result'
    );

    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'response_snapshot',
      'provider_adapter_attempts.response_snapshot'
    );

  elsif tg_table_name = 'provider_webhook_events' then
    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'verification_context',
      'provider_webhook_events.verification_context'
    );

    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'normalized_event_snapshot',
      'provider_webhook_events.normalized_event_snapshot'
    );

  elsif tg_table_name = 'provider_webhook_dispatches' then
    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'command_result',
      'provider_webhook_dispatches.command_result'
    );

    perform haulvia_command.assert_p2e_safe_json(
      v_row -> 'error_context',
      'provider_webhook_dispatches.error_context'
    );
  end if;

  return new;
end;
$$;

revoke all
on function haulvia_command.guard_p2e_safe_payloads()
from public;

create trigger provider_adapter_requests_safe_payload
before insert or update
on haulvia.provider_adapter_requests
for each row
execute function haulvia_command.guard_p2e_safe_payloads();

create trigger provider_adapter_attempts_safe_payload
before insert or update
on haulvia.provider_adapter_attempts
for each row
execute function haulvia_command.guard_p2e_safe_payloads();

create trigger provider_webhook_events_safe_payload
before insert or update
on haulvia.provider_webhook_events
for each row
execute function haulvia_command.guard_p2e_safe_payloads();

create trigger provider_webhook_dispatches_safe_payload
before insert or update
on haulvia.provider_webhook_dispatches
for each row
execute function haulvia_command.guard_p2e_safe_payloads();


-- ============================================================================
-- 11. Adapter-request lifecycle guard
--
-- All identity, correlation, canonical-link, fingerprint, and request payload
-- facts are immutable after creation.
--
-- Allowed request-state movement:
--
-- PREPARED
--   -> SUBMITTED
--   -> SUBMISSION_FAILED
--   -> CANCELLED
--
-- SUBMISSION_FAILED
--   -> SUBMISSION_FAILED  (another failed retry)
--   -> SUBMITTED          (later retry accepted)
--   -> CANCELLED
--
-- SUBMITTED and CANCELLED are terminal integration states.
-- ============================================================================

create or replace function haulvia_command.guard_provider_adapter_request_update()
returns trigger
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if (
    to_jsonb(new)
      - array[
          'status',
          'submitted_at',
          'submission_failed_at',
          'cancelled_at',
          'updated_at'
        ]::text[]
  ) is distinct from (
    to_jsonb(old)
      - array[
          'status',
          'submitted_at',
          'submission_failed_at',
          'cancelled_at',
          'updated_at'
        ]::text[]
  ) then
    perform haulvia_command.fail(
      'IMMUTABLE_RECORD',
      'Provider adapter request identity and request facts are immutable'
    );
  end if;

  if old.status = 'PREPARED' then
    if new.status not in (
      'SUBMITTED',
      'SUBMISSION_FAILED',
      'CANCELLED'
    ) then
      perform haulvia_command.fail(
        'INVALID_STATE',
        'Invalid provider adapter request lifecycle transition'
      );
    end if;

  elsif old.status = 'SUBMISSION_FAILED' then
    if new.status not in (
      'SUBMISSION_FAILED',
      'SUBMITTED',
      'CANCELLED'
    ) then
      perform haulvia_command.fail(
        'INVALID_STATE',
        'Invalid provider adapter retry lifecycle transition'
      );
    end if;

  else
    perform haulvia_command.fail(
      'INVALID_STATE',
      'Submitted or cancelled provider adapter requests are terminal'
    );
  end if;

  if new.updated_at < old.updated_at then
    perform haulvia_command.fail(
      'INVALID_STATE',
      'Provider adapter request updated_at cannot move backwards'
    );
  end if;

  return new;
end;
$$;

revoke all
on function haulvia_command.guard_provider_adapter_request_update()
from public;

create trigger provider_adapter_requests_lifecycle_guard
before update
on haulvia.provider_adapter_requests
for each row
execute function haulvia_command.guard_provider_adapter_request_update();


-- ============================================================================
-- 12. Provider adapter worker-authority routing
-- ============================================================================

create or replace function haulvia_command.assert_p2e_adapter_worker(
  p_operation haulvia.provider_adapter_operation,
  p_request jsonb
)
returns void
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
begin
  if p_operation = 'DRIVER_PAYOUT' then
    perform haulvia_command.assert_worker(
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      p_request ->> 'workerAuthority',
      array['PAYOUT_WORKER']
    );

  elsif p_operation = 'FINANCIAL_ADJUSTMENT' then
    perform haulvia_command.assert_worker(
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      p_request ->> 'workerAuthority',
      array['PAYMENT_WORKER', 'PAYOUT_WORKER']
    );

  else
    perform haulvia_command.assert_worker(
      haulvia_command.optional_uuid(p_request, 'actorProfileId'),
      p_request ->> 'workerAuthority',
      array['PAYMENT_WORKER']
    );
  end if;
end;
$$;

revoke all
on function haulvia_command.assert_p2e_adapter_worker(
  haulvia.provider_adapter_operation,
  jsonb
)
from public;


-- ============================================================================
-- 13. Prepare outbound provider adapter request
--
-- Provider idempotency is separate from command idempotency.
--
-- Exact replay returns the existing request.
-- Reuse of the same provider + operation + provider idempotency key with
-- different material facts fails closed.
-- ============================================================================

create or replace function haulvia_command.apply_p2e_prepare_provider_adapter_request(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_shipment_id uuid :=
    haulvia_command.required_uuid(p_request, 'shipmentId');

  v_operation haulvia.provider_adapter_operation;

  v_provider text :=
    haulvia_command.required_text(p_request, 'externalProvider');

  v_provider_key text :=
    haulvia_command.required_text(p_request, 'providerIdempotencyKey');

  v_correlation_id uuid :=
    haulvia_command.required_uuid(p_request, 'correlationId');

  v_payment_intent_id uuid :=
    haulvia_command.optional_uuid(p_request, 'paymentIntentId');

  v_payment_transaction_id uuid :=
    haulvia_command.optional_uuid(p_request, 'paymentTransactionId');

  v_payout_id uuid :=
    haulvia_command.optional_uuid(p_request, 'payoutId');

  v_payout_transaction_id uuid :=
    haulvia_command.optional_uuid(p_request, 'payoutTransactionId');

  v_financial_adjustment_id uuid :=
    haulvia_command.optional_uuid(p_request, 'financialAdjustmentId');

  v_fingerprint text :=
    haulvia_command.required_text(
      p_request,
      'requestFingerprintSha256'
    );

  v_snapshot jsonb :=
    coalesce(p_request -> 'requestSnapshot', '{}'::jsonb);

  v_row haulvia.provider_adapter_requests%rowtype;
  v_inserted boolean := false;
begin
  begin
    v_operation :=
      pg_catalog.upper(
        haulvia_command.required_text(p_request, 'operation')
      )::haulvia.provider_adapter_operation;
  exception
    when invalid_text_representation then
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Provider adapter operation is invalid'
      );
  end;

  perform haulvia_command.assert_p2e_adapter_worker(
    v_operation,
    p_request
  );

  if not exists (
    select 1
    from haulvia.shipments s
    where s.id = v_shipment_id
  ) then
    perform haulvia_command.fail(
      'NOT_FOUND',
      'Provider adapter shipment was not found'
    );
  end if;

  if v_fingerprint !~ '^[0-9a-f]{64}$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'requestFingerprintSha256 must be a lowercase SHA-256 digest'
    );
  end if;

  if jsonb_typeof(v_snapshot) <> 'object' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'requestSnapshot must be a JSON object'
    );
  end if;

  perform haulvia_command.assert_p2e_safe_json(
    v_snapshot,
    'provider adapter request snapshot'
  );

  if v_payment_intent_id is not null then
    if not exists (
      select 1
      from haulvia.payment_intents pi
      where pi.id = v_payment_intent_id
        and pi.shipment_id = v_shipment_id
        and pi.external_provider = v_provider
    ) then
      perform haulvia_command.fail(
        'PAYMENT_NOT_FOUND',
        'Payment intent does not belong to this shipment and provider'
      );
    end if;
  end if;

  if v_payment_transaction_id is not null then
    if not exists (
      select 1
      from haulvia.payment_transactions pt
      where pt.id = v_payment_transaction_id
        and pt.shipment_id = v_shipment_id
        and pt.external_provider = v_provider
        and (
          v_payment_intent_id is null
          or pt.payment_intent_id = v_payment_intent_id
        )
    ) then
      perform haulvia_command.fail(
        'PAYMENT_NOT_FOUND',
        'Payment transaction does not match the adapter request context'
      );
    end if;
  end if;

  if v_payout_id is not null then
    if not exists (
      select 1
      from haulvia.driver_payouts dp
      where dp.id = v_payout_id
        and dp.shipment_id = v_shipment_id
    ) then
      perform haulvia_command.fail(
        'PAYOUT_NOT_FOUND',
        'Driver payout does not belong to this shipment'
      );
    end if;
  end if;

  if v_payout_transaction_id is not null then
    if not exists (
      select 1
      from haulvia.payout_transactions pt
      join haulvia.driver_payouts dp
        on dp.id = pt.payout_id
      where pt.id = v_payout_transaction_id
        and dp.shipment_id = v_shipment_id
        and pt.external_provider = v_provider
        and (
          v_payout_id is null
          or pt.payout_id = v_payout_id
        )
    ) then
      perform haulvia_command.fail(
        'PAYOUT_NOT_FOUND',
        'Payout transaction does not match the adapter request context'
      );
    end if;
  end if;

  if v_financial_adjustment_id is not null then
    if not exists (
      select 1
      from haulvia.financial_adjustments fa
      where fa.id = v_financial_adjustment_id
        and fa.shipment_id = v_shipment_id
    ) then
      perform haulvia_command.fail(
        'NOT_FOUND',
        'Financial adjustment does not belong to this shipment'
      );
    end if;
  end if;

  if v_operation in (
    'PAYMENT_AUTHORIZE',
    'PAYMENT_CAPTURE',
    'PAYMENT_VOID',
    'CUSTOMER_REFUND'
  )
  and v_payment_intent_id is null then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'Payment provider operations require paymentIntentId'
    );
  end if;

  if v_operation = 'DRIVER_PAYOUT'
     and (
       v_payout_id is null
       or v_payout_transaction_id is null
     ) then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'DRIVER_PAYOUT requires payoutId and payoutTransactionId'
    );
  end if;

  if v_operation = 'FINANCIAL_ADJUSTMENT'
     and pg_catalog.num_nonnulls(
       v_payment_intent_id,
       v_payout_id,
       v_financial_adjustment_id
     ) = 0 then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'FINANCIAL_ADJUSTMENT requires a canonical financial reference'
    );
  end if;

  insert into haulvia.provider_adapter_requests (
    shipment_id,
    operation,
    external_provider,
    provider_idempotency_key,
    correlation_id,
    payment_intent_id,
    payment_transaction_id,
    payout_id,
    payout_transaction_id,
    financial_adjustment_id,
    request_fingerprint_sha256,
    request_snapshot
  ) values (
    v_shipment_id,
    v_operation,
    v_provider,
    v_provider_key,
    v_correlation_id,
    v_payment_intent_id,
    v_payment_transaction_id,
    v_payout_id,
    v_payout_transaction_id,
    v_financial_adjustment_id,
    v_fingerprint,
    v_snapshot
  )
  on conflict (
    external_provider,
    operation,
    provider_idempotency_key
  )
  do nothing
  returning *
  into v_row;

  if found then
    v_inserted := true;
  else
    select *
    into v_row
    from haulvia.provider_adapter_requests par
    where par.external_provider = v_provider
      and par.operation = v_operation
      and par.provider_idempotency_key = v_provider_key
    for update;

    if not found then
      perform haulvia_command.fail(
        'INTEGRATION_CONFLICT',
        'Provider adapter request could not be reconciled after idempotent insert'
      );
    end if;
  end if;

  if not v_inserted then
    if v_row.shipment_id <> v_shipment_id
       or v_row.correlation_id <> v_correlation_id
       or v_row.request_fingerprint_sha256 <> v_fingerprint
       or v_row.request_snapshot is distinct from v_snapshot
       or v_row.payment_intent_id is distinct from v_payment_intent_id
       or v_row.payment_transaction_id is distinct from v_payment_transaction_id
       or v_row.payout_id is distinct from v_payout_id
       or v_row.payout_transaction_id is distinct from v_payout_transaction_id
       or v_row.financial_adjustment_id is distinct from v_financial_adjustment_id then
      perform haulvia_command.fail(
        'IDEMPOTENCY_KEY_REUSED',
        'Provider idempotency key was reused with different request facts'
      );
    end if;
  end if;

  return jsonb_build_object(
    'providerAdapterRequestId', v_row.id,
    'shipmentId', v_row.shipment_id,
    'operation', v_row.operation,
    'externalProvider', v_row.external_provider,
    'providerIdempotencyKey', v_row.provider_idempotency_key,
    'correlationId', v_row.correlation_id,
    'status', v_row.status,
    'duplicateProviderRequest', not v_inserted
  );
end;
$$;

revoke all
on function haulvia_command.apply_p2e_prepare_provider_adapter_request(jsonb)
from public;


create or replace function haulvia_command.command_prepare_provider_adapter_request(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_p2e_prepare_provider_adapter_request(p_request);
$$;

revoke all
on function haulvia_command.command_prepare_provider_adapter_request(jsonb)
from public;


-- ============================================================================
-- 14. Record provider adapter attempt
--
-- attemptNo is caller-visible concurrency control.
-- Exact replay is idempotent.
-- Reuse of an attempt number with different facts fails closed.
-- ============================================================================

create or replace function haulvia_command.apply_p2e_record_provider_adapter_attempt(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_request_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'providerAdapterRequestId'
    );

  v_attempt_no integer :=
    haulvia_command.required_numeric(
      p_request,
      'attemptNo'
    )::integer;

  v_started_at timestamptz :=
    haulvia_command.required_timestamptz(
      p_request,
      'startedAt'
    );

  v_completed_at timestamptz :=
    haulvia_command.required_timestamptz(
      p_request,
      'completedAt'
    );

  v_succeeded boolean :=
    haulvia_command.required_boolean(
      p_request,
      'submissionSucceeded'
    );

  v_normalized_result jsonb :=
    coalesce(
      p_request -> 'normalizedResult',
      '{}'::jsonb
    );

  v_response_snapshot jsonb :=
    coalesce(
      p_request -> 'responseSnapshot',
      '{}'::jsonb
    );

  v_error_category haulvia.provider_adapter_error_category;

  v_provider_status text :=
    nullif(p_request ->> 'providerStatus', '');

  v_provider_reference text :=
    nullif(p_request ->> 'providerReference', '');

  v_provider_error_code text :=
    nullif(p_request ->> 'providerErrorCode', '');

  v_retryable boolean :=
    coalesce(
      (p_request ->> 'retryable')::boolean,
      false
    );

  v_adapter_request haulvia.provider_adapter_requests%rowtype;
  v_existing haulvia.provider_adapter_attempts%rowtype;
  v_attempt_id uuid;
  v_expected_attempt integer;
  v_new_status haulvia.provider_adapter_request_status;
begin
  select *
  into v_adapter_request
  from haulvia.provider_adapter_requests par
  where par.id = v_request_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'NOT_FOUND',
      'Provider adapter request was not found'
    );
  end if;

  perform haulvia_command.assert_p2e_adapter_worker(
    v_adapter_request.operation,
    p_request
  );

  if v_attempt_no <= 0 then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'attemptNo must be greater than zero'
    );
  end if;

  if v_completed_at < v_started_at then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'Provider attempt completedAt cannot precede startedAt'
    );
  end if;

  if jsonb_typeof(v_normalized_result) <> 'object'
     or jsonb_typeof(v_response_snapshot) <> 'object' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'Provider attempt result snapshots must be JSON objects'
    );
  end if;

  perform haulvia_command.assert_p2e_safe_json(
    v_normalized_result,
    'provider adapter normalized result'
  );

  perform haulvia_command.assert_p2e_safe_json(
    v_response_snapshot,
    'provider adapter response snapshot'
  );

  if nullif(p_request ->> 'errorCategory', '') is not null then
    begin
      v_error_category :=
        pg_catalog.upper(
          p_request ->> 'errorCategory'
        )::haulvia.provider_adapter_error_category;
    exception
      when invalid_text_representation then
        perform haulvia_command.fail(
          'INVALID_REQUEST',
          'Provider adapter error category is invalid'
        );
    end;
  end if;

  if v_succeeded and v_error_category is not null then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'Successful provider submission cannot include an error category'
    );
  end if;

  if not v_succeeded and v_error_category is null then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'Failed provider submission requires a normalized error category'
    );
  end if;

  select *
  into v_existing
  from haulvia.provider_adapter_attempts paa
  where paa.adapter_request_id = v_request_id
    and paa.attempt_no = v_attempt_no;

  if found then
    if v_existing.started_at <> v_started_at
       or v_existing.completed_at <> v_completed_at
       or v_existing.submission_succeeded <> v_succeeded
       or v_existing.normalized_result is distinct from v_normalized_result
       or v_existing.error_category is distinct from v_error_category
       or v_existing.provider_status is distinct from v_provider_status
       or v_existing.provider_reference is distinct from v_provider_reference
       or v_existing.provider_error_code is distinct from v_provider_error_code
       or v_existing.retryable <> v_retryable
       or v_existing.response_snapshot is distinct from v_response_snapshot then
      perform haulvia_command.fail(
        'IDEMPOTENCY_KEY_REUSED',
        'Provider adapter attempt number was reused with different facts'
      );
    end if;

    return jsonb_build_object(
      'providerAdapterRequestId', v_adapter_request.id,
      'providerAdapterAttemptId', v_existing.id,
      'attemptNo', v_existing.attempt_no,
      'submissionSucceeded', v_existing.submission_succeeded,
      'requestStatus', v_adapter_request.status,
      'correlationId', v_adapter_request.correlation_id,
      'duplicateAttempt', true
    );
  end if;

  if v_adapter_request.status in ('SUBMITTED', 'CANCELLED') then
    perform haulvia_command.fail(
      'INVALID_STATE',
      'Provider adapter request no longer accepts execution attempts'
    );
  end if;

  select coalesce(max(paa.attempt_no), 0) + 1
  into v_expected_attempt
  from haulvia.provider_adapter_attempts paa
  where paa.adapter_request_id = v_request_id;

  if v_attempt_no <> v_expected_attempt then
    perform haulvia_command.fail(
      'STALE_ATTEMPT_SEQUENCE',
      'Provider adapter attempt number is not the next expected sequence',
      jsonb_build_object(
        'expectedAttemptNo', v_expected_attempt,
        'receivedAttemptNo', v_attempt_no
      )
    );
  end if;

  insert into haulvia.provider_adapter_attempts (
    adapter_request_id,
    attempt_no,
    correlation_id,
    started_at,
    completed_at,
    submission_succeeded,
    normalized_result,
    error_category,
    provider_status,
    provider_reference,
    provider_error_code,
    retryable,
    response_snapshot
  ) values (
    v_adapter_request.id,
    v_attempt_no,
    v_adapter_request.correlation_id,
    v_started_at,
    v_completed_at,
    v_succeeded,
    v_normalized_result,
    v_error_category,
    v_provider_status,
    v_provider_reference,
    v_provider_error_code,
    v_retryable,
    v_response_snapshot
  )
  returning id
  into v_attempt_id;

  if v_succeeded then
    v_new_status := 'SUBMITTED';

    update haulvia.provider_adapter_requests
    set
      status = 'SUBMITTED',
      submitted_at = v_completed_at,
      submission_failed_at = null,
      cancelled_at = null,
      updated_at = clock_timestamp()
    where id = v_adapter_request.id;

  else
    v_new_status := 'SUBMISSION_FAILED';

    update haulvia.provider_adapter_requests
    set
      status = 'SUBMISSION_FAILED',
      submitted_at = null,
      submission_failed_at = v_completed_at,
      cancelled_at = null,
      updated_at = clock_timestamp()
    where id = v_adapter_request.id;
  end if;

  return jsonb_build_object(
    'providerAdapterRequestId', v_adapter_request.id,
    'providerAdapterAttemptId', v_attempt_id,
    'attemptNo', v_attempt_no,
    'submissionSucceeded', v_succeeded,
    'requestStatus', v_new_status,
    'correlationId', v_adapter_request.correlation_id,
    'duplicateAttempt', false
  );
end;
$$;

revoke all
on function haulvia_command.apply_p2e_record_provider_adapter_attempt(jsonb)
from public;


create or replace function haulvia_command.command_record_provider_adapter_attempt(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_p2e_record_provider_adapter_attempt(p_request);
$$;

revoke all
on function haulvia_command.command_record_provider_adapter_attempt(jsonb)
from public;


-- ============================================================================
-- 15. Cancel provider adapter request before successful submission
-- ============================================================================

create or replace function haulvia_command.apply_p2e_cancel_provider_adapter_request(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_request_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'providerAdapterRequestId'
    );

  v_adapter_request haulvia.provider_adapter_requests%rowtype;
begin
  select *
  into v_adapter_request
  from haulvia.provider_adapter_requests par
  where par.id = v_request_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'NOT_FOUND',
      'Provider adapter request was not found'
    );
  end if;

  perform haulvia_command.assert_p2e_adapter_worker(
    v_adapter_request.operation,
    p_request
  );

  if v_adapter_request.status = 'CANCELLED' then
    return jsonb_build_object(
      'providerAdapterRequestId', v_adapter_request.id,
      'requestStatus', v_adapter_request.status,
      'correlationId', v_adapter_request.correlation_id,
      'duplicateCancel', true
    );
  end if;

  if v_adapter_request.status = 'SUBMITTED' then
    perform haulvia_command.fail(
      'INVALID_STATE',
      'A submitted provider adapter request cannot be cancelled locally'
    );
  end if;

  update haulvia.provider_adapter_requests
  set
    status = 'CANCELLED',
    cancelled_at = clock_timestamp(),
    updated_at = clock_timestamp()
  where id = v_adapter_request.id;

  return jsonb_build_object(
    'providerAdapterRequestId', v_adapter_request.id,
    'requestStatus', 'CANCELLED',
    'correlationId', v_adapter_request.correlation_id,
    'duplicateCancel', false
  );
end;
$$;

revoke all
on function haulvia_command.apply_p2e_cancel_provider_adapter_request(jsonb)
from public;


create or replace function haulvia_command.command_cancel_provider_adapter_request(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_p2e_cancel_provider_adapter_request(p_request);
$$;

revoke all
on function haulvia_command.command_cancel_provider_adapter_request(jsonb)
from public;


-- ============================================================================
-- P2E-BLOCK-1-END
-- ============================================================================

-- ============================================================================
-- P2E-BLOCK-2-BEGIN
-- Verified provider webhook ingress, replay, and conflict protection
-- ============================================================================


-- ============================================================================
-- 16. Trusted webhook callback authority
--
-- Signature verification happens outside PostgreSQL.
-- The database accepts only the verified result from a trusted callback
-- authority and never stores provider signing secrets.
-- ============================================================================

create or replace function haulvia_command.assert_p2e_webhook_worker(
  p_request jsonb
)
returns text
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_worker_authority text :=
    pg_catalog.upper(
      haulvia_command.required_text(
        p_request,
        'workerAuthority'
      )
    );
begin
  perform haulvia_command.assert_worker(
    haulvia_command.optional_uuid(
      p_request,
      'actorProfileId'
    ),
    v_worker_authority,
    array[
      'PAYMENT_PROVIDER_CALLBACK',
      'PAYOUT_PROVIDER_CALLBACK'
    ]
  );

  return v_worker_authority;
end;
$$;

revoke all
on function haulvia_command.assert_p2e_webhook_worker(jsonb)
from public;


-- ============================================================================
-- 17. Receive verified provider webhook event
--
-- Provider + providerEventId is the provider replay identity.
--
-- Exact material replay returns the original immutable event.
-- Same provider event ID with a different body digest fails closed as a
-- provider-event conflict.
-- ============================================================================

create or replace function haulvia_command.apply_p2e_receive_provider_webhook(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_provider text :=
    haulvia_command.required_text(
      p_request,
      'externalProvider'
    );

  v_provider_event_id text :=
    haulvia_command.required_text(
      p_request,
      'providerEventId'
    );

  v_provider_event_type text :=
    haulvia_command.required_text(
      p_request,
      'providerEventType'
    );

  v_body_sha256 text :=
    haulvia_command.required_text(
      p_request,
      'bodySha256'
    );

  v_signature_verified boolean :=
    haulvia_command.required_boolean(
      p_request,
      'signatureVerified'
    );

  v_correlation_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'correlationId'
    );

  v_worker_authority text;

  v_provider_occurred_at timestamptz;

  v_verification_context jsonb :=
    coalesce(
      p_request -> 'verificationContext',
      '{}'::jsonb
    );

  v_normalized_event_snapshot jsonb :=
    coalesce(
      p_request -> 'normalizedEventSnapshot',
      '{}'::jsonb
    );

  v_existing haulvia.provider_webhook_events%rowtype;
  v_inserted haulvia.provider_webhook_events%rowtype;

  v_is_duplicate boolean := false;
begin
  v_worker_authority :=
    haulvia_command.assert_p2e_webhook_worker(
      p_request
    );

  if not v_signature_verified then
    perform haulvia_command.fail(
      'WEBHOOK_SIGNATURE_INVALID',
      'Provider webhook signature must be verified before database ingress'
    );
  end if;

  if v_body_sha256 !~ '^[0-9a-f]{64}$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'bodySha256 must be a lowercase SHA-256 digest'
    );
  end if;

  if jsonb_typeof(v_verification_context) <> 'object' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'verificationContext must be a JSON object'
    );
  end if;

  if jsonb_typeof(v_normalized_event_snapshot) <> 'object' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'normalizedEventSnapshot must be a JSON object'
    );
  end if;

  perform haulvia_command.assert_p2e_safe_json(
    v_verification_context,
    'provider webhook verification context'
  );

  perform haulvia_command.assert_p2e_safe_json(
    v_normalized_event_snapshot,
    'provider webhook normalized event snapshot'
  );

  if nullif(
       btrim(p_request ->> 'providerOccurredAt'),
       ''
     ) is not null then
    begin
      v_provider_occurred_at :=
        (p_request ->> 'providerOccurredAt')::timestamptz;
    exception
      when invalid_datetime_format
        or datetime_field_overflow then
        perform haulvia_command.fail(
          'INVALID_REQUEST',
          'providerOccurredAt must be a valid timestamp'
        );
    end;
  end if;

  insert into haulvia.provider_webhook_events (
    external_provider,
    provider_event_id,
    provider_event_type,
    provider_occurred_at,
    body_sha256,
    signature_verified,
    verifier_authority,
    verification_context,
    normalized_event_snapshot,
    correlation_id
  )
  values (
    v_provider,
    v_provider_event_id,
    v_provider_event_type,
    v_provider_occurred_at,
    v_body_sha256,
    true,
    v_worker_authority,
    v_verification_context,
    v_normalized_event_snapshot,
    v_correlation_id
  )
  on conflict (
    external_provider,
    provider_event_id
  )
  where provider_event_id is not null
  do nothing
  returning *
  into v_inserted;

  if found then
    return jsonb_build_object(
      'providerWebhookEventId',
        v_inserted.id,
      'externalProvider',
        v_inserted.external_provider,
      'providerEventId',
        v_inserted.provider_event_id,
      'providerEventType',
        v_inserted.provider_event_type,
      'bodySha256',
        v_inserted.body_sha256,
      'correlationId',
        v_inserted.correlation_id,
      'signatureVerified',
        v_inserted.signature_verified,
      'duplicateProviderEvent',
        false
    );
  end if;

  select *
  into v_existing
  from haulvia.provider_webhook_events pwe
  where pwe.external_provider = v_provider
    and pwe.provider_event_id = v_provider_event_id;

  if not found then
    perform haulvia_command.fail(
      'INTEGRATION_CONFLICT',
      'Provider webhook event could not be reconciled after idempotent ingress'
    );
  end if;

  if v_existing.body_sha256 <> v_body_sha256 then
    perform haulvia_command.fail(
      'PROVIDER_EVENT_CONFLICT',
      'Provider event ID was reused with a different webhook body digest',
      jsonb_build_object(
        'externalProvider',
          v_provider,
        'providerEventId',
          v_provider_event_id,
        'existingBodySha256',
          v_existing.body_sha256,
        'receivedBodySha256',
          v_body_sha256
      )
    );
  end if;

  if v_existing.provider_event_type <> v_provider_event_type
     or v_existing.provider_occurred_at
          is distinct from v_provider_occurred_at
     or v_existing.normalized_event_snapshot
          is distinct from v_normalized_event_snapshot then
    perform haulvia_command.fail(
      'PROVIDER_EVENT_CONFLICT',
      'Provider event replay contained different normalized event facts',
      jsonb_build_object(
        'externalProvider',
          v_provider,
        'providerEventId',
          v_provider_event_id
      )
    );
  end if;

  v_is_duplicate := true;

  return jsonb_build_object(
    'providerWebhookEventId',
      v_existing.id,
    'externalProvider',
      v_existing.external_provider,
    'providerEventId',
      v_existing.provider_event_id,
    'providerEventType',
      v_existing.provider_event_type,
    'bodySha256',
      v_existing.body_sha256,
    'correlationId',
      v_existing.correlation_id,
    'signatureVerified',
      v_existing.signature_verified,
    'duplicateProviderEvent',
      v_is_duplicate
  );
end;
$$;

revoke all
on function haulvia_command.apply_p2e_receive_provider_webhook(jsonb)
from public;


create or replace function haulvia_command.command_receive_provider_webhook(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select haulvia_command.apply_p2e_receive_provider_webhook(
    p_request
  );
$$;

revoke all
on function haulvia_command.command_receive_provider_webhook(jsonb)
from public;


-- ============================================================================
-- P2E-BLOCK-2-END
-- ============================================================================

-- ============================================================================
-- P2E-BLOCK-3A-BEGIN
-- Dedicated inbound payment-provider callback authority
--
-- Historical Block A remains immutable.
-- These prospective CREATE OR REPLACE definitions change only the trusted
-- worker authority for provider-originated payment outcomes.
-- ============================================================================


-- ============================================================================
-- 18. A16 provider success outcome
-- PAYMENT_WORKER -> PAYMENT_PROVIDER_CALLBACK
-- ============================================================================

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
    p_request ->> 'workerAuthority', array['PAYMENT_PROVIDER_CALLBACK']
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


-- ============================================================================
-- 19. A17 provider failure / timeout / late-success outcome
-- PAYMENT_WORKER -> PAYMENT_PROVIDER_CALLBACK
-- ============================================================================

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
    p_request ->> 'workerAuthority', array['PAYMENT_PROVIDER_CALLBACK']
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


-- ============================================================================
-- P2E-BLOCK-3A-END
-- ============================================================================

-- ============================================================================
-- P2E-BLOCK-3B-BEGIN
-- Verified webhook dispatch into canonical financial commands
-- ============================================================================


-- ============================================================================
-- 20. Strengthen webhook dispatch evidence
--
-- The adapter request is the correlation bridge between provider integration
-- evidence and Haulvia's existing financial source of truth.
-- ============================================================================

alter table haulvia.provider_webhook_dispatches
  add column provider_adapter_request_id uuid
    references haulvia.provider_adapter_requests(id);

alter table haulvia.provider_webhook_dispatches
  add column shipment_id uuid
    references haulvia.shipments(id);

alter table haulvia.provider_webhook_dispatches
  add constraint provider_webhook_dispatches_committed_target_ck
  check (
    status <> 'COMMITTED'
    or (
      target_command is not null
      and command_request_hash is not null
      and provider_adapter_request_id is not null
      and shipment_id is not null
    )
  );


-- ============================================================================
-- 21. Dispatch one verified provider event
--
-- Supported automatic financial callback routes:
--
-- PAYMENT_AUTHORIZE / PAYMENT_CAPTURE
--   SUCCEEDED    -> command_confirm_paid_assignment
--   FAILED       -> command_release_failed_reservation
--   TIMED_OUT    -> command_release_failed_reservation
--   LATE_SUCCESS -> command_release_failed_reservation
--
-- DRIVER_PAYOUT
--   SUCCEEDED -> command_confirm_driver_payout
--   FAILED    -> command_handle_payout_failure
--
-- Other recognized provider operations remain retained integration evidence
-- but are not automatically dispatched here. In particular, refunds and
-- financial adjustments continue through their separately authorized
-- canonical D09 path.
-- ============================================================================

create or replace function haulvia_command.apply_p2e_dispatch_provider_webhook(
  p_request jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_event_id uuid :=
    haulvia_command.required_uuid(
      p_request,
      'providerWebhookEventId'
    );

  v_command_hash text :=
    haulvia_command.required_text(
      p_request,
      'commandRequestSha256'
    );

  v_command_request jsonb :=
    coalesce(
      p_request -> 'commandRequest',
      '{}'::jsonb
    );

  v_event haulvia.provider_webhook_events%rowtype;
  v_adapter haulvia.provider_adapter_requests%rowtype;
  v_existing haulvia.provider_webhook_dispatches%rowtype;

  v_operation haulvia.provider_adapter_operation;
  v_outcome text;

  v_caller_authority text;
  v_required_authority text;
  v_target_command text;

  v_adapter_request_id uuid;
  v_shipment_id uuid;

  v_payment_intent haulvia.payment_intents%rowtype;
  v_reservation_id uuid;

  v_provider_reference text;
  v_provider_amount numeric;
  v_provider_currency text;

  v_domain_request jsonb;
  v_domain_result jsonb;

  v_attempt_no integer;
  v_dispatch_id uuid;

  v_started_at timestamptz :=
    clock_timestamp();

  v_completed_at timestamptz;

  v_sqlstate text;
  v_message text;
  v_detail text;
  v_detail_json jsonb;
  v_error_code text;
  v_error_context jsonb;
begin
  -- -------------------------------------------------------------------------
  -- Trusted callback caller
  -- -------------------------------------------------------------------------

  v_caller_authority :=
    haulvia_command.assert_p2e_webhook_worker(
      p_request
    );

  if v_command_hash !~ '^[0-9a-f]{64}$' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'commandRequestSha256 must be a lowercase SHA-256 digest'
    );
  end if;

  if jsonb_typeof(v_command_request) <> 'object' then
    perform haulvia_command.fail(
      'INVALID_REQUEST',
      'commandRequest must be a JSON object'
    );
  end if;

  perform haulvia_command.assert_p2e_safe_json(
    v_command_request,
    'provider webhook domain command request'
  );


  -- -------------------------------------------------------------------------
  -- Lock immutable webhook event
  -- -------------------------------------------------------------------------

  select *
  into v_event
  from haulvia.provider_webhook_events pwe
  where pwe.id = v_event_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'NOT_FOUND',
      'Provider webhook event was not found'
    );
  end if;

  if v_event.signature_verified is distinct from true then
    perform haulvia_command.fail(
      'WEBHOOK_SIGNATURE_INVALID',
      'Only signature-verified provider events may be dispatched'
    );
  end if;

  if v_caller_authority <> v_event.verifier_authority then
    perform haulvia_command.fail(
      'NOT_AUTHORIZED',
      'Webhook dispatch authority must match the verified ingress authority'
    );
  end if;


  -- -------------------------------------------------------------------------
  -- Normalize operation and outcome from the immutable event
  -- -------------------------------------------------------------------------

  begin
    v_operation :=
      pg_catalog.upper(
        haulvia_command.required_text(
          v_event.normalized_event_snapshot,
          'operation'
        )
      )::haulvia.provider_adapter_operation;
  exception
    when invalid_text_representation then
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Webhook normalized operation is not recognized'
      );
  end;

  v_outcome :=
    pg_catalog.upper(
      haulvia_command.required_text(
        v_event.normalized_event_snapshot,
        'outcome'
      )
    );

  v_provider_reference :=
    nullif(
      btrim(
        v_event.normalized_event_snapshot
          ->> 'providerReference'
      ),
      ''
    );


  -- -------------------------------------------------------------------------
  -- Static route selection
  --
  -- No target command name is accepted from the caller.
  -- -------------------------------------------------------------------------

  if v_operation in (
    'PAYMENT_AUTHORIZE',
    'PAYMENT_CAPTURE'
  ) then
    v_required_authority :=
      'PAYMENT_PROVIDER_CALLBACK';

    if v_outcome = 'SUCCEEDED' then
      v_target_command :=
        'command_confirm_paid_assignment';

    elsif v_outcome in (
      'FAILED',
      'TIMED_OUT',
      'LATE_SUCCESS'
    ) then
      v_target_command :=
        'command_release_failed_reservation';

    else
      v_target_command := null;
    end if;

  elsif v_operation = 'DRIVER_PAYOUT' then
    v_required_authority :=
      'PAYOUT_PROVIDER_CALLBACK';

    if v_outcome = 'SUCCEEDED' then
      v_target_command :=
        'command_confirm_driver_payout';

    elsif v_outcome = 'FAILED' then
      v_target_command :=
        'command_handle_payout_failure';

    else
      v_target_command := null;
    end if;

  else
    v_target_command := null;
  end if;


  -- -------------------------------------------------------------------------
  -- Callback-authority separation
  -- -------------------------------------------------------------------------

  if v_required_authority is not null
     and v_caller_authority <> v_required_authority then
    perform haulvia_command.fail(
      'NOT_AUTHORIZED',
      'Provider callback authority does not match the normalized financial operation',
      jsonb_build_object(
        'operation',
          v_operation,
        'requiredAuthority',
          v_required_authority,
        'receivedAuthority',
          v_caller_authority
      )
    );
  end if;


  -- -------------------------------------------------------------------------
  -- Exact committed-dispatch replay
  -- -------------------------------------------------------------------------

  select *
  into v_existing
  from haulvia.provider_webhook_dispatches pwd
  where pwd.provider_webhook_event_id = v_event.id
    and pwd.status = 'COMMITTED'
  order by pwd.dispatch_attempt_no desc
  limit 1;

  if found then
    -- Committed replay must preserve provider adapter correlation.
    --
    -- The originally committed adapter request is part of the immutable
    -- financial-correlation evidence. A replay using another adapter request
    -- must therefore fail closed even when its command hash is unchanged.
    v_adapter_request_id :=
      haulvia_command.required_uuid(
        p_request,
        'providerAdapterRequestId'
      );

    if v_existing.provider_adapter_request_id
         is distinct from v_adapter_request_id then
      perform haulvia_command.fail(
        'PROVIDER_EVENT_CONFLICT',
        'Committed webhook dispatch was replayed with a different provider adapter request',
        jsonb_build_object(
          'providerWebhookEventId',
            v_event.id,
          'existingProviderAdapterRequestId',
            v_existing.provider_adapter_request_id,
          'receivedProviderAdapterRequestId',
            v_adapter_request_id
        )
      );
    end if;

    if v_existing.normalized_operation
         is distinct from v_operation
       or v_existing.normalized_outcome
         is distinct from v_outcome
       or v_existing.target_command
         is distinct from v_target_command
       or v_existing.command_request_hash
         is distinct from v_command_hash then
      perform haulvia_command.fail(
        'PROVIDER_EVENT_CONFLICT',
        'Committed webhook dispatch was replayed with different command facts',
        jsonb_build_object(
          'providerWebhookEventId',
            v_event.id,
          'existingTargetCommand',
            v_existing.target_command,
          'receivedTargetCommand',
            v_target_command
        )
      );
    end if;

    return jsonb_build_object(
      'providerWebhookEventId',
        v_event.id,
      'providerWebhookDispatchId',
        v_existing.id,
      'providerAdapterRequestId',
        v_existing.provider_adapter_request_id,
      'shipmentId',
        v_existing.shipment_id,
      'operation',
        v_existing.normalized_operation,
      'outcome',
        v_existing.normalized_outcome,
      'targetCommand',
        v_existing.target_command,
      'dispatchStatus',
        v_existing.status,
      'commandResult',
        v_existing.command_result,
      'duplicateDispatch',
        true
    );
  end if;


  -- -------------------------------------------------------------------------
  -- Unsupported recognized event
  --
  -- Retain the dispatch decision but do not mutate financial state.
  -- -------------------------------------------------------------------------

  if v_target_command is null then
    select *
    into v_existing
    from haulvia.provider_webhook_dispatches pwd
    where pwd.provider_webhook_event_id = v_event.id
      and pwd.status = 'SKIPPED_UNSUPPORTED'
    order by pwd.dispatch_attempt_no desc
    limit 1;

    if found then
      if v_existing.normalized_operation
           is distinct from v_operation
         or v_existing.normalized_outcome
           is distinct from v_outcome
         or v_existing.command_request_hash
           is distinct from v_command_hash then
        perform haulvia_command.fail(
          'PROVIDER_EVENT_CONFLICT',
          'Unsupported webhook replay contained different dispatch facts'
        );
      end if;

      return jsonb_build_object(
        'providerWebhookEventId',
          v_event.id,
        'providerWebhookDispatchId',
          v_existing.id,
        'operation',
          v_operation,
        'outcome',
          v_outcome,
        'dispatchStatus',
          'SKIPPED_UNSUPPORTED',
        'duplicateDispatch',
          true
      );
    end if;

    select
      coalesce(
        max(pwd.dispatch_attempt_no),
        0
      ) + 1
    into v_attempt_no
    from haulvia.provider_webhook_dispatches pwd
    where pwd.provider_webhook_event_id =
      v_event.id;

    v_completed_at := clock_timestamp();

    insert into haulvia.provider_webhook_dispatches (
      provider_webhook_event_id,
      dispatch_attempt_no,
      normalized_operation,
      normalized_outcome,
      target_command,
      command_idempotency_key,
      command_request_hash,
      correlation_id,
      status,
      command_result,
      error_context,
      started_at,
      completed_at
    )
    values (
      v_event.id,
      v_attempt_no,
      v_operation,
      v_outcome,
      null,
      null,
      v_command_hash,
      v_event.correlation_id,
      'SKIPPED_UNSUPPORTED',
      jsonb_build_object(
        'skipped',
          true,
        'reason',
          'UNSUPPORTED_OPERATION_OR_OUTCOME'
      ),
      '{}'::jsonb,
      v_started_at,
      v_completed_at
    )
    returning id
    into v_dispatch_id;

    return jsonb_build_object(
      'providerWebhookEventId',
        v_event.id,
      'providerWebhookDispatchId',
        v_dispatch_id,
      'operation',
        v_operation,
      'outcome',
        v_outcome,
      'dispatchStatus',
        'SKIPPED_UNSUPPORTED',
      'duplicateDispatch',
        false
    );
  end if;


  -- -------------------------------------------------------------------------
  -- Supported financial callbacks require an outbound adapter correlation.
  -- -------------------------------------------------------------------------

  v_adapter_request_id :=
    haulvia_command.required_uuid(
      p_request,
      'providerAdapterRequestId'
    );

  select *
  into v_adapter
  from haulvia.provider_adapter_requests par
  where par.id = v_adapter_request_id
  for update;

  if not found then
    perform haulvia_command.fail(
      'NOT_FOUND',
      'Provider adapter request was not found for webhook dispatch'
    );
  end if;

  if v_adapter.status <> 'SUBMITTED' then
    perform haulvia_command.fail(
      'INVALID_STATE',
      'Provider webhook dispatch requires a submitted adapter request'
    );
  end if;

  if v_adapter.external_provider
       <> v_event.external_provider
     or v_adapter.operation
       <> v_operation then
    perform haulvia_command.fail(
      'PROVIDER_EVENT_CONFLICT',
      'Webhook event does not match the correlated provider adapter request',
      jsonb_build_object(
        'adapterProvider',
          v_adapter.external_provider,
        'eventProvider',
          v_event.external_provider,
        'adapterOperation',
          v_adapter.operation,
        'eventOperation',
          v_operation
      )
    );
  end if;

  v_shipment_id :=
    v_adapter.shipment_id;


  -- -------------------------------------------------------------------------
  -- Provider-normalized amount/currency
  -- -------------------------------------------------------------------------

  if v_event.normalized_event_snapshot
       ? 'amount' then
    begin
      v_provider_amount :=
        (
          v_event.normalized_event_snapshot
            ->> 'amount'
        )::numeric;
    exception
      when invalid_text_representation then
        perform haulvia_command.fail(
          'INVALID_REQUEST',
          'Normalized provider amount must be numeric'
        );
    end;
  end if;

  v_provider_currency :=
    nullif(
      btrim(
        v_event.normalized_event_snapshot
          ->> 'currency'
      ),
      ''
    );


  -- -------------------------------------------------------------------------
  -- Build canonical domain request.
  --
  -- Caller-supplied commandRequest contains only command-specific fields that
  -- cannot be derived from retained integration evidence. Authoritative
  -- correlation/provider fields below overwrite any caller-supplied values.
  -- -------------------------------------------------------------------------

  v_domain_request :=
    v_command_request
    || jsonb_build_object(
      'commandId',
        v_event.id,
      'idempotencyKey',
        'provider-webhook:' || v_event.id::text,
      'requestHash',
        v_command_hash,
      'actorProfileId',
        null,
      'workerAuthority',
        v_required_authority,
      'shipmentId',
        v_shipment_id,
      'requestedAt',
        v_event.received_at,
      'providerEventId',
        v_event.provider_event_id,
      'externalProvider',
        v_event.external_provider,
      'externalReference',
        v_provider_reference,
      'providerOccurredAt',
        v_event.provider_occurred_at
    );


  -- -------------------------------------------------------------------------
  -- Payment callback bindings
  -- -------------------------------------------------------------------------

  if v_operation in (
    'PAYMENT_AUTHORIZE',
    'PAYMENT_CAPTURE'
  ) then
    if v_adapter.payment_intent_id is null then
      perform haulvia_command.fail(
        'PAYMENT_NOT_FOUND',
        'Payment webhook adapter request is missing its retained payment intent'
      );
    end if;

    select *
    into v_payment_intent
    from haulvia.payment_intents pi
    where pi.id = v_adapter.payment_intent_id
      and pi.shipment_id = v_shipment_id;

    if not found then
      perform haulvia_command.fail(
        'PAYMENT_NOT_FOUND',
        'Correlated payment intent was not found'
      );
    end if;

    if v_payment_intent.external_provider
         <> v_event.external_provider then
      perform haulvia_command.fail(
        'PROVIDER_EVENT_CONFLICT',
        'Webhook provider does not match the retained payment intent provider'
      );
    end if;

    v_reservation_id :=
      v_payment_intent.offer_reservation_id;

    if v_reservation_id is null then
      perform haulvia_command.fail(
        'NOT_FOUND',
        'Correlated payment intent has no retained reservation'
      );
    end if;

    if v_provider_amount is null
       or v_provider_currency is null then
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Payment webhook normalization requires amount and currency'
      );
    end if;

    v_domain_request :=
      v_domain_request
      || jsonb_build_object(
        'paymentIntentId',
          v_payment_intent.id,
        'reservationId',
          v_reservation_id,
        'amount',
          v_provider_amount,
        'currency',
          pg_catalog.upper(v_provider_currency),
        'providerPayload',
          v_event.normalized_event_snapshot
      );

    if v_target_command =
         'command_confirm_paid_assignment' then
      v_domain_request :=
        v_domain_request
        || jsonb_build_object(
          'securedAmount',
            v_provider_amount,
          'transactionType',
            coalesce(
              nullif(
                v_event.normalized_event_snapshot
                  ->> 'transactionType',
                ''
              ),
              case
                when v_operation =
                  'PAYMENT_AUTHORIZE'
                then 'AUTHORIZE'
                else 'CAPTURE'
              end
            )
        );

    else
      if v_outcome = 'TIMED_OUT' then
        v_domain_request :=
          v_domain_request
          || jsonb_build_object(
            'failureCategory',
              'TIMEOUT',
            'lateSuccess',
              false
          );

      elsif v_outcome = 'LATE_SUCCESS' then
        v_domain_request :=
          v_domain_request
          || jsonb_build_object(
            'failureCategory',
              'LATE_SUCCESS',
            'lateSuccess',
              true
          );

      else
        v_domain_request :=
          v_domain_request
          || jsonb_build_object(
            'failureCategory',
              coalesce(
                nullif(
                  v_event.normalized_event_snapshot
                    ->> 'failureCategory',
                  ''
                ),
                'FAILED'
              ),
            'lateSuccess',
              false
          );
      end if;
    end if;


  -- -------------------------------------------------------------------------
  -- Payout callback bindings
  -- -------------------------------------------------------------------------

  elsif v_operation = 'DRIVER_PAYOUT' then
    if v_adapter.payout_id is null
       or v_adapter.payout_transaction_id is null then
      perform haulvia_command.fail(
        'PAYOUT_NOT_FOUND',
        'Payout webhook adapter request is missing retained payout references'
      );
    end if;

    if v_provider_amount is null then
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Payout webhook normalization requires amount'
      );
    end if;

    if v_provider_reference is null then
      perform haulvia_command.fail(
        'INVALID_REQUEST',
        'Payout webhook normalization requires providerReference'
      );
    end if;

    v_domain_request :=
      v_domain_request
      || jsonb_build_object(
        'expectedPayoutId',
          v_adapter.payout_id,
        'payoutRequestTransactionId',
          v_adapter.payout_transaction_id,
        'payoutAmount',
          v_provider_amount,
        'providerResponse',
          v_event.normalized_event_snapshot
      );
  end if;


  -- -------------------------------------------------------------------------
  -- Final request safety check after authoritative merge
  -- -------------------------------------------------------------------------

  perform haulvia_command.assert_p2e_safe_json(
    v_domain_request,
    'provider webhook canonical domain command'
  );


  -- -------------------------------------------------------------------------
  -- Allocate append-only dispatch attempt number while event row is locked.
  -- -------------------------------------------------------------------------

  select
    coalesce(
      max(pwd.dispatch_attempt_no),
      0
    ) + 1
  into v_attempt_no
  from haulvia.provider_webhook_dispatches pwd
  where pwd.provider_webhook_event_id =
    v_event.id;


  -- -------------------------------------------------------------------------
  -- Execute canonical financial command in a subtransaction.
  --
  -- Domain failure rolls back the canonical command work, but the outer
  -- dispatch transaction retains a normalized FAILED dispatch record.
  -- -------------------------------------------------------------------------

  begin
    case v_target_command
      when 'command_confirm_paid_assignment' then
        v_domain_result :=
          haulvia_command.command_confirm_paid_assignment(
            v_domain_request
          );

      when 'command_release_failed_reservation' then
        v_domain_result :=
          haulvia_command.command_release_failed_reservation(
            v_domain_request
          );

      when 'command_confirm_driver_payout' then
        v_domain_result :=
          haulvia_command.command_confirm_driver_payout(
            v_domain_request
          );

      when 'command_handle_payout_failure' then
        v_domain_result :=
          haulvia_command.command_handle_payout_failure(
            v_domain_request
          );

      else
        perform haulvia_command.fail(
          'INVALID_REQUEST',
          'Webhook target command is not an approved P2E financial route'
        );
    end case;

  exception
    when others then
      get stacked diagnostics
        v_sqlstate = returned_sqlstate,
        v_message = message_text,
        v_detail = pg_exception_detail;

      begin
        if nullif(v_detail, '') is null then
          v_detail_json := '{}'::jsonb;
        else
          v_detail_json := v_detail::jsonb;
        end if;
      exception
        when others then
          v_detail_json := '{}'::jsonb;
      end;

      v_error_code :=
        coalesce(
          nullif(
            v_detail_json ->> 'code',
            ''
          ),
          'DATABASE_ERROR'
        );

      v_error_context :=
        jsonb_build_object(
          'sqlstate',
            coalesce(v_sqlstate, ''),
          'message',
            coalesce(v_message, ''),
          'domainContext',
            coalesce(
              v_detail_json -> 'context',
              '{}'::jsonb
            )
        );

      v_completed_at :=
        clock_timestamp();

      insert into haulvia.provider_webhook_dispatches (
        provider_webhook_event_id,
        provider_adapter_request_id,
        shipment_id,
        dispatch_attempt_no,
        normalized_operation,
        normalized_outcome,
        target_command,
        command_idempotency_key,
        command_request_hash,
        correlation_id,
        status,
        command_result,
        haulvia_error_code,
        error_context,
        started_at,
        completed_at
      )
      values (
        v_event.id,
        v_adapter.id,
        v_shipment_id,
        v_attempt_no,
        v_operation,
        v_outcome,
        v_target_command,
        'provider-webhook:' || v_event.id::text,
        v_command_hash,
        v_event.correlation_id,
        'FAILED',
        '{}'::jsonb,
        v_error_code,
        v_error_context,
        v_started_at,
        v_completed_at
      )
      returning id
      into v_dispatch_id;

      return jsonb_build_object(
        'providerWebhookEventId',
          v_event.id,
        'providerWebhookDispatchId',
          v_dispatch_id,
        'providerAdapterRequestId',
          v_adapter.id,
        'shipmentId',
          v_shipment_id,
        'operation',
          v_operation,
        'outcome',
          v_outcome,
        'targetCommand',
          v_target_command,
        'dispatchStatus',
          'FAILED',
        'haulviaErrorCode',
          v_error_code,
        'errorContext',
          v_error_context,
        'duplicateDispatch',
          false
      );
  end;


  -- -------------------------------------------------------------------------
  -- Canonical financial mutation succeeded.
  -- Retain exactly one committed dispatch for the provider event.
  -- -------------------------------------------------------------------------

  v_completed_at :=
    clock_timestamp();

  insert into haulvia.provider_webhook_dispatches (
    provider_webhook_event_id,
    provider_adapter_request_id,
    shipment_id,
    dispatch_attempt_no,
    normalized_operation,
    normalized_outcome,
    target_command,
    command_idempotency_key,
    command_request_hash,
    correlation_id,
    status,
    command_result,
    error_context,
    started_at,
    completed_at
  )
  values (
    v_event.id,
    v_adapter.id,
    v_shipment_id,
    v_attempt_no,
    v_operation,
    v_outcome,
    v_target_command,
    'provider-webhook:' || v_event.id::text,
    v_command_hash,
    v_event.correlation_id,
    'COMMITTED',
    coalesce(
      v_domain_result,
      '{}'::jsonb
    ),
    '{}'::jsonb,
    v_started_at,
    v_completed_at
  )
  returning id
  into v_dispatch_id;

  return jsonb_build_object(
    'providerWebhookEventId',
      v_event.id,
    'providerWebhookDispatchId',
      v_dispatch_id,
    'providerAdapterRequestId',
      v_adapter.id,
    'shipmentId',
      v_shipment_id,
    'operation',
      v_operation,
    'outcome',
      v_outcome,
    'targetCommand',
      v_target_command,
    'dispatchStatus',
      'COMMITTED',
    'commandResult',
      v_domain_result,
    'duplicateDispatch',
      false
  );
end;
$$;

revoke all
on function haulvia_command.apply_p2e_dispatch_provider_webhook(jsonb)
from public;


create or replace function haulvia_command.command_dispatch_provider_webhook(
  p_request jsonb
)
returns jsonb
language sql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
  select
    haulvia_command.apply_p2e_dispatch_provider_webhook(
      p_request
    );
$$;

revoke all
on function haulvia_command.command_dispatch_provider_webhook(jsonb)
from public;


-- ============================================================================
-- P2E-BLOCK-3B-END
-- ============================================================================

-- ============================================================================
-- P2E-BLOCK-4-COMMAND-MANIFEST-PRIVILEGE-CLOSURE
--
-- Backend command execution is allowlist-only.
-- Exact approved surface:
--   86 preserved pre-P2E command wrappers
--   + 5 P2E command wrappers
--   = 91 service-role executable command signatures.
--
-- Internal helpers remain unavailable to service_role and client roles.
-- Raw P2E integration tables remain unavailable to all backend/client roles.
-- ============================================================================

revoke all privileges
on all functions in schema haulvia_command
from public, anon, authenticated, service_role;

grant execute
on function
  haulvia_command.command_abandon_private_storage_object(jsonb),
  haulvia_command.command_accept_firm_route_match(jsonb),
  haulvia_command.command_advance_to_next_stop(jsonb),
  haulvia_command.command_approve_private_storage_deletion(jsonb),
  haulvia_command.command_assign_cargo_to_stops(jsonb),
  haulvia_command.command_authorize_continue_after_stop_failure(jsonb),
  haulvia_command.command_authorize_custody_transfer(jsonb),
  haulvia_command.command_authorize_route_amendment(jsonb),
  haulvia_command.command_cancel_assigned_before_custody(jsonb),
  haulvia_command.command_cancel_before_any_custody(jsonb),
  haulvia_command.command_cancel_draft(jsonb),
  haulvia_command.command_cancel_marketplace_shipment(jsonb),
  haulvia_command.command_cancel_pre_assignment(jsonb),
  haulvia_command.command_cancel_private_storage_deletion(jsonb),
  haulvia_command.command_cancel_provider_adapter_request(jsonb),
  haulvia_command.command_close_failed_first_pickup(jsonb),
  haulvia_command.command_close_last_active_offer(jsonb),
  haulvia_command.command_complete_planned_route(jsonb),
  haulvia_command.command_complete_shipment(jsonb),
  haulvia_command.command_confirm_arrival_at_first_pickup(jsonb),
  haulvia_command.command_confirm_arrival_at_stop(jsonb),
  haulvia_command.command_confirm_driver_payout(jsonb),
  haulvia_command.command_confirm_paid_assignment(jsonb),
  haulvia_command.command_confirm_private_storage_purge(jsonb),
  haulvia_command.command_confirm_receiver_receipt(jsonb),
  haulvia_command.command_continue_route_after_failed_stop(jsonb),
  haulvia_command.command_copy_terminal_shipment_for_repost(jsonb),
  haulvia_command.command_correct_first_stop_arrival(jsonb),
  haulvia_command.command_correct_stop_arrival(jsonb),
  haulvia_command.command_counter_offer(jsonb),
  haulvia_command.command_dispatch_provider_webhook(jsonb),
  haulvia_command.command_edit_draft_route(jsonb),
  haulvia_command.command_edit_paused_after_driver_cancellation(jsonb),
  haulvia_command.command_edit_posted_shipment(jsonb),
  haulvia_command.command_expire_confirmation_window(jsonb),
  haulvia_command.command_expire_listing(jsonb),
  haulvia_command.command_finalize_private_storage_object(jsonb),
  haulvia_command.command_handle_payout_failure(jsonb),
  haulvia_command.command_issue_refund_or_adjustment(jsonb),
  haulvia_command.command_mark_private_storage_deletion_pending(jsonb),
  haulvia_command.command_materially_edit_negotiation(jsonb),
  haulvia_command.command_open_dispute(jsonb),
  haulvia_command.command_open_post_delivery_dispute(jsonb),
  haulvia_command.command_pause_marketplace(jsonb),
  haulvia_command.command_place_private_storage_hold(jsonb),
  haulvia_command.command_post_shipment(jsonb),
  haulvia_command.command_prepare_compliance_document_access(jsonb),
  haulvia_command.command_prepare_failed_first_pickup_repost(jsonb),
  haulvia_command.command_prepare_provider_adapter_request(jsonb),
  haulvia_command.command_prepare_stop_evidence_access(jsonb),
  haulvia_command.command_quarantine_private_storage_object(jsonb),
  haulvia_command.command_receive_provider_webhook(jsonb),
  haulvia_command.command_reconfirm_offer_or_firm_match(jsonb),
  haulvia_command.command_record_provider_adapter_attempt(jsonb),
  haulvia_command.command_record_route_update(jsonb),
  haulvia_command.command_register_compliance_document(jsonb),
  haulvia_command.command_reject_private_storage_deletion(jsonb),
  haulvia_command.command_release_driver_before_any_custody(jsonb),
  haulvia_command.command_release_failed_reservation(jsonb),
  haulvia_command.command_release_private_storage_hold(jsonb),
  haulvia_command.command_release_private_storage_quarantine(jsonb),
  haulvia_command.command_report_delivery_problem(jsonb),
  haulvia_command.command_report_failed_delivery_stop(jsonb),
  haulvia_command.command_report_failed_first_pickup(jsonb),
  haulvia_command.command_report_failed_pickup_stop(jsonb),
  haulvia_command.command_report_pre_custody_issue(jsonb),
  haulvia_command.command_report_transit_issue(jsonb),
  haulvia_command.command_repost_paused_shipment(jsonb),
  haulvia_command.command_request_private_storage_deletion(jsonb),
  haulvia_command.command_reserve_private_storage_object(jsonb),
  haulvia_command.command_reserve_selection(jsonb),
  haulvia_command.command_resolve_dispute(jsonb),
  haulvia_command.command_resume_after_resolution(jsonb),
  haulvia_command.command_resume_marketplace(jsonb),
  haulvia_command.command_retry_failed_stop_same_driver(jsonb),
  haulvia_command.command_revise_offer(jsonb),
  haulvia_command.command_save_draft(jsonb),
  haulvia_command.command_secure_cargo_in_storage(jsonb),
  haulvia_command.command_start_first_pickup_service(jsonb),
  haulvia_command.command_start_recovery_leg(jsonb),
  haulvia_command.command_start_route(jsonb),
  haulvia_command.command_start_stop_service(jsonb),
  haulvia_command.command_submit_driver_payout(jsonb),
  haulvia_command.command_submit_first_pickup_evidence(jsonb),
  haulvia_command.command_submit_independent_flex_offer(jsonb),
  haulvia_command.command_submit_partner_flex_offer(jsonb),
  haulvia_command.command_submit_stop_evidence(jsonb),
  haulvia_command.command_verify_delivery_stop(jsonb),
  haulvia_command.command_verify_first_pickup(jsonb),
  haulvia_command.command_verify_pickup_stop(jsonb),
  haulvia_command.command_verify_return_handoff(jsonb)
to service_role;


revoke all privileges
on table
  haulvia.provider_adapter_requests,
  haulvia.provider_adapter_attempts,
  haulvia.provider_webhook_events,
  haulvia.provider_webhook_dispatches
from public, anon, authenticated, service_role;


-- RLS is intentionally retained with zero direct policies.
alter table haulvia.provider_adapter_requests
  enable row level security;

alter table haulvia.provider_adapter_attempts
  enable row level security;

alter table haulvia.provider_webhook_events
  enable row level security;

alter table haulvia.provider_webhook_dispatches
  enable row level security;


-- ============================================================================
-- End P2E Block 4
-- ============================================================================

COMMIT;
