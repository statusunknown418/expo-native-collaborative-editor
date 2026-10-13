import { Host } from '@expo/ui/swift-ui';
import { EditingSurface } from 'expo-native-collaborative-editor';

export default function App() {
  return (
    <Host style={{ flex: 1 }}>
      <EditingSurface testID="editing-surface" />
    </Host>
  );
}
