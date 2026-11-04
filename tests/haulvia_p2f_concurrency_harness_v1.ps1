param(
    [string]$SourceDatabase = "haulvia_p2e_test_20260919_205420",
    [string]$DatabaseHost = "localhost",
    [int]$DatabasePort = 5432,
    [string]$DatabaseUser = "postgres"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


$RepoRoot =
    (
        Resolve-Path (
            Join-Path $PSScriptRoot ".."
        )
    ).Path


$P2eMigration =
    Join-Path `
        $RepoRoot `
        "supabase\migrations\20260920024711_haulvia_p2e_provider_adapters_and_webhooks_v1.sql"

$P2fMigration =
    Join-Path `
        $RepoRoot `
        "supabase\migrations\20261003205557_haulvia_p2f_observability_and_concurrency_preparation_v1.sql"

$Contract =
    Join-Path `
        $RepoRoot `
        "docs\Haulvia_P2F_Observability_and_Concurrency_Contract_v1.md"

$Acceptance =
    Join-Path `
        $RepoRoot `
        "tests\haulvia_p2f_acceptance_v1.sql"


$ExpectedP2eMigrationHash =
    "7A9EBA429BB88346DA1FD24F890D8E0149BFB2FE10E22D416E96DD4B7C2BDAF6"

$ExpectedP2fMigrationHash =
    "7E54F82F26841252BD8EAA93935B6344F029CED564B942CE4E92B60D1FAE5A7E"

$ExpectedContractHash =
    "B09E4D8E9556854FB491BC908A111A46466BCE46DEB5A8C0E844A737118AB945"

$ExpectedAcceptanceHash =
    "A5EA8BCF5E03795C59DBF999027760B5C523412EB1C198410F9DD4C1AB414956"


$PsqlPath =
    (
        Get-Command `
            "psql" `
            -ErrorAction Stop
    ).Source

$CreateDbPath =
    (
        Get-Command `
            "createdb" `
            -ErrorAction Stop
    ).Source

$DropDbPath =
    (
        Get-Command `
            "dropdb" `
            -ErrorAction Stop
    ).Source


$TargetDatabase =
    "haulvia_p2f_concurrency_" +
    (Get-Date -Format "yyyyMMdd_HHmmss")


$TempRoot =
    Join-Path `
        $env:TEMP `
        (
            "haulvia-p2f-concurrency-" +
            [guid]::NewGuid().ToString("N")
        )


$GateKey =
    20909


$TargetCreated =
    $false

$RunPassed =
    $false

$PasswordWasSetByHarness =
    $false


function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Text
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        [System.Text.UTF8Encoding]::new($false)
    )
}


function Invoke-PsqlText {
    param(
        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$Sql,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $output =
        @(
            & $PsqlPath `
                -h $DatabaseHost `
                -p $DatabasePort `
                -U $DatabaseUser `
                -d $Database `
                -X `
                -q `
                -v ON_ERROR_STOP=1 `
                -A `
                -t `
                -c $Sql `
                2>&1
        )

    $exitCode =
        $LASTEXITCODE

    $text =
        (
            $output |
            ForEach-Object {
                "$_"
            }
        ) -join "`n"

    if ($exitCode -ne 0) {
        throw "$Label failed with exit code $exitCode.`n$text"
    }

    return $text.Trim()
}


function Invoke-PsqlScalar {
    param(
        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$Sql,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $text =
        Invoke-PsqlText `
            -Database $Database `
            -Sql $Sql `
            -Label $Label

    $lines =
        @(
            $text -split "`r?`n" |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
        )

    if ($lines.Count -eq 0) {
        return ""
    }

    return $lines[-1].Trim()
}


function Invoke-PsqlAllowFailure {
    param(
        [Parameter(Mandatory)]
        [string]$Database,

        [Parameter(Mandatory)]
        [string]$Sql
    )


    # P2F_EXPECTED_NATIVE_FAILURE_CAPTURE
    #
    # This helper is specifically for negative tests whose expected result is
    # a nonzero psql exit code. Windows PowerShell converts native stderr into
    # ErrorRecord objects; with the harness-wide ErrorActionPreference=Stop,
    # those expected errors would terminate the harness before we can inspect
    # the exit code and structured database error text.
    #
    # Scope the relaxation to this native call only, then restore the caller's
    # original error policy immediately.

    $previousErrorActionPreference =
        $ErrorActionPreference


    try {

        $ErrorActionPreference =
            "Continue"


        $output =
            @(
                & $PsqlPath `
                    -h $DatabaseHost `
                    -p $DatabasePort `
                    -U $DatabaseUser `
                    -d $Database `
                    -X `
                    -q `
                    -v ON_ERROR_STOP=1 `
                    -A `
                    -t `
                    -c $Sql `
                    2>&1
            )


        $exitCode =
            $LASTEXITCODE
    }
    finally {

        $ErrorActionPreference =
            $previousErrorActionPreference
    }


    $text =
        (
            $output |
            ForEach-Object {
                "$_"
            }
        ) -join "`n"


    return [pscustomobject]@{
        ExitCode =
            $exitCode

        Text =
            $text.Trim()
    }
}


function Start-PsqlScriptProcess {
    param(
        [Parameter(Mandatory)]
        [string]$SqlFile,

        [Parameter(Mandatory)]
        [string]$StdOutFile,

        [Parameter(Mandatory)]
        [string]$StdErrFile,

        [string]$ExitCodeFile = ""
    )


    if (
        [string]::IsNullOrWhiteSpace(
            $ExitCodeFile
        )
    ) {

        $arguments =
            @(
                "-h",
                $DatabaseHost,
                "-p",
                "$DatabasePort",
                "-U",
                $DatabaseUser,
                "-d",
                $TargetDatabase,
                "-X",
                "-v",
                "ON_ERROR_STOP=1",
                "-A",
                "-t",
                "-f",
                $SqlFile
            )


        return Start-Process `
            -FilePath $PsqlPath `
            -ArgumentList $arguments `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $StdOutFile `
            -RedirectStandardError $StdErrFile
    }


    $runnerFile =
        [System.IO.Path]::ChangeExtension(
            $SqlFile,
            ".runner.cmd"
        )


    $runnerText =
        @"
@echo off
"$PsqlPath" -h "$DatabaseHost" -p "$DatabasePort" -U "$DatabaseUser" -d "$TargetDatabase" -X -v ON_ERROR_STOP=1 -A -t -f "$SqlFile" > "$StdOutFile" 2> "$StdErrFile"
set "HAULVIA_PSQL_EXIT_CODE=%ERRORLEVEL%"
> "$ExitCodeFile" echo %HAULVIA_PSQL_EXIT_CODE%
exit /b %HAULVIA_PSQL_EXIT_CODE%
"@


    Write-Utf8NoBom `
        -Path $runnerFile `
        -Text (
            $runnerText.TrimEnd() +
            "`r`n"
        )


    return Start-Process `
        -FilePath $env:ComSpec `
        -ArgumentList @(
            "/d",
            "/c",
            $runnerFile
        ) `
        -NoNewWindow `
        -PassThru
}


function Read-WholeFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }


    $lastReadError =
        $null


    for ($attempt = 1; $attempt -le 40; $attempt++) {

        try {
            return [System.IO.File]::ReadAllText(
                $Path
            )
        }
        catch {

            $lastReadError =
                $_.Exception.Message


            if ($attempt -eq 40) {
                break
            }


            Start-Sleep `
                -Milliseconds 50
        }
    }


    throw (
        "Unable to read finalized process-output file: " +
        $Path +
        ". Last error: " +
        $lastReadError
    )
}


function Wait-ForScalarValue {
    param(
        [Parameter(Mandatory)]
        [string]$Sql,

        [Parameter(Mandatory)]
        [string]$Expected,

        [Parameter(Mandatory)]
        [string]$Label,

        [int]$TimeoutSeconds = 15
    )

    $deadline =
        [DateTime]::UtcNow.AddSeconds(
            $TimeoutSeconds
        )

    do {
        $actual =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Sql $Sql `
                -Label $Label

        if ($actual -eq $Expected) {
            return $actual
        }

        Start-Sleep `
            -Milliseconds 100

    } while (
        [DateTime]::UtcNow -lt $deadline
    )

    throw "$Label timed out. Expected $Expected; last observed $actual."
}


try {

    # ========================================================================
    # Secure local password handling
    #
    # The password is never written to source, stdout, logs or evidence files.
    # It exists only in this process environment long enough for child psql
    # sessions to inherit it.
    # ========================================================================

    if (
        [string]::IsNullOrWhiteSpace(
            $env:PGPASSWORD
        )
    ) {
        $securePassword =
            Read-Host `
                "PostgreSQL password for $DatabaseUser" `
                -AsSecureString

        $passwordPointer =
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
                $securePassword
            )

        try {
            $env:PGPASSWORD =
                [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                    $passwordPointer
                )
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
                $passwordPointer
            )
        }

        $PasswordWasSetByHarness =
            $true
    }


    # ========================================================================
    # Immutable source checkpoint
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F CONCURRENCY SOURCE CHECK ================"
    Write-Host ""

    $sourceHashes =
        [ordered]@{
            $P2eMigration = $ExpectedP2eMigrationHash
            $P2fMigration = $ExpectedP2fMigrationHash
            $Contract     = $ExpectedContractHash
            $Acceptance   = $ExpectedAcceptanceHash
        }


    foreach ($entry in $sourceHashes.GetEnumerator()) {

        if (-not (Test-Path -LiteralPath $entry.Key)) {
            throw "Required source missing: $($entry.Key)"
        }

        $actual =
            (
                Get-FileHash `
                    -LiteralPath $entry.Key `
                    -Algorithm SHA256
            ).Hash

        if ($actual -ne $entry.Value) {
            throw "Source hash mismatch: $($entry.Key)"
        }

        Write-Host "PASS: $($entry.Key)"
    }


    # ========================================================================
    # Verify pristine P2D source
    # ========================================================================

    $sourceShape =
        Invoke-PsqlScalar `
            -Database $SourceDatabase `
            -Label "P2D source verification" `
            -Sql @"
select
  (
    select count(*)
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and left(p.proname, 8) = 'command_'
  )
  || '|'
  || (
    to_regclass(
      'haulvia.provider_adapter_requests'
    ) is null
  )::text
  || '|'
  || (
    to_regclass(
      'haulvia.command_failure_observations'
    ) is null
  )::text;
"@

    Write-Host "P2D source: $sourceShape"

    if ($sourceShape -ne "86|true|true") {
        throw "Expected pristine P2D source 86|true|true."
    }


    # ========================================================================
    # Fresh disposable database
    # ========================================================================

    Write-Host ""
    Write-Host "================ CREATE DISPOSABLE CONCURRENCY DATABASE ================"
    Write-Host ""
    Write-Host $TargetDatabase

    & $CreateDbPath `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -T $SourceDatabase `
        $TargetDatabase

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create disposable concurrency database."
    }

    $TargetCreated =
        $true


    # ========================================================================
    # Apply committed P2E and current P2F
    # ========================================================================

    Write-Host ""
    Write-Host "================ APPLY P2E ================"

    & $PsqlPath `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $TargetDatabase `
        -X `
        -v ON_ERROR_STOP=1 `
        -f $P2eMigration

    if ($LASTEXITCODE -ne 0) {
        throw "P2E migration failed."
    }


    Write-Host ""
    Write-Host "================ APPLY P2F ================"

    & $PsqlPath `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $TargetDatabase `
        -X `
        -v ON_ERROR_STOP=1 `
        -f $P2fMigration

    if ($LASTEXITCODE -ne 0) {
        throw "P2F migration failed."
    }


    $committedShape =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F committed shape" `
            -Sql @"
select
  (
    select count(*)
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and left(p.proname, 8) = 'command_'
  )
  || '|'
  || (
    select count(*)
    from pg_class c
    join pg_namespace n
      on n.oid = c.relnamespace
    where n.nspname = 'haulvia'
      and c.relkind = 'v'
      and c.relname in (
        'v_admin_audit_projection',
        'v_failed_command_queue',
        'v_stuck_workflow_queue',
        'v_payout_attention_queue',
        'v_dispute_attention_queue',
        'v_compliance_attention_queue'
      )
  );
"@

    Write-Host "Committed shape: $committedShape"

    if ($committedShape -ne "92|6") {
        throw "Unexpected committed P2F shape."
    }


    # ========================================================================
    # Test-only working directory
    # ========================================================================

    New-Item `
        -ItemType Directory `
        -Path $TempRoot `
        -Force |
    Out-Null


    # ========================================================================
    # P2F-09 — Offer race fixture
    #
    # Build the same authority/pricing/provider model already proven by the
    # Block A acceptance suite. Production commands create the shipment route,
    # posting, initial offer and negotiation revisions.
    #
    # The race begins with:
    #
    # revision 1 = initial provider offer
    # revision 2 = customer counter #1
    # revision 3 = provider revision #1
    #
    # Two independent sessions then both try to create customer counter #2
    # against revision 3. Exactly one may become revision 4.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-09 OFFER RACE FIXTURE ================"
    Write-Host ""

    $seedSql = @"
\set ON_ERROR_STOP on
set search_path = haulvia, haulvia_command, public;

create schema p2f_test;

create table p2f_test.race_context (
  race_key text primary key,
  shipment_id uuid not null,
  route_version_id uuid not null,
  offer_thread_id uuid not null,
  response_revision_id uuid not null,
  expected_shipment_version bigint not null,
  input_a jsonb not null,
  input_b jsonb not null
);

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values
  (
    'f2090000-0000-0000-0000-000000000001'::uuid,
    'p2f09-customer',
    'CUSTOMER',
    'P2F 09 Customer Ltd.',
    'P2F 09 Customer'
  ),
  (
    'f2090000-0000-0000-0000-000000000011'::uuid,
    'p2f09-provider',
    'INDEPENDENT_PROVIDER',
    'P2F 09 Provider Ltd.',
    'P2F 09 Provider'
  );

insert into haulvia.profiles (
  id,
  display_name
)
values
  (
    'f2090000-0000-0000-0000-000000000002'::uuid,
    'P2F 09 Customer'
  ),
  (
    'f2090000-0000-0000-0000-000000000012'::uuid,
    'P2F 09 Provider'
  );

insert into haulvia.organization_memberships (
  organization_id,
  profile_id,
  status
)
values
  (
    'f2090000-0000-0000-0000-000000000001'::uuid,
    'f2090000-0000-0000-0000-000000000002'::uuid,
    'ACTIVE'
  ),
  (
    'f2090000-0000-0000-0000-000000000011'::uuid,
    'f2090000-0000-0000-0000-000000000012'::uuid,
    'ACTIVE'
  );

-- ============================================================================
-- P2F-09 test-only P2A publication authority
--
-- Approved policy/pricing fixtures must honor the production P2A
-- dual-control contract. The customer remains the creator; a separate
-- Haulvia PLATFORM_ADMIN performs approval with fresh reauthentication.
-- ============================================================================

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name
)
values (
  'f2090000-0000-0000-0000-000000000091'::uuid,
  'p2f09-publication-authority',
  'HAULVIA',
  'P2F 09 Publication Authority',
  'P2F 09 Publication Authority'
);


insert into haulvia.profiles (
  id,
  display_name
)
values (
  'f2090000-0000-0000-0000-000000000092'::uuid,
  'P2F 09 Publication Approver'
);


insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status
)
values (
  'f2090000-0000-0000-0000-000000000093'::uuid,
  'f2090000-0000-0000-0000-000000000091'::uuid,
  'f2090000-0000-0000-0000-000000000092'::uuid,
  'ACTIVE'
);


insert into haulvia.membership_roles (
  membership_id,
  role_id
)
select
  'f2090000-0000-0000-0000-000000000093'::uuid,
  r.id
from haulvia.roles r
where r.role_key =
  'PLATFORM_ADMIN';


insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at
)
values (
  'f2090000-0000-0000-0000-000000000094'::uuid,
  'f2090000-0000-0000-0000-000000000092'::uuid,
  'f2090000-0000-0000-0000-000000000091'::uuid,
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes'
);


select
  'P2F09_PUBLICATION_AUTHORITY|' ||
  haulvia.has_permission(
    'f2090000-0000-0000-0000-000000000092'::uuid,
    'f2090000-0000-0000-0000-000000000091'::uuid,
    'POLICY_PUBLISH'
  )::text
  || '|'
  ||
  haulvia.has_permission(
    'f2090000-0000-0000-0000-000000000092'::uuid,
    'f2090000-0000-0000-0000-000000000091'::uuid,
    'PRICING_MANAGE'
  )::text;

insert into haulvia.service_providers (
  id,
  organization_id,
  kind,
  status,
  approved_at
)
values (
  'f2090000-0000-0000-0000-000000000013'::uuid,
  'f2090000-0000-0000-0000-000000000011'::uuid,
  'INDEPENDENT_DRIVER',
  'ACTIVE',
  clock_timestamp()
);

insert into haulvia.drivers (
  id,
  profile_id,
  status,
  public_label
)
values (
  'f2090000-0000-0000-0000-000000000014'::uuid,
  'f2090000-0000-0000-0000-000000000012'::uuid,
  'ACTIVE',
  'P2F 09 Driver'
);

insert into haulvia.provider_drivers (
  provider_id,
  driver_id,
  status
)
values (
  'f2090000-0000-0000-0000-000000000013'::uuid,
  'f2090000-0000-0000-0000-000000000014'::uuid,
  'ACTIVE'
);

insert into haulvia.vehicles (
  id,
  provider_id,
  vehicle_key,
  status,
  vehicle_class,
  capacity_weight_kg
)
values (
  'f2090000-0000-0000-0000-000000000015'::uuid,
  'f2090000-0000-0000-0000-000000000013'::uuid,
  'p2f09-van',
  'ACTIVE',
  'CARGO_VAN',
  1000
);

insert into haulvia.policy_sets (
  id,
  policy_key,
  name
)
values (
  'f2090000-0000-0000-0000-000000000021'::uuid,
  'P2F09_POLICY',
  'P2F 09 concurrency policy'
);

insert into haulvia.policy_versions (
  id,
  policy_set_id,
  version_no,
  publication_status,
  effective_from,
  config,
  config_sha256,
  legal_review_required,
  created_by_profile_id,
  approved_by_profile_id,
  approved_at,
  reauth_session_id,
  approval_reason
)
values (
  'f2090000-0000-0000-0000-000000000022'::uuid,
  'f2090000-0000-0000-0000-000000000021'::uuid,
  1,
  'APPROVED',
  clock_timestamp() - interval '1 day',
  jsonb_build_object(
    'evidenceRequirements',
    jsonb_build_object(
      'photo',
      true
    ),
    'cancellationRules',
    jsonb_build_object(
      'preAssignment',
      'allowed'
    ),
    'refundRules',
    '{}'::jsonb,
    'timingWindows',
    '{}'::jsonb,
    'riskRules',
    '{}'::jsonb
  ),
  repeat(
    '1',
    64
  ),
  false,
  'f2090000-0000-0000-0000-000000000002'::uuid,
  'f2090000-0000-0000-0000-000000000092'::uuid,
  clock_timestamp(),
  'f2090000-0000-0000-0000-000000000094'::uuid,
  'P2F-09 concurrency fixture policy approval'
);

insert into haulvia.pricing_rule_sets (
  id,
  rule_key,
  name,
  pricing_source,
  service_level,
  currency
)
values (
  'f2090000-0000-0000-0000-000000000031'::uuid,
  'P2F09_FLEX_GUARD',
  'P2F 09 Flex guardrail',
  'HAULVIA_GUARDRAIL',
  'FLEX',
  'CAD'
);

insert into haulvia.pricing_rule_versions (
  id,
  pricing_rule_set_id,
  version_no,
  publication_status,
  effective_from,
  rule_config,
  rule_sha256,
  created_by_profile_id,
  approved_by_profile_id,
  approved_at,
  reauth_session_id,
  approval_reason
)
values (
  'f2090000-0000-0000-0000-000000000032'::uuid,
  'f2090000-0000-0000-0000-000000000031'::uuid,
  1,
  'APPROVED',
  clock_timestamp() - interval '1 day',
  jsonb_build_object(
    'floorAmount',
    50,
    'ceilingAmount',
    200,
    'absoluteCapAmount',
    300
  ),
  repeat(
    '2',
    64
  ),
  'f2090000-0000-0000-0000-000000000002'::uuid,
  'f2090000-0000-0000-0000-000000000092'::uuid,
  clock_timestamp(),
  'f2090000-0000-0000-0000-000000000094'::uuid,
  'P2F-09 concurrency fixture pricing approval'
);

insert into haulvia.customer_payment_method_refs (
  id,
  customer_organization_id,
  customer_profile_id,
  external_provider,
  external_reference,
  verified_at
)
values (
  'f2090000-0000-0000-0000-000000000041'::uuid,
  'f2090000-0000-0000-0000-000000000001'::uuid,
  'f2090000-0000-0000-0000-000000000002'::uuid,
  'TESTPAY',
  'pm-p2f09',
  clock_timestamp()
);

insert into haulvia.shipments (
  id,
  customer_organization_id,
  customer_profile_id,
  pickup_timing,
  service_level,
  currency
)
values (
  'f2090000-0000-0000-0000-000000000051'::uuid,
  'f2090000-0000-0000-0000-000000000001'::uuid,
  'f2090000-0000-0000-0000-000000000002'::uuid,
  'ASAP',
  'FLEX',
  'CAD'
);

select
  gen_random_uuid() as pickup_id,
  gen_random_uuid() as delivery_id,
  gen_random_uuid() as cargo_id,
  gen_random_uuid() as allocation_id,
  gen_random_uuid() as leg_id
\gset

select
  haulvia_command.command_save_draft(
    jsonb_build_object(
      'commandId',
      gen_random_uuid(),

      'idempotencyKey',
      'p2f09-save-draft',

      'requestHash',
      repeat(
        '1',
        64
      ),

      'actorProfileId',
      'f2090000-0000-0000-0000-000000000002'::uuid,

      'actorOrganizationId',
      'f2090000-0000-0000-0000-000000000001'::uuid,

      'shipmentId',
      'f2090000-0000-0000-0000-000000000051'::uuid,

      'expectedShipmentVersion',
      0,

      'requestedAt',
      clock_timestamp(),

      'routePlan',
      jsonb_build_object(
        'plannedDistanceKm',
        260,

        'plannedDurationSeconds',
        10800,

        'stops',
        jsonb_build_array(
          jsonb_build_object(
            'id',
            :'pickup_id'::uuid,

            'stableStopKey',
            gen_random_uuid(),

            'sequenceNo',
            1,

            'stopType',
            'PICKUP',

            'addressLine1',
            '100 P2F Avenue',

            'city',
            'Saskatoon',

            'regionCode',
            'SK',

            'countryCode',
            'CA',

            'verificationProfile',
            jsonb_build_object(
              'photo',
              true
            )
          ),

          jsonb_build_object(
            'id',
            :'delivery_id'::uuid,

            'stableStopKey',
            gen_random_uuid(),

            'sequenceNo',
            2,

            'stopType',
            'DELIVERY',

            'addressLine1',
            '200 P2F Street',

            'city',
            'Regina',

            'regionCode',
            'SK',

            'countryCode',
            'CA',

            'verificationProfile',
            jsonb_build_object(
              'pin',
              true
            )
          )
        ),

        'legs',
        jsonb_build_array(
          jsonb_build_object(
            'id',
            :'leg_id'::uuid,

            'sequenceNo',
            1,

            'fromStopId',
            :'pickup_id'::uuid,

            'toStopId',
            :'delivery_id'::uuid,

            'plannedDistanceKm',
            260,

            'plannedDurationSeconds',
            10800
          )
        ),

        'cargoItems',
        jsonb_build_array(
          jsonb_build_object(
            'id',
            :'cargo_id'::uuid,

            'stableCargoKey',
            gen_random_uuid(),

            'cargoLineNo',
            1,

            'description',
            'P2F concurrency parcel',

            'quantity',
            2,

            'quantityUnit',
            'piece',

            'totalWeightKg',
            20,

            'currency',
            'CAD'
          )
        ),

        'allocations',
        jsonb_build_array(
          jsonb_build_object(
            'id',
            :'allocation_id'::uuid,

            'cargoItemId',
            :'cargo_id'::uuid,

            'pickupStopId',
            :'pickup_id'::uuid,

            'deliveryStopId',
            :'delivery_id'::uuid,

            'quantity',
            2,

            'quantityUnit',
            'piece'
          )
        )
      )
    )
  ) as result
\gset save_

select
  (
    :'save_result'::jsonb ->>
    'routeVersionId'
  ) as route_id
\gset

select
  lock_version as shipment_lock
from haulvia.shipments
where id =
  'f2090000-0000-0000-0000-000000000051'::uuid
\gset

select
  haulvia_command.command_post_shipment(
    jsonb_build_object(
      'commandId',
      gen_random_uuid(),

      'idempotencyKey',
      'p2f09-post',

      'requestHash',
      repeat(
        '2',
        64
      ),

      'actorProfileId',
      'f2090000-0000-0000-0000-000000000002'::uuid,

      'actorOrganizationId',
      'f2090000-0000-0000-0000-000000000001'::uuid,

      'shipmentId',
      'f2090000-0000-0000-0000-000000000051'::uuid,

      'expectedShipmentVersion',
      :shipment_lock,

      'expectedRouteVersionId',
      :'route_id'::uuid,

      'requestedAt',
      clock_timestamp(),

      'paymentMethodId',
      'f2090000-0000-0000-0000-000000000041'::uuid,

      'policyVersionId',
      'f2090000-0000-0000-0000-000000000022'::uuid,

      'marketplaceDeadline',
      clock_timestamp() +
        interval '4 hours',

      'pricingSource',
      'HAULVIA_GUARDRAIL',

      'pricingMode',
      'NOT_APPLICABLE',

      'pricingRuleVersionId',
      'f2090000-0000-0000-0000-000000000032'::uuid,

      'amount',
      120,

      'subtotal',
      120,

      'taxAmount',
      0,

      'currency',
      'CAD',

      'breakdown',
      '[]'::jsonb,

      'snapshotSha256',
      repeat(
        '2',
        64
      )
    )
  ) as result
\gset post_

select
  lock_version as shipment_lock
from haulvia.shipments
where id =
  'f2090000-0000-0000-0000-000000000051'::uuid
\gset

select
  haulvia_command.command_submit_independent_flex_offer(
    jsonb_build_object(
      'commandId',
      gen_random_uuid(),

      'idempotencyKey',
      'p2f09-initial-offer',

      'requestHash',
      repeat(
        '3',
        64
      ),

      'actorProfileId',
      'f2090000-0000-0000-0000-000000000012'::uuid,

      'actorOrganizationId',
      'f2090000-0000-0000-0000-000000000011'::uuid,

      'shipmentId',
      'f2090000-0000-0000-0000-000000000051'::uuid,

      'expectedShipmentVersion',
      :shipment_lock,

      'expectedRouteVersionId',
      :'route_id'::uuid,

      'requestedAt',
      clock_timestamp(),

      'providerId',
      'f2090000-0000-0000-0000-000000000013'::uuid,

      'driverId',
      'f2090000-0000-0000-0000-000000000014'::uuid,

      'vehicleId',
      'f2090000-0000-0000-0000-000000000015'::uuid,

      'coversWholeRoute',
      true,

      'validUntil',
      clock_timestamp() +
        interval '2 hours',

      'pricingSource',
      'HAULVIA_GUARDRAIL',

      'pricingMode',
      'NOT_APPLICABLE',

      'pricingRuleVersionId',
      'f2090000-0000-0000-0000-000000000032'::uuid,

      'amount',
      125,

      'subtotal',
      125,

      'taxAmount',
      0,

      'currency',
      'CAD',

      'breakdown',
      '[]'::jsonb,

      'snapshotSha256',
      repeat(
        '3',
        64
      )
    )
  ) as result
\gset offer_

select
  (
    :'offer_result'::jsonb ->>
    'offerThreadId'
  ) as thread_id,

  (
    :'offer_result'::jsonb ->>
    'offerRevisionId'
  ) as revision_id
\gset

select
  lock_version as shipment_lock
from haulvia.shipments
where id =
  'f2090000-0000-0000-0000-000000000051'::uuid
\gset

select
  haulvia_command.command_counter_offer(
    jsonb_build_object(
      'commandId',
      gen_random_uuid(),

      'idempotencyKey',
      'p2f09-counter-one',

      'requestHash',
      repeat(
        '4',
        64
      ),

      'actorProfileId',
      'f2090000-0000-0000-0000-000000000002'::uuid,

      'actorOrganizationId',
      'f2090000-0000-0000-0000-000000000001'::uuid,

      'shipmentId',
      'f2090000-0000-0000-0000-000000000051'::uuid,

      'expectedShipmentVersion',
      :shipment_lock,

      'expectedRouteVersionId',
      :'route_id'::uuid,

      'requestedAt',
      clock_timestamp(),

      'offerThreadId',
      :'thread_id'::uuid,

      'responseToRevisionId',
      :'revision_id'::uuid,

      'validUntil',
      clock_timestamp() +
        interval '90 minutes',

      'pricingRuleVersionId',
      'f2090000-0000-0000-0000-000000000032'::uuid,

      'amount',
      115,

      'subtotal',
      115,

      'taxAmount',
      0,

      'currency',
      'CAD',

      'breakdown',
      '[]'::jsonb,

      'snapshotSha256',
      repeat(
        '4',
        64
      )
    )
  ) as result
\gset counter_

select
  (
    :'counter_result'::jsonb ->>
    'offerRevisionId'
  ) as revision_id
\gset

select
  lock_version as shipment_lock
from haulvia.shipments
where id =
  'f2090000-0000-0000-0000-000000000051'::uuid
\gset

select
  haulvia_command.command_revise_offer(
    jsonb_build_object(
      'commandId',
      gen_random_uuid(),

      'idempotencyKey',
      'p2f09-provider-revision-one',

      'requestHash',
      repeat(
        '5',
        64
      ),

      'actorProfileId',
      'f2090000-0000-0000-0000-000000000012'::uuid,

      'actorOrganizationId',
      'f2090000-0000-0000-0000-000000000011'::uuid,

      'shipmentId',
      'f2090000-0000-0000-0000-000000000051'::uuid,

      'expectedShipmentVersion',
      :shipment_lock,

      'expectedRouteVersionId',
      :'route_id'::uuid,

      'requestedAt',
      clock_timestamp(),

      'offerThreadId',
      :'thread_id'::uuid,

      'responseToRevisionId',
      :'revision_id'::uuid,

      'validUntil',
      clock_timestamp() +
        interval '80 minutes',

      'pricingRuleVersionId',
      'f2090000-0000-0000-0000-000000000032'::uuid,

      'amount',
      118,

      'subtotal',
      118,

      'taxAmount',
      0,

      'currency',
      'CAD',

      'breakdown',
      '[]'::jsonb,

      'snapshotSha256',
      repeat(
        '5',
        64
      )
    )
  ) as result
\gset revise_

select
  (
    :'revise_result'::jsonb ->>
    'offerRevisionId'
  ) as revision_id
\gset

select
  lock_version as shipment_lock
from haulvia.shipments
where id =
  'f2090000-0000-0000-0000-000000000051'::uuid
\gset

insert into p2f_test.race_context (
  race_key,
  shipment_id,
  route_version_id,
  offer_thread_id,
  response_revision_id,
  expected_shipment_version,
  input_a,
  input_b
)
values (
  'P2F-09',

  'f2090000-0000-0000-0000-000000000051'::uuid,

  :'route_id'::uuid,

  :'thread_id'::uuid,

  :'revision_id'::uuid,

  :shipment_lock,

  jsonb_build_object(
    'commandId',
    'f2090000-0000-0000-0000-000000000081'::uuid,

    'idempotencyKey',
    'p2f09-race-a',

    'requestHash',
    repeat(
      '8',
      64
    ),

    'actorProfileId',
    'f2090000-0000-0000-0000-000000000002'::uuid,

    'actorOrganizationId',
    'f2090000-0000-0000-0000-000000000001'::uuid,

    'shipmentId',
    'f2090000-0000-0000-0000-000000000051'::uuid,

    'expectedShipmentVersion',
    :shipment_lock,

    'expectedRouteVersionId',
    :'route_id'::uuid,

    'requestedAt',
    clock_timestamp(),

    'offerThreadId',
    :'thread_id'::uuid,

    'responseToRevisionId',
    :'revision_id'::uuid,

    'validUntil',
    clock_timestamp() +
      interval '60 minutes',

    'pricingRuleVersionId',
    'f2090000-0000-0000-0000-000000000032'::uuid,

    'amount',
    116,

    'subtotal',
    116,

    'taxAmount',
    0,

    'currency',
    'CAD',

    'breakdown',
    '[]'::jsonb,

    'snapshotSha256',
    repeat(
      '8',
      64
    )
  ),

  jsonb_build_object(
    'commandId',
    'f2090000-0000-0000-0000-000000000082'::uuid,

    'idempotencyKey',
    'p2f09-race-b',

    'requestHash',
    repeat(
      '9',
      64
    ),

    'actorProfileId',
    'f2090000-0000-0000-0000-000000000002'::uuid,

    'actorOrganizationId',
    'f2090000-0000-0000-0000-000000000001'::uuid,

    'shipmentId',
    'f2090000-0000-0000-0000-000000000051'::uuid,

    'expectedShipmentVersion',
    :shipment_lock,

    'expectedRouteVersionId',
    :'route_id'::uuid,

    'requestedAt',
    clock_timestamp(),

    'offerThreadId',
    :'thread_id'::uuid,

    'responseToRevisionId',
    :'revision_id'::uuid,

    'validUntil',
    clock_timestamp() +
      interval '60 minutes',

    'pricingRuleVersionId',
    'f2090000-0000-0000-0000-000000000032'::uuid,

    'amount',
    117,

    'subtotal',
    117,

    'taxAmount',
    0,

    'currency',
    'CAD',

    'breakdown',
    '[]'::jsonb,

    'snapshotSha256',
    repeat(
      '9',
      64
    )
  )
);

select
  'P2F09_FIXTURE|' ||
  (
    select
      shipment_id::text ||
      '|' ||
      offer_thread_id::text ||
      '|' ||
      response_revision_id::text ||
      '|' ||
      expected_shipment_version::text
    from p2f_test.race_context
    where race_key =
      'P2F-09'
  );
"@


    $seedFile =
        Join-Path `
            $TempRoot `
            "p2f09-seed.sql"

    Write-Utf8NoBom `
        -Path $seedFile `
        -Text (
            $seedSql.TrimEnd() +
            "`n"
        )


    & $PsqlPath `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $TargetDatabase `
        -X `
        -v ON_ERROR_STOP=1 `
        -A `
        -t `
        -f $seedFile

    if ($LASTEXITCODE -ne 0) {
        throw "P2F-09 fixture creation failed."
    }


    $fixtureShape =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 fixture verification" `
            -Sql @"
with c as (
  select *
  from p2f_test.race_context
  where race_key =
    'P2F-09'
)

select
  (
    select count(*)
    from haulvia.offer_revisions r
    join c
      on c.offer_thread_id =
        r.offer_thread_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_revisions r
    join c
      on c.offer_thread_id =
        r.offer_thread_id
    where r.revision_kind =
      'CUSTOMER_COUNTER'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_revisions r
    join c
      on c.offer_thread_id =
        r.offer_thread_id
    where r.revision_kind =
      'PROVIDER_REVISION'
  )
  || '|'
  || (
    select status::text
    from haulvia.offer_threads t
    join c
      on c.offer_thread_id =
        t.id
  );
"@

    Write-Host "Fixture shape: $fixtureShape"

    if ($fixtureShape -ne "3|1|1|ACTIVE") {
        throw "Unexpected P2F-09 pre-race fixture shape."
    }


    # ========================================================================
    # Build three real session scripts:
    #
    # 1. gate holder acquires EXCLUSIVE advisory lock;
    # 2. actor A waits for SHARED access;
    # 3. actor B waits for SHARED access.
    #
    # Parent proves that both actor sessions are waiting before terminating
    # the gate-holder backend. Both compatible shared locks are then released
    # together. Advisory locks are test synchronization only.
    # ========================================================================

    $gateSql = @"
\set ON_ERROR_STOP on
set application_name = 'p2f09_gate';
select pg_advisory_lock($GateKey);
select pg_sleep(120);
"@

    $actorASql = @"
\set ON_ERROR_STOP on
set application_name = 'p2f09_actor_a';
select pg_advisory_lock_shared($GateKey);
\echo P2F09_GATE_ACQUIRED_A
select
  'P2F09_RESULT_A|' ||
  haulvia_command.command_counter_offer(
    (
      select input_a
      from p2f_test.race_context
      where race_key =
        'P2F-09'
    )
  )::text;
select pg_advisory_unlock_shared($GateKey);
"@

    $actorBSql = @"
\set ON_ERROR_STOP on
set application_name = 'p2f09_actor_b';
select pg_advisory_lock_shared($GateKey);
\echo P2F09_GATE_ACQUIRED_B
select
  'P2F09_RESULT_B|' ||
  haulvia_command.command_counter_offer(
    (
      select input_b
      from p2f_test.race_context
      where race_key =
        'P2F-09'
    )
  )::text;
select pg_advisory_unlock_shared($GateKey);
"@


    $gateFile =
        Join-Path $TempRoot "p2f09-gate.sql"

    $actorAFile =
        Join-Path $TempRoot "p2f09-actor-a.sql"

    $actorBFile =
        Join-Path $TempRoot "p2f09-actor-b.sql"

    $gateOut =
        Join-Path $TempRoot "p2f09-gate.out.txt"

    $gateErr =
        Join-Path $TempRoot "p2f09-gate.err.txt"

    $actorAOut =
        Join-Path $TempRoot "p2f09-actor-a.out.txt"

    $actorAErr =
        Join-Path $TempRoot "p2f09-actor-a.err.txt"

    $actorBOut =
        Join-Path $TempRoot "p2f09-actor-b.out.txt"

    $actorBErr =
        Join-Path $TempRoot "p2f09-actor-b.err.txt"

    $actorAExitCodeFile =
        Join-Path $TempRoot "p2f09-actor-a.exit.txt"

    $actorBExitCodeFile =
        Join-Path $TempRoot "p2f09-actor-b.exit.txt"


    Write-Utf8NoBom `
        -Path $gateFile `
        -Text (
            $gateSql.TrimEnd() +
            "`n"
        )

    Write-Utf8NoBom `
        -Path $actorAFile `
        -Text (
            $actorASql.TrimEnd() +
            "`n"
        )

    Write-Utf8NoBom `
        -Path $actorBFile `
        -Text (
            $actorBSql.TrimEnd() +
            "`n"
        )


    # ========================================================================
    # Acquire test gate
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-09 START SYNCHRONIZATION ================"
    Write-Host ""

    $gateProcess =
        Start-PsqlScriptProcess `
            -SqlFile $gateFile `
            -StdOutFile $gateOut `
            -StdErrFile $gateErr


    Wait-ForScalarValue `
        -Expected "1" `
        -Label "P2F-09 exclusive gate acquisition" `
        -Sql @"
select count(*)
from pg_stat_activity a
join pg_locks l
  on l.pid = a.pid
where a.datname =
    current_database()

  and a.application_name =
    'p2f09_gate'

  and l.locktype =
    'advisory'

  and l.granted;
"@ |
    Out-Null

    Write-Host "P2F09_GATE_HELD|1"


    # ========================================================================
    # Launch genuinely separate PostgreSQL actor processes
    # ========================================================================

    $actorAProcess =
        Start-PsqlScriptProcess `
            -SqlFile $actorAFile `
            -StdOutFile $actorAOut `
            -StdErrFile $actorAErr `
            -ExitCodeFile $actorAExitCodeFile

    $actorBProcess =
        Start-PsqlScriptProcess `
            -SqlFile $actorBFile `
            -StdOutFile $actorBOut `
            -StdErrFile $actorBErr `
            -ExitCodeFile $actorBExitCodeFile


    $waiterCount =
        Wait-ForScalarValue `
            -Expected "2" `
            -Label "P2F-09 two-session barrier readiness" `
            -Sql @"
select count(*)
from pg_stat_activity
where datname =
    current_database()

  and application_name in (
    'p2f09_actor_a',
    'p2f09_actor_b'
  )

  and wait_event_type =
    'Lock'

  and wait_event =
    'advisory';
"@

    Write-Host "P2F09_WAITERS|$waiterCount"


    $gateBackendPid =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 gate backend lookup" `
            -Sql @"
select pid
from pg_stat_activity
where datname =
    current_database()

  and application_name =
    'p2f09_gate';
"@


    if (
        [string]::IsNullOrWhiteSpace(
            $gateBackendPid
        )
    ) {
        throw "Unable to identify P2F-09 gate backend."
    }


    $gateReleasedAt =
        [DateTime]::UtcNow

    $gateReleaseResult =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 gate release" `
            -Sql @"
select pg_terminate_backend(
  $gateBackendPid
);
"@

    if ($gateReleaseResult -ne "t") {
        throw "Unable to release P2F-09 synchronization gate."
    }

    Write-Host (
        "P2F09_GATE_RELEASED_UTC|" +
        $gateReleasedAt.ToString("o")
    )


    # ========================================================================
    # Capture completion order
    # ========================================================================

    $completion =
        [System.Collections.Generic.List[object]]::new()

    $seen =
        @{}

    $actorDeadline =
        [DateTime]::UtcNow.AddSeconds(
            30
        )


    while ($completion.Count -lt 2) {

        foreach ($actor in @(
            @{
                Name =
                    "A"

                Process =
                    $actorAProcess
            },
            @{
                Name =
                    "B"

                Process =
                    $actorBProcess
            }
        )) {

            if ($seen.ContainsKey($actor.Name)) {
                continue
            }

            $actor.Process.Refresh()

            if ($actor.Process.HasExited) {

                $observedAt =
                    [DateTime]::UtcNow

                $completion.Add(
                    [pscustomobject]@{
                        Actor =
                            $actor.Name

                        ObservedCompletionUtc =
                            $observedAt

                        ExitCode =
                            $null
                    }
                )

                $seen[$actor.Name] =
                    $true
            }
        }


        if (
            $completion.Count -lt 2 -and
            [DateTime]::UtcNow -ge $actorDeadline
        ) {

            foreach ($process in @(
                $actorAProcess,
                $actorBProcess
            )) {

                $process.Refresh()

                if (-not $process.HasExited) {
                    $process.Kill()
                }
            }

            throw "P2F-09 actors did not complete within 30 seconds."
        }

        if ($completion.Count -lt 2) {
            Start-Sleep `
                -Milliseconds 20
        }
    }


    # ========================================================================
    # Windows process/output finalization
    #
    # HasExited proves that the child process has terminated, but on Windows
    # redirected stdout/stderr file handles may not yet be fully finalized.
    # WaitForExit() establishes the process-output completion boundary before
    # exit codes or evidence files are consumed.
    # ========================================================================

    $actorAProcess.WaitForExit()
    $actorBProcess.WaitForExit()


    $actorAExitCodeText =
        (
            Read-WholeFile `
                $actorAExitCodeFile
        ).Trim()

    $actorBExitCodeText =
        (
            Read-WholeFile `
                $actorBExitCodeFile
        ).Trim()


    if (
        $actorAExitCodeText -notmatch
        '^\d+$'
    ) {
        throw "P2F-09 Actor A psql exit-code sidecar is invalid: $actorAExitCodeText"
    }


    if (
        $actorBExitCodeText -notmatch
        '^\d+$'
    ) {
        throw "P2F-09 Actor B psql exit-code sidecar is invalid: $actorBExitCodeText"
    }


    $actorAExitCode =
        [int]$actorAExitCodeText

    $actorBExitCode =
        [int]$actorBExitCodeText


    foreach ($item in $completion) {

        if ($item.Actor -eq "A") {
            $item.ExitCode =
                $actorAExitCode
        }
        elseif ($item.Actor -eq "B") {
            $item.ExitCode =
                $actorBExitCode
        }
        else {
            throw "Unexpected P2F-09 completion actor: $($item.Actor)"
        }
    }


    Write-Host (
        "P2F09_PROCESS_OUTPUT_FINALIZED|" +
        $actorAExitCode +
        "|" +
        $actorBExitCode
    )


    foreach ($item in $completion) {
        Write-Host (
            "P2F09_COMPLETION|" +
            $item.Actor +
            "|" +
            $item.ObservedCompletionUtc.ToString("o") +
            "|" +
            $item.ExitCode
        )
    }


    $actorAStdOut =
        Read-WholeFile $actorAOut

    $actorAStdErr =
        Read-WholeFile $actorAErr

    $actorBStdOut =
        Read-WholeFile $actorBOut

    $actorBStdErr =
        Read-WholeFile $actorBErr


    Write-Host ""
    Write-Host "================ P2F-09 ACTOR CLASSIFICATION ================"
    Write-Host ""

    Write-Host "Actor A exit: $actorAExitCode"
    Write-Host "Actor B exit: $actorBExitCode"


    $successfulActors =
        @(
            if ($actorAExitCode -eq 0) {
                "A"
            }

            if ($actorBExitCode -eq 0) {
                "B"
            }
        )


    if ($successfulActors.Count -ne 1) {
        Write-Host "---- Actor A stdout ----"
        Write-Host $actorAStdOut

        Write-Host "---- Actor A stderr ----"
        Write-Host $actorAStdErr

        Write-Host "---- Actor B stdout ----"
        Write-Host $actorBStdOut

        Write-Host "---- Actor B stderr ----"
        Write-Host $actorBStdErr

        throw "P2F-09 requires exactly one successful logical winner."
    }


    $winner =
        $successfulActors[0]

    $loser =
        if ($winner -eq "A") {
            "B"
        }
        else {
            "A"
        }


    $winnerOutput =
        if ($winner -eq "A") {
            $actorAStdOut
        }
        else {
            $actorBStdOut
        }


    $loserOutput =
        if ($loser -eq "A") {
            $actorAStdOut +
            "`n" +
            $actorAStdErr
        }
        else {
            $actorBStdOut +
            "`n" +
            $actorBStdErr
        }


    if (
        $winnerOutput -notmatch
        "P2F09_RESULT_$winner\|"
    ) {
        throw "P2F-09 winner did not return the expected command result marker."
    }


    $approvedLoserCodes =
        @(
            "OFFER_NOT_ACTIONABLE",
            "STALE_SHIPMENT_VERSION"
        )


    $loserCode =
        $approvedLoserCodes |
        Where-Object {
            $loserOutput.Contains($_)
        } |
        Select-Object -First 1


    if (
        [string]::IsNullOrWhiteSpace(
            $loserCode
        )
    ) {
        Write-Host "---- Loser output ----"
        Write-Host $loserOutput

        throw "P2F-09 loser did not use an approved deterministic conflict path."
    }


    Write-Host "P2F09_WINNER|$winner"
    Write-Host "P2F09_LOSER|$loser|$loserCode"


    # ========================================================================
    # Canonical post-race state
    # ========================================================================

    $postRaceState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 canonical post-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.race_context
  where race_key =
    'P2F-09'
),

revision_stats as (
  select
    count(*) as revision_count,

    count(*) filter (
      where r.revision_kind =
        'CUSTOMER_COUNTER'
    ) as customer_counter_count,

    max(
      r.revision_no
    ) as max_revision_no

  from haulvia.offer_revisions r
  join c
    on c.offer_thread_id =
      r.offer_thread_id
),

duplicate_revision_numbers as (
  select count(*) as n
  from (
    select
      r.revision_no
    from haulvia.offer_revisions r
    join c
      on c.offer_thread_id =
        r.offer_thread_id
    group by
      r.revision_no
    having count(*) > 1
  ) d
),

orphan_offer_snapshots as (
  select count(*) as n
  from haulvia.shipment_price_snapshots s
  join c
    on c.shipment_id =
      s.shipment_id
  left join haulvia.offer_revisions r
    on r.pricing_snapshot_id =
      s.id
  where s.purpose::text =
      'OFFER'

    and r.id
      is null
),

race_idempotency as (
  select count(*) as n
  from haulvia.command_idempotency
  where idempotency_key in (
    'p2f09-race-a',
    'p2f09-race-b'
  )
),

reservation_count as (
  select count(*) as n
  from haulvia.offer_reservations x
  join c
    on c.shipment_id =
      x.shipment_id
)

select
  rs.revision_count::text
  || '|'
  || rs.customer_counter_count::text
  || '|'
  || dr.n::text
  || '|'
  || os.n::text
  || '|'
  || ri.n::text
  || '|'
  || (
    select t.status::text
    from haulvia.offer_threads t
    join c
      on c.offer_thread_id =
        t.id
  )
  || '|'
  || rc.n::text
  || '|'
  || rs.max_revision_no::text

from revision_stats rs
cross join duplicate_revision_numbers dr
cross join orphan_offer_snapshots os
cross join race_idempotency ri
cross join reservation_count rc;
"@

    Write-Host "P2F09_POST_RACE|$postRaceState"


    if (
        $postRaceState -ne
        "4|2|0|0|1|ACTIVE|0|4"
    ) {
        throw "P2F-09 canonical post-race state is invalid."
    }


    # ========================================================================
    # Exact idempotent replay of winner
    # ========================================================================

    $winnerInputColumn =
        if ($winner -eq "A") {
            "input_a"
        }
        else {
            "input_b"
        }


    $winnerKey =
        if ($winner -eq "A") {
            "p2f09-race-a"
        }
        else {
            "p2f09-race-b"
        }


    $loserKey =
        if ($loser -eq "A") {
            "p2f09-race-a"
        }
        else {
            "p2f09-race-b"
        }


    $replayOutput =
        Invoke-PsqlText `
            -Database $TargetDatabase `
            -Label "P2F-09 winner replay" `
            -Sql @"
select
  'P2F09_REPLAY|' ||
  haulvia_command.command_counter_offer(
    (
      select $winnerInputColumn
      from p2f_test.race_context
      where race_key =
        'P2F-09'
    )
  )::text;
"@


    Write-Host $replayOutput


    if (
        $replayOutput -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-09 exact winner replay did not return replayed=true."
    }


    $postReplayRevisionCount =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 replay revision count" `
            -Sql @"
select count(*)
from haulvia.offer_revisions r
join p2f_test.race_context c
  on c.offer_thread_id =
    r.offer_thread_id
where c.race_key =
  'P2F-09';
"@

    if ($postReplayRevisionCount -ne "4") {
        throw "P2F-09 exact replay created a duplicate revision."
    }


    # ========================================================================
    # Same key + different request hash must fail closed
    # ========================================================================

    $differentHash =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
select
  haulvia_command.command_counter_offer(
    (
      select $winnerInputColumn
      from p2f_test.race_context
      where race_key =
        'P2F-09'
    )
    ||
    jsonb_build_object(
      'requestHash',
      repeat(
        'f',
        64
      )
    )
  );
"@


    if (
        $differentHash.ExitCode -eq 0 -or
        -not $differentHash.Text.Contains(
            "IDEMPOTENCY_KEY_REUSED"
        )
    ) {
        Write-Host $differentHash.Text
        throw "P2F-09 same-key/different-hash reuse did not fail closed."
    }

    Write-Host "P2F09_IDEMPOTENCY_CONFLICT|IDEMPOTENCY_KEY_REUSED"


    # ========================================================================
    # Counter limit remains intact after the race
    # ========================================================================

    $thirdCounter =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
with c as (
  select *
  from p2f_test.race_context
  where race_key =
    'P2F-09'
),

latest_revision as (
  select r.id
  from haulvia.offer_revisions r
  join c
    on c.offer_thread_id =
      r.offer_thread_id
  order by
    r.revision_no desc
  limit 1
),

current_shipment as (
  select s.lock_version
  from haulvia.shipments s
  join c
    on c.shipment_id =
      s.id
)

select
  haulvia_command.command_counter_offer(
    jsonb_build_object(
      'commandId',
      'f2090000-0000-0000-0000-000000000083'::uuid,

      'idempotencyKey',
      'p2f09-third-counter',

      'requestHash',
      repeat(
        'c',
        64
      ),

      'actorProfileId',
      'f2090000-0000-0000-0000-000000000002'::uuid,

      'actorOrganizationId',
      'f2090000-0000-0000-0000-000000000001'::uuid,

      'shipmentId',
      c.shipment_id,

      'expectedShipmentVersion',
      s.lock_version,

      'expectedRouteVersionId',
      c.route_version_id,

      'requestedAt',
      clock_timestamp(),

      'offerThreadId',
      c.offer_thread_id,

      'responseToRevisionId',
      r.id,

      'validUntil',
      clock_timestamp() +
        interval '45 minutes',

      'pricingRuleVersionId',
      'f2090000-0000-0000-0000-000000000032'::uuid,

      'amount',
      119,

      'subtotal',
      119,

      'taxAmount',
      0,

      'currency',
      'CAD',

      'breakdown',
      '[]'::jsonb,

      'snapshotSha256',
      repeat(
        'c',
        64
      )
    )
  )

from c
cross join latest_revision r
cross join current_shipment s;
"@


    if (
        $thirdCounter.ExitCode -eq 0 -or
        -not $thirdCounter.Text.Contains(
            "COUNTER_LIMIT_REACHED"
        )
    ) {
        Write-Host $thirdCounter.Text
        throw "P2F-09 counter limit did not remain intact after concurrency."
    }

    Write-Host "P2F09_COUNTER_LIMIT|COUNTER_LIMIT_REACHED"


    # ========================================================================
    # Loser and rejected third counter leave no idempotency/orphan facts
    # ========================================================================

    $failureResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 loser/orphan residue" `
            -Sql @"
select
  (
    select count(*)
    from haulvia.command_idempotency
    where idempotency_key =
      '$loserKey'
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency
    where idempotency_key =
      'p2f09-third-counter'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    join p2f_test.race_context c
      on c.shipment_id =
        s.shipment_id
    left join haulvia.offer_revisions r
      on r.pricing_snapshot_id =
        s.id
    where c.race_key =
        'P2F-09'

      and s.purpose::text =
        'OFFER'

      and r.id
        is null
  );
"@

    Write-Host "P2F09_FAILURE_RESIDUE|$failureResidue"

    if ($failureResidue -ne "0|0|0") {
        throw "P2F-09 losing/rejected operations left partial business facts."
    }


    # ========================================================================
    # Final P2F-09 state
    # ========================================================================

    $finalRaceState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-09 final canonical state" `
            -Sql @"
with c as (
  select *
  from p2f_test.race_context
  where race_key =
    'P2F-09'
)

select
  (
    select count(*)
    from haulvia.offer_revisions r
    where r.offer_thread_id =
      c.offer_thread_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_revisions r
    where r.offer_thread_id =
        c.offer_thread_id

      and r.revision_kind =
        'CUSTOMER_COUNTER'
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency
    where idempotency_key =
      '$winnerKey'

      and status =
        'COMPLETED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_reservations x
    where x.shipment_id =
      c.shipment_id
  )

from c;
"@

    Write-Host "P2F09_FINAL_STATE|$finalRaceState"

    if ($finalRaceState -ne "4|2|1|0") {
        throw "P2F-09 final canonical state is invalid."
    }


    # ========================================================================
    # P2F-10 — Reservation race fixture
    #
    # Two customer tabs select two different valid offer threads for the same
    # shipment from the same observed shipment version.
    #
    # Required result:
    #   - exactly one active reservation;
    #   - exactly one payment intent;
    #   - exactly one RESERVATION price snapshot;
    #   - exactly one selected thread becomes RESERVED;
    #   - the losing still-valid thread remains ACTIVE;
    #   - marketplace becomes RESERVED;
    #   - customer payment becomes AUTHORIZING;
    #   - no assignment is created;
    #   - losing transaction leaves no command/payment/pricing residue.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-10 RESERVATION RACE FIXTURE ================"
    Write-Host ""


    $p2f10FixtureOutput =
        Invoke-PsqlText `
            -Database $TargetDatabase `
            -Label "P2F-10 reservation fixture" `
            -Sql @"
create table p2f_test.reservation_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  route_version_id uuid not null,
  thread_a_id uuid not null,
  revision_a_id uuid not null,
  thread_b_id uuid not null,
  revision_b_id uuid not null,
  input_a jsonb not null,
  input_b jsonb not null
);


with base as (
  select
    c.shipment_id,
    c.route_version_id,
    c.offer_thread_id as thread_a_id,

    (
      select r.id
      from haulvia.offer_revisions r
      where r.offer_thread_id =
        c.offer_thread_id
      order by
        r.revision_no desc
      limit 1
    ) as revision_a_id,

    (
      select r.amount
      from haulvia.offer_revisions r
      where r.offer_thread_id =
        c.offer_thread_id
      order by
        r.revision_no asc
      limit 1
    ) as seed_amount,

    s.lock_version

  from p2f_test.race_context c
  join haulvia.shipments s
    on s.id =
      c.shipment_id

  where c.race_key =
    'P2F-09'
),

second_offer as (
  select
    b.*,

    haulvia_command.command_submit_independent_flex_offer(
      jsonb_build_object(
        'commandId',
        'f2100000-0000-0000-0000-000000000060'::uuid,

        'idempotencyKey',
        'p2f10-seed-offer-b',

        'requestHash',
        repeat(
          'd',
          64
        ),

        'actorProfileId',
        'f2090000-0000-0000-0000-000000000012'::uuid,

        'actorOrganizationId',
        'f2090000-0000-0000-0000-000000000011'::uuid,

        'shipmentId',
        b.shipment_id,

        'expectedShipmentVersion',
        b.lock_version,

        'expectedRouteVersionId',
        b.route_version_id,

        'requestedAt',
        clock_timestamp(),

        'providerId',
        'f2090000-0000-0000-0000-000000000013'::uuid,

        'driverId',
        'f2090000-0000-0000-0000-000000000014'::uuid,

        'vehicleId',
        'f2090000-0000-0000-0000-000000000015'::uuid,

        'coversWholeRoute',
        true,

        'validUntil',
        clock_timestamp() +
          interval '60 minutes',

        'pricingSource',
        'HAULVIA_GUARDRAIL',

        'pricingMode',
        'NOT_APPLICABLE',

        'pricingRuleVersionId',
        'f2090000-0000-0000-0000-000000000032'::uuid,

        'amount',
        b.seed_amount,

        'subtotal',
        b.seed_amount,

        'taxAmount',
        0,

        'currency',
        'CAD',

        'breakdown',
        '[]'::jsonb,

        'snapshotSha256',
        repeat(
          'd',
          64
        )
      )
    ) as result

  from base b
),

normalized as (
  select
    so.shipment_id,
    so.route_version_id,
    so.thread_a_id,
    so.revision_a_id,

    (
      so.result ->>
      'offerThreadId'
    )::uuid as thread_b_id,

    (
      so.result ->>
      'offerRevisionId'
    )::uuid as revision_b_id,

    (
      so.result ->>
      'lockVersion'
    )::bigint as race_lock_version

  from second_offer so
)

insert into p2f_test.reservation_race_context (
  race_key,
  shipment_id,
  route_version_id,
  thread_a_id,
  revision_a_id,
  thread_b_id,
  revision_b_id,
  input_a,
  input_b
)

select
  'P2F-10',
  n.shipment_id,
  n.route_version_id,
  n.thread_a_id,
  n.revision_a_id,
  n.thread_b_id,
  n.revision_b_id,

  jsonb_build_object(
    'commandId',
    'f2100000-0000-0000-0000-000000000081'::uuid,

    'idempotencyKey',
    'p2f10-race-a',

    'requestHash',
    repeat(
      'a',
      64
    ),

    'actorProfileId',
    'f2090000-0000-0000-0000-000000000002'::uuid,

    'actorOrganizationId',
    'f2090000-0000-0000-0000-000000000001'::uuid,

    'shipmentId',
    n.shipment_id,

    'expectedShipmentVersion',
    n.race_lock_version,

    'expectedRouteVersionId',
    n.route_version_id,

    'requestedAt',
    clock_timestamp(),

    'offerThreadId',
    n.thread_a_id,

    'selectedRevisionId',
    n.revision_a_id,

    'paymentMethodId',
    'f2090000-0000-0000-0000-000000000041'::uuid,

    'reservationExpiresAt',
    clock_timestamp() +
      interval '10 minutes',

    'reservationSnapshotSha256',
    repeat(
      'a',
      64
    ),

    'paymentProvider',
    'TESTPAY',

    'paymentProviderIdempotencyKey',
    'p2f10-pay-a'
  ),

  jsonb_build_object(
    'commandId',
    'f2100000-0000-0000-0000-000000000082'::uuid,

    'idempotencyKey',
    'p2f10-race-b',

    'requestHash',
    repeat(
      'b',
      64
    ),

    'actorProfileId',
    'f2090000-0000-0000-0000-000000000002'::uuid,

    'actorOrganizationId',
    'f2090000-0000-0000-0000-000000000001'::uuid,

    'shipmentId',
    n.shipment_id,

    'expectedShipmentVersion',
    n.race_lock_version,

    'expectedRouteVersionId',
    n.route_version_id,

    'requestedAt',
    clock_timestamp(),

    'offerThreadId',
    n.thread_b_id,

    'selectedRevisionId',
    n.revision_b_id,

    'paymentMethodId',
    'f2090000-0000-0000-0000-000000000041'::uuid,

    'reservationExpiresAt',
    clock_timestamp() +
      interval '10 minutes',

    'reservationSnapshotSha256',
    repeat(
      'b',
      64
    ),

    'paymentProvider',
    'TESTPAY',

    'paymentProviderIdempotencyKey',
    'p2f10-pay-b'
  )

from normalized n;


select
  'P2F10_FIXTURE|'
  || c.shipment_id::text
  || '|'
  || c.thread_a_id::text
  || '|'
  || c.thread_b_id::text
  || '|'
  || (
    c.input_a ->>
    'expectedShipmentVersion'
  )
  || '|'
  || (
    c.input_b ->>
    'expectedShipmentVersion'
  )

from p2f_test.reservation_race_context c
where c.race_key =
  'P2F-10';
"@


    Write-Host $p2f10FixtureOutput


    $p2f10PreRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 pre-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.reservation_race_context
  where race_key =
    'P2F-10'
)

select
  (
    select count(*)
    from haulvia.offer_threads t
    where t.id in (
      c.thread_a_id,
      c.thread_b_id
    )

      and t.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_reservations r
    where r.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
        c.shipment_id

      and s.purpose =
        'RESERVATION'
  )
  || '|'
  || (
    select m.state::text
    from haulvia.shipment_marketplace_axes m
    where m.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select p.state::text
    from haulvia.shipment_customer_payment_axes p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select s.shipment_state::text
    from haulvia.shipments s
    where s.id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id
  )

from c;
"@


    Write-Host "P2F10_PRE_RACE|$p2f10PreRace"


    if (
        $p2f10PreRace -ne
        "2|0|0|0|ACTIVE|METHOD_VERIFIED|NEGOTIATING|0"
    ) {
        throw "P2F-10 fixture is not in the required pre-race state."
    }


    # ========================================================================
    # P2F-10 start barrier
    # ========================================================================

    $p2f10GateFile =
        Join-Path $TempRoot "p2f10-gate.sql"

    $p2f10GateOut =
        Join-Path $TempRoot "p2f10-gate.out.txt"

    $p2f10GateErr =
        Join-Path $TempRoot "p2f10-gate.err.txt"

    $p2f10ActorAFile =
        Join-Path $TempRoot "p2f10-actor-a.sql"

    $p2f10ActorBFile =
        Join-Path $TempRoot "p2f10-actor-b.sql"

    $p2f10ActorAOut =
        Join-Path $TempRoot "p2f10-actor-a.out.txt"

    $p2f10ActorBOut =
        Join-Path $TempRoot "p2f10-actor-b.out.txt"

    $p2f10ActorAErr =
        Join-Path $TempRoot "p2f10-actor-a.err.txt"

    $p2f10ActorBErr =
        Join-Path $TempRoot "p2f10-actor-b.err.txt"

    $p2f10ActorAExit =
        Join-Path $TempRoot "p2f10-actor-a.exit.txt"

    $p2f10ActorBExit =
        Join-Path $TempRoot "p2f10-actor-b.exit.txt"


    Write-Utf8NoBom `
        -Path $p2f10GateFile `
        -Text @"
set application_name =
  'p2f10_gate';

select
  pg_advisory_lock(
    21010
  );

select
  'P2F10_GATE_HELD';

select
  pg_sleep(
    120
  );
"@


    Write-Utf8NoBom `
        -Path $p2f10ActorAFile `
        -Text @"
set application_name =
  'p2f10_actor_a';

select
  pg_advisory_lock_shared(
    21010
  );

select
  'P2F10_GATE_ACQUIRED_A';

select
  'P2F10_RESULT_A|'
  ||
  haulvia_command.command_reserve_selection(
    (
      select input_a
      from p2f_test.reservation_race_context
      where race_key =
        'P2F-10'
    )
  )::text;
"@


    Write-Utf8NoBom `
        -Path $p2f10ActorBFile `
        -Text @"
set application_name =
  'p2f10_actor_b';

select
  pg_advisory_lock_shared(
    21010
  );

select
  'P2F10_GATE_ACQUIRED_B';

select
  'P2F10_RESULT_B|'
  ||
  haulvia_command.command_reserve_selection(
    (
      select input_b
      from p2f_test.reservation_race_context
      where race_key =
        'P2F-10'
    )
  )::text;
"@


    Write-Host ""
    Write-Host "================ P2F-10 START SYNCHRONIZATION ================"
    Write-Host ""


    $p2f10GateProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f10GateFile `
            -StdOutFile $p2f10GateOut `
            -StdErrFile $p2f10GateErr


    $p2f10GateReady =
        $false


    for (
        $attempt = 1;
        $attempt -le 100;
        $attempt++
    ) {

        $gateCount =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-10 gate readiness" `
                -Sql @"
select count(*)
from pg_stat_activity a
join pg_locks l
  on l.pid =
    a.pid
where a.datname =
    current_database()

  and a.application_name =
    'p2f10_gate'

  and l.locktype =
    'advisory'

  and l.granted;
"@


        if ($gateCount -eq "1") {
            $p2f10GateReady =
                $true

            break
        }


        Start-Sleep `
            -Milliseconds 50
    }


    if (-not $p2f10GateReady) {
        throw "P2F-10 start gate did not acquire its advisory lock."
    }


    Write-Host "P2F10_GATE_HELD|1"


    $p2f10ActorAProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f10ActorAFile `
            -StdOutFile $p2f10ActorAOut `
            -StdErrFile $p2f10ActorAErr `
            -ExitCodeFile $p2f10ActorAExit


    $p2f10ActorBProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f10ActorBFile `
            -StdOutFile $p2f10ActorBOut `
            -StdErrFile $p2f10ActorBErr `
            -ExitCodeFile $p2f10ActorBExit


    $p2f10BothWaiting =
        $false


    for (
        $attempt = 1;
        $attempt -le 200;
        $attempt++
    ) {

        $waiterCount =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-10 waiting actors" `
                -Sql @"
select count(
  distinct a.pid
)
from pg_stat_activity a
join pg_locks l
  on l.pid =
    a.pid
where a.datname =
    current_database()

  and a.application_name in (
    'p2f10_actor_a',
    'p2f10_actor_b'
  )

  and l.locktype =
    'advisory'

  and not l.granted;
"@


        if ($waiterCount -eq "2") {
            $p2f10BothWaiting =
                $true

            break
        }


        Start-Sleep `
            -Milliseconds 50
    }


    Write-Host "P2F10_WAITERS|$waiterCount"


    if (-not $p2f10BothWaiting) {
        throw "P2F-10 did not observe both actor sessions waiting at the barrier."
    }


    $p2f10GateBackendPid =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 gate backend pid" `
            -Sql @"
select
  case
    when count(*) = 1 then
      min(pid)::text
    else
      ''
  end
from pg_stat_activity
where datname =
    current_database()

  and application_name =
    'p2f10_gate'

  and pid <>
    pg_backend_pid();
"@


    if (
        [string]::IsNullOrWhiteSpace(
            $p2f10GateBackendPid
        )
    ) {
        throw "P2F-10 did not identify exactly one start-gate session."
    }


    $releasedGate =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 gate release" `
            -Sql @"
select pg_terminate_backend(
  $p2f10GateBackendPid
);
"@


    if ($releasedGate -ne "t") {
        throw "Unable to release P2F-10 synchronization gate."
    }


    $p2f10GateReleasedUtc =
        [DateTime]::UtcNow


    Write-Host (
        "P2F10_GATE_RELEASED_UTC|" +
        $p2f10GateReleasedUtc.ToString("o")
    )


    # ========================================================================
    # Capture independent actor completion order
    # ========================================================================

    $p2f10Completion =
        New-Object `
            System.Collections.Generic.List[object]

    $p2f10Seen =
        @{}


    $p2f10Actors =
        @(
            [pscustomobject]@{
                Actor =
                    "A"

                Process =
                    $p2f10ActorAProcess
            },

            [pscustomobject]@{
                Actor =
                    "B"

                Process =
                    $p2f10ActorBProcess
            }
        )


    for (
        $attempt = 1;
        $attempt -le 6000 -and
        $p2f10Completion.Count -lt 2;
        $attempt++
    ) {

        foreach ($actor in $p2f10Actors) {

            if (
                -not $p2f10Seen.ContainsKey(
                    $actor.Actor
                )
            ) {

                $actor.Process.Refresh()


                if ($actor.Process.HasExited) {

                    $p2f10Seen[
                        $actor.Actor
                    ] =
                        $true


                    $p2f10Completion.Add(
                        [pscustomobject]@{
                            Actor =
                                $actor.Actor

                            ObservedCompletionUtc =
                                [DateTime]::UtcNow

                            ExitCode =
                                $null
                        }
                    )
                }
            }
        }


        if ($p2f10Completion.Count -lt 2) {
            Start-Sleep `
                -Milliseconds 10
        }
    }


    if ($p2f10Completion.Count -ne 2) {
        throw "P2F-10 actor completion timed out."
    }


    $p2f10ActorAProcess.WaitForExit()
    $p2f10ActorBProcess.WaitForExit()
    $p2f10GateProcess.WaitForExit()


    $p2f10ActorAExitText =
        (
            Read-WholeFile `
                $p2f10ActorAExit
        ).Trim()

    $p2f10ActorBExitText =
        (
            Read-WholeFile `
                $p2f10ActorBExit
        ).Trim()


    if (
        $p2f10ActorAExitText -notmatch
        '^\d+$'
    ) {
        throw "P2F-10 Actor A exit sidecar is invalid: $p2f10ActorAExitText"
    }


    if (
        $p2f10ActorBExitText -notmatch
        '^\d+$'
    ) {
        throw "P2F-10 Actor B exit sidecar is invalid: $p2f10ActorBExitText"
    }


    $p2f10ActorAExitCode =
        [int]$p2f10ActorAExitText

    $p2f10ActorBExitCode =
        [int]$p2f10ActorBExitText


    foreach ($item in $p2f10Completion) {

        if ($item.Actor -eq "A") {
            $item.ExitCode =
                $p2f10ActorAExitCode
        }
        elseif ($item.Actor -eq "B") {
            $item.ExitCode =
                $p2f10ActorBExitCode
        }
        else {
            throw "Unexpected P2F-10 completion actor: $($item.Actor)"
        }
    }


    Write-Host (
        "P2F10_PROCESS_OUTPUT_FINALIZED|" +
        $p2f10ActorAExitCode +
        "|" +
        $p2f10ActorBExitCode
    )


    foreach ($item in $p2f10Completion) {

        Write-Host (
            "P2F10_COMPLETION|" +
            $item.Actor +
            "|" +
            $item.ObservedCompletionUtc.ToString("o") +
            "|" +
            $item.ExitCode
        )
    }


    # ========================================================================
    # Actor result classification
    # ========================================================================

    $p2f10ActorAStdOut =
        Read-WholeFile `
            $p2f10ActorAOut

    $p2f10ActorAStdErr =
        Read-WholeFile `
            $p2f10ActorAErr

    $p2f10ActorBStdOut =
        Read-WholeFile `
            $p2f10ActorBOut

    $p2f10ActorBStdErr =
        Read-WholeFile `
            $p2f10ActorBErr


    Write-Host ""
    Write-Host "================ P2F-10 ACTOR CLASSIFICATION ================"
    Write-Host ""

    Write-Host "Actor A exit: $p2f10ActorAExitCode"
    Write-Host "Actor B exit: $p2f10ActorBExitCode"

    Write-Host "---- Actor A stdout ----"
    Write-Host $p2f10ActorAStdOut

    Write-Host "---- Actor A stderr ----"
    Write-Host $p2f10ActorAStdErr

    Write-Host "---- Actor B stdout ----"
    Write-Host $p2f10ActorBStdOut

    Write-Host "---- Actor B stderr ----"
    Write-Host $p2f10ActorBStdErr


    $p2f10SuccessfulActors =
        @()


    if ($p2f10ActorAExitCode -eq 0) {
        $p2f10SuccessfulActors +=
            "A"
    }


    if ($p2f10ActorBExitCode -eq 0) {
        $p2f10SuccessfulActors +=
            "B"
    }


    if ($p2f10SuccessfulActors.Count -ne 1) {
        throw "P2F-10 requires exactly one successful reservation actor."
    }


    $p2f10Winner =
        $p2f10SuccessfulActors[0]

    $p2f10Loser =
        if ($p2f10Winner -eq "A") {
            "B"
        }
        else {
            "A"
        }


    $p2f10LoserText =
        if ($p2f10Loser -eq "A") {
            $p2f10ActorAStdOut +
            "`n" +
            $p2f10ActorAStdErr
        }
        else {
            $p2f10ActorBStdOut +
            "`n" +
            $p2f10ActorBStdErr
        }


    if (
        $p2f10LoserText.Contains(
            "STALE_SHIPMENT_VERSION"
        )
    ) {
        $p2f10LoserCode =
            "STALE_SHIPMENT_VERSION"
    }
    elseif (
        $p2f10LoserText.Contains(
            "RESERVATION_CONFLICT"
        )
    ) {
        $p2f10LoserCode =
            "RESERVATION_CONFLICT"
    }
    else {
        throw "P2F-10 loser did not use an approved deterministic conflict path."
    }


    $p2f10WinnerOutput =
        if ($p2f10Winner -eq "A") {
            $p2f10ActorAStdOut
        }
        else {
            $p2f10ActorBStdOut
        }


    if (
        -not $p2f10WinnerOutput.Contains(
            "P2F10_RESULT_$p2f10Winner|"
        )
    ) {
        throw "P2F-10 winner did not return a reservation command result."
    }


    Write-Host "P2F10_WINNER|$p2f10Winner"
    Write-Host "P2F10_LOSER|$p2f10Loser|$p2f10LoserCode"


    # ========================================================================
    # Canonical post-race reservation/payment state
    # ========================================================================

    $p2f10PostRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 canonical post-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.reservation_race_context
  where race_key =
    'P2F-10'
)

select
  (
    select count(*)
    from haulvia.offer_reservations r
    where r.shipment_id =
        c.shipment_id

      and r.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_reservations r
    where r.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.shipment_id =
        c.shipment_id

      and p.status =
        'AUTHORIZING'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
        c.shipment_id

      and s.purpose =
        'RESERVATION'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_threads t
    where t.id in (
      c.thread_a_id,
      c.thread_b_id
    )

      and t.status =
        'RESERVED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_threads t
    where t.id in (
      c.thread_a_id,
      c.thread_b_id
    )

      and t.status =
        'ACTIVE'
  )
  || '|'
  || (
    select m.state::text
    from haulvia.shipment_marketplace_axes m
    where m.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select p.state::text
    from haulvia.shipment_customer_payment_axes p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name =
        'reserveSelection'

      and i.idempotency_key in (
        'p2f10-race-a',
        'p2f10-race-b'
      )

      and i.status =
        'COMPLETED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    left join haulvia.offer_reservations r
      on r.id =
        p.offer_reservation_id
    where p.shipment_id =
        c.shipment_id

      and r.id
        is null
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id =
        c.shipment_id

      and j.job_code =
        'PAYMENT_RESERVATION_TIMEOUT'

      and j.idempotency_key in (
        c.shipment_id::text ||
          ':p2f10-race-a:selection-timeout',

        c.shipment_id::text ||
          ':p2f10-race-b:selection-timeout'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id =
        c.shipment_id

      and n.event_code =
        'SELECTION_RESERVED'

      and n.idempotency_key in (
        c.shipment_id::text ||
          ':p2f10-race-a:selection-reserved',

        c.shipment_id::text ||
          ':p2f10-race-b:selection-reserved'
      )
  )

from c;
"@


    Write-Host "P2F10_POST_RACE|$p2f10PostRace"


    if (
        $p2f10PostRace -ne
        "1|1|1|1|1|1|1|RESERVED|AUTHORIZING|0|1|0|1|1"
    ) {
        throw "P2F-10 canonical reservation/payment state is invalid."
    }


    $p2f10WinnerBinding =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 winner binding" `
            -Sql @"
with c as (
  select *
  from p2f_test.reservation_race_context
  where race_key =
    'P2F-10'
),

r as (
  select x.*
  from haulvia.offer_reservations x
  join c
    on c.shipment_id =
      x.shipment_id
  where x.status =
    'ACTIVE'
)

select
  case
    when (
      r.offer_thread_id =
        c.thread_a_id

      and r.selected_revision_id =
        c.revision_a_id
    )
      then 'A'

    when (
      r.offer_thread_id =
        c.thread_b_id

      and r.selected_revision_id =
        c.revision_b_id
    )
      then 'B'

    else 'INVALID'
  end

from r
join c
  on c.shipment_id =
    r.shipment_id;
"@


    Write-Host "P2F10_WINNER_BINDING|$p2f10WinnerBinding"


    if (
        $p2f10WinnerBinding -ne
        $p2f10Winner
    ) {
        throw "P2F-10 active reservation is not bound to the winning actor selection."
    }


    # ========================================================================
    # Exact winner replay
    # ========================================================================

    $p2f10WinnerInputColumn =
        if ($p2f10Winner -eq "A") {
            "input_a"
        }
        else {
            "input_b"
        }


    $p2f10WinnerKey =
        if ($p2f10Winner -eq "A") {
            "p2f10-race-a"
        }
        else {
            "p2f10-race-b"
        }


    $p2f10LoserKey =
        if ($p2f10Loser -eq "A") {
            "p2f10-race-a"
        }
        else {
            "p2f10-race-b"
        }


    $p2f10LoserPaymentKey =
        if ($p2f10Loser -eq "A") {
            "p2f10-pay-a"
        }
        else {
            "p2f10-pay-b"
        }


    $p2f10Replay =
        Invoke-PsqlText `
            -Database $TargetDatabase `
            -Label "P2F-10 winner replay" `
            -Sql @"
select
  'P2F10_REPLAY|'
  ||
  haulvia_command.command_reserve_selection(
    (
      select $p2f10WinnerInputColumn
      from p2f_test.reservation_race_context
      where race_key =
        'P2F-10'
    )
  )::text;
"@


    Write-Host $p2f10Replay


    if (
        $p2f10Replay -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-10 exact winner replay did not return replayed=true."
    }


    $p2f10ReplayState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 replay state" `
            -Sql @"
with c as (
  select *
  from p2f_test.reservation_race_context
  where race_key =
    'P2F-10'
)

select
  (
    select count(*)
    from haulvia.offer_reservations r
    where r.shipment_id =
        c.shipment_id

      and r.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
        c.shipment_id

      and s.purpose =
        'RESERVATION'
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id =
        c.shipment_id

      and j.job_code =
        'PAYMENT_RESERVATION_TIMEOUT'

      and j.idempotency_key like
        c.shipment_id::text ||
        ':p2f10-race-%:selection-timeout'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id =
        c.shipment_id

      and n.event_code =
        'SELECTION_RESERVED'

      and n.idempotency_key like
        c.shipment_id::text ||
        ':p2f10-race-%:selection-reserved'
  )

from c;
"@


    Write-Host "P2F10_REPLAY_STATE|$p2f10ReplayState"


    if ($p2f10ReplayState -ne "1|1|1|1|1") {
        throw "P2F-10 replay duplicated reservation/payment facts."
    }


    # ========================================================================
    # Same key + different request hash must fail closed
    # ========================================================================

    $p2f10DifferentHash =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
select
  haulvia_command.command_reserve_selection(
    (
      select $p2f10WinnerInputColumn
      from p2f_test.reservation_race_context
      where race_key =
        'P2F-10'
    )
    ||
    jsonb_build_object(
      'requestHash',
      repeat(
        'f',
        64
      )
    )
  );
"@


    if (
        $p2f10DifferentHash.ExitCode -eq 0 -or
        -not $p2f10DifferentHash.Text.Contains(
            "IDEMPOTENCY_KEY_REUSED"
        )
    ) {
        Write-Host $p2f10DifferentHash.Text
        throw "P2F-10 same-key/different-hash reuse did not fail closed."
    }


    Write-Host "P2F10_IDEMPOTENCY_CONFLICT|IDEMPOTENCY_KEY_REUSED"


    # ========================================================================
    # Losing transaction residue
    # ========================================================================

    $p2f10FailureResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 loser residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.reservation_race_context
  where race_key =
    'P2F-10'
)

select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name =
        'reserveSelection'

      and i.idempotency_key =
        '$p2f10LoserKey'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.shipment_id =
        c.shipment_id

      and p.provider_idempotency_key =
        '$p2f10LoserPaymentKey'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
        c.shipment_id

      and s.purpose =
        'RESERVATION'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    left join haulvia.offer_reservations r
      on r.id =
        p.offer_reservation_id
    where p.shipment_id =
        c.shipment_id

      and r.id
        is null
  )

from c;
"@


    Write-Host "P2F10_FAILURE_RESIDUE|$p2f10FailureResidue"


    if ($p2f10FailureResidue -ne "0|0|1|0") {
        throw "P2F-10 losing reservation operation left partial business facts."
    }


    $p2f10FinalState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-10 final state" `
            -Sql @"
with c as (
  select *
  from p2f_test.reservation_race_context
  where race_key =
    'P2F-10'
)

select
  (
    select count(*)
    from haulvia.offer_reservations r
    where r.shipment_id =
        c.shipment_id

      and r.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_threads t
    where t.id in (
      c.thread_a_id,
      c.thread_b_id
    )

      and t.status =
        'RESERVED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_threads t
    where t.id in (
      c.thread_a_id,
      c.thread_b_id
    )

      and t.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id
  )

from c;
"@


    Write-Host "P2F10_FINAL_STATE|$p2f10FinalState"


    if ($p2f10FinalState -ne "1|1|1|1|0") {
        throw "P2F-10 final canonical state is invalid."
    }



    # ========================================================================
    # P2F-11 - Assignment race fixture
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-11 ASSIGNMENT RACE FIXTURE ================"
    Write-Host ""


    & $PsqlPath `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        -d $TargetDatabase `
        -X `
        -v ON_ERROR_STOP=1 `
        -c @"
create table p2f_test.assignment_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  route_version_id uuid not null,
  reservation_id uuid not null,
  payment_intent_id uuid not null,
  selected_revision_id uuid not null,
  expected_version bigint not null,
  secured_amount numeric(14,2) not null,
  currency char(3) not null,
  input_a jsonb not null,
  input_b jsonb not null
);

insert into p2f_test.assignment_race_context (
  race_key,
  shipment_id,
  route_version_id,
  reservation_id,
  payment_intent_id,
  selected_revision_id,
  expected_version,
  secured_amount,
  currency,
  input_a,
  input_b
)
with base as (
  select
    s.id as shipment_id,
    rv.id as route_version_id,
    r.id as reservation_id,
    pi.id as payment_intent_id,
    r.selected_revision_id,
    s.lock_version as expected_version,
    pi.amount as secured_amount,
    pi.currency
  from p2f_test.reservation_race_context rc
  join haulvia.shipments s
    on s.id =
      rc.shipment_id
  join haulvia.route_versions rv
    on rv.shipment_id =
      s.id

   and rv.status =
      'ACTIVE'
  join haulvia.offer_reservations r
    on r.shipment_id =
      s.id

   and r.status =
      'ACTIVE'
  join haulvia.payment_intents pi
    on pi.shipment_id =
      s.id

   and pi.offer_reservation_id =
      r.id

   and pi.status =
      'AUTHORIZING'
  where rc.race_key =
    'P2F-10'
)
select
  'P2F-11',
  b.shipment_id,
  b.route_version_id,
  b.reservation_id,
  b.payment_intent_id,
  b.selected_revision_id,
  b.expected_version,
  b.secured_amount,
  b.currency,

  jsonb_build_object(
    'commandId',
      'f2110000-0000-0000-0000-000000000081'::uuid,
    'idempotencyKey',
      'p2f11-race-a',
    'requestHash',
      repeat('a', 64),
    'actorProfileId',
      null,
    'workerAuthority',
      'PAYMENT_PROVIDER_CALLBACK',
    'shipmentId',
      b.shipment_id,
    'expectedShipmentVersion',
      b.expected_version,
    'expectedRouteVersionId',
      b.route_version_id,
    'requestedAt',
      clock_timestamp(),
    'paymentIntentId',
      b.payment_intent_id,
    'reservationId',
      b.reservation_id,
    'providerEventId',
      'evt-p2f11-a',
    'securedAmount',
      b.secured_amount,
    'currency',
      b.currency,
    'transactionType',
      'CAPTURE',
    'assignmentSnapshotSha256',
      repeat('a', 64),
    'agreementSnapshot',
      jsonb_build_object(
        'termsVersion',
          'p2f11-v1',
        'raceActor',
          'A'
      )
  ),

  jsonb_build_object(
    'commandId',
      'f2110000-0000-0000-0000-000000000082'::uuid,
    'idempotencyKey',
      'p2f11-race-b',
    'requestHash',
      repeat('b', 64),
    'actorProfileId',
      null,
    'workerAuthority',
      'PAYMENT_PROVIDER_CALLBACK',
    'shipmentId',
      b.shipment_id,
    'expectedShipmentVersion',
      b.expected_version,
    'expectedRouteVersionId',
      b.route_version_id,
    'requestedAt',
      clock_timestamp(),
    'paymentIntentId',
      b.payment_intent_id,
    'reservationId',
      b.reservation_id,
    'providerEventId',
      'evt-p2f11-b',
    'securedAmount',
      b.secured_amount,
    'currency',
      b.currency,
    'transactionType',
      'CAPTURE',
    'assignmentSnapshotSha256',
      repeat('b', 64),
    'agreementSnapshot',
      jsonb_build_object(
        'termsVersion',
          'p2f11-v1',
        'raceActor',
          'B'
      )
  )

from base b;
"@


    if ($LASTEXITCODE -ne 0) {
        throw "Unable to create P2F-11 assignment-race fixture."
    }


    $p2f11Fixture =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 fixture" `
            -Sql @"
select
  'P2F11_FIXTURE|'
  || shipment_id::text
  || '|'
  || reservation_id::text
  || '|'
  || payment_intent_id::text
  || '|'
  || selected_revision_id::text
  || '|'
  || expected_version::text
  || '|'
  || secured_amount::text
  || '|'
  || currency::text
from p2f_test.assignment_race_context
where race_key =
  'P2F-11';
"@


    Write-Host $p2f11Fixture


    $p2f11PreRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 pre-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.assignment_race_context
  where race_key =
    'P2F-11'
)

select
  (
    select count(*)
    from haulvia.offer_reservations r
    where r.id =
      c.reservation_id

      and r.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents p
    where p.id =
      c.payment_intent_id

      and p.status =
        'AUTHORIZING'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_transactions pt
    where pt.payment_intent_id =
      c.payment_intent_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
      c.shipment_id

      and s.purpose =
        'ASSIGNMENT'
  )
  || '|'
  || (
    select p.state::text
    from haulvia.shipment_customer_payment_axes p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select m.state::text
    from haulvia.shipment_marketplace_axes m
    where m.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select s.shipment_state::text
    from haulvia.shipments s
    where s.id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_reservations r
    where r.id =
      c.reservation_id

      and r.selected_revision_id =
        c.selected_revision_id
  )

from c;
"@


    Write-Host "P2F11_PRE_RACE|$p2f11PreRace"


    if (
        $p2f11PreRace -ne
        "1|1|0|0|0|AUTHORIZING|RESERVED|NEGOTIATING|1"
    ) {
        throw "P2F-11 fixture is not at the required pre-assignment state."
    }


    # ========================================================================
    # Test-only synchronization files
    # ========================================================================

    $p2f11GateFile =
        Join-Path $TempRoot "p2f11-gate.sql"

    $p2f11GateOut =
        Join-Path $TempRoot "p2f11-gate.out.txt"

    $p2f11GateErr =
        Join-Path $TempRoot "p2f11-gate.err.txt"

    $p2f11ActorAFile =
        Join-Path $TempRoot "p2f11-actor-a.sql"

    $p2f11ActorBFile =
        Join-Path $TempRoot "p2f11-actor-b.sql"

    $p2f11ActorAOut =
        Join-Path $TempRoot "p2f11-actor-a.out.txt"

    $p2f11ActorBOut =
        Join-Path $TempRoot "p2f11-actor-b.out.txt"

    $p2f11ActorAErr =
        Join-Path $TempRoot "p2f11-actor-a.err.txt"

    $p2f11ActorBErr =
        Join-Path $TempRoot "p2f11-actor-b.err.txt"

    $p2f11ActorAExitFile =
        Join-Path $TempRoot "p2f11-actor-a.exit.txt"

    $p2f11ActorBExitFile =
        Join-Path $TempRoot "p2f11-actor-b.exit.txt"


    Write-Utf8NoBom `
        -Path $p2f11GateFile `
        -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f11_gate';

select pg_advisory_lock(
  211,
  11
);

\echo P2F11_GATE_ACQUIRED

select pg_sleep(
  120
);
"@


    Write-Utf8NoBom `
        -Path $p2f11ActorAFile `
        -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f11_actor_a';

select pg_advisory_lock_shared(
  211,
  11
);

\echo P2F11_GATE_ACQUIRED_A

select
  'P2F11_RESULT_A|'
  ||
  haulvia_command.command_confirm_paid_assignment(
    (
      select input_a
      from p2f_test.assignment_race_context
      where race_key =
        'P2F-11'
    )
  )::text;
"@


    Write-Utf8NoBom `
        -Path $p2f11ActorBFile `
        -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f11_actor_b';

select pg_advisory_lock_shared(
  211,
  11
);

\echo P2F11_GATE_ACQUIRED_B

select
  'P2F11_RESULT_B|'
  ||
  haulvia_command.command_confirm_paid_assignment(
    (
      select input_b
      from p2f_test.assignment_race_context
      where race_key =
        'P2F-11'
    )
  )::text;
"@


    # ========================================================================
    # Hold exclusive test-only gate
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-11 START SYNCHRONIZATION ================"
    Write-Host ""


    $p2f11GateProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f11GateFile `
            -StdOutFile $p2f11GateOut `
            -StdErrFile $p2f11GateErr


    $p2f11GateReady =
        $false

    $p2f11GateDeadline =
        [DateTime]::UtcNow.AddSeconds(
            15
        )


    while (
        -not $p2f11GateReady -and
        [DateTime]::UtcNow -lt $p2f11GateDeadline
    ) {

        $gateCount =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-11 gate readiness" `
                -Sql @"
select count(*)::text
from pg_locks l
join pg_stat_activity a
  on a.pid =
    l.pid
where a.datname =
    current_database()

  and a.application_name =
    'p2f11_gate'

  and l.locktype =
    'advisory'

  and l.granted;
"@


        if ($gateCount -eq "1") {
            $p2f11GateReady =
                $true
        }
        else {
            Start-Sleep `
                -Milliseconds 50
        }
    }


    if (-not $p2f11GateReady) {
        throw "P2F-11 exclusive synchronization gate was not established."
    }


    Write-Host "P2F11_GATE_HELD|1"


    # ========================================================================
    # Launch two genuine PostgreSQL actors
    # ========================================================================

    $p2f11ActorAProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f11ActorAFile `
            -StdOutFile $p2f11ActorAOut `
            -StdErrFile $p2f11ActorAErr `
            -ExitCodeFile $p2f11ActorAExitFile


    $p2f11ActorBProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f11ActorBFile `
            -StdOutFile $p2f11ActorBOut `
            -StdErrFile $p2f11ActorBErr `
            -ExitCodeFile $p2f11ActorBExitFile


    $p2f11BothWaiting =
        $false

    $p2f11WaitDeadline =
        [DateTime]::UtcNow.AddSeconds(
            15
        )


    while (
        -not $p2f11BothWaiting -and
        [DateTime]::UtcNow -lt $p2f11WaitDeadline
    ) {

        $p2f11Waiters =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-11 waiting actors" `
                -Sql @"
select count(*)::text
from pg_stat_activity
where datname =
    current_database()

  and application_name in (
    'p2f11_actor_a',
    'p2f11_actor_b'
  )

  and wait_event_type =
    'Lock';
"@


        if ($p2f11Waiters -eq "2") {
            $p2f11BothWaiting =
                $true
        }
        else {
            Start-Sleep `
                -Milliseconds 50
        }
    }


    if (-not $p2f11BothWaiting) {
        throw "P2F-11 did not observe both assignment actors waiting at the barrier."
    }


    Write-Host "P2F11_WAITERS|2"


    # ========================================================================
    # Safe two-stage gate release
    # ========================================================================

    $p2f11GateBackendPid =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 gate backend pid" `
            -Sql @"
select
  case
    when count(*) = 1 then
      min(pid)::text
    else
      ''
  end
from pg_stat_activity
where datname =
    current_database()

  and application_name =
    'p2f11_gate'

  and pid <>
    pg_backend_pid();
"@


    if (
        [string]::IsNullOrWhiteSpace(
            $p2f11GateBackendPid
        )
    ) {
        throw "P2F-11 did not identify exactly one synchronization-gate session."
    }


    $p2f11GateReleasedUtc =
        [DateTime]::UtcNow


    $p2f11GateReleaseResult =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 gate release" `
            -Sql @"
select pg_terminate_backend(
  $p2f11GateBackendPid
);
"@


    if ($p2f11GateReleaseResult -ne "t") {
        throw "Unable to release P2F-11 synchronization gate."
    }


    Write-Host (
        "P2F11_GATE_RELEASED_UTC|" +
        $p2f11GateReleasedUtc.ToString("o")
    )


    # ========================================================================
    # Capture independent actor completion order
    # ========================================================================

    $p2f11Completion =
        [System.Collections.Generic.List[object]]::new()

    $p2f11Seen =
        @{}

    $p2f11CompletionDeadline =
        [DateTime]::UtcNow.AddSeconds(
            30
        )


    $p2f11Actors =
        @(
            [pscustomobject]@{
                Name =
                    "A"

                Process =
                    $p2f11ActorAProcess
            },

            [pscustomobject]@{
                Name =
                    "B"

                Process =
                    $p2f11ActorBProcess
            }
        )


    while (
        $p2f11Completion.Count -lt 2 -and
        [DateTime]::UtcNow -lt $p2f11CompletionDeadline
    ) {

        foreach ($actor in $p2f11Actors) {

            if (
                -not $p2f11Seen.ContainsKey(
                    $actor.Name
                ) -and
                $actor.Process.HasExited
            ) {

                $completedAt =
                    [DateTime]::UtcNow


                $p2f11Completion.Add(
                    [pscustomobject]@{
                        Name =
                            $actor.Name

                        CompletedAt =
                            $completedAt
                    }
                )


                $p2f11Seen[
                    $actor.Name
                ] =
                    $true
            }
        }


        if ($p2f11Completion.Count -lt 2) {
            Start-Sleep `
                -Milliseconds 20
        }
    }


    if ($p2f11Completion.Count -ne 2) {
        throw "P2F-11 actor processes did not both complete within the deadline."
    }


    $p2f11ActorAProcess.WaitForExit()
    $p2f11ActorBProcess.WaitForExit()
    $p2f11GateProcess.WaitForExit()


    foreach ($exitPath in @(
        $p2f11ActorAExitFile,
        $p2f11ActorBExitFile
    )) {

        if (-not (Test-Path -LiteralPath $exitPath)) {
            throw "P2F-11 actor exit-code sidecar is missing: $exitPath"
        }
    }


    $p2f11ActorAExit =
        [int](
            (
                Read-WholeFile `
                    -Path $p2f11ActorAExitFile
            ).Trim()
        )


    $p2f11ActorBExit =
        [int](
            (
                Read-WholeFile `
                    -Path $p2f11ActorBExitFile
            ).Trim()
        )


    Write-Host (
        "P2F11_PROCESS_OUTPUT_FINALIZED|" +
        $p2f11ActorAExit +
        "|" +
        $p2f11ActorBExit
    )


    foreach ($entry in $p2f11Completion) {

        $entryExit =
            if ($entry.Name -eq "A") {
                $p2f11ActorAExit
            }
            else {
                $p2f11ActorBExit
            }


        Write-Host (
            "P2F11_COMPLETION|" +
            $entry.Name +
            "|" +
            $entry.CompletedAt.ToString("o") +
            "|" +
            $entryExit
        )
    }


    # ========================================================================
    # Actor classification
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-11 ACTOR CLASSIFICATION ================"
    Write-Host ""


    $p2f11ActorAStdOut =
        Read-WholeFile `
            -Path $p2f11ActorAOut

    $p2f11ActorBStdOut =
        Read-WholeFile `
            -Path $p2f11ActorBOut

    $p2f11ActorAStdErr =
        Read-WholeFile `
            -Path $p2f11ActorAErr

    $p2f11ActorBStdErr =
        Read-WholeFile `
            -Path $p2f11ActorBErr


    Write-Host "Actor A exit: $p2f11ActorAExit"
    Write-Host "Actor B exit: $p2f11ActorBExit"

    Write-Host "---- Actor A stdout ----"
    Write-Host $p2f11ActorAStdOut

    Write-Host "---- Actor A stderr ----"
    Write-Host $p2f11ActorAStdErr

    Write-Host "---- Actor B stdout ----"
    Write-Host $p2f11ActorBStdOut

    Write-Host "---- Actor B stderr ----"
    Write-Host $p2f11ActorBStdErr


    if (
        $p2f11ActorAExit -eq 0 -and
        $p2f11ActorBExit -ne 0
    ) {

        $p2f11Winner =
            "A"

        $p2f11Loser =
            "B"

        $p2f11WinnerInputColumn =
            "input_a"

        $p2f11WinnerKey =
            "p2f11-race-a"

        $p2f11LoserKey =
            "p2f11-race-b"

        $p2f11LoserProviderEvent =
            "evt-p2f11-b"

        $p2f11LoserSnapshotHash =
            ("b" * 64)

        $p2f11LoserText =
            $p2f11ActorBStdOut +
            "`n" +
            $p2f11ActorBStdErr
    }
    elseif (
        $p2f11ActorBExit -eq 0 -and
        $p2f11ActorAExit -ne 0
    ) {

        $p2f11Winner =
            "B"

        $p2f11Loser =
            "A"

        $p2f11WinnerInputColumn =
            "input_b"

        $p2f11WinnerKey =
            "p2f11-race-b"

        $p2f11LoserKey =
            "p2f11-race-a"

        $p2f11LoserProviderEvent =
            "evt-p2f11-a"

        $p2f11LoserSnapshotHash =
            ("a" * 64)

        $p2f11LoserText =
            $p2f11ActorAStdOut +
            "`n" +
            $p2f11ActorAStdErr
    }
    else {

        throw "P2F-11 did not produce exactly one successful assignment actor."
    }


    $p2f11ApprovedLoserCodes =
        @(
            "STALE_SHIPMENT_VERSION",
            "INVALID_STATE",
            "FUNDING_NOT_SECURED",
            "ASSIGNMENT_CONFLICT",
            "DEADLINE_EXPIRED"
        )


    $p2f11LoserCode =
        $null


    foreach ($candidate in $p2f11ApprovedLoserCodes) {

        if (
            $p2f11LoserText.Contains(
                $candidate
            )
        ) {

            $p2f11LoserCode =
                $candidate

            break
        }
    }


    if (
        [string]::IsNullOrWhiteSpace(
            $p2f11LoserCode
        )
    ) {

        throw "P2F-11 losing assignment actor did not use an approved deterministic conflict path."
    }


    Write-Host "P2F11_WINNER|$p2f11Winner"
    Write-Host "P2F11_LOSER|$p2f11Loser|$p2f11LoserCode"


    # ========================================================================
    # Canonical post-race state
    # ========================================================================

    $p2f11PostRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 post-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.assignment_race_context
  where race_key =
    'P2F-11'
)

select
  (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id

      and a.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_transactions pt
    where pt.payment_intent_id =
      c.payment_intent_id

      and pt.status =
        'SUCCEEDED'

      and pt.provider_event_id in (
        'evt-p2f11-a',
        'evt-p2f11-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
      c.shipment_id

      and s.purpose =
        'ASSIGNMENT'

      and s.snapshot_sha256 in (
        repeat('a', 64),
        repeat('b', 64)
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignment_events ae
    where ae.shipment_id =
      c.shipment_id

      and ae.command_name =
        'confirmPaidAssignment'

      and ae.idempotency_key in (
        'p2f11-race-a',
        'p2f11-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_reservations r
    where r.id =
      c.reservation_id

      and r.status =
        'CONVERTED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_intents pi
    where pi.id =
      c.payment_intent_id

      and pi.status =
        'SECURED'
  )
  || '|'
  || (
    select p.state::text
    from haulvia.shipment_customer_payment_axes p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select m.state::text
    from haulvia.shipment_marketplace_axes m
    where m.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select s.shipment_state::text
    from haulvia.shipments s
    where s.id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_threads t
    join haulvia.offer_reservations r
      on r.id =
        c.reservation_id
    where t.id =
      r.offer_thread_id

      and t.status =
        'ACCEPTED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_threads t
    join haulvia.offer_reservations r
      on r.id =
        c.reservation_id
    where t.shipment_id =
      c.shipment_id

      and t.id <>
        r.offer_thread_id

      and t.status in (
        'ACTIVE',
        'RESERVED',
        'RECONFIRMATION_REQUIRED'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id

      and a.status =
        'ACTIVE'

      and a.offer_reservation_id =
        c.reservation_id

      and a.selected_offer_revision_id =
        c.selected_revision_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id =
      c.shipment_id

      and n.event_code =
        'ASSIGNMENT_CONFIRMED'

      and n.idempotency_key in (
        c.shipment_id::text ||
          ':p2f11-race-a:assignment-customer',

        c.shipment_id::text ||
          ':p2f11-race-a:assignment-driver',

        c.shipment_id::text ||
          ':p2f11-race-b:assignment-customer',

        c.shipment_id::text ||
          ':p2f11-race-b:assignment-driver'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id =
      c.shipment_id

      and j.job_code =
        'TRIP_START_REMINDER'

      and j.idempotency_key in (
        c.shipment_id::text ||
          ':p2f11-race-a:trip-start',

        c.shipment_id::text ||
          ':p2f11-race-b:trip-start'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name =
      'confirmPaidAssignment'

      and i.idempotency_key in (
        'p2f11-race-a',
        'p2f11-race-b'
      )

      and i.status =
        'COMPLETED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name =
      'confirmPaidAssignment'

      and i.idempotency_key in (
        'p2f11-race-a',
        'p2f11-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_executions re
    where re.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_customer_payment_axes p
    where p.shipment_id =
      c.shipment_id

      and p.state =
        'SECURED'

      and p.secured_amount =
        c.secured_amount

      and p.currency =
        c.currency
  )

from c;
"@


    Write-Host "P2F11_POST_RACE|$p2f11PostRace"


    if (
        $p2f11PostRace -ne
        "1|1|1|1|1|1|1|SECURED|CLOSED|DRIVER_ASSIGNED|1|0|1|2|1|1|1|0|1"
    ) {
        throw "P2F-11 canonical assignment/funding state is invalid."
    }


    # ========================================================================
    # Winner must match the committed payment event
    # ========================================================================

    $p2f11WinnerBinding =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 winner binding" `
            -Sql @"
with c as (
  select *
  from p2f_test.assignment_race_context
  where race_key =
    'P2F-11'
)

select
  case pt.provider_event_id
    when 'evt-p2f11-a'
      then 'A'

    when 'evt-p2f11-b'
      then 'B'

    else
      'INVALID'
  end

from c
join haulvia.payment_transactions pt
  on pt.payment_intent_id =
    c.payment_intent_id

 and pt.status =
    'SUCCEEDED'

 and pt.provider_event_id in (
    'evt-p2f11-a',
    'evt-p2f11-b'
 )
join haulvia.assignments a
  on a.shipment_id =
    c.shipment_id

 and a.status =
    'ACTIVE'

 and a.offer_reservation_id =
    c.reservation_id;
"@


    Write-Host "P2F11_WINNER_BINDING|$p2f11WinnerBinding"


    if (
        $p2f11WinnerBinding -ne
        $p2f11Winner
    ) {
        throw "P2F-11 committed assignment/payment event does not match the winning actor."
    }


    # ========================================================================
    # Exact winner replay
    # ========================================================================

    $p2f11Replay =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 winner replay" `
            -Sql @"
select
  haulvia_command.command_confirm_paid_assignment(
    (
      select $p2f11WinnerInputColumn
      from p2f_test.assignment_race_context
      where race_key =
        'P2F-11'
    )
  );
"@


    Write-Host "P2F11_REPLAY|$p2f11Replay"


    if (
        $p2f11Replay -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-11 exact winner replay did not return replayed=true."
    }


    $p2f11ReplayState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 replay state" `
            -Sql @"
with c as (
  select *
  from p2f_test.assignment_race_context
  where race_key =
    'P2F-11'
)

select
  (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_transactions pt
    where pt.payment_intent_id =
      c.payment_intent_id

      and pt.provider_event_id in (
        'evt-p2f11-a',
        'evt-p2f11-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
      c.shipment_id

      and s.purpose =
        'ASSIGNMENT'

      and s.snapshot_sha256 in (
        repeat('a', 64),
        repeat('b', 64)
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignment_events ae
    where ae.shipment_id =
      c.shipment_id

      and ae.idempotency_key in (
        'p2f11-race-a',
        'p2f11-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id =
      c.shipment_id

      and n.event_code =
        'ASSIGNMENT_CONFIRMED'

      and n.idempotency_key like
        c.shipment_id::text ||
        ':p2f11-race-%:assignment-%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id =
      c.shipment_id

      and j.job_code =
        'TRIP_START_REMINDER'

      and j.idempotency_key like
        c.shipment_id::text ||
        ':p2f11-race-%:trip-start'
  )

from c;
"@


    Write-Host "P2F11_REPLAY_STATE|$p2f11ReplayState"


    if ($p2f11ReplayState -ne "1|1|1|1|2|1") {
        throw "P2F-11 replay duplicated assignment/payment facts."
    }


    # ========================================================================
    # Same key + different request hash must fail closed
    # ========================================================================

    $p2f11DifferentHash =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
select
  haulvia_command.command_confirm_paid_assignment(
    (
      select $p2f11WinnerInputColumn
      from p2f_test.assignment_race_context
      where race_key =
        'P2F-11'
    )
    ||
    jsonb_build_object(
      'requestHash',
      repeat(
        'f',
        64
      )
    )
  );
"@


    if (
        $p2f11DifferentHash.ExitCode -eq 0 -or
        -not $p2f11DifferentHash.Text.Contains(
            "IDEMPOTENCY_KEY_REUSED"
        )
    ) {

        Write-Host $p2f11DifferentHash.Text

        throw "P2F-11 same-key/different-hash reuse did not fail closed."
    }


    Write-Host "P2F11_IDEMPOTENCY_CONFLICT|IDEMPOTENCY_KEY_REUSED"


    # ========================================================================
    # Losing assignment transaction must leave no partial facts
    # ========================================================================

    $p2f11FailureResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 loser residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.assignment_race_context
  where race_key =
    'P2F-11'
)

select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name =
      'confirmPaidAssignment'

      and i.idempotency_key =
        '$p2f11LoserKey'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_transactions pt
    where pt.payment_intent_id =
      c.payment_intent_id

      and pt.provider_event_id =
        '$p2f11LoserProviderEvent'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
      c.shipment_id

      and s.purpose =
        'ASSIGNMENT'

      and s.snapshot_sha256 =
        '$p2f11LoserSnapshotHash'
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignment_events ae
    where ae.shipment_id =
      c.shipment_id

      and ae.idempotency_key =
        '$p2f11LoserKey'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id =
      c.shipment_id

      and n.idempotency_key like
        c.shipment_id::text ||
        ':${p2f11LoserKey}:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id =
      c.shipment_id

      and j.idempotency_key like
        c.shipment_id::text ||
        ':${p2f11LoserKey}:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events ae
    where ae.entity_table =
      'shipments'

      and ae.entity_id =
        c.shipment_id

      and ae.command_name =
        'confirmPaidAssignment'

      and ae.idempotency_key =
        '$p2f11LoserKey'
  )

from c;
"@


    Write-Host "P2F11_FAILURE_RESIDUE|$p2f11FailureResidue"


    if ($p2f11FailureResidue -ne "0|0|0|0|0|0|0") {
        throw "P2F-11 losing assignment operation left partial business facts."
    }


    # ========================================================================
    # Final canonical assignment state
    # ========================================================================

    $p2f11FinalState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-11 final state" `
            -Sql @"
with c as (
  select *
  from p2f_test.assignment_race_context
  where race_key =
    'P2F-11'
)

select
  (
    select count(*)
    from haulvia.assignments a
    where a.shipment_id =
      c.shipment_id

      and a.status =
        'ACTIVE'
  )
  || '|'
  || (
    select count(*)
    from haulvia.payment_transactions pt
    where pt.payment_intent_id =
      c.payment_intent_id

      and pt.status =
        'SUCCEEDED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_price_snapshots s
    where s.shipment_id =
      c.shipment_id

      and s.purpose =
        'ASSIGNMENT'
  )
  || '|'
  || (
    select count(*)
    from haulvia.offer_reservations r
    where r.id =
      c.reservation_id

      and r.status =
        'CONVERTED'
  )
  || '|'
  || (
    select p.state::text
    from haulvia.shipment_customer_payment_axes p
    where p.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select m.state::text
    from haulvia.shipment_marketplace_axes m
    where m.shipment_id =
      c.shipment_id
  )
  || '|'
  || (
    select s.shipment_state::text
    from haulvia.shipments s
    where s.id =
      c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_executions re
    where re.shipment_id =
      c.shipment_id
  )

from c;
"@


    Write-Host "P2F11_FINAL_STATE|$p2f11FinalState"


    if (
        $p2f11FinalState -ne
        "1|1|1|1|SECURED|CLOSED|DRIVER_ASSIGNED|0"
    ) {
        throw "P2F-11 final canonical state is invalid."
    }


    # ========================================================================
    # P2F-12 - Stop-execution race
    #
    # Two valid first-arrival commands leave the same shipment version and
    # route-execution version. The dispatcher locks shipment first, so the
    # ordinary losing race actor is expected to fail STALE_SHIPMENT_VERSION.
    #
    # A second probe then uses the new/current shipment version but the old
    # route-execution version. That must fail STALE_ROUTE_EXECUTION_VERSION,
    # proving the route-position version boundary independently.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-12 START ROUTE FIXTURE ================"
    Write-Host ""


    # ========================================================================
    # Move the authoritative P2F-11 assignment into route execution exactly
    # once. This gives P2F-12 a real production-created ACTIVE execution,
    # EN_ROUTE first pickup, active attempt and record_version=1.
    # ========================================================================

    $p2f12StartRoute =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 start route" `
            -Sql @"
select
  haulvia_command.command_start_route(
    jsonb_build_object(
      'commandId',
        'f2120000-0000-0000-0000-000000000070',

      'idempotencyKey',
        'p2f12-start-route',

      'requestHash',
        repeat('c', 64),

      'shipmentId',
        s.id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        a.route_version_id,

      'expectedAssignmentId',
        a.id,

      'actorProfileId',
        d.profile_id,

      'occurredAt',
        clock_timestamp(),

      'etaAt',
        clock_timestamp() + interval '15 minutes'
    )
  )
from haulvia.shipments s
join haulvia.assignments a
  on a.shipment_id = s.id
 and a.status = 'ACTIVE'
join haulvia.drivers d
  on d.id = a.driver_id
where s.id = (
  select shipment_id
  from p2f_test.assignment_race_context
  where race_key = 'P2F-11'
);
"@


    Write-Host "P2F12_START_ROUTE|$p2f12StartRoute"


    if (
        $p2f12StartRoute -notmatch
        '"shipmentState"\s*:\s*"ROUTE_IN_PROGRESS"'
    ) {
        throw "P2F-12 startRoute did not establish ROUTE_IN_PROGRESS."
    }


    # ========================================================================
    # Retained race context
    # ========================================================================

    Invoke-PsqlText `
        -Database $TargetDatabase `
        -Label "P2F-12 race context" `
        -Sql @"
create table p2f_test.stop_execution_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  assignment_id uuid not null,
  route_version_id uuid not null,
  route_execution_id uuid not null,
  stop_execution_id uuid not null,
  stop_attempt_id uuid not null,
  driver_profile_id uuid not null,
  pre_shipment_version bigint not null,
  pre_execution_version bigint not null,
  captured_at_a timestamptz not null,
  captured_at_b timestamptz not null,
  input_a jsonb not null,
  input_b jsonb not null
);

with base as (
  select
    s.id as shipment_id,
    a.id as assignment_id,
    a.route_version_id,
    re.id as route_execution_id,
    se.id as stop_execution_id,
    sa.id as stop_attempt_id,
    d.profile_id as driver_profile_id,
    s.lock_version as shipment_version,
    re.record_version as execution_version
  from haulvia.shipments s
  join haulvia.assignments a
    on a.shipment_id = s.id
   and a.status = 'ACTIVE'
  join haulvia.drivers d
    on d.id = a.driver_id
  join haulvia.route_executions re
    on re.shipment_id = s.id
   and re.assignment_id = a.id
   and re.state = 'ACTIVE'
  join haulvia.stop_executions se
    on se.id = re.active_stop_execution_id
  join haulvia.route_stops rs
    on rs.id = se.route_stop_id
   and rs.sequence_no = 1
   and rs.stop_type = 'PICKUP'
  join haulvia.stop_attempts sa
    on sa.stop_execution_id = se.id
   and sa.attempt_no = se.current_attempt_no
  where s.id = (
    select shipment_id
    from p2f_test.assignment_race_context
    where race_key = 'P2F-11'
  )
),
times as (
  select
    b.*,
    clock_timestamp() as captured_a,
    clock_timestamp() + interval '1 second' as captured_b
  from base b
)
insert into p2f_test.stop_execution_race_context (
  race_key,
  shipment_id,
  assignment_id,
  route_version_id,
  route_execution_id,
  stop_execution_id,
  stop_attempt_id,
  driver_profile_id,
  pre_shipment_version,
  pre_execution_version,
  captured_at_a,
  captured_at_b,
  input_a,
  input_b
)
select
  'P2F-12',
  t.shipment_id,
  t.assignment_id,
  t.route_version_id,
  t.route_execution_id,
  t.stop_execution_id,
  t.stop_attempt_id,
  t.driver_profile_id,
  t.shipment_version,
  t.execution_version,
  t.captured_a,
  t.captured_b,

  jsonb_build_object(
    'commandId',
      'f2120000-0000-0000-0000-000000000081',

    'idempotencyKey',
      'p2f12-race-a',

    'requestHash',
      repeat('a', 64),

    'shipmentId',
      t.shipment_id,

    'expectedShipmentVersion',
      t.shipment_version,

    'expectedRouteVersionId',
      t.route_version_id,

    'expectedAssignmentId',
      t.assignment_id,

    'expectedRouteExecutionId',
      t.route_execution_id,

    'expectedRouteExecutionVersion',
      t.execution_version,

    'expectedStopExecutionId',
      t.stop_execution_id,

    'actorProfileId',
      t.driver_profile_id,

    'latitude',
      52.1332,

    'longitude',
      -106.6700,

    'accuracyM',
      5,

    'capturedAt',
      t.captured_a,

    'waitingFreeUntil',
      t.captured_a + interval '10 minutes',

    'gpsExceptionReason',
      'P2F-12 controlled GPS exception actor A',

    'gpsExceptionEvidence',
      jsonb_build_object(
        'testDomain', 'P2F-12',
        'actor', 'A'
      )
  ),

  jsonb_build_object(
    'commandId',
      'f2120000-0000-0000-0000-000000000082',

    'idempotencyKey',
      'p2f12-race-b',

    'requestHash',
      repeat('b', 64),

    'shipmentId',
      t.shipment_id,

    'expectedShipmentVersion',
      t.shipment_version,

    'expectedRouteVersionId',
      t.route_version_id,

    'expectedAssignmentId',
      t.assignment_id,

    'expectedRouteExecutionId',
      t.route_execution_id,

    'expectedRouteExecutionVersion',
      t.execution_version,

    'expectedStopExecutionId',
      t.stop_execution_id,

    'actorProfileId',
      t.driver_profile_id,

    'latitude',
      52.1332,

    'longitude',
      -106.6700,

    'accuracyM',
      5,

    'capturedAt',
      t.captured_b,

    'waitingFreeUntil',
      t.captured_b + interval '10 minutes',

    'gpsExceptionReason',
      'P2F-12 controlled GPS exception actor B',

    'gpsExceptionEvidence',
      jsonb_build_object(
        'testDomain', 'P2F-12',
        'actor', 'B'
      )
  )
from times t;
"@


    $p2f12PreRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 pre-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
      and (
        e.idempotency_key like 'p2f12-race-a:%'
        or e.idempotency_key like 'p2f12-race-b:%'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F12_PRE_RACE|$p2f12PreRace"


    if (
        $p2f12PreRace -ne
        "10|1|EN_ROUTE|EN_ROUTE|ACTIVE|CONFIRM_ARRIVAL_AT_FIRST_PICKUP|0|1"
    ) {
        throw "P2F-12 fixture does not have the expected route/stop position."
    }


    # ========================================================================
    # Separate PostgreSQL actor scripts
    # ========================================================================

    $p2f12GateFile =
        Join-Path $TempRoot "p2f12-gate.sql"

    $p2f12GateOut =
        Join-Path $TempRoot "p2f12-gate.out.txt"

    $p2f12GateErr =
        Join-Path $TempRoot "p2f12-gate.err.txt"

    $p2f12ActorAFile =
        Join-Path $TempRoot "p2f12-actor-a.sql"

    $p2f12ActorAOut =
        Join-Path $TempRoot "p2f12-actor-a.out.txt"

    $p2f12ActorAErr =
        Join-Path $TempRoot "p2f12-actor-a.err.txt"

    $p2f12ActorAExitFile =
        Join-Path $TempRoot "p2f12-actor-a.exit.txt"

    $p2f12ActorBFile =
        Join-Path $TempRoot "p2f12-actor-b.sql"

    $p2f12ActorBOut =
        Join-Path $TempRoot "p2f12-actor-b.out.txt"

    $p2f12ActorBErr =
        Join-Path $TempRoot "p2f12-actor-b.err.txt"

    $p2f12ActorBExitFile =
        Join-Path $TempRoot "p2f12-actor-b.exit.txt"


    Write-Utf8NoBom `
        -Path $p2f12GateFile `
        -Text (
            @"
set application_name = 'p2f12_gate';

select pg_advisory_lock(
  212,
  12
);

\echo P2F12_GATE_HELD

select pg_sleep(300);
"@.Trim() +
            "`r`n"
        )


    Write-Utf8NoBom `
        -Path $p2f12ActorAFile `
        -Text (
            @"
set application_name = 'p2f12_actor_a';

select pg_advisory_lock_shared(
  212,
  12
);

\echo P2F12_GATE_ACQUIRED_A

select
  'P2F12_RESULT_A|'
  ||
  haulvia_command.command_confirm_arrival_at_first_pickup(
    (
      select input_a
      from p2f_test.stop_execution_race_context
      where race_key = 'P2F-12'
    )
  )::text;
"@.Trim() +
            "`r`n"
        )


    Write-Utf8NoBom `
        -Path $p2f12ActorBFile `
        -Text (
            @"
set application_name = 'p2f12_actor_b';

select pg_advisory_lock_shared(
  212,
  12
);

\echo P2F12_GATE_ACQUIRED_B

select
  'P2F12_RESULT_B|'
  ||
  haulvia_command.command_confirm_arrival_at_first_pickup(
    (
      select input_b
      from p2f_test.stop_execution_race_context
      where race_key = 'P2F-12'
    )
  )::text;
"@.Trim() +
            "`r`n"
        )


    # ========================================================================
    # Start synchronization
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-12 START SYNCHRONIZATION ================"
    Write-Host ""


    $p2f12GateProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f12GateFile `
            -StdOutFile $p2f12GateOut `
            -StdErrFile $p2f12GateErr


    # ========================================================================
    # Observe the live synchronization gate through PostgreSQL itself.
    #
    # Do not inspect redirected stdout while the gate process is alive.
    # On Windows the process legitimately retains the output-file handle until
    # finalization, so Read-WholeFile is reserved for post-WaitForExit evidence.
    #
    # A gate is considered established only when exactly one p2f12_gate backend
    # owns at least one granted advisory lock in this disposable database.
    # ========================================================================

    $p2f12GateDeadline =
        [DateTime]::UtcNow.AddSeconds(15)

    $p2f12GateHeld =
        $false

    $p2f12GateHolderCount =
        "0"


    while (
        -not $p2f12GateHeld -and
        [DateTime]::UtcNow -lt $p2f12GateDeadline
    ) {

        $p2f12GateHolderCount =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-12 live gate observation" `
                -Sql @"
select
  count(
    distinct a.pid
  )::text

from pg_stat_activity a

join pg_locks l
  on l.pid =
    a.pid

where a.datname =
    current_database()

  and a.application_name =
    'p2f12_gate'

  and l.locktype =
    'advisory'

  and l.granted;
"@


        if ($p2f12GateHolderCount -eq "1") {

            $p2f12GateHeld =
                $true
        }
        else {

            Start-Sleep `
                -Milliseconds 100
        }
    }


    if (-not $p2f12GateHeld) {
        throw (
            "P2F-12 start gate was not observed as held. " +
            "Granted advisory-lock holders observed: " +
            $p2f12GateHolderCount
        )
    }


    Write-Host "P2F12_GATE_HELD|1"


    $p2f12ActorAProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f12ActorAFile `
            -StdOutFile $p2f12ActorAOut `
            -StdErrFile $p2f12ActorAErr `
            -ExitCodeFile $p2f12ActorAExitFile


    $p2f12ActorBProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f12ActorBFile `
            -StdOutFile $p2f12ActorBOut `
            -StdErrFile $p2f12ActorBErr `
            -ExitCodeFile $p2f12ActorBExitFile


    # ========================================================================
    # Both actors must really be waiting on the advisory barrier
    # ========================================================================

    $p2f12WaitDeadline =
        [DateTime]::UtcNow.AddSeconds(15)

    $p2f12Waiters =
        "0"

    $p2f12BothWaiting =
        $false


    while (
        -not $p2f12BothWaiting -and
        [DateTime]::UtcNow -lt $p2f12WaitDeadline
    ) {

        $p2f12Waiters =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-12 waiter count" `
                -Sql @"
select count(*)::text
from pg_stat_activity
where datname = current_database()
  and application_name in (
    'p2f12_actor_a',
    'p2f12_actor_b'
  )
  and wait_event_type = 'Lock'
  and wait_event = 'advisory';
"@


        if ($p2f12Waiters -eq "2") {
            $p2f12BothWaiting =
                $true
        }
        else {
            Start-Sleep -Milliseconds 100
        }
    }


    Write-Host "P2F12_WAITERS|$p2f12Waiters"


    if (-not $p2f12BothWaiting) {
        throw "P2F-12 did not observe both actor sessions waiting."
    }


    # ========================================================================
    # Safe gate release: resolve exact backend first, terminate separately.
    # ========================================================================

    $p2f12GateBackendPid =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 gate PID" `
            -Sql @"
select pid::text
from pg_stat_activity
where datname = current_database()
  and application_name = 'p2f12_gate'
  and pid <> pg_backend_pid()
order by pid
limit 1;
"@


    if (
        [string]::IsNullOrWhiteSpace(
            $p2f12GateBackendPid
        ) -or
        $p2f12GateBackendPid -notmatch '^[0-9]+$'
    ) {
        throw "Unable to resolve exact P2F-12 gate backend PID."
    }


    $p2f12GateReleasedUtc =
        [DateTime]::UtcNow


    $p2f12GateRelease =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 gate release" `
            -Sql @"
select pg_terminate_backend(
  $p2f12GateBackendPid
);
"@


    if ($p2f12GateRelease -ne "t") {
        throw "Unable to release P2F-12 start gate."
    }


    Write-Host (
        "P2F12_GATE_RELEASED_UTC|" +
        $p2f12GateReleasedUtc.ToString("o")
    )


    # ========================================================================
    # Capture completion ordering without depending on Process.ExitCode
    # ========================================================================

    $p2f12Completion =
        [System.Collections.Generic.List[object]]::new()

    $p2f12Seen =
        @{}

    $p2f12CompletionDeadline =
        [DateTime]::UtcNow.AddSeconds(30)


    while (
        $p2f12Completion.Count -lt 2 -and
        [DateTime]::UtcNow -lt $p2f12CompletionDeadline
    ) {

        foreach ($actor in @(
            [pscustomobject]@{
                Name = "A"
                Process = $p2f12ActorAProcess
            },
            [pscustomobject]@{
                Name = "B"
                Process = $p2f12ActorBProcess
            }
        )) {

            if (
                -not $p2f12Seen.ContainsKey(
                    $actor.Name
                ) -and
                $actor.Process.HasExited
            ) {

                $p2f12Seen[$actor.Name] =
                    $true

                $p2f12Completion.Add(
                    [pscustomobject]@{
                        Name =
                            $actor.Name

                        CompletedUtc =
                            [DateTime]::UtcNow
                    }
                )
            }
        }


        if ($p2f12Completion.Count -lt 2) {
            Start-Sleep -Milliseconds 25
        }
    }


    if ($p2f12Completion.Count -ne 2) {
        throw "P2F-12 actors did not both complete within the deadline."
    }


    $p2f12ActorAProcess.WaitForExit()
    $p2f12ActorBProcess.WaitForExit()
    $p2f12GateProcess.WaitForExit()


    $p2f12ActorAExitText =
        (
            Read-WholeFile `
                $p2f12ActorAExitFile
        ).Trim()

    $p2f12ActorBExitText =
        (
            Read-WholeFile `
                $p2f12ActorBExitFile
        ).Trim()


    if (
        $p2f12ActorAExitText -notmatch '^-?[0-9]+$' -or
        $p2f12ActorBExitText -notmatch '^-?[0-9]+$'
    ) {
        throw "P2F-12 actor exit-code sidecar is invalid."
    }


    $p2f12ActorAExit =
        [int]$p2f12ActorAExitText

    $p2f12ActorBExit =
        [int]$p2f12ActorBExitText


    Write-Host (
        "P2F12_PROCESS_OUTPUT_FINALIZED|" +
        $p2f12ActorAExit +
        "|" +
        $p2f12ActorBExit
    )


    foreach ($item in $p2f12Completion) {

        $exit =
            if ($item.Name -eq "A") {
                $p2f12ActorAExit
            }
            else {
                $p2f12ActorBExit
            }


        Write-Host (
            "P2F12_COMPLETION|" +
            $item.Name +
            "|" +
            $item.CompletedUtc.ToString("o") +
            "|" +
            $exit
        )
    }


    # ========================================================================
    # Read independent actor evidence
    # ========================================================================

    $p2f12ActorAStdout =
        Read-WholeFile $p2f12ActorAOut

    $p2f12ActorAStderr =
        Read-WholeFile $p2f12ActorAErr

    $p2f12ActorBStdout =
        Read-WholeFile $p2f12ActorBOut

    $p2f12ActorBStderr =
        Read-WholeFile $p2f12ActorBErr


    Write-Host ""
    Write-Host "================ P2F-12 ACTOR CLASSIFICATION ================"
    Write-Host ""

    Write-Host "Actor A exit: $p2f12ActorAExit"
    Write-Host "Actor B exit: $p2f12ActorBExit"

    Write-Host "---- Actor A stdout ----"
    Write-Host $p2f12ActorAStdout

    Write-Host "---- Actor A stderr ----"
    Write-Host $p2f12ActorAStderr

    Write-Host "---- Actor B stdout ----"
    Write-Host $p2f12ActorBStdout

    Write-Host "---- Actor B stderr ----"
    Write-Host $p2f12ActorBStderr


    if (
        $p2f12ActorAExit -eq 0 -and
        $p2f12ActorBExit -ne 0
    ) {

        $p2f12Winner =
            "A"

        $p2f12Loser =
            "B"

        $p2f12WinnerInputColumn =
            "input_a"

        $p2f12LoserKey =
            "p2f12-race-b"

        $p2f12LoserCapturedColumn =
            "captured_at_b"

        $p2f12LoserText =
            $p2f12ActorBStdout +
            "`n" +
            $p2f12ActorBStderr
    }
    elseif (
        $p2f12ActorBExit -eq 0 -and
        $p2f12ActorAExit -ne 0
    ) {

        $p2f12Winner =
            "B"

        $p2f12Loser =
            "A"

        $p2f12WinnerInputColumn =
            "input_b"

        $p2f12LoserKey =
            "p2f12-race-a"

        $p2f12LoserCapturedColumn =
            "captured_at_a"

        $p2f12LoserText =
            $p2f12ActorAStdout +
            "`n" +
            $p2f12ActorAStderr
    }
    else {
        throw "P2F-12 did not produce exactly one successful actor."
    }


    if (
        -not $p2f12LoserText.Contains(
            "STALE_SHIPMENT_VERSION"
        )
    ) {
        throw "P2F-12 race loser did not fail STALE_SHIPMENT_VERSION."
    }


    Write-Host "P2F12_WINNER|$p2f12Winner"
    Write-Host "P2F12_LOSER|$p2f12Loser|STALE_SHIPMENT_VERSION"


    # ========================================================================
    # Canonical post-race position and durable side effects
    # ========================================================================

    $p2f12PostRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 post-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
      and (
        e.idempotency_key like 'p2f12-race-a:%'
        or e.idempotency_key like 'p2f12-race-b:%'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
      and u.captured_at in (
        c.captured_at_a,
        c.captured_at_b
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id = c.shipment_id
      and j.job_code = 'STOP_WAITING_GRACE_EXPIRES'
      and (
        j.idempotency_key =
          c.shipment_id::text ||
          ':p2f12-race-a:first-pickup-waiting'
        or
        j.idempotency_key =
          c.shipment_id::text ||
          ':p2f12-race-b:first-pickup-waiting'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'confirmArrivalAtFirstPickup'
      and e.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'DRIVER_ARRIVED_FIRST_PICKUP'
      and (
        n.idempotency_key =
          c.shipment_id::text ||
          ':p2f12-race-a:first-pickup-arrival'
        or
        n.idempotency_key =
          c.shipment_id::text ||
          ':p2f12-race-b:first-pickup-arrival'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'confirmArrivalAtFirstPickup'
      and a.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'confirmArrivalAtFirstPickup'
      and i.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
      and i.status = 'COMPLETED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements m
    where m.shipment_id = c.shipment_id
  )
  || '|'
  || s.shipment_state
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F12_POST_RACE|$p2f12PostRace"


    if (
        $p2f12PostRace -ne
        "11|2|ARRIVED|ARRIVED|ACTIVE|START_FIRST_PICKUP_SERVICE|2|1|1|1|1|1|1|0|ROUTE_IN_PROGRESS"
    ) {
        throw "P2F-12 post-race route/stop state is invalid."
    }


    # ========================================================================
    # Winner durable binding
    # ========================================================================

    $p2f12WinnerBinding =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 winner binding" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
),
counts as (
  select
    (
      select count(*)
      from haulvia.stop_evidence e
      where e.stop_attempt_id = c.stop_attempt_id
        and e.idempotency_key like 'p2f12-race-a:%'
    ) as a_count,
    (
      select count(*)
      from haulvia.stop_evidence e
      where e.stop_attempt_id = c.stop_attempt_id
        and e.idempotency_key like 'p2f12-race-b:%'
    ) as b_count
  from c
)
select
  case
    when a_count = 2 and b_count = 0 then 'A'
    when b_count = 2 and a_count = 0 then 'B'
    else 'INVALID'
  end
from counts;
"@


    Write-Host "P2F12_WINNER_BINDING|$p2f12WinnerBinding"


    if ($p2f12WinnerBinding -ne $p2f12Winner) {
        throw "P2F-12 committed evidence does not bind to the winning actor."
    }


    # ========================================================================
    # Exact winner replay
    # ========================================================================

    $p2f12Replay =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 winner replay" `
            -Sql @"
select
  haulvia_command.command_confirm_arrival_at_first_pickup(
    (
      select $($p2f12WinnerInputColumn)
      from p2f_test.stop_execution_race_context
      where race_key = 'P2F-12'
    )
  );
"@


    Write-Host "P2F12_REPLAY|$p2f12Replay"


    if (
        $p2f12Replay -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-12 exact winner replay did not return replayed=true."
    }


    $p2f12ReplayState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 replay state" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
      and (
        e.idempotency_key like 'p2f12-race-a:%'
        or e.idempotency_key like 'p2f12-race-b:%'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
      and u.captured_at in (
        c.captured_at_a,
        c.captured_at_b
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id = c.shipment_id
      and j.job_code = 'STOP_WAITING_GRACE_EXPIRES'
      and j.idempotency_key like
        c.shipment_id::text || ':p2f12-race-%:first-pickup-waiting'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'confirmArrivalAtFirstPickup'
      and e.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'DRIVER_ARRIVED_FIRST_PICKUP'
      and n.idempotency_key like
        c.shipment_id::text || ':p2f12-race-%:first-pickup-arrival'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'confirmArrivalAtFirstPickup'
      and a.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'confirmArrivalAtFirstPickup'
      and i.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
from c;
"@


    Write-Host "P2F12_REPLAY_STATE|$p2f12ReplayState"


    if ($p2f12ReplayState -ne "2|1|1|1|1|1|1") {
        throw "P2F-12 replay duplicated arrival facts."
    }


    # ========================================================================
    # Same key + different hash
    # ========================================================================

    $p2f12DifferentHash =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
select
  haulvia_command.command_confirm_arrival_at_first_pickup(
    (
      select $($p2f12WinnerInputColumn)
      from p2f_test.stop_execution_race_context
      where race_key = 'P2F-12'
    )
    ||
    jsonb_build_object(
      'requestHash',
      repeat('f', 64)
    )
  );
"@


    if (
        $p2f12DifferentHash.ExitCode -eq 0 -or
        -not $p2f12DifferentHash.Text.Contains(
            "IDEMPOTENCY_KEY_REUSED"
        )
    ) {

        Write-Host $p2f12DifferentHash.Text

        throw "P2F-12 same-key/different-hash reuse did not fail closed."
    }


    Write-Host "P2F12_IDEMPOTENCY_CONFLICT|IDEMPOTENCY_KEY_REUSED"


    # ========================================================================
    # Race loser must leave zero transaction residue
    # ========================================================================

    $p2f12FailureResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 loser residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'confirmArrivalAtFirstPickup'
      and i.idempotency_key = '${p2f12LoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.idempotency_key like '${p2f12LoserKey}:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
      and u.captured_at = c.$($p2f12LoserCapturedColumn)
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id = c.shipment_id
      and j.idempotency_key =
        c.shipment_id::text ||
        ':${p2f12LoserKey}:first-pickup-waiting'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'confirmArrivalAtFirstPickup'
      and e.idempotency_key = '${p2f12LoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'DRIVER_ARRIVED_FIRST_PICKUP'
      and n.idempotency_key =
        c.shipment_id::text ||
        ':${p2f12LoserKey}:first-pickup-arrival'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'confirmArrivalAtFirstPickup'
      and a.idempotency_key = '${p2f12LoserKey}'
  )
from c;
"@


    Write-Host "P2F12_FAILURE_RESIDUE|$p2f12FailureResidue"


    if ($p2f12FailureResidue -ne "0|0|0|0|0|0|0") {
        throw "P2F-12 race loser left partial stop-execution facts."
    }


    # ========================================================================
    # Explicit stale route-execution-version probe
    #
    # The shipment version is deliberately current. Only
    # expectedRouteExecutionVersion remains at the pre-race value (1).
    # The command therefore must reach lock_route_execution and reject there.
    # ========================================================================

    $p2f12StaleRouteProbe =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  haulvia_command.command_confirm_arrival_at_first_pickup(
    jsonb_build_object(
      'commandId',
        'f2120000-0000-0000-0000-000000000090',

      'idempotencyKey',
        'p2f12-stale-route',

      'requestHash',
        repeat('d', 64),

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        c.pre_execution_version,

      'expectedStopExecutionId',
        c.stop_execution_id,

      'actorProfileId',
        c.driver_profile_id,

      'latitude',
        52.1332,

      'longitude',
        -106.6700,

      'accuracyM',
        5,

      'capturedAt',
        c.captured_at_b + interval '2 seconds',

      'waitingFreeUntil',
        c.captured_at_b + interval '12 minutes',

      'gpsExceptionReason',
        'P2F-12 explicit stale route execution probe',

      'gpsExceptionEvidence',
        jsonb_build_object(
          'testDomain', 'P2F-12',
          'probe', 'STALE_ROUTE_EXECUTION_VERSION'
        )
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id;
"@


    if (
        $p2f12StaleRouteProbe.ExitCode -eq 0 -or
        -not $p2f12StaleRouteProbe.Text.Contains(
            "STALE_ROUTE_EXECUTION_VERSION"
        )
    ) {

        Write-Host $p2f12StaleRouteProbe.Text

        throw "P2F-12 stale route-execution-version probe did not fail correctly."
    }


    Write-Host "P2F12_STALE_ROUTE_VERSION|STALE_ROUTE_EXECUTION_VERSION"


    # ========================================================================
    # Probe must also roll back completely
    # ========================================================================

    $p2f12ProbeResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 stale-route probe residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'confirmArrivalAtFirstPickup'
      and i.idempotency_key = 'p2f12-stale-route'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.idempotency_key like 'p2f12-stale-route:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
      and u.captured_at =
        c.captured_at_b + interval '2 seconds'
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id = c.shipment_id
      and j.idempotency_key =
        c.shipment_id::text ||
        ':p2f12-stale-route:first-pickup-waiting'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'confirmArrivalAtFirstPickup'
      and e.idempotency_key = 'p2f12-stale-route'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.idempotency_key =
        c.shipment_id::text ||
        ':p2f12-stale-route:first-pickup-arrival'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'confirmArrivalAtFirstPickup'
      and a.idempotency_key = 'p2f12-stale-route'
  )
from c;
"@


    Write-Host "P2F12_STALE_ROUTE_RESIDUE|$p2f12ProbeResidue"


    if ($p2f12ProbeResidue -ne "0|0|0|0|0|0|0") {
        throw "P2F-12 stale route-version probe left partial facts."
    }


    # ========================================================================
    # Final canonical stop/execution position
    # ========================================================================

    $p2f12FinalState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-12 final state" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
      and (
        e.idempotency_key like 'p2f12-race-a:%'
        or e.idempotency_key like 'p2f12-race-b:%'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
      and u.captured_at in (
        c.captured_at_a,
        c.captured_at_b
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_jobs j
    where j.shipment_id = c.shipment_id
      and j.job_code = 'STOP_WAITING_GRACE_EXPIRES'
      and j.idempotency_key like
        c.shipment_id::text || ':p2f12-race-%:first-pickup-waiting'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'confirmArrivalAtFirstPickup'
      and e.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'DRIVER_ARRIVED_FIRST_PICKUP'
      and n.idempotency_key like
        c.shipment_id::text || ':p2f12-race-%:first-pickup-arrival'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'confirmArrivalAtFirstPickup'
      and a.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'confirmArrivalAtFirstPickup'
      and i.idempotency_key in (
        'p2f12-race-a',
        'p2f12-race-b'
      )
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements m
    where m.shipment_id = c.shipment_id
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F12_FINAL_STATE|$p2f12FinalState"


    if (
        $p2f12FinalState -ne
        "11|2|ARRIVED|ARRIVED|START_FIRST_PICKUP_SERVICE|2|1|1|1|1|1|1|0"
    ) {
        throw "P2F-12 final canonical stop/execution state is invalid."
    }



    # ========================================================================
    # P2F-13A - First-custody LOAD race
    #
    # Internal custody-domain gate only.
    #
    # This block DOES NOT complete P2F-13 and DOES NOT advance the official
    # concurrency-domain count. P2F-13B must still exercise the UNLOAD,
    # negative-balance and route-resolution boundaries.
    #
    # Handoff from authoritative P2F-12:
    #   shipment lock_version = 11
    #   route execution record_version = 2
    #   first pickup stop/attempt = ARRIVED
    #   next action = START_FIRST_PICKUP_SERVICE
    #
    # B04 and B05 establish a production-created EVIDENCE_PENDING first pickup.
    # Two separate EVIDENCE_REVIEWER commands then race B06 verifyFirstPickup.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-13A FIRST-CUSTODY FIXTURE ================"
    Write-Host ""


    # ========================================================================
    # Fixture precondition: the first pickup has exactly one allocation.
    #
    # This keeps the concurrency assertion focused on exactly-one custody
    # mutation rather than conflating the race with multi-allocation iteration.
    # Later custody-domain work remains responsible for the broader ledger.
    # ========================================================================

    $p2f13FirstAllocationCount =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A first-stop allocation count" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select count(*)::text
from c
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.cargo_allocations ca
  on ca.route_version_id = c.route_version_id
 and ca.pickup_stop_id = se.route_stop_id;
"@


    Write-Host "P2F13_FIRST_ALLOCATION_COUNT|$p2f13FirstAllocationCount"


    if ($p2f13FirstAllocationCount -ne "1") {
        throw "P2F-13A requires exactly one first-stop allocation in the race fixture."
    }


    # ========================================================================
    # B04: ARRIVED -> SERVICE_IN_PROGRESS
    # ========================================================================

    $p2f13StartService =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A start first pickup service" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
)
select
  haulvia_command.command_start_first_pickup_service(
    jsonb_build_object(
      'commandId',
        'f2130000-0000-0000-0000-000000000070',

      'idempotencyKey',
        'p2f13-start-service',

      'requestHash',
        repeat('4', 64),

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        re.record_version,

      'expectedStopExecutionId',
        c.stop_execution_id,

      'actorProfileId',
        c.driver_profile_id,

      'contactConfirmed',
        true,

      'locationConfirmed',
        true,

      'cargoAvailable',
        true,

      'occurredAt',
        clock_timestamp()
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_START_SERVICE|$p2f13StartService"


    if (
        $p2f13StartService -notmatch
        '"routeExecutionVersion"\s*:\s*3'
    ) {
        throw "P2F-13A B04 did not advance the execution to version 3."
    }


    # ========================================================================
    # B05: SERVICE_IN_PROGRESS -> EVIDENCE_PENDING
    #
    # Existing B02 arrival evidence already supplies GPS + TIMESTAMP.
    # Append PHOTO + QUANTITY + CONDITION + PIN, matching the approved
    # Block-B acceptance pattern.
    # ========================================================================

    $p2f13SubmitEvidence =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A submit first pickup evidence" `
            -Sql @"
with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
),
allocation as (
  select ca.*
  from c
  join haulvia.stop_executions se
    on se.id = c.stop_execution_id
  join haulvia.cargo_allocations ca
    on ca.route_version_id = c.route_version_id
   and ca.pickup_stop_id = se.route_stop_id
)
select
  haulvia_command.command_submit_first_pickup_evidence(
    jsonb_build_object(
      'commandId',
        'f2130000-0000-0000-0000-000000000071',

      'idempotencyKey',
        'p2f13-submit-evidence',

      'requestHash',
        repeat('5', 64),

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        re.record_version,

      'expectedStopExecutionId',
        c.stop_execution_id,

      'actorProfileId',
        c.driver_profile_id,

      'driverConfirmed',
        true,

      'releasingPersonName',
        'P2F-13 Test Sender',

      'occurredAt',
        clock_timestamp(),

      'evidence',
        jsonb_build_array(
          jsonb_build_object(
            'type',
              'PHOTO',

            'structuredValue',
              jsonb_build_object(
                'captureMode',
                  'STRUCTURED_TEST_PHOTO',

                'verified',
                  true,

                'purpose',
                  'P2F-13 first-pickup custody concurrency'
              ),

            'capturedAt',
              clock_timestamp()
          ),

          jsonb_build_object(
            'type',
              'QUANTITY',

            'structuredValue',
              jsonb_build_object(
                'quantity',
                  a.quantity,

                'unit',
                  a.quantity_unit
              ),

            'capturedAt',
              clock_timestamp()
          ),

          jsonb_build_object(
            'type',
              'CONDITION',

            'structuredValue',
              jsonb_build_object(
                'condition',
                  'GOOD'
              ),

            'capturedAt',
              clock_timestamp()
          ),

          jsonb_build_object(
            'type',
              'PIN',

            'structuredValue',
              jsonb_build_object(
                'verified',
                  true
              ),

            'capturedAt',
              clock_timestamp()
          )
        )
    )
  )
from c
cross join allocation a
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_SUBMIT_EVIDENCE|$p2f13SubmitEvidence"


    if (
        $p2f13SubmitEvidence -notmatch
        '"routeExecutionVersion"\s*:\s*4'
    ) {
        throw "P2F-13A B05 did not advance the execution to version 4."
    }


    # ========================================================================
    # Race context
    # ========================================================================

    Invoke-PsqlText `
        -Database $TargetDatabase `
        -Label "P2F-13A LOAD race context" `
        -Sql @"
create table p2f_test.custody_load_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  assignment_id uuid not null,
  route_version_id uuid not null,
  route_execution_id uuid not null,
  stop_execution_id uuid not null,
  stop_attempt_id uuid not null,
  cargo_allocation_id uuid not null,
  driver_profile_id uuid not null,
  customer_profile_id uuid not null,
  pre_shipment_version bigint not null,
  pre_execution_version bigint not null,
  allocation_quantity numeric(14,3) not null,
  quantity_unit text not null,
  input_a jsonb not null,
  input_b jsonb not null
);

with c as (
  select *
  from p2f_test.stop_execution_race_context
  where race_key = 'P2F-12'
),
base as (
  select
    c.shipment_id,
    c.assignment_id,
    c.route_version_id,
    c.route_execution_id,
    c.stop_execution_id,
    c.stop_attempt_id,
    c.driver_profile_id,
    s.customer_profile_id,
    s.lock_version as shipment_version,
    re.record_version as execution_version,
    ca.id as cargo_allocation_id,
    ca.quantity as allocation_quantity,
    ca.quantity_unit
  from c
  join haulvia.shipments s
    on s.id = c.shipment_id
  join haulvia.route_executions re
    on re.id = c.route_execution_id
  join haulvia.stop_executions se
    on se.id = c.stop_execution_id
  join haulvia.cargo_allocations ca
    on ca.route_version_id = c.route_version_id
   and ca.pickup_stop_id = se.route_stop_id
)
insert into p2f_test.custody_load_race_context (
  race_key,
  shipment_id,
  assignment_id,
  route_version_id,
  route_execution_id,
  stop_execution_id,
  stop_attempt_id,
  cargo_allocation_id,
  driver_profile_id,
  customer_profile_id,
  pre_shipment_version,
  pre_execution_version,
  allocation_quantity,
  quantity_unit,
  input_a,
  input_b
)
select
  'P2F-13A',
  b.shipment_id,
  b.assignment_id,
  b.route_version_id,
  b.route_execution_id,
  b.stop_execution_id,
  b.stop_attempt_id,
  b.cargo_allocation_id,
  b.driver_profile_id,
  b.customer_profile_id,
  b.shipment_version,
  b.execution_version,
  b.allocation_quantity,
  b.quantity_unit,

  jsonb_build_object(
    'commandId',
      'f2130000-0000-0000-0000-000000000081',

    'idempotencyKey',
      'p2f13-load-a',

    'requestHash',
      repeat('a', 64),

    'shipmentId',
      b.shipment_id,

    'expectedShipmentVersion',
      b.shipment_version,

    'expectedRouteVersionId',
      b.route_version_id,

    'expectedAssignmentId',
      b.assignment_id,

    'expectedRouteExecutionId',
      b.route_execution_id,

    'expectedRouteExecutionVersion',
      b.execution_version,

    'expectedStopExecutionId',
      b.stop_execution_id,

    'workerAuthority',
      'EVIDENCE_REVIEWER',

    'reviewerLabel',
      'P2F-13 reviewer A',

    'loads',
      jsonb_build_array(
        jsonb_build_object(
          'cargoAllocationId',
            b.cargo_allocation_id,

          'quantity',
            b.allocation_quantity,

          'quantityUnit',
            b.quantity_unit,

          'occurredAt',
            clock_timestamp(),

          'evidenceBundle',
            jsonb_build_object(
              'stopAttemptId',
                b.stop_attempt_id,

              'race',
                'P2F-13A',

              'actor',
                'A'
            )
        )
      )
  ),

  jsonb_build_object(
    'commandId',
      'f2130000-0000-0000-0000-000000000082',

    'idempotencyKey',
      'p2f13-load-b',

    'requestHash',
      repeat('b', 64),

    'shipmentId',
      b.shipment_id,

    'expectedShipmentVersion',
      b.shipment_version,

    'expectedRouteVersionId',
      b.route_version_id,

    'expectedAssignmentId',
      b.assignment_id,

    'expectedRouteExecutionId',
      b.route_execution_id,

    'expectedRouteExecutionVersion',
      b.execution_version,

    'expectedStopExecutionId',
      b.stop_execution_id,

    'workerAuthority',
      'EVIDENCE_REVIEWER',

    'reviewerLabel',
      'P2F-13 reviewer B',

    'loads',
      jsonb_build_array(
        jsonb_build_object(
          'cargoAllocationId',
            b.cargo_allocation_id,

          'quantity',
            b.allocation_quantity,

          'quantityUnit',
            b.quantity_unit,

          'occurredAt',
            clock_timestamp(),

          'evidenceBundle',
            jsonb_build_object(
              'stopAttemptId',
                b.stop_attempt_id,

              'race',
                'P2F-13A',

              'actor',
                'B'
            )
        )
      )
  )
from base b;
"@


    $p2f13LoadPreRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A pre-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_custody_milestones m
    where m.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence_reviews r
    join haulvia.stop_evidence e
      on e.id = r.stop_evidence_id
    where e.stop_attempt_id = c.stop_attempt_id
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F13_LOAD_PRE_RACE|$p2f13LoadPreRace"


    if (
        $p2f13LoadPreRace -ne
        "13|4|EVIDENCE_PENDING|EVIDENCE_PENDING|VERIFY_FIRST_PICKUP|0|0|6|0"
    ) {
        throw "P2F-13A fixture is not at the expected first-custody boundary."
    }


    # ========================================================================
    # Separate PostgreSQL gate + actors
    # ========================================================================

    $p2f13LoadGateFile =
        Join-Path $TempRoot "p2f13-load-gate.sql"

    $p2f13LoadGateOut =
        Join-Path $TempRoot "p2f13-load-gate.out.txt"

    $p2f13LoadGateErr =
        Join-Path $TempRoot "p2f13-load-gate.err.txt"

    $p2f13LoadActorAFile =
        Join-Path $TempRoot "p2f13-load-actor-a.sql"

    $p2f13LoadActorAOut =
        Join-Path $TempRoot "p2f13-load-actor-a.out.txt"

    $p2f13LoadActorAErr =
        Join-Path $TempRoot "p2f13-load-actor-a.err.txt"

    $p2f13LoadActorAExitFile =
        Join-Path $TempRoot "p2f13-load-actor-a.exit.txt"

    $p2f13LoadActorBFile =
        Join-Path $TempRoot "p2f13-load-actor-b.sql"

    $p2f13LoadActorBOut =
        Join-Path $TempRoot "p2f13-load-actor-b.out.txt"

    $p2f13LoadActorBErr =
        Join-Path $TempRoot "p2f13-load-actor-b.err.txt"

    $p2f13LoadActorBExitFile =
        Join-Path $TempRoot "p2f13-load-actor-b.exit.txt"


    Write-Utf8NoBom `
        -Path $p2f13LoadGateFile `
        -Text (
            @"
set application_name = 'p2f13_load_gate';

select pg_advisory_lock(
  213,
  13
);

\echo P2F13_LOAD_GATE_ACQUIRED

select pg_sleep(300);
"@.Trim() +
            "`r`n"
        )


    Write-Utf8NoBom `
        -Path $p2f13LoadActorAFile `
        -Text (
            @"
set application_name = 'p2f13_load_actor_a';

select pg_advisory_lock_shared(
  213,
  13
);

\echo P2F13_LOAD_GATE_ACQUIRED_A

select
  'P2F13_LOAD_RESULT_A|'
  ||
  haulvia_command.command_verify_first_pickup(
    (
      select input_a
      from p2f_test.custody_load_race_context
      where race_key = 'P2F-13A'
    )
  )::text;
"@.Trim() +
            "`r`n"
        )


    Write-Utf8NoBom `
        -Path $p2f13LoadActorBFile `
        -Text (
            @"
set application_name = 'p2f13_load_actor_b';

select pg_advisory_lock_shared(
  213,
  13
);

\echo P2F13_LOAD_GATE_ACQUIRED_B

select
  'P2F13_LOAD_RESULT_B|'
  ||
  haulvia_command.command_verify_first_pickup(
    (
      select input_b
      from p2f_test.custody_load_race_context
      where race_key = 'P2F-13A'
    )
  )::text;
"@.Trim() +
            "`r`n"
        )


    Write-Host ""
    Write-Host "================ P2F-13A START SYNCHRONIZATION ================"
    Write-Host ""


    $p2f13LoadGateProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f13LoadGateFile `
            -StdOutFile $p2f13LoadGateOut `
            -StdErrFile $p2f13LoadGateErr


    # ========================================================================
    # Observe the live gate through PostgreSQL lock state.
    # ========================================================================

    $p2f13LoadGateDeadline =
        [DateTime]::UtcNow.AddSeconds(15)

    $p2f13LoadGateHeld =
        $false

    $p2f13LoadGateHolderCount =
        "0"


    while (
        -not $p2f13LoadGateHeld -and
        [DateTime]::UtcNow -lt $p2f13LoadGateDeadline
    ) {

        $p2f13LoadGateHolderCount =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-13A live gate observation" `
                -Sql @"
select
  count(
    distinct a.pid
  )::text
from pg_stat_activity a
join pg_locks l
  on l.pid = a.pid
where a.datname = current_database()
  and a.application_name = 'p2f13_load_gate'
  and l.locktype = 'advisory'
  and l.granted;
"@


        if ($p2f13LoadGateHolderCount -eq "1") {
            $p2f13LoadGateHeld =
                $true
        }
        else {
            Start-Sleep -Milliseconds 100
        }
    }


    if (-not $p2f13LoadGateHeld) {
        throw (
            "P2F-13A LOAD gate was not observed as held. " +
            "Granted holders: " +
            $p2f13LoadGateHolderCount
        )
    }


    Write-Host "P2F13_LOAD_GATE_HELD|1"


    $p2f13LoadActorAProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f13LoadActorAFile `
            -StdOutFile $p2f13LoadActorAOut `
            -StdErrFile $p2f13LoadActorAErr `
            -ExitCodeFile $p2f13LoadActorAExitFile


    $p2f13LoadActorBProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f13LoadActorBFile `
            -StdOutFile $p2f13LoadActorBOut `
            -StdErrFile $p2f13LoadActorBErr `
            -ExitCodeFile $p2f13LoadActorBExitFile


    # ========================================================================
    # Both actors must be genuinely waiting on the barrier.
    # ========================================================================

    $p2f13LoadWaitDeadline =
        [DateTime]::UtcNow.AddSeconds(15)

    $p2f13LoadWaiters =
        "0"

    $p2f13LoadBothWaiting =
        $false


    while (
        -not $p2f13LoadBothWaiting -and
        [DateTime]::UtcNow -lt $p2f13LoadWaitDeadline
    ) {

        $p2f13LoadWaiters =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-13A waiter count" `
                -Sql @"
select count(*)::text
from pg_stat_activity
where datname = current_database()
  and application_name in (
    'p2f13_load_actor_a',
    'p2f13_load_actor_b'
  )
  and wait_event_type = 'Lock'
  and wait_event = 'advisory';
"@


        if ($p2f13LoadWaiters -eq "2") {
            $p2f13LoadBothWaiting =
                $true
        }
        else {
            Start-Sleep -Milliseconds 100
        }
    }


    Write-Host "P2F13_LOAD_WAITERS|$p2f13LoadWaiters"


    if (-not $p2f13LoadBothWaiting) {
        throw "P2F-13A did not observe both LOAD actors waiting."
    }


    # ========================================================================
    # Exact gate backend resolution/release.
    # ========================================================================

    $p2f13LoadGateBackendPid =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A gate PID" `
            -Sql @"
select pid::text
from pg_stat_activity
where datname = current_database()
  and application_name = 'p2f13_load_gate'
  and pid <> pg_backend_pid()
order by pid
limit 1;
"@


    if (
        [string]::IsNullOrWhiteSpace(
            $p2f13LoadGateBackendPid
        ) -or
        $p2f13LoadGateBackendPid -notmatch '^[0-9]+$'
    ) {
        throw "Unable to resolve exact P2F-13A gate backend."
    }


    $p2f13LoadGateRelease =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A gate release" `
            -Sql @"
select pg_terminate_backend(
  $p2f13LoadGateBackendPid
);
"@


    if ($p2f13LoadGateRelease -ne "t") {
        throw "Unable to release the P2F-13A LOAD gate."
    }


    Write-Host "P2F13_LOAD_GATE_RELEASED|1"


    # ========================================================================
    # Wait for both actors before consuming their redirected files.
    # ========================================================================

    $p2f13LoadCompletionDeadline =
        [DateTime]::UtcNow.AddSeconds(30)


    while (
        (
            -not $p2f13LoadActorAProcess.HasExited -or
            -not $p2f13LoadActorBProcess.HasExited
        ) -and
        [DateTime]::UtcNow -lt $p2f13LoadCompletionDeadline
    ) {

        Start-Sleep -Milliseconds 25
    }


    if (
        -not $p2f13LoadActorAProcess.HasExited -or
        -not $p2f13LoadActorBProcess.HasExited
    ) {
        throw "P2F-13A LOAD actors did not both finish within the deadline."
    }


    $p2f13LoadActorAProcess.WaitForExit()
    $p2f13LoadActorBProcess.WaitForExit()
    $p2f13LoadGateProcess.WaitForExit()


    $p2f13LoadActorAExitText =
        (
            Read-WholeFile `
                $p2f13LoadActorAExitFile
        ).Trim()

    $p2f13LoadActorBExitText =
        (
            Read-WholeFile `
                $p2f13LoadActorBExitFile
        ).Trim()


    if (
        $p2f13LoadActorAExitText -notmatch '^-?[0-9]+$' -or
        $p2f13LoadActorBExitText -notmatch '^-?[0-9]+$'
    ) {
        throw "P2F-13A actor exit sidecars are invalid."
    }


    $p2f13LoadActorAExit =
        [int]$p2f13LoadActorAExitText

    $p2f13LoadActorBExit =
        [int]$p2f13LoadActorBExitText


    Write-Host (
        "P2F13_LOAD_PROCESS_OUTPUT_FINALIZED|" +
        $p2f13LoadActorAExit +
        "|" +
        $p2f13LoadActorBExit
    )


    $p2f13LoadActorAStdout =
        Read-WholeFile $p2f13LoadActorAOut

    $p2f13LoadActorAStderr =
        Read-WholeFile $p2f13LoadActorAErr

    $p2f13LoadActorBStdout =
        Read-WholeFile $p2f13LoadActorBOut

    $p2f13LoadActorBStderr =
        Read-WholeFile $p2f13LoadActorBErr


    Write-Host ""
    Write-Host "================ P2F-13A ACTOR CLASSIFICATION ================"
    Write-Host ""

    Write-Host "Actor A exit: $p2f13LoadActorAExit"
    Write-Host "Actor B exit: $p2f13LoadActorBExit"

    Write-Host "---- Actor A stdout ----"
    Write-Host $p2f13LoadActorAStdout

    Write-Host "---- Actor A stderr ----"
    Write-Host $p2f13LoadActorAStderr

    Write-Host "---- Actor B stdout ----"
    Write-Host $p2f13LoadActorBStdout

    Write-Host "---- Actor B stderr ----"
    Write-Host $p2f13LoadActorBStderr


    if (
        $p2f13LoadActorAExit -eq 0 -and
        $p2f13LoadActorBExit -ne 0
    ) {

        $p2f13LoadWinner =
            "A"

        $p2f13LoadLoser =
            "B"

        $p2f13LoadWinnerInputColumn =
            "input_a"

        $p2f13LoadLoserKey =
            "p2f13-load-b"

        $p2f13LoadLoserText =
            $p2f13LoadActorBStdout +
            "`n" +
            $p2f13LoadActorBStderr
    }
    elseif (
        $p2f13LoadActorBExit -eq 0 -and
        $p2f13LoadActorAExit -ne 0
    ) {

        $p2f13LoadWinner =
            "B"

        $p2f13LoadLoser =
            "A"

        $p2f13LoadWinnerInputColumn =
            "input_b"

        $p2f13LoadLoserKey =
            "p2f13-load-a"

        $p2f13LoadLoserText =
            $p2f13LoadActorAStdout +
            "`n" +
            $p2f13LoadActorAStderr
    }
    else {
        throw "P2F-13A did not produce exactly one successful B06 actor."
    }


    if (
        -not $p2f13LoadLoserText.Contains(
            "STALE_SHIPMENT_VERSION"
        )
    ) {
        throw "P2F-13A loser did not fail STALE_SHIPMENT_VERSION."
    }


    Write-Host "P2F13_LOAD_WINNER|$p2f13LoadWinner"
    Write-Host "P2F13_LOAD_LOSER|$p2f13LoadLoser|STALE_SHIPMENT_VERSION"


    # ========================================================================
    # Canonical committed first-custody state
    # ========================================================================

    $p2f13LoadPostRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A post-race custody state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'LOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_custody_milestones m
    where m.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.v_cargo_custody_balance cb
    where cb.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence_reviews r
    join haulvia.stop_evidence e
      on e.id = r.stop_evidence_id
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.route_updates u
    where u.route_execution_id = c.route_execution_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'verifyFirstPickup'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'verifyFirstPickup'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'FIRST_PICKUP_VERIFIED'
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity), 0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = c.allocation_quantity
      then 1
      else 0
    end
  || '|'
  || s.shipment_state
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F13_LOAD_POST_RACE|$p2f13LoadPostRace"


    if (
        $p2f13LoadPostRace -ne
        "14|5|COMPLETED|COMPLETED|ADVANCE_TO_NEXT_STOP|1|1|1|6|6|3|1|1|1|1|ROUTE_IN_PROGRESS"
    ) {
        throw "P2F-13A committed custody state is invalid."
    }


    # ========================================================================
    # Durable winner binding
    # ========================================================================

    $p2f13LoadWinnerBinding =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A winner binding" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
),
counts as (
  select
    (
      select count(*)
      from haulvia.cargo_movements cm
      where cm.shipment_id = c.shipment_id
        and cm.idempotency_key like 'p2f13-load-a:load:%'
    ) as a_count,
    (
      select count(*)
      from haulvia.cargo_movements cm
      where cm.shipment_id = c.shipment_id
        and cm.idempotency_key like 'p2f13-load-b:load:%'
    ) as b_count
  from c
)
select
  case
    when a_count = 1 and b_count = 0 then 'A'
    when b_count = 1 and a_count = 0 then 'B'
    else 'INVALID'
  end
from counts;
"@


    Write-Host "P2F13_LOAD_WINNER_BINDING|$p2f13LoadWinnerBinding"


    if ($p2f13LoadWinnerBinding -ne $p2f13LoadWinner) {
        throw "P2F-13A LOAD movement does not bind to the winning actor."
    }


    # ========================================================================
    # Exact replay
    # ========================================================================

    $p2f13LoadReplay =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A winner replay" `
            -Sql @"
select
  haulvia_command.command_verify_first_pickup(
    (
      select $($p2f13LoadWinnerInputColumn)
      from p2f_test.custody_load_race_context
      where race_key = 'P2F-13A'
    )
  );
"@


    Write-Host "P2F13_LOAD_REPLAY|$p2f13LoadReplay"


    if (
        $p2f13LoadReplay -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-13A winner replay did not return replayed=true."
    }


    $p2f13LoadReplayState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A replay state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'LOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_custody_milestones m
    where m.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence_reviews r
    join haulvia.stop_evidence e
      on e.id = r.stop_evidence_id
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'verifyFirstPickup'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'verifyFirstPickup'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'FIRST_PICKUP_VERIFIED'
  )
from c;
"@


    Write-Host "P2F13_LOAD_REPLAY_STATE|$p2f13LoadReplayState"


    if ($p2f13LoadReplayState -ne "1|1|6|1|1|1") {
        throw "P2F-13A winner replay duplicated custody facts."
    }


    # ========================================================================
    # Same key + different hash
    # ========================================================================

    $p2f13LoadDifferentHash =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
select
  haulvia_command.command_verify_first_pickup(
    (
      select $($p2f13LoadWinnerInputColumn)
      from p2f_test.custody_load_race_context
      where race_key = 'P2F-13A'
    )
    ||
    jsonb_build_object(
      'requestHash',
      repeat('f', 64)
    )
  );
"@


    if (
        $p2f13LoadDifferentHash.ExitCode -eq 0 -or
        -not $p2f13LoadDifferentHash.Text.Contains(
            "IDEMPOTENCY_KEY_REUSED"
        )
    ) {

        Write-Host $p2f13LoadDifferentHash.Text

        throw "P2F-13A same-key/different-hash reuse did not fail closed."
    }


    Write-Host "P2F13_LOAD_IDEMPOTENCY_CONFLICT|IDEMPOTENCY_KEY_REUSED"


    # ========================================================================
    # Losing B06 transaction must leave zero attributable residue.
    # ========================================================================

    $p2f13LoadFailureResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A loser residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'verifyFirstPickup'
      and i.idempotency_key = '${p2f13LoadLoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.idempotency_key like '${p2f13LoadLoserKey}:load:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'verifyFirstPickup'
      and e.idempotency_key = '${p2f13LoadLoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'verifyFirstPickup'
      and a.idempotency_key = '${p2f13LoadLoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.notification_events n
    where n.shipment_id = c.shipment_id
      and n.event_code = 'FIRST_PICKUP_VERIFIED'
      and n.idempotency_key like '%' || '${p2f13LoadLoserKey}' || '%'
  )
from c;
"@


    Write-Host "P2F13_LOAD_FAILURE_RESIDUE|$p2f13LoadFailureResidue"


    if ($p2f13LoadFailureResidue -ne "0|0|0|0|0") {
        throw "P2F-13A losing transaction left custody residue."
    }


    # ========================================================================
    # Direct append-only ledger probe: a second LOAD for the already-fully
    # loaded allocation must fail before it can increase onboard quantity.
    #
    # The first pickup is now COMPLETED, which is a valid ledger state for the
    # movement trigger, so this reaches the planned-quantity guard directly.
    # ========================================================================

    $p2f13DuplicateLoadProbe =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
insert into haulvia.cargo_movements (
  shipment_id,
  route_execution_id,
  route_version_id,
  stop_execution_id,
  cargo_allocation_id,
  movement_type,
  quantity,
  quantity_unit,
  stop_attempt_id,
  evidence_bundle,
  occurred_at,
  recorded_by_profile_id,
  idempotency_key
)
select
  c.shipment_id,
  c.route_execution_id,
  c.route_version_id,
  c.stop_execution_id,
  c.cargo_allocation_id,
  'LOAD',
  c.allocation_quantity,
  c.quantity_unit,
  c.stop_attempt_id,
  jsonb_build_object(
    'probe',
    'P2F-13A duplicate LOAD'
  ),
  clock_timestamp(),
  null,
  'p2f13-duplicate-load-probe'
from c;
"@


    if (
        $p2f13DuplicateLoadProbe.ExitCode -eq 0 -or
        -not $p2f13DuplicateLoadProbe.Text.Contains(
            "LOAD movements cannot exceed the planned cargo allocation quantity"
        )
    ) {

        Write-Host $p2f13DuplicateLoadProbe.Text

        throw "P2F-13A duplicate LOAD ledger probe did not fail at the quantity guard."
    }


    Write-Host "P2F13_DUPLICATE_LOAD_GUARD|CARGO_ALLOCATION_LIMIT"


    $p2f13DuplicateLoadResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A duplicate LOAD residue" `
            -Sql @"
select count(*)::text
from haulvia.cargo_movements
where idempotency_key = 'p2f13-duplicate-load-probe';
"@


    Write-Host "P2F13_DUPLICATE_LOAD_RESIDUE|$p2f13DuplicateLoadResidue"


    if ($p2f13DuplicateLoadResidue -ne "0") {
        throw "P2F-13A duplicate LOAD probe left a ledger row."
    }


    # ========================================================================
    # Verified-custody boundary:
    # ordinary customer cancellation must now reject CUSTODY_EXISTS.
    #
    # Only fields parsed before assert_no_verified_custody are required.
    # ========================================================================

    $p2f13CancellationProbe =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  haulvia_command.command_cancel_before_any_custody(
    jsonb_strip_nulls(
      jsonb_build_object(
        'commandId',
          'f2130000-0000-0000-0000-000000000090',

        'idempotencyKey',
          'p2f13-post-custody-cancel',

        'requestHash',
          repeat('c', 64),

        'shipmentId',
          c.shipment_id,

        'expectedShipmentVersion',
          s.lock_version,

        'expectedRouteVersionId',
          c.route_version_id,

        'expectedAssignmentId',
          c.assignment_id,

        'expectedRouteExecutionId',
          c.route_execution_id,

        'expectedRouteExecutionVersion',
          re.record_version,

        'actorProfileId',
          c.customer_profile_id,

        'actorOrganizationId',
          s.customer_organization_id,

        'cancellationChargeAmount',
          0,

        'customerRefundAmount',
          0,

        'reason',
          'P2F-13 post-custody cancellation boundary probe'
      )
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    if (
        $p2f13CancellationProbe.ExitCode -eq 0 -or
        -not $p2f13CancellationProbe.Text.Contains(
            "CUSTODY_EXISTS"
        )
    ) {

        Write-Host $p2f13CancellationProbe.Text

        throw "P2F-13A post-custody cancellation did not fail CUSTODY_EXISTS."
    }


    Write-Host "P2F13_CUSTODY_BOUNDARY|CUSTODY_EXISTS"


    $p2f13CancellationResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A cancellation residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'cancelBeforeAnyCustody'
      and i.idempotency_key = 'p2f13-post-custody-cancel'
  )
  || '|'
  || (
    select count(*)
    from haulvia.pre_custody_financial_decisions d
    where d.shipment_id = c.shipment_id
      and d.command_name = 'cancelBeforeAnyCustody'
      and d.idempotency_key = 'p2f13-post-custody-cancel'
  )
  || '|'
  || (
    select count(*)
    from haulvia.assignment_events ae
    where ae.shipment_id = c.shipment_id
      and ae.command_name = 'cancelBeforeAnyCustody'
      and ae.idempotency_key = 'p2f13-post-custody-cancel'
  )
from c;
"@


    Write-Host "P2F13_CUSTODY_BOUNDARY_RESIDUE|$p2f13CancellationResidue"


    if ($p2f13CancellationResidue -ne "0|0|0") {
        throw "P2F-13A failed cancellation left pre-custody residue."
    }


    # ========================================================================
    # Final first-custody state
    # ========================================================================

    $p2f13LoadFinalState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13A final first-custody state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'LOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.shipment_custody_milestones m
    where m.shipment_id = c.shipment_id
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity), 0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = c.allocation_quantity
      then 1
      else 0
    end
  || '|'
  || s.shipment_state
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id;
"@


    Write-Host "P2F13_LOAD_FINAL_STATE|$p2f13LoadFinalState"


    if (
        $p2f13LoadFinalState -ne
        "14|5|COMPLETED|ADVANCE_TO_NEXT_STOP|1|1|1|ROUTE_IN_PROGRESS"
    ) {
        throw "P2F-13A final custody state changed unexpectedly."
    }


    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F-13A FIRST-CUSTODY LOAD RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: P2F-12 ARRIVED handoff advanced through real B04/B05 commands."
    Write-Host "PASS: first pickup reached EVIDENCE_PENDING through production evidence handling."
    Write-Host "PASS: two separate EVIDENCE_REVIEWER sessions raced B06."
    Write-Host "PASS: both actors were observed waiting on the advisory barrier."
    Write-Host "PASS: exactly one verifyFirstPickup transaction committed."
    Write-Host "PASS: losing actor failed STALE_SHIPMENT_VERSION."
    Write-Host "PASS: exactly one LOAD movement committed."
    Write-Host "PASS: exactly one first-custody milestone committed."
    Write-Host "PASS: onboard quantity equals the planned loaded allocation."
    Write-Host "PASS: stop/attempt completed and route execution advanced exactly once."
    Write-Host "PASS: evidence reviews, stop event, audit, route update and notification were not duplicated."
    Write-Host "PASS: exact winner replay is idempotent."
    Write-Host "PASS: same-key/different-hash reuse fails closed."
    Write-Host "PASS: losing transaction left zero attributable custody residue."
    Write-Host "PASS: append-only ledger rejected a second full LOAD."
    Write-Host "PASS: ordinary cancellation is blocked after verified custody."
    Write-Host ""
    Write-Host "P2F-13 internal progress: 1 / 2 custody sub-races."
    Write-Host "P2F-13 remains NON-AUTHORITATIVE until the UNLOAD/balance/resolution gate passes."
    Write-Host "Official P2F concurrency progress remains 4 / 8 race domains."
    Write-Host ""


    # ========================================================================

    # ========================================================================
    # P2F-13B - Delivery UNLOAD race and aggregate custody resolution
    #
    # Continues directly from authoritative P2F-13A:
    #
    #   shipment lock_version              = 14
    #   route execution record_version     = 5
    #   first pickup                       = COMPLETED
    #   next action                        = ADVANCE_TO_NEXT_STOP
    #   verified LOAD movements            = 1
    #   onboard custody                    = full planned 2 piece
    #
    # Actual P2F fixture topology:
    #
    #   stop 1 PICKUP -> stop 2 DELIVERY
    #   one route leg
    #   one cargo item
    #   one cargo allocation
    #   allocation quantity = 2 piece
    #
    # No second pickup, transfer, storage, or return stop exists.
    #
    # P2F-13B:
    #   1. advances to the sole delivery through C01
    #   2. creates real delivery arrival/service/evidence through C02/C04/C05
    #   3. proves route resolution fails while custody remains onboard
    #   4. races two C07 verifyDeliveryStop reviewers
    #   5. proves exactly one UNLOAD/outcome commits
    #   6. proves a second outbound movement cannot create negative custody
    #   7. resolves the real route through C14 only after custody reaches zero
    #
    # Full P2F-13 becomes runtime-authoritative only when this entire block
    # subsequently passes in a fresh disposable PostgreSQL database.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-13B DELIVERY FIXTURE ================"
    Write-Host ""


    # ========================================================================
    # 1. Runtime topology gate
    # ========================================================================

    $p2f13RouteShape =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B runtime route shape" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
),
shape as (
  select
    (
      select count(*)
      from haulvia.route_stops rs
      where rs.route_version_id = c.route_version_id
    ) as stop_count,

    (
      select count(*)
      from haulvia.route_stops rs
      where rs.route_version_id = c.route_version_id
        and rs.stop_type = 'PICKUP'
    ) as pickup_count,

    (
      select count(*)
      from haulvia.route_stops rs
      where rs.route_version_id = c.route_version_id
        and rs.stop_type = 'DELIVERY'
    ) as delivery_count,

    (
      select count(*)
      from haulvia.route_legs rl
      where rl.route_version_id = c.route_version_id
    ) as leg_count,

    (
      select count(*)
      from haulvia.cargo_allocations ca
      where ca.route_version_id = c.route_version_id
    ) as allocation_count,

    (
      select count(*)
      from haulvia.cargo_allocations ca
      where ca.route_version_id = c.route_version_id
        and ca.id = c.cargo_allocation_id
        and ca.quantity = 2
        and ca.quantity_unit = 'piece'
    ) as exact_allocation
  from c
)
select
  stop_count
  || '|'
  || pickup_count
  || '|'
  || delivery_count
  || '|'
  || leg_count
  || '|'
  || allocation_count
  || '|'
  || exact_allocation
from shape;
"@


    Write-Host "P2F13_ROUTE_SHAPE|$p2f13RouteShape"


    if ($p2f13RouteShape -ne "2|1|1|1|1|1") {
        throw "P2F-13B runtime fixture no longer matches the proven two-stop route."
    }


    # ========================================================================
    # 2. C01: completed pickup -> sole delivery EN_ROUTE
    # ========================================================================

    $p2f13AdvanceDelivery =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B advance to delivery" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  haulvia_command.command_advance_to_next_stop(
    jsonb_build_object(
      'commandId',
        'f2130000-0000-0000-0000-000000000101',

      'idempotencyKey',
        'p2f13-advance-delivery',

      'requestHash',
        repeat('1',64),

      'actorProfileId',
        c.driver_profile_id,

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        re.record_version,

      'expectedStopExecutionId',
        c.stop_execution_id,

      'nextStopEtaAt',
        clock_timestamp() + interval '3 hours',

      'etaNotificationThresholdSeconds',
        60,

      'occurredAt',
        clock_timestamp()
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_ADVANCE_DELIVERY|$p2f13AdvanceDelivery"


    if (
        $p2f13AdvanceDelivery -notmatch
        '"routeExecutionVersion"\s*:\s*6'
    ) {
        throw "P2F-13B C01 did not advance the route execution to version 6."
    }


    # ========================================================================
    # 3. Exact delivery handoff after C01
    # ========================================================================

    $p2f13DeliveryAfterAdvance =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B delivery handoff" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || rs.sequence_no
  || '|'
  || rs.stop_type
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.next_action
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity),0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = 2
      then 1
      else 0
    end
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = re.active_stop_execution_id
join haulvia.route_stops rs
  on rs.id = se.route_stop_id
join haulvia.stop_attempts sa
  on sa.stop_execution_id = se.id
 and sa.attempt_no = se.current_attempt_no;
"@


    Write-Host "P2F13_DELIVERY_HANDOFF|$p2f13DeliveryAfterAdvance"


    if (
        $p2f13DeliveryAfterAdvance -ne
        "15|6|2|DELIVERY|EN_ROUTE|EN_ROUTE|CONFIRM_ARRIVAL_AT_STOP|1"
    ) {
        throw "P2F-13B C01 did not reach the sole delivery exactly."
    }


    # ========================================================================
    # 4. C02: delivery arrival
    #
    # The actual P2F fixture intentionally has address-only stops without
    # latitude/longitude/geofence coordinates. Therefore the production C02
    # documented-location-exception path is used rather than fabricating a
    # route-plan geofence.
    # ========================================================================

    $p2f13DeliveryArrival =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B delivery arrival" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  haulvia_command.command_confirm_arrival_at_stop(
    jsonb_build_object(
      'commandId',
        'f2130000-0000-0000-0000-000000000102',

      'idempotencyKey',
        'p2f13-delivery-arrival',

      'requestHash',
        repeat('2',64),

      'actorProfileId',
        c.driver_profile_id,

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        re.record_version,

      'expectedStopExecutionId',
        re.active_stop_execution_id,

      'latitude',
        50.4452,

      'longitude',
        -104.6189,

      'accuracyM',
        5,

      'capturedAt',
        clock_timestamp(),

      'waitingFreeUntil',
        clock_timestamp() + interval '30 minutes',

      'gpsExceptionReason',
        'P2F fixture delivery has no stored geofence coordinates',

      'gpsExceptionEvidence',
        jsonb_build_object(
          'fixture',
            'P2F-13B',

          'reason',
            'address-only immutable route stop'
        ),

      'etaNotificationThresholdSeconds',
        60
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_DELIVERY_ARRIVAL|$p2f13DeliveryArrival"


    if (
        $p2f13DeliveryArrival -notmatch
        '"routeExecutionVersion"\s*:\s*7'
    ) {
        throw "P2F-13B C02 did not advance route execution to version 7."
    }


    # ========================================================================
    # 5. C04: start delivery service
    # ========================================================================

    $p2f13DeliveryService =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B start delivery service" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  haulvia_command.command_start_stop_service(
    jsonb_build_object(
      'commandId',
        'f2130000-0000-0000-0000-000000000103',

      'idempotencyKey',
        'p2f13-delivery-service',

      'requestHash',
        repeat('3',64),

      'actorProfileId',
        c.driver_profile_id,

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        re.record_version,

      'expectedStopExecutionId',
        re.active_stop_execution_id,

      'contactConfirmed',
        true,

      'locationConfirmed',
        true
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_DELIVERY_SERVICE|$p2f13DeliveryService"


    if (
        $p2f13DeliveryService -notmatch
        '"routeExecutionVersion"\s*:\s*8'
    ) {
        throw "P2F-13B C04 did not advance route execution to version 8."
    }


    # ========================================================================
    # 6. C05: submit current-contract standard-delivery evidence
    #
    # C02 already supplied GPS + TIMESTAMP.
    # C05 adds structured PHOTO + QUANTITY + CONDITION + PIN.
    # ========================================================================

    $p2f13DeliveryEvidence =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B submit delivery evidence" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
)
select
  haulvia_command.command_submit_stop_evidence(
    jsonb_build_object(
      'commandId',
        'f2130000-0000-0000-0000-000000000104',

      'idempotencyKey',
        'p2f13-delivery-evidence',

      'requestHash',
        repeat('4',64),

      'actorProfileId',
        c.driver_profile_id,

      'shipmentId',
        c.shipment_id,

      'expectedShipmentVersion',
        s.lock_version,

      'expectedRouteVersionId',
        c.route_version_id,

      'expectedAssignmentId',
        c.assignment_id,

      'expectedRouteExecutionId',
        c.route_execution_id,

      'expectedRouteExecutionVersion',
        re.record_version,

      'expectedStopExecutionId',
        re.active_stop_execution_id,

      'driverConfirmed',
        true,

      'receiverName',
        'P2F-13 Test Receiver',

      'evidence',
        jsonb_build_array(
          jsonb_build_object(
            'type',
              'PHOTO',

            'structuredValue',
              jsonb_build_object(
                'captureMode',
                  'STRUCTURED_TEST_PHOTO',

                'verified',
                  true,

                'purpose',
                  'P2F-13 delivery custody concurrency'
              ),

            'capturedAt',
              clock_timestamp()
          ),

          jsonb_build_object(
            'type',
              'QUANTITY',

            'structuredValue',
              jsonb_build_object(
                'quantity',
                  2,

                'unit',
                  'piece'
              ),

            'capturedAt',
              clock_timestamp()
          ),

          jsonb_build_object(
            'type',
              'CONDITION',

            'structuredValue',
              jsonb_build_object(
                'condition',
                  'GOOD'
              ),

            'capturedAt',
              clock_timestamp()
          ),

          jsonb_build_object(
            'type',
              'PIN',

            'structuredValue',
              jsonb_build_object(
                'verified',
                  true
              ),

            'capturedAt',
              clock_timestamp()
          )
        )
    )
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_DELIVERY_EVIDENCE|$p2f13DeliveryEvidence"


    if (
        $p2f13DeliveryEvidence -notmatch
        '"routeExecutionVersion"\s*:\s*9'
    ) {
        throw "P2F-13B C05 did not advance route execution to version 9."
    }


    # ========================================================================
    # 7. Build exact C07 race context
    # ========================================================================

    Invoke-PsqlText `
        -Database $TargetDatabase `
        -Label "P2F-13B UNLOAD race context" `
        -Sql @"
create table p2f_test.custody_unload_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  assignment_id uuid not null,
  route_version_id uuid not null,
  route_execution_id uuid not null,
  stop_execution_id uuid not null,
  stop_attempt_id uuid not null,
  cargo_allocation_id uuid not null,
  driver_profile_id uuid not null,
  pre_shipment_version bigint not null,
  pre_execution_version bigint not null,
  allocation_quantity numeric(14,3) not null,
  quantity_unit text not null,
  input_a jsonb not null,
  input_b jsonb not null
);

with c as (
  select *
  from p2f_test.custody_load_race_context
  where race_key = 'P2F-13A'
),
base as (
  select
    c.shipment_id,
    c.assignment_id,
    c.route_version_id,
    c.route_execution_id,
    re.active_stop_execution_id as stop_execution_id,
    sa.id as stop_attempt_id,
    c.cargo_allocation_id,
    c.driver_profile_id,
    s.lock_version as shipment_version,
    re.record_version as execution_version,
    ca.quantity as allocation_quantity,
    ca.quantity_unit
  from c
  join haulvia.shipments s
    on s.id = c.shipment_id
  join haulvia.route_executions re
    on re.id = c.route_execution_id
  join haulvia.stop_executions se
    on se.id = re.active_stop_execution_id
  join haulvia.stop_attempts sa
    on sa.stop_execution_id = se.id
   and sa.attempt_no = se.current_attempt_no
  join haulvia.cargo_allocations ca
    on ca.id = c.cargo_allocation_id
   and ca.route_version_id = c.route_version_id
   and ca.delivery_stop_id = se.route_stop_id
)
insert into p2f_test.custody_unload_race_context (
  race_key,
  shipment_id,
  assignment_id,
  route_version_id,
  route_execution_id,
  stop_execution_id,
  stop_attempt_id,
  cargo_allocation_id,
  driver_profile_id,
  pre_shipment_version,
  pre_execution_version,
  allocation_quantity,
  quantity_unit,
  input_a,
  input_b
)
select
  'P2F-13B',
  b.shipment_id,
  b.assignment_id,
  b.route_version_id,
  b.route_execution_id,
  b.stop_execution_id,
  b.stop_attempt_id,
  b.cargo_allocation_id,
  b.driver_profile_id,
  b.shipment_version,
  b.execution_version,
  b.allocation_quantity,
  b.quantity_unit,

  jsonb_build_object(
    'commandId',
      'f2130000-0000-0000-0000-000000000111',

    'idempotencyKey',
      'p2f13-unload-a',

    'requestHash',
      repeat('a',64),

    'shipmentId',
      b.shipment_id,

    'expectedShipmentVersion',
      b.shipment_version,

    'expectedRouteVersionId',
      b.route_version_id,

    'expectedAssignmentId',
      b.assignment_id,

    'expectedRouteExecutionId',
      b.route_execution_id,

    'expectedRouteExecutionVersion',
      b.execution_version,

    'expectedStopExecutionId',
      b.stop_execution_id,

    'workerAuthority',
      'EVIDENCE_REVIEWER',

    'reviewerLabel',
      'P2F-13 delivery reviewer A',

    'completedAt',
      clock_timestamp(),

    'contactlessDelivery',
      false,

    'etaNotificationThresholdSeconds',
      60,

    'unloads',
      jsonb_build_array(
        jsonb_build_object(
          'cargoAllocationId',
            b.cargo_allocation_id,

          'quantity',
            b.allocation_quantity,

          'quantityUnit',
            b.quantity_unit,

          'occurredAt',
            clock_timestamp(),

          'evidenceBundle',
            jsonb_build_object(
              'race',
                'P2F-13B',

              'actor',
                'A',

              'stopAttemptId',
                b.stop_attempt_id
            )
        )
      )
  ),

  jsonb_build_object(
    'commandId',
      'f2130000-0000-0000-0000-000000000112',

    'idempotencyKey',
      'p2f13-unload-b',

    'requestHash',
      repeat('b',64),

    'shipmentId',
      b.shipment_id,

    'expectedShipmentVersion',
      b.shipment_version,

    'expectedRouteVersionId',
      b.route_version_id,

    'expectedAssignmentId',
      b.assignment_id,

    'expectedRouteExecutionId',
      b.route_execution_id,

    'expectedRouteExecutionVersion',
      b.execution_version,

    'expectedStopExecutionId',
      b.stop_execution_id,

    'workerAuthority',
      'EVIDENCE_REVIEWER',

    'reviewerLabel',
      'P2F-13 delivery reviewer B',

    'completedAt',
      clock_timestamp(),

    'contactlessDelivery',
      false,

    'etaNotificationThresholdSeconds',
      60,

    'unloads',
      jsonb_build_array(
        jsonb_build_object(
          'cargoAllocationId',
            b.cargo_allocation_id,

          'quantity',
            b.allocation_quantity,

          'quantityUnit',
            b.quantity_unit,

          'occurredAt',
            clock_timestamp(),

          'evidenceBundle',
            jsonb_build_object(
              'race',
                'P2F-13B',

              'actor',
                'B',

              'stopAttemptId',
                b.stop_attempt_id
            )
        )
      )
  )
from base b;
"@


    # ========================================================================
    # 8. Exact pre-race custody boundary
    # ========================================================================

    $p2f13UnloadPreRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B pre-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'LOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'UNLOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_resolution_outcomes cro
    where cro.shipment_id = c.shipment_id
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity),0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = c.allocation_quantity
      then 1
      else 0
    end
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence_reviews er
    join haulvia.stop_evidence e
      on e.id = er.stop_evidence_id
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || s.shipment_state
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F13_UNLOAD_PRE_RACE|$p2f13UnloadPreRace"


    if (
        $p2f13UnloadPreRace -ne
        "18|9|EVIDENCE_PENDING|EVIDENCE_PENDING|VERIFY_DELIVERY_STOP|1|0|0|1|6|0|ROUTE_IN_PROGRESS"
    ) {
        throw "P2F-13B fixture is not at the exact delivery custody boundary."
    }


    # ========================================================================
    # 9. Frozen invariant probe:
    #    route resolution must fail while 2 piece remains onboard.
    #
    # This intentionally exercises the foundation state-transition guard.
    # The trigger checks custody before stop terminality, so the expected
    # failure is specifically the unbalanced-custody invariant.
    # ========================================================================

    $p2f13UnbalancedResolution =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
update haulvia.shipments s
set shipment_state = 'DELIVERED'
from c
where s.id = c.shipment_id;
"@


    if (
        $p2f13UnbalancedResolution.ExitCode -eq 0 -or
        -not $p2f13UnbalancedResolution.Text.Contains(
            "Route cannot resolve while the cargo custody ledger is unbalanced"
        )
    ) {

        Write-Host $p2f13UnbalancedResolution.Text

        throw "P2F-13B unbalanced route-resolution probe did not hit the custody guard."
    }


    Write-Host "P2F13_UNBALANCED_ROUTE_GUARD|CARGO_BALANCE_INVALID"


    $p2f13UnbalancedResolutionState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B unbalanced route residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  s.lock_version
  || '|'
  || s.shipment_state
  || '|'
  || (
    select count(*)
    from haulvia.route_resolution_records rr
    where rr.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'UNLOAD'
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity),0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = c.allocation_quantity
      then 1
      else 0
    end
from c
join haulvia.shipments s
  on s.id = c.shipment_id;
"@


    Write-Host "P2F13_UNBALANCED_ROUTE_RESIDUE|$p2f13UnbalancedResolutionState"


    if (
        $p2f13UnbalancedResolutionState -ne
        "18|ROUTE_IN_PROGRESS|0|0|1"
    ) {
        throw "P2F-13B failed route-resolution probe changed durable state."
    }


    # ========================================================================
    # 10. Synchronized C07 race
    # ========================================================================

    $p2f13UnloadGateFile =
        Join-Path $TempRoot "p2f13-unload-gate.sql"

    $p2f13UnloadGateOut =
        Join-Path $TempRoot "p2f13-unload-gate.out.txt"

    $p2f13UnloadGateErr =
        Join-Path $TempRoot "p2f13-unload-gate.err.txt"

    $p2f13UnloadActorAFile =
        Join-Path $TempRoot "p2f13-unload-actor-a.sql"

    $p2f13UnloadActorAOut =
        Join-Path $TempRoot "p2f13-unload-actor-a.out.txt"

    $p2f13UnloadActorAErr =
        Join-Path $TempRoot "p2f13-unload-actor-a.err.txt"

    $p2f13UnloadActorAExitFile =
        Join-Path $TempRoot "p2f13-unload-actor-a.exit.txt"

    $p2f13UnloadActorBFile =
        Join-Path $TempRoot "p2f13-unload-actor-b.sql"

    $p2f13UnloadActorBOut =
        Join-Path $TempRoot "p2f13-unload-actor-b.out.txt"

    $p2f13UnloadActorBErr =
        Join-Path $TempRoot "p2f13-unload-actor-b.err.txt"

    $p2f13UnloadActorBExitFile =
        Join-Path $TempRoot "p2f13-unload-actor-b.exit.txt"


    Write-Utf8NoBom `
        -Path $p2f13UnloadGateFile `
        -Text (
            @"
set application_name = 'p2f13_unload_gate';

select pg_advisory_lock(
  213,
  14
);

\echo P2F13_UNLOAD_GATE_ACQUIRED

select pg_sleep(300);
"@.Trim() +
            "`r`n"
        )


    Write-Utf8NoBom `
        -Path $p2f13UnloadActorAFile `
        -Text (
            @"
set application_name = 'p2f13_unload_actor_a';

select pg_advisory_lock_shared(
  213,
  14
);

\echo P2F13_UNLOAD_GATE_ACQUIRED_A

select
  'P2F13_UNLOAD_RESULT_A|'
  ||
  haulvia_command.command_verify_delivery_stop(
    (
      select input_a
      from p2f_test.custody_unload_race_context
      where race_key = 'P2F-13B'
    )
  )::text;
"@.Trim() +
            "`r`n"
        )


    Write-Utf8NoBom `
        -Path $p2f13UnloadActorBFile `
        -Text (
            @"
set application_name = 'p2f13_unload_actor_b';

select pg_advisory_lock_shared(
  213,
  14
);

\echo P2F13_UNLOAD_GATE_ACQUIRED_B

select
  'P2F13_UNLOAD_RESULT_B|'
  ||
  haulvia_command.command_verify_delivery_stop(
    (
      select input_b
      from p2f_test.custody_unload_race_context
      where race_key = 'P2F-13B'
    )
  )::text;
"@.Trim() +
            "`r`n"
        )


    $p2f13UnloadGateProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f13UnloadGateFile `
            -StdOutFile $p2f13UnloadGateOut `
            -StdErrFile $p2f13UnloadGateErr


    # ========================================================================
    # Observe live gate in PostgreSQL; do not read gate file while open.
    # ========================================================================

    $p2f13UnloadGateDeadline =
        [DateTime]::UtcNow.AddSeconds(15)

    $p2f13UnloadGateHeld =
        $false


    while (
        -not $p2f13UnloadGateHeld -and
        [DateTime]::UtcNow -lt $p2f13UnloadGateDeadline
    ) {

        $holderCount =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-13B live gate observation" `
                -Sql @"
select count(distinct a.pid)::text
from pg_stat_activity a
join pg_locks l
  on l.pid = a.pid
where a.datname = current_database()
  and a.application_name = 'p2f13_unload_gate'
  and l.locktype = 'advisory'
  and l.granted;
"@


        if ($holderCount -eq "1") {
            $p2f13UnloadGateHeld = $true
        }
        else {
            Start-Sleep -Milliseconds 100
        }
    }


    if (-not $p2f13UnloadGateHeld) {
        throw "P2F-13B UNLOAD gate was not observed as held."
    }


    Write-Host "P2F13_UNLOAD_GATE_HELD|1"


    $p2f13UnloadActorAProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f13UnloadActorAFile `
            -StdOutFile $p2f13UnloadActorAOut `
            -StdErrFile $p2f13UnloadActorAErr `
            -ExitCodeFile $p2f13UnloadActorAExitFile


    $p2f13UnloadActorBProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f13UnloadActorBFile `
            -StdOutFile $p2f13UnloadActorBOut `
            -StdErrFile $p2f13UnloadActorBErr `
            -ExitCodeFile $p2f13UnloadActorBExitFile


    # ========================================================================
    # Both reviewers must be blocked at the same advisory barrier.
    # ========================================================================

    $p2f13UnloadWaitDeadline =
        [DateTime]::UtcNow.AddSeconds(15)

    $p2f13UnloadWaiters =
        "0"


    while (
        $p2f13UnloadWaiters -ne "2" -and
        [DateTime]::UtcNow -lt $p2f13UnloadWaitDeadline
    ) {

        $p2f13UnloadWaiters =
            Invoke-PsqlScalar `
                -Database $TargetDatabase `
                -Label "P2F-13B waiter count" `
                -Sql @"
select count(*)::text
from pg_stat_activity
where datname = current_database()
  and application_name in (
    'p2f13_unload_actor_a',
    'p2f13_unload_actor_b'
  )
  and wait_event_type = 'Lock'
  and wait_event = 'advisory';
"@


        if ($p2f13UnloadWaiters -ne "2") {
            Start-Sleep -Milliseconds 100
        }
    }


    Write-Host "P2F13_UNLOAD_WAITERS|$p2f13UnloadWaiters"


    if ($p2f13UnloadWaiters -ne "2") {
        throw "P2F-13B did not observe two blocked C07 reviewers."
    }


    # ========================================================================
    # Resolve and terminate only the exact gate backend.
    # ========================================================================

    $p2f13UnloadGateBackendPid =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B gate PID" `
            -Sql @"
select pid::text
from pg_stat_activity
where datname = current_database()
  and application_name = 'p2f13_unload_gate'
  and pid <> pg_backend_pid()
order by pid
limit 1;
"@


    if (
        [string]::IsNullOrWhiteSpace(
            $p2f13UnloadGateBackendPid
        ) -or
        $p2f13UnloadGateBackendPid -notmatch '^[0-9]+$'
    ) {
        throw "Unable to resolve exact P2F-13B gate backend PID."
    }


    $p2f13UnloadGateRelease =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B gate release" `
            -Sql @"
select pg_terminate_backend(
  $p2f13UnloadGateBackendPid
);
"@


    if ($p2f13UnloadGateRelease -ne "t") {
        throw "Unable to release exact P2F-13B gate backend."
    }


    Write-Host "P2F13_UNLOAD_GATE_RELEASED|1"


    # ========================================================================
    # Finalize processes before reading redirected output.
    # ========================================================================

    $p2f13UnloadCompletionDeadline =
        [DateTime]::UtcNow.AddSeconds(30)


    while (
        (
            -not $p2f13UnloadActorAProcess.HasExited -or
            -not $p2f13UnloadActorBProcess.HasExited
        ) -and
        [DateTime]::UtcNow -lt $p2f13UnloadCompletionDeadline
    ) {

        Start-Sleep -Milliseconds 25
    }


    if (
        -not $p2f13UnloadActorAProcess.HasExited -or
        -not $p2f13UnloadActorBProcess.HasExited
    ) {
        throw "P2F-13B C07 actors did not finish within the deadline."
    }


    $p2f13UnloadActorAProcess.WaitForExit()
    $p2f13UnloadActorBProcess.WaitForExit()
    $p2f13UnloadGateProcess.WaitForExit()


    $p2f13UnloadActorAExit =
        [int](
            Read-WholeFile `
                $p2f13UnloadActorAExitFile
        ).Trim()

    $p2f13UnloadActorBExit =
        [int](
            Read-WholeFile `
                $p2f13UnloadActorBExitFile
        ).Trim()


    Write-Host (
        "P2F13_UNLOAD_PROCESS_OUTPUT_FINALIZED|" +
        $p2f13UnloadActorAExit +
        "|" +
        $p2f13UnloadActorBExit
    )


    $p2f13UnloadActorAStdout =
        Read-WholeFile $p2f13UnloadActorAOut

    $p2f13UnloadActorAStderr =
        Read-WholeFile $p2f13UnloadActorAErr

    $p2f13UnloadActorBStdout =
        Read-WholeFile $p2f13UnloadActorBOut

    $p2f13UnloadActorBStderr =
        Read-WholeFile $p2f13UnloadActorBErr


    Write-Host "---- P2F-13B Actor A stdout ----"
    Write-Host $p2f13UnloadActorAStdout

    Write-Host "---- P2F-13B Actor A stderr ----"
    Write-Host $p2f13UnloadActorAStderr

    Write-Host "---- P2F-13B Actor B stdout ----"
    Write-Host $p2f13UnloadActorBStdout

    Write-Host "---- P2F-13B Actor B stderr ----"
    Write-Host $p2f13UnloadActorBStderr


    # ========================================================================
    # Exactly one C07 reviewer may commit.
    # ========================================================================

    if (
        $p2f13UnloadActorAExit -eq 0 -and
        $p2f13UnloadActorBExit -ne 0
    ) {

        $p2f13UnloadWinner =
            "A"

        $p2f13UnloadLoser =
            "B"

        $p2f13UnloadWinnerInputColumn =
            "input_a"

        $p2f13UnloadLoserKey =
            "p2f13-unload-b"

        $p2f13UnloadLoserText =
            $p2f13UnloadActorBStdout +
            "`n" +
            $p2f13UnloadActorBStderr
    }
    elseif (
        $p2f13UnloadActorBExit -eq 0 -and
        $p2f13UnloadActorAExit -ne 0
    ) {

        $p2f13UnloadWinner =
            "B"

        $p2f13UnloadLoser =
            "A"

        $p2f13UnloadWinnerInputColumn =
            "input_b"

        $p2f13UnloadLoserKey =
            "p2f13-unload-a"

        $p2f13UnloadLoserText =
            $p2f13UnloadActorAStdout +
            "`n" +
            $p2f13UnloadActorAStderr
    }
    else {
        throw "P2F-13B did not produce exactly one successful C07 transaction."
    }


    if (
        -not $p2f13UnloadLoserText.Contains(
            "STALE_SHIPMENT_VERSION"
        )
    ) {
        throw "P2F-13B losing C07 reviewer did not fail STALE_SHIPMENT_VERSION."
    }


    Write-Host "P2F13_UNLOAD_WINNER|$p2f13UnloadWinner"
    Write-Host "P2F13_UNLOAD_LOSER|$p2f13UnloadLoser|STALE_SHIPMENT_VERSION"


    # ========================================================================
    # 11. Canonical post-race state
    # ========================================================================

    $p2f13UnloadPostRace =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B post-race state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  s.lock_version
  || '|'
  || re.record_version
  || '|'
  || se.state
  || '|'
  || sa.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'LOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'UNLOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_resolution_outcomes cro
    where cro.shipment_id = c.shipment_id
      and cro.outcome_code = 'DELIVERED'
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity),0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = 0
      then 1
      else 0
    end
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence e
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence_reviews er
    join haulvia.stop_evidence e
      on e.id = er.stop_evidence_id
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'verifyDeliveryStop'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'verifyDeliveryStop'
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_axis_events wa
    where wa.shipment_id = c.shipment_id
      and wa.command_name = 'verifyDeliveryStop'
  )
  || '|'
  || se.delivery_verification_state
  || '|'
  || s.shipment_state
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.stop_attempts sa
  on sa.id = c.stop_attempt_id;
"@


    Write-Host "P2F13_UNLOAD_POST_RACE|$p2f13UnloadPostRace"


    if (
        $p2f13UnloadPostRace -ne
        "19|10|COMPLETED|COMPLETED|COMPLETE_PLANNED_ROUTE|1|1|1|1|6|6|1|1|1|NOT_REQUIRED|ROUTE_IN_PROGRESS"
    ) {
        throw "P2F-13B committed delivery/custody state is invalid."
    }


    # ========================================================================
    # 12. Durable winner binding
    # ========================================================================

    $p2f13UnloadWinnerBinding =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B winner binding" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
),
counts as (
  select
    (
      select count(*)
      from haulvia.cargo_movements cm
      where cm.shipment_id = c.shipment_id
        and cm.idempotency_key like 'p2f13-unload-a:unload:%'
    ) as a_move,

    (
      select count(*)
      from haulvia.cargo_resolution_outcomes cro
      where cro.shipment_id = c.shipment_id
        and cro.idempotency_key like 'p2f13-unload-a:outcome:%'
    ) as a_outcome,

    (
      select count(*)
      from haulvia.cargo_movements cm
      where cm.shipment_id = c.shipment_id
        and cm.idempotency_key like 'p2f13-unload-b:unload:%'
    ) as b_move,

    (
      select count(*)
      from haulvia.cargo_resolution_outcomes cro
      where cro.shipment_id = c.shipment_id
        and cro.idempotency_key like 'p2f13-unload-b:outcome:%'
    ) as b_outcome
  from c
)
select
  case
    when a_move=1 and a_outcome=1 and b_move=0 and b_outcome=0
      then 'A'
    when b_move=1 and b_outcome=1 and a_move=0 and a_outcome=0
      then 'B'
    else 'INVALID'
  end
from counts;
"@


    Write-Host "P2F13_UNLOAD_WINNER_BINDING|$p2f13UnloadWinnerBinding"


    if ($p2f13UnloadWinnerBinding -ne $p2f13UnloadWinner) {
        throw "P2F-13B movement/outcome does not bind to the winning reviewer."
    }


    # ========================================================================
    # 13. Exact winner replay
    # ========================================================================

    $p2f13UnloadReplay =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B winner replay" `
            -Sql @"
select
  haulvia_command.command_verify_delivery_stop(
    (
      select $($p2f13UnloadWinnerInputColumn)
      from p2f_test.custody_unload_race_context
      where race_key = 'P2F-13B'
    )
  );
"@


    Write-Host "P2F13_UNLOAD_REPLAY|$p2f13UnloadReplay"


    if (
        $p2f13UnloadReplay -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-13B winner replay did not return replayed=true."
    }


    $p2f13UnloadReplayState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B replay state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.movement_type = 'UNLOAD'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_resolution_outcomes cro
    where cro.shipment_id = c.shipment_id
      and cro.outcome_code = 'DELIVERED'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_evidence_reviews er
    join haulvia.stop_evidence e
      on e.id = er.stop_evidence_id
    where e.stop_attempt_id = c.stop_attempt_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'verifyDeliveryStop'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'verifyDeliveryStop'
  )
  || '|'
  || (
    select count(*)
    from haulvia.workflow_axis_events wa
    where wa.shipment_id = c.shipment_id
      and wa.command_name = 'verifyDeliveryStop'
  )
from c;
"@


    Write-Host "P2F13_UNLOAD_REPLAY_STATE|$p2f13UnloadReplayState"


    if ($p2f13UnloadReplayState -ne "1|1|6|1|1|1") {
        throw "P2F-13B replay duplicated delivery custody state."
    }


    # ========================================================================
    # 14. Same idempotency key + different request hash
    # ========================================================================

    $p2f13UnloadDifferentHash =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
select
  haulvia_command.command_verify_delivery_stop(
    (
      select $($p2f13UnloadWinnerInputColumn)
      from p2f_test.custody_unload_race_context
      where race_key = 'P2F-13B'
    )
    ||
    jsonb_build_object(
      'requestHash',
      repeat('f',64)
    )
  );
"@


    if (
        $p2f13UnloadDifferentHash.ExitCode -eq 0 -or
        -not $p2f13UnloadDifferentHash.Text.Contains(
            "IDEMPOTENCY_KEY_REUSED"
        )
    ) {

        Write-Host $p2f13UnloadDifferentHash.Text

        throw "P2F-13B same-key/different-hash reuse did not fail closed."
    }


    Write-Host "P2F13_UNLOAD_IDEMPOTENCY_CONFLICT|IDEMPOTENCY_KEY_REUSED"


    # ========================================================================
    # 15. Losing C07 transaction leaves no attributable residue
    # ========================================================================

    $p2f13UnloadFailureResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B loser residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  (
    select count(*)
    from haulvia.command_idempotency i
    where i.command_name = 'verifyDeliveryStop'
      and i.idempotency_key = '${p2f13UnloadLoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.shipment_id = c.shipment_id
      and cm.idempotency_key like '${p2f13UnloadLoserKey}:unload:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_resolution_outcomes cro
    where cro.shipment_id = c.shipment_id
      and cro.idempotency_key like '${p2f13UnloadLoserKey}:outcome:%'
  )
  || '|'
  || (
    select count(*)
    from haulvia.stop_attempt_events e
    where e.stop_attempt_id = c.stop_attempt_id
      and e.command_name = 'verifyDeliveryStop'
      and e.idempotency_key = '${p2f13UnloadLoserKey}'
  )
  || '|'
  || (
    select count(*)
    from haulvia.audit_events a
    where a.entity_table = 'shipments'
      and a.entity_id = c.shipment_id
      and a.command_name = 'verifyDeliveryStop'
      and a.idempotency_key = '${p2f13UnloadLoserKey}'
  )
from c;
"@


    Write-Host "P2F13_UNLOAD_FAILURE_RESIDUE|$p2f13UnloadFailureResidue"


    if ($p2f13UnloadFailureResidue -ne "0|0|0|0|0") {
        throw "P2F-13B losing C07 transaction left durable residue."
    }


    # ========================================================================
    # 16. Negative-custody probe
    #
    # Delivery is COMPLETED and route execution remains ACTIVE.
    # A second valid-type UNLOAD therefore reaches the actual outbound
    # custody-balance guard instead of failing on stop/execution state.
    # ========================================================================

    $p2f13NegativeUnload =
        Invoke-PsqlAllowFailure `
            -Database $TargetDatabase `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
insert into haulvia.cargo_movements (
  shipment_id,
  route_execution_id,
  route_version_id,
  stop_execution_id,
  cargo_allocation_id,
  movement_type,
  quantity,
  quantity_unit,
  stop_attempt_id,
  evidence_bundle,
  occurred_at,
  recorded_by_profile_id,
  idempotency_key
)
select
  c.shipment_id,
  c.route_execution_id,
  c.route_version_id,
  c.stop_execution_id,
  c.cargo_allocation_id,
  'UNLOAD',
  1,
  c.quantity_unit,
  c.stop_attempt_id,
  jsonb_build_object(
    'probe',
      'P2F-13B negative custody'
  ),
  clock_timestamp(),
  null,
  'p2f13-negative-unload-probe'
from c;
"@


    if (
        $p2f13NegativeUnload.ExitCode -eq 0 -or
        -not $p2f13NegativeUnload.Text.Contains(
            "Outbound custody movement cannot exceed current onboard quantity"
        )
    ) {

        Write-Host $p2f13NegativeUnload.Text

        throw "P2F-13B negative-custody probe did not reach the outbound custody guard."
    }


    Write-Host "P2F13_NEGATIVE_CUSTODY_GUARD|CARGO_BALANCE_INVALID"


    $p2f13NegativeUnloadResidue =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B negative unload residue" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  (
    select count(*)
    from haulvia.cargo_movements cm
    where cm.idempotency_key =
      'p2f13-negative-unload-probe'
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity),0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = 0
      then 1
      else 0
    end
from c;
"@


    Write-Host "P2F13_NEGATIVE_CUSTODY_RESIDUE|$p2f13NegativeUnloadResidue"


    if ($p2f13NegativeUnloadResidue -ne "0|1") {
        throw "P2F-13B negative-custody probe changed the ledger."
    }


    # ========================================================================
    # 17. C14: valid zero-balance planned-route resolution
    # ========================================================================

    Invoke-PsqlText `
        -Database $TargetDatabase `
        -Label "P2F-13B freeze C14 request" `
        -Sql @"
create table p2f_test.custody_route_resolution_context (
  race_key text primary key,
  input jsonb not null
);

with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
insert into p2f_test.custody_route_resolution_context (
  race_key,
  input
)
select
  'P2F-13B',

  jsonb_build_object(
    'commandId',
      'f2130000-0000-0000-0000-000000000120',

    'idempotencyKey',
      'p2f13-route-resolution',

    'requestHash',
      repeat('e',64),

    'shipmentId',
      c.shipment_id,

    'expectedShipmentVersion',
      s.lock_version,

    'expectedRouteVersionId',
      c.route_version_id,

    'expectedAssignmentId',
      c.assignment_id,

    'expectedRouteExecutionId',
      c.route_execution_id,

    'expectedRouteExecutionVersion',
      re.record_version,

    'workerAuthority',
      'EVIDENCE_REVIEWER'
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    $p2f13RouteResolutionInputSnapshot =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B C14 request snapshot" `
            -Sql @"
select
  (input ->> 'expectedShipmentVersion')
  || '|'
  || (input ->> 'expectedRouteExecutionVersion')
from p2f_test.custody_route_resolution_context
where race_key = 'P2F-13B';
"@


    Write-Host (
        "P2F13_ROUTE_RESOLUTION_INPUT_SNAPSHOT|" +
        $p2f13RouteResolutionInputSnapshot
    )


    if ($p2f13RouteResolutionInputSnapshot -ne "19|10") {
        throw "P2F-13B C14 request was not frozen at the expected pre-resolution versions."
    }


    $p2f13RouteResolution =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B complete planned route" `
            -Sql @"
select
  haulvia_command.command_complete_planned_route(
    (
      select input
      from p2f_test.custody_route_resolution_context
      where race_key = 'P2F-13B'
    )
  );
"@


    Write-Host "P2F13_ROUTE_RESOLUTION|$p2f13RouteResolution"


    if (
        $p2f13RouteResolution -notmatch
            '"shipmentState"\s*:\s*"DELIVERED"' -or
        $p2f13RouteResolution -notmatch
            '"routeExecutionState"\s*:\s*"COMPLETED"'
    ) {
        throw "P2F-13B C14 did not resolve the zero-custody route."
    }


    $p2f13ResolvedState =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B resolved state" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select
  s.lock_version
  || '|'
  || s.shipment_state
  || '|'
  || re.record_version
  || '|'
  || re.state
  || '|'
  || re.next_action
  || '|'
  || (
    select count(*)
    from haulvia.route_resolution_records rr
    where rr.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select rr.public_outcome_label
    from haulvia.route_resolution_records rr
    where rr.shipment_id = c.shipment_id
    order by rr.resolved_at desc
    limit 1
  )
  || '|'
  || (
    select count(*)
    from haulvia.cargo_resolution_outcomes cro
    where cro.shipment_id = c.shipment_id
      and cro.outcome_code = 'DELIVERED'
  )
  || '|'
  || case
      when (
        select coalesce(sum(cb.onboard_quantity),0)
        from haulvia.v_cargo_custody_balance cb
        where cb.shipment_id = c.shipment_id
      ) = 0
      then 1
      else 0
    end
  || '|'
  || (
    select count(*)
    from haulvia.tracking_sessions ts
    where ts.route_execution_id = c.route_execution_id
      and ts.ended_at is null
  )
from c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host "P2F13_RESOLVED_STATE|$p2f13ResolvedState"


    if (
        $p2f13ResolvedState -ne
        "20|DELIVERED|11|COMPLETED|COMPLETE_SHIPMENT|1|DELIVERED|1|1|0"
    ) {
        throw "P2F-13B final C14 state changed unexpectedly."
    }


    # ========================================================================
    # 18. C14 exact replay must not duplicate resolution
    #
    # Prove the replay request itself remains the original 19|10 request
    # while durable state has already advanced to 20|11.
    # ========================================================================

    $p2f13RouteResolutionReplayInput =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B exact C14 replay input" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
),
r as (
  select input
  from p2f_test.custody_route_resolution_context
  where race_key = 'P2F-13B'
)
select
  (r.input ->> 'expectedShipmentVersion')
  || '|'
  || (r.input ->> 'expectedRouteExecutionVersion')
  || '|'
  || s.lock_version
  || '|'
  || re.record_version
from c
cross join r
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id;
"@


    Write-Host (
        "P2F13_ROUTE_RESOLUTION_REPLAY_INPUT|" +
        $p2f13RouteResolutionReplayInput
    )


    if ($p2f13RouteResolutionReplayInput -ne "19|10|20|11") {
        throw "P2F-13B C14 replay is not using the exact original request snapshot."
    }


    $p2f13RouteResolutionReplay =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B route-resolution replay" `
            -Sql @"
select
  haulvia_command.command_complete_planned_route(
    (
      select input
      from p2f_test.custody_route_resolution_context
      where race_key = 'P2F-13B'
    )
  );
"@


    Write-Host "P2F13_ROUTE_RESOLUTION_REPLAY|$p2f13RouteResolutionReplay"


    if (
        $p2f13RouteResolutionReplay -notmatch
        '"replayed"\s*:\s*true'
    ) {
        throw "P2F-13B C14 exact replay was not idempotent."
    }


    $p2f13ResolutionCount =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-13B route-resolution cardinality" `
            -Sql @"
with c as (
  select *
  from p2f_test.custody_unload_race_context
  where race_key = 'P2F-13B'
)
select count(*)::text
from haulvia.route_resolution_records rr
join c
  on c.shipment_id = rr.shipment_id;
"@


    Write-Host "P2F13_ROUTE_RESOLUTION_COUNT|$p2f13ResolutionCount"


    if ($p2f13ResolutionCount -ne "1") {
        throw "P2F-13B C14 replay duplicated route resolution."
    }


    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F-13B DELIVERY UNLOAD RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: actual two-stop P2F route topology was verified at runtime."
    Write-Host "PASS: C01 advanced directly from first verified pickup to the sole delivery."
    Write-Host "PASS: C02/C04/C05 created the production delivery evidence boundary."
    Write-Host "PASS: unbalanced custody blocked route resolution before UNLOAD."
    Write-Host "PASS: two separate EVIDENCE_REVIEWER sessions raced C07."
    Write-Host "PASS: exactly one C07 transaction committed."
    Write-Host "PASS: losing C07 reviewer failed STALE_SHIPMENT_VERSION."
    Write-Host "PASS: exactly one UNLOAD movement committed."
    Write-Host "PASS: exactly one DELIVERED cargo outcome committed."
    Write-Host "PASS: onboard custody reached zero exactly once."
    Write-Host "PASS: delivery evidence reviews and durable command effects were not duplicated."
    Write-Host "PASS: exact C07 winner replay is idempotent."
    Write-Host "PASS: same-key/different-hash C07 reuse fails closed."
    Write-Host "PASS: losing C07 transaction left zero attributable residue."
    Write-Host "PASS: a second UNLOAD cannot drive onboard custody negative."
    Write-Host "PASS: C14 resolved the route only after the custody ledger reached zero."
    Write-Host "PASS: C14 replay did not duplicate the immutable route-resolution record."
    Write-Host ""
    Write-Host "P2F-13 internal progress: 2 / 2 custody sub-races."
    Write-Host ""


    Write-Host "============================================================"
    Write-Host "P2F-13 CUSTODY RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: first verified custody LOAD race is proven."
    Write-Host "PASS: delivery UNLOAD race is proven."
    Write-Host "PASS: double LOAD is rejected."
    Write-Host "PASS: double UNLOAD / negative onboard custody is rejected."
    Write-Host "PASS: post-custody ordinary cancellation is blocked."
    Write-Host "PASS: route resolution is blocked while custody is unbalanced."
    Write-Host "PASS: zero-balance route resolution succeeds exactly once."
    Write-Host ""
    Write-Host "P2F concurrency progress: 5 / 8 race domains."
    Write-Host "Next required domain: P2F-14 Receiver review race."
    Write-Host ""



    # ========================================================================
    # P2F-14 RECEIVER REVIEW FIXTURE
    #
    # Source fixture only. No P2F-14 race authority is claimed here.
    #
    # This uses the existing Block D acceptance seed to create a separate,
    # real, contactless delivery-review window in the disposable database.
    #
    # It persists independent D01 and D02 request JSON so that separate
    # PostgreSQL actor sessions can race against the same canonical window.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-14 RECEIVER REVIEW FIXTURE ================"
    Write-Host ""

    $p2f14AcceptanceFile =
        Join-Path $PSScriptRoot "haulvia_block_d_acceptance_v1.sql"

    $p2f14AcceptanceExpectedHash = "FE71347ECC174C13C263036BDDE91CE4B76F1EDF0A960480160E2BE630F16E8B"

    $p2f14AcceptanceActualHash =
        (Get-FileHash -LiteralPath $p2f14AcceptanceFile -Algorithm SHA256).Hash

    if ($p2f14AcceptanceActualHash -ne $p2f14AcceptanceExpectedHash) {
        throw "Block D acceptance fixture source changed after P2F-14 preparation."
    }

    $p2f14AcceptanceSource =
        [System.IO.File]::ReadAllText($p2f14AcceptanceFile).Replace("`r`n", "`n")


    function Get-P2F14SourceSection {
        param(
            [string]$Start,
            [string]$End
        )

        $startIndex = $p2f14AcceptanceSource.IndexOf(
            $Start,
            [System.StringComparison]::Ordinal
        )

        if ($startIndex -lt 0) {
            throw "P2F-14 missing Block D source section start: $Start"
        }

        $endIndex = $p2f14AcceptanceSource.IndexOf(
            $End,
            $startIndex + $Start.Length,
            [System.StringComparison]::Ordinal
        )

        if ($endIndex -lt 0) {
            throw "P2F-14 missing Block D source section end: $End"
        }

        return $p2f14AcceptanceSource.Substring(
            $startIndex,
            $endIndex - $startIndex
        )
    }


    $p2f14EnvelopeSource =
        Get-P2F14SourceSection `
            -Start "create or replace function pg_temp.envelope(" `
            -End "-- Shared customer, provider, policy, pricing, and sensitive-admin fixtures."


    $p2f14SharedSeedSource =
        Get-P2F14SourceSection `
            -Start "-- Shared customer, provider, policy, pricing, and sensitive-admin fixtures." `
            -End "create or replace function pg_temp.seed_delivered("
    # P2F-14 receiver-link D01/D02 commands authenticate via the exact
    # receiver token, not via an admin organization membership or role.
    # The older Block D acceptance fixture seeds a BLOCK_D_ADMIN role and
    # grants it to a HAULVIA org. The currently installed role-kind policy
    # intentionally rejects that grant. Keep the original acceptance file
    # unchanged; remove only this unneeded legacy RBAC segment from the
    # temporary fixture SQL assembled for P2F-14.
    $p2f14LegacyAdminRoleSeed = @(
        "  insert into roles(id, role_key, name, description)"
        "  values (v_role, 'BLOCK_D_ADMIN', 'Block D administrator', 'Acceptance-only sensitive role');"
        "  insert into role_permissions(role_id, permission_id)"
        "  select v_role, p.id from permissions p"
        "  where p.permission_key in ('SHIPMENT_STATE_OVERRIDE', 'PAYOUT_MANAGE', 'FINANCIAL_ADJUST');"
        "  insert into membership_roles(membership_id, role_id, granted_by_profile_id)"
        "  values (v_admin_membership, v_role, v_admin);"
    ) -join "`n"

    $p2f14LegacyGrantCount = [regex]::Matches(
        $p2f14SharedSeedSource,
        [regex]::Escape($p2f14LegacyAdminRoleSeed)
    ).Count
    Write-Host "P2F14_LEGACY_ROLE_GRANT_SOURCE_COUNT|$p2f14LegacyGrantCount"
    if ($p2f14LegacyGrantCount -ne 1) {
        throw 'P2F-14 legacy admin-role seed differs from approved Block D source.'
    }
    $p2f14SharedSeedSource = $p2f14SharedSeedSource.Replace(
        $p2f14LegacyAdminRoleSeed,
        '  -- P2F-14: no test admin role grant; receiver token supplies authority.'
    )
    foreach ($forbidden in @(
        'insert into roles(id, role_key, name, description)',
        'insert into role_permissions(role_id, permission_id)',
        'insert into membership_roles(membership_id, role_id, granted_by_profile_id)'
    )) {
        if ($p2f14SharedSeedSource.Contains($forbidden)) {
            throw "P2F-14 extracted fixture still includes unneeded role seed: $forbidden"
        }
    }
    Write-Host 'P2F14_LEGACY_ADMIN_ROLE_GRANT_REMOVED|true'
    # P2F-14 uses the approved P2A publication flow for its test-only
    # Block D policy and pricing versions. The customer fixture profile is
    # the creator; the separate Haulvia test administrator is the approver.
    # The admin has an actual HAULVIA membership and fresh MFA session, but
    # must receive the existing seeded PLATFORM_ADMIN role for publication.
    # Do not bypass the publication trigger or convert versions to DRAFT.
    function Replace-P2F14SeedExact {
        param(
            [string]$Current,
            [string]$Old,
            [string]$New,
            [string]$Label
        )
        $count = [regex]::Matches($Current, [regex]::Escape($Old)).Count
        Write-Host "P2F14_P2A_SEED_REPLACE|$Label|$count"
        if ($count -ne 1) {
            throw "P2F-14 P2A fixture source differs for $Label."
        }
        return $Current.Replace($Old, $New)
    }

    $p2f14PlatformAuthority = @"
  -- P2F-14 TEST-ONLY P2A publication authority, scoped to HAULVIA.
  insert into membership_roles (membership_id, role_id)
  select v_admin_membership, r.id
  from roles r
  where r.role_key = 'PLATFORM_ADMIN';
  if not found then
    raise exception 'P2F-14 PLATFORM_ADMIN role seed is absent';
  end if;
  if not coalesce(haulvia.has_permission(v_admin, v_haulvia_org, 'POLICY_PUBLISH'), false)
     or not coalesce(haulvia.has_permission(v_admin, v_haulvia_org, 'PRICING_MANAGE'), false) then
    raise exception 'P2F-14 test publisher lacks P2A publishing authority';
  end if;

"@

    $p2f14SharedSeedSource = Replace-P2F14SeedExact `
        -Current $p2f14SharedSeedSource `
        -Old '  insert into policy_sets(id, policy_key, name)' `
        -New ($p2f14PlatformAuthority + '  insert into policy_sets(id, policy_key, name)') `
        -Label 'platform-admin-publisher'

    $p2f14SharedSeedSource = Replace-P2F14SeedExact `
        -Current $p2f14SharedSeedSource `
        -Old ("    config_sha256, legal_review_required, created_by_profile_id,`n    approved_by_profile_id, approved_at") `
        -New ("    config_sha256, legal_review_required, created_by_profile_id,`n    approved_by_profile_id, approved_at, reauth_session_id, approval_reason") `
        -Label 'policy-publication-columns'

    $p2f14SharedSeedSource = Replace-P2F14SeedExact `
        -Current $p2f14SharedSeedSource `
        -Old "false, v_admin, v_admin, clock_timestamp()" `
        -New "false, v_customer, v_admin, clock_timestamp(), 'd3000000-0000-0000-0000-000000000004'::uuid, 'P2F-14 receiver test policy approval'" `
        -Label 'policy-creator-approver-reauth'

    $p2f14SharedSeedSource = Replace-P2F14SeedExact `
        -Current $p2f14SharedSeedSource `
        -Old '    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at' `
        -New '    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at, reauth_session_id, approval_reason' `
        -Label 'pricing-publication-columns'

    $p2f14SharedSeedSource = Replace-P2F14SeedExact `
        -Current $p2f14SharedSeedSource `
        -Old "repeat('e', 64), v_admin, v_admin, clock_timestamp()" `
        -New "repeat('e', 64), v_customer, v_admin, clock_timestamp(), 'd3000000-0000-0000-0000-000000000004'::uuid, 'P2F-14 receiver test pricing approval'" `
        -Label 'pricing-creator-approver-reauth'

    if ($p2f14SharedSeedSource.Contains('v_admin, v_admin, clock_timestamp()')) {
        throw 'P2F-14 legacy self-approval remains in the generated seed.'
    }
    Write-Host 'P2F14_P2A_PUBLICATION_INPUTS_PATCHED|true'


    $p2f14DeliveredSeedSource =
        Get-P2F14SourceSection `
            -Start "create or replace function pg_temp.seed_delivered(" `
            -End "create or replace function pg_temp.cargo_manifest("


    $p2f14ManifestSource =
        Get-P2F14SourceSection `
            -Start "create or replace function pg_temp.cargo_manifest(" `
            -End "create or replace function pg_temp.resolve_and_complete("


    $p2f14SeedHead = @"
\set ON_ERROR_STOP on

begin;
set local search_path = haulvia, haulvia_command, public;
"@


    $p2f14SeedTail = @"

create table p2f_test.receiver_review_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  route_execution_id uuid not null,
  stop_execution_id uuid not null,
  delivery_review_window_id uuid not null,
  receiver_access_token_id uuid not null,
  fixture jsonb not null,
  input_a jsonb not null,
  input_b jsonb not null
);

do `$`$
declare
  v_fixture jsonb :=
    pg_temp.seed_delivered('p2f14-primary');

  v_shipment uuid :=
    (v_fixture ->> 'shipmentId')::uuid;

  v_input_a jsonb;
  v_input_b jsonb;
begin
  v_input_a :=
    pg_temp.envelope(
      v_shipment,
      null,
      'p2f14-receiver-confirm',
      'a'
    ) ||
    jsonb_build_object(
      'expectedDeliveryReviewWindowId',
        v_fixture ->> 'deliveryReviewWindowId',

      'expectedStopExecutionId',
        v_fixture ->> 'deliveryStopExecutionId',

      'expectedRouteExecutionId',
        v_fixture ->> 'routeExecutionId',

      'expectedRouteExecutionVersion',
        v_fixture ->> 'routeExecutionVersion',

      'receiverAccessTokenId',
        v_fixture ->> 'receiverAccessTokenId',

      'receiverTokenHash',
        v_fixture ->> 'receiverTokenHash',

      'receiverLabel',
        'P2F14 Verified Receiver',

      'cargoManifest',
        pg_temp.cargo_manifest(v_fixture),

      'respondedAt',
        clock_timestamp()
    );

  v_input_b :=
    pg_temp.envelope(
      v_shipment,
      null,
      'p2f14-report-damage',
      'b'
    ) ||
    jsonb_build_object(
      'expectedDeliveryReviewWindowId',
        v_fixture ->> 'deliveryReviewWindowId',

      'expectedStopExecutionId',
        v_fixture ->> 'deliveryStopExecutionId',

      'expectedRouteExecutionId',
        v_fixture ->> 'routeExecutionId',

      'expectedRouteExecutionVersion',
        v_fixture ->> 'routeExecutionVersion',

      'receiverAccessTokenId',
        v_fixture ->> 'receiverAccessTokenId',

      'receiverTokenHash',
        v_fixture ->> 'receiverTokenHash',

      'receiverLabel',
        'P2F14 Verified Receiver',

      'cargoManifest',
        pg_temp.cargo_manifest(v_fixture),

      'issueCategory',
        'DAMAGED',

      'description',
        'Outer packaging and cargo were visibly damaged at receipt',

      'evidenceManifest',
        jsonb_build_array(
          jsonb_build_object(
            'type', 'PHOTO',
            'storageObjectKey', 'p2f14/receiver-damage.jpg',
            'contentSha256', repeat('b', 64)
          )
        ),

      'cargoItemId',
        v_fixture ->> 'cargoItemId',

      'disputedAmount',
        25,

      'financialAllocation',
        jsonb_build_object(
          'priceSnapshotId',
            v_fixture ->> 'priceSnapshotId',

          'basis',
            'DAMAGED_CARGO_SHARE'
        ),

      'respondedAt',
        clock_timestamp()
    );

  insert into p2f_test.receiver_review_race_context (
    race_key,
    shipment_id,
    route_execution_id,
    stop_execution_id,
    delivery_review_window_id,
    receiver_access_token_id,
    fixture,
    input_a,
    input_b
  )
  values (
    'P2F-14',
    v_shipment,
    (v_fixture ->> 'routeExecutionId')::uuid,
    (v_fixture ->> 'deliveryStopExecutionId')::uuid,
    (v_fixture ->> 'deliveryReviewWindowId')::uuid,
    (v_fixture ->> 'receiverAccessTokenId')::uuid,
    v_fixture,
    v_input_a,
    v_input_b
  );
end;
`$`$;

commit;
"@


    # P2F-14 fixture compatibility with P2D private storage: the original
    # Block D acceptance helper predates P2D and inserts deleted columns.
    # This test requires structured, verified delivery-review evidence only.
    # No binary PHOTO object is invented or marked AVAILABLE; testing the
    # binary upload/attachment lifecycle is a separate P2D test boundary.
    # This patch changes only the in-memory copy of seed_delivered().
    $p2f14OldEvidenceColumns =
        '    stop_attempt_id, evidence_type, storage_object_key, content_sha256,'
    $p2f14NewEvidenceColumns =
        '    stop_attempt_id, evidence_type,'

    $p2f14OldEvidenceValues =
        "    v_delivery_attempt, 'PHOTO', p_label || '/proof.jpg', repeat('a', 64),"
    $p2f14NewEvidenceValues =
        "    v_delivery_attempt, 'PHOTO',"

    function Replace-P2F14EvidenceExact {
        param([string]$Text, [string]$Old, [string]$New, [string]$Label)
        $count = [regex]::Matches($Text, [regex]::Escape($Old)).Count
        Write-Host "P2F14_P2D_SEED_REPLACE|$Label|$count"
        if ($count -ne 1) {
            throw "P2F-14 P2D $Label match count was $count; expected 1."
        }
        return $Text.Replace($Old, $New)
    }

    $p2f14DeliveredSeedSource = Replace-P2F14EvidenceExact `
        -Text $p2f14DeliveredSeedSource `
        -Old $p2f14OldEvidenceColumns `
        -New $p2f14NewEvidenceColumns `
        -Label 'evidence-insert-columns'

    $p2f14DeliveredSeedSource = Replace-P2F14EvidenceExact `
        -Text $p2f14DeliveredSeedSource `
        -Old $p2f14OldEvidenceValues `
        -New $p2f14NewEvidenceValues `
        -Label 'evidence-insert-values'

    if (
        $p2f14DeliveredSeedSource.Contains('storage_object_key') -or
        $p2f14DeliveredSeedSource.Contains('content_sha256') -or
        -not $p2f14DeliveredSeedSource.Contains(
            "jsonb_build_object('dropLocation', 'AUTHORIZED_FRONT_DESK', 'notes', 'Secure drop')"
        )
    ) {
        throw 'P2F-14 P2D structured evidence seed integrity check failed.'
    }
    Write-Host 'P2F14_P2D_EVIDENCE_SEED_PATCHED|true'
    $p2f14SeedSql =
        @(
            $p2f14SeedHead,
            $p2f14EnvelopeSource,
            $p2f14SharedSeedSource,
            $p2f14DeliveredSeedSource,
            $p2f14ManifestSource,
            $p2f14SeedTail
        ) -join "`n"


    $p2f14SeedFile =
        Join-Path $TempRoot "p2f14-fixture.sql"

    $p2f14SeedOut =
        Join-Path $TempRoot "p2f14-fixture.stdout.txt"

    $p2f14SeedErr =
        Join-Path $TempRoot "p2f14-fixture.stderr.txt"


    Write-Utf8NoBom `
        -Path $p2f14SeedFile `
        -Text $p2f14SeedSql


    $p2f14FixtureExitFile =
        Join-Path $TempRoot "p2f14-fixture.exitcode.txt"

    $p2f14SeedProcess =
        Start-PsqlScriptProcess `
            -SqlFile $p2f14SeedFile `
            -StdOutFile $p2f14SeedOut `
            -StdErrFile $p2f14SeedErr `
            -ExitCodeFile $p2f14FixtureExitFile


    $p2f14SeedProcess.WaitForExit()

    if (-not (Test-Path -LiteralPath $p2f14FixtureExitFile -PathType Leaf)) {
        Write-Host (Read-WholeFile -Path $p2f14SeedOut)
        Write-Host (Read-WholeFile -Path $p2f14SeedErr)
        throw 'P2F-14 fixture psql exit-code file was not created.'
    }

    $p2f14FixtureExitRaw =
        [System.IO.File]::ReadAllText($p2f14FixtureExitFile).Trim()

    if ($p2f14FixtureExitRaw -notmatch '^(0|[1-9][0-9]*)$') {
        Write-Host (Read-WholeFile -Path $p2f14SeedOut)
        Write-Host (Read-WholeFile -Path $p2f14SeedErr)
        throw "P2F-14 fixture exit-code file malformed: '$p2f14FixtureExitRaw'"
    }

    $p2f14FixturePsqlExitCode = [int]$p2f14FixtureExitRaw
    Write-Host "P2F14_FIXTURE_PSQL_EXIT_CODE|$p2f14FixturePsqlExitCode"
    Write-Host "P2F14_FIXTURE_LAUNCHER_EXIT_CODE|$($p2f14SeedProcess.ExitCode)"


    if ($p2f14FixturePsqlExitCode -ne 0) {
        Write-Host (Read-WholeFile -Path $p2f14SeedOut)
        Write-Host (Read-WholeFile -Path $p2f14SeedErr)

        throw "P2F-14 contactless receiver fixture preparation failed."
    }


    $p2f14FixtureStdoutText = Read-WholeFile -Path $p2f14SeedOut
    $p2f14FixtureStderrText = Read-WholeFile -Path $p2f14SeedErr
    if (
        $p2f14FixtureStdoutText -notmatch '(?m)^COMMIT\s*$' -or
        -not [string]::IsNullOrWhiteSpace($p2f14FixtureStderrText)
    ) {
        Write-Host $p2f14FixtureStdoutText
        Write-Host $p2f14FixtureStderrText
        throw 'P2F-14 fixture exit code was zero but COMMIT/stderr evidence is inconsistent.'
    }
    Write-Host 'P2F14_FIXTURE_SQL_COMMIT_AND_CLEAN_STDERR|true'

    $p2f14FixtureShape =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-14 contactless fixture shape" `
            -Sql @"
select
  s.shipment_state::text
  || '|'
  || re.state::text
  || '|'
  || re.record_version
  || '|'
  || se.state::text
  || '|'
  || se.delivery_verification_state::text
  || '|'
  || w.review_required::text
  || '|'
  || w.configured_window_seconds
  || '|'
  || (w.expires_at > clock_timestamp())::text
  || '|'
  || (rat.used_at is null)::text
  || '|'
  || (
    select count(*)
    from haulvia.delivery_review_window_resolutions r
    where r.delivery_review_window_id = w.id
  )
  || '|'
  || (
    select count(*)
    from haulvia.receiver_confirmations rc
    where rc.stop_execution_id = se.id
  )
  || '|'
  || (
    select count(*)
    from haulvia.disputes d
    where d.shipment_id = c.shipment_id
  )
  || '|'
  || (
    select count(*)
    from haulvia.financial_holds fh
    where fh.shipment_id = c.shipment_id
  )
from p2f_test.receiver_review_race_context c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
join haulvia.stop_executions se
  on se.id = c.stop_execution_id
join haulvia.delivery_review_windows w
  on w.id = c.delivery_review_window_id
join haulvia.receiver_access_tokens rat
  on rat.id = c.receiver_access_token_id
where c.race_key = 'P2F-14';
"@


    Write-Host "P2F14_FIXTURE_PRE_RACE|$p2f14FixtureShape"


    if (
        $p2f14FixtureShape -ne
        "DELIVERED|COMPLETED|1|COMPLETED|PENDING_RECEIVER_CONFIRMATION|true|86400|true|true|0|0|0|0"
    ) {
        throw "P2F-14 fixture is not at the required pending receiver-review boundary."
    }


    $p2f14AuthorityShape =
        Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label "P2F-14 distinct valid command snapshots" `
            -Sql @"
select
  (
    (c.input_a ->> 'expectedShipmentVersion')::bigint
      = s.lock_version

    and

    (c.input_b ->> 'expectedShipmentVersion')::bigint
      = s.lock_version

    and

    (c.input_a ->> 'expectedRouteExecutionVersion')::bigint
      = re.record_version

    and

    (c.input_b ->> 'expectedRouteExecutionVersion')::bigint
      = re.record_version

    and

    (c.input_a ->> 'receiverAccessTokenId')::uuid
      = c.receiver_access_token_id

    and

    (c.input_b ->> 'receiverAccessTokenId')::uuid
      = c.receiver_access_token_id

    and

    c.input_a ->> 'idempotencyKey'
      <> c.input_b ->> 'idempotencyKey'

    and

    c.input_a ->> 'requestHash'
      <> c.input_b ->> 'requestHash'

    and

    (c.input_a ->> 'receiverTokenHash')
      = (c.input_b ->> 'receiverTokenHash')

    and

    jsonb_array_length(c.input_a -> 'cargoManifest') = 1

    and

    c.input_a -> 'cargoManifest'
      = c.input_b -> 'cargoManifest'
  )::text
from p2f_test.receiver_review_race_context c
join haulvia.shipments s
  on s.id = c.shipment_id
join haulvia.route_executions re
  on re.id = c.route_execution_id
where c.race_key = 'P2F-14';
"@


    Write-Host "P2F14_FIXTURE_AUTHORITY|$p2f14AuthorityShape"


    if ($p2f14AuthorityShape -ne "true") {
        throw "P2F-14 receiver command versions, authority or cargo snapshots are inconsistent."
    }


    Write-Host ""
    Write-Host "P2F-14 CONTACTLESS FIXTURE PREPARATION PASSED"
    Write-Host "PASS: independent contactless delivery fixture prepared."
    Write-Host "PASS: pending receiver window and single-use token available."
    Write-Host "PASS: D01 and D02 requests persist against the same window."
    Write-Host "PASS: no receiver, dispute, hold or resolution yet exists."
    Write-Host "PASS: P2F-14 race has not been executed."
    Write-Host "PASS: official authority remains 5 / 8."
    Write-Host ""

    # ========================================================================
    # P2F-14: D01 receiver receipt vs D02 receiver damage/problem race.
    # The two independent sessions wait on an EXCLUSIVE advisory gate and
    # execute only after both waiters are observed. No artificial sleeps
    # inside business command transactions. A failed gate terminates actors
    # before releasing the gate, to avoid an unproven sequential execution.
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-14 D01/D02 RECEIVER RACE ================"
    Write-Host ""

    $p2f14GateFile = Join-Path $TempRoot 'p2f14-receiver-gate.sql'
    $p2f14GateOut = Join-Path $TempRoot 'p2f14-receiver-gate.stdout.txt'
    $p2f14GateErr = Join-Path $TempRoot 'p2f14-receiver-gate.stderr.txt'
    $p2f14ActorAFile = Join-Path $TempRoot 'p2f14-receiver-actor-a.sql'
    $p2f14ActorBFile = Join-Path $TempRoot 'p2f14-receiver-actor-b.sql'
    $p2f14ActorAOut = Join-Path $TempRoot 'p2f14-receiver-actor-a.stdout.txt'
    $p2f14ActorBOut = Join-Path $TempRoot 'p2f14-receiver-actor-b.stdout.txt'
    $p2f14ActorAErr = Join-Path $TempRoot 'p2f14-receiver-actor-a.stderr.txt'
    $p2f14ActorBErr = Join-Path $TempRoot 'p2f14-receiver-actor-b.stderr.txt'
    $p2f14ActorAExit = Join-Path $TempRoot 'p2f14-receiver-actor-a.exit.txt'
    $p2f14ActorBExit = Join-Path $TempRoot 'p2f14-receiver-actor-b.exit.txt'

    Write-Utf8NoBom -Path $p2f14GateFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f14_gate';
select pg_advisory_lock(214, 1401);
select pg_sleep(600);
"@
    Write-Utf8NoBom -Path $p2f14ActorAFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f14_actor_a';
select pg_advisory_lock_shared(214, 1401);
\echo P2F14_GATE_ACQUIRED_A
select 'P2F14_RESULT_A|' ||
       haulvia_command.command_confirm_receiver_receipt(c.input_a)::text
from p2f_test.receiver_review_race_context c
where c.race_key = 'P2F-14';
"@
    Write-Utf8NoBom -Path $p2f14ActorBFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f14_actor_b';
select pg_advisory_lock_shared(214, 1401);
\echo P2F14_GATE_ACQUIRED_B
select 'P2F14_RESULT_B|' ||
       haulvia_command.command_report_delivery_problem(c.input_b)::text
from p2f_test.receiver_review_race_context c
where c.race_key = 'P2F-14';
"@

    $p2f14GateReleased = $false
    $p2f14GateProcess = $null
    $p2f14ActorA = $null
    $p2f14ActorB = $null

    try {
        $p2f14GateProcess = Start-PsqlScriptProcess `
            -SqlFile $p2f14GateFile `
            -StdOutFile $p2f14GateOut `
            -StdErrFile $p2f14GateErr

        Wait-ForScalarValue -Expected '1' -Label 'P2F-14 exclusive advisory gate' -Sql @"
select count(*)
from pg_stat_activity a
join pg_locks l on l.pid = a.pid
where a.datname = current_database()
  and a.application_name = 'p2f14_gate'
  and l.locktype = 'advisory'
  and l.granted;
"@ | Out-Null
        Write-Host 'P2F14_RACE_GATE_HELD|1'

        $p2f14ActorA = Start-PsqlScriptProcess `
            -SqlFile $p2f14ActorAFile `
            -StdOutFile $p2f14ActorAOut `
            -StdErrFile $p2f14ActorAErr `
            -ExitCodeFile $p2f14ActorAExit
        $p2f14ActorB = Start-PsqlScriptProcess `
            -SqlFile $p2f14ActorBFile `
            -StdOutFile $p2f14ActorBOut `
            -StdErrFile $p2f14ActorBErr `
            -ExitCodeFile $p2f14ActorBExit

        Wait-ForScalarValue -Expected '2' -Label 'P2F-14 two advisory-lock waiters' -Sql @"
select count(distinct a.pid)
from pg_stat_activity a
join pg_locks l on l.pid = a.pid
where a.datname = current_database()
  and a.application_name in ('p2f14_actor_a','p2f14_actor_b')
  and l.locktype = 'advisory'
  and not l.granted;
"@ | Out-Null
        Write-Host 'P2F14_RACE_WAITERS|2'

        # Intentional release; never put pg_terminate_backend in a poll predicate.
        $p2f14GateRelease = Invoke-PsqlScalar `
            -Database $TargetDatabase `
            -Label 'P2F-14 release exclusive advisory gate' `
            -Sql @"
select pg_terminate_backend(pid)::text
from pg_stat_activity
where datname = current_database()
  and application_name = 'p2f14_gate'
  and pid <> pg_backend_pid()
limit 1;
"@
        Write-Host "P2F14_RACE_GATE_RELEASED|$p2f14GateRelease"
        if ($p2f14GateRelease -ne 'true' -and $p2f14GateRelease -ne 't') {
            throw 'P2F-14 exclusive gate could not be released.'
        }
        $p2f14GateReleased = $true
    }
    finally {
        if (-not $p2f14GateReleased) {
            # Cancel worker sessions while still blocked, then remove gate.
            # This protects against an unobserved sequential test after a
            # synchronization failure. These calls affect only this DB's
            # P2F-14 test sessions.
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                    -Label 'P2F-14 cancel unproven actors' -Sql @"
select pg_terminate_backend(pid)
from pg_stat_activity
where datname = current_database()
  and application_name in ('p2f14_actor_a','p2f14_actor_b')
  and pid <> pg_backend_pid();
"@ | Out-Null
            }
            catch { Write-Warning "P2F-14 actor cancellation warning: $_" }
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                    -Label 'P2F-14 release orphaned gate' -Sql @"
select pg_terminate_backend(pid)
from pg_stat_activity
where datname = current_database()
  and application_name = 'p2f14_gate'
  and pid <> pg_backend_pid();
"@ | Out-Null
            }
            catch { Write-Warning "P2F-14 gate cancellation warning: $_" }
        }
    }

    $p2f14ActorA.WaitForExit()
    $p2f14ActorB.WaitForExit()
    $p2f14GateProcess.WaitForExit()
    $p2f14OutA = Read-WholeFile -Path $p2f14ActorAOut
    $p2f14OutB = Read-WholeFile -Path $p2f14ActorBOut
    $p2f14ErrA = Read-WholeFile -Path $p2f14ActorAErr
    $p2f14ErrB = Read-WholeFile -Path $p2f14ActorBErr
    $p2f14ExitA = (Read-WholeFile -Path $p2f14ActorAExit).Trim()
    $p2f14ExitB = (Read-WholeFile -Path $p2f14ActorBExit).Trim()

    Write-Host '---- P2F-14 Actor A stdout ----'
    Write-Host $p2f14OutA
    Write-Host '---- P2F-14 Actor A stderr ----'
    Write-Host $p2f14ErrA
    Write-Host '---- P2F-14 Actor B stdout ----'
    Write-Host $p2f14OutB
    Write-Host '---- P2F-14 Actor B stderr ----'
    Write-Host $p2f14ErrB
    Write-Host "P2F14_RACE_EXIT_CODES|$p2f14ExitA|$p2f14ExitB"

    if ($p2f14ExitA -notmatch '^\d+$' -or $p2f14ExitB -notmatch '^\d+$') {
        throw 'P2F-14 actor exit-code evidence is incomplete.'
    }
    $p2f14SucceededA = $p2f14ExitA -eq '0'
    $p2f14SucceededB = $p2f14ExitB -eq '0'
    if ($p2f14SucceededA -eq $p2f14SucceededB) {
        throw 'P2F-14 did not produce exactly one committed D01/D02 winner.'
    }
    $p2f14Winner = if ($p2f14SucceededA) { 'A' } else { 'B' }
    $p2f14Loser = if ($p2f14SucceededA) { 'B' } else { 'A' }
    $p2f14WinnerOut = if ($p2f14SucceededA) { $p2f14OutA } else { $p2f14OutB }
    $p2f14LoserErr = if ($p2f14SucceededA) { $p2f14ErrB } else { $p2f14ErrA }
    $p2f14WinnerName = if ($p2f14SucceededA) { 'confirmReceiverReceipt' } else { 'reportDeliveryProblem' }
    $p2f14ExpectedState = if ($p2f14SucceededA) { 'RECEIVER_CONFIRMED' } else { 'ISSUE_REPORTED' }

    if ($p2f14LoserErr -notmatch 'STALE_SHIPMENT_VERSION|DELIVERY_REVIEW_ALREADY_RESOLVED') {
        throw 'P2F-14 losing command did not provide an accepted stale/resolved rejection code.'
    }
    $p2f14WinnerMatch = [regex]::Match(
        $p2f14WinnerOut,
        '(?m)^P2F14_RESULT_[AB]\|(\{[^\r\n]+\})\s*$'
    )
    if (-not $p2f14WinnerMatch.Success) {
        throw 'P2F-14 winning command JSON was not captured.'
    }
    $p2f14WinnerJson = $p2f14WinnerMatch.Groups[1].Value | ConvertFrom-Json
    if ($p2f14WinnerJson.replayed -ne $false -or
        $p2f14WinnerJson.commandName -ne $p2f14WinnerName -or
        $p2f14WinnerJson.deliveryVerificationState -ne $p2f14ExpectedState -or
        $p2f14WinnerJson.shipmentState -ne 'DELIVERED') {
        throw 'P2F-14 winner JSON does not match the expected canonical receiver outcome.'
    }
    Write-Host "P2F14_RACE_WINNER|$p2f14Winner|$p2f14WinnerName|$p2f14ExpectedState"
    Write-Host "P2F14_RACE_LOSER|$p2f14Loser|REJECTED"

    # Compare the irreversible receipt / dispute / financial and custody facts.
    # All values are produced from the persisted fixture and production tables.
    $p2f14PostSql = @"
select concat_ws('|',
  s.shipment_state::text,
  re.state::text,
  re.record_version::text,
  se.delivery_verification_state::text,
  re.next_action::text,
  (rat.used_at is not null)::text,
  (select count(*) from haulvia.delivery_review_window_resolutions x
   where x.delivery_review_window_id = c.delivery_review_window_id)::text,
  (select count(*) from haulvia.receiver_confirmations x
   where x.stop_execution_id = c.stop_execution_id)::text,
  (select count(*) from haulvia.delivery_problem_reports x
   where x.delivery_review_window_id = c.delivery_review_window_id)::text,
  (select count(*) from haulvia.disputes x
   where x.shipment_id = c.shipment_id)::text,
  (select count(*) from haulvia.financial_holds x
   where x.shipment_id = c.shipment_id)::text,
  (select count(*) from haulvia.route_resolution_records x
   where x.shipment_id = c.shipment_id)::text,
  (select count(*) from haulvia.cargo_movements x
   where x.shipment_id = c.shipment_id and x.movement_type = 'LOAD')::text,
  (select count(*) from haulvia.cargo_movements x
   where x.shipment_id = c.shipment_id and x.movement_type = 'UNLOAD')::text,
  (select count(*) from haulvia.cargo_resolution_outcomes x
   where x.shipment_id = c.shipment_id and x.outcome_code = 'DELIVERED')::text,
  (select count(*) from haulvia.audit_events x
   where x.entity_table = 'shipments' and x.entity_id = c.shipment_id
     and x.command_name in ('confirmReceiverReceipt','reportDeliveryProblem'))::text,
  (select count(*) from haulvia.workflow_axis_events x
   where x.shipment_id = c.shipment_id and x.axis = 'DELIVERY_VERIFICATION'
     and x.command_name in ('confirmReceiverReceipt','reportDeliveryProblem'))::text,
  (s.lock_version = ((c.input_a ->> 'expectedShipmentVersion')::bigint + 1))::text,
  exists(select 1 from haulvia.financial_holds x
   where x.shipment_id = c.shipment_id and x.amount = 25
     and x.hold_code = 'DISPUTED_AMOUNT' and x.status = 'ACTIVE')::text
)
from p2f_test.receiver_review_race_context c
join haulvia.shipments s on s.id = c.shipment_id
join haulvia.route_executions re on re.id = c.route_execution_id
join haulvia.stop_executions se on se.id = c.stop_execution_id
join haulvia.receiver_access_tokens rat on rat.id = c.receiver_access_token_id
where c.race_key = 'P2F-14';
"@
    $p2f14PostState = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-14 canonical post-race database state' -Sql $p2f14PostSql
    Write-Host "P2F14_RACE_POST_STATE|$p2f14PostState"

    $p2f14ExpectedPost = if ($p2f14SucceededA) {
        'DELIVERED|COMPLETED|2|RECEIVER_CONFIRMED|AWAIT_SHIPMENT_COMPLETION|true|1|1|0|0|0|1|1|1|1|1|1|true|false'
    } else {
        'DELIVERED|COMPLETED|2|ISSUE_REPORTED|AWAIT_DISPUTE_RESOLUTION|true|1|1|1|1|1|1|1|1|1|1|1|true|true'
    }
    if ($p2f14PostState -ne $p2f14ExpectedPost) {
        throw 'P2F-14 post-race canonical operational/financial fact cardinality mismatch.'
    }

    # Exact replay of the winning, frozen JSON request must reuse its result.
    $p2f14ReplaySql = if ($p2f14SucceededA) {
        @"
select haulvia_command.command_confirm_receiver_receipt(input_a)::text
from p2f_test.receiver_review_race_context where race_key = 'P2F-14';
"@
    } else {
        @"
select haulvia_command.command_report_delivery_problem(input_b)::text
from p2f_test.receiver_review_race_context where race_key = 'P2F-14';
"@
    }
    $p2f14ReplayText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-14 exact winner idempotent replay' -Sql $p2f14ReplaySql
    Write-Host "P2F14_RACE_REPLAY|$p2f14ReplayText"
    $p2f14ReplayJson = $p2f14ReplayText | ConvertFrom-Json
    if ($p2f14ReplayJson.replayed -ne $true -or
        $p2f14ReplayJson.deliveryReviewResolutionId -ne $p2f14WinnerJson.deliveryReviewResolutionId -or
        $p2f14ReplayJson.receiverConfirmationId -ne $p2f14WinnerJson.receiverConfirmationId) {
        throw 'P2F-14 exact replay changed the canonical receiver-review result.'
    }
    $p2f14ReplayPost = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-14 idempotent replay residue' -Sql $p2f14PostSql
    Write-Host "P2F14_RACE_REPLAY_POST_STATE|$p2f14ReplayPost"
    if ($p2f14ReplayPost -ne $p2f14PostState) {
        throw 'P2F-14 exact replay changed operational, financial, audit, or custody facts.'
    }

    # Same key, different hash must fail closed before stale-version checks.
    $p2f14ConflictSql = if ($p2f14SucceededA) {
        @"
select haulvia_command.command_confirm_receiver_receipt(
  input_a || jsonb_build_object('requestHash', repeat('c',64)))::text
from p2f_test.receiver_review_race_context where race_key = 'P2F-14';
"@
    } else {
        @"
select haulvia_command.command_report_delivery_problem(
  input_b || jsonb_build_object('requestHash', repeat('c',64)))::text
from p2f_test.receiver_review_race_context where race_key = 'P2F-14';
"@
    }
    $p2f14Conflict = Invoke-PsqlAllowFailure -Database $TargetDatabase `
        -Sql $p2f14ConflictSql
    Write-Host "P2F14_RACE_IDEMPOTENCY_CONFLICT_EXIT|$($p2f14Conflict.ExitCode)"
    if ($p2f14Conflict.ExitCode -eq 0 -or
        $p2f14Conflict.Text -notmatch 'IDEMPOTENCY_KEY_REUSED') {
        throw 'P2F-14 same-key/different-hash request was not rejected.'
    }

    # Failed command may not persist any audit or workflow-axis residue.
    $p2f14LoserKey = if ($p2f14SucceededA) {
        'p2f14-report-damage'
    } else {
        'p2f14-receiver-confirm'
    }
    $p2f14LoserResidue = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-14 rejected actor residue' -Sql @"
select concat_ws('|',
  (select count(*) from haulvia.audit_events a
   where a.idempotency_key = '$p2f14LoserKey')::text,
  (select count(*) from haulvia.workflow_axis_events e
   where e.idempotency_key like '$p2f14LoserKey%')::text,
  (select count(*) from haulvia.receiver_confirmations r
   where r.idempotency_key = '$p2f14LoserKey')::text,
  (select count(*) from haulvia.delivery_problem_reports p
   where p.idempotency_key = '$p2f14LoserKey')::text,
  (select count(*) from haulvia.delivery_review_window_resolutions w
   where w.idempotency_key = '$p2f14LoserKey')::text
);
"@
    Write-Host "P2F14_RACE_LOSER_RESIDUE|$p2f14LoserResidue"
    if ($p2f14LoserResidue -ne '0|0|0|0|0') {
        throw 'P2F-14 losing receiver command persisted attributable residue.'
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'P2F-14 RECEIVER REVIEW RACE PASSED'
    Write-Host '============================================================'
    Write-Host 'PASS: both D01 and D02 waited on an exclusive advisory gate.'
    Write-Host 'PASS: exactly one receiver response committed.'
    Write-Host 'PASS: losing action rejected without attributable audit or workflow residue.'
    Write-Host 'PASS: exactly one immutable review-window resolution exists.'
    Write-Host 'PASS: disputes and financial holds are conditional on D02 victory.'
    Write-Host 'PASS: original route resolution and LOAD/UNLOAD ledger remain unchanged.'
    Write-Host 'PASS: exact winning request replay is idempotent.'
    Write-Host 'PASS: same-key/different-hash reuse fails closed.'
    Write-Host ''
    Write-Host 'P2F concurrency progress: 6 / 8 race domains.'
    Write-Host 'Next required domain: P2F-15 Payout race.'
    Write-Host ''

    # ========================================================================
    # P2F-15A: D06 payout submission race. This is only sub-race 1/3;
    # D07/D08 callback competition and failed-request retry remain pending.
    # Reuse the P2A/P2D-compatible, runtime-verified P2F-14 Block D fixture
    # helpers rather than reseeding a legacy admin role or storage columns.
    # ========================================================================
    Write-Host ''
    Write-Host '================ P2F-15A D06 PAYOUT SUBMISSION FIXTURE ================'
    Write-Host ''

    $p2f15EnvelopeSource = Get-P2F14SourceSection `
        -Start 'create or replace function pg_temp.envelope(' `
        -End '-- Shared customer, provider, policy, pricing, and sensitive-admin fixtures.'
    $p2f15CompletedSource = Get-P2F14SourceSection `
        -Start 'create or replace function pg_temp.resolve_and_complete(' `
        -End '-- D01: verified receiver result is stop-scoped, first-valid, and replay-safe.'
    foreach ($segment in @(
        $p2f15EnvelopeSource,
        $p2f14DeliveredSeedSource,
        $p2f14ManifestSource,
        $p2f15CompletedSource
    )) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            throw 'P2F-15A required Block D fixture section was not extracted.'
        }
    }
    if ($p2f14DeliveredSeedSource.Contains('storage_object_key') -or
        $p2f14DeliveredSeedSource.Contains('content_sha256')) {
        throw 'P2F-15A refuses to reuse a pre-P2D stop-evidence fixture.'
    }

    $p2f15SeedFile = Join-Path $TempRoot 'p2f15a-fixture.sql'
    $p2f15SeedOut = Join-Path $TempRoot 'p2f15a-fixture.stdout.txt'
    $p2f15SeedErr = Join-Path $TempRoot 'p2f15a-fixture.stderr.txt'
    $p2f15SeedExit = Join-Path $TempRoot 'p2f15a-fixture.exit.txt'
    $p2f15SeedHead = @"
\set ON_ERROR_STOP on
begin;
set local search_path = haulvia, haulvia_command, public;
"@
    $p2f15SeedTail = @'
create table p2f_test.payout_submit_race_context (
    race_key text primary key,
    shipment_id uuid not null,
    payout_id uuid not null,
    payout_eligibility_record_id uuid not null,
    shipment_completion_record_id uuid not null,
    expected_shipment_version bigint not null,
    input_a jsonb not null,
    input_b jsonb not null
);
do $$
declare
  v_f jsonb := pg_temp.resolve_and_complete('p2f15-d06-submission');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_payout uuid := (v_f ->> 'payoutId')::uuid;
  v_a jsonb;
  v_b jsonb;
begin
  if not exists (
     select 1 from haulvia.shipments s
     join haulvia.driver_payouts p on p.shipment_id = s.id
     join haulvia.shipment_driver_payout_axes ax on ax.shipment_id = s.id
     where s.id = v_shipment and s.shipment_state = 'COMPLETED'
       and p.id = v_payout and p.state = 'READY' and p.net_amount = 90
       and ax.state = 'READY'
       and (select count(*) from haulvia.payout_eligibility_records e
            where e.shipment_id = v_shipment) = 1
       and (select count(*) from haulvia.shipment_completion_records sc
            where sc.shipment_id = v_shipment) = 1
       and not exists (select 1 from haulvia.payout_transactions pt
            where pt.payout_id = v_payout)
       and not exists (select 1 from haulvia.financial_holds fh
            where fh.shipment_id = v_shipment and fh.status = 'ACTIVE')
  ) then
    raise exception 'P2F-15A fixture is not COMPLETED/READY with clean payout balance';
  end if;
  v_a := pg_temp.envelope(v_shipment, null, 'p2f15a-submit-a', 'a') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_WORKER',
      'expectedPayoutId', v_payout,
      'payoutAmount', 90,
      'externalProvider', 'p2f15-test-provider',
      'providerIdempotencyKey', 'p2f15a-provider-a',
      'payoutAccountReference', 'acct_p2f15a_local',
      'payoutAccountValid', true,
      'providerRequest', jsonb_build_object('rail', 'EFT')
    );
  v_b := pg_temp.envelope(v_shipment, null, 'p2f15a-submit-b', 'b') ||
    jsonb_build_object(
      'workerAuthority', 'PAYOUT_WORKER',
      'expectedPayoutId', v_payout,
      'payoutAmount', 90,
      'externalProvider', 'p2f15-test-provider',
      'providerIdempotencyKey', 'p2f15a-provider-b',
      'payoutAccountReference', 'acct_p2f15a_local',
      'payoutAccountValid', true,
      'providerRequest', jsonb_build_object('rail', 'EFT')
    );
  insert into p2f_test.payout_submit_race_context (
     race_key, shipment_id, payout_id, payout_eligibility_record_id,
     shipment_completion_record_id, expected_shipment_version,
     input_a, input_b
  ) values (
     'P2F-15A', v_shipment, v_payout,
     (v_f ->> 'payoutEligibilityRecordId')::uuid,
     (v_f ->> 'shipmentCompletionRecordId')::uuid,
     (v_a ->> 'expectedShipmentVersion')::bigint,
     v_a, v_b
  );
end;
$$;
commit;
'@
    $p2f15SeedSql = @(
        $p2f15SeedHead,
        $p2f15EnvelopeSource,
        $p2f14DeliveredSeedSource,
        $p2f14ManifestSource,
        $p2f15CompletedSource,
        $p2f15SeedTail
    ) -join "`n"
    Write-Utf8NoBom -Path $p2f15SeedFile -Text ($p2f15SeedSql.TrimEnd() + "`n")
    $p2f15SeedProcess = Start-PsqlScriptProcess `
        -SqlFile $p2f15SeedFile `
        -StdOutFile $p2f15SeedOut `
        -StdErrFile $p2f15SeedErr `
        -ExitCodeFile $p2f15SeedExit
    $p2f15SeedProcess.WaitForExit()
    $p2f15SeedExitText = (Read-WholeFile -Path $p2f15SeedExit).Trim()
    $p2f15SeedStdout = Read-WholeFile -Path $p2f15SeedOut
    $p2f15SeedStderr = Read-WholeFile -Path $p2f15SeedErr
    Write-Host "P2F15A_FIXTURE_PSQL_EXIT_CODE|$p2f15SeedExitText"
    if ($p2f15SeedExitText -ne '0' -or
        $p2f15SeedStdout -notmatch '(?m)^COMMIT\s*$' -or
        -not [string]::IsNullOrWhiteSpace($p2f15SeedStderr)) {
        Write-Host $p2f15SeedStdout
        Write-Host $p2f15SeedStderr
        throw 'P2F-15A completed payout fixture did not commit cleanly.'
    }
    $p2f15Pre = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15A completed READY payout fixture' -Sql @"
select concat_ws('|', s.shipment_state::text, p.state::text,
                  a.state::text, p.net_amount::text,
                  (select count(*) from haulvia.payout_transactions pt
                   where pt.payout_id=c.payout_id)::text,
                  (select count(*) from haulvia.financial_holds fh
                   where fh.shipment_id=c.shipment_id and fh.status='ACTIVE')::text,
                  (c.input_a ->> 'expectedShipmentVersion' =
                   c.input_b ->> 'expectedShipmentVersion')::text)
from p2f_test.payout_submit_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.driver_payouts p on p.id=c.payout_id
join haulvia.shipment_driver_payout_axes a on a.shipment_id=c.shipment_id
where c.race_key='P2F-15A';
"@
    Write-Host "P2F15A_PRE_RACE|$p2f15Pre"
    if ($p2f15Pre -ne 'COMPLETED|READY|READY|90.00|0|0|true') {
        throw 'P2F-15A pre-race completion/eligibility state mismatch.'
    }
    Write-Host 'P2F-15A completed payout fixture prepared; two distinct D06 inputs share one version.'

    # Real independent psql actor processes, synchronized before D06.
    Write-Host ''
    Write-Host '================ P2F-15A D06 SUBMISSION RACE ================'
    $p2f15GateFile = Join-Path $TempRoot 'p2f15a-gate.sql'
    $p2f15GateOut = Join-Path $TempRoot 'p2f15a-gate.stdout.txt'
    $p2f15GateErr = Join-Path $TempRoot 'p2f15a-gate.stderr.txt'
    $p2f15AFile = Join-Path $TempRoot 'p2f15a-actor-a.sql'
    $p2f15BFile = Join-Path $TempRoot 'p2f15a-actor-b.sql'
    $p2f15AOut = Join-Path $TempRoot 'p2f15a-actor-a.stdout.txt'
    $p2f15BOut = Join-Path $TempRoot 'p2f15a-actor-b.stdout.txt'
    $p2f15AErr = Join-Path $TempRoot 'p2f15a-actor-a.stderr.txt'
    $p2f15BErr = Join-Path $TempRoot 'p2f15a-actor-b.stderr.txt'
    $p2f15AExit = Join-Path $TempRoot 'p2f15a-actor-a.exit.txt'
    $p2f15BExit = Join-Path $TempRoot 'p2f15a-actor-b.exit.txt'
    Write-Utf8NoBom -Path $p2f15GateFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15a_gate';
select pg_advisory_lock(215,1501);
select pg_sleep(600);
"@
    Write-Utf8NoBom -Path $p2f15AFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15a_actor_a';
select pg_advisory_lock_shared(215,1501);
\echo P2F15A_GATE_ACQUIRED_A
select 'P2F15A_RESULT_A|' ||
  haulvia_command.command_submit_driver_payout(c.input_a)::text
from p2f_test.payout_submit_race_context c
where c.race_key = 'P2F-15A';
"@
    Write-Utf8NoBom -Path $p2f15BFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15a_actor_b';
select pg_advisory_lock_shared(215,1501);
\echo P2F15A_GATE_ACQUIRED_B
select 'P2F15A_RESULT_B|' ||
  haulvia_command.command_submit_driver_payout(c.input_b)::text
from p2f_test.payout_submit_race_context c
where c.race_key = 'P2F-15A';
"@
    $p2f15GateReleased = $false
    $p2f15GateProcess = $null
    $p2f15ActorA = $null
    $p2f15ActorB = $null
    try {
        $p2f15GateProcess = Start-PsqlScriptProcess `
            -SqlFile $p2f15GateFile -StdOutFile $p2f15GateOut -StdErrFile $p2f15GateErr
        Wait-ForScalarValue -Expected '1' -Label 'P2F-15A exclusive gate' -Sql @"
select count(*) from pg_stat_activity a
join pg_locks l on l.pid=a.pid
where a.datname=current_database() and a.application_name='p2f15a_gate'
  and l.locktype='advisory' and l.granted;
"@ | Out-Null
        Write-Host 'P2F15A_GATE_HELD|1'
        $p2f15ActorA = Start-PsqlScriptProcess `
            -SqlFile $p2f15AFile -StdOutFile $p2f15AOut `
            -StdErrFile $p2f15AErr -ExitCodeFile $p2f15AExit
        $p2f15ActorB = Start-PsqlScriptProcess `
            -SqlFile $p2f15BFile -StdOutFile $p2f15BOut `
            -StdErrFile $p2f15BErr -ExitCodeFile $p2f15BExit
        Wait-ForScalarValue -Expected '2' -Label 'P2F-15A two worker waiters' -Sql @"
select count(distinct a.pid) from pg_stat_activity a
join pg_locks l on l.pid=a.pid
where a.datname=current_database()
  and a.application_name in ('p2f15a_actor_a','p2f15a_actor_b')
  and l.locktype='advisory' and not l.granted;
"@ | Out-Null
        Write-Host 'P2F15A_WAITERS|2'
        $p2f15GateRelease = Invoke-PsqlScalar -Database $TargetDatabase `
            -Label 'P2F-15A gate release' -Sql @"
select pg_terminate_backend(pid)::text from pg_stat_activity
where datname=current_database() and application_name='p2f15a_gate'
 and pid<>pg_backend_pid() limit 1;
"@
        Write-Host "P2F15A_GATE_RELEASED|$p2f15GateRelease"
        if ($p2f15GateRelease -notin @('true','t')) {
            throw 'P2F-15A gate could not be released.'
        }
        $p2f15GateReleased = $true
    }
    finally {
        if (-not $p2f15GateReleased) {
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                  -Label 'P2F-15A cancel unproven workers' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database()
 and application_name in ('p2f15a_actor_a','p2f15a_actor_b')
 and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-15A worker cleanup warning: $_" }
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                  -Label 'P2F-15A release orphan gate' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database() and application_name='p2f15a_gate'
 and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-15A gate cleanup warning: $_" }
        }
    }
    $p2f15ActorA.WaitForExit()
    $p2f15ActorB.WaitForExit()
    $p2f15GateProcess.WaitForExit()
    $p2f15StdA = Read-WholeFile -Path $p2f15AOut
    $p2f15StdB = Read-WholeFile -Path $p2f15BOut
    $p2f15ErrA = Read-WholeFile -Path $p2f15AErr
    $p2f15ErrB = Read-WholeFile -Path $p2f15BErr
    $p2f15ExitA = (Read-WholeFile -Path $p2f15AExit).Trim()
    $p2f15ExitB = (Read-WholeFile -Path $p2f15BExit).Trim()
    Write-Host '---- P2F-15A Worker A stdout ----'
    Write-Host $p2f15StdA
    Write-Host '---- P2F-15A Worker A stderr ----'
    Write-Host $p2f15ErrA
    Write-Host '---- P2F-15A Worker B stdout ----'
    Write-Host $p2f15StdB
    Write-Host '---- P2F-15A Worker B stderr ----'
    Write-Host $p2f15ErrB
    Write-Host "P2F15A_EXIT_CODES|$p2f15ExitA|$p2f15ExitB"
    if ($p2f15ExitA -notmatch '^\d+$' -or $p2f15ExitB -notmatch '^\d+$') {
        throw 'P2F-15A actor process exit evidence missing.'
    }
    $p2f15WinA = $p2f15ExitA -eq '0'
    $p2f15WinB = $p2f15ExitB -eq '0'
    if ($p2f15WinA -eq $p2f15WinB) {
        throw 'P2F-15A must have exactly one successful D06 submission.'
    }
    $p2f15Winner = if ($p2f15WinA) { 'A' } else { 'B' }
    $p2f15Loser = if ($p2f15WinA) { 'B' } else { 'A' }
    $p2f15WinnerOut = if ($p2f15WinA) { $p2f15StdA } else { $p2f15StdB }
    $p2f15LoserErr = if ($p2f15WinA) { $p2f15ErrB } else { $p2f15ErrA }
    $p2f15LoserKey = if ($p2f15WinA) { 'p2f15a-submit-b' } else { 'p2f15a-submit-a' }
    $p2f15LoserProviderKey = if ($p2f15WinA) { 'p2f15a-provider-b' } else { 'p2f15a-provider-a' }
    if ($p2f15LoserErr -notmatch 'STALE_SHIPMENT_VERSION|PAYOUT_AMOUNT_UNAVAILABLE') {
        throw 'P2F-15A losing command did not fail through an accepted stale/unavailable path.'
    }
    $p2f15WinnerMatch = [regex]::Match($p2f15WinnerOut,
        '(?m)^P2F15A_RESULT_[AB]\|(\{[^\r\n]+\})\s*$')
    if (-not $p2f15WinnerMatch.Success) {
        throw 'P2F-15A winner JSON was not captured.'
    }
    $p2f15Result = $p2f15WinnerMatch.Groups[1].Value | ConvertFrom-Json
    if ($p2f15Result.replayed -ne $false -or
        $p2f15Result.commandName -ne 'submitDriverPayout' -or
        $p2f15Result.driverPayoutState -ne 'PROCESSING' -or
        $p2f15Result.shipmentState -ne 'COMPLETED' -or
        [decimal]$p2f15Result.payoutAmount -ne [decimal]90 -or
        -not $p2f15Result.payoutTransactionId) {
        throw 'P2F-15A winning request did not create the expected pending payout.'
    }
    Write-Host "P2F15A_WINNER|$p2f15Winner|submitDriverPayout"
    Write-Host "P2F15A_LOSER|$p2f15Loser|REJECTED"

    $p2f15PostSql = @"
select concat_ws('|', s.shipment_state::text, dp.state::text,
  ax.state::text, s.lock_version::text,
  (select count(*) from haulvia.driver_payouts x
    where x.assignment_id=dp.assignment_id)::text,
  (select count(*) from haulvia.payout_eligibility_records x
    where x.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.shipment_completion_records x
    where x.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.payout_transactions x
    where x.payout_id=c.payout_id and x.status='PENDING'
    and not exists (select 1 from haulvia.payout_transactions y
                    where y.request_transaction_id=x.id))::text,
  (select count(*) from haulvia.payout_transactions x
    where x.payout_id=c.payout_id and x.status='SUCCEEDED')::text,
  (select count(*) from haulvia.payout_transactions x
    where x.payout_id=c.payout_id and x.status='FAILED')::text,
  (select coalesce(sum(x.amount),0) from haulvia.payout_transactions x
    where x.payout_id=c.payout_id and x.status='PENDING')::text,
  (select count(*) from haulvia.financial_holds fh
    where fh.shipment_id=c.shipment_id and fh.status='ACTIVE')::text,
  (select count(*) from haulvia.audit_events a
    where a.entity_table='shipments' and a.entity_id=c.shipment_id
      and a.command_name='submitDriverPayout')::text,
  (select count(*) from haulvia.workflow_axis_events e
    where e.shipment_id=c.shipment_id and e.axis='DRIVER_PAYOUT'
      and e.command_name='submitDriverPayout')::text,
  (s.lock_version=c.expected_shipment_version)::text,
  (select count(distinct x.idempotency_key)=1 from haulvia.payout_transactions x
    where x.payout_id=c.payout_id and x.status='PENDING')::text
)
from p2f_test.payout_submit_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.driver_payouts dp on dp.id=c.payout_id
join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=c.shipment_id
where c.race_key='P2F-15A';
"@
    $p2f15Post = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15A canonical payout post-state' -Sql $p2f15PostSql
    Write-Host "P2F15A_POST_STATE|$p2f15Post"
    $p2f15Fields = $p2f15Post.Split('|')
    if ($p2f15Fields.Count -ne 16 -or
        $p2f15Fields[0] -ne 'COMPLETED' -or
        $p2f15Fields[1] -ne 'PROCESSING' -or
        $p2f15Fields[2] -ne 'PROCESSING' -or
        (@($p2f15Fields[4..9]) -join '|') -ne '1|1|1|1|0|0' -or
        [decimal]$p2f15Fields[10] -ne [decimal]90 -or
        (@($p2f15Fields[11..15]) -join '|') -ne '0|1|1|true|true') {
        throw 'P2F-15A payout transaction, eligibility, or audit cardinality mismatch.'
    }
    $p2f15WinnerBinding = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15A winner transaction binding' -Sql @"
select concat_ws('|',
  (pt.id = '$($p2f15Result.payoutTransactionId)'::uuid)::text,
  (pt.status='PENDING')::text,
  (pt.amount=90)::text,
  (pt.external_provider='p2f15-test-provider')::text,
  (pt.idempotency_key='p2f15a-provider-$($p2f15Winner.ToLowerInvariant())')::text)
from p2f_test.payout_submit_race_context c
join haulvia.payout_transactions pt on pt.payout_id=c.payout_id
where c.race_key='P2F-15A';
"@
    Write-Host "P2F15A_WINNER_BINDING|$p2f15WinnerBinding"
    if ($p2f15WinnerBinding -ne 'true|true|true|true|true') {
        throw 'P2F-15A winner payout transaction is not bound to the winning request.'
    }

    $p2f15WinnerInput = if ($p2f15WinA) { 'input_a' } else { 'input_b' }
    $p2f15ReplayText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15A exact command replay' -Sql @"
select haulvia_command.command_submit_driver_payout($p2f15WinnerInput)::text
from p2f_test.payout_submit_race_context where race_key='P2F-15A';
"@
    Write-Host "P2F15A_REPLAY|$p2f15ReplayText"
    $p2f15Replay = $p2f15ReplayText | ConvertFrom-Json
    if ($p2f15Replay.replayed -ne $true -or
        $p2f15Replay.payoutTransactionId -ne $p2f15Result.payoutTransactionId) {
        throw 'P2F-15A winning request did not replay the same payout transaction.'
    }
    $p2f15PostReplay = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15A replay did not change financial facts' -Sql $p2f15PostSql
    Write-Host "P2F15A_REPLAY_STATE|$p2f15PostReplay"
    if ($p2f15PostReplay -ne $p2f15Post) {
        throw 'P2F-15A replay duplicated or mutated financial facts.'
    }
    $p2f15Conflict = Invoke-PsqlAllowFailure -Database $TargetDatabase -Sql @"
select haulvia_command.command_submit_driver_payout(
  $p2f15WinnerInput || jsonb_build_object('requestHash', repeat('f',64)))::text
from p2f_test.payout_submit_race_context where race_key='P2F-15A';
"@
    Write-Host "P2F15A_IDEMPOTENCY_CONFLICT_EXIT|$($p2f15Conflict.ExitCode)"
    if ($p2f15Conflict.ExitCode -eq 0 -or
        $p2f15Conflict.Text -notmatch 'IDEMPOTENCY_KEY_REUSED') {
        throw 'P2F-15A same key/different hash failed open.'
    }
    $p2f15Residue = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15A losing worker residue' -Sql @"
select concat_ws('|',
  (select count(*) from haulvia.payout_transactions t
    where t.idempotency_key='$p2f15LoserProviderKey')::text,
  (select count(*) from haulvia.audit_events a
    where a.idempotency_key='$p2f15LoserKey')::text,
  (select count(*) from haulvia.workflow_axis_events e
    where e.idempotency_key='$p2f15LoserKey')::text,
  (select count(*) from haulvia.command_idempotency c
    where c.idempotency_key='$p2f15LoserKey')::text);
"@
    Write-Host "P2F15A_LOSER_RESIDUE|$p2f15Residue"
    if ($p2f15Residue -ne '0|0|0|0') {
        throw 'P2F-15A losing worker persisted payout or command residue.'
    }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'P2F-15A D06 SUBMISSION RACE PASSED'
    Write-Host '============================================================'
    Write-Host 'PASS: two independent PAYOUT_WORKER sessions waited on an exclusive gate.'
    Write-Host 'PASS: exactly one D06 request submitted 90 CAD; the loser was rejected.'
    Write-Host 'PASS: one payout/eligibility/completion fact; one pending, no provider settlement.'
    Write-Host 'PASS: winning request replay and same-key hash conflict enforced.'
    Write-Host 'PASS: losing request left zero command, payout, axis, or audit residue.'
    Write-Host 'P2F-15 internal progress: 1 / 3 payout sub-races.'
    Write-Host 'P2F-15 remains NON-AUTHORITATIVE until provider callback and retry races pass.'
    Write-Host 'Official P2F concurrency progress remains 6 / 8 race domains.'
    Write-Host ''


    # ========================================================================
    # P2F-15B: D07 versus D08 on one already-submitted D06 request.
    # A separate callback must be allowed to win, but both cannot commit.
    # This is payout sub-race 2/3, NOT the P2F-15 domain pass.
    # ========================================================================
    Write-Host ''
    Write-Host '================ P2F-15B D07/D08 CALLBACK FIXTURE ================'
    $p2f15bSeedFile = Join-Path $TempRoot 'p2f15b-fixture.sql'
    $p2f15bSeedOut  = Join-Path $TempRoot 'p2f15b-fixture.stdout.txt'
    $p2f15bSeedErr  = Join-Path $TempRoot 'p2f15b-fixture.stderr.txt'
    $p2f15bSeedExit = Join-Path $TempRoot 'p2f15b-fixture.exit.txt'
    $p2f15bSeedSql = @'
\set ON_ERROR_STOP on
begin;
set local search_path = haulvia, haulvia_command, public;
create table p2f_test.payout_callback_race_context (
  race_key text primary key,
  shipment_id uuid not null,
  payout_id uuid not null,
  payout_request_transaction_id uuid not null,
  expected_shipment_version bigint not null,
  input_success jsonb not null,
  input_failure jsonb not null
);
do $$
declare
  v_shipment uuid;
  v_payout uuid;
  v_request uuid;
  v_version bigint;
  v_success jsonb;
  v_failure jsonb;
begin
  select c.shipment_id, c.payout_id, ptx.id, s.lock_version
  into strict v_shipment, v_payout, v_request, v_version
  from p2f_test.payout_submit_race_context c
  join haulvia.shipments s on s.id=c.shipment_id
  join haulvia.driver_payouts p on p.id=c.payout_id
  join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=c.shipment_id
  join haulvia.payout_transactions ptx on ptx.payout_id=c.payout_id
  where c.race_key='P2F-15A'
    and s.shipment_state='COMPLETED'
    and p.state='PROCESSING' and ax.state='PROCESSING'
    and p.net_amount=90
    and ptx.status='PENDING' and ptx.amount=90
    and ptx.external_provider='p2f15-test-provider'
    and not exists (select 1 from haulvia.payout_transactions outcome
                    where outcome.request_transaction_id=ptx.id)
    and (select count(*) from haulvia.payout_transactions t
         where t.payout_id=c.payout_id)=1
    and (select count(*) from haulvia.driver_payouts dp
         where dp.assignment_id=p.assignment_id)=1
    and (select count(*) from haulvia.payout_eligibility_records e
         where e.shipment_id=c.shipment_id)=1
    and (select count(*) from haulvia.shipment_completion_records sc
         where sc.shipment_id=c.shipment_id)=1
    and not exists(select 1 from haulvia.financial_holds fh
                   where fh.shipment_id=c.shipment_id and fh.status='ACTIVE');
  v_success:=jsonb_build_object(
    'commandId',gen_random_uuid(),
    'idempotencyKey','p2f15b-confirm-success',
    'requestHash',repeat('c',64),
    'shipmentId',v_shipment,
    'expectedShipmentVersion',v_version,
    'requestedAt',clock_timestamp(),
    'workerAuthority','PAYOUT_PROVIDER_CALLBACK',
    'expectedPayoutId',v_payout,
    'payoutRequestTransactionId',v_request,
    'payoutAmount',90,
    'externalProvider','p2f15-test-provider',
    'providerEventId','p2f15b-event-success',
    'externalReference','p2f15b-paid-reference',
    'providerOccurredAt',clock_timestamp(),
    'providerResponse',jsonb_build_object('status','paid')
  );
  v_failure:=jsonb_build_object(
    'commandId',gen_random_uuid(),
    'idempotencyKey','p2f15b-confirm-failure',
    'requestHash',repeat('e',64),
    'shipmentId',v_shipment,
    'expectedShipmentVersion',v_version,
    'requestedAt',clock_timestamp(),
    'workerAuthority','PAYOUT_PROVIDER_CALLBACK',
    'expectedPayoutId',v_payout,
    'payoutRequestTransactionId',v_request,
    'payoutAmount',90,
    'externalProvider','p2f15-test-provider',
    'providerEventId','p2f15b-event-failure',
    'externalReference','p2f15b-failed-reference',
    'providerOccurredAt',clock_timestamp(),
    'providerResponse',jsonb_build_object('failureCode','SIMULATED_PROVIDER_REJECTION')
  );
  insert into p2f_test.payout_callback_race_context
    (race_key,shipment_id,payout_id,payout_request_transaction_id,
     expected_shipment_version,input_success,input_failure)
  values ('P2F-15B',v_shipment,v_payout,v_request,v_version,v_success,v_failure);
end;
$$;
commit;
'@
    Write-Utf8NoBom -Path $p2f15bSeedFile -Text ($p2f15bSeedSql.TrimEnd() + "`n")
    $p2f15bSeedProcess = Start-PsqlScriptProcess `
        -SqlFile $p2f15bSeedFile -StdOutFile $p2f15bSeedOut `
        -StdErrFile $p2f15bSeedErr -ExitCodeFile $p2f15bSeedExit
    $p2f15bSeedProcess.WaitForExit()
    $p2f15bSeedExitText = (Read-WholeFile -Path $p2f15bSeedExit).Trim()
    $p2f15bSeedStdout = Read-WholeFile -Path $p2f15bSeedOut
    $p2f15bSeedStderr = Read-WholeFile -Path $p2f15bSeedErr
    Write-Host "P2F15B_FIXTURE_PSQL_EXIT_CODE|$p2f15bSeedExitText"
    if ($p2f15bSeedExitText -ne '0' -or
        $p2f15bSeedStdout -notmatch '(?m)^COMMIT\s*$' -or
        -not [string]::IsNullOrWhiteSpace($p2f15bSeedStderr)) {
        Write-Host $p2f15bSeedStdout
        Write-Host $p2f15bSeedStderr
        throw 'P2F-15B pending-provider-outcome fixture did not commit cleanly.'
    }
    $p2f15bPre = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B callback pre-race' -Sql @'
select concat_ws('|',s.shipment_state::text,p.state::text,ax.state::text,
  (s.lock_version=c.expected_shipment_version)::text,
  (select count(*) from haulvia.payout_transactions pt where pt.payout_id=c.payout_id)::text,
  (select count(*) from haulvia.payout_transactions pt
    where pt.request_transaction_id=c.payout_request_transaction_id)::text,
  (select coalesce(sum(pt.amount),0) from haulvia.payout_transactions pt
    where pt.payout_id=c.payout_id and pt.status='SUCCEEDED')::text,
  (c.input_success->>'payoutRequestTransactionId'=c.input_failure->>'payoutRequestTransactionId')::text)
from p2f_test.payout_callback_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.driver_payouts p on p.id=c.payout_id
join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=c.shipment_id
where c.race_key='P2F-15B';
'@
    Write-Host "P2F15B_PRE_RACE|$p2f15bPre"
    if ($p2f15bPre -ne 'COMPLETED|PROCESSING|PROCESSING|true|1|0|0|true') {
        throw 'P2F-15B pre-race shared-request/payout state mismatch.'
    }

    Write-Host ''
    Write-Host '================ P2F-15B D07/D08 PROVIDER OUTCOME RACE ================'
    $p2f15bGateFile = Join-Path $TempRoot 'p2f15b-gate.sql'
    $p2f15bGateOut = Join-Path $TempRoot 'p2f15b-gate.stdout.txt'
    $p2f15bGateErr = Join-Path $TempRoot 'p2f15b-gate.stderr.txt'
    $p2f15bAFile = Join-Path $TempRoot 'p2f15b-actor-a.sql'
    $p2f15bBFile = Join-Path $TempRoot 'p2f15b-actor-b.sql'
    $p2f15bAOut = Join-Path $TempRoot 'p2f15b-actor-a.stdout.txt'
    $p2f15bBOut = Join-Path $TempRoot 'p2f15b-actor-b.stdout.txt'
    $p2f15bAErr = Join-Path $TempRoot 'p2f15b-actor-a.stderr.txt'
    $p2f15bBErr = Join-Path $TempRoot 'p2f15b-actor-b.stderr.txt'
    $p2f15bAExit = Join-Path $TempRoot 'p2f15b-actor-a.exit.txt'
    $p2f15bBExit = Join-Path $TempRoot 'p2f15b-actor-b.exit.txt'
    Write-Utf8NoBom -Path $p2f15bGateFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15b_gate';
select pg_advisory_lock(215,1502);
select pg_sleep(600);
"@
    Write-Utf8NoBom -Path $p2f15bAFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15b_actor_a';
select pg_advisory_lock_shared(215,1502);
\echo P2F15B_GATE_ACQUIRED_A
select 'P2F15B_RESULT_A|' ||
  haulvia_command.command_confirm_driver_payout(c.input_success)::text
from p2f_test.payout_callback_race_context c
where c.race_key = 'P2F-15B';
"@
    Write-Utf8NoBom -Path $p2f15bBFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15b_actor_b';
select pg_advisory_lock_shared(215,1502);
\echo P2F15B_GATE_ACQUIRED_B
select 'P2F15B_RESULT_B|' ||
  haulvia_command.command_handle_payout_failure(c.input_failure)::text
from p2f_test.payout_callback_race_context c
where c.race_key = 'P2F-15B';
"@
    $p2f15bGateReleased = $false
    $p2f15bGateProcess = $null
    $p2f15bActorA = $null
    $p2f15bActorB = $null
    try {
        $p2f15bGateProcess = Start-PsqlScriptProcess `
            -SqlFile $p2f15bGateFile -StdOutFile $p2f15bGateOut -StdErrFile $p2f15bGateErr
        Wait-ForScalarValue -Expected '1' -Label 'P2F-15B exclusive gate' -Sql @"
select count(*) from pg_stat_activity a join pg_locks l on l.pid=a.pid
where a.datname=current_database() and a.application_name='p2f15b_gate'
  and l.locktype='advisory' and l.granted;
"@ | Out-Null
        Write-Host 'P2F15B_GATE_HELD|1'
        $p2f15bActorA = Start-PsqlScriptProcess `
            -SqlFile $p2f15bAFile -StdOutFile $p2f15bAOut `
            -StdErrFile $p2f15bAErr -ExitCodeFile $p2f15bAExit
        $p2f15bActorB = Start-PsqlScriptProcess `
            -SqlFile $p2f15bBFile -StdOutFile $p2f15bBOut `
            -StdErrFile $p2f15bBErr -ExitCodeFile $p2f15bBExit
        Wait-ForScalarValue -Expected '2' -Label 'P2F-15B callback waiters' -Sql @"
select count(distinct a.pid) from pg_stat_activity a join pg_locks l on l.pid=a.pid
where a.datname=current_database()
  and a.application_name in ('p2f15b_actor_a','p2f15b_actor_b')
  and l.locktype='advisory' and not l.granted;
"@ | Out-Null
        Write-Host 'P2F15B_WAITERS|2'
        $p2f15bGateRelease = Invoke-PsqlScalar -Database $TargetDatabase `
            -Label 'P2F-15B gate release' -Sql @"
select pg_terminate_backend(pid)::text from pg_stat_activity
where datname=current_database() and application_name='p2f15b_gate'
  and pid<>pg_backend_pid() limit 1;
"@
        Write-Host "P2F15B_GATE_RELEASED|$p2f15bGateRelease"
        if ($p2f15bGateRelease -notin @('true','t')) {
            throw 'P2F-15B exclusive gate release was not confirmed.'
        }
        $p2f15bGateReleased = $true
    }
    finally {
        if (-not $p2f15bGateReleased) {
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                    -Label 'P2F-15B cancel waiting callback actors' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database()
  and application_name in ('p2f15b_actor_a','p2f15b_actor_b')
  and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-15B actor cleanup warning: $_" }
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                    -Label 'P2F-15B release orphan gate' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database() and application_name='p2f15b_gate'
  and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-15B gate cleanup warning: $_" }
        }
    }
    $p2f15bActorA.WaitForExit()
    $p2f15bActorB.WaitForExit()
    $p2f15bGateProcess.WaitForExit()
    $p2f15bStdA = Read-WholeFile -Path $p2f15bAOut
    $p2f15bStdB = Read-WholeFile -Path $p2f15bBOut
    $p2f15bErrA = Read-WholeFile -Path $p2f15bAErr
    $p2f15bErrB = Read-WholeFile -Path $p2f15bBErr
    $p2f15bExitA = (Read-WholeFile -Path $p2f15bAExit).Trim()
    $p2f15bExitB = (Read-WholeFile -Path $p2f15bBExit).Trim()
    Write-Host '---- P2F-15B Actor A stdout ----'
    Write-Host $p2f15bStdA
    Write-Host '---- P2F-15B Actor A stderr ----'
    Write-Host $p2f15bErrA
    Write-Host '---- P2F-15B Actor B stdout ----'
    Write-Host $p2f15bStdB
    Write-Host '---- P2F-15B Actor B stderr ----'
    Write-Host $p2f15bErrB
    Write-Host "P2F15B_EXIT_CODES|$p2f15bExitA|$p2f15bExitB"
    if ($p2f15bExitA -notmatch '^\d+$' -or $p2f15bExitB -notmatch '^\d+$') {
        throw 'P2F-15B actor exit files are missing or malformed.'
    }
    $p2f15bWinA = $p2f15bExitA -eq '0'
    $p2f15bWinB = $p2f15bExitB -eq '0'
    if ($p2f15bWinA -eq $p2f15bWinB) {
        throw 'P2F-15B requires exactly one successful provider callback.'
    }
    $p2f15bWinner = if ($p2f15bWinA) { 'A|confirmDriverPayout|PAID' } `
                        else { 'B|handlePayoutFailure|FAILED' }
    $p2f15bLoserErr = if ($p2f15bWinA) { $p2f15bErrB } else { $p2f15bErrA }
    $p2f15bLoserKey = if ($p2f15bWinA) { 'p2f15b-confirm-failure' } `
                        else { 'p2f15b-confirm-success' }
    $p2f15bLoserEvent = if ($p2f15bWinA) { 'p2f15b-event-failure' } `
                          else { 'p2f15b-event-success' }
    $p2f15bWinnerEvent = if ($p2f15bWinA) { 'p2f15b-event-success' } `
                           else { 'p2f15b-event-failure' }
    $p2f15bWinnerKey = if ($p2f15bWinA) { 'input_success' } else { 'input_failure' }
    $p2f15bWinnerFunction = if ($p2f15bWinA) { 'command_confirm_driver_payout' } `
                               else { 'command_handle_payout_failure' }
    $p2f15bLoserFunction = if ($p2f15bWinA) { 'command_handle_payout_failure' } `
                              else { 'command_confirm_driver_payout' }
    $p2f15bWinnerOut = if ($p2f15bWinA) { $p2f15bStdA } else { $p2f15bStdB }
    if ($p2f15bLoserErr -notmatch 'PAYOUT_REQUEST_MISMATCH|STALE_SHIPMENT_VERSION') {
        throw 'P2F-15B loser did not use an approved conflict/error path.'
    }
    $p2f15bWinnerMatch = [regex]::Match($p2f15bWinnerOut,
        '(?m)^P2F15B_RESULT_[AB]\|(\{[^\r\n]+\})\s*$')
    if (-not $p2f15bWinnerMatch.Success) {
        throw 'P2F-15B winning callback JSON was not captured.'
    }
    $p2f15bResult = $p2f15bWinnerMatch.Groups[1].Value | ConvertFrom-Json
    $p2f15bExpectedState = if ($p2f15bWinA) { 'PAID' } else { 'FAILED' }
    if ($p2f15bResult.replayed -ne $false -or
        $p2f15bResult.driverPayoutState -ne $p2f15bExpectedState -or
        $p2f15bResult.shipmentState -ne 'COMPLETED' -or
        [decimal]$p2f15bResult.payoutAmount -ne [decimal]90 -or
        $p2f15bResult.providerEventId -ne $p2f15bWinnerEvent -or
        $p2f15bResult.duplicateProviderEvent -ne $false -or
        -not $p2f15bResult.payoutTransactionId) {
        throw 'P2F-15B committed callback result does not match the winning outcome.'
    }
    Write-Host "P2F15B_WINNER|$p2f15bWinner"
    Write-Host "P2F15B_LOSER|$(if ($p2f15bWinA) {'B'} else {'A'})|REJECTED"

    $p2f15bPostSql = @'
select concat_ws('|',s.shipment_state::text,p.state::text,ax.state::text,
  (s.lock_version=c.expected_shipment_version)::text,
  (select count(*) from haulvia.driver_payouts dp
    where dp.assignment_id=p.assignment_id)::text,
  (select count(*) from haulvia.payout_eligibility_records e
    where e.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.shipment_completion_records sc
    where sc.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.payout_transactions t
    where t.payout_id=c.payout_id and t.status='PENDING')::text,
  (select count(*) from haulvia.payout_transactions t
    where t.payout_id=c.payout_id and t.status in ('SUCCEEDED','FAILED'))::text,
  (select count(*) from haulvia.payout_transactions t
    where t.request_transaction_id=c.payout_request_transaction_id)::text,
  (select count(*) from haulvia.payout_transactions t
    where t.payout_id=c.payout_id and t.status='PENDING' and not exists (
      select 1 from haulvia.payout_transactions o where o.request_transaction_id=t.id))::text,
  (select coalesce(sum(t.amount),0) from haulvia.payout_transactions t
    where t.payout_id=c.payout_id and t.status='SUCCEEDED')::text,
  (select coalesce(sum(t.amount),0) from haulvia.payout_transactions t
    where t.payout_id=c.payout_id and t.status='FAILED')::text,
  (select count(*) from haulvia.payout_transactions t
    where t.external_provider='p2f15-test-provider'
    and t.provider_event_id in ('p2f15b-event-success','p2f15b-event-failure'))::text,
  (select count(*) from haulvia.audit_events a
    where a.entity_table='shipments' and a.entity_id=c.shipment_id
    and a.command_name in ('confirmDriverPayout','handlePayoutFailure'))::text,
  (select count(*) from haulvia.workflow_axis_events e
    where e.shipment_id=c.shipment_id
    and e.command_name in ('confirmDriverPayout','handlePayoutFailure'))::text,
  (select count(*) from haulvia.financial_holds h
    where h.shipment_id=c.shipment_id and h.status='ACTIVE')::text)
from p2f_test.payout_callback_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.driver_payouts p on p.id=c.payout_id
join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=c.shipment_id
where c.race_key='P2F-15B';
'@
    $p2f15bPost = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B canonical financial post-state' -Sql $p2f15bPostSql
    Write-Host "P2F15B_POST_STATE|$p2f15bPost"
    $p2f15bFields = $p2f15bPost.Split('|')
    if ($p2f15bFields.Count -ne 17 -or
        $p2f15bFields[0] -ne 'COMPLETED' -or
        $p2f15bFields[1] -ne $p2f15bExpectedState -or
        $p2f15bFields[2] -ne $p2f15bExpectedState -or
        (@($p2f15bFields[3..10]) -join '|') -ne 'true|1|1|1|1|1|1|0' -or
        $p2f15bFields[13] -ne '1' -or
        (@($p2f15bFields[14..16]) -join '|') -ne '1|1|0') {
        throw 'P2F-15B canonical payout cardinality or settlement state is inconsistent.'
    }
    if ($p2f15bWinA) {
        if ([decimal]$p2f15bFields[11] -ne 90 -or
            [decimal]$p2f15bFields[12] -ne 0) {
            throw 'P2F-15B D07 success did not settle exactly 90 CAD.'
        }
    } else {
        if ([decimal]$p2f15bFields[11] -ne 0 -or
            [decimal]$p2f15bFields[12] -ne 90) {
            throw 'P2F-15B D08 failure misclassified the outcome amount.'
        }
    }
    $p2f15bBinding = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B winning outcome lineage' -Sql @"
select concat_ws('|',
  (t.id='$($p2f15bResult.payoutTransactionId)'::uuid)::text,
  (t.payout_id=c.payout_id)::text,
  (t.request_transaction_id=c.payout_request_transaction_id)::text,
  (t.amount=90)::text,
  (t.external_provider='p2f15-test-provider')::text,
  (t.provider_event_id='$p2f15bWinnerEvent')::text,
  (t.status='$(if ($p2f15bWinA) {'SUCCEEDED'} else {'FAILED'})')::text)
from p2f_test.payout_callback_race_context c
join haulvia.payout_transactions t
  on t.request_transaction_id=c.payout_request_transaction_id
where c.race_key='P2F-15B';
"@
    Write-Host "P2F15B_WINNER_BINDING|$p2f15bBinding"
    if ($p2f15bBinding -ne 'true|true|true|true|true|true|true') {
        throw 'P2F-15B winning event not bound to one existing D06 request.'
    }
    $p2f15bReplayText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B winning callback replay' -Sql @"
select haulvia_command.$p2f15bWinnerFunction($p2f15bWinnerKey)::text
from p2f_test.payout_callback_race_context where race_key='P2F-15B';
"@
    Write-Host "P2F15B_REPLAY|$p2f15bReplayText"
    $p2f15bReplay = $p2f15bReplayText | ConvertFrom-Json
    if ($p2f15bReplay.replayed -ne $true -or
        $p2f15bReplay.payoutTransactionId -ne $p2f15bResult.payoutTransactionId) {
        throw 'P2F-15B exact winning callback did not replay established outcome.'
    }
    $p2f15bPostReplay = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B no replay financial mutation' -Sql $p2f15bPostSql
    Write-Host "P2F15B_REPLAY_STATE|$p2f15bPostReplay"
    if ($p2f15bPostReplay -ne $p2f15bPost) {
        throw 'P2F-15B exact replay changed provider outcome or payout facts.'
    }
    $p2f15bConflict = Invoke-PsqlAllowFailure -Database $TargetDatabase -Sql @"
select haulvia_command.$p2f15bWinnerFunction(
  $p2f15bWinnerKey || jsonb_build_object('requestHash',repeat('f',64)))::text
from p2f_test.payout_callback_race_context where race_key='P2F-15B';
"@
    Write-Host "P2F15B_IDEMPOTENCY_CONFLICT_EXIT|$($p2f15bConflict.ExitCode)"
    if ($p2f15bConflict.ExitCode -eq 0 -or
        $p2f15bConflict.Text -notmatch 'IDEMPOTENCY_KEY_REUSED') {
        throw 'P2F-15B winning command same-key/different-hash failed open.'
    }
    # Distinct callback command envelope but *identical* already-recorded
    # provider event must return the original outcome without new money effects.
    $p2f15bDuplicateText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B duplicate provider-event no-op' -Sql @"
select haulvia_command.$p2f15bWinnerFunction(
  $p2f15bWinnerKey || jsonb_build_object(
    'commandId',gen_random_uuid(),
    'idempotencyKey','p2f15b-provider-event-duplicate',
    'requestHash',repeat('d',64),
    'expectedShipmentVersion',(select lock_version from haulvia.shipments s
      where s.id=c.shipment_id)))::text
from p2f_test.payout_callback_race_context c where c.race_key='P2F-15B';
"@
    Write-Host "P2F15B_DUPLICATE_EVENT|$p2f15bDuplicateText"
    $p2f15bDuplicate = $p2f15bDuplicateText | ConvertFrom-Json
    if ($p2f15bDuplicate.duplicateProviderEvent -ne $true -or
        $p2f15bDuplicate.payoutTransactionId -ne $p2f15bResult.payoutTransactionId) {
        throw 'P2F-15B duplicate provider event was not idempotent.'
    }
    $p2f15bPostDuplicate = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B duplicate event left financial facts unchanged' -Sql $p2f15bPostSql
    Write-Host "P2F15B_DUPLICATE_EVENT_STATE|$p2f15bPostDuplicate"
    if ($p2f15bPostDuplicate -ne $p2f15bPost) {
        throw 'P2F-15B duplicate provider event modified financial facts.'
    }
    # An opposite outcome reusing the already-committed provider event ID
    # must be rejected by provider event uniqueness, before request handling.
    $p2f15bProviderConflict = Invoke-PsqlAllowFailure -Database $TargetDatabase -Sql @"
select haulvia_command.$p2f15bLoserFunction(
  $p2f15bWinnerKey || jsonb_build_object(
    'commandId',gen_random_uuid(),
    'idempotencyKey','p2f15b-opposite-event-conflict',
    'requestHash',repeat('b',64),
    'expectedShipmentVersion',(select lock_version from haulvia.shipments s
      where s.id=c.shipment_id)))::text
from p2f_test.payout_callback_race_context c where c.race_key='P2F-15B';
"@
    Write-Host "P2F15B_PROVIDER_CONFLICT_EXIT|$($p2f15bProviderConflict.ExitCode)"
    if ($p2f15bProviderConflict.ExitCode -eq 0 -or
        $p2f15bProviderConflict.Text -notmatch 'PROVIDER_EVENT_CONFLICT') {
        throw 'P2F-15B opposite outcome for one provider event failed open.'
    }
    $p2f15bLoserResidue = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B losing callback left no side effects' -Sql @"
select concat_ws('|',
  (select count(*) from haulvia.command_idempotency c
    where c.idempotency_key='$p2f15bLoserKey')::text,
  (select count(*) from haulvia.payout_transactions t
    where t.provider_event_id='$p2f15bLoserEvent')::text,
  (select count(*) from haulvia.audit_events a
    where a.idempotency_key='$p2f15bLoserKey')::text,
  (select count(*) from haulvia.workflow_axis_events e
    where e.idempotency_key='$p2f15bLoserKey')::text);
"@
    Write-Host "P2F15B_LOSER_RESIDUE|$p2f15bLoserResidue"
    if ($p2f15bLoserResidue -ne '0|0|0|0') {
        throw 'P2F-15B losing callback committed partial command or financial facts.'
    }
    $p2f15bFinal = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15B final immutable financial state' -Sql $p2f15bPostSql
    Write-Host "P2F15B_FINAL_STATE|$p2f15bFinal"
    if ($p2f15bFinal -ne $p2f15bPost) {
        throw 'P2F-15B post-probe state differs from initial winning settlement state.'
    }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'P2F-15B D07/D08 PROVIDER CALLBACK RACE PASSED'
    Write-Host '============================================================'
    Write-Host 'PASS: both independent provider callbacks were waiting on an exclusive gate.'
    Write-Host 'PASS: exactly one D07 or D08 outcome committed against the pending D06 request.'
    Write-Host 'PASS: one provider event and one bound outcome; no duplicated settlement.'
    Write-Host 'PASS: success/failure state and money ledger match the winning provider outcome.'
    Write-Host 'PASS: exact replay, duplicate provider event and same-key hash conflict enforced.'
    Write-Host 'PASS: opposite status for one provider event was rejected.'
    Write-Host 'PASS: losing callback left zero command, payout, axis or audit residue.'
    Write-Host 'P2F-15 internal progress: 2 / 3 payout sub-races.'
    Write-Host 'P2F-15 remains NON-AUTHORITATIVE until retry-after-failure race passes.'
    Write-Host 'Official P2F concurrency progress remains 6 / 8 race domains.'
    Write-Host ''

    # ========================================================================
    # P2F-15C: D08 provider failure releases eligible funds for ONE D06 retry.
    # Independent payout workers race; only the winning retry may settle.
    # This is the final payout sub-race, but it is NOT authoritative until
    # the complete fresh 8-domain harness exits zero and evidence is reviewed.
    # ========================================================================
    Write-Host ''
    Write-Host '================ P2F-15C FAILED PAYOUT / RETRY FIXTURE ================'
    $p2f15cSeedFile = Join-Path $TempRoot 'p2f15c-fixture.sql'
    $p2f15cSeedOut = Join-Path $TempRoot 'p2f15c-fixture.stdout.txt'
    $p2f15cSeedErr = Join-Path $TempRoot 'p2f15c-fixture.stderr.txt'
    $p2f15cSeedExit = Join-Path $TempRoot 'p2f15c-fixture.exit.txt'
    $p2f15cSeedTail = @'
create table p2f_test.payout_retry_race_context (
    race_key text primary key,
    shipment_id uuid not null,
    payout_id uuid not null,
    initial_request_transaction_id uuid not null,
    failure_outcome_transaction_id uuid not null,
    expected_shipment_version bigint not null,
    input_failure jsonb not null,
    input_a jsonb not null,
    input_b jsonb not null,
    input_settlement jsonb
);
do $$
declare
  v_f jsonb := pg_temp.resolve_and_complete('p2f15c-retry-after-failure');
  v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
  v_payout uuid := (v_f ->> 'payoutId')::uuid;
  v_initial jsonb;
  v_submitted jsonb;
  v_failure jsonb;
  v_failed jsonb;
  v_a jsonb;
  v_b jsonb;
begin
  if not exists (
    select 1 from haulvia.shipments s
    join haulvia.driver_payouts p on p.shipment_id=s.id
    join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=s.id
    where s.id=v_shipment and s.shipment_state='COMPLETED'
      and p.id=v_payout and p.state='READY' and ax.state='READY'
      and p.net_amount=90
      and (select count(*) from haulvia.payout_eligibility_records e
           where e.shipment_id=s.id)=1
      and (select count(*) from haulvia.shipment_completion_records sc
           where sc.shipment_id=s.id)=1
      and not exists(select 1 from haulvia.payout_transactions t where t.payout_id=p.id)
      and not exists(select 1 from haulvia.financial_holds h
                     where h.shipment_id=s.id and h.status='ACTIVE')
  ) then
    raise exception 'P2F-15C fresh completed/READY payout fixture is invalid';
  end if;
  v_initial:=pg_temp.envelope(v_shipment,null,'p2f15c-initial-submit','2') ||
    jsonb_build_object(
      'workerAuthority','PAYOUT_WORKER',
      'expectedPayoutId',v_payout,
      'payoutAmount',90,
      'externalProvider','p2f15c-test-provider',
      'providerIdempotencyKey','p2f15c-provider-initial',
      'payoutAccountReference','acct_p2f15c_local',
      'payoutAccountValid',true,
      'providerRequest',jsonb_build_object('rail','EFT')
    );
  v_submitted:=haulvia_command.command_submit_driver_payout(v_initial);
  if v_submitted ->> 'driverPayoutState' <> 'PROCESSING'
     or v_submitted ->> 'payoutTransactionId' is null then
    raise exception 'P2F-15C initial D06 payout request did not enter PROCESSING';
  end if;
  v_failure:=pg_temp.envelope(v_shipment,null,'p2f15c-initial-failure','3') ||
    jsonb_build_object(
      'workerAuthority','PAYOUT_PROVIDER_CALLBACK',
      'expectedPayoutId',v_payout,
      'payoutRequestTransactionId',v_submitted ->> 'payoutTransactionId',
      'payoutAmount',90,
      'externalProvider','p2f15c-test-provider',
      'providerEventId','p2f15c-event-initial-failure',
      'externalReference','p2f15c-failed-reference',
      'providerOccurredAt',clock_timestamp(),
      'providerResponse',jsonb_build_object('failureCode','SIMULATED_RETRYABLE_FAILURE')
    );
  v_failed:=haulvia_command.command_handle_payout_failure(v_failure);
  if v_failed ->> 'driverPayoutState' <> 'FAILED'
     or v_failed ->> 'shipmentState' <> 'COMPLETED'
     or v_failed ->> 'payoutTransactionId' is null then
    raise exception 'P2F-15C D08 failure did not retain COMPLETED and FAILED';
  end if;
  if not exists (
    select 1 from haulvia.payout_transactions t
    where t.id=(v_failed ->> 'payoutTransactionId')::uuid
      and t.request_transaction_id=(v_submitted ->> 'payoutTransactionId')::uuid
      and t.status='FAILED' and t.amount=90
      and t.provider_event_id='p2f15c-event-initial-failure'
  ) then
    raise exception 'P2F-15C failed outcome not linked to initial D06 request';
  end if;
  v_a:=pg_temp.envelope(v_shipment,null,'p2f15c-retry-a','4') ||
    jsonb_build_object(
      'workerAuthority','PAYOUT_WORKER',
      'expectedPayoutId',v_payout,
      'payoutAmount',90,
      'externalProvider','p2f15c-test-provider',
      'providerIdempotencyKey','p2f15c-retry-provider-a',
      'payoutAccountReference','acct_p2f15c_local',
      'payoutAccountValid',true,
      'providerRequest',jsonb_build_object('rail','EFT','retry',true)
    );
  v_b:=pg_temp.envelope(v_shipment,null,'p2f15c-retry-b','5') ||
    jsonb_build_object(
      'workerAuthority','PAYOUT_WORKER',
      'expectedPayoutId',v_payout,
      'payoutAmount',90,
      'externalProvider','p2f15c-test-provider',
      'providerIdempotencyKey','p2f15c-retry-provider-b',
      'payoutAccountReference','acct_p2f15c_local',
      'payoutAccountValid',true,
      'providerRequest',jsonb_build_object('rail','EFT','retry',true)
    );
  insert into p2f_test.payout_retry_race_context (
    race_key,shipment_id,payout_id,initial_request_transaction_id,
    failure_outcome_transaction_id,expected_shipment_version,
    input_failure,input_a,input_b
  ) values (
    'P2F-15C',v_shipment,v_payout,
    (v_submitted ->> 'payoutTransactionId')::uuid,
    (v_failed ->> 'payoutTransactionId')::uuid,
    (v_a ->> 'expectedShipmentVersion')::bigint,
    v_failure,v_a,v_b
  );
end;
$$;
commit;
'@
    $p2f15cSeedSql = @(
        $p2f15SeedHead,
        $p2f15EnvelopeSource,
        $p2f14DeliveredSeedSource,
        $p2f14ManifestSource,
        $p2f15CompletedSource,
        $p2f15cSeedTail
    ) -join "`n"
    Write-Utf8NoBom -Path $p2f15cSeedFile -Text ($p2f15cSeedSql.TrimEnd() + "`n")
    $p2f15cSeedProcess = Start-PsqlScriptProcess `
        -SqlFile $p2f15cSeedFile -StdOutFile $p2f15cSeedOut `
        -StdErrFile $p2f15cSeedErr -ExitCodeFile $p2f15cSeedExit
    $p2f15cSeedProcess.WaitForExit()
    $p2f15cSeedExitText = (Read-WholeFile -Path $p2f15cSeedExit).Trim()
    $p2f15cSeedStdout = Read-WholeFile -Path $p2f15cSeedOut
    $p2f15cSeedStderr = Read-WholeFile -Path $p2f15cSeedErr
    Write-Host "P2F15C_FIXTURE_PSQL_EXIT_CODE|$p2f15cSeedExitText"
    if ($p2f15cSeedExitText -ne '0' -or
        $p2f15cSeedStdout -notmatch '(?m)^COMMIT\s*$' -or
        -not [string]::IsNullOrWhiteSpace($p2f15cSeedStderr)) {
        Write-Host $p2f15cSeedStdout
        Write-Host $p2f15cSeedStderr
        throw 'P2F-15C initial payout-failure fixture did not commit cleanly.'
    }
    $p2f15cPre = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C failed payout state before retry' -Sql @'
select concat_ws('|',s.shipment_state::text,p.state::text,ax.state::text,
  (s.lock_version=c.expected_shipment_version)::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id)::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='FAILED')::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='SUCCEEDED')::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id
    and t.status='PENDING' and not exists (
      select 1 from haulvia.payout_transactions o where o.request_transaction_id=t.id))::text,
  (select count(*) from haulvia.payout_transactions t
    where t.id=c.failure_outcome_transaction_id
      and t.request_transaction_id=c.initial_request_transaction_id
      and t.provider_event_id='p2f15c-event-initial-failure')::text,
  (select count(*) from haulvia.financial_holds h
    where h.shipment_id=c.shipment_id and h.status='ACTIVE')::text)
from p2f_test.payout_retry_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.driver_payouts p on p.id=c.payout_id
join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=c.shipment_id
where c.race_key='P2F-15C';
'@
    Write-Host "P2F15C_PRE_RACE|$p2f15cPre"
    if ($p2f15cPre -ne 'COMPLETED|FAILED|FAILED|true|2|1|0|0|1|0') {
        throw 'P2F-15C prior failed D08 callback did not free exactly one eligible payout amount.'
    }
    Write-Host 'PASS: initial D06 request and linked D08 failure retained; amount can be retried.'

    Write-Host ''
    Write-Host '================ P2F-15C TWO-WORKER D06 RETRY RACE ================'
    $p2f15cGateFile = Join-Path $TempRoot 'p2f15c-gate.sql'
    $p2f15cGateOut = Join-Path $TempRoot 'p2f15c-gate.stdout.txt'
    $p2f15cGateErr = Join-Path $TempRoot 'p2f15c-gate.stderr.txt'
    $p2f15cAFile = Join-Path $TempRoot 'p2f15c-actor-a.sql'
    $p2f15cBFile = Join-Path $TempRoot 'p2f15c-actor-b.sql'
    $p2f15cAOut = Join-Path $TempRoot 'p2f15c-actor-a.stdout.txt'
    $p2f15cBOut = Join-Path $TempRoot 'p2f15c-actor-b.stdout.txt'
    $p2f15cAErr = Join-Path $TempRoot 'p2f15c-actor-a.stderr.txt'
    $p2f15cBErr = Join-Path $TempRoot 'p2f15c-actor-b.stderr.txt'
    $p2f15cAExit = Join-Path $TempRoot 'p2f15c-actor-a.exit.txt'
    $p2f15cBExit = Join-Path $TempRoot 'p2f15c-actor-b.exit.txt'
    Write-Utf8NoBom -Path $p2f15cGateFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15c_gate';
select pg_advisory_lock(215,1503);
select pg_sleep(600);
"@
    Write-Utf8NoBom -Path $p2f15cAFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15c_actor_a';
select pg_advisory_lock_shared(215,1503);
\echo P2F15C_GATE_ACQUIRED_A
select 'P2F15C_RESULT_A|' ||
  haulvia_command.command_submit_driver_payout(c.input_a)::text
from p2f_test.payout_retry_race_context c where c.race_key='P2F-15C';
"@
    Write-Utf8NoBom -Path $p2f15cBFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f15c_actor_b';
select pg_advisory_lock_shared(215,1503);
\echo P2F15C_GATE_ACQUIRED_B
select 'P2F15C_RESULT_B|' ||
  haulvia_command.command_submit_driver_payout(c.input_b)::text
from p2f_test.payout_retry_race_context c where c.race_key='P2F-15C';
"@
    $p2f15cGateReleased = $false
    $p2f15cGateProcess = $null
    $p2f15cActorA = $null
    $p2f15cActorB = $null
    try {
        $p2f15cGateProcess = Start-PsqlScriptProcess `
            -SqlFile $p2f15cGateFile -StdOutFile $p2f15cGateOut -StdErrFile $p2f15cGateErr
        Wait-ForScalarValue -Expected '1' -Label 'P2F-15C exclusive retry gate' -Sql @"
select count(*) from pg_stat_activity a join pg_locks l on l.pid=a.pid
where a.datname=current_database() and a.application_name='p2f15c_gate'
  and l.locktype='advisory' and l.granted;
"@ | Out-Null
        Write-Host 'P2F15C_GATE_HELD|1'
        $p2f15cActorA = Start-PsqlScriptProcess `
            -SqlFile $p2f15cAFile -StdOutFile $p2f15cAOut `
            -StdErrFile $p2f15cAErr -ExitCodeFile $p2f15cAExit
        $p2f15cActorB = Start-PsqlScriptProcess `
            -SqlFile $p2f15cBFile -StdOutFile $p2f15cBOut `
            -StdErrFile $p2f15cBErr -ExitCodeFile $p2f15cBExit
        Wait-ForScalarValue -Expected '2' -Label 'P2F-15C two independent retry workers' -Sql @"
select count(distinct a.pid) from pg_stat_activity a join pg_locks l on l.pid=a.pid
where a.datname=current_database()
  and a.application_name in ('p2f15c_actor_a','p2f15c_actor_b')
  and l.locktype='advisory' and not l.granted;
"@ | Out-Null
        Write-Host 'P2F15C_WAITERS|2'
        $p2f15cGateRelease = Invoke-PsqlScalar -Database $TargetDatabase `
            -Label 'P2F-15C exclusive gate release' -Sql @"
select pg_terminate_backend(pid)::text from pg_stat_activity
where datname=current_database() and application_name='p2f15c_gate'
  and pid<>pg_backend_pid() limit 1;
"@
        Write-Host "P2F15C_GATE_RELEASED|$p2f15cGateRelease"
        if ($p2f15cGateRelease -notin @('true','t')) {
            throw 'P2F-15C gate release not confirmed.'
        }
        $p2f15cGateReleased = $true
    }
    finally {
        if (-not $p2f15cGateReleased) {
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                    -Label 'P2F-15C terminate blocked retry actors' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database()
  and application_name in ('p2f15c_actor_a','p2f15c_actor_b')
  and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-15C actor cleanup warning: $_" }
            try {
                Invoke-PsqlText -Database $TargetDatabase `
                    -Label 'P2F-15C release orphan gate' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database() and application_name='p2f15c_gate'
  and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-15C gate cleanup warning: $_" }
        }
    }
    $p2f15cActorA.WaitForExit()
    $p2f15cActorB.WaitForExit()
    $p2f15cGateProcess.WaitForExit()
    $p2f15cStdA = Read-WholeFile -Path $p2f15cAOut
    $p2f15cStdB = Read-WholeFile -Path $p2f15cBOut
    $p2f15cErrA = Read-WholeFile -Path $p2f15cAErr
    $p2f15cErrB = Read-WholeFile -Path $p2f15cBErr
    $p2f15cExitA = (Read-WholeFile -Path $p2f15cAExit).Trim()
    $p2f15cExitB = (Read-WholeFile -Path $p2f15cBExit).Trim()
    Write-Host '---- P2F-15C Worker A stdout ----'
    Write-Host $p2f15cStdA
    Write-Host '---- P2F-15C Worker A stderr ----'
    Write-Host $p2f15cErrA
    Write-Host '---- P2F-15C Worker B stdout ----'
    Write-Host $p2f15cStdB
    Write-Host '---- P2F-15C Worker B stderr ----'
    Write-Host $p2f15cErrB
    Write-Host "P2F15C_EXIT_CODES|$p2f15cExitA|$p2f15cExitB"
    if ($p2f15cExitA -notmatch '^\d+$' -or $p2f15cExitB -notmatch '^\d+$') {
        throw 'P2F-15C retry actor exit code files are missing or malformed.'
    }
    $p2f15cWinA = $p2f15cExitA -eq '0'
    $p2f15cWinB = $p2f15cExitB -eq '0'
    if ($p2f15cWinA -eq $p2f15cWinB) {
        throw 'P2F-15C must have exactly one successful retry worker.'
    }
    $p2f15cWinner = if ($p2f15cWinA) { 'A' } else { 'B' }
    $p2f15cLoser = if ($p2f15cWinA) { 'B' } else { 'A' }
    $p2f15cWinnerOut = if ($p2f15cWinA) { $p2f15cStdA } else { $p2f15cStdB }
    $p2f15cLoserErr = if ($p2f15cWinA) { $p2f15cErrB } else { $p2f15cErrA }
    $p2f15cWinnerInput = if ($p2f15cWinA) { 'input_a' } else { 'input_b' }
    $p2f15cLoserKey = if ($p2f15cWinA) { 'p2f15c-retry-b' } else { 'p2f15c-retry-a' }
    $p2f15cLoserProvider = if ($p2f15cWinA) { 'p2f15c-retry-provider-b' } else { 'p2f15c-retry-provider-a' }
    if ($p2f15cLoserErr -notmatch 'PAYOUT_AMOUNT_UNAVAILABLE|STALE_SHIPMENT_VERSION') {
        throw 'P2F-15C losing retry worker did not use an approved deterministic error path.'
    }
    $p2f15cWinnerMatch = [regex]::Match($p2f15cWinnerOut,
        '(?m)^P2F15C_RESULT_[AB]\|(\{[^\r\n]+\})\s*$')
    if (-not $p2f15cWinnerMatch.Success) {
        throw 'P2F-15C winning retry JSON not captured.'
    }
    $p2f15cResult = $p2f15cWinnerMatch.Groups[1].Value | ConvertFrom-Json
    if ($p2f15cResult.replayed -ne $false -or
        $p2f15cResult.driverPayoutState -ne 'PROCESSING' -or
        $p2f15cResult.shipmentState -ne 'COMPLETED' -or
        [decimal]$p2f15cResult.payoutAmount -ne [decimal]90 -or
        $p2f15cResult.duplicateProviderRequest -ne $false -or
        -not $p2f15cResult.payoutTransactionId) {
        throw 'P2F-15C winning retry did not create one new PENDING request.'
    }
    Write-Host "P2F15C_WINNER|$p2f15cWinner|submitDriverPayout|PROCESSING"
    Write-Host "P2F15C_LOSER|$p2f15cLoser|REJECTED"

    $p2f15cPostSql = @'
select concat_ws('|',s.shipment_state::text,p.state::text,ax.state::text,
  (s.lock_version=c.expected_shipment_version)::text,
  (select count(*) from haulvia.driver_payouts dp where dp.assignment_id=p.assignment_id)::text,
  (select count(*) from haulvia.payout_eligibility_records e where e.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.shipment_completion_records sc where sc.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id)::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='PENDING')::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='FAILED')::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='SUCCEEDED')::text,
  (select count(*) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='PENDING'
     and not exists (select 1 from haulvia.payout_transactions o where o.request_transaction_id=t.id))::text,
  (select coalesce(sum(t.amount),0) from haulvia.payout_transactions t where t.payout_id=c.payout_id
     and t.status='PENDING' and not exists (select 1 from haulvia.payout_transactions o where o.request_transaction_id=t.id))::text,
  (select coalesce(sum(t.amount),0) from haulvia.payout_transactions t where t.payout_id=c.payout_id and t.status='SUCCEEDED')::text,
  (select count(*) from haulvia.payout_transactions t
     where t.id=c.failure_outcome_transaction_id
       and t.request_transaction_id=c.initial_request_transaction_id
       and t.status='FAILED' and t.provider_event_id='p2f15c-event-initial-failure')::text,
  (select count(*) from haulvia.audit_events a where a.entity_table='shipments'
     and a.entity_id=c.shipment_id and a.command_name='submitDriverPayout')::text,
  (select count(*) from haulvia.audit_events a where a.entity_table='shipments'
     and a.entity_id=c.shipment_id and a.command_name='handlePayoutFailure')::text,
  (select count(*) from haulvia.workflow_axis_events e where e.shipment_id=c.shipment_id
     and e.command_name='submitDriverPayout')::text,
  (select count(*) from haulvia.workflow_axis_events e where e.shipment_id=c.shipment_id
     and e.command_name='handlePayoutFailure')::text,
  (select count(*) from haulvia.financial_holds h where h.shipment_id=c.shipment_id and h.status='ACTIVE')::text)
from p2f_test.payout_retry_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.driver_payouts p on p.id=c.payout_id
join haulvia.shipment_driver_payout_axes ax on ax.shipment_id=c.shipment_id
where c.race_key='P2F-15C';
'@
    $p2f15cPost = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C retry winning canonical ledger' -Sql $p2f15cPostSql
    Write-Host "P2F15C_POST_STATE|$p2f15cPost"
    $p2f15cFields = $p2f15cPost.Split('|')
    if ($p2f15cFields.Count -ne 20 -or
        (@($p2f15cFields[0..7]) -join '|') -ne 'COMPLETED|PROCESSING|PROCESSING|true|1|1|1|3' -or
        (@($p2f15cFields[8..11]) -join '|') -ne '2|1|0|1' -or
        [decimal]$p2f15cFields[12] -ne 90 -or
        [decimal]$p2f15cFields[13] -ne 0 -or
        (@($p2f15cFields[14..19]) -join '|') -ne '1|2|1|2|1|0') {
        throw 'P2F-15C retry duplicated or lost pending, failed, eligibility, or audit facts.'
    }
    $p2f15cBinding = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C winning retry request binding' -Sql @"
select concat_ws('|',
  (t.id='$($p2f15cResult.payoutTransactionId)'::uuid)::text,
  (t.payout_id=c.payout_id)::text,
  (t.status='PENDING')::text,
  (t.amount=90)::text,
  (t.external_provider='p2f15c-test-provider')::text,
  (t.idempotency_key='p2f15c-retry-provider-$($p2f15cWinner.ToLowerInvariant())')::text,
  (t.id<>c.initial_request_transaction_id)::text)
from p2f_test.payout_retry_race_context c
join haulvia.payout_transactions t on t.payout_id=c.payout_id
where c.race_key='P2F-15C'
  and t.status='PENDING' and not exists (
    select 1 from haulvia.payout_transactions o where o.request_transaction_id=t.id);
"@
    Write-Host "P2F15C_WINNER_BINDING|$p2f15cBinding"
    if ($p2f15cBinding -ne 'true|true|true|true|true|true|true') {
        throw 'P2F-15C winning retry transaction is not uniquely bound.'
    }
    $p2f15cReplayText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C exact winning retry replay' -Sql @"
select haulvia_command.command_submit_driver_payout($p2f15cWinnerInput)::text
from p2f_test.payout_retry_race_context where race_key='P2F-15C';
"@
    Write-Host "P2F15C_REPLAY|$p2f15cReplayText"
    $p2f15cReplay = $p2f15cReplayText | ConvertFrom-Json
    if ($p2f15cReplay.replayed -ne $true -or
        $p2f15cReplay.payoutTransactionId -ne $p2f15cResult.payoutTransactionId) {
        throw 'P2F-15C winning retry did not replay the established PENDING request.'
    }
    $p2f15cReplayState = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C exact retry replay unchanged ledger' -Sql $p2f15cPostSql
    Write-Host "P2F15C_REPLAY_STATE|$p2f15cReplayState"
    if ($p2f15cReplayState -ne $p2f15cPost) {
        throw 'P2F-15C retry replay changed financial or audit records.'
    }
    $p2f15cConflict = Invoke-PsqlAllowFailure -Database $TargetDatabase -Sql @"
select haulvia_command.command_submit_driver_payout(
  $p2f15cWinnerInput || jsonb_build_object('requestHash',repeat('f',64)))::text
from p2f_test.payout_retry_race_context where race_key='P2F-15C';
"@
    Write-Host "P2F15C_IDEMPOTENCY_CONFLICT_EXIT|$($p2f15cConflict.ExitCode)"
    if ($p2f15cConflict.ExitCode -eq 0 -or
        $p2f15cConflict.Text -notmatch 'IDEMPOTENCY_KEY_REUSED') {
        throw 'P2F-15C same retry key with different request hash failed open.'
    }
    $p2f15cLoserResidue = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C losing retry has no residue' -Sql @"
select concat_ws('|',
  (select count(*) from haulvia.command_idempotency ci where ci.idempotency_key='$p2f15cLoserKey')::text,
  (select count(*) from haulvia.payout_transactions t where t.idempotency_key='$p2f15cLoserProvider')::text,
  (select count(*) from haulvia.audit_events a where a.idempotency_key='$p2f15cLoserKey')::text,
  (select count(*) from haulvia.workflow_axis_events e where e.idempotency_key='$p2f15cLoserKey')::text);
"@
    Write-Host "P2F15C_LOSER_RESIDUE|$p2f15cLoserResidue"
    if ($p2f15cLoserResidue -ne '0|0|0|0') {
        throw 'P2F-15C losing retry created orphan command or payout facts.'
    }

    # Settle ONLY the winning retry after verifying that its request is the
    # unique outstanding request. This exercises real D07 funds settlement.
    $p2f15cSettlementPrepare = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C settlement input preparation' -Sql @"
with winner as (
  select c.race_key,c.shipment_id,c.payout_id,c.expected_shipment_version,t.id
  from p2f_test.payout_retry_race_context c
  join haulvia.payout_transactions t on t.payout_id=c.payout_id
  where c.race_key='P2F-15C' and t.id='$($p2f15cResult.payoutTransactionId)'::uuid
    and t.status='PENDING' and not exists (
      select 1 from haulvia.payout_transactions o where o.request_transaction_id=t.id)
), update_request as (
  update p2f_test.payout_retry_race_context c
  set input_settlement=jsonb_build_object(
    'commandId',gen_random_uuid(),
    'idempotencyKey','p2f15c-settle-winning-retry',
    'requestHash',repeat('6',64),
    'shipmentId',w.shipment_id,
    'expectedShipmentVersion',w.expected_shipment_version,
    'requestedAt',clock_timestamp(),
    'workerAuthority','PAYOUT_PROVIDER_CALLBACK',
    'expectedPayoutId',w.payout_id,
    'payoutRequestTransactionId',w.id,
    'payoutAmount',90,
    'externalProvider','p2f15c-test-provider',
    'providerEventId','p2f15c-event-retry-paid',
    'externalReference','p2f15c-paid-reference',
    'providerOccurredAt',clock_timestamp(),
    'providerResponse',jsonb_build_object('status','paid')
  )
  from winner w where c.race_key=w.race_key and c.input_settlement is null
  returning c.race_key
)
select count(*)::text from update_request;
"@
    Write-Host "P2F15C_SETTLEMENT_PREPARED|$p2f15cSettlementPrepare"
    if ($p2f15cSettlementPrepare -ne '1') {
        throw 'P2F-15C winning retry could not be uniquely prepared for settlement.'
    }
    $p2f15cSettleText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C actual D07 settlement of winner' -Sql @'
select haulvia_command.command_confirm_driver_payout(c.input_settlement)::text
from p2f_test.payout_retry_race_context c where c.race_key='P2F-15C';
'@
    Write-Host "P2F15C_SETTLEMENT|$p2f15cSettleText"
    $p2f15cSettle = $p2f15cSettleText | ConvertFrom-Json
    if ($p2f15cSettle.replayed -ne $false -or
        $p2f15cSettle.driverPayoutState -ne 'PAID' -or
        $p2f15cSettle.shipmentState -ne 'COMPLETED' -or
        [decimal]$p2f15cSettle.paidAmount -ne 90 -or
        $p2f15cSettle.providerEventId -ne 'p2f15c-event-retry-paid' -or
        $p2f15cSettle.payoutRequestTransactionId -ne $p2f15cResult.payoutTransactionId -or
        $p2f15cSettle.duplicateProviderEvent -ne $false) {
        throw 'P2F-15C winning retry was not settled exactly once.'
    }
    $p2f15cFinal = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C final paid / failed immutable lineage' -Sql $p2f15cPostSql
    Write-Host "P2F15C_SETTLED_STATE|$p2f15cFinal"
    $p2f15cFinalFields = $p2f15cFinal.Split('|')
    if ($p2f15cFinalFields.Count -ne 20 -or
        (@($p2f15cFinalFields[0..7]) -join '|') -ne 'COMPLETED|PAID|PAID|true|1|1|1|4' -or
        (@($p2f15cFinalFields[8..11]) -join '|') -ne '2|1|1|0' -or
        [decimal]$p2f15cFinalFields[12] -ne 0 -or
        [decimal]$p2f15cFinalFields[13] -ne 90 -or
        (@($p2f15cFinalFields[14..19]) -join '|') -ne '1|2|1|2|1|0') {
        throw 'P2F-15C final money movement not exactly 90 with one failed prior outcome.'
    }
    $p2f15cSettleReplayText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C exact D07 settlement replay' -Sql @'
select haulvia_command.command_confirm_driver_payout(c.input_settlement)::text
from p2f_test.payout_retry_race_context c where c.race_key='P2F-15C';
'@
    Write-Host "P2F15C_SETTLEMENT_REPLAY|$p2f15cSettleReplayText"
    $p2f15cSettleReplay = $p2f15cSettleReplayText | ConvertFrom-Json
    if ($p2f15cSettleReplay.replayed -ne $true -or
        $p2f15cSettleReplay.payoutTransactionId -ne $p2f15cSettle.payoutTransactionId) {
        throw 'P2F-15C settlement idempotent replay failed.'
    }
    $p2f15cFailReplayText = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C original D08 failure replay' -Sql @'
select haulvia_command.command_handle_payout_failure(c.input_failure)::text
from p2f_test.payout_retry_race_context c where c.race_key='P2F-15C';
'@
    Write-Host "P2F15C_FAILURE_REPLAY|$p2f15cFailReplayText"
    $p2f15cFailReplay = $p2f15cFailReplayText | ConvertFrom-Json
    $p2f15cFailureBinding = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C previous failed outcome replay identity' -Sql @'
select c.failure_outcome_transaction_id::text
from p2f_test.payout_retry_race_context c where c.race_key='P2F-15C';
'@
    if ($p2f15cFailReplay.replayed -ne $true -or
        $p2f15cFailReplay.payoutTransactionId -ne $p2f15cFailureBinding) {
        throw 'P2F-15C retained D08 failure did not replay its original outcome.'
    }
    $p2f15cFinalReplay = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C final no-duplicate-movement state' -Sql $p2f15cPostSql
    Write-Host "P2F15C_FINAL_STATE|$p2f15cFinalReplay"
    if ($p2f15cFinalReplay -ne $p2f15cFinal) {
        throw 'P2F-15C replay duplicated final settlement or rewrote failure history.'
    }
    $p2f15cDoublePayout = Invoke-PsqlAllowFailure -Database $TargetDatabase -Sql @"
select haulvia_command.command_submit_driver_payout(
  $p2f15cWinnerInput || jsonb_build_object(
    'commandId',gen_random_uuid(),
    'idempotencyKey','p2f15c-after-paid-rejected',
    'requestHash',repeat('7',64),
    'providerIdempotencyKey','p2f15c-after-paid-provider-rejected'
  ))::text
from p2f_test.payout_retry_race_context where race_key='P2F-15C';
"@
    Write-Host "P2F15C_AFTER_PAID_REJECT_EXIT|$($p2f15cDoublePayout.ExitCode)"
    if ($p2f15cDoublePayout.ExitCode -eq 0 -or
        $p2f15cDoublePayout.Text -notmatch 'PAYOUT_ALREADY_PAID') {
        throw 'P2F-15C post-settlement double payout failed open.'
    }
    $p2f15cDoubleResidue = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C double payout failure left no residue' -Sql @'
select concat_ws('|',
  (select count(*) from haulvia.command_idempotency c where c.idempotency_key='p2f15c-after-paid-rejected')::text,
  (select count(*) from haulvia.payout_transactions t where t.idempotency_key='p2f15c-after-paid-provider-rejected')::text,
  (select count(*) from haulvia.audit_events a where a.idempotency_key='p2f15c-after-paid-rejected')::text,
  (select count(*) from haulvia.workflow_axis_events e where e.idempotency_key='p2f15c-after-paid-rejected')::text);
'@
    Write-Host "P2F15C_AFTER_PAID_RESIDUE|$p2f15cDoubleResidue"
    if ($p2f15cDoubleResidue -ne '0|0|0|0') {
        throw 'P2F-15C rejected duplicate payout created residue.'
    }
    $p2f15cFinalPost = Invoke-PsqlScalar -Database $TargetDatabase `
        -Label 'P2F-15C final state unchanged after all negative probes' -Sql $p2f15cPostSql
    if ($p2f15cFinalPost -ne $p2f15cFinal) {
        throw 'P2F-15C final payout facts changed during negative probes.'
    }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'P2F-15C D08 FAILURE / D06 RETRY RACE PASSED'
    Write-Host '============================================================'
    Write-Host 'PASS: D08 failed outcome retained with immutable linkage to first D06.'
    Write-Host 'PASS: two independent PAYOUT_WORKER retries synchronized on one eligible amount.'
    Write-Host 'PASS: exactly one retry submitted 90 CAD; the loser left zero residue.'
    Write-Host 'PASS: original failure was not converted into a paid transaction.'
    Write-Host 'PASS: successful retry D07 paid 90 CAD exactly once.'
    Write-Host 'PASS: command replay, hash conflict, and post-PAID rejection enforced.'
    Write-Host 'PASS: one payout/eligibility/completion ledger survived without double movement.'
    Write-Host 'P2F-15 internal progress: 3 / 3 payout sub-races.'
    Write-Host 'P2F-15 PAYOUT RACE PASSED'
    Write-Host 'P2F concurrency progress: 7 / 8 race domains.'
    Write-Host 'Next required domain: P2F-16 Recovery race.'
    Write-Host ''

    # ========================================================================
    # P2F-16 E10 RECOVERY CREATION/ACTIVATION RACE.
    # Independent database sessions race incompatible recovery route plans.
    # Only runtime checks below can authorize 8/8; source patch alone cannot.
    # ========================================================================
    Write-Host ''
    Write-Host '================ P2F-16 BLOCK E RECOVERY FIXTURE ================'
    $p2f16Acceptance = Join-Path $PSScriptRoot 'haulvia_block_e_acceptance_v1.sql'
    $p2f16Migration = Join-Path $RepoRoot 'supabase\migrations\20260814000600_haulvia_block_e_commands_v1.sql'
    if ((Get-FileHash -LiteralPath $p2f16Acceptance -Algorithm SHA256).Hash -ne 'C4ED21B6FA06E7F6491DAAE7AEDA2DFF1CA562C75211A94B830AC0EF2059C83D' -or
        (Get-FileHash -LiteralPath $p2f16Migration -Algorithm SHA256).Hash -ne '1A24146DD01B02C59FDAF666830E7DF278FF8A8A8471407E8273EBFE8C27D8FD') {
        throw 'P2F-16 Block E source hash mismatch: frozen acceptance/migration must remain unchanged.'
    }
    $p2f16Source = [System.IO.File]::ReadAllText($p2f16Acceptance).Replace("`r`n", "`n")
    function Get-P2F16Section {
        param([string]$Start,[string]$End)
        $from = $p2f16Source.IndexOf($Start,[StringComparison]::Ordinal)
        if ($from -lt 0) { throw "P2F-16 fixture source start missing: $Start" }
        $to = $p2f16Source.IndexOf($End,$from+$Start.Length,[StringComparison]::Ordinal)
        if ($to -lt 0 -or $to -le $from) { throw "P2F-16 fixture source end missing: $End" }
        if ($p2f16Source.IndexOf($Start,$from+$Start.Length,[StringComparison]::Ordinal) -ge 0) {
            throw "P2F-16 fixture section duplicated: $Start"
        }
        return $p2f16Source.Substring($from,$to-$from)
    }
    $p2f16Envelope = Get-P2F16Section -Start 'create or replace function pg_temp.envelope(' `
        -End '-- Shared customer, two eligible providers, policy, pricing, and fresh-admin fixtures.'
    $p2f16Shared = Get-P2F16Section -Start '-- Shared customer, two eligible providers, policy, pricing, and fresh-admin fixtures.' `
        -End '-- A two-stop immutable route fixture.'
    $p2f16SeedFunctions = Get-P2F16Section -Start 'create or replace function pg_temp.seed_route(' `
        -End '-- E01 and E16:'
    function Replace-P2F16Once {
        param([string]$Text,[string]$Old,[string]$New,[string]$Label)
        $n = [regex]::Matches($Text,[regex]::Escape($Old)).Count
        Write-Host "P2F16_COMPATIBILITY_REPLACEMENT|$Label|$n"
        if ($n -ne 1) { throw "P2F-16 frozen source compatibility anchor invalid: $Label" }
        return $Text.Replace($Old,$New)
    }
    # Legacy BLOCK_E_ADMIN is not grantable to HAULVIA under the installed
    # role-kind constraints. Use already seeded PLATFORM_ADMIN for the fixture
    # with real P2A publisher authority; never bypass publication triggers.
    $p2f16LegacyRoleStart = '  insert into roles(id, role_key, name, description)'
    $p2f16LegacyRoleEnd = '  insert into reauth_sessions('
    $p2f16RoleStart = $p2f16Shared.IndexOf($p2f16LegacyRoleStart,[StringComparison]::Ordinal)
    $p2f16RoleEnd = $p2f16Shared.IndexOf($p2f16LegacyRoleEnd,$p2f16RoleStart,[StringComparison]::Ordinal)
    if ($p2f16RoleStart -lt 0 -or $p2f16RoleEnd -le $p2f16RoleStart) {
        throw 'P2F-16 Block E legacy role boundaries changed.'
    }
    $p2f16RoleBlock = $p2f16Shared.Substring($p2f16RoleStart,$p2f16RoleEnd-$p2f16RoleStart)
    foreach ($requiredRole in @('BLOCK_E_ADMIN','insert into role_permissions','insert into membership_roles')) {
        if (-not $p2f16RoleBlock.Contains($requiredRole)) {
            throw "P2F-16 Block E legacy role block changed: $requiredRole"
        }
    }
    $p2f16Shared = $p2f16Shared.Remove($p2f16RoleStart,$p2f16RoleEnd-$p2f16RoleStart)
    $p2f16Publisher = @'
  -- P2F-16 local acceptance-only PLATFORM_ADMIN publisher.
  insert into membership_roles (membership_id, role_id)
  select v_membership, id from roles where role_key = 'PLATFORM_ADMIN';
  if not found then raise exception 'P2F-16 PLATFORM_ADMIN seed missing'; end if;
  if not coalesce(haulvia.has_permission(v_admin,v_admin_org,'POLICY_PUBLISH'),false)
     or not coalesce(haulvia.has_permission(v_admin,v_admin_org,'PRICING_MANAGE'),false) then
    raise exception 'P2F-16 publisher lacks P2A authority';
  end if;
'@
    $p2f16Shared = Replace-P2F16Once -Text $p2f16Shared `
        -Old '  insert into policy_sets(id, policy_key, name)' `
        -New ($p2f16Publisher + "`n  insert into policy_sets(id, policy_key, name)") `
        -Label 'platform-authority'
    $p2f16Shared = Replace-P2F16Once -Text $p2f16Shared `
        -Old ("    config_sha256, legal_review_required, created_by_profile_id,`n    approved_by_profile_id, approved_at") `
        -New ("    config_sha256, legal_review_required, created_by_profile_id,`n    approved_by_profile_id, approved_at, reauth_session_id, approval_reason") `
        -Label 'policy-publication-columns'
    $p2f16Shared = Replace-P2F16Once -Text $p2f16Shared `
        -Old 'false, v_admin, v_admin, clock_timestamp()' `
        -New "false, v_customer, v_admin, clock_timestamp(), 'e3000000-0000-0000-0000-000000000004'::uuid, 'P2F-16 recovery policy acceptance'" `
        -Label 'policy-independent-approver'
    $p2f16Shared = Replace-P2F16Once -Text $p2f16Shared `
        -Old '    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at' `
        -New '    rule_config, rule_sha256, created_by_profile_id, approved_by_profile_id, approved_at, reauth_session_id, approval_reason' `
        -Label 'pricing-publication-columns'
    $p2f16Shared = Replace-P2F16Once -Text $p2f16Shared `
        -Old "repeat('5', 64), v_admin, v_admin, clock_timestamp()" `
        -New "repeat('5', 64), v_customer, v_admin, clock_timestamp(), 'e3000000-0000-0000-0000-000000000004'::uuid, 'P2F-16 recovery pricing acceptance'" `
        -Label 'pricing-independent-approver'
    $p2f16SeedTail = @'
create table p2f_test.recovery_race_context (
 race_key text primary key, shipment_id uuid not null,
 prior_route_version_id uuid not null, prior_route_execution_id uuid not null,
 assignment_id uuid not null, cargo_stable_key uuid not null,
 custody_snapshot jsonb not null, input_a jsonb not null, input_b jsonb not null
);
create or replace function pg_temp.recovery_plan(p_fixture jsonb, p_label text)
returns jsonb language plpgsql as $$
declare
 v_pickup uuid := gen_random_uuid(); v_return uuid := gen_random_uuid();
 v_cargo uuid := gen_random_uuid(); v_allocation uuid := gen_random_uuid();
begin
 return jsonb_build_object(
  'plannedDistanceKm',30,'plannedDurationSeconds',2400,
  'stops',jsonb_build_array(
   jsonb_build_object('id',v_pickup,'stableStopKey',(p_fixture ->> 'pickupStableKey')::uuid,
    'sequenceNo',1,'stopType','PICKUP','addressLine1','100 Origin Road',
    'city','Saskatoon','regionCode','SK','countryCode','CA',
    'verificationProfile',jsonb_build_object('photo',true)),
   jsonb_build_object('id',v_return,'stableStopKey',gen_random_uuid(),
    'sequenceNo',2,'stopType','RETURN','addressLine1',p_label || ' Return Road',
    'city','Saskatoon','regionCode','SK','countryCode','CA',
    'verificationProfile',jsonb_build_object('photo',true))
  ),
  'legs',jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),
    'sequenceNo',1,'fromStopId',v_pickup,'toStopId',v_return,
    'plannedDistanceKm',30,'plannedDurationSeconds',2400)),
  'cargoItems',jsonb_build_array(jsonb_build_object('id',v_cargo,
    'stableCargoKey',(p_fixture ->> 'cargoStableKey')::uuid,
    'cargoLineNo',1,'description','Block E cargo','quantity',1,
    'quantityUnit','piece','totalWeightKg',10,'declaredValue',100,'currency','CAD')),
  'allocations',jsonb_build_array(jsonb_build_object('id',v_allocation,
    'cargoItemId',v_cargo,'pickupStopId',v_pickup,'deliveryStopId',v_return,
    'quantity',1,'quantityUnit','piece'))
 );
end;
$$;
do $$
declare
 v_f jsonb := pg_temp.seed_execution('p2f16-recovery',2,'EN_ROUTE','DELIVERY',true,false);
 v_shipment uuid := (v_f ->> 'shipmentId')::uuid;
 v_a jsonb; v_b jsonb;
begin
 v_a := pg_temp.envelope(v_shipment,'e3000000-0000-0000-0000-000000000002',
      'p2f16-recovery-a','a') || jsonb_build_object(
  'actorOrganizationId','e3000000-0000-0000-0000-000000000001',
  'reauthSessionId','e3000000-0000-0000-0000-000000000004',
  'workerAuthority','RECOVERY_WORKER',
  'expectedRouteVersionId',v_f ->> 'routeVersionId',
  'expectedAssignmentId',v_f ->> 'assignmentId',
  'expectedRouteExecutionId',v_f ->> 'routeExecutionId',
  'expectedRouteExecutionVersion',0,
  'reason','P2F16 first competing recovery plan',
  'recoveryKind','RETURN','recoveryActionCode','RETURN',
  'providerAcceptance',jsonb_build_object('accepted',true,
    'driverId','e2000000-0000-0000-0000-000000000004',
    'acceptedAt',clock_timestamp()),
  'recoverySnapshot',jsonb_build_object('approvedDestination','ORIGINAL_SENDER',
    'reasonCode','DESTINATION_UNAVAILABLE'),
  'custodyBalance',v_f -> 'custodyBalance',
  'routePlan',pg_temp.recovery_plan(v_f,'First'),
  'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE',
  'pricingRuleVersionId','e5000000-0000-0000-0000-000000000002',
  'amount',0,'subtotal',0,'taxAmount',0,
  'additionalPaymentAmount',0,'currency','CAD',
  'breakdown','[]'::jsonb,'snapshotSha256',repeat('a',64),
  'emergencyWaiver',false,'nextStopEtaAt',clock_timestamp()+interval '2 hours'
 );
 v_b := pg_temp.envelope(v_shipment,'e3000000-0000-0000-0000-000000000002',
      'p2f16-recovery-b','b') || jsonb_build_object(
  'actorOrganizationId','e3000000-0000-0000-0000-000000000001',
  'reauthSessionId','e3000000-0000-0000-0000-000000000004',
  'workerAuthority','RECOVERY_WORKER',
  'expectedRouteVersionId',v_f ->> 'routeVersionId',
  'expectedAssignmentId',v_f ->> 'assignmentId',
  'expectedRouteExecutionId',v_f ->> 'routeExecutionId',
  'expectedRouteExecutionVersion',0,
  'reason','P2F16 second competing recovery plan',
  'recoveryKind','RETURN','recoveryActionCode','RETURN',
  'providerAcceptance',jsonb_build_object('accepted',true,
    'driverId','e2000000-0000-0000-0000-000000000004',
    'acceptedAt',clock_timestamp()),
  'recoverySnapshot',jsonb_build_object('approvedDestination','ORIGINAL_SENDER',
    'reasonCode','DESTINATION_UNAVAILABLE'),
  'custodyBalance',v_f -> 'custodyBalance',
  'routePlan',pg_temp.recovery_plan(v_f,'Second'),
  'pricingSource','HAULVIA_GUARDRAIL','pricingMode','NOT_APPLICABLE',
  'pricingRuleVersionId','e5000000-0000-0000-0000-000000000002',
  'amount',0,'subtotal',0,'taxAmount',0,
  'additionalPaymentAmount',0,'currency','CAD',
  'breakdown','[]'::jsonb,'snapshotSha256',repeat('b',64),
  'emergencyWaiver',false,'nextStopEtaAt',clock_timestamp()+interval '3 hours'
 );
 if not exists (select 1 from haulvia.route_executions re
    where re.id=(v_f ->> 'routeExecutionId')::uuid and re.state='ACTIVE'
      and re.record_version=0) or
    not exists (select 1 from haulvia.v_cargo_custody_balance cb
      where cb.shipment_id=v_shipment and cb.onboard_quantity=1) then
    raise exception 'P2F-16 fixture lacks active route or verified onboard cargo';
 end if;
 insert into p2f_test.recovery_race_context (
  race_key,shipment_id,prior_route_version_id,prior_route_execution_id,
  assignment_id,cargo_stable_key,custody_snapshot,input_a,input_b
 ) values ('P2F-16',v_shipment,(v_f ->> 'routeVersionId')::uuid,
  (v_f ->> 'routeExecutionId')::uuid,(v_f ->> 'assignmentId')::uuid,
  (v_f ->> 'cargoStableKey')::uuid,v_f -> 'custodyBalance',v_a,v_b);
end;
$$;
commit;
'@
    $p2f16FixtureFile = Join-Path $TempRoot 'p2f16-fixture.sql'
    $p2f16FixtureOut = Join-Path $TempRoot 'p2f16-fixture.stdout.txt'
    $p2f16FixtureErr = Join-Path $TempRoot 'p2f16-fixture.stderr.txt'
    $p2f16FixtureExit = Join-Path $TempRoot 'p2f16-fixture.exit.txt'
    $p2f16FixtureSql = @(
        "\set ON_ERROR_STOP on`nbegin;`nset local search_path = haulvia, haulvia_command, public;",
        $p2f16Envelope, $p2f16Shared, $p2f16SeedFunctions, $p2f16SeedTail
    ) -join "`n"
    Write-Utf8NoBom -Path $p2f16FixtureFile -Text ($p2f16FixtureSql.TrimEnd()+"`n")
    $p2f16FixtureProcess = Start-PsqlScriptProcess -SqlFile $p2f16FixtureFile `
        -StdOutFile $p2f16FixtureOut -StdErrFile $p2f16FixtureErr -ExitCodeFile $p2f16FixtureExit
    $p2f16FixtureProcess.WaitForExit()
    $p2f16FixtureExitValue = (Read-WholeFile -Path $p2f16FixtureExit).Trim()
    Write-Host "P2F16_FIXTURE_PSQL_EXIT_CODE|$p2f16FixtureExitValue"
    if ($p2f16FixtureExitValue -ne '0' -or
        (Read-WholeFile -Path $p2f16FixtureOut) -notmatch '(?m)^COMMIT\s*$' -or
        -not [string]::IsNullOrWhiteSpace((Read-WholeFile -Path $p2f16FixtureErr))) {
        Write-Host (Read-WholeFile -Path $p2f16FixtureOut)
        Write-Host (Read-WholeFile -Path $p2f16FixtureErr)
        throw 'P2F-16 recovery fixture did not commit cleanly.'
    }
    $p2f16Pre = Invoke-PsqlScalar -Database $TargetDatabase -Label 'P2F-16 pre-race' -Sql @'
select concat_ws('|',s.shipment_state::text,rv.status::text,re.state::text,
  re.record_version::text,
  (select count(*) from haulvia.recovery_route_records r where r.shipment_id=c.shipment_id)::text,
  (select count(*) from haulvia.v_cargo_custody_balance b
   where b.shipment_id=c.shipment_id and b.onboard_quantity=1)::text,
  (c.input_a ->> 'expectedShipmentVersion'=c.input_b ->> 'expectedShipmentVersion')::text,
  (c.input_a ->> 'expectedRouteExecutionId'=c.input_b ->> 'expectedRouteExecutionId')::text)
from p2f_test.recovery_race_context c
join haulvia.shipments s on s.id=c.shipment_id
join haulvia.route_versions rv on rv.id=c.prior_route_version_id
join haulvia.route_executions re on re.id=c.prior_route_execution_id
where c.race_key='P2F-16';
'@
    Write-Host "P2F16_PRE_RACE|$p2f16Pre"
    if ($p2f16Pre -ne 'ROUTE_IN_PROGRESS|ACTIVE|ACTIVE|0|0|1|true|true') {
        throw 'P2F-16 race did not begin with exactly one active parent execution and custody.'
    }
    Write-Host ''
    Write-Host '================ P2F-16 E10 RECOVERY ACTIVATION RACE ================'
    $p2f16GateFile = Join-Path $TempRoot 'p2f16-gate.sql'
    $p2f16AFile = Join-Path $TempRoot 'p2f16-actor-a.sql'
    $p2f16BFile = Join-Path $TempRoot 'p2f16-actor-b.sql'
    $p2f16GateOut = Join-Path $TempRoot 'p2f16-gate.stdout.txt'
    $p2f16GateErr = Join-Path $TempRoot 'p2f16-gate.stderr.txt'
    $p2f16AOut = Join-Path $TempRoot 'p2f16-actor-a.stdout.txt'
    $p2f16AErr = Join-Path $TempRoot 'p2f16-actor-a.stderr.txt'
    $p2f16AExit = Join-Path $TempRoot 'p2f16-actor-a.exit.txt'
    $p2f16BOut = Join-Path $TempRoot 'p2f16-actor-b.stdout.txt'
    $p2f16BErr = Join-Path $TempRoot 'p2f16-actor-b.stderr.txt'
    $p2f16BExit = Join-Path $TempRoot 'p2f16-actor-b.exit.txt'
    Write-Utf8NoBom -Path $p2f16GateFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f16_gate';
select pg_advisory_lock(216,1601);
select pg_sleep(600);
"@
    Write-Utf8NoBom -Path $p2f16AFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f16_actor_a';
select pg_advisory_lock_shared(216,1601);
\echo P2F16_GATE_ACQUIRED_A
select 'P2F16_RESULT_A|' ||
  haulvia_command.command_start_recovery_leg(c.input_a)::text
from p2f_test.recovery_race_context c where c.race_key='P2F-16';
"@
    Write-Utf8NoBom -Path $p2f16BFile -Text @"
\set ON_ERROR_STOP on
set application_name = 'p2f16_actor_b';
select pg_advisory_lock_shared(216,1601);
\echo P2F16_GATE_ACQUIRED_B
select 'P2F16_RESULT_B|' ||
  haulvia_command.command_start_recovery_leg(c.input_b)::text
from p2f_test.recovery_race_context c where c.race_key='P2F-16';
"@
    $p2f16Released = $false
    try {
        $p2f16GateProc = Start-PsqlScriptProcess -SqlFile $p2f16GateFile `
            -StdOutFile $p2f16GateOut -StdErrFile $p2f16GateErr
        Wait-ForScalarValue -Expected '1' -Label 'P2F-16 exclusive recovery gate' -Sql @"
select count(*) from pg_stat_activity a join pg_locks l on l.pid=a.pid
where a.datname=current_database() and a.application_name='p2f16_gate'
  and l.locktype='advisory' and l.granted;
"@ | Out-Null
        Write-Host 'P2F16_GATE_HELD|1'
        $p2f16ActorA = Start-PsqlScriptProcess -SqlFile $p2f16AFile `
            -StdOutFile $p2f16AOut -StdErrFile $p2f16AErr -ExitCodeFile $p2f16AExit
        $p2f16ActorB = Start-PsqlScriptProcess -SqlFile $p2f16BFile `
            -StdOutFile $p2f16BOut -StdErrFile $p2f16BErr -ExitCodeFile $p2f16BExit
        Wait-ForScalarValue -Expected '2' -Label 'P2F-16 independent recovery workers' -Sql @"
select count(distinct a.pid) from pg_stat_activity a join pg_locks l on l.pid=a.pid
where a.datname=current_database()
  and a.application_name in ('p2f16_actor_a','p2f16_actor_b')
  and l.locktype='advisory' and not l.granted;
"@ | Out-Null
        Write-Host 'P2F16_WAITERS|2'
        $p2f16GateRelease = Invoke-PsqlScalar -Database $TargetDatabase `
            -Label 'P2F-16 release recovery barrier' -Sql @"
select pg_terminate_backend(pid)::text from pg_stat_activity
where datname=current_database() and application_name='p2f16_gate'
  and pid<>pg_backend_pid() limit 1;
"@
        Write-Host "P2F16_GATE_RELEASED|$p2f16GateRelease"
        if ($p2f16GateRelease -notin @('true','t')) { throw 'P2F-16 recovery gate not released.' }
        $p2f16Released = $true
    }
    finally {
        if (-not $p2f16Released) {
            try {
                Invoke-PsqlText -Database $TargetDatabase -Label 'P2F-16 stop waiting actors' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database() and application_name in ('p2f16_actor_a','p2f16_actor_b')
  and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-16 actor cleanup warning: $_" }
            try {
                Invoke-PsqlText -Database $TargetDatabase -Label 'P2F-16 release gate on failure' -Sql @"
select pg_terminate_backend(pid) from pg_stat_activity
where datname=current_database() and application_name='p2f16_gate' and pid<>pg_backend_pid();
"@ | Out-Null
            } catch { Write-Warning "P2F-16 gate cleanup warning: $_" }
        }
    }
    $p2f16ActorA.WaitForExit()
    $p2f16ActorB.WaitForExit()
    $p2f16GateProc.WaitForExit()
    $p2f16OutA = Read-WholeFile -Path $p2f16AOut
    $p2f16OutB = Read-WholeFile -Path $p2f16BOut
    $p2f16ErrA = Read-WholeFile -Path $p2f16AErr
    $p2f16ErrB = Read-WholeFile -Path $p2f16BErr
    $p2f16CodeA = (Read-WholeFile -Path $p2f16AExit).Trim()
    $p2f16CodeB = (Read-WholeFile -Path $p2f16BExit).Trim()
    Write-Host '---- P2F-16 Worker A stdout ----'
    Write-Host $p2f16OutA
    Write-Host '---- P2F-16 Worker A stderr ----'
    Write-Host $p2f16ErrA
    Write-Host '---- P2F-16 Worker B stdout ----'
    Write-Host $p2f16OutB
    Write-Host '---- P2F-16 Worker B stderr ----'
    Write-Host $p2f16ErrB
    Write-Host "P2F16_EXIT_CODES|$p2f16CodeA|$p2f16CodeB"
    if ($p2f16CodeA -notmatch '^\d+$' -or $p2f16CodeB -notmatch '^\d+$') {
        throw 'P2F-16 actor exit codes malformed.'
    }
    $p2f16WinA = $p2f16CodeA -eq '0'
    $p2f16WinB = $p2f16CodeB -eq '0'
    if ($p2f16WinA -eq $p2f16WinB) { throw 'P2F-16 must have exactly one winning recovery activation.' }
    $p2f16Winner = if ($p2f16WinA) { 'A' } else { 'B' }
    $p2f16Loser = if ($p2f16WinA) { 'B' } else { 'A' }
    $p2f16WinnerOutput = if ($p2f16WinA) { $p2f16OutA } else { $p2f16OutB }
    $p2f16LoserError = if ($p2f16WinA) { $p2f16ErrB } else { $p2f16ErrA }
    $p2f16LoserKey = if ($p2f16WinA) { 'p2f16-recovery-b' } else { 'p2f16-recovery-a' }
    if ($p2f16LoserError -notmatch '"code"\s*:\s*"(STALE_SHIPMENT_VERSION|STALE_ROUTE_VERSION|STALE_ROUTE_EXECUTION_VERSION|INVALID_STATE|ACTIVE_ROUTE_NOT_FOUND|ROUTE_VERSION_MISMATCH|ASSIGNMENT_MISMATCH)"') {
        throw 'P2F-16 losing recovery worker did not fail through a structured approved stale/conflict guard.'
    }
    $p2f16Match = [regex]::Match($p2f16WinnerOutput,'(?m)^P2F16_RESULT_[AB]\|(\{[^\r\n]+\})\s*$')
    if (-not $p2f16Match.Success) { throw 'P2F-16 winning command JSON not captured.' }
    $p2f16Result = $p2f16Match.Groups[1].Value | ConvertFrom-Json
    if ($p2f16Result.replayed -ne $false -or
        $p2f16Result.routeExecutionState -ne 'RECOVERY_ACTIVE' -or
        -not $p2f16Result.recoveryRouteRecordId -or
        -not $p2f16Result.routeExecutionId -or -not $p2f16Result.routeVersionId -or
        $p2f16Result.shipmentState -ne 'ROUTE_IN_PROGRESS') {
        throw 'P2F-16 winner did not create the expected linked active recovery route.'
    }
    Write-Host "P2F16_WINNER|$p2f16Winner|startRecoveryLeg|RECOVERY_ACTIVE"
    Write-Host "P2F16_LOSER|$p2f16Loser|REJECTED"
    $p2f16CanonicalSql = @'
select concat_ws('|',
 s.shipment_state::text,
 (select count(*) from haulvia.route_versions rv where rv.shipment_id=c.shipment_id)::text,
 (select count(*) from haulvia.route_versions rv where rv.shipment_id=c.shipment_id and rv.status='ACTIVE')::text,
 (select count(*) from haulvia.route_versions rv where rv.shipment_id=c.shipment_id and rv.status='SUPERSEDED')::text,
 (select count(*) from haulvia.route_executions re where re.shipment_id=c.shipment_id)::text,
 (select count(*) from haulvia.route_executions re where re.shipment_id=c.shipment_id and re.state in ('ACTIVE','RECOVERY_ACTIVE','HELD'))::text,
 (select count(*) from haulvia.route_executions re where re.shipment_id=c.shipment_id and re.state='RECOVERY_ACTIVE')::text,
 (select count(*) from haulvia.route_executions re where re.id=c.prior_route_execution_id and re.state='COMPLETED' and re.parent_route_execution_id is null and re.next_action='RECOVERY_LINKED')::text,
 (select count(*) from haulvia.recovery_route_records rr where rr.shipment_id=c.shipment_id)::text,
 (select count(*) from haulvia.recovery_route_records rr
   join haulvia.route_executions re on re.id=rr.recovery_route_execution_id
   join haulvia.route_versions rv on rv.id=rr.recovery_route_version_id
   where rr.shipment_id=c.shipment_id and rr.prior_route_version_id=c.prior_route_version_id
     and rr.prior_route_execution_id=c.prior_route_execution_id
     and rr.assignment_id=c.assignment_id
     and re.parent_route_execution_id=c.prior_route_execution_id
     and re.state='RECOVERY_ACTIVE' and re.route_version_id=rr.recovery_route_version_id
     and re.assignment_id=c.assignment_id and re.record_version=1
     and rv.status='ACTIVE' and rr.recovery_kind='RETURN' and rr.recovery_action_code='RETURN'
     and rr.additional_payment_amount=0 and rr.currency='CAD'
     and rr.custody_balance_snapshot=c.custody_snapshot)::text,
 (select count(*) from haulvia.shipment_price_snapshots p where p.shipment_id=c.shipment_id and p.purpose='ADJUSTMENT' and p.total_amount=0)::text,
 (select count(*) from haulvia.shipment_price_snapshots p where p.shipment_id=c.shipment_id and p.purpose='ASSIGNMENT' and p.total_amount=100)::text,
 (select count(*) from haulvia.tracking_sessions ts join haulvia.route_executions re on re.id=ts.route_execution_id
   where re.shipment_id=c.shipment_id and re.state='RECOVERY_ACTIVE' and ts.ended_at is null)::text,
 (select count(*) from haulvia.tracking_sessions ts where ts.route_execution_id=c.prior_route_execution_id and ts.ended_at is not null)::text,
 (select count(*) from haulvia.audit_events a where a.entity_table='shipments' and a.entity_id=c.shipment_id and a.command_name='startRecoveryLeg')::text,
 (select count(*) from haulvia.workflow_axis_events e where e.shipment_id=c.shipment_id and e.command_name='startRecoveryLeg')::text,
 (select count(*) from haulvia.notification_events n where n.shipment_id=c.shipment_id and n.event_code='RECOVERY_ROUTE_STARTED')::text,
 (select count(*) from haulvia.v_cargo_custody_balance b where b.shipment_id=c.shipment_id and b.onboard_quantity=1 and b.stable_cargo_key=c.cargo_stable_key)::text,
 (select count(*) from haulvia.cargo_movements m where m.shipment_id=c.shipment_id and m.movement_type='LOAD')::text
) from p2f_test.recovery_race_context c
join haulvia.shipments s on s.id=c.shipment_id where c.race_key='P2F-16';
'@
    $p2f16Post = Invoke-PsqlScalar -Database $TargetDatabase -Label 'P2F-16 route/price/custody ledger' -Sql $p2f16CanonicalSql
    Write-Host "P2F16_POST_STATE|$p2f16Post"
    $p2f16Expected = 'ROUTE_IN_PROGRESS|2|1|1|2|1|1|1|1|1|1|1|1|1|1|1|1|1|1'
    if ($p2f16Post -ne $p2f16Expected) {
        throw 'P2F-16 recovery route, parent, money, audit, or custody invariants failed.'
    }
    $p2f16Binding = Invoke-PsqlScalar -Database $TargetDatabase -Label 'P2F-16 winner identity binding' -Sql @"
select concat_ws('|',(rr.id='$($p2f16Result.recoveryRouteRecordId)'::uuid)::text,
 (rr.recovery_route_version_id='$($p2f16Result.routeVersionId)'::uuid)::text,
 (rr.recovery_route_execution_id='$($p2f16Result.routeExecutionId)'::uuid)::text,
 (rr.idempotency_key='p2f16-recovery-$($p2f16Winner.ToLowerInvariant())')::text,
 (rr.price_snapshot_id='$($p2f16Result.priceSnapshotId)'::uuid)::text)
from haulvia.recovery_route_records rr join p2f_test.recovery_race_context c on c.shipment_id=rr.shipment_id
where c.race_key='P2F-16';
"@
    Write-Host "P2F16_WINNER_BINDING|$p2f16Binding"
    if ($p2f16Binding -ne 'true|true|true|true|true') { throw 'P2F-16 persisted recovery binding mismatch.' }
    $p2f16WinnerCol = if ($p2f16WinA) { 'input_a' } else { 'input_b' }
    $p2f16Replay = Invoke-PsqlScalar -Database $TargetDatabase -Label 'P2F-16 replay winner' -Sql @"
select haulvia_command.command_start_recovery_leg(c.$p2f16WinnerCol)::text
from p2f_test.recovery_race_context c where c.race_key='P2F-16';
"@
    Write-Host "P2F16_REPLAY|$p2f16Replay"
    $p2f16ReplayJson = $p2f16Replay | ConvertFrom-Json
    if ($p2f16ReplayJson.replayed -ne $true -or
        $p2f16ReplayJson.recoveryRouteRecordId -ne $p2f16Result.recoveryRouteRecordId -or
        $p2f16ReplayJson.routeExecutionId -ne $p2f16Result.routeExecutionId) {
        throw 'P2F-16 idempotent winner replay returned different recovery identifiers.'
    }
    $p2f16Conflict = Invoke-PsqlAllowFailure -Database $TargetDatabase -Sql @"
select haulvia_command.command_start_recovery_leg(
 (select jsonb_set($p2f16WinnerCol,'{requestHash}',to_jsonb(repeat('f',64)))
 from p2f_test.recovery_race_context where race_key='P2F-16'));
"@
    Write-Host "P2F16_IDEMPOTENCY_CONFLICT_EXIT|$($p2f16Conflict.ExitCode)"
    if ($p2f16Conflict.ExitCode -eq 0 -or $p2f16Conflict.Text -notmatch 'IDEMPOTENCY_KEY_REUSED') {
        throw 'P2F-16 same-key/different-hash command did not fail closed.'
    }
    $p2f16LoserResidue = Invoke-PsqlScalar -Database $TargetDatabase -Label 'P2F-16 loser residue' -Sql @"
select concat_ws('|',
 (select count(*) from haulvia.command_idempotency i where i.idempotency_key='$p2f16LoserKey')::text,
 (select count(*) from haulvia.recovery_route_records rr where rr.idempotency_key='$p2f16LoserKey')::text,
 (select count(*) from haulvia.audit_events a where a.idempotency_key='$p2f16LoserKey')::text,
 (select count(*) from haulvia.workflow_axis_events e where e.idempotency_key='$p2f16LoserKey')::text);
"@
    Write-Host "P2F16_LOSER_RESIDUE|$p2f16LoserResidue"
    if ($p2f16LoserResidue -ne '0|0|0|0') { throw 'P2F-16 rejected recovery transaction persisted residue.' }
    $p2f16Final = Invoke-PsqlScalar -Database $TargetDatabase -Label 'P2F-16 final immutable canonical state' -Sql $p2f16CanonicalSql
    Write-Host "P2F16_FINAL_STATE|$p2f16Final"
    if ($p2f16Final -ne $p2f16Post) { throw 'P2F-16 replay/negative probes mutated recovery facts.' }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'P2F-16 RECOVERY RACE PASSED'
    Write-Host '============================================================'
    Write-Host 'PASS: two independent recovery sessions were synchronized at one start gate.'
    Write-Host 'PASS: exactly one linked recovery route and one RECOVERY_ACTIVE execution survived.'
    Write-Host 'PASS: original route SUPERSEDED and original execution COMPLETED once.'
    Write-Host 'PASS: parent/child execution and immutable recovery record linked correctly.'
    Write-Host 'PASS: zero-price adjustment snapshot, tracking, customer notice, and audit created once.'
    Write-Host 'PASS: verified onboard cargo balance retained unchanged.'
    Write-Host 'PASS: winner replay and request-hash conflict enforced.'
    Write-Host 'PASS: losing transaction left no idempotency, recovery, audit or axis residue.'
    Write-Host 'P2F concurrency progress: 8 / 8 race domains.'
    Write-Host ''

    # Source integrity before cleanup
    # ========================================================================

    foreach ($entry in $sourceHashes.GetEnumerator()) {

        $actual =
            (
                Get-FileHash `
                    -LiteralPath $entry.Key `
                    -Algorithm SHA256
            ).Hash

        if ($actual -ne $entry.Value) {
            throw "Source changed during P2F-09/P2F-10/P2F-11/P2F-12 run: $($entry.Key)"
        }
    }


    # ========================================================================
    # Disposable cleanup
    # ========================================================================

    Write-Host ""
    Write-Host "================ P2F-09 / P2F-10 / P2F-11 / P2F-12 DISPOSABLE CLEANUP ================"
    Write-Host ""

    & $DropDbPath `
        -h $DatabaseHost `
        -p $DatabasePort `
        -U $DatabaseUser `
        $TargetDatabase

    if ($LASTEXITCODE -ne 0) {
        throw "P2F-09/P2F-10/P2F-11/P2F-12 passed but disposable database cleanup failed."
    }

    $TargetCreated =
        $false


    Remove-Item `
        -LiteralPath $TempRoot `
        -Recurse `
        -Force

    $RunPassed =
        $true


    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F-09 OFFER RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: two genuinely separate PostgreSQL actor sessions participated."
    Write-Host "PASS: both actors were observed waiting on the test-only start barrier."
    Write-Host "PASS: the barrier was released only after both actors were ready."
    Write-Host "PASS: exactly one logical counter revision committed."
    Write-Host "PASS: losing operation used an approved deterministic conflict path."
    Write-Host "PASS: revision ordering remained unique."
    Write-Host "PASS: customer counter limit remained intact."
    Write-Host "PASS: exact winner replay returned the established result."
    Write-Host "PASS: same-key/different-request-hash reuse failed closed."
    Write-Host "PASS: loser left no command-idempotency or pricing orphan."
    Write-Host "PASS: no reservation/accepted downstream outcome was duplicated."
    Write-Host "PASS: disposable database was removed."
    Write-Host "PASS: production source artifacts were unchanged."
    Write-Host ""
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F-10 RESERVATION RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: two different valid selections raced from the same shipment version."
    Write-Host "PASS: two genuinely separate PostgreSQL actor sessions participated."
    Write-Host "PASS: both actors were observed waiting on the test-only barrier."
    Write-Host "PASS: exactly one active reservation committed."
    Write-Host "PASS: exactly one payment intent and reservation snapshot committed."
    Write-Host "PASS: winning thread became RESERVED."
    Write-Host "PASS: losing still-valid thread remained ACTIVE."
    Write-Host "PASS: marketplace became RESERVED and payment became AUTHORIZING."
    Write-Host "PASS: no assignment was created."
    Write-Host "PASS: exact winner replay returned the established result."
    Write-Host "PASS: same-key/different-request-hash reuse failed closed."
    Write-Host "PASS: loser left no idempotency, payment or pricing orphan."
    Write-Host ""
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F-11 ASSIGNMENT RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: two distinct payment-worker confirmations raced from the same shipment version."
    Write-Host "PASS: both assignment actors referenced the same reservation, payment intent and selected revision."
    Write-Host "PASS: two genuinely separate PostgreSQL actor sessions participated."
    Write-Host "PASS: both actors were observed waiting on the test-only barrier."
    Write-Host "PASS: exactly one active whole-route assignment committed."
    Write-Host "PASS: exactly one successful payment transaction committed."
    Write-Host "PASS: exactly one ASSIGNMENT price snapshot and assignment event committed."
    Write-Host "PASS: reservation converted exactly once."
    Write-Host "PASS: selected thread became ACCEPTED and competing offer state closed."
    Write-Host "PASS: marketplace closed, payment became SECURED and shipment became DRIVER_ASSIGNED."
    Write-Host "PASS: committed assignment retained the selected reservation/revision binding."
    Write-Host "PASS: assignment notifications and trip-start work were not duplicated."
    Write-Host "PASS: exact winner replay returned the established result."
    Write-Host "PASS: same-key/different-request-hash reuse failed closed."
    Write-Host "PASS: loser left no command, payment, pricing, assignment, notification, job or audit orphan."
    Write-Host "PASS: no route execution was created during assignment confirmation."
    Write-Host ""
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F-12 STOP EXECUTION RACE PASSED"
    Write-Host "============================================================"
    Write-Host ""

    Write-Host "PASS: startRoute created one real ACTIVE route execution and EN_ROUTE first pickup."
    Write-Host "PASS: two distinct first-arrival commands raced from the same shipment/execution versions."
    Write-Host "PASS: two genuinely separate PostgreSQL actor sessions participated."
    Write-Host "PASS: both actors were observed waiting on the test-only barrier."
    Write-Host "PASS: exactly one arrival operation committed."
    Write-Host "PASS: ordinary race loser failed STALE_SHIPMENT_VERSION."
    Write-Host "PASS: first pickup and active attempt advanced exactly once to ARRIVED."
    Write-Host "PASS: route-execution record_version advanced exactly once."
    Write-Host "PASS: next action advanced exactly once to START_FIRST_PICKUP_SERVICE."
    Write-Host "PASS: exactly two arrival evidence records committed."
    Write-Host "PASS: exactly one arrival route update committed."
    Write-Host "PASS: waiting-grace job, stop event, audit and customer notification were not duplicated."
    Write-Host "PASS: exact winner replay returned the established result."
    Write-Host "PASS: same-key/different-request-hash reuse failed closed."
    Write-Host "PASS: losing race transaction left zero command/evidence/update/job/event/notification/audit residue."
    Write-Host "PASS: current shipment version plus stale route-execution version failed STALE_ROUTE_EXECUTION_VERSION."
    Write-Host "PASS: stale route-version probe left zero residue."
    Write-Host "PASS: no custody movement was created by arrival confirmation."
    Write-Host ""
    Write-Host "P2F concurrency progress: 4 / 8 race domains."
    Write-Host "Next required domain: P2F-13 Custody race."
}
catch {

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "P2F CONCURRENCY HARNESS STOPPED"
    Write-Host "============================================================"
    Write-Host ""

    if ($TargetCreated) {
        Write-Host "Disposable database retained:"
        Write-Host $TargetDatabase
    }

    if (
        Test-Path -LiteralPath $TempRoot
    ) {
        Write-Host ""
        Write-Host "Session evidence retained:"
        Write-Host $TempRoot
    }

    Write-Host ""
    Write-Host "Do not rerun blindly."

    throw
}
finally {

    if ($PasswordWasSetByHarness) {
        Remove-Item `
            Env:PGPASSWORD `
            -ErrorAction SilentlyContinue
    }
}
