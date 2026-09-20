$ErrorActionPreference = "Stop"

# ============================================================================
# Haulvia P2E legacy regression compatibility
#
# Adapts legacy Block A / Block D acceptance fixtures to later Phase 2
# invariants without changing production guards or the original test files.
#
# Compatibility only:
#   1. dual-control publication approval
#   2. BLOCK_D_ADMIN -> HAULVIA organization-kind scope
#   3. pre-P2D stop_evidence -> structured-only evidence
# ============================================================================


$repoRoot =
    Split-Path `
        -Parent `
        $PSScriptRoot

Set-Location $repoRoot


$blockA =
    ".\tests\haulvia_block_a_acceptance_v1.sql"

$blockD =
    ".\tests\haulvia_block_d_acceptance_v1.sql"


if (-not $env:HAULVIA_P2E_TEST_DATABASE_URL) {
    throw "HAULVIA_P2E_TEST_DATABASE_URL is not set."
}


foreach ($path in @(
    $blockA,
    $blockD
)) {

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required legacy regression file not found: $path"
    }

}


$blockAHashBefore =
    (
        Get-FileHash `
            -LiteralPath $blockA `
            -Algorithm SHA256
    ).Hash

$blockDHashBefore =
    (
        Get-FileHash `
            -LiteralPath $blockD `
            -Algorithm SHA256
    ).Hash


# ============================================================================
# Clean P2D baseline
# ============================================================================

$baselineSql = @"
select
  count(distinct p.proname),
  count(*) filter (
    where has_function_privilege(
      'service_role',
      p.oid,
      'EXECUTE'
    )
  ),
  to_regclass(
    'haulvia.provider_adapter_requests'
  ) is null,
  to_regclass(
    'haulvia.provider_webhook_dispatches'
  ) is null
from pg_proc p
join pg_namespace n
  on n.oid = p.pronamespace
where n.nspname = 'haulvia_command'
  and p.proname like
    'command\_%'
    escape '\';
"@


function Get-P2DBaseline {

    $result =
        & psql `
            "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
            -X `
            -A `
            -t `
            -v ON_ERROR_STOP=1 `
            -c $baselineSql

    if ($LASTEXITCODE -ne 0) {
        throw "P2D baseline query failed."
    }

    return (
        $result |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            } |
            Select-Object -Last 1
    ).Trim()
}


function Normalize-Lf {

    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    return $Text.Replace(
        "`r`n",
        "`n"
    ).Replace(
        "`r",
        "`n"
    )
}


function Replace-Exact {

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

    $oldNormalized =
        Normalize-Lf $Old

    $newNormalized =
        Normalize-Lf $New

    $count =
        (
            [regex]::Matches(
                $Text,
                [regex]::Escape($oldNormalized)
            )
        ).Count

    Write-Host "$Label targets: $count"

    if ($count -ne 1) {
        throw "$Label expected exactly one target, found $count."
    }

    return $Text.Replace(
        $oldNormalized,
        $newNormalized
    )
}


Write-Host ""
Write-Host "================ LEGACY REGRESSION PRECHECK ================"
Write-Host ""

$initialBaseline =
    Get-P2DBaseline

Write-Host "Baseline: $initialBaseline"

if ($initialBaseline -ne "86|86|t|t") {
    throw "Legacy regression helper requires clean 86|86|t|t P2D baseline."
}


# ============================================================================
# Transaction-only publication authority
# ============================================================================

$approverOrg =
    "f2e00000-0000-0000-0000-000000000001"

$approverProfile =
    "f2e00000-0000-0000-0000-000000000002"

$approverMembership =
    "f2e00000-0000-0000-0000-000000000003"

$approverReauth =
    "f2e00000-0000-0000-0000-000000000004"


$bridge = @"
-- ============================================================================
-- P2E-LEGACY-REGRESSION-PUBLICATION-BRIDGE-BEGIN
--
-- Transaction-only compatibility authority for acceptance fixtures written
-- before Phase 2A dual-control publication hardening.
-- Production publication enforcement remains enabled.
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
  'p2e-legacy-regression-approver',
  'HAULVIA',
  'P2E Legacy Regression Publication Authority',
  'P2E Legacy Regression Publication Authority'
);


insert into haulvia.profiles (
  id,
  display_name
)
values (
  '$approverProfile',
  'P2E Legacy Regression Publication Approver'
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


do `$`$
begin

  if not exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id =
        '$approverMembership'::uuid
      and r.role_key =
        'PLATFORM_ADMIN'
  ) then

    raise exception
      'P2E legacy regression PLATFORM_ADMIN role was not assigned';

  end if;


  if not haulvia.has_permission(
    '$approverProfile'::uuid,
    '$approverOrg'::uuid,
    'POLICY_PUBLISH'
  ) then

    raise exception
      'P2E legacy regression approver lacks POLICY_PUBLISH';

  end if;


  if not haulvia.has_permission(
    '$approverProfile'::uuid,
    '$approverOrg'::uuid,
    'PRICING_MANAGE'
  ) then

    raise exception
      'P2E legacy regression approver lacks PRICING_MANAGE';

  end if;

end;
`$`$;


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

-- ============================================================================
-- P2E-LEGACY-REGRESSION-PUBLICATION-BRIDGE-END
-- ============================================================================

"@


# ============================================================================
# Build compatible Block A
# ============================================================================

Write-Host ""
Write-Host "================ BUILD COMPATIBLE BLOCK A ================"
Write-Host ""


$blockAText =
    Normalize-Lf (
        Get-Content `
            -LiteralPath $blockA `
            -Raw
    )


$blockAAnchor =
    "-- Shared authority, policy, pricing, payment, and provider fixtures."


$anchorCount =
    (
        [regex]::Matches(
            $blockAText,
            [regex]::Escape($blockAAnchor)
        )
    ).Count


if ($anchorCount -ne 1) {
    throw "Expected exactly one Block A publication bridge anchor."
}


$blockAText =
    $blockAText.Replace(
        $blockAAnchor,
        (Normalize-Lf $bridge) +
            "`n" +
            $blockAAnchor
    )


$old = @"
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
"@


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
    'P2E rollback fixture approval for Block A policy'
  );
"@


$blockAText =
    Replace-Exact `
        -Text $blockAText `
        -Old $old `
        -New $new `
        -Label "Block A policy"


$old = @"
  insert into pricing_rule_versions (
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values
    (v_guard_version, v_guard_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('floorAmount', 50, 'ceilingAmount', 200, 'absoluteCapAmount', 300),
      repeat('2', 64), v_customer, v_customer, clock_timestamp()),
    (v_fixed_version, v_fixed_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('fixedAmount', 150), repeat('3', 64), v_customer, v_customer, clock_timestamp());
"@


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
      'P2E rollback fixture approval for Block A guardrail'),
    (v_fixed_version, v_fixed_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
      jsonb_build_object('fixedAmount', 150), repeat('3', 64),
      v_customer, '$approverProfile'::uuid,
      clock_timestamp(), '$approverReauth'::uuid,
      'P2E rollback fixture approval for Block A fixed pricing');
"@


$blockAText =
    Replace-Exact `
        -Text $blockAText `
        -Old $old `
        -New $new `
        -Label "Block A pricing"


$old = @"
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    v_partner_profile, clock_timestamp(), v_reauth
"@


$new = @"
    'Approved for Block A acceptance', repeat('4', 64), v_partner_profile,
    '$approverProfile'::uuid, clock_timestamp(), '$approverReauth'::uuid
"@


$blockAText =
    Replace-Exact `
        -Text $blockAText `
        -Old $old `
        -New $new `
        -Label "Block A partner rate card"


$tempBlockA =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_block_a_legacy_compatible.sql"


[System.IO.File]::WriteAllText(
    $tempBlockA,
    $blockAText,
    [System.Text.UTF8Encoding]::new($false)
)


# ============================================================================
# Build compatible Block D
# ============================================================================

Write-Host ""
Write-Host "================ BUILD COMPATIBLE BLOCK D ================"
Write-Host ""


$blockDText =
    Normalize-Lf (
        Get-Content `
            -LiteralPath $blockD `
            -Raw
    )


$blockDAnchor =
    "-- Shared customer, provider, policy, pricing, and sensitive-admin fixtures."


$anchorCount =
    (
        [regex]::Matches(
            $blockDText,
            [regex]::Escape($blockDAnchor)
        )
    ).Count


if ($anchorCount -ne 1) {
    throw "Expected exactly one Block D publication bridge anchor."
}


$blockDText =
    $blockDText.Replace(
        $blockDAnchor,
        (Normalize-Lf $bridge) +
            "`n" +
            $blockDAnchor
    )


$old = @"
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
"@


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
    'P2E rollback fixture approval for Block D policy'
  );
"@


$blockDText =
    Replace-Exact `
        -Text $blockDText `
        -Old $old `
        -New $new `
        -Label "Block D policy"


$old = @"
  insert into pricing_rule_versions(
    id, pricing_rule_set_id, version_no, publication_status, effective_from,
    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at
  ) values (
    v_pricing_version, v_pricing_set, 1, 'APPROVED', clock_timestamp() - interval '1 day',
    jsonb_build_object('floorAmount', 0, 'ceilingAmount', 200),
    repeat('e', 64), v_admin, v_admin, clock_timestamp()
  );
"@


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
    'P2E rollback fixture approval for Block D pricing'
  );
"@


$blockDText =
    Replace-Exact `
        -Text $blockDText `
        -Old $old `
        -New $new `
        -Label "Block D pricing"


# ---------------------------------------------------------------------------
# Block D role organization-kind compatibility
# ---------------------------------------------------------------------------

$old = @"
  insert into roles(id, role_key, name, description)
  values (v_role, 'BLOCK_D_ADMIN', 'Block D administrator', 'Acceptance-only sensitive role');
  insert into role_permissions(role_id, permission_id)
"@


$new = @"
  insert into roles(id, role_key, name, description)
  values (v_role, 'BLOCK_D_ADMIN', 'Block D administrator', 'Acceptance-only sensitive role');

  -- P2E-FIXTURE-BLOCK-D-ROLE-SCOPE
  -- Transaction-only compatibility mapping for the pre-P2A fixture role.
  -- Production organization-kind enforcement remains enabled.
  insert into role_organization_kinds(
    role_id,
    organization_kind
  )
  values (
    v_role,
    'HAULVIA'
  );

  insert into role_permissions(role_id, permission_id)
"@


$blockDText =
    Replace-Exact `
        -Text $blockDText `
        -Old $old `
        -New $new `
        -Label "Block D role scope"


# ---------------------------------------------------------------------------
# Block D Phase 2D evidence compatibility
# ---------------------------------------------------------------------------

$old = @"
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
"@


$new = @"
  -- P2E-FIXTURE-BLOCK-D-EVIDENCE-P2D
  -- Phase 2D permits structured-only evidence without a private storage object.
  -- Production private-storage attachment rules remain unchanged.
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
"@


$blockDText =
    Replace-Exact `
        -Text $blockDText `
        -Old $old `
        -New $new `
        -Label "Block D Phase 2D evidence"


$tempBlockD =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_block_d_legacy_compatible.sql"


[System.IO.File]::WriteAllText(
    $tempBlockD,
    $blockDText,
    [System.Text.UTF8Encoding]::new($false)
)


# ============================================================================
# Run compatible Block A
# ============================================================================

Write-Host ""
Write-Host "================ COMPATIBLE BLOCK A REGRESSION ================"
Write-Host ""


& psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -v ON_ERROR_STOP=1 `
    -f $tempBlockA


$blockAExit =
    $LASTEXITCODE


if ($blockAExit -ne 0) {

    Write-Host ""
    Write-Host "Block A temporary SQL preserved:"
    Write-Host $tempBlockA

    throw "Compatible Block A regression failed."
}


$afterA =
    Get-P2DBaseline


Write-Host ""
Write-Host "Block A post-test baseline: $afterA"


if ($afterA -ne "86|86|t|t") {
    throw "Compatible Block A did not restore 86|86|t|t."
}


Write-Host "PASS: Block A regression passed."


# ============================================================================
# Run compatible Block D
# ============================================================================

Write-Host ""
Write-Host "================ COMPATIBLE BLOCK D REGRESSION ================"
Write-Host ""


& psql `
    "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
    -X `
    -v ON_ERROR_STOP=1 `
    -f $tempBlockD


$blockDExit =
    $LASTEXITCODE


if ($blockDExit -ne 0) {

    Write-Host ""
    Write-Host "Block D temporary SQL preserved:"
    Write-Host $tempBlockD

    throw "Compatible Block D regression failed."
}


$afterD =
    Get-P2DBaseline


Write-Host ""
Write-Host "Block D post-test baseline: $afterD"


if ($afterD -ne "86|86|t|t") {
    throw "Compatible Block D did not restore 86|86|t|t."
}


Write-Host "PASS: Block D regression passed."


# ============================================================================
# Original source integrity
# ============================================================================

$blockAHashAfter =
    (
        Get-FileHash `
            -LiteralPath $blockA `
            -Algorithm SHA256
    ).Hash

$blockDHashAfter =
    (
        Get-FileHash `
            -LiteralPath $blockD `
            -Algorithm SHA256
    ).Hash


if ($blockAHashAfter -ne $blockAHashBefore) {
    throw "Original Block A acceptance file changed."
}

if ($blockDHashAfter -ne $blockDHashBefore) {
    throw "Original Block D acceptance file changed."
}


Remove-Item `
    -LiteralPath $tempBlockA `
    -Force

Remove-Item `
    -LiteralPath $tempBlockD `
    -Force


$finalBaseline =
    Get-P2DBaseline


if ($finalBaseline -ne "86|86|t|t") {
    throw "Legacy compatibility regression did not end at 86|86|t|t."
}


Write-Host ""
Write-Host "============================================================"
Write-Host "P2E LEGACY REGRESSION COMPATIBILITY PASSED"
Write-Host "============================================================"
Write-Host ""
Write-Host "PASS: Block A dual-control fixture compatibility passed."
Write-Host "PASS: Block D dual-control fixture compatibility passed."
Write-Host "PASS: BLOCK_D_ADMIN HAULVIA role-scope compatibility passed."
Write-Host "PASS: Block D Phase 2D structured-evidence compatibility passed."
Write-Host "PASS: production guards remained enabled."
Write-Host "PASS: original Block A/D acceptance files remained unchanged."
Write-Host "PASS: final baseline is 86|86|t|t."
Write-Host ""