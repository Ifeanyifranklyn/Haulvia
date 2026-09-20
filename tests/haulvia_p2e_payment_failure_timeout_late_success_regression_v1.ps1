$ErrorActionPreference = "Stop"

$migration  = ".\supabase\migrations\20260920024711_haulvia_p2e_provider_adapters_and_webhooks_v1.sql"
$contract   = ".\docs\Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md"
$blockATest = ".\tests\haulvia_block_a_acceptance_v1.sql"

$expectedContractHash =
    "60C0408922C0474B3338C5E1274B6C74B570F57B18F01ACE62E7E718EBB7140A"

if (-not $env:HAULVIA_P2E_TEST_DATABASE_URL) {
    throw "HAULVIA_P2E_TEST_DATABASE_URL is not set."
}

foreach ($path in @($migration, $contract, $blockATest)) {
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
# Clean baseline
# ============================================================================

$baselineSql = @'
select
  (select count(*) from haulvia.shipments),
  (select count(*) from haulvia.payment_intents),
  (select count(*) from haulvia.payment_transactions),
  (
    select count(distinct p.proname)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname like 'command\_%' escape '\'
  ),
  to_regclass('haulvia.provider_adapter_requests') is null,
  to_regclass('haulvia.provider_webhook_events') is null,
  to_regclass('haulvia.provider_webhook_dispatches') is null;
'@

Write-Host ""
Write-Host "================ PRE-TEST BASELINE ================"

$baseline = & psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X -A -t -v ON_ERROR_STOP=1 `
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

if ($baseline -ne "0|0|0|86|t|t|t") {
    throw "Database is not at clean P2D baseline."
}


# ============================================================================
# Extract Block A fixture setup
# ============================================================================

$blockAText = Get-Content -LiteralPath $blockATest -Raw

$beginMatch = [regex]::Match(
    $blockAText,
    '(?im)^\s*begin\s*;\s*\r?\n'
)

if (-not $beginMatch.Success) {
    throw "Block A BEGIN not found."
}

$marker =
    "-- Main independent-driver path covers A01-A04, A06-A08, A11, A13-A17."

$endIndex = $blockAText.IndexOf(
    $marker,
    [System.StringComparison]::Ordinal
)

if ($endIndex -lt 0) {
    throw "Block A fixture marker not found."
}

$startIndex = $beginMatch.Index + $beginMatch.Length

$blockASetup = $blockAText.Substring(
    $startIndex,
    $endIndex - $startIndex
)


# ============================================================================
# P2A publication compatibility for historical fixture only
# ============================================================================

$approverOrg        = "f2e30000-0000-0000-0000-000000000001"
$approverProfile    = "f2e30000-0000-0000-0000-000000000002"
$approverMembership = "f2e30000-0000-0000-0000-000000000003"
$approverReauth     = "f2e30000-0000-0000-0000-000000000004"

$bridge = @"

-- P2E-A17-PUBLICATION-BRIDGE

insert into haulvia.organizations(
  id, organization_key, kind, legal_name, display_name
)
values (
  '$approverOrg',
  'p2e-a17-approver',
  'HAULVIA',
  'P2E A17 Fixture Approver',
  'P2E A17 Fixture Approver'
);

insert into haulvia.profiles(id, display_name)
values (
  '$approverProfile',
  'P2E A17 Fixture Approver'
);

insert into haulvia.organization_memberships(
  id, organization_id, profile_id, status
)
values (
  '$approverMembership',
  '$approverOrg',
  '$approverProfile',
  'ACTIVE'
);

insert into haulvia.membership_roles(
  membership_id, role_id
)
select
  '$approverMembership'::uuid,
  r.id
from haulvia.roles r
where r.role_key = 'PLATFORM_ADMIN';

insert into haulvia.reauth_sessions(
  id, profile_id, organization_id, method, verified_at, expires_at
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
    ([regex]::Matches(
        $blockASetup,
        [regex]::Escape($anchor)
    )).Count -ne 1
) {
    throw "Block A fixture anchor mismatch."
}

$blockASetup = $blockASetup.Replace(
    $anchor,
    $bridge + "`r`n" + $anchor
)


function Replace-One {
    param(
        [string]$Text,
        [string]$Old,
        [string]$New,
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

    return $Text.Replace($Old, $New)
}


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
    'P2E A17 rollback fixture policy approval'
  );
"@

$blockASetup = Replace-One `
    $blockASetup $old $new "Block A policy"


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
      'P2E A17 rollback fixture guardrail approval'),
    (v_fixed_version, v_fixed_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('fixedAmount', 150), repeat('3', 64),
      v_customer, '$approverProfile'::uuid,
      clock_timestamp(), '$approverReauth'::uuid,
      'P2E A17 rollback fixture fixed pricing approval');
"@

$blockASetup = Replace-One `
    $blockASetup $old $new "Block A pricing"


$old = @'
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    v_partner_profile, clock_timestamp(), v_reauth
'@

$new = @"
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    '$approverProfile'::uuid, clock_timestamp(), '$approverReauth'::uuid
"@

$blockASetup = Replace-One `
    $blockASetup $old $new "Block A rate card"


# ============================================================================
# Behavior SQL
# ============================================================================

$behaviorSql = @'

set local search_path =
  haulvia,
  haulvia_command,
  public,
  pg_temp;


create temporary table p2e_a17_results (
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
  insert into p2e_a17_results(
    test_name,
    passed,
    detail
  )
  values (
    p_name,
    p_condition is true,
    case
      when p_condition is true then p_detail
      else 'FAILED'
    end
  );
end;
$$;


-- ============================================================================
-- Canonical pre-assignment payment fixture
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
  returning id into v_shipment;


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
    'offerThreadId', v_thread,
    'reservationId', v_reservation,
    'paymentIntentId', v_intent
  );
end;
$$;


-- ============================================================================
-- Prepare + submit provider adapter request
-- ============================================================================

create or replace function pg_temp.prepare_payment_adapter(
  p_shipment uuid,
  p_intent uuid,
  p_label text,
  p_correlation uuid,
  p_digest_char text
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
        'shipmentId', p_shipment,
        'operation', 'PAYMENT_AUTHORIZE',
        'externalProvider', 'TESTPAY',
        'providerIdempotencyKey', p_label || '-adapter',
        'correlationId', p_correlation,
        'paymentIntentId', p_intent,
        'requestFingerprintSha256',
          repeat(p_digest_char,64),
        'requestSnapshot',
          jsonb_build_object(
            'amount',125,
            'currency','CAD',
            'paymentMethodReference',
              'pm_' || p_label
          ),
        'workerAuthority','PAYMENT_WORKER'
      )
    );

  v_adapter :=
    (v_prepare ->> 'providerAdapterRequestId')::uuid;


  v_attempt :=
    haulvia_command.command_record_provider_adapter_attempt(
      jsonb_build_object(
        'providerAdapterRequestId', v_adapter,
        'attemptNo', 1,
        'startedAt', '2099-01-05T00:00:00Z',
        'completedAt', '2099-01-05T00:00:01Z',
        'submissionSucceeded', true,
        'normalizedResult',
          jsonb_build_object('accepted',true),
        'providerStatus','submitted',
        'providerReference',
          'request-' || p_label,
        'retryable',false,
        'responseSnapshot',
          jsonb_build_object(
            'status','submitted',
            'providerReference',
              'request-' || p_label
          ),
        'workerAuthority','PAYMENT_WORKER'
      )
    );

  if v_attempt ->> 'requestStatus' <> 'SUBMITTED' then
    raise exception
      'Adapter did not reach SUBMITTED';
  end if;

  return v_adapter;
end;
$$;


-- ============================================================================
-- Receive normalized verified payment webhook
-- ============================================================================

create or replace function pg_temp.receive_payment_outcome(
  p_event_id text,
  p_outcome text,
  p_failure_category text,
  p_correlation uuid,
  p_digest_char text
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
        'externalProvider','TESTPAY',
        'providerEventId',p_event_id,
        'providerEventType',
          'payment.authorization.' ||
          lower(p_outcome),
        'bodySha256',
          repeat(p_digest_char,64),
        'signatureVerified',true,
        'correlationId',p_correlation,
        'providerOccurredAt',
          '2099-01-05T00:00:02Z',
        'verificationContext',
          jsonb_build_object(
            'algorithm','TEST_SIGNATURE',
            'keyVersion','test-v1'
          ),
        'normalizedEventSnapshot',
          jsonb_build_object(
            'operation','PAYMENT_AUTHORIZE',
            'outcome',p_outcome,
            'failureCategory',
              p_failure_category,
            'amount',125,
            'currency','CAD',
            'providerReference',
              'txn-' || p_event_id
          ),
        'workerAuthority',
          'PAYMENT_PROVIDER_CALLBACK'
      )
    );

  return
    (v_result ->> 'providerWebhookEventId')::uuid;
end;
$$;


-- ============================================================================
-- FAILED
-- ============================================================================

do $$
declare
  v_f jsonb;
  v_shipment uuid;
  v_reservation uuid;
  v_intent uuid;
  v_adapter uuid;
  v_event uuid;
  v_lock bigint;
  v_request jsonb;
  v_result jsonb;
  v_dispatch uuid;
  v_tx_count integer;
begin

  v_f :=
    pg_temp.seed_p2e_payment_ready(
      'p2e-a17-failed',
      125
    );

  v_shipment :=
    (v_f ->> 'shipmentId')::uuid;

  v_reservation :=
    (v_f ->> 'reservationId')::uuid;

  v_intent :=
    (v_f ->> 'paymentIntentId')::uuid;


  v_adapter :=
    pg_temp.prepare_payment_adapter(
      v_shipment,
      v_intent,
      'p2e-a17-failed',
      'f2e31000-0000-0000-0000-000000000001',
      'a'
    );

  v_event :=
    pg_temp.receive_payment_outcome(
      'evt-p2e-a17-failed',
      'FAILED',
      'DECLINED',
      'f2e31000-0000-0000-0000-000000000002',
      'b'
    );

  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  v_request :=
    jsonb_build_object(
      'providerWebhookEventId',v_event,
      'providerAdapterRequestId',v_adapter,
      'commandRequestSha256',repeat('c',64),
      'commandRequest',
        jsonb_build_object(
          'expectedShipmentVersion',v_lock
        ),
      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );

  v_dispatch :=
    (v_result ->> 'providerWebhookDispatchId')::uuid;


  perform pg_temp.p2e_assert(
    '01 FAILED webhook commits through A17',
    v_result ->> 'dispatchStatus' = 'COMMITTED'
    and v_result ->> 'targetCommand' =
      'command_release_failed_reservation'
  );


  perform pg_temp.p2e_assert(
    '02 FAILED releases reservation with provider failure reason',
    (
      select
        status = 'RELEASED'
        and release_reason = 'DECLINED'
      from haulvia.offer_reservations
      where id = v_reservation
    )
  );


  perform pg_temp.p2e_assert(
    '03 FAILED moves canonical payment intent and axis to FAILED',
    (
      select status = 'FAILED'
      from haulvia.payment_intents
      where id = v_intent
    )
    and (
      select
        state = 'FAILED'
        and secured_amount = 0
      from haulvia.shipment_customer_payment_axes
      where shipment_id = v_shipment
    )
  );


  perform pg_temp.p2e_assert(
    '04 FAILED retains failed provider transaction',
    (
      select count(*) = 1
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
        and provider_event_id =
          'evt-p2e-a17-failed'
        and transaction_type = 'AUTHORIZE'
        and status = 'FAILED'
        and amount = 125
        and currency = 'CAD'
    )
  );


  perform pg_temp.p2e_assert(
    '05 FAILED does not create assignment',
    not exists (
      select 1
      from haulvia.assignments
      where shipment_id = v_shipment
        and status = 'ACTIVE'
    )
  );


  v_tx_count :=
    (
      select count(*)
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );


  perform pg_temp.p2e_assert(
    '06 FAILED exact replay is dispatch-idempotent',
    (v_result ->> 'duplicateDispatch')::boolean
    and (
      v_result ->> 'providerWebhookDispatchId'
    )::uuid = v_dispatch
    and (
      select count(*) = v_tx_count
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    )
    and (
      select count(*) = 1
      from haulvia.provider_webhook_dispatches
      where provider_webhook_event_id = v_event
        and status = 'COMMITTED'
    )
  );

end;
$$;


-- ============================================================================
-- TIMED_OUT
-- ============================================================================

do $$
declare
  v_f jsonb;
  v_shipment uuid;
  v_reservation uuid;
  v_intent uuid;
  v_adapter uuid;
  v_event uuid;
  v_lock bigint;
  v_request jsonb;
  v_result jsonb;
begin

  v_f :=
    pg_temp.seed_p2e_payment_ready(
      'p2e-a17-timeout',
      125
    );

  v_shipment :=
    (v_f ->> 'shipmentId')::uuid;

  v_reservation :=
    (v_f ->> 'reservationId')::uuid;

  v_intent :=
    (v_f ->> 'paymentIntentId')::uuid;


  v_adapter :=
    pg_temp.prepare_payment_adapter(
      v_shipment,
      v_intent,
      'p2e-a17-timeout',
      'f2e32000-0000-0000-0000-000000000001',
      'd'
    );

  -- Deliberately supply DECLINED.
  -- Block 3B must override it to TIMEOUT for TIMED_OUT.
  v_event :=
    pg_temp.receive_payment_outcome(
      'evt-p2e-a17-timeout',
      'TIMED_OUT',
      'DECLINED',
      'f2e32000-0000-0000-0000-000000000002',
      'e'
    );


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  v_request :=
    jsonb_build_object(
      'providerWebhookEventId',v_event,
      'providerAdapterRequestId',v_adapter,
      'commandRequestSha256',repeat('f',64),
      'commandRequest',
        jsonb_build_object(
          'expectedShipmentVersion',v_lock
        ),
      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );


  perform pg_temp.p2e_assert(
    '07 TIMED_OUT webhook commits through A17',
    v_result ->> 'dispatchStatus' = 'COMMITTED'
    and v_result ->> 'targetCommand' =
      'command_release_failed_reservation'
  );


  perform pg_temp.p2e_assert(
    '08 TIMED_OUT forces canonical TIMEOUT release reason',
    (
      select
        status = 'RELEASED'
        and release_reason = 'TIMEOUT'
      from haulvia.offer_reservations
      where id = v_reservation
    )
  );


  perform pg_temp.p2e_assert(
    '09 TIMED_OUT sets payment intent timeout evidence',
    (
      select
        status = 'TIMED_OUT'
        and timed_out_at is not null
      from haulvia.payment_intents
      where id = v_intent
    )
  );


  perform pg_temp.p2e_assert(
    '10 TIMED_OUT leaves customer payment axis FAILED',
    (
      select
        state = 'FAILED'
        and secured_amount = 0
      from haulvia.shipment_customer_payment_axes
      where shipment_id = v_shipment
    )
  );


  perform pg_temp.p2e_assert(
    '11 TIMED_OUT retains failed provider transaction',
    (
      select count(*) = 1
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
        and provider_event_id =
          'evt-p2e-a17-timeout'
        and transaction_type = 'AUTHORIZE'
        and status = 'FAILED'
    )
  );


  perform pg_temp.p2e_assert(
    '12 TIMED_OUT does not queue late-success reversal',
    not exists (
      select 1
      from haulvia.workflow_jobs
      where shipment_id = v_shipment
        and job_code =
          'VOID_OR_REFUND_LATE_SUCCESS'
    )
  );

end;
$$;


-- ============================================================================
-- LATE_SUCCESS
-- ============================================================================

do $$
declare
  v_f jsonb;
  v_shipment uuid;
  v_reservation uuid;
  v_intent uuid;
  v_adapter uuid;
  v_event uuid;
  v_lock bigint;
  v_request jsonb;
  v_result jsonb;
  v_dispatch uuid;
  v_tx_count integer;
  v_job_count integer;
begin

  v_f :=
    pg_temp.seed_p2e_payment_ready(
      'p2e-a17-late',
      125
    );

  v_shipment :=
    (v_f ->> 'shipmentId')::uuid;

  v_reservation :=
    (v_f ->> 'reservationId')::uuid;

  v_intent :=
    (v_f ->> 'paymentIntentId')::uuid;


  v_adapter :=
    pg_temp.prepare_payment_adapter(
      v_shipment,
      v_intent,
      'p2e-a17-late',
      'f2e33000-0000-0000-0000-000000000001',
      '1'
    );

  -- Again deliberately supply DECLINED.
  -- LATE_SUCCESS must overwrite it and set lateSuccess=true.
  v_event :=
    pg_temp.receive_payment_outcome(
      'evt-p2e-a17-late',
      'LATE_SUCCESS',
      'DECLINED',
      'f2e33000-0000-0000-0000-000000000002',
      '2'
    );


  select lock_version
  into v_lock
  from haulvia.shipments
  where id = v_shipment;


  v_request :=
    jsonb_build_object(
      'providerWebhookEventId',v_event,
      'providerAdapterRequestId',v_adapter,
      'commandRequestSha256',repeat('3',64),
      'commandRequest',
        jsonb_build_object(
          'expectedShipmentVersion',v_lock
        ),
      'workerAuthority',
        'PAYMENT_PROVIDER_CALLBACK'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );

  v_dispatch :=
    (v_result ->> 'providerWebhookDispatchId')::uuid;


  perform pg_temp.p2e_assert(
    '13 LATE_SUCCESS commits through A17',
    v_result ->> 'dispatchStatus' = 'COMMITTED'
    and v_result ->> 'targetCommand' =
      'command_release_failed_reservation'
  );


  perform pg_temp.p2e_assert(
    '14 LATE_SUCCESS forces canonical release reason',
    (
      select
        status = 'RELEASED'
        and release_reason = 'LATE_SUCCESS'
      from haulvia.offer_reservations
      where id = v_reservation
    )
  );


  perform pg_temp.p2e_assert(
    '15 LATE_SUCCESS voids intent and releases payment axis',
    (
      select status = 'VOIDED'
      from haulvia.payment_intents
      where id = v_intent
    )
    and (
      select
        state = 'RELEASED'
        and secured_amount = 0
      from haulvia.shipment_customer_payment_axes
      where shipment_id = v_shipment
    )
  );


  perform pg_temp.p2e_assert(
    '16 LATE_SUCCESS retains successful provider transaction',
    (
      select count(*) = 1
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
        and provider_event_id =
          'evt-p2e-a17-late'
        and transaction_type = 'AUTHORIZE'
        and status = 'SUCCEEDED'
        and amount = 125
    )
  );


  perform pg_temp.p2e_assert(
    '17 LATE_SUCCESS queues exactly one void-or-refund reversal job',
    (
      select count(*) = 1
      from haulvia.workflow_jobs
      where shipment_id = v_shipment
        and job_code =
          'VOID_OR_REFUND_LATE_SUCCESS'
    )
  );


  perform pg_temp.p2e_assert(
    '18 LATE_SUCCESS does not create assignment',
    not exists (
      select 1
      from haulvia.assignments
      where shipment_id = v_shipment
        and status = 'ACTIVE'
    )
  );


  v_tx_count :=
    (
      select count(*)
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    );

  v_job_count :=
    (
      select count(*)
      from haulvia.workflow_jobs
      where shipment_id = v_shipment
        and job_code =
          'VOID_OR_REFUND_LATE_SUCCESS'
    );


  v_result :=
    haulvia_command.command_dispatch_provider_webhook(
      v_request
    );


  perform pg_temp.p2e_assert(
    '19 LATE_SUCCESS exact replay creates no second reversal or transaction',
    (v_result ->> 'duplicateDispatch')::boolean
    and (
      v_result ->> 'providerWebhookDispatchId'
    )::uuid = v_dispatch
    and (
      select count(*) = v_tx_count
      from haulvia.payment_transactions
      where payment_intent_id = v_intent
    )
    and (
      select count(*) = v_job_count
      from haulvia.workflow_jobs
      where shipment_id = v_shipment
        and job_code =
          'VOID_OR_REFUND_LATE_SUCCESS'
    )
  );

end;
$$;


-- ============================================================================
-- Cross-scenario structural assertions
-- ============================================================================

select pg_temp.p2e_assert(
  '20 all three outcomes commit through release-failed-reservation route',
  (
    select
      count(*) = 3
      and count(*) filter(
        where status = 'COMMITTED'
      ) = 3
      and bool_and(
        target_command =
          'command_release_failed_reservation'
      )
    from haulvia.provider_webhook_dispatches
  )
);


select pg_temp.p2e_assert(
  '21 all payment outcome webhooks retain payment callback authority',
  (
    select
      count(*) = 3
      and bool_and(signature_verified)
      and bool_and(
        verifier_authority =
          'PAYMENT_PROVIDER_CALLBACK'
      )
    from haulvia.provider_webhook_events
  )
);


select pg_temp.p2e_assert(
  '22 failure routes create no FAILED dispatch records',
  (
    select count(*) = 0
    from haulvia.provider_webhook_dispatches
    where status = 'FAILED'
  )
);


select pg_temp.p2e_assert(
  '23 no A17 outcome creates an active assignment',
  (
    select count(*) = 0
    from haulvia.assignments
    where status = 'ACTIVE'
  )
);


select pg_temp.p2e_assert(
  '24 P2E wrapper count remains 91 in transaction',
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
\echo ================ BLOCK 3B A17 OUTCOME RESULTS ================
\echo

select
  test_no,
  test_name,
  passed,
  detail
from p2e_a17_results
order by test_no;


\echo
\echo ================ BLOCK 3B A17 OUTCOME SUMMARY ================
\echo

select
  count(*) as total_tests,
  count(*) filter(where passed) as passed_tests,
  count(*) filter(where not passed) as failed_tests
from p2e_a17_results;


do $$
begin
  if exists (
    select 1
    from p2e_a17_results
    where not passed
  ) then
    raise exception
      'P2E Block 3B A17 outcome suite has failed assertions';
  end if;
end;
$$;


\echo
\echo A17 outcome suite passed. Rolling back.
\echo
'@


# ============================================================================
# Build temporary rollback-only SQL
# ============================================================================

$migrationText =
    Get-Content -LiteralPath $migration -Raw

$tempSql =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_block3b_a17_outcomes.sql"

$fullSql = @(
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
Write-Host "================ RUN BLOCK 3B A17 OUTCOME SUITE ================"

& psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -v ON_ERROR_STOP=1 `
    -f $tempSql

$testExitCode = $LASTEXITCODE


# ============================================================================
# Verify rollback
# ============================================================================

Write-Host ""
Write-Host "================ POST-TEST BASELINE ================"

$post = & psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X -A -t -v ON_ERROR_STOP=1 `
    -c $baselineSql

if ($LASTEXITCODE -ne 0) {
    throw "Post-test baseline query failed."
}

$post = (
    $post |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
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

git status --short


if ($testExitCode -ne 0) {
    Write-Host ""
    Write-Host "A17 outcome test SQL preserved for diagnosis:"
    Write-Host $tempSql

    throw "P2E Block 3B A17 outcome suite failed."
}


Remove-Item `
    -LiteralPath $tempSql `
    -Force


Write-Host ""
Write-Host "PASS: ordinary payment failure dispatched through canonical A17."
Write-Host "PASS: timeout forced TIMEOUT semantics and TIMED_OUT intent."
Write-Host "PASS: late success forced LATE_SUCCESS semantics."
Write-Host "PASS: late success queued exactly one void/refund reversal."
Write-Host "PASS: committed replay duplicated neither transaction nor reversal work."
Write-Host "PASS: no A17 path created an assignment."
Write-Host "PASS: rollback restored the 86-wrapper P2D baseline."
Write-Host ""
Write-Host "NEXT: Block 3B driver-payout success/failure dispatch."