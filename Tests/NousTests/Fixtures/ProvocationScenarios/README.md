# Provocation Scenarios

Hand-authored fixtures for judgment-quality regression checks on `ProvocationJudge`.

Each `*.json` file is one scenario. Format:

```json
{
  "name": "short-scenario-name",
  "user_message": "what the user said this turn",
  "chat_mode": "companion" | "strategist",
  "citable_pool": [
    { "id": "E1", "text": "…entry text…", "scope": "global" }
  ],
  "expected": {
    "should_provoke": true,
    "user_state": "deciding",
    "entry_id": "E1"
  }
}
```

The `expected` block asserts **shape only**, not exact wording. The runner (`scripts/run_provocation_fixtures.sh`) runs each scenario against the real judge and reports:
- ✅ if `should_provoke`, `user_state`, and (when expected) `entry_id` match
- ❌ with a diff otherwise

When you change the judge prompt, run the script and treat every ❌ as either:
(a) a regression (fix the prompt), or
(b) a legitimate behavior shift (update the fixture's `expected`).
