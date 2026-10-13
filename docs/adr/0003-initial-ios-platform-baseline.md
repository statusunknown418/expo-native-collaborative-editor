# Initial iOS platform baseline

The initial release supports native iOS 26 and later, with no backward-compatibility path for earlier iOS releases and no Android or web implementation. Evaluate SwiftUI TextEditor first; the allowed fallback is a public UIKit/TextKit editing surface inside the native SwiftUI component, not a web editor.

Use the latest stable Expo SDK when establishing the implementation baseline, together with the latest React Native release supported by that SDK; align the module and example toolchains to that compatible pair. Independently selecting the latest Expo and React Native releases is not sufficient evidence of compatibility. Exact dependency pins and clean simulator/device build evidence belong to the implementation gate, not to this planning decision.
