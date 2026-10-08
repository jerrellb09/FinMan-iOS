import Foundation
#if canImport(CoreXLSX)
import CoreXLSX
#endif

/// The text of every cell in a CSV or Excel file, sheet by sheet. Excel dates come out as yyyy-MM-dd.
nonisolated struct Spreadsheet: Sendable {
    struct Sheet: Sendable {
        var name: String
        var rows: [[String]]
    }

    enum ReadError: LocalizedError {
        case unreadable, empty, numbers

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file couldn't be opened. Try saving it again as .xlsx or .csv."
            case .empty: "That spreadsheet looks empty."
            case .numbers: "Numbers files can't be read directly. In Numbers, choose File › Export To › Excel or CSV, then import that."
            }
        }
    }

    var sheets: [Sheet]

    private static let maxRows = 5_000
    private static let maxSheets = 10

    static func read(data: Data, fileExtension: String) throws -> Spreadsheet {
        let sheets: [Sheet]
        switch fileExtension.lowercased() {
        case "numbers":
            throw ReadError.numbers
        case "xlsx", "xlsm":
            sheets = try xlsx(data)
        default:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else { throw ReadError.unreadable }
            sheets = [Sheet(name: "Sheet 1", rows: csv(text))]
        }
        let cleaned = sheets.map { Sheet(name: $0.name, rows: trimmed($0.rows)) }.filter { !$0.rows.isEmpty }
        guard !cleaned.isEmpty else { throw ReadError.empty }
        return Spreadsheet(sheets: cleaned)
    }

    /// Drops empty rows and columns, so layouts can be read from the top-left.
    static func trimmed(_ rows: [[String]]) -> [[String]] {
        let clean = rows.prefix(maxRows)
            .map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
            .filter { $0.contains { !$0.isEmpty } }
        let width = clean.map(\.count).max() ?? 0
        let usedColumns = (0..<width).filter { col in clean.contains { col < $0.count && !$0[col].isEmpty } }
        return clean.map { row in usedColumns.map { $0 < row.count ? row[$0] : "" } }
    }

    // MARK: CSV

    /// RFC 4180 CSV (quoted fields, doubled quotes, line breaks inside quotes), comma, semicolon or tab separated.
    static func csv(_ raw: String) -> [[String]] {
        let text = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        // Title lines often have no separators, so count over the first few lines.
        let sample = text.split(whereSeparator: \.isNewline).prefix(10).joined(separator: "\n")
        let counts = ([",", ";", "\t"] as [Character]).map { delimiter in (delimiter: delimiter, count: sample.filter { $0 == delimiter }.count) }
        let delimiter = counts.max { $0.count < $1.count }.flatMap { $0.count > 0 ? $0.delimiter : nil } ?? ","

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                row.append(field)
                field = ""
            case "\n", "\r", "\r\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    // MARK: Excel

    static func xlsx(_ data: Data) throws -> [Sheet] {
        #if canImport(CoreXLSX)
        guard let file = try? XLSXFile(data: data) else { throw ReadError.unreadable }
        let shared = (try? file.parseSharedStrings()) ?? nil
        let styles = try? file.parseStyles()
        var sheets: [Sheet] = []

        for workbook in (try? file.parseWorkbooks()) ?? [] {
            for (name, path) in (try? file.parseWorksheetPathsAndNames(workbook: workbook)) ?? [] {
                guard sheets.count < maxSheets, let worksheet = try? file.parseWorksheet(at: path) else { continue }
                var grid: [[String]] = []
                for row in worksheet.data?.rows ?? [] {
                    for cell in row.cells {
                        let r = Int(cell.reference.row) - 1
                        let c = columnIndex(cell.reference.column.value)
                        guard r >= 0, r < maxRows, c < 200 else { continue }
                        let text = value(of: cell, shared: shared, styles: styles)
                        guard !text.isEmpty else { continue }
                        while grid.count <= r { grid.append([]) }
                        while grid[r].count <= c { grid[r].append("") }
                        grid[r][c] = text
                    }
                }
                sheets.append(Sheet(name: name ?? "Sheet \(sheets.count + 1)", rows: grid))
            }
        }
        guard !sheets.isEmpty else { throw ReadError.unreadable }
        return sheets
        #else
        throw ReadError.unreadable
        #endif
    }

    /// "A" → 0, "Z" → 25, "AA" → 26.
    static func columnIndex(_ letters: String) -> Int {
        letters.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    #if canImport(CoreXLSX)
    private static func value(of cell: Cell, shared: SharedStrings?, styles: Styles?) -> String {
        switch cell.type {
        case .sharedString?:
            guard let shared, let index = cell.value.flatMap(Int.init), index < shared.items.count else { return "" }
            let item = shared.items[index]
            return item.text ?? item.richText.compactMap(\.text).joined()
        case .inlineStr?:
            return cell.inlineString?.text ?? ""
        case .bool?:
            return cell.value == "1" ? "TRUE" : "FALSE"
        case .error?:
            return ""
        case .date?:
            return cell.value ?? ""
        default:
            guard let raw = cell.value else { return "" }
            if isDateFormatted(cell, styles: styles), let date = cell.dateValue {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
            return raw
        }
    }

    /// Excel stores dates as day counts; only the cell's number format says it's a date.
    private static func isDateFormatted(_ cell: Cell, styles: Styles?) -> Bool {
        guard let index = cell.styleIndex, let formats = styles?.cellFormats?.items, index < formats.count else { return false }
        let id = formats[index].numberFormatId
        if (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) { return true }
        guard let code = styles?.numberFormats?.items.first(where: { $0.id == id })?.formatCode.lowercased() else { return false }
        // Ignore quoted text and [color]/[locale] sections, then look for day or year codes.
        let stripped = code.replacingOccurrences(of: #""[^"]*"|\[[^\]]*\]"#, with: "", options: .regularExpression)
        return stripped.contains("d") || stripped.contains("y")
    }
    #endif
}
