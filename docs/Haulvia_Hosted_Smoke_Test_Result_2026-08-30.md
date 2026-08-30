# Haulvia Hosted Smoke Test Result

**Test date (UTC):** 2026-08-30
**Result:** PASS
**Environment:** Dedicated disposable Supabase project

## Target

- Project name: `haulvia-db-test`
- Project reference: `hdollfahfrrwewekpodr`
- Region: Canada (Central)
- Compute: Nano
- PostgreSQL: 17.6 (`server_version_num=170006`)
- Connection used for acceptance testing: Session pooler with SSL required

No database password, access token, API key, service-role key, or connection string is recorded in this file.

## Migration result

The dry run and hosted migration history both confirmed these six migrations in order:

1. `20260814000100_haulvia_foundation_v1.sql`
2. `20260814000200_haulvia_block_a_commands_v1.sql`
3. `20260814000300_haulvia_block_b_commands_v1.sql`
4. `20260814000400_haulvia_block_c_commands_v1.sql`
5. `20260814000500_haulvia_block_d_commands_v1.sql`
6. `20260814000600_haulvia_block_e_commands_v1.sql`

All six migrations applied successfully. The local and remote migration timestamps matched exactly after installation.

## Acceptance result

The corrected Windows-compatible runner was executed in `--verify-block-e` mode. It verified the installed cumulative shape and ran all rollback-only suites:

- Foundation: PASS (`28` recorded foundation tests)
- Block A: PASS
- Block B: PASS
- Block C: PASS
- Block D: PASS
- Block E: PASS

Every suite ended with `ROLLBACK`. Final runner result:

```text
Haulvia database checks passed for mode --verify-block-e.
```

## Independently verified final shape

| Check | Actual | Expected | Result |
| --- | ---: | ---: | --- |
| Haulvia base tables | 110 | 110 | PASS |
| Haulvia views | 5 | 5 | PASS |
| Named command wrappers | 70 | 70 | PASS |
| Function grants to `PUBLIC` | 0 | 0 | PASS |
| `service_role` wrapper grants | 70 | 70 | PASS |
| `service_role` private-helper grants | 0 | 0 | PASS |

## Runner correction made during hosted testing

Windows `psql` emitted carriage-return characters in captured scalar results. The original runner completed the behavioral suites but printed Bash arithmetic warnings during structural comparisons. The runner was corrected to strip `\r` from captured `psql` output before numeric and security checks. The corrected runner passed shell syntax validation and the complete hosted rerun without warnings.

Corrected runner SHA-256:

```text
41BE21F236725DD8E0550565E7A739666C86F937F2E4E2A967FC93B0FDB8FCDC
```

## Security and cleanup

- The database password was entered only through a silent terminal prompt.
- Temporary password, connection, and disposable-project confirmation environment variables were unset after verification.
- Data API, automatic table exposure, and automatic RLS creation were disabled for this private smoke-test project.
- The Expo application was not connected to the disposable database.
- `frankies-carrier-network` was temporarily paused to free a Free-plan project slot. Its restoration remains required after the disposable Haulvia test project is no longer needed.

## Scope boundary

This result verifies the Foundation-through-Block-E schema, trusted command layer, rollback-only behaviors, and current grant boundary on one hosted PostgreSQL instance. It does not replace the later Phase 2 work for true multi-session concurrency, seed/configuration migrations, Auth/JWT mapping, production RLS, private storage policy, provider webhooks, API adapter tests, or production monitoring.
