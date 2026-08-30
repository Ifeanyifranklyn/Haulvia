#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: HAULVIA_TEST_DATABASE_URL=postgresql://... $0 [--verify-foundation|--verify-block-a|--verify-block-b|--verify-block-c|--verify-block-d|--verify-block-e|--apply-foundation|--apply-block-a|--apply-block-b|--apply-block-c|--apply-block-d|--apply-block-e|--apply-all]" >&2
  echo "For a dedicated disposable Supabase project whose database is named postgres, also set HAULVIA_ALLOW_DEFAULT_DATABASE=I_CONFIRM_DISPOSABLE_TEST_PROJECT." >&2
}

mode="${1:---verify-foundation}"
if [[ "$mode" == "--verify-existing" ]]; then
  mode="--verify-foundation"
fi
if [[ "$mode" != "--verify-foundation" && "$mode" != "--verify-block-a" \
   && "$mode" != "--verify-block-b" && "$mode" != "--verify-block-c" \
   && "$mode" != "--verify-block-d" && "$mode" != "--verify-block-e" \
   && "$mode" != "--apply-foundation" && "$mode" != "--apply-block-a" \
   && "$mode" != "--apply-block-b" && "$mode" != "--apply-block-c" \
   && "$mode" != "--apply-block-d" && "$mode" != "--apply-block-e" \
   && "$mode" != "--apply-all" ]]; then
  usage
  exit 64
fi

if [[ -z "${HAULVIA_TEST_DATABASE_URL:-}" ]]; then
  usage
  echo "HAULVIA_TEST_DATABASE_URL is required. Use a disposable test database only." >&2
  exit 64
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required but was not found." >&2
  exit 69
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

migration_dir="$script_dir"
if [[ ! -f "$migration_dir/20260814000100_haulvia_foundation_v1.sql" \
   && -f "$script_dir/supabase/migrations/20260814000100_haulvia_foundation_v1.sql" ]]; then
  migration_dir="$script_dir/supabase/migrations"
fi

acceptance_dir="$script_dir"
if [[ ! -f "$acceptance_dir/haulvia_foundation_acceptance_v1.sql" \
   && -f "$script_dir/tests/haulvia_foundation_acceptance_v1.sql" ]]; then
  acceptance_dir="$script_dir/tests"
fi

migration="$migration_dir/20260814000100_haulvia_foundation_v1.sql"
acceptance="$acceptance_dir/haulvia_foundation_acceptance_v1.sql"
block_a_migration="$migration_dir/20260814000200_haulvia_block_a_commands_v1.sql"
block_a_acceptance="$acceptance_dir/haulvia_block_a_acceptance_v1.sql"
block_b_migration="$migration_dir/20260814000300_haulvia_block_b_commands_v1.sql"
block_b_acceptance="$acceptance_dir/haulvia_block_b_acceptance_v1.sql"
block_c_migration="$migration_dir/20260814000400_haulvia_block_c_commands_v1.sql"
block_c_acceptance="$acceptance_dir/haulvia_block_c_acceptance_v1.sql"
block_d_migration="$migration_dir/20260814000500_haulvia_block_d_commands_v1.sql"
block_d_acceptance="$acceptance_dir/haulvia_block_d_acceptance_v1.sql"
block_e_migration="$migration_dir/20260814000600_haulvia_block_e_commands_v1.sql"
block_e_acceptance="$acceptance_dir/haulvia_block_e_acceptance_v1.sql"

for required_file in "$migration" "$acceptance" "$block_a_migration" "$block_a_acceptance" \
  "$block_b_migration" "$block_b_acceptance" "$block_c_migration" "$block_c_acceptance" \
  "$block_d_migration" "$block_d_acceptance" "$block_e_migration" "$block_e_acceptance"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required file is missing: $required_file" >&2
    exit 66
  fi
done

IFS='|' read -r database_name server_version_num < <(
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '|' \
    -c "select current_database(), current_setting('server_version_num')" | tr -d '\r'
)

if [[ "$database_name" == "template0" || "$database_name" == "template1" ]]; then
  echo "Refusing to run against reserved/default database: $database_name" >&2
  exit 78
fi

if [[ "$database_name" == "postgres" ]]; then
  if [[ "${HAULVIA_ALLOW_DEFAULT_DATABASE:-}" != "I_CONFIRM_DISPOSABLE_TEST_PROJECT" ]]; then
    echo "Refusing to run against the default database: postgres" >&2
    echo "A dedicated disposable Supabase project may be used only with HAULVIA_ALLOW_DEFAULT_DATABASE=I_CONFIRM_DISPOSABLE_TEST_PROJECT." >&2
    exit 78
  fi
  echo "WARNING: default database override accepted for a confirmed disposable test project."
fi

if (( server_version_num < 150000 )); then
  echo "PostgreSQL 15 or newer is required; detected server_version_num=$server_version_num" >&2
  exit 78
fi

echo "Target: $database_name (server_version_num=$server_version_num)"

if [[ "$mode" == "--apply-foundation" || "$mode" == "--apply-all" ]]; then
  echo "Applying Haulvia foundation migration..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$migration"
else
  installed_tables="$({
    psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At \
      -c "select count(*) from information_schema.tables where table_schema='haulvia' and table_type='BASE TABLE'" | tr -d '\r'
  })"
  if (( installed_tables < 83 )); then
    echo "Expected at least 83 Haulvia foundation tables; found $installed_tables. Use --apply-foundation on a new disposable database." >&2
    exit 78
  fi
fi

if [[ "$mode" == "--apply-block-a" || "$mode" == "--apply-all" ]]; then
  echo "Applying Haulvia Block A command migration..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_a_migration"
fi

if [[ "$mode" == "--verify-block-a" || "$mode" == "--verify-block-b" \
   || "$mode" == "--verify-block-c" || "$mode" == "--verify-block-d" \
   || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-a" || "$mode" == "--apply-block-b" \
   || "$mode" == "--apply-block-c" || "$mode" == "--apply-block-d" \
   || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  IFS='|' read -r installed_tables installed_command_wrappers < <(
    psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '|' -c \
      "select
         (select count(*) from information_schema.tables where table_schema='haulvia' and table_type='BASE TABLE'),
         (select count(*) from information_schema.routines where routine_schema='haulvia_command' and routine_name like 'command_%')" \
      | tr -d '\r'
  )
  if (( installed_tables < 86 || installed_command_wrappers < 20 )); then
    echo "Expected at least 86 Haulvia tables and 20 Block A command wrappers; found $installed_tables and $installed_command_wrappers." >&2
    exit 78
  fi
fi

if [[ "$mode" == "--apply-block-b" || "$mode" == "--apply-all" ]]; then
  echo "Applying Haulvia Block B command migration..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_b_migration"
fi

if [[ "$mode" == "--verify-block-b" || "$mode" == "--verify-block-c" \
   || "$mode" == "--verify-block-d" || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-b" || "$mode" == "--apply-block-c" \
   || "$mode" == "--apply-block-d" || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  IFS='|' read -r installed_tables installed_command_wrappers < <(
    psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '|' -c \
      "select
         (select count(*) from information_schema.tables where table_schema='haulvia' and table_type='BASE TABLE'),
         (select count(*) from information_schema.routines where routine_schema='haulvia_command' and routine_name like 'command_%')" \
      | tr -d '\r'
  )
  if (( installed_tables < 88 || installed_command_wrappers < 32 )); then
    echo "Expected at least 88 Haulvia tables and 32 Block A+B command wrappers; found $installed_tables and $installed_command_wrappers." >&2
    exit 78
  fi
fi

if [[ "$mode" == "--apply-block-c" || "$mode" == "--apply-all" ]]; then
  echo "Applying Haulvia Block C command migration..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_c_migration"
fi

if [[ "$mode" == "--verify-block-c" || "$mode" == "--verify-block-d" \
   || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-c" || "$mode" == "--apply-block-d" \
   || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  IFS='|' read -r installed_tables installed_views installed_command_wrappers public_command_grants service_helper_grants < <(
    psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '|' -c \
      "select
         (select count(*) from information_schema.tables where table_schema='haulvia' and table_type='BASE TABLE'),
         (select count(*) from information_schema.views where table_schema='haulvia'),
         (select count(*) from information_schema.routines where routine_schema='haulvia_command' and routine_name like 'command_%'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and routine_name like 'command_%' and grantee='PUBLIC'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and grantee='service_role' and left(routine_name,8)<>'command_')" \
      | tr -d '\r'
  )
  if (( installed_tables < 95 || installed_views < 5 || installed_command_wrappers < 46 || public_command_grants != 0 || service_helper_grants != 0 )); then
    echo "Expected at least 95 Haulvia tables, 5 views, 46 Block A+B+C wrappers, zero PUBLIC wrapper grants, and zero service_role helper grants; found $installed_tables, $installed_views, $installed_command_wrappers, $public_command_grants, and $service_helper_grants." >&2
    exit 78
  fi
fi

if [[ "$mode" == "--apply-block-d" || "$mode" == "--apply-all" ]]; then
  echo "Applying Haulvia Block D command migration..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_d_migration"
fi

if [[ "$mode" == "--verify-block-d" || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-d" || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  IFS='|' read -r installed_tables installed_views installed_command_wrappers public_command_grants service_helper_grants < <(
    psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '|' -c \
      "select
         (select count(*) from information_schema.tables where table_schema='haulvia' and table_type='BASE TABLE'),
         (select count(*) from information_schema.views where table_schema='haulvia'),
         (select count(*) from information_schema.routines where routine_schema='haulvia_command' and routine_name like 'command_%'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and routine_name like 'command_%' and grantee='PUBLIC'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and grantee='service_role' and left(routine_name,8)<>'command_')" \
      | tr -d '\r'
  )
  if (( installed_tables < 100 || installed_views < 5 || installed_command_wrappers < 55 || public_command_grants != 0 || service_helper_grants != 0 )); then
    echo "Expected at least 100 Haulvia tables, 5 views, 55 Block A+B+C+D wrappers, zero PUBLIC wrapper grants, and zero service_role helper grants; found $installed_tables, $installed_views, $installed_command_wrappers, $public_command_grants, and $service_helper_grants." >&2
    exit 78
  fi
fi

if [[ "$mode" == "--apply-block-e" || "$mode" == "--apply-all" ]]; then
  echo "Applying Haulvia Block E command migration..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_e_migration"
fi

if [[ "$mode" == "--verify-block-e" || "$mode" == "--apply-block-e" || "$mode" == "--apply-all" ]]; then
  IFS='|' read -r installed_tables installed_views installed_command_wrappers public_function_grants service_wrapper_grants service_helper_grants < <(
    psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -At -F '|' -c \
      "select
         (select count(*) from information_schema.tables where table_schema='haulvia' and table_type='BASE TABLE'),
         (select count(*) from information_schema.views where table_schema='haulvia'),
         (select count(*) from information_schema.routines where routine_schema='haulvia_command' and routine_name like 'command_%'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and grantee='PUBLIC'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and routine_name like 'command_%' and grantee='service_role'),
         (select count(*) from information_schema.routine_privileges where routine_schema='haulvia_command' and grantee='service_role' and left(routine_name,8)<>'command_')" \
      | tr -d '\r'
  )
  if (( installed_tables < 110 || installed_views < 5 || installed_command_wrappers < 70 \
     || public_function_grants != 0 || service_wrapper_grants != installed_command_wrappers \
     || service_helper_grants != 0 )); then
    echo "Expected at least 110 Haulvia tables, 5 views, 70 Block A+B+C+D+E wrappers, zero PUBLIC function grants, every wrapper granted to service_role, and zero service_role helper grants; found $installed_tables, $installed_views, $installed_command_wrappers, $public_function_grants, $service_wrapper_grants, and $service_helper_grants." >&2
    exit 78
  fi
fi

echo "Running rollback-only foundation acceptance suite..."
psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$acceptance"

if [[ "$mode" == "--verify-block-a" || "$mode" == "--verify-block-b" \
   || "$mode" == "--verify-block-c" || "$mode" == "--verify-block-d" \
   || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-a" || "$mode" == "--apply-block-b" \
   || "$mode" == "--apply-block-c" || "$mode" == "--apply-block-d" \
   || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  echo "Running rollback-only Block A acceptance suite..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_a_acceptance"
fi

if [[ "$mode" == "--verify-block-b" || "$mode" == "--verify-block-c" \
   || "$mode" == "--verify-block-d" || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-b" || "$mode" == "--apply-block-c" \
   || "$mode" == "--apply-block-d" || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  echo "Running rollback-only Block B acceptance suite..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_b_acceptance"
fi

if [[ "$mode" == "--verify-block-c" || "$mode" == "--verify-block-d" \
   || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-c" || "$mode" == "--apply-block-d" \
   || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  echo "Running rollback-only Block C acceptance suite..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_c_acceptance"
fi

if [[ "$mode" == "--verify-block-d" || "$mode" == "--verify-block-e" \
   || "$mode" == "--apply-block-d" || "$mode" == "--apply-block-e" \
   || "$mode" == "--apply-all" ]]; then
  echo "Running rollback-only Block D acceptance suite..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_d_acceptance"
fi

if [[ "$mode" == "--verify-block-e" || "$mode" == "--apply-block-e" || "$mode" == "--apply-all" ]]; then
  echo "Running rollback-only Block E acceptance suite..."
  psql "$HAULVIA_TEST_DATABASE_URL" -X -v ON_ERROR_STOP=1 -f "$block_e_acceptance"
fi

echo "Haulvia database checks passed for mode $mode."
