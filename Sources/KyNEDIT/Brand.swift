import SwiftUI
import AppKit

/// Nom de l'appli (règle Socle « Nom de l'appli ») : tout en majuscules sauf une lettre, toujours colorée dans l'interface.
enum Brand {
    static let name = "kYNEDIT"
    static let color = Socle.accentText

    /// Plages des lettres minuscules du nom dans un texte.
    static func lowercaseRanges(in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: name, range: from..<text.endIndex) {
            for i in text[r].indices where text[i].isLowercase { out.append(i..<text.index(after: i)) }
            from = r.upperBound
        }
        return out
    }

    /// Texte SwiftUI dont la lettre minuscule du nom est colorée (à chaque occurrence).
    static func text(_ s: String) -> Text {
        let ranges = lowercaseRanges(in: s)
        var out = Text(""); var pos = s.startIndex
        for r in ranges {
            out = out + Text(s[pos..<r.lowerBound])
            out = out + Text(s[r]).foregroundColor(color)
            pos = r.upperBound
        }
        return out + Text(s[pos...])
    }
}
