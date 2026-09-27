$ErrorActionPreference = "Stop"

$migration  = ".\supabase\migrations\20260920024711_haulvia_p2e_provider_adapters_and_webhooks_v1.sql"
$contract   = ".\docs\Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md"
$blockDTest = ".\tests\haulvia_block_d_acceptance_v1.sql"

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
    $contract,
    $blockDTest
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


# ============================================================================
# Clean P2D baseline
# ============================================================================

$baselineSql = @'
select
  (select count(*) from haulvia.shipments),
  (select count(*) from haulvia.driver_payouts),
  (select count(*) from haulvia.payout_transactions),
  (
    select count(distinct p.proname)
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname like 'command\_%' escape '\'
  ),
  to_regclass('haulvia.provider_adapter_requests') is null,
  to_regclass('haulvia.provider_webhook_events') is null,
  to_regclass('haulvia.provider_webhook_dispatches') is null;
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
    throw "Baseline query failed."
}

$baseline = (
    $baseline |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Last 1
).Trim()

Write-Host "Baseline result: $baseline"

if ($baseline -ne "0|0|0|86|t|t|t") {
    throw "Database is not at clean P2D baseline."
}


# ============================================================================
# Extract reusable Block D fixture layer
# ============================================================================

$blockDText =
    Get-Content `
        -LiteralPath $blockDTest `
        -Raw

$beginMatch =
    [regex]::Match(
        $blockDText,
        '(?im)^\s*begin\s*;\s*\r?\n'
    )

if (-not $beginMatch.Success) {
    throw "Block D BEGIN not found."
}

$fixtureMarker =
    "-- D01: verified receiver result is stop-scoped, first-valid, and replay-safe."

$fixtureEnd =
    $blockDText.IndexOf(
        $fixtureMarker,
        [System.StringComparison]::Ordinal
    )

if ($fixtureEnd -lt 0) {
    throw "Block D fixture marker not found."
}

$fixtureStart =
    $beginMatch.Index +
    $beginMatch.Length

$blockDSetup =
    $blockDText.Substring(
        $fixtureStart,
        $fixtureEnd - $fixtureStart
    )


function Replace-One {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Old,

        [Parameter(Mandatory)]
        [string]$New,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $count = (
        [regex]::Matches(
            $Text,
            [regex]::Escape($Old)
        )
    ).Count

    Write-Host "$Label targets: $count"

    if ($count -ne 1) {
        throw "$Label expected exactly one target."
    }

    return $Text.Replace(
        $Old,
        $New
    )
}


# ============================================================================
# Transaction-only P2A publication authority
# ============================================================================

$approverOrg =
    "f2e40000-0000-0000-0000-000000000001"

$approverProfile =
    "f2e40000-0000-0000-0000-000000000002"

$approverMembership =
    "f2e40000-0000-0000-0000-000000000003"

$approverReauth =
    "f2e40000-0000-0000-0000-000000000004"


$bridge = @"

-- ============================================================================
-- P2E-PAYOUT-FIXTURE-PUBLICATION-BRIDGE
-- ============================================================================

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  '$approverOrg',
  'p2e-payout-fixture-approver',
  'HAULVIA',
  'P2E Payout Fixture Approver',
  'P2E Payout Fixture Approver'
);

insert into haulvia.profiles (
  id,
  display_name
)
values (
  '$approverProfile',
  'P2E Payout Fixture Approver'
);

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status
)
values (
  '$approverMembership',
  '$approverOrg',
  '$approverProfile',
  'ACTIVE'
);

insert into haulvia.membership_roles (
  membership_id,
  role_id
)
select
  '$approverMembership'::uuid,
  r.id
from haulvia.roles r
where r.role_key = 'PLATFORM_ADMIN';

insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at
)
values (
  '$approverReauth',
  '$approverProfile',
  '$approverOrg',
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes'
);

"@

$anchor =
    "-- Shared customer, provider, policy, pricing, and sensitive-admin fixtures."

$anchorCount = (
    [regex]::Matches(
        $blockDSetup,
        [regex]::Escape($anchor)
    )
).Count

Write-Host ""
Write-Host "Publication bridge targets: $anchorCount"

if ($anchorCount -ne 1) {
    throw "Block D shared-fixture anchor mismatch."
}

$blockDSetup =
    $blockDSetup.Replace(
        $anchor,
        $bridge + "`r`n" + $anchor
    )


# ============================================================================
# P2A role-kind compatibility
# ============================================================================

$old = @'
  insert into roles(id, role_key, name, description)
  values (v_role, 'BLOCK_D_ADMIN', 'Block D administrator', 'Acceptance-only sensitive role');
  insert into role_permissions(role_id, permission_id)
'@

$new = @'
  insert into roles(id, role_key, name, description)
  values (v_role, 'BLOCK_D_ADMIN', 'Block D administrator', 'Acceptance-only sensitive role');

  -- P2E-PAYOUT-FIXTURE-ROLE-SCOPE
  insert into role_organization_kinds(
    role_id,
    organization_kind
  )
  values (
    v_role,
    'HAULVIA'
  );

  insert into role_permissions(role_id, permission_id)
'@

$blockDSetup =
    Replace-One `
        -Text $blockDSetup `
        -Old $old `
        -New $new `
        -Label "Block D role scope"


# ============================================================================
# P2A policy publication compatibility
# ============================================================================

$old = @'
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
'@

$new = @"
  insert into policy_versions(
    id, policy_set_id, version_no, publication_status, effective_from, config,
    config_sha256, legal_review_required, created_by_profile_id,
    approved_by_profile_id, approved_at, reauth_session_id, approval_reason
  ) values (
    v_policy, v_policy_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object(
      'evidenceRequirements', jsonb_build_object('photo', true),
      'cancellationRules', jsonb_build_object('preCustody', 'versioned'),
      'refundRules', jsonb_build_object('originalMethod', true),
      'timingWindows', jsonb_build_object('deliveryReviewSeconds', 86400),
      'riskRules', jsonb_build_object('contactless', 'versioned')
    ), repeat('d', 64), false, v_admin,
    '$approverProfile'::uuid, clock_timestamp(),
    '$approverReauth'::uuid,
    'P2E payout dispatch rollback fixture policy approval'
  );
"@

$blockDSetup =
    Replace-One `
        -Text $blockDSetup `
        -Old $old `
        -New $new `
        -Label "Block D policy"


# ============================================================================
# P2A pricing publication compatibility
# ============================================================================

$old = @'
  insert into pricing_rule_versions(
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values (
    v_pricing_version, v_pricing_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object('floorAmount', 0, 'ceilingAmount', 200),
    repeat('e', 64), v_admin, v_admin, clock_timestamp()
  );
'@

$new = @"
  insert into pricing_rule_versions(
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id,
    approved_at, reauth_session_id, approval_reason
  ) values (
    v_pricing_version, v_pricing_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object('floorAmount', 0, 'ceilingAmount', 200),
    repeat('e', 64), v_admin, '$approverProfile'::uuid,
    clock_timestamp(), '$approverReauth'::uuid,
    'P2E payout dispatch rollback fixture pricing approval'
  );
"@

$blockDSetup =
    Replace-One `
        -Text $blockDSetup `
        -Old $old `
        -New $new `
        -Label "Block D pricing"


# ============================================================================
# P2D structured-only evidence compatibility
# ============================================================================

$old = @'
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
'@

$new = @'
  -- P2E-PAYOUT-FIXTURE-P2D-EVIDENCE
  insert into stop_evidence(
    stop_attempt_id, evidence_type,
    structured_value, captured_at, captured_latitude, captured_longitude,
    captured_accuracy_m, idempotency_key
  ) values (
    v_delivery_attempt, 'PHOTO',
    jsonb_build_object('dropLocation', 'AUTHORIZED_FRONT_DESK', 'notes', 'Secure drop'),
    p_window_started_at - interval '5 minutes', 50.4452, -104.6189, 5,
    p_label || '-proof'
  ) returning id into v_evidence;
'@

$blockDSetup =
    Replace-One `
        -Text $blockDSetup `
        -Old $old `
        -New $new `
        -Label "Block D evidence"


# ============================================================================
# Payout dispatch behavior suite
# ============================================================================

$behaviorSql = @'

set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


create temporary table p2e_payout_results (
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
  insert into p2e_payout_results(
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

    insert into p2e_payout_results(
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
            nullif(v_detail, ''),
            '{}'
          )::jsonb;
      exception
        when others then
          v_detail_json :=
            '{}'::jsonb;
      end;

      v_actual_code :=
        v_detail_json ->> 'code';

      insert into p2e_payout_results(
        test_name,
        passed,
        detail
      )
      values (
        p_name,
        v_actual_code = p_expected_code,
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
-- Submit canonical D06 provider request
-- ============================================================================

create or replace function pg_temp.submit_payout_request(
  p_shipment uuid,
  p_payout uuid,
  p_label text,
  p_hash_character text,
  p_provider_key text
)
returns jsonb
language plpgsql
as $$
begin
  return
    haulvia_command.command_submit_driver_payout(
      pg_temp.envelope(
        p_shipment,
        null,
        p_label,
        p_hash_character
      )
      ||
      jsonb_build_object(
        'workerAuthority',
          'PAYOUT_WORKER',

        'expectedPayoutId',
          p_payout,

        'payoutAmount',
          90,

        'externalProvider',
          'block-d-payouts',

        'providerIdempotencyKey',
          p_provider_key,

        'payoutAccountReference',
          'acct_' || p_label,

        'payoutAccountValid',
          true,

        'providerRequest',
          jsonb_build_object(
            'rail',
              'EFT'
          )
      )
    );
end;
$$;


-- ============================================================================
-- Prepare and submit P2E adapter request for exact D06 transaction
-- ============================================================================

create or replace function pg_temp.prepare_payout_adapter(
  p_shipment uuid,
  p_payout uuid,
  p_payout_transaction uuid,
  p_label text,
  p_correlation uuid,
  p_digest_character text
)
returns uuid
language plpgsql
as $$
declare
  v_prepare jsonb;
  v_attempt jsonb;
  v_adapter uuid;
begin

  v_prepare :=
    haulvia_command.command_prepare_provider_adapter_request(
      jsonb_build_object(
        'shipmentId',
          p_shipment,

        'operation',
          'DRIVER_PAYOUT',

        'externalProvider',
          'block-d-payouts',

        'providerIdempotencyKey',
          p_label || '-adapter',

        'correlationId',
          p_correlation,

        'payoutId',
          p_payout,

        'payoutTransactionId',
          p_payout_transaction,

        'requestFingerprintSha256',
          repeat(
            p_digest_character,
            64
          ),

        'requestSnapshot',
          jsonb_build_object(
            'amount',
              90,

            'currency',
              'CAD',

            'payoutAccountReference',
              'acct_' || p_label
          ),

        'workerAuthority',
          'PAYOUT_WORKER'
      )
    );

  v_adapter :=
    (
      v_prepare ->
>       'providerAdapterRequestId'
    )::uuid;


  v_attempt :=
    haulvia_command.command_record_provider_adapter_attempt(
      jsonb_build_object(
        'providerAdapterRequestId',
          v_adapter,

        'attemptNo',
          1,

        'startedAt',
          '2099-01-06T00:00:00Z',

        'completedAt',
          '2099-01-06T00:00:01Z',

        'submissionSucceeded',
          true,

        'normalizedResult',
          jsonb_build_object(
            'accepted',
              true
          ),

        'providerStatus',
          'submitted',

        'providerReference',
          'provider-request-' ||
            p_label,

        'retryable',
          false,

        'responseSnapshot',
          jsonb_build_object(
            'status',
              'submitted',

            'providerReference',
              'provider-request-' ||
                p_label
          ),

        'workerAuthority',
          'PAYOUT_WORKER'
      )
    );

  if v_attempt ->> 'requestStatus'
       <> 'SUBMITTED' then
    raise exception
      'Payout adapter did not reach SUBMITTED';
  end if;

  return v_adapter;
end;
$$;


-- ============================================================================
-- Receive normalized verified payout webhook
-- ============================================================================

create or replace function pg_temp.receive_payout_outcome(
  p_event_id text,
  p_outcome text,
  p_reference text,
  p_correlation uuid,
  p_digest_character text
)
returns uuid
language plpgsql
as $$
declare
  v_snapshot jsonb;
  v_result jsonb;
begin

  v_snapshot :=
    jsonb_build_object(
      'operation',
        'DRIVER_PAYOUT',

      'outcome',
        upper(p_outcome),

      'amount',
        90,

      'currency',
        'CAD',

      'providerReference',
        p_reference
    );

  if upper(p_outcome) = 'SUCCEEDED' then
    v_snapshot :=
      v_snapshot
      ||
      jsonb_build_object(
        'providerStatus',
          'paid'
      );
  else
    v_snapshot :=
      v_snapshot
      ||
      jsonb_build_object(
        'providerStatus',
          'failed',

        'failureCode',
          'ACCOUNT_TEMPORARILY_UNAVAILABLE'
      );
  end if;


  v_result :=
    haulvia_command.command_receive_provider_webhook(
      jsonb_build_object(
        'externalProvider',
          'block-d-payouts',

        'providerEventId',
          p_event_id,

        'providerEventType',
          'payout.' ||
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
          '2099-01-06T00:00:02Z',

        'verificationContext',
          jsonb_build_object(
            'algorithm',
              'TEST_SIGNATURE',

            'keyVersion',
              'test-v1'
          ),

        'normalizedEventSnapshot',
          v_snapshot,

        'workerAuthority',
          'PAYOUT_PROVIDER_CALLBACK'
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
-- PAYOUT SUCCESS
-- ============================================================================

do $$
declare
  v_f jsonb;

  v_shipment uuid;
  v_payout uuid;

  v_submit jsonb;
  v_request_tx uuid;

  v_adapter uuid;
  v_event uuid;

  v_lock bigint;

  v_dispatch_request jsonb;
  v_result jsonb;
  v_dispatch_id uuid;

  v_tx_count integer;
begin

  v_f :=
    pg_temp.resolve_and_complete(
      'p2e-payout-success'
    );

  v_shipment :=
    (
      v_f ->
>       'shipmentId'
    )::uuid;

  v_payout :=
    (
      v_f ->
>       'payoutId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '01 success fixture begins COMPLETED with READY payout',
    (
      select
        shipment_state =
          'COMPLETED'
        and terminal_at is not null
      from haulvia.shipments
      where id = v_shipment
    )
    and (
      select
        state = 'READY'
        and net_amount = 90
        and currency = 'CAD'
      from haulvia.driver_payouts
      where id = v_payout
    )
  );


  v_submit :=
    pg_temp.submit_payout_request(
      v_shipment,
      v_payout,
      'p2e-payout-success-submit',
      '1',
      'p2e-payout-success-provider-request'
    );

  v_request_tx :=
    (
      v_submit ->
>       'payoutTransactionId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '02 D06 creates exact pending payout request',
    v_submit ->
>       'driverPayoutState' =
          'PROCESSING'
    and (
      select
        status = 'PENDING'
        and amount = 90
        and currency = 'CAD'
        and external_provider =
          'block-d-payouts'
      from haulvia.payout_transactions
      where id = v_request_tx
    )
  );


  v_adapter :=
    pg_temp.prepare_payout_adapter(
      v_shipment,
      v_payout,
      v_request_tx,
      'p2e-payout-success',
      'f2e41000-0000-0000-0000-000000000001',
      'a'
    );


  perform pg_temp.p2e_assert(
    '03 success adapter retains exact D06 correlation',
    (
      select
        status = 'SUBMITTED'
        and shipment_id =
          v_shipment
        and payout_id =
          v_payout
        and payout_transaction_id =
          v_request_tx
        and operation =
          'DRIVER_PAYOUT'
        and external_provider =
          'block-d-payouts'
      from haulvia.provider_adapter_requests
      where id = v_adapter
    )
  );


  v_event :=
    pg_temp.receive_payout_outcome(
      'evt-p2e-payout-success-001',
      'SUCCEEDED',
      'payout-p2e-success-001',
      'f2e41000-0000-0000-0000-000000000002',
      'b'
    );


  perform pg_temp.p2e_assert(
    '04 successful payout webhook is verified by payout callback authority',
    (
      select
        signature_verified
        and verifier_authority =
          'PAYOUT_PROVIDER_CALLBACK'
        and external_provider =
          'block-d-payouts'
      from haulvia.provider_webhook_events
      where id = v_event
    )
  );


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  v_dispatch_request :=
    jsonb_build_object(
      'providerWebhookEventId',
        v_event,

      'providerAdapterRequestId',
        v_adapter,

      'commandRequestSha256',
        repeat('c',64),

      'commandRequest',
        jsonb_build_object(
          'expectedShipmentVersion',
            v_lock
        ),

      'workerAuthority',
        'PAYOUT_PROVIDER_CALLBACK'
    );


  perform pg_temp.p2e_expect_error(
    '05 generic PAYOUT_WORKER cannot dispatch inbound payout webhook',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_set(
        v_dispatch_request,
        '{workerAuthority}',
        to_jsonb(
          'PAYOUT_WORKER'::text
        )
      )::text
    ),

    'NOT_AUTHORIZED'
  );


  perform pg_temp.p2e_assert(
    '06 rejected payout authority creates no dispatch evidence',
    (
      select count(*) = 0
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )
  );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_dispatch_request
    );

  v_dispatch_id :=
    (
      v_result ->
>       'providerWebhookDispatchId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '07 payout success commits through canonical D07',
    v_result ->
>       'dispatchStatus' =
          'COMMITTED'
    and v_result ->
>       'targetCommand' =
          'command_confirm_driver_payout'
    and v_result ->
      'commandResult' ->
>       'driverPayoutState' =
          'PAID'
  );


  perform pg_temp.p2e_assert(
    '08 D07 keeps shipment completed and moves payout plus axis to PAID',
    (
      select
        shipment_state =
          'COMPLETED'
        and terminal_at is not null
      from haulvia.shipments
      where id = v_shipment
    )
    and (
      select state = 'PAID'
      from haulvia.driver_payouts
      where id = v_payout
    )
    and (
      select
        state = 'PAID'
        and eligible_amount = 90
        and currency = 'CAD'
      from haulvia.shipment_driver_payout_axes
      where shipment_id =
        v_shipment
    )
  );


  perform pg_temp.p2e_assert(
    '09 successful payout outcome retains provider and request evidence',
    (
      select count(*) = 1
      from haulvia.payout_transactions
      where payout_id =
          v_payout
        and request_transaction_id =
          v_request_tx
        and status =
          'SUCCEEDED'
        and amount = 90
        and currency = 'CAD'
        and external_provider =
          'block-d-payouts'
        and provider_event_id =
          'evt-p2e-payout-success-001'
        and external_reference =
          'payout-p2e-success-001'
        and response_payload ->
>           'providerStatus' =
              'paid'
    )
  );


  perform pg_temp.p2e_assert(
    '10 committed payout-success dispatch retains canonical correlation',
    (
      select
        provider_adapter_request_id =
          v_adapter
        and shipment_id =
          v_shipment
        and normalized_operation =
          'DRIVER_PAYOUT'
        and normalized_outcome =
          'SUCCEEDED'
        and target_command =
          'command_confirm_driver_payout'
        and command_request_hash =
          repeat('c',64)
      from haulvia.provider_webhook_dispatches
      where id =
        v_dispatch_id
    )
  );


  v_tx_count :=
    (
      select count(*)
      from haulvia.payout_transactions
      where payout_id =
        v_payout
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_dispatch_request
    );


  perform pg_temp.p2e_assert(
    '11 payout-success exact replay creates no second provider outcome',
    (
      v_result ->
>       'duplicateDispatch'
    )::boolean
    and (
      v_result ->
>       'providerWebhookDispatchId'
    )::uuid = v_dispatch_id
    and (
      select count(*) =
        v_tx_count
      from haulvia.payout_transactions
      where payout_id =
        v_payout
    )
    and (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
          v_event
        and status =
          'COMMITTED'
    )
  );


  perform pg_temp.p2e_expect_error(
    '12 committed payout webhook rejects changed command hash',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_set(
        v_dispatch_request,
        '{commandRequestSha256}',
        to_jsonb(
          repeat('9',64)
        )
      )::text
    ),

    'PROVIDER_EVENT_CONFLICT'
  );


  perform pg_temp.p2e_assert(
    '13 payout-success conflict creates no additional dispatch attempt',
    (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_event
    )
  );

end;
$$;


-- ============================================================================
-- PAYOUT FAILURE
-- ============================================================================

do $$
declare
  v_f jsonb;

  v_shipment uuid;
  v_payout uuid;

  v_submit jsonb;
  v_request_tx uuid;

  v_adapter uuid;
  v_event uuid;

  v_lock bigint;

  v_dispatch_request jsonb;
  v_result jsonb;
  v_dispatch_id uuid;

  v_tx_count integer;

  v_retry jsonb;
  v_retry_tx uuid;
  v_retry_adapter uuid;
begin

  v_f :=
    pg_temp.resolve_and_complete(
      'p2e-payout-failure'
    );

  v_shipment :=
    (
      v_f ->
>       'shipmentId'
    )::uuid;

  v_payout :=
    (
      v_f ->
>       'payoutId'
    )::uuid;


  v_submit :=
    pg_temp.submit_payout_request(
      v_shipment,
      v_payout,
      'p2e-payout-failure-submit',
      '2',
      'p2e-payout-failure-provider-request'
    );

  v_request_tx :=
    (
      v_submit ->
>       'payoutTransactionId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '14 failure fixture enters PROCESSING through D06',
    (
      v_submit ->
>       'driverPayoutState'
    ) = 'PROCESSING'
    and (
      select
        state =
          'PROCESSING'
      from haulvia.driver_payouts
      where id =
        v_payout
    )
    and (
      select status =
        'PENDING'
      from haulvia.payout_transactions
      where id =
        v_request_tx
    )
  );


  v_adapter :=
    pg_temp.prepare_payout_adapter(
      v_shipment,
      v_payout,
      v_request_tx,
      'p2e-payout-failure',
      'f2e42000-0000-0000-0000-000000000001',
      'd'
    );


  perform pg_temp.p2e_assert(
    '15 failure adapter reaches SUBMITTED with exact payout request',
    (
      select
        status =
          'SUBMITTED'
        and payout_id =
          v_payout
        and payout_transaction_id =
          v_request_tx
      from haulvia.provider_adapter_requests
      where id =
        v_adapter
    )
  );


  v_event :=
    pg_temp.receive_payout_outcome(
      'evt-p2e-payout-failure-001',
      'FAILED',
      'payout-p2e-failure-001',
      'f2e42000-0000-0000-0000-000000000002',
      'e'
    );


  perform pg_temp.p2e_assert(
    '16 failed payout webhook is retained as verified immutable evidence',
    (
      select
        signature_verified
        and verifier_authority =
          'PAYOUT_PROVIDER_CALLBACK'
        and normalized_event_snapshot ->
>           'failureCode' =
              'ACCOUNT_TEMPORARILY_UNAVAILABLE'
      from haulvia.provider_webhook_events
      where id =
        v_event
    )
  );


  select lock_version
  into v_lock
  from haulvia.shipments
  where id =
    v_shipment;


  v_dispatch_request :=
    jsonb_build_object(
      'providerWebhookEventId',
        v_event,

      'providerAdapterRequestId',
        v_adapter,

      'commandRequestSha256',
        repeat('f',64),

      'commandRequest',
        jsonb_build_object(
          'expectedShipmentVersion',
            v_lock
        ),

      'workerAuthority',
        'PAYOUT_PROVIDER_CALLBACK'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_dispatch_request
    );

  v_dispatch_id :=
    (
      v_result ->
>       'providerWebhookDispatchId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '17 payout failure commits through canonical D08',
    v_result ->
>       'dispatchStatus' =
          'COMMITTED'
    and v_result ->
>       'targetCommand' =
          'command_handle_payout_failure'
    and v_result ->
      'commandResult' ->
>       'driverPayoutState' =
          'FAILED'
  );


  perform pg_temp.p2e_assert(
    '18 D08 leaves shipment COMPLETED and moves payout plus axis to FAILED',
    (
      select
        shipment_state =
          'COMPLETED'
        and terminal_at is not null
      from haulvia.shipments
      where id =
        v_shipment
    )
    and (
      select state =
        'FAILED'
      from haulvia.driver_payouts
      where id =
        v_payout
    )
    and (
      select
        state =
          'FAILED'
        and eligible_amount =
          90
      from haulvia.shipment_driver_payout_axes
      where shipment_id =
        v_shipment
    )
  );


  perform pg_temp.p2e_assert(
    '19 failed payout outcome retains exact failed provider evidence',
    (
      select count(*) = 1
      from haulvia.payout_transactions
      where payout_id =
          v_payout
        and request_transaction_id =
          v_request_tx
        and status =
          'FAILED'
        and amount = 90
        and external_provider =
          'block-d-payouts'
        and provider_event_id =
          'evt-p2e-payout-failure-001'
        and external_reference =
          'payout-p2e-failure-001'
        and response_payload ->
>           'failureCode' =
              'ACCOUNT_TEMPORARILY_UNAVAILABLE'
    )
  );


  v_tx_count :=
    (
      select count(*)
      from haulvia.payout_transactions
      where payout_id =
        v_payout
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_dispatch_request
    );


  perform pg_temp.p2e_assert(
    '20 payout-failure exact replay creates no second provider outcome',
    (
      v_result ->
>       'duplicateDispatch'
    )::boolean
    and (
      v_result ->
>       'providerWebhookDispatchId'
    )::uuid = v_dispatch_id
    and (
      select count(*) =
        v_tx_count
      from haulvia.payout_transactions
      where payout_id =
        v_payout
    )
    and (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
          v_event
        and status =
          'COMMITTED'
    )
  );


  -- -------------------------------------------------------------------------
  -- Canonical retry after retained failure
  -- -------------------------------------------------------------------------

  v_retry :=
    pg_temp.submit_payout_request(
      v_shipment,
      v_payout,
      'p2e-payout-failure-retry',
      '3',
      'p2e-payout-failure-provider-request-2'
    );

  v_retry_tx :=
    (
      v_retry ->
>       'payoutTransactionId'
    )::uuid;


  perform pg_temp.p2e_assert(
    '21 retained payout failure permits a new D06 provider request',
    (
      v_retry ->
>       'driverPayoutState'
    ) = 'PROCESSING'
    and v_retry_tx <>
      v_request_tx
    and (
      select state =
        'PROCESSING'
      from haulvia.driver_payouts
      where id =
        v_payout
    )
    and (
      select
        count(*) filter(
          where status =
            'PENDING'
        ) = 2
        and count(*) filter(
          where status =
            'FAILED'
        ) = 1
      from haulvia.payout_transactions
      where payout_id =
        v_payout
    )
  );


  v_retry_adapter :=
    pg_temp.prepare_payout_adapter(
      v_shipment,
      v_payout,
      v_retry_tx,
      'p2e-payout-failure-retry',
      'f2e42000-0000-0000-0000-000000000003',
      '4'
    );


  perform pg_temp.p2e_assert(
    '22 retry payout request can independently reach adapter SUBMITTED',
    (
      select
        status =
          'SUBMITTED'
        and payout_id =
          v_payout
        and payout_transaction_id =
          v_retry_tx
        and operation =
          'DRIVER_PAYOUT'
      from haulvia.provider_adapter_requests
      where id =
        v_retry_adapter
    )
    and (
      select count(*) = 2
      from haulvia.provider_adapter_requests
      where payout_id =
        v_payout
    )
  );

end;
$$;


-- ============================================================================
-- Cross-scenario invariants
-- ============================================================================

select pg_temp.p2e_assert(
  '23 all payout webhooks retain dedicated payout callback authority',
  (
    select
      count(*) = 2
      and bool_and(
        signature_verified
      )
      and bool_and(
        verifier_authority =
          'PAYOUT_PROVIDER_CALLBACK'
      )
    from haulvia.provider_webhook_events
  )
);


select pg_temp.p2e_assert(
  '24 payout success and failure each have exactly one committed dispatch',
  (
    select
      count(*) = 2
      and count(*) filter(
        where status =
          'COMMITTED'
      ) = 2
      and count(*) filter(
        where status =
          'FAILED'
      ) = 0
      and count(*) filter(
        where target_command =
          'command_confirm_driver_payout'
      ) = 1
      and count(*) filter(
        where target_command =
          'command_handle_payout_failure'
      ) = 1
    from haulvia.provider_webhook_dispatches
  )
);


select pg_temp.p2e_assert(
  '25 P2E wrapper count remains 91 inside transaction',
  (
    select count(distinct p.proname) = 91
    from pg_proc p
    join pg_namespace n
      on n.oid =
        p.pronamespace
    where n.nspname =
        'haulvia_command'
      and p.proname like
        'command\_%'
        escape '\'
  )
);


\echo
\echo ================ BLOCK 3B PAYOUT RESULTS ================
\echo

select
  test_no,
  test_name,
  passed,
  detail
from p2e_payout_results
order by test_no;


\echo
\echo ================ BLOCK 3B PAYOUT SUMMARY ================
\echo

select
  count(*) as total_tests,
  count(*) filter(
    where passed
  ) as passed_tests,
  count(*) filter(
    where not passed
  ) as failed_tests
from p2e_payout_results;


do $$
begin
  if exists (
    select 1
    from p2e_payout_results
    where not passed
  ) then
    raise exception
      'P2E Block 3B payout behavior suite has failed assertions';
  end if;
end;
$$;


\echo
\echo Payout behavior suite passed. Rolling back.
\echo
'@


# ============================================================================
# Remove accidental formatting marker introduced by chat wrapping, if present.
#
# This only normalizes the temporary SQL text being generated below.
# ============================================================================

$behaviorSql =
    $behaviorSql.Replace(
        "->`r`n>       ",
        "->> "
    ).Replace(
        "->`n>       ",
        "->> "
    ).Replace(
        "->`r`n>           ",
        "->> "
    ).Replace(
        "->`n>           ",
        "->> "
    )


# ============================================================================
# Build one rollback-only test file
# ============================================================================

$migrationText =
    Get-Content `
        -LiteralPath $migration `
        -Raw

$tempSql =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_block3b_payout_outcomes.sql"

$fullSql =
    @(
        ([regex]::Replace($migrationText.TrimEnd(), '(?im)^\s*COMMIT\s*;\s*$', '')).TrimEnd(),
        $blockDSetup.Trim(),
        $behaviorSql.Trim(),
        "ROLLBACK;"
    ) -join "`r`n`r`n"

[System.IO.File]::WriteAllText(
    $tempSql,
    $fullSql,
    [System.Text.UTF8Encoding]::new($false)
)


# Ensure no chat-wrap marker survived into SQL.

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
Write-Host "================ RUN BLOCK 3B PAYOUT SUITE ================"
Write-Host ""

& psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -v ON_ERROR_STOP=1 `
    -f $tempSql

$testExitCode =
    $LASTEXITCODE


# ============================================================================
# Verify rollback
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

if ($post -ne "0|0|0|86|t|t|t") {
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

$commitCount = (
    Select-String `
        -Path $migration `
        -Pattern '^\s*COMMIT\s*;\s*$' `
        -CaseSensitive:$false
).Count

Write-Host "Migration COMMIT count: $commitCount"

if ($commitCount -ne 1) {
    throw "P2E migration must contain exactly one deployment COMMIT."
}


Write-Host ""
Write-Host "================ GIT STATUS ================"
Write-Host ""

git status --short


if ($testExitCode -ne 0) {
    Write-Host ""
    Write-Host "Payout test SQL preserved for diagnosis:"
    Write-Host $tempSql

    throw "P2E Block 3B payout behavior suite failed."
}


Remove-Item `
    -LiteralPath $tempSql `
    -Force


Write-Host ""
Write-Host "PASS: payout-success webhook dispatched through canonical D07."
Write-Host "PASS: full payout reached PAID while shipment remained COMPLETED."
Write-Host "PASS: payout-success replay created no duplicate provider outcome."
Write-Host "PASS: payout-failure webhook dispatched through canonical D08."
Write-Host "PASS: provider failure was retained without reopening shipment lifecycle."
Write-Host "PASS: payout-failure replay created no duplicate provider outcome."
Write-Host "PASS: failed payout can issue a new D06 request and P2E adapter attempt."
Write-Host "PASS: dedicated PAYOUT_PROVIDER_CALLBACK authority remained enforced."
Write-Host "PASS: rollback restored the 86-wrapper P2D baseline."
Write-Host ""
Write-Host "NEXT: Block 3B unsupported-operation behavior and dispatch edge hardening."