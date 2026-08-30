-- Haulvia database foundation v1
-- Approved source baseline: Policy Decision Register v1.1 and State Transition Matrix v1.1
-- Target: PostgreSQL 16; compatible with Supabase Postgres
-- Scope: relational foundation, invariants, history, snapshots, and ERD-facing foreign keys
-- Note: authorization policies/RLS belong in a follow-up migration after API actor rules are approved.

begin;

create schema if not exists haulvia;
set local search_path = haulvia, public;

-- -----------------------------------------------------------------------------
-- Stable code values
-- -----------------------------------------------------------------------------

create type organization_kind as enum (
  'CUSTOMER', 'INDEPENDENT_PROVIDER', 'COURIER_PARTNER', 'HAULVIA'
);

create type membership_status as enum ('INVITED', 'ACTIVE', 'SUSPENDED', 'ENDED');
create type reauth_method as enum ('PASSWORD', 'PASSKEY', 'MFA');
create type actor_kind as enum ('SYSTEM', 'PROFILE', 'SERVICE_PROVIDER', 'EXTERNAL_RECEIVER');
create type provider_kind as enum ('INDEPENDENT_DRIVER', 'COURIER_PARTNER');
create type provider_status as enum ('PENDING', 'ACTIVE', 'SUSPENDED', 'INACTIVE');
create type asset_status as enum ('PENDING', 'ACTIVE', 'SUSPENDED', 'RETIRED');
create type application_status as enum (
  'DRAFT', 'SUBMITTED', 'REVIEWING', 'NEEDS_MORE_INFO', 'APPROVED', 'REJECTED', 'WITHDRAWN'
);
create type record_status as enum ('ACTIVE', 'ARCHIVED');
create type compliance_subject_kind as enum ('APPLICATION', 'PROVIDER', 'DRIVER', 'VEHICLE');
create type compliance_review_status as enum (
  'CLAIMED', 'UNDER_REVIEW', 'NEEDS_INFO', 'VERIFIED', 'REJECTED', 'EXPIRED', 'REVOKED'
);
create type compliance_applicability as enum ('APPLICABLE', 'NOT_APPLICABLE');
create type compliance_document_status as enum ('SUBMITTED', 'ACCEPTED', 'REJECTED', 'SUPERSEDED');

create type shipment_state as enum (
  'DRAFT', 'POSTED', 'NEGOTIATING', 'DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS',
  'DELIVERED', 'COMPLETED', 'CANCELLED', 'EXPIRED', 'RETURNED_TO_SENDER'
);
create type pickup_timing_type as enum ('ASAP', 'SCHEDULED');
create type service_level as enum ('FLEX', 'EXPEDITED');
create type marketplace_state as enum ('INACTIVE', 'ACTIVE', 'PAUSED', 'RESERVED', 'CLOSED', 'EXPIRED');
create type customer_payment_state as enum (
  'UNFUNDED', 'METHOD_VERIFIED', 'AUTHORIZING', 'SECURED', 'FAILED',
  'RELEASED', 'PARTIALLY_REFUNDED', 'REFUNDED', 'CHARGEBACK'
);
create type driver_payout_state as enum ('NOT_READY', 'READY', 'HELD', 'PROCESSING', 'PAID', 'FAILED', 'CANCELLED');
create type dispute_axis_state as enum ('NONE', 'OPEN', 'EVIDENCE_COLLECTION', 'UNDER_REVIEW', 'RESOLVED');
create type workflow_axis as enum (
  'SHIPMENT', 'MARKETPLACE', 'CUSTOMER_PAYMENT', 'ROUTE_EXECUTION',
  'DRIVER_PAYOUT', 'DISPUTE', 'DELIVERY_VERIFICATION', 'WORKFLOW_HOLD'
);

create type route_version_status as enum ('DRAFT', 'ACTIVE', 'SUPERSEDED', 'FROZEN');
create type route_execution_kind as enum ('PRIMARY', 'AMENDMENT', 'RECOVERY', 'RETURN', 'REDELIVERY');
create type route_execution_state as enum ('NOT_STARTED', 'ACTIVE', 'HELD', 'RECOVERY_ACTIVE', 'COMPLETED', 'CANCELLED');
create type stop_type as enum ('PICKUP', 'DELIVERY', 'RETURN', 'STORAGE', 'TRANSFER');
create type stop_state as enum (
  'PENDING', 'EN_ROUTE', 'ARRIVED', 'SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING',
  'COMPLETED', 'FAILED', 'EXCEPTION_REVIEW', 'SKIPPED', 'CANCELLED'
);
create type delivery_verification_state as enum (
  'NOT_REQUIRED', 'PENDING_RECEIVER_CONFIRMATION', 'RECEIVER_CONFIRMED',
  'VERIFIED_BY_PROOF_OF_DROP', 'ISSUE_REPORTED', 'EXCEPTION_REVIEW'
);
create type evidence_review_status as enum ('PENDING', 'VERIFIED', 'REJECTED', 'NEEDS_INFO');
create type evidence_type as enum (
  'PHOTO', 'SIGNATURE', 'PIN', 'QR', 'GPS', 'TIMESTAMP', 'CONTACT_ATTEMPT',
  'QUANTITY', 'CONDITION', 'IDENTIFIER', 'SEAL', 'SECUREMENT', 'NOTE', 'OTHER'
);
create type cargo_movement_type as enum (
  'LOAD', 'UNLOAD', 'TRANSFER_IN', 'TRANSFER_OUT', 'STORAGE_IN', 'STORAGE_OUT'
);
create type exception_status as enum ('OPEN', 'UNDER_REVIEW', 'ACTION_REQUIRED', 'RESOLVED', 'CLOSED');
create type hold_status as enum ('ACTIVE', 'RELEASED', 'EXPIRED');
create type transfer_status as enum ('PENDING', 'VERIFIED', 'REJECTED', 'CANCELLED');

create type pricing_source as enum ('HAULVIA_GUARDRAIL', 'HAULVIA_FIXED', 'PARTNER_RATE_CARD');
create type partner_pricing_mode as enum ('NOT_APPLICABLE', 'FLEX_NEGOTIABLE', 'FLEX_FIRM', 'EXPEDITED_FIRM');
create type publication_status as enum ('DRAFT', 'PENDING_REVIEW', 'APPROVED', 'REJECTED', 'SUPERSEDED', 'EXPIRED');
create type pricing_review_status as enum ('PENDING', 'PASSED', 'NEEDS_REVIEW', 'APPROVED', 'REJECTED', 'EXPIRED');
create type price_snapshot_purpose as enum ('POSTING', 'OFFER', 'RESERVATION', 'ASSIGNMENT', 'ADJUSTMENT');
create type rate_component_type as enum (
  'BASE', 'DISTANCE', 'DURATION', 'STOP', 'WAITING', 'SURCHARGE', 'MINIMUM', 'MAXIMUM', 'TAX'
);
create type offer_status as enum (
  'ACTIVE', 'RECONFIRMATION_REQUIRED', 'RESERVED', 'ACCEPTED',
  'DECLINED', 'WITHDRAWN', 'EXPIRED', 'CLOSED'
);
create type offer_revision_kind as enum (
  'INITIAL', 'CUSTOMER_COUNTER', 'PROVIDER_REVISION', 'FIRM_MATCH', 'RECONFIRMATION'
);
create type proposal_actor_kind as enum ('CUSTOMER', 'PROVIDER', 'SYSTEM');
create type reservation_status as enum ('ACTIVE', 'RELEASED', 'CONVERTED', 'EXPIRED');
create type assignment_status as enum ('ACTIVE', 'COMPLETED', 'CANCELLED', 'TRANSFERRED', 'REPLACED');

create type payment_intent_status as enum (
  'CREATED', 'AUTHORIZING', 'SECURED', 'FAILED', 'TIMED_OUT', 'VOIDED', 'REFUNDED'
);
create type payment_transaction_type as enum (
  'AUTHORIZE', 'CAPTURE', 'VOID', 'REFUND', 'ADJUSTMENT', 'CHARGEBACK', 'CHARGEBACK_REVERSAL'
);
create type transaction_status as enum ('PENDING', 'SUCCEEDED', 'FAILED', 'CANCELLED');
create type financial_adjustment_type as enum ('CUSTOMER_CHARGE', 'CUSTOMER_REFUND', 'CUSTOMER_CREDIT', 'DRIVER_COMPENSATION');
create type dispute_status as enum ('OPEN', 'EVIDENCE_COLLECTION', 'UNDER_REVIEW', 'RESOLVED', 'CLOSED');
create type claim_status as enum ('OPEN', 'EVIDENCE_COLLECTION', 'UNDER_REVIEW', 'APPROVED', 'DENIED', 'SETTLED', 'CLOSED');
create type notification_status as enum ('QUEUED', 'SENT', 'DELIVERED', 'FAILED', 'SUPPRESSED');
create type tracking_source as enum ('DEVICE', 'SERVER', 'ADMIN', 'PARTNER_API');

-- -----------------------------------------------------------------------------
-- Shared helpers, identity, authority, reauthentication, and audit
-- -----------------------------------------------------------------------------

create or replace function touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create or replace function reject_append_only_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception '% is append-only; write a correcting or superseding record instead', tg_table_name
    using errcode = '55000';
end;
$$;

create or replace function reject_delete()
returns trigger
language plpgsql
as $$
begin
  raise exception '% records are retained and cannot be deleted', tg_table_name
    using errcode = '55000';
end;
$$;

create table organizations (
  id uuid primary key default gen_random_uuid(),
  organization_key text not null unique,
  kind organization_kind not null,
  legal_name text not null,
  display_name text not null,
  country_code char(2) not null default 'CA',
  status record_status not null default 'ACTIVE',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (organization_key = lower(organization_key)),
  check (country_code ~ '^[A-Z]{2}$')
);

create table profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  display_name text not null,
  preferred_locale text not null default 'en-CA',
  status record_status not null default 'ACTIVE',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table organization_memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id),
  profile_id uuid not null references profiles(id),
  status membership_status not null default 'INVITED',
  starts_at timestamptz not null default clock_timestamp(),
  ends_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (organization_id, profile_id),
  check (ends_at is null or ends_at > starts_at)
);

create table roles (
  id uuid primary key default gen_random_uuid(),
  role_key text not null unique,
  name text not null,
  description text,
  created_at timestamptz not null default clock_timestamp(),
  check (role_key = upper(role_key))
);

create table permissions (
  id uuid primary key default gen_random_uuid(),
  permission_key text not null unique,
  description text not null,
  is_sensitive boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  check (permission_key = upper(permission_key))
);

create table role_permissions (
  role_id uuid not null references roles(id),
  permission_id uuid not null references permissions(id),
  created_at timestamptz not null default clock_timestamp(),
  primary key (role_id, permission_id)
);

create table membership_roles (
  membership_id uuid not null references organization_memberships(id),
  role_id uuid not null references roles(id),
  granted_by_profile_id uuid references profiles(id),
  granted_at timestamptz not null default clock_timestamp(),
  primary key (membership_id, role_id)
);

create table reauth_sessions (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id),
  organization_id uuid references organizations(id),
  method reauth_method not null,
  verified_at timestamptz not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  provider_reference text,
  created_at timestamptz not null default clock_timestamp(),
  check (expires_at > verified_at),
  check (revoked_at is null or revoked_at >= verified_at)
);

create table audit_events (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default clock_timestamp(),
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  actor_provider_id uuid,
  organization_id uuid references organizations(id),
  command_name text not null,
  authority_code text,
  reauth_session_id uuid references reauth_sessions(id),
  reason text,
  entity_schema text not null default 'haulvia',
  entity_table text not null,
  entity_id uuid,
  before_value jsonb,
  after_value jsonb,
  metadata jsonb not null default '{}'::jsonb,
  correlation_id uuid,
  idempotency_key text,
  check (
    (actor_kind = 'PROFILE' and actor_profile_id is not null)
    or actor_kind <> 'PROFILE'
  ),
  check (reason is null or length(btrim(reason)) >= 3)
);

create unique index audit_events_idempotency_uq
  on audit_events (command_name, idempotency_key)
  where idempotency_key is not null;
create index audit_events_entity_idx on audit_events (entity_table, entity_id, occurred_at desc);
create index audit_events_actor_idx on audit_events (actor_profile_id, occurred_at desc);

create table command_idempotency (
  id uuid primary key default gen_random_uuid(),
  actor_profile_id uuid references profiles(id),
  command_name text not null,
  idempotency_key text not null,
  request_hash text not null,
  status text not null default 'STARTED' check (status in ('STARTED', 'COMPLETED', 'FAILED')),
  result jsonb,
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  unique (actor_profile_id, command_name, idempotency_key),
  check (request_hash ~ '^[0-9a-fA-F]{64}$'),
  check (
    (status = 'STARTED' and completed_at is null)
    or (status in ('COMPLETED', 'FAILED') and completed_at is not null)
  )
);

-- -----------------------------------------------------------------------------
-- Provider onboarding, people/assets, and compliance
-- -----------------------------------------------------------------------------

create table provider_applications (
  id uuid primary key default gen_random_uuid(),
  applicant_organization_id uuid not null references organizations(id),
  provider_kind provider_kind not null,
  status application_status not null default 'DRAFT',
  submitted_at timestamptz,
  first_meaningful_action_at timestamptz,
  reviewed_by_profile_id uuid references profiles(id),
  reviewed_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (reviewed_at is null or reviewed_by_profile_id is not null)
);

create table provider_application_events (
  id uuid primary key default gen_random_uuid(),
  application_id uuid not null references provider_applications(id),
  prior_status application_status,
  current_status application_status not null,
  action_name text not null,
  actor_profile_id uuid references profiles(id),
  reviewer_label text,
  note text,
  occurred_at timestamptz not null default clock_timestamp(),
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb,
  check (actor_profile_id is not null or reviewer_label is not null)
);

create unique index provider_application_events_idempotency_uq
  on provider_application_events (application_id, action_name, idempotency_key)
  where idempotency_key is not null;

create table service_providers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references organizations(id),
  application_id uuid unique references provider_applications(id),
  kind provider_kind not null,
  status provider_status not null default 'PENDING',
  approved_at timestamptz,
  suspended_at timestamptz,
  capabilities jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

alter table audit_events
  add constraint audit_events_actor_provider_fk
  foreign key (actor_provider_id) references service_providers(id);

create table drivers (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references profiles(id),
  status asset_status not null default 'PENDING',
  public_label text not null,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp()
);

create table provider_drivers (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references service_providers(id),
  driver_id uuid not null references drivers(id),
  status membership_status not null default 'INVITED',
  starts_at timestamptz not null default clock_timestamp(),
  ends_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (provider_id, driver_id),
  check (ends_at is null or ends_at > starts_at)
);

create table vehicles (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references service_providers(id),
  vehicle_key text not null,
  status asset_status not null default 'PENDING',
  vehicle_class text not null,
  plate_region text,
  plate_last4 text,
  capacity_weight_kg numeric(12,3),
  capacity_volume_m3 numeric(12,4),
  capabilities jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (provider_id, vehicle_key),
  check (capacity_weight_kg is null or capacity_weight_kg > 0),
  check (capacity_volume_m3 is null or capacity_volume_m3 > 0)
);

create table compliance_subjects (
  id uuid primary key default gen_random_uuid(),
  subject_kind compliance_subject_kind not null,
  application_id uuid references provider_applications(id),
  provider_id uuid references service_providers(id),
  driver_id uuid references drivers(id),
  vehicle_id uuid references vehicles(id),
  created_at timestamptz not null default clock_timestamp(),
  unique nulls not distinct (application_id, provider_id, driver_id, vehicle_id),
  check (num_nonnulls(application_id, provider_id, driver_id, vehicle_id) = 1),
  check (
    (subject_kind = 'APPLICATION' and application_id is not null)
    or (subject_kind = 'PROVIDER' and provider_id is not null)
    or (subject_kind = 'DRIVER' and driver_id is not null)
    or (subject_kind = 'VEHICLE' and vehicle_id is not null)
  )
);

create table compliance_requirements (
  id uuid primary key default gen_random_uuid(),
  requirement_key text not null unique,
  item_category text not null,
  compliance_code text not null unique,
  compliance_name text not null,
  related_service_code text,
  subject_kind compliance_subject_kind not null,
  default_required boolean not null default true,
  permits_not_applicable boolean not null default false,
  status record_status not null default 'ACTIVE',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (requirement_key = upper(requirement_key)),
  check (compliance_code = upper(compliance_code))
);

create table compliance_requirement_versions (
  id uuid primary key default gen_random_uuid(),
  requirement_id uuid not null references compliance_requirements(id),
  version_no integer not null check (version_no > 0),
  publication_status publication_status not null default 'DRAFT',
  effective_from timestamptz,
  effective_to timestamptz,
  applicability_rules jsonb not null default '{}'::jsonb,
  evidence_requirements jsonb not null default '{}'::jsonb,
  created_by_profile_id uuid references profiles(id),
  approved_by_profile_id uuid references profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  unique (requirement_id, version_no),
  check (effective_to is null or effective_from is null or effective_to > effective_from),
  check (approved_at is null or approved_by_profile_id is not null),
  check (
    publication_status <> 'APPROVED'
    or (effective_from is not null and approved_by_profile_id is not null and approved_at is not null)
  )
);

create table compliance_items (
  id uuid primary key default gen_random_uuid(),
  subject_id uuid not null references compliance_subjects(id),
  requirement_version_id uuid references compliance_requirement_versions(id),
  item_category text not null,
  compliance_code text not null,
  item_instance_key text not null default 'PRIMARY',
  compliance_name text not null,
  related_service_code text,
  holder_name text,
  credential_number text,
  issuing_authority text,
  issue_date date,
  effective_date date,
  expiry_date date,
  review_status compliance_review_status not null default 'CLAIMED',
  applicability compliance_applicability not null default 'APPLICABLE',
  is_required boolean not null default true,
  notes text,
  reviewed_at timestamptz,
  reviewer_profile_id uuid references profiles(id),
  reviewer_label text,
  review_action_note text,
  status record_status not null default 'ACTIVE',
  status_changed_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (expiry_date is null or effective_date is null or expiry_date >= effective_date),
  check (effective_date is null or issue_date is null or effective_date >= issue_date),
  check (applicability <> 'NOT_APPLICABLE' or is_required = false),
  check (reviewed_at is null or reviewer_label is not null or reviewer_profile_id is not null)
);

create unique index compliance_items_active_code_uq
  on compliance_items (subject_id, compliance_code, item_instance_key)
  where status = 'ACTIVE';
create index compliance_items_blocker_idx
  on compliance_items (subject_id, review_status)
  where status = 'ACTIVE' and applicability = 'APPLICABLE' and is_required;

create table compliance_documents (
  id uuid primary key default gen_random_uuid(),
  compliance_item_id uuid not null references compliance_items(id),
  version_no integer not null check (version_no > 0),
  file_name text not null,
  media_type text not null,
  storage_object_key text not null unique,
  content_sha256 text not null,
  status compliance_document_status not null default 'SUBMITTED',
  uploaded_by_profile_id uuid references profiles(id),
  uploaded_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  unique (compliance_item_id, version_no),
  check (content_sha256 ~ '^[0-9a-fA-F]{64}$')
);

create table compliance_document_reviews (
  id uuid primary key default gen_random_uuid(),
  compliance_document_id uuid not null references compliance_documents(id),
  prior_status compliance_document_status,
  current_status compliance_document_status not null,
  reviewer_profile_id uuid references profiles(id),
  reviewer_label text not null,
  note text,
  reviewed_at timestamptz not null default clock_timestamp(),
  metadata jsonb not null default '{}'::jsonb
);

create table compliance_item_history (
  id uuid primary key default gen_random_uuid(),
  compliance_item_id uuid not null references compliance_items(id),
  prior_status compliance_review_status,
  current_status compliance_review_status not null,
  reviewer_profile_id uuid references profiles(id),
  reviewer_label text not null,
  note text,
  item_metadata jsonb not null,
  occurred_at timestamptz not null default clock_timestamp()
);

create table compliance_state_transition_rules (
  from_status compliance_review_status not null,
  to_status compliance_review_status not null,
  command_name text not null,
  primary key (from_status, to_status, command_name),
  check (from_status <> to_status)
);

insert into compliance_state_transition_rules (from_status, to_status, command_name) values
  ('CLAIMED', 'UNDER_REVIEW', 'startComplianceReview'),
  ('CLAIMED', 'NEEDS_INFO', 'requestComplianceInformation'),
  ('CLAIMED', 'VERIFIED', 'verifyComplianceItem'),
  ('CLAIMED', 'REJECTED', 'rejectComplianceItem'),
  ('UNDER_REVIEW', 'NEEDS_INFO', 'requestComplianceInformation'),
  ('UNDER_REVIEW', 'VERIFIED', 'verifyComplianceItem'),
  ('UNDER_REVIEW', 'REJECTED', 'rejectComplianceItem'),
  ('NEEDS_INFO', 'UNDER_REVIEW', 'resumeComplianceReview'),
  ('NEEDS_INFO', 'VERIFIED', 'verifyComplianceItem'),
  ('NEEDS_INFO', 'REJECTED', 'rejectComplianceItem'),
  ('REJECTED', 'UNDER_REVIEW', 'reopenComplianceReview'),
  ('EXPIRED', 'UNDER_REVIEW', 'renewComplianceItem'),
  ('REVOKED', 'UNDER_REVIEW', 'reopenComplianceReview'),
  ('VERIFIED', 'EXPIRED', 'expireComplianceItem'),
  ('VERIFIED', 'REVOKED', 'revokeComplianceItem');

-- -----------------------------------------------------------------------------
-- Versioned policy and pricing sources
-- -----------------------------------------------------------------------------

create table policy_sets (
  id uuid primary key default gen_random_uuid(),
  policy_key text not null unique,
  name text not null,
  description text,
  created_at timestamptz not null default clock_timestamp(),
  check (policy_key = upper(policy_key))
);

create table policy_versions (
  id uuid primary key default gen_random_uuid(),
  policy_set_id uuid not null references policy_sets(id),
  version_no integer not null check (version_no > 0),
  publication_status publication_status not null default 'DRAFT',
  effective_from timestamptz,
  effective_to timestamptz,
  config jsonb not null,
  config_sha256 text not null,
  legal_review_required boolean not null default true,
  created_by_profile_id uuid references profiles(id),
  approved_by_profile_id uuid references profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  unique (policy_set_id, version_no),
  check (config_sha256 ~ '^[0-9a-fA-F]{64}$'),
  check (effective_to is null or effective_from is null or effective_to > effective_from),
  check (approved_at is null or approved_by_profile_id is not null),
  check (
    publication_status <> 'APPROVED'
    or (effective_from is not null and approved_by_profile_id is not null and approved_at is not null)
  )
);

create table pricing_rule_sets (
  id uuid primary key default gen_random_uuid(),
  rule_key text not null unique,
  name text not null,
  pricing_source pricing_source not null,
  service_level service_level not null,
  currency char(3) not null default 'CAD',
  created_at timestamptz not null default clock_timestamp(),
  check (pricing_source in ('HAULVIA_GUARDRAIL', 'HAULVIA_FIXED')),
  check (currency ~ '^[A-Z]{3}$')
);

create table pricing_rule_versions (
  id uuid primary key default gen_random_uuid(),
  pricing_rule_set_id uuid not null references pricing_rule_sets(id),
  version_no integer not null check (version_no > 0),
  publication_status publication_status not null default 'DRAFT',
  effective_from timestamptz,
  effective_to timestamptz,
  rule_config jsonb not null,
  rule_sha256 text not null,
  created_by_profile_id uuid references profiles(id),
  approved_by_profile_id uuid references profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  unique (pricing_rule_set_id, version_no),
  check (rule_sha256 ~ '^[0-9a-fA-F]{64}$'),
  check (effective_to is null or effective_from is null or effective_to > effective_from),
  check (approved_at is null or approved_by_profile_id is not null),
  check (
    publication_status <> 'APPROVED'
    or (effective_from is not null and approved_by_profile_id is not null and approved_at is not null)
  )
);

create table partner_rate_cards (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references service_providers(id),
  rate_card_key text not null,
  name text not null,
  service_level service_level not null,
  pricing_mode partner_pricing_mode not null,
  region_code text not null,
  vehicle_class text,
  currency char(3) not null default 'CAD',
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (provider_id, rate_card_key),
  check (currency ~ '^[A-Z]{3}$'),
  check (
    (service_level = 'FLEX' and pricing_mode in ('FLEX_NEGOTIABLE', 'FLEX_FIRM'))
    or (service_level = 'EXPEDITED' and pricing_mode = 'EXPEDITED_FIRM')
  )
);

create table partner_rate_card_versions (
  id uuid primary key default gen_random_uuid(),
  rate_card_id uuid not null references partner_rate_cards(id),
  version_no integer not null check (version_no > 0),
  publication_status publication_status not null default 'DRAFT',
  effective_from timestamptz,
  effective_to timestamptz,
  review_note text,
  source_sha256 text not null,
  created_by_profile_id uuid references profiles(id),
  approved_by_profile_id uuid references profiles(id),
  approved_at timestamptz,
  reauth_session_id uuid references reauth_sessions(id),
  created_at timestamptz not null default clock_timestamp(),
  unique (rate_card_id, version_no),
  check (source_sha256 ~ '^[0-9a-fA-F]{64}$'),
  check (effective_to is null or effective_from is null or effective_to > effective_from),
  check (approved_at is null or approved_by_profile_id is not null),
  check (
    publication_status <> 'APPROVED'
    or (
      effective_from is not null and approved_by_profile_id is not null
      and approved_at is not null and reauth_session_id is not null
      and nullif(btrim(review_note), '') is not null
    )
  )
);

create table partner_rate_card_lines (
  id uuid primary key default gen_random_uuid(),
  rate_card_version_id uuid not null references partner_rate_card_versions(id),
  line_no integer not null check (line_no > 0),
  component_type rate_component_type not null,
  label text not null,
  amount numeric(14,4) not null,
  unit text not null,
  minimum_quantity numeric(14,4),
  maximum_quantity numeric(14,4),
  conditions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  unique (rate_card_version_id, line_no),
  check (amount >= 0),
  check (minimum_quantity is null or minimum_quantity >= 0),
  check (maximum_quantity is null or maximum_quantity >= 0),
  check (maximum_quantity is null or minimum_quantity is null or maximum_quantity >= minimum_quantity)
);

-- -----------------------------------------------------------------------------
-- Shipment identity and independent current-state axes
-- -----------------------------------------------------------------------------

create table shipment_reference_counters (
  reference_date date primary key,
  last_value integer not null check (last_value > 0),
  updated_at timestamptz not null default clock_timestamp()
);

create or replace function next_shipment_reference(p_reference_date date default current_date)
returns text
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
declare
  v_value integer;
begin
  insert into shipment_reference_counters (reference_date, last_value)
  values (p_reference_date, 1)
  on conflict (reference_date)
  do update set
    last_value = shipment_reference_counters.last_value + 1,
    updated_at = clock_timestamp()
  returning last_value into v_value;

  if v_value > 9999 then
    raise exception 'Daily shipment reference capacity exceeded for %', p_reference_date
      using errcode = '22003';
  end if;

  return 'HV-' || to_char(p_reference_date, 'YYYYMMDD') || '-' || lpad(v_value::text, 4, '0');
end;
$$;

create table shipments (
  id uuid primary key default gen_random_uuid(),
  shipment_reference text not null unique default next_shipment_reference(current_date),
  customer_organization_id uuid references organizations(id),
  customer_profile_id uuid references profiles(id),
  source_shipment_id uuid references shipments(id),
  shipment_state shipment_state not null default 'DRAFT',
  pickup_timing pickup_timing_type not null,
  service_level service_level not null,
  currency char(3) not null default 'CAD',
  marketplace_deadline timestamptz,
  state_changed_at timestamptz not null default clock_timestamp(),
  terminal_at timestamptz,
  lock_version bigint not null default 0,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (id, customer_organization_id),
  check (shipment_reference ~ '^HV-[0-9]{8}-[0-9]{4}$'),
  check (num_nonnulls(customer_organization_id, customer_profile_id) >= 1),
  check (currency ~ '^[A-Z]{3}$'),
  check (
    (shipment_state in ('COMPLETED', 'CANCELLED', 'EXPIRED', 'RETURNED_TO_SENDER') and terminal_at is not null)
    or (shipment_state not in ('COMPLETED', 'CANCELLED', 'EXPIRED', 'RETURNED_TO_SENDER'))
  )
);

create index shipments_customer_org_idx on shipments (customer_organization_id, created_at desc);
create index shipments_customer_profile_idx on shipments (customer_profile_id, created_at desc);
create index shipments_state_deadline_idx on shipments (shipment_state, marketplace_deadline);

create table shipment_marketplace_axes (
  shipment_id uuid primary key references shipments(id),
  state marketplace_state not null default 'INACTIVE',
  paused_reason text,
  state_changed_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (state = 'PAUSED' or paused_reason is null)
);

create table shipment_customer_payment_axes (
  shipment_id uuid primary key references shipments(id),
  state customer_payment_state not null default 'UNFUNDED',
  secured_amount numeric(14,2) not null default 0,
  currency char(3) not null default 'CAD',
  state_changed_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (secured_amount >= 0),
  check (currency ~ '^[A-Z]{3}$')
);

create table shipment_driver_payout_axes (
  shipment_id uuid primary key references shipments(id),
  state driver_payout_state not null default 'NOT_READY',
  eligible_amount numeric(14,2) not null default 0,
  currency char(3) not null default 'CAD',
  state_changed_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (eligible_amount >= 0),
  check (currency ~ '^[A-Z]{3}$')
);

create table shipment_dispute_axes (
  shipment_id uuid primary key references shipments(id),
  state dispute_axis_state not null default 'NONE',
  open_dispute_count integer not null default 0,
  state_changed_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (open_dispute_count >= 0),
  check ((state = 'NONE' and open_dispute_count = 0) or state <> 'NONE')
);

create table shipment_state_transition_rules (
  from_state shipment_state not null,
  to_state shipment_state not null,
  command_name text not null,
  requires_zero_custody boolean not null default false,
  primary key (from_state, to_state, command_name),
  check (from_state <> to_state)
);

insert into shipment_state_transition_rules (from_state, to_state, command_name, requires_zero_custody) values
  ('DRAFT', 'POSTED', 'postShipment', false),
  ('DRAFT', 'CANCELLED', 'cancelDraft', true),
  ('POSTED', 'NEGOTIATING', 'openNegotiation', true),
  ('POSTED', 'CANCELLED', 'cancelMarketplaceShipment', true),
  ('POSTED', 'EXPIRED', 'expireListing', true),
  ('NEGOTIATING', 'POSTED', 'closeLastActiveOffer', true),
  ('NEGOTIATING', 'DRIVER_ASSIGNED', 'confirmPaidAssignment', true),
  ('NEGOTIATING', 'CANCELLED', 'cancelPreAssignment', true),
  ('NEGOTIATING', 'EXPIRED', 'expireListing', true),
  ('DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS', 'startRoute', false),
  ('DRIVER_ASSIGNED', 'CANCELLED', 'cancelAssignedBeforeCustody', true),
  ('ROUTE_IN_PROGRESS', 'POSTED', 'prepareFailedFirstPickupRepost', true),
  ('ROUTE_IN_PROGRESS', 'CANCELLED', 'closeFailedFirstPickup', true),
  ('ROUTE_IN_PROGRESS', 'DELIVERED', 'completePlannedRoute', false),
  ('ROUTE_IN_PROGRESS', 'RETURNED_TO_SENDER', 'verifyReturnHandoff', false),
  ('DELIVERED', 'COMPLETED', 'completeShipment', false);

create table shipment_state_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  prior_state shipment_state,
  current_state shipment_state not null,
  command_name text not null,
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  actor_provider_id uuid references service_providers(id),
  reason text,
  route_version_id uuid,
  occurred_at timestamptz not null default clock_timestamp(),
  correlation_id uuid,
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb
);

create unique index shipment_state_events_idempotency_uq
  on shipment_state_events (shipment_id, command_name, idempotency_key)
  where idempotency_key is not null;
create index shipment_state_events_timeline_idx
  on shipment_state_events (shipment_id, occurred_at, id);

create table workflow_axis_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  axis workflow_axis not null,
  axis_entity_id uuid,
  prior_state text,
  current_state text not null,
  command_name text not null,
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  reason text,
  occurred_at timestamptz not null default clock_timestamp(),
  correlation_id uuid,
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb
);

create unique index workflow_axis_events_idempotency_uq
  on workflow_axis_events (shipment_id, axis, command_name, idempotency_key)
  where idempotency_key is not null;
create index workflow_axis_events_timeline_idx
  on workflow_axis_events (shipment_id, axis, occurred_at, id);

create or replace function initialize_shipment_axes()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  insert into shipment_marketplace_axes (shipment_id) values (new.id);
  insert into shipment_customer_payment_axes (shipment_id, currency) values (new.id, new.currency);
  insert into shipment_driver_payout_axes (shipment_id, currency) values (new.id, new.currency);
  insert into shipment_dispute_axes (shipment_id) values (new.id);
  insert into shipment_state_events (
    shipment_id, prior_state, current_state, command_name, actor_kind, metadata
  ) values (
    new.id, null, new.shipment_state, 'createShipment', 'SYSTEM',
    jsonb_build_object('shipmentReference', new.shipment_reference)
  );
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Versioned route plans: ordered stops, cargo lines, allocations, and legs
-- -----------------------------------------------------------------------------

create table route_versions (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  version_no integer not null check (version_no > 0),
  status route_version_status not null default 'DRAFT',
  prior_route_version_id uuid references route_versions(id),
  change_reason text not null,
  planned_distance_km numeric(12,3),
  planned_duration_seconds integer,
  created_by_profile_id uuid references profiles(id),
  activated_at timestamptz,
  superseded_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, version_no),
  unique (shipment_id, id),
  check (planned_distance_km is null or planned_distance_km >= 0),
  check (planned_duration_seconds is null or planned_duration_seconds >= 0),
  check ((status = 'ACTIVE' and activated_at is not null) or status <> 'ACTIVE'),
  check ((status = 'SUPERSEDED' and superseded_at is not null) or status <> 'SUPERSEDED')
);

create unique index route_versions_one_active_uq
  on route_versions (shipment_id)
  where status = 'ACTIVE';

alter table shipment_state_events
  add constraint shipment_state_events_route_version_fk
  foreign key (route_version_id) references route_versions(id);

create table route_stops (
  id uuid primary key default gen_random_uuid(),
  route_version_id uuid not null references route_versions(id),
  stable_stop_key uuid not null default gen_random_uuid(),
  sequence_no integer not null check (sequence_no > 0),
  stop_type stop_type not null,
  address_label text,
  address_line1 text not null,
  address_line2 text,
  city text not null,
  region_code text not null,
  postal_code text,
  country_code char(2) not null default 'CA',
  latitude numeric(9,6),
  longitude numeric(9,6),
  geofence_radius_m integer,
  contact_name text,
  contact_phone text,
  contact_email text,
  service_window_start timestamptz,
  service_window_end timestamptz,
  planned_service_seconds integer not null default 0,
  instructions text,
  verification_profile jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_version_id, id),
  unique (route_version_id, sequence_no),
  unique (route_version_id, stable_stop_key),
  check (country_code ~ '^[A-Z]{2}$'),
  check (latitude is null or latitude between -90 and 90),
  check (longitude is null or longitude between -180 and 180),
  check (geofence_radius_m is null or geofence_radius_m > 0),
  check (service_window_end is null or service_window_start is null or service_window_end > service_window_start),
  check (planned_service_seconds >= 0)
);

create table route_legs (
  id uuid primary key default gen_random_uuid(),
  route_version_id uuid not null references route_versions(id),
  sequence_no integer not null check (sequence_no > 0),
  from_stop_id uuid not null,
  to_stop_id uuid not null,
  planned_distance_km numeric(12,3),
  planned_duration_seconds integer,
  route_provider_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_version_id, id),
  unique (route_version_id, sequence_no),
  foreign key (route_version_id, from_stop_id) references route_stops(route_version_id, id),
  foreign key (route_version_id, to_stop_id) references route_stops(route_version_id, id),
  check (from_stop_id <> to_stop_id),
  check (planned_distance_km is null or planned_distance_km >= 0),
  check (planned_duration_seconds is null or planned_duration_seconds >= 0)
);

create table cargo_items (
  id uuid primary key default gen_random_uuid(),
  route_version_id uuid not null references route_versions(id),
  stable_cargo_key uuid not null default gen_random_uuid(),
  cargo_line_no integer not null check (cargo_line_no > 0),
  description text not null,
  quantity numeric(14,3) not null,
  quantity_unit text not null,
  total_weight_kg numeric(14,3),
  total_volume_m3 numeric(14,4),
  declared_value numeric(14,2),
  currency char(3),
  handling_requirements jsonb not null default '{}'::jsonb,
  risk_attributes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_version_id, id),
  unique (route_version_id, cargo_line_no),
  unique (route_version_id, stable_cargo_key),
  check (quantity > 0),
  check (total_weight_kg is null or total_weight_kg > 0),
  check (total_volume_m3 is null or total_volume_m3 > 0),
  check (declared_value is null or declared_value >= 0),
  check (currency is null or currency ~ '^[A-Z]{3}$')
);

create table cargo_allocations (
  id uuid primary key default gen_random_uuid(),
  route_version_id uuid not null references route_versions(id),
  cargo_item_id uuid not null,
  pickup_stop_id uuid not null,
  delivery_stop_id uuid not null,
  quantity numeric(14,3) not null,
  quantity_unit text not null,
  allocation_note text,
  created_at timestamptz not null default clock_timestamp(),
  unique (route_version_id, id),
  unique (route_version_id, cargo_item_id, pickup_stop_id, delivery_stop_id),
  foreign key (route_version_id, cargo_item_id) references cargo_items(route_version_id, id),
  foreign key (route_version_id, pickup_stop_id) references route_stops(route_version_id, id),
  foreign key (route_version_id, delivery_stop_id) references route_stops(route_version_id, id),
  check (pickup_stop_id <> delivery_stop_id),
  check (quantity > 0)
);

-- -----------------------------------------------------------------------------
-- Per-shipment policy/pricing snapshots and marketplace negotiation
-- -----------------------------------------------------------------------------

create table shipment_rule_snapshots (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_version_id uuid not null,
  policy_version_id uuid references policy_versions(id),
  evidence_requirements jsonb not null,
  cancellation_rules jsonb not null,
  refund_rules jsonb not null,
  timing_windows jsonb not null,
  risk_rules jsonb not null,
  config_sha256 text not null,
  captured_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, route_version_id),
  foreign key (shipment_id, route_version_id) references route_versions(shipment_id, id),
  check (config_sha256 ~ '^[0-9a-fA-F]{64}$')
);

create table pricing_reviews (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_version_id uuid not null,
  pricing_source pricing_source not null,
  pricing_mode partner_pricing_mode not null default 'NOT_APPLICABLE',
  status pricing_review_status not null default 'PENDING',
  reviewed_amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  flags jsonb not null default '[]'::jsonb,
  rationale text,
  reviewed_by_profile_id uuid references profiles(id),
  reviewed_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  foreign key (shipment_id, route_version_id) references route_versions(shipment_id, id),
  check (reviewed_amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check (
    (pricing_source = 'PARTNER_RATE_CARD' and pricing_mode <> 'NOT_APPLICABLE')
    or (pricing_source <> 'PARTNER_RATE_CARD' and pricing_mode = 'NOT_APPLICABLE')
  )
);

create table shipment_price_snapshots (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_version_id uuid not null,
  purpose price_snapshot_purpose not null,
  pricing_source pricing_source not null,
  pricing_mode partner_pricing_mode not null default 'NOT_APPLICABLE',
  pricing_rule_version_id uuid references pricing_rule_versions(id),
  rate_card_version_id uuid references partner_rate_card_versions(id),
  pricing_review_id uuid references pricing_reviews(id),
  subtotal numeric(14,2) not null,
  tax_amount numeric(14,2) not null default 0,
  total_amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  breakdown jsonb not null,
  snapshot_sha256 text not null,
  accepted_at timestamptz,
  captured_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  foreign key (shipment_id, route_version_id) references route_versions(shipment_id, id),
  check (subtotal >= 0 and tax_amount >= 0 and total_amount >= 0),
  check (total_amount = subtotal + tax_amount),
  check (currency ~ '^[A-Z]{3}$'),
  check (snapshot_sha256 ~ '^[0-9a-fA-F]{64}$'),
  check (
    (pricing_source in ('HAULVIA_GUARDRAIL', 'HAULVIA_FIXED')
      and pricing_rule_version_id is not null and rate_card_version_id is null
      and pricing_mode = 'NOT_APPLICABLE')
    or
    (pricing_source = 'PARTNER_RATE_CARD'
      and pricing_rule_version_id is null and rate_card_version_id is not null
      and pricing_mode <> 'NOT_APPLICABLE')
  )
);

create index shipment_price_snapshots_route_idx
  on shipment_price_snapshots (shipment_id, route_version_id, captured_at desc);

create table offer_threads (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_version_id uuid not null,
  provider_id uuid not null references service_providers(id),
  driver_id uuid references drivers(id),
  vehicle_id uuid references vehicles(id),
  pricing_source pricing_source not null,
  pricing_mode partner_pricing_mode not null default 'NOT_APPLICABLE',
  status offer_status not null default 'ACTIVE',
  expires_at timestamptz not null,
  reconfirmation_route_version_id uuid references route_versions(id),
  closed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  foreign key (shipment_id, route_version_id) references route_versions(shipment_id, id),
  check (expires_at > created_at),
  check (
    (pricing_source = 'PARTNER_RATE_CARD' and pricing_mode <> 'NOT_APPLICABLE')
    or (pricing_source <> 'PARTNER_RATE_CARD' and pricing_mode = 'NOT_APPLICABLE')
  ),
  check ((status = 'RECONFIRMATION_REQUIRED' and reconfirmation_route_version_id is not null) or status <> 'RECONFIRMATION_REQUIRED')
);

create index offer_threads_active_idx
  on offer_threads (shipment_id, expires_at)
  where status in ('ACTIVE', 'RECONFIRMATION_REQUIRED', 'RESERVED');

create table offer_revisions (
  id uuid primary key default gen_random_uuid(),
  offer_thread_id uuid not null references offer_threads(id),
  revision_no integer not null check (revision_no > 0),
  revision_kind offer_revision_kind not null,
  proposed_by proposal_actor_kind not null,
  amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  valid_until timestamptz not null,
  response_to_revision_id uuid references offer_revisions(id),
  pricing_snapshot_id uuid not null references shipment_price_snapshots(id),
  route_version_id uuid not null references route_versions(id),
  reason text,
  created_by_profile_id uuid references profiles(id),
  created_at timestamptz not null default clock_timestamp(),
  idempotency_key text,
  unique (offer_thread_id, revision_no),
  unique (offer_thread_id, id),
  check (amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check (valid_until > created_at),
  check (
    (revision_kind = 'CUSTOMER_COUNTER' and proposed_by = 'CUSTOMER')
    or (revision_kind in ('INITIAL', 'PROVIDER_REVISION', 'RECONFIRMATION') and proposed_by in ('PROVIDER', 'SYSTEM'))
    or (revision_kind = 'FIRM_MATCH' and proposed_by in ('PROVIDER', 'SYSTEM'))
  )
);

create unique index offer_revisions_idempotency_uq
  on offer_revisions (offer_thread_id, idempotency_key)
  where idempotency_key is not null;

create table offer_reservations (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  offer_thread_id uuid not null,
  selected_revision_id uuid not null,
  status reservation_status not null default 'ACTIVE',
  reserved_by_profile_id uuid references profiles(id),
  reserved_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null,
  released_at timestamptz,
  release_reason text,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  foreign key (shipment_id, offer_thread_id) references offer_threads(shipment_id, id),
  foreign key (offer_thread_id, selected_revision_id) references offer_revisions(offer_thread_id, id),
  check (expires_at > reserved_at),
  check ((status = 'RELEASED' and released_at is not null) or status <> 'RELEASED')
);

create unique index offer_reservations_one_active_uq
  on offer_reservations (shipment_id)
  where status = 'ACTIVE';

create table assignments (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_version_id uuid not null,
  provider_id uuid not null references service_providers(id),
  driver_id uuid not null references drivers(id),
  vehicle_id uuid not null references vehicles(id),
  offer_reservation_id uuid unique,
  selected_offer_revision_id uuid references offer_revisions(id),
  price_snapshot_id uuid not null,
  status assignment_status not null default 'ACTIVE',
  agreement_snapshot jsonb not null,
  assigned_at timestamptz not null default clock_timestamp(),
  ended_at timestamptz,
  end_reason text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  foreign key (shipment_id, route_version_id) references route_versions(shipment_id, id),
  foreign key (shipment_id, offer_reservation_id) references offer_reservations(shipment_id, id),
  foreign key (shipment_id, price_snapshot_id) references shipment_price_snapshots(shipment_id, id),
  check ((status = 'ACTIVE' and ended_at is null) or status <> 'ACTIVE')
);

create unique index assignments_one_active_uq
  on assignments (shipment_id)
  where status = 'ACTIVE';

create table assignment_events (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id),
  shipment_id uuid not null references shipments(id),
  prior_status assignment_status,
  current_status assignment_status not null,
  command_name text not null,
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  reason text,
  occurred_at timestamptz not null default clock_timestamp(),
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb
);

create unique index assignment_events_idempotency_uq
  on assignment_events (assignment_id, command_name, idempotency_key)
  where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- Route execution, reusable stop loop, evidence, tracking, and custody ledger
-- -----------------------------------------------------------------------------

create table route_executions (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_version_id uuid not null,
  assignment_id uuid not null,
  parent_route_execution_id uuid references route_executions(id),
  execution_kind route_execution_kind not null default 'PRIMARY',
  state route_execution_state not null default 'NOT_STARTED',
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (id, route_version_id),
  unique (shipment_id, id),
  foreign key (shipment_id, route_version_id) references route_versions(shipment_id, id),
  foreign key (shipment_id, assignment_id) references assignments(shipment_id, id),
  check ((state in ('ACTIVE', 'RECOVERY_ACTIVE') and started_at is not null) or state not in ('ACTIVE', 'RECOVERY_ACTIVE')),
  check ((state = 'COMPLETED' and completed_at is not null) or state <> 'COMPLETED')
);

create unique index route_executions_one_moving_uq
  on route_executions (shipment_id)
  where state in ('ACTIVE', 'RECOVERY_ACTIVE');

create table stop_state_transition_rules (
  from_state stop_state not null,
  to_state stop_state not null,
  command_name text not null,
  primary key (from_state, to_state, command_name),
  check (from_state <> to_state)
);

insert into stop_state_transition_rules (from_state, to_state, command_name) values
  ('PENDING', 'EN_ROUTE', 'advanceToNextStop'),
  ('PENDING', 'SKIPPED', 'authorizeContinueAfterStopFailure'),
  ('PENDING', 'CANCELLED', 'cancelRemainingStop'),
  ('EN_ROUTE', 'ARRIVED', 'confirmArrivalAtStop'),
  ('EN_ROUTE', 'FAILED', 'reportFailedStop'),
  ('EN_ROUTE', 'EXCEPTION_REVIEW', 'reportStopException'),
  ('ARRIVED', 'EN_ROUTE', 'correctStopArrival'),
  ('ARRIVED', 'SERVICE_IN_PROGRESS', 'startStopService'),
  ('ARRIVED', 'FAILED', 'reportFailedStop'),
  ('ARRIVED', 'EXCEPTION_REVIEW', 'reportStopException'),
  ('SERVICE_IN_PROGRESS', 'EVIDENCE_PENDING', 'submitStopEvidence'),
  ('SERVICE_IN_PROGRESS', 'FAILED', 'reportFailedStop'),
  ('SERVICE_IN_PROGRESS', 'EXCEPTION_REVIEW', 'reportStopException'),
  ('EVIDENCE_PENDING', 'COMPLETED', 'verifyStop'),
  ('EVIDENCE_PENDING', 'FAILED', 'rejectStopService'),
  ('EVIDENCE_PENDING', 'EXCEPTION_REVIEW', 'reviewStopEvidence'),
  ('FAILED', 'ARRIVED', 'retryFailedStopSameDriver'),
  ('FAILED', 'EXCEPTION_REVIEW', 'reviewFailedStop'),
  ('FAILED', 'SKIPPED', 'authorizeContinueAfterStopFailure'),
  ('EXCEPTION_REVIEW', 'ARRIVED', 'resumeStopAtArrival'),
  ('EXCEPTION_REVIEW', 'SERVICE_IN_PROGRESS', 'resumeStopService'),
  ('EXCEPTION_REVIEW', 'EVIDENCE_PENDING', 'resumeEvidenceReview'),
  ('EXCEPTION_REVIEW', 'COMPLETED', 'resolveAndVerifyStop'),
  ('EXCEPTION_REVIEW', 'FAILED', 'resolveStopAsFailed'),
  ('EXCEPTION_REVIEW', 'SKIPPED', 'resolveStopAsSkipped');

create table stop_executions (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_execution_id uuid not null,
  route_version_id uuid not null,
  route_stop_id uuid not null,
  state stop_state not null default 'PENDING',
  delivery_verification_state delivery_verification_state not null default 'NOT_REQUIRED',
  current_attempt_no integer not null default 0,
  state_changed_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (route_execution_id, route_stop_id),
  unique (shipment_id, id),
  unique (id, route_execution_id, route_version_id),
  foreign key (route_execution_id, route_version_id) references route_executions(id, route_version_id),
  foreign key (shipment_id, route_execution_id) references route_executions(shipment_id, id),
  foreign key (route_version_id, route_stop_id) references route_stops(route_version_id, id),
  check (current_attempt_no >= 0),
  check ((state = 'COMPLETED' and completed_at is not null) or state <> 'COMPLETED')
);

create index stop_executions_active_idx
  on stop_executions (route_execution_id, state)
  where state not in ('COMPLETED', 'SKIPPED', 'CANCELLED');

create table stop_attempts (
  id uuid primary key default gen_random_uuid(),
  stop_execution_id uuid not null references stop_executions(id),
  attempt_no integer not null check (attempt_no > 0),
  state stop_state not null,
  arrived_at timestamptz,
  service_started_at timestamptz,
  evidence_submitted_at timestamptz,
  ended_at timestamptz,
  responsibility_code text,
  failure_reason text,
  offline_started_at timestamptz,
  synced_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (stop_execution_id, attempt_no),
  check (synced_at is null or offline_started_at is not null)
);

create table stop_attempt_events (
  id uuid primary key default gen_random_uuid(),
  stop_attempt_id uuid not null references stop_attempts(id),
  stop_execution_id uuid not null references stop_executions(id),
  prior_state stop_state,
  current_state stop_state not null,
  command_name text not null,
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  reason text,
  occurred_at timestamptz not null default clock_timestamp(),
  captured_at timestamptz,
  synced_at timestamptz,
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb,
  check (synced_at is null or captured_at is not null)
);

create unique index stop_attempt_events_idempotency_uq
  on stop_attempt_events (stop_attempt_id, command_name, idempotency_key)
  where idempotency_key is not null;

create table stop_evidence (
  id uuid primary key default gen_random_uuid(),
  stop_attempt_id uuid not null references stop_attempts(id),
  evidence_type evidence_type not null,
  storage_object_key text,
  content_sha256 text,
  structured_value jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null,
  captured_latitude numeric(9,6),
  captured_longitude numeric(9,6),
  captured_accuracy_m numeric(10,3),
  submitted_by_profile_id uuid references profiles(id),
  synced_at timestamptz,
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (stop_attempt_id, idempotency_key),
  check (storage_object_key is not null or structured_value <> '{}'::jsonb),
  check (content_sha256 is null or content_sha256 ~ '^[0-9a-fA-F]{64}$'),
  check (captured_latitude is null or captured_latitude between -90 and 90),
  check (captured_longitude is null or captured_longitude between -180 and 180),
  check (captured_accuracy_m is null or captured_accuracy_m >= 0),
  check (synced_at is null or synced_at >= captured_at)
);

create table stop_evidence_reviews (
  id uuid primary key default gen_random_uuid(),
  stop_evidence_id uuid not null references stop_evidence(id),
  status evidence_review_status not null,
  reviewer_profile_id uuid references profiles(id),
  reviewer_label text not null,
  note text,
  reviewed_at timestamptz not null default clock_timestamp(),
  metadata jsonb not null default '{}'::jsonb
);

create table stop_evidence_corrections (
  id uuid primary key default gen_random_uuid(),
  original_evidence_id uuid not null references stop_evidence(id),
  replacement_evidence_id uuid not null unique references stop_evidence(id),
  reason text not null,
  requested_by_profile_id uuid references profiles(id),
  approved_by_profile_id uuid references profiles(id),
  created_at timestamptz not null default clock_timestamp(),
  check (original_evidence_id <> replacement_evidence_id),
  check (length(btrim(reason)) >= 3)
);

create table cargo_movements (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_execution_id uuid not null,
  route_version_id uuid not null,
  stop_execution_id uuid not null,
  cargo_allocation_id uuid not null,
  movement_type cargo_movement_type not null,
  quantity numeric(14,3) not null,
  quantity_unit text not null,
  stop_attempt_id uuid references stop_attempts(id),
  evidence_bundle jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default clock_timestamp(),
  recorded_by_profile_id uuid references profiles(id),
  idempotency_key text not null,
  unique (route_execution_id, idempotency_key),
  foreign key (shipment_id, route_execution_id)
    references route_executions(shipment_id, id),
  foreign key (stop_execution_id, route_execution_id, route_version_id)
    references stop_executions(id, route_execution_id, route_version_id),
  foreign key (route_version_id, cargo_allocation_id)
    references cargo_allocations(route_version_id, id),
  check (quantity > 0)
);

create index cargo_movements_shipment_idx
  on cargo_movements (shipment_id, occurred_at, id);
create index cargo_movements_allocation_idx
  on cargo_movements (cargo_allocation_id, occurred_at, id);

create table tracking_sessions (
  id uuid primary key default gen_random_uuid(),
  route_execution_id uuid not null references route_executions(id),
  driver_id uuid not null references drivers(id),
  started_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  check (ended_at is null or ended_at >= started_at)
);

create table tracking_points (
  id bigint generated always as identity primary key,
  tracking_session_id uuid not null references tracking_sessions(id),
  source tracking_source not null,
  latitude numeric(9,6) not null,
  longitude numeric(9,6) not null,
  accuracy_m numeric(10,3),
  speed_kph numeric(10,3),
  heading_degrees numeric(6,2),
  captured_at timestamptz not null,
  synced_at timestamptz not null default clock_timestamp(),
  is_offline_capture boolean not null default false,
  check (latitude between -90 and 90),
  check (longitude between -180 and 180),
  check (accuracy_m is null or accuracy_m >= 0),
  check (speed_kph is null or speed_kph >= 0),
  check (heading_degrees is null or heading_degrees between 0 and 360),
  check (synced_at >= captured_at)
);

create index tracking_points_timeline_idx
  on tracking_points (tracking_session_id, captured_at, id);

create table route_updates (
  id uuid primary key default gen_random_uuid(),
  route_execution_id uuid not null references route_executions(id),
  active_route_leg_id uuid references route_legs(id),
  active_stop_execution_id uuid references stop_executions(id),
  eta_at timestamptz,
  dwell_seconds integer,
  delay_seconds integer,
  connectivity_status text,
  custody_summary jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null,
  synced_at timestamptz not null default clock_timestamp(),
  source tracking_source not null,
  check (dwell_seconds is null or dwell_seconds >= 0),
  check (synced_at >= captured_at)
);

create index route_updates_timeline_idx
  on route_updates (route_execution_id, captured_at, id);

create table workflow_holds (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_execution_id uuid references route_executions(id),
  stop_execution_id uuid references stop_executions(id),
  hold_code text not null,
  status hold_status not null default 'ACTIVE',
  blocks_marketplace boolean not null default false,
  blocks_route_movement boolean not null default false,
  blocks_completion boolean not null default false,
  reason text not null,
  opened_by_profile_id uuid references profiles(id),
  opened_at timestamptz not null default clock_timestamp(),
  released_by_profile_id uuid references profiles(id),
  released_at timestamptz,
  release_reason text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((status = 'RELEASED' and released_at is not null and release_reason is not null) or status <> 'RELEASED')
);

create index workflow_holds_active_idx
  on workflow_holds (shipment_id, blocks_route_movement, blocks_completion)
  where status = 'ACTIVE';

create table route_exceptions (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_execution_id uuid references route_executions(id),
  stop_execution_id uuid references stop_executions(id),
  cargo_item_id uuid references cargo_items(id),
  workflow_hold_id uuid references workflow_holds(id),
  exception_code text not null,
  status exception_status not null default 'OPEN',
  responsibility_code text,
  blocks_completion boolean not null default false,
  description text not null,
  resolution text,
  opened_by_profile_id uuid references profiles(id),
  resolved_by_profile_id uuid references profiles(id),
  opened_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check ((status in ('RESOLVED', 'CLOSED') and resolved_at is not null and resolution is not null) or status not in ('RESOLVED', 'CLOSED'))
);

create index route_exceptions_open_idx
  on route_exceptions (shipment_id, blocks_completion)
  where status not in ('RESOLVED', 'CLOSED');

create table custody_transfers (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  route_execution_id uuid not null references route_executions(id),
  from_assignment_id uuid not null references assignments(id),
  to_assignment_id uuid not null references assignments(id),
  from_driver_id uuid not null references drivers(id),
  to_driver_id uuid not null references drivers(id),
  from_vehicle_id uuid references vehicles(id),
  to_vehicle_id uuid references vehicles(id),
  status transfer_status not null default 'PENDING',
  handoff_snapshot jsonb not null,
  transferred_at timestamptz,
  verified_by_profile_id uuid references profiles(id),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (from_assignment_id <> to_assignment_id),
  check (from_driver_id <> to_driver_id),
  check ((status = 'VERIFIED' and transferred_at is not null) or status <> 'VERIFIED')
);

create table custody_transfer_items (
  custody_transfer_id uuid not null references custody_transfers(id),
  cargo_allocation_id uuid not null references cargo_allocations(id),
  quantity numeric(14,3) not null,
  quantity_unit text not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key (custody_transfer_id, cargo_allocation_id),
  check (quantity > 0)
);

-- -----------------------------------------------------------------------------
-- Customer funding, payout, holds, disputes, claims, and adjustments
-- -----------------------------------------------------------------------------

create table payment_intents (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  offer_reservation_id uuid,
  status payment_intent_status not null default 'CREATED',
  amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  external_provider text not null,
  external_reference text,
  provider_idempotency_key text not null,
  funding_deadline timestamptz,
  secured_at timestamptz,
  timed_out_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, id),
  unique (external_provider, provider_idempotency_key),
  unique nulls not distinct (external_provider, external_reference),
  foreign key (shipment_id, offer_reservation_id) references offer_reservations(shipment_id, id),
  check (amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check ((status = 'SECURED' and secured_at is not null) or status <> 'SECURED'),
  check ((status = 'TIMED_OUT' and timed_out_at is not null) or status <> 'TIMED_OUT')
);

create table payment_transactions (
  id uuid primary key default gen_random_uuid(),
  payment_intent_id uuid not null,
  shipment_id uuid not null references shipments(id),
  transaction_type payment_transaction_type not null,
  status transaction_status not null,
  amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  external_provider text not null,
  external_reference text,
  provider_event_id text,
  provider_occurred_at timestamptz,
  response_payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (payment_intent_id, idempotency_key),
  foreign key (shipment_id, payment_intent_id) references payment_intents(shipment_id, id),
  unique nulls not distinct (external_provider, provider_event_id),
  check (amount >= 0),
  check (currency ~ '^[A-Z]{3}$')
);

create table driver_payouts (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  assignment_id uuid not null,
  provider_id uuid not null references service_providers(id),
  driver_id uuid not null references drivers(id),
  state driver_payout_state not null default 'NOT_READY',
  gross_amount numeric(14,2) not null,
  platform_fee_amount numeric(14,2) not null default 0,
  adjustment_amount numeric(14,2) not null default 0,
  net_amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  state_changed_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (assignment_id),
  foreign key (shipment_id, assignment_id) references assignments(shipment_id, id),
  check (gross_amount >= 0 and platform_fee_amount >= 0),
  check (net_amount = gross_amount - platform_fee_amount + adjustment_amount),
  check (net_amount >= 0),
  check (currency ~ '^[A-Z]{3}$')
);

create table payout_transactions (
  id uuid primary key default gen_random_uuid(),
  payout_id uuid not null references driver_payouts(id),
  status transaction_status not null,
  amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  external_provider text not null,
  external_reference text,
  provider_event_id text,
  response_payload jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  occurred_at timestamptz not null default clock_timestamp(),
  unique (payout_id, idempotency_key),
  unique nulls not distinct (external_provider, provider_event_id),
  check (amount >= 0),
  check (currency ~ '^[A-Z]{3}$')
);

create table financial_holds (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  payment_intent_id uuid references payment_intents(id),
  payout_id uuid references driver_payouts(id),
  hold_code text not null,
  source_type text not null,
  source_id uuid,
  status hold_status not null default 'ACTIVE',
  amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  reason text not null,
  opened_at timestamptz not null default clock_timestamp(),
  released_at timestamptz,
  released_by_profile_id uuid references profiles(id),
  release_reason text,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check ((status = 'RELEASED' and released_at is not null and release_reason is not null) or status <> 'RELEASED')
);

create index financial_holds_active_idx
  on financial_holds (shipment_id, amount)
  where status = 'ACTIVE';

create table financial_adjustments (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  stop_execution_id uuid references stop_executions(id),
  cargo_item_id uuid references cargo_items(id),
  adjustment_type financial_adjustment_type not null,
  amount numeric(14,2) not null,
  currency char(3) not null default 'CAD',
  reason text not null,
  policy_version_id uuid references policy_versions(id),
  payment_transaction_id uuid references payment_transactions(id),
  payout_transaction_id uuid references payout_transactions(id),
  authorized_by_profile_id uuid not null references profiles(id),
  reauth_session_id uuid not null references reauth_sessions(id),
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (shipment_id, idempotency_key),
  check (amount > 0),
  check (currency ~ '^[A-Z]{3}$'),
  check (length(btrim(reason)) >= 3)
);

create table disputes (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  stop_execution_id uuid references stop_executions(id),
  cargo_item_id uuid references cargo_items(id),
  opened_by_profile_id uuid references profiles(id),
  opened_by_provider_id uuid references service_providers(id),
  category_code text not null,
  status dispute_status not null default 'OPEN',
  description text not null,
  disputed_amount numeric(14,2) not null default 0,
  currency char(3) not null default 'CAD',
  financial_hold_id uuid references financial_holds(id),
  resolution_code text,
  resolution_summary text,
  resolved_by_profile_id uuid references profiles(id),
  opened_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (num_nonnulls(opened_by_profile_id, opened_by_provider_id) >= 1),
  check (disputed_amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check ((status in ('RESOLVED', 'CLOSED') and resolved_at is not null and resolution_summary is not null) or status not in ('RESOLVED', 'CLOSED'))
);

create index disputes_open_idx
  on disputes (shipment_id, status)
  where status not in ('RESOLVED', 'CLOSED');

create table dispute_events (
  id uuid primary key default gen_random_uuid(),
  dispute_id uuid not null references disputes(id),
  prior_status dispute_status,
  current_status dispute_status not null,
  event_type text not null,
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  actor_provider_id uuid references service_providers(id),
  note text,
  evidence_manifest jsonb not null default '[]'::jsonb,
  financial_allocation jsonb not null default '{}'::jsonb,
  authority_code text,
  reauth_session_id uuid references reauth_sessions(id),
  occurred_at timestamptz not null default clock_timestamp(),
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb
);

create unique index dispute_events_idempotency_uq
  on dispute_events (dispute_id, event_type, idempotency_key)
  where idempotency_key is not null;

create table claims (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  stop_execution_id uuid references stop_executions(id),
  cargo_item_id uuid references cargo_items(id),
  claimant_profile_id uuid references profiles(id),
  claimant_provider_id uuid references service_providers(id),
  category_code text not null,
  status claim_status not null default 'OPEN',
  description text not null,
  claimed_amount numeric(14,2),
  currency char(3) not null default 'CAD',
  financial_hold_id uuid references financial_holds(id),
  resolution_summary text,
  opened_at timestamptz not null default clock_timestamp(),
  resolved_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  check (num_nonnulls(claimant_profile_id, claimant_provider_id) >= 1),
  check (claimed_amount is null or claimed_amount >= 0),
  check (currency ~ '^[A-Z]{3}$'),
  check ((status in ('APPROVED', 'DENIED', 'SETTLED', 'CLOSED') and resolved_at is not null) or status not in ('APPROVED', 'DENIED', 'SETTLED', 'CLOSED'))
);

create table claim_events (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null references claims(id),
  prior_status claim_status,
  current_status claim_status not null,
  event_type text not null,
  actor_kind actor_kind not null,
  actor_profile_id uuid references profiles(id),
  actor_provider_id uuid references service_providers(id),
  note text,
  evidence_manifest jsonb not null default '[]'::jsonb,
  occurred_at timestamptz not null default clock_timestamp(),
  idempotency_key text,
  metadata jsonb not null default '{}'::jsonb
);

create unique index claim_events_idempotency_uq
  on claim_events (claim_id, event_type, idempotency_key)
  where idempotency_key is not null;

-- -----------------------------------------------------------------------------
-- Receiver access, confirmations, messages, and notifications
-- -----------------------------------------------------------------------------

create table receiver_access_tokens (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  stop_execution_id uuid not null references stop_executions(id),
  token_hash text not null unique,
  permissions jsonb not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  check (token_hash ~ '^[0-9a-fA-F]{64}$'),
  check (expires_at > created_at)
);

create table receiver_confirmations (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  stop_execution_id uuid not null references stop_executions(id),
  receiver_access_token_id uuid references receiver_access_tokens(id),
  verification_state delivery_verification_state not null,
  receiver_label text,
  cargo_manifest jsonb not null,
  issue_category text,
  response_note text,
  responded_at timestamptz not null default clock_timestamp(),
  idempotency_key text not null,
  unique (stop_execution_id, idempotency_key),
  check (verification_state <> 'NOT_REQUIRED')
);

create table shipment_messages (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id),
  stop_execution_id uuid references stop_executions(id),
  sender_kind actor_kind not null,
  sender_profile_id uuid references profiles(id),
  sender_provider_id uuid references service_providers(id),
  receiver_token_id uuid references receiver_access_tokens(id),
  body text not null,
  attachments jsonb not null default '[]'::jsonb,
  sent_at timestamptz not null default clock_timestamp(),
  redacted_at timestamptz,
  redaction_reason text,
  check (length(btrim(body)) > 0),
  check ((redacted_at is null and redaction_reason is null) or (redacted_at is not null and redaction_reason is not null))
);

create index shipment_messages_timeline_idx
  on shipment_messages (shipment_id, sent_at, id);

create table notification_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid references shipments(id),
  profile_id uuid references profiles(id),
  receiver_access_token_id uuid references receiver_access_tokens(id),
  event_code text not null,
  channel text not null,
  template_version text not null,
  status notification_status not null default 'QUEUED',
  destination_hash text,
  payload jsonb not null default '{}'::jsonb,
  provider_reference text,
  scheduled_at timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  failed_at timestamptz,
  idempotency_key text not null,
  created_at timestamptz not null default clock_timestamp(),
  unique (event_code, idempotency_key),
  check (num_nonnulls(shipment_id, profile_id, receiver_access_token_id) >= 1)
);

-- -----------------------------------------------------------------------------
-- Read models
-- -----------------------------------------------------------------------------

create view v_compliance_item_export as
select
  ci.item_category as "itemCategory",
  ci.compliance_code as "complianceCode",
  ci.compliance_name as "complianceName",
  ci.related_service_code as "relatedServiceCode",
  ci.holder_name as "holderName",
  ci.credential_number as "credentialNumber",
  ci.issuing_authority as "issuingAuthority",
  ci.issue_date as "issueDate",
  ci.effective_date as "effectiveDate",
  ci.expiry_date as "expiryDate",
  ci.review_status::text as "reviewStatus",
  ci.is_required as "isRequired",
  ci.notes,
  ci.reviewed_at as "reviewedAt",
  ci.reviewer_label as "reviewerLabel",
  ci.status::text as "status",
  count(cd.id)::bigint as "documentCount",
  count(cd.id) filter (where cd.status = 'ACCEPTED')::bigint as "acceptedDocumentCount"
from compliance_items ci
left join compliance_documents cd on cd.compliance_item_id = ci.id
group by ci.id;

create view v_compliance_blockers as
select
  ci.subject_id,
  ci.id as compliance_item_id,
  ci.compliance_code,
  ci.compliance_name,
  ci.review_status,
  ci.expiry_date
from compliance_items ci
where ci.status = 'ACTIVE'
  and ci.applicability = 'APPLICABLE'
  and ci.is_required
  and ci.review_status <> 'VERIFIED';

create view v_route_allocation_manifest as
select
  rv.shipment_id,
  rv.id as route_version_id,
  rv.version_no,
  ci.id as cargo_item_id,
  ci.stable_cargo_key,
  ci.cargo_line_no,
  ci.description,
  ca.id as cargo_allocation_id,
  ca.quantity,
  ca.quantity_unit,
  pickup.sequence_no as pickup_sequence_no,
  pickup.stable_stop_key as pickup_stop_key,
  delivery.sequence_no as delivery_sequence_no,
  delivery.stable_stop_key as delivery_stop_key
from route_versions rv
join cargo_items ci on ci.route_version_id = rv.id
join cargo_allocations ca on ca.route_version_id = rv.id and ca.cargo_item_id = ci.id
join route_stops pickup on pickup.route_version_id = rv.id and pickup.id = ca.pickup_stop_id
join route_stops delivery on delivery.route_version_id = rv.id and delivery.id = ca.delivery_stop_id;

create view v_cargo_custody_balance as
select
  cm.shipment_id,
  ci.stable_cargo_key,
  cm.quantity_unit,
  sum(
    case cm.movement_type
      when 'LOAD' then cm.quantity
      when 'TRANSFER_IN' then cm.quantity
      when 'STORAGE_OUT' then cm.quantity
      when 'UNLOAD' then -cm.quantity
      when 'TRANSFER_OUT' then -cm.quantity
      when 'STORAGE_IN' then -cm.quantity
    end
  ) as onboard_quantity,
  max(cm.occurred_at) as last_movement_at
from cargo_movements cm
join cargo_allocations ca
  on ca.route_version_id = cm.route_version_id and ca.id = cm.cargo_allocation_id
join cargo_items ci
  on ci.route_version_id = ca.route_version_id and ci.id = ca.cargo_item_id
group by cm.shipment_id, ci.stable_cargo_key, cm.quantity_unit;

create view v_shipment_operating_context as
select
  s.id as shipment_id,
  s.shipment_reference,
  s.shipment_state,
  ma.state as marketplace_state,
  pa.state as customer_payment_state,
  pa.secured_amount,
  po.state as driver_payout_state,
  da.state as dispute_state,
  rv.id as active_route_version_id,
  rv.version_no as active_route_version_no,
  a.id as active_assignment_id,
  re.id as active_route_execution_id,
  re.state as route_execution_state,
  s.lock_version
from shipments s
left join shipment_marketplace_axes ma on ma.shipment_id = s.id
left join shipment_customer_payment_axes pa on pa.shipment_id = s.id
left join shipment_driver_payout_axes po on po.shipment_id = s.id
left join shipment_dispute_axes da on da.shipment_id = s.id
left join route_versions rv on rv.shipment_id = s.id and rv.status = 'ACTIVE'
left join assignments a on a.shipment_id = s.id and a.status = 'ACTIVE'
left join route_executions re on re.shipment_id = s.id and re.state in ('ACTIVE', 'RECOVERY_ACTIVE');

-- -----------------------------------------------------------------------------
-- Authority helpers
-- -----------------------------------------------------------------------------

insert into permissions (permission_key, description, is_sensitive) values
  ('COMPLIANCE_REVIEW', 'Review and decide provider compliance items', true),
  ('PRICING_MANAGE', 'Publish Haulvia pricing rules or partner rate cards', true),
  ('SHIPMENT_STATE_OVERRIDE', 'Execute an approved administrative shipment transition', true),
  ('CUSTODY_TRANSFER_AUTHORIZE', 'Authorize a post-pickup custody transfer', true),
  ('DISPUTE_RESOLVE', 'Resolve a dispute and allocate protected funds', true),
  ('FINANCIAL_ADJUST', 'Issue a refund, charge, credit, or driver compensation', true);

create or replace function has_permission(
  p_profile_id uuid,
  p_organization_id uuid,
  p_permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = haulvia, pg_temp
as $$
  select exists (
    select 1
    from organization_memberships om
    join membership_roles mr on mr.membership_id = om.id
    join role_permissions rp on rp.role_id = mr.role_id
    join permissions p on p.id = rp.permission_id
    where om.profile_id = p_profile_id
      and om.organization_id = p_organization_id
      and om.status = 'ACTIVE'
      and (om.ends_at is null or om.ends_at > clock_timestamp())
      and p.permission_key = upper(p_permission_key)
  );
$$;

create or replace function assert_sensitive_authority(
  p_profile_id uuid,
  p_organization_id uuid,
  p_permission_key text,
  p_reauth_session_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = haulvia, pg_temp
as $$
begin
  if p_reason is null or length(btrim(p_reason)) < 8 then
    raise exception 'A specific reason of at least 8 characters is required'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from reauth_sessions rs
    where rs.id = p_reauth_session_id
      and rs.profile_id = p_profile_id
      and rs.organization_id is not distinct from p_organization_id
      and rs.verified_at <= clock_timestamp()
      and rs.expires_at > clock_timestamp()
      and rs.revoked_at is null
  ) then
    raise exception 'Fresh password, passkey, or MFA verification is required'
      using errcode = '42501';
  end if;

  if not exists (
    select 1 from permissions p
    where p.permission_key = upper(p_permission_key)
      and p.is_sensitive
  ) or not has_permission(p_profile_id, p_organization_id, p_permission_key) then
    raise exception 'Actor does not hold required sensitive permission %', upper(p_permission_key)
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function has_permission(uuid, uuid, text) from public;
revoke all on function assert_sensitive_authority(uuid, uuid, text, uuid, text) from public;

-- -----------------------------------------------------------------------------
-- Relational invariant triggers
-- -----------------------------------------------------------------------------

create or replace function enforce_compliance_state_transition()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.review_status = old.review_status then
    return new;
  end if;

  if not exists (
    select 1 from compliance_state_transition_rules r
    where r.from_status = old.review_status and r.to_status = new.review_status
  ) then
    raise exception 'Compliance transition % -> % is not approved', old.review_status, new.review_status
      using errcode = '23514';
  end if;

  if new.reviewer_profile_id is null and nullif(btrim(new.reviewer_label), '') is null then
    raise exception 'Compliance status changes require a reviewer identity or system label'
      using errcode = '23514';
  end if;

  if nullif(btrim(new.review_action_note), '') is null then
    raise exception 'Compliance status changes require an action note'
      using errcode = '23514';
  end if;

  new.reviewed_at := clock_timestamp();
  new.reviewer_label := coalesce(nullif(btrim(new.reviewer_label), ''), 'PROFILE:' || new.reviewer_profile_id::text);
  new.status_changed_at := clock_timestamp();
  return new;
end;
$$;

create or replace function append_compliance_item_history()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.review_status <> old.review_status then
    insert into compliance_item_history (
      compliance_item_id, prior_status, current_status, reviewer_profile_id,
      reviewer_label, note, item_metadata, occurred_at
    ) values (
      new.id, old.review_status, new.review_status, new.reviewer_profile_id,
      new.reviewer_label, new.review_action_note,
      jsonb_build_object(
        'itemCategory', new.item_category,
        'complianceCode', new.compliance_code,
        'complianceName', new.compliance_name,
        'relatedServiceCode', new.related_service_code,
        'holderName', new.holder_name,
        'credentialNumber', new.credential_number,
        'issuingAuthority', new.issuing_authority,
        'issueDate', new.issue_date,
        'effectiveDate', new.effective_date,
        'expiryDate', new.expiry_date,
        'isRequired', new.is_required,
        'applicability', new.applicability,
        'recordStatus', new.status
      ),
      new.reviewed_at
    );
  end if;
  return new;
end;
$$;

create or replace function guard_route_plan_mutation()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_route_version_id uuid;
  v_status route_version_status;
begin
  v_route_version_id := case when tg_op = 'DELETE' then old.route_version_id else new.route_version_id end;

  select status into v_status
  from route_versions
  where id = v_route_version_id
  for update;

  if v_status is null then
    raise exception 'Route version % does not exist', v_route_version_id
      using errcode = '23503';
  end if;

  if v_status <> 'DRAFT' then
    raise exception 'Route version % is % and its plan is immutable', v_route_version_id, v_status
      using errcode = '55000';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function validate_cargo_allocation()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_pickup_sequence integer;
  v_delivery_sequence integer;
  v_pickup_type stop_type;
  v_delivery_type stop_type;
  v_item_unit text;
begin
  select p.sequence_no, p.stop_type, d.sequence_no, d.stop_type, ci.quantity_unit
    into v_pickup_sequence, v_pickup_type, v_delivery_sequence, v_delivery_type, v_item_unit
  from route_stops p
  join route_stops d on d.route_version_id = p.route_version_id
  join cargo_items ci on ci.route_version_id = p.route_version_id
  where p.route_version_id = new.route_version_id
    and p.id = new.pickup_stop_id
    and d.id = new.delivery_stop_id
    and ci.id = new.cargo_item_id;

  if not found then
    raise exception 'Cargo allocation references an inconsistent route version'
      using errcode = '23503';
  end if;

  if v_pickup_sequence >= v_delivery_sequence then
    raise exception 'Cargo pickup stop must precede its delivery stop'
      using errcode = '23514';
  end if;

  if v_pickup_type not in ('PICKUP', 'TRANSFER', 'STORAGE') then
    raise exception 'Cargo pickup endpoint type % cannot load custody', v_pickup_type
      using errcode = '23514';
  end if;

  if v_delivery_type not in ('DELIVERY', 'RETURN', 'TRANSFER', 'STORAGE') then
    raise exception 'Cargo delivery endpoint type % cannot unload custody', v_delivery_type
      using errcode = '23514';
  end if;

  if new.quantity_unit <> v_item_unit then
    raise exception 'Cargo allocation unit must match its cargo line unit'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function validate_route_version_change()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_stop_count integer;
  v_leg_count integer;
  v_cargo_count integer;
  v_min_sequence integer;
  v_max_sequence integer;
begin
  if tg_op = 'DELETE' then
    raise exception 'Route versions are retained and cannot be deleted'
      using errcode = '55000';
  end if;

  if old.status in ('SUPERSEDED', 'FROZEN') and new is distinct from old then
    raise exception 'A % route version is immutable', old.status
      using errcode = '55000';
  end if;

  if old.status = 'ACTIVE' then
    if new.status not in ('ACTIVE', 'SUPERSEDED', 'FROZEN') then
      raise exception 'An active route version may only be superseded or frozen'
        using errcode = '23514';
    end if;
    if new.shipment_id is distinct from old.shipment_id
       or new.version_no is distinct from old.version_no
       or new.prior_route_version_id is distinct from old.prior_route_version_id
       or new.change_reason is distinct from old.change_reason
       or new.planned_distance_km is distinct from old.planned_distance_km
       or new.planned_duration_seconds is distinct from old.planned_duration_seconds
       or new.created_by_profile_id is distinct from old.created_by_profile_id
       or new.created_at is distinct from old.created_at then
      raise exception 'An active route plan cannot be edited; create a new route version'
        using errcode = '55000';
    end if;
  end if;

  if new.prior_route_version_id is not null and not exists (
    select 1 from route_versions prior
    where prior.id = new.prior_route_version_id
      and prior.shipment_id = new.shipment_id
      and prior.version_no < new.version_no
  ) then
    raise exception 'Prior route version must belong to the same shipment and have a lower version number'
      using errcode = '23514';
  end if;

  if new.status = 'ACTIVE' and old.status <> 'ACTIVE' then
    if old.status <> 'DRAFT' then
      raise exception 'Only a draft route version can be activated'
        using errcode = '23514';
    end if;

    select count(*), min(sequence_no), max(sequence_no)
      into v_stop_count, v_min_sequence, v_max_sequence
    from route_stops where route_version_id = new.id;

    select count(*) into v_leg_count
    from route_legs where route_version_id = new.id;

    select count(*) into v_cargo_count
    from cargo_items where route_version_id = new.id;

    if v_stop_count < 2 or v_min_sequence <> 1 or v_max_sequence <> v_stop_count then
      raise exception 'An active route requires a contiguous ordered stop list beginning at 1'
        using errcode = '23514';
    end if;

    if not exists (select 1 from route_stops where route_version_id = new.id and stop_type = 'PICKUP')
       or not exists (select 1 from route_stops where route_version_id = new.id and stop_type in ('DELIVERY', 'RETURN', 'STORAGE')) then
      raise exception 'An active route requires a pickup and a delivery/recovery endpoint'
        using errcode = '23514';
    end if;

    if v_leg_count <> v_stop_count - 1 or exists (
      select 1
      from route_legs rl
      join route_stops f on f.route_version_id = rl.route_version_id and f.id = rl.from_stop_id
      join route_stops t on t.route_version_id = rl.route_version_id and t.id = rl.to_stop_id
      where rl.route_version_id = new.id
        and (t.sequence_no <> f.sequence_no + 1 or rl.sequence_no <> f.sequence_no)
    ) then
      raise exception 'Route legs must connect every pair of adjacent ordered stops exactly once'
        using errcode = '23514';
    end if;

    if v_cargo_count < 1 or exists (
      select 1
      from cargo_items ci
      left join cargo_allocations ca
        on ca.route_version_id = ci.route_version_id and ca.cargo_item_id = ci.id
      where ci.route_version_id = new.id
      group by ci.id, ci.quantity
      having coalesce(sum(ca.quantity), 0) <> ci.quantity
    ) then
      raise exception 'Every cargo line must be fully allocated across valid pickup/delivery stop pairs'
        using errcode = '23514';
    end if;

    new.activated_at := coalesce(new.activated_at, clock_timestamp());
  end if;

  if new.status = 'SUPERSEDED' and old.status <> 'SUPERSEDED' then
    new.superseded_at := coalesce(new.superseded_at, clock_timestamp());
  end if;

  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create or replace function enforce_offer_revision_rules()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_source pricing_source;
  v_mode partner_pricing_mode;
  v_status offer_status;
  v_expires_at timestamptz;
  v_route_version_id uuid;
  v_shipment_id uuid;
  v_count integer;
begin
  select pricing_source, pricing_mode, status, expires_at, route_version_id, shipment_id
    into v_source, v_mode, v_status, v_expires_at, v_route_version_id, v_shipment_id
  from offer_threads
  where id = new.offer_thread_id
  for update;

  if v_status not in ('ACTIVE', 'RECONFIRMATION_REQUIRED') or v_expires_at <= clock_timestamp() then
    raise exception 'Offer thread is not actionable'
      using errcode = '55000';
  end if;

  if new.valid_until <= clock_timestamp() or new.valid_until > v_expires_at then
    raise exception 'Offer revision validity must be current and cannot outlive its thread'
      using errcode = '23514';
  end if;

  if new.route_version_id <> v_route_version_id
     and not exists (
       select 1 from offer_threads ot
       where ot.id = new.offer_thread_id
         and ot.reconfirmation_route_version_id = new.route_version_id
     ) then
    raise exception 'Offer revision does not cover the current or requested reconfirmation route version'
      using errcode = '23514';
  end if;

  if not exists (
    select 1 from shipment_price_snapshots ps
    where ps.id = new.pricing_snapshot_id
      and ps.shipment_id = v_shipment_id
      and ps.route_version_id = new.route_version_id
      and ps.total_amount = new.amount
      and ps.currency = new.currency
  ) then
    raise exception 'Offer revision amount/currency must match its route price snapshot'
      using errcode = '23514';
  end if;

  if new.revision_kind in ('CUSTOMER_COUNTER', 'PROVIDER_REVISION')
     and not (v_source = 'HAULVIA_GUARDRAIL' or (v_source = 'PARTNER_RATE_CARD' and v_mode = 'FLEX_NEGOTIABLE')) then
    raise exception 'Counters and revisions are available only on negotiable Flex pricing'
      using errcode = '23514';
  end if;

  if new.revision_kind = 'FIRM_MATCH'
     and not (v_source = 'HAULVIA_FIXED' or (v_source = 'PARTNER_RATE_CARD' and v_mode in ('FLEX_FIRM', 'EXPEDITED_FIRM'))) then
    raise exception 'Firm matches require a fixed or firm pricing branch'
      using errcode = '23514';
  end if;

  if new.revision_kind = 'CUSTOMER_COUNTER' then
    select count(*) into v_count from offer_revisions
    where offer_thread_id = new.offer_thread_id and revision_kind = 'CUSTOMER_COUNTER';
    if v_count >= 2 then
      raise exception 'A negotiation thread permits at most two customer counters'
        using errcode = '23514';
    end if;
  elsif new.revision_kind = 'PROVIDER_REVISION' then
    select count(*) into v_count from offer_revisions
    where offer_thread_id = new.offer_thread_id and revision_kind = 'PROVIDER_REVISION';
    if v_count >= 2 then
      raise exception 'A negotiation thread permits at most two provider revisions'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create or replace function validate_price_snapshot()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_shipment_service_level service_level;
  v_shipment_currency char(3);
  v_source pricing_source;
  v_service_level service_level;
  v_mode partner_pricing_mode;
  v_currency char(3);
  v_review_status pricing_review_status;
  v_review_amount numeric(14,2);
  v_review_expires_at timestamptz;
begin
  select s.service_level, s.currency
    into v_shipment_service_level, v_shipment_currency
  from shipments s
  where s.id = new.shipment_id;

  if not found or v_shipment_currency <> new.currency then
    raise exception 'Price snapshot currency must match its shipment'
      using errcode = '23514';
  end if;

  if new.pricing_source in ('HAULVIA_GUARDRAIL', 'HAULVIA_FIXED') then
    select prs.pricing_source, prs.service_level, prs.currency
      into v_source, v_service_level, v_currency
    from pricing_rule_versions prv
    join pricing_rule_sets prs on prs.id = prv.pricing_rule_set_id
    where prv.id = new.pricing_rule_version_id;

    if not found
       or v_source <> new.pricing_source
       or v_service_level <> v_shipment_service_level
       or v_currency <> new.currency then
      raise exception 'Haulvia price snapshot does not match its rule source, service level, or currency'
        using errcode = '23514';
    end if;
  else
    select 'PARTNER_RATE_CARD'::pricing_source, prc.service_level, prc.pricing_mode, prc.currency
      into v_source, v_service_level, v_mode, v_currency
    from partner_rate_card_versions prcv
    join partner_rate_cards prc on prc.id = prcv.rate_card_id
    where prcv.id = new.rate_card_version_id;

    if not found
       or v_service_level <> v_shipment_service_level
       or v_mode <> new.pricing_mode
       or v_currency <> new.currency then
      raise exception 'Partner price snapshot does not match its rate-card service level, mode, or currency'
        using errcode = '23514';
    end if;
  end if;

  if new.purpose <> 'ADJUSTMENT' then
    if new.pricing_review_id is null then
      raise exception 'Posting, offer, reservation, and assignment snapshots require a pricing review'
        using errcode = '23514';
    end if;

    select pr.status, pr.reviewed_amount, pr.expires_at
      into v_review_status, v_review_amount, v_review_expires_at
    from pricing_reviews pr
    where pr.id = new.pricing_review_id
      and pr.shipment_id = new.shipment_id
      and pr.route_version_id = new.route_version_id
      and pr.pricing_source = new.pricing_source
      and pr.pricing_mode = new.pricing_mode
      and pr.currency = new.currency;

    if not found
       or v_review_status not in ('PASSED', 'APPROVED')
       or v_review_amount <> new.total_amount
       or (v_review_expires_at is not null and v_review_expires_at <= clock_timestamp()) then
      raise exception 'Price snapshot requires a current passed/approved review for the same amount and branch'
        using errcode = '23514';
    end if;
  end if;

  if new.purpose in ('RESERVATION', 'ASSIGNMENT') and new.accepted_at is null then
    raise exception 'Reservation and assignment price snapshots require accepted_at'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function enforce_paid_active_assignment()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_payment_state customer_payment_state;
  v_secured_amount numeric(14,2);
  v_payment_currency char(3);
  v_price_amount numeric(14,2);
  v_price_currency char(3);
begin
  if tg_op = 'UPDATE' then
    if old.status = 'ACTIVE' and new.status = 'ACTIVE' then
      if new.shipment_id is distinct from old.shipment_id
         or new.route_version_id is distinct from old.route_version_id
         or new.provider_id is distinct from old.provider_id
         or new.driver_id is distinct from old.driver_id
         or new.vehicle_id is distinct from old.vehicle_id
         or new.offer_reservation_id is distinct from old.offer_reservation_id
         or new.selected_offer_revision_id is distinct from old.selected_offer_revision_id
         or new.price_snapshot_id is distinct from old.price_snapshot_id
         or new.agreement_snapshot is distinct from old.agreement_snapshot
         or new.assigned_at is distinct from old.assigned_at then
        raise exception 'An active assignment is immutable; transfer or replace it with a new assignment'
          using errcode = '55000';
      end if;
      return new;
    end if;
  end if;

  if new.status <> 'ACTIVE' then
    return new;
  end if;

  select state, secured_amount, currency
    into v_payment_state, v_secured_amount, v_payment_currency
  from shipment_customer_payment_axes
  where shipment_id = new.shipment_id
  for update;

  if not found then
    raise exception 'Shipment customer-payment axis is missing'
      using errcode = '23514';
  end if;

  select total_amount, currency
    into v_price_amount, v_price_currency
  from shipment_price_snapshots
  where id = new.price_snapshot_id
    and shipment_id = new.shipment_id
    and route_version_id = new.route_version_id
    and purpose in ('RESERVATION', 'ASSIGNMENT');

  if not found then
    raise exception 'Assignment price snapshot is missing or does not match the shipment route'
      using errcode = '23514';
  end if;

  if v_payment_state is distinct from 'SECURED'
     or v_secured_amount < v_price_amount
     or v_payment_currency <> v_price_currency then
    raise exception 'Full route amount must be secured in the assignment currency before assignment'
      using errcode = '23514';
  end if;

  if not exists (
    select 1 from route_versions rv
    where rv.id = new.route_version_id
      and rv.shipment_id = new.shipment_id
      and rv.status = 'ACTIVE'
  ) then
    raise exception 'Assignment requires the shipment current active route version'
      using errcode = '23514';
  end if;

  if not exists (
    select 1
    from service_providers sp
    join provider_drivers pd on pd.provider_id = sp.id and pd.driver_id = new.driver_id
    join drivers d on d.id = pd.driver_id
    join vehicles v on v.id = new.vehicle_id and v.provider_id = sp.id
    where sp.id = new.provider_id
      and sp.status = 'ACTIVE'
      and pd.status = 'ACTIVE'
      and (pd.ends_at is null or pd.ends_at > clock_timestamp())
      and d.status = 'ACTIVE'
      and v.status = 'ACTIVE'
  ) then
    raise exception 'Provider, driver membership, driver, and vehicle must all be active'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from compliance_subjects cs
    join v_compliance_blockers cb on cb.subject_id = cs.id
    where cs.provider_id = new.provider_id
       or cs.driver_id = new.driver_id
       or cs.vehicle_id = new.vehicle_id
  ) then
    raise exception 'Provider, driver, or vehicle has an unresolved required compliance item'
      using errcode = '23514';
  end if;

  if new.offer_reservation_id is not null and not exists (
    select 1 from offer_reservations r
    where r.id = new.offer_reservation_id
      and r.shipment_id = new.shipment_id
      and r.status = 'ACTIVE'
      and r.expires_at > clock_timestamp()
      and r.selected_revision_id is not distinct from new.selected_offer_revision_id
  ) then
    raise exception 'Assignment offer reservation is inactive, expired, or does not match the selected revision'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function enforce_stop_state_transition()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if new.state = old.state then
    return new;
  end if;

  if old.state in ('COMPLETED', 'SKIPPED', 'CANCELLED') then
    raise exception 'Terminal stop state % cannot move backward', old.state
      using errcode = '55000';
  end if;

  if not exists (
    select 1 from stop_state_transition_rules r
    where r.from_state = old.state and r.to_state = new.state
  ) then
    raise exception 'Stop transition % -> % is not approved', old.state, new.state
      using errcode = '23514';
  end if;

  new.state_changed_at := clock_timestamp();
  new.current_attempt_no := greatest(new.current_attempt_no, old.current_attempt_no);
  if new.state = 'COMPLETED' then
    new.completed_at := coalesce(new.completed_at, clock_timestamp());
  end if;
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

create or replace function validate_cargo_movement()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_stop_type stop_type;
  v_stop_state stop_state;
  v_execution_state route_execution_state;
  v_allocation_quantity numeric(14,3);
  v_allocation_unit text;
  v_stable_cargo_key uuid;
  v_existing_quantity numeric(14,3);
begin
  select rs.stop_type, se.state, re.state, ca.quantity, ca.quantity_unit, ci.stable_cargo_key
    into v_stop_type, v_stop_state, v_execution_state,
         v_allocation_quantity, v_allocation_unit, v_stable_cargo_key
  from stop_executions se
  join route_executions re on re.id = se.route_execution_id
  join route_stops rs on rs.id = se.route_stop_id and rs.route_version_id = se.route_version_id
  join cargo_allocations ca on ca.id = new.cargo_allocation_id and ca.route_version_id = se.route_version_id
  join cargo_items ci on ci.id = ca.cargo_item_id and ci.route_version_id = ca.route_version_id
  where se.id = new.stop_execution_id
    and se.route_execution_id = new.route_execution_id
    and se.route_version_id = new.route_version_id
    and se.shipment_id = new.shipment_id;

  if not found then
    raise exception 'Cargo movement does not match its shipment, execution, stop, route, and allocation'
      using errcode = '23514';
  end if;

  if v_execution_state not in ('ACTIVE', 'RECOVERY_ACTIVE')
     or v_stop_state not in ('EVIDENCE_PENDING', 'COMPLETED') then
    raise exception 'Cargo movement requires an active execution and evidence-pending/completed stop'
      using errcode = '23514';
  end if;

  if new.quantity_unit <> v_allocation_unit then
    raise exception 'Cargo movement unit must match its allocation unit'
      using errcode = '23514';
  end if;

  if (new.movement_type = 'LOAD' and v_stop_type not in ('PICKUP', 'TRANSFER', 'STORAGE'))
     or (new.movement_type = 'UNLOAD' and v_stop_type not in ('DELIVERY', 'RETURN', 'TRANSFER', 'STORAGE'))
     or (new.movement_type in ('TRANSFER_IN', 'TRANSFER_OUT') and v_stop_type <> 'TRANSFER')
     or (new.movement_type in ('STORAGE_IN', 'STORAGE_OUT') and v_stop_type <> 'STORAGE') then
    raise exception 'Movement type % is not valid at stop type %', new.movement_type, v_stop_type
      using errcode = '23514';
  end if;

  if new.movement_type = 'LOAD' then
    select coalesce(sum(cm.quantity), 0)
      into v_existing_quantity
    from cargo_movements cm
    where cm.cargo_allocation_id = new.cargo_allocation_id
      and cm.movement_type = 'LOAD';

    if v_existing_quantity + new.quantity > v_allocation_quantity then
      raise exception 'LOAD movements cannot exceed the planned cargo allocation quantity'
        using errcode = '23514';
    end if;
  elsif new.movement_type in ('UNLOAD', 'TRANSFER_OUT', 'STORAGE_IN') then
    select coalesce(sum(
      case cm.movement_type
        when 'LOAD' then cm.quantity
        when 'TRANSFER_IN' then cm.quantity
        when 'STORAGE_OUT' then cm.quantity
        when 'UNLOAD' then -cm.quantity
        when 'TRANSFER_OUT' then -cm.quantity
        when 'STORAGE_IN' then -cm.quantity
      end
    ), 0)
      into v_existing_quantity
    from cargo_movements cm
    join cargo_allocations existing_ca
      on existing_ca.id = cm.cargo_allocation_id and existing_ca.route_version_id = cm.route_version_id
    join cargo_items existing_ci
      on existing_ci.id = existing_ca.cargo_item_id and existing_ci.route_version_id = existing_ca.route_version_id
    where cm.shipment_id = new.shipment_id
      and existing_ci.stable_cargo_key = v_stable_cargo_key
      and cm.quantity_unit = new.quantity_unit;

    if v_existing_quantity < new.quantity then
      raise exception 'Outbound custody movement cannot exceed current onboard quantity'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

create or replace function enforce_shipment_state_transition()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if old.shipment_state in ('COMPLETED', 'CANCELLED', 'EXPIRED', 'RETURNED_TO_SENDER') then
    if new is distinct from old then
      raise exception 'Terminal shipment % is immutable; copy it to a new draft instead', old.shipment_reference
        using errcode = '55000';
    end if;
    return new;
  end if;

  if new.shipment_state = old.shipment_state then
    new.lock_version := old.lock_version + 1;
    new.updated_at := clock_timestamp();
    return new;
  end if;

  if not exists (
    select 1 from shipment_state_transition_rules r
    where r.from_state = old.shipment_state and r.to_state = new.shipment_state
  ) then
    raise exception 'Shipment transition % -> % is not approved', old.shipment_state, new.shipment_state
      using errcode = '23514';
  end if;

  if new.shipment_state in ('POSTED', 'CANCELLED')
     and old.shipment_state in ('DRIVER_ASSIGNED', 'ROUTE_IN_PROGRESS')
     and exists (
       select 1 from cargo_movements cm
       where cm.shipment_id = old.id and cm.movement_type = 'LOAD'
     ) then
    raise exception 'Ordinary cancellation or repost is unavailable after first verified custody'
      using errcode = '23514';
  end if;

  if new.shipment_state in ('DELIVERED', 'RETURNED_TO_SENDER') then
    if exists (
      select 1 from v_cargo_custody_balance cb
      where cb.shipment_id = old.id and cb.onboard_quantity <> 0
    ) then
      raise exception 'Route cannot resolve while the cargo custody ledger is unbalanced'
        using errcode = '23514';
    end if;

    if exists (
      select 1 from stop_executions se
      where se.shipment_id = old.id
        and se.state not in ('COMPLETED', 'FAILED', 'SKIPPED', 'CANCELLED')
    ) then
      raise exception 'Route cannot resolve while a stop remains non-terminal'
        using errcode = '23514';
    end if;
  end if;

  if new.shipment_state = 'COMPLETED' then
    if exists (
      select 1 from workflow_holds wh
      where wh.shipment_id = old.id and wh.status = 'ACTIVE' and wh.blocks_completion
    ) or exists (
      select 1 from route_exceptions re
      where re.shipment_id = old.id
        and re.blocks_completion
        and re.status not in ('RESOLVED', 'CLOSED')
    ) then
      raise exception 'Shipment completion is blocked by an unresolved workflow hold or route exception'
        using errcode = '23514';
    end if;

    if exists (
      select 1 from stop_executions se
      where se.shipment_id = old.id
        and se.delivery_verification_state in (
          'PENDING_RECEIVER_CONFIRMATION', 'ISSUE_REPORTED', 'EXCEPTION_REVIEW'
        )
    ) then
      raise exception 'Shipment completion requires all delivery verification windows or issues to resolve'
        using errcode = '23514';
    end if;
  end if;

  new.state_changed_at := clock_timestamp();
  new.lock_version := old.lock_version + 1;
  new.updated_at := clock_timestamp();
  if new.shipment_state in ('COMPLETED', 'CANCELLED', 'EXPIRED', 'RETURNED_TO_SENDER') then
    new.terminal_at := coalesce(new.terminal_at, clock_timestamp());
  end if;
  return new;
end;
$$;

create or replace function guard_rate_card_line_mutation()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
declare
  v_version_id uuid;
  v_status publication_status;
begin
  v_version_id := case when tg_op = 'DELETE' then old.rate_card_version_id else new.rate_card_version_id end;
  select publication_status into v_status
  from partner_rate_card_versions
  where id = v_version_id
  for update;

  if v_status not in ('DRAFT', 'PENDING_REVIEW') then
    raise exception 'Published rate-card version % is immutable', v_version_id
      using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function guard_published_version()
returns trigger
language plpgsql
set search_path = haulvia, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% versions are retained and cannot be deleted', tg_table_name
      using errcode = '55000';
  end if;

  if old.publication_status in ('REJECTED', 'SUPERSEDED', 'EXPIRED')
     and new is distinct from old then
    raise exception '% version in % status is immutable', tg_table_name, old.publication_status
      using errcode = '55000';
  end if;

  if old.publication_status = 'APPROVED' and new is distinct from old then
    if new.publication_status not in ('SUPERSEDED', 'EXPIRED')
       or (to_jsonb(new) - array['publication_status', 'effective_to'])
          is distinct from
          (to_jsonb(old) - array['publication_status', 'effective_to']) then
      raise exception 'Approved % content is immutable; publish a new version', tg_table_name
        using errcode = '55000';
    end if;
  end if;

  return new;
end;
$$;

create trigger route_stops_plan_guard
before insert or update or delete on route_stops
for each row execute function guard_route_plan_mutation();

create trigger compliance_items_transition_guard
before update of review_status on compliance_items
for each row execute function enforce_compliance_state_transition();

create trigger compliance_items_history
after update of review_status on compliance_items
for each row execute function append_compliance_item_history();

create trigger route_legs_plan_guard
before insert or update or delete on route_legs
for each row execute function guard_route_plan_mutation();

create trigger cargo_items_plan_guard
before insert or update or delete on cargo_items
for each row execute function guard_route_plan_mutation();

create trigger cargo_allocations_plan_guard
before insert or update or delete on cargo_allocations
for each row execute function guard_route_plan_mutation();

create trigger cargo_allocations_validate
before insert or update on cargo_allocations
for each row execute function validate_cargo_allocation();

create trigger route_versions_validate
before update or delete on route_versions
for each row execute function validate_route_version_change();

create trigger offer_revisions_validate
before insert on offer_revisions
for each row execute function enforce_offer_revision_rules();

create trigger shipment_price_snapshots_validate
before insert on shipment_price_snapshots
for each row execute function validate_price_snapshot();

create trigger assignments_funding_guard
before insert or update of status on assignments
for each row execute function enforce_paid_active_assignment();

create trigger stop_executions_transition_guard
before update of state on stop_executions
for each row execute function enforce_stop_state_transition();

create trigger cargo_movements_validate
before insert on cargo_movements
for each row execute function validate_cargo_movement();

create trigger shipments_transition_guard
before update on shipments
for each row execute function enforce_shipment_state_transition();

create trigger shipments_initialize_axes
after insert on shipments
for each row execute function initialize_shipment_axes();

create trigger shipments_delete_guard
before delete on shipments
for each row execute function reject_delete();

create trigger partner_rate_card_lines_guard
before insert or update or delete on partner_rate_card_lines
for each row execute function guard_rate_card_line_mutation();

create trigger compliance_requirement_versions_guard
before update or delete on compliance_requirement_versions
for each row execute function guard_published_version();

create trigger policy_versions_guard
before update or delete on policy_versions
for each row execute function guard_published_version();

create trigger pricing_rule_versions_guard
before update or delete on pricing_rule_versions
for each row execute function guard_published_version();

create trigger partner_rate_card_versions_guard
before update or delete on partner_rate_card_versions
for each row execute function guard_published_version();

-- Mutable current/summarizing records receive consistent update timestamps.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'organizations', 'profiles', 'organization_memberships', 'provider_applications',
    'service_providers', 'drivers', 'provider_drivers', 'vehicles',
    'compliance_requirements', 'compliance_items', 'partner_rate_cards',
    'shipment_marketplace_axes', 'shipment_customer_payment_axes',
    'shipment_driver_payout_axes', 'shipment_dispute_axes', 'pricing_reviews',
    'offer_threads', 'assignments', 'route_executions', 'stop_attempts',
    'workflow_holds', 'route_exceptions', 'custody_transfers', 'payment_intents',
    'driver_payouts', 'financial_holds', 'disputes', 'claims'
  ]
  loop
    execute format(
      'create trigger %I before update on haulvia.%I for each row execute function haulvia.touch_updated_at()',
      v_table || '_touch_updated_at', v_table
    );
  end loop;
end;
$$;

-- Evidence, ledgers, snapshots, and histories are corrected by appending records.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'audit_events', 'compliance_document_reviews', 'compliance_item_history',
    'provider_application_events', 'shipment_state_events', 'workflow_axis_events', 'shipment_rule_snapshots',
    'shipment_price_snapshots', 'offer_revisions', 'assignment_events',
    'stop_attempt_events', 'stop_evidence', 'stop_evidence_reviews',
    'stop_evidence_corrections', 'cargo_movements', 'tracking_points',
    'route_updates', 'payment_transactions', 'payout_transactions',
    'dispute_events', 'claim_events', 'receiver_confirmations'
  ]
  loop
    execute format(
      'create trigger %I before update or delete on haulvia.%I for each row execute function haulvia.reject_append_only_mutation()',
      v_table || '_append_only', v_table
    );
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Documentation carried with the database
-- -----------------------------------------------------------------------------

comment on schema haulvia is
  'Haulvia operational schema. Shipment, marketplace, customer payment, route execution, payout, dispute, and verification states are independent axes.';
comment on table route_versions is
  'Immutable route-plan versions. Material changes create a new version; accepted shipments retain the version they accepted.';
comment on table route_stops is
  'Ordered stop snapshots for a route version. Launch supports 1:1, 1:many, and many:1; the allocation model is many:many ready.';
comment on table cargo_allocations is
  'Explicit quantity allocation from one pickup stop to one delivery/recovery stop within a route version.';
comment on table cargo_movements is
  'Append-only actual custody ledger. LOAD/UNLOAD and transfer/storage pairs must reconcile before route resolution.';
comment on table shipment_price_snapshots is
  'Append-only accepted pricing/rule evidence, retaining Haulvia or partner source, mode, version, and breakdown.';
comment on table stop_evidence is
  'Append-only per-attempt evidence with offline capture metadata. Corrections link new evidence without overwriting originals.';
comment on table financial_holds is
  'Financial protection is separate from shipment execution. Public wording should use held for payout unless escrow terminology is approved.';
comment on view v_compliance_item_export is
  'Exact approved compliance export field contract, including document and accepted-document counts.';

commit;
