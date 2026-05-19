import XCTest

final class ProductSurfaceRetirementTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testContentViewDoesNotExposeProjectOrGalaxySurfaces() throws {
        let source = try contents("Sources/Nous/App/ContentView.swift")

        XCTAssertFalse(source.contains("GalaxyView("))
        XCTAssertFalse(source.contains("selectedGalaxyLens"))
        XCTAssertFalse(source.contains("selectedProjectId"))
        XCTAssertFalse(source.contains("case .galaxy"))
        XCTAssertFalse(source.contains("selectedTab = .galaxy"))
    }

    func testSidebarDoesNotExposeProjectListOrGalaxyIcons() throws {
        let source = try contents("Sources/Nous/Views/LeftSidebar.swift")

        XCTAssertFalse(source.contains("ProjectListView("))
        XCTAssertFalse(source.contains("showProjectList"))
        XCTAssertFalse(source.contains("struct GalaxyIcon"))
        XCTAssertFalse(source.contains("struct ProjectIcon"))
    }

    func testGalaxyUiFilesAreRemoved() {
        let retiredFiles = [
            "Sources/Nous/Views/GalaxyView.swift",
            "Sources/Nous/Views/GalaxyScene.swift",
            "Sources/Nous/Views/GalaxySceneContainer.swift",
            "Sources/Nous/Views/ProjectListView.swift"
        ]

        for path in retiredFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(path).path),
                "\(path) should stay retired"
            )
        }
    }

    func testSpriteKitIsNotLinkedWhenGalaxyUiIsRetired() throws {
        let projectYAML = try contents("project.yml")

        XCTAssertFalse(projectYAML.contains("SpriteKit.framework"))
    }

    func testProjectReusePathsAreHiddenBehindRetirementPolicy() throws {
        let noteEditor = try contents("Sources/Nous/Views/NoteEditor.swift")
        let noteViewModel = try contents("Sources/Nous/ViewModels/NoteViewModel.swift")
        let branchOverlay = try contents("Sources/Nous/Views/TemporaryBranchOverlay.swift")
        let branchViewModel = try contents("Sources/Nous/ViewModels/TemporaryBranchViewModel.swift")
        let memoryInspector = try contents("Sources/Nous/Views/MemoryDebugInspector.swift")

        XCTAssertFalse(noteEditor.contains("currentProject"))
        XCTAssertFalse(noteViewModel.contains("var currentProject"))
        XCTAssertTrue(branchOverlay.contains("RetiredFeaturePolicy.projectSurfacesEnabled"))
        XCTAssertTrue(branchViewModel.contains("RetiredFeaturePolicy.projectSurfacesEnabled"))
        XCTAssertTrue(memoryInspector.contains("MemoryFocus.availableCases"))
        XCTAssertTrue(memoryInspector.contains("RetiredFeaturePolicy.projectSurfacesEnabled"))
    }

    func testFinderProjectExportCannotRunWhileProjectIsRetired() throws {
        let contentView = try contents("Sources/Nous/App/ContentView.swift")
        let settingsView = try contents("Sources/Nous/Views/SettingsView.swift")
        let finderSyncService = try contents("Sources/Nous/Services/FinderProjectSyncService.swift")

        XCTAssertTrue(contentView.contains("guard RetiredFeaturePolicy.projectSurfacesEnabled else { return }"))
        XCTAssertTrue(settingsView.contains("if RetiredFeaturePolicy.projectSurfacesEnabled"))
        XCTAssertTrue(finderSyncService.contains("guard RetiredFeaturePolicy.projectSurfacesEnabled else { return }"))
    }

    func testGalaxyDebugTelemetryIsHiddenBehindRetirementPolicy() throws {
        let memoryInspector = try contents("Sources/Nous/Views/MemoryDebugInspector.swift")

        XCTAssertTrue(memoryInspector.contains("if RetiredFeaturePolicy.galaxyBackgroundWorkEnabled"))
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
