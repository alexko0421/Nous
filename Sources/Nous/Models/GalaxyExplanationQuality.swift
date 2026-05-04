import Foundation

enum GalaxyExplanationQuality {
    static func hasUsefulChineseExplanation(_ raw: String?) -> Bool {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return false
        }

        return containsCJK(text) && !isGenericRelationExplanation(text)
    }

    static func isGenericRelationExplanation(_ raw: String?) -> Bool {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return true
        }

        let normalized = normalized(text)
        if normalized.count < 8 {
            return true
        }

        return genericRelationExplanations.contains(normalized)
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJKScalar)
    }

    private static func normalized(_ text: String) -> String {
        text
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || isCJKScalar($0) }
            .map(String.init)
            .joined()
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    private static let genericRelationExplanations: Set<String> = [
        "它们反复指向同一种底层模式",
        "它们之间有一个值得留意的张力",
        "其中一个想法正在支撑另一个想法",
        "这些想法看起来互相矛盾",
        "其中一个想法可能解释了另一个想法的原因",
        "这只是语义相似不是强结论先把它当成待验证的线索",
        "thesenodesappeartoexpressthesameunderlyingpatternthroughdifferentsurfacetopics",
        "thesenodesmaypullagainsteachotheronestatesaboundaryorconstraintwhiletheotherpointstowardagoalplanorproposal",
        "onenodeappearstogiveareasonruleorinsightthatsupportstheother",
        "thesenodesmayconflictwitheachotherandareworthreviewingtogether",
        "thesenodesmaydescribeacauseandeffectchain",
        "thesenodesaresemanticallyclosebutnousdoesnotyethavestrongerevidenceforadeeperrelationship"
    ]
}
