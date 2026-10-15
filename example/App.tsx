import { Button, Host, HStack, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { accessibilityValue, buttonStyle, disabled, padding } from '@expo/ui/swift-ui/modifiers';
import { useEvent } from 'expo';
import {
  connectScriptedReplica,
  type DocumentSession,
  EditingSurface,
  formattingPlugin,
  openDocument,
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
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    openDocument({
      accountNamespace: 'example-account',
      documentId,
      plugins: [formattingPlugin({ headingLevels: [1, 2, 3] })],
    })
      .then(setSession)
      .catch((error: unknown) => setError(String(error)));
  }, []);

  return (
    <Host style={{ flex: 1 }}>
      {session ? <ProofScreen session={session} /> : error ? <Text>{error}</Text> : null}
    </Host>
  );
}

function ProofScreen({ session }: { session: DocumentSession }) {
  const { savedOnThisPhone, pendingSynchronization, canUndo, canRedo, selectedFormatting } =
    useEvent(session, 'stateChange', session.state);
  const [showsEditor, setShowsEditor] = useState(true);
  const [replica, setReplica] = useState<ScriptedReplica | null>(null);
  const [nextRemoteEdit, setNextRemoteEdit] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [formattingEnabled, setFormattingEnabled] = useState(true);

  async function runCommand(command: () => Promise<void>) {
    setError(null);
    try {
      await command();
    } catch (error) {
      setError(String(error));
    }
  }

  useEffect(() => {
    if (remoteEdits.length > 0) {
      connectScriptedReplica(session)
        .then(setReplica)
        .catch((error: unknown) => setError(String(error)));
    }
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
              void runCommand(async () => {
                const { offset, deleteCount, text } = remoteEdits[nextRemoteEdit];
                await replica.edit(offset, deleteCount, text);
                setNextRemoteEdit(nextRemoteEdit + 1);
              });
            }}
          />
        ) : null}
        <Button
          label={showsEditor ? 'Hide editor' : 'Show editor'}
          onPress={() => setShowsEditor(!showsEditor)}
        />
      </HStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        <Button
          label="Undo"
          modifiers={[disabled(!canUndo)]}
          onPress={() => void runCommand(() => session.undo())}
        />
        <Button
          label="Redo"
          modifiers={[disabled(!canRedo)]}
          onPress={() => void runCommand(() => session.redo())}
        />
        <Spacer />
      </HStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        <Button
          label="Bold"
          modifiers={[
            disabled(!formattingEnabled),
            buttonStyle(selectedFormatting.bold === true ? 'borderedProminent' : 'bordered'),
            accessibilityValue(
              selectedFormatting.bold === null ? 'Mixed' : selectedFormatting.bold ? 'On' : 'Off'
            ),
          ]}
          onPress={() => void runCommand(() => session.toggleBold())}
        />
        <Button
          label="Italic"
          modifiers={[
            disabled(!formattingEnabled),
            buttonStyle(selectedFormatting.italic === true ? 'borderedProminent' : 'bordered'),
            accessibilityValue(
              selectedFormatting.italic === null
                ? 'Mixed'
                : selectedFormatting.italic
                  ? 'On'
                  : 'Off'
            ),
          ]}
          onPress={() => void runCommand(() => session.toggleItalic())}
        />
        <Button
          label="Heading"
          modifiers={[
            disabled(!formattingEnabled),
            buttonStyle(selectedFormatting.heading ? 'borderedProminent' : 'bordered'),
            accessibilityValue(
              selectedFormatting.heading === null ? 'Mixed' : `Level ${selectedFormatting.heading}`
            ),
          ]}
          onPress={() =>
            void runCommand(() => session.setHeading(selectedFormatting.heading ? 0 : 1))
          }
        />
        <Spacer />
      </HStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        <Button
          label={formattingEnabled ? 'Disable formatting' : 'Enable formatting'}
          onPress={() =>
            void runCommand(async () => {
              await session.setPlugins(
                formattingEnabled ? [] : [formattingPlugin({ headingLevels: [1, 2, 3] })]
              );
              setFormattingEnabled(!formattingEnabled);
            })
          }
        />
        <Spacer />
      </HStack>
      {error ? <Text>{error}</Text> : null}
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
