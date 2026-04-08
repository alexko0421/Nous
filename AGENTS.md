# Nous — Agent Instructions

## Who you are building for

Alex is 19, a solo founder on an F-1 visa at Santa Monica College. He builds full-time and uses school to maintain visa status. No team, limited capital, no safety net. Every decision you make in this codebase exists within these real constraints.

Nous is not a product Alex is building for other people. It is the tool he uses to think. It is his second brain — the version of his mind that remembers everything, sees connections he missed, and is honest with him when he is wrong.

## How Alex thinks — and how you should make decisions

These are not personality traits. These are decision-making methods. Apply them when you face choices in this codebase.

**First principles before analogy.** Do not copy patterns from other apps because "that's how it's done." Ask: what does Nous actually need here? Raw SQLite instead of SwiftData exists because Alex wants full control over his data layer — not because he doesn't know SwiftData exists. Every architectural choice has a reason. Understand it before changing it.

**Inversion.** Before adding a feature, ask: what happens if this goes wrong? What's the worst version of this feature? If the downside is worse than the upside, don't build it. A feature that adds complexity but marginal value is a net negative.

**The pain test.** Before adding anything — a dependency, a feature, a UI element — ask: "冇呢样嘢，会痛唔痛？" If the honest answer is no, it is a false need. Do not build it.

**Simplicity is not laziness.** If you cannot explain what a piece of code does in one sentence, it is doing too much. Alex reaches for plain language and concrete images, not abstraction. The code should do the same. A 50-line file that does one thing clearly is better than a 200-line file with "flexibility."

**Action over perfection for building. Patience for consuming.** When building features: move, ship, iterate. Do not over-plan. When choosing dependencies or tools: wait for the right one. Do not incrementally adopt things.

## What Nous is

A macOS 26 native personal knowledge management + AI assistant.

Core philosophy: **"连点成线"** — every piece of content (conversation or note) is a node. The system discovers semantic relationships via vector similarity, surfacing connections the user didn't explicitly create. Conversations and notes have no boundary. Both are `NousNode`.

**Two axes:**
- **Project** (active) — a goal-driven container. Alex focuses here.
- **Galaxy** (passive) — knowledge graph that reveals connections across everything.

Project is how Alex pushes forward. Galaxy is how he discovers what he didn't know he knew.

## The anchor

`Sources/Nous/Resources/anchor.md` is Nous's soul. It contains Alex's values, thinking methods, and communication style, written when he was most lucid. It is loaded as the system prompt for every LLM call.

**Do not modify anchor.md.** It is frozen by design. It is the ground truth against which Nous can measure change over time. When Alex's living knowledge (accumulated in conversations and notes) contradicts the anchor, Nous surfaces that tension — it does not silently update.

## Design taste

Alex's aesthetic is a judgment system: something is correct when it is **useful** and **visually calm** simultaneously. Simple, soft colours, nothing excessive.

- **ColaOS palette:** warm beige `#FDFBF7`, vibrant orange `#F38335`, dark text `#333`
- **Typography:** Fredoka One (logo), Nunito Variable (body)
- **Shapes:** large corner radii (32-36pt panels, 24pt bubbles), Liquid Glass where macOS 26 supports it
- **Galaxy:** dark space `#1A1A2E`, glowing orange nodes
- **Window:** borderless, transparent, custom traffic lights

If a UI element does not serve a clear purpose, remove it. Decoration that doesn't inform is noise.

## Architecture

```
SwiftUI Views → @Observable ViewModels → Services → SQLite + MLX Swift
```

| Layer | Contents |
|---|---|
| **Models/** | `NousNode`, `Message`, `Project`, `NodeEdge` |
| **Services/** | `NodeStore` (SQLite CRUD), `VectorStore` (Accelerate cosine), `EmbeddingService` (MLX), `LLMService` (protocol + 4 providers), `GraphEngine` (force layout) |
| **ViewModels/** | `ChatViewModel` (RAG pipeline), `NoteViewModel`, `GalaxyViewModel`, `SettingsViewModel` |
| **Views/** | `ChatArea`, `NoteEditor`, `GalaxyView` (SpriteKit), `SettingsView`, `SetupView`, `LeftSidebar` |
| **Theme/** | `AppColor`, `WindowConfigurator` |
| **Resources/** | `anchor.md` |

## Key files

| What | Where |
|---|---|
| App entry | `Sources/Nous/App/NousApp.swift` |
| Central coordinator | `Sources/Nous/App/ContentView.swift` |
| RAG pipeline + anchor loading | `Sources/Nous/ViewModels/ChatViewModel.swift` |
| Nous's identity | `Sources/Nous/Resources/anchor.md` |
| Database schema | `Sources/Nous/Services/NodeStore.swift` |
| Vector search | `Sources/Nous/Services/VectorStore.swift` |
| LLM providers | `Sources/Nous/Services/LLMService.swift` |
| Design spec | `docs/superpowers/specs/2026-04-06-nous-mvp-design.md` |

## Tech choices and why

| Choice | Why |
|---|---|
| Raw SQLite C API (not SwiftData) | Full control. No framework magic. Alex owns the data layer completely. |
| Accelerate brute-force (not sqlite-vss) | Simpler. For <10k vectors, vDSP cosine is sub-millisecond. Add indexing when it's actually needed. |
| MLX Swift for local inference | Apple Silicon native. Data never leaves the machine. Privacy is non-negotiable. |
| SpriteKit for Galaxy | System framework, no deps. Good enough for 2D force-directed graph. |
| xcodegen | Single source of truth for project config. `project.yml` → Xcode project. |
| Four LLM providers | User chooses. Local for privacy, cloud for power. Gemini 2.5 Flash is the default cloud option. |

## Build

```bash
xcodegen generate
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Requires: Xcode with macOS 26 SDK, Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

## Test

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

Tests use `NodeStore(path: ":memory:")` for in-memory SQLite.

## Rules

### Before you build anything, ask:

1. **Does Alex need this?** Not "would this be nice" — does the absence of this cause pain?
2. **Does this make Nous simpler or more complex?** If more complex, the bar is higher.
3. **Does this follow existing patterns?** If not, explain why the existing pattern is wrong.
4. **Can you explain what this does in one sentence?** If not, break it down.

### Technical rules

- `@Observable` for ViewModels, `@Bindable` in views
- UUIDs as TEXT, dates as REAL, booleans as INTEGER, embeddings as BLOB
- Services are plain classes — no actors, no SwiftData
- Swift files go in subdirectories (App/, Views/, ViewModels/, Services/, Models/, Theme/) — never in `Sources/Nous/` root
- System frameworks use `sdk: Framework.framework` in project.yml, not `framework:`
- Run `xcodegen generate` after any project.yml change

### Do not

- Add SwiftData, Core Data, or any ORM
- Add third-party dependencies without explicit approval
- Modify `anchor.md`
- Restructure file organization without approval
- Build features that weren't asked for — YAGNI applies strictly

### iCloud Drive warning

This project lives in iCloud Drive. Files deleted via `git` may reappear due to sync. After moving or deleting files, verify with `find Sources/Nous -maxdepth 1 -name "*.swift"` and clean up orphans.

## LLM providers

All implement `LLMService` protocol, all stream via `AsyncThrowingStream<String, Error>`:

| Provider | Service | API | Default model |
|---|---|---|---|
| Gemini | `GeminiLLMService` | `generativelanguage.googleapis.com` | gemini-2.5-flash |
| Claude | `ClaudeLLMService` | `api.anthropic.com` | claude-sonnet-4-6 |
| OpenAI | `OpenAILLMService` | `api.openai.com` | gpt-4o |
| Local | `LocalLLMService` | MLX Swift | Llama 3.2 3B 4bit |

The anchor prompt is passed as the system message to every provider. For Gemini, it uses `systemInstruction`. For Claude, the `system` parameter. For OpenAI/Local, a system message in the messages array.
