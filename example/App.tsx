import { Button, HStack, Host, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { padding } from '@expo/ui/swift-ui/modifiers';
import { useEvent } from 'expo';
import {
  connectScriptedReplica,
  EditingSurface,
  openDocument,
  type DocumentSession,
  type ScriptedReplica,
} from 'expo-native-collaborative-editor';
import { useEffect, useState } from 'react';
import { Settings } from 'react-native';

// UI tests launch with `-documentId <id>` for a fresh document; launch arguments land in NSUserDefaults.
const documentId: string = Settings.get('documentId') ?? 'proof-document';
// They script a remote replica with `-remoteEdits <percent-encoded JSON>`; each tap on "Remote edit"
// makes the next edit.
const remoteEdits: { offset: number; deleteCount: number; text: string }[] = JSON.parse(
  decodeURIComponent(Settings.get('remoteEdits') ?? '[]')
);

export default function App() {
  const [session, setSession] = useState<DocumentSession | null>(null);

  useEffect(() => {
    openDocument({ accountNamespace: 'example-account', documentId }).then(setSession);
  }, []);

  return <Host style={{ flex: 1 }}>{session ? <ProofScreen session={session} /> : null}</Host>;
}

function ProofScreen({ session }: { session: DocumentSession }) {
  const { savedOnThisPhone, pendingSynchronization } = useEvent(
    session,
    'stateChange',
    session.state
  );
  const [showsEditor, setShowsEditor] = useState(true);
  const [replica, setReplica] = useState<ScriptedReplica | null>(null);
  const [nextRemoteEdit, setNextRemoteEdit] = useState(0);

  useEffect(() => {
    if (remoteEdits.length > 0) connectScriptedReplica(session).then(setReplica);
  }, [session]);

  return (
    <VStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        {savedOnThisPhone ? <Text>Saved on this phone</Text> : null}
        <Spacer />
        {replica && nextRemoteEdit < remoteEdits.length ? (
          <Button
            label="Remote edit"
            onPress={() => {
              const { offset, deleteCount, text } = remoteEdits[nextRemoteEdit];
              replica.edit(offset, deleteCount, text);
              setNextRemoteEdit(nextRemoteEdit + 1);
            }}
          />
        ) : null}
        <Button
          label={showsEditor ? 'Hide editor' : 'Show editor'}
          onPress={() => setShowsEditor(!showsEditor)}
        />
      </HStack>
      {replica ? (
        <HStack modifiers={[padding({ horizontal: 16 })]}>
          <Text>{pendingSynchronization ? 'Pending synchronization' : 'Acknowledged'}</Text>
          <Spacer />
        </HStack>
      ) : null}
      {showsEditor ? <EditingSurface session={session} testID="editing-surface" /> : <Spacer />}
    </VStack>
  );
}
