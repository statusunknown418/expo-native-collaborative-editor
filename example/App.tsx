import ExpoNativeCollaborativeEditor, { ExpoNativeCollaborativeEditorSwiftUIView, expoNativeCollaborativeEditorSwiftUIModifier } from 'expo-native-collaborative-editor';
import { useEvent } from 'expo';
import { Host as SwiftUIHost, Text as SwiftUIText } from '@expo/ui/swift-ui';
import { padding, cornerRadius, background } from '@expo/ui/swift-ui/modifiers';
import { VStack } from '@expo/ui/swift-ui';
import { Button, SafeAreaView, ScrollView, Text, View } from 'react-native';

export default function App() {
  const onChangePayload = useEvent(ExpoNativeCollaborativeEditor, 'onChange');
  return (
    <SafeAreaView style={styles.container}>
      <ScrollView style={styles.container}>
        <Text style={styles.header}>Module API Example</Text>
        <Group name="Events">
          <Text>{onChangePayload?.value}</Text>
        </Group>
        {process.env.EXPO_OS === 'ios' && (
          <Group name="SwiftUI View">
            <SwiftUIHost style={styles.view}>
              <ExpoNativeCollaborativeEditorSwiftUIView
                title="Hello from ExpoNativeCollaborativeEditor"
                modifiers={[padding({ all: 16 }), cornerRadius(12), background('#f0f0f0')]}>
                <SwiftUIText>Child content</SwiftUIText>
              </ExpoNativeCollaborativeEditorSwiftUIView>
            </SwiftUIHost>
          </Group>
        )}
        {process.env.EXPO_OS === 'ios' && (
          <Group name="SwiftUI Modifier">
            <SwiftUIHost style={styles.view}>
              <VStack
                modifiers={[
                  padding({ all: 20 }),
                  expoNativeCollaborativeEditorSwiftUIModifier({ color: '#FF6B35', width: 3, cornerRadius: 8 }),
                ]}>
                <SwiftUIText>Custom modifier example</SwiftUIText>
              </VStack>
            </SwiftUIHost>
          </Group>
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

function Group(props: { name: string; children: React.ReactNode }) {
  return (
    <View style={styles.group}>
      <Text style={styles.groupHeader}>{props.name}</Text>
      {props.children}
    </View>
  );
}

const styles = {
  header: { fontSize: 30, margin: 20 },
  groupHeader: { fontSize: 20, marginBottom: 20 },
  group: { margin: 20, backgroundColor: '#fff', borderRadius: 10, padding: 20 },
  container: { flex: 1, backgroundColor: '#eee' },
  view: { flex: 1, height: 200 },
};
