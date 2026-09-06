-- Haulvia Phase 2 Block P2B acceptance suite v1
--
-- Requires:
--   Foundation v1
--   Blocks A-E command migrations v1
--   P2A authority and configuration seeds v1
--   P2B Auth/Profile Mapping migration v1
--
-- Pure PostgreSQL. No pgTAP dependency.
-- All acceptance fixtures are rolled back.
--
-- Run only against a disposable/local test database with ON_ERROR_STOP=1.

begin;

set local search_path = haulvia, haulvia_command, public;

-- -----------------------------------------------------------------------------
-- Acceptance helpers
-- -----------------------------------------------------------------------------

create temporary table p2b_test_results (
  test_name text primary key,
  passed boolean not null,
  detail text
) on commit drop;

create or replace function pg_temp.assert_true(
  p_test_name text,
  p_condition boolean,
  p_detail text default null
)
returns void
language plpgsql
as $$
begin
  if p_condition is distinct from true then
    raise exception
      'P2B TEST FAILED: % (%)',
      p_test_name,
      coalesce(p_detail, 'condition was not true')
      using errcode = 'P0001';
  end if;

  insert into pg_temp.p2b_test_results (
    test_name,
    passed,
    detail
  )
  values (
    p_test_name,
    true,
    p_detail
  );
end;
$$;

create or replace function pg_temp.expect_error(
  p_test_name text,
  p_sql text,
  p_expected_sqlstate text default null,
  p_message_fragment text default null
)
returns void
language plpgsql
as $$
declare
  v_caught boolean := false;
  v_state text;
  v_message text;
begin
  begin
    execute p_sql;

  exception when others then
    v_caught := true;

    get stacked diagnostics
      v_state = returned_sqlstate,
      v_message = message_text;
  end;

  if not v_caught then
    raise exception
      'P2B TEST FAILED: % (expected an error)',
      p_test_name
      using errcode = 'P0001';
  end if;

  if p_expected_sqlstate is not null
     and v_state <> p_expected_sqlstate
  then
    raise exception
      'P2B TEST FAILED: % (expected SQLSTATE %, received %: %)',
      p_test_name,
      p_expected_sqlstate,
      v_state,
      v_message
      using errcode = 'P0001';
  end if;

  if p_message_fragment is not null
     and position(
       lower(p_message_fragment)
       in lower(coalesce(v_message, ''))
     ) = 0
  then
    raise exception
      'P2B TEST FAILED: % (message did not contain "%": %)',
      p_test_name,
      p_message_fragment,
      v_message
      using errcode = 'P0001';
  end if;

  insert into pg_temp.p2b_test_results (
    test_name,
    passed,
    detail
  )
  values (
    p_test_name,
    true,
    case
      when p_expected_sqlstate is null then
        'Expected error received'
      else
        'Expected SQLSTATE ' || p_expected_sqlstate || ' received'
    end
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- P2B deterministic fixture identifiers
-- -----------------------------------------------------------------------------

create temporary table p2b_fixture_ids (
  fixture_key text primary key,
  id uuid not null
) on commit drop;

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('customer_org',           '20000000-0000-0000-0000-000000000001'),
  ('courier_org',            '20000000-0000-0000-0000-000000000002'),
  ('haulvia_org',            '20000000-0000-0000-0000-000000000003'),

  ('customer_admin',         '21000000-0000-0000-0000-000000000001'),
  ('courier_admin',          '21000000-0000-0000-0000-000000000002'),
  ('haulvia_admin',          '21000000-0000-0000-0000-000000000003'),

  ('invitee_profile',        '21000000-0000-0000-0000-000000000010'),
  ('claim_target_profile',   '21000000-0000-0000-0000-000000000011'),
  ('recovery_profile',       '21000000-0000-0000-0000-000000000012'),

  ('auth_user_a',            '22000000-0000-0000-0000-000000000001'),
  ('auth_user_b',            '22000000-0000-0000-0000-000000000002'),
  ('auth_user_c',            '22000000-0000-0000-0000-000000000003'),
  ('auth_user_d',            '22000000-0000-0000-0000-000000000004'),

  ('customer_membership',    '23000000-0000-0000-0000-000000000001'),
  ('courier_membership',     '23000000-0000-0000-0000-000000000002'),
  ('haulvia_membership',     '23000000-0000-0000-0000-000000000003'),

  ('customer_reauth',        '24000000-0000-0000-0000-000000000001'),
  ('courier_reauth',         '24000000-0000-0000-0000-000000000002'),
  ('haulvia_reauth',         '24000000-0000-0000-0000-000000000003');

-- -----------------------------------------------------------------------------
-- Remaining fixture creation and the 60 contract checks follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B fixture data: organizations, administrators and authority
-- -----------------------------------------------------------------------------

-- Additional deterministic Auth identities used by later acceptance cases.

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('auth_user_e', '22000000-0000-0000-0000-000000000005'),
  ('auth_user_f', '22000000-0000-0000-0000-000000000006'),
  ('auth_user_g', '22000000-0000-0000-0000-000000000007'),
  ('auth_user_h', '22000000-0000-0000-0000-000000000008');

-- -----------------------------------------------------------------------------
-- Organizations
-- -----------------------------------------------------------------------------

insert into haulvia.organizations (
  id,
  organization_key,
  kind,
  legal_name,
  display_name,
  country_code,
  status
)
values
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_org'),
    'p2b-customer-org',
    'CUSTOMER',
    'P2B Customer Organization Ltd.',
    'P2B Customer Organization',
    'CA',
    'ACTIVE'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_org'),
    'p2b-courier-org',
    'COURIER_PARTNER',
    'P2B Courier Organization Ltd.',
    'P2B Courier Organization',
    'CA',
    'ACTIVE'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_org'),
    'p2b-haulvia-org',
    'HAULVIA',
    'Haulvia P2B Test Operations',
    'Haulvia P2B Test Operations',
    'CA',
    'ACTIVE'
  );

-- -----------------------------------------------------------------------------
-- Administrator and identity-test profiles
-- -----------------------------------------------------------------------------

insert into haulvia.profiles (
  id,
  auth_user_id,
  display_name,
  preferred_locale,
  status,
  auth_access_status
)
values
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'auth_user_a'),
    'P2B Customer Admin',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'auth_user_b'),
    'P2B Courier Admin',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'auth_user_c'),
    'P2B Haulvia Admin',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  ),

  -- Existing unclaimed profile for invitation/claim scenarios.
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'invitee_profile'),
    null,
    'P2B Invited Person',
    'en-CA',
    'ACTIVE',
    'UNCLAIMED'
  ),

  -- Existing unclaimed profile for explicit claimExistingProfile tests.
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'claim_target_profile'),
    null,
    'P2B Claim Target',
    'en-CA',
    'ACTIVE',
    'UNCLAIMED'
  ),

  -- Existing claimed profile for privileged Auth-recovery tests.
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'recovery_profile'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'auth_user_d'),
    'P2B Recovery Target',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  );

-- -----------------------------------------------------------------------------
-- Active administrator memberships
-- -----------------------------------------------------------------------------

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status,
  starts_at
)
values
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_membership'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_org'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_admin'),
    'ACTIVE',
    clock_timestamp() - interval '1 day'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_membership'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_org'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_admin'),
    'ACTIVE',
    clock_timestamp() - interval '1 day'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_membership'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_org'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_admin'),
    'ACTIVE',
    clock_timestamp() - interval '1 day'
  );

-- -----------------------------------------------------------------------------
-- Administrator role assignments
-- -----------------------------------------------------------------------------

insert into haulvia.membership_roles (
  membership_id,
  role_id,
  granted_by_profile_id
)
select
  (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_membership'),
  r.id,
  (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_admin')
from haulvia.roles r
where r.role_key = 'BUSINESS_ADMIN';

insert into haulvia.membership_roles (
  membership_id,
  role_id,
  granted_by_profile_id
)
select
  (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_membership'),
  r.id,
  (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_admin')
from haulvia.roles r
where r.role_key = 'COURIER_ADMIN';

insert into haulvia.membership_roles (
  membership_id,
  role_id,
  granted_by_profile_id
)
select
  (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_membership'),
  r.id,
  (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_admin')
from haulvia.roles r
where r.role_key = 'PLATFORM_ADMIN';

-- -----------------------------------------------------------------------------
-- Fresh reauthentication sessions
-- -----------------------------------------------------------------------------

insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at,
  provider_reference
)
values
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_reauth'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_org'),
    'MFA',
    clock_timestamp() - interval '1 minute',
    clock_timestamp() + interval '30 minutes',
    'p2b-test-customer-reauth'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_reauth'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_org'),
    'MFA',
    clock_timestamp() - interval '1 minute',
    clock_timestamp() + interval '30 minutes',
    'p2b-test-courier-reauth'
  ),
  (
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_reauth'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_org'),
    'MFA',
    clock_timestamp() - interval '1 minute',
    clock_timestamp() + interval '30 minutes',
    'p2b-test-haulvia-reauth'
  );

-- -----------------------------------------------------------------------------
-- Fixture-authority sanity checks
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'fixture BUSINESS_ADMIN has ORG_MEMBER_MANAGE',
  haulvia.has_permission(
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'customer_org'),
    'ORG_MEMBER_MANAGE'
  )
);

select pg_temp.assert_true(
  'fixture COURIER_ADMIN has PROVIDER_MEMBER_MANAGE',
  haulvia.has_permission(
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'courier_org'),
    'PROVIDER_MEMBER_MANAGE'
  )
);

select pg_temp.assert_true(
  'fixture PLATFORM_ADMIN has SECURITY_ACCESS_REVIEW',
  haulvia.has_permission(
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_admin'),
    (select id from pg_temp.p2b_fixture_ids where fixture_key = 'haulvia_org'),
    'SECURITY_ACCESS_REVIEW'
  )
);

select pg_temp.assert_true(
  'fixture customer reauthentication is currently valid',
  exists (
    select 1
    from haulvia.reauth_sessions rs
    where rs.id = (
      select id
      from pg_temp.p2b_fixture_ids
      where fixture_key = 'customer_reauth'
    )
      and rs.revoked_at is null
      and rs.verified_at <= clock_timestamp()
      and rs.expires_at > clock_timestamp()
  )
);

select pg_temp.assert_true(
  'fixture courier reauthentication is currently valid',
  exists (
    select 1
    from haulvia.reauth_sessions rs
    where rs.id = (
      select id
      from pg_temp.p2b_fixture_ids
      where fixture_key = 'courier_reauth'
    )
      and rs.revoked_at is null
      and rs.verified_at <= clock_timestamp()
      and rs.expires_at > clock_timestamp()
  )
);

select pg_temp.assert_true(
  'fixture Haulvia reauthentication is currently valid',
  exists (
    select 1
    from haulvia.reauth_sessions rs
    where rs.id = (
      select id
      from pg_temp.p2b_fixture_ids
      where fixture_key = 'haulvia_reauth'
    )
      and rs.revoked_at is null
      and rs.verified_at <= clock_timestamp()
      and rs.expires_at > clock_timestamp()
  )
);

-- -----------------------------------------------------------------------------
-- P2B fixture setup complete.
-- Identity-mapping acceptance checks follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 1-7: identity mapping
-- -----------------------------------------------------------------------------

create or replace function pg_temp.p2b_id(
  p_fixture_key text
)
returns uuid
language sql
stable
as $$
  select f.id
  from pg_temp.p2b_fixture_ids f
  where f.fixture_key = p_fixture_key;
$$;

create temporary table p2b_command_results (
  result_key text primary key,
  result jsonb not null
) on commit drop;

-- -----------------------------------------------------------------------------
-- 1. A new Auth UUID bootstraps exactly one Haulvia profile.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'bootstrap_auth_e_initial',
  haulvia_command.bootstrap_profile_from_auth(
    pg_temp.p2b_id('auth_user_e'),
    'P2B Bootstrap User E',
    'en-CA',
    'p2b-01-bootstrap-auth-e',
    repeat('1', 64),
    '25000000-0000-0000-0000-000000000001'::uuid
  )
);

select pg_temp.assert_true(
  'P2B-01 new Auth UUID bootstraps exactly one Haulvia profile',
  (
    select count(*) = 1
    from haulvia.profiles p
    where p.auth_user_id = pg_temp.p2b_id('auth_user_e')
  )
  and
  (
    select
      (r.result ->> 'profileId')::uuid
        =
      (
        select p.id
        from haulvia.profiles p
        where p.auth_user_id = pg_temp.p2b_id('auth_user_e')
      )
    from pg_temp.p2b_command_results r
    where r.result_key = 'bootstrap_auth_e_initial'
  )
);

-- -----------------------------------------------------------------------------
-- 2. Repeating bootstrap with the same idempotency key returns same profile.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'bootstrap_auth_e_replay',
  haulvia_command.bootstrap_profile_from_auth(
    pg_temp.p2b_id('auth_user_e'),
    'P2B Bootstrap User E',
    'en-CA',
    'p2b-01-bootstrap-auth-e',
    repeat('1', 64),
    '25000000-0000-0000-0000-000000000001'::uuid
  )
);

select pg_temp.assert_true(
  'P2B-02 repeated bootstrap returns the same profile',
  (
    select
      initial.result ->> 'profileId'
        =
      replay.result ->> 'profileId'
    from pg_temp.p2b_command_results initial
    cross join pg_temp.p2b_command_results replay
    where initial.result_key = 'bootstrap_auth_e_initial'
      and replay.result_key = 'bootstrap_auth_e_replay'
  )
  and
  (
    select
      (result ->> 'replayed')::boolean
    from pg_temp.p2b_command_results
    where result_key = 'bootstrap_auth_e_replay'
  )
);

-- -----------------------------------------------------------------------------
-- 3. Repeated bootstrap under another idempotency key cannot duplicate profile.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'bootstrap_auth_e_second_request',
  haulvia_command.bootstrap_profile_from_auth(
    pg_temp.p2b_id('auth_user_e'),
    'P2B Bootstrap User E',
    'en-CA',
    'p2b-03-bootstrap-auth-e-second-key',
    repeat('2', 64),
    '25000000-0000-0000-0000-000000000003'::uuid
  )
);

select pg_temp.assert_true(
  'P2B-03 repeated bootstrap cannot create duplicate profiles',
  (
    select count(*) = 1
    from haulvia.profiles p
    where p.auth_user_id = pg_temp.p2b_id('auth_user_e')
  )
  and
  (
    select
      initial.result ->> 'profileId'
        =
      second_request.result ->> 'profileId'
    from pg_temp.p2b_command_results initial
    cross join pg_temp.p2b_command_results second_request
    where initial.result_key = 'bootstrap_auth_e_initial'
      and second_request.result_key = 'bootstrap_auth_e_second_request'
  )
);

-- -----------------------------------------------------------------------------
-- 4. One Auth UUID cannot be linked to two profiles.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-04 one Auth UUID cannot be linked to two profiles',
  format(
    $sql$
      insert into haulvia.profiles (
        id,
        auth_user_id,
        display_name,
        preferred_locale,
        status,
        auth_access_status
      )
      values (
        '21000000-0000-0000-0000-000000000099'::uuid,
        %L::uuid,
        'Duplicate Auth Mapping',
        'en-CA',
        'ACTIVE',
        'ACTIVE'
      )
    $sql$,
    pg_temp.p2b_id('auth_user_e')::text
  ),
  '23505'
);

-- -----------------------------------------------------------------------------
-- Prepare two independent proofs against one currently-unclaimed profile.
-- The first succeeds; the second must not allow another Auth UUID to overwrite
-- the profile after the first claim.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'claim_proof_one',
  haulvia_command.issue_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('claim_target_profile'),
    'ADMIN_RECOVERY',
    repeat('a', 64),
    null,
    null,
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B claim proof one issuance',
    'p2b-05-claim-proof-one',
    repeat('3', 64),
    null,
    '25000000-0000-0000-0000-000000000005'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'claim_proof_two',
  haulvia_command.issue_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('claim_target_profile'),
    'ADMIN_RECOVERY',
    repeat('b', 64),
    null,
    null,
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B claim proof two issuance',
    'p2b-05-claim-proof-two',
    repeat('4', 64),
    null,
    '25000000-0000-0000-0000-000000000006'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'claim_target_first_claim',
  haulvia_command.claim_existing_profile(
    pg_temp.p2b_id('auth_user_f'),
    repeat('a', 64),
    null,
    'p2b-05-first-profile-claim',
    repeat('5', 64),
    '25000000-0000-0000-0000-000000000007'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 5. A claimed profile cannot be claimed by a second Auth UUID.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-05 claimed profile cannot be claimed by a second Auth UUID',
  format(
    $sql$
      select haulvia_command.claim_existing_profile(
        %L::uuid,
        repeat('b', 64),
        null,
        'p2b-05-second-profile-claim',
        repeat('6', 64),
        '25000000-0000-0000-0000-000000000008'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_g')::text
  ),
  '23505',
  'already been claimed'
);

-- -----------------------------------------------------------------------------
-- 6. Client-selected profile_id cannot impersonate another profile.
--
-- Neither public identity-bootstrap nor ordinary profile-claim command accepts
-- a target profile identifier from the caller.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-06 client-selected profile_id cannot impersonate another profile',
  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    cross join lateral unnest(
      coalesce(
        p.proargnames,
        array[]::text[]
      )
    ) arg_name
    where n.nspname = 'haulvia_command'
      and p.proname in (
        'bootstrap_profile_from_auth',
        'claim_existing_profile'
      )
      and lower(arg_name) in (
        'p_profile_id',
        'p_target_profile_id'
      )
  )
);

-- -----------------------------------------------------------------------------
-- Prepare an existing historical relationship/reference for recovery continuity.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values (
  'recovery_membership',
  '23000000-0000-0000-0000-000000000012'
);

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status,
  starts_at
)
values (
  pg_temp.p2b_id('recovery_membership'),
  pg_temp.p2b_id('customer_org'),
  pg_temp.p2b_id('recovery_profile'),
  'ACTIVE',
  clock_timestamp() - interval '2 days'
);

insert into haulvia.audit_events (
  actor_kind,
  actor_profile_id,
  command_name,
  entity_table,
  entity_id,
  metadata,
  idempotency_key
)
values (
  'PROFILE',
  pg_temp.p2b_id('recovery_profile'),
  'p2bOperationalHistoryFixture',
  'profiles',
  pg_temp.p2b_id('recovery_profile'),
  jsonb_build_object(
    'purpose',
    'prove historical profile reference survives Auth identity replacement'
  ),
  'p2b-operational-history-fixture'
);

-- Approved single-use recovery proof.

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'recovery_proof',
  haulvia_command.issue_profile_auth_recovery_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('recovery_profile'),
    pg_temp.p2b_id('auth_user_h'),
    repeat('c', 64),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B verified identity recovery',
    'p2b-07-recovery-proof',
    repeat('7', 64),
    '25000000-0000-0000-0000-000000000009'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'recovery_completed',
  haulvia_command.replace_profile_auth_identity(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('recovery_profile'),
    pg_temp.p2b_id('auth_user_h'),
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'recovery_proof'
    ),
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B approved Auth identity replacement',
    'p2b-07-replace-auth-identity',
    repeat('8', 64),
    '25000000-0000-0000-0000-000000000010'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 7. Operational/history references retain the same Haulvia profile ID after
--    external Auth identity replacement.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-07 operational records retain the same Haulvia profile after identity recovery',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('recovery_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_h')
      and p.auth_access_status = 'ACTIVE'
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('recovery_membership')
      and om.profile_id = pg_temp.p2b_id('recovery_profile')
  )
  and
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'p2bOperationalHistoryFixture'
      and ae.actor_profile_id = pg_temp.p2b_id('recovery_profile')
      and ae.entity_id = pg_temp.p2b_id('recovery_profile')
  )
);

-- -----------------------------------------------------------------------------
-- P2B acceptance checks 1-7 complete.
-- Invitation-security checks 8-20 follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 8-20: invitation security and membership activation
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('auth_user_i',       '22000000-0000-0000-0000-000000000009'),
  ('auth_user_j',       '22000000-0000-0000-0000-000000000010'),
  ('auth_user_k',       '22000000-0000-0000-0000-000000000011'),
  ('expired_invitation','26000000-0000-0000-0000-000000000001');

-- Common verified destination identity for the invited person.
-- Only the SHA-256 digest is persisted.
create temporary table p2b_invitation_values (
  value_key text primary key,
  value text not null
) on commit drop;

insert into pg_temp.p2b_invitation_values (
  value_key,
  value
)
values
  ('invitee_identity_hash', repeat('d', 64)),
  ('main_invite_secret',    repeat('e', 64)),
  ('revoked_invite_secret', repeat('f', 64)),
  ('expired_invite_secret', repeat('0', 64)),
  ('widen_invite_secret',   repeat('1', 64)),
  ('subset_invite_secret',  repeat('2', 64)),
  ('suspend_invite_secret', repeat('3', 64)),
  ('ended_invite_secret',   repeat('4', 64));

-- -----------------------------------------------------------------------------
-- Create the principal invitation used by several following checks.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'main_customer_invitation',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER'],
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'main_invite_secret'
    ),
    clock_timestamp() + interval '2 hours',
    pg_temp.p2b_id('customer_reauth'),
    'P2B test customer organization invitation',
    'p2b-08-main-customer-invite',
    repeat('9', 64),
    pg_temp.p2b_id('invitee_profile'),
    'p***@example.test',
    '25000000-0000-0000-0000-000000000020'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 8. Creating an invitation grants zero organization authority.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-08 invitation creation grants zero organization authority',
  not exists (
    select 1
    from haulvia.organization_memberships om
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
      and om.status = 'ACTIVE'
  )
  and
  not haulvia.has_permission(
    pg_temp.p2b_id('invitee_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- 9. Only an authorized organization member may create an invitation.
-- -----------------------------------------------------------------------------

insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at,
  provider_reference
)
values (
  '24000000-0000-0000-0000-000000000009'::uuid,
  pg_temp.p2b_id('haulvia_admin'),
  pg_temp.p2b_id('customer_org'),
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes',
  'p2b-test-unauthorized-customer-org-reauth'
);

select pg_temp.expect_error(
  'P2B-09 only an authorized organization member may create an invitation',
  format(
    $sql$
      select haulvia_command.create_organization_invitation(
        %L::uuid,
        %L::uuid,
        array['BUSINESS_VIEWER'],
        repeat('5', 64),
        repeat('6', 64),
        clock_timestamp() + interval '1 hour',
        '24000000-0000-0000-0000-000000000009'::uuid,
        'P2B unauthorized inviter membership test',
        'p2b-09-unauthorized-inviter',
        repeat('c', 64),
        null,
        null,
        '25000000-0000-0000-0000-000000000040'::uuid
      )
    $sql$,
    pg_temp.p2b_id('haulvia_admin')::text,
    pg_temp.p2b_id('customer_org')::text
  ),
  '42501'
);
-- 11. Raw invitation secrets are not represented by a storage column.
--    The persisted invitation contains only the supplied one-way digest.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-11 raw invitation secret is not stored',
  not exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name = 'organization_invitations'
      and lower(c.column_name) in (
        'secret',
        'raw_secret',
        'invitation_secret',
        'token',
        'raw_token',
        'invitation_token'
      )
  )
  and
  exists (
    select 1
    from haulvia.organization_invitations oi
    where oi.id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'main_customer_invitation'
    )
      and oi.secret_hash = (
        select value
        from pg_temp.p2b_invitation_values
        where value_key = 'main_invite_secret'
      )
  )
);

-- -----------------------------------------------------------------------------
-- 10. Invitation roles must respect P2A organization-kind boundaries.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-10 customer invitation cannot contain courier-partner role',
  format(
    $sql$
      select haulvia_command.create_organization_invitation(
        %L::uuid,
        %L::uuid,
        array['COURIER_ADMIN'],
        repeat('5', 64),
        repeat('6', 64),
        clock_timestamp() + interval '1 hour',
        %L::uuid,
        'P2B incompatible invitation role test',
        'p2b-10-incompatible-role',
        repeat('a', 64),
        null,
        null,
        '25000000-0000-0000-0000-000000000021'::uuid
      )
    $sql$,
    pg_temp.p2b_id('customer_admin')::text,
    pg_temp.p2b_id('customer_org')::text,
    pg_temp.p2b_id('customer_reauth')::text
  )
);

-- -----------------------------------------------------------------------------
-- 16. An invitation bound to another verified identity rejects acceptance.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-16 invitation bound to another verified identity fails',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        repeat('7', 64),
        'P2B Invited Person',
        'en-CA',
        'p2b-11-wrong-identity',
        repeat('b', 64),
        '25000000-0000-0000-0000-000000000022'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_i')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'main_invite_secret'
    )
  ),
  '42501',
  'identity'
);

-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- 12. An unknown invitation secret fails.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-12 unknown invitation secret fails',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        repeat('7', 64),
        null,
        'Unknown Invitation User',
        'en-CA',
        'p2b-12-unknown-invitation',
        repeat('d', 64),
        '25000000-0000-0000-0000-000000000041'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_j')::text
  )
);

-- -----------------------------------------------------------------------------
-- 17. Invitation acceptance is atomic.
--
-- P2B-16 already attempted the main invitation using the wrong verified
-- identity. Nothing from that failed transaction may have partially activated.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-17 invitation acceptance is atomic',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('invitee_profile')
      and p.auth_user_id is null
      and p.auth_access_status = 'UNCLAIMED'
  )
  and
  not exists (
    select 1
    from haulvia.organization_memberships om
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
  )
  and
  exists (
    select 1
    from haulvia.organization_invitations oi
    where oi.id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'main_customer_invitation'
    )
      and oi.consumed_at is null
      and oi.consumed_by_profile_id is null
  )
);
-- 13. Expired invitations cannot be accepted.
--
-- This fixture is inserted directly because the public creation command
-- correctly refuses creation with an already-expired timestamp.
-- -----------------------------------------------------------------------------

insert into haulvia.organization_invitations (
  id,
  organization_id,
  invited_by_profile_id,
  target_profile_id,
  destination_identity_hash,
  destination_hint,
  secret_hash,
  expires_at,
  correlation_id,
  creation_idempotency_key,
  created_at
)
values (
  pg_temp.p2b_id('expired_invitation'),
  pg_temp.p2b_id('customer_org'),
  pg_temp.p2b_id('customer_admin'),
  null,
  repeat('8', 64),
  'e***@example.test',
  (
    select value
    from pg_temp.p2b_invitation_values
    where value_key = 'expired_invite_secret'
  ),
  clock_timestamp() - interval '1 hour',
  '25000000-0000-0000-0000-000000000023'::uuid,
  'p2b-12-expired-fixture',
  clock_timestamp() - interval '2 hours'
);

insert into haulvia.organization_invitation_roles (
  invitation_id,
  role_id
)
select
  pg_temp.p2b_id('expired_invitation'),
  r.id
from haulvia.roles r
where r.role_key = 'BUSINESS_VIEWER';

update haulvia.organization_invitations
set sealed_at = clock_timestamp() - interval '90 minutes'
where id = pg_temp.p2b_id('expired_invitation');

select pg_temp.expect_error(
  'P2B-13 expired invitation fails',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        repeat('8', 64),
        'Expired Invitation User',
        'en-CA',
        'p2b-12-expired-accept',
        repeat('c', 64),
        '25000000-0000-0000-0000-000000000024'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_j')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'expired_invite_secret'
    )
  ),
  '42501',
  'expired'
);

-- -----------------------------------------------------------------------------
-- 14. Revoked invitations cannot be accepted.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'revoked_customer_invitation',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER'],
    repeat('9', 64),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'revoked_invite_secret'
    ),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('customer_reauth'),
    'P2B invitation revocation test',
    'p2b-13-create-revoked-invite',
    repeat('d', 64),
    null,
    'r***@example.test',
    '25000000-0000-0000-0000-000000000025'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'revoked_customer_invitation_result',
  haulvia_command.revoke_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'revoked_customer_invitation'
    ),
    pg_temp.p2b_id('customer_reauth'),
    'P2B authorized invitation revocation',
    'p2b-13-revoke-invite',
    repeat('e', 64),
    '25000000-0000-0000-0000-000000000026'::uuid
  )
);

select pg_temp.expect_error(
  'P2B-14 revoked invitation fails',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        repeat('9', 64),
        'Revoked Invitation User',
        'en-CA',
        'p2b-13-accept-revoked',
        repeat('f', 64),
        '25000000-0000-0000-0000-000000000027'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_k')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'revoked_invite_secret'
    )
  ),
  '42501',
  'revoked'
);

-- -----------------------------------------------------------------------------
-- Supplemental: valid acceptance establishes the complete expected state and
--     the membership, assigns invited roles and consumes the invitation.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'main_customer_invitation_accept',
  haulvia_command.accept_organization_invitation(
    pg_temp.p2b_id('auth_user_i'),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'main_invite_secret'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    'P2B Invited Person',
    'en-CA',
    'p2b-14-main-invite-accept',
    repeat('0', 64),
    '25000000-0000-0000-0000-000000000028'::uuid
  )
);

select pg_temp.assert_true(
  'SUPPLEMENTAL valid invitation acceptance establishes identity membership and role',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('invitee_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_i')
      and p.auth_access_status = 'ACTIVE'
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
      and om.status = 'ACTIVE'
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    join haulvia.membership_roles mr
      on mr.membership_id = om.id
    join haulvia.roles r
      on r.id = mr.role_id
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
      and r.role_key = 'BUSINESS_VIEWER'
  )
  and
  exists (
    select 1
    from haulvia.organization_invitations oi
    where oi.id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'main_customer_invitation'
    )
      and oi.consumed_at is not null
      and oi.consumed_by_profile_id = pg_temp.p2b_id('invitee_profile')
  )
);

-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- 18. Successful acceptance produces exactly one active membership.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-18 successful acceptance produces exactly one active membership',
  (
    select count(*) = 1
    from haulvia.organization_memberships om
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
      and om.status = 'ACTIVE'
  )
);

-- -----------------------------------------------------------------------------
-- 19. Successful acceptance produces exactly the approved role mappings.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-19 successful acceptance produces exactly the approved role mappings',
  (
    select count(*) = 1
    from haulvia.organization_memberships om
    join haulvia.membership_roles mr
      on mr.membership_id = om.id
    join haulvia.roles r
      on r.id = mr.role_id
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    join haulvia.membership_roles mr
      on mr.membership_id = om.id
    join haulvia.roles r
      on r.id = mr.role_id
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
      and r.role_key = 'BUSINESS_VIEWER'
  )
);

-- -----------------------------------------------------------------------------
-- 20. Successful acceptance consumes the invitation.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-20 successful acceptance consumes the invitation',
  exists (
    select 1
    from haulvia.organization_invitations oi
    where oi.id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'main_customer_invitation'
    )
      and oi.consumed_at is not null
      and oi.consumed_by_profile_id = pg_temp.p2b_id('invitee_profile')
  )
);
-- 15. A consumed invitation cannot be used by another Auth principal.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-15 consumed invitation cannot be accepted again',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        %L,
        'Second Consumer',
        'en-CA',
        'p2b-15-second-consumption',
        repeat('1', 64),
        '25000000-0000-0000-0000-000000000029'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_j')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'main_invite_secret'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    )
  ),
  '42501',
  'consumed'
);

-- -----------------------------------------------------------------------------
-- Supplemental: invitation secret digests are not copied into notification/audit payloads.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'SUPPLEMENTAL invitation secret digest is excluded from notification and audit payloads',
  not exists (
    select 1
    from haulvia.notification_events ne
    where ne.organization_invitation_id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'main_customer_invitation'
    )
      and (
        coalesce(ne.payload::text, '') like
          '%' ||
          (
            select value
            from pg_temp.p2b_invitation_values
            where value_key = 'main_invite_secret'
          ) ||
          '%'
      )
  )
  and
  not exists (
    select 1
    from haulvia.audit_events ae
    where ae.entity_table = 'organization_invitations'
      and ae.entity_id = (
        select (result ->> 'invitationId')::uuid
        from pg_temp.p2b_command_results
        where result_key = 'main_customer_invitation'
      )
      and (
        coalesce(ae.before_value::text, '') ||
        coalesce(ae.after_value::text, '') ||
        coalesce(ae.metadata::text, '')
      ) like
        '%' ||
        (
          select value
          from pg_temp.p2b_invitation_values
          where value_key = 'main_invite_secret'
        ) ||
        '%'
  )
);

-- -----------------------------------------------------------------------------
-- Supplemental: an invitation cannot widen roles on an already ACTIVE membership.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'active_membership_widen_invite',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER', 'BUSINESS_SHIPMENT_MANAGER'],
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'widen_invite_secret'
    ),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('customer_reauth'),
    'P2B active membership role widening test',
    'p2b-17-create-widen-invite',
    repeat('2', 64),
    pg_temp.p2b_id('invitee_profile'),
    'p***@example.test',
    '25000000-0000-0000-0000-000000000030'::uuid
  )
);

select pg_temp.expect_error(
  'SUPPLEMENTAL active membership invitation cannot widen roles',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        %L,
        'P2B Invited Person',
        'en-CA',
        'p2b-17-accept-widen-invite',
        repeat('3', 64),
        '25000000-0000-0000-0000-000000000031'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_i')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'widen_invite_secret'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    )
  ),
  '42501'
);

-- -----------------------------------------------------------------------------
-- Supplemental: an invitation containing only an already-held role may be consumed
--     without changing the ACTIVE membership's role set.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'active_membership_subset_invite',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER'],
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'subset_invite_secret'
    ),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('customer_reauth'),
    'P2B existing role invitation test',
    'p2b-18-create-subset-invite',
    repeat('4', 64),
    pg_temp.p2b_id('invitee_profile'),
    'p***@example.test',
    '25000000-0000-0000-0000-000000000032'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'active_membership_subset_accept',
  haulvia_command.accept_organization_invitation(
    pg_temp.p2b_id('auth_user_i'),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'subset_invite_secret'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    'P2B Invited Person',
    'en-CA',
    'p2b-18-accept-subset-invite',
    repeat('5', 64),
    '25000000-0000-0000-0000-000000000033'::uuid
  )
);

select pg_temp.assert_true(
  'SUPPLEMENTAL existing-role invitation consumes without widening active membership',
  (
    select count(*) = 1
    from haulvia.organization_memberships om
    join haulvia.membership_roles mr
      on mr.membership_id = om.id
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('invitee_profile')
  )
  and
  exists (
    select 1
    from haulvia.organization_invitations oi
    where oi.id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'active_membership_subset_invite'
    )
      and oi.consumed_at is not null
  )
);

-- Resolve the membership created by the successful invitation acceptance.
insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
select
  'invitee_membership',
  om.id
from haulvia.organization_memberships om
where om.organization_id = pg_temp.p2b_id('customer_org')
  and om.profile_id = pg_temp.p2b_id('invitee_profile');

-- -----------------------------------------------------------------------------
-- Suspend the membership through the trusted command.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'invitee_membership_suspend',
  haulvia_command.suspend_organization_membership(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('invitee_membership'),
    pg_temp.p2b_id('customer_reauth'),
    'P2B suspension invitation test',
    'p2b-19-suspend-membership',
    repeat('6', 64),
    '25000000-0000-0000-0000-000000000034'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'suspended_membership_invite',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER'],
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'suspend_invite_secret'
    ),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('customer_reauth'),
    'P2B suspended membership invitation test',
    'p2b-19-create-suspended-invite',
    repeat('7', 64),
    pg_temp.p2b_id('invitee_profile'),
    'p***@example.test',
    '25000000-0000-0000-0000-000000000035'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 25. A SUSPENDED membership cannot be silently reopened by invitation.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-25 invitation acceptance cannot silently reactivate suspended membership',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        %L,
        'P2B Invited Person',
        'en-CA',
        'p2b-19-accept-suspended-invite',
        repeat('8', 64),
        '25000000-0000-0000-0000-000000000036'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_i')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'suspend_invite_secret'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    )
  ),
  '42501'
);

-- End the same membership through the trusted command.

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'invitee_membership_end',
  haulvia_command.end_organization_membership(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('invitee_membership'),
    pg_temp.p2b_id('customer_reauth'),
    'P2B ended membership invitation test',
    'p2b-20-end-membership',
    repeat('9', 64),
    '25000000-0000-0000-0000-000000000037'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'ended_membership_invite',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER'],
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'ended_invite_secret'
    ),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('customer_reauth'),
    'P2B ended membership invitation test',
    'p2b-20-create-ended-invite',
    repeat('a', 64),
    pg_temp.p2b_id('invitee_profile'),
    'p***@example.test',
    '25000000-0000-0000-0000-000000000038'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 26. An ENDED membership cannot be silently recreated/reopened by invitation.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-26 invitation acceptance cannot silently reopen ended membership',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        %L,
        'P2B Invited Person',
        'en-CA',
        'p2b-20-accept-ended-invite',
        repeat('b', 64),
        '25000000-0000-0000-0000-000000000039'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_i')::text,
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'ended_invite_secret'
    ),
    (
      select value
      from pg_temp.p2b_invitation_values
      where value_key = 'invitee_identity_hash'
    )
  ),
  '42501'
);

-- -----------------------------------------------------------------------------
-- P2B invitation checks 8-20 complete; membership checks 25-26 are also pre-exercised.
-- Membership lifecycle and organization-isolation checks 21-24 and 27-33 follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 21-24 and 27-33:
-- membership lifecycle and organization isolation
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('lifecycle_invited_profile',  '21000000-0000-0000-0000-000000000021'),
  ('lifecycle_suspend_profile',  '21000000-0000-0000-0000-000000000022'),
  ('lifecycle_end_profile',      '21000000-0000-0000-0000-000000000023'),

  ('auth_user_l',                '22000000-0000-0000-0000-000000000012'),
  ('auth_user_m',                '22000000-0000-0000-0000-000000000013'),
  ('auth_user_n',                '22000000-0000-0000-0000-000000000014'),

  ('lifecycle_invited_membership','23000000-0000-0000-0000-000000000021'),
  ('lifecycle_suspend_membership','23000000-0000-0000-0000-000000000022'),
  ('lifecycle_end_membership',    '23000000-0000-0000-0000-000000000023'),

  ('cross_org_reauth',           '24000000-0000-0000-0000-000000000020');

-- -----------------------------------------------------------------------------
-- Dedicated lifecycle profiles
-- -----------------------------------------------------------------------------

insert into haulvia.profiles (
  id,
  auth_user_id,
  display_name,
  preferred_locale,
  status,
  auth_access_status
)
values
  (
    pg_temp.p2b_id('lifecycle_invited_profile'),
    pg_temp.p2b_id('auth_user_l'),
    'P2B Invited Membership User',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  ),
  (
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('auth_user_m'),
    'P2B Suspension User',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  ),
  (
    pg_temp.p2b_id('lifecycle_end_profile'),
    pg_temp.p2b_id('auth_user_n'),
    'P2B Ending User',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  );

-- -----------------------------------------------------------------------------
-- Membership fixtures
-- -----------------------------------------------------------------------------

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status,
  starts_at
)
values
  (
    pg_temp.p2b_id('lifecycle_invited_membership'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('lifecycle_invited_profile'),
    'INVITED',
    clock_timestamp() - interval '1 day'
  ),
  (
    pg_temp.p2b_id('lifecycle_suspend_membership'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    'ACTIVE',
    clock_timestamp() - interval '2 days'
  ),
  (
    pg_temp.p2b_id('lifecycle_end_membership'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('lifecycle_end_profile'),
    'ACTIVE',
    clock_timestamp() - interval '2 days'
  );

-- Retain BUSINESS_VIEWER role mappings across every lifecycle state.

insert into haulvia.membership_roles (
  membership_id,
  role_id,
  granted_by_profile_id
)
select
  fixture.membership_id,
  r.id,
  pg_temp.p2b_id('customer_admin')
from (
  values
    (pg_temp.p2b_id('lifecycle_invited_membership')),
    (pg_temp.p2b_id('lifecycle_suspend_membership')),
    (pg_temp.p2b_id('lifecycle_end_membership'))
) as fixture(membership_id)
cross join haulvia.roles r
where r.role_key = 'BUSINESS_VIEWER';

-- -----------------------------------------------------------------------------
-- Operational-history evidence that must survive lifecycle changes.
-- -----------------------------------------------------------------------------

insert into haulvia.audit_events (
  actor_kind,
  actor_profile_id,
  organization_id,
  command_name,
  entity_table,
  entity_id,
  metadata,
  idempotency_key
)
values
  (
    'PROFILE',
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('customer_org'),
    'p2bSuspendHistoryFixture',
    'profiles',
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    jsonb_build_object(
      'purpose',
      'prove suspension preserves profile and historical references'
    ),
    'p2b-suspend-history-fixture'
  ),
  (
    'PROFILE',
    pg_temp.p2b_id('lifecycle_end_profile'),
    pg_temp.p2b_id('customer_org'),
    'p2bEndHistoryFixture',
    'profiles',
    pg_temp.p2b_id('lifecycle_end_profile'),
    jsonb_build_object(
      'purpose',
      'prove membership ending preserves profile and historical references'
    ),
    'p2b-end-history-fixture'
  );

-- -----------------------------------------------------------------------------
-- 21. An ACTIVE membership contributes authority.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-21 active membership contributes authority',
  haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- 22. An INVITED membership contributes no authority.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-22 invited membership contributes no authority',
  not haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_invited_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- Suspend the dedicated ACTIVE membership.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'lifecycle_suspend_result',
  haulvia_command.suspend_organization_membership(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('lifecycle_suspend_membership'),
    pg_temp.p2b_id('customer_reauth'),
    'P2B acceptance suspension test',
    'p2b-23-suspend-lifecycle-membership',
    repeat('c', 64),
    '25000000-0000-0000-0000-000000000050'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 23. A SUSPENDED membership contributes no authority.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-23 suspended membership contributes no authority',
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('lifecycle_suspend_membership')
      and om.status = 'SUSPENDED'
  )
  and
  not haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- 27. Suspending a membership preserves profile and operational history.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-27 suspension preserves profile and operational history',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('lifecycle_suspend_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_m')
  )
  and
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'p2bSuspendHistoryFixture'
      and ae.actor_profile_id = pg_temp.p2b_id('lifecycle_suspend_profile')
      and ae.entity_id = pg_temp.p2b_id('lifecycle_suspend_profile')
  )
  and
  exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id =
      pg_temp.p2b_id('lifecycle_suspend_membership')
      and r.role_key = 'BUSINESS_VIEWER'
  )
);

-- -----------------------------------------------------------------------------
-- End the second dedicated ACTIVE membership.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'lifecycle_end_result',
  haulvia_command.end_organization_membership(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    pg_temp.p2b_id('lifecycle_end_membership'),
    pg_temp.p2b_id('customer_reauth'),
    'P2B acceptance membership-ending test',
    'p2b-24-end-lifecycle-membership',
    repeat('d', 64),
    '25000000-0000-0000-0000-000000000051'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 24. An ENDED membership contributes no authority.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-24 ended membership contributes no authority',
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('lifecycle_end_membership')
      and om.status = 'ENDED'
      and om.ends_at is not null
  )
  and
  not haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_end_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- 28. Ending a membership preserves profile and operational history.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-28 ending membership preserves profile and operational history',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('lifecycle_end_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_n')
  )
  and
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'p2bEndHistoryFixture'
      and ae.actor_profile_id = pg_temp.p2b_id('lifecycle_end_profile')
      and ae.entity_id = pg_temp.p2b_id('lifecycle_end_profile')
  )
  and
  exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id =
      pg_temp.p2b_id('lifecycle_end_membership')
      and r.role_key = 'BUSINESS_VIEWER'
  )
);

-- -----------------------------------------------------------------------------
-- 29. Authority in Organization A does not create authority in Organization B.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-29 active user in organization A cannot act in organization B without separate membership',
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('customer_admin')
      and om.status = 'ACTIVE'
  )
  and
  not exists (
    select 1
    from haulvia.organization_memberships om
    where om.organization_id = pg_temp.p2b_id('courier_org')
      and om.profile_id = pg_temp.p2b_id('customer_admin')
      and om.status = 'ACTIVE'
  )
  and
  not haulvia.has_permission(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('courier_org'),
    'PROVIDER_MEMBER_MANAGE'
  )
);

-- -----------------------------------------------------------------------------
-- Give the customer administrator a fresh reauthentication record scoped to
-- the courier organization. This deliberately removes reauthentication as the
-- reason the following cross-organization command fails.
-- -----------------------------------------------------------------------------

insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at,
  provider_reference
)
values (
  pg_temp.p2b_id('cross_org_reauth'),
  pg_temp.p2b_id('customer_admin'),
  pg_temp.p2b_id('courier_org'),
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes',
  'p2b-cross-organization-reauth'
);

-- -----------------------------------------------------------------------------
-- 30. Supplying an organization ID does not manufacture authority.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-30 client-supplied organization ID does not create authority',
  format(
    $sql$
      select haulvia_command.create_organization_invitation(
        %L::uuid,
        %L::uuid,
        array['COURIER_DRIVER'],
        repeat('a', 64),
        repeat('b', 64),
        clock_timestamp() + interval '1 hour',
        %L::uuid,
        'P2B client supplied organization authority test',
        'p2b-30-client-org-id',
        repeat('e', 64),
        null,
        null,
        '25000000-0000-0000-0000-000000000052'::uuid
      )
    $sql$,
    pg_temp.p2b_id('customer_admin')::text,
    pg_temp.p2b_id('courier_org')::text,
    pg_temp.p2b_id('cross_org_reauth')::text
  ),
  '42501'
);

-- -----------------------------------------------------------------------------
-- 31. Supplying another organization's membership ID does not create authority.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-31 client-supplied membership ID does not create authority',
  format(
    $sql$
      select haulvia_command.suspend_organization_membership(
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        'P2B foreign membership identifier authority test',
        'p2b-31-client-membership-id',
        repeat('f', 64),
        '25000000-0000-0000-0000-000000000053'::uuid
      )
    $sql$,
    pg_temp.p2b_id('customer_admin')::text,
    pg_temp.p2b_id('customer_org')::text,
    pg_temp.p2b_id('courier_membership')::text,
    pg_temp.p2b_id('customer_reauth')::text
  )
);

-- -----------------------------------------------------------------------------
-- 32. A client/JWT role assertion cannot override database membership state.
--
-- The role mapping intentionally remains after suspension. The database still
-- denies the permission because membership status is authoritative.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-32 client or JWT role claim cannot override database membership state',
  exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id =
      pg_temp.p2b_id('lifecycle_suspend_membership')
      and r.role_key = 'BUSINESS_VIEWER'
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('lifecycle_suspend_membership')
      and om.status = 'SUSPENDED'
  )
  and
  not haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- 33. A stale authentication token cannot restore authority after suspension.
--
-- The Auth UUID still resolves to the same valid Haulvia profile, proving that
-- authentication itself remains valid. Organization authority nevertheless
-- remains denied because the database membership is SUSPENDED.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-33 stale token cannot restore authority after membership suspension',
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_m')
  ) = pg_temp.p2b_id('lifecycle_suspend_profile')
  and
  not haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- P2B acceptance checks 21-33 complete.
-- Checks 25-26 were exercised in the invitation section above.
-- Profile-claim and recovery checks 34-44 follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 34-44: profile claim and Auth identity recovery
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('claim_acceptance_profile',      '21000000-0000-0000-0000-000000000031'),
  ('claim_second_target_profile',   '21000000-0000-0000-0000-000000000032'),
  ('recovery_guard_profile',        '21000000-0000-0000-0000-000000000033'),
  ('recovery_conflict_profile',     '21000000-0000-0000-0000-000000000034'),
  ('replacement_owner_profile',     '21000000-0000-0000-0000-000000000035'),

  ('auth_user_o',                   '22000000-0000-0000-0000-000000000015'),
  ('auth_user_p',                   '22000000-0000-0000-0000-000000000016'),
  ('auth_user_q',                   '22000000-0000-0000-0000-000000000017'),
  ('auth_user_r',                   '22000000-0000-0000-0000-000000000018'),
  ('auth_user_s',                   '22000000-0000-0000-0000-000000000019'),
  ('auth_user_t',                   '22000000-0000-0000-0000-000000000020'),

  ('recovery_guard_membership',     '23000000-0000-0000-0000-000000000031'),

  ('unauthorized_recovery_reauth',  '24000000-0000-0000-0000-000000000031'),
  ('expired_recovery_reauth',       '24000000-0000-0000-0000-000000000032');

-- -----------------------------------------------------------------------------
-- Profiles used by claim and recovery acceptance cases.
-- -----------------------------------------------------------------------------

insert into haulvia.profiles (
  id,
  auth_user_id,
  display_name,
  preferred_locale,
  status,
  auth_access_status
)
values
  (
    pg_temp.p2b_id('claim_acceptance_profile'),
    null,
    'P2B Claim Acceptance Target',
    'en-CA',
    'ACTIVE',
    'UNCLAIMED'
  ),
  (
    pg_temp.p2b_id('claim_second_target_profile'),
    null,
    'P2B Second Claim Target',
    'en-CA',
    'ACTIVE',
    'UNCLAIMED'
  ),
  (
    pg_temp.p2b_id('recovery_guard_profile'),
    pg_temp.p2b_id('auth_user_q'),
    'P2B Recovery Guard Target',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  ),
  (
    pg_temp.p2b_id('recovery_conflict_profile'),
    pg_temp.p2b_id('auth_user_s'),
    'P2B Recovery Conflict Target',
    'en-CA',
    'ACTIVE',
    'ACTIVE'
  );

-- -----------------------------------------------------------------------------
-- Issue two valid proofs for the first unclaimed profile before claiming it.
--
-- This lets later checks prove that a claimed profile cannot be overwritten
-- even when another otherwise-valid proof existed before the first claim.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'acceptance_claim_proof_primary',
  haulvia_command.issue_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('claim_acceptance_profile'),
    'ADMIN_RECOVERY',
    repeat('c', 64),
    null,
    null,
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B primary profile claim proof',
    'p2b-34-primary-claim-proof',
    repeat('1', 64),
    null,
    '25000000-0000-0000-0000-000000000060'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'acceptance_claim_proof_secondary',
  haulvia_command.issue_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('claim_acceptance_profile'),
    'ADMIN_RECOVERY',
    repeat('d', 64),
    null,
    null,
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B secondary profile claim proof',
    'p2b-37-secondary-claim-proof',
    repeat('2', 64),
    null,
    '25000000-0000-0000-0000-000000000061'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 34. A valid claim proof can link an Auth UUID to an unclaimed profile.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'acceptance_profile_claim',
  haulvia_command.claim_existing_profile(
    pg_temp.p2b_id('auth_user_o'),
    repeat('c', 64),
    null,
    'p2b-34-valid-profile-claim',
    repeat('3', 64),
    '25000000-0000-0000-0000-000000000062'::uuid
  )
);

select pg_temp.assert_true(
  'P2B-34 valid claim proof links Auth UUID to unclaimed profile',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('claim_acceptance_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_o')
      and p.auth_access_status = 'ACTIVE'
  )
);

-- -----------------------------------------------------------------------------
-- 35. Claiming consumes the claim proof.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-35 claiming consumes the claim proof',
  exists (
    select 1
    from haulvia.profile_claim_proofs pcp
    where pcp.id = (
      select (result ->> 'claimProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'acceptance_claim_proof_primary'
    )
      and pcp.consumed_at is not null
      and pcp.consumed_by_auth_user_id = pg_temp.p2b_id('auth_user_o')
  )
);

-- -----------------------------------------------------------------------------
-- 36. A consumed claim proof cannot be reused.
--
-- Use a different unmapped Auth UUID so failure is specifically attributable
-- to the already-consumed proof, not an existing Auth mapping.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-36 consumed claim proof cannot be reused',
  format(
    $sql$
      select haulvia_command.claim_existing_profile(
        %L::uuid,
        repeat('c', 64),
        null,
        'p2b-36-consumed-proof-reuse',
        repeat('4', 64),
        '25000000-0000-0000-0000-000000000063'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_p')::text
  ),
  null,
  'consumed'
);

-- -----------------------------------------------------------------------------
-- 37. A claimed profile cannot be overwritten through ordinary claim.
--
-- The secondary proof was valid and issued while the profile was still
-- UNCLAIMED. The first successful claim must nevertheless make overwrite fail.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-37 claimed profile cannot be overwritten by ordinary claim',
  format(
    $sql$
      select haulvia_command.claim_existing_profile(
        %L::uuid,
        repeat('d', 64),
        null,
        'p2b-37-overwrite-claimed-profile',
        repeat('5', 64),
        '25000000-0000-0000-0000-000000000064'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_p')::text
  )
);

select pg_temp.assert_true(
  'SUPPLEMENTAL P2B-37 failed overwrite leaves original Auth mapping intact',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('claim_acceptance_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_o')
  )
);

-- -----------------------------------------------------------------------------
-- Prepare a second unclaimed profile with its own valid claim proof.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'second_target_claim_proof',
  haulvia_command.issue_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('claim_second_target_profile'),
    'ADMIN_RECOVERY',
    repeat('e', 64),
    null,
    null,
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B second target claim proof',
    'p2b-38-second-target-proof',
    repeat('6', 64),
    null,
    '25000000-0000-0000-0000-000000000065'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 38. An Auth UUID already mapped elsewhere cannot claim another profile.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-38 Auth UUID mapped elsewhere cannot claim another profile',
  format(
    $sql$
      select haulvia_command.claim_existing_profile(
        %L::uuid,
        repeat('e', 64),
        null,
        'p2b-38-auth-already-mapped',
        repeat('7', 64),
        '25000000-0000-0000-0000-000000000066'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_o')::text
  )
);

select pg_temp.assert_true(
  'SUPPLEMENTAL P2B-38 failed claim leaves second profile unclaimed',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('claim_second_target_profile')
      and p.auth_user_id is null
      and p.auth_access_status = 'UNCLAIMED'
  )
);

-- -----------------------------------------------------------------------------
-- Recovery continuity fixture.
-- -----------------------------------------------------------------------------

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status,
  starts_at
)
values (
  pg_temp.p2b_id('recovery_guard_membership'),
  pg_temp.p2b_id('customer_org'),
  pg_temp.p2b_id('recovery_guard_profile'),
  'ACTIVE',
  clock_timestamp() - interval '5 days'
);

insert into haulvia.audit_events (
  actor_kind,
  actor_profile_id,
  organization_id,
  command_name,
  entity_table,
  entity_id,
  metadata,
  idempotency_key
)
values (
  'PROFILE',
  pg_temp.p2b_id('recovery_guard_profile'),
  pg_temp.p2b_id('customer_org'),
  'p2bRecoveryOperationalHistoryFixture',
  'profiles',
  pg_temp.p2b_id('recovery_guard_profile'),
  jsonb_build_object(
    'purpose',
    'prove Auth identity replacement preserves operational references'
  ),
  'p2b-recovery-operational-history-fixture'
);

-- A valid recovery proof is issued by the authorized Haulvia administrator.
-- Failed authorization/reauth/reason attempts below must not consume it.

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'guard_recovery_proof',
  haulvia_command.issue_profile_auth_recovery_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('recovery_guard_profile'),
    pg_temp.p2b_id('auth_user_r'),
    repeat('f', 64),
    clock_timestamp() + interval '2 hours',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B approved recovery proof for guard tests',
    'p2b-39-44-recovery-proof',
    repeat('8', 64),
    '25000000-0000-0000-0000-000000000067'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- Valid reauthentication belonging to an actor who has no Haulvia
-- SECURITY_ACCESS_REVIEW permission.
-- -----------------------------------------------------------------------------

insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at,
  provider_reference
)
values (
  pg_temp.p2b_id('unauthorized_recovery_reauth'),
  pg_temp.p2b_id('customer_admin'),
  pg_temp.p2b_id('haulvia_org'),
  'MFA',
  clock_timestamp() - interval '1 minute',
  clock_timestamp() + interval '30 minutes',
  'p2b-unauthorized-recovery-reauth'
);

-- -----------------------------------------------------------------------------
-- 39. Auth identity replacement requires SECURITY_ACCESS_REVIEW.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-39 Auth identity replacement requires SECURITY_ACCESS_REVIEW',
  format(
    $sql$
      select haulvia_command.replace_profile_auth_identity(
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        'P2B unauthorized recovery authority test',
        'p2b-39-missing-security-access-review',
        repeat('9', 64),
        '25000000-0000-0000-0000-000000000068'::uuid
      )
    $sql$,
    pg_temp.p2b_id('customer_admin')::text,
    pg_temp.p2b_id('haulvia_org')::text,
    pg_temp.p2b_id('recovery_guard_profile')::text,
    pg_temp.p2b_id('auth_user_r')::text,
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'guard_recovery_proof'
    )::text,
    pg_temp.p2b_id('unauthorized_recovery_reauth')::text
  ),
  '42501'
);

-- -----------------------------------------------------------------------------
-- Expired reauthentication for the correctly authorized Haulvia administrator.
-- -----------------------------------------------------------------------------

insert into haulvia.reauth_sessions (
  id,
  profile_id,
  organization_id,
  method,
  verified_at,
  expires_at,
  provider_reference
)
values (
  pg_temp.p2b_id('expired_recovery_reauth'),
  pg_temp.p2b_id('haulvia_admin'),
  pg_temp.p2b_id('haulvia_org'),
  'MFA',
  clock_timestamp() - interval '2 hours',
  clock_timestamp() - interval '1 hour',
  'p2b-expired-recovery-reauth'
);

-- -----------------------------------------------------------------------------
-- 40. Auth identity replacement requires fresh reauthentication.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-40 Auth identity replacement requires fresh reauthentication',
  format(
    $sql$
      select haulvia_command.replace_profile_auth_identity(
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        'P2B expired reauthentication recovery test',
        'p2b-40-expired-reauth',
        repeat('a', 64),
        '25000000-0000-0000-0000-000000000069'::uuid
      )
    $sql$,
    pg_temp.p2b_id('haulvia_admin')::text,
    pg_temp.p2b_id('haulvia_org')::text,
    pg_temp.p2b_id('recovery_guard_profile')::text,
    pg_temp.p2b_id('auth_user_r')::text,
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'guard_recovery_proof'
    )::text,
    pg_temp.p2b_id('expired_recovery_reauth')::text
  )
);

-- -----------------------------------------------------------------------------
-- 41. Auth identity replacement requires a written reason.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-41 Auth identity replacement requires written reason',
  format(
    $sql$
      select haulvia_command.replace_profile_auth_identity(
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        'short',
        'p2b-41-short-reason',
        repeat('b', 64),
        '25000000-0000-0000-0000-000000000070'::uuid
      )
    $sql$,
    pg_temp.p2b_id('haulvia_admin')::text,
    pg_temp.p2b_id('haulvia_org')::text,
    pg_temp.p2b_id('recovery_guard_profile')::text,
    pg_temp.p2b_id('auth_user_r')::text,
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'guard_recovery_proof'
    )::text,
    pg_temp.p2b_id('haulvia_reauth')::text
  )
);

-- -----------------------------------------------------------------------------
-- Prepare requirement 42:
-- issue a valid recovery proof while auth_user_t is unassigned, then assign
-- auth_user_t to another profile before attempting replacement.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'conflicting_replacement_proof',
  haulvia_command.issue_profile_auth_recovery_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('recovery_conflict_profile'),
    pg_temp.p2b_id('auth_user_t'),
    repeat('0', 64),
    clock_timestamp() + interval '2 hours',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B recovery proof before replacement UUID conflict',
    'p2b-42-conflict-proof',
    repeat('c', 64),
    '25000000-0000-0000-0000-000000000071'::uuid
  )
);

insert into haulvia.profiles (
  id,
  auth_user_id,
  display_name,
  preferred_locale,
  status,
  auth_access_status
)
values (
  pg_temp.p2b_id('replacement_owner_profile'),
  pg_temp.p2b_id('auth_user_t'),
  'P2B Existing Replacement UUID Owner',
  'en-CA',
  'ACTIVE',
  'ACTIVE'
);

-- -----------------------------------------------------------------------------
-- 42. Replacement fails when the replacement Auth UUID belongs to another
--     profile.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-42 replacement Auth UUID belonging to another profile fails',
  format(
    $sql$
      select haulvia_command.replace_profile_auth_identity(
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        %L::uuid,
        'P2B replacement Auth UUID collision test',
        'p2b-42-replacement-auth-conflict',
        repeat('d', 64),
        '25000000-0000-0000-0000-000000000072'::uuid
      )
    $sql$,
    pg_temp.p2b_id('haulvia_admin')::text,
    pg_temp.p2b_id('haulvia_org')::text,
    pg_temp.p2b_id('recovery_conflict_profile')::text,
    pg_temp.p2b_id('auth_user_t')::text,
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'conflicting_replacement_proof'
    )::text,
    pg_temp.p2b_id('haulvia_reauth')::text
  ),
  '23505'
);

-- -----------------------------------------------------------------------------
-- Perform one authorized recovery after all guard tests.
-- The same recovery proof from requirements 39-41 must still be usable because
-- those rejected attempts were atomic and did not consume it.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'guard_recovery_success',
  haulvia_command.replace_profile_auth_identity(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('recovery_guard_profile'),
    pg_temp.p2b_id('auth_user_r'),
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'guard_recovery_proof'
    ),
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B approved identity replacement after guard tests',
    'p2b-43-authorized-recovery',
    repeat('e', 64),
    '25000000-0000-0000-0000-000000000073'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 43. Identity replacement retains immutable before/after audit evidence.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-43 identity replacement retains immutable before and after audit evidence',
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'replaceProfileAuthIdentity'
      and ae.entity_table = 'profiles'
      and ae.entity_id = pg_temp.p2b_id('recovery_guard_profile')
      and (ae.before_value ->> 'authUserId')::uuid =
        pg_temp.p2b_id('auth_user_q')
      and (ae.after_value ->> 'authUserId')::uuid =
        pg_temp.p2b_id('auth_user_r')
      and ae.authority_code = 'SECURITY_ACCESS_REVIEW'
      and ae.reauth_session_id = pg_temp.p2b_id('haulvia_reauth')
      and length(coalesce(ae.reason, '')) >= 8
  )
);

-- -----------------------------------------------------------------------------
-- 44. Identity replacement does not move/delete memberships or operational
--     records.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-44 identity replacement preserves memberships and operational records',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('recovery_guard_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_r')
      and p.auth_access_status = 'ACTIVE'
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('recovery_guard_membership')
      and om.profile_id = pg_temp.p2b_id('recovery_guard_profile')
      and om.organization_id = pg_temp.p2b_id('customer_org')
      and om.status = 'ACTIVE'
  )
  and
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'p2bRecoveryOperationalHistoryFixture'
      and ae.actor_profile_id = pg_temp.p2b_id('recovery_guard_profile')
      and ae.entity_id = pg_temp.p2b_id('recovery_guard_profile')
  )
);

-- -----------------------------------------------------------------------------
-- P2B acceptance checks 34-44 complete.
-- Disabled/deleted Auth handling checks 45-49 follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 45-50: disabled/deleted Auth handling
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('auth_lifecycle_profile',    '21000000-0000-0000-0000-000000000041'),
  ('auth_user_u',               '22000000-0000-0000-0000-000000000021'),
  ('auth_lifecycle_membership', '23000000-0000-0000-0000-000000000041');

-- -----------------------------------------------------------------------------
-- Dedicated claimed profile with real organization authority and history.
-- -----------------------------------------------------------------------------

insert into haulvia.profiles (
  id,
  auth_user_id,
  display_name,
  preferred_locale,
  status,
  auth_access_status
)
values (
  pg_temp.p2b_id('auth_lifecycle_profile'),
  pg_temp.p2b_id('auth_user_u'),
  'P2B Auth Lifecycle User',
  'en-CA',
  'ACTIVE',
  'ACTIVE'
);

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status,
  starts_at
)
values (
  pg_temp.p2b_id('auth_lifecycle_membership'),
  pg_temp.p2b_id('customer_org'),
  pg_temp.p2b_id('auth_lifecycle_profile'),
  'ACTIVE',
  clock_timestamp() - interval '10 days'
);

insert into haulvia.membership_roles (
  membership_id,
  role_id,
  granted_by_profile_id
)
select
  pg_temp.p2b_id('auth_lifecycle_membership'),
  r.id,
  pg_temp.p2b_id('customer_admin')
from haulvia.roles r
where r.role_key = 'BUSINESS_VIEWER';

insert into haulvia.audit_events (
  actor_kind,
  actor_profile_id,
  organization_id,
  command_name,
  entity_table,
  entity_id,
  metadata,
  idempotency_key
)
values (
  'PROFILE',
  pg_temp.p2b_id('auth_lifecycle_profile'),
  pg_temp.p2b_id('customer_org'),
  'p2bAuthLifecycleHistoryFixture',
  'profiles',
  pg_temp.p2b_id('auth_lifecycle_profile'),
  jsonb_build_object(
    'purpose',
    'prove Auth disable/delete never erases operational history'
  ),
  'p2b-auth-lifecycle-history-fixture'
);

select pg_temp.assert_true(
  'SUPPLEMENTAL auth lifecycle fixture begins authenticated and authorized',
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_u')
  ) = pg_temp.p2b_id('auth_lifecycle_profile')
  and
  haulvia.has_permission(
    pg_temp.p2b_id('auth_lifecycle_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- Trusted provider synchronization disables external Auth access.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'auth_lifecycle_disabled',
  haulvia_command.sync_profile_auth_access(
    pg_temp.p2b_id('auth_user_u'),
    'DISABLED',
    'p2b-45-disable-auth',
    repeat('1', 64),
    '25000000-0000-0000-0000-000000000080'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 45. A disabled Auth principal cannot exercise new authority.
--
-- The organization membership and role still exist, but the authoritative
-- Auth UUID -> profile resolver no longer resolves the disabled principal.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-45 disabled Auth principal cannot exercise new authority',
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_u')
  ) is null
  and
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('auth_lifecycle_profile')
      and p.auth_access_status = 'DISABLED'
  )
);

-- -----------------------------------------------------------------------------
-- 46. Disabling Auth access does not delete the Haulvia profile.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-46 disabling Auth access does not delete Haulvia profile',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('auth_lifecycle_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_u')
      and p.status = 'ACTIVE'
      and p.auth_access_status = 'DISABLED'
  )
);

-- -----------------------------------------------------------------------------
-- 47. Disabling Auth access does not delete memberships.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-47 disabling Auth access does not delete memberships',
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('auth_lifecycle_membership')
      and om.organization_id = pg_temp.p2b_id('customer_org')
      and om.profile_id = pg_temp.p2b_id('auth_lifecycle_profile')
      and om.status = 'ACTIVE'
  )
  and
  exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id =
      pg_temp.p2b_id('auth_lifecycle_membership')
      and r.role_key = 'BUSINESS_VIEWER'
  )
);

-- -----------------------------------------------------------------------------
-- 48. Disabling Auth access does not delete operational history.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-48 disabling Auth access does not delete operational history',
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'p2bAuthLifecycleHistoryFixture'
      and ae.actor_profile_id =
        pg_temp.p2b_id('auth_lifecycle_profile')
      and ae.entity_id =
        pg_temp.p2b_id('auth_lifecycle_profile')
  )
);

-- -----------------------------------------------------------------------------
-- Model deletion of the external Auth principal.
--
-- The provider-originated lifecycle synchronization changes only Auth access
-- state. The external UUID remains as historical identity correlation rather
-- than cascading through Haulvia operational records.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'auth_lifecycle_deleted',
  haulvia_command.sync_profile_auth_access(
    pg_temp.p2b_id('auth_user_u'),
    'DELETED',
    'p2b-49-delete-auth',
    repeat('2', 64),
    '25000000-0000-0000-0000-000000000081'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 49. Deleting the external Auth principal does not cascade-delete Haulvia
--     operational history.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-49 deleted external Auth principal does not cascade-delete operational history',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('auth_lifecycle_profile')
      and p.auth_user_id = pg_temp.p2b_id('auth_user_u')
      and p.auth_access_status = 'DELETED'
  )
  and
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('auth_lifecycle_membership')
      and om.profile_id = pg_temp.p2b_id('auth_lifecycle_profile')
  )
  and
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'p2bAuthLifecycleHistoryFixture'
      and ae.actor_profile_id =
        pg_temp.p2b_id('auth_lifecycle_profile')
  )
  and
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_u')
  ) is null
);

-- -----------------------------------------------------------------------------
-- Ordinary bootstrap must not reactivate a disabled/deleted identity.
--
-- The contract explicitly requires bootstrap not to restore disabled/archived
-- access. Whether bootstrap rejects or safely returns an ineligible result,
-- the persisted state must remain DELETED.
-- -----------------------------------------------------------------------------

do $$
begin
  begin
    perform haulvia_command.bootstrap_profile_from_auth(
      pg_temp.p2b_id('auth_user_u'),
      'P2B Auth Lifecycle User',
      'en-CA',
      'p2b-50-bootstrap-cannot-reactivate',
      repeat('3', 64),
      '25000000-0000-0000-0000-000000000082'::uuid
    );
  exception
    when others then
      null;
  end;
end;
$$;

select pg_temp.assert_true(
  'SUPPLEMENTAL ordinary bootstrap cannot reactivate deleted Auth access',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('auth_lifecycle_profile')
      and p.auth_access_status = 'DELETED'
  )
  and
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_u')
  ) is null
);

-- -----------------------------------------------------------------------------
-- Reactivation through the explicitly trusted provider lifecycle command.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'auth_lifecycle_reactivated',
  haulvia_command.sync_profile_auth_access(
    pg_temp.p2b_id('auth_user_u'),
    'ACTIVE',
    'p2b-50-trusted-reactivation',
    repeat('4', 64),
    '25000000-0000-0000-0000-000000000083'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- 50. Reactivation/replacement requires an approved trusted path.
--
-- Ordinary bootstrap could not restore access; the service-only lifecycle
-- command can restore ACTIVE after provider-side approval/synchronization.
-- Privileged replacement was separately proven in requirements 39-44.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-50 reactivation or replacement requires approved trusted path',
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('auth_lifecycle_profile')
      and p.auth_access_status = 'ACTIVE'
  )
  and
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_u')
  ) = pg_temp.p2b_id('auth_lifecycle_profile')
  and
  exists (
    select 1
    from haulvia.audit_events ae
    where ae.command_name = 'syncProfileAuthAccess'
      and ae.entity_id = pg_temp.p2b_id('auth_lifecycle_profile')
      and ae.after_value ->> 'authAccessStatus' = 'ACTIVE'
  )
);

-- -----------------------------------------------------------------------------
-- P2B acceptance checks 45-50 complete.
-- Audit and idempotency checks 51-55 follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 51-55: audit, idempotency and atomic rollback
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_fixture_ids (
  fixture_key,
  id
)
values
  ('auth_user_v',                  '22000000-0000-0000-0000-000000000022'),
  ('auth_user_w',                  '22000000-0000-0000-0000-000000000023'),
  ('atomic_failure_profile',       '21000000-0000-0000-0000-000000000051'),
  ('atomic_failure_membership',    '23000000-0000-0000-0000-000000000051');

-- -----------------------------------------------------------------------------
-- Exercise the two proof-revocation commands so requirement 51 can verify the
-- complete material P2B audit surface rather than only commands used earlier.
-- -----------------------------------------------------------------------------

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'audit_claim_proof_to_revoke',
  haulvia_command.issue_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('claim_second_target_profile'),
    'ADMIN_RECOVERY',
    repeat('f', 64),
    null,
    null,
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B audit claim proof revocation fixture',
    'p2b-51-issue-claim-proof-for-revoke',
    repeat('5', 64),
    null,
    '25000000-0000-0000-0000-000000000090'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'audit_claim_proof_revoked',
  haulvia_command.revoke_profile_claim_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    (
      select (result ->> 'claimProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'audit_claim_proof_to_revoke'
    ),
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B authorized claim proof revocation',
    'p2b-51-revoke-claim-proof',
    repeat('6', 64),
    '25000000-0000-0000-0000-000000000091'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'audit_recovery_proof_to_revoke',
  haulvia_command.issue_profile_auth_recovery_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    pg_temp.p2b_id('auth_lifecycle_profile'),
    pg_temp.p2b_id('auth_user_v'),
    repeat('1', 64),
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B audit recovery proof revocation fixture',
    'p2b-51-issue-recovery-proof-for-revoke',
    repeat('7', 64),
    '25000000-0000-0000-0000-000000000092'::uuid
  )
);

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'audit_recovery_proof_revoked',
  haulvia_command.revoke_profile_auth_recovery_proof(
    pg_temp.p2b_id('haulvia_admin'),
    pg_temp.p2b_id('haulvia_org'),
    (
      select (result ->> 'recoveryProofId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'audit_recovery_proof_to_revoke'
    ),
    pg_temp.p2b_id('haulvia_reauth'),
    'P2B authorized recovery proof revocation',
    'p2b-51-revoke-recovery-proof',
    repeat('8', 64),
    '25000000-0000-0000-0000-000000000093'::uuid
  )
);

-- -----------------------------------------------------------------------------
-- Expected material P2B command audit surface.
-- -----------------------------------------------------------------------------

create temporary table p2b_expected_material_audit_commands (
  command_name text primary key
) on commit drop;

insert into pg_temp.p2b_expected_material_audit_commands (
  command_name
)
values
  ('bootstrapProfileFromAuth'),
  ('claimExistingProfile'),
  ('createOrganizationInvitation'),
  ('acceptOrganizationInvitation'),
  ('revokeOrganizationInvitation'),
  ('suspendOrganizationMembership'),
  ('endOrganizationMembership'),
  ('issueProfileClaimProof'),
  ('revokeProfileClaimProof'),
  ('issueProfileAuthRecoveryProof'),
  ('revokeProfileAuthRecoveryProof'),
  ('replaceProfileAuthIdentity'),
  ('syncProfileAuthAccess');

-- -----------------------------------------------------------------------------
-- 51. Every material P2B mutation creates immutable audit evidence.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-51 every material P2B mutation creates immutable audit evidence',
  not exists (
    select 1
    from pg_temp.p2b_expected_material_audit_commands expected
    where not exists (
      select 1
      from haulvia.audit_events ae
      where ae.command_name = expected.command_name
    )
  )
);

-- Prove that retained P2B audit evidence is append-only, not merely present.

select pg_temp.expect_error(
  'SUPPLEMENTAL P2B-51 P2B audit evidence cannot be updated',
  $sql$
    update haulvia.audit_events
    set metadata =
      metadata || jsonb_build_object('tampered', true)
    where id = (
      select ae.id
      from haulvia.audit_events ae
      where ae.command_name = 'replaceProfileAuthIdentity'
      order by ae.occurred_at desc
      limit 1
    )
  $sql$
);

select pg_temp.expect_error(
  'SUPPLEMENTAL P2B-51 P2B audit evidence cannot be deleted',
  $sql$
    delete from haulvia.audit_events
    where id = (
      select ae.id
      from haulvia.audit_events ae
      where ae.command_name = 'replaceProfileAuthIdentity'
      order by ae.occurred_at desc
      limit 1
    )
  $sql$
);

-- -----------------------------------------------------------------------------
-- 52. Invitation/claim secrets never appear in audit metadata.
--
-- Test every persisted invitation and profile-claim digest, not merely one
-- known fixture. Recovery verification-reference hashes are also included as
-- an additional protection even though the contract names invitation/claim
-- secrets specifically.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-52 invitation and claim secrets never appear in audit metadata',
  not exists (
    select 1
    from haulvia.audit_events ae
    cross join lateral (
      select oi.secret_hash as sensitive_value
      from haulvia.organization_invitations oi

      union all

      select pcp.secret_hash
      from haulvia.profile_claim_proofs pcp

      union all

      select prp.verification_reference_hash
      from haulvia.profile_auth_recovery_proofs prp
    ) sensitive
    where sensitive.sensitive_value is not null
      and coalesce(ae.metadata::text, '') like
        '%' || sensitive.sensitive_value || '%'
  )
);

select pg_temp.assert_true(
  'SUPPLEMENTAL P2B-52 invitation and claim secrets are absent from complete audit values',
  not exists (
    select 1
    from haulvia.audit_events ae
    cross join lateral (
      select oi.secret_hash as sensitive_value
      from haulvia.organization_invitations oi

      union all

      select pcp.secret_hash
      from haulvia.profile_claim_proofs pcp

      union all

      select prp.verification_reference_hash
      from haulvia.profile_auth_recovery_proofs prp
    ) sensitive
    where sensitive.sensitive_value is not null
      and (
        coalesce(ae.before_value::text, '') ||
        coalesce(ae.after_value::text, '') ||
        coalesce(ae.metadata::text, '')
      ) like
        '%' || sensitive.sensitive_value || '%'
  )
);

-- -----------------------------------------------------------------------------
-- 53. Replaying an idempotent command with the same request returns the
--     original result.
--
-- P2B-01/P2B-02 already executed this exact bootstrap twice. Compare the
-- durable business result while allowing only the replay marker to differ.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-53 same idempotency key and same request returns original result',
  (
    select
      (initial.result - 'replayed')
        =
      (replay.result - 'replayed')
    from pg_temp.p2b_command_results initial
    cross join pg_temp.p2b_command_results replay
    where initial.result_key = 'bootstrap_auth_e_initial'
      and replay.result_key = 'bootstrap_auth_e_replay'
  )
  and
  (
    select (result ->> 'replayed')::boolean
    from pg_temp.p2b_command_results
    where result_key = 'bootstrap_auth_e_replay'
  )
);

-- -----------------------------------------------------------------------------
-- 54. Reusing an idempotency key with a different canonical request fails
--     closed.
--
-- Same Auth principal, command and idempotency key as P2B-01, but a different
-- request hash.
-- -----------------------------------------------------------------------------

select pg_temp.expect_error(
  'P2B-54 same idempotency key with different canonical request fails closed',
  format(
    $sql$
      select haulvia_command.bootstrap_profile_from_auth(
        %L::uuid,
        'P2B Bootstrap User E',
        'en-CA',
        'p2b-01-bootstrap-auth-e',
        repeat('9', 64),
        '25000000-0000-0000-0000-000000000094'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_e')::text
  ),
  null,
  'different request'
);

select pg_temp.assert_true(
  'SUPPLEMENTAL P2B-54 idempotency conflict creates no duplicate profile',
  (
    select count(*) = 1
    from haulvia.profiles p
    where p.auth_user_id = pg_temp.p2b_id('auth_user_e')
  )
);

-- -----------------------------------------------------------------------------
-- Requirement 55 fixture:
--
-- Existing profile is UNCLAIMED, but its membership is already SUSPENDED.
-- Invitation acceptance is therefore prohibited. The command may resolve and
-- begin identity work before discovering the membership lifecycle conflict;
-- the entire failed command must nevertheless roll back atomically.
-- -----------------------------------------------------------------------------

insert into haulvia.profiles (
  id,
  auth_user_id,
  display_name,
  preferred_locale,
  status,
  auth_access_status
)
values (
  pg_temp.p2b_id('atomic_failure_profile'),
  null,
  'P2B Atomic Failure Target',
  'en-CA',
  'ACTIVE',
  'UNCLAIMED'
);

insert into haulvia.organization_memberships (
  id,
  organization_id,
  profile_id,
  status,
  starts_at
)
values (
  pg_temp.p2b_id('atomic_failure_membership'),
  pg_temp.p2b_id('customer_org'),
  pg_temp.p2b_id('atomic_failure_profile'),
  'SUSPENDED',
  clock_timestamp() - interval '3 days'
);

insert into haulvia.membership_roles (
  membership_id,
  role_id,
  granted_by_profile_id
)
select
  pg_temp.p2b_id('atomic_failure_membership'),
  r.id,
  pg_temp.p2b_id('customer_admin')
from haulvia.roles r
where r.role_key = 'BUSINESS_VIEWER';

insert into pg_temp.p2b_command_results (
  result_key,
  result
)
values (
  'atomic_failure_invitation',
  haulvia_command.create_organization_invitation(
    pg_temp.p2b_id('customer_admin'),
    pg_temp.p2b_id('customer_org'),
    array['BUSINESS_VIEWER'],
    repeat('6', 64),
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    clock_timestamp() + interval '1 hour',
    pg_temp.p2b_id('customer_reauth'),
    'P2B multi-row atomic rollback fixture',
    'p2b-55-create-atomic-failure-invite',
    repeat('a', 64),
    pg_temp.p2b_id('atomic_failure_profile'),
    'a***@example.test',
    '25000000-0000-0000-0000-000000000095'::uuid
  )
);

-- Capture the exact pre-failure role count.

create temporary table p2b_atomic_failure_before (
  membership_id uuid primary key,
  role_count bigint not null
) on commit drop;

insert into pg_temp.p2b_atomic_failure_before (
  membership_id,
  role_count
)
select
  pg_temp.p2b_id('atomic_failure_membership'),
  count(*)
from haulvia.membership_roles mr
where mr.membership_id =
  pg_temp.p2b_id('atomic_failure_membership');

select pg_temp.expect_error(
  'SUPPLEMENTAL P2B-55 suspended membership forces invitation acceptance failure',
  format(
    $sql$
      select haulvia_command.accept_organization_invitation(
        %L::uuid,
        %L,
        repeat('6', 64),
        'P2B Atomic Failure Target',
        'en-CA',
        'p2b-55-failed-multi-row-accept',
        repeat('b', 64),
        '25000000-0000-0000-0000-000000000096'::uuid
      )
    $sql$,
    pg_temp.p2b_id('auth_user_w')::text,
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  )
);

-- -----------------------------------------------------------------------------
-- 55. Failed multi-row commands leave no partial membership, role,
--     identity-link or invitation-consumption state.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-55 failed multi-row command leaves no partial identity membership role or consumption state',

  -- Identity link did not persist.
  exists (
    select 1
    from haulvia.profiles p
    where p.id = pg_temp.p2b_id('atomic_failure_profile')
      and p.auth_user_id is null
      and p.auth_access_status = 'UNCLAIMED'
  )

  and

  -- Membership lifecycle did not change.
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id = pg_temp.p2b_id('atomic_failure_membership')
      and om.profile_id = pg_temp.p2b_id('atomic_failure_profile')
      and om.organization_id = pg_temp.p2b_id('customer_org')
      and om.status = 'SUSPENDED'
  )

  and

  -- No role row was added or removed.
  (
    select count(*)
    from haulvia.membership_roles mr
    where mr.membership_id =
      pg_temp.p2b_id('atomic_failure_membership')
  )
  =
  (
    select role_count
    from pg_temp.p2b_atomic_failure_before
    where membership_id =
      pg_temp.p2b_id('atomic_failure_membership')
  )

  and

  -- Invitation remained unconsumed.
  exists (
    select 1
    from haulvia.organization_invitations oi
    where oi.id = (
      select (result ->> 'invitationId')::uuid
      from pg_temp.p2b_command_results
      where result_key = 'atomic_failure_invitation'
    )
      and oi.consumed_at is null
      and oi.consumed_by_profile_id is null
      and oi.revoked_at is null
  )

  and

  -- Failed Auth principal was not accidentally mapped elsewhere.
  not exists (
    select 1
    from haulvia.profiles p
    where p.auth_user_id = pg_temp.p2b_id('auth_user_w')
  )
);

-- -----------------------------------------------------------------------------
-- P2B acceptance checks 51-55 complete.
-- Security-surface checks 56-60 follow next.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B acceptance 56-60: security surface
-- -----------------------------------------------------------------------------

-- Worker authorities explicitly reserved for trusted backend execution.
create temporary table p2b_worker_authority_codes (
  authority_code text primary key
) on commit drop;

insert into pg_temp.p2b_worker_authority_codes (
  authority_code
)
values
  ('ROUTE_OPERATIONS_WORKER'),
  ('TERMINAL_REPOST_WORKER'),
  ('CUSTODY_TRANSFER_WORKER'),
  ('RECOVERY_WORKER'),
  ('STORAGE_WORKER'),
  ('COMPLETION_WORKER'),
  ('PAYOUT_WORKER');

-- P2B commands that may be initiated on behalf of a human identity.
create temporary table p2b_human_command_functions (
  function_name text primary key
) on commit drop;

insert into pg_temp.p2b_human_command_functions (
  function_name
)
values
  ('bootstrap_profile_from_auth'),
  ('claim_existing_profile'),
  ('create_organization_invitation'),
  ('accept_organization_invitation'),
  ('revoke_organization_invitation'),
  ('suspend_organization_membership'),
  ('end_organization_membership'),
  ('issue_profile_claim_proof'),
  ('revoke_profile_claim_proof'),
  ('issue_profile_auth_recovery_proof'),
  ('revoke_profile_auth_recovery_proof'),
  ('replace_profile_auth_identity');

-- -----------------------------------------------------------------------------
-- 56. No P2B human command grants worker authority.
--
-- Human identity commands must neither accept a worker-authority parameter nor
-- contain any of the approved backend worker authority codes.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-56 no P2B human command grants worker authority',

  -- Every expected P2B human command exists.
  (
    select count(distinct expected.function_name)
    from pg_temp.p2b_human_command_functions expected
    join pg_proc p
      on p.proname = expected.function_name
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
  )
  =
  (
    select count(*)
    from pg_temp.p2b_human_command_functions
  )

  and

  -- No human command exposes a worker-authority argument.
  not exists (
    select 1
    from pg_temp.p2b_human_command_functions expected
    join pg_proc p
      on p.proname = expected.function_name
    join pg_namespace n
      on n.oid = p.pronamespace
    cross join lateral unnest(
      coalesce(
        p.proargnames,
        array[]::text[]
      )
    ) arg_name
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and lower(arg_name) in (
        'worker_authority',
        'workerauthority',
        'p_worker_authority'
      )
  )

  and

  -- No human command embeds any trusted worker authority code.
  not exists (
    select 1
    from pg_temp.p2b_human_command_functions expected
    join pg_proc p
      on p.proname = expected.function_name
    join pg_namespace n
      on n.oid = p.pronamespace
    cross join pg_temp.p2b_worker_authority_codes worker
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and position(
        worker.authority_code
        in upper(pg_get_functiondef(p.oid))
      ) > 0
  )
);

-- -----------------------------------------------------------------------------
-- Complete unique P2B function catalogue.
--
-- The migration contains 27 CREATE OR REPLACE FUNCTION statements because
-- replace_profile_auth_identity is deliberately replaced once by the final
-- recovery-proof-gated signature. The final database surface contains these
-- 26 unique P2B function names.
-- -----------------------------------------------------------------------------

create temporary table p2b_created_functions (
  function_name text primary key
) on commit drop;

insert into pg_temp.p2b_created_functions (
  function_name
)
values
  ('touch_profile_auth_access_changed_at'),
  ('enforce_invitation_role_organization_kind'),

  ('begin_auth_request'),
  ('complete_auth_request'),
  ('resolve_authenticated_profile_id'),
  ('resolve_active_membership_id'),
  ('membership_management_permission'),
  ('assert_membership_management_authority'),

  ('bootstrap_profile_from_auth'),
  ('lock_valid_profile_claim_proof'),
  ('claim_existing_profile'),

  ('guard_organization_invitation_update'),
  ('guard_organization_invitation_role_mutation'),
  ('guard_profile_claim_proof_update'),
  ('create_organization_invitation'),
  ('accept_organization_invitation'),

  ('revoke_organization_invitation'),
  ('suspend_organization_membership'),
  ('end_organization_membership'),

  ('issue_profile_claim_proof'),
  ('revoke_profile_claim_proof'),
  ('replace_profile_auth_identity'),
  ('sync_profile_auth_access'),

  ('guard_profile_auth_recovery_proof_update'),
  ('issue_profile_auth_recovery_proof'),
  ('revoke_profile_auth_recovery_proof');

-- -----------------------------------------------------------------------------
-- 57. No P2B function introduces PUBLIC, anon or authenticated execution unless
--     explicitly required and reviewed.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-57 no P2B function grants PUBLIC anon or authenticated execution',

  -- All expected final P2B functions actually exist.
  (
    select count(distinct expected.function_name)
    from pg_temp.p2b_created_functions expected
    join pg_proc p
      on p.proname = expected.function_name
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
  )
  =
  (
    select count(*)
    from pg_temp.p2b_created_functions
  )

  and

  -- Grantee OID zero represents PUBLIC in PostgreSQL ACLs.
  not exists (
    select 1
    from pg_temp.p2b_created_functions expected
    join pg_proc p
      on p.proname = expected.function_name
    join pg_namespace n
      on n.oid = p.pronamespace
    cross join lateral aclexplode(
      coalesce(
        p.proacl,
        acldefault('f', p.proowner)
      )
    ) acl
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  )

  and

  -- If Supabase-facing roles exist, neither may directly execute P2B functions.
  not exists (
    select 1
    from pg_temp.p2b_created_functions expected
    join pg_proc p
      on p.proname = expected.function_name
    join pg_namespace n
      on n.oid = p.pronamespace
    cross join lateral aclexplode(
      coalesce(
        p.proacl,
        acldefault('f', p.proowner)
      )
    ) acl
    join pg_roles granted_role
      on granted_role.oid = acl.grantee
    where n.nspname in (
      'haulvia',
      'haulvia_command'
    )
      and granted_role.rolname in (
        'anon',
        'authenticated'
      )
      and acl.privilege_type = 'EXECUTE'
  )
);

-- -----------------------------------------------------------------------------
-- 58. Auth resolution uses trusted authentication context rather than arbitrary
--     request JSON.
--
-- The authoritative resolver accepts one Auth UUID and resolves it through
-- profiles.auth_user_id. Identity entrypoints do not consume a generic JSON/
-- JSONB request envelope from which a client could manufacture identity claims.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-58 Auth resolution uses trusted Auth UUID rather than arbitrary request JSON',

  exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia'
      and p.proname = 'resolve_authenticated_profile_id'
      and oidvectortypes(p.proargtypes) = 'uuid'
      and position(
        'auth_user_id'
        in lower(pg_get_functiondef(p.oid))
      ) > 0
  )

  and

  not exists (
    select 1
    from pg_proc p
    join pg_namespace n
      on n.oid = p.pronamespace
    where n.nspname = 'haulvia_command'
      and p.proname in (
        'bootstrap_profile_from_auth',
        'claim_existing_profile',
        'accept_organization_invitation',
        'replace_profile_auth_identity',
        'sync_profile_auth_access'
      )
      and pg_get_function_identity_arguments(p.oid)
        ~* '(^|[ ,])(json|jsonb)([ ,]|$)'
  )
);

-- -----------------------------------------------------------------------------
-- 59. Database membership state overrides stale JWT role/organization claims.
--
-- The suspended lifecycle fixture deliberately retains its BUSINESS_VIEWER
-- role mapping and a valid Auth->profile mapping. Database membership state
-- nevertheless removes the permission.
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B-59 database membership state overrides stale JWT role or organization claims',

  -- Authentication still identifies the same person.
  haulvia.resolve_authenticated_profile_id(
    pg_temp.p2b_id('auth_user_m')
  ) = pg_temp.p2b_id('lifecycle_suspend_profile')

  and

  -- The old role mapping still exists and could therefore appear in stale
  -- cached/JWT state.
  exists (
    select 1
    from haulvia.membership_roles mr
    join haulvia.roles r
      on r.id = mr.role_id
    where mr.membership_id =
      pg_temp.p2b_id('lifecycle_suspend_membership')
      and r.role_key = 'BUSINESS_VIEWER'
  )

  and

  -- Database membership state is authoritative.
  exists (
    select 1
    from haulvia.organization_memberships om
    where om.id =
      pg_temp.p2b_id('lifecycle_suspend_membership')
      and om.status = 'SUSPENDED'
  )

  and

  not haulvia.has_permission(
    pg_temp.p2b_id('lifecycle_suspend_profile'),
    pg_temp.p2b_id('customer_org'),
    'SHIPMENT_VIEW'
  )
);

-- -----------------------------------------------------------------------------
-- 60. P2B creates no second canonical application-user table.
--
-- profiles remains the application-level person record. P2B adds invitation,
-- role-intent and proof/evidence tables only.
-- -----------------------------------------------------------------------------

create temporary table p2b_new_tables (
  table_name text primary key
) on commit drop;

insert into pg_temp.p2b_new_tables (
  table_name
)
values
  ('organization_invitations'),
  ('organization_invitation_roles'),
  ('profile_claim_proofs'),
  ('profile_auth_recovery_proofs');

select pg_temp.assert_true(
  'P2B-60 P2B creates no second canonical application-user table',

  -- Canonical profile table remains present.
  exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'haulvia'
      and t.table_name = 'profiles'
      and t.table_type = 'BASE TABLE'
  )

  and

  -- Its external Auth bridge remains the canonical mapping.
  exists (
    select 1
    from information_schema.columns c
    where c.table_schema = 'haulvia'
      and c.table_name = 'profiles'
      and c.column_name = 'auth_user_id'
      and c.data_type = 'uuid'
  )

  and

  -- Every table introduced by P2B is an invitation/security-support table.
  (
    select count(*)
    from pg_temp.p2b_new_tables expected
    join information_schema.tables t
      on t.table_schema = 'haulvia'
     and t.table_name = expected.table_name
     and t.table_type = 'BASE TABLE'
  ) = 4

  and

  -- No competing application-user identity master exists.
  not exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'haulvia'
      and lower(t.table_name) in (
        'users',
        'app_users',
        'application_users',
        'auth_users',
        'user_profiles',
        'profile_identities',
        'application_identities'
      )
  )
);

-- -----------------------------------------------------------------------------
-- Final P2B contract-coverage evidence
-- -----------------------------------------------------------------------------

select pg_temp.assert_true(
  'P2B contract coverage contains requirements 01 through 60 exactly once',

  (
    select count(*)
    from pg_temp.p2b_test_results r
    where r.test_name ~ '^P2B-[0-9]{2} '
  ) = 60

  and

  not exists (
    select required_no
    from generate_series(1, 60) required_no
    where (
      select count(*)
      from pg_temp.p2b_test_results r
      where r.test_name like
        'P2B-' ||
        lpad(required_no::text, 2, '0') ||
        ' %'
    ) <> 1
  )
);

-- -----------------------------------------------------------------------------
-- Final P2B acceptance evidence
-- -----------------------------------------------------------------------------

select
  test_name,
  passed,
  detail
from pg_temp.p2b_test_results
order by test_name;

select
  count(*) filter (
    where test_name ~ '^P2B-[0-9]{2} '
  ) as recorded_p2b_contract_checks,

  count(*) as total_recorded_checks,

  bool_and(passed)
    as all_recorded_checks_passed
from pg_temp.p2b_test_results;

-- -----------------------------------------------------------------------------
-- Acceptance suite is intentionally non-persistent.
-- -----------------------------------------------------------------------------

rollback;