import {
  resolveHaulviaCommand,
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

  try {
    // Critical security invariant:
    // rpcFunction comes ONLY from the static manifest above.
    // invocation.commandName is never passed directly to rpc().
    const {
      data,
      error,
    } = await client.rpc(
      manifestEntry.rpcFunction,
      {
        p_request:
          invocation.request,
      },
    );

    if (error) {
      return {
        success: false,
        commandName:
          manifestEntry.commandName,
        correlationId,
        error:
          normalizeRpcError(
            error,
          ),
      };
    }

    return {
      success: true,
      commandName:
        manifestEntry.commandName,
      correlationId,
      result: data,
    };
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
}