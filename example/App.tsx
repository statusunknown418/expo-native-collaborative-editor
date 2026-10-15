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
import { useCallback, useEffect, useState } from 'react';
import { Settings } from 'react-native';

// UI tests launch with `-documentId <id>` for a fresh document; launch arguments land in NSUserDefaults.
const documentId: string = Settings.get('documentId') ?? 'proof-document';
// They script a remote replica with `-remoteEdits <percent-encoded JSON>`; each tap on "Remote edit"
// makes the next edit.
const remoteEdits: { offset: number; deleteCount: number; text: string }[] = JSON.parse(
  decodeURIComponent(Settings.get('remoteEdits') ?? '[]')
);

function formattingValue(value: boolean | null) {
  if (value === null) {
    return 'Mixed';
  }
  return value ? 'On' : 'Off';
}

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
      .catch((failure: unknown) => setError(String(failure)));
  }, []);

  return (
    <Host style={{ flex: 1 }}>
      {session ? <ProofScreen session={session} /> : null}
      {!session && error ? <Text>{error}</Text> : null}
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

  const runCommand = useCallback(async (command: () => Promise<void>) => {
    setError(null);
    try {
      await command();
    } catch (failure) {
      setError(String(failure));
    }
  }, []);

  useEffect(() => {
    if (remoteEdits.length > 0) {
      connectScriptedReplica(session)
        .then(setReplica)
        .catch((failure: unknown) => setError(String(failure)));
    }
  }, [session]);

  const handleRemoteEdit = useCallback(async () => {
    if (replica) {
      await runCommand(async () => {
        const { offset, deleteCount, text } = remoteEdits[nextRemoteEdit];
        await replica.edit(offset, deleteCount, text);
        setNextRemoteEdit(nextRemoteEdit + 1);
      });
    }
  }, [nextRemoteEdit, replica, runCommand]);

  const handleToggleEditor = useCallback(() => setShowsEditor((visible) => !visible), []);
  const handleUndo = useCallback(() => runCommand(() => session.undo()), [runCommand, session]);
  const handleRedo = useCallback(() => runCommand(() => session.redo()), [runCommand, session]);
  const handleBold = useCallback(
    () => runCommand(() => session.toggleBold()),
    [runCommand, session]
  );
  const handleItalic = useCallback(
    () => runCommand(() => session.toggleItalic()),
    [runCommand, session]
  );
  const handleHeading = useCallback(
    () => runCommand(() => session.setHeading(selectedFormatting.heading ? 0 : 1)),
    [runCommand, selectedFormatting.heading, session]
  );
  const handleToggleFormatting = useCallback(
    () =>
      runCommand(async () => {
        await session.setPlugins(
          formattingEnabled ? [] : [formattingPlugin({ headingLevels: [1, 2, 3] })]
        );
        setFormattingEnabled(!formattingEnabled);
      }),
    [formattingEnabled, runCommand, session]
  );

  return (
    <VStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        {savedOnThisPhone ? <Text>Saved on this phone</Text> : null}
        <Spacer />
        {replica && nextRemoteEdit < remoteEdits.length ? (
          <Button label="Remote edit" onPress={handleRemoteEdit} />
        ) : null}
        <Button label={showsEditor ? 'Hide editor' : 'Show editor'} onPress={handleToggleEditor} />
      </HStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        <Button label="Undo" modifiers={[disabled(!canUndo)]} onPress={handleUndo} />
        <Button label="Redo" modifiers={[disabled(!canRedo)]} onPress={handleRedo} />
        <Spacer />
      </HStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        <Button
          label="Bold"
          modifiers={[
            disabled(!formattingEnabled),
            buttonStyle(selectedFormatting.bold === true ? 'borderedProminent' : 'bordered'),
            accessibilityValue(formattingValue(selectedFormatting.bold)),
          ]}
          onPress={handleBold}
        />
        <Button
          label="Italic"
          modifiers={[
            disabled(!formattingEnabled),
            buttonStyle(selectedFormatting.italic === true ? 'borderedProminent' : 'bordered'),
            accessibilityValue(formattingValue(selectedFormatting.italic)),
          ]}
          onPress={handleItalic}
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
          onPress={handleHeading}
        />
        <Spacer />
      </HStack>
      <HStack modifiers={[padding({ horizontal: 16 })]}>
        <Button
          label={formattingEnabled ? 'Disable formatting' : 'Enable formatting'}
          onPress={handleToggleFormatting}
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
