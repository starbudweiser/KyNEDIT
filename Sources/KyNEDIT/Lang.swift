import Foundation

/// Langue de l'interface : première langue préférée du système parmi fr/en/es/it, sinon anglais.
enum Lang {
    static let supported = ["fr", "en", "es", "it"]
    static let current: String = {
        for id in Locale.preferredLanguages {
            let code = String(id.prefix(2))
            if supported.contains(code) { return code } // sinon on essaie la langue préférée suivante
        }
        return "en"
    }()
}

/// Texte traduit par clé ; arguments %@ facultatifs. Aucune chaîne visible n'est écrite en dur ailleurs.
func L(_ key: String, _ args: CVarArg...) -> String {
    let table = Strings.table[Lang.current] ?? Strings.table["en"]!
    let fmt = table[key] ?? Strings.table["en"]?[key] ?? key
    return args.isEmpty ? fmt : String(format: fmt, arguments: args)
}
