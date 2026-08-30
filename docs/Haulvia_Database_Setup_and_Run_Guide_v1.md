# Haulvia Database Setup and Run Guide v1

**Purpose:** Create the Haulvia database project files in VS Code, apply Foundation through Block E to a dedicated disposable Supabase project, and run every rollback-only acceptance suite.

**Current verified database package:**

- 6 ordered migrations: Foundation plus Blocks A–E
- 6 rollback-only acceptance suites
- 110 Haulvia base tables
- 5 Haulvia views
- 70 named command wrappers
- 0 function grants to `PUBLIC`
- all 70 wrappers, and no private helpers, granted to `service_role`

This guide is for the first hosted smoke test. It does not make the schema production-ready. Production RLS, Auth/JWT mapping, payment-provider webhook verification, object-storage policy, seed configuration, and true multi-session concurrency testing still follow later.

## 1. Safety boundary

Use a **new, dedicated, disposable Haulvia test project**. Do not use:

- the Freight Portal database;
- The Frankie's Carrier Network database;
- a production database;
- a project containing data that must be preserved.

The schema does not yet have production RLS policies. Do not connect a public client application to this test project.

Do not share the database password, connection string, service-role key, or Supabase access token in chat, screenshots, source control, or documentation.

## 2. Software required on Windows

Before starting, confirm these commands work in the VS Code terminal:

```powershell
node --version
npm --version
git --version
psql --version
```

You need:

1. Node.js and npm.
2. Git for Windows, which provides Git Bash.
3. PostgreSQL command-line tools, including `psql`.
4. A Supabase account.

If `psql` is not recognized, install the PostgreSQL Windows command-line tools, ensure the PostgreSQL `bin` folder is on the Windows `PATH`, and restart VS Code. The official Windows download is <https://www.postgresql.org/download/windows/>.

The official Supabase CLI setup uses a project-local npm dependency and `npx supabase ...` commands: <https://supabase.com/docs/guides/local-development/cli/getting-started>.

Docker is not required for the hosted-project steps in this guide. It is required only if we later choose to run the complete Supabase stack locally with `npx supabase start`.

## 3. Create the local project folder

In a PowerShell terminal, choose the parent folder where you keep projects and run:

```powershell
New-Item -ItemType Directory -Path haulvia-database
Set-Location haulvia-database
npm init -y
npm install supabase --save-dev
npx supabase init
New-Item -ItemType Directory -Path tests -Force
New-Item -ItemType Directory -Path docs -Force
```

`npx supabase init` creates the `supabase` folder and its configuration. Do not run `npx supabase start` for this hosted test.

## 4. Create and place the files

Download the completed files instead of copying thousands of SQL lines manually.

Use this structure:

```text
haulvia-database/
├── docs/
│   ├── Haulvia_Command_Contracts_Block_A_v1.md
│   ├── Haulvia_Command_Contracts_Block_B_v1.md
│   ├── Haulvia_Command_Contracts_Block_C_v1.md
│   ├── Haulvia_Command_Contracts_Block_D_v1.md
│   ├── Haulvia_Command_Contracts_Block_E_v1.md
│   ├── Haulvia_Database_Schema_Guide_v1.md
│   ├── Haulvia_Database_Setup_and_Run_Guide_v1.md
│   └── Haulvia_ERD_v1.md
├── supabase/
│   ├── config.toml
│   └── migrations/
│       ├── 20260814000100_haulvia_foundation_v1.sql
│       ├── 20260814000200_haulvia_block_a_commands_v1.sql
│       ├── 20260814000300_haulvia_block_b_commands_v1.sql
│       ├── 20260814000400_haulvia_block_c_commands_v1.sql
│       ├── 20260814000500_haulvia_block_d_commands_v1.sql
│       └── 20260814000600_haulvia_block_e_commands_v1.sql
├── tests/
│   ├── haulvia_foundation_acceptance_v1.sql
│   ├── haulvia_block_a_acceptance_v1.sql
│   ├── haulvia_block_b_acceptance_v1.sql
│   ├── haulvia_block_c_acceptance_v1.sql
│   ├── haulvia_block_d_acceptance_v1.sql
│   └── haulvia_block_e_acceptance_v1.sql
├── package.json
└── run_haulvia_database_checks.sh
```

Important rules:

- Keep the six migration filenames and their timestamp order exactly as shown.
- Put only the six migrations in `supabase/migrations`.
- Never put the acceptance suites in `supabase/migrations`; they are tests, not migrations.
- Keep `run_haulvia_database_checks.sh` at the project root.
- In VS Code, confirm the shell runner uses `LF` line endings. The bottom-right status bar should show `LF`, not `CRLF`.

Confirm the files from PowerShell:

```powershell
Get-ChildItem .\supabase\migrations
Get-ChildItem .\tests
Get-Item .\run_haulvia_database_checks.sh
```

You should see six migration files and six acceptance files.

## 5. Create the disposable Supabase project

In the Supabase dashboard:

1. Create a new project with a clear name such as `haulvia-db-test`.
2. Select the Canadian region that best matches the future app when available.
3. Create and securely retain the database password.
4. Wait until the project reports that the database is healthy.
5. Copy the project reference from the project URL or project settings.

Do not reuse another project's reference or database password.

## 6. Log in and link the local folder

From the `haulvia-database` PowerShell terminal:

```powershell
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_REF
```

Replace `YOUR_PROJECT_REF` with the new disposable Haulvia project's reference. Do not type the placeholder literally. Enter the database password only when the CLI securely prompts for it.

The official linked-project workflow is documented at <https://supabase.com/docs/guides/local-development/cli-workflows>.

## 7. Preview the migrations

Run:

```powershell
npx supabase db push --dry-run
```

Stop if the command targets the wrong project or does not list these six migrations in order:

1. `20260814000100_haulvia_foundation_v1.sql`
2. `20260814000200_haulvia_block_a_commands_v1.sql`
3. `20260814000300_haulvia_block_b_commands_v1.sql`
4. `20260814000400_haulvia_block_c_commands_v1.sql`
5. `20260814000500_haulvia_block_d_commands_v1.sql`
6. `20260814000600_haulvia_block_e_commands_v1.sql`

`db push --dry-run` previews pending migrations without applying them. Supabase records applied timestamps in `supabase_migrations.schema_migrations`.

## 8. Apply the six migrations

After the dry run shows the correct project and all six files, run:

```powershell
npx supabase db push
```

Let the command finish. Do not close the terminal during a migration and do not separately paste the same migrations into the SQL Editor.

If `db push` fails:

1. Stop.
2. Save the complete error output, starting with the first error.
3. Do not reorder, rename, edit, or rerun individual migrations.
4. Do not use `npx supabase db reset --linked` unless we deliberately decide to erase this disposable project.

## 9. Obtain the safe test connection parameters

In the Supabase dashboard, open the new project and select **Connect**. Use the **Session pooler** parameters, not the transaction pooler:

- host: the displayed pooler hostname;
- port: `5432`;
- database: `postgres`;
- user: normally `postgres.YOUR_PROJECT_REF`;
- password: the database password created with the project;
- SSL: required.

Session pooler mode is suitable for persistent `psql` test sessions and supports IPv4 networks. Supabase's connection guidance is at <https://supabase.com/docs/guides/database/connecting-to-postgres>.

## 10. Run all six rollback-only suites

In VS Code, open a **Git Bash** terminal at the `haulvia-database` project root.

First confirm the tools are visible:

```bash
bash --version
psql --version
```

Then enter the connection values without placing the password in shell history:

```bash
read -rp "Session pooler host: " HAULVIA_DB_HOST
read -rp "Session pooler user: " HAULVIA_DB_USER
read -rsp "Disposable database password: " PGPASSWORD
echo
export PGPASSWORD
export HAULVIA_TEST_DATABASE_URL="host=$HAULVIA_DB_HOST port=5432 dbname=postgres user=$HAULVIA_DB_USER sslmode=require"
export HAULVIA_ALLOW_DEFAULT_DATABASE=I_CONFIRM_DISPOSABLE_TEST_PROJECT
bash ./run_haulvia_database_checks.sh --verify-block-e
```

Why the long confirmation value exists: hosted Supabase uses the default database name `postgres`. The checker normally rejects that name. It proceeds only when this exact variable confirms that the entire Supabase project is disposable.

Because `npx supabase db push` already applied the migrations, use `--verify-block-e`. Do **not** use `--apply-all` on the same Supabase project.

The runner will:

1. confirm PostgreSQL 15 or newer;
2. confirm the cumulative database shape after each block;
3. run Foundation, A, B, C, D, and E acceptance suites;
4. roll back all test fixtures;
5. verify wrapper grants and private-helper restrictions.

The final line should be:

```text
Haulvia database checks passed for mode --verify-block-e.
```

When finished, remove the credentials from the terminal environment:

```bash
unset PGPASSWORD HAULVIA_TEST_DATABASE_URL HAULVIA_ALLOW_DEFAULT_DATABASE HAULVIA_DB_HOST HAULVIA_DB_USER
```

Close the terminal afterward.

## 11. Independently confirm the installed shape

Open the Supabase SQL Editor for the disposable project and run this read-only query:

```sql
select
  (select count(*)
   from information_schema.tables
   where table_schema = 'haulvia'
     and table_type = 'BASE TABLE') as haulvia_tables,
  (select count(*)
   from information_schema.views
   where table_schema = 'haulvia') as haulvia_views,
  (select count(*)
   from information_schema.routines
   where routine_schema = 'haulvia_command'
     and routine_name like 'command_%') as command_wrappers,
  (select count(*)
   from information_schema.routine_privileges
   where routine_schema = 'haulvia_command'
     and grantee = 'PUBLIC') as public_function_grants,
  (select count(*)
   from information_schema.routine_privileges
   where routine_schema = 'haulvia_command'
     and routine_name like 'command_%'
     and grantee = 'service_role') as service_wrapper_grants,
  (select count(*)
   from information_schema.routine_privileges
   where routine_schema = 'haulvia_command'
     and grantee = 'service_role'
     and left(routine_name, 8) <> 'command_') as service_helper_grants;
```

Expected result:

| Check | Expected |
|---|---:|
| `haulvia_tables` | 110 |
| `haulvia_views` | 5 |
| `command_wrappers` | 70 |
| `public_function_grants` | 0 |
| `service_wrapper_grants` | 70 |
| `service_helper_grants` | 0 |

## 12. Record the hosted smoke-test result

Retain these facts in the project test log:

- date and time;
- disposable Supabase project name and project reference, but not its password or keys;
- migration dry-run result;
- migration push result;
- final checker line;
- the six independent shape values;
- any warning or failure output.

Do not retain the connection string.

## 13. What this test proves—and what it does not

A clean run proves that the exact six migrations install on hosted Supabase, the 110-table/5-view/70-wrapper shape is present, the six acceptance suites pass, test fixtures roll back, and the intended wrapper privilege boundary is installed.

It does not yet prove:

- two-session race handling under real concurrent writes;
- payment-provider signature or webhook behavior;
- Supabase Auth-to-profile mapping;
- production RLS behavior;
- API adapter request validation;
- object-storage access and retention policy;
- production seed values;
- app-screen integration.

Those are the next database-hardening stages after this first hosted run succeeds.

## 14. Stop conditions

Stop and bring back the complete terminal output if any of these happens:

- the linked project is not the dedicated Haulvia test project;
- the dry run lists fewer or more than six Haulvia migrations;
- migration order differs from Foundation → A → B → C → D → E;
- `psql` cannot connect;
- the checker reports any failed assertion;
- the final shape differs from `110 / 5 / 70 / 0 / 70 / 0`;
- a command asks to reset or delete a database.

Do not improvise a fix against the database. We will diagnose the first error and preserve the migration history.
