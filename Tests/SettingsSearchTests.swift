import XCTest

final class SettingsSearchTests: XCTestCase {
    private let direct = SettingsSearchIndex(entries: SettingsSearchCatalog.entries())

    private func ids(_ query: String, in index: SettingsSearchIndex? = nil) -> [String] {
        (index ?? direct).search(query).map(\.entry.id)
    }

    private func top(_ query: String, in index: SettingsSearchIndex? = nil) -> String? {
        ids(query, in: index).first
    }

    // MARK: Catalog integrity

    func testEverySectionHasEntries() {
        let sections = Set(direct.entries.map(\.section))
        for section in SettingsSection.allCases {
            XCTAssertTrue(sections.contains(section), "\(section) has no search entry")
            XCTAssertTrue(direct.entries.contains { $0.section == section && $0.isSection },
                          "\(section) has no section entry")
            XCTAssertTrue(direct.entries.contains { $0.section == section && !$0.isSection },
                          "\(section) has no row entry")
        }
    }

    func testIdentifiersAreUnique() {
        let ids = direct.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate ids: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }

    func testEveryEntryHasKeywordsAndDescription() {
        for entry in direct.entries {
            XCTAssertFalse(entry.keywords.isEmpty, entry.id)
            XCTAssertFalse(entry.detail.isEmpty, entry.id)
            XCTAssertFalse(entry.keywords.contains(""), "\(entry.id) has an empty keyword")
        }
    }

    /// A catalog anchor with no matching `.settingsSearchAnchor("…")` in a view would make a
    /// result select its section but land nowhere. Scan the real sources to catch renames.
    func testEveryAnchorExistsInTheSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Dictari")
        var text = ""
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            text += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        // Literal anchors, plus interpolated ones such as "models.\(model.id)" whose fixed
        // prefix must match (the ForEach supplies the rest from the same data the catalog uses).
        let marker = "settingsSearchAnchor(\""
        var literals = Set<String>(), prefixes = Set<String>()
        var rest = text[...]
        while let start = rest.range(of: marker) {
            let tail = rest[start.upperBound...]
            guard let end = tail.firstIndex(of: "\"") else { break }
            let value = String(tail[..<end])
            if let interpolation = value.range(of: "\\(") {
                prefixes.insert(String(value[..<interpolation.lowerBound]))
            } else {
                literals.insert(value)
            }
            rest = tail[end...]
        }
        let anchors = Set(direct.entries.compactMap(\.anchor))
        XCTAssertGreaterThan(anchors.count, 40)
        for anchor in anchors {
            let found = literals.contains(anchor) || prefixes.contains { !$0.isEmpty && anchor.hasPrefix($0) }
            XCTAssertTrue(found, "No view carries .settingsSearchAnchor(\"\(anchor)\")")
        }
        // The dynamic anchors must match real data, not just a prefix.
        XCTAssertTrue(anchors.contains("models.parakeet-v3"))
        XCTAssertTrue(anchors.contains("profiles.builtin.standard"))
    }

    /// Model and built-in profile rows are generated from data in the views; the catalog
    /// mirrors it by hand, so a renamed model or profile must fail here.
    func testDataDrivenRowsMatchTheirSources() {
        for model in ModelDescriptor.curated {
            let entry = direct.entries.first { $0.id == "models.\(model.id)" }
            XCTAssertEqual(entry?.title, model.displayName, "Model \(model.id)")
            XCTAssertEqual(entry?.anchor, "models.\(model.id)")
        }
        XCTAssertEqual(direct.entries.filter { $0.id.hasPrefix("models.") && $0.id != "models.transcriptionModel" }.count,
                       ModelDescriptor.curated.count)
        for profile in DictationProfile.allCases {
            let entry = direct.entries.first { $0.id == "profiles.builtin.\(profile.rawValue)" }
            XCTAssertEqual(entry?.title, profile.label, "Profile \(profile.rawValue)")
        }
    }

    func testLiveTypingAndUpdatesAreIndexed() {
        XCTAssertTrue(direct.entries.contains { $0.id == "dictation.liveTyping" })
        XCTAssertTrue(direct.entries.contains { $0.id == "updates.checkNow" })
    }

    /// The reorganised sidebar renamed or folded pages; the words people learned for the old
    /// ones must still lead somewhere sensible.
    func testOldPageNamesStillFindTheirRows() {
        XCTAssertTrue(ids("general").prefix(3).contains("section.dictation"))
        XCTAssertTrue(ids("shortcuts").prefix(3).contains("section.dictation"))
        XCTAssertTrue(ids("pill").prefix(3).contains("appearance.indicator"))
        XCTAssertTrue(ids("delivery method").prefix(3).contains("dictation.deliveryMethod"))
        XCTAssertTrue(ids("restore clipboard").prefix(3).contains("dictation.restoreClipboard"))
        XCTAssertTrue(ids("distant voice guard").prefix(3).contains("sound.distantVoice"))
        XCTAssertTrue(ids("stop after silence").prefix(3).contains("sound.stopAfterSilence"))
        XCTAssertTrue(ids("sound cues").prefix(3).contains("sound.cues"))
        XCTAssertTrue(ids("input device").prefix(3).contains("sound.inputDevice"))
        XCTAssertTrue(ids("models").prefix(3).contains("section.models"))
        XCTAssertTrue(ids("diagnostics").prefix(3).contains("section.diagnostics"))
    }

    func testLanguagesISpeakIsSearchable() {
        for query in ["lingue", "parlo", "lingua principale", "languages I speak", "main language"] {
            XCTAssertTrue(ids(query).prefix(3).contains("dictation.spokenLanguages"),
                          "“\(query)” got \(ids(query).prefix(5))")
        }
        XCTAssertTrue(ids("conversazione").prefix(3).contains("dictation.conversation"))
        XCTAssertEqual(top("conversation mode"), "dictation.conversation")
    }

    /// `DICTARI_OPEN_SETTINGS` takes a section raw value; names of pages that were folded
    /// into others must keep opening the page that now holds their rows.
    func testLegacyLaunchValuesResolve() {
        XCTAssertEqual(SettingsSection(launchValue: "general"), .dictation)
        XCTAssertEqual(SettingsSection(launchValue: "shortcuts"), .dictation)
        XCTAssertEqual(SettingsSection(launchValue: "sound"), .sound)
        XCTAssertEqual(SettingsSection(launchValue: "license"), .updates)
        XCTAssertEqual(SettingsSection(launchValue: "Diagnostics"), .diagnostics)
        XCTAssertNil(SettingsSection(launchValue: "1"))
        for section in SettingsSection.allCases {
            XCTAssertEqual(SettingsSection(launchValue: section.rawValue), section)
        }
    }

    func testEverySectionIsInExactlyOneSidebarGroup() {
        let grouped = SettingsSection.groups.flatMap(\.sections)
        XCTAssertEqual(grouped.count, Set(grouped).count)
        XCTAssertEqual(Set(grouped), Set(SettingsSection.allCases))
    }

    // MARK: Empty & trivial queries

    func testEmptyAndWhitespaceQueriesReturnNothing() {
        XCTAssertTrue(direct.search("").isEmpty)
        XCTAssertTrue(direct.search("   ").isEmpty)
        XCTAssertTrue(direct.search("\n\t").isEmpty)
        XCTAssertTrue(direct.search("—…›").isEmpty, "Punctuation alone is not a query")
    }

    func testNonsenseMatchesNothing() {
        XCTAssertTrue(direct.search("zzqxw").isEmpty)
        XCTAssertTrue(direct.search("microphone zzqxw").isEmpty, "Every required term must match")
    }

    // MARK: Case, diacritics

    func testCaseAndDiacriticInsensitive() {
        XCTAssertEqual(top("LAUNCH AT LOGIN"), "appearance.launchAtLogin")
        XCTAssertEqual(top("launch at login"), "appearance.launchAtLogin")
        XCTAssertTrue(ids("accessibilita").contains("home.permissions"))
        XCTAssertTrue(ids("ACCESSIBILITÀ").contains("home.permissions"))
        XCTAssertTrue(ids("modalita scura").contains("appearance.appearance"))
        XCTAssertTrue(ids("sensibilità").contains("sound.silenceSensitivity"))
    }

    // MARK: Italian synonyms

    func testItalianSynonymsFindTheirRows() {
        let expectations: [(String, String)] = [
            ("microfono", "sound.inputDevice"),
            ("ingresso", "sound.inputDevice"),
            ("scorciatoia", "dictation.shortcut"),
            ("tasto", "dictation.shortcut"),
            ("lingua", "dictation.language"),
            ("punteggiatura", "dictation.spokenPunctuation"),
            ("virgola", "dictation.spokenPunctuation"),
            ("a capo", "dictation.spokenPunctuation"),
            ("tema", "appearance.appearance"),
            ("scuro", "appearance.appearance"),
            ("pillola", "appearance.indicator"),
            ("indicatore", "appearance.indicator"),
            ("beep", "sound.cues"),
            ("suono", "sound.cues"),
            ("cronologia", "section.history"),
            ("cancella cronologia", "history.clearAll"),
            ("aggiornamenti", "updates.updates"),
            ("modello", "models.transcriptionModel"),
            ("vocabolario", "section.vocabulary"),
            ("appunti", "dictation.restoreClipboard"),
            ("incolla", "dictation.pasteIntoFocus"),
            ("permessi", "home.permissions"),
            ("avvio automatico", "appearance.launchAtLogin"),
            ("riunione", "library.meeting"),
            ("cuffie", "sound.inputDevice"),
        ]
        for (query, expected) in expectations {
            let found = ids(query)
            XCTAssertTrue(found.prefix(3).contains(expected),
                          "“\(query)” should rank \(expected) in the top 3, got \(found.prefix(5))")
        }
    }

    func testDeleteSynonymsReachDestructiveRows() {
        XCTAssertTrue(ids("elimina").contains("history.clearAll"))
        XCTAssertTrue(ids("cancella").contains("history.clearAll"))
        XCTAssertTrue(ids("elimina modello").prefix(2).contains("models.transcriptionModel"))
    }

    // MARK: Typos

    func testSingleTypoInShortWordIsForgiven() {
        XCTAssertTrue(ids("microfno").prefix(3).contains("sound.inputDevice"))
        XCTAssertTrue(ids("lingau").prefix(3).contains("dictation.language"), "Transposition")
        XCTAssertTrue(ids("clipbaord").prefix(3).contains("dictation.restoreClipboard"))
        XCTAssertTrue(ids("vocabulray").prefix(3).contains("section.vocabulary"))
    }

    func testTwoTyposAllowedOnlyForLongWords() {
        XCTAssertTrue(ids("punteggatuar").contains("dictation.spokenPunctuation"), "12 letters, 2 edits")
        XCTAssertTrue(direct.search("mcrfno").isEmpty || !ids("mcrfno").contains("sound.inputDevice"),
                      "6 letters, 3 edits is too far")
        XCTAssertFalse(ids("tme").contains("appearance.appearance"), "Short words need an exact prefix")
    }

    func testTypoInAWordStillBeingTyped() {
        XCTAssertTrue(ids("micorf").contains("sound.inputDevice"), "Prefix with a transposition")
    }

    // MARK: Multi-word

    func testMultiWordTermsMatchInAnyOrderAndAcrossFields() {
        XCTAssertEqual(top("login launch"), "appearance.launchAtLogin")
        XCTAssertEqual(top("pill position"), "appearance.indicatorPosition")
        XCTAssertEqual(top("position pill"), "appearance.indicatorPosition")
        // "sound" is a section, "device" a title word: fields combine.
        XCTAssertEqual(top("sound device"), "sound.inputDevice")
    }

    func testFillerWordsDoNotExclude() {
        XCTAssertTrue(ids("how do I change the language").prefix(3).contains("dictation.language"))
        XCTAssertTrue(ids("come cambio la lingua").prefix(3).contains("dictation.language"))
        XCTAssertTrue(ids("dove si trova il microfono").prefix(3).contains("sound.inputDevice"))
    }

    func testAllFillerQueryIsStillSearched() {
        // “a” alone is required when it is the whole query, so the user sees something.
        XCTAssertFalse(direct.search("a").isEmpty)
    }

    func testCompoundsMatchWordsTypedTogether() {
        XCTAssertTrue(ids("darkmode").contains("appearance.appearance"))
        XCTAssertTrue(ids("autocapitalise").first == "dictation.autoCapitalise")
        XCTAssertTrue(ids("pushtotalk").contains("dictation.mode"))
    }

    // MARK: Ranking

    func testExactTitleBeatsTitlePrefix() {
        // "Microphone" (the row) is an exact title; "Include my microphone" only a title word.
        XCTAssertEqual(top("microphone"), "sound.inputDevice")
        XCTAssertEqual(top("sound"), "section.sound")
        XCTAssertEqual(top("language"), "dictation.language")
    }

    func testRankingTiersAreOrdered() {
        typealias S = SettingsSearchScore
        let tiers = [S.exactTitle, S.titlePrefix, S.titleWordExact, S.titleWordPrefix,
                     S.keywordExact, S.keywordPrefix, S.contextExact, S.contextPrefix,
                     S.detailExact, S.detailPrefix, S.fuzzyTitle, S.fuzzyKeyword, S.fuzzyContext]
        XCTAssertEqual(tiers, tiers.sorted(by: >))
        XCTAssertGreaterThan(S.fuzzyContext - 2 * S.fuzzyPenalty, 0)
    }

    func testTitleWordBeatsKeywordBeatsDescription() {
        let index = SettingsSearchIndex(entries: [
            entry("d", title: "Alpha", detail: "Mentions zebra here", keywords: ["other"]),
            entry("k", title: "Beta", detail: "Nothing", keywords: ["zebra"]),
            entry("t", title: "Zebra crossing", detail: "Nothing", keywords: ["other"]),
            entry("f", title: "Zebar", detail: "Nothing", keywords: ["other"]),
        ])
        // "Zebar" is only a typo match, and typo matches are a fallback: exact hits exist.
        XCTAssertEqual(index.search("zebra").map(\.entry.id), ["t", "k", "d"])
        // With no exact hit, the fuzzy ones appear, title before keyword.
        XCTAssertEqual(index.search("zebrs").map(\.entry.id), ["t", "k"])
        XCTAssertEqual(index.search("zeb").map(\.entry.id), ["t", "f", "k", "d"],
                       "A title prefix outranks keyword and description prefixes")
    }

    func testExactTitleThenTitlePrefixThenWordPrefix() {
        let index = SettingsSearchIndex(entries: [
            entry("word", title: "Clear sound cues", detail: "x", keywords: ["x"]),
            entry("prefix", title: "Sound cues extra", detail: "x", keywords: ["x"]),
            entry("exact", title: "Sound Cues", detail: "x", keywords: ["x"]),
        ])
        XCTAssertEqual(index.search("sound cues").map(\.entry.id), ["exact", "prefix", "word"])
    }

    func testOrderingIsStableForEqualScores() {
        let index = SettingsSearchIndex(entries: (0..<6).map {
            entry("e\($0)", title: "Row \($0)", detail: "x", keywords: ["shared"])
        })
        XCTAssertEqual(index.search("shared").map(\.entry.id), (0..<6).map { "e\($0)" })
        XCTAssertEqual(index.search("shared").map(\.entry.id), index.search("SHARED").map(\.entry.id))
    }

    func testLimit() {
        XCTAssertLessThanOrEqual(direct.search("a", limit: 5).count, 5)
    }

    // MARK: Other interface languages

    /// The suite runs in English, where the catalog indexes nothing twice. A translated entry
    /// (as the catalog builds it on a German Mac) must answer both its own words and English.
    func testTranslatedEntriesStillAnswerEnglish() {
        XCTAssertTrue(direct.entries.allSatisfy { $0.english == nil },
                      "In English the source wording is the shown wording")

        var german = SettingsSearchEntry(id: "s", title: "Tastenkürzel", section: .dictation, card: nil,
                                         detail: "Startet und beendet das Diktat.", keywords: ["Hotkey"], anchor: "s")
        german.english = .init(title: "Shortcut", context: ["Dictation"],
                               detail: "Starts and stops dictation.", keywords: ["scorciatoia", "tasto"])
        let index = SettingsSearchIndex(entries: [
            entry("o", title: "Mikrofon", detail: "x", keywords: ["shortcut"]),
            german,
        ])
        XCTAssertEqual(index.search("shortcut").first?.entry.id, "s", "The English title is a whole-title match")
        XCTAssertEqual(index.search("tastenkurzel").map(\.entry.id), ["s"])
        XCTAssertEqual(index.search("scorciatoia").map(\.entry.id), ["s"], "Source keywords stay searchable")
        XCTAssertEqual(index.search("wie ändere ich das Tastenkürzel").first?.entry.id, "s",
                       "German question words are filler")
    }

    // MARK: Breadcrumb & emphasis

    func testBreadcrumb() {
        let row = direct.entries.first { $0.id == "sound.cues" }!
        XCTAssertEqual(row.breadcrumb, "Microphone & Sound › While recording")
        let section = direct.entries.first { $0.id == "section.sound" }!
        XCTAssertEqual(section.breadcrumb, "Microphone & Sound")
        let card = direct.entries.first { $0.id == "appearance.indicator" }!
        XCTAssertEqual(card.breadcrumb, "Appearance", "A card does not repeat itself")
    }

    func testEmphasisMarksMatchedWordPrefixes() {
        let title = "Launch at Login"
        let ranges = SettingsSearchText.emphasisRanges(in: title, query: "lau log")
        XCTAssertEqual(ranges.map { String(title[$0]) }, ["Lau", "Log"])
    }

    func testEmphasisIsDiacriticInsensitiveAndSkipsFiller() {
        let title = "Accessibilità e permessi"
        let ranges = SettingsSearchText.emphasisRanges(in: title, query: "accessibilita e perm")
        XCTAssertEqual(ranges.map { String(title[$0]) }, ["Accessibilità", "perm"])
        XCTAssertTrue(SettingsSearchText.emphasisRanges(in: title, query: "").isEmpty)
    }

    // MARK: Edit distance

    func testEditDistance() {
        func d(_ a: String, _ b: String, _ limit: Int = 3) -> Int? {
            SettingsSearchText.editDistance(Array(a.utf8), Array(b.utf8)[...], limit: limit)
        }
        XCTAssertEqual(d("abc", "abc"), 0)
        XCTAssertEqual(d("abc", "acb"), 1, "Adjacent transposition is one edit")
        XCTAssertEqual(d("microfno", "microfono"), 1)
        XCTAssertEqual(d("kitten", "sitting"), 3)
        XCTAssertNil(d("kitten", "sitting", 2))
        XCTAssertEqual(d("", "ab"), 2)
        XCTAssertNil(d("abcdef", "a", 2))
    }

    func testPrefixEditDistance() {
        func p(_ a: String, _ b: String, _ limit: Int) -> Int? {
            SettingsSearchText.editDistance(Array(a.utf8), Array(b.utf8)[...], limit: limit, allowingPrefix: true)
        }
        XCTAssertEqual(p("micorf", "microfono", 1), 1, "Transposition inside a prefix")
        XCTAssertEqual(p("micro", "microfono", 1), 0)
        XCTAssertEqual(p("microfno", "microfono", 2), 1, "Whole-word distance is still found")
        XCTAssertNil(p("zzzz", "microfono", 1))
        XCTAssertNil(p("abcd", "ab", 1), "A token shorter than the term by more than the limit")
    }

    // MARK: Speed

    func testKeystrokeSearchIsFast() {
        let queries = ["m", "mi", "mic", "micr", "micro", "microf", "microfo", "microfon", "microfono",
                       "punteggatuar", "how do I change the language", "cancella cronologia"]
        _ = SettingsSearchIndex.shared.search("warm up")
        let start = Date()
        for _ in 0..<50 { for q in queries { _ = direct.search(q) } }
        let perQuery = Date().timeIntervalSince(start) / Double(50 * queries.count)
        // This bundle is unoptimised (about 3 ms a query); an optimised build runs ~60 µs. The
        // bound is a regression guard against quadratic work sneaking in, not a benchmark:
        // one frame at 60 Hz is 16 ms.
        XCTAssertLessThan(perQuery, 0.016, "Search took \(perQuery * 1000) ms per keystroke")
    }

    // MARK: Helpers

    private func entry(_ id: String, title: String, detail: String, keywords: [String]) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, title: title, section: .dictation, card: nil, detail: detail,
                            keywords: keywords, anchor: id)
    }
}
