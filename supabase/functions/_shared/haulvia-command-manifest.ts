// SERVER-ONLY.
// Do not import this module into the Expo application.
//
// Haulvia P2E explicit backend command manifest.
// Frozen baseline: 86 pre-P2E wrappers.
// P2E additions: 5 wrappers.
// Total approved backend command signatures: 91.
//
// No request-controlled SQL/function identifier may bypass this registry.

export const HAULVIA_COMMAND_MANIFEST = [
  {
    commandName: "command_abandon_private_storage_object",
    rpcFunction: "command_abandon_private_storage_object",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_accept_firm_route_match",
    rpcFunction: "command_accept_firm_route_match",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_advance_to_next_stop",
    rpcFunction: "command_advance_to_next_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_approve_private_storage_deletion",
    rpcFunction: "command_approve_private_storage_deletion",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_assign_cargo_to_stops",
    rpcFunction: "command_assign_cargo_to_stops",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_authorize_continue_after_stop_failure",
    rpcFunction: "command_authorize_continue_after_stop_failure",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_authorize_custody_transfer",
    rpcFunction: "command_authorize_custody_transfer",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_authorize_route_amendment",
    rpcFunction: "command_authorize_route_amendment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_cancel_assigned_before_custody",
    rpcFunction: "command_cancel_assigned_before_custody",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_cancel_before_any_custody",
    rpcFunction: "command_cancel_before_any_custody",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_cancel_draft",
    rpcFunction: "command_cancel_draft",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_cancel_marketplace_shipment",
    rpcFunction: "command_cancel_marketplace_shipment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_cancel_pre_assignment",
    rpcFunction: "command_cancel_pre_assignment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_cancel_private_storage_deletion",
    rpcFunction: "command_cancel_private_storage_deletion",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_close_failed_first_pickup",
    rpcFunction: "command_close_failed_first_pickup",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_close_last_active_offer",
    rpcFunction: "command_close_last_active_offer",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_complete_planned_route",
    rpcFunction: "command_complete_planned_route",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_complete_shipment",
    rpcFunction: "command_complete_shipment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_confirm_arrival_at_first_pickup",
    rpcFunction: "command_confirm_arrival_at_first_pickup",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_confirm_arrival_at_stop",
    rpcFunction: "command_confirm_arrival_at_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_confirm_driver_payout",
    rpcFunction: "command_confirm_driver_payout",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_confirm_paid_assignment",
    rpcFunction: "command_confirm_paid_assignment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_confirm_private_storage_purge",
    rpcFunction: "command_confirm_private_storage_purge",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_confirm_receiver_receipt",
    rpcFunction: "command_confirm_receiver_receipt",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_continue_route_after_failed_stop",
    rpcFunction: "command_continue_route_after_failed_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_copy_terminal_shipment_for_repost",
    rpcFunction: "command_copy_terminal_shipment_for_repost",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_correct_first_stop_arrival",
    rpcFunction: "command_correct_first_stop_arrival",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_correct_stop_arrival",
    rpcFunction: "command_correct_stop_arrival",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_counter_offer",
    rpcFunction: "command_counter_offer",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_edit_draft_route",
    rpcFunction: "command_edit_draft_route",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_edit_paused_after_driver_cancellation",
    rpcFunction: "command_edit_paused_after_driver_cancellation",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_edit_posted_shipment",
    rpcFunction: "command_edit_posted_shipment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_expire_confirmation_window",
    rpcFunction: "command_expire_confirmation_window",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_expire_listing",
    rpcFunction: "command_expire_listing",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_finalize_private_storage_object",
    rpcFunction: "command_finalize_private_storage_object",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_handle_payout_failure",
    rpcFunction: "command_handle_payout_failure",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_issue_refund_or_adjustment",
    rpcFunction: "command_issue_refund_or_adjustment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_mark_private_storage_deletion_pending",
    rpcFunction: "command_mark_private_storage_deletion_pending",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_materially_edit_negotiation",
    rpcFunction: "command_materially_edit_negotiation",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_open_dispute",
    rpcFunction: "command_open_dispute",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_open_post_delivery_dispute",
    rpcFunction: "command_open_post_delivery_dispute",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_pause_marketplace",
    rpcFunction: "command_pause_marketplace",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_place_private_storage_hold",
    rpcFunction: "command_place_private_storage_hold",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_post_shipment",
    rpcFunction: "command_post_shipment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_prepare_compliance_document_access",
    rpcFunction: "command_prepare_compliance_document_access",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_prepare_failed_first_pickup_repost",
    rpcFunction: "command_prepare_failed_first_pickup_repost",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_prepare_stop_evidence_access",
    rpcFunction: "command_prepare_stop_evidence_access",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_quarantine_private_storage_object",
    rpcFunction: "command_quarantine_private_storage_object",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_reconfirm_offer_or_firm_match",
    rpcFunction: "command_reconfirm_offer_or_firm_match",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_record_route_update",
    rpcFunction: "command_record_route_update",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_register_compliance_document",
    rpcFunction: "command_register_compliance_document",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_reject_private_storage_deletion",
    rpcFunction: "command_reject_private_storage_deletion",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_release_driver_before_any_custody",
    rpcFunction: "command_release_driver_before_any_custody",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_release_failed_reservation",
    rpcFunction: "command_release_failed_reservation",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_release_private_storage_hold",
    rpcFunction: "command_release_private_storage_hold",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_release_private_storage_quarantine",
    rpcFunction: "command_release_private_storage_quarantine",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_report_delivery_problem",
    rpcFunction: "command_report_delivery_problem",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_report_failed_delivery_stop",
    rpcFunction: "command_report_failed_delivery_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_report_failed_first_pickup",
    rpcFunction: "command_report_failed_first_pickup",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_report_failed_pickup_stop",
    rpcFunction: "command_report_failed_pickup_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_report_pre_custody_issue",
    rpcFunction: "command_report_pre_custody_issue",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_report_transit_issue",
    rpcFunction: "command_report_transit_issue",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_repost_paused_shipment",
    rpcFunction: "command_repost_paused_shipment",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_request_private_storage_deletion",
    rpcFunction: "command_request_private_storage_deletion",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_reserve_private_storage_object",
    rpcFunction: "command_reserve_private_storage_object",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_reserve_selection",
    rpcFunction: "command_reserve_selection",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_resolve_dispute",
    rpcFunction: "command_resolve_dispute",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_resume_after_resolution",
    rpcFunction: "command_resume_after_resolution",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_resume_marketplace",
    rpcFunction: "command_resume_marketplace",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_retry_failed_stop_same_driver",
    rpcFunction: "command_retry_failed_stop_same_driver",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_revise_offer",
    rpcFunction: "command_revise_offer",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_save_draft",
    rpcFunction: "command_save_draft",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_secure_cargo_in_storage",
    rpcFunction: "command_secure_cargo_in_storage",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_start_first_pickup_service",
    rpcFunction: "command_start_first_pickup_service",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_start_recovery_leg",
    rpcFunction: "command_start_recovery_leg",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_start_route",
    rpcFunction: "command_start_route",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_start_stop_service",
    rpcFunction: "command_start_stop_service",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_submit_driver_payout",
    rpcFunction: "command_submit_driver_payout",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_submit_first_pickup_evidence",
    rpcFunction: "command_submit_first_pickup_evidence",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_submit_independent_flex_offer",
    rpcFunction: "command_submit_independent_flex_offer",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_submit_partner_flex_offer",
    rpcFunction: "command_submit_partner_flex_offer",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_submit_stop_evidence",
    rpcFunction: "command_submit_stop_evidence",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_verify_delivery_stop",
    rpcFunction: "command_verify_delivery_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_verify_first_pickup",
    rpcFunction: "command_verify_first_pickup",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_verify_pickup_stop",
    rpcFunction: "command_verify_pickup_stop",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },  {
    commandName: "command_verify_return_handoff",
    rpcFunction: "command_verify_return_handoff",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "PRE_P2E",
  },
  {
    commandName: "command_cancel_provider_adapter_request",
    rpcFunction: "command_cancel_provider_adapter_request",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "P2E",
  },  {
    commandName: "command_dispatch_provider_webhook",
    rpcFunction: "command_dispatch_provider_webhook",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "P2E",
  },  {
    commandName: "command_prepare_provider_adapter_request",
    rpcFunction: "command_prepare_provider_adapter_request",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "P2E",
  },  {
    commandName: "command_receive_provider_webhook",
    rpcFunction: "command_receive_provider_webhook",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "P2E",
  },  {
    commandName: "command_record_provider_adapter_attempt",
    rpcFunction: "command_record_provider_adapter_attempt",
    identityArguments: "p_request jsonb",
    resultType: "jsonb",
    phase: "P2E",
  },
] as const;

export type HaulviaCommandManifestEntry =
  (typeof HAULVIA_COMMAND_MANIFEST)[number];

export type HaulviaCommandName =
  HaulviaCommandManifestEntry["commandName"];

export type HaulviaRpcFunctionName =
  HaulviaCommandManifestEntry["rpcFunction"];

export const PRE_P2E_COMMAND_COUNT = 86 as const;
export const P2E_COMMAND_COUNT = 5 as const;
export const TOTAL_COMMAND_COUNT = 91 as const;

const COMMAND_BY_NAME:
  ReadonlyMap<string, HaulviaCommandManifestEntry> =
  new Map(
    HAULVIA_COMMAND_MANIFEST.map(
      (entry) => [
        entry.commandName,
        entry,
      ] as const,
    ),
  );

export function resolveHaulviaCommand(
  commandName: string,
): HaulviaCommandManifestEntry | null {
  return COMMAND_BY_NAME.get(commandName) ?? null;
}

export function isHaulviaCommandName(
  commandName: string,
): commandName is HaulviaCommandName {
  return COMMAND_BY_NAME.has(commandName);
}