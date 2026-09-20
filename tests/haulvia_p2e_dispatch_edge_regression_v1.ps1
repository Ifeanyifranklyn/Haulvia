$ErrorActionPreference = "Stop"

$migration = ".\supabase\migrations\20260920024711_haulvia_p2e_provider_adapters_and_webhooks_v1.sql"
$contract  = ".\docs\Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md"

$expectedContractHash =
    "60C0408922C0474B3338C5E1274B6C74B570F57B18F01ACE62E7E718EBB7140A"


# ============================================================================
# Preconditions
# ============================================================================

if (-not $env:HAULVIA_P2E_TEST_DATABASE_URL) {
    throw "HAULVIA_P2E_TEST_DATABASE_URL is not set."
}

foreach ($path in @(
    $migration,
    $contract
)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

if (
    (Get-FileHash $contract -Algorithm SHA256).Hash `
        -ne $expectedContractHash
) {
    throw "Frozen P2E contract hash changed."
}


$migrationText =
    Get-Content `
        -LiteralPath $migration `
        -Raw

$commitCount = (
    [regex]::Matches(
        $migrationText,
        '(?im)^\s*COMMIT\s*;\s*$'
    )
).Count

if ($commitCount -ne 0) {
    throw "P2E migration unexpectedly contains COMMIT."
}


# ============================================================================
# Baseline
# ============================================================================

$baselineSql = @'
select
  (select count(*) from haulvia.shipments),
  (select count(*) from haulvia.payment_transactions),
  (select count(*) from haulvia.payout_transactions),
  (select count(*) from haulvia.financial_adjustments),
  (
    select count(distinct p.proname)
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname like 'command\_%' escape '\'
  ),
  to_regclass(
    'haulvia.provider_webhook_events'
  ) is null,
  to_regclass(
    'haulvia.provider_webhook_dispatches'
  ) is null;
'@

Write-Host ""
Write-Host "================ PRE-TEST BASELINE ================"
Write-Host ""

$baseline = & psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -A `
    -t `
    -v ON_ERROR_STOP=1 `
    -c $baselineSql

if ($LASTEXITCODE -ne 0) {
    throw "Pre-test baseline query failed."
}

$baseline = (
    $baseline |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Last 1
).Trim()

Write-Host "Baseline result: $baseline"

if ($baseline -ne "0|0|0|0|86|t|t") {
    throw "Database is not at the expected clean P2D baseline."
}


# ============================================================================
# Unsupported / edge-hardening behavior SQL
# ============================================================================

$behaviorSql = @'

set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


create temporary table p2e_dispatch_edge_results (
  test_no integer generated always as identity,
  test_name text not null,
  passed boolean not null,
  detail text not null
) on commit drop;


create or replace function pg_temp.p2e_assert(
  p_name text,
  p_condition boolean,
  p_detail text default 'passed'
)
returns void
language plpgsql
as $$
begin
  insert into p2e_dispatch_edge_results(
    test_name,
    passed,
    detail
  )
  values (
    p_name,
    p_condition is true,
    case
      when p_condition is true
        then p_detail
      else 'FAILED'
    end
  );
end;
$$;


create or replace function pg_temp.p2e_expect_error(
  p_name text,
  p_sql text,
  p_expected_code text
)
returns void
language plpgsql
as $$
declare
  v_detail text;
  v_detail_json jsonb;
  v_actual_code text;
begin
  begin
    execute p_sql;

    insert into p2e_dispatch_edge_results(
      test_name,
      passed,
      detail
    )
    values (
      p_name,
      false,
      'Expected ' ||
        p_expected_code ||
        ' but statement succeeded'
    );

  exception
    when others then
      get stacked diagnostics
        v_detail = pg_exception_detail;

      begin
        v_detail_json :=
          coalesce(
            nullif(
              v_detail,
              ''
            ),
            '{}'
          )::jsonb;
      exception
        when others then
          v_detail_json :=
            '{}'::jsonb;
      end;

      v_actual_code :=
        v_detail_json ->> 'code';

      insert into p2e_dispatch_edge_results(
        test_name,
        passed,
        detail
      )
      values (
        p_name,
        v_actual_code =
          p_expected_code,
        'expected=' ||
          p_expected_code ||
          ', actual=' ||
          coalesce(
            v_actual_code,
            '<null>'
          )
      );
  end;
end;
$$;


-- ============================================================================
-- Receive one deterministic verified provider event.
-- ============================================================================

create or replace function pg_temp.receive_edge_event(
  p_event_id text,
  p_operation text,
  p_outcome text,
  p_authority text,
  p_correlation uuid,
  p_digest_character text
)
returns uuid
language plpgsql
as $$
declare
  v_result jsonb;
begin

  v_result :=
    haulvia_command.command_receive_provider_webhook(
      jsonb_build_object(
        'externalProvider',
          'P2E_EDGE_PROVIDER',

        'providerEventId',
          p_event_id,

        'providerEventType',
          lower(p_operation) ||
          '.' ||
          lower(p_outcome),

        'bodySha256',
          repeat(
            p_digest_character,
            64
          ),

        'signatureVerified',
          true,

        'correlationId',
          p_correlation,

        'providerOccurredAt',
          '2099-01-07T00:00:00Z',

        'verificationContext',
          jsonb_build_object(
            'algorithm',
              'TEST_SIGNATURE',

            'keyVersion',
              'edge-v1'
          ),

        'normalizedEventSnapshot',
          jsonb_build_object(
            'operation',
              p_operation,

            'outcome',
              p_outcome,

            'providerReference',
              'ref-' || p_event_id
          ),

        'workerAuthority',
          p_authority
      )
    );

  return
    (
      v_result ->
>       'providerWebhookEventId'
    )::uuid;
end;
$$;


-- ============================================================================
-- PAYMENT_VOID is a recognized P2E operation but has no automatic financial
-- command route in Block 3B.
-- ============================================================================

do $$
declare
  v_event uuid;
  v_request jsonb;
  v_result jsonb;
  v_dispatch uuid;
begin

  v_event :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-payment-void-001',
      'PAYMENT_VOID',
      'SUCCEEDED',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e51000-0000-0000-0000-000000000001',
      'a'
    );


  perform pg_temp.p2e_assert(
    '01 recognized PAYMENT_VOID webhook is retained',
    (
      select
        signature_verified
        and verifier_authority =
          'PAYMENT_PROVIDER_CALLBACK'
        and normalized_event_snapshot ->
>           'operation' =
              'PAYMENT_VOID'
      from haulvia.provider_webhook_events
      where id = v_event
    )
  );


  v_request :=
    jsonb_build_object(
      'providerWebhookEventId',
        v_event,

      'commandRequestSha256',
        repeat('b',64),

      'commandRequest',
        '{}'::jsonb,

      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );

  v_dispatch :=
    (
      v_result ->
>       'providerWebhookDispatchId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '02 PAYMENT_VOID is retained as SKIPPED_UNSUPPORTED',
    v_result ->
>       'dispatchStatus' =
          'SKIPPED_UNSUPPORTED'
    and coalesce(
      (
        v_result ->
>         'duplicateDispatch'
      )::boolean,
      false
    ) = false
  );


  perform pg_temp.p2e_assert(
    '03 unsupported dispatch requires no adapter correlation',
    (
      select
        normalized_operation =
          'PAYMENT_VOID'
        and normalized_outcome =
          'SUCCEEDED'
        and target_command is null
        and command_idempotency_key is null
        and command_request_hash =
          repeat('b',64)
        and provider_adapter_request_id is null
        and shipment_id is null
        and status =
          'SKIPPED_UNSUPPORTED'
        and command_result ->
>           'reason' =
              'UNSUPPORTED_OPERATION_OR_OUTCOME'
      from haulvia.provider_webhook_dispatches
      where id = v_dispatch
    )
  );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );


  perform pg_temp.p2e_assert(
    '04 exact unsupported replay returns original skipped dispatch',
    (
      v_result ->
>       'duplicateDispatch'
    )::boolean
    and (
      v_result ->
>       'providerWebhookDispatchId'
    )::uuid = v_dispatch
    and (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )
  );


  perform pg_temp.p2e_expect_error(
    '05 unsupported replay rejects changed command hash',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_set(
        v_request,
        '{commandRequestSha256}',
        to_jsonb(
          repeat('c',64)
        )
      )::text
    ),

    'PROVIDER_EVENT_CONFLICT'
  );


  perform pg_temp.p2e_assert(
    '06 unsupported replay conflict creates no second dispatch',
    (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )
  );


  perform pg_temp.p2e_expect_error(
    '07 skipped dispatch cannot be updated',

    format(
      'update haulvia.provider_webhook_dispatches set correlation_id = gen_random_uuid() where id = %L::uuid',
      v_dispatch::text
    ),

    'IMMUTABLE_RECORD'
  );


  perform pg_temp.p2e_expect_error(
    '08 skipped dispatch cannot be deleted',

    format(
      'delete from haulvia.provider_webhook_dispatches where id = %L::uuid',
      v_dispatch::text
    ),

    'IMMUTABLE_RECORD'
  );

end;
$$;


-- ============================================================================
-- Other recognized operations intentionally not routed by Block 3B.
-- ============================================================================

do $$
declare
  v_refund_event uuid;
  v_adjustment_event uuid;

  v_refund_result jsonb;
  v_adjustment_result jsonb;
begin

  v_refund_event :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-refund-001',
      'CUSTOMER_REFUND',
      'SUCCEEDED',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e52000-0000-0000-0000-000000000001',
      'd'
    );


  v_refund_result :=
    haulvia_command.command_dispatch_provider_webhook(
      jsonb_build_object(
        'providerWebhookEventId',
          v_refund_event,

        'commandRequestSha256',
          repeat('e',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )
    );


  perform pg_temp.p2e_assert(
    '09 CUSTOMER_REFUND is retained but not auto-dispatched',
    v_refund_result ->
>       'dispatchStatus' =
          'SKIPPED_UNSUPPORTED'
  );


  v_adjustment_event :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-adjustment-001',
      'FINANCIAL_ADJUSTMENT',
      'SUCCEEDED',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e52000-0000-0000-0000-000000000002',
      'f'
    );


  v_adjustment_result :=
    haulvia_command.command_dispatch_provider_webhook(
      jsonb_build_object(
        'providerWebhookEventId',
          v_adjustment_event,

        'commandRequestSha256',
          repeat('1',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )
    );


  perform pg_temp.p2e_assert(
    '10 FINANCIAL_ADJUSTMENT is retained but not auto-dispatched',
    v_adjustment_result ->
>       'dispatchStatus' =
          'SKIPPED_UNSUPPORTED'
  );


  perform pg_temp.p2e_assert(
    '11 unsupported financial operations create no canonical financial rows',
    (
      select count(*) = 0
      from haulvia.payment_transactions
    )
    and (
      select count(*) = 0
      from haulvia.payout_transactions
    )
    and (
      select count(*) = 0
      from haulvia.financial_adjustments
    )
  );

end;
$$;


-- ============================================================================
-- Unsupported outcomes on otherwise routed operations.
--
-- Authority separation must still apply even though there is no target command.
-- ============================================================================

do $$
declare
  v_payment_pending uuid;
  v_payout_pending uuid;

  v_wrong_payment_authority uuid;
  v_wrong_payout_authority uuid;

  v_result jsonb;
begin

  v_payment_pending :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-payment-pending-001',
      'PAYMENT_AUTHORIZE',
      'PENDING',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e53000-0000-0000-0000-000000000001',
      '2'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      jsonb_build_object(
        'providerWebhookEventId',
          v_payment_pending,

        'commandRequestSha256',
          repeat('3',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )
    );


  perform pg_temp.p2e_assert(
    '12 unsupported PAYMENT_AUTHORIZE outcome is skipped under payment callback authority',
    v_result ->
>       'dispatchStatus' =
          'SKIPPED_UNSUPPORTED'
  );


  v_payout_pending :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-payout-pending-001',
      'DRIVER_PAYOUT',
      'PENDING',
      'PAYOUT_PROVIDER_CALLBACK',
      'f2e53000-0000-0000-0000-000000000002',
      '4'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      jsonb_build_object(
        'providerWebhookEventId',
          v_payout_pending,

        'commandRequestSha256',
          repeat('5',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYOUT_PROVIDER_CALLBACK'
      )
    );


  perform pg_temp.p2e_assert(
    '13 unsupported DRIVER_PAYOUT outcome is skipped under payout callback authority',
    v_result ->
>       'dispatchStatus' =
          'SKIPPED_UNSUPPORTED'
  );


  -- Event verified through the payout callback boundary but normalized as
  -- PAYMENT_AUTHORIZE. Dispatch must fail closed.

  v_wrong_payment_authority :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-payment-wrong-authority-001',
      'PAYMENT_AUTHORIZE',
      'PENDING',
      'PAYOUT_PROVIDER_CALLBACK',
      'f2e53000-0000-0000-0000-000000000003',
      '6'
    );


  perform pg_temp.p2e_expect_error(
    '14 PAYMENT_AUTHORIZE rejects payout callback authority even for unsupported outcome',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_wrong_payment_authority,

        'commandRequestSha256',
          repeat('7',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYOUT_PROVIDER_CALLBACK'
      )::text
    ),

    'NOT_AUTHORIZED'
  );


  perform pg_temp.p2e_assert(
    '15 rejected PAYMENT_AUTHORIZE authority creates no dispatch row',
    (
      select count(*) = 0
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_wrong_payment_authority
    )
  );


  -- Inverse authority mismatch.

  v_wrong_payout_authority :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-payout-wrong-authority-001',
      'DRIVER_PAYOUT',
      'PENDING',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e53000-0000-0000-0000-000000000004',
      '8'
    );


  perform pg_temp.p2e_expect_error(
    '16 DRIVER_PAYOUT rejects payment callback authority even for unsupported outcome',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_wrong_payout_authority,

        'commandRequestSha256',
          repeat('9',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )::text
    ),

    'NOT_AUTHORIZED'
  );


  perform pg_temp.p2e_assert(
    '17 rejected DRIVER_PAYOUT authority creates no dispatch row',
    (
      select count(*) = 0
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_wrong_payout_authority
    )
  );

end;
$$;


-- ============================================================================
-- Dispatch-input hardening
-- ============================================================================

do $$
declare
  v_event uuid;
begin

  v_event :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-input-hardening-001',
      'PAYMENT_VOID',
      'SUCCEEDED',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e54000-0000-0000-0000-000000000001',
      'a'
    );


  perform pg_temp.p2e_expect_error(
    '18 uppercase command-request digest is rejected',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_event,

        'commandRequestSha256',
          repeat('A',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )::text
    ),

    'INVALID_REQUEST'
  );


  perform pg_temp.p2e_expect_error(
    '19 non-object commandRequest is rejected',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_event,

        'commandRequestSha256',
          repeat('b',64),

        'commandRequest',
          'not-an-object',

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )::text
    ),

    'INVALID_REQUEST'
  );


  perform pg_temp.p2e_expect_error(
    '20 sensitive commandRequest payload is rejected',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_event,

        'commandRequestSha256',
          repeat('c',64),

        'commandRequest',
          jsonb_build_object(
            'nested',
              jsonb_build_object(
                'clientSecret',
                  'must-never-persist'
              )
          ),

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )::text
    ),

    'SENSITIVE_PROVIDER_DATA'
  );


  perform pg_temp.p2e_assert(
    '21 rejected malformed or sensitive dispatch requests persist nothing',
    (
      select count(*) = 0
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )
  );

end;
$$;


-- ============================================================================
-- Supported financial routes require adapter correlation.
-- ============================================================================

do $$
declare
  v_event uuid;
begin

  v_event :=
    pg_temp.receive_edge_event(
      'evt-p2e-edge-supported-no-adapter-001',
      'PAYMENT_AUTHORIZE',
      'SUCCEEDED',
      'PAYMENT_PROVIDER_CALLBACK',
      'f2e55000-0000-0000-0000-000000000001',
      'd'
    );


  perform pg_temp.p2e_expect_error(
    '22 supported payment route requires providerAdapterRequestId',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_event,

        'commandRequestSha256',
          repeat('e',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )::text
    ),

    'INVALID_REQUEST'
  );


  perform pg_temp.p2e_expect_error(
    '23 supported payment route rejects unknown adapter request',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_event,

        'providerAdapterRequestId',
          'f2e55000-0000-0000-0000-000000000099',

        'commandRequestSha256',
          repeat('f',64),

        'commandRequest',
          '{}'::jsonb,

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )::text
    ),

    'NOT_FOUND'
  );


  perform pg_temp.p2e_assert(
    '24 missing or unknown adapter correlation creates no dispatch evidence',
    (
      select count(*) = 0
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )
  );

end;
$$;


-- ============================================================================
-- Cross-scenario invariants
-- ============================================================================

select pg_temp.p2e_assert(
  '25 exactly five unsupported decisions were retained',
  (
    select
      count(*) = 5
      and count(*) filter(
        where status =
          'SKIPPED_UNSUPPORTED'
      ) = 5
      and count(*) filter(
        where status =
          'COMMITTED'
      ) = 0
      and count(*) filter(
        where status =
          'FAILED'
      ) = 0
    from haulvia.provider_webhook_dispatches
  )
);


select pg_temp.p2e_assert(
  '26 skipped decisions never claim a canonical financial target',
  (
    select
      bool_and(
        target_command is null
      )
      and bool_and(
        command_idempotency_key is null
      )
      and bool_and(
        provider_adapter_request_id is null
      )
      and bool_and(
        shipment_id is null
      )
    from haulvia.provider_webhook_dispatches
    where status =
      'SKIPPED_UNSUPPORTED'
  )
);


select pg_temp.p2e_assert(
  '27 edge suite created no canonical financial mutation',
  (
    select count(*) = 0
    from haulvia.payment_transactions
  )
  and (
    select count(*) = 0
    from haulvia.payout_transactions
  )
  and (
    select count(*) = 0
    from haulvia.financial_adjustments
  )
);


select pg_temp.p2e_assert(
  '28 P2E wrapper count remains 91 inside transaction',
  (
    select
      count(distinct p.proname) = 91
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname =
        'haulvia_command'
      and p.proname like
        'command\_%'
        escape '\'
  )
);


\echo
\echo ================ BLOCK 3B EDGE RESULTS ================
\echo

select
  test_no,
  test_name,
  passed,
  detail
from p2e_dispatch_edge_results
order by test_no;


\echo
\echo ================ BLOCK 3B EDGE SUMMARY ================
\echo

select
  count(*) as total_tests,
  count(*) filter(
    where passed
  ) as passed_tests,
  count(*) filter(
    where not passed
  ) as failed_tests
from p2e_dispatch_edge_results;


do $$
begin
  if exists (
    select 1
    from p2e_dispatch_edge_results
    where not passed
  ) then
    raise exception
      'P2E Block 3B edge-hardening suite has failed assertions';
  end if;
end;
$$;


\echo
\echo Block 3B edge-hardening suite passed. Rolling back.
\echo
'@


# ============================================================================
# Normalize any visual chat wrapping around ->> before execution.
# ============================================================================

$behaviorSql = [regex]::Replace(
    $behaviorSql,
    '->\r?\n>\s*',
    '->> '
)


# ============================================================================
# Build rollback-only SQL file
# ============================================================================

$tempSql =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_block3b_edge_hardening.sql"

$fullSql = @(
    $migrationText.TrimEnd(),
    $behaviorSql.Trim(),
    "ROLLBACK;"
) -join "`r`n`r`n"

[System.IO.File]::WriteAllText(
    $tempSql,
    $fullSql,
    [System.Text.UTF8Encoding]::new($false)
)


$generatedText =
    Get-Content `
        -LiteralPath $tempSql `
        -Raw

if ($generatedText -match '(?m)^\s*>\s+') {
    throw "Generated SQL contains an unexpected chat-wrap marker."
}


Write-Host ""
Write-Host "Temporary test SQL:"
Write-Host $tempSql

Write-Host ""
Write-Host "================ RUN BLOCK 3B EDGE-HARDENING SUITE ================"
Write-Host ""

& psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -v ON_ERROR_STOP=1 `
    -f $tempSql

$testExitCode =
    $LASTEXITCODE


# ============================================================================
# Rollback verification
# ============================================================================

Write-Host ""
Write-Host "================ POST-TEST BASELINE ================"
Write-Host ""

$post = & psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -A `
    -t `
    -v ON_ERROR_STOP=1 `
    -c $baselineSql

if ($LASTEXITCODE -ne 0) {
    throw "Post-test baseline query failed."
}

$post = (
    $post |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Last 1
).Trim()

Write-Host "Post-test result: $post"

if ($post -ne "0|0|0|0|86|t|t") {
    throw "Database did not return to clean P2D baseline."
}


# ============================================================================
# Frozen artifact integrity
# ============================================================================

Write-Host ""
Write-Host "================ CONTRACT / MIGRATION INTEGRITY ================"
Write-Host ""

$hash =
    (Get-FileHash $contract -Algorithm SHA256).Hash

Write-Host "Contract SHA-256: $hash"

if ($hash -ne $expectedContractHash) {
    throw "Frozen P2E contract hash changed."
}

$finalCommitCount = (
    Select-String `
        -Path $migration `
        -Pattern '^\s*COMMIT\s*;\s*$' `
        -CaseSensitive:$false
).Count

Write-Host "Migration COMMIT count: $finalCommitCount"

if ($finalCommitCount -ne 0) {
    throw "P2E migration unexpectedly contains COMMIT."
}


Write-Host ""
Write-Host "================ GIT STATUS ================"
Write-Host ""

git status --short


if ($testExitCode -ne 0) {
    Write-Host ""
    Write-Host "Edge-hardening SQL preserved for diagnosis:"
    Write-Host $tempSql

    throw "P2E Block 3B edge-hardening suite failed."
}


Remove-Item `
    -LiteralPath $tempSql `
    -Force


Write-Host ""
Write-Host "PASS: unsupported recognized operations are retained as SKIPPED_UNSUPPORTED."
Write-Host "PASS: unsupported dispatch replay is idempotent and conflict-protected."
Write-Host "PASS: skipped dispatch evidence is append-only."
Write-Host "PASS: payment and payout callback authority separation applies to unsupported outcomes."
Write-Host "PASS: malformed and sensitive dispatch requests fail before persistence."
Write-Host "PASS: supported routes require a real adapter correlation."
Write-Host "PASS: unsupported events cause no canonical financial mutation."
Write-Host "PASS: rollback restored the 86-wrapper P2D baseline."
Write-Host ""
Write-Host "NEXT: P2E command manifest / service-role allowlist and privilege closure."