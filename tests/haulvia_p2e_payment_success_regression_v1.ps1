$ErrorActionPreference = "Stop"

$migration  = ".\supabase\migrations\20260920024711_haulvia_p2e_provider_adapters_and_webhooks_v1.sql"
$contract   = ".\docs\Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md"
$blockATest = ".\tests\haulvia_block_a_acceptance_v1.sql"

$expectedContractHash =
    "60C0408922C0474B3338C5E1274B6C74B570F57B18F01ACE62E7E718EBB7140A"

if (-not $env:HAULVIA_P2E_TEST_DATABASE_URL) {
    throw "HAULVIA_P2E_TEST_DATABASE_URL is not set."
}

foreach ($path in @(
    $migration,
    $contract,
    $blockATest
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
  (select count(*) from haulvia.payment_intents),
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
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Last 1
).Trim()

Write-Host "Baseline result: $baseline"

if ($baseline -ne "0|0|86|t|t|t") {
    throw "Database is not at clean P2D baseline."
}


# ============================================================================
# Extract Block A fixture setup only
# ============================================================================

$blockAText =
    Get-Content `
        -LiteralPath $blockATest `
        -Raw

$beginMatch =
    [regex]::Match(
        $blockAText,
        '(?im)^\s*begin\s*;\s*\r?\n'
    )

if (-not $beginMatch.Success) {
    throw "Block A BEGIN not found."
}

$fixtureMarker =
    "-- Main independent-driver path covers A01-A04, A06-A08, A11, A13-A17."

$fixtureEnd =
    $blockAText.IndexOf(
        $fixtureMarker,
        [System.StringComparison]::Ordinal
    )

if ($fixtureEnd -lt 0) {
    throw "Block A fixture marker not found."
}

$fixtureStart =
    $beginMatch.Index +
    $beginMatch.Length

$blockASetup =
    $blockAText.Substring(
        $fixtureStart,
        $fixtureEnd - $fixtureStart
    )


# ============================================================================
# P2A compatibility patch for extracted historical setup
# ============================================================================

$approverOrg =
    "f2e10000-0000-0000-0000-000000000001"

$approverProfile =
    "f2e10000-0000-0000-0000-000000000002"

$approverMembership =
    "f2e10000-0000-0000-0000-000000000003"

$approverReauth =
    "f2e10000-0000-0000-0000-000000000004"


$bridge = @"

-- P2E-PAYMENT-SUCCESS-PUBLICATION-BRIDGE

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  '$approverOrg',
  'p2e-payment-success-approver',
  'HAULVIA',
  'P2E Payment Success Approver',
  'P2E Payment Success Approver'
);

insert into haulvia.profiles (
  id,
  display_name
)
values (
  '$approverProfile',
  'P2E Payment Success Approver'
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
    "-- Shared authority, policy, pricing, payment, and provider fixtures."

if (
    (
        [regex]::Matches(
            $blockASetup,
            [regex]::Escape($anchor)
        )
    ).Count -ne 1
) {
    throw "Block A shared-fixture anchor mismatch."
}

$blockASetup =
    $blockASetup.Replace(
        $anchor,
        $bridge + "`r`n" + $anchor
    )


$old = @'
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
'@

$new = @"
  insert into policy_versions (
    id, policy_set_id, version_no, publication_status, effective_from, config,
    config_sha256, legal_review_required, created_by_profile_id,
    approved_by_profile_id, approved_at, reauth_session_id, approval_reason
  ) values (
    v_policy_version, v_policy_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object(
      'evidenceRequirements', jsonb_build_object('photo', true),
      'cancellationRules', jsonb_build_object('preAssignment', 'allowed'),
      'refundRules', '{}'::jsonb, 'timingWindows', '{}'::jsonb, 'riskRules', '{}'::jsonb
    ), repeat('1', 64), false, v_customer,
    '$approverProfile'::uuid, clock_timestamp(),
    '$approverReauth'::uuid,
    'P2E payment dispatch rollback fixture policy approval'
  );
"@

if (-not $blockASetup.Contains($old)) {
    throw "Block A policy fixture target not found."
}

$blockASetup =
    $blockASetup.Replace(
        $old,
        $new
    )


$old = @'
  insert into pricing_rule_versions (
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values
    (v_guard_version, v_guard_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('floorAmount', 50, 'ceilingAmount', 200, 'absoluteCapAmount', 300),
      repeat('2', 64), v_customer, v_customer, clock_timestamp()),
    (v_fixed_version, v_fixed_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('fixedAmount', 150), repeat('3', 64), v_customer, v_customer, clock_timestamp());
'@

$new = @"
  insert into pricing_rule_versions (
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id,
    approved_at, reauth_session_id, approval_reason
  ) values
    (v_guard_version, v_guard_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('floorAmount', 50, 'ceilingAmount', 200, 'absoluteCapAmount', 300),
      repeat('2', 64), v_customer, '$approverProfile'::uuid,
      clock_timestamp(), '$approverReauth'::uuid,
      'P2E payment dispatch rollback fixture guardrail approval'),
    (v_fixed_version, v_fixed_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('fixedAmount', 150), repeat('3', 64),
      v_customer, '$approverProfile'::uuid,
      clock_timestamp(), '$approverReauth'::uuid,
      'P2E payment dispatch rollback fixture fixed pricing approval');
"@

if (-not $blockASetup.Contains($old)) {
    throw "Block A pricing fixture target not found."
}

$blockASetup =
    $blockASetup.Replace(
        $old,
        $new
    )


$old = @'
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    v_partner_profile, clock_timestamp(), v_reauth
'@

$new = @"
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    '$approverProfile'::uuid, clock_timestamp(), '$approverReauth'::uuid
"@

if (-not $blockASetup.Contains($old)) {
    throw "Block A partner rate-card target not found."
}

$blockASetup =
    $blockASetup.Replace(
        $old,
        $new
    )


# ============================================================================
# Payment-success dispatch behavior suite
# ============================================================================

$behaviorSql = @'

set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


create temporary table p2e_dispatch_test_results (
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
  insert into p2e_dispatch_test_results(
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

    insert into p2e_dispatch_test_results(
      test_name,
      passed,
      detail
    )
    values (
      p_name,
      false,
      'Expected error ' || p_expected_code || ' but statement succeeded'
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
          v_detail_json := '{}'::jsonb;
      end;

      v_actual_code :=
        v_detail_json ->> 'code';

      insert into p2e_dispatch_test_results(
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
          coalesce(v_actual_code, '<null>')
      );
  end;
end;
$$;


-- ============================================================================
-- Proven Block A payment-ready fixture
-- ============================================================================

create or replace function pg_temp.seed_p2e_payment_ready(
  p_label text,
  p_amount numeric default 125
)
returns jsonb
language plpgsql
as $$
declare
  v_customer uuid :=
    '10000000-0000-0000-0000-000000000002';

  v_customer_org uuid :=
    '10000000-0000-0000-0000-000000000001';

  v_provider_org uuid :=
    '20000000-0000-0000-0000-000000000001';

  v_provider_profile uuid :=
    '20000000-0000-0000-0000-000000000002';

  v_provider uuid :=
    '20000000-0000-0000-0000-000000000003';

  v_driver uuid :=
    '20000000-0000-0000-0000-000000000004';

  v_vehicle uuid :=
    '20000000-0000-0000-0000-000000000005';

  v_policy uuid :=
    '40000000-0000-0000-0000-000000000002';

  v_rule uuid :=
    '50000000-0000-0000-0000-000000000002';

  v_payment_method uuid :=
    '70000000-0000-0000-0000-000000000001';

  v_shipment uuid;
  v_route uuid;
  v_thread uuid;
  v_revision uuid;
  v_reservation uuid;
  v_intent uuid;

  v_result jsonb;
  v_lock bigint;
begin
  insert into haulvia.shipments(
    customer_organization_id,
    customer_profile_id,
    pickup_timing,
    service_level,
    currency
  )
  values (
    v_customer_org,
    v_customer,
    'ASAP',
    'FLEX',
    'CAD'
  )
  returning id
  into v_shipment;


  select haulvia_command.command_save_draft(
    jsonb_build_object(
      'commandId', gen_random_uuid(),
      'idempotencyKey', p_label || '-save',
      'requestHash', repeat('1',64),
      'actorProfileId', v_customer,
      'actorOrganizationId', v_customer_org,
      'shipmentId', v_shipment,
      'expectedShipmentVersion', 0,
      'requestedAt', clock_timestamp(),
      'routePlan', pg_temp.make_plan()
    )
  )
  into v_result;

  v_route :=
    (v_result ->> 'routeVersionId')::uuid;


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  select haulvia_command.command_post_shipment(
    jsonb_build_object(
      'commandId', gen_random_uuid(),
      'idempotencyKey', p_label || '-post',
      'requestHash', repeat('2',64),
      'actorProfileId', v_customer,
      'actorOrganizationId', v_customer_org,
      'shipmentId', v_shipment,
      'expectedShipmentVersion', v_lock,
      'expectedRouteVersionId', v_route,
      'requestedAt', clock_timestamp(),
      'paymentMethodId', v_payment_method,
      'policyVersionId', v_policy,
      'marketplaceDeadline', clock_timestamp() + interval '3 hours',
      'pricingSource', 'HAULVIA_GUARDRAIL',
      'pricingMode', 'NOT_APPLICABLE',
      'pricingRuleVersionId', v_rule,
      'amount', p_amount,
      'subtotal', p_amount,
      'taxAmount', 0,
      'currency', 'CAD',
      'breakdown', '[]'::jsonb,
      'snapshotSha256', repeat('2',64)
    )
  )
  into v_result;


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  select haulvia_command.command_submit_independent_flex_offer(
    jsonb_build_object(
      'commandId', gen_random_uuid(),
      'idempotencyKey', p_label || '-offer',
      'requestHash', repeat('3',64),
      'actorProfileId', v_provider_profile,
      'actorOrganizationId', v_provider_org,
      'shipmentId', v_shipment,
      'expectedShipmentVersion', v_lock,
      'expectedRouteVersionId', v_route,
      'requestedAt', clock_timestamp(),
      'providerId', v_provider,
      'driverId', v_driver,
      'vehicleId', v_vehicle,
      'coversWholeRoute', true,
      'validUntil', clock_timestamp() + interval '2 hours',
      'pricingSource', 'HAULVIA_GUARDRAIL',
      'pricingMode', 'NOT_APPLICABLE',
      'pricingRuleVersionId', v_rule,
      'amount', p_amount,
      'subtotal', p_amount,
      'taxAmount', 0,
      'currency', 'CAD',
      'breakdown', '[]'::jsonb,
      'snapshotSha256', repeat('3',64)
    )
  )
  into v_result;

  v_thread :=
    (v_result ->> 'offerThreadId')::uuid;

  v_revision :=
    (v_result ->> 'offerRevisionId')::uuid;


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  select haulvia_command.command_reserve_selection(
    jsonb_build_object(
      'commandId', gen_random_uuid(),
      'idempotencyKey', p_label || '-reserve',
      'requestHash', repeat('4',64),
      'actorProfileId', v_customer,
      'actorOrganizationId', v_customer_org,
      'shipmentId', v_shipment,
      'expectedShipmentVersion', v_lock,
      'expectedRouteVersionId', v_route,
      'requestedAt', clock_timestamp(),
      'offerThreadId', v_thread,
      'selectedRevisionId', v_revision,
      'paymentMethodId', v_payment_method,
      'reservationExpiresAt', clock_timestamp() + interval '30 minutes',
      'reservationSnapshotSha256', repeat('4',64),
      'paymentProvider', 'TESTPAY',
      'paymentProviderIdempotencyKey', p_label || '-provider'
    )
  )
  into v_result;

  v_reservation :=
    (v_result ->> 'reservationId')::uuid;

  v_intent :=
    (v_result ->> 'paymentIntentId')::uuid;


  return jsonb_build_object(
    'shipmentId', v_shipment,
    'routeVersionId', v_route,
    'reservationId', v_reservation,
    'paymentIntentId', v_intent
  );
end;
$$;


-- ============================================================================
-- Payment-success webhook dispatch
-- ============================================================================

do $$
declare
  v_f jsonb;

  v_shipment uuid;
  v_route uuid;
  v_intent uuid;

  v_adapter jsonb;
  v_adapter_id uuid;

  v_attempt jsonb;

  v_webhook jsonb;
  v_webhook_id uuid;

  v_lock bigint;

  v_bad_dispatch jsonb;
  v_failed jsonb;

  v_good_command jsonb;
  v_good_dispatch jsonb;
  v_committed jsonb;
  v_committed_id uuid;

  v_replay jsonb;

  v_before_assignment_count integer;
  v_before_payment_tx_count integer;
begin

  v_f :=
    pg_temp.seed_p2e_payment_ready(
      'p2e-dispatch-success',
      125
    );

  v_shipment :=
    (v_f ->> 'shipmentId')::uuid;

  v_route :=
    (v_f ->> 'routeVersionId')::uuid;

  v_intent :=
    (v_f ->> 'paymentIntentId')::uuid;


  perform pg_temp.p2e_assert(
    '01 payment fixture is awaiting provider outcome',
    (
      select
        shipment_state = 'NEGOTIATING'
      from haulvia.shipments
      where id = v_shipment
    )
    and (
      select
        status = 'AUTHORIZING'
      from haulvia.payment_intents
      where id = v_intent
    )
  );


  v_adapter :=
    haulvia_command.command_prepare_provider_adapter_request(
      jsonb_build_object(
        'shipmentId',
          v_shipment,

        'operation',
          'PAYMENT_AUTHORIZE',

        'externalProvider',
          'TESTPAY',

        'providerIdempotencyKey',
          'p2e-dispatch-success-adapter',

        'correlationId',
          'f2e20000-0000-0000-0000-000000000001',

        'paymentIntentId',
          v_intent,

        'requestFingerprintSha256',
          repeat('a',64),

        'requestSnapshot',
          jsonb_build_object(
            'amount',125,
            'currency','CAD',
            'paymentMethodReference','pm_p2e_success'
          ),

        'workerAuthority',
          'PAYMENT_WORKER'
      )
    );

  v_adapter_id :=
    (v_adapter ->> 'providerAdapterRequestId')::uuid;


  v_attempt :=
    haulvia_command.command_record_provider_adapter_attempt(
      jsonb_build_object(
        'providerAdapterRequestId',
          v_adapter_id,

        'attemptNo',
          1,

        'startedAt',
          '2099-01-04T00:00:00Z',

        'completedAt',
          '2099-01-04T00:00:01Z',

        'submissionSucceeded',
          true,

        'normalizedResult',
          jsonb_build_object(
            'accepted',true
          ),

        'providerStatus',
          'submitted',

        'providerReference',
          'provider-request-payment-success',

        'retryable',
          false,

        'responseSnapshot',
          jsonb_build_object(
            'status','submitted',
            'providerReference','provider-request-payment-success'
          ),

        'workerAuthority',
          'PAYMENT_WORKER'
      )
    );


  perform pg_temp.p2e_assert(
    '02 outbound payment adapter is SUBMITTED',
    v_attempt ->> 'requestStatus' = 'SUBMITTED'
    and (
      select status = 'SUBMITTED'
      from haulvia.provider_adapter_requests
      where id = v_adapter_id
    )
  );


  v_webhook :=
    haulvia_command.command_receive_provider_webhook(
      jsonb_build_object(
        'externalProvider',
          'TESTPAY',

        'providerEventId',
          'evt-p2e-payment-success-001',

        'providerEventType',
          'payment.authorization.succeeded',

        'bodySha256',
          repeat('b',64),

        'signatureVerified',
          true,

        'correlationId',
          'f2e20000-0000-0000-0000-000000000002',

        'providerOccurredAt',
          '2099-01-04T00:00:02Z',

        'verificationContext',
          jsonb_build_object(
            'algorithm','TEST_SIGNATURE',
            'keyVersion','test-v1'
          ),

        'normalizedEventSnapshot',
          jsonb_build_object(
            'operation','PAYMENT_AUTHORIZE',
            'outcome','SUCCEEDED',
            'amount',125,
            'currency','CAD',
            'providerReference','txn-p2e-payment-success-001',
            'transactionType','AUTHORIZE'
          ),

        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )
    );

  v_webhook_id :=
    (v_webhook ->> 'providerWebhookEventId')::uuid;


  perform pg_temp.p2e_assert(
    '03 verified payment webhook is retained',
    v_webhook_id is not null
    and (
      select
        signature_verified
        and verifier_authority =
          'PAYMENT_PROVIDER_CALLBACK'
      from haulvia.provider_webhook_events
      where id = v_webhook_id
    )
  );


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  v_good_command :=
    jsonb_build_object(
      'expectedShipmentVersion',
        v_lock,

      'expectedRouteVersionId',
        v_route,

      'assignmentSnapshotSha256',
        repeat('c',64),

      'agreementSnapshot',
        jsonb_build_object(
          'termsVersion','p2e-test-v1'
        )
    );


  -- PAYMENT_WORKER is not a legal inbound callback authority.

  perform pg_temp.p2e_expect_error(
    '04 generic PAYMENT_WORKER cannot dispatch inbound webhook',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_build_object(
        'providerWebhookEventId',
          v_webhook_id,

        'providerAdapterRequestId',
          v_adapter_id,

        'commandRequestSha256',
          repeat('d',64),

        'commandRequest',
          v_good_command,

        'workerAuthority',
          'PAYMENT_WORKER'
      )::text
    ),

    'NOT_AUTHORIZED'
  );


  perform pg_temp.p2e_assert(
    '05 rejected authority creates no dispatch row',
    (
      select count(*) = 0
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_webhook_id
    )
  );


  -- -------------------------------------------------------------------------
  -- First trusted dispatch intentionally omits assignmentSnapshotSha256.
  --
  -- Canonical A16 must reject it. Block 3B must retain FAILED dispatch
  -- evidence without retaining partial financial mutation.
  -- -------------------------------------------------------------------------

  v_bad_dispatch :=
    jsonb_build_object(
      'providerWebhookEventId',
        v_webhook_id,

      'providerAdapterRequestId',
        v_adapter_id,

      'commandRequestSha256',
        repeat('e',64),

      'commandRequest',
        jsonb_build_object(
          'expectedShipmentVersion',
            v_lock,

          'expectedRouteVersionId',
            v_route
        ),

      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_failed :=
    haulvia_command.command_dispatch_provider_webhook(
      v_bad_dispatch
    );


  perform pg_temp.p2e_assert(
    '06 canonical A16 failure is normalized as FAILED dispatch',
    v_failed ->> 'dispatchStatus' = 'FAILED'
    and v_failed ->> 'haulviaErrorCode' is not null
  );


  perform pg_temp.p2e_assert(
    '07 failed dispatch retains one append-only failure attempt',
    (
      select
        count(*) = 1
        and bool_and(status = 'FAILED')
        and min(dispatch_attempt_no) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_webhook_id
    )
  );


  perform pg_temp.p2e_assert(
    '08 failed canonical command leaves financial state unchanged',
    (
      select status = 'AUTHORIZING'
      from haulvia.payment_intents
      where id = v_intent
    )
    and (
      select shipment_state = 'NEGOTIATING'
      from haulvia.shipments
      where id = v_shipment
    )
    and not exists (
      select 1
      from haulvia.assignments
      where shipment_id = v_shipment
        and status = 'ACTIVE'
    )
  );


  -- Refresh optimistic lock after failed inner subtransaction.
  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;

  v_good_command :=
    jsonb_set(
      v_good_command,
      '{expectedShipmentVersion}',
      to_jsonb(v_lock)
    );


  v_good_dispatch :=
    jsonb_build_object(
      'providerWebhookEventId',
        v_webhook_id,

      'providerAdapterRequestId',
        v_adapter_id,

      'commandRequestSha256',
        repeat('f',64),

      'commandRequest',
        v_good_command,

      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_before_assignment_count :=
    (
      select count(*)
      from haulvia.assignments
      where shipment_id = v_shipment
    );

  v_before_payment_tx_count :=
    (
      select count(*)
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    );


  v_committed :=
    haulvia_command.command_dispatch_provider_webhook(
      v_good_dispatch
    );

  v_committed_id :=
    (v_committed ->> 'providerWebhookDispatchId')::uuid;


  perform pg_temp.p2e_assert(
    '09 corrected retry commits through canonical A16',
    v_committed ->> 'dispatchStatus' = 'COMMITTED'
    and coalesce(
      (v_committed ->> 'duplicateDispatch')::boolean,
      false
    ) = false
  );


  -- P2E-PAYMENT-SUCCESS-AXIS-ASSERTION-FIX
  -- Shipment lifecycle and customer-payment state are separate canonical axes.
  perform pg_temp.p2e_assert(
    '10 A16 secures payment and creates DRIVER_ASSIGNED shipment',
    (
      select
        shipment_state = 'DRIVER_ASSIGNED'
      from haulvia.shipments
      where id = v_shipment
    )
    and (
      select
        state = 'SECURED'
        and secured_amount = 125
        and currency = 'CAD'
      from haulvia.shipment_customer_payment_axes
      where shipment_id = v_shipment
    )
    and (
      select
        status = 'SECURED'
        and amount = 125
        and currency = 'CAD'
      from haulvia.payment_intents
      where id = v_intent
    )
  );


  perform pg_temp.p2e_assert(
    '11 successful dispatch creates exactly one active assignment',
    (
      select count(*) =
        v_before_assignment_count + 1
      from haulvia.assignments
      where shipment_id = v_shipment
    )
    and (
      select count(*) = 1
      from haulvia.assignments
      where shipment_id = v_shipment
        and status = 'ACTIVE'
    )
  );


  perform pg_temp.p2e_assert(
    '12 canonical payment transaction retains webhook provider event',
    (
      select count(*) =
        v_before_payment_tx_count + 1
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    )
    and exists (
      select 1
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
        and provider_event_id =
          'evt-p2e-payment-success-001'
    )
  );


  perform pg_temp.p2e_assert(
    '13 dispatch history retains failed then committed attempts',
    (
      select
        count(*) = 2
        and count(*) filter(
          where status = 'FAILED'
        ) = 1
        and count(*) filter(
          where status = 'COMMITTED'
        ) = 1
        and max(dispatch_attempt_no) = 2
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_webhook_id
    )
  );


  perform pg_temp.p2e_assert(
    '14 committed dispatch retains canonical correlation evidence',
    (
      select
        provider_adapter_request_id =
          v_adapter_id
        and shipment_id =
          v_shipment
        and normalized_operation =
          'PAYMENT_AUTHORIZE'
        and normalized_outcome =
          'SUCCEEDED'
        and target_command =
          'command_confirm_paid_assignment'
        and command_request_hash =
          repeat('f',64)
      from haulvia.provider_webhook_dispatches
      where id = v_committed_id
    )
  );


  -- -------------------------------------------------------------------------
  -- Exact dispatch replay
  -- -------------------------------------------------------------------------

  v_replay :=
    haulvia_command.command_dispatch_provider_webhook(
      v_good_dispatch
    );


  perform pg_temp.p2e_assert(
    '15 exact committed dispatch replay returns original dispatch',
    (v_replay ->> 'duplicateDispatch')::boolean
    and (
      v_replay ->> 'providerWebhookDispatchId'
    )::uuid = v_committed_id
  );


  perform pg_temp.p2e_assert(
    '16 exact replay creates no additional dispatch or financial mutation',
    (
      select count(*) = 2
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_webhook_id
    )
    and (
      select count(*) =
        v_before_assignment_count + 1
      from haulvia.assignments
      where shipment_id = v_shipment
    )
    and (
      select count(*) =
        v_before_payment_tx_count + 1
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    )
  );


  -- -------------------------------------------------------------------------
  -- Same committed webhook, different canonical request hash = conflict.
  -- -------------------------------------------------------------------------

  perform pg_temp.p2e_expect_error(
    '17 committed webhook dispatch rejects changed command hash',

    format(
      'select haulvia_command.command_dispatch_provider_webhook(%L::jsonb)',
      jsonb_set(
        v_good_dispatch,
        '{commandRequestSha256}',
        to_jsonb(repeat('9',64))
      )::text
    ),

    'PROVIDER_EVENT_CONFLICT'
  );


  perform pg_temp.p2e_assert(
    '18 dispatch conflict creates no third attempt',
    (
      select count(*) = 2
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id =
        v_webhook_id
    )
  );


  -- -------------------------------------------------------------------------
  -- Append-only dispatch evidence
  -- -------------------------------------------------------------------------

  perform pg_temp.p2e_expect_error(
    '19 committed dispatch cannot be updated',

    format(
      'update haulvia.provider_webhook_dispatches set correlation_id = gen_random_uuid() where id = %L::uuid',
      v_committed_id::text
    ),

    'IMMUTABLE_RECORD'
  );


  perform pg_temp.p2e_expect_error(
    '20 committed dispatch cannot be deleted',

    format(
      'delete from haulvia.provider_webhook_dispatches where id = %L::uuid',
      v_committed_id::text
    ),

    'IMMUTABLE_RECORD'
  );

end;
$$;


select pg_temp.p2e_assert(
  '21 P2E wrapper count is 91 inside transaction',
  (
    select count(distinct p.proname) = 91
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname like 'command\_%' escape '\'
  )
);


\echo
\echo ================ BLOCK 3B PAYMENT SUCCESS RESULTS ================
\echo

select
  test_no,
  test_name,
  passed,
  detail
from p2e_dispatch_test_results
order by test_no;


\echo
\echo ================ BLOCK 3B PAYMENT SUCCESS SUMMARY ================
\echo

select
  count(*) as total_tests,
  count(*) filter (
    where passed
  ) as passed_tests,
  count(*) filter (
    where not passed
  ) as failed_tests
from p2e_dispatch_test_results;


do $$
begin
  if exists (
    select 1
    from p2e_dispatch_test_results
    where not passed
  ) then
    raise exception
      'P2E Block 3B payment-success behavior suite has failed assertions';
  end if;
end;
$$;

\echo
\echo Payment-success behavior suite passed. Rolling back.
\echo
'@


# ============================================================================
# Build rollback-only test file
# ============================================================================

$migrationText =
    Get-Content `
        -LiteralPath $migration `
        -Raw

$tempSql =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_block3b_payment_success.sql"

$fullSql =
    @(
        $migrationText.TrimEnd(),
        $blockASetup.Trim(),
        $behaviorSql.Trim(),
        "ROLLBACK;"
    ) -join "`r`n`r`n"

[System.IO.File]::WriteAllText(
    $tempSql,
    $fullSql,
    [System.Text.UTF8Encoding]::new($false)
)


Write-Host ""
Write-Host "Temporary test SQL:"
Write-Host $tempSql

Write-Host ""
Write-Host "================ RUN BLOCK 3B PAYMENT SUCCESS SUITE ================"
Write-Host ""

& psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -v ON_ERROR_STOP=1 `
    -f $tempSql

$testExitCode =
    $LASTEXITCODE


# ============================================================================
# Post-test rollback verification
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

if ($post -ne "0|0|86|t|t|t") {
    throw "Database did not return to clean P2D baseline."
}


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

if ($commitCount -ne 0) {
    throw "P2E migration unexpectedly contains COMMIT."
}


Write-Host ""
Write-Host "================ GIT STATUS ================"
Write-Host ""

git status --short


if ($testExitCode -ne 0) {
    Write-Host ""
    Write-Host "Payment-success test SQL preserved for diagnosis:"
    Write-Host $tempSql

    throw "P2E Block 3B payment-success behavior suite failed."
}


Remove-Item `
    -LiteralPath $tempSql `
    -Force


Write-Host ""
Write-Host "PASS: payment-success provider webhook dispatched through canonical A16."
Write-Host "PASS: failed canonical dispatch retained FAILED evidence without partial financial mutation."
Write-Host "PASS: corrected retry committed successfully."
Write-Host "PASS: exact committed replay produced no duplicate financial mutation."
Write-Host "PASS: changed command hash was rejected as a provider-event conflict."
Write-Host "PASS: dispatch evidence is append-only."
Write-Host "PASS: rollback restored the 86-wrapper P2D baseline."
Write-Host ""
Write-Host "NEXT: payment failure / timeout / late-success routes."