import AppKit
import SwiftUI

/// NSTextView-backed log pane for one channel of a `VPhoneLogBuffer`.
///
/// Replaces the per-line SwiftUI `Text` stack, which re-diffed every visible
/// row on each output chunk (seconds of beachball on open) and could not
/// select across lines (`.textSelection` does not span separate Text views).
/// The text view appends only lines it has not seen yet, keeps its own copy
/// trimmed to the buffer cap, and follows the tail only while the user is
/// already scrolled to the bottom.
struct VPhoneLogTextView: NSViewRepresentable {
    let buffer: VPhoneLogBuffer
    let channel: VPhoneLogBuffer.Channel
    /// Stored so the enclosing SwiftUI body re-runs updateNSView on new output.
    let revision: Int

    var fontSize: CGFloat = 11

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isRichText = false
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        context.coordinator.attributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        context.coordinator.sync(textView: textView, scroll: scroll, buffer: buffer, channel: channel)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.sync(textView: textView, scroll: scroll, buffer: buffer, channel: channel)
    }

    @MainActor
    final class Coordinator {
        var attributes: [NSAttributedString.Key: Any] = [:]

        /// SwiftUI reuses the same NSTextView when the selected VM changes
        /// (same structural identity, different buffer) — rebuild then too.
        private var bufferID: ObjectIdentifier?
        private var generation = -1
        /// Buffer-side line count we have already appended (monotonic).
        private var seenTotal = 0
        /// UTF-16 length of the live (not newline-terminated) tail currently
        /// at the end of the storage; rewritten on every sync.
        private var tailLength = 0
        private var lastTail = ""
        private var lineCount = 0

        private let cap = 4000
        /// Trim in batches so we don't rescan the storage on every append.
        private let trimSlack = 512

        func sync(textView: NSTextView, scroll: NSScrollView, buffer: VPhoneLogBuffer, channel: VPhoneLogBuffer.Channel) {
            guard let storage = textView.textStorage else { return }

            if bufferID != ObjectIdentifier(buffer) || generation != buffer.generation {
                storage.setAttributedString(NSAttributedString())
                bufferID = ObjectIdentifier(buffer)
                generation = buffer.generation
                seenTotal = 0
                tailLength = 0
                lastTail = ""
                lineCount = 0
            }

            let total = buffer.total(in: channel)
            let tail = channel == .console ? buffer.partial : ""
            let newCount = total - seenTotal
            guard newCount > 0 || tail != lastTail else { return }

            let visible = scroll.contentView.documentVisibleRect
            let docHeight = textView.frame.height
            let followTail = visible.maxY >= docHeight - 24

            storage.beginEditing()
            if tailLength > 0 {
                storage.deleteCharacters(in: NSRange(location: storage.length - tailLength, length: tailLength))
            }
            if newCount > 0 {
                let committed = buffer.committedLines(in: channel)
                // If the buffer trimmed past lines we never displayed, show what's left.
                let fresh = newCount <= committed.count ? Array(committed.suffix(newCount)) : committed
                storage.append(NSAttributedString(string: fresh.joined(separator: "\n") + "\n", attributes: attributes))
                lineCount += fresh.count
                seenTotal = total
            }
            if !tail.isEmpty {
                storage.append(NSAttributedString(string: tail, attributes: attributes))
            }
            tailLength = (tail as NSString).length
            lastTail = tail

            if lineCount > cap + trimSlack {
                let drop = lineCount - cap
                let text = storage.string as NSString
                var cut = 0
                var dropped = 0
                while dropped < drop {
                    let nl = text.range(of: "\n", range: NSRange(location: cut, length: text.length - cut))
                    if nl.location == NSNotFound { break }
                    cut = nl.location + 1
                    dropped += 1
                }
                storage.deleteCharacters(in: NSRange(location: 0, length: cut))
                lineCount -= dropped
            }
            storage.endEditing()

            if followTail {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
}
