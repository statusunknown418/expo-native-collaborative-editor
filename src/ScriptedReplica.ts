import { NativeModule, requireNativeModule, SharedObject } from 'expo';

import type { DocumentSession } from './DocumentSession';

/**
 * Test-only: another replica of a session's document, with its own temporary store, connected to the
 * session through the in-process delivery harness. It is not a sync adapter.
 */
export declare class ScriptedReplica extends SharedObject {
  /**
   * Replaces `deleteCount` UTF-16 code units at `offset` in the replica's text with `text`, once every
   * earlier operation has been delivered.
   */
  edit(offset: number, deleteCount: number, text: string): Promise<void>;
}

declare class ScriptedReplicaModule extends NativeModule {
  connectScriptedReplica(session: DocumentSession): Promise<ScriptedReplica>;
}

const nativeModule = requireNativeModule<ScriptedReplicaModule>('ExpoNativeCollaborativeEditor');

/** Test-only: connects a scripted remote replica to the session's document. */
export function connectScriptedReplica(session: DocumentSession): Promise<ScriptedReplica> {
  return nativeModule.connectScriptedReplica(session);
}
