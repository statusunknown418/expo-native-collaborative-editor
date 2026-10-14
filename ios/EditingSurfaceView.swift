import Combine
import ExpoModulesCore
import ExpoUI
import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "EditingSurface")

final class EditingSurfaceViewProps: UIBaseViewProps {
  @Field var session: DocumentSessionHandle?
}

/// Holds no document state: remounting binds a new view to the same session.
struct EditingSurfaceView: ExpoSwiftUI.View {
  @ObservedObject public var props: EditingSurfaceViewProps

  var body: some View {
    if let session = props.session?.session {
      CollaborativeTextView(session: session)
    }
  }
}

/// A `UITextView` (TextKit 2) bound to the session. SwiftUI `TextEditor` exposes no scroll position,
/// so it cannot keep the visible text in place while a remote change lands (docs/m1-evidence.md).
private struct CollaborativeTextView: UIViewRepresentable {
  let session: DocumentSession

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.text = session.text
    textView.selectedRange = NSRange(session.selection)
    textView.delegate = context.coordinator
    context.coordinator.bind(textView)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {}

  func makeCoordinator() -> Coordinator {
    Coordinator(session: session)
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate {
    private let session: DocumentSession
    private weak var textView: UITextView?
    private var remoteChanges: AnyCancellable?
    private var isApplyingRemoteChange = false

    init(session: DocumentSession) {
      self.session = session
    }

    func bind(_ textView: UITextView) {
      self.textView = textView
      remoteChanges = session.remoteChanges.sink { [weak self] in self?.apply($0) }
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !isApplyingRemoteChange else { return }
      do {
        try session.replaceText(with: textView.text)
      } catch {
        logger.fault("Engine rejected a local edit: \(String(describing: error), privacy: .public)")
      }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isApplyingRemoteChange, let selection = Range(textView.selectedRange) else { return }
      session.selection = selection
    }

    /// Patches the text storage with a remote change and restores the session's selection. Unless the
    /// view is scrolled to the very top, the first visible character keeps its place on screen.
    private func apply(_ edits: [TextEdit]) {
      guard let textView else { return }
      let insets = textView.adjustedContentInset
      var anchor: (offset: Int, onScreen: CGFloat)?
      if textView.contentOffset.y > -insets.top,
        let first = textView.closestPosition(
          to: CGPoint(x: textView.textContainerInset.left, y: textView.contentOffset.y + textView.textContainerInset.top))
      {
        let offset = textView.offset(from: textView.beginningOfDocument, to: first)
        anchor = (offset, top(of: offset, in: textView) - textView.contentOffset.y)
      }

      isApplyingRemoteChange = true
      defer { isApplyingRemoteChange = false }
      let storage = textView.textStorage
      storage.beginEditing()
      for edit in edits {
        storage.replaceCharacters(
          in: NSRange(location: edit.utf16Offset, length: edit.utf16Length),
          with: NSAttributedString(string: edit.replacement, attributes: textView.typingAttributes))
      }
      storage.endEditing()
      textView.selectedRange = NSRange(session.selection)

      guard let anchor else { return }
      // Text inserted right before the anchor lands above the visible area.
      let moved = edits.reduce(anchor.offset) { $1.transform($0, sticksToPreceding: false) }
      textView.layoutIfNeeded()
      let maxOffset = max(-insets.top, textView.contentSize.height + insets.bottom - textView.bounds.height)
      textView.contentOffset.y = min(max(top(of: moved, in: textView) - anchor.onScreen, -insets.top), maxOffset)
    }

    private func top(of offset: Int, in textView: UITextView) -> CGFloat {
      guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else { return 0 }
      return textView.caretRect(for: position).minY
    }
  }
}
