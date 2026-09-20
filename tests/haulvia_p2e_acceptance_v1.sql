-- Haulvia Phase 2 Block P2E acceptance suite v1
--
-- Contract:
--   docs/Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md
--
-- Frozen contract SHA-256:
--   60C0408922C0474B3338C5E1274B6C74B570F57B18F01ACE62E7E718EBB7140A
--
-- This file is executed after the P2E migration in the SAME transaction.
-- The migration intentionally owns BEGIN.
--
-- Part 1 implements P2E-01 through P2E-37.
-- P2E-38 through P2E-48 are appended in Part 2.
--
-- Final suite remains rollback-only.


set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


-- ============================================================================
-- Test harness
-- ============================================================================

create temporary table p2e_test_results (
  requirement_id text primary key,
  test_name text not null,
  passed boolean not null,
  detail text not null
) on commit drop;


create or replace function pg_temp.assert_requirement(
  p_requirement_id text,
  p_test_name text,
  p_condition boolean,
  p_detail text
)
returns void
language plpgsql
as $$
begin
  insert into p2e_test_results (
    requirement_id,
    test_name,
    passed,
    detail
  )
  values (
    p_requirement_id,
    p_test_name,
    coalesce(p_condition, false),
    case
      when coalesce(p_condition, false)
        then 'passed'
      else p_detail
    end
  );
end;
$$;


create or replace function pg_temp.expect_p2e_error(
  p_sql text,
  p_expected_code text
)
returns boolean
language plpgsql
as $$
declare
  v_detail text;
  v_detail_json jsonb;
begin
  begin
    execute p_sql;
    return false;

  exception
    when others then
      get stacked diagnostics
        v_detail = pg_exception_detail;

      begin
        v_detail_json :=
          coalesce(
            nullif(v_detail, ''),
            '{}'
          )::jsonb;
      exception
        when others then
          return false;
      end;

      return
        v_detail_json ->> 'code' =
          p_expected_code;
  end;
end;
$$;


-- ============================================================================
-- P2E-01 through P2E-07
-- Provider neutrality / preserved canonical model
-- ============================================================================

select pg_temp.assert_requirement(
  'P2E-01',
  'P2E remains provider-neutral and introduces no provider-branded database identifiers',
  not exists (
    select 1
    from (
      select lower(c.relname) as object_name
      from pg_class c
      join pg_namespace n
        on n.oid = c.relnamespace
      where n.nspname = 'haulvia'
        and c.relname like 'provider_%'

      union all

      select lower(t.typname)
      from pg_type t
      join pg_namespace n
        on n.oid = t.typnamespace
      where n.nspname = 'haulvia'
        and t.typname like 'provider_%'

      union all

      select lower(p.proname)
      from pg_proc p
      join pg_namespace n
        on n.oid = p.pronamespace
      where n.nspname = 'haulvia_command'
        and (
          p.proname like '%provider%'
          or p.proname like '%p2e%'
        )
    ) x
    where x.object_name ~
      '(stripe|paypal|adyen|braintree|square|worldpay|moneris|checkout)'
  ),
  'Provider-branded database identifier detected.'
);


select pg_temp.assert_requirement(
  'P2E-02',
  'Existing Haulvia financial tables remain canonical',
  to_regclass('haulvia.shipment_customer_payment_axes') is not null
  and to_regclass('haulvia.shipment_driver_payout_axes') is not null
  and to_regclass('haulvia.customer_payment_method_refs') is not null
  and to_regclass('haulvia.payment_intents') is not null
  and to_regclass('haulvia.payment_transactions') is not null
  and to_regclass('haulvia.driver_payouts') is not null
  and to_regclass('haulvia.payout_transactions') is not null
  and to_regclass('haulvia.financial_holds') is not null
  and to_regclass('haulvia.financial_adjustments') is not null,
  'One or more canonical financial relations are missing.'
);


select pg_temp.assert_requirement(
  'P2E-03',
  'Integration relations supplement rather than duplicate canonical financial state',
  (
    select count(*) = 4
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r','p')
      and c.relname in (
        'provider_adapter_requests',
        'provider_adapter_attempts',
        'provider_webhook_events',
        'provider_webhook_dispatches'
      )
  )
  and not exists (
    select 1
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind in ('r','p')
      and c.relname like 'provider_%'
      and c.relname ~
        '(payment_state|payout_state|refund_state|adjustment_state)'
  ),
  'Unexpected duplicate provider financial-state relation detected.'
);


select pg_temp.assert_requirement(
  'P2E-04',
  'Acceptance requires no live provider network or credential dependency',
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and (
        p.proname like '%p2e%'
        or p.proname in (
          'command_prepare_provider_adapter_request',
          'command_record_provider_adapter_attempt',
          'command_cancel_provider_adapter_request',
          'command_receive_provider_webhook',
          'command_dispatch_provider_webhook'
        )
      )
      and p.prokind in ('f', 'p')
      and lower(coalesce(p.prosrc, '')) ~
        '(http_get|http_post|net\.http|curl|fetch\()'
  ),
  'P2E database function appears to perform a live network call.'
);


select pg_temp.assert_requirement(
  'P2E-05',
  'Raw credentials and payment secrets are not represented as persisted P2E columns',
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'haulvia'
      and table_name in (
        'provider_adapter_requests',
        'provider_adapter_attempts',
        'provider_webhook_events',
        'provider_webhook_dispatches'
      )
      and lower(column_name) ~
        '(card_number|cvv|cvc|api_key|api_secret|signing_secret|webhook_secret|access_token|refresh_token|bank_account_number|routing_number|iban|private_key)'
  )
  and position(
    'clientsecret'
    in lower(
      pg_get_functiondef(
        'haulvia_command.assert_p2e_safe_json(jsonb,text)'::regprocedure
      )
    )
  ) > 0
  and position(
    'signingsecret'
    in lower(
      pg_get_functiondef(
        'haulvia_command.assert_p2e_safe_json(jsonb,text)'::regprocedure
      )
    )
  ) > 0,
  'Sensitive persisted column or incomplete sanitizer detected.'
);


select pg_temp.assert_requirement(
  'P2E-06',
  'customer_payment_method_refs remains an opaque provider-reference abstraction',
  to_regclass(
    'haulvia.customer_payment_method_refs'
  ) is not null
  and not exists (
    select 1
    from information_schema.columns
    where table_schema = 'haulvia'
      and table_name =
        'customer_payment_method_refs'
      and lower(column_name) ~
        '(card_number|cvv|cvc|account_number|routing_number|iban|access_token|secret)'
  ),
  'customer_payment_method_refs exposes raw payment credentials.'
);


select pg_temp.assert_requirement(
  'P2E-07',
  'All 86 pre-P2E command wrappers remain present',
  (
    select count(*) = 91
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname like
        'command\_%'
        escape '\'
  )
  and (
    select count(*) = 5
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname in (
        'command_prepare_provider_adapter_request',
        'command_record_provider_adapter_attempt',
        'command_cancel_provider_adapter_request',
        'command_receive_provider_webhook',
        'command_dispatch_provider_webhook'
      )
  ),
  'Expected 86 preserved wrappers plus exactly five P2E wrappers.'
);


-- ============================================================================
-- P2E-08 through P2E-12
-- Backend command adapter
--
-- These flags are injected by the final local gate only after the permanent
-- TypeScript adapter acceptance suite succeeds.
-- ============================================================================

select pg_temp.assert_requirement(
  'P2E-08',
  'Backend command adapter uses an explicit allowlist manifest',
  current_setting(
    'haulvia.p2e.adapter_manifest_ok',
    true
  ) = 'true',
  'Static manifest verification was not proven by the outer acceptance gate.'
);


select pg_temp.assert_requirement(
  'P2E-09',
  'Unknown commands and internal helpers cannot be invoked through the backend adapter',
  current_setting(
    'haulvia.p2e.adapter_acceptance_ok',
    true
  ) = 'true'
  and not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname not like
        'command\_%'
        escape '\'
      and has_function_privilege(
        'service_role',
        p.oid,
        'EXECUTE'
      )
  ),
  'Adapter acceptance or wrapper-only service-role execution invariant failed.'
);


select pg_temp.assert_requirement(
  'P2E-10',
  'No generic dynamic SQL execute-by-name gateway exists',
  current_setting(
    'haulvia.p2e.adapter_static_routing_ok',
    true
  ) = 'true'
  and not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname like '%p2e%'
      and lower(coalesce(p.prosrc, '')) ~
        'execute[[:space:]]+format'
  ),
  'Dynamic request-controlled execution surface detected.'
);


select pg_temp.assert_requirement(
  'P2E-11',
  'Backend command results use normalized command and correlation envelopes',
  current_setting(
    'haulvia.p2e.adapter_acceptance_ok',
    true
  ) = 'true',
  'Permanent TypeScript adapter acceptance did not pass.'
);


select pg_temp.assert_requirement(
  'P2E-12',
  'Haulvia domain errors and safe details survive the adapter boundary',
  current_setting(
    'haulvia.p2e.adapter_acceptance_ok',
    true
  ) = 'true',
  'Permanent TypeScript adapter error-normalization acceptance did not pass.'
);


-- ============================================================================
-- Deterministic outbound fixture
-- ============================================================================

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  'e2e70000-0000-0000-0000-000000000001',
  'p2e-final-customer',
  'CUSTOMER',
  'P2E Final Customer Ltd.',
  'P2E Final Customer'
);


insert into haulvia.profiles (
  id,
  display_name
)
values (
  'e2e70000-0000-0000-0000-000000000002',
  'P2E Final Customer'
);


insert into haulvia.shipments (
  id,
  shipment_reference,
  customer_organization_id,
  customer_profile_id,
  shipment_state,
  pickup_timing,
  service_level,
  currency
)
values (
  'e2e70000-0000-0000-0000-000000000003',
  'HV-20991231-9701',
  'e2e70000-0000-0000-0000-000000000001',
  'e2e70000-0000-0000-0000-000000000002',
  'DRAFT',
  'ASAP',
  'FLEX',
  'CAD'
);


insert into haulvia.payment_intents (
  id,
  shipment_id,
  status,
  amount,
  currency,
  external_provider,
  provider_idempotency_key
)
values (
  'e2e70000-0000-0000-0000-000000000004',
  'e2e70000-0000-0000-0000-000000000003',
  'CREATED',
  125.00,
  'CAD',
  'P2E_MOCK_PROVIDER',
  'p2e-final-payment-intent'
);


create temporary table p2e_fixture_state (
  adapter_request_id uuid,
  webhook_event_id uuid,
  webhook_dispatch_id uuid
) on commit drop;


-- ============================================================================
-- Exercise adapter request replay / conflict and attempt lifecycle.
-- ============================================================================

do $$
declare
  v_request jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_adapter uuid;
  v_failed jsonb;
  v_submitted jsonb;
begin

  v_request :=
    jsonb_build_object(
      'shipmentId',
        'e2e70000-0000-0000-0000-000000000003',

      'operation',
        'PAYMENT_AUTHORIZE',

      'externalProvider',
        'P2E_MOCK_PROVIDER',

      'providerIdempotencyKey',
        'p2e-final-adapter-001',

      'correlationId',
        'e2e70000-0000-0000-0000-000000000005',

      'paymentIntentId',
        'e2e70000-0000-0000-0000-000000000004',

      'requestFingerprintSha256',
        repeat('a',64),

      'requestSnapshot',
        jsonb_build_object(
          'amount',125,
          'currency','CAD',
          'paymentMethodReference',
            'pm_mock_reference'
        ),

      'workerAuthority',
        'PAYMENT_WORKER'
    );


  v_result :=
    haulvia_command.command_prepare_provider_adapter_request(
      v_request
    );

  v_adapter :=
    (
      v_result ->> 'providerAdapterRequestId'
    )::uuid;


  insert into p2e_fixture_state(
    adapter_request_id
  )
  values (
    v_adapter
  );


  v_replay :=
    haulvia_command.command_prepare_provider_adapter_request(
      v_request
    );


  perform pg_temp.assert_requirement(
    'P2E-13',
    'Adapter retry and idempotency preserve request-hash mismatch protection',

    (
      v_replay ->> 'providerAdapterRequestId'
    )::uuid = v_adapter

    and (
      v_replay ->> 'duplicateProviderRequest'
    )::boolean

    and pg_temp.expect_p2e_error(
      format(
        'select haulvia_command.command_prepare_provider_adapter_request(%L::jsonb)',
        jsonb_set(
          v_request,
          '{requestSnapshot}',
          jsonb_build_object(
            'amount',126,
            'currency','CAD',
            'paymentMethodReference',
              'pm_mock_reference'
          )
        )::text
      ),
      'IDEMPOTENCY_KEY_REUSED'
    ),

    'Exact replay or conflicting replay protection failed.'
  );


  perform pg_temp.assert_requirement(
    'P2E-14',
    'Provider operations carry traceable correlation IDs',

    (
      select
        correlation_id =
          'e2e70000-0000-0000-0000-000000000005'
      from haulvia.provider_adapter_requests
      where id = v_adapter
    ),

    'Outbound adapter request did not retain its correlation ID.'
  );


  perform pg_temp.assert_requirement(
    'P2E-15',
    'Provider-neutral outbound adapter-request relation exists',

    to_regclass(
      'haulvia.provider_adapter_requests'
    ) is not null,

    'provider_adapter_requests relation is missing.'
  );


  perform pg_temp.assert_requirement(
    'P2E-16',
    'Provider adapter requests use canonical UUID identity',

    (
      select
        data_type = 'uuid'
      from information_schema.columns
      where table_schema = 'haulvia'
        and table_name =
          'provider_adapter_requests'
        and column_name = 'id'
    )
    and exists (
      select 1
      from pg_constraint con
      where con.conrelid =
        'haulvia.provider_adapter_requests'::regclass
        and con.contype = 'p'
    ),

    'provider_adapter_requests does not use a UUID primary identity.'
  );


  perform pg_temp.assert_requirement(
    'P2E-17',
    'P2E v1 exposes the six frozen provider operations',

    (
      select
        array_agg(
          e.enumlabel::text
          order by e.enumsortorder
        ) =
        array[
          'PAYMENT_AUTHORIZE',
          'PAYMENT_CAPTURE',
          'PAYMENT_VOID',
          'CUSTOMER_REFUND',
          'DRIVER_PAYOUT',
          'FINANCIAL_ADJUSTMENT'
        ]
      from pg_type t
      join pg_namespace n
        on n.oid = t.typnamespace
      join pg_enum e
        on e.enumtypid = t.oid
      where n.nspname = 'haulvia'
        and t.typname =
          'provider_adapter_operation'
    ),

    'provider_adapter_operation labels differ from the frozen six operations.'
  );


  perform pg_temp.assert_requirement(
    'P2E-18',
    'Adapter requests link shipment and canonical financial entities',

    (
      select
        shipment_id =
          'e2e70000-0000-0000-0000-000000000003'
        and payment_intent_id =
          'e2e70000-0000-0000-0000-000000000004'
      from haulvia.provider_adapter_requests
      where id = v_adapter
    )
    and exists (
      select 1
      from pg_constraint
      where conrelid =
        'haulvia.provider_adapter_requests'::regclass
        and contype = 'f'
    ),

    'Adapter request did not retain canonical shipment/payment correlation.'
  );


  perform pg_temp.assert_requirement(
    'P2E-19',
    'Outbound provider and provider idempotency key are required and nonblank',

    (
      select
        external_provider =
          'P2E_MOCK_PROVIDER'
        and provider_idempotency_key =
          'p2e-final-adapter-001'
        and length(
          btrim(external_provider)
        ) > 0
        and length(
          btrim(provider_idempotency_key)
        ) > 0
      from haulvia.provider_adapter_requests
      where id = v_adapter
    ),

    'Required provider/idempotency identity was not retained.'
  );


  perform pg_temp.assert_requirement(
    'P2E-20',
    'Provider operation and idempotency identity reject conflicting request facts',

    pg_temp.expect_p2e_error(
      format(
        'select haulvia_command.command_prepare_provider_adapter_request(%L::jsonb)',
        jsonb_set(
          v_request,
          '{correlationId}',
          to_jsonb(
            'e2e70000-0000-0000-0000-000000000006'::text
          )
        )::text
      ),
      'IDEMPOTENCY_KEY_REUSED'
    ),

    'Conflicting provider idempotency facts were accepted.'
  );


  perform pg_temp.assert_requirement(
    'P2E-21',
    'Persisted provider request snapshots reject provider authentication secrets',

    pg_temp.expect_p2e_error(
      format(
        'select haulvia_command.command_prepare_provider_adapter_request(%L::jsonb)',
        jsonb_set(
          jsonb_set(
            v_request,
            '{providerIdempotencyKey}',
            to_jsonb(
              'p2e-final-sensitive-001'::text
            )
          ),
          '{requestSnapshot}',
          jsonb_build_object(
            'nested',
            jsonb_build_object(
              'clientSecret',
              'must-never-persist'
            )
          )
        )::text
      ),
      'SENSITIVE_PROVIDER_DATA'
    ),

    'Sensitive provider request content was accepted.'
  );


  perform pg_temp.assert_requirement(
    'P2E-22',
    'Provider adapter request lifecycle uses the frozen four states',

    (
      select
        array_agg(
          e.enumlabel::text
          order by e.enumsortorder
        ) =
        array[
          'PREPARED',
          'SUBMITTED',
          'SUBMISSION_FAILED',
          'CANCELLED'
        ]
      from pg_type t
      join pg_namespace n
        on n.oid = t.typnamespace
      join pg_enum e
        on e.enumtypid = t.oid
      where n.nspname = 'haulvia'
        and t.typname =
          'provider_adapter_request_status'
    ),

    'Adapter request lifecycle enum differs from frozen contract.'
  );


  v_failed :=
    haulvia_command.command_record_provider_adapter_attempt(
      jsonb_build_object(
        'providerAdapterRequestId',
          v_adapter,

        'attemptNo',
          1,

        'startedAt',
          '2099-01-08T00:00:00Z',

        'completedAt',
          '2099-01-08T00:00:01Z',

        'submissionSucceeded',
          false,

        'normalizedResult',
          jsonb_build_object(
            'accepted',false
          ),

        'errorCategory',
          'TEMPORARY_PROVIDER_ERROR',

        'providerStatus',
          'temporary_failure',

        'providerReference',
          'attempt-1',

        'retryable',
          true,

        'responseSnapshot',
          jsonb_build_object(
            'status','temporary_failure'
          ),

        'workerAuthority',
          'PAYMENT_WORKER'
      )
    );


  v_submitted :=
    haulvia_command.command_record_provider_adapter_attempt(
      jsonb_build_object(
        'providerAdapterRequestId',
          v_adapter,

        'attemptNo',
          2,

        'startedAt',
          '2099-01-08T00:00:02Z',

        'completedAt',
          '2099-01-08T00:00:03Z',

        'submissionSucceeded',
          true,

        'normalizedResult',
          jsonb_build_object(
            'accepted',true
          ),

        'providerStatus',
          'submitted',

        'providerReference',
          'attempt-2',

        'retryable',
          false,

        'responseSnapshot',
          jsonb_build_object(
            'status','submitted'
          ),

        'workerAuthority',
          'PAYMENT_WORKER'
      )
    );


  perform pg_temp.assert_requirement(
    'P2E-23',
    'SUBMITTED means provider submission and not canonical financial success',

    (
      select status = 'SUBMITTED'
      from haulvia.provider_adapter_requests
      where id = v_adapter
    )
    and (
      select status = 'CREATED'
      from haulvia.payment_intents
      where id =
        'e2e70000-0000-0000-0000-000000000004'
    ),

    'Provider submission incorrectly mutated canonical payment success.'
  );


  perform pg_temp.assert_requirement(
    'P2E-24',
    'Provider adapter attempts are append-only',

    pg_temp.expect_p2e_error(
      format(
        'update haulvia.provider_adapter_attempts set provider_status = %L where adapter_request_id = %L::uuid and attempt_no = 1',
        'mutated',
        v_adapter::text
      ),
      'IMMUTABLE_RECORD'
    )
    and pg_temp.expect_p2e_error(
      format(
        'delete from haulvia.provider_adapter_attempts where adapter_request_id = %L::uuid and attempt_no = 1',
        v_adapter::text
      ),
      'IMMUTABLE_RECORD'
    ),

    'Adapter attempt update/delete was not blocked.'
  );


  perform pg_temp.assert_requirement(
    'P2E-25',
    'Adapter attempt sequence is unique within one provider request',

    exists (
      select 1
      from pg_constraint con
      where con.conrelid =
        'haulvia.provider_adapter_attempts'::regclass
        and con.contype = 'u'
        and pg_get_constraintdef(
          con.oid
        ) like
          '%adapter_request_id%attempt_no%'
    )
    or exists (
      select 1
      from pg_indexes
      where schemaname = 'haulvia'
        and tablename =
          'provider_adapter_attempts'
        and indexdef like
          '%adapter_request_id%'
        and indexdef like
          '%attempt_no%'
        and indexdef like
          'CREATE UNIQUE INDEX%'
    ),

    'No unique adapter request / attempt sequence protection exists.'
  );


  perform pg_temp.assert_requirement(
    'P2E-26',
    'Adapter attempts retain timestamps correlation result error and safe provider metadata',

    (
      select
        count(*) = 2
        and bool_and(
          correlation_id is not null
        )
        and bool_and(
          started_at is not null
        )
        and bool_and(
          completed_at is not null
        )
        and bool_and(
          normalized_result is not null
        )
        and bool_and(
          response_snapshot is not null
        )
      from haulvia.provider_adapter_attempts
      where adapter_request_id =
        v_adapter
    )
    and exists (
      select 1
      from haulvia.provider_adapter_attempts
      where adapter_request_id =
          v_adapter
        and attempt_no = 1
        and error_category =
          'TEMPORARY_PROVIDER_ERROR'
    ),

    'Required adapter attempt observability metadata is incomplete.'
  );


  perform pg_temp.assert_requirement(
    'P2E-27',
    'Adapter attempts reject provider authorization or credential secrets',

    pg_temp.expect_p2e_error(
      $sql$
        select haulvia_command.assert_p2e_safe_json(
          '{"nested":{"authorizationHeader":"Bearer forbidden"}}'::jsonb,
          'responseSnapshot'
        )
      $sql$,
      'SENSITIVE_PROVIDER_DATA'
    ),

    'Sensitive provider-response material was accepted by sanitizer.'
  );

end;
$$;


-- ============================================================================
-- P2E-28 through P2E-37
-- Webhook ingress, replay/conflict and normalized dispatch
-- ============================================================================

do $$
declare
  v_request jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_event uuid;
  v_dispatch_request jsonb;
  v_dispatch jsonb;
  v_dispatch_replay jsonb;
  v_dispatch_id uuid;
begin

  perform pg_temp.assert_requirement(
    'P2E-28',
    'Provider-neutral webhook ingress relation exists',

    to_regclass(
      'haulvia.provider_webhook_events'
    ) is not null,

    'provider_webhook_events relation is missing.'
  );


  perform pg_temp.assert_requirement(
    'P2E-29',
    'Provider event identity is unique per provider when event ID exists',

    exists (
      select 1
      from pg_indexes
      where schemaname = 'haulvia'
        and tablename =
          'provider_webhook_events'
        and indexname =
          'provider_webhook_events_provider_event_uq'
        and indexdef like
          'CREATE UNIQUE INDEX%'
    ),

    'Provider/event identity partial unique index is missing.'
  );


  v_request :=
    jsonb_build_object(
      'externalProvider',
        'P2E_MOCK_PROVIDER',

      'providerEventId',
        'evt-p2e-final-refund-001',

      'providerEventType',
        'mock.refund.completed',

      'bodySha256',
        repeat('b',64),

      'signatureVerified',
        true,

      'correlationId',
        'e2e70000-0000-0000-0000-000000000007',

      'providerOccurredAt',
        '2099-01-08T00:01:00Z',

      'verificationContext',
        jsonb_build_object(
          'algorithm',
            'MOCK_SIGNATURE',

          'keyVersion',
            'mock-v1'
        ),

      'normalizedEventSnapshot',
        jsonb_build_object(
          'operation',
            'CUSTOMER_REFUND',

          'outcome',
            'SUCCEEDED',

          'providerReference',
            'mock-refund-001'
        ),

      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_result :=
    haulvia_command.command_receive_provider_webhook(
      v_request
    );

  v_event :=
    (
      v_result ->> 'providerWebhookEventId'
    )::uuid;


  update p2e_fixture_state
  set webhook_event_id =
    v_event;


  perform pg_temp.assert_requirement(
    'P2E-30',
    'Accepted provider event retains lowercase signed-body SHA-256 digest',

    (
      select
        body_sha256 =
          repeat('b',64)
        and body_sha256 ~
          '^[0-9a-f]{64}$'
      from haulvia.provider_webhook_events
      where id = v_event
    ),

    'Webhook body digest is missing or not canonical lowercase SHA-256.'
  );


  perform pg_temp.assert_requirement(
    'P2E-31',
    'Provider event ingress facts are immutable after acceptance',

    pg_temp.expect_p2e_error(
      format(
        'update haulvia.provider_webhook_events set provider_event_type = %L where id = %L::uuid',
        'changed',
        v_event::text
      ),
      'IMMUTABLE_RECORD'
    )
    and pg_temp.expect_p2e_error(
      format(
        'delete from haulvia.provider_webhook_events where id = %L::uuid',
        v_event::text
      ),
      'IMMUTABLE_RECORD'
    ),

    'Webhook event update/delete was not blocked.'
  );


  perform pg_temp.assert_requirement(
    'P2E-32',
    'Financial dispatch is gated on successful signature verification',

    pg_temp.expect_p2e_error(
      format(
        'select haulvia_command.command_receive_provider_webhook(%L::jsonb)',
        jsonb_set(
          jsonb_set(
            jsonb_set(
              v_request,
              '{providerEventId}',
              to_jsonb(
                'evt-p2e-final-bad-signature'::text
              )
            ),
            '{bodySha256}',
            to_jsonb(
              repeat('c',64)
            )
          ),
          '{signatureVerified}',
          'false'::jsonb
        )::text
      ),
      'WEBHOOK_SIGNATURE_INVALID'
    ),

    'Unverified webhook was accepted.'
  );


  perform pg_temp.assert_requirement(
    'P2E-33',
    'Signature verification provenance is attributable without storing secrets',

    (
      select
        signature_verified
        and verifier_authority =
          'PAYMENT_PROVIDER_CALLBACK'
        and verification_context ->> 'algorithm' =
              'MOCK_SIGNATURE'
        and verification_context ->> 'keyVersion' =
              'mock-v1'
      from haulvia.provider_webhook_events
      where id = v_event
    )
    and not exists (
      select 1
      from jsonb_object_keys(
        (
          select verification_context
          from haulvia.provider_webhook_events
          where id = v_event
        )
      ) k
      where lower(k) ~
        '(secret|token|password|authorization|privatekey)'
    ),

    'Signature provenance is missing or contains forbidden secret material.'
  );


  v_replay :=
    haulvia_command.command_receive_provider_webhook(
      v_request
    );


  perform pg_temp.assert_requirement(
    'P2E-34',
    'Same provider event and body digest replay without a second financial mutation',

    (
      v_replay ->> 'providerWebhookEventId'
    )::uuid = v_event
    and (
      select count(*) = 1
      from haulvia.provider_webhook_events
      where external_provider =
          'P2E_MOCK_PROVIDER'
        and provider_event_id =
          'evt-p2e-final-refund-001'
    ),

    'Exact provider event replay inserted a second ingress record.'
  );


  perform pg_temp.assert_requirement(
    'P2E-35',
    'Same provider event ID with different body digest fails closed',

    pg_temp.expect_p2e_error(
      format(
        'select haulvia_command.command_receive_provider_webhook(%L::jsonb)',
        jsonb_set(
          v_request,
          '{bodySha256}',
          to_jsonb(
            repeat('d',64)
          )
        )::text
      ),
      'PROVIDER_EVENT_CONFLICT'
    ),

    'Conflicting webhook body was not rejected.'
  );


  v_dispatch_request :=
    jsonb_build_object(
      'providerWebhookEventId',
        v_event,

      'commandRequestSha256',
        repeat('e',64),

      'commandRequest',
        '{}'::jsonb,

      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_dispatch :=
    haulvia_command.command_dispatch_provider_webhook(
      v_dispatch_request
    );

  v_dispatch_id :=
    (
      v_dispatch ->> 'providerWebhookDispatchId'
    )::uuid;


  update p2e_fixture_state
  set webhook_dispatch_id =
    v_dispatch_id;


  v_dispatch_replay :=
    haulvia_command.command_dispatch_provider_webhook(
      v_dispatch_request
    );


  perform pg_temp.assert_requirement(
    'P2E-36',
    'Webhook dispatch history is append-only and permits at most one committed dispatch per event',

    (
      v_dispatch ->> 'dispatchStatus'
    ) =
      'SKIPPED_UNSUPPORTED'

    and (
      v_dispatch_replay ->> 'duplicateDispatch'
    )::boolean

    and (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )

    and not exists (
      select 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
          v_event
        and status = 'COMMITTED'
      group by provider_webhook_event_id
      having count(*) > 1
    )

    and exists (
      select 1
      from pg_indexes
      where schemaname = 'haulvia'
        and tablename =
          'provider_webhook_dispatches'
        and indexname =
          'provider_webhook_dispatches_one_commit_uq'
    )

    and pg_temp.expect_p2e_error(
      format(
        'delete from haulvia.provider_webhook_dispatches where id = %L::uuid',
        v_dispatch_id::text
      ),
      'IMMUTABLE_RECORD'
    ),

    'Webhook dispatch append-only or one-commit protection failed.'
  );


  perform pg_temp.assert_requirement(
    'P2E-37',
    'Provider-specific event types are normalized before domain dispatch',

    (
      select
        normalized_operation =
          'CUSTOMER_REFUND'
        and normalized_outcome =
          'SUCCEEDED'
        and target_command is null
        and status =
          'SKIPPED_UNSUPPORTED'
      from haulvia.provider_webhook_dispatches
      where id = v_dispatch_id
    ),

    'Normalized operation/outcome did not drive dispatch independently of provider event type.'
  );

end;
$$;


-- ============================================================================
-- Part 1 result guard
-- ============================================================================

\echo
\echo ================ P2E ACCEPTANCE PART 1 RESULTS ================
\echo

select
  requirement_id,
  test_name,
  passed,
  detail
from p2e_test_results
order by requirement_id;


\echo
\echo ================ P2E ACCEPTANCE PART 1 SUMMARY ================
\echo

select
  count(*) as total_tests,
  count(*) filter(
    where passed
  ) as passed_tests,
  count(*) filter(
    where not passed
  ) as failed_tests
from p2e_test_results;


do $$
declare
  v_total integer;
  v_passed integer;
  v_failed integer;
begin

  select
    count(*),
    count(*) filter(
      where passed
    ),
    count(*) filter(
      where not passed
    )
  into
    v_total,
    v_passed,
    v_failed
  from p2e_test_results;


  if v_total <> 37 then
    raise exception
      'P2E Part 1 expected 37 requirement checks, found %',
      v_total;
  end if;


  if v_passed <> 37
     or v_failed <> 0 then
    raise exception
      'P2E Part 1 acceptance failed: % passed, % failed',
      v_passed,
      v_failed;
  end if;

end;
$$;

-- ============================================================================
-- P2E acceptance Part 2
-- P2E-38 through P2E-48
--
-- IMPORTANT:
-- P2E-38 through P2E-41 intentionally consume transaction-local evidence
-- flags written by the permanent P2E final-gate runner after the corresponding
-- rollback-only behavioral regression succeeds.
--
-- Running this complete 48-check SQL directly without the final gate is
-- therefore expected to fail closed at P2E-38.
--
-- No COMMIT.
-- No ROLLBACK.
-- ============================================================================


do $$
declare
  v_dispatch_source text := '';
  v_a16_source text := '';
  v_a17_source text := '';
  v_d06_source text := '';
  v_payout_outcome_source text := '';
  v_d09_source text := '';
  v_sensitive_authority_source text := '';
  v_cancel_source text := '';
  v_expire_source text := '';
  v_worker_role_guard_source text := '';

begin

  -- --------------------------------------------------------------------------
  -- Resolve canonical function sources once.
  -- --------------------------------------------------------------------------

  select coalesce(p.prosrc, '')
  into v_dispatch_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_p2e_dispatch_provider_webhook'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_a16_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_a16_confirm_paid_assignment'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_a17_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_a17_release_failed_reservation'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_d06_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_d06_submit_driver_payout'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_payout_outcome_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_payout_provider_outcome'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_d09_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_d09_issue_refund_or_adjustment'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_sensitive_authority_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'assert_sensitive_command_authority'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_cancel_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_a18_cancel_pre_assignment'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_expire_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia_command'
    and p.proname =
      'apply_a19_expire_listing'
  limit 1;


  select coalesce(p.prosrc, '')
  into v_worker_role_guard_source
  from pg_proc p
  join pg_namespace n
    on n.oid = p.pronamespace
  where n.nspname = 'haulvia'
    and p.proname =
      'reject_worker_authority_role'
  limit 1;


  -- ==========================================================================
  -- P2E-38
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-38',

    'Successful customer-payment provider outcomes reconcile through existing confirmPaidAssignment behavior using PAYMENT_PROVIDER_CALLBACK',

    current_setting(
      'haulvia.p2e.evidence.payment_success',
      true
    ) = 'passed'

    and position(
      'command_confirm_paid_assignment'
      in v_dispatch_source
    ) > 0

    and position(
      'PAYMENT_PROVIDER_CALLBACK'
      in v_a16_source
    ) > 0

    and position(
      '''PAYMENT_WORKER'''
      in v_a16_source
    ) = 0,

    'Payment-success behavioral evidence or A16 callback routing/authority invariant is missing.'
  );


  -- ==========================================================================
  -- P2E-39
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-39',

    'Customer-payment failure or timeout reconciles through existing failed-reservation behavior using PAYMENT_PROVIDER_CALLBACK',

    current_setting(
      'haulvia.p2e.evidence.payment_failure_timeout',
      true
    ) = 'passed'

    and position(
      'command_release_failed_reservation'
      in v_dispatch_source
    ) > 0

    and position(
      'PAYMENT_PROVIDER_CALLBACK'
      in v_a17_source
    ) > 0,

    'Failure/timeout behavioral evidence or canonical A17 callback routing is missing.'
  );


  -- ==========================================================================
  -- P2E-40
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-40',

    'Late customer-payment success cannot create an assignment and preserves existing reversal-queue behavior',

    current_setting(
      'haulvia.p2e.evidence.late_success',
      true
    ) = 'passed'

    and position(
      'command_release_failed_reservation'
      in v_dispatch_source
    ) > 0

    and position(
      'PAYMENT_PROVIDER_CALLBACK'
      in v_a17_source
    ) > 0

    and position(
      'VOID_OR_REFUND_LATE_SUCCESS'
      in v_a17_source
    ) > 0,

    'Late-success behavioral evidence or canonical reversal behavior is missing.'
  );


  -- ==========================================================================
  -- P2E-41
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-41',

    'Payout submission and callback behavior preserve PAYOUT_WORKER / PAYOUT_PROVIDER_CALLBACK separation and payout reconciliation invariants',

    current_setting(
      'haulvia.p2e.evidence.payout',
      true
    ) = 'passed'

    and position(
      'PAYOUT_WORKER'
      in v_d06_source
    ) > 0

    and position(
      'PAYOUT_PROVIDER_CALLBACK'
      in v_payout_outcome_source
    ) > 0

    and position(
      'command_confirm_driver_payout'
      in v_dispatch_source
    ) > 0

    and position(
      'command_handle_payout_failure'
      in v_dispatch_source
    ) > 0,

    'Payout behavioral evidence or D06/D07/D08 authority separation is missing.'
  );


  -- ==========================================================================
  -- P2E-42
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-42',

    'Refunds and adjustments continue through sensitive issueRefundOrAdjustment authority and reauthentication',

    exists (
      select 1
      from pg_proc p
      join pg_namespace n
        on n.oid = p.pronamespace
      where n.nspname = 'haulvia_command'
        and p.proname =
          'command_issue_refund_or_adjustment'
    )

    and position(
      'assert_sensitive_command_authority'
      in v_d09_source
    ) > 0

    and position(
      'FINANCIAL_ADJUST'
      in v_d09_source
    ) > 0

    and position(
      'reauthSessionId'
      in v_sensitive_authority_source
    ) > 0

    and position(
      'FRESH_AUTH_REQUIRED'
      in v_sensitive_authority_source
    ) > 0,

    'D09 no longer preserves FINANCIAL_ADJUST plus fresh reauthentication authority.'
  );


  -- ==========================================================================
  -- P2E-43
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-43',

    'Existing cancellation and expiry payment-authorization void queue behavior remains intact',

    position(
      'VOID_PAYMENT_AUTHORIZATION'
      in v_cancel_source
    ) > 0

    and position(
      'VOID_PAYMENT_AUTHORIZATION'
      in v_expire_source
    ) > 0,

    'Cancellation or expiry no longer queues VOID_PAYMENT_AUTHORIZATION.'
  );


  -- ==========================================================================
  -- P2E-44
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-44',

    'Existing payment/payout provider-event uniqueness and one-outcome-per-payout-request protections remain intact',

    exists (
      select 1
      from pg_indexes
      where schemaname = 'haulvia'
        and tablename =
          'payment_transactions'
        and indexname =
          'payment_transactions_provider_event_uq'
    )

    and exists (
      select 1
      from pg_indexes
      where schemaname = 'haulvia'
        and tablename =
          'payout_transactions'
        and indexname =
          'payout_transactions_provider_event_uq'
    )

    and exists (
      select 1
      from pg_indexes
      where schemaname = 'haulvia'
        and tablename =
          'payout_transactions'
        and indexname =
          'payout_transactions_one_request_outcome_uq'
    )

    and position(
      'PROVIDER_EVENT_CONFLICT'
      in v_payout_outcome_source
    ) > 0

    and position(
      'request_transaction_id'
      in v_payout_outcome_source
    ) > 0,

    'Canonical provider-event uniqueness or payout request/outcome protection changed.'
  );


  -- ==========================================================================
  -- P2E-45
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-45',

    'All P2E base tables use RLS and expose no raw integration-table privileges to broad roles',

    (
      select
        count(*) = 4
        and bool_and(c.relrowsecurity)
      from pg_class c
      join pg_namespace n
        on n.oid = c.relnamespace
      where n.nspname = 'haulvia'
        and c.relkind = 'r'
        and c.relname in (
          'provider_adapter_requests',
          'provider_adapter_attempts',
          'provider_webhook_events',
          'provider_webhook_dispatches'
        )
    )

    and not exists (
      select 1
      from pg_class c
      join pg_namespace n
        on n.oid = c.relnamespace
      cross join lateral aclexplode(
        coalesce(
          c.relacl,
          acldefault(
            'r',
            c.relowner
          )
        )
      ) as acl
      where n.nspname = 'haulvia'
        and c.relkind = 'r'
        and c.relname in (
          'provider_adapter_requests',
          'provider_adapter_attempts',
          'provider_webhook_events',
          'provider_webhook_dispatches'
        )
        and acl.grantee = 0
        and acl.privilege_type in (
          'SELECT',
          'INSERT',
          'UPDATE',
          'DELETE',
          'TRUNCATE',
          'REFERENCES',
          'TRIGGER'
        )
    )
    and not exists (
      select 1
      from (
        values
          ('anon'),
          ('authenticated'),
          ('service_role')
      ) as roles(role_name)
      cross join (
        values
          ('provider_adapter_requests'),
          ('provider_adapter_attempts'),
          ('provider_webhook_events'),
          ('provider_webhook_dispatches')
      ) as tables(table_name)
      where
        has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'SELECT'
        )

        or has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'INSERT'
        )

        or has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'UPDATE'
        )

        or has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'DELETE'
        )

        or has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'TRUNCATE'
        )

        or has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'REFERENCES'
        )

        or has_table_privilege(
          roles.role_name,
          format(
            'haulvia.%I',
            tables.table_name
          ),
          'TRIGGER'
        )
    ),

    'P2E RLS or raw integration-table privilege closure failed.'
  );


  -- ==========================================================================
  -- P2E-46
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-46',

    'P2E SECURITY DEFINER functions use pinned search paths safe ownership and wrapper-only execution',

    (
      select
        count(*) = 5
        and bool_and(p.prosecdef)
        and bool_and(
          array_to_string(
            coalesce(
              p.proconfig,
              array[]::text[]
            ),
            ','
          )
          like
            '%search_path=haulvia, haulvia_command, pg_temp%'
        )
        and bool_and(
          array_to_string(
            coalesce(
              p.proconfig,
              array[]::text[]
            ),
            ','
          )
          not like
            '%public%'
        )
        and bool_and(
          pg_get_userbyid(p.proowner)
          not in (
            'anon',
            'authenticated'
          )
        )
        and bool_and(
          has_function_privilege(
            'service_role',
            p.oid,
            'EXECUTE'
          )
        )
        and bool_and(
          not has_function_privilege(
            'anon',
            p.oid,
            'EXECUTE'
          )
        )
        and bool_and(
          not has_function_privilege(
            'authenticated',
            p.oid,
            'EXECUTE'
          )
        )
        and bool_and(
          not exists (
            select 1
            from aclexplode(
              coalesce(
                p.proacl,
                acldefault(
                  'f',
                  p.proowner
                )
              )
            ) as acl
            where acl.grantee = 0
              and acl.privilege_type = 'EXECUTE'
          )
        )
      from pg_proc p
      join pg_namespace n
        on n.oid = p.pronamespace
      where n.nspname = 'haulvia_command'
        and p.proname in (
          'command_prepare_provider_adapter_request',
          'command_record_provider_adapter_attempt',
          'command_cancel_provider_adapter_request',
          'command_receive_provider_webhook',
          'command_dispatch_provider_webhook'
        )
    )

    and not exists (
      select 1
      from pg_proc p
      join pg_namespace n
        on n.oid = p.pronamespace
      where n.nspname = 'haulvia_command'
        and (
          p.proname like
            'apply_p2e_%'

          or p.proname like
            'assert_p2e_%'

          or p.proname like
            'guard_p2e_%'

          or p.proname =
            'reject_p2e_append_only_mutation'

          or p.proname in (
            'apply_a16_confirm_paid_assignment',
            'apply_a17_release_failed_reservation'
          )
        )
        and (
          has_function_privilege(
            'service_role',
            p.oid,
            'EXECUTE'
          )

          or has_function_privilege(
            'anon',
            p.oid,
            'EXECUTE'
          )

          or has_function_privilege(
            'authenticated',
            p.oid,
            'EXECUTE'
          )

          or exists (
            select 1
            from aclexplode(
              coalesce(
                p.proacl,
                acldefault(
                  'f',
                  p.proowner
                )
              )
            ) as acl
            where acl.grantee = 0
              and acl.privilege_type = 'EXECUTE'
          )
        )
    ),

    'P2E SECURITY DEFINER ownership/search-path/wrapper-only execution invariant failed.'
  );


  -- ==========================================================================
  -- P2E-47
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-47',

    'PAYMENT_PROVIDER_CALLBACK remains worker authority and all prior Phase 2 security/authority invariants remain intact',

    position(
      'PAYMENT_PROVIDER_CALLBACK'
      in v_worker_role_guard_source
    ) > 0

    and not exists (
      select 1
      from haulvia.roles
      where role_key =
        'PAYMENT_PROVIDER_CALLBACK'
    )

    and exists (
      select 1
      from pg_trigger t
      join pg_class c
        on c.oid = t.tgrelid
      join pg_namespace n
        on n.oid = c.relnamespace
      where n.nspname = 'haulvia'
        and c.relname = 'roles'
        and t.tgname =
          'roles_reject_worker_authority'
        and not t.tgisinternal
        and t.tgenabled <> 'D'
    )

    and not exists (
      select 1
      from pg_class c
      join pg_namespace n
        on n.oid = c.relnamespace
      where n.nspname = 'haulvia'
        and c.relkind = 'r'
        and not c.relrowsecurity
    )

    and not exists (
      select 1
      from p2e_test_results
      where requirement_id between
          'P2E-01'
          and 'P2E-46'
        and not passed
    ),

    'Worker-role separation or inherited Phase 2 security/authority invariants failed.'
  );


  -- ==========================================================================
  -- P2E-48
  -- ==========================================================================

  perform pg_temp.assert_requirement(
    'P2E-48',

    'Deterministic local acceptance proves provider retry webhook payment payout adjustment secret baseline and security invariants without hosted mutation',

    current_setting(
      'haulvia.p2e.evidence.adapter_regression',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.payment_success',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.payment_failure_timeout',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.late_success',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.payout',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.dispatch_edge',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.block_a_regression',
      true
    ) = 'passed'

    and current_setting(
      'haulvia.p2e.evidence.block_d_regression',
      true
    ) = 'passed'

    and not exists (
      select 1
      from p2e_test_results
      where requirement_id between
          'P2E-01'
          and 'P2E-47'
        and not passed
    ),

    'Complete deterministic P2E final-gate evidence is incomplete.'
  );

end;
$$;


-- ============================================================================
-- Complete 48-check result guard
-- ============================================================================

\echo
\echo ================ P2E COMPLETE ACCEPTANCE RESULTS ================
\echo

select
  requirement_id,
  test_name,
  passed,
  detail
from p2e_test_results
order by requirement_id;


\echo
\echo ================ P2E COMPLETE ACCEPTANCE SUMMARY ================
\echo

select
  count(*) as total_tests,

  count(*) filter (
    where passed
  ) as passed_tests,

  count(*) filter (
    where not passed
  ) as failed_tests

from p2e_test_results;


do $$
declare
  v_total integer;
  v_passed integer;
  v_failed integer;

begin

  select
    count(*),

    count(*) filter (
      where passed
    ),

    count(*) filter (
      where not passed
    )

  into
    v_total,
    v_passed,
    v_failed

  from p2e_test_results;


  if v_total <> 48 then
    raise exception
      'P2E final acceptance expected 48 requirement checks, found %',
      v_total;
  end if;


  if v_passed <> 48
     or v_failed <> 0 then

    raise exception
      'P2E final acceptance failed: % passed, % failed',
      v_passed,
      v_failed;

  end if;

end;
$$;


-- ============================================================================
-- End P2E acceptance v1.
--
-- The permanent final-gate runner owns the final ROLLBACK.
-- Do not add COMMIT here.
-- Do not add ROLLBACK here.
-- ============================================================================