import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

enum AppTheme {
    static let bg = Color(red: 0.012, green: 0.024, blue: 0.040)
    static let panel = Color(red: 0.030, green: 0.054, blue: 0.078)
    static let panel2 = Color(red: 0.050, green: 0.078, blue: 0.110)
    static let stroke = Color(red: 0.105, green: 0.180, blue: 0.250)
    static let blue = Color(red: 0.075, green: 0.480, blue: 0.980)
    static let green = Color(red: 0.100, green: 0.820, blue: 0.430)
    static let orange = Color(red: 1.000, green: 0.620, blue: 0.080)
    static let red = Color(red: 1.000, green: 0.280, blue: 0.320)
    static let muted = Color(red: 0.560, green: 0.620, blue: 0.700)
}

func dollars(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "$0"
}

func money(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
}

func number(_ value: Double) -> String {
    if value.rounded() == value {
        return String(Int(value))
    }
    return String(format: "%.2f", value)
}

func signedPercent(_ value: Double) -> String {
    String(format: "%+.1f%%", value)
}

func recentDays(count: Int) -> [Date] {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: Date())
    return (0..<count).compactMap { offset in
        calendar.date(byAdding: .day, value: -offset, to: start)
    }
}

func shortWeekdaySymbols() -> [String] {
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}

func startOfMonth(_ date: Date) -> Date {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: components) ?? calendar.startOfDay(for: date)
}

func monthGridDates(for month: Date) -> [Date] {
    let calendar = Calendar.current
    let first = startOfMonth(month)
    let weekday = calendar.component(.weekday, from: first)
    let gridStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: first) ?? first
    return (0..<42).compactMap { offset in
        calendar.date(byAdding: .day, value: offset, to: gridStart)
    }
}

func daysInMonth(_ month: Date) -> [Date] {
    let calendar = Calendar.current
    let start = startOfMonth(month)
    guard let range = calendar.range(of: .day, in: .month, for: start) else {
        return []
    }
    return range.compactMap { day -> Date? in
        calendar.date(byAdding: .day, value: day - 1, to: start)
    }
}

func isSameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
    let calendar = Calendar.current
    let left = calendar.dateComponents([.year, .month], from: lhs)
    let right = calendar.dateComponents([.year, .month], from: rhs)
    return left.year == right.year && left.month == right.month
}

func monthYearLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"
    return formatter.string(from: date)
}

func parseJournalDate(_ timestamp: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: timestamp) {
        return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: timestamp)
}

func isSameJournalDay(_ timestamp: String, _ day: Date) -> Bool {
    guard let date = parseJournalDate(timestamp) else { return false }
    return Calendar.current.isDate(date, inSameDayAs: day)
}

func journalTime(_ timestamp: String) -> String {
    guard let date = parseJournalDate(timestamp) else { return "—" }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func dayLabel(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return "Today"
    }
    if Calendar.current.isDateInYesterday(date) {
        return "Yesterday"
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE"
    return formatter.string(from: date)
}

func monthDayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, yyyy"
    return formatter.string(from: date)
}

func longDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM d, yyyy"
    return formatter.string(from: date)
}

func appTimestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func jsonDouble(_ dict: [String: Any], _ key: String) -> Double {
    if let number = dict[key] as? NSNumber {
        return number.doubleValue
    }
    if let value = dict[key] as? Double {
        return value
    }
    if let value = dict[key] as? String, let parsed = Double(value) {
        return parsed
    }
    return 0
}

func jsonDoubleOptional(_ dict: [String: Any], _ key: String) -> Double? {
    if dict[key] is NSNull {
        return nil
    }
    if let number = dict[key] as? NSNumber {
        return number.doubleValue
    }
    if let value = dict[key] as? Double {
        return value
    }
    if let value = dict[key] as? String, let parsed = Double(value) {
        return parsed
    }
    return nil
}

func jsonInt(_ dict: [String: Any], _ key: String) -> Int? {
    if dict[key] is NSNull {
        return nil
    }
    if let number = dict[key] as? NSNumber {
        return number.intValue
    }
    if let value = dict[key] as? Int {
        return value
    }
    if let value = dict[key] as? String, let parsed = Int(value) {
        return parsed
    }
    return nil
}

func loadCSVGrid(from url: URL, limit: Int = 80) -> [CSVGridRow] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return []
    }
    let rows = parseCSV(text)
    guard let header = rows.first else {
        return []
    }
    return rows.dropFirst().prefix(limit).map { row in
        var cells: [String: String] = [:]
        for (index, key) in header.enumerated() {
            cells[key] = index < row.count ? row[index] : ""
        }
        return CSVGridRow(cells: cells)
    }
}

func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var iterator = text.makeIterator()

    while let char = iterator.next() {
        if char == "\"" {
            if inQuotes {
                if let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes = false
                }
            } else {
                inQuotes = true
            }
        } else if char == "," && !inQuotes {
            row.append(field)
            field = ""
        } else if char == "\n" && !inQuotes {
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        } else if char != "\r" {
            field.append(char)
        }
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows
}

struct AppError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
