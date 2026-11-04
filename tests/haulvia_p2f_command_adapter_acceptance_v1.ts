import {
  HAULVIA_COMMAND_MANIFEST,
  PRE_P2E_COMMAND_COUNT,
  P2E_COMMAND_COUNT,
  P2F_COMMAND_COUNT,
  TOTAL_COMMAND_COUNT,
  resolveHaulviaCommand,
} from "../supabase/functions/_shared/haulvia-command-manifest";

import {
  executeHaulviaCommand,
  type HaulviaRpcClient,
  type HaulviaRpcResult,
  type JsonObject,
} from "../supabase/functions/_shared/haulvia-command-adapter";


interface TestResult {
  name: string;
  passed: boolean;
  detail: string;
}


const results: TestResult[] = [];

const OBSERVATION_COMMAND =
  "command_record_command_failure_observation";

const BUSINESS_COMMAND =
  "command_prepare_provider_adapter_request";


function assertTest(
  name: string,
  condition: boolean,
  detail = "passed",
): void {
  results.push({
    name,
    passed:
      condition,
    detail:
      condition
        ? detail
        : "FAILED",
  });
}


function isLowerSha256(
  value: unknown,
): value is string {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{64}$/.test(
      value,
    )
  );
}


function domainRejection(): HaulviaRpcResult {
  return {
    data:
      null,

    error: {
      code:
        "P0001",

      message:
        "raise_exception sensitive raw database text",

      details:
        JSON.stringify({
          code:
            "IDEMPOTENCY_KEY_REUSED",

          message:
            "Provider idempotency key was already used",

          context: {
            existingRequestId:
              "f2f70000-0000-0000-0000-000000000099",
          },
        }),
    },
  };
}


function observationSuccess(): HaulviaRpcResult {
  return {
    data: {
      commandFailureObservationId:
        "f2f70000-0000-0000-0000-000000000090",

      replayed:
        false,
    },

    error:
      null,
  };
}


class FakeRpcClient
  implements HaulviaRpcClient {

  readonly calls: Array<{
    functionName: string;
    args: {
      p_request: JsonObject;
    };
  }> = [];


  constructor(
    private readonly handler: (
      functionName: string,
      args: {
        p_request: JsonObject;
      },
    ) =>
      | HaulviaRpcResult
      | PromiseLike<HaulviaRpcResult>,
  ) {}


  async rpc(
    functionName: string,
    args: {
      p_request: JsonObject;
    },
  ): Promise<HaulviaRpcResult> {
    this.calls.push({
      functionName,
      args,
    });

    return await this.handler(
      functionName,
      args,
    );
  }
}


async function main(): Promise<void> {

  assertTest(
    "01 manifest is exactly 86 PRE_P2E + 5 P2E + 1 P2F = 92",
    PRE_P2E_COMMAND_COUNT === 86 &&
      P2E_COMMAND_COUNT === 5 &&
      P2F_COMMAND_COUNT === 1 &&
      TOTAL_COMMAND_COUNT === 92 &&
      HAULVIA_COMMAND_MANIFEST.length ===
        92,
  );


  const uniqueNames =
    new Set(
      HAULVIA_COMMAND_MANIFEST.map(
        (entry) =>
          entry.commandName,
      ),
    );

  assertTest(
    "02 cumulative manifest has 92 unique command names",
    uniqueNames.size === 92,
  );


  const baselineEntry =
    resolveHaulviaCommand(
      "command_save_draft",
    );

  const p2eEntry =
    resolveHaulviaCommand(
      "command_dispatch_provider_webhook",
    );

  const p2fEntry =
    resolveHaulviaCommand(
      OBSERVATION_COMMAND,
    );

  assertTest(
    "03 manifest resolves all three phase boundaries",
    baselineEntry?.phase ===
      "PRE_P2E" &&
      baselineEntry.rpcFunction ===
        "command_save_draft" &&
      p2eEntry?.phase ===
        "P2E" &&
      p2eEntry.rpcFunction ===
        "command_dispatch_provider_webhook" &&
      p2fEntry?.phase ===
        "P2F" &&
      p2fEntry.rpcFunction ===
        OBSERVATION_COMMAND,
  );


  const unknownClient =
    new FakeRpcClient(
      () =>
        observationSuccess(),
    );

  const unknownResult =
    await executeHaulviaCommand(
      unknownClient,
      {
        commandName:
          "apply_p2f_record_command_failure_observation",

        correlationId:
          "f2f70000-0000-0000-0000-000000000001",

        request: {},
      },
    );

  assertTest(
    "04 unknown helper remains rejected before RPC",
    unknownResult.success === false &&
      unknownResult.error.code ===
        "UNKNOWN_COMMAND" &&
      unknownClient.calls.length ===
        0,
  );


  const rawIdempotencyKey =
    "RAW-IDEMPOTENCY-KEY-MUST-NOT-BE-OBSERVED";

  const rawSecret =
    "RAW-PROVIDER-SECRET-MUST-NOT-BE-OBSERVED";

  const businessRequest: JsonObject = {
    actorProfileId:
      "f2f70000-0000-0000-0000-000000000011",

    organizationId:
      "f2f70000-0000-0000-0000-000000000012",

    shipmentId:
      "f2f70000-0000-0000-0000-000000000013",

    idempotencyKey:
      rawIdempotencyKey,

    operation:
      "PAYMENT_AUTHORIZE",

    providerSecret:
      rawSecret,

    nested: {
      credential:
        rawSecret,
    },
  };


  const observedClient =
    new FakeRpcClient(
      (functionName) => {
        if (
          functionName ===
            OBSERVATION_COMMAND
        ) {
          return observationSuccess();
        }

        return domainRejection();
      },
    );


  const observedResult =
    await executeHaulviaCommand(
      observedClient,
      {
        commandName:
          BUSINESS_COMMAND,

        correlationId:
          "f2f70000-0000-0000-0000-000000000020",

        request:
          businessRequest,
      },
    );


  assertTest(
    "05 original normalized database rejection remains caller-visible",
    observedResult.success === false &&
      observedResult.commandName ===
        BUSINESS_COMMAND &&
      observedResult.error.code ===
        "IDEMPOTENCY_KEY_REUSED" &&
      observedResult.error.message ===
        "Provider idempotency key was already used",
  );


  assertTest(
    "06 confirmed database rejection performs exactly original RPC then one observation RPC",
    observedClient.calls.length ===
      2 &&
      observedClient.calls[0]
        .functionName ===
        BUSINESS_COMMAND &&
      observedClient.calls[1]
        .functionName ===
        OBSERVATION_COMMAND,
  );


  const observationPayload =
    observedClient.calls[1]
      .args
      .p_request;


  assertTest(
    "07 observation payload contains only trusted sanitized failure facts",
    observationPayload.actorProfileId ===
        null &&
      observationPayload.workerAuthority ===
        "OBSERVABILITY_WORKER" &&
      observationPayload.sourceCode ===
        "COMMAND_ADAPTER" &&
      observationPayload.failedCommandName ===
        BUSINESS_COMMAND &&
      observationPayload.failedActorProfileId ===
        "f2f70000-0000-0000-0000-000000000011" &&
      observationPayload.failedOrganizationId ===
        "f2f70000-0000-0000-0000-000000000012" &&
      observationPayload.failedShipmentId ===
        "f2f70000-0000-0000-0000-000000000013" &&
      observationPayload.correlationId ===
        "f2f70000-0000-0000-0000-000000000020" &&
      observationPayload.errorCode ===
        "IDEMPOTENCY_KEY_REUSED" &&
      observationPayload.sqlstate ===
        "P0001" &&
      observationPayload.retryable ===
        false,
  );


  const serializedObservation =
    JSON.stringify(
      observationPayload,
    );

  assertTest(
    "08 observation path receives no raw request payload idempotency key error text or secret",
    !(
      "request" in observationPayload
    ) &&
      !(
        "idempotencyKey" in
          observationPayload
      ) &&
      !serializedObservation.includes(
        rawIdempotencyKey,
      ) &&
      !serializedObservation.includes(
        rawSecret,
      ) &&
      !serializedObservation.includes(
        "sensitive raw database text",
      ),
  );


  assertTest(
    "09 request idempotency and observation identities are SHA-256 based",
    isLowerSha256(
      observationPayload.requestSha256,
    ) &&
      isLowerSha256(
        observationPayload.idempotencyKeySha256,
      ) &&
      typeof observationPayload.observationKey ===
        "string" &&
      /^command-adapter:[0-9a-f]{64}$/.test(
        observationPayload.observationKey,
      ),
  );


  const replayClient =
    new FakeRpcClient(
      (functionName) => {
        if (
          functionName ===
            OBSERVATION_COMMAND
        ) {
          return observationSuccess();
        }

        return domainRejection();
      },
    );


  const replayInvocation = {
    commandName:
      BUSINESS_COMMAND,

    correlationId:
      "f2f70000-0000-0000-0000-000000000030",

    request:
      businessRequest,
  } as const;


  await executeHaulviaCommand(
    replayClient,
    replayInvocation,
  );

  await executeHaulviaCommand(
    replayClient,
    replayInvocation,
  );


  const replayObservationCalls =
    replayClient.calls.filter(
      (call) =>
        call.functionName ===
          OBSERVATION_COMMAND,
    );


  assertTest(
    "10 exact rejected-invocation replay reuses deterministic observation identity",
    replayObservationCalls.length ===
      2 &&
      replayObservationCalls[0]
        .args
        .p_request
        .observationKey ===
        replayObservationCalls[1]
          .args
          .p_request
          .observationKey &&
      replayObservationCalls[0]
        .args
        .p_request
        .requestSha256 ===
        replayObservationCalls[1]
          .args
          .p_request
          .requestSha256,
  );


  await executeHaulviaCommand(
    replayClient,
    {
      ...replayInvocation,

      correlationId:
        "f2f70000-0000-0000-0000-000000000031",
    },
  );


  const distinctObservationCalls =
    replayClient.calls.filter(
      (call) =>
        call.functionName ===
          OBSERVATION_COMMAND,
    );


  assertTest(
    "11 later distinct rejected invocation receives a different observation identity",
    distinctObservationCalls.length ===
      3 &&
      distinctObservationCalls[2]
        .args
        .p_request
        .observationKey !==
        distinctObservationCalls[0]
          .args
          .p_request
          .observationKey,
  );


  const retryClient =
    new FakeRpcClient(
      (functionName) => {
        if (
          functionName ===
            OBSERVATION_COMMAND
        ) {
          return observationSuccess();
        }

        return {
          data:
            null,

          error: {
            code:
              "40001",

            message:
              "serialization failure raw text",
          },
        };
      },
    );


  await executeHaulviaCommand(
    retryClient,
    {
      commandName:
        BUSINESS_COMMAND,

      correlationId:
        "f2f70000-0000-0000-0000-000000000040",

      request: {},
    },
  );


  const retryPayload =
    retryClient.calls[1]
      .args
      .p_request;


  assertTest(
    "12 retryable DB SQLSTATE is recorded without raw database message",
    retryPayload.sqlstate ===
        "40001" &&
      retryPayload.errorCode ===
        "40001" &&
      retryPayload.retryable ===
        true &&
      !JSON.stringify(
        retryPayload,
      ).includes(
        "serialization failure raw text",
      ),
  );


  const selfFailureClient =
    new FakeRpcClient(
      () =>
        domainRejection(),
    );


  const selfFailure =
    await executeHaulviaCommand(
      selfFailureClient,
      {
        commandName:
          OBSERVATION_COMMAND,

        correlationId:
          "f2f70000-0000-0000-0000-000000000050",

        request: {
          workerAuthority:
            "OBSERVABILITY_WORKER",
        },
      },
    );


  assertTest(
    "13 observation-writer rejection never recursively observes itself",
    selfFailure.success === false &&
      selfFailure.error.code ===
        "IDEMPOTENCY_KEY_REUSED" &&
      selfFailureClient.calls.length ===
        1 &&
      selfFailureClient.calls[0]
        .functionName ===
        OBSERVATION_COMMAND,
  );


  const originalConsoleError =
    console.error;

  const rpcFailureLogs: unknown[][] =
    [];

  console.error =
    (...args: unknown[]): void => {
      rpcFailureLogs.push(
        args,
      );
    };


  const observationRpcFailureClient =
    new FakeRpcClient(
      (functionName) => {
        if (
          functionName ===
            OBSERVATION_COMMAND
        ) {
          return {
            data:
              null,

            error: {
              code:
                "P0001",

              message:
                "observer writer raw failure",

              details:
                JSON.stringify({
                  code:
                    "OBSERVATION_WRITE_CONFLICT",

                  message:
                    "Observer write failed",
                }),
            },
          };
        }

        return domainRejection();
      },
    );


  let observationRpcFailureResult;

  try {
    observationRpcFailureResult =
      await executeHaulviaCommand(
        observationRpcFailureClient,
        {
          commandName:
            BUSINESS_COMMAND,

          correlationId:
            "f2f70000-0000-0000-0000-000000000060",

          request: {},
        },
      );
  } finally {
    console.error =
      originalConsoleError;
  }


  assertTest(
    "14 observation RPC rejection preserves original failure and emits trusted-server diagnostic",
    observationRpcFailureResult.success ===
        false &&
      observationRpcFailureResult.error.code ===
        "IDEMPOTENCY_KEY_REUSED" &&
      observationRpcFailureClient.calls.length ===
        2 &&
      rpcFailureLogs.length ===
        1 &&
      rpcFailureLogs[0][0] ===
        "HAULVIA_COMMAND_FAILURE_OBSERVATION_WRITE_FAILED",
  );


  const transportFailureLogs: unknown[][] =
    [];

  console.error =
    (...args: unknown[]): void => {
      transportFailureLogs.push(
        args,
      );
    };


  const observationTransportFailureClient =
    new FakeRpcClient(
      (functionName) => {
        if (
          functionName ===
            OBSERVATION_COMMAND
        ) {
          throw new Error(
            "simulated observation transport failure",
          );
        }

        return domainRejection();
      },
    );


  let observationTransportFailureResult;

  try {
    observationTransportFailureResult =
      await executeHaulviaCommand(
        observationTransportFailureClient,
        {
          commandName:
            BUSINESS_COMMAND,

          correlationId:
            "f2f70000-0000-0000-0000-000000000061",

          request: {},
        },
      );
  } finally {
    console.error =
      originalConsoleError;
  }


  assertTest(
    "15 observation transport failure preserves original failure without recursion",
    observationTransportFailureResult.success ===
        false &&
      observationTransportFailureResult.error.code ===
        "IDEMPOTENCY_KEY_REUSED" &&
      observationTransportFailureClient.calls.length ===
        2 &&
      transportFailureLogs.length ===
        1 &&
      transportFailureLogs[0][0] ===
        "HAULVIA_COMMAND_FAILURE_OBSERVATION_WRITE_FAILED",
  );


  const commandTransportClient =
    new FakeRpcClient(
      () => {
        throw new Error(
          "simulated original command transport failure",
        );
      },
    );


  const commandTransportResult =
    await executeHaulviaCommand(
      commandTransportClient,
      {
        commandName:
          BUSINESS_COMMAND,

        correlationId:
          "f2f70000-0000-0000-0000-000000000070",

        request: {},
      },
    );


  assertTest(
    "16 original transport-only failure never invokes observation writer",
    commandTransportResult.success ===
        false &&
      commandTransportResult.error.code ===
        "BACKEND_COMMAND_TRANSPORT_ERROR" &&
      commandTransportClient.calls.length ===
        1 &&
      commandTransportClient.calls[0]
        .functionName ===
        BUSINESS_COMMAND,
  );


  console.log("");
  console.log(
    "================ P2F COMMAND ADAPTER RESULTS ================",
  );
  console.log("");

  for (const result of results) {
    console.log(
      `${result.passed ? "PASS" : "FAIL"} | ${result.name} | ${result.detail}`,
    );
  }


  const passed =
    results.filter(
      (result) =>
        result.passed,
    ).length;

  const failed =
    results.length -
    passed;


  console.log("");
  console.log(
    "================ P2F COMMAND ADAPTER SUMMARY ================",
  );
  console.log("");

  console.log(
    `total_tests=${results.length}`,
  );

  console.log(
    `passed_tests=${passed}`,
  );

  console.log(
    `failed_tests=${failed}`,
  );


  if (
    results.length !== 16 ||
    passed !== 16 ||
    failed !== 0
  ) {
    throw new Error(
      `P2F adapter acceptance failed: ${passed}/${results.length} passed`,
    );
  }
}


main().catch(
  (error) => {
    console.error(error);
    throw error;
  },
);
