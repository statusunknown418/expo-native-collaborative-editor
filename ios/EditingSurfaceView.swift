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
struct CollaborativeTextView: UIViewRepresentable {
  let session: DocumentSession

  func makeUIView(context: Context) -> UITextView {
    let textView = InputTextView()
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
  final class Coordinator: NSObject, UITextViewDelegate, @MainActor NSTextStorageDelegate {
    private let session: DocumentSession
    private weak var textView: UITextView?
    private var remoteChanges: AnyCancellable?
    private var isApplyingRemoteChange = false
    /// One replacement from committed document coordinates to the surface's uncommitted text.
    private var pendingRange: Range<Int>?
    private var pendingLength = 0
    /// UITextView clears marked text on storage patches. Keep the input system untouched until commit.
    private var deferredRemoteEdits: [TextEdit] = []

    init(session: DocumentSession) {
      self.session = session
    }

    func bind(_ textView: UITextView) {
      self.textView = textView
      textView.textStorage.delegate = self
      (textView as? InputTextView)?.didFinishInput = { [weak self] in self?.finishInput() }
      remoteChanges = session.remoteChanges.sink { [weak self] in self?.apply($0) }
    }

    func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard !isApplyingRemoteChange, editedMask.contains(.editedCharacters) else { return }
      let oldEnd = NSMaxRange(editedRange) - delta
      if let pendingRange {
        let lower = min(pendingRange.lowerBound, editedRange.location)
        let upper = max(pendingRange.upperBound, oldEnd - pendingLength + pendingRange.count)
        pendingLength += upper - lower - pendingRange.count + delta
        self.pendingRange = lower..<upper
      } else {
        pendingRange = editedRange.location..<oldEnd
        pendingLength = editedRange.length
      }
    }

    func textViewDidChange(_ textView: UITextView) {
      finishInput()
    }

    private func finishInput() {
      guard !isApplyingRemoteChange, let textView,
        (textView as? InputTextView)?.inputDepth == 0
      else { return }
      if textView.markedTextRange != nil {
        session.hasMarkedText = true
        return
      }
      var selection = Range(textView.selectedRange) ?? session.selection
      var surfaceEdits: [TextEdit] = []
      if let pendingRange {
        let replacement = (textView.text as NSString).substring(
          with: NSRange(location: pendingRange.lowerBound, length: pendingLength))
        var range = pendingRange
        for edit in deferredRemoteEdits {
          // Session deltas split replacements into deletions and insertions. Project only the
          // characters outside the provisional replacement; never delete the composed text.
          if edit.utf16Length > 0 {
            let end = edit.utf16Offset + edit.utf16Length
            let right = max(edit.utf16Offset, range.upperBound)
            if end > right {
              surfaceEdits.append(TextEdit(
                utf16Offset: right + pendingLength - range.count, utf16Length: end - right, replacement: ""))
            }
            let leftEnd = min(end, range.lowerBound)
            if leftEnd > edit.utf16Offset {
              surfaceEdits.append(TextEdit(
                utf16Offset: edit.utf16Offset, utf16Length: leftEnd - edit.utf16Offset, replacement: ""))
            }
          } else if edit.utf16Offset < range.lowerBound
            || (edit.utf16Offset == range.lowerBound && !range.isEmpty)
          {
            surfaceEdits.append(edit)
          } else if edit.utf16Offset >= range.upperBound {
            surfaceEdits.append(TextEdit(
              utf16Offset: edit.utf16Offset + pendingLength - range.count,
              utf16Length: 0, replacement: edit.replacement))
          }
          let lower = edit.transform(range.lowerBound, sticksToPreceding: range.isEmpty)
          let upper = edit.transform(range.upperBound, sticksToPreceding: true)
          range = lower..<max(lower, upper)
        }
        let committedEdit = TextEdit(
          utf16Offset: range.lowerBound, utf16Length: range.count, replacement: replacement)
        func move(_ offset: Int, sticksToPreceding: Bool) -> Int {
          if offset >= pendingRange.lowerBound, offset <= pendingRange.lowerBound + pendingLength {
            return range.lowerBound + offset - pendingRange.lowerBound
          }
          var moved = offset < pendingRange.lowerBound ? offset : offset - pendingLength + pendingRange.count
          for edit in deferredRemoteEdits {
            moved = edit.transform(moved, sticksToPreceding: sticksToPreceding)
          }
          return committedEdit.transform(moved, sticksToPreceding: sticksToPreceding)
        }
        let selected = textView.selectedRange
        let lower = move(selected.location, sticksToPreceding: selected.length == 0)
        selection = lower..<max(lower, move(NSMaxRange(selected), sticksToPreceding: true))
        do {
          let original = (session.text as NSString).substring(with: NSRange(range))
          if !original.utf16.elementsEqual(replacement.utf16) {
            try session.replaceText(in: range, with: replacement)
          }
          self.pendingRange = nil
          pendingLength = 0
        } catch {
          logger.fault("Engine rejected a local edit: \(String(describing: error), privacy: .public)")
          return
        }
      } else {
        surfaceEdits = deferredRemoteEdits
        for edit in deferredRemoteEdits {
          let lower = edit.transform(selection.lowerBound, sticksToPreceding: selection.isEmpty)
          let upper = edit.transform(selection.upperBound, sticksToPreceding: true)
          selection = lower..<max(lower, upper)
        }
      }
      session.hasMarkedText = false
      session.selection = selection
      if !deferredRemoteEdits.isEmpty {
        deferredRemoteEdits.removeAll(keepingCapacity: true)
        apply(surfaceEdits)
      }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isApplyingRemoteChange, textView.markedTextRange == nil,
        (textView as? InputTextView)?.inputDepth == 0, let selection = Range(textView.selectedRange)
      else { return }
      session.selection = selection
    }

    /// Patches the text storage with a remote change and restores the session's selection. Unless the
    /// view is scrolled to the very top, the first visible character keeps its place on screen.
    private func apply(_ edits: [TextEdit]) {
      guard let textView else { return }
      if textView.markedTextRange != nil {
        deferredRemoteEdits.append(contentsOf: edits)
        return
      }
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

/// UIKit can notify its delegate before updating `markedTextRange`; flush only after the input call.
private final class InputTextView: UITextView {
  var didFinishInput: (() -> Void)?
  private(set) var inputDepth = 0

  override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
    inputDepth += 1
    defer { finishInput() }
    super.setMarkedText(markedText, selectedRange: selectedRange)
  }

  override func unmarkText() {
    inputDepth += 1
    defer { finishInput() }
    super.unmarkText()
  }

  override func insertText(_ text: String) {
    inputDepth += 1
    defer { finishInput() }
    super.insertText(text)
  }

  override func replace(_ range: UITextRange, withText text: String) {
    inputDepth += 1
    defer { finishInput() }
    super.replace(range, withText: text)
  }

  override func deleteBackward() {
    inputDepth += 1
    defer { finishInput() }
    super.deleteBackward()
  }

  private func finishInput() {
    inputDepth -= 1
    if inputDepth == 0 { didFinishInput?() }
  }
}
