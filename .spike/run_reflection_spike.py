#!/usr/bin/env python3
"""W1 D1 reflection spike: calls Gemini 2.5 Pro with responseJsonSchema, 3 runs @ temp 0.7."""
import json, os, subprocess, sys, urllib.request, urllib.error

FIXTURE = os.path.expanduser("~/.gstack/projects/alexko0421-Nous/fixtures/reflection-fixture-2026-W16.json")
OUTDIR = os.path.expanduser("~/.gstack/projects/alexko0421-Nous/fixtures")

key = subprocess.check_output(
    ["defaults", "read", "com.nous.app.Nous", "nous.gemini.apikey"]
).decode().strip()

with open(FIXTURE) as f:
    fixture_json = f.read()

SYSTEM = """You are reading one week of conversations between Alex and Nous.

Your job is to produce at most 2 "reflection claims" about Alex — patterns you notice across multiple conversations that week, NOT summaries of what was discussed.

HARD BAR (read this twice):
A reflection claim that reads like a journal entry is REJECTED. Examples of
REJECTED claims:
- "This week you discussed Swift and design." (summary, not pattern)
- "You worked on Nous a lot." (generic, not non-obvious)
- "You asked questions about engineering." (tautological)

Examples of ACCEPTED claims:
- "Three times this week you asked for a 'second opinion' right after
  committing to a direction yourself. The pattern is: decide → seek
  validation → reinforce the original call. You might be using outside
  voices as post-hoc confirmation rather than real re-evaluation."
- "In reflective-mode you accepted my provocations without pushback; in
  debug-mode you pushed back three times. You may be calibrating tolerance
  for challenge by context, not by topic."

A claim must be specific, backed by at least two turns, and tell Alex
something he would NOT have said about himself before reading it.

Rules:
- claims array has length 0, 1, or 2. Never more.
- Length 0 is a VALID answer. If nothing clears the "non-obvious" bar, return {"claims": []}. Do not invent patterns.
- supporting_turn_ids MUST be real `id` values copied verbatim from the fixture messages. Minimum 2 ids per claim.
- confidence below 0.5 means you're not confident. Use it honestly.
- why_non_obvious explains why this is a pattern Alex wouldn't self-report, not a description of the claim.

Alex's fixture (one week of his free-chat conversations) follows as the user message."""

SCHEMA = {
    "type": "object",
    "properties": {
        "claims": {
            "type": "array",
            "maxItems": 2,
            "items": {
                "type": "object",
                "properties": {
                    "claim": {"type": "string"},
                    "confidence": {"type": "number"},
                    "supporting_turn_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "minItems": 2,
                    },
                    "why_non_obvious": {"type": "string"},
                },
                "required": ["claim", "confidence", "supporting_turn_ids", "why_non_obvious"],
            },
        }
    },
    "required": ["claims"],
}

URL = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key={key}"

body = {
    "systemInstruction": {"parts": [{"text": SYSTEM}]},
    "contents": [{"role": "user", "parts": [{"text": f"Fixture:\n\n{fixture_json}"}]}],
    "generationConfig": {
        "temperature": 0.7,
        "responseMimeType": "application/json",
        "responseJsonSchema": SCHEMA,
    },
}

results = []
for i in range(1, 4):
    print(f"--- Run {i}/3 ---", flush=True)
    req = urllib.request.Request(
        URL, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            raw = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}:\n{e.read().decode()}", file=sys.stderr); sys.exit(1)

    try:
        text = raw["candidates"][0]["content"]["parts"][0]["text"]
        usage = raw.get("usageMetadata", {})
        parsed = json.loads(text)
    except (KeyError, IndexError, json.JSONDecodeError) as e:
        print(f"parse error: {e}\nraw: {json.dumps(raw, indent=2)[:3000]}", file=sys.stderr); sys.exit(1)

    results.append({"run": i, "claims": parsed, "usage": usage})
    print(json.dumps(parsed, indent=2, ensure_ascii=False))
    print(f"tokens: in={usage.get('promptTokenCount')} thinking={usage.get('thoughtsTokenCount')} out={usage.get('candidatesTokenCount')}")
    print()

out_path = os.path.join(OUTDIR, "spike-W16-results.json")
with open(out_path, "w") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)
print(f"wrote {out_path}")
