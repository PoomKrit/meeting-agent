import AppKit
import UniformTypeIdentifiers

/// Note pad text view: plain-text paste (so web formatting doesn't leak into markdown),
/// images pasted as attachments, ⌘B / ⌘I wrap the selection in markdown markers.
final class MarkdownTextView: NSTextView {
    override func paste(_ sender: Any?) {
        smartPaste(from: .general)
    }

    /// Image files → image attachment; any text → plain text; otherwise (image data) → attachment.
    func smartPaste(from pasteboard: NSPasteboard) {
        let imageFiles = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        if !imageFiles.isEmpty {
            for url in imageFiles {
                guard let data = try? Data(contentsOf: url) else { continue }
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = url.lastPathComponent
                insertText(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)),
                           replacementRange: selectedRange())
            }
            return
        }
        if pasteboard.string(forType: .string) != nil {
            _ = readSelection(from: pasteboard, type: .string)
            return
        }
        _ = readSelection(from: pasteboard)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": wrapSelection(with: "**"); return true
        case "i": wrapSelection(with: "*"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    func wrapSelection(with marker: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText(marker + selected + marker, replacementRange: range)
        if range.length == 0 {
            setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: 0))
        }
    }
}

/// Free-form markdown note pad. Saved by the app itself as `<meeting folder>/notes.md`, pasted
/// images as `<meeting folder>/images/paste-N.png` — never sent to the LLM.
@MainActor
final class NotesController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView: NSScrollView
    let textView: MarkdownTextView

    /// Where notes.md goes. Text typed before the folder exists is kept and saved once it is set.
    var folder: URL? {
        didSet { if folder != nil { save() } }
    }

    private var saveTimer: Timer?
    private var nextImage = 1

    var fileURL: URL? { folder?.appendingPathComponent("notes.md") }
    var imagesURL: URL? { folder?.appendingPathComponent("images") }

    override init() {
        // TextKit 1: image attachment cells can be resized in place, so big screenshots fit the pad.
        textView = MarkdownTextView(usingTextLayoutManager: false)
        scrollView = NSScrollView()
        super.init()

        textView.isRichText = true  // needed for image attachments; styling itself is computed
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false  // keep markdown quotes/dashes literal
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: MarkdownStyler.baseSize)
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: MarkdownStyler.baseSize),
                                     .foregroundColor: NSColor.textColor]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.textStorage?.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        // Window resized → re-fit images to the new width.
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitImages() }
        }
    }

    /// Drop the pad without saving (cancelled meeting).
    func discard() {
        saveTimer?.invalidate()
        folder = nil
        nextImage = 1
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    /// Start a fresh pad for the next meeting (saves the current one first).
    func reset() {
        save()
        folder = nil
        nextImage = 1
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    // Restyle inside processEditing: the one place attribute changes fold into the same edit.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MarkdownStyler.apply(to: textStorage)
    }

    func textDidChange(_ notification: Notification) {
        fitImages()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
    }

    /// Sizes every image to fit the pad: its natural size, but never wider than the pad. Rebuilt from
    /// the attachment's original data each time, so the pad shrinking and growing both work. The file
    /// wrapper (what gets saved) always keeps the full-resolution image.
    func fitImages() {
        guard let storage = textView.textStorage, let container = textView.textContainer else { return }
        let maxWidth = max(container.size.width - container.lineFragmentPadding * 2 - 4, 80)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let data = attachment.fileWrapper?.regularFileContents,
                  let original = NSImage(data: data), original.size.width > 0 else { return }
            let width = min(original.size.width, maxWidth)
            if let cell = attachment.attachmentCell as? NSTextAttachmentCell,
               let shown = cell.image, abs(shown.size.width - width) < 0.5 { return }  // already right
            original.size = NSSize(width: width, height: original.size.height * width / original.size.width)
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: original)
            textView.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    /// The pad as markdown: text as typed, each attachment replaced by a link to its file in images/.
    /// Assigns file names on first use (stored on the attachment's file wrapper, so they follow
    /// the attachment through cut/paste) and returns the files that need to exist.
    func markdown() -> (text: String, files: [String: Data]) {
        guard let storage = textView.textStorage else { return ("", [:]) }
        let ns = storage.string as NSString
        var text = ""
        var files: [String: Data] = [:]
        var cursor = 0
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let wrapper = attachment.fileWrapper,
                  let raw = wrapper.regularFileContents else { return }
            text += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            cursor = NSMaxRange(range)

            let isImage = NSBitmapImageRep(data: raw) != nil
            var name = wrapper.preferredFilename ?? ""
            if !Self.isOurs(name) {
                let ext = isImage ? "png" : ((name as NSString).pathExtension.isEmpty ? "bin" : (name as NSString).pathExtension)
                name = "paste-\(nextImage).\(ext)"
                nextImage += 1
                wrapper.preferredFilename = name
            }
            if files[name] == nil {
                files[name] = isImage ? (NSBitmapImageRep(data: raw)?.representation(using: .png, properties: [:]) ?? raw) : raw
            }
            text += isImage ? "![](images/\(name))" : "[\(name)](images/\(name))"
        }
        text += ns.substring(from: cursor)
        return (text, files)
    }

    private static func isOurs(_ name: String) -> Bool {
        name.range(of: #"^paste-\d+\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    func save() {
        saveTimer?.invalidate()
        guard let url = fileURL, let images = imagesURL, let storage = textView.textStorage else { return }
        // Don't create an empty notes.md for a meeting where nothing was written.
        if storage.length == 0, !FileManager.default.fileExists(atPath: url.path) { return }
        let (text, files) = markdown()
        do {
            let fm = FileManager.default
            if !files.isEmpty { try fm.createDirectory(at: images, withIntermediateDirectories: true) }
            for (name, data) in files where !fm.fileExists(atPath: images.appendingPathComponent(name).path) {
                try data.write(to: images.appendingPathComponent(name), options: .atomic)
            }
            // Images deleted from the pad: remove their files (only ones this pad created).
            for name in (try? fm.contentsOfDirectory(atPath: images.path)) ?? []
            where Self.isOurs(name) && files[name] == nil {
                try? fm.removeItem(at: images.appendingPathComponent(name))
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("MeetingAgent: saving notes failed: \(error)")
        }
    }
}
