# Haulvia P2D Private Storage and Retention Contract v1

## 1. Purpose

Phase 2D establishes Haulvia's canonical private digital-object registry,
retention model, protected-object access boundary, hold/deletion lifecycle,
and domain linkage for binary-backed records.

P2D is a database and command-contract phase.

P2D does not create or configure a hosted Supabase Storage bucket and does
not require the PostgreSQL `storage` schema to exist.

The physical blob provider remains an adapter outside the Haulvia business
schema.

---

## 2. Baseline

P2D builds on the completed P2C checkpoint:

`473ce673568262123d5e3230e775234d95c43493`

P2C established:

- RLS on all existing Haulvia base tables.
- default-deny raw client data access.
- no raw client view access.
- command-mediated application mutations.
- controlled SECURITY DEFINER search paths.
- service-role execution only on approved command wrappers.
- hardened default privileges.
- no dependency on Supabase's `storage` schema.

P2D must preserve those security boundaries.

---

## 3. Discovery baseline

At P2D discovery time:

- `haulvia.compliance_documents` contains zero rows.
- `haulvia.stop_evidence` contains zero rows.
- `compliance_documents` is always binary-object-backed.
- `stop_evidence` supports both binary evidence and structured-only evidence.
- the disposable local database has no `storage` schema.
- no existing command writes `compliance_documents`.
- stop-evidence commands currently accept `storageObjectKey` and `contentSha256`.
- `RETENTION_POLICY` version 1 exists in DRAFT state with empty config.
- `EVIDENCE_POD_POLICY` version 1 exists in DRAFT state with empty config.
- both policies require legal review.
- no retention period is currently approved or published.

P2D therefore has no legacy production rows to migrate or backfill.

---

## 4. Architectural boundary

The canonical model is:

    Private blob provider
            |
            v
    haulvia.private_storage_objects
            |
            +-- haulvia.compliance_documents
            |
            +-- haulvia.stop_evidence

`private_storage_objects` owns digital-object identity and lifecycle.

Domain tables own the business meaning of an object.

The physical provider's object table is not part of the Haulvia domain model.

Haulvia must not create foreign keys to `storage.objects`, `storage.buckets`,
or any provider-specific storage relation.

---

## 5. Physical-storage neutrality

A private storage object records the provider-facing locator required by
the backend adapter.

The canonical object registry must support, at minimum:

- storage provider code;
- bucket/container key;
- object key;
- original display filename;
- media type;
- byte size;
- SHA-256 content hash;
- lifecycle status;
- creation/reservation actor and timestamps;
- finalization timestamps;
- retention decision;
- deletion lifecycle;
- purge confirmation metadata.

The original filename is display metadata only.

It must never be used as the physical object key.

Provider secrets, signed URLs, bearer tokens, credentials, and raw access
tokens must never be persisted in the object registry.

---

## 6. Canonical registry

P2D creates:

`haulvia.private_storage_objects`

Each physical private blob has one canonical Haulvia object identity.

The registry row survives physical purge so that historical references,
hashes, retention decisions, and audit history remain attributable.

Deleting the physical blob must not delete the registry row.

---

## 7. Object-key uniqueness

The tuple:

`storage_provider + bucket_key + object_key`

must uniquely identify a registered physical object.

Object keys must not be supplied directly by an untrusted browser/mobile
client as authority.

The trusted backend/storage adapter is responsible for using the
server-authorized locator returned by the storage workflow.

---

## 8. Content integrity

An AVAILABLE object must have:

- a non-empty media type;
- a non-negative byte size;
- a lowercase 64-character hexadecimal SHA-256 digest;
- a provider code;
- a bucket key;
- an object key.

The content digest recorded at finalization is immutable.

A subsequent replacement must be represented by a new private storage
object rather than overwriting the historical object's digest.

---

## 9. Storage lifecycle

P2D defines a private-storage lifecycle with these states:

- `RESERVED`
- `AVAILABLE`
- `QUARANTINED`
- `DELETION_PENDING`
- `PURGED`
- `ABANDONED`

The lifecycle is distinct from domain status such as:

- compliance-document review status;
- stop-evidence review status;
- shipment state;
- dispute state.

---

## 10. Lifecycle rules

The normal lifecycle is:

`RESERVED -> AVAILABLE`

A reservation may instead become:

`RESERVED -> ABANDONED`

An object may enter quarantine:

`AVAILABLE -> QUARANTINED`

An authorized workflow may release a valid quarantined object:

`QUARANTINED -> AVAILABLE`

A deletion-eligible object may transition:

`AVAILABLE -> DELETION_PENDING -> PURGED`

A quarantined object may transition to deletion only through an authorized
deletion workflow.

`PURGED` and `ABANDONED` are terminal in P2D v1.

Physical content must never be considered purged merely because deletion
was requested.

---

## 11. Reservation versus finalization

Reservation establishes a Haulvia object identity and provider locator
before a binary upload is finalized.

Finalization confirms the authoritative:

- content SHA-256;
- byte size;
- media type;
- provider locator;
- retention decision.

A domain record must not treat a RESERVED object as valid evidence or a
valid compliance document.

Binary-backed domain records may bind only to an AVAILABLE private object
unless a specifically authorized internal review workflow permits a
QUARANTINED object.

---

## 12. Provider confirmation

Haulvia's database does not infer successful upload or deletion from an
API request alone.

The trusted storage adapter must confirm finalization before the object
becomes AVAILABLE.

Likewise, the trusted storage/purge worker must confirm physical deletion
before the object becomes PURGED.

---

## 13. Retention authority

Retention periods must not be hard-coded into P2D SQL.

Retention decisions derive from an approved and effective
`RETENTION_POLICY` version.

The existing DRAFT version with empty `{}` configuration is not sufficient
authority for a production retention decision.

P2D must not silently publish, approve, populate, or invent legal retention
periods.

---

## 14. Retention-policy configuration contract

P2D defines the database contract expected from a future approved
`RETENTION_POLICY`.

The policy must provide named retention classes.

Each storage object must resolve to one explicit retention class.

A retention class must provide, at minimum, an approved retention duration
or equivalent not-before-deletion rule.

There is no implicit fallback retention period.

If no approved/effective policy version can resolve the requested retention
class, finalization of the private object must fail closed.

---

## 15. Retention snapshot

At object finalization, Haulvia snapshots the resolved retention decision.

The snapshot must preserve at minimum:

- retention policy version ID;
- retention class;
- resolved retention parameters;
- calculated `retain_until`;
- policy/config evidence sufficient to establish how the date was derived.

The historical decision must not change merely because a newer retention
policy is later published.

---

## 16. Retention clock

Unless an approved policy explicitly defines another anchor, P2D uses the
object's finalization timestamp as the retention calculation anchor.

A RESERVED object does not start the evidentiary retention clock merely
because a reservation was created.

---

## 17. Holds

Retention expiry alone does not authorize purge.

P2D introduces explicit object holds.

Supported P2D hold categories are:

- `LEGAL`
- `DISPUTE`
- `COMPLIANCE`
- `SECURITY`
- `OPERATIONAL`

An active hold blocks physical purge regardless of `retain_until`.

---

## 18. Hold history

Hold placement and release must be attributable.

Haulvia must retain:

- hold category;
- reason;
- placing actor or trusted worker identity;
- placement timestamp;
- releasing actor or trusted worker identity;
- release reason;
- release timestamp.

Hold history must not disappear when a hold is released.

---

## 19. Deletion requests

P2D creates an explicit deletion-request record rather than deleting
objects directly from domain commands.

A deletion request must preserve:

- target private object;
- requester;
- reason;
- request timestamp;
- decision;
- decision actor;
- decision reason;
- decision timestamp;
- resulting provider purge correlation when applicable.

---

## 20. Purge eligibility

A physical purge may proceed only when all applicable conditions hold:

- the object is not already PURGED or ABANDONED;
- the approved retention decision allows deletion;
- `retain_until` has been reached when applicable;
- there is no active hold;
- an authorized deletion request has been approved;
- the provider purge is performed by a trusted storage worker/adapter.

P2D v1 provides no generic client-controlled bypass around these conditions.

---

## 21. Purge confirmation

`PURGED` means the trusted storage adapter has confirmed that the physical
object no longer exists at the provider locator.

Approval of a deletion request is not equivalent to purge confirmation.

Failure to delete the provider object must leave enough state for retry and
audit rather than falsely marking the object PURGED.

---

## 22. Metadata after purge

Purge removes binary content, not Haulvia's evidentiary metadata.

After purge, Haulvia retains the internal record necessary to prove:

- what object existed;
- its immutable content digest;
- its historical size/type;
- which retention decision applied;
- why deletion was permitted;
- who approved it;
- when physical deletion was confirmed.

---

## 23. Object events

P2D creates an append-only private-storage lifecycle event history.

Lifecycle events must capture material transitions such as:

- reservation;
- finalization;
- quarantine;
- quarantine release;
- abandonment;
- deletion request/approval linkage;
- deletion pending;
- purge confirmation.

Lifecycle history is not replaced by only storing the current status.

---

## 24. Protected-object access auditing

P2D creates append-only protected-object access events.

Sensitive object access must be attributable to:

- object ID;
- actor profile when applicable;
- organization/context when applicable;
- access action;
- reason/purpose;
- access result;
- correlation/request identifier;
- timestamp.

Actual signed URLs or provider credentials are never written to the audit
record.

---

## 25. Access authorization

Raw private object locators do not themselves grant access.

An application user must satisfy the relevant Haulvia permission and
business relationship before the backend may provide object access.

Existing authority concepts include:

- `PROVIDER_DOCUMENT_VIEW`
- `SHIPMENT_DOCUMENT_VIEW`
- `INTERNAL_SHIPMENT_DOCUMENT_VIEW`
- `SENSITIVE_DOCUMENT_VIEW`
- `STOP_EVIDENCE_REVIEW`
- `COMPLIANCE_REVIEW`

Sensitive documents continue to require specialized authority.

---

## 26. Upload authority

Existing upload permissions remain authoritative for their domains:

- `PROVIDER_DOCUMENT_UPLOAD`
- `SHIPMENT_DOCUMENT_UPLOAD`

Storage reservation/finalization is performed through trusted backend
commands.

Possession of a provider upload URL does not create Haulvia business
authority.

---

## 27. Storage lifecycle management authority

P2D introduces one explicit sensitive permission:

`PRIVATE_STORAGE_LIFECYCLE_MANAGE`

This permission governs exceptional human storage-lifecycle administration
such as quarantine release, hold administration, deletion approval, and
other protected lifecycle decisions not already authorized by a narrower
domain permission.

P2D may assign this permission only to intentionally authorized internal
roles.

It must not be granted to customer, courier-driver, or general provider
roles.

---

## 28. Storage worker authority

Physical storage adapter actions may use the existing trusted worker
authority:

`STORAGE_WORKER`

`STORAGE_WORKER` remains a worker authority and must not become a human
RBAC role.

A storage worker may perform only the worker-specific action for which the
command contract authorizes it.

---

## 29. Compliance-document linkage

P2D adds:

`compliance_documents.private_storage_object_id`

Every new compliance document must reference exactly one canonical private
storage object.

The referenced object must be AVAILABLE when the compliance document is
registered.

The compliance-document row continues to own:

- compliance item;
- document version;
- filename/display meaning;
- compliance review status;
- uploader;
- upload business timestamp.

The private-storage row owns the physical binary metadata and retention
lifecycle.

---

## 30. Compliance-document storage columns

Because the P2D discovery baseline contains zero compliance-document rows,
P2D may remove the old storage truth from:

- `compliance_documents.storage_object_key`
- `compliance_documents.content_sha256`

Those values become authoritative only in `private_storage_objects`.

P2D must not maintain two independent mutable sources of truth for the same
physical blob.

---

## 31. Stop-evidence linkage

P2D adds:

`stop_evidence.private_storage_object_id`

This column is nullable because some stop evidence is structured-only.

Binary-backed stop evidence references one canonical private storage object.

Structured-only evidence remains valid without a private object where the
evidence type permits structured data.

---

## 32. Stop-evidence invariant

Each stop-evidence record must contain meaningful evidence through at least
one of:

- `private_storage_object_id IS NOT NULL`; or
- `structured_value <> '{}'::jsonb`.

For binary-backed stop evidence, the referenced object must be AVAILABLE at
submission.

---

## 33. Stop-evidence legacy storage columns

Because the P2D discovery baseline contains zero stop-evidence rows, P2D may
remove:

- `stop_evidence.storage_object_key`
- `stop_evidence.content_sha256`

Binary metadata is read through `private_storage_object_id`.

---

## 34. Stop-evidence request contract

The P2D stop-evidence command contract supersedes the old binary request
shape.

Binary-backed evidence uses:

`privateStorageObjectId`

rather than accepting raw:

- `storageObjectKey`
- `contentSha256`

as client-declared storage truth.

Structured-only evidence continues to submit its approved structured values.

---

## 35. Historical migrations

P2D must not rewrite the committed Phase 1, P2A, P2B, or P2C migration files
merely to make them resemble the new architecture.

P2D supersedes affected schema/functions through a new migration.

Historical migrations remain an immutable record of schema evolution.

---

## 36. Historical tests and documentation

Existing earlier-phase acceptance files and versioned documents may
describe the schema/API that existed in those phases.

P2D does not require rewriting all historical artifacts.

P2D must instead include regression acceptance proving that the important
business behavior still works using the P2D object contract.

Any current non-versioned implementation guide created after P2D should
describe the P2D model rather than the superseded raw object-key model.

---

## 37. Compliance-document command boundary

P2D introduces a command-mediated path for registering a compliance
document against an AVAILABLE private storage object.

The command must:

- validate provider/compliance upload authority;
- validate the compliance item;
- validate object availability;
- prevent inappropriate object reuse;
- create the next valid compliance document version;
- preserve audit attribution.

No browser/mobile client receives raw table INSERT authority.

---

## 38. Private-storage command boundary

P2D introduces command-mediated operations for:

- object reservation;
- object finalization;
- object quarantine/release where authorized;
- hold placement/release;
- deletion request;
- deletion decision;
- purge confirmation;
- protected-object access authorization/audit;
- compliance-document registration.

Trusted internal helpers must not become public application entry points.

---

## 39. SECURITY DEFINER posture

Any P2D SECURITY DEFINER command wrapper must:

- use a controlled pinned `search_path`;
- terminate its trusted search path in `pg_temp`;
- not be owned by `anon` or `authenticated`;
- not be executable by PUBLIC, `anon`, or `authenticated`;
- be executable by `service_role` only when intentionally part of the P2D
  command allowlist.

Internal helper functions remain non-executable by application roles.

---

## 40. RLS

All new P2D base tables must have Row Level Security enabled.

P2D v1 does not require FORCE RLS.

P2D does not add permissive raw-table policies for `anon` or
`authenticated`.

---

## 41. Raw relation privileges

P2D must not grant raw private-storage table privileges to:

- PUBLIC;
- `anon`;
- `authenticated`.

P2D must not introduce broad raw-table grants to `service_role`.

The command boundary remains the application mutation interface.

---

## 42. Default privileges

P2D must preserve the P2C hardened default-privilege posture.

Future tables/views created by the migration owner must not automatically
be exposed to PUBLIC, `anon`, or `authenticated`.

Future privileged functions must not inherit PUBLIC EXECUTE.

---

## 43. No provider-schema dependency

The P2D migration and acceptance suite must run successfully in plain
PostgreSQL where:

- `storage` schema does not exist;
- `storage.buckets` does not exist;
- `storage.objects` does not exist.

This is a mandatory portability invariant.

---

## 44. Provider adapter boundary

Creating a private-storage registry row does not itself create a remote
blob.

Deleting a registry row is not the provider-deletion mechanism.

The backend adapter is responsible for translating an authorized Haulvia
storage operation into the provider API operation.

P2D stores provider-neutral state necessary to authorize and reconcile that
work.

---

## 45. Idempotency

All externally callable P2D mutation commands must participate in the
existing Haulvia command-idempotency model.

Retries must not create duplicate:

- storage reservations;
- object finalizations;
- compliance documents;
- holds;
- deletion requests;
- purge confirmations.

---

## 46. Audit continuity

P2D operations that materially affect object availability, retention,
access, or deletion must emit or link to Haulvia audit history.

P2D must not weaken existing append-only audit semantics.

---

## 47. No silent overwrite

An AVAILABLE object's physical identity or content digest must not be
silently overwritten in place.

Replacing content creates a new object identity and preserves the old
object's lifecycle/history.

Domain supersession/correction mechanisms continue to reference the
appropriate historical object.

---

## 48. P2A/P2B/P2C preservation

P2D is additive to the established authority, Auth/profile, command, and
security architecture.

P2D must preserve:

- Auth UUID to Haulvia profile mapping;
- active-membership authority checks;
- reauthentication requirements for sensitive operations;
- command idempotency;
- worker/human authority separation;
- P2C raw-client denial;
- controlled SECURITY DEFINER posture;
- append-only historical/audit behavior.

The additive P2D lifecycle permission does not redefine the earlier
authority model.

---

# Acceptance Requirements

## P2D-01
The migration runs without a Supabase `storage` schema.

## P2D-02
`private_storage_objects` exists.

## P2D-03
Private storage objects use a canonical UUID identity.

## P2D-04
Provider + bucket + object key is unique.

## P2D-05
AVAILABLE objects require provider, bucket, object key, media type, byte
size, and valid lowercase SHA-256 metadata.

## P2D-06
The content digest cannot be silently changed after availability.

## P2D-07
The P2D lifecycle contains RESERVED, AVAILABLE, QUARANTINED,
DELETION_PENDING, PURGED, and ABANDONED.

## P2D-08
Invalid storage lifecycle transitions are rejected.

## P2D-09
PURGED is terminal.

## P2D-10
ABANDONED is terminal.

## P2D-11
A RESERVED object cannot be used as ordinary binary-backed domain evidence.

## P2D-12
Finalization fails closed when no approved/effective retention policy can
resolve the object's retention class.

## P2D-13
P2D does not hard-code a legal retention duration.

## P2D-14
Finalization snapshots the exact retention policy version and class.

## P2D-15
Historical retention decisions remain stable after newer policy versions
exist.

## P2D-16
`retain_until` is persisted for a finalized object.

## P2D-17
An active hold blocks purge eligibility.

## P2D-18
Hold placement and release remain attributable.

## P2D-19
Deletion requests are represented explicitly.

## P2D-20
A deletion request alone does not mark an object PURGED.

## P2D-21
Purge is rejected before retention eligibility is satisfied.

## P2D-22
Purge is rejected while an active hold exists.

## P2D-23
Only trusted storage-worker/authorized lifecycle paths can confirm purge.

## P2D-24
Purge confirmation preserves the private-storage metadata row.

## P2D-25
Private-storage lifecycle events are append-only.

## P2D-26
Protected-object access events are append-only.

## P2D-27
Protected access records actor/context, action, purpose/result, and
timestamp without storing signed URLs or secrets.

## P2D-28
PUBLIC has no raw P2D relation privileges.

## P2D-29
`anon` has no raw P2D relation privileges.

## P2D-30
`authenticated` has no raw P2D relation privileges.

## P2D-31
P2D introduces no broad raw-table service-role grant.

## P2D-32
All P2D base tables have RLS enabled.

## P2D-33
P2D creates no permissive raw-table policy for `anon` or `authenticated`.

## P2D-34
P2D SECURITY DEFINER functions use controlled pinned search paths.

## P2D-35
P2D privileged functions are not owned by `anon` or `authenticated`.

## P2D-36
Only the intended P2D command wrappers are executable by `service_role`.

## P2D-37
Internal P2D helper functions remain unavailable to PUBLIC, `anon`,
`authenticated`, and direct `service_role` invocation unless explicitly
part of the allowlist.

## P2D-38
`PRIVATE_STORAGE_LIFECYCLE_MANAGE` exists and is sensitive.

## P2D-39
The lifecycle-management permission is not granted to customer/provider
driver roles.

## P2D-40
`STORAGE_WORKER` remains worker authority rather than a human RBAC role.

## P2D-41
Every compliance document references a canonical AVAILABLE private storage
object.

## P2D-42
Compliance documents no longer maintain an independent authoritative
storage key/content hash.

## P2D-43
Stop evidence may be structured-only.

## P2D-44
Binary-backed stop evidence references a canonical AVAILABLE private
storage object.

## P2D-45
The P2D stop-evidence command accepts `privateStorageObjectId` for binary
evidence and does not trust client-supplied raw storage key/hash as the
canonical binary identity.

## P2D-46
The compliance-document registration path is command-mediated and authority
checked.

## P2D-47
Externally callable P2D mutations preserve command idempotency.

## P2D-48
P2D preserves the established P2A/P2B/P2C identity, membership,
reauthentication, worker separation, audit, RLS, privilege, and SECURITY
DEFINER invariants.

---

# Implementation constraint

The P2D migration must be implementable and testable locally without
creating hosted Supabase resources.

Hosted private-bucket creation, provider credentials, signed-upload URL
generation, signed-download URL generation, and provider API execution are
adapter/deployment work and are not prerequisites for the local P2D
database acceptance suite.
