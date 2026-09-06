-- Haulvia Phase 2 Block P2B
-- Auth/Profile Mapping v1
--
-- Contract:
--   docs/Haulvia_P2B_Auth_Profile_Mapping_Contract_v1.md
--
-- Contract SHA-256:
--   b31b46143d3371a92c11d0076ef4e3691b04c30411468794a4db7576e5780f16
--
-- Depends on:
--   20260814000100_haulvia_foundation_v1.sql
--   20260814000200_haulvia_block_a_commands_v1.sql
--   20260814000300_haulvia_block_b_commands_v1.sql
--   20260814000400_haulvia_block_c_commands_v1.sql
--   20260814000500_haulvia_block_d_commands_v1.sql
--   20260814000600_haulvia_block_e_commands_v1.sql
--   20260830055339_haulvia_p2a_authority_and_config_seeds_v1.sql
--
-- Phase 2 local-only artifact.
-- Hosted Supabase Auth/webhook/email integration remains deferred.

begin;

set local search_path = haulvia, haulvia_command, public;

-- -----------------------------------------------------------------------------
-- P2B.1 Auth-access lifecycle
-- -----------------------------------------------------------------------------

create type haulvia.auth_access_status as enum (
  'UNCLAIMED',
  'ACTIVE',
  'DISABLED',
  'DELETED'
);

alter table haulvia.profiles
  add column auth_access_status haulvia.auth_access_status,
  add column auth_access_changed_at timestamptz;

update haulvia.profiles
set
  auth_access_status =
    case
      when auth_user_id is null then 'UNCLAIMED'::haulvia.auth_access_status
      else 'ACTIVE'::haulvia.auth_access_status
    end,
  auth_access_changed_at = clock_timestamp();

alter table haulvia.profiles
  alter column auth_access_status set not null,
  alter column auth_access_status set default 'UNCLAIMED',
  alter column auth_access_changed_at set not null,
  alter column auth_access_changed_at set default clock_timestamp();

alter table haulvia.profiles
  add constraint profiles_auth_access_mapping_ck
  check (
    (
      auth_user_id is null
      and auth_access_status = 'UNCLAIMED'
    )
    or
    (
      auth_user_id is not null
      and auth_access_status in ('ACTIVE', 'DISABLED', 'DELETED')
    )
  );

comment on column haulvia.profiles.auth_access_status is
  'Current external-auth access lifecycle. Operational identity remains profiles.id.';

comment on column haulvia.profiles.auth_access_changed_at is
  'Last time auth_user_id or auth_access_status materially changed.';

create or replace function haulvia.touch_profile_auth_access_changed_at()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.auth_user_id is distinct from old.auth_user_id
     or new.auth_access_status is distinct from old.auth_access_status
  then
    new.auth_access_changed_at := clock_timestamp();
  end if;

  return new;
end;
$$;

create trigger profiles_touch_auth_access_changed_at
before update of auth_user_id, auth_access_status
on haulvia.profiles
for each row
execute function haulvia.touch_profile_auth_access_changed_at();

revoke all
on function haulvia.touch_profile_auth_access_changed_at()
from public;

-- -----------------------------------------------------------------------------
-- P2B.2 Organization invitations
-- -----------------------------------------------------------------------------

create table haulvia.organization_invitations (
  id uuid primary key default gen_random_uuid(),

  organization_id uuid not null
    references haulvia.organizations(id),

  invited_by_profile_id uuid not null
    references haulvia.profiles(id),

  target_profile_id uuid
    references haulvia.profiles(id),

  destination_identity_kind text not null default 'EMAIL',

  destination_identity_hash text not null,

  destination_hint text,

  secret_hash text not null unique,

  expires_at timestamptz not null,

  revoked_at timestamptz,

  consumed_at timestamptz,

  consumed_by_profile_id uuid
    references haulvia.profiles(id),

  correlation_id uuid,

  creation_idempotency_key text not null,

  created_at timestamptz not null default clock_timestamp(),

  check (
    destination_identity_kind in ('EMAIL')
  ),

  check (
    destination_identity_hash ~ '^[0-9a-fA-F]{64}$'
  ),

  check (
    secret_hash ~ '^[0-9a-fA-F]{64}$'
  ),

  check (
    expires_at > created_at
  ),

  check (
    revoked_at is null
    or revoked_at >= created_at
  ),

  check (
    consumed_at is null
    or consumed_at >= created_at
  ),

  check (
    consumed_at is null
    or consumed_at <= expires_at
  ),

  check (
    (consumed_at is null and consumed_by_profile_id is null)
    or
    (consumed_at is not null and consumed_by_profile_id is not null)
  ),

  check (
    not (
      revoked_at is not null
      and consumed_at is not null
    )
  )
);

comment on table haulvia.organization_invitations is
  'Single-use organization invitations. Raw invitation secrets are never persisted.';

comment on column haulvia.organization_invitations.destination_identity_hash is
  'SHA-256 of the normalized identity used to bind invitation acceptance, normally normalized email.';

comment on column haulvia.organization_invitations.secret_hash is
  'SHA-256 or equivalent approved one-way digest of the invitation secret. Raw secret is never stored.';

create index organization_invitations_org_created_idx
  on haulvia.organization_invitations (
    organization_id,
    created_at desc
  );

create index organization_invitations_target_profile_idx
  on haulvia.organization_invitations (
    target_profile_id,
    created_at desc
  )
  where target_profile_id is not null;

create index organization_invitations_destination_idx
  on haulvia.organization_invitations (
    destination_identity_kind,
    destination_identity_hash
  );

create trigger organization_invitations_reject_delete
before delete on haulvia.organization_invitations
for each row
execute function haulvia.reject_delete();

-- -----------------------------------------------------------------------------
-- P2B.3 Invitation role set
-- -----------------------------------------------------------------------------

create table haulvia.organization_invitation_roles (
  invitation_id uuid not null
    references haulvia.organization_invitations(id),

  role_id uuid not null
    references haulvia.roles(id),

  created_at timestamptz not null default clock_timestamp(),

  primary key (invitation_id, role_id)
);

create or replace function haulvia.enforce_invitation_role_organization_kind()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_organization_kind haulvia.organization_kind;
  v_role_key text;
begin
  select o.kind
    into v_organization_kind
  from haulvia.organization_invitations oi
  join haulvia.organizations o
    on o.id = oi.organization_id
  where oi.id = new.invitation_id;

  if not found then
    raise exception
      'Invitation % does not resolve to an organization',
      new.invitation_id
      using errcode = '23503';
  end if;

  select r.role_key
    into v_role_key
  from haulvia.roles r
  where r.id = new.role_id;

  if not found then
    raise exception
      'Role % does not exist',
      new.role_id
      using errcode = '23503';
  end if;

  if not exists (
    select 1
    from haulvia.role_organization_kinds rok
    where rok.role_id = new.role_id
      and rok.organization_kind = v_organization_kind
  ) then
    raise exception
      'Role % is not permitted for organization kind %',
      v_role_key,
      v_organization_kind
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger organization_invitation_roles_enforce_kind
before insert or update of invitation_id, role_id
on haulvia.organization_invitation_roles
for each row
execute function haulvia.enforce_invitation_role_organization_kind();

revoke all
on function haulvia.enforce_invitation_role_organization_kind()
from public;

-- -----------------------------------------------------------------------------
-- P2B.4 Secure profile-claim proofs
-- -----------------------------------------------------------------------------

create type haulvia.profile_claim_proof_type as enum (
  'INVITATION',
  'VERIFIED_INVITE',
  'ADMIN_RECOVERY'
);

create table haulvia.profile_claim_proofs (
  id uuid primary key default gen_random_uuid(),

  target_profile_id uuid not null
    references haulvia.profiles(id),

  proof_type haulvia.profile_claim_proof_type not null,

  secret_hash text not null unique,

  identity_kind text,

  identity_hash text,

  source_invitation_id uuid
    references haulvia.organization_invitations(id),

  created_by_profile_id uuid
    references haulvia.profiles(id),

  expires_at timestamptz not null,

  revoked_at timestamptz,

  consumed_at timestamptz,

  consumed_by_auth_user_id uuid,

  correlation_id uuid,

  creation_idempotency_key text,

  created_at timestamptz not null default clock_timestamp(),

  check (
    secret_hash ~ '^[0-9a-fA-F]{64}$'
  ),

  check (
    identity_kind is null
    or identity_kind in ('EMAIL')
  ),

  check (
    identity_hash is null
    or identity_hash ~ '^[0-9a-fA-F]{64}$'
  ),

  check (
    (identity_kind is null and identity_hash is null)
    or
    (identity_kind is not null and identity_hash is not null)
  ),

  check (
    expires_at > created_at
  ),

  check (
    revoked_at is null
    or revoked_at >= created_at
  ),

  check (
    consumed_at is null
    or consumed_at >= created_at
  ),

  check (
    consumed_at is null
    or consumed_at <= expires_at
  ),

  check (
    (consumed_at is null and consumed_by_auth_user_id is null)
    or
    (consumed_at is not null and consumed_by_auth_user_id is not null)
  ),

  check (
    not (
      revoked_at is not null
      and consumed_at is not null
    )
  ),

  check (
    proof_type <> 'INVITATION'
    or source_invitation_id is not null
  )
);

comment on table haulvia.profile_claim_proofs is
  'Single-use proof records for securely claiming an existing unclaimed Haulvia profile.';

comment on column haulvia.profile_claim_proofs.secret_hash is
  'One-way digest of the claim secret. Raw claim secrets are never persisted.';

create index profile_claim_proofs_target_idx
  on haulvia.profile_claim_proofs (
    target_profile_id,
    created_at desc
  );

create index profile_claim_proofs_source_invitation_idx
  on haulvia.profile_claim_proofs (
    source_invitation_id
  )
  where source_invitation_id is not null;

create trigger profile_claim_proofs_reject_delete
before delete on haulvia.profile_claim_proofs
for each row
execute function haulvia.reject_delete();

-- -----------------------------------------------------------------------------
-- P2B.5 Existing notification outbox integration
-- -----------------------------------------------------------------------------

alter table haulvia.notification_events
  add column organization_invitation_id uuid
    references haulvia.organization_invitations(id);

do $$
declare
  v_constraint_name text;
begin
  select c.conname
    into v_constraint_name
  from pg_constraint c
  where c.conrelid = 'haulvia.notification_events'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) like '%num_nonnulls%'
    and pg_get_constraintdef(c.oid) like '%receiver_access_token_id%'
  limit 1;

  if v_constraint_name is null then
    raise exception
      'Could not locate existing notification_events subject check constraint';
  end if;

  execute format(
    'alter table haulvia.notification_events drop constraint %I',
    v_constraint_name
  );
end;
$$;

alter table haulvia.notification_events
  add constraint notification_events_subject_ck
  check (
    num_nonnulls(
      shipment_id,
      profile_id,
      receiver_access_token_id,
      organization_invitation_id
    ) >= 1
  );

create index notification_events_invitation_idx
  on haulvia.notification_events (
    organization_invitation_id,
    created_at desc
  )
  where organization_invitation_id is not null;

-- -----------------------------------------------------------------------------
-- P2B Part 1 ends here.
-- Trusted resolver and command functions follow in the next section.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.6 Auth-principal idempotency scope
-- -----------------------------------------------------------------------------

-- Existing commands normally scope idempotency by actor_profile_id.
-- bootstrapProfileFromAuth runs before a Haulvia profile necessarily exists,
-- so P2B adds a separate external-Auth actor scope without creating a second
-- idempotency subsystem.

alter table haulvia.command_idempotency
  add column actor_auth_user_id uuid;

alter table haulvia.command_idempotency
  add constraint command_idempotency_actor_identity_ck
  check (
    num_nonnulls(
      actor_profile_id,
      actor_auth_user_id
    ) <= 1
  );

comment on column haulvia.command_idempotency.actor_auth_user_id is
  'External Auth UUID used only when a trusted command executes before a Haulvia profile exists.';

drop index if exists haulvia.command_idempotency_actor_scope_uq;

create unique index command_idempotency_actor_scope_uq
  on haulvia.command_idempotency (
    (
      case
        when actor_profile_id is not null
          then 'PROFILE:' || actor_profile_id::text

        when actor_auth_user_id is not null
          then 'AUTH:' || actor_auth_user_id::text

        else 'SYSTEM'
      end
    ),
    command_name,
    idempotency_key
  );

-- -----------------------------------------------------------------------------
-- P2B.7 Auth-principal idempotency helpers
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.begin_auth_request(
  p_auth_user_id uuid,
  p_command_name text,
  p_idempotency_key text,
  p_request_hash text
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_row haulvia.command_idempotency%rowtype;
begin
  if p_auth_user_id is null then
    raise exception
      'Authenticated Auth UUID is required'
      using errcode = '22023';
  end if;

  if p_command_name is null
     or length(btrim(p_command_name)) = 0
  then
    raise exception
      'commandName is required'
      using errcode = '22023';
  end if;

  if p_idempotency_key is null
     or length(btrim(p_idempotency_key)) = 0
  then
    raise exception
      'idempotencyKey is required'
      using errcode = '22023';
  end if;

  if p_request_hash is null
     or p_request_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'requestHash must be a 64-character SHA-256 hex value'
      using errcode = '22023';
  end if;

  insert into haulvia.command_idempotency (
    actor_profile_id,
    actor_auth_user_id,
    command_name,
    idempotency_key,
    request_hash
  )
  values (
    null,
    p_auth_user_id,
    p_command_name,
    p_idempotency_key,
    lower(p_request_hash)
  )
  on conflict do nothing;

  select ci.*
    into v_row
  from haulvia.command_idempotency ci
  where ci.actor_profile_id is null
    and ci.actor_auth_user_id = p_auth_user_id
    and ci.command_name = p_command_name
    and ci.idempotency_key = p_idempotency_key
  for update;

  if not found then
    raise exception
      'Unable to resolve Auth-scoped idempotency record'
      using errcode = '55000';
  end if;

  if v_row.request_hash <> lower(p_request_hash) then
    raise exception
      'The idempotency key was already used with a different request'
      using errcode = '22023';
  end if;

  if v_row.status = 'COMPLETED' then
    return
      coalesce(v_row.result, '{}'::jsonb)
      || jsonb_build_object('replayed', true);
  end if;

  return null;
end;
$$;

create or replace function haulvia_command.complete_auth_request(
  p_auth_user_id uuid,
  p_command_name text,
  p_idempotency_key text,
  p_result jsonb
)
returns jsonb
language plpgsql
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_result jsonb;
begin
  if p_auth_user_id is null then
    raise exception
      'Authenticated Auth UUID is required'
      using errcode = '22023';
  end if;

  v_result :=
    coalesce(p_result, '{}'::jsonb)
    || jsonb_build_object('replayed', false);

  update haulvia.command_idempotency
  set
    status = 'COMPLETED',
    result = v_result,
    completed_at = clock_timestamp()
  where actor_profile_id is null
    and actor_auth_user_id = p_auth_user_id
    and command_name = p_command_name
    and idempotency_key = p_idempotency_key;

  if not found then
    raise exception
      'Auth-scoped idempotency request was not started'
      using errcode = '55000';
  end if;

  return v_result;
end;
$$;

revoke all
on function haulvia_command.begin_auth_request(
  uuid,
  text,
  text,
  text
)
from public;

revoke all
on function haulvia_command.complete_auth_request(
  uuid,
  text,
  text,
  jsonb
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.8 Trusted Auth-to-profile resolver
-- -----------------------------------------------------------------------------

create or replace function haulvia.resolve_authenticated_profile_id(
  p_auth_user_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = haulvia, pg_temp
as $$
  select p.id
  from haulvia.profiles p
  where p.auth_user_id = p_auth_user_id
    and p.status = 'ACTIVE'
    and p.auth_access_status = 'ACTIVE'
  limit 1;
$$;

comment on function haulvia.resolve_authenticated_profile_id(uuid) is
  'Resolves a currently authorized external Auth principal to its canonical Haulvia profile. Does not grant organization authority.';

revoke all
on function haulvia.resolve_authenticated_profile_id(uuid)
from public;

-- -----------------------------------------------------------------------------
-- P2B.9 Active organization-membership resolver
-- -----------------------------------------------------------------------------

create or replace function haulvia.resolve_active_membership_id(
  p_profile_id uuid,
  p_organization_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = haulvia, pg_temp
as $$
  select om.id
  from haulvia.organization_memberships om
  join haulvia.organizations o
    on o.id = om.organization_id
  where om.profile_id = p_profile_id
    and om.organization_id = p_organization_id
    and om.status = 'ACTIVE'
    and (
      om.ends_at is null
      or om.ends_at > clock_timestamp()
    )
    and o.status = 'ACTIVE'
  limit 1;
$$;

comment on function haulvia.resolve_active_membership_id(uuid, uuid) is
  'Resolves current ACTIVE organization membership. Role and permission evaluation remain separate.';

revoke all
on function haulvia.resolve_active_membership_id(uuid, uuid)
from public;

-- -----------------------------------------------------------------------------
-- P2B.10 Membership-management authority resolver
-- -----------------------------------------------------------------------------

create or replace function haulvia.membership_management_permission(
  p_organization_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_kind haulvia.organization_kind;
  v_status haulvia.record_status;
begin
  select
    o.kind,
    o.status
  into
    v_kind,
    v_status
  from haulvia.organizations o
  where o.id = p_organization_id;

  if not found then
    raise exception
      'Organization % does not exist',
      p_organization_id
      using errcode = '23503';
  end if;

  if v_status <> 'ACTIVE' then
    raise exception
      'Organization % is not active',
      p_organization_id
      using errcode = '42501';
  end if;

  case v_kind
    when 'CUSTOMER' then
      return 'ORG_MEMBER_MANAGE';

    when 'COURIER_PARTNER' then
      return 'PROVIDER_MEMBER_MANAGE';

    when 'HAULVIA' then
      return 'SECURITY_ACCESS_REVIEW';

    when 'INDEPENDENT_PROVIDER' then
      raise exception
        'Independent-provider organizations do not use human membership-management roles'
        using errcode = '42501';

    else
      raise exception
        'Unsupported organization kind %',
        v_kind
        using errcode = '42501';
  end case;
end;
$$;

revoke all
on function haulvia.membership_management_permission(uuid)
from public;

-- -----------------------------------------------------------------------------
-- P2B.11 Sensitive membership-management authority assertion
-- -----------------------------------------------------------------------------

create or replace function haulvia.assert_membership_management_authority(
  p_actor_profile_id uuid,
  p_organization_id uuid,
  p_reauth_session_id uuid,
  p_reason text
)
returns text
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_permission_key text;
begin
  v_permission_key :=
    haulvia.membership_management_permission(
      p_organization_id
    );

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_organization_id,
    v_permission_key,
    p_reauth_session_id,
    p_reason
  );

  return v_permission_key;
end;
$$;

comment on function haulvia.assert_membership_management_authority(
  uuid,
  uuid,
  uuid,
  text
) is
  'Applies organization-kind-specific sensitive membership authority, including active membership, permission, fresh reauthentication and written reason.';

revoke all
on function haulvia.assert_membership_management_authority(
  uuid,
  uuid,
  uuid,
  text
)
from public;

-- -----------------------------------------------------------------------------
-- P2B Part 2 ends here.
-- Bootstrap and identity-claim commands follow in Part 3.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.12 bootstrapProfileFromAuth
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.bootstrap_profile_from_auth(
  p_auth_user_id uuid,
  p_display_name text,
  p_preferred_locale text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_profile haulvia.profiles%rowtype;
  v_created boolean := false;
  v_result jsonb;
begin
  if p_auth_user_id is null then
    raise exception
      'Authenticated Auth UUID is required'
      using errcode = '22023';
  end if;

  if p_display_name is null
     or length(btrim(p_display_name)) = 0
  then
    raise exception
      'displayName is required'
      using errcode = '22023';
  end if;

  if p_preferred_locale is null
     or length(btrim(p_preferred_locale)) = 0
  then
    raise exception
      'preferredLocale is required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_auth_request(
    p_auth_user_id,
    'bootstrapProfileFromAuth',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  select p.*
    into v_profile
  from haulvia.profiles p
  where p.auth_user_id = p_auth_user_id
  for update;

  if not found then
    insert into haulvia.profiles (
      auth_user_id,
      display_name,
      preferred_locale,
      status,
      auth_access_status,
      auth_access_changed_at
    )
    values (
      p_auth_user_id,
      btrim(p_display_name),
      btrim(p_preferred_locale),
      'ACTIVE',
      'ACTIVE',
      clock_timestamp()
    )
    on conflict (auth_user_id) do nothing
    returning *
      into v_profile;

    if found then
      v_created := true;
    else
      -- A concurrent bootstrap using another idempotency key may have
      -- created the profile after our initial lookup.
      select p.*
        into strict v_profile
      from haulvia.profiles p
      where p.auth_user_id = p_auth_user_id
      for update;
    end if;
  end if;

  -- Bootstrap never reactivates archived, disabled or deleted identity state.
  if v_created then
    insert into haulvia.audit_events (
      actor_kind,
      actor_profile_id,
      command_name,
      entity_table,
      entity_id,
      before_value,
      after_value,
      metadata,
      correlation_id,
      idempotency_key
    )
    values (
      'PROFILE',
      v_profile.id,
      'bootstrapProfileFromAuth',
      'profiles',
      v_profile.id,
      null,
      jsonb_build_object(
        'profileId', v_profile.id,
        'authUserId', v_profile.auth_user_id,
        'status', v_profile.status,
        'authAccessStatus', v_profile.auth_access_status
      ),
      jsonb_build_object(
        'created', true
      ),
      p_correlation_id,
      p_idempotency_key
    );
  end if;

  v_result := jsonb_build_object(
    'profileId', v_profile.id,
    'profileStatus', v_profile.status,
    'authAccessStatus', v_profile.auth_access_status,
    'created', v_created,
    'authorityEligible',
      (
        v_profile.status = 'ACTIVE'
        and v_profile.auth_access_status = 'ACTIVE'
      )
  );

  return haulvia_command.complete_auth_request(
    p_auth_user_id,
    'bootstrapProfileFromAuth',
    p_idempotency_key,
    v_result
  );
end;
$$;

comment on function haulvia_command.bootstrap_profile_from_auth(
  uuid,
  text,
  text,
  text,
  text,
  uuid
) is
  'Idempotently resolves or creates exactly one Haulvia profile for a trusted external Auth UUID. Does not create organization authority.';

revoke all
on function haulvia_command.bootstrap_profile_from_auth(
  uuid,
  text,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.13 Claim-proof resolver
-- -----------------------------------------------------------------------------

create or replace function haulvia.lock_valid_profile_claim_proof(
  p_secret_hash text,
  p_verified_identity_hash text default null
)
returns haulvia.profile_claim_proofs
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_proof haulvia.profile_claim_proofs%rowtype;
begin
  if p_secret_hash is null
     or p_secret_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 claim-secret digest is required'
      using errcode = '22023';
  end if;

  select pcp.*
    into v_proof
  from haulvia.profile_claim_proofs pcp
  where pcp.secret_hash = lower(p_secret_hash)
  for update;

  if not found then
    raise exception
      'Claim proof is invalid'
      using errcode = '42501';
  end if;

  if v_proof.revoked_at is not null then
    raise exception
      'Claim proof has been revoked'
      using errcode = '42501';
  end if;

  if v_proof.consumed_at is not null then
    raise exception
      'Claim proof has already been consumed'
      using errcode = '42501';
  end if;

  if v_proof.expires_at <= clock_timestamp() then
    raise exception
      'Claim proof has expired'
      using errcode = '42501';
  end if;

  if v_proof.identity_hash is not null then
    if p_verified_identity_hash is null
       or p_verified_identity_hash !~ '^[0-9a-fA-F]{64}$'
       or lower(p_verified_identity_hash) <> lower(v_proof.identity_hash)
    then
      raise exception
        'Verified identity does not match claim proof'
        using errcode = '42501';
    end if;
  end if;

  return v_proof;
end;
$$;

revoke all
on function haulvia.lock_valid_profile_claim_proof(
  text,
  text
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.14 claimExistingProfile
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.claim_existing_profile(
  p_auth_user_id uuid,
  p_claim_secret_hash text,
  p_verified_identity_hash text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_proof haulvia.profile_claim_proofs%rowtype;
  v_profile haulvia.profiles%rowtype;
  v_existing_profile_id uuid;
  v_before jsonb;
  v_result jsonb;
begin
  if p_auth_user_id is null then
    raise exception
      'Authenticated Auth UUID is required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_auth_request(
    p_auth_user_id,
    'claimExistingProfile',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  -- Fail closed if this Auth principal already belongs to any profile.
  select p.id
    into v_existing_profile_id
  from haulvia.profiles p
  where p.auth_user_id = p_auth_user_id
  limit 1;

  if found then
    raise exception
      'Authenticated Auth principal is already linked to a Haulvia profile'
      using errcode = '23505';
  end if;

  v_proof := haulvia.lock_valid_profile_claim_proof(
    lower(p_claim_secret_hash),
    case
      when p_verified_identity_hash is null then null
      else lower(p_verified_identity_hash)
    end
  );

  select p.*
    into v_profile
  from haulvia.profiles p
  where p.id = v_proof.target_profile_id
  for update;

  if not found then
    raise exception
      'Claim target profile does not exist'
      using errcode = '23503';
  end if;

  if v_profile.status <> 'ACTIVE' then
    raise exception
      'Claim target profile is not active'
      using errcode = '42501';
  end if;

  if v_profile.auth_user_id is not null
     or v_profile.auth_access_status <> 'UNCLAIMED'
  then
    raise exception
      'Claim target profile has already been claimed'
      using errcode = '23505';
  end if;

  -- Re-check after locking the target profile.
  if exists (
    select 1
    from haulvia.profiles p
    where p.auth_user_id = p_auth_user_id
      and p.id <> v_profile.id
  ) then
    raise exception
      'Authenticated Auth principal is already linked to another Haulvia profile'
      using errcode = '23505';
  end if;

  v_before := jsonb_build_object(
    'profileId', v_profile.id,
    'authUserId', v_profile.auth_user_id,
    'authAccessStatus', v_profile.auth_access_status,
    'status', v_profile.status
  );

  update haulvia.profiles
  set
    auth_user_id = p_auth_user_id,
    auth_access_status = 'ACTIVE'
  where id = v_profile.id
  returning *
    into v_profile;

  update haulvia.profile_claim_proofs
  set
    consumed_at = clock_timestamp(),
    consumed_by_auth_user_id = p_auth_user_id
  where id = v_proof.id
    and consumed_at is null
    and revoked_at is null;

  if not found then
    raise exception
      'Claim proof could not be consumed'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    command_name,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    v_profile.id,
    'claimExistingProfile',
    'profiles',
    v_profile.id,
    v_before,
    jsonb_build_object(
      'profileId', v_profile.id,
      'authUserId', v_profile.auth_user_id,
      'authAccessStatus', v_profile.auth_access_status,
      'status', v_profile.status
    ),
    jsonb_build_object(
      'claimProofId', v_proof.id,
      'proofType', v_proof.proof_type
    ),
    p_correlation_id,
    p_idempotency_key
  );

  v_result := jsonb_build_object(
    'profileId', v_profile.id,
    'authAccessStatus', v_profile.auth_access_status,
    'claimed', true
  );

  return haulvia_command.complete_auth_request(
    p_auth_user_id,
    'claimExistingProfile',
    p_idempotency_key,
    v_result
  );
end;
$$;

comment on function haulvia_command.claim_existing_profile(
  uuid,
  text,
  text,
  text,
  text,
  uuid
) is
  'Atomically links a trusted Auth UUID to the profile bound to a valid single-use claim proof. The client does not choose the target profile.';

revoke all
on function haulvia_command.claim_existing_profile(
  uuid,
  text,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B Part 3 ends here.
-- Organization invitation creation and acceptance follow in Part 4.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.15 Seal invitation role sets
-- -----------------------------------------------------------------------------

alter table haulvia.organization_invitations
  add column sealed_at timestamptz;

alter table haulvia.organization_invitations
  add constraint organization_invitations_sealed_at_ck
  check (
    sealed_at is null
    or sealed_at >= created_at
  );

create or replace function haulvia.guard_organization_invitation_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.organization_id is distinct from old.organization_id
     or new.invited_by_profile_id is distinct from old.invited_by_profile_id
     or new.target_profile_id is distinct from old.target_profile_id
     or new.destination_identity_kind is distinct from old.destination_identity_kind
     or new.destination_identity_hash is distinct from old.destination_identity_hash
     or new.destination_hint is distinct from old.destination_hint
     or new.secret_hash is distinct from old.secret_hash
     or new.expires_at is distinct from old.expires_at
     or new.correlation_id is distinct from old.correlation_id
     or new.creation_idempotency_key is distinct from old.creation_idempotency_key
     or new.created_at is distinct from old.created_at
  then
    raise exception
      'Organization invitation immutable fields cannot be changed after creation'
      using errcode = '55000';
  end if;

  if old.sealed_at is not null
     and new.sealed_at is distinct from old.sealed_at
  then
    raise exception
      'A sealed organization invitation cannot be unsealed or resealed'
      using errcode = '55000';
  end if;

  if old.revoked_at is not null
     and new.revoked_at is distinct from old.revoked_at
  then
    raise exception
      'Invitation revocation is irreversible'
      using errcode = '55000';
  end if;

  if old.consumed_at is not null
     and (
       new.consumed_at is distinct from old.consumed_at
       or new.consumed_by_profile_id is distinct from old.consumed_by_profile_id
     )
  then
    raise exception
      'Invitation consumption is irreversible'
      using errcode = '55000';
  end if;

  return new;
end;
$$;

create trigger organization_invitations_guard_update
before update on haulvia.organization_invitations
for each row
execute function haulvia.guard_organization_invitation_update();

revoke all
on function haulvia.guard_organization_invitation_update()
from public;

create or replace function haulvia.guard_organization_invitation_role_mutation()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_invitation_id uuid;
  v_sealed_at timestamptz;
begin
  if tg_op <> 'INSERT' then
    raise exception
      'Organization invitation roles are immutable'
      using errcode = '55000';
  end if;

  v_invitation_id := new.invitation_id;

  select oi.sealed_at
    into v_sealed_at
  from haulvia.organization_invitations oi
  where oi.id = v_invitation_id
  for update;

  if not found then
    raise exception
      'Invitation % does not exist',
      v_invitation_id
      using errcode = '23503';
  end if;

  if v_sealed_at is not null then
    raise exception
      'Roles cannot be added to a sealed invitation'
      using errcode = '55000';
  end if;

  return new;
end;
$$;

create trigger organization_invitation_roles_guard_mutation
before insert or update or delete
on haulvia.organization_invitation_roles
for each row
execute function haulvia.guard_organization_invitation_role_mutation();

revoke all
on function haulvia.guard_organization_invitation_role_mutation()
from public;

-- -----------------------------------------------------------------------------
-- P2B.16 Protect profile-claim proof immutable fields
-- -----------------------------------------------------------------------------

create or replace function haulvia.guard_profile_claim_proof_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.target_profile_id is distinct from old.target_profile_id
     or new.proof_type is distinct from old.proof_type
     or new.secret_hash is distinct from old.secret_hash
     or new.identity_kind is distinct from old.identity_kind
     or new.identity_hash is distinct from old.identity_hash
     or new.source_invitation_id is distinct from old.source_invitation_id
     or new.created_by_profile_id is distinct from old.created_by_profile_id
     or new.expires_at is distinct from old.expires_at
     or new.correlation_id is distinct from old.correlation_id
     or new.creation_idempotency_key is distinct from old.creation_idempotency_key
     or new.created_at is distinct from old.created_at
  then
    raise exception
      'Profile claim proof immutable fields cannot be changed after creation'
      using errcode = '55000';
  end if;

  if old.revoked_at is not null
     and new.revoked_at is distinct from old.revoked_at
  then
    raise exception
      'Claim-proof revocation is irreversible'
      using errcode = '55000';
  end if;

  if old.consumed_at is not null
     and (
       new.consumed_at is distinct from old.consumed_at
       or new.consumed_by_auth_user_id is distinct from old.consumed_by_auth_user_id
     )
  then
    raise exception
      'Claim-proof consumption is irreversible'
      using errcode = '55000';
  end if;

  return new;
end;
$$;

create trigger profile_claim_proofs_guard_update
before update on haulvia.profile_claim_proofs
for each row
execute function haulvia.guard_profile_claim_proof_update();

revoke all
on function haulvia.guard_profile_claim_proof_update()
from public;

-- -----------------------------------------------------------------------------
-- P2B.17 createOrganizationInvitation
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.create_organization_invitation(
  p_actor_profile_id uuid,
  p_organization_id uuid,
  p_role_keys text[],
  p_destination_identity_hash text,
  p_secret_hash text,
  p_expires_at timestamptz,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_target_profile_id uuid default null,
  p_destination_hint text default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_permission_key text;
  v_organization_kind haulvia.organization_kind;
  v_role_keys text[];
  v_invitation haulvia.organization_invitations%rowtype;
  v_notification_id uuid;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_organization_id is null
  then
    raise exception
      'Actor profile and organization are required'
      using errcode = '22023';
  end if;

  if p_destination_identity_hash is null
     or p_destination_identity_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 destination identity digest is required'
      using errcode = '22023';
  end if;

  if p_secret_hash is null
     or p_secret_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 invitation-secret digest is required'
      using errcode = '22023';
  end if;

  if p_expires_at is null
     or p_expires_at <= clock_timestamp()
  then
    raise exception
      'Invitation expiry must be in the future'
      using errcode = '22023';
  end if;

  if p_role_keys is null
     or cardinality(p_role_keys) = 0
  then
    raise exception
      'At least one invitation role is required'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from unnest(p_role_keys) rk
    where rk is null
       or length(btrim(rk)) = 0
  ) then
    raise exception
      'Invitation role keys cannot be blank'
      using errcode = '22023';
  end if;

  select array_agg(
           distinct upper(btrim(rk))
           order by upper(btrim(rk))
         )
    into v_role_keys
  from unnest(p_role_keys) rk;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'createOrganizationInvitation',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  v_permission_key :=
    haulvia.assert_membership_management_authority(
      p_actor_profile_id,
      p_organization_id,
      p_reauth_session_id,
      p_reason
    );

  select o.kind
    into v_organization_kind
  from haulvia.organizations o
  where o.id = p_organization_id
    and o.status = 'ACTIVE';

  if not found then
    raise exception
      'Target organization is not active'
      using errcode = '42501';
  end if;

  if p_target_profile_id is not null
     and not exists (
       select 1
       from haulvia.profiles p
       where p.id = p_target_profile_id
         and p.status = 'ACTIVE'
     )
  then
    raise exception
      'Target profile does not exist or is not active'
      using errcode = '23503';
  end if;

  if exists (
    select 1
    from unnest(v_role_keys) requested(role_key)
    left join haulvia.roles r
      on r.role_key = requested.role_key
    left join haulvia.role_organization_kinds rok
      on rok.role_id = r.id
     and rok.organization_kind = v_organization_kind
    where r.id is null
       or rok.role_id is null
  ) then
    raise exception
      'One or more requested roles are invalid for organization kind %',
      v_organization_kind
      using errcode = '42501';
  end if;

  insert into haulvia.organization_invitations (
    organization_id,
    invited_by_profile_id,
    target_profile_id,
    destination_identity_kind,
    destination_identity_hash,
    destination_hint,
    secret_hash,
    expires_at,
    correlation_id,
    creation_idempotency_key
  )
  values (
    p_organization_id,
    p_actor_profile_id,
    p_target_profile_id,
    'EMAIL',
    lower(p_destination_identity_hash),
    p_destination_hint,
    lower(p_secret_hash),
    p_expires_at,
    p_correlation_id,
    p_idempotency_key
  )
  returning *
    into v_invitation;

  insert into haulvia.organization_invitation_roles (
    invitation_id,
    role_id
  )
  select
    v_invitation.id,
    r.id
  from haulvia.roles r
  where r.role_key = any (v_role_keys);

  update haulvia.organization_invitations
  set sealed_at = clock_timestamp()
  where id = v_invitation.id
  returning *
    into v_invitation;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_organization_id,
    'createOrganizationInvitation',
    v_permission_key,
    p_reauth_session_id,
    p_reason,
    'organization_invitations',
    v_invitation.id,
    null,
    jsonb_build_object(
      'invitationId', v_invitation.id,
      'organizationId', v_invitation.organization_id,
      'targetProfileId', v_invitation.target_profile_id,
      'expiresAt', v_invitation.expires_at,
      'sealedAt', v_invitation.sealed_at
    ),
    jsonb_build_object(
      'roleKeys', to_jsonb(v_role_keys),
      'destinationIdentityKind', 'EMAIL'
    ),
    p_correlation_id,
    p_idempotency_key
  );

  -- This is durable notification intent only. The raw invitation secret is
  -- deliberately not stored in notification_events.
  insert into haulvia.notification_events (
    organization_invitation_id,
    event_code,
    channel,
    template_version,
    status,
    destination_hash,
    payload,
    scheduled_at,
    idempotency_key
  )
  values (
    v_invitation.id,
    'ORGANIZATION_INVITATION_CREATED',
    'EMAIL',
    'P2B_ORGANIZATION_INVITATION_V1',
    'QUEUED',
    lower(p_destination_identity_hash),
    jsonb_build_object(
      'invitationId', v_invitation.id,
      'organizationId', p_organization_id,
      'expiresAt', p_expires_at,
      'targetProfileId', p_target_profile_id,
      'roleKeys', to_jsonb(v_role_keys),
      'requiresSecretAtDispatch', true
    ),
    clock_timestamp(),
    v_invitation.id::text
  )
  returning id
    into v_notification_id;

  v_result := jsonb_build_object(
    'invitationId', v_invitation.id,
    'organizationId', v_invitation.organization_id,
    'expiresAt', v_invitation.expires_at,
    'roleKeys', to_jsonb(v_role_keys),
    'notificationEventId', v_notification_id
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'createOrganizationInvitation',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.create_organization_invitation(
  uuid,
  uuid,
  text[],
  text,
  text,
  timestamptz,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.18 acceptOrganizationInvitation
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.accept_organization_invitation(
  p_auth_user_id uuid,
  p_invitation_secret_hash text,
  p_verified_identity_hash text,
  p_display_name text,
  p_preferred_locale text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_invitation haulvia.organization_invitations%rowtype;
  v_profile haulvia.profiles%rowtype;
  v_membership haulvia.organization_memberships%rowtype;
  v_profile_created boolean := false;
  v_profile_claimed boolean := false;
  v_membership_created boolean := false;
  v_membership_activated boolean := false;
  v_role_keys text[];
  v_before jsonb;
  v_result jsonb;
begin
  if p_auth_user_id is null then
    raise exception
      'Authenticated Auth UUID is required'
      using errcode = '22023';
  end if;

  if p_invitation_secret_hash is null
     or p_invitation_secret_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 invitation-secret digest is required'
      using errcode = '22023';
  end if;

  if p_verified_identity_hash is null
     or p_verified_identity_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A verified identity digest is required'
      using errcode = '22023';
  end if;

  if p_display_name is null
     or length(btrim(p_display_name)) = 0
  then
    raise exception
      'displayName is required'
      using errcode = '22023';
  end if;

  if p_preferred_locale is null
     or length(btrim(p_preferred_locale)) = 0
  then
    raise exception
      'preferredLocale is required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_auth_request(
    p_auth_user_id,
    'acceptOrganizationInvitation',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  select oi.*
    into v_invitation
  from haulvia.organization_invitations oi
  where oi.secret_hash = lower(p_invitation_secret_hash)
  for update;

  if not found then
    raise exception
      'Organization invitation is invalid'
      using errcode = '42501';
  end if;

  if v_invitation.sealed_at is null then
    raise exception
      'Organization invitation is not finalized'
      using errcode = '42501';
  end if;

  if v_invitation.revoked_at is not null then
    raise exception
      'Organization invitation has been revoked'
      using errcode = '42501';
  end if;

  if v_invitation.consumed_at is not null then
    raise exception
      'Organization invitation has already been consumed'
      using errcode = '42501';
  end if;

  if v_invitation.expires_at <= clock_timestamp() then
    raise exception
      'Organization invitation has expired'
      using errcode = '42501';
  end if;

  if lower(p_verified_identity_hash)
     <> lower(v_invitation.destination_identity_hash)
  then
    raise exception
      'Verified identity does not match invitation'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = v_invitation.organization_id
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Invitation organization is not active'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from haulvia.organization_invitation_roles oir
    where oir.invitation_id = v_invitation.id
  ) then
    raise exception
      'Invitation contains no roles'
      using errcode = '42501';
  end if;

  -- Revalidate role compatibility at acceptance time.
  if exists (
    select 1
    from haulvia.organization_invitation_roles oir
    join haulvia.roles r
      on r.id = oir.role_id
    join haulvia.organizations o
      on o.id = v_invitation.organization_id
    left join haulvia.role_organization_kinds rok
      on rok.role_id = oir.role_id
     and rok.organization_kind = o.kind
    where oir.invitation_id = v_invitation.id
      and rok.role_id is null
  ) then
    raise exception
      'Invitation contains a role no longer valid for the organization'
      using errcode = '42501';
  end if;

  select array_agg(
           r.role_key
           order by r.role_key
         )
    into v_role_keys
  from haulvia.organization_invitation_roles oir
  join haulvia.roles r
    on r.id = oir.role_id
  where oir.invitation_id = v_invitation.id;

  -- First resolve an already-claimed profile for this Auth UUID.
  select p.*
    into v_profile
  from haulvia.profiles p
  where p.auth_user_id = p_auth_user_id
  for update;

  if found then
    if v_profile.status <> 'ACTIVE'
       or v_profile.auth_access_status <> 'ACTIVE'
    then
      raise exception
        'Authenticated profile is not eligible to accept invitations'
        using errcode = '42501';
    end if;

    if v_invitation.target_profile_id is not null
       and v_invitation.target_profile_id <> v_profile.id
    then
      raise exception
        'Invitation is bound to a different Haulvia profile'
        using errcode = '42501';
    end if;

  elsif v_invitation.target_profile_id is not null then

    select p.*
      into v_profile
    from haulvia.profiles p
    where p.id = v_invitation.target_profile_id
    for update;

    if not found then
      raise exception
        'Invitation target profile does not exist'
        using errcode = '23503';
    end if;

    if v_profile.status <> 'ACTIVE'
       or v_profile.auth_user_id is not null
       or v_profile.auth_access_status <> 'UNCLAIMED'
    then
      raise exception
        'Invitation target profile is not eligible for claim'
        using errcode = '42501';
    end if;

    if exists (
      select 1
      from haulvia.profiles p
      where p.auth_user_id = p_auth_user_id
        and p.id <> v_profile.id
    ) then
      raise exception
        'Authenticated Auth principal is already linked elsewhere'
        using errcode = '23505';
    end if;

    update haulvia.profiles
    set
      auth_user_id = p_auth_user_id,
      auth_access_status = 'ACTIVE'
    where id = v_profile.id
    returning *
      into v_profile;

    v_profile_claimed := true;

  else

    insert into haulvia.profiles (
      auth_user_id,
      display_name,
      preferred_locale,
      status,
      auth_access_status,
      auth_access_changed_at
    )
    values (
      p_auth_user_id,
      btrim(p_display_name),
      btrim(p_preferred_locale),
      'ACTIVE',
      'ACTIVE',
      clock_timestamp()
    )
    on conflict (auth_user_id) do nothing
    returning *
      into v_profile;

    if found then
      v_profile_created := true;
    else
      select p.*
        into strict v_profile
      from haulvia.profiles p
      where p.auth_user_id = p_auth_user_id
      for update;

      if v_profile.status <> 'ACTIVE'
         or v_profile.auth_access_status <> 'ACTIVE'
      then
        raise exception
          'Authenticated profile is not eligible to accept invitations'
          using errcode = '42501';
      end if;
    end if;
  end if;

  select om.*
    into v_membership
  from haulvia.organization_memberships om
  where om.organization_id = v_invitation.organization_id
    and om.profile_id = v_profile.id
  for update;

  if not found then

    insert into haulvia.organization_memberships (
      organization_id,
      profile_id,
      status,
      starts_at,
      ends_at
    )
    values (
      v_invitation.organization_id,
      v_profile.id,
      'ACTIVE',
      clock_timestamp(),
      null
    )
    returning *
      into v_membership;

    v_membership_created := true;

  elsif v_membership.status = 'INVITED' then

    -- Activating an INVITED membership must not activate roles that were not
    -- part of the sealed invitation.
    if exists (
      select 1
      from haulvia.membership_roles mr
      where mr.membership_id = v_membership.id
        and not exists (
          select 1
          from haulvia.organization_invitation_roles oir
          where oir.invitation_id = v_invitation.id
            and oir.role_id = mr.role_id
        )
    ) then
      raise exception
        'Existing invited membership contains roles outside this invitation'
        using errcode = '42501';
    end if;

    update haulvia.organization_memberships
    set
      status = 'ACTIVE',
      starts_at = clock_timestamp(),
      ends_at = null
    where id = v_membership.id
    returning *
      into v_membership;

    v_membership_activated := true;

  elsif v_membership.status = 'ACTIVE' then

    -- Acceptance may be idempotent for an existing ACTIVE membership only
    -- when it does not grant any additional role.
    if exists (
      select 1
      from haulvia.organization_invitation_roles oir
      where oir.invitation_id = v_invitation.id
        and not exists (
          select 1
          from haulvia.membership_roles mr
          where mr.membership_id = v_membership.id
            and mr.role_id = oir.role_id
        )
    ) then
      raise exception
        'Invitation would widen an already-active membership'
        using errcode = '42501';
    end if;

  else
    raise exception
      'Suspended or ended memberships cannot be reactivated by invitation acceptance'
      using errcode = '42501';
  end if;

  if v_membership_created or v_membership_activated then
    insert into haulvia.membership_roles (
      membership_id,
      role_id,
      granted_by_profile_id
    )
    select
      v_membership.id,
      oir.role_id,
      v_invitation.invited_by_profile_id
    from haulvia.organization_invitation_roles oir
    where oir.invitation_id = v_invitation.id
    on conflict (membership_id, role_id) do nothing;
  end if;

  v_before := jsonb_build_object(
    'invitationId', v_invitation.id,
    'consumedAt', v_invitation.consumed_at,
    'consumedByProfileId', v_invitation.consumed_by_profile_id
  );

  update haulvia.organization_invitations
  set
    consumed_at = clock_timestamp(),
    consumed_by_profile_id = v_profile.id
  where id = v_invitation.id
    and consumed_at is null
    and revoked_at is null
  returning *
    into v_invitation;

  if not found then
    raise exception
      'Invitation could not be consumed'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    v_profile.id,
    v_invitation.organization_id,
    'acceptOrganizationInvitation',
    'organization_invitations',
    v_invitation.id,
    v_before,
    jsonb_build_object(
      'invitationId', v_invitation.id,
      'consumedAt', v_invitation.consumed_at,
      'consumedByProfileId', v_invitation.consumed_by_profile_id,
      'membershipId', v_membership.id,
      'membershipStatus', v_membership.status
    ),
    jsonb_build_object(
      'roleKeys', to_jsonb(v_role_keys),
      'profileCreated', v_profile_created,
      'profileClaimed', v_profile_claimed,
      'membershipCreated', v_membership_created,
      'membershipActivated', v_membership_activated
    ),
    p_correlation_id,
    p_idempotency_key
  );

  v_result := jsonb_build_object(
    'invitationId', v_invitation.id,
    'profileId', v_profile.id,
    'organizationId', v_invitation.organization_id,
    'membershipId', v_membership.id,
    'membershipStatus', v_membership.status,
    'roleKeys', to_jsonb(v_role_keys),
    'profileCreated', v_profile_created,
    'profileClaimed', v_profile_claimed
  );

  return haulvia_command.complete_auth_request(
    p_auth_user_id,
    'acceptOrganizationInvitation',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.accept_organization_invitation(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B Part 4 ends here.
-- Membership lifecycle, claim-proof issuance and Auth recovery follow in Part 5.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.19 revokeOrganizationInvitation
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.revoke_organization_invitation(
  p_actor_profile_id uuid,
  p_organization_id uuid,
  p_invitation_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_permission_key text;
  v_invitation haulvia.organization_invitations%rowtype;
  v_before jsonb;
  v_notification_id uuid;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_organization_id is null
     or p_invitation_id is null
  then
    raise exception
      'Actor profile, organization and invitation are required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'revokeOrganizationInvitation',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  v_permission_key :=
    haulvia.assert_membership_management_authority(
      p_actor_profile_id,
      p_organization_id,
      p_reauth_session_id,
      p_reason
    );

  select oi.*
    into v_invitation
  from haulvia.organization_invitations oi
  where oi.id = p_invitation_id
  for update;

  if not found then
    raise exception
      'Organization invitation does not exist'
      using errcode = '23503';
  end if;

  if v_invitation.organization_id <> p_organization_id then
    raise exception
      'Invitation does not belong to the requested organization'
      using errcode = '42501';
  end if;

  if v_invitation.consumed_at is not null then
    raise exception
      'A consumed invitation cannot be revoked'
      using errcode = '55000';
  end if;

  if v_invitation.revoked_at is not null then
    raise exception
      'Invitation has already been revoked'
      using errcode = '55000';
  end if;

  v_before := jsonb_build_object(
    'invitationId', v_invitation.id,
    'revokedAt', v_invitation.revoked_at,
    'consumedAt', v_invitation.consumed_at
  );

  update haulvia.organization_invitations
  set revoked_at = clock_timestamp()
  where id = v_invitation.id
    and revoked_at is null
    and consumed_at is null
  returning *
    into v_invitation;

  if not found then
    raise exception
      'Invitation could not be revoked'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_organization_id,
    'revokeOrganizationInvitation',
    v_permission_key,
    p_reauth_session_id,
    p_reason,
    'organization_invitations',
    v_invitation.id,
    v_before,
    jsonb_build_object(
      'invitationId', v_invitation.id,
      'revokedAt', v_invitation.revoked_at,
      'consumedAt', v_invitation.consumed_at
    ),
    '{}'::jsonb,
    p_correlation_id,
    p_idempotency_key
  );

  insert into haulvia.notification_events (
    organization_invitation_id,
    event_code,
    channel,
    template_version,
    status,
    destination_hash,
    payload,
    scheduled_at,
    idempotency_key
  )
  values (
    v_invitation.id,
    'ORGANIZATION_INVITATION_REVOKED',
    'EMAIL',
    'P2B_ORGANIZATION_INVITATION_REVOKED_V1',
    'QUEUED',
    v_invitation.destination_identity_hash,
    jsonb_build_object(
      'invitationId', v_invitation.id,
      'organizationId', v_invitation.organization_id
    ),
    clock_timestamp(),
    v_invitation.id::text || ':' || p_idempotency_key
  )
  returning id
    into v_notification_id;

  v_result := jsonb_build_object(
    'invitationId', v_invitation.id,
    'revokedAt', v_invitation.revoked_at,
    'notificationEventId', v_notification_id
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'revokeOrganizationInvitation',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.revoke_organization_invitation(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.20 suspendOrganizationMembership
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.suspend_organization_membership(
  p_actor_profile_id uuid,
  p_organization_id uuid,
  p_membership_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_permission_key text;
  v_membership haulvia.organization_memberships%rowtype;
  v_before jsonb;
  v_notification_id uuid;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_organization_id is null
     or p_membership_id is null
  then
    raise exception
      'Actor profile, organization and membership are required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'suspendOrganizationMembership',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  v_permission_key :=
    haulvia.assert_membership_management_authority(
      p_actor_profile_id,
      p_organization_id,
      p_reauth_session_id,
      p_reason
    );

  select om.*
    into v_membership
  from haulvia.organization_memberships om
  where om.id = p_membership_id
  for update;

  if not found then
    raise exception
      'Organization membership does not exist'
      using errcode = '23503';
  end if;

  if v_membership.organization_id <> p_organization_id then
    raise exception
      'Membership does not belong to the requested organization'
      using errcode = '42501';
  end if;

  if v_membership.status <> 'ACTIVE' then
    raise exception
      'Only an ACTIVE membership may be suspended'
      using errcode = '55000';
  end if;

  v_before := jsonb_build_object(
    'membershipId', v_membership.id,
    'status', v_membership.status,
    'startsAt', v_membership.starts_at,
    'endsAt', v_membership.ends_at
  );

  update haulvia.organization_memberships
  set status = 'SUSPENDED'
  where id = v_membership.id
    and status = 'ACTIVE'
  returning *
    into v_membership;

  if not found then
    raise exception
      'Membership could not be suspended'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_organization_id,
    'suspendOrganizationMembership',
    v_permission_key,
    p_reauth_session_id,
    p_reason,
    'organization_memberships',
    v_membership.id,
    v_before,
    jsonb_build_object(
      'membershipId', v_membership.id,
      'status', v_membership.status,
      'startsAt', v_membership.starts_at,
      'endsAt', v_membership.ends_at
    ),
    jsonb_build_object(
      'targetProfileId', v_membership.profile_id
    ),
    p_correlation_id,
    p_idempotency_key
  );

  insert into haulvia.notification_events (
    profile_id,
    event_code,
    channel,
    template_version,
    status,
    payload,
    scheduled_at,
    idempotency_key
  )
  values (
    v_membership.profile_id,
    'ORGANIZATION_MEMBERSHIP_SUSPENDED',
    'IN_APP',
    'P2B_MEMBERSHIP_SUSPENDED_V1',
    'QUEUED',
    jsonb_build_object(
      'organizationId', v_membership.organization_id,
      'membershipId', v_membership.id
    ),
    clock_timestamp(),
    v_membership.id::text || ':' || p_idempotency_key
  )
  returning id
    into v_notification_id;

  v_result := jsonb_build_object(
    'membershipId', v_membership.id,
    'profileId', v_membership.profile_id,
    'organizationId', v_membership.organization_id,
    'status', v_membership.status,
    'notificationEventId', v_notification_id
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'suspendOrganizationMembership',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.suspend_organization_membership(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.21 endOrganizationMembership
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.end_organization_membership(
  p_actor_profile_id uuid,
  p_organization_id uuid,
  p_membership_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_permission_key text;
  v_membership haulvia.organization_memberships%rowtype;
  v_before jsonb;
  v_end_time timestamptz;
  v_notification_id uuid;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_organization_id is null
     or p_membership_id is null
  then
    raise exception
      'Actor profile, organization and membership are required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'endOrganizationMembership',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  v_permission_key :=
    haulvia.assert_membership_management_authority(
      p_actor_profile_id,
      p_organization_id,
      p_reauth_session_id,
      p_reason
    );

  select om.*
    into v_membership
  from haulvia.organization_memberships om
  where om.id = p_membership_id
  for update;

  if not found then
    raise exception
      'Organization membership does not exist'
      using errcode = '23503';
  end if;

  if v_membership.organization_id <> p_organization_id then
    raise exception
      'Membership does not belong to the requested organization'
      using errcode = '42501';
  end if;

  if v_membership.status not in ('ACTIVE', 'SUSPENDED') then
    raise exception
      'Only an ACTIVE or SUSPENDED membership may be ended'
      using errcode = '55000';
  end if;

  v_before := jsonb_build_object(
    'membershipId', v_membership.id,
    'status', v_membership.status,
    'startsAt', v_membership.starts_at,
    'endsAt', v_membership.ends_at
  );

  v_end_time := clock_timestamp();

  if v_end_time <= v_membership.starts_at then
    v_end_time := v_membership.starts_at + interval '1 microsecond';
  end if;

  update haulvia.organization_memberships
  set
    status = 'ENDED',
    ends_at = v_end_time
  where id = v_membership.id
    and status in ('ACTIVE', 'SUSPENDED')
  returning *
    into v_membership;

  if not found then
    raise exception
      'Membership could not be ended'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_organization_id,
    'endOrganizationMembership',
    v_permission_key,
    p_reauth_session_id,
    p_reason,
    'organization_memberships',
    v_membership.id,
    v_before,
    jsonb_build_object(
      'membershipId', v_membership.id,
      'status', v_membership.status,
      'startsAt', v_membership.starts_at,
      'endsAt', v_membership.ends_at
    ),
    jsonb_build_object(
      'targetProfileId', v_membership.profile_id
    ),
    p_correlation_id,
    p_idempotency_key
  );

  insert into haulvia.notification_events (
    profile_id,
    event_code,
    channel,
    template_version,
    status,
    payload,
    scheduled_at,
    idempotency_key
  )
  values (
    v_membership.profile_id,
    'ORGANIZATION_MEMBERSHIP_ENDED',
    'IN_APP',
    'P2B_MEMBERSHIP_ENDED_V1',
    'QUEUED',
    jsonb_build_object(
      'organizationId', v_membership.organization_id,
      'membershipId', v_membership.id,
      'endedAt', v_membership.ends_at
    ),
    clock_timestamp(),
    v_membership.id::text || ':' || p_idempotency_key
  )
  returning id
    into v_notification_id;

  v_result := jsonb_build_object(
    'membershipId', v_membership.id,
    'profileId', v_membership.profile_id,
    'organizationId', v_membership.organization_id,
    'status', v_membership.status,
    'endsAt', v_membership.ends_at,
    'notificationEventId', v_notification_id
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'endOrganizationMembership',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.end_organization_membership(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B Part 5 ends here.
-- Claim-proof issuance/revocation and Auth identity recovery follow in Part 6.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.22 issueProfileClaimProof
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.issue_profile_claim_proof(
  p_actor_profile_id uuid,
  p_haulvia_organization_id uuid,
  p_target_profile_id uuid,
  p_proof_type haulvia.profile_claim_proof_type,
  p_secret_hash text,
  p_identity_kind text,
  p_identity_hash text,
  p_expires_at timestamptz,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_source_invitation_id uuid default null,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_target_profile haulvia.profiles%rowtype;
  v_proof haulvia.profile_claim_proofs%rowtype;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_haulvia_organization_id is null
     or p_target_profile_id is null
  then
    raise exception
      'Actor profile, Haulvia organization and target profile are required'
      using errcode = '22023';
  end if;

  if p_secret_hash is null
     or p_secret_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 claim-secret digest is required'
      using errcode = '22023';
  end if;

  if (
       p_identity_kind is null
       and p_identity_hash is not null
     )
     or (
       p_identity_kind is not null
       and p_identity_hash is null
     )
  then
    raise exception
      'identityKind and identityHash must either both be supplied or both be null'
      using errcode = '22023';
  end if;

  if p_identity_kind is not null
     and upper(btrim(p_identity_kind)) <> 'EMAIL'
  then
    raise exception
      'Unsupported claim identity kind'
      using errcode = '22023';
  end if;

  if p_identity_hash is not null
     and p_identity_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 identity digest is required'
      using errcode = '22023';
  end if;

  if p_expires_at is null
     or p_expires_at <= clock_timestamp()
  then
    raise exception
      'Claim proof expiry must be in the future'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'issueProfileClaimProof',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = p_haulvia_organization_id
      and o.kind = 'HAULVIA'
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Recovery authority must operate inside an active Haulvia organization'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_haulvia_organization_id,
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason
  );

  select p.*
    into v_target_profile
  from haulvia.profiles p
  where p.id = p_target_profile_id
  for update;

  if not found then
    raise exception
      'Target profile does not exist'
      using errcode = '23503';
  end if;

  if v_target_profile.status <> 'ACTIVE' then
    raise exception
      'Target profile is not active'
      using errcode = '42501';
  end if;

  if v_target_profile.auth_user_id is not null
     or v_target_profile.auth_access_status <> 'UNCLAIMED'
  then
    raise exception
      'Profile claim proof may only target an unclaimed profile'
      using errcode = '42501';
  end if;

  if p_proof_type = 'INVITATION' then
    if p_source_invitation_id is null then
      raise exception
        'Invitation claim proof requires a source invitation'
        using errcode = '22023';
    end if;

    if not exists (
      select 1
      from haulvia.organization_invitations oi
      where oi.id = p_source_invitation_id
        and oi.target_profile_id = p_target_profile_id
        and oi.revoked_at is null
        and oi.consumed_at is null
        and oi.expires_at > clock_timestamp()
    ) then
      raise exception
        'Source invitation is not valid for the target profile'
        using errcode = '42501';
    end if;
  end if;

  insert into haulvia.profile_claim_proofs (
    target_profile_id,
    proof_type,
    secret_hash,
    identity_kind,
    identity_hash,
    source_invitation_id,
    created_by_profile_id,
    expires_at,
    correlation_id,
    creation_idempotency_key
  )
  values (
    p_target_profile_id,
    p_proof_type,
    lower(p_secret_hash),
    case
      when p_identity_kind is null then null
      else upper(btrim(p_identity_kind))
    end,
    case
      when p_identity_hash is null then null
      else lower(p_identity_hash)
    end,
    p_source_invitation_id,
    p_actor_profile_id,
    p_expires_at,
    p_correlation_id,
    p_idempotency_key
  )
  returning *
    into v_proof;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_haulvia_organization_id,
    'issueProfileClaimProof',
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason,
    'profile_claim_proofs',
    v_proof.id,
    null,
    jsonb_build_object(
      'claimProofId', v_proof.id,
      'targetProfileId', v_proof.target_profile_id,
      'proofType', v_proof.proof_type,
      'expiresAt', v_proof.expires_at
    ),
    jsonb_build_object(
      'identityKind', v_proof.identity_kind,
      'sourceInvitationId', v_proof.source_invitation_id
    ),
    p_correlation_id,
    p_idempotency_key
  );

  v_result := jsonb_build_object(
    'claimProofId', v_proof.id,
    'targetProfileId', v_proof.target_profile_id,
    'proofType', v_proof.proof_type,
    'expiresAt', v_proof.expires_at
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'issueProfileClaimProof',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.issue_profile_claim_proof(
  uuid,
  uuid,
  uuid,
  haulvia.profile_claim_proof_type,
  text,
  text,
  text,
  timestamptz,
  uuid,
  text,
  text,
  text,
  uuid,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.23 revokeProfileClaimProof
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.revoke_profile_claim_proof(
  p_actor_profile_id uuid,
  p_haulvia_organization_id uuid,
  p_claim_proof_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_proof haulvia.profile_claim_proofs%rowtype;
  v_before jsonb;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_haulvia_organization_id is null
     or p_claim_proof_id is null
  then
    raise exception
      'Actor profile, Haulvia organization and claim proof are required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'revokeProfileClaimProof',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = p_haulvia_organization_id
      and o.kind = 'HAULVIA'
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Claim-proof revocation must operate inside an active Haulvia organization'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_haulvia_organization_id,
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason
  );

  select pcp.*
    into v_proof
  from haulvia.profile_claim_proofs pcp
  where pcp.id = p_claim_proof_id
  for update;

  if not found then
    raise exception
      'Claim proof does not exist'
      using errcode = '23503';
  end if;

  if v_proof.consumed_at is not null then
    raise exception
      'A consumed claim proof cannot be revoked'
      using errcode = '55000';
  end if;

  if v_proof.revoked_at is not null then
    raise exception
      'Claim proof has already been revoked'
      using errcode = '55000';
  end if;

  v_before := jsonb_build_object(
    'claimProofId', v_proof.id,
    'revokedAt', v_proof.revoked_at,
    'consumedAt', v_proof.consumed_at
  );

  update haulvia.profile_claim_proofs
  set revoked_at = clock_timestamp()
  where id = v_proof.id
    and revoked_at is null
    and consumed_at is null
  returning *
    into v_proof;

  if not found then
    raise exception
      'Claim proof could not be revoked'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_haulvia_organization_id,
    'revokeProfileClaimProof',
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason,
    'profile_claim_proofs',
    v_proof.id,
    v_before,
    jsonb_build_object(
      'claimProofId', v_proof.id,
      'revokedAt', v_proof.revoked_at,
      'consumedAt', v_proof.consumed_at
    ),
    jsonb_build_object(
      'targetProfileId', v_proof.target_profile_id,
      'proofType', v_proof.proof_type
    ),
    p_correlation_id,
    p_idempotency_key
  );

  v_result := jsonb_build_object(
    'claimProofId', v_proof.id,
    'targetProfileId', v_proof.target_profile_id,
    'revokedAt', v_proof.revoked_at
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'revokeProfileClaimProof',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.revoke_profile_claim_proof(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.24 replaceProfileAuthIdentity
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.replace_profile_auth_identity(
  p_actor_profile_id uuid,
  p_haulvia_organization_id uuid,
  p_target_profile_id uuid,
  p_replacement_auth_user_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_profile haulvia.profiles%rowtype;
  v_previous_auth_user_id uuid;
  v_before jsonb;
  v_notification_id uuid;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_haulvia_organization_id is null
     or p_target_profile_id is null
     or p_replacement_auth_user_id is null
  then
    raise exception
      'Actor, Haulvia organization, target profile and replacement Auth UUID are required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'replaceProfileAuthIdentity',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = p_haulvia_organization_id
      and o.kind = 'HAULVIA'
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Auth recovery must operate inside an active Haulvia organization'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_haulvia_organization_id,
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason
  );

  select p.*
    into v_profile
  from haulvia.profiles p
  where p.id = p_target_profile_id
  for update;

  if not found then
    raise exception
      'Target profile does not exist'
      using errcode = '23503';
  end if;

  if v_profile.status <> 'ACTIVE' then
    raise exception
      'Archived profiles cannot use ordinary Auth identity recovery'
      using errcode = '42501';
  end if;

  if v_profile.auth_user_id is null
     or v_profile.auth_access_status = 'UNCLAIMED'
  then
    raise exception
      'Unclaimed profiles must use the profile-claim flow'
      using errcode = '42501';
  end if;

  if v_profile.auth_user_id = p_replacement_auth_user_id then
    raise exception
      'Replacement Auth UUID must differ from the current Auth UUID'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from haulvia.profiles p
    where p.auth_user_id = p_replacement_auth_user_id
      and p.id <> v_profile.id
  ) then
    raise exception
      'Replacement Auth UUID is already linked to another profile'
      using errcode = '23505';
  end if;

  v_previous_auth_user_id := v_profile.auth_user_id;

  v_before := jsonb_build_object(
    'profileId', v_profile.id,
    'authUserId', v_previous_auth_user_id,
    'authAccessStatus', v_profile.auth_access_status
  );

  update haulvia.profiles
  set
    auth_user_id = p_replacement_auth_user_id,
    auth_access_status = 'ACTIVE'
  where id = v_profile.id
  returning *
    into v_profile;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_haulvia_organization_id,
    'replaceProfileAuthIdentity',
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason,
    'profiles',
    v_profile.id,
    v_before,
    jsonb_build_object(
      'profileId', v_profile.id,
      'authUserId', v_profile.auth_user_id,
      'authAccessStatus', v_profile.auth_access_status
    ),
    jsonb_build_object(
      'identityReplacement', true
    ),
    p_correlation_id,
    p_idempotency_key
  );

  insert into haulvia.notification_events (
    profile_id,
    event_code,
    channel,
    template_version,
    status,
    payload,
    scheduled_at,
    idempotency_key
  )
  values (
    v_profile.id,
    'PROFILE_AUTH_IDENTITY_REPLACED',
    'IN_APP',
    'P2B_AUTH_IDENTITY_REPLACED_V1',
    'QUEUED',
    jsonb_build_object(
      'profileId', v_profile.id,
      'securitySensitive', true
    ),
    clock_timestamp(),
    v_profile.id::text || ':' || p_idempotency_key
  )
  returning id
    into v_notification_id;

  v_result := jsonb_build_object(
    'profileId', v_profile.id,
    'authAccessStatus', v_profile.auth_access_status,
    'identityReplaced', true,
    'notificationEventId', v_notification_id
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'replaceProfileAuthIdentity',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.replace_profile_auth_identity(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.25 Trusted Auth lifecycle synchronization
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.sync_profile_auth_access(
  p_auth_user_id uuid,
  p_auth_access_status haulvia.auth_access_status,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_profile haulvia.profiles%rowtype;
  v_before jsonb;
  v_audit_idempotency_key text;
  v_result jsonb;
begin
  if p_auth_user_id is null then
    raise exception
      'Auth UUID is required'
      using errcode = '22023';
  end if;

  if p_auth_access_status not in ('ACTIVE', 'DISABLED', 'DELETED') then
    raise exception
      'Trusted Auth synchronization may only set ACTIVE, DISABLED or DELETED'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_auth_request(
    p_auth_user_id,
    'syncProfileAuthAccess',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  select p.*
    into v_profile
  from haulvia.profiles p
  where p.auth_user_id = p_auth_user_id
  for update;

  if not found then
    v_audit_idempotency_key :=
      p_auth_user_id::text || ':' || p_idempotency_key;

    insert into haulvia.audit_events (
      actor_kind,
      command_name,
      entity_table,
      entity_id,
      before_value,
      after_value,
      metadata,
      correlation_id,
      idempotency_key
    )
    values (
      'SYSTEM',
      'syncProfileAuthAccess',
      'profiles',
      null,
      null,
      null,
      jsonb_build_object(
        'authUserId', p_auth_user_id,
        'requestedAuthAccessStatus', p_auth_access_status,
        'profileFound', false
      ),
      p_correlation_id,
      v_audit_idempotency_key
    );

    v_result := jsonb_build_object(
      'profileFound', false,
      'authAccessStatus', p_auth_access_status
    );

    return haulvia_command.complete_auth_request(
      p_auth_user_id,
      'syncProfileAuthAccess',
      p_idempotency_key,
      v_result
    );
  end if;

  v_before := jsonb_build_object(
    'profileId', v_profile.id,
    'authUserId', v_profile.auth_user_id,
    'authAccessStatus', v_profile.auth_access_status,
    'profileStatus', v_profile.status
  );

  update haulvia.profiles
  set auth_access_status = p_auth_access_status
  where id = v_profile.id
  returning *
    into v_profile;

  v_audit_idempotency_key :=
    p_auth_user_id::text || ':' || p_idempotency_key;

  insert into haulvia.audit_events (
    actor_kind,
    command_name,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'SYSTEM',
    'syncProfileAuthAccess',
    'profiles',
    v_profile.id,
    v_before,
    jsonb_build_object(
      'profileId', v_profile.id,
      'authUserId', v_profile.auth_user_id,
      'authAccessStatus', v_profile.auth_access_status,
      'profileStatus', v_profile.status
    ),
    jsonb_build_object(
      'providerOriginated', true
    ),
    p_correlation_id,
    v_audit_idempotency_key
  );

  v_result := jsonb_build_object(
    'profileFound', true,
    'profileId', v_profile.id,
    'profileStatus', v_profile.status,
    'authAccessStatus', v_profile.auth_access_status,
    'authorityEligible',
      (
        v_profile.status = 'ACTIVE'
        and v_profile.auth_access_status = 'ACTIVE'
      )
  );

  return haulvia_command.complete_auth_request(
    p_auth_user_id,
    'syncProfileAuthAccess',
    p_idempotency_key,
    v_result
  );
end;
$$;

comment on function haulvia_command.sync_profile_auth_access(
  uuid,
  haulvia.auth_access_status,
  text,
  text,
  uuid
) is
  'Trusted backend synchronization of external Auth disable/delete/reinstatement state. Not an end-user command.';

revoke all
on function haulvia_command.sync_profile_auth_access(
  uuid,
  haulvia.auth_access_status,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B Part 6 ends here.
-- Final security hardening and migration close follow in Part 7.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.26 Auth identity-recovery proof
-- -----------------------------------------------------------------------------

create table haulvia.profile_auth_recovery_proofs (
  id uuid primary key default gen_random_uuid(),

  target_profile_id uuid not null
    references haulvia.profiles(id),

  replacement_auth_user_id uuid not null,

  haulvia_organization_id uuid not null
    references haulvia.organizations(id),

  created_by_profile_id uuid not null
    references haulvia.profiles(id),

  verification_reference_hash text not null,

  expires_at timestamptz not null,

  revoked_at timestamptz,

  consumed_at timestamptz,

  consumed_by_profile_id uuid
    references haulvia.profiles(id),

  correlation_id uuid,

  creation_idempotency_key text not null,

  created_at timestamptz not null default clock_timestamp(),

  check (
    verification_reference_hash ~ '^[0-9a-fA-F]{64}$'
  ),

  check (
    expires_at > created_at
  ),

  check (
    revoked_at is null
    or revoked_at >= created_at
  ),

  check (
    consumed_at is null
    or consumed_at >= created_at
  ),

  check (
    consumed_at is null
    or consumed_at <= expires_at
  ),

  check (
    (consumed_at is null and consumed_by_profile_id is null)
    or
    (consumed_at is not null and consumed_by_profile_id is not null)
  ),

  check (
    not (
      revoked_at is not null
      and consumed_at is not null
    )
  )
);

comment on table haulvia.profile_auth_recovery_proofs is
  'Single-use evidence that an approved identity-recovery procedure was completed before replacing a profile external Auth UUID.';

comment on column haulvia.profile_auth_recovery_proofs.verification_reference_hash is
  'SHA-256 digest of an approved external/internal recovery verification reference. Raw recovery evidence or secrets are not stored here.';

create index profile_auth_recovery_proofs_target_idx
  on haulvia.profile_auth_recovery_proofs (
    target_profile_id,
    created_at desc
  );

create index profile_auth_recovery_proofs_replacement_idx
  on haulvia.profile_auth_recovery_proofs (
    replacement_auth_user_id,
    created_at desc
  );

create trigger profile_auth_recovery_proofs_reject_delete
before delete on haulvia.profile_auth_recovery_proofs
for each row
execute function haulvia.reject_delete();

create or replace function haulvia.guard_profile_auth_recovery_proof_update()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.target_profile_id is distinct from old.target_profile_id
     or new.replacement_auth_user_id is distinct from old.replacement_auth_user_id
     or new.haulvia_organization_id is distinct from old.haulvia_organization_id
     or new.created_by_profile_id is distinct from old.created_by_profile_id
     or new.verification_reference_hash is distinct from old.verification_reference_hash
     or new.expires_at is distinct from old.expires_at
     or new.correlation_id is distinct from old.correlation_id
     or new.creation_idempotency_key is distinct from old.creation_idempotency_key
     or new.created_at is distinct from old.created_at
  then
    raise exception
      'Auth recovery proof immutable fields cannot be changed after creation'
      using errcode = '55000';
  end if;

  if old.revoked_at is not null
     and new.revoked_at is distinct from old.revoked_at
  then
    raise exception
      'Auth recovery proof revocation is irreversible'
      using errcode = '55000';
  end if;

  if old.consumed_at is not null
     and (
       new.consumed_at is distinct from old.consumed_at
       or new.consumed_by_profile_id is distinct from old.consumed_by_profile_id
     )
  then
    raise exception
      'Auth recovery proof consumption is irreversible'
      using errcode = '55000';
  end if;

  return new;
end;
$$;

create trigger profile_auth_recovery_proofs_guard_update
before update on haulvia.profile_auth_recovery_proofs
for each row
execute function haulvia.guard_profile_auth_recovery_proof_update();

revoke all
on function haulvia.guard_profile_auth_recovery_proof_update()
from public;

-- -----------------------------------------------------------------------------
-- P2B.27 issueProfileAuthRecoveryProof
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.issue_profile_auth_recovery_proof(
  p_actor_profile_id uuid,
  p_haulvia_organization_id uuid,
  p_target_profile_id uuid,
  p_replacement_auth_user_id uuid,
  p_verification_reference_hash text,
  p_expires_at timestamptz,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_target_profile haulvia.profiles%rowtype;
  v_proof haulvia.profile_auth_recovery_proofs%rowtype;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_haulvia_organization_id is null
     or p_target_profile_id is null
     or p_replacement_auth_user_id is null
  then
    raise exception
      'Actor, Haulvia organization, target profile and replacement Auth UUID are required'
      using errcode = '22023';
  end if;

  if p_verification_reference_hash is null
     or p_verification_reference_hash !~ '^[0-9a-fA-F]{64}$'
  then
    raise exception
      'A valid SHA-256 recovery verification-reference digest is required'
      using errcode = '22023';
  end if;

  if p_expires_at is null
     or p_expires_at <= clock_timestamp()
  then
    raise exception
      'Recovery proof expiry must be in the future'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'issueProfileAuthRecoveryProof',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = p_haulvia_organization_id
      and o.kind = 'HAULVIA'
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Auth recovery proof must be issued inside an active Haulvia organization'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_haulvia_organization_id,
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason
  );

  select p.*
    into v_target_profile
  from haulvia.profiles p
  where p.id = p_target_profile_id
  for update;

  if not found then
    raise exception
      'Target profile does not exist'
      using errcode = '23503';
  end if;

  if v_target_profile.status <> 'ACTIVE' then
    raise exception
      'Archived profiles are not eligible for ordinary Auth recovery'
      using errcode = '42501';
  end if;

  if v_target_profile.auth_user_id is null
     or v_target_profile.auth_access_status = 'UNCLAIMED'
  then
    raise exception
      'Unclaimed profiles must use the profile-claim flow'
      using errcode = '42501';
  end if;

  if v_target_profile.auth_user_id = p_replacement_auth_user_id then
    raise exception
      'Replacement Auth UUID must differ from the current Auth UUID'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from haulvia.profiles p
    where p.auth_user_id = p_replacement_auth_user_id
      and p.id <> v_target_profile.id
  ) then
    raise exception
      'Replacement Auth UUID is already linked to another profile'
      using errcode = '23505';
  end if;

  insert into haulvia.profile_auth_recovery_proofs (
    target_profile_id,
    replacement_auth_user_id,
    haulvia_organization_id,
    created_by_profile_id,
    verification_reference_hash,
    expires_at,
    correlation_id,
    creation_idempotency_key
  )
  values (
    p_target_profile_id,
    p_replacement_auth_user_id,
    p_haulvia_organization_id,
    p_actor_profile_id,
    lower(p_verification_reference_hash),
    p_expires_at,
    p_correlation_id,
    p_idempotency_key
  )
  returning *
    into v_proof;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_haulvia_organization_id,
    'issueProfileAuthRecoveryProof',
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason,
    'profile_auth_recovery_proofs',
    v_proof.id,
    null,
    jsonb_build_object(
      'recoveryProofId', v_proof.id,
      'targetProfileId', v_proof.target_profile_id,
      'replacementAuthUserId', v_proof.replacement_auth_user_id,
      'expiresAt', v_proof.expires_at
    ),
    jsonb_build_object(
      'identityRecoveryVerified', true
    ),
    p_correlation_id,
    p_idempotency_key
  );

  v_result := jsonb_build_object(
    'recoveryProofId', v_proof.id,
    'targetProfileId', v_proof.target_profile_id,
    'expiresAt', v_proof.expires_at
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'issueProfileAuthRecoveryProof',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.issue_profile_auth_recovery_proof(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  timestamptz,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.28 revokeProfileAuthRecoveryProof
-- -----------------------------------------------------------------------------

create or replace function haulvia_command.revoke_profile_auth_recovery_proof(
  p_actor_profile_id uuid,
  p_haulvia_organization_id uuid,
  p_recovery_proof_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_proof haulvia.profile_auth_recovery_proofs%rowtype;
  v_before jsonb;
  v_result jsonb;
begin
  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'revokeProfileAuthRecoveryProof',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = p_haulvia_organization_id
      and o.kind = 'HAULVIA'
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Recovery proof revocation must operate inside an active Haulvia organization'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_haulvia_organization_id,
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason
  );

  select prp.*
    into v_proof
  from haulvia.profile_auth_recovery_proofs prp
  where prp.id = p_recovery_proof_id
  for update;

  if not found then
    raise exception
      'Auth recovery proof does not exist'
      using errcode = '23503';
  end if;

  if v_proof.haulvia_organization_id <> p_haulvia_organization_id then
    raise exception
      'Auth recovery proof belongs to another Haulvia organization'
      using errcode = '42501';
  end if;

  if v_proof.consumed_at is not null then
    raise exception
      'A consumed Auth recovery proof cannot be revoked'
      using errcode = '55000';
  end if;

  if v_proof.revoked_at is not null then
    raise exception
      'Auth recovery proof has already been revoked'
      using errcode = '55000';
  end if;

  v_before := jsonb_build_object(
    'recoveryProofId', v_proof.id,
    'revokedAt', v_proof.revoked_at,
    'consumedAt', v_proof.consumed_at
  );

  update haulvia.profile_auth_recovery_proofs
  set revoked_at = clock_timestamp()
  where id = v_proof.id
    and revoked_at is null
    and consumed_at is null
  returning *
    into v_proof;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_haulvia_organization_id,
    'revokeProfileAuthRecoveryProof',
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason,
    'profile_auth_recovery_proofs',
    v_proof.id,
    v_before,
    jsonb_build_object(
      'recoveryProofId', v_proof.id,
      'revokedAt', v_proof.revoked_at,
      'consumedAt', v_proof.consumed_at
    ),
    jsonb_build_object(
      'targetProfileId', v_proof.target_profile_id
    ),
    p_correlation_id,
    p_idempotency_key
  );

  v_result := jsonb_build_object(
    'recoveryProofId', v_proof.id,
    'targetProfileId', v_proof.target_profile_id,
    'revokedAt', v_proof.revoked_at
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'revokeProfileAuthRecoveryProof',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.revoke_profile_auth_recovery_proof(
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B.29 Replace Part 6 identity-recovery function with proof-gated version
-- -----------------------------------------------------------------------------

drop function haulvia_command.replace_profile_auth_identity(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
);

create or replace function haulvia_command.replace_profile_auth_identity(
  p_actor_profile_id uuid,
  p_haulvia_organization_id uuid,
  p_target_profile_id uuid,
  p_replacement_auth_user_id uuid,
  p_recovery_proof_id uuid,
  p_reauth_session_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_request_hash text,
  p_correlation_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = haulvia, haulvia_command, pg_temp
as $$
declare
  v_replay jsonb;
  v_profile haulvia.profiles%rowtype;
  v_proof haulvia.profile_auth_recovery_proofs%rowtype;
  v_previous_auth_user_id uuid;
  v_before jsonb;
  v_notification_id uuid;
  v_result jsonb;
begin
  if p_actor_profile_id is null
     or p_haulvia_organization_id is null
     or p_target_profile_id is null
     or p_replacement_auth_user_id is null
     or p_recovery_proof_id is null
  then
    raise exception
      'Actor, Haulvia organization, target profile, replacement Auth UUID and recovery proof are required'
      using errcode = '22023';
  end if;

  v_replay := haulvia_command.begin_request(
    p_actor_profile_id,
    'replaceProfileAuthIdentity',
    p_idempotency_key,
    p_request_hash
  );

  if v_replay is not null then
    return v_replay;
  end if;

  if not exists (
    select 1
    from haulvia.organizations o
    where o.id = p_haulvia_organization_id
      and o.kind = 'HAULVIA'
      and o.status = 'ACTIVE'
  ) then
    raise exception
      'Auth recovery must operate inside an active Haulvia organization'
      using errcode = '42501';
  end if;

  perform haulvia.assert_sensitive_authority(
    p_actor_profile_id,
    p_haulvia_organization_id,
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason
  );

  select prp.*
    into v_proof
  from haulvia.profile_auth_recovery_proofs prp
  where prp.id = p_recovery_proof_id
  for update;

  if not found then
    raise exception
      'Auth recovery proof does not exist'
      using errcode = '42501';
  end if;

  if v_proof.haulvia_organization_id <> p_haulvia_organization_id
     or v_proof.target_profile_id <> p_target_profile_id
     or v_proof.replacement_auth_user_id <> p_replacement_auth_user_id
  then
    raise exception
      'Auth recovery proof does not match the requested identity replacement'
      using errcode = '42501';
  end if;

  if v_proof.revoked_at is not null then
    raise exception
      'Auth recovery proof has been revoked'
      using errcode = '42501';
  end if;

  if v_proof.consumed_at is not null then
    raise exception
      'Auth recovery proof has already been consumed'
      using errcode = '42501';
  end if;

  if v_proof.expires_at <= clock_timestamp() then
    raise exception
      'Auth recovery proof has expired'
      using errcode = '42501';
  end if;

  select p.*
    into v_profile
  from haulvia.profiles p
  where p.id = p_target_profile_id
  for update;

  if not found then
    raise exception
      'Target profile does not exist'
      using errcode = '23503';
  end if;

  if v_profile.status <> 'ACTIVE' then
    raise exception
      'Archived profiles cannot use ordinary Auth identity recovery'
      using errcode = '42501';
  end if;

  if v_profile.auth_user_id is null
     or v_profile.auth_access_status = 'UNCLAIMED'
  then
    raise exception
      'Unclaimed profiles must use the profile-claim flow'
      using errcode = '42501';
  end if;

  if v_profile.auth_user_id = p_replacement_auth_user_id then
    raise exception
      'Replacement Auth UUID must differ from current Auth UUID'
      using errcode = '22023';
  end if;

  if exists (
    select 1
    from haulvia.profiles p
    where p.auth_user_id = p_replacement_auth_user_id
      and p.id <> v_profile.id
  ) then
    raise exception
      'Replacement Auth UUID is already linked to another profile'
      using errcode = '23505';
  end if;

  v_previous_auth_user_id := v_profile.auth_user_id;

  v_before := jsonb_build_object(
    'profileId', v_profile.id,
    'authUserId', v_previous_auth_user_id,
    'authAccessStatus', v_profile.auth_access_status
  );

  update haulvia.profiles
  set
    auth_user_id = p_replacement_auth_user_id,
    auth_access_status = 'ACTIVE'
  where id = v_profile.id
  returning *
    into v_profile;

  update haulvia.profile_auth_recovery_proofs
  set
    consumed_at = clock_timestamp(),
    consumed_by_profile_id = p_actor_profile_id
  where id = v_proof.id
    and consumed_at is null
    and revoked_at is null;

  if not found then
    raise exception
      'Auth recovery proof could not be consumed'
      using errcode = '40001';
  end if;

  insert into haulvia.audit_events (
    actor_kind,
    actor_profile_id,
    organization_id,
    command_name,
    authority_code,
    reauth_session_id,
    reason,
    entity_table,
    entity_id,
    before_value,
    after_value,
    metadata,
    correlation_id,
    idempotency_key
  )
  values (
    'PROFILE',
    p_actor_profile_id,
    p_haulvia_organization_id,
    'replaceProfileAuthIdentity',
    'SECURITY_ACCESS_REVIEW',
    p_reauth_session_id,
    p_reason,
    'profiles',
    v_profile.id,
    v_before,
    jsonb_build_object(
      'profileId', v_profile.id,
      'authUserId', v_profile.auth_user_id,
      'authAccessStatus', v_profile.auth_access_status
    ),
    jsonb_build_object(
      'identityReplacement', true,
      'recoveryProofId', v_proof.id
    ),
    p_correlation_id,
    p_idempotency_key
  );

  insert into haulvia.notification_events (
    profile_id,
    event_code,
    channel,
    template_version,
    status,
    payload,
    scheduled_at,
    idempotency_key
  )
  values (
    v_profile.id,
    'PROFILE_AUTH_IDENTITY_REPLACED',
    'IN_APP',
    'P2B_AUTH_IDENTITY_REPLACED_V1',
    'QUEUED',
    jsonb_build_object(
      'profileId', v_profile.id,
      'securitySensitive', true
    ),
    clock_timestamp(),
    v_profile.id::text || ':' || p_idempotency_key
  )
  returning id
    into v_notification_id;

  v_result := jsonb_build_object(
    'profileId', v_profile.id,
    'authAccessStatus', v_profile.auth_access_status,
    'identityReplaced', true,
    'recoveryProofId', v_proof.id,
    'notificationEventId', v_notification_id
  );

  return haulvia_command.complete_request(
    p_actor_profile_id,
    'replaceProfileAuthIdentity',
    p_idempotency_key,
    v_result
  );
end;
$$;

revoke all
on function haulvia_command.replace_profile_auth_identity(
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  uuid,
  text,
  text,
  text,
  uuid
)
from public;

-- -----------------------------------------------------------------------------
-- P2B Part 7 ends here.
-- Final grants/security review and migration close follow in Part 8.
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
-- P2B.30 Final security boundary
-- -----------------------------------------------------------------------------

-- P2B remains service-only until the hosted Auth/RLS integration phase.
-- These explicit revocations supplement the per-function revocations above.

revoke all
on table haulvia.organization_invitations
from public;

revoke all
on table haulvia.organization_invitation_roles
from public;

revoke all
on table haulvia.profile_claim_proofs
from public;

revoke all
on table haulvia.profile_auth_recovery_proofs
from public;

do $$
begin
  if exists (
    select 1
    from pg_roles
    where rolname = 'anon'
  ) then
    execute 'revoke all on table haulvia.organization_invitations from anon';
    execute 'revoke all on table haulvia.organization_invitation_roles from anon';
    execute 'revoke all on table haulvia.profile_claim_proofs from anon';
    execute 'revoke all on table haulvia.profile_auth_recovery_proofs from anon';
  end if;

  if exists (
    select 1
    from pg_roles
    where rolname = 'authenticated'
  ) then
    execute 'revoke all on table haulvia.organization_invitations from authenticated';
    execute 'revoke all on table haulvia.organization_invitation_roles from authenticated';
    execute 'revoke all on table haulvia.profile_claim_proofs from authenticated';
    execute 'revoke all on table haulvia.profile_auth_recovery_proofs from authenticated';
  end if;
end;
$$;

comment on schema haulvia_command is
  'Trusted Haulvia command layer. P2B Auth/profile commands remain backend-only until reviewed hosted Auth/RLS integration.';

-- -----------------------------------------------------------------------------
-- P2B.31 Contract boundary
-- -----------------------------------------------------------------------------

comment on table haulvia.organization_invitations is
  'P2B organization invitation authority. Contract SHA-256: b31b46143d3371a92c11d0076ef4e3691b04c30411468794a4db7576e5780f16';

comment on table haulvia.profile_claim_proofs is
  'P2B secure existing-profile claim authority. Contract SHA-256: b31b46143d3371a92c11d0076ef4e3691b04c30411468794a4db7576e5780f16';

comment on table haulvia.profile_auth_recovery_proofs is
  'P2B privileged Auth-identity recovery evidence. Contract SHA-256: b31b46143d3371a92c11d0076ef4e3691b04c30411468794a4db7576e5780f16';

-- -----------------------------------------------------------------------------
-- End Haulvia Phase 2 Block P2B
-- -----------------------------------------------------------------------------

commit;