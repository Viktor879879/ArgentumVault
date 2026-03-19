import Foundation

enum CSVExporter {
    static func transactionsCSV(_ transactions: [Transaction]) -> String {
        var rows: [String] = []
        rows.append("Date,Type,Amount,Currency,Category,Wallet,Note")
        
        let formatter = ISO8601DateFormatter()
        for transaction in transactions {
            let date = formatter.string(from: transaction.date)
            let type = (transaction.type ?? .expense) == .income ? "Income" : "Expense"
            let amount = DecimalFormatter.editingString(from: transaction.amount)
            let currency = transaction.currencyCode
            let category = csvEscape(transaction.category?.name ?? "")
            let wallet = csvEscape(transaction.wallet?.name ?? "")
            let note = csvEscape(transaction.note ?? "")
            rows.append("\(date),\(type),\(amount),\(currency),\(category),\(wallet),\(note)")
        }
        
        return rows.joined(separator: "\n")
    }
    
    static func writeCSVToDocuments(_ content: String, filename: String) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = directory.appendingPathComponent(filename)
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
    
    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
