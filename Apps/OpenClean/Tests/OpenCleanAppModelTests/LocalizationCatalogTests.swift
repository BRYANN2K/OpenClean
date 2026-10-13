import Foundation
import Quarantine
import Testing

@testable import OpenCleanAppModel

/// The app's String Catalogs (`Apps/OpenClean/Sources/{OpenCleanApp,OpenCleanAppModel}/Resources/
/// Localizable.xcstrings`): every key is translated into every shipped language, and every translation uses
/// the same format specifiers as its key, so `String(format:)` never reads an argument of the wrong type.
@Suite struct LocalizationCatalogTests {
    static let languages = ["de", "es", "fr", "ja", "zh-Hans"]
    static let targets = ["OpenCleanApp", "OpenCleanAppModel"]

    static func catalogURL(_ target: String) -> URL {
        // Apps/OpenClean/Tests/OpenCleanAppModelTests/<file> → Apps/OpenClean.
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/\(target)/Resources/Localizable.xcstrings")
    }

    struct Catalog: Decodable {
        var sourceLanguage: String
        var strings: [String: Entry]
    }

    struct Entry: Decodable {
        var localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        var stringUnit: StringUnit?
        var variations: Variations?
        var substitutions: [String: Substitution]?
    }

    struct StringUnit: Decodable {
        var state: String
        var value: String
    }

    struct Variations: Decodable {
        var plural: [String: Localization]
    }

    struct Substitution: Decodable {
        var argNum: Int
        var formatSpecifier: String
        var variations: Variations
    }

    static func load(_ target: String) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL(target)))
    }

    /// The arguments a format string reads, in argument order: "@" for objects, "d" for integers, "f" for
    /// floating point. Positional specifiers (`%2$@`) are placed at their position; `%%` reads nothing. A
    /// `%#@name@` substitution reads its own argument, given by `substitutions`.
    static func arguments(_ format: String, substitutions: [String: Substitution] = [:]) -> [Int: String] {
        let pattern = /%(?:(\d+)\$)?(#@(\w+)@|@|%|l{0,2}[dui]|[fFeEgG])/
        var result: [Int: String] = [:]
        var next = 1
        for match in format.matches(of: pattern) {
            let token = String(match.output.2)
            if token == "%" { continue }
            var position = match.output.1.flatMap { Int($0) }
            let kind: String
            if let name = match.output.3 {
                let substitution = substitutions[String(name)]
                kind = substitution.map { Self.kind(of: $0.formatSpecifier) } ?? "?"
                position = position ?? substitution?.argNum
            } else {
                kind = Self.kind(of: token)
            }
            let index = position ?? next
            next = index + 1
            result[index] = kind
        }
        return result
    }

    static func kind(of specifier: String) -> String {
        if specifier == "@" { return "@" }
        if specifier.last.map({ "fFeEgG".contains($0) }) == true { return "f" }
        return "d"
    }

    /// Every string one localization can produce, with the substitutions it uses.
    static func forms(_ localization: Localization) -> [(value: String, substitutions: [String: Substitution])] {
        var forms: [(String, [String: Substitution])] = []
        if let unit = localization.stringUnit { forms.append((unit.value, localization.substitutions ?? [:])) }
        for form in localization.variations?.plural.values.sorted(by: {
            $0.stringUnit?.value ?? "" < $1.stringUnit?.value ?? ""
        }) ?? [] {
            forms.append(contentsOf: Self.forms(form))
        }
        return forms
    }

    @Test(arguments: targets)
    func everyKeyIsTranslatedIntoEveryLanguage(target: String) throws {
        let catalog = try Self.load(target)
        #expect(catalog.sourceLanguage == "en")
        #expect(catalog.strings.count > 10)
        for (key, entry) in catalog.strings {
            for language in Self.languages {
                guard let localization = entry.localizations?[language] else {
                    Issue.record("\(target): \"\(key)\" has no \(language) translation")
                    continue
                }
                let units =
                    [localization.stringUnit].compactMap { $0 }
                    + (localization.variations?.plural.values.compactMap(\.stringUnit) ?? [])
                    + ((localization.substitutions ?? [:]).values.flatMap {
                        $0.variations.plural.values.compactMap(\.stringUnit)
                    }
                        ?? [])
                #expect(!units.isEmpty, "\(target): \"\(key)\" (\(language)) has no text")
                for unit in units {
                    #expect(unit.state == "translated", "\(target): \"\(key)\" (\(language)) is \(unit.state)")
                    #expect(!unit.value.isEmpty, "\(target): \"\(key)\" (\(language)) is empty")
                }
                if let plural = localization.variations?.plural {
                    #expect(plural["other"] != nil, "\(target): \"\(key)\" (\(language)) has no plural \"other\" form")
                }
                for substitution in (localization.substitutions ?? [:]).values {
                    #expect(substitution.variations.plural["other"] != nil, "\(target): \"\(key)\" (\(language))")
                }
            }
        }
    }

    @Test(arguments: targets)
    func formatSpecifiersMatchTheKeyInEveryLanguage(target: String) throws {
        let catalog = try Self.load(target)
        for (key, entry) in catalog.strings {
            let expected = Self.arguments(key)
            for (language, localization) in entry.localizations ?? [:] {
                for form in Self.forms(localization) {
                    let found = Self.arguments(form.value, substitutions: form.substitutions)
                    if localization.variations != nil {
                        // A plural form may leave its number out ("one" in some languages), never add one.
                        #expect(
                            found.allSatisfy { expected[$0.key] == $0.value },
                            "\(target): \"\(key)\" (\(language)) reads \(found), the key \(expected): \(form.value)")
                    } else {
                        #expect(
                            found == expected,
                            "\(target): \"\(key)\" (\(language)) reads \(found), the key \(expected): \(form.value)")
                    }
                }
                // Inside a substitution only %arg stands for the number.
                for substitution in (localization.substitutions ?? [:]).values {
                    for form in substitution.variations.plural.values.compactMap(\.stringUnit) {
                        #expect(
                            Self.arguments(form.value).isEmpty,
                            "\(target): \"\(key)\" (\(language)) substitution form \(form.value)")
                    }
                }
            }
        }
    }

    @Test func specifierParserReadsPositionsAndSubstitutions() {
        #expect(Self.arguments("%@ of %lld files") == [1: "@", 2: "d"])
        #expect(Self.arguments("%2$lld 件中 %1$@") == [1: "@", 2: "d"])
        #expect(Self.arguments("%lld%%") == [1: "d"])
        let days = Substitution(
            argNum: 2, formatSpecifier: "lld", variations: Variations(plural: [:]))
        #expect(Self.arguments("%1$@ for %#@days@", substitutions: ["days": days]) == [1: "@", 2: "d"])
    }

    /// `SkippedItems` translates Quarantine's skip explanations; in English it must say exactly what the
    /// library says (the CLI prints the library's text).
    @Test func skipExplanationsMatchTheLibraryInEnglish() {
        let reasons: [SkipReason] = [
            .reportOnly, .missing, .changedSinceScan, .inUse, .openFilesUnknown, .appRunning("Xcode"),
            .protected("~/Documents"), .adminCancelled, .adminUnsupportedPath, .adminBatchFull, .adminUnsafeParent,
            .adminRequiresImmediate, .appNotMoved,
        ]
        for reason in reasons {
            #expect(SkippedItems.explanation(for: reason) == reason.plainExplanation)
        }
    }
}
