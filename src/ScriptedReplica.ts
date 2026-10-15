import { NativeModule, requireNativeModule, SharedObject } from 'expo';

import type { DocumentSession } from './DocumentSession';

/** Progress of the scripted concurrent nested-list scenario. */
export type NestedListScenarioPhase = 'idle' | 'seeding' | 'holding' | 'delivering' | 'converged';

export type ScriptedReplicaEvents = {
  scenarioChange(event: { phase: NestedListScenarioPhase }): void;
};

/**
 * Test-only: another replica of a session's document, with its own temporary store, connected to the
 * session through the in-process delivery harness. It is not a sync adapter.
 */
export declare class ScriptedReplica extends SharedObject<ScriptedReplicaEvents> {
  /**
   * Replaces `deleteCount` UTF-16 code units at `offset` in the replica's text with `text`, once every
   * earlier operation has been delivered.
   */
  edit(offset: number, deleteCount: number, text: string): Promise<void>;
  /**
   * Writes the list Parent (checklist) > Child (unordered) > Grandchild (ordered) and delivers it. Once
   * the session shows it, removes only Child and checks Parent, then holds delivery ('holding') until
   * `resumeDelivery()`, so edits made meanwhile are concurrent with the removal. Reports 'converged'
   * when both replicas show the same document.
   */
  startNestedListScenario(): Promise<void>;
  resumeDelivery(): Promise<void>;
}

declare class ScriptedReplicaModule extends NativeModule {
  connectScriptedReplica(session: DocumentSession): Promise<ScriptedReplica>;
}

const nativeModule = requireNativeModule<ScriptedReplicaModule>('ExpoNativeCollaborativeEditor');

/** Test-only: connects a scripted remote replica to the session's document. */
export function connectScriptedReplica(session: DocumentSession): Promise<ScriptedReplica> {
  return nativeModule.connectScriptedReplica(session);
}
