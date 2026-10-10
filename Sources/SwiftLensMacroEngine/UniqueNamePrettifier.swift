/// Rewrites compiler-mangled unique names such as `$s3obs7Counter10ObservablefMm_6MemberfMu_` (from
/// `context.makeUniqueName("Member")`) into short readable identifiers like `__Member_1`.
///
/// The mapping is deterministic within one prettifier, so the same mangled name always maps to the same
/// readable one and different mangled names never collide.
public final class UniqueNamePrettifier {
    private var mapping: [String: String] = [:]
    private var usedNames: Set<String> = []

    public init() {}

    public func rewrite(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "$", text[index...].hasPrefix("$s") {
                var end = text.index(after: index)
                while end < text.endIndex, text[end].isIdentifierCharacter { end = text.index(after: end) }
                let candidate = String(text[index..<end])
                if let readable = readableName(for: candidate) {
                    output += readable
                    index = end
                    continue
                }
            }
            output.append(text[index])
            index = text.index(after: index)
        }
        return output
    }

    func readableName(for mangled: String) -> String? {
        if let existing = mapping[mangled] { return existing }
        guard let base = Self.uniqueBaseName(mangled) else { return nil }
        var counter = 1
        var name = "__\(base)_\(counter)"
        while usedNames.contains(name) {
            counter += 1
            name = "__\(base)_\(counter)"
        }
        usedNames.insert(name)
        mapping[mangled] = name
        return name
    }

    /// Extracts `Member` from `…6MemberfMu_` / `…6MemberfMu0_`.
    static func uniqueBaseName(_ mangled: String) -> String? {
        let characters = Array(mangled)
        guard characters.count > 5, characters.last == "_" else { return nil }
        // Strip the `fMu<digits>_` suffix.
        var end = characters.count - 1 // at "_"
        while end > 0, characters[end - 1].isNumber { end -= 1 }
        guard end >= 3, String(characters[(end - 3)..<end]) == "fMu" else { return nil }
        let nameEnd = end - 3
        // Find a split `<digits><name>` such that the digits equal the name length.
        for nameStart in stride(from: nameEnd - 1, to: 0, by: -1) {
            let length = nameEnd - nameStart
            var digitsStart = nameStart
            while digitsStart > 0, characters[digitsStart - 1].isNumber { digitsStart -= 1 }
            guard digitsStart < nameStart else { continue }
            // Only accept the shortest digit suffix that encodes the length.
            for split in digitsStart..<nameStart {
                if let value = Int(String(characters[split..<nameStart])), value == length {
                    let name = String(characters[nameStart..<nameEnd])
                    if let first = name.first, first.isLetter || first == "_" { return name }
                }
            }
        }
        return nil
    }
}

extension Character {
    var isIdentifierCharacter: Bool { isLetter || isNumber || self == "_" || self == "$" }
}
