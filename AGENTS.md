# Nous — Agent Instructions

## What is this

Nous is a macOS 26 native personal knowledge management + AI assistant. It combines conversations and notes into a unified knowledge graph (Galaxy), powered by local vector storage and user-configurable LLM.

Core philosophy: "连点成线" — every piece of content is a node. The system discovers semantic relationships via vector similarity, surfacing connections the user didn't explicitly create.

## Architecture

```
SwiftUI Views → @Observable ViewModels → Services → SQLite + MLX Swift
```

- **Models/** — `NousNode` (universal content unit), `Message`, `Project`, `NodeEdge`
- **Services/** — `NodeStore` (SQLite CRUD), `VectorStore` (cosine similarity via Accelerate), `EmbeddingService` (MLX), `LLMService` (protocol + Gemini/Claude/OpenAI/local MLX), `GraphEngine` (force-directed layout)
- **ViewModels/** — `ChatViewModel` (RAG pipeline), `NoteViewModel`, `GalaxyViewModel`, `SettingsViewModel`
- **Views/** — `ChatArea`, `NoteEditor`, `GalaxyView` (SpriteKit), `SettingsView`, `SetupView`, `LeftSidebar`
- **Theme/** — `AppColor` (ColaOS palette), `WindowConfigurator` (borderless transparent window)
- **Resources/** — `anchor.md` (Nous's immutable core identity)

## Key files

| What | Where |
|---|---|
| App entry | `Sources/Nous/App/NousApp.swift` |
| Central coordinator | `Sources/Nous/App/ContentView.swift` |
| RAG pipeline | `Sources/Nous/ViewModels/ChatViewModel.swift` |
| System prompt | `Sources/Nous/Resources/anchor.md` |
| Database schema | `Sources/Nous/Services/NodeStore.swift` (createTables) |
| Vector search | `Sources/Nous/Services/VectorStore.swift` |
| LLM providers | `Sources/Nous/Services/LLMService.swift` |
| Design spec | `docs/superpowers/specs/2026-04-06-nous-mvp-design.md` |
| Implementation plan | `docs/superpowers/plans/2026-04-06-nous-mvp.md` |

## Tech stack

- Swift / SwiftUI (macOS 26, deployment target 26.0)
- SQLite via C API (libsqlite3) — no ORM, no SwiftData
- Accelerate (vDSP) for cosine similarity — brute-force, no sqlite-vss
- MLX Swift (`mlx-swift` 0.29.1+, `mlx-swift-examples` 2.29.1+) for local embedding + LLM
- SpriteKit for Galaxy 2D knowledge graph
- xcodegen (`project.yml`) generates the Xcode project

## Build

```bash
xcodegen generate
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Requires: Xcode with macOS 26 SDK, Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

## Rules

### Do

- Follow existing patterns. This codebase has a specific structure — respect it.
- Use the ColaOS design language: warm beige (#FDFBF7), orange (#F38335), dark text (#333), large corner radii, Liquid Glass where appropriate.
- Keep services as plain classes (not actors, not SwiftData). The DB layer uses raw SQLite C API intentionally.
- Store UUIDs as TEXT, dates as REAL (timeIntervalSince1970), booleans as INTEGER, embeddings as BLOB.
- Use `@Observable` for ViewModels, `@Bindable` in views.
- Run `xcodegen generate` after changing `project.yml`.

### Do not

- Do not add SwiftData, Core Data, or any ORM.
- Do not restructure the file organization without explicit approval.
- Do not modify `anchor.md` — it is immutable by design. It captures the user's values at a specific point in time.
- Do not add third-party dependencies without approval. The project deliberately minimizes external deps.
- Do not put Swift files directly in `Sources/Nous/` root — use the subdirectories (App, Views, ViewModels, Services, Models, Theme).
- Do not use `framework:` in project.yml for system frameworks — use `sdk: Framework.framework`.

### iCloud Drive warning

This project lives in iCloud Drive. Files deleted via `git` may reappear due to iCloud sync. After moving or deleting files, verify with `find Sources/Nous -maxdepth 1 -name "*.swift"` and remove any orphans.

## LLM providers

Four providers, all implementing `LLMService` protocol:
- **Gemini** (`GeminiLLMService`) — `generativelanguage.googleapis.com`, SSE streaming, `systemInstruction` for anchor
- **Claude** (`ClaudeLLMService`) — Anthropic Messages API, SSE streaming
- **OpenAI** (`OpenAILLMService`) — Chat Completions API, SSE streaming  
- **Local** (`LocalLLMService`) — MLX Swift, `LLMModelFactory`, `TokenIterator`

All stream via `AsyncThrowingStream<String, Error>`. The anchor prompt from `Resources/anchor.md` is passed as the system message to every provider.

## Testing

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

Tests use `NodeStore(path: ":memory:")` for in-memory SQLite. Test files are in `Tests/NousTests/`.
