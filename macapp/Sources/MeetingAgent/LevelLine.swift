import Foundation

enum LevelLine {
    /// "[level] 35 80" → (me: 0.35, others: 0.8). The line may have input()'s "note> " prompt in
    /// front of it, so the marker is searched for, not matched at the start.
    static func parse(_ line: String) -> (me: Double, others: Double)? {
        guard let marker = line.range(of: "[level]") else { return nil }
        let numbers = line[marker.upperBound...].split(separator: " ").compactMap { Double($0) }
        guard numbers.count == 2 else { return nil }
        let unit = { (value: Double) in min(max(value / 100, 0), 1) }
        return (unit(numbers[0]), unit(numbers[1]))
    }
}
