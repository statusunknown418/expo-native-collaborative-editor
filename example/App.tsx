import { Button, HStack, Host, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { padding } from '@expo/ui/swift-ui/modifiers';
import { useEvent } from 'expo';
import {
  EditingSurface,
  openDocument,
  type DocumentSession,
} from 'expo-native-collaborative-editor';
import { useEffect, useState } from 'react';
import { Settings } from 'react-native';

// UI tests launch with `-documentId <id>` for a fresh document; launch arguments land in NSUserDefaults.
const documentId: string = Settings.get('documentId') ?? 'proof-document';

export default function App() {
  const [session, setSession] = useState<DocumentSession | null>(null);

  useEffect(() => {
    openDocument({ accountNamespace: 'example-account', documentId }).then(setSession);
  }, []);

  return <Host style={{ flex: 1 }}>{session ? <ProofScreen session={session} /> : null}</Host>;
}

function ProofScreen({ session }: { session: DocumentSession }) {
  const { savedOnThisPhone } = useEvent(session, 'stateChange', session.state);
  const [showsEditor, setShowsEditor] = useState(true);

  return (
    <VStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        {savedOnThisPhone ? <Text>Saved on this phone</Text> : null}
        <Spacer />
        <Button
          label={showsEditor ? 'Hide editor' : 'Show editor'}
          onPress={() => setShowsEditor(!showsEditor)}
        />
      </HStack>
      {showsEditor ? <EditingSurface session={session} testID="editing-surface" /> : <Spacer />}
    </VStack>
  );
}
