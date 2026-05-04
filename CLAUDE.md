## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review

## Beads engineering memory

Use Beads (`bd`) for coding-agent task tracking and stable repo-specific engineering memories. Run `scripts/beads_agent_workflow.sh start` at session start. For non-trivial code/docs work, claim or create a bead before editing and finish with `scripts/beads_agent_workflow.sh finish <id> "<verification summary>"`. Keep Alex/product/thinking memory in Nous, not Beads. Full protocol: `docs/beads-agent-memory.md`.

For agent delegation decisions, follow `docs/agentic-engineering-workflow.md`: default to one lead agent, use the Context Boundary Card before delegating, and keep agent teams deferred unless explicitly requested. Non-trivial work needs concrete verification; use a separate Verifier/Gatekeeper only when false-green risk justifies the extra context boundary.
