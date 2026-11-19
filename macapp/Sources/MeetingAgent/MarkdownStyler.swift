import AppKit

/// Live markdown styling for the note pad: the markdown symbols stay in the text (they are what
/// gets saved), they are just dimmed, and the text they mark up is styled.
/// Only display attributes are touched — characters and attachments are never changed.
enum MarkdownStyler {
    static let baseSize: CGFloat = 13
    static let managed: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .strikethroughStyle]

    private static let marker = NSColor.tertiaryLabelColor
    private static let accent = NSColor.controlAccentColor
    private static let codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.12)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try — patterns are constants
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let fence = regex(#"^```[^\n]*\n[\s\S]*?^```[^\n]*$"#)
    private static let inlineCode = regex(#"`[^`\n]+`"#)
    private static let heading = regex(#"^(#{1,6})[ \t]+\S[^\n]*$"#)
    private static let quote = regex(#"^(>+)[^\n]*$"#)
    private static let checkbox = regex(#"^([ \t]*[-*+] \[([ xX])\])([ \t]+[^\n]*)?$"#)
    private static let listItem = regex(#"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"#)
    private static let rule = regex(#"^(?:-{3,}|\*{3,}|_{3,})[ \t]*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)([^\n]+?)(?<=\S)\1"#)
    private static let italicStar = regex(#"(?<![*\\])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?!\*)"#)
    private static let italicUnderscore = regex(#"(?<![_\w])_(?=\S)([^_\n]+?)(?<=\S)_(?![_\w])"#)
    private static let strike = regex(#"~~(?=\S)([^\n]+?)(?<=\S)~~"#)
    private static let link = regex(#"!?\[([^\]\n]*)\]\(([^)\n]+)\)"#)

    static func apply(to storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        let text = storage.string
        let base = NSFont.systemFont(ofSize: baseSize)
        let mono = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)

        storage.beginEditing()
        defer { storage.endEditing() }
        for key in managed { storage.removeAttribute(key, range: all) }
        storage.addAttributes([.font: base, .foregroundColor: NSColor.textColor], range: all)

        // Code first: nothing inside a code span or block gets any other styling.
        var protected: [NSRange] = []
        for m in matches(fence, text) {
            protected.append(m.range)
            storage.addAttributes([.font: mono, .backgroundColor: codeBackground], range: m.range)
            dim(storage, firstLine(of: m.range, in: text))
            dim(storage, lastLine(of: m.range, in: text))
        }
        for m in matches(inlineCode, text) where !overlaps(m.range, protected) {
            protected.append(m.range)
            storage.addAttributes([.font: mono, .backgroundColor: codeBackground], range: m.range)
            dim(storage, NSRange(location: m.range.location, length: 1))
            dim(storage, NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        func free(_ m: NSTextCheckingResult) -> Bool { !overlaps(m.range, protected) }

        for m in matches(heading, text) where free(m) {
            let level = m.range(at: 1).length
            let size: CGFloat = [22, 18, 16, 14, 13, 13][level - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: m.range)
            dim(storage, m.range(at: 1))
        }
        for m in matches(quote, text) where free(m) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
        }
        for m in matches(rule, text) where free(m) { dim(storage, m.range) }
        for m in matches(listItem, text) where free(m) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range)
        }
        for m in matches(checkbox, text) where free(m) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
            let done = (text as NSString).substring(with: m.range(at: 2)).lowercased() == "x"
            if done, m.range(at: 3).location != NSNotFound {
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: m.range(at: 3))
            }
        }

        for m in matches(bold, text) where free(m) {
            addTrait(.boldFontMask, storage, m.range(at: 2))
            let markerLength = m.range(at: 1).length
            dim(storage, NSRange(location: m.range.location, length: markerLength))
            dim(storage, NSRange(location: NSMaxRange(m.range) - markerLength, length: markerLength))
        }
        for pattern in [italicStar, italicUnderscore] {
            for m in matches(pattern, text) where free(m) {
                addTrait(.italicFontMask, storage, m.range(at: 1))
                dim(storage, NSRange(location: m.range.location, length: 1))
                dim(storage, NSRange(location: NSMaxRange(m.range) - 1, length: 1))
            }
        }
        for m in matches(strike, text) where free(m) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            dim(storage, NSRange(location: m.range.location, length: 2))
            dim(storage, NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in matches(link, text) where free(m) {
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 1))
            dim(storage, m.range(at: 2))
        }
    }

    // MARK: helpers

    private static func matches(_ re: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: marker, range: range)
    }

    /// Adds bold/italic on top of whatever font is already there (e.g. bold inside a heading).
    private static func addTrait(_ trait: NSFontTraitMask, _ storage: NSTextStorage, _ range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: baseSize)
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
        }
    }

    private static func firstLine(of range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
        return NSIntersectionRange(line, range)
    }

    private static func lastLine(of range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: max(NSMaxRange(range) - 1, range.location), length: 0))
        return NSIntersectionRange(line, range)
    }
}
