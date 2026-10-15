import Combine
import ExpoModulesCore
import SwiftUI
import UIKit
import os

private let logger = Logger(subsystem: "expo.modules.nativecollaborativeeditor", category: "EditingSurface")

final class EditingSurfaceViewProps: ExpoSwiftUI.ViewProps {
  @Field var session: DocumentSessionHandle?
  @Field var testID: String?
}

/// Holds no document state: remounting binds a new view to the same session.
struct EditingSurfaceView: ExpoSwiftUI.View {
  @ObservedObject public var props: EditingSurfaceViewProps

  var body: some View {
    if let session = props.session?.session {
      CollaborativeTextView(session: session, testID: props.testID)
    }
  }
}

/// A `UITextView` (TextKit 2) bound to the session. SwiftUI `TextEditor` exposes no scroll position,
/// so it cannot keep the visible text in place while a remote change lands (docs/m1-evidence.md).
struct CollaborativeTextView: UIViewRepresentable {
  let session: DocumentSession
  var testID: String? = nil

  func makeUIView(context: Context) -> EditingTextContainer {
    let container = EditingTextContainer()
    let textView = container.textView
    textView.accessibilityIdentifier = testID
    (textView as? InputTextView)?.sessionUndoManager = SessionUndoManager(session: session, textView: textView)
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    context.coordinator.bind(textView)
    return container
  }

  func updateUIView(_ container: EditingTextContainer, context: Context) {
    container.textView.accessibilityIdentifier = testID
  }

  static func dismantleUIView(_ container: EditingTextContainer, coordinator: Coordinator) {
    (container.textView as? InputTextView)?.windowChanged = nil
    coordinator.unbind(container.textView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(session: session)
  }

  @MainActor
  final class Coordinator: NSObject, UITextViewDelegate, @MainActor NSTextStorageDelegate {
    private let session: DocumentSession
    private weak var textView: UITextView?
    private var surfaceChanges: AnyCancellable?
    private var closedChanges: AnyCancellable?
    private var typingChanges: AnyCancellable?
    private var isApplyingRemoteChange = false
    /// One replacement from committed document coordinates to the surface's uncommitted text.
    private var pendingRange: Range<Int>?
    private var pendingLength = 0
    /// UITextView clears marked text on storage patches. Keep the input system untouched until commit.
    private var deferredRemoteEdits: [TextEdit] = []
    private var hasDeferredRemoteChanges = false
    private var markers: [String: UIView] = [:]

    init(session: DocumentSession) {
      self.session = session
    }

    func bind(_ textView: UITextView) {
      self.textView = textView
      isApplyingRemoteChange = true
      textView.text = session.text
      textView.selectedRange = NSRange(session.selection)
      renderFormatting(in: textView)
      isApplyingRemoteChange = false
      textView.delegate = self
      textView.textStorage.delegate = self
      (textView as? InputTextView)?.didFinishInput = { [weak self] in self?.finishInput() }
      (textView as? InputTextView)?.handleListInput = { [weak self] range, replacement in
        self?.handleListInput(in: range, replacement: replacement) ?? false
      }
      (textView as? InputTextView)?.geometryChanged = { [weak self] in self?.layoutListMarkers() }
      (textView as? InputTextView)?.contentSizeCategoryChanged = { [weak self, weak textView] in
        guard let self, let textView else { return }
        self.renderFormatting(in: textView)
      }
      (textView as? InputTextView)?.windowChanged = { [weak self, weak textView] in
        guard let self, let textView else { return }
        if textView.window == nil {
          self.unbind(textView)
        } else if self.textView == nil {
          self.bind(textView)
        }
      }
      surfaceChanges = session.surfaceChanges.sink { [weak self] in self?.apply($0) }
      typingChanges = session.typingFormattingChanges.sink { [weak self, weak textView] in
        guard let self, let textView, textView.markedTextRange == nil else { return }
        self.applyTypingAttributes(to: textView)
      }
      closedChanges = session.$isClosed.sink { [weak textView] in textView?.isEditable = !$0 }
    }

    func unbind(_ textView: UITextView) {
      surfaceChanges?.cancel()
      surfaceChanges = nil
      closedChanges?.cancel()
      closedChanges = nil
      typingChanges?.cancel()
      typingChanges = nil
      textView.delegate = nil
      textView.textStorage.delegate = nil
      (textView as? InputTextView)?.didFinishInput = nil
      (textView as? InputTextView)?.handleListInput = nil
      (textView as? InputTextView)?.geometryChanged = nil
      (textView as? InputTextView)?.contentSizeCategoryChanged = nil
      markers.values.forEach { $0.removeFromSuperview() }
      markers.removeAll()
      self.textView = nil
    }

    func textStorage(
      _ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard !isApplyingRemoteChange, editedMask.contains(.editedCharacters) else { return }
      // Attribute fixing can widen didProcessEditing's range to the rest of the paragraph.
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

    private func handleListInput(in range: NSRange, replacement: String) -> Bool {
      guard let textView, textView.markedTextRange == nil, !session.hasMarkedText,
        pendingRange == nil, !hasDeferredRemoteChanges, let range = Range(range),
        let selection = Range(textView.selectedRange)
      else { return false }
      session.selection = selection
      do {
        return try session.handleListInput(in: range, replacement: replacement)
      } catch {
        logger.error("Engine rejected list input: \(String(describing: error), privacy: .public)")
        return true
      }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      layoutListMarkers()
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
      if hasDeferredRemoteChanges {
        hasDeferredRemoteChanges = false
        deferredRemoteEdits.removeAll(keepingCapacity: true)
        apply(surfaceEdits)
      } else {
        renderFormatting(in: textView)
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
        hasDeferredRemoteChanges = true
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
      renderFormatting(in: textView)
      textView.selectedRange = NSRange(session.selection)
      applyTypingAttributes(to: textView)

      guard let anchor else { return }
      // Text inserted right before the anchor lands above the visible area.
      let moved = edits.reduce(anchor.offset) { $1.transform($0, sticksToPreceding: false) }
      textView.layoutIfNeeded()
      let maxOffset = max(-insets.top, textView.contentSize.height + insets.bottom - textView.bounds.height)
      textView.contentOffset.y = min(max(top(of: moved, in: textView) - anchor.onScreen, -insets.top), maxOffset)
    }

    private func applyTypingAttributes(to textView: UITextView) {
      textView.typingAttributes = [
        .font: session.typingFormatting.font(compatibleWith: textView.traitCollection),
        .foregroundColor: UIColor.label,
      ]
    }

    private func renderFormatting(in textView: UITextView) {
      guard textView.markedTextRange == nil else { return }
      let wasApplyingChange = isApplyingRemoteChange
      isApplyingRemoteChange = true
      defer { isApplyingRemoteChange = wasApplyingChange }
      let storage = textView.textStorage
      storage.beginEditing()
      storage.addAttributes([
        .font: TextFormatting().font(compatibleWith: textView.traitCollection), .foregroundColor: UIColor.label,
        .paragraphStyle: NSParagraphStyle.default,
      ], range: NSRange(location: 0, length: storage.length))
      for mark in session.snapshot.marks ?? [] {
        storage.addAttribute(.font, value: mark.formatting.font(compatibleWith: textView.traitCollection),
          range: NSRange(location: mark.offset, length: mark.length))
      }
      for item in session.snapshot.listItems ?? [] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 44 + CGFloat(item.depth) * 28
        paragraph.headIndent = paragraph.firstLineHeadIndent
        paragraph.minimumLineHeight = 44
        storage.addAttribute(.paragraphStyle, value: paragraph,
          range: NSRange(location: item.offset, length: item.length + 1))
      }
      storage.endEditing()
      applyTypingAttributes(to: textView)
      renderListMarkers(in: textView)
    }

    private func renderListMarkers(in textView: UITextView) {
      guard let container = textView.superview as? EditingTextContainer else { return }
      let items = session.snapshot.listItems ?? []
      let ids = Set(items.map(\.id))
      for id in Array(markers.keys) where !ids.contains(id) {
        markers.removeValue(forKey: id)?.removeFromSuperview()
      }
      var orderedCounts: [String: Int] = [:]
      var previousEnd: Int?
      for item in items {
        if previousEnd != nil, previousEnd != item.offset { orderedCounts.removeAll(keepingCapacity: true) }
        previousEnd = item.offset + item.length + 1
        let parent = item.parent ?? ""
        if item.kind == .ordered {
          orderedCounts[parent, default: 0] += 1
        } else {
          orderedCounts[parent] = 0
        }
        let wantsButton = item.kind == .checklist
        if let marker = markers[item.id], (marker is UIButton) != wantsButton {
          marker.removeFromSuperview()
          markers[item.id] = nil
        }
        let marker: UIView
        if wantsButton {
          let button = (markers[item.id] as? UIButton) ?? UIButton(type: .system)
          let checked = item.checked == true
          button.setImage(UIImage(systemName: checked ? "checkmark.square.fill" : "square"), for: .normal)
          button.accessibilityIdentifier = "checklist-\(item.id)"
          let label = (session.text as NSString).substring(
            with: NSRange(location: item.offset, length: item.length))
          button.accessibilityLabel = label.isEmpty ? "Empty checklist item" : label
          button.accessibilityValue = checked ? "Checked" : "Unchecked"
          button.accessibilityTraits = checked ? [.button, .selected] : [.button]
          button.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Toggle") { [weak self] _ in
              self?.toggleChecklistItem(item.id) ?? false
            }
          ]
          button.removeAction(identifiedBy: UIAction.Identifier("toggle"), for: .touchUpInside)
          button.addAction(UIAction(identifier: UIAction.Identifier("toggle")) { [weak self] _ in
            _ = self?.toggleChecklistItem(item.id)
          }, for: .touchUpInside)
          marker = button
        } else {
          let label = (markers[item.id] as? UILabel) ?? UILabel()
          label.text = item.kind == .ordered ? "\(orderedCounts[parent, default: 1])." : "•"
          label.font = .preferredFont(forTextStyle: .body, compatibleWith: textView.traitCollection)
          label.textColor = .secondaryLabel
          label.textAlignment = .center
          label.isAccessibilityElement = false
          marker = label
        }
        markers[item.id] = marker
        if marker.superview == nil { container.markers.addSubview(marker) }
      }
      layoutListMarkers()
    }

    @discardableResult
    private func toggleChecklistItem(_ id: String) -> Bool {
      guard let textView, textView.markedTextRange == nil else { return false }
      do {
        try session.toggleChecklistItem(id)
        return true
      } catch {
        logger.error("Engine rejected checklist toggle: \(String(describing: error), privacy: .public)")
        return false
      }
    }

    private func layoutListMarkers() {
      guard let textView, let container = textView.superview as? EditingTextContainer else { return }
      container.markers.isHidden = textView.markedTextRange != nil
      guard !container.markers.isHidden, let manager = textView.textLayoutManager,
        let content = manager.textContentManager else { return }
      for item in session.snapshot.listItems ?? [] {
        guard let marker = markers[item.id],
          let position = textView.position(from: textView.beginningOfDocument, offset: item.offset)
        else { continue }
        let caret = textView.caretRect(for: position)
        guard let location = content.location(content.documentRange.location, offsetBy: item.offset),
          let fragment = manager.textLayoutFragment(for: location),
          let line = fragment.textLineFragments.first,
          let font = textView.textStorage.attribute(.font, at: item.offset, effectiveRange: nil) as? UIFont
        else {
          marker.isHidden = true
          continue
        }
        marker.isHidden = false
        let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
        let origin = textView.convert(CGPoint(x: caret.minX - 44,
          y: baseline + textView.textContainerInset.top - font.capHeight / 2 - 22), to: container.markers)
        marker.frame = CGRect(origin: origin, size: CGSize(width: 44, height: 44))
      }
    }

    private func top(of offset: Int, in textView: UITextView) -> CGFloat {
      guard let position = textView.position(from: textView.beginningOfDocument, offset: offset) else { return 0 }
      return textView.caretRect(for: position).minY
    }
  }
}

private extension TextFormatting {
  func font(compatibleWith traitCollection: UITraitCollection) -> UIFont {
    let style: UIFont.TextStyle = switch heading {
    case 1: .title1
    case 2: .title2
    case 3: .title3
    case 4: .headline
    case 5: .subheadline
    default: .body
    }
    let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traitCollection)
    var traits = base.fontDescriptor.symbolicTraits
    if bold || heading > 0 { traits.insert(.traitBold) }
    if italic { traits.insert(.traitItalic) }
    return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor, size: 0)
  }
}

/// UIKit supplies the gestures, menus, and key commands; the engine owns every history entry.
private final class SessionUndoManager: UndoManager {
  private let session: DocumentSession
  private weak var textView: UITextView?

  @MainActor
  init(session: DocumentSession, textView: UITextView) {
    self.session = session
    self.textView = textView
    super.init()
    disableUndoRegistration()
  }

  override var canUndo: Bool {
    MainActor.assumeIsolated {
      !session.isClosed && (session.canUndo || textView?.markedTextRange != nil)
    }
  }

  override var canRedo: Bool {
    MainActor.assumeIsolated { session.canRedo }
  }

  override func undo() {
    MainActor.assumeIsolated {
      textView?.unmarkText()
      do {
        try session.undo()
      } catch {
        logger.error("Engine rejected undo: \(String(describing: error), privacy: .public)")
      }
    }
  }

  override func redo() {
    MainActor.assumeIsolated {
      textView?.unmarkText()
      do {
        try session.redo()
      } catch {
        logger.error("Engine rejected redo: \(String(describing: error), privacy: .public)")
      }
    }
  }

  override func enableUndoRegistration() {
    // UIKit may balance its own disable/enable calls, but native history must stay disabled.
  }

  override func removeAllActions() {
    super.removeAllActions()
    // UIKit clears its stack on mount/unmount. This must neither clear engine history nor
    // reenable native recording (UndoManager.removeAllActions resets registration).
    if isUndoRegistrationEnabled { disableUndoRegistration() }
  }

  override func removeAllActions(withTarget target: Any) {
    super.removeAllActions(withTarget: target)
    if isUndoRegistrationEnabled { disableUndoRegistration() }
  }
}

/// Checkboxes are siblings of the accessible text view, never hidden inside its accessibility leaf.
final class EditingTextContainer: UIView {
  let textView: UITextView = InputTextView()
  fileprivate let markers: UIView = ListMarkerOverlay()

  init() {
    super.init(frame: .zero)
    isAccessibilityElement = false
    markers.isAccessibilityElement = false
    markers.clipsToBounds = true
    addSubview(textView)
    addSubview(markers)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    textView.frame = bounds
    markers.frame = bounds
    (textView as? InputTextView)?.geometryChanged?()
  }
}

private final class ListMarkerOverlay: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }
}

/// UIKit can notify its delegate before updating `markedTextRange`; flush only after the input call.
private final class InputTextView: UITextView {
  var sessionUndoManager: SessionUndoManager?
  override var undoManager: UndoManager? { sessionUndoManager }

  var didFinishInput: (() -> Void)?
  private(set) var inputDepth = 0
  var windowChanged: (() -> Void)?
  var handleListInput: ((NSRange, String) -> Bool)?
  var geometryChanged: (() -> Void)?
  var contentSizeCategoryChanged: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    geometryChanged?()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
      contentSizeCategoryChanged?()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    windowChanged?()
  }

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
    if inputDepth == 0, markedTextRange == nil, handleListInput?(selectedRange, text) == true { return }
    inputDepth += 1
    defer { finishInput() }
    super.insertText(text)
  }

  override func replace(_ range: UITextRange, withText text: String) {
    let replacementRange = NSRange(
      location: offset(from: beginningOfDocument, to: range.start),
      length: offset(from: range.start, to: range.end))
    if inputDepth == 0, markedTextRange == nil, handleListInput?(replacementRange, text) == true { return }
    inputDepth += 1
    defer { finishInput() }
    super.replace(range, withText: text)
  }

  override func deleteBackward() {
    var range = selectedRange
    if range.length == 0, range.location > 0 {
      range = (text as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
    }
    if inputDepth == 0, markedTextRange == nil, handleListInput?(range, "") == true { return }
    inputDepth += 1
    defer { finishInput() }
    super.deleteBackward()
  }

  private func finishInput() {
    inputDepth -= 1
    if inputDepth == 0 { didFinishInput?() }
  }
}
