import Foundation
import SwiftUI

enum TextPreviewDisplayMode: String, CaseIterable, Identifiable {
    case raw
    case renderedMarkdown
    case table
    case outline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw:
            return "Raw"
        case .renderedMarkdown:
            return "Rendered"
        case .table:
            return "Table"
        case .outline:
            return "Outline"
        }
    }

    static func defaultMode(fileName: String, language: String?) -> TextPreviewDisplayMode {
        availableModes(fileName: fileName, language: language).first ?? .raw
    }

    static func availableModes(fileName: String, language: String?) -> [TextPreviewDisplayMode] {
        switch structuredKind(fileName: fileName, language: language) {
        case .markdown:
            return [.renderedMarkdown, .raw]
        case .delimited:
            return [.table, .raw]
        case .json:
            return [.outline, .raw]
        case .none:
            return [.raw]
        }
    }

    private enum StructuredKind {
        case markdown
        case delimited
        case json
    }

    private static func structuredKind(fileName: String, language: String?) -> StructuredKind? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        if ["csv", "tsv"].contains(ext) {
            return .delimited
        }
        if ["json", "jsonl", "ndjson"].contains(ext) {
            return .json
        }
        if ["markdown", "md", "mdown", "mdtext", "mdwn", "mkd"].contains(ext) {
            return .markdown
        }

        switch language {
        case "csv":
            return .delimited
        case "json":
            return .json
        case "markdown":
            return .markdown
        default:
            return nil
        }
    }
}

struct MarkdownRenderedPreview: View {
    let text: String
    let query: String

    var body: some View {
        ScrollView {
            Text(TextPreviewFormatter.highlightedText(renderedText, query: query, language: nil))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private var renderedText: String {
        MarkdownPreviewRenderer.renderedText(text)
    }
}

enum MarkdownPreviewRenderer {
    static func renderedText(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { renderedLine(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderedLine(_ line: String) -> String {
        var rendered = line.replacingOccurrences(
            of: #"^\s{0,3}#{1,6}\s+"#,
            with: "",
            options: .regularExpression
        )
        rendered = rendered.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        for token in ["**", "__", "`", "*", "_"] {
            rendered = rendered.replacingOccurrences(of: token, with: "")
        }
        return rendered
    }
}

struct DelimitedPreviewTable {
    let headers: [String]
    let rows: [[String]]
    let totalRowCount: Int
    let totalColumnCount: Int
    let truncatedRows: Bool
    let truncatedColumns: Bool
    let columnWidths: [CGFloat]

    var isEmpty: Bool {
        headers.isEmpty && rows.isEmpty
    }
}

enum DelimitedTextParser {
    static func delimiter(forFileName fileName: String) -> Character {
        URL(fileURLWithPath: fileName).pathExtension.lowercased() == "tsv" ? "\t" : ","
    }

    static func parse(
        _ text: String,
        delimiter: Character,
        maxRows: Int = 80,
        maxColumns: Int = 12
    ) -> DelimitedPreviewTable {
        let records = parsedRecords(text, delimiter: delimiter)
            .filter { row in
                row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        guard let headerRow = records.first else {
            return DelimitedPreviewTable(
                headers: [],
                rows: [],
                totalRowCount: 0,
                totalColumnCount: 0,
                truncatedRows: false,
                truncatedColumns: false,
                columnWidths: []
            )
        }

        let widestRowCount = records.map(\.count).max() ?? 0
        let visibleColumnCount = min(max(widestRowCount, 1), maxColumns)
        let headers = (0..<visibleColumnCount).map { index in
            guard index < headerRow.count else { return "Column \(index + 1)" }
            let title = headerRow[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "Column \(index + 1)" : title
        }

        let bodyRows = Array(records.dropFirst())
        let visibleRows = bodyRows.prefix(maxRows).map { row in
            (0..<visibleColumnCount).map { index in
                index < row.count ? row[index] : ""
            }
        }

        return DelimitedPreviewTable(
            headers: headers,
            rows: visibleRows,
            totalRowCount: bodyRows.count,
            totalColumnCount: widestRowCount,
            truncatedRows: bodyRows.count > maxRows,
            truncatedColumns: widestRowCount > maxColumns,
            columnWidths: columnWidths(headers: headers, rows: visibleRows)
        )
    }

    private static func columnWidths(headers: [String], rows: [[String]]) -> [CGFloat] {
        headers.indices.map { index in
            let headerLength = headers[index].count
            let rowLength = rows.map { row in
                index < row.count ? row[index].count : 0
            }.max() ?? 0
            let visibleCharacterCount = min(max(headerLength, rowLength), 24)
            return CGFloat(max(10, visibleCharacterCount)) * 8 + 28
        }
    }

    private static func parsedRecords(_ text: String, delimiter: Character) -> [[String]] {
        guard !text.isEmpty else { return [] }

        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex
        var endedOnRecordBoundary = false

        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let nextIndex = text.index(after: index)
                    if nextIndex < text.endIndex, text[nextIndex] == "\"" {
                        field.append("\"")
                        index = text.index(after: nextIndex)
                    } else {
                        inQuotes = false
                        index = nextIndex
                    }
                } else {
                    field.append(character)
                    index = text.index(after: index)
                }
                endedOnRecordBoundary = false
                continue
            }

            if character == "\"" {
                inQuotes = true
                index = text.index(after: index)
                endedOnRecordBoundary = false
            } else if character == delimiter {
                row.append(field)
                field = ""
                index = text.index(after: index)
                endedOnRecordBoundary = false
            } else if character == "\n" || character == "\r" {
                row.append(field)
                records.append(row)
                row = []
                field = ""
                let nextIndex = text.index(after: index)
                if character == "\r", nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    index = text.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                endedOnRecordBoundary = true
            } else {
                field.append(character)
                index = text.index(after: index)
                endedOnRecordBoundary = false
            }
        }

        if !endedOnRecordBoundary || !row.isEmpty || !field.isEmpty {
            row.append(field)
            records.append(row)
        }

        return records
    }
}

struct DelimitedTablePreview: View {
    let text: String
    let delimiter: Character
    let query: String

    var body: some View {
        let table = DelimitedTextParser.parse(text, delimiter: delimiter)

        if table.isEmpty {
            ScrollView {
                Text("No tabular rows found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                tableSummary(table)
                    .padding(.horizontal)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemGroupedBackground))

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        tableRow(table.headers, widths: table.columnWidths, isHeader: true)
                            .background(Color(.tertiarySystemFill))
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                                    tableRow(row, widths: table.columnWidths, isHeader: false)
                                }
                                if table.truncatedRows || table.truncatedColumns {
                                    Text(tableLimitText(table))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 8)
                                        .padding(.bottom, 12)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func tableSummary(_ table: DelimitedPreviewTable) -> some View {
        HStack(spacing: 8) {
            Label("\(table.totalRowCount) \(table.totalRowCount == 1 ? "row" : "rows")", systemImage: "tablecells")
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(table.totalColumnCount) \(table.totalColumnCount == 1 ? "column" : "columns")")
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func tableRow(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(TextPreviewFormatter.highlightedText(cell, query: query, language: nil))
                    .font(.system(.caption, design: .monospaced).weight(isHeader ? .semibold : .regular))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(width: index < widths.count ? widths[index] : 148, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(isHeader ? Color(.tertiarySystemFill) : Color(.systemBackground))
                    .overlay(
                        Rectangle()
                            .stroke(Color(.separator).opacity(0.16), lineWidth: 0.5)
                    )
            }
        }
    }

    private func tableLimitText(_ table: DelimitedPreviewTable) -> String {
        var parts: [String] = []
        if table.truncatedRows {
            parts.append("showing \(table.rows.count) of \(table.totalRowCount) rows")
        }
        if table.truncatedColumns {
            parts.append("showing \(table.headers.count) of \(table.totalColumnCount) columns")
        }
        return parts.joined(separator: ", ")
    }
}

struct JSONPreviewNode {
    let key: String?
    let value: String
    let kind: String
    let children: [JSONPreviewNode]
}

struct JSONPreviewRow: Identifiable {
    let id = UUID()
    let depth: Int
    let key: String
    let value: String
    let kind: String
}

enum JSONPreviewParser {
    static func parse(_ text: String) -> JSONPreviewNode? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let value = parseJSONValue(trimmed) {
            return node(key: "Root", value: value)
        }

        let lineValues = trimmed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseJSONValue(String($0)) }
        guard !lineValues.isEmpty else { return nil }
        return node(key: "JSON Lines", value: lineValues)
    }

    static func flattenedRows(from node: JSONPreviewNode, maxRows: Int = 200) -> [JSONPreviewRow] {
        var rows: [JSONPreviewRow] = []
        appendRows(from: node, depth: 0, rows: &rows, maxRows: maxRows)
        return rows
    }

    private static func appendRows(
        from node: JSONPreviewNode,
        depth: Int,
        rows: inout [JSONPreviewRow],
        maxRows: Int
    ) {
        guard rows.count < maxRows else { return }
        rows.append(JSONPreviewRow(depth: depth, key: node.key ?? "Value", value: node.value, kind: node.kind))
        for child in node.children {
            appendRows(from: child, depth: depth + 1, rows: &rows, maxRows: maxRows)
        }
    }

    private static func parseJSONValue(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func node(key: String?, value: Any) -> JSONPreviewNode {
        if let dictionary = value as? [String: Any] {
            let children = dictionary.keys.sorted().map { childKey in
                node(key: childKey, value: dictionary[childKey] as Any)
            }
            return JSONPreviewNode(
                key: key,
                value: "\(children.count) \(children.count == 1 ? "key" : "keys")",
                kind: "object",
                children: children
            )
        }

        if let array = value as? [Any] {
            let children = array.enumerated().map { index, child in
                node(key: "[\(index)]", value: child)
            }
            return JSONPreviewNode(
                key: key,
                value: "\(children.count) \(children.count == 1 ? "item" : "items")",
                kind: "array",
                children: children
            )
        }

        if value is NSNull {
            return JSONPreviewNode(key: key, value: "null", kind: "null", children: [])
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return JSONPreviewNode(
                    key: key,
                    value: number.boolValue ? "true" : "false",
                    kind: "boolean",
                    children: []
                )
            }
            return JSONPreviewNode(key: key, value: number.stringValue, kind: "number", children: [])
        }

        if let bool = value as? Bool {
            return JSONPreviewNode(key: key, value: bool ? "true" : "false", kind: "boolean", children: [])
        }

        if let string = value as? String {
            return JSONPreviewNode(key: key, value: string, kind: "string", children: [])
        }

        return JSONPreviewNode(key: key, value: String(describing: value), kind: "value", children: [])
    }
}

struct JSONOutlinePreview: View {
    let text: String
    let query: String

    var body: some View {
        let root = JSONPreviewParser.parse(text)

        ScrollView {
            if let root {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(JSONPreviewParser.flattenedRows(from: root)) { row in
                        rowView(row)
                    }
                }
                .padding()
            } else {
                Text("JSON could not be parsed. Switch to Raw to inspect the text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private func rowView(_ row: JSONPreviewRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.key)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(row.kind == "object" || row.kind == "array" ? .primary : .secondary)
                .frame(minWidth: 72, alignment: .leading)
            Text(TextPreviewFormatter.highlightedText(row.value, query: query, language: nil))
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(row.depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum TextPreviewFormatter {
    static func numberedText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = String(max(lines.count, 1)).count
        return lines.enumerated().map { index, line in
            "\(String(index + 1).leftPadded(toLength: width))  \(line)"
        }.joined(separator: "\n")
    }

    static func matchCount(in text: String, query: String) -> Int {
        matchRanges(in: text, query: query).count
    }

    static func matchRanges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: [.caseInsensitive], range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<text.endIndex
        }
        return ranges
    }

    static func highlightedText(_ text: String, query: String, language: String? = nil) -> AttributedString {
        let attributed = FilePreviewLanguage.highlightedText(text, language: language)
        return highlightQuery(in: attributed, query: query)
    }

    static func highlightQuery(in attributed: AttributedString, query: String) -> AttributedString {
        var highlighted = attributed
        let text = String(highlighted.characters)
        for range in matchRanges(in: text, query: query) {
            guard let attributedRange = Range(range, in: highlighted) else { continue }
            highlighted[attributedRange].backgroundColor = Color.yellow.opacity(0.35)
            highlighted[attributedRange].foregroundColor = Color.primary
        }
        return highlighted
    }
}

enum TextPreviewDataDecoder {
    struct PrefixDecodeResult {
        let text: String
        let byteCount: Int
    }

    static func decodedText(from data: Data) -> String? {
        for encoding in preferredEncodings(for: data) {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    static func decodedPrefix(from data: Data) -> PrefixDecodeResult? {
        guard !data.isEmpty else {
            return PrefixDecodeResult(text: "", byteCount: 0)
        }
        for encoding in preferredEncodings(for: data) {
            if requiresEvenByteCount(encoding), !data.count.isMultiple(of: 2),
               let prefix = longestDecodablePrefix(data, encoding: encoding) {
                return prefix
            }
            if let text = String(data: data, encoding: encoding) {
                return PrefixDecodeResult(text: text, byteCount: data.count)
            }
            if let prefix = longestDecodablePrefix(data, encoding: encoding) {
                return prefix
            }
        }
        return nil
    }

    private static func preferredEncodings(for data: Data) -> [String.Encoding] {
        if data.starts(with: Data([0xEF, 0xBB, 0xBF])) {
            return [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
        }
        if data.starts(with: Data([0xFF, 0xFE])) {
            return [.utf16, .utf16LittleEndian, .utf8, .utf16BigEndian, .isoLatin1]
        }
        if data.starts(with: Data([0xFE, 0xFF])) {
            return [.utf16, .utf16BigEndian, .utf8, .utf16LittleEndian, .isoLatin1]
        }
        if let nulPatternEncoding = encodingFromNulPattern(data) {
            let fallback: [String.Encoding] = nulPatternEncoding == .utf16LittleEndian
                ? [.utf16BigEndian, .utf16]
                : [.utf16LittleEndian, .utf16]
            return [nulPatternEncoding, .utf8] + fallback + [.isoLatin1]
        }
        return [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
    }

    private static func encodingFromNulPattern(_ data: Data) -> String.Encoding? {
        let sample = Array(data.prefix(512))
        guard sample.count >= 4 else { return nil }

        var evenNulls = 0
        var oddNulls = 0
        var evenCount = 0
        var oddCount = 0
        for (index, byte) in sample.enumerated() {
            if index.isMultiple(of: 2) {
                evenCount += 1
                if byte == 0 { evenNulls += 1 }
            } else {
                oddCount += 1
                if byte == 0 { oddNulls += 1 }
            }
        }

        let evenRatio = Double(evenNulls) / Double(max(evenCount, 1))
        let oddRatio = Double(oddNulls) / Double(max(oddCount, 1))
        if oddNulls >= 2, oddRatio > 0.35, oddRatio > evenRatio * 2 {
            return .utf16LittleEndian
        }
        if evenNulls >= 2, evenRatio > 0.35, evenRatio > oddRatio * 2 {
            return .utf16BigEndian
        }
        return nil
    }

    private static func requiresEvenByteCount(_ encoding: String.Encoding) -> Bool {
        [.utf16, .utf16LittleEndian, .utf16BigEndian].contains(encoding)
    }

    private static func longestDecodablePrefix(_ data: Data, encoding: String.Encoding) -> PrefixDecodeResult? {
        guard data.count > 1 else { return nil }
        for count in stride(from: data.count - 1, through: 1, by: -1) {
            if requiresEvenByteCount(encoding), !count.isMultiple(of: 2) {
                continue
            }
            let prefix = data.prefix(count)
            if let text = String(data: prefix, encoding: encoding) {
                return PrefixDecodeResult(text: text, byteCount: count)
            }
        }
        return nil
    }
}

private extension String {
    func leftPadded(toLength length: Int) -> String {
        guard count < length else { return self }
        return String(repeating: " ", count: length - count) + self
    }
}
