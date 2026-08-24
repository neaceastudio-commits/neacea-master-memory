/**
 * Domain types aligned with supabase/migrations/20260824145626_initial_master_memory_schema.sql.
 * They intentionally contain no client configuration or secrets.
 */

export const memoryTypes = [
  'FACT',
  'PREFERENCE',
  'DECISION',
  'EVENT',
  'PROJECT_STATE',
  'PROCEDURE',
  'GOAL',
  'NOTE',
] as const;

export type MemoryType = (typeof memoryTypes)[number];

export const memoryStatuses = [
  'CURRENT',
  'SUPERSEDED',
  'ARCHIVED',
  'TO_VERIFY',
] as const;

export type MemoryStatus = (typeof memoryStatuses)[number];

export const sensitivityLevels = [
  'PUBLIC',
  'PRIVATE',
  'CONFIDENTIAL',
  'HIGHLY_SENSITIVE',
] as const;

export type SensitivityLevel = (typeof sensitivityLevels)[number];

export const sourceTypes = [
  'CONVERSATION',
  'DOCUMENT',
  'MANUAL_ENTRY',
  'SYSTEM_APPLICATION',
  'IMPORT',
] as const;

export type SourceType = (typeof sourceTypes)[number];

export const acquisitionModes = ['AUTOMATIC', 'CONFIRM', 'NEVER_AUTO'] as const;
export type AcquisitionMode = (typeof acquisitionModes)[number];

export const presenceStates = [
  'PRESENT_IN_MASTER',
  'CONVERSATION_ONLY',
  'DISMISSED',
] as const;

export type PresenceState = (typeof presenceStates)[number];

export type JsonObject = Record<string, unknown>;

export interface MemorySourceRow {
  id: string;
  owner_id: string;
  source_type: SourceType;
  source_label: string;
  source_reference: string | null;
  source_metadata: JsonObject;
  created_at: string;
}

export interface MemoryItemRow {
  id: string;
  owner_id: string;
  current_version_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface MemoryVersionRow {
  id: string;
  memory_id: string;
  version: number;
  supersedes_version_id: string | null;
  category: string;
  memory_type: MemoryType;
  title: string;
  content: string;
  status: Exclude<MemoryStatus, 'SUPERSEDED'>;
  sensitivity: SensitivityLevel;
  reliability: number;
  source_id: string;
  valid_from: string | null;
  valid_to: string | null;
  acquisition_mode: AcquisitionMode;
  metadata: JsonObject;
  created_at: string;
  updated_at: string;
}

export interface MemoryIntakeRecordRow {
  id: string;
  owner_id: string;
  source_id: string;
  memory_id: string | null;
  supersedes_intake_record_id: string | null;
  content_fingerprint: string;
  acquisition_mode: AcquisitionMode;
  presence_state: PresenceState;
  created_at: string;
}

export interface MemorySearchResult {
  memory_id: string;
  version_id: string;
  version: number;
  category: string;
  memory_type: MemoryType;
  title: string;
  content: string;
  status: MemoryStatus;
  sensitivity: SensitivityLevel;
  reliability: number;
  source_id: string;
  valid_from: string | null;
  valid_to: string | null;
  updated_at: string;
}
