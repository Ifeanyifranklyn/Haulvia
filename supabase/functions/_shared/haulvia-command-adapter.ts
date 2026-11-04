import {
  resolveHaulviaCommand,
  type HaulviaCommandManifestEntry,
  type HaulviaCommandName,
} from "./haulvia-command-manifest";


export type JsonPrimitive =
  | string
  | number
  | boolean
  | null;


export type JsonValue =
  | JsonPrimitive
  | JsonObject
  | JsonValue[];


export interface JsonObject {
  [key: string]: JsonValue;
}


export interface HaulviaRpcError {
  code?: string | null;
  message?: string | null;
  details?: string | null;
  hint?: string | null;
}


export interface HaulviaRpcResult {
  data: unknown;
  error: HaulviaRpcError | null;
}


export interface HaulviaRpcClient {
  rpc(
    functionName: string,
    args: {
      p_request: JsonObject;
    },
  ): PromiseLike<HaulviaRpcResult>;
}


export interface HaulviaCommandInvocation {
  commandName: string;
  correlationId: string;
  request: JsonObject;
}


export interface HaulviaNormalizedError {
  code: string;
  message: string;
  details?: JsonObject;
}


export type HaulviaCommandResultEnvelope =
  | {
      success: true;
      commandName: HaulviaCommandName;
      correlationId: string;
      result: unknown;
    }
  | {
      success: false;
      commandName: string;
      correlationId: string;
      error: HaulviaNormalizedError;
    };


const FAILURE_OBSERVATION_COMMAND_NAME =
  "command_record_command_failure_observation";


const RETRYABLE_DATABASE_SQLSTATES =
  new Set([
    "40001",
    "40P01",
    "55P03",
  ]);


function isObject(
  value: unknown,
): value is Record<string, unknown> {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value)
  );
}


function parseStructuredErrorDetail(
  details: string | null | undefined,
): Record<string, unknown> | null {
  if (!details) {
    return null;
  }

  try {
    const parsed: unknown =
      JSON.parse(details);

    return isObject(parsed)
      ? parsed
      : null;
  } catch {
    return null;
  }
}


function optionalString(
  value: unknown,
): string | null {
  return (
    typeof value === "string" &&
    value.length > 0
  )
    ? value
    : null;
}


function optionalTrimmedString(
  value: unknown,
): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const trimmed =
    value.trim();

  return trimmed.length > 0
    ? trimmed
    : null;
}


function optionalUuid(
  value: unknown,
): string | null {
  const candidate =
    optionalTrimmedString(
      value,
    );

  if (
    candidate === null ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      candidate,
    )
  ) {
    return null;
  }

  return candidate.toLowerCase();
}


function normalizeSqlstate(
  value: unknown,
): string | null {
  const candidate =
    optionalTrimmedString(
      value,
    );

  if (candidate === null) {
    return null;
  }

  const normalized =
    candidate.toUpperCase();

  return /^[0-9A-Z]{5}$/.test(
    normalized,
  )
    ? normalized
    : null;
}


function sanitizeStableErrorCode(
  value: string,
): string {
  const normalized =
    value
      .trim()
      .toUpperCase()
      .replace(
        /[^A-Z0-9_.:-]+/g,
        "_",
      )
      .slice(
        0,
        200,
      );

  return (
    normalized.length > 0 &&
    /^[A-Z0-9_]/.test(
      normalized,
    )
  )
    ? normalized
    : "HAULVIA_COMMAND_FAILED";
}


function canonicalJson(
  value: JsonValue,
): string {
  if (value === null) {
    return "null";
  }

  if (Array.isArray(value)) {
    return (
      "[" +
      value
        .map(
          (entry) =>
            canonicalJson(
              entry,
            ),
        )
        .join(",") +
      "]"
    );
  }

  if (typeof value === "object") {
    const keys =
      Object.keys(
        value,
      ).sort();

    return (
      "{" +
      keys
        .map(
          (key) =>
            JSON.stringify(key) +
            ":" +
            canonicalJson(
              value[key],
            ),
        )
        .join(",") +
      "}"
    );
  }

  if (typeof value === "string") {
    return JSON.stringify(
      value,
    );
  }

  if (typeof value === "number") {
    return Number.isFinite(
      value,
    )
      ? String(value)
      : "null";
  }

  return value
    ? "true"
    : "false";
}


async function sha256Hex(
  value: string,
): Promise<string> {
  const bytes =
    new TextEncoder()
      .encode(
        value,
      );

  const digest =
    await globalThis.crypto
      .subtle
      .digest(
        "SHA-256",
        bytes,
      );

  return Array.from(
    new Uint8Array(
      digest,
    ),
    (byte) =>
      byte
        .toString(16)
        .padStart(
          2,
          "0",
        ),
  ).join("");
}


function normalizeRpcError(
  error: HaulviaRpcError,
): HaulviaNormalizedError {
  const structured =
    parseStructuredErrorDetail(
      error.details,
    );

  const structuredCode =
    structured
      ? optionalString(
          structured.code,
        )
      : null;

  const structuredMessage =
    structured
      ? optionalString(
          structured.message,
        )
      : null;

  const context =
    structured &&
    isObject(
      structured.context,
    )
      ? structured.context as JsonObject
      : undefined;

  return {
    code:
      structuredCode ??
      optionalString(error.code) ??
      "HAULVIA_COMMAND_FAILED",

    message:
      structuredMessage ??
      "Haulvia command was rejected",

    ...(context
      ? {
          details: context,
        }
      : {}),
  };
}


function logObservationWriteFailure(
  failedCommandName: string,
  correlationId: string,
  observerErrorCode: string,
): void {
  console.error(
    "HAULVIA_COMMAND_FAILURE_OBSERVATION_WRITE_FAILED",
    {
      failedCommandName,
      correlationId,
      observerErrorCode:
        sanitizeStableErrorCode(
          observerErrorCode,
        ),
    },
  );
}


async function tryRecordCommandFailureObservation(
  client: HaulviaRpcClient,
  failedManifestEntry: HaulviaCommandManifestEntry,
  correlationId: string,
  request: JsonObject,
  normalizedError: HaulviaNormalizedError,
  rpcError: HaulviaRpcError,
): Promise<void> {

  if (
    failedManifestEntry.commandName ===
      FAILURE_OBSERVATION_COMMAND_NAME
  ) {
    return;
  }


  const observerManifestEntry =
    resolveHaulviaCommand(
      FAILURE_OBSERVATION_COMMAND_NAME,
    );

  if (!observerManifestEntry) {
    logObservationWriteFailure(
      failedManifestEntry.commandName,
      correlationId,
      "OBSERVATION_COMMAND_NOT_MANIFESTED",
    );

    return;
  }


  try {
    const requestSha256 =
      await sha256Hex(
        canonicalJson(
          request,
        ),
      );

    const rawIdempotencyKey =
      optionalTrimmedString(
        request.idempotencyKey,
      );

    const idempotencyKeySha256 =
      rawIdempotencyKey === null
        ? null
        : await sha256Hex(
            rawIdempotencyKey,
          );

    const sqlstate =
      normalizeSqlstate(
        rpcError.code,
      );

    const errorCode =
      sanitizeStableErrorCode(
        normalizedError.code,
      );


    const observationIdentity =
      [
        failedManifestEntry.commandName,
        correlationId,
        requestSha256,
        errorCode,
        sqlstate ?? "",
      ].join("\n");


    const observationKey =
      "command-adapter:" +
      await sha256Hex(
        observationIdentity,
      );


    const observationRequest: JsonObject = {
      actorProfileId:
        null,

      workerAuthority:
        "OBSERVABILITY_WORKER",

      observationKey,

      sourceCode:
        "COMMAND_ADAPTER",

      failedCommandName:
        failedManifestEntry.commandName,

      correlationId:
        correlationId.length <= 200
          ? correlationId
          : null,

      requestSha256,

      errorCode,

      sqlstate,

      retryable:
        sqlstate !== null &&
        RETRYABLE_DATABASE_SQLSTATES.has(
          sqlstate,
        ),
    };


    const failedActorProfileId =
      optionalUuid(
        request.actorProfileId,
      );

    const failedOrganizationId =
      optionalUuid(
        request.organizationId,
      );

    const failedShipmentId =
      optionalUuid(
        request.shipmentId,
      );


    if (failedActorProfileId !== null) {
      observationRequest.failedActorProfileId =
        failedActorProfileId;
    }

    if (failedOrganizationId !== null) {
      observationRequest.failedOrganizationId =
        failedOrganizationId;
    }

    if (failedShipmentId !== null) {
      observationRequest.failedShipmentId =
        failedShipmentId;
    }

    if (idempotencyKeySha256 !== null) {
      observationRequest.idempotencyKeySha256 =
        idempotencyKeySha256;
    }


    const observationResult =
      await client.rpc(
        observerManifestEntry.rpcFunction,
        {
          p_request:
            observationRequest,
        },
      );


    if (observationResult.error) {
      const observerError =
        normalizeRpcError(
          observationResult.error,
        );

      logObservationWriteFailure(
        failedManifestEntry.commandName,
        correlationId,
        observerError.code,
      );
    }
  } catch {
    logObservationWriteFailure(
      failedManifestEntry.commandName,
      correlationId,
      "OBSERVATION_WRITE_TRANSPORT_ERROR",
    );
  }
}


export async function executeHaulviaCommand(
  client: HaulviaRpcClient,
  invocation: HaulviaCommandInvocation,
): Promise<HaulviaCommandResultEnvelope> {
  const correlationId =
    invocation.correlationId.trim();

  if (!correlationId) {
    return {
      success: false,
      commandName:
        invocation.commandName,
      correlationId: "",
      error: {
        code:
          "INVALID_CORRELATION_ID",
        message:
          "A correlation ID is required",
      },
    };
  }


  const manifestEntry =
    resolveHaulviaCommand(
      invocation.commandName,
    );

  if (!manifestEntry) {
    return {
      success: false,
      commandName:
        invocation.commandName,
      correlationId,
      error: {
        code:
          "UNKNOWN_COMMAND",
        message:
          "Command is not present in the approved Haulvia backend manifest",
      },
    };
  }


  let rpcResult: HaulviaRpcResult;

  try {
    rpcResult =
      await client.rpc(
        manifestEntry.rpcFunction,
        {
          p_request:
            invocation.request,
        },
      );
  } catch {
    return {
      success: false,
      commandName:
        manifestEntry.commandName,
      correlationId,
      error: {
        code:
          "BACKEND_COMMAND_TRANSPORT_ERROR",
        message:
          "The backend command transport failed",
      },
    };
  }


  if (rpcResult.error) {
    const normalizedError =
      normalizeRpcError(
        rpcResult.error,
      );

    await tryRecordCommandFailureObservation(
      client,
      manifestEntry,
      correlationId,
      invocation.request,
      normalizedError,
      rpcResult.error,
    );

    return {
      success: false,
      commandName:
        manifestEntry.commandName,
      correlationId,
      error:
        normalizedError,
    };
  }


  return {
    success: true,
    commandName:
      manifestEntry.commandName,
    correlationId,
    result:
      rpcResult.data,
  };
}
