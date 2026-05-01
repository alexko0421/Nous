import XCTest
@testable import Nous

final class BeadsAgentWorkServiceTests: XCTestCase {
    func testDefaultCommandsExposeReadOnlyAgentWorkflow() {
        let commands = BeadsAgentWorkCommand.defaultCommands

        XCTAssertEqual(commands.map(\.command), [
            "bd prime",
            "bd ready --json",
            "scripts/setup_beads_agent_memory.sh"
        ])
        XCTAssertTrue(commands.allSatisfy { !$0.command.contains(" close ") })
        XCTAssertTrue(commands.allSatisfy { !$0.command.contains(" update ") })
        XCTAssertTrue(commands.allSatisfy { !$0.command.contains(" remember ") })
    }

    func testSetupHintPointsMissingBdToSetupScript() {
        let hint = BeadsAgentWorkSetupHint.message(
            errorMessage: "Could not launch bd: The file bd does not exist.",
            beadsPath: ""
        )

        XCTAssertTrue(hint.contains("scripts/setup_beads_agent_memory.sh --install"))
    }

    func testLoadSnapshotDecodesReadOnlyAgentWorkLists() throws {
        let runner = FakeBeadsCommandRunner(outputs: [
            "where": "/Users/alex/.local/share/nous/beads\n",
            "ready --json": """
            [
              {
                "id": "new-york-0hm",
                "title": "Evaluate native Beads graph",
                "description": "Decide whether a later native graph is worth it.",
                "status": "open",
                "priority": 3,
                "issue_type": "task",
                "created_at": "2026-04-30T20:00:00Z",
                "updated_at": "2026-04-30T20:05:00Z",
                "dependency_count": 0,
                "dependent_count": 0,
                "comment_count": 0
              }
            ]
            """,
            "list --status=in_progress --json": """
            [
              {
                "id": "new-york-129",
                "title": "Design read-only Beads surface in Nous",
                "description": "Show active coding-agent work without writing to Beads.",
                "status": "in_progress",
                "priority": 2,
                "issue_type": "feature",
                "assignee": "codex",
                "created_at": "2026-04-30T20:10:00Z",
                "updated_at": "2026-04-30T20:15:00Z",
                "started_at": "2026-04-30T20:12:00Z",
                "dependency_count": 1,
                "dependent_count": 0,
                "comment_count": 2,
                "dependencies": [
                  {
                    "issue_id": "new-york-129",
                    "depends_on_id": "new-york-b1e",
                    "type": "discovered-from",
                    "created_at": "2026-04-30T18:57:24Z",
                    "created_by": "codex",
                    "metadata": "{}"
                  }
                ]
              }
            ]
            """,
            "list --status=closed --json": """
            [
              {
                "id": "new-york-b1e",
                "title": "Wire Beads setup",
                "description": "Add shared Beads setup and protocol docs.",
                "status": "closed",
                "priority": 1,
                "issue_type": "task",
                "closed_at": "2026-04-30T20:20:00Z",
                "close_reason": "Setup script, docs, and workflow helper shipped.",
                "dependency_count": 0,
                "dependent_count": 1,
                "comment_count": 1
              },
              {
                "id": "new-york-l61",
                "title": "Older closed work",
                "description": "",
                "status": "closed",
                "priority": 4,
                "issue_type": "task",
                "closed_at": "2026-04-29T20:20:00Z",
                "dependency_count": 0,
                "dependent_count": 0,
                "comment_count": 0
              }
            ]
            """
        ])
        let service = BeadsAgentWorkService(commandRunner: runner, recentClosedLimit: 1)

        let snapshot = try service.loadSnapshot()

        XCTAssertEqual(snapshot.beadsPath, "/Users/alex/.local/share/nous/beads")
        XCTAssertEqual(snapshot.ready.map(\.id), ["new-york-0hm"])
        XCTAssertEqual(snapshot.inProgress.map(\.id), ["new-york-129"])
        XCTAssertEqual(snapshot.inProgress.first?.dependencies.map(\.id), ["new-york-b1e"])
        XCTAssertEqual(snapshot.inProgress.first?.dependencies.first?.relation, "discovered-from")
        XCTAssertEqual(snapshot.recentClosed.map(\.id), ["new-york-b1e"])
        XCTAssertEqual(snapshot.recentClosed.first?.closeReason, "Setup script, docs, and workflow helper shipped.")
        XCTAssertEqual(runner.invocations, [
            ["where"],
            ["ready", "--json"],
            ["list", "--status=in_progress", "--json"],
            ["list", "--status=closed", "--json"]
        ])
    }

    func testLoadSnapshotTreatsBlankJsonAsEmptyLists() throws {
        let runner = FakeBeadsCommandRunner(outputs: [
            "where": "  /shared/beads  \n",
            "ready --json": "",
            "list --status=in_progress --json": "   \n",
            "list --status=closed --json": "[]"
        ])
        let service = BeadsAgentWorkService(commandRunner: runner)

        let snapshot = try service.loadSnapshot()

        XCTAssertEqual(snapshot.beadsPath, "/shared/beads")
        XCTAssertTrue(snapshot.ready.isEmpty)
        XCTAssertTrue(snapshot.inProgress.isEmpty)
        XCTAssertTrue(snapshot.recentClosed.isEmpty)
    }
}

private final class FakeBeadsCommandRunner: BeadsCommandRunning {
    private let outputs: [String: String]
    private(set) var invocations: [[String]] = []

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    func run(_ arguments: [String]) throws -> String {
        invocations.append(arguments)
        let key = arguments.joined(separator: " ")
        guard let output = outputs[key] else {
            throw MissingFakeBeadsOutput(arguments: arguments)
        }
        return output
    }
}

private struct MissingFakeBeadsOutput: Error {
    let arguments: [String]
}
