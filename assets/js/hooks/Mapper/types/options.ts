import { UserPermission } from '@/hooks/Mapper/types/permissions.ts';

export type StringBoolean = 'true' | 'false';

export type MapOptions = {
  allowed_copy_for: UserPermission;
  allowed_paste_for: UserPermission;
  layout: string;
  restrict_offline_showing: StringBoolean;
  show_linked_signature_id: StringBoolean;
  show_linked_signature_id_temp_name: StringBoolean;
  show_temp_system_name: StringBoolean;
  store_custom_labels: StringBoolean;
  // CHEWY PATCH: server-side map beautifier feature flag (WANDERER_MAP_BEAUTIFIER).
  beautifier_enabled?: StringBoolean;
  // CHEWY PATCH: cells of clearance between a wormhole chain and the k-space
  // system it hangs off (WANDERER_CHAIN_STANDOFF); "0" = upstream behaviour.
  chain_standoff_cells?: string;
  // CHEWY PATCH: quantize connection directions when beautifying
  // (WANDERER_ANGLE_SNAP); absent or "false" = upstream behaviour.
  angle_snap?: StringBoolean;
};
