# Nous Design System

## 1. Visual Theme & Atmosphere

Nous is a macOS 26 native personal knowledge + AI assistant. The design philosophy is **"useful and visually calm simultaneously"** — every UI element must serve a purpose, decoration that doesn't inform is noise.

The aesthetic draws from ColaOS: warm beige canvas, vibrant orange accent, soft rounded shapes. The interface feels like a conversation in a sunlit room — warm, inviting, never cold or clinical. Two separate panels (sidebar + main area) float independently on a transparent window, each casting its own shadow, creating a sense of physical objects on a desktop.

macOS 26 Liquid Glass is used for the sidebar, respecting the system's transparent/tinted preference. The main content area uses a solid warm beige surface.

**Key Characteristics:**
- Warm beige canvas (`#FDFBF7`) — not white, not gray, paper-warm
- Vibrant orange accent (`#F38335`) — the only saturated color, used sparingly for identity and interaction
- Dark text (`#333333`) — warm dark, never pure black
- Nunito Variable for body text — rounded, friendly, readable
- Fredoka One for the logo — playful weight, identity anchor
- Large corner radii throughout (32-36pt panels, 24pt bubbles, 10pt buttons)
- Transparent window with independent floating panels
- Liquid Glass sidebar (system-managed tint)
- No borders except selected states — separation comes from background color and spacing

## 2. Color Palette & Roles

### Primary
- **Cola Beige** (`#FDFBF7`): Primary background, main canvas, content area fill
- **Cola Orange** (`#F38335`): Accent color, CTAs, active states, logo, selected items
- **Cola Dark Text** (`#333333`): Primary text color, headings, body copy

### Surface & Container
- **White 75%** (`rgba(255,255,255,0.75)`): Sidebar background (non-Liquid Glass fallback)
- **Orange 12%** (`rgba(243,131,53,0.12)`): Assistant message bubbles, thinking indicator
- **Orange 8%** (`rgba(243,131,53,0.08)`): Selected item background, New Chat button fill, hover states
- **Orange 15%** (`rgba(243,131,53,0.15)`): User avatar background

### Text Hierarchy
- **Primary** (`#333333`): Headings, conversation titles, body text
- **Secondary** (`rgba(51,51,51,0.7)`): Sidebar items, recents list
- **Tertiary** (`rgba(51,51,51,0.5)`): Sidebar toggle icon, toolbar icons, placeholders
- **Muted** (`rgba(51,51,51,0.4)`): Cost display, metadata, timestamps

### Interactive States
- **Default**: Cola Dark Text at 70% opacity (sidebar items)
- **Selected**: Cola Orange text + Orange 8% background + Orange 30% border
- **Hover**: Subtle opacity increase
- **Active**: Cola Orange at full saturation

### Galaxy (Knowledge Graph)
- **Background**: Cola Beige (`#FDFBF7`) — matches main app, not dark
- **Morandi Node Palette** (project-based coloring):
  - Warm Sand (`#C6A38A`)
  - Sage Grey (`#A3B4B4`)
  - Dusty Rose (`#BC9DA9`)
  - Muted Green (`#9BAF9B`)
  - Lavender Grey (`#AAA3BD`)
  - Warm Taupe (`#C6B29B`)
  - Steel Blue (`#9BAAB9`)
  - Terracotta Mute (`#BDA39B`)
- **Edge Default**: `rgba(0,0,0,0.05)` — barely visible, quiet canvas
- **Edge Highlight**: Cola Orange at 80% — glow on selection
- **Node without project**: Warm Sand (first palette color)

## 3. Typography

### Font Stack
- **Logo**: Fredoka One — 72pt, semibold weight, rounded display face
- **Body**: System font with `.rounded` design — maps to SF Pro Rounded on macOS
- **Galaxy Labels**: SF Pro Text — 10pt, system native for small text
- **Code/Monospace**: System monospaced — for cost display, technical data

### Type Scale
| Use | Size | Weight | Design | Letter Spacing |
|-----|------|--------|--------|---------------|
| Logo (NOUS) | 72pt | .semibold | .rounded | default |
| Page title | 26pt | .medium | .rounded | default |
| Chat header | 20pt | .bold | .rounded | default |
| Body text | 13pt | .regular | default | default |
| Sidebar section | 11pt | .semibold | .rounded | default |
| Sidebar item | 12pt | .medium | .rounded | default |
| Quick action chips | 12pt | .medium | default | default |
| Chip icons | 11pt | default | default | default |
| Cost display | 11pt | .regular | .monospaced | default |
| Galaxy node label | 10pt | .regular | SF Pro Text | default |
| Galaxy empty state | .title2 | .semibold | default | default |

### Line Height
- Body text: +4pt line spacing (set via `.lineSpacing(4)`)
- Default system line height for all other sizes

## 4. Component Specifications

### Chat Bubbles (MessageBubble)
**User (Alex)**
- Alignment: right-aligned (Spacer on left)
- Background: Cola Bubble (app-defined, warm tint)
- Padding: 16pt horizontal, 12pt vertical
- Radius: 24pt continuous
- Text: 13pt regular, Cola Dark Text, +4pt line spacing

**Assistant (Nous)**
- Alignment: left-aligned (Spacer on right)
- Background: Orange 12% (`rgba(243,131,53,0.12)`)
- Padding: 16pt horizontal, 12pt vertical
- Radius: 24pt continuous
- Text: 13pt regular, Cola Dark Text, +4pt line spacing

### Thinking Indicator
- Three circles, 8pt diameter each, 6pt spacing
- Fill: Cola Orange
- Background container: Orange 12%, 24pt radius
- Animation: `.easeInOut(duration: 1.2).repeatForever(autoreverses: true)`
- Scale: 0.6 → 1.0 with staggered delay (0.2 per dot)
- Opacity: 0.4 → 1.0 matching scale timing
- Shows when `isGenerating && currentResponse.isEmpty`

### Sidebar (LeftSidebar)
- Width: 150pt fixed
- Background: Liquid Glass `.regular` (system-managed)
- Corner radius: 32pt continuous
- Content padding: 20pt leading, 8pt trailing, 30pt bottom

**Sidebar Items (Recents)**
- HStack: 6pt spacing
- Emoji: 11pt (AI-generated per conversation)
- Title: 12pt medium rounded, 1 line limit
- Selected state: Orange text + Orange 8% bg + Orange 30% border, 10pt radius
- Padding: 5pt vertical, 6pt horizontal
- Context menu: "Add to Project" submenu + "Delete"

**New Chat Button**
- HStack: icon (12pt medium) + text (11pt medium rounded)
- Color: Cola Orange text
- Background: Orange 8%
- Radius: 10pt
- Full width, 8pt vertical padding, 16pt horizontal padding

### Input Field (WelcomeView)
- TextField with `.plain` style
- Font: 14pt regular
- Placeholder: "How can I help you today?"
- Container: white 70% opacity, 18pt radius, 1pt border at Dark Text 8%
- Shadow: black 4% opacity, 8pt radius, 0x 2y offset
- Multi-line: 1-5 lines

### Quick Action Chips
- HStack with 10pt spacing
- Each chip: icon (11pt) + label (12pt medium)
- Color: Dark Text at 65%
- Background: white 55%
- Shape: Capsule
- Border: 1pt, Dark Text 8%
- Padding: 14pt horizontal, 8pt vertical

### Chat Header
- Title: 20pt bold rounded, Dark Text, 1 line
- Left padding: 64pt (clears sidebar overlap)
- Right padding: 36pt
- Top: 36pt, Bottom: 12pt
- Right side: export button + cost display (when applicable)

### Galaxy Nodes
- Shape: Circle
- Size: 6-14pt radius (based on edge count: `6 + edgeCount * 1.5`)
- Fill: Morandi palette color (by project)
- Stroke: same color at 30% opacity
- Glow: 2pt default, 12pt when selected
- Title: 10pt SF Pro Text, Dark Text at 65%, below node
- Physics: ForceAtlas2 (gravity -40, damping 0.82, spring 120)

## 5. Layout Principles

### Window
- Transparent background, no system chrome visible
- Title bar hidden, custom traffic lights
- Standard resize behavior
- Movable by window background (except in Galaxy view)
- Default size: 800 x 600pt

### Panel Architecture
- Two independent floating panels with HStack spacing 20pt
- Sidebar: 150pt fixed width, left
- Main area: fills remaining space
- Each panel has its own corner radius and visual treatment
- Gap between panels shows through to desktop

### Spacing System
- Panel gap: 20pt
- Content padding (chat): 36pt horizontal
- Sidebar padding: 20pt leading, 8pt trailing
- Section spacing: 24pt (chat messages), 14pt (sidebar items), 28pt (sidebar sections)
- Button internal: 8pt vertical, 16pt horizontal

### Corner Radius Scale
| Use | Radius | Style |
|-----|--------|-------|
| Main content area | 36pt | .continuous |
| Sidebar | 32pt | .continuous |
| Chat bubbles | 24pt | .continuous |
| Input field | 18pt | .continuous |
| Selected items, buttons | 10pt | default |
| Quick action chips | Capsule | — |

## 6. Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat | No shadow, beige background | Main canvas |
| Glass | `.glassEffect(.regular)` | Sidebar (system Liquid Glass) |
| Subtle | `rgba(0,0,0,0.04)` 8pt blur, 2y | Input field |
| None | `hasShadow = false` on window | Window level (panels cast own shadow) |

**Shadow Philosophy**: Nous uses minimal shadows. The floating panel design creates natural depth through separation rather than shadow layers. The window itself has no shadow (`hasShadow = false`), allowing each panel to exist as its own visual object. The only explicit shadow is on the input field container, and it's barely perceptible.

## 7. Conversation Modes

Four modes change Nous's behavior and visual identity:

| Mode | Greeting Emoji | System Instruction Style |
|------|---------------|------------------------|
| **Business** | 🏢 | Sharp, analytical, constraint-aware |
| **Direction** | 🧭 | Listening-first, value-exploring |
| **Brain Storm** | 🧠 | Yes-and, no filtering, high energy |
| **Mental Health** | 💚 | Warm, patient, never minimizing |

Each mode has a unique opening message from Nous and a tailored compression template that preserves mode-appropriate information during context compression.

## 8. Motion & Animation

### Thinking Indicator
- Three-dot breathing animation
- Duration: 1.2s ease-in-out, infinite repeat with autoreversal
- Staggered delay: 0.2s between dots
- Scale range: 0.6x → 1.0x
- Opacity range: 0.4 → 1.0

### Sidebar Toggle
- `.spring(response: 0.3, dampingFraction: 0.8)`
- Combined `.move(edge: .leading)` + `.opacity` transition

### Galaxy Physics
- ForceAtlas2-based simulation
- Damping: 0.82 (heavy, sticky feel)
- Max velocity: 15 (slow, deliberate movement)
- Stabilization: ~150 iterations then stops
- On drag release: all velocities zero (no drift)
- Click: connected edges glow orange
- Long press (>0.5s): spotlight mode (dim unrelated to 10% opacity)

### General
- No unnecessary animation
- Transitions should feel physical (spring-based) not decorative
- Galaxy is the only place with continuous animation

## 9. Agent Prompt Guide

### Quick Color Reference
- Background: Cola Beige (`#FDFBF7`)
- Accent: Cola Orange (`#F38335`)
- Text: Cola Dark (`#333333`)
- Secondary text: Dark at 70% (`rgba(51,51,51,0.7)`)
- Muted text: Dark at 40% (`rgba(51,51,51,0.4)`)
- Assistant bubble: Orange at 12% (`rgba(243,131,53,0.12)`)
- Selected bg: Orange at 8% (`rgba(243,131,53,0.08)`)
- Border (selected): Orange at 30% (`rgba(243,131,53,0.3)`)
- Sidebar: Liquid Glass `.regular`

### Example Component Prompts
- "Create a chat bubble: left-aligned, `rgba(243,131,53,0.12)` background, 24pt continuous corner radius, 16pt horizontal / 12pt vertical padding. Text at 13pt system regular, `#333333`, line spacing 4pt."
- "Create a sidebar item: HStack with 6pt spacing. 11pt emoji + 12pt medium rounded text at `rgba(51,51,51,0.7)`. Selected state: orange text `#F38335`, `rgba(243,131,53,0.08)` background, `rgba(243,131,53,0.3)` 1pt border, 10pt radius."
- "Design the welcome screen: centered VStack. 'NOUS' at 72pt semibold rounded in `#F38335`. Greeting at 26pt medium rounded in `#333333`. Input box with white 70% background, 18pt radius, 1pt border at 8% opacity. Four capsule chips below."
- "Build a Galaxy node: circle with 6-14pt radius. Fill with Morandi color (e.g. `rgb(198,163,138)`). Stroke at 30% opacity. 10pt label below in `rgba(51,51,51,0.65)`. Connected edges as faint curves at `rgba(0,0,0,0.05)`, glow orange on selection."

### Design Rules
1. If a UI element does not serve a clear purpose, remove it
2. Cola Orange is the ONLY saturated color — everything else is neutral
3. Prefer spacing over borders for visual separation
4. Rounded shapes everywhere — no sharp corners in user-facing UI
5. Liquid Glass only for sidebar — main content stays solid beige
6. Text is never pure black (`#000000`) — always use `#333333`
7. Shadows are barely perceptible or absent — depth comes from panel separation
8. Animation is physical (spring) not decorative (bounce/wobble)
