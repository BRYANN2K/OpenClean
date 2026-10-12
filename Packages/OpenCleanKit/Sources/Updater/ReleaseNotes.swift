import Foundation

/// Release notes split into display blocks. Handles the Markdown that `scripts/next-version.sh --notes`
/// writes (`## Headings`, `- bullets`, `**bold**`, inline code and links); anything else is a paragraph.
/// Inline Markdown is parsed into `AttributedString`; text that fails to parse is shown literally.
public enum ReleaseNoteBlock: Sendable, Equatable, Identifiable {
    case heading(AttributedString, id: Int)
    case bullet(AttributedString, id: Int)
    case paragraph(AttributedString, id: Int)

    public var id: Int {
        switch self {
        case .heading(_, let id), .bullet(_, let id), .paragraph(_, let id): id
        }
    }

    public var text: AttributedString {
        switch self {
        case .heading(let text, _), .bullet(let text, _), .paragraph(let text, _): text
        }
    }
}

public enum ReleaseNotes {
    public static func blocks(from markdown: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: " ")), id: blocks.count))
            paragraph = []
        }

        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { blocks.append(.heading(inline(title), id: blocks.count)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(inline(String(line.dropFirst(2))), id: blocks.count))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
