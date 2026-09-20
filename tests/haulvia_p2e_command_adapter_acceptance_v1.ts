import {
  HAULVIA_COMMAND_MANIFEST,
  PRE_P2E_COMMAND_COUNT,
  P2E_COMMAND_COUNT,
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


function assertTest(
  name: string,
  condition: boolean,
  detail = "passed",
): void {
  results.push({
    name,
    passed: condition,
    detail: condition
      ? detail
      : "FAILED",
  });
}


function jsonEqual(
  left: unknown,
  right: unknown,
): boolean {
  return (
    JSON.stringify(left) ===
    JSON.stringify(right)
  );
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

  // ==========================================================================
  // Manifest shape
  // ==========================================================================

  assertTest(
    "01 manifest exposes frozen 86 + 5 = 91 command counts",
    PRE_P2E_COMMAND_COUNT === 86 &&
      P2E_COMMAND_COUNT === 5 &&
      TOTAL_COMMAND_COUNT === 91 &&
      HAULVIA_COMMAND_MANIFEST.length === 91,
  );


  const uniqueNames =
    new Set(
      HAULVIA_COMMAND_MANIFEST.map(
        (entry) =>
          entry.commandName,
      ),
    );


  assertTest(
    "02 manifest contains 91 unique command names",
    uniqueNames.size === 91,
  );


  const baselineCommand =
    resolveHaulviaCommand(
      "command_save_draft",
    );

  const p2eCommand =
    resolveHaulviaCommand(
      "command_dispatch_provider_webhook",
    );


  assertTest(
    "03 manifest resolves both pre-P2E and P2E commands",
    baselineCommand !== null &&
      baselineCommand.phase ===
        "PRE_P2E" &&
      baselineCommand.rpcFunction ===
        "command_save_draft" &&
      p2eCommand !== null &&
      p2eCommand.phase ===
        "P2E" &&
      p2eCommand.rpcFunction ===
        "command_dispatch_provider_webhook",
  );


  assertTest(
    "04 unknown command does not resolve",
    resolveHaulviaCommand(
      "apply_p2e_dispatch_provider_webhook",
    ) === null,
  );


  // ==========================================================================
  // Correlation requirement
  // ==========================================================================

  const invalidCorrelationClient =
    new FakeRpcClient(
      () => ({
        data: {
          impossible:
            true,
        },
        error: null,
      }),
    );


  const invalidCorrelation =
    await executeHaulviaCommand(
      invalidCorrelationClient,
      {
        commandName:
          "command_save_draft",

        correlationId:
          "   ",

        request: {
          shipmentId:
            "fixture",
        },
      },
    );


  assertTest(
    "05 blank correlation ID is rejected before RPC",
    invalidCorrelation.success === false &&
      invalidCorrelation.error.code ===
        "INVALID_CORRELATION_ID" &&
      invalidCorrelationClient.calls.length ===
        0,
  );


  // ==========================================================================
  // Unknown command rejection
  // ==========================================================================

  const unknownClient =
    new FakeRpcClient(
      () => ({
        data: {
          impossible:
            true,
        },
        error: null,
      }),
    );


  const unknown =
    await executeHaulviaCommand(
      unknownClient,
      {
        commandName:
          "apply_p2e_dispatch_provider_webhook",

        correlationId:
          "f2e60000-0000-0000-0000-000000000001",

        request: {},
      },
    );


  assertTest(
    "06 internal helper name is rejected before RPC",
    unknown.success === false &&
      unknown.error.code ===
        "UNKNOWN_COMMAND" &&
      unknown.commandName ===
        "apply_p2e_dispatch_provider_webhook" &&
      unknown.correlationId ===
        "f2e60000-0000-0000-0000-000000000001" &&
      unknownClient.calls.length ===
        0,
  );


  // ==========================================================================
  // Successful command normalization
  // ==========================================================================

  const successRequest: JsonObject = {
    shipmentId:
      "f2e60000-0000-0000-0000-000000000010",

    expectedShipmentVersion:
      7,

    idempotencyKey:
      "adapter-acceptance-success",
  };


  const successClient =
    new FakeRpcClient(
      (
        functionName,
        args,
      ) => ({
        data: {
          accepted:
            true,

          functionName,

          echoedRequest:
            args.p_request,
        },

        error:
          null,
      }),
    );


  const success =
    await executeHaulviaCommand(
      successClient,
      {
        commandName:
          "command_save_draft",

        correlationId:
          "  f2e60000-0000-0000-0000-000000000002  ",

        request:
          successRequest,
      },
    );


  assertTest(
    "07 successful RPC returns normalized success envelope",
    success.success === true &&
      success.commandName ===
        "command_save_draft" &&
      success.correlationId ===
        "f2e60000-0000-0000-0000-000000000002",
  );


  assertTest(
    "08 successful RPC uses manifest function and exact p_request",
    successClient.calls.length === 1 &&
      successClient.calls[0]
        .functionName ===
        "command_save_draft" &&
      jsonEqual(
        successClient.calls[0]
          .args.p_request,
        successRequest,
      ),
  );


  // ==========================================================================
  // Structured Haulvia domain rejection
  // ==========================================================================

  const domainErrorClient =
    new FakeRpcClient(
      () => ({
        data:
          null,

        error: {
          code:
            "P0001",

          message:
            "raise_exception",

          details:
            JSON.stringify({
              code:
                "IDEMPOTENCY_KEY_REUSED",

              message:
                "Provider idempotency key was already used",

              context: {
                existingRequestId:
                  "f2e60000-0000-0000-0000-000000000099",

                externalProvider:
                  "TESTPAY",
              },
            }),
        },
      }),
    );


  const domainError =
    await executeHaulviaCommand(
      domainErrorClient,
      {
        commandName:
          "command_prepare_provider_adapter_request",

        correlationId:
          "f2e60000-0000-0000-0000-000000000003",

        request: {
          operation:
            "PAYMENT_AUTHORIZE",
        },
      },
    );


  assertTest(
    "09 structured Haulvia error code and message are preserved",
    domainError.success === false &&
      domainError.commandName ===
        "command_prepare_provider_adapter_request" &&
      domainError.correlationId ===
        "f2e60000-0000-0000-0000-000000000003" &&
      domainError.error.code ===
        "IDEMPOTENCY_KEY_REUSED" &&
      domainError.error.message ===
        "Provider idempotency key was already used",
  );


  assertTest(
    "10 safe structured error context is preserved",
    domainError.success === false &&
      jsonEqual(
        domainError.error.details,
        {
          existingRequestId:
            "f2e60000-0000-0000-0000-000000000099",

          externalProvider:
            "TESTPAY",
        },
      ),
  );


  // ==========================================================================
  // Unstructured RPC rejection
  // ==========================================================================

  const unstructuredClient =
    new FakeRpcClient(
      () => ({
        data:
          null,

        error: {
          code:
            "42501",

          message:
            "permission denied",

          details:
            "non-json provider/database detail",
        },
      }),
    );


  const unstructured =
    await executeHaulviaCommand(
      unstructuredClient,
      {
        commandName:
          "command_receive_provider_webhook",

        correlationId:
          "f2e60000-0000-0000-0000-000000000004",

        request: {},
      },
    );


  assertTest(
    "11 unstructured database failure uses safe normalized fallback",
    unstructured.success === false &&
      unstructured.error.code ===
        "42501" &&
      unstructured.error.message ===
        "Haulvia command was rejected" &&
      unstructured.error.details ===
        undefined,
  );


  // ==========================================================================
  // Transport failure
  // ==========================================================================

  const transportClient =
    new FakeRpcClient(
      () => {
        throw new Error(
          "simulated network transport failure",
        );
      },
    );


  const transport =
    await executeHaulviaCommand(
      transportClient,
      {
        commandName:
          "command_record_provider_adapter_attempt",

        correlationId:
          "f2e60000-0000-0000-0000-000000000005",

        request: {},
      },
    );


  assertTest(
    "12 transport exception returns normalized transport failure",
    transport.success === false &&
      transport.commandName ===
        "command_record_provider_adapter_attempt" &&
      transport.correlationId ===
        "f2e60000-0000-0000-0000-000000000005" &&
      transport.error.code ===
        "BACKEND_COMMAND_TRANSPORT_ERROR" &&
      transport.error.message ===
        "The backend command transport failed",
  );


  assertTest(
    "13 transport failure still invoked only manifest-resolved RPC function",
    transportClient.calls.length === 1 &&
      transportClient.calls[0]
        .functionName ===
        "command_record_provider_adapter_attempt",
  );


  // ==========================================================================
  // Results
  // ==========================================================================

  console.log("");
  console.log(
    "================ P2E COMMAND ADAPTER RESULTS ================",
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
    "================ P2E COMMAND ADAPTER SUMMARY ================",
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
    results.length !== 13 ||
    passed !== 13 ||
    failed !== 0
  ) {
    throw new Error(
      `P2E adapter acceptance failed: ${passed}/${results.length} passed`,
    );
  }
}


main().catch(
  (error) => {
    console.error(error);
    throw error;
  },
);