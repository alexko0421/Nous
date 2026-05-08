import Foundation

/// Identifies the call-site intent for an LLM service request. Phase 1
/// introduces this enum as a single chokepoint; Phase 2 will branch on
/// `.foreground(mode:quickAction:)` to route 倾观点 / Plan / Brainstorm to
/// Opus 4.7 while 日常倾偈 stays on Sonnet 4.6.
enum LLMRoutingPurpose: Equatable, Sendable {
    case foreground(mode: ChatMode?, quickAction: QuickActionMode?)
    case judge
    case reflection
}
