import Foundation

/// Normalizes free-text queries before they hit the lexical retrieval lane.
///
/// Per `docs/superpowers/plans/2026-05-08-memory-retrieval-multilingual-architecture.md`
/// Move 1. Used by both vector embedding (so the same input shape is hashed
/// consistently) and lexical FTS5 search.
///
/// Steps applied, in order:
///   1. Strip leading/trailing whitespace.
///   2. NFC unicode normalization — collapses combining sequences that look
///      identical but tokenize differently.
///   3. Full-width → half-width Latin/digit/punctuation (e.g. `Ｒ` → `R`,
///      `１` → `1`, `？` → `?`). Cantonese / Mandarin keyboards default to
///      full-width when typing English alongside CJK; FTS5 tokenizes them
///      differently.
///   4. CJK punctuation normalization (`，` → `,`, `。` → `.`, `！` → `!`,
///      `？` → `?`, `；` → `;`, `：` → `:`). Trigram tokenizer treats
///      punctuation as boundaries; unifying these prevents trigrams from
///      straddling visually-equivalent separators.
///   5. Strip emoji + variation selectors. Emoji introduce trigram boundaries
///      that pollute the index without semantic content.
///   6. Collapse runs of whitespace into single spaces.
///
/// Note: Traditional ↔ Simplified Chinese conversion is intentionally NOT
/// applied here. The codebase already mixes both freely (Cantonese tends to
/// trad, Mandarin tends to simp); doing trigram FTS without conversion lets
/// users query in whichever script they used at write time. If retrieval
/// quality measurements later show cross-script mismatches dominating
/// failures, add a `Trad2Simp` step here. Out of scope per plan.
enum QueryNormalizer {

    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // NFC pass. Swift's `String` already normalizes for equality but
        // FTS5 indexes raw bytes; explicit NFC ensures index + query agree.
        let nfc = trimmed.precomposedStringWithCanonicalMapping

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(nfc.unicodeScalars.count)

        for scalar in nfc.unicodeScalars {
            // Skip variation selectors (U+FE00..U+FE0F) and emoji-presentation
            // joiner U+200D. They add noise without semantic value.
            if (0xFE00...0xFE0F).contains(scalar.value) ||
               scalar.value == 0x200D {
                continue
            }

            // Skip emoji proper. Emoji.Properties on the scalar gives us
            // a reliable test (covers people/objects/symbols emojis but
            // leaves through real punctuation and CJK).
            if scalar.properties.isEmojiPresentation ||
               (scalar.properties.isEmoji && scalar.value > 0x2300) {
                continue
            }

            // Full-width → half-width fold for Latin / digits / ASCII
            // punctuation range U+FF01..U+FF5E.
            if (0xFF01...0xFF5E).contains(scalar.value) {
                let folded = UnicodeScalar(scalar.value - 0xFEE0)
                if let folded {
                    scalars.append(folded)
                    continue
                }
            }

            // CJK punctuation → ASCII equivalents.
            switch scalar.value {
            case 0x3001:        // 、 → ,
                scalars.append(UnicodeScalar(0x002C)!)
            case 0x3002:        // 。 → .
                scalars.append(UnicodeScalar(0x002E)!)
            case 0xFF1F:        // ？ — already covered by FF range above
                scalars.append(UnicodeScalar(0x003F)!)
            case 0xFF01:        // ！
                scalars.append(UnicodeScalar(0x0021)!)
            case 0xFF1B:        // ；
                scalars.append(UnicodeScalar(0x003B)!)
            case 0xFF1A:        // ：
                scalars.append(UnicodeScalar(0x003A)!)
            case 0x300C, 0x300D, 0x300E, 0x300F: // 「」『』
                scalars.append(UnicodeScalar(0x0022)!)
            case 0xFF08:        // （
                scalars.append(UnicodeScalar(0x0028)!)
            case 0xFF09:        // ）
                scalars.append(UnicodeScalar(0x0029)!)
            default:
                scalars.append(scalar)
            }
        }

        let folded = String(String.UnicodeScalarView(scalars))

        // Collapse whitespace runs into single space. Cheap final pass.
        let collapsed = folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return collapsed
    }
}
