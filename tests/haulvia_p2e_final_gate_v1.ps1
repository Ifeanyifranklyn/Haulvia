$ErrorActionPreference = "Stop"

# ============================================================================
# Haulvia Phase 2E final deterministic acceptance gate
#
# Runs:
#   - clean P2D baseline
#   - command-adapter 13/13 regression
#   - Block A regression
#   - Block D regression
#   - payment-success P2E behavioral regression
#   - payment failure / timeout / late-success regression
#   - payout success / failure regression
#   - unsupported / dispatch-edge regression
#   - migration + complete P2E-01..P2E-48 acceptance in one transaction
#   - final ROLLBACK
#   - clean P2D 86|86|t|t verification
#
# Hosted database mutation is prohibited.
# ============================================================================


# ============================================================================
# Paths
# ============================================================================

$repoRoot =
    Split-Path `
        -Parent `
        $PSScriptRoot

Set-Location $repoRoot


$contract =
    ".\docs\Haulvia_P2E_Provider_Adapters_and_Webhooks_Contract_v1.md"

$migration =
    ".\supabase\migrations\20260920024711_haulvia_p2e_provider_adapters_and_webhooks_v1.sql"

$manifestPath =
    ".\supabase\functions\_shared\haulvia-command-manifest.ts"

$adapterPath =
    ".\supabase\functions\_shared\haulvia-command-adapter.ts"

$adapterTestPath =
    ".\tests\haulvia_p2e_command_adapter_acceptance_v1.ts"

$acceptance =
    ".\tests\haulvia_p2e_acceptance_v1.sql"

$blockATest =
    ".\tests\haulvia_block_a_acceptance_v1.sql"

$blockDTest =
    ".\tests\haulvia_block_d_acceptance_v1.sql"

$legacyCompatibilityRunner =
    ".\tests\haulvia_p2e_legacy_regression_compatibility_v1.ps1"


$paymentSuccessRunner =
    ".\tests\haulvia_p2e_payment_success_regression_v1.ps1"

$a17Runner =
    ".\tests\haulvia_p2e_payment_failure_timeout_late_success_regression_v1.ps1"

$payoutRunner =
    ".\tests\haulvia_p2e_payout_regression_v1.ps1"

$edgeRunner =
    ".\tests\haulvia_p2e_dispatch_edge_regression_v1.ps1"


# ============================================================================
# Frozen hashes
# ============================================================================

$expectedContractHash =
    "60C0408922C0474B3338C5E1274B6C74B570F57B18F01ACE62E7E718EBB7140A"

$expectedAcceptanceHash =
    "741BC060847A9DA96A8F6ED9BE9D86A75DEC6B9DD5AB2CB8BDD65C07A4CCB493"

$expectedPaymentSuccessHash =
    "A2B7781A2DEB2A607DDF029958006459C2486C0C5BD497E8A90C8AA23198A355"

$expectedA17Hash =
    "4BE7D8F2ACEBDF86EA6B43983D8E1ACB2B321BF4478B23B7E78764D2DD17A74E"

$expectedPayoutHash =
    "9B62272BC024E8BA5B86A8350FF5B76A173332C75EF76E86FF30240F073E47D3"

$expectedEdgeHash =
    "E08A3F207CFE16C3F4FCF041A0C87D824B64AAB79EA4B62853E450EFBD4766A9"

$expectedLegacyCompatibilityHash =
    "B35E72DC26091E2ECF88B7E2A843E866E5FD7C1281D2EE2F064DC9C0EA07B0C6"


# ============================================================================
# Preconditions
# ============================================================================

Write-Host ""
Write-Host "================ P2E FINAL GATE PRECHECK ================"
Write-Host ""


if (-not $env:HAULVIA_P2E_TEST_DATABASE_URL) {
    throw "HAULVIA_P2E_TEST_DATABASE_URL is not set."
}


# Fail closed if somebody accidentally points this gate at hosted infrastructure.
#
# PostgreSQL connection strings may be URI-style:
#   postgresql://user:password@127.0.0.1:54322/postgres
#
# or libpq-style:
#   host=127.0.0.1 port=54322 dbname=postgres ...
#
# Do not rely on System.Uri.Host because Windows PowerShell/.NET may not
# consistently parse PostgreSQL URI schemes.

$connectionString =
    $env:HAULVIA_P2E_TEST_DATABASE_URL.Trim()

$databaseHost =
    $null


# ---------------------------------------------------------------------------
# URI-style PostgreSQL URL
# ---------------------------------------------------------------------------

$uriMatch =
    [regex]::Match(
        $connectionString,
        '^(?i:postgres(?:ql)?)://(?:.*@)?(?<host>\[[^\]]+\]|[^:/?#]+)(?::\d+)?(?:/|$)'
    )


if ($uriMatch.Success) {

    $databaseHost =
        $uriMatch.Groups["host"].Value

    if (
        $databaseHost.StartsWith("[") `
        -and $databaseHost.EndsWith("]")
    ) {

        $databaseHost =
            $databaseHost.Substring(
                1,
                $databaseHost.Length - 2
            )

    }

}


# ---------------------------------------------------------------------------
# libpq-style connection string
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($databaseHost)) {

    $libpqMatch =
        [regex]::Match(
            $connectionString,
            '(?i)(?:^|\s)host\s*=\s*(?:"(?<double>[^"]+)"|''(?<single>[^'']+)''|(?<plain>[^\s]+))'
        )


    if ($libpqMatch.Success) {

        if ($libpqMatch.Groups["double"].Success) {

            $databaseHost =
                $libpqMatch.Groups["double"].Value

        }
        elseif ($libpqMatch.Groups["single"].Success) {

            $databaseHost =
                $libpqMatch.Groups["single"].Value

        }
        else {

            $databaseHost =
                $libpqMatch.Groups["plain"].Value

        }

    }

}


if ([string]::IsNullOrWhiteSpace($databaseHost)) {

    throw (
        "Unable to determine the PostgreSQL host from " +
        "HAULVIA_P2E_TEST_DATABASE_URL. Final gate fails closed."
    )

}


$databaseHost =
    $databaseHost.Trim().ToLowerInvariant()


# Reject multi-host connection strings.
if (
    $databaseHost.Contains(",") `
    -or $databaseHost.Contains(" ")
) {

    throw (
        "P2E final gate refuses multi-host database configuration: {0}" -f
            $databaseHost
    )

}


$allowedLocalHosts =
    @(
        "localhost",
        "127.0.0.1",
        "::1"
    )


if ($allowedLocalHosts -notcontains $databaseHost) {

    throw (
        "P2E final gate refuses non-local database host: {0}" -f
            $databaseHost
    )

}


Write-Host "PASS: test database is local: $databaseHost"


foreach ($commandName in @(
    "psql",
    "node",
    "npx.cmd",
    "powershell.exe"
)) {

    if (
        -not (
            Get-Command `
                $commandName `
                -ErrorAction SilentlyContinue
        )
    ) {
        throw "Required executable not found: $commandName"
    }

}


$requiredFiles =
    @(
        $contract,
        $migration,
        $manifestPath,
        $adapterPath,
        $adapterTestPath,
        $acceptance,
        $blockATest,
        $blockDTest,
        $legacyCompatibilityRunner,
        $paymentSuccessRunner,
        $a17Runner,
        $payoutRunner,
        $edgeRunner
    )


foreach ($path in $requiredFiles) {

    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required final-gate artifact missing: $path"
    }

}


Write-Host "PASS: all required final-gate artifacts exist."


# ============================================================================
# Frozen artifact integrity
# ============================================================================

function Assert-FileHash {

    param(
        [string]$Path,
        [string]$ExpectedHash
    )

    $actualHash =
        (
            Get-FileHash `
                -LiteralPath $Path `
                -Algorithm SHA256
        ).Hash

    if ($actualHash -ne $ExpectedHash) {

        throw (
            "Frozen artifact hash mismatch: {0}`nExpected: {1}`nActual:   {2}" -f
                $Path,
                $ExpectedHash,
                $actualHash
        )

    }

    Write-Host "PASS: hash frozen -> $Path"
}


Assert-FileHash `
    $contract `
    $expectedContractHash

Assert-FileHash `
    $acceptance `
    $expectedAcceptanceHash

Assert-FileHash `
    $paymentSuccessRunner `
    $expectedPaymentSuccessHash

Assert-FileHash `
    $a17Runner `
    $expectedA17Hash

Assert-FileHash `
    $payoutRunner `
    $expectedPayoutHash

Assert-FileHash `
    $edgeRunner `
    $expectedEdgeHash

Assert-FileHash `
    $legacyCompatibilityRunner `
    $expectedLegacyCompatibilityHash


$migrationCommitCount =
    @(
        Select-String `
            -Path $migration `
            -Pattern '^\s*COMMIT\s*;\s*$' `
            -CaseSensitive:$false
    ).Count


if ($migrationCommitCount -ne 1) {
    throw "P2E migration must contain exactly one deployment COMMIT."
}


$acceptanceCommitCount =
    @(
        Select-String `
            -Path $acceptance `
            -Pattern '^\s*COMMIT\s*;\s*$' `
            -CaseSensitive:$false
    ).Count


$acceptanceRollbackCount =
    @(
        Select-String `
            -Path $acceptance `
            -Pattern '^\s*ROLLBACK\s*;\s*$' `
            -CaseSensitive:$false
    ).Count


if (
    $acceptanceCommitCount -ne 0 `
    -or $acceptanceRollbackCount -ne 0
) {
    throw "Complete P2E acceptance file must own neither COMMIT nor ROLLBACK."
}


Write-Host "PASS: production migration owns one COMMIT; final gate strips it from the rollback-only test copy."


# ============================================================================
# Exact clean P2D baseline query
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


    $normalized =
        (
            $result |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -Last 1
        ).Trim()


    return $normalized
}


Write-Host ""
Write-Host "================ PRE-GATE P2D BASELINE ================"
Write-Host ""

$preBaseline =
    Get-P2DBaseline

Write-Host "Baseline result: $preBaseline"

if ($preBaseline -ne "86|86|t|t") {
    throw "Database is not at the clean P2D baseline."
}

Write-Host "PASS: database begins at 86|86|t|t."


# ============================================================================
# Existing Block A / Block D test transaction safety
# ============================================================================

foreach ($priorTest in @(
    $blockATest,
    $blockDTest
)) {

    $commitCount =
        @(
            Select-String `
                -Path $priorTest `
                -Pattern '^\s*COMMIT\s*;\s*$' `
                -CaseSensitive:$false
        ).Count

    $rollbackCount =
        @(
            Select-String `
                -Path $priorTest `
                -Pattern '^\s*ROLLBACK\s*;\s*$' `
                -CaseSensitive:$false
        ).Count


    if ($commitCount -ne 0) {
        throw "Prior regression unexpectedly contains COMMIT: $priorTest"
    }

    if ($rollbackCount -lt 1) {
        throw "Prior regression does not contain rollback protection: $priorTest"
    }

}


Write-Host "PASS: Block A and Block D regressions are rollback protected."


# ============================================================================
# Adapter regression ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Â ÃƒÂ¢Ã¢â€šÂ¬Ã¢â€žÂ¢ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã¢â‚¬Â¦Ãƒâ€šÃ‚Â¡ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™Ãƒâ€ Ã¢â‚¬â„¢ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã†â€™Ãƒâ€šÃ‚Â¢ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬Ãƒâ€¦Ã‚Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â¬ÃƒÆ’Ã†â€™ÃƒÂ¢Ã¢â€šÂ¬Ã…Â¡ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â frozen 13/13 execution pattern
# ============================================================================

Write-Host ""
Write-Host "================ ADAPTER REGRESSION ================"
Write-Host ""

$buildDir =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_adapter_final_gate"


if (Test-Path -LiteralPath $buildDir) {

    Remove-Item `
        -LiteralPath $buildDir `
        -Recurse `
        -Force

}


New-Item `
    -ItemType Directory `
    -Path $buildDir `
    -Force |
Out-Null


& npx.cmd tsc `
    --strict `
    --skipLibCheck `
    --target ES2022 `
    --module CommonJS `
    --moduleResolution Node `
    --rootDir . `
    --outDir $buildDir `
    $manifestPath `
    $adapterPath `
    $adapterTestPath


if ($LASTEXITCODE -ne 0) {
    throw "Adapter regression TypeScript compilation failed."
}


$compiledTest =
    Join-Path `
        $buildDir `
        "tests\haulvia_p2e_command_adapter_acceptance_v1.js"


if (-not (Test-Path -LiteralPath $compiledTest)) {
    throw "Compiled adapter regression test was not created."
}


& node $compiledTest

$adapterExit =
    $LASTEXITCODE


if ($adapterExit -ne 0) {

    Write-Host ""
    Write-Host "Adapter build preserved for diagnosis:"
    Write-Host $buildDir

    throw "P2E command-adapter regression failed."

}


Remove-Item `
    -LiteralPath $buildDir `
    -Recurse `
    -Force


Write-Host "PASS: command-adapter regression passed."


# ============================================================================
# Helpers for prior deterministic SQL regressions
# ============================================================================

function Invoke-PsqlRegression {

    param(
        [string]$Label,
        [string]$Path
    )

    Write-Host ""
    Write-Host "================ $Label ================"
    Write-Host ""

    & psql `
        "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
        -X `
        -v ON_ERROR_STOP=1 `
        -f $Path

    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed."
    }

    Write-Host "PASS: $Label passed."
}


function Invoke-PowerShellRegression {

    param(
        [string]$Label,
        [string]$Path
    )

    Write-Host ""
    Write-Host "================ $Label ================"
    Write-Host ""

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $Path

    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed."
    }

    Write-Host "PASS: $Label passed."
}


# ============================================================================
# Prior financial/state-machine regressions
#
# The original Block A / Block D acceptance files predate later Phase 2A/2D
# fixture constraints. The compatibility runner adapts temporary copies only.
# ============================================================================

Invoke-PowerShellRegression `
    "BLOCK A / BLOCK D LEGACY COMPATIBILITY REGRESSION" `
    $legacyCompatibilityRunner


if ((Get-P2DBaseline) -ne "86|86|t|t") {
    throw "Legacy Block A/D regressions did not restore clean P2D baseline."
}


# ============================================================================
# P2E behavioral regressions
# ============================================================================

Invoke-PowerShellRegression `
    "P2E PAYMENT SUCCESS / A16" `
    $paymentSuccessRunner


Invoke-PowerShellRegression `
    "P2E FAILURE / TIMEOUT / LATE SUCCESS / A17" `
    $a17Runner


Invoke-PowerShellRegression `
    "P2E PAYOUT SUCCESS / FAILURE" `
    $payoutRunner


Invoke-PowerShellRegression `
    "P2E DISPATCH EDGE HARDENING" `
    $edgeRunner


$afterBehaviorBaseline =
    Get-P2DBaseline


Write-Host ""
Write-Host "Behavior-suite baseline: $afterBehaviorBaseline"

if ($afterBehaviorBaseline -ne "86|86|t|t") {
    throw "Behavioral regression layer did not restore clean P2D baseline."
}


Write-Host "PASS: all behavioral suites returned to 86|86|t|t."


# ============================================================================
# Build final rollback-only P2E transaction
# ============================================================================

Write-Host ""
Write-Host "================ BUILD COMPLETE 48-CHECK TRANSACTION ================"
Write-Host ""


$migrationText =
    Get-Content `
        -LiteralPath $migration `
        -Raw


$acceptanceText =
    Get-Content `
        -LiteralPath $acceptance `
        -Raw


$evidenceSql = @"
select set_config(
  'haulvia.p2e.adapter_manifest_ok',
  'true',
  true
);

select set_config(
  'haulvia.p2e.adapter_acceptance_ok',
  'true',
  true
);

select set_config(
  'haulvia.p2e.adapter_static_routing_ok',
  'true',
  true
);

select set_config(
  'haulvia.p2e.evidence.adapter_regression',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.payment_success',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.payment_failure_timeout',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.late_success',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.payout',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.dispatch_edge',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.block_a_regression',
  'passed',
  true
);

select set_config(
  'haulvia.p2e.evidence.block_d_regression',
  'passed',
  true
);
"@


$finalCountSql = @"
select
  'P2E_FINAL_COUNTS|' ||
  count(*)::text ||
  '|' ||
  count(*) filter (
    where passed
  )::text ||
  '|' ||
  count(*) filter (
    where not passed
  )::text
from p2e_test_results;
"@


$tempSql =
    Join-Path `
        $env:TEMP `
        "haulvia_p2e_final_gate_v1.sql"


$combined =
    ([regex]::Replace($migrationText.TrimEnd(), '(?im)^\s*COMMIT\s*;\s*$', '')).TrimEnd() +
    "`r`n`r`n" +
    $evidenceSql.Trim() +
    "`r`n`r`n" +
    $acceptanceText.Trim() +
    "`r`n`r`n" +
    $finalCountSql.Trim() +
    "`r`n`r`nROLLBACK;`r`n"


$utf8NoBom =
    New-Object System.Text.UTF8Encoding($false)


[System.IO.File]::WriteAllText(
    $tempSql,
    $combined,
    $utf8NoBom
)


Write-Host "Final transaction SQL:"
Write-Host $tempSql


# ============================================================================
# Execute complete P2E final gate
# ============================================================================

Write-Host ""
Write-Host "================ RUN COMPLETE P2E FINAL GATE ================"
Write-Host ""


$finalOutput =
    @(
        & psql `
            "$env:HAULVIA_P2E_TEST_DATABASE_URL" `
            -X `
            -v ON_ERROR_STOP=1 `
            -f $tempSql `
            2>&1
    )


$finalExitCode =
    $LASTEXITCODE


$finalOutput |
    ForEach-Object {
        Write-Host $_
    }


if ($finalExitCode -ne 0) {

    Write-Host ""
    Write-Host "Final-gate SQL preserved for diagnosis:"
    Write-Host $tempSql

    throw "Complete P2E final gate failed."

}


$joinedOutput =
    (
        $finalOutput |
            ForEach-Object {
                $_.ToString()
            }
    ) -join "`n"


if (
    $joinedOutput -notmatch
        'P2E_FINAL_COUNTS\|48\|48\|0'
) {

    Write-Host ""
    Write-Host "Final-gate SQL preserved for diagnosis:"
    Write-Host $tempSql

    throw "P2E final gate did not report 48|48|0."
}


Remove-Item `
    -LiteralPath $tempSql `
    -Force


Write-Host ""
Write-Host "PASS: complete P2E acceptance reported 48|48|0."


# ============================================================================
# Mandatory post-rollback P2D baseline
# ============================================================================

Write-Host ""
Write-Host "================ POST-ROLLBACK P2D BASELINE ================"
Write-Host ""


$postBaseline =
    Get-P2DBaseline


Write-Host "Post-rollback result: $postBaseline"


if ($postBaseline -ne "86|86|t|t") {
    throw "P2E final gate failed to restore the clean P2D baseline."
}


Write-Host "PASS: rollback restored 86|86|t|t."


# ============================================================================
# Final artifact / repository evidence
# ============================================================================

Write-Host ""
Write-Host "================ FINAL ARTIFACT EVIDENCE ================"
Write-Host ""

Write-Host "Contract SHA-256:"
Write-Host (
    Get-FileHash `
        -LiteralPath $contract `
        -Algorithm SHA256
).Hash

Write-Host ""

Write-Host "Acceptance SHA-256:"
Write-Host (
    Get-FileHash `
        -LiteralPath $acceptance `
        -Algorithm SHA256
).Hash

Write-Host ""

Write-Host "Migration COMMIT count: $migrationCommitCount"


Write-Host ""
Write-Host "================ GIT STATUS ================"
Write-Host ""

git status --short


Write-Host ""
Write-Host "============================================================"
Write-Host "HAULVIA PHASE 2E FINAL GATE PASSED"
Write-Host "============================================================"
Write-Host ""
Write-Host "PASS: local database boundary enforced."
Write-Host "PASS: P2D pre-gate baseline was 86|86|t|t."
Write-Host "PASS: command-adapter regression passed."
Write-Host "PASS: Block A regression passed."
Write-Host "PASS: Block D regression passed."
Write-Host "PASS: payment-success / A16 regression passed."
Write-Host "PASS: failure / timeout / late-success / A17 regression passed."
Write-Host "PASS: payout success/failure regression passed."
Write-Host "PASS: unsupported/dispatch-edge regression passed."
Write-Host "PASS: P2E-01 through P2E-48 passed."
Write-Host "PASS: final acceptance reported 48|48|0."
Write-Host "PASS: final rollback restored 86|86|t|t."
Write-Host "PASS: hosted Supabase was not mutated."
Write-Host ""