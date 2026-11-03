import Foundation

/// Finds "Hey Lotti" in a transcript, tolerating what the speech recognizer does to the name
/// ("Lottie", "Lotty", "Loti", "Lodi") and rejecting what it isn't ("a lotta", "Lotte", "Lotto",
/// "Lola"). A greeting is required: a bare "Lotti" doesn't count.
public enum WakeWordMatcher {
    public struct Match: Equatable, Sendable {
        /// What was said after the wake phrase, without leading punctuation. Empty if nothing followed.
        public var command: String
    }

    static let greetings: Set<String> = ["hey", "hei", "hi", "hallo"]

    /// The first "greeting + Lotti" in `text`, or nil.
    public static func match(_ text: String) -> Match? {
        let words = words(in: text)
        for index in words.indices.dropLast() where greetings.contains(words[index].word) && isName(words[index + 1].word) {
            let rest = text[words[index + 1].end...]
            return Match(command: String(rest.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Runs of letters and digits, lowercased, with where each one ends.
    private static func words(in text: String) -> [(word: String, end: String.Index)] {
        var words: [(word: String, end: String.Index)] = []
        var start: String.Index?
        for index in text.indices {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil { start = index }
            if !isWordCharacter, let from = start {
                words.append((text[from..<index].lowercased(), index))
                start = nil
            }
        }
        if let from = start { words.append((text[from...].lowercased(), text.endIndex)) }
        return words
    }

    /// Spelling variants collapse to "loti": ie → i, y → i, d → t, double letters → one.
    static func normalized(_ word: String) -> String {
        var folded = word.lowercased().replacingOccurrences(of: "ie", with: "i")
            .replacingOccurrences(of: "y", with: "i").replacingOccurrences(of: "d", with: "t")
        folded = folded.reduce(into: "") { result, character in
            if result.last != character { result.append(character) }
        }
        return folded
    }

    /// Within one edit of "loti" after folding, starting with l and ending in i. The ending is
    /// what tells "Lotti" from "Lotta", "Lotte", "Lotto" and "Lola".
    static func isName(_ word: String) -> Bool {
        let name = normalized(word)
        guard name.count >= 3, name.first == "l", name.last == "i" else { return false }
        return editDistance(Array(name), Array("loti")) <= 1
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
