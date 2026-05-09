# Source Connection Brief V2A Design

**Date:** 2026-05-04
**Status:** Approved for implementation

## Summary

Source/Link Connection V1 made external URLs and documents real `source` nodes: Nous can ingest, chunk, embed, cite, and connect them in Galaxy. V2A keeps that substrate and upgrades the answer behavior. When a turn contains source material, Nous should produce a compact connection brief that separates external claims from Alex/Nous connections, grounds both sides, and leaves personal memory untouched.

## Goal

Make pasted links and documents feel like "连点成线" instead of plain summarization: the reply should say what the source claims, which existing Nous notes/conversations it connects to, why that connection matters, and what evidence grounded the connection.

## Non-Goals

- Do not build a Source Library UI.
- Do not auto-promote source material into Alex identity, project memory, `memory_entries`, `memory_fact_entries`, or atoms.
- Do not add a multi-agent framework.
- Do not render web pages with JavaScript, authenticate, transcribe video, or browse with automation.
- Do not modify `Sources/Nous/Resources/anchor.md`.

## Behavior

When `sourceMaterials` are present, the prompt should include a Source Connection Brief contract:

1. State what the source says, citing source title, URL, filename, or source chunk marker.
2. State how it connects to Alex's existing notes, conversations, projects, or decisions when relevant.
3. Ground each connection with an existing Nous citation title when citations are available.
4. Say when no strong connection is available instead of inventing one.
5. Keep source material separate from Alex memory and do not claim it was saved as personal memory.

The reply stays in chat. No new mode or panel appears in V2A.

## Telemetry And Review

Context manifest should record source materials as loaded resources, just like citations and memory are recorded today. A source material counts as used when the assistant mentions its title, URL, filename, or host.

The runtime reviewer should keep the V1 grounding gate and add one V2A warning: when source material and existing citations are both available, the answer should either mention at least one citation title or explicitly say there is no strong existing Nous connection. This catches source answers that summarize the source but fail to connect it back to the graph.

## Files

- `Sources/Nous/Services/PromptContextAssembler.swift` adds the Source Connection Brief contract inside the existing source material prompt block.
- `Sources/Nous/Services/GovernanceTelemetryStore.swift` adds `sourceMaterial` resources to context manifests and telemetry summary counts.
- `Sources/Nous/Services/CognitionArtifactAdapters.swift` adds a source connection grounding warning.
- `Tests/NousTests/SourcePromptContextTests.swift` tests the prompt contract.
- `Tests/NousTests/AgentToolTests.swift` tests manifest source material resources.
- `Tests/NousTests/RuntimeQualityReviewerTests.swift` tests the new grounding warning.

## Acceptance Criteria

- Source prompt context includes a clear Source Connection Brief contract.
- Source material resources appear in context manifests only when `source_material` was loaded.
- Used detection works for source title, URL, filename, and host references.
- Source-analysis reviewer warns when the reply uses a source turn but does not connect to any available citation or state that no strong connection exists.
- Ordinary chat without source material is unchanged.
- Full macOS build and NousTests pass.
