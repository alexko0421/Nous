# Nous MVP Design Spec

## Overview

Nous is a macOS-native personal knowledge management + AI assistant. It combines conversations and notes into a unified knowledge graph (Galaxy), powered by fully local vector storage and user-configurable LLM (local MLX or cloud API). Built for macOS 26 with Liquid Glass and native APIs.

**Core philosophy:** "连点成线" — every piece of content is a node in the Galaxy. Conversations and notes have no hard boundary. The system automatically discovers semantic relationships between nodes via vector similarity, surfacing connections the user didn't explicitly create.

## Product Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Platform | macOS 26+ (native SwiftUI) | Leverage Liquid Glass, Apple Silicon acceleration |
| Vector storage | Fully local (SQLite + sqlite-vss) | Privacy-first, data never leaves the machine |
| Embedding | Local MLX Swift (nomic-embed-text-v1.5) | 768-dim, ~274MB, good quality/size tradeoff |
| LLM | User-configurable: local MLX or cloud API | Flexibility — local for privacy, cloud for power |
| Project concept | Lightweight goal-driven containers | Not Jira — just a goal description + grouped nodes |
| Galaxy | 2D force-directed node graph (SpriteKit) | Like Obsidian graph view, semantic edges auto-generated |
| Content types | Conversations and notes, equal weight | Both are NousNodes, both get embedded and connected |
| macOS 26 features | Aggressive adoption | Liquid Glass, new animations, latest APIs throughout |
| MVP scope | Full stack: Chat + Notes + Vector + Galaxy | All four pillars in v1 |

## Data Model

### NousNode (base unit of all content)

```
NousNode
├── id: UUID
├── type: NodeType (.conversation | .note)
├── title: String
├── content: String (Markdown)
├── embedding: [Float] (768-dim vector)
├── projectId: UUID? (optional Project association)
├── isFavorite: Bool
├── createdAt: Date
├── updatedAt: Date
├── messages: [Message] (only for type=.conversation)
└── edges: [NodeEdge] (Galaxy connections)
```

### Message (conversation turns)

```
Message
├── id: UUID
├── nodeId: UUID (parent NousNode)
├── role: MessageRole (.user | .assistant)
├── content: String
└── timestamp: Date
```

### Project (lightweight goal container)

```
Project
├── id: UUID
├── title: String
├── goal: String (what this project aims to achieve)
├── emoji: String
├── createdAt: Date
└── nodes: [NousNode] (via nodeId foreign key)
```

### NodeEdge (Galaxy connections)

```
NodeEdge
├── id: UUID
├── sourceId: UUID (NousNode)
├── targetId: UUID (NousNode)
├── strength: Float (0.0–1.0)
└── type: EdgeType
      ├── .semantic — auto-generated via vector similarity (cosine > 0.75)
      ├── .manual — user-created by dragging in Galaxy
      └── .shared — same Project membership (weaker weight)
```

### Embedding Strategy

- **Notes:** embed the full content (title + body). Re-embed on edit.
- **Conversations:** embed a rolling summary. When a conversation has ≤5 messages, embed concatenated content. When longer, embed title + the most recent 5 messages. Individual messages are not independently embedded in MVP — the conversation node is the unit of embedding.
- **Embedding trigger:** on node creation and on content update (debounced 2s for notes being edited).

### Storage

All data lives in a single SQLite database file with sqlite-vss extension for vector indexing. Schema:

- `nodes` table — all NousNode fields, content stored as TEXT
- `messages` table — conversation messages, foreign key to nodes
- `projects` table — project metadata
- `edges` table — node relationships
- `vss_nodes` virtual table — sqlite-vss vector index on node embeddings

## System Architecture

```
┌─────────────────────────────────────────────────────┐
│                    SwiftUI Layer                     │
│  ┌───────────┐ ┌──────────┐ ┌────────┐ ┌─────────┐ │
│  │LeftSidebar│ │ ChatArea │ │ Note   │ │ Galaxy  │ │
│  │           │ │          │ │ Editor │ │ (graph) │ │
│  └─────┬─────┘ └────┬─────┘ └───┬────┘ └────┬────┘ │
│        └─────────────┼──────────┼────────────┘      │
│                      ▼          ▼                    │
│              ┌──────────────────────┐                │
│              │   @Observable VMs    │                │
│              │  Chat / Note /       │                │
│              │  Galaxy / Settings   │                │
│              └──────────┬───────────┘                │
└─────────────────────────┼───────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────┐
│                   Service Layer                      │
│                                                      │
│  ┌─────────────┐ ┌─────────────┐ ┌───────────────┐  │
│  │ NodeStore   │ │ VectorStore │ │  LLMService   │  │
│  │ (CRUD)      │ │ (embed +    │ │  (generate)   │  │
│  │             │ │  search)    │ │               │  │
│  └──────┬──────┘ └──────┬──────┘ └───────┬───────┘  │
│         │               │                │          │
│  ┌──────┴───────────────┴────┐   ┌───────┴───────┐  │
│  │     SQLite + sqlite-vss   │   │   MLX Swift   │  │
│  │  (nodes, edges, vectors)  │   │  (embed+LLM)  │  │
│  └───────────────────────────┘   └───────────────┘  │
│                                                      │
│  ┌─────────────────────────────────────────────┐     │
│  │              GraphEngine                     │    │
│  │  (force-directed layout + edge generation)   │    │
│  └─────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

### Services

| Service | Responsibility | Technology |
|---|---|---|
| **NodeStore** | CRUD for nodes, messages, projects, edges | SQLite (direct, not SwiftData) |
| **VectorStore** | Embed content + semantic search | sqlite-vss + MLX Swift |
| **LLMService** | Text generation (local or cloud) | MLX Swift / URLSession |
| **GraphEngine** | Force-directed layout + edge generation | Accelerate (vDSP) + SpriteKit |

### RAG Pipeline

```
User input
    → embed(query) via MLX
    → sqlite-vss search top-5 similar nodes
    → Assemble context prompt:
        - Project goal (if in a Project)
        - Top-5 related content summaries
        - Conversation history (recent N messages)
    → Send to LLM → generate response
    → Store response → embed → store vector
    → Async: update Galaxy edges for new content
```

### Galaxy Edge Generation

- On new content: find nodes with cosine similarity > 0.75, create `semantic` edges
- `strength` field = cosine similarity value
- User can manually connect nodes by dragging in Galaxy view (`manual` edges)
- Nodes in the same Project get automatic `shared` edges (weaker weight)

## UI Structure

### Layout

The app has two panels:
- **Left Sidebar** (130px, existing) — traffic lights, Galaxy/Project nav, Favorites/Recents, user avatar
- **Main Content Area** (flex) — three tabs: Chat, Notes, Galaxy

### Views

**Chat tab (existing, enhanced):**
- WelcomeView when no active conversation (existing)
- ChatArea with message bubbles (existing)
- Enhancement: RAG citation display — when AI references knowledge from other nodes, show inline citation with source node title and similarity score
- Quick Actions trigger new conversations within relevant Projects

**Notes tab (new):**
- Markdown editor using NSTextView / TextKit 2
- Title, project badge, timestamps at top
- Content body with basic rich text (headers, bold, italic, lists, code blocks)
- Related nodes panel at bottom — shows semantically similar nodes with similarity percentage

**Galaxy tab (new):**
- Dark background (#1a1a2e) with orange-themed nodes
- SpriteKit scene rendering force-directed 2D graph
- Node size reflects content volume
- Node labels show emoji + title
- Edge opacity reflects strength
- Click node → navigate to Chat or Notes tab with that content
- Pinch to zoom, drag to pan, drag nodes to reposition
- Filter by Project (show only nodes in selected Project)

**Settings (new):**
- Accessed from sidebar user avatar area
- LLM Provider selection: Local (MLX) / Claude API / OpenAI API
- Local model management: download, select, delete models
- Embedding model status
- Vector database stats (count, size)
- API key input fields for cloud providers

### Navigation Flow

- Click sidebar item → opens in Chat or Notes tab (based on node type)
- Click Galaxy nav icon → switches to Galaxy tab (full graph)
- Click Project nav icon → shows Project list, selecting filters sidebar + Galaxy
- Click Galaxy node → jumps to corresponding Chat or Notes tab
- New conversation → Chat tab, optionally within a Project
- New note → Notes tab, optionally within a Project

## File Structure

```
Sources/Nous/
├── App/
│   ├── NousApp.swift              (existing — app entry, window config)
│   └── ContentView.swift          (existing — add tab switching)
├── Views/
│   ├── LeftSidebar.swift          (existing — minor updates)
│   ├── ChatArea.swift             (existing — integrate RAG)
│   ├── WelcomeView.swift          (existing — keep as-is)
│   ├── NoteEditor.swift           (new — TextKit 2 markdown editor)
│   ├── GalaxyView.swift           (new — SpriteKit graph)
│   └── SettingsView.swift         (new — LLM/model config)
├── ViewModels/
│   ├── ChatViewModel.swift        (new — manages chat state + RAG calls)
│   ├── NoteViewModel.swift        (new — manages note editing + relations)
│   ├── GalaxyViewModel.swift      (new — manages graph state + interactions)
│   └── SettingsViewModel.swift    (new — manages preferences + model downloads)
├── Services/
│   ├── NodeStore.swift            (new — SQLite CRUD)
│   ├── VectorStore.swift          (new — sqlite-vss + MLX embedding)
│   ├── LLMService.swift           (new — local MLX + cloud API client)
│   └── GraphEngine.swift          (new — force layout + edge generation)
├── Models/
│   ├── NousNode.swift             (new — core data model)
│   ├── NodeEdge.swift             (new — graph edges)
│   ├── Project.swift              (new — project container)
│   └── Message.swift              (new — chat messages, replaces ChatMessage)
├── Theme/
│   ├── AppColor.swift             (existing)
│   └── WindowConfigurator.swift   (extracted from NousApp.swift)
└── Fonts/
    ├── FredokaOne-Regular.ttf     (existing)
    └── Nunito-Variable.ttf        (existing)
```

## First Launch Flow

1. App opens with a setup screen
2. Download embedding model (~274MB) — show progress bar
3. Optional: download local LLM (~2GB) OR enter API key for cloud LLM
4. Create SQLite database + sqlite-vss index
5. Enter main interface (WelcomeView)

## Technical Dependencies

| Dependency | Purpose | Integration |
|---|---|---|
| SQLite | Data storage | via C API or SQLite.swift wrapper |
| sqlite-vss | Vector similarity search | C extension loaded into SQLite |
| MLX Swift | Local ML inference (embedding + LLM) | Apple's official Swift package |
| Accelerate | Fast vector math for graph layout | System framework |
| SpriteKit | 2D graph rendering | System framework |

## Design Language

- **ColaOS aesthetic** — warm beige (#FDFBF7), vibrant orange (#F38335), dark text (#333)
- **Fonts** — Fredoka One (logo), Nunito Variable (body)
- **Shapes** — large corner radius (32-36pt panels, 24pt bubbles, 18pt input)
- **Window** — borderless, transparent, custom traffic lights, movable by background
- **macOS 26** — Liquid Glass (`.glassEffect`) on input fields, panels; new animation APIs throughout
- **Galaxy** — dark space theme (#1a1a2e), glowing orange nodes, subtle edge lines
