# Voice Mode — OpenAI Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ghost cursor overlay, streamed transcript panel, and live audio waveform to Nous's existing native voice mode, matching the OpenAI realtime-voice-component reference for ghost cursor behavior and timing while keeping the rest of the existing native voice stack intact.

**Architecture:** Native SwiftUI throughout. Three new views (`VoiceWaveformBars`, `VoiceTranscriptPanel`, `GhostCursorOverlay`) plus a `GhostCursorRegistry` environment object plumb signals from the existing `VoiceAudioCapture` and `VoiceCommandController` into the UI. The controller gains a published `transcript: [VoiceTranscriptLine]` array, a published `ghostCursorIntent`, and a small dispatch-flow change that gates spatial tool execution behind cursor travel completion.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, the Observation framework (`@Observable`). No new third-party dependencies.

**Phasing:** Three sequential phases with a live-test fence between each. Per Alex's "never bundle all four" rule. Phase 0 is shared scaffolding.

---

## File Structure

**New files**

- `Sources/Nous/Models/Voice/VoiceTranscriptLine.swift` — model for one streamed line.
- `Sources/Nous/Models/Voice/GhostCursorIntent.swift` — intent struct + phase / easing enums.
- `Sources/Nous/Services/GhostCursorRegistry.swift` — environment object mapping IDs to global frames; the `.ghostCursorTarget(id:)` view modifier.
- `Sources/Nous/Views/Voice/VoiceWaveformBars.swift` — five-bar waveform view.
- `Sources/Nous/Views/Voice/VoiceTranscriptPanel.swift` — bubble panel.
- `Sources/Nous/Views/Voice/GhostCursorOverlay.swift` — top-level overlay.
- `Tests/NousTests/Voice/VoiceTranscriptLineReducerTests.swift`
- `Tests/NousTests/Voice/VoiceAudioLevelSmoothingTests.swift`
- `Tests/NousTests/Voice/GhostCursorTargetResolverTests.swift`
- `Tests/NousTests/Voice/GhostCursorTravelDurationTests.swift`

**Existing files modified**

- `Sources/Nous/Services/VoiceAudioCapture.swift` — emit smoothed audio level via callback.
- `Sources/Nous/Services/VoiceCommandController.swift` — own `audioLevel`, evolve buffer pair into `transcript: [VoiceTranscriptLine]`, add `ghostCursorIntent`, add spatial gate in tool dispatch.
- `Sources/Nous/Views/ChatArea.swift` — replace static dot in `VoiceCapsuleView` with `VoiceWaveformBars`; mount `VoiceTranscriptPanel`; tag `voice_capsule` ghost cursor target; add ghost cursor target modifiers on the sidebar / scratchpad toggle buttons in this file.
- `Sources/Nous/App/ContentView.swift` — also mount waveform + transcript panel where the second `VoiceCapsuleView` is rendered; mount `GhostCursorOverlay` at top of body; provide `GhostCursorRegistry` via `.environment`.
- `Sources/Nous/Views/LeftSidebar.swift` — tag tab `NavIconButton`s and the settings button with `.ghostCursorTarget(id:)`.

---

## Phase 0 — Shared scaffolding

### Task 0.1: Create the `VoiceTranscriptLine` model

**Files:**
- Create: `Sources/Nous/Models/Voice/VoiceTranscriptLine.swift`

- [ ] **Step 1: Write the failing test**

Create: `Tests/NousTests/Voice/VoiceTranscriptLineReducerTests.swift`

```swift
import XCTest
@testable import Nous

final class VoiceTranscriptLineReducerTests: XCTestCase {
    func test_appendingDelta_updatesLatestLine() {
        var lines: [VoiceTranscriptLine] = []
        VoiceTranscriptLine.appendDelta("Hello", role: .user, into: &lines, now: Date(timeIntervalSince1970: 0))
        VoiceTranscriptLine.appendDelta(" world", role: .user, into: &lines, now: Date(timeIntervalSince1970: 0.1))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].role, .user)
        XCTAssertFalse(lines[0].isFinal)
    }

    func test_finalizingThenSwitchingRole_opensNewLine() {
        var lines: [VoiceTranscriptLine] = []
        VoiceTranscriptLine.appendDelta("Hi", role: .user, into: &lines, now: Date(timeIntervalSince1970: 0))
        VoiceTranscriptLine.finalize(text: "Hi.", role: .user, into: &lines)
        VoiceTranscriptLine.appendDelta("Hey", role: .assistant, into: &lines, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].isFinal)
        XCTAssertEqual(lines[0].text, "Hi.")
        XCTAssertFalse(lines[1].isFinal)
        XCTAssertEqual(lines[1].role, .assistant)
        XCTAssertEqual(lines[1].text, "Hey")
    }

    func test_bargeInSealsAssistantLineKeepingText() {
        var lines: [VoiceTranscriptLine] = []
        VoiceTranscriptLine.appendDelta("Opening Gala", role: .assistant, into: &lines, now: Date(timeIntervalSince1970: 0))
        VoiceTranscriptLine.bargeInSealsLatestAssistant(into: &lines)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isFinal)
        XCTAssertEqual(lines[0].text, "Opening Gala")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceTranscriptLineReducerTests`
Expected: FAIL with "cannot find 'VoiceTranscriptLine' in scope".

- [ ] **Step 3: Implement the model and reducer**

Create `Sources/Nous/Models/Voice/VoiceTranscriptLine.swift`:

```swift
import Foundation

struct VoiceTranscriptLine: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var isFinal: Bool
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, isFinal: Bool, createdAt: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
    }

    static func appendDelta(
        _ delta: String,
        role: Role,
        into lines: inout [VoiceTranscriptLine],
        now: Date = Date()
    ) {
        if var last = lines.last, last.role == role, last.isFinal == false {
            last.text += delta
            lines[lines.count - 1] = last
            return
        }
        lines.append(VoiceTranscriptLine(role: role, text: delta, isFinal: false, createdAt: now))
    }

    static func finalize(
        text: String,
        role: Role,
        into lines: inout [VoiceTranscriptLine],
        now: Date = Date()
    ) {
        if var last = lines.last, last.role == role, last.isFinal == false {
            last.text = text
            last.isFinal = true
            lines[lines.count - 1] = last
            return
        }
        lines.append(VoiceTranscriptLine(role: role, text: text, isFinal: true, createdAt: now))
    }

    static func bargeInSealsLatestAssistant(into lines: inout [VoiceTranscriptLine]) {
        guard var last = lines.last, last.role == .assistant, last.isFinal == false else { return }
        last.isFinal = true
        lines[lines.count - 1] = last
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VoiceTranscriptLineReducerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Voice/VoiceTranscriptLine.swift Tests/NousTests/Voice/VoiceTranscriptLineReducerTests.swift
git commit -m "feat(voice): add VoiceTranscriptLine model and reducer"
```

---

### Task 0.2: Create `GhostCursorIntent`, phase, and easing

**Files:**
- Create: `Sources/Nous/Models/Voice/GhostCursorIntent.swift`

- [ ] **Step 1: Write the failing test (travel duration formula)**

Create `Tests/NousTests/Voice/GhostCursorTravelDurationTests.swift`:

```swift
import XCTest
@testable import Nous

final class GhostCursorTravelDurationTests: XCTestCase {
    func test_zeroDistance_clampsToMin() {
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 0), 320, accuracy: 0.001)
    }

    func test_shortDistance_scalesNormally() {
        // 320 + 100 * 0.18 = 338 (above the 320 floor, no clamping)
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 100), 338, accuracy: 0.001)
    }

    func test_midDistance_scalesLinearly() {
        // 320 + 1500 * 0.18 = 320 + 270 = 590 → clamped to 560
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 1500), 560, accuracy: 0.001)
    }

    func test_belowClampUpperBound() {
        // 320 + 1000 * 0.18 = 500 (within range)
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 1000), 500, accuracy: 0.001)
    }

    func test_aboveClampUpperBound() {
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 5000), 560, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GhostCursorTravelDurationTests`
Expected: FAIL with "cannot find 'GhostCursorIntent' in scope".

- [ ] **Step 3: Implement the intent and helpers**

Create `Sources/Nous/Models/Voice/GhostCursorIntent.swift`:

```swift
import Foundation
import CoreGraphics

enum GhostCursorPhase: Equatable {
    case hidden
    case traveling
    case arrived
    case error
}

enum GhostCursorEasing: Equatable {
    case smooth      // cubic-bezier(0.22, 0.84, 0.26, 1.0)
    case expressive  // cubic-bezier(0.16, 1.18, 0.30, 1.0) — slight overshoot
}

struct GhostCursorIntent: Equatable, Identifiable {
    let id: UUID
    let targetId: String
    let easing: GhostCursorEasing
    let createdAt: Date

    init(
        id: UUID = UUID(),
        targetId: String,
        easing: GhostCursorEasing = .smooth,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetId = targetId
        self.easing = easing
        self.createdAt = createdAt
    }

    /// Travel duration in milliseconds, distance-driven and clamped 320…560.
    /// Mirrors openai/realtime-voice-component's getTravelDuration.
    static func travelDurationMs(distance: Double) -> Double {
        let raw = 320.0 + distance * 0.18
        return min(560.0, max(320.0, raw))
    }

    static func travelDurationMs(from origin: CGPoint, to target: CGPoint) -> Double {
        let dx = Double(target.x - origin.x)
        let dy = Double(target.y - origin.y)
        return travelDurationMs(distance: (dx * dx + dy * dy).squareRoot())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GhostCursorTravelDurationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Voice/GhostCursorIntent.swift Tests/NousTests/Voice/GhostCursorTravelDurationTests.swift
git commit -m "feat(voice): add GhostCursorIntent with travel duration formula"
```

---

### Task 0.3: Create `GhostCursorRegistry` environment object + `.ghostCursorTarget(id:)` modifier

**Files:**
- Create: `Sources/Nous/Services/GhostCursorRegistry.swift`

- [ ] **Step 1: Implement the registry and modifier**

Create `Sources/Nous/Services/GhostCursorRegistry.swift`:

```swift
import SwiftUI
import Observation

/// Maps stable string IDs to the global frames of the SwiftUI views that registered them.
/// Views register via `.ghostCursorTarget(id:)`. Missing IDs return nil — overlay then
/// silently no-ops, matching the reference's "skip on null target" behavior.
@Observable
@MainActor
final class GhostCursorRegistry {
    private var frames: [String: CGRect] = [:]
    private var pulseTriggers: [String: UUID] = [:]

    func update(id: String, frame: CGRect) {
        frames[id] = frame
    }

    func remove(id: String) {
        frames.removeValue(forKey: id)
        pulseTriggers.removeValue(forKey: id)
    }

    func frame(for id: String) -> CGRect? {
        frames[id]
    }

    func center(for id: String) -> CGPoint? {
        guard let f = frames[id] else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    func pulseTrigger(for id: String) -> UUID? {
        pulseTriggers[id]
    }

    /// Triggers an arrival pulse animation on the registered target view.
    func pulse(id: String) {
        pulseTriggers[id] = UUID()
    }
}

extension View {
    func ghostCursorTarget(id: String) -> some View {
        modifier(GhostCursorTargetModifier(id: id))
    }
}

private struct GhostCursorTargetModifier: ViewModifier {
    let id: String
    @Environment(GhostCursorRegistry.self) private var registry: GhostCursorRegistry?

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: GhostCursorTargetFramePreferenceKey.self,
                            value: [GhostCursorTargetFrame(id: id, frame: proxy.frame(in: .global))]
                        )
                }
            )
            .overlay(GhostCursorTargetPulse(id: id))
            .onPreferenceChange(GhostCursorTargetFramePreferenceKey.self) { values in
                guard let registry else { return }
                for value in values where value.id == id {
                    registry.update(id: value.id, frame: value.frame)
                }
            }
            .onDisappear {
                registry?.remove(id: id)
            }
    }
}

private struct GhostCursorTargetFrame: Equatable {
    let id: String
    let frame: CGRect
}

private struct GhostCursorTargetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [GhostCursorTargetFrame] = []
    static func reduce(value: inout [GhostCursorTargetFrame], nextValue: () -> [GhostCursorTargetFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct GhostCursorTargetPulse: View {
    let id: String
    @Environment(GhostCursorRegistry.self) private var registry: GhostCursorRegistry?
    @State private var pulse: Bool = false
    @State private var seenTrigger: UUID?

    var body: some View {
        Color.clear
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColor.colaOrange.opacity(0.28), lineWidth: 3)
                    .blur(radius: 0.5)
                    .scaleEffect(pulse ? 1.06 : 1.0)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 0.18), value: pulse)
            )
            .allowsHitTesting(false)
            .onChange(of: registry?.pulseTrigger(for: id)) { _, newTrigger in
                guard let newTrigger, newTrigger != seenTrigger else { return }
                seenTrigger = newTrigger
                pulse = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    pulse = true
                }
            }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Services/GhostCursorRegistry.swift
git commit -m "feat(voice): add GhostCursorRegistry env object and ghostCursorTarget modifier"
```

---

## Phase 1 — Audio level + waveform

### Task 1.1: Emit smoothed audio level from `VoiceAudioCapture`

**Files:**
- Modify: `Sources/Nous/Services/VoiceAudioCapture.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NousTests/Voice/VoiceAudioLevelSmoothingTests.swift`:

```swift
import XCTest
@testable import Nous

final class VoiceAudioLevelSmoothingTests: XCTestCase {
    func test_smoothingFactor_blends80PercentPrev20PercentCurrent() {
        var smoother = VoiceAudioLevelSmoother()
        XCTAssertEqual(smoother.value, 0, accuracy: 0.0001)
        smoother.ingest(rms: 0.5)
        // 0.8 * 0 + 0.2 * 0.5 = 0.1
        XCTAssertEqual(smoother.value, 0.1, accuracy: 0.0001)
        smoother.ingest(rms: 0.5)
        // 0.8 * 0.1 + 0.2 * 0.5 = 0.18
        XCTAssertEqual(smoother.value, 0.18, accuracy: 0.0001)
    }

    func test_clampsToZeroAndOne() {
        var smoother = VoiceAudioLevelSmoother()
        smoother.ingest(rms: -1.0)
        XCTAssertGreaterThanOrEqual(smoother.value, 0.0)
        smoother.ingest(rms: 5.0)
        XCTAssertLessThanOrEqual(smoother.value, 1.0)
    }

    func test_rmsOfFloatSamples_zeroForSilence() {
        let silence = [Float](repeating: 0, count: 480)
        XCTAssertEqual(VoiceAudioLevelSmoother.rms(samples: silence), 0, accuracy: 0.0001)
    }

    func test_rmsOfFloatSamples_nonzeroForTone() {
        let tone = (0..<480).map { i in sin(Float(i) * 0.1) * 0.5 }
        let rms = VoiceAudioLevelSmoother.rms(samples: tone)
        XCTAssertGreaterThan(rms, 0.1)
        XCTAssertLessThan(rms, 0.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceAudioLevelSmoothingTests`
Expected: FAIL with "cannot find 'VoiceAudioLevelSmoother' in scope".

- [ ] **Step 3: Add the smoother + extend `VoiceAudioCapturing` protocol**

Modify `Sources/Nous/Services/VoiceAudioCapture.swift`. Add this struct near the top (below `VoiceAudioEncoder`):

```swift
/// Exponentially-smoothed peak-RMS audio level in 0...1.
struct VoiceAudioLevelSmoother {
    private(set) var value: Float = 0
    private let alpha: Float = 0.2  // 0.8 prev + 0.2 current

    mutating func ingest(rms: Float) {
        let clamped = max(0, min(1, rms))
        value = (1 - alpha) * value + alpha * clamped
    }

    mutating func reset() {
        value = 0
    }

    static func rms(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return (sumSq / Float(samples.count)).squareRoot()
    }
}
```

Update the protocol and `start(...)` signature to forward audio level:

```swift
protocol VoiceAudioCapturing: AnyObject {
    func start(
        onAudio: @escaping @Sendable (String) -> Void,
        onAudioLevel: @escaping @Sendable (Float) -> Void
    ) throws
    func stop()
}
```

In `VoiceAudioCapture.start(...)`, change the signature to match and add a `Sendable`-safe smoother box. Replace the existing `start` body with:

```swift
func start(
    onAudio: @escaping @Sendable (String) -> Void,
    onAudioLevel: @escaping @Sendable (Float) -> Void
) throws {
    stop()

    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw VoiceAudioCaptureError.cannotCreateConverter
    }

    self.converter = converter
    let smootherBox = SmootherBox()
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
        let frameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate))
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil,
              convertedBuffer.frameLength > 0,
              let channel = convertedBuffer.floatChannelData?[0] else {
            return
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(convertedBuffer.frameLength)))
        let chunk = VoiceAudioEncoder.base64PCM16(fromMonoFloatSamples: samples)
        if !chunk.isEmpty {
            onAudio(chunk)
        }

        let rms = VoiceAudioLevelSmoother.rms(samples: samples)
        let smoothed = smootherBox.ingest(rms: rms)
        onAudioLevel(smoothed)
    }

    engine.prepare()
    try engine.start()
}
```

Add the `SmootherBox` helper at file scope (below `VoiceAudioCapture`):

```swift
/// Thread-safe smoother holder for the audio tap closure.
private final class SmootherBox: @unchecked Sendable {
    private let lock = NSLock()
    private var smoother = VoiceAudioLevelSmoother()

    func ingest(rms: Float) -> Float {
        lock.lock()
        defer { lock.unlock() }
        smoother.ingest(rms: rms)
        return smoother.value
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VoiceAudioLevelSmoothingTests`
Expected: PASS.

- [ ] **Step 5: Find and update existing `start(onAudio:)` callers**

Run: `grep -n "audioCapture.start\|capture.start(" Sources/Nous`
For each call site, add the second argument as `onAudioLevel: { _ in }` to keep the build green at this step. Real wiring happens in Task 1.2.

- [ ] **Step 6: Verify build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/VoiceAudioCapture.swift Tests/NousTests/Voice/VoiceAudioLevelSmoothingTests.swift
git add -u Sources/Nous
git commit -m "feat(voice): emit smoothed audio level from VoiceAudioCapture"
```

---

### Task 1.2: Plumb audio level into `VoiceCommandController`

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
- Modify: caller of `VoiceAudioCapture.start(...)` (typically inside `RealtimeVoiceSession.swift`; trace from `start` in the controller)

- [ ] **Step 1: Add the `audioLevel` property on the controller**

In `VoiceCommandController.swift`, near the top of the class (alongside `var status`), add:

```swift
var audioLevel: Float = 0
```

Add a setter method below `markListening()`:

```swift
func updateAudioLevel(_ level: Float) {
    let clamped = max(0, min(1, level))
    audioLevel = clamped
}
```

Add a reset point: extend `resetTranscript()` (or wherever the session is fully reset) to also do `audioLevel = 0`. Search for `isActive = false` lines and zero `audioLevel` next to each.

- [ ] **Step 2: Add a default-empty audio-level hook on `RealtimeVoiceSessioning`**

Open `Sources/Nous/Services/RealtimeVoiceSession.swift`. Find the protocol declaration (`protocol RealtimeVoiceSessioning`). Add the new method, then add a default empty implementation in a protocol extension so existing fakes (e.g. `FakeRealtimeVoiceSession` at `Tests/NousTests/VoiceCommandControllerTests.swift:819`) keep compiling without changes:

```swift
protocol RealtimeVoiceSessioning {
    // ...existing requirements...
    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void)
}

extension RealtimeVoiceSessioning {
    func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {}
}
```

In the concrete `RealtimeVoiceSession` class, store the handler and forward it. Find where `audioCapture.start(onAudio:)` is called (the placeholder closure was inserted in Task 1.1 step 5). Replace `onAudioLevel: { _ in }` there with `onAudioLevel: { [audioLevelHandler] level in audioLevelHandler?(level) }` and add a stored property `private var audioLevelHandler: (@Sendable (Float) -> Void)?`. Implement:

```swift
func setAudioLevelHandler(_ handler: @escaping @Sendable (Float) -> Void) {
    self.audioLevelHandler = handler
}
```

- [ ] **Step 3: Have the controller register the handler at session-start time**

In `VoiceCommandController.start(apiKey:)` (around line 50-78), immediately after instantiating or referencing the session, register the level handler:

```swift
session.setAudioLevelHandler { [weak self] level in
    Task { @MainActor in
        self?.updateAudioLevel(level)
    }
}
```

If the controller already has a single shared `session` instance from `init`, register the handler in `init` instead so it persists across reconnects.

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 5: Run all voice-related tests**

Run: `swift test --filter Voice`
Expected: PASS (no regressions in `VoiceAudioCaptureTests`, `VoiceCommandControllerTests`, etc.).

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Sources/Nous/Services/RealtimeVoiceSession.swift
git commit -m "feat(voice): plumb smoothed audio level into VoiceCommandController"
```

---

### Task 1.3: Create `VoiceWaveformBars` view

**Files:**
- Create: `Sources/Nous/Views/Voice/VoiceWaveformBars.swift`

- [ ] **Step 1: Implement the view**

Create `Sources/Nous/Views/Voice/VoiceWaveformBars.swift`:

```swift
import SwiftUI

/// Five vertical bars whose heights are driven by a 0...1 audio level. Center-weighted
/// envelope so middle bars peak higher, giving a "breathing" feel. Color is state-driven.
struct VoiceWaveformBars: View {
    enum BarState: Equatable {
        case idle
        case listening
        case thinking
        case error
    }

    let level: Float                    // 0.0 ... 1.0
    let state: BarState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 2
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 22
    private static let phase: Double = 0.85

    @State private var clock: Double = 0
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: Self.barGap) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: Self.barWidth / 2)
                    .fill(barColor)
                    .frame(width: Self.barWidth, height: barHeight(forIndex: i))
                    .animation(.spring(response: 0.18, dampingFraction: 0.7), value: barHeight(forIndex: i))
                    .animation(.easeInOut(duration: 0.14), value: state)
            }
        }
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            clock += 1.0 / 30.0
        }
    }

    private func barHeight(forIndex i: Int) -> CGFloat {
        if reduceMotion { return Self.minHeight + 6 }
        if state == .idle || state == .error { return Self.minHeight }

        let envelope = 0.6 + 0.4 * sin(Double(i) * Self.phase + clock)
        let raw = CGFloat(level) * CGFloat(envelope) * Self.maxHeight
        return min(Self.maxHeight, max(Self.minHeight, raw))
    }

    private var barColor: Color {
        switch state {
        case .idle:      return AppColor.colaOrange.opacity(0.28)
        case .listening: return AppColor.colaOrange
        case .thinking:  return AppColor.colaOrange.opacity(0.6)
        case .error:     return Color.red
        }
    }
}

#Preview("Listening high level") {
    VoiceWaveformBars(level: 0.9, state: .listening).padding()
}

#Preview("Idle") {
    VoiceWaveformBars(level: 0.0, state: .idle).padding()
}

#Preview("Thinking") {
    VoiceWaveformBars(level: 0.4, state: .thinking).padding()
}

#Preview("Error") {
    VoiceWaveformBars(level: 0.0, state: .error).padding()
}
```

- [ ] **Step 2: Verify build and previews compile**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/VoiceWaveformBars.swift
git commit -m "feat(voice): add VoiceWaveformBars view"
```

---

### Task 1.4: Replace static dot in `VoiceCapsuleView` with `VoiceWaveformBars`

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift` (where `VoiceCapsuleView` lives — search the file for `struct VoiceCapsuleView`)

- [ ] **Step 1: Find the `VoiceCapsuleView` definition**

Run: `grep -n "struct VoiceCapsuleView\|VoiceModeStatus\|Circle()" Sources/Nous/Views/ChatArea.swift`
Confirm the dot is rendered there (likely a small `Circle().fill(...)` inside the capsule body).

- [ ] **Step 2: Add `audioLevel` and `voiceState` parameters to `VoiceCapsuleView`**

Edit `VoiceCapsuleView`'s declaration to take an audio level and a derived `BarState`:

```swift
struct VoiceCapsuleView: View {
    let status: VoiceModeStatus
    let subtitleText: String
    let hasPendingConfirmation: Bool
    let audioLevel: Float
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var barState: VoiceWaveformBars.BarState {
        switch status {
        case .listening:                return .listening
        case .thinking:                 return .thinking
        case .error:                    return .error
        case .idle, .action, .needsConfirmation:
            return .idle
        }
    }
    // ... rest of the view body unchanged except for the dot replacement below.
}
```

Replace the existing leading status indicator (the small `Circle()`) with:

```swift
VoiceWaveformBars(level: audioLevel, state: barState)
    .frame(width: 27, height: 22)  // five 3-wide bars + four 2-gaps = 23pt; pad to 27 for breathing room
```

- [ ] **Step 3: Update callers of `VoiceCapsuleView` to pass `audioLevel`**

Two call sites:
1. `Sources/Nous/Views/ChatArea.swift` around line 259-265
2. `Sources/Nous/App/ContentView.swift` around line 393-399

Both should pass `audioLevel: voiceController.audioLevel` (and `dependencies.voiceController.audioLevel` respectively).

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift Sources/Nous/App/ContentView.swift
git commit -m "feat(voice): replace static dot with waveform bars in capsule"
```

---

### Task 1.5: Phase 1 live test fence (manual, no commit)

- [ ] **Step 1: Run the app**

Open the project in Xcode and run. Activate voice mode (mic button in chat composer). Speak.

- [ ] **Step 2: Visual verification**

- The dot is gone; five colaOrange bars now sit in the capsule.
- Bars react in real time to your voice. Louder = taller.
- When the model is thinking, bars dim to ~60% alpha and reduce activity.
- Toggle macOS "Reduce motion" in System Settings → Accessibility → Display. Re-test: bars hold a flat midline instead of breathing.
- Stop voice mode. Bars freeze flat.

- [ ] **Step 3: If anything is off, fix and amend the most recent commit before moving to Phase 2.**

Run: `git status` (should be clean after fixes).

---

## Phase 2 — Transcript panel

### Task 2.1: Add `transcript: [VoiceTranscriptLine]` to controller and migrate the buffer reducer

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NousTests/Voice/VoiceCommandControllerTranscriptTests.swift`. Follow the existing test pattern (the `FakeRealtimeVoiceSession` private fake is defined in `Tests/NousTests/VoiceCommandControllerTests.swift` lines 819-863; copy its declaration into the new file or move it to a shared test helper if you prefer).

```swift
import XCTest
@testable import Nous

@MainActor
final class VoiceCommandControllerTranscriptTests: XCTestCase {
    func test_inputDeltaThenComplete_buildsUserLine() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        try await controller.start(apiKey: "k")

        await session.emit(.inputTranscriptDelta("Open"))
        await session.emit(.inputTranscriptDelta(" Galaxy"))
        XCTAssertEqual(controller.transcript.count, 1)
        XCTAssertEqual(controller.transcript[0].role, .user)
        XCTAssertEqual(controller.transcript[0].text, "Open Galaxy")
        XCTAssertFalse(controller.transcript[0].isFinal)

        await session.emit(.inputTranscriptCompleted("Open Galaxy."))
        XCTAssertEqual(controller.transcript.count, 1)
        XCTAssertTrue(controller.transcript[0].isFinal)
        XCTAssertEqual(controller.transcript[0].text, "Open Galaxy.")
    }

    func test_assistantAfterUser_opensSecondLine() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        try await controller.start(apiKey: "k")

        await session.emit(.inputTranscriptCompleted("Hi."))
        await session.emit(.outputTranscriptDelta("Hey"))
        XCTAssertEqual(controller.transcript.count, 2)
        XCTAssertEqual(controller.transcript[1].role, .assistant)
        XCTAssertEqual(controller.transcript[1].text, "Hey")
        XCTAssertFalse(controller.transcript[1].isFinal)
    }

    func test_stopClearsTranscript() async throws {
        let session = FakeRealtimeVoiceSession()
        let controller = VoiceCommandController(session: session)
        try await controller.start(apiKey: "k")

        await session.emit(.outputTranscriptCompleted("Done."))
        XCTAssertEqual(controller.transcript.count, 1)

        controller.stop()
        XCTAssertEqual(controller.transcript.count, 0)
    }
}
```

(If `FakeRealtimeVoiceSession` is private to `VoiceCommandControllerTests.swift`, the fastest path is to lift it into a new shared file `Tests/NousTests/Voice/Fakes/FakeRealtimeVoiceSession.swift` with `internal` access and import it into both test files.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceCommandControllerTranscriptTests`
Expected: FAIL with "value of type 'VoiceCommandController' has no member 'transcript'".

- [ ] **Step 3: Add `transcript` and route deltas through the new reducer**

In `VoiceCommandController.swift`, near the top of the class:

```swift
var transcript: [VoiceTranscriptLine] = []
```

Replace `appendInputTranscript`, `completeInputTranscript`, `appendOutputTranscript`, `completeOutputTranscript`, and `resetTranscript` with:

```swift
private func appendInputTranscript(_ delta: String) {
    inputTranscriptBuffer += delta
    subtitleText = inputTranscriptBuffer
    VoiceTranscriptLine.appendDelta(delta, role: .user, into: &transcript)
}

private func completeInputTranscript(_ text: String) {
    inputTranscriptBuffer = text
    inputTranscriptIsFinal = true
    subtitleText = text
    VoiceTranscriptLine.finalize(text: text, role: .user, into: &transcript)
    if pendingAction == nil {
        status = .thinking
    }
}

private func appendOutputTranscript(_ delta: String) {
    outputTranscriptBuffer += delta
    subtitleText = outputTranscriptBuffer
    VoiceTranscriptLine.appendDelta(delta, role: .assistant, into: &transcript)
}

private func completeOutputTranscript(_ text: String) {
    outputTranscriptBuffer = text
    outputTranscriptIsFinal = true
    subtitleText = text
    VoiceTranscriptLine.finalize(text: text, role: .assistant, into: &transcript)
}

private func resetTranscript() {
    subtitleText = ""
    inputTranscriptBuffer = ""
    outputTranscriptBuffer = ""
    inputTranscriptIsFinal = false
    outputTranscriptIsFinal = false
    transcript = []
}
```

(Note: keep `subtitleText` for now — the capsule's small status label still uses it. We do not remove it in this plan.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VoiceCommandControllerTranscriptTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Tests/NousTests/Voice/VoiceCommandControllerTranscriptTests.swift
git commit -m "feat(voice): track transcript as [VoiceTranscriptLine] on controller"
```

---

### Task 2.2: Create `VoiceTranscriptPanel` view

**Files:**
- Create: `Sources/Nous/Views/Voice/VoiceTranscriptPanel.swift`

- [ ] **Step 1: Implement the panel**

Create `Sources/Nous/Views/Voice/VoiceTranscriptPanel.swift`:

```swift
import SwiftUI

struct VoiceTranscriptPanel: View {
    let lines: [VoiceTranscriptLine]
    let isVisible: Bool

    @State private var userIsScrolling: Bool = false

    var body: some View {
        if isVisible && !lines.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(lines) { line in
                            bubble(for: line)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("__bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(maxWidth: 480)
                .frame(maxHeight: 360)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppColor.colaOrange.opacity(0.18), lineWidth: 1)
                        )
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.easeOut(duration: 0.22), value: isVisible)
                .onChange(of: lines.count) { _, _ in
                    if !userIsScrolling {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("__bottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: lines.last?.text) { _, _ in
                    if !userIsScrolling {
                        proxy.scrollTo("__bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for line: VoiceTranscriptLine) -> some View {
        HStack(spacing: 0) {
            if line.role == .user { Spacer(minLength: 40) }
            VStack(alignment: line.role == .user ? .trailing : .leading, spacing: 4) {
                Text(line.role == .user ? "YOU" : "NOUS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(.body)
                    .foregroundStyle(line.isFinal ? .primary : .primary.opacity(0.7))
                    .multilineTextAlignment(line.role == .user ? .trailing : .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(line.role == .user
                                  ? Color.clear
                                  : AppColor.colaOrange.opacity(0.04))
                    )
            }
            if line.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

#Preview("Multi-turn") {
    VoiceTranscriptPanel(
        lines: [
            VoiceTranscriptLine(role: .user, text: "Open Galaxy.", isFinal: true, createdAt: Date()),
            VoiceTranscriptLine(role: .assistant, text: "Opening Galaxy now.", isFinal: true, createdAt: Date()),
            VoiceTranscriptLine(role: .user, text: "Show my recent thoughts on Path B.", isFinal: true, createdAt: Date()),
            VoiceTranscriptLine(role: .assistant, text: "Searching memory…", isFinal: false, createdAt: Date()),
        ],
        isVisible: true
    )
    .padding()
    .frame(width: 600, height: 500)
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/VoiceTranscriptPanel.swift
git commit -m "feat(voice): add VoiceTranscriptPanel view"
```

---

### Task 2.3: Mount the transcript panel beneath the capsule

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift`
- Modify: `Sources/Nous/App/ContentView.swift`

- [ ] **Step 1: In `ChatArea.swift`, mount the panel inside the same `ZStack(alignment: .top)` that hosts `VoiceCapsuleView`**

Find the block around line 247-291 (`// Floating Header` ZStack). Inside it, after the existing `if voiceController.isActive || voiceController.status.shouldDisplayPill || voiceController.pendingAction != nil { VoiceCapsuleView(...) }` block, add:

```swift
VoiceTranscriptPanel(
    lines: voiceController.transcript,
    isVisible: voiceController.isActive
)
.padding(.top, 60)  // sits below the capsule
.allowsHitTesting(true)
```

- [ ] **Step 2: In `ContentView.swift`, mount the panel near the second `VoiceCapsuleView` (around line 393)**

After the existing `VoiceCapsuleView(...)` block, add the same panel:

```swift
VoiceTranscriptPanel(
    lines: dependencies.voiceController.transcript,
    isVisible: dependencies.voiceController.isActive
)
.padding(.top, 60)
.allowsHitTesting(true)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift Sources/Nous/App/ContentView.swift
git commit -m "feat(voice): mount transcript panel beneath capsule"
```

---

### Task 2.4: Phase 2 live test fence (manual, no commit)

- [ ] **Step 1: Run the app and start voice mode**

Speak a few turns. The transcript panel should appear under the capsule and stream live deltas.

- [ ] **Step 2: Verify**

- User lines right-aligned with "YOU" label; assistant left-aligned with "NOUS" label.
- In-progress lines render dimmer than final lines.
- Auto-scroll follows new content.
- Scroll up to read history — auto-scroll stops chasing the bottom.
- Stop voice mode. Panel fades out and clears.

- [ ] **Step 3: Fix issues and amend the most recent commit before Phase 3.**

---

## Phase 3 — Ghost cursor

### Task 3.1: Add a target-id resolver to the controller

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NousTests/Voice/GhostCursorTargetResolverTests.swift`:

```swift
import XCTest
@testable import Nous

final class GhostCursorTargetResolverTests: XCTestCase {
    func test_navigateToTab_resolvesToTabId() {
        XCTAssertEqual(
            VoiceCommandController.ghostCursorTargetId(toolName: "navigate_to_tab", args: ["tab": "galaxy"]),
            "tab_galaxy"
        )
        XCTAssertEqual(
            VoiceCommandController.ghostCursorTargetId(toolName: "navigate_to_tab", args: ["tab": "chat"]),
            "tab_chat"
        )
    }

    func test_setSidebarVisibility_resolvesToSidebarToggle() {
        XCTAssertEqual(
            VoiceCommandController.ghostCursorTargetId(toolName: "set_sidebar_visibility", args: ["visible": true]),
            "sidebar_toggle"
        )
    }

    func test_setScratchpadVisibility_resolvesToScratchpadToggle() {
        XCTAssertEqual(
            VoiceCommandController.ghostCursorTargetId(toolName: "set_scratchpad_visibility", args: ["visible": false]),
            "scratchpad_toggle"
        )
    }

    func test_setAppearanceMode_resolvesToAppearanceToggle() {
        XCTAssertEqual(
            VoiceCommandController.ghostCursorTargetId(toolName: "set_appearance_mode", args: ["mode": "dark"]),
            "appearance_toggle"
        )
    }

    func test_unknownTool_returnsNil() {
        XCTAssertNil(
            VoiceCommandController.ghostCursorTargetId(toolName: "recall_memory", args: [:])
        )
    }

    func test_unknownTabValue_returnsNil() {
        XCTAssertNil(
            VoiceCommandController.ghostCursorTargetId(toolName: "navigate_to_tab", args: ["tab": "atlantis"])
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GhostCursorTargetResolverTests`
Expected: FAIL.

- [ ] **Step 3: Add the resolver as a static method**

At the top of `VoiceCommandController.swift` (or near the bottom of the type), add:

```swift
static func ghostCursorTargetId(toolName: String, args: [String: Any]) -> String? {
    switch toolName {
    case "navigate_to_tab":
        guard let tab = args["tab"] as? String else { return nil }
        switch tab {
        case "chat", "notes", "galaxy", "settings":
            return "tab_\(tab)"
        default:
            return nil
        }
    case "set_sidebar_visibility":
        return "sidebar_toggle"
    case "set_scratchpad_visibility":
        return "scratchpad_toggle"
    case "set_appearance_mode":
        return "appearance_toggle"
    default:
        return nil
    }
}

static let spatialTools: Set<String> = [
    "navigate_to_tab",
    "set_sidebar_visibility",
    "set_scratchpad_visibility",
    "set_appearance_mode",
]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GhostCursorTargetResolverTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Tests/NousTests/Voice/GhostCursorTargetResolverTests.swift
git commit -m "feat(voice): add ghost cursor target id resolver"
```

---

### Task 3.2: Tag SwiftUI views with `.ghostCursorTarget(id:)`

**Files:**
- Modify: `Sources/Nous/Views/LeftSidebar.swift`
- Modify: `Sources/Nous/Views/ChatArea.swift`

- [ ] **Step 1: Tag tab buttons in `LeftSidebar.swift`**

Find each tab `NavIconButton` (approximately lines 257-263 for galaxy and chat; also locate the notes button and the settings button around line 377). Append `.ghostCursorTarget(id:)` to each:

```swift
NavIconButton(/* ... galaxy ... */)
    .ghostCursorTarget(id: "tab_galaxy")

NavIconButton(/* ... chat ... */)
    .ghostCursorTarget(id: "tab_chat")

NavIconButton(/* ... notes ... */)
    .ghostCursorTarget(id: "tab_notes")

// Settings tap area around line 377
.contentShape(Rectangle())
.onTapGesture { selectedTab = .settings }
.ghostCursorTarget(id: "tab_settings")
```

- [ ] **Step 2: Tag the sidebar toggle and scratchpad toggle in `ChatArea.swift`**

Find the two `.overlay(alignment: .topLeading)` (sidebar toggle) and `.overlay(alignment: .topTrailing)` (scratchpad toggle) blocks (around line 433 and 455). On the inner `Button` (or its containing view), append:

```swift
.ghostCursorTarget(id: "sidebar_toggle")
```

and

```swift
.ghostCursorTarget(id: "scratchpad_toggle")
```

- [ ] **Step 3: Tag the voice capsule itself as `voice_capsule` (origin point for ghost cursor travel)**

In both `ChatArea.swift` and `ContentView.swift`, add to the `VoiceCapsuleView(...)` instance:

```swift
VoiceCapsuleView(...).ghostCursorTarget(id: "voice_capsule")
```

- [ ] **Step 4: Tag the appearance toggle**

Find where appearance mode is changed (likely a Settings row). Search:

Run: `grep -rn "set_appearance_mode\|appearance" Sources/Nous/Views Sources/Nous/App | head`
Tag the most natural target view (the appearance picker row in `SettingsView.swift`, or the menu item that triggers it) with `.ghostCursorTarget(id: "appearance_toggle")`. If no clear single target exists, tag the settings tab button as a fallback (already covered by `tab_settings` — in that case, document and skip).

- [ ] **Step 5: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Views/LeftSidebar.swift Sources/Nous/Views/ChatArea.swift Sources/Nous/App/ContentView.swift Sources/Nous/Views/SettingsView.swift
git commit -m "feat(voice): tag tab buttons and toggles with ghostCursorTarget"
```

---

### Task 3.3: Add `ghostCursorIntent` published state and gate spatial tool dispatch

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

- [ ] **Step 1: Add the published state**

In `VoiceCommandController.swift`:

```swift
var ghostCursorIntent: GhostCursorIntent?
private var pendingCursorContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]
```

Add public methods the overlay calls:

```swift
func cursorDidArrive(intentId: UUID) {
    pendingCursorContinuations[intentId]?.resume()
    pendingCursorContinuations.removeValue(forKey: intentId)
    if ghostCursorIntent?.id == intentId {
        ghostCursorIntent = nil
    }
}

func cursorWasDismissed(intentId: UUID) {
    pendingCursorContinuations[intentId]?.resume()
    pendingCursorContinuations.removeValue(forKey: intentId)
    if ghostCursorIntent?.id == intentId {
        ghostCursorIntent = nil
    }
}
```

- [ ] **Step 2: Add a private gate function**

```swift
private func awaitGhostCursorOrTimeout(intent: GhostCursorIntent) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        pendingCursorContinuations[intent.id] = continuation
        ghostCursorIntent = intent
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000) // 700ms safety
            if let pending = self.pendingCursorContinuations.removeValue(forKey: intent.id) {
                pending.resume()
                if self.ghostCursorIntent?.id == intent.id {
                    self.ghostCursorIntent = nil
                }
            }
        }
    }
}
```

- [ ] **Step 3: Wire the gate into the spatial-tool dispatch path**

Find where the controller dispatches a tool call (around lines 92-107, the `case .toolCall(let call, let callId):` branch). Just before invoking the actual handler, insert:

```swift
let toolName = call.name
let args = call.argumentsAsDictionary  // or however the existing code reads args

if Self.spatialTools.contains(toolName),
   let targetId = Self.ghostCursorTargetId(toolName: toolName, args: args) {
    let intent = GhostCursorIntent(targetId: targetId)
    await awaitGhostCursorOrTimeout(intent: intent)
}
```

(Adapt the `args` extraction to match the existing `call` model.)

This means the dispatch path needs to be `async`. If it isn't already, wrap the existing dispatch in `Task { @MainActor in ... }` and convert the relevant call sites to `await`. If that ripples too far, instead enqueue the intent and have the overlay's `cursorDidArrive` callback drive a queued continuation; choose the simpler path that the existing code allows.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 5: Run all voice tests**

Run: `swift test --filter Voice`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift
git commit -m "feat(voice): gate spatial tool dispatch behind ghost cursor travel"
```

---

### Task 3.4: Implement the `GhostCursorOverlay` view

**Files:**
- Create: `Sources/Nous/Views/Voice/GhostCursorOverlay.swift`

- [ ] **Step 1: Implement the overlay**

Create `Sources/Nous/Views/Voice/GhostCursorOverlay.swift`:

```swift
import SwiftUI
import AppKit

/// Top-level overlay that animates a stylized cursor from the voice capsule to a registered
/// target view, then fires an arrival pulse on the target. Behavior and timing port the
/// openai/realtime-voice-component reference; chromatic accents use Nous's colaOrange.
struct GhostCursorOverlay: View {
    let intent: GhostCursorIntent?
    let onArrive: (UUID) -> Void
    let onDismiss: (UUID) -> Void

    @Environment(GhostCursorRegistry.self) private var registry: GhostCursorRegistry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: GhostCursorPhase = .hidden
    @State private var position: CGPoint = .zero
    @State private var activeIntentId: UUID?
    @State private var scrollMonitor: Any?

    var body: some View {
        Group {
            if phase != .hidden {
                cursorView
                    .position(position)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onChange(of: intent) { _, newIntent in
            guard let newIntent, let registry else {
                clearCursor()
                return
            }
            startTravel(intent: newIntent, registry: registry)
        }
        .onDisappear { stopScrollMonitor() }
    }

    private var cursorView: some View {
        ZStack {
            // Halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AppColor.colaOrange.opacity(0.20),
                            AppColor.colaOrange.opacity(0.08),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 12
                    )
                )
                .frame(width: 24, height: 24)
                .blur(radius: 4)
                .opacity(phase == .traveling || phase == .arrived || phase == .error ? 1 : 0)

            // Pointer body (dark navy with orange core accent)
            cursorArrow
                .frame(width: 18, height: 26)
                .offset(x: -2, y: -3)
        }
    }

    private var cursorArrow: some View {
        ZStack(alignment: .topLeading) {
            CursorShape()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.09, blue: 0.16),
                                 Color(red: 0.07, green: 0.09, blue: 0.16)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 4)

            CursorShape()
                .inset(by: 1)
                .fill(
                    LinearGradient(
                        colors: [.white, Color(red: 0.96, green: 0.97, blue: 1.0), Color(red: 0.86, green: 0.90, blue: 0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Core accent (was reference cyan, here colaOrange)
            RoundedRectangle(cornerRadius: 1)
                .fill(
                    LinearGradient(
                        colors: [AppColor.colaOrange.opacity(0.95), AppColor.colaOrange.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2, height: 10)
                .offset(x: 6, y: 7)
                .opacity(0.55)
        }
        .rotationEffect(.degrees(-7))
    }

    private func startTravel(intent: GhostCursorIntent, registry: GhostCursorRegistry) {
        guard
            let origin = registry.center(for: "voice_capsule"),
            let target = registry.center(for: intent.targetId)
        else {
            // No origin or no target — tell controller to release immediately.
            onArrive(intent.id)
            return
        }

        activeIntentId = intent.id
        position = origin
        phase = .traveling
        startScrollMonitor(intentId: intent.id)

        if reduceMotion {
            position = target
            phase = .arrived
            registry.pulse(id: intent.targetId)
            onArrive(intent.id)
            scheduleHide(after: 0.26)
            return
        }

        let durationMs = GhostCursorIntent.travelDurationMs(from: origin, to: target)
        let timing = SwiftUI.Animation.timingCurve(0.22, 0.84, 0.26, 1.0, duration: durationMs / 1000.0)
        withAnimation(timing) {
            position = target
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(durationMs * 1_000_000))
            guard activeIntentId == intent.id else { return }
            phase = .arrived
            registry.pulse(id: intent.targetId)
            onArrive(intent.id)
            scheduleHide(after: 0.26)
        }
    }

    private func scheduleHide(after seconds: Double) {
        let ownIntentId = activeIntentId
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard activeIntentId == ownIntentId else { return }
            withAnimation(.easeOut(duration: 0.18)) { phase = .hidden }
            stopScrollMonitor()
            activeIntentId = nil
        }
    }

    private func clearCursor() {
        withAnimation(.easeOut(duration: 0.12)) { phase = .hidden }
        stopScrollMonitor()
        activeIntentId = nil
    }

    private func startScrollMonitor(intentId: UUID) {
        stopScrollMonitor()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            if activeIntentId == intentId {
                onDismiss(intentId)
                clearCursor()
            }
            return event
        }
    }

    private func stopScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}

private struct CursorShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> CursorShape {
        var copy = self
        copy.insetAmount = amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var p = Path()
        let w = r.width
        let h = r.height
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h))
        p.addLine(to: CGPoint(x: r.minX + 0.30 * w, y: r.minY + 0.74 * h))
        p.addLine(to: CGPoint(x: r.minX + 0.44 * w, y: r.minY + h))
        p.addLine(to: CGPoint(x: r.minX + 0.57 * w, y: r.minY + 0.94 * h))
        p.addLine(to: CGPoint(x: r.minX + 0.45 * w, y: r.minY + 0.67 * h))
        p.addLine(to: CGPoint(x: r.minX + w, y: r.minY + 0.67 * h))
        p.closeSubpath()
        return p
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/Voice/GhostCursorOverlay.swift
git commit -m "feat(voice): add GhostCursorOverlay view"
```

---

### Task 3.5: Mount the overlay and provide the registry

**Files:**
- Modify: `Sources/Nous/App/ContentView.swift`

- [ ] **Step 1: Construct the registry and inject it**

Near the top of the `ContentView` struct, add a `@State` for the registry:

```swift
@State private var ghostCursorRegistry = GhostCursorRegistry()
```

In the body, find the outermost view that wraps the entire app (the root `ZStack` or similar). Wrap it (or attach to it) with:

```swift
.environment(ghostCursorRegistry)
```

- [ ] **Step 2: Mount the overlay at the top of the root view**

After the existing root content, add an `.overlay(...)` that draws the cursor on top of everything:

```swift
.overlay(alignment: .topLeading) {
    GhostCursorOverlay(
        intent: dependencies.voiceController.ghostCursorIntent,
        onArrive: { intentId in
            dependencies.voiceController.cursorDidArrive(intentId: intentId)
        },
        onDismiss: { intentId in
            dependencies.voiceController.cursorWasDismissed(intentId: intentId)
        }
    )
    .environment(ghostCursorRegistry)
    .allowsHitTesting(false)
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/App/ContentView.swift
git commit -m "feat(voice): mount GhostCursorOverlay and inject registry"
```

---

### Task 3.6: Phase 3 live test fence (manual, no commit)

- [ ] **Step 1: Run the app and start voice mode**

Speak: "Open Galaxy."

- [ ] **Step 2: Verify**

- The cursor sprite appears at the capsule, travels in 0.3–0.6s to the Galaxy tab, the tab pulses with a colaOrange ring, then the tab actually switches.
- Try "Show notes," "Open settings," "Show chat" — same flow for each.
- Try "Hide the sidebar" / "Show the sidebar" — cursor flies to the sidebar toggle.
- Try a memory recall ("Remind me what I said about X") — no ghost cursor (expected).
- Toggle macOS Reduce Motion: the cursor jumps to arrived state without travel.
- Trigger a long-distance ghost cursor and scroll the chat area mid-travel — cursor disappears, the tab still switches.
- Force an unregistered target (temporarily comment out one tab's `.ghostCursorTarget` modifier) — the tool still executes; no stall.

- [ ] **Step 3: Fix issues and amend the most recent commit before Task 3.7.**

---

### Task 3.7: Tool-error cursor flash (red halo for ~320ms)

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
- Modify: `Sources/Nous/Views/Voice/GhostCursorOverlay.swift`

- [ ] **Step 1: Add an error-flash signal on the controller**

In `VoiceCommandController.swift`:

```swift
var ghostCursorErrorAt: Date?

func flashGhostCursorError() {
    ghostCursorErrorAt = Date()
}
```

In the tool-dispatch path, when a spatial tool's handler throws or returns an error, call `flashGhostCursorError()` after `cursorDidArrive` (so the cursor is already at the target when it goes red).

- [ ] **Step 2: Render an error-tinted variant in the overlay**

In `GhostCursorOverlay.swift`, accept an additional binding-like input:

```swift
let errorAt: Date?
```

Update the call site in `ContentView` to pass `errorAt: dependencies.voiceController.ghostCursorErrorAt`.

In the overlay, watch for `errorAt` changes; when a new value arrives within the last 400ms, swap the halo + core gradient to system red for ~320ms, then fade. Concretely:

```swift
@State private var errorFlashStart: Date?

// in onChange(of: errorAt):
.onChange(of: errorAt) { _, newDate in
    guard let newDate, newDate.timeIntervalSinceNow > -0.4 else { return }
    errorFlashStart = newDate
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 320_000_000)
        if errorFlashStart == newDate { errorFlashStart = nil }
    }
}

// in cursorView, swap halo gradient when errorFlashStart != nil:
private var haloIsErroring: Bool { errorFlashStart != nil }
```

Use `Color.red.opacity(0.32)` for the halo center stop when `haloIsErroring` is true; otherwise the existing colaOrange.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 4: Manual verification**

Force a tool failure (e.g., temporarily make the `navigate_to_tab` handler in `ContentView` throw, then say "Open Galaxy") — cursor arrives, halo flashes red briefly, then fades.

- [ ] **Step 5: Revert any test-only failure injection. Commit.**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Sources/Nous/Views/Voice/GhostCursorOverlay.swift Sources/Nous/App/ContentView.swift
git commit -m "feat(voice): flash red halo on ghost cursor when tool errors"
```

---

## Self-Review Checklist (run after writing the plan, before handing off)

- [ ] Spec coverage: every locked decision in `2026-04-28-voice-mode-openai-parity-design.md` maps to at least one task above.
- [ ] No placeholders: no "TBD", "TODO", or "implement later" text in any task step.
- [ ] Type consistency: `VoiceTranscriptLine`, `GhostCursorIntent`, `GhostCursorPhase`, `GhostCursorEasing`, `GhostCursorRegistry`, `VoiceWaveformBars.BarState` all referenced consistently across tasks.
- [ ] Each phase has a live-test fence; no phase commits without a fresh-conversation manual test (per the surgical-edit memory).
- [ ] No anchor.md edits anywhere.
