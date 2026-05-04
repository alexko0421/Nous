import AppKit
import SwiftUI

struct AgentWorkView: View {
    @Bindable var vm: BeadsAgentWorkViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    statusStrip
                    harnessSection
                    commandBar

                    if let errorMessage = vm.errorMessage {
                        errorBanner(errorMessage)
                    }

                    workSection(
                        title: "Now",
                        count: vm.snapshot.inProgress.count,
                        accent: AppColor.colaOrange,
                        issues: vm.snapshot.inProgress,
                        emptyText: "No active Beads work."
                    )

                    workSection(
                        title: "Next",
                        count: vm.snapshot.ready.count,
                        accent: Color(red: 0.16, green: 0.46, blue: 0.78),
                        issues: vm.snapshot.ready,
                        emptyText: "No ready Beads."
                    )

                    workSection(
                        title: "Recent Done",
                        count: vm.snapshot.recentClosed.count,
                        accent: Color(red: 0.16, green: 0.54, blue: 0.36),
                        issues: vm.snapshot.recentClosed,
                        emptyText: "No recently closed Beads."
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.colaBeige)
        .onAppear {
            if !vm.hasLoaded {
                vm.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text("Agent Work")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText)

                    boundaryPill("Read-only")
                }

                Text("Engineering memory only. Nous memory stays separate.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
            }

            Spacer()

            Button(action: { vm.refresh() }) {
                HStack(spacing: 7) {
                    if vm.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Refresh")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(AppColor.colaDarkText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(NativeGlassPanel(cornerRadius: 12, tintColor: AppColor.controlGlassTint) { EmptyView() })
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppColor.panelStroke.opacity(0.55), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isLoading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func boundaryPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(AppColor.colaOrange)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(AppColor.colaOrange.opacity(0.12))
            )
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                metric("Now", vm.snapshot.inProgress.count, color: AppColor.colaOrange)
                metric("Next", vm.snapshot.ready.count, color: Color(red: 0.16, green: 0.46, blue: 0.78))
                metric("Done", vm.snapshot.recentClosed.count, color: Color(red: 0.16, green: 0.54, blue: 0.36))

                Spacer(minLength: 12)

                if vm.snapshot.hasLoaded {
                    Text("Updated \(vm.snapshot.loadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.colaOrange)

                Text(vm.snapshot.beadsPath.isEmpty ? "Beads path unavailable" : vm.snapshot.beadsPath)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Image(systemName: vm.errorMessage == nil ? "lock.shield" : "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(vm.errorMessage == nil ? Color(red: 0.16, green: 0.54, blue: 0.36) : AppColor.colaOrange)

                Text(BeadsAgentWorkSetupHint.message(
                    errorMessage: vm.errorMessage,
                    beadsPath: vm.snapshot.beadsPath
                ))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(NativeGlassPanel(cornerRadius: 20, tintColor: AppColor.surfaceGlassTint) { EmptyView() })
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColor.panelStroke.opacity(0.52), lineWidth: 1)
        }
    }

    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Harness")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)

                Text(vm.snapshot.harness.buildStatus.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(harnessColor(vm.snapshot.harness.buildStatus))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(harnessColor(vm.snapshot.harness.buildStatus).opacity(0.12))
                    )
            }

            HStack(alignment: .top, spacing: 10) {
                harnessStatusCard(
                    title: "Build",
                    systemImage: harnessIcon(vm.snapshot.harness.buildStatus),
                    color: harnessColor(vm.snapshot.harness.buildStatus),
                    primary: vm.snapshot.harness.statusText,
                    secondary: harnessDetailText(vm.snapshot.harness)
                )

                harnessStatusCard(
                    title: "Runtime",
                    systemImage: runtimeIcon(vm.snapshot.runtimeHarness),
                    color: runtimeColor(vm.snapshot.runtimeHarness),
                    primary: vm.snapshot.runtimeHarness.statusText,
                    secondary: runtimeDetailText(vm.snapshot.runtimeHarness)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Founder Loop")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)

                ForEach(vm.snapshot.harness.founderLoopSummary, id: \.self) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(AppColor.colaOrange.opacity(0.72))
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)

                        Text(item)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(AppColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.surfaceGlassTint) { EmptyView() })
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColor.panelStroke.opacity(0.50), lineWidth: 1)
        }
    }

    private func harnessStatusCard(
        title: String,
        systemImage: String,
        color: Color,
        primary: String,
        secondary: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)

                Text(primary)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(secondary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(NativeGlassPanel(cornerRadius: 14, tintColor: AppColor.controlGlassTint) { EmptyView() })
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.panelStroke.opacity(0.42), lineWidth: 1)
        }
    }

    private func harnessDetailText(_ snapshot: HarnessHealthSnapshot) -> String {
        if snapshot.findingTitles.isEmpty {
            return snapshot.latestRun?.detail.isEmpty == false ? snapshot.latestRun?.detail ?? "" : "No local harness findings."
        }
        return snapshot.findingTitles.joined(separator: " · ")
    }

    private func runtimeDetailText(_ snapshot: RuntimeHarnessSnapshot) -> String {
        [
            snapshot.reviewerCoverageText,
            snapshot.riskFlagSummary,
            snapshot.agentToolReliability.summaryText,
            snapshot.behaviorEval.summaryText,
            snapshot.contextManifest.summaryText,
            snapshot.modelHarnessProfiles.summaryText,
            snapshot.sycophancyFixtureTrend
        ].joined(separator: " · ")
    }

    private func harnessColor(_ status: HarnessBuildStatus) -> Color {
        switch status {
        case .passed:
            return Color(red: 0.16, green: 0.54, blue: 0.36)
        case .failed:
            return Color(red: 0.74, green: 0.18, blue: 0.14)
        case .needsQuickGate:
            return AppColor.colaOrange
        case .needsFullGate:
            return AppColor.colaOrange
        case .neverRun:
            return AppColor.secondaryText
        }
    }

    private func harnessIcon(_ status: HarnessBuildStatus) -> String {
        switch status {
        case .passed:
            return "checkmark.shield"
        case .failed:
            return "xmark.shield"
        case .needsQuickGate:
            return "shield.lefthalf.filled"
        case .needsFullGate:
            return "shield.lefthalf.filled"
        case .neverRun:
            return "shield"
        }
    }

    private func runtimeColor(_ snapshot: RuntimeHarnessSnapshot) -> Color {
        if !snapshot.modelHarnessProfiles.isComplete {
            return AppColor.colaOrange
        }
        if snapshot.agentToolReliability.unknownErrorCount > 0 {
            return AppColor.colaOrange
        }
        if !snapshot.lastRiskFlags.isEmpty {
            return AppColor.colaOrange
        }
        if snapshot.totalTurnCount == 0 {
            return AppColor.secondaryText
        }
        return Color(red: 0.16, green: 0.54, blue: 0.36)
    }

    private func runtimeIcon(_ snapshot: RuntimeHarnessSnapshot) -> String {
        if !snapshot.modelHarnessProfiles.isComplete {
            return "exclamationmark.bubble"
        }
        if snapshot.agentToolReliability.unknownErrorCount > 0 {
            return "exclamationmark.bubble"
        }
        if !snapshot.lastRiskFlags.isEmpty {
            return "exclamationmark.bubble"
        }
        if snapshot.totalTurnCount == 0 {
            return "waveform.path.ecg"
        }
        return "brain.head.profile"
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Copy Commands")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)

                Text("\(BeadsAgentWorkCommand.defaultCommands.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(AppColor.colaDarkText.opacity(0.06))
                    )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 176), spacing: 8)], spacing: 8) {
                ForEach(BeadsAgentWorkCommand.defaultCommands) { command in
                    commandButton(command)
                }
            }
        }
        .padding(14)
        .background(NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.surfaceGlassTint) { EmptyView() })
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColor.panelStroke.opacity(0.50), lineWidth: 1)
        }
    }

    private func commandButton(_ command: BeadsAgentWorkCommand) -> some View {
        Button(action: { copyToPasteboard(command.command) }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColor.colaOrange)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(AppColor.colaOrange.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(command.title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText)

                    Text(command.command)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(command.detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText.opacity(0.88))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(NativeGlassPanel(cornerRadius: 14, tintColor: AppColor.controlGlassTint) { EmptyView() })
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.panelStroke.opacity(0.42), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Copy \(command.command)")
    }

    private func metric(_ title: String, _ count: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColor.secondaryText)

            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .monospacedDigit()
        }
    }

    private func workSection(
        title: String,
        count: Int,
        accent: Color,
        issues: [BeadsIssue],
        emptyText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)

                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.12))
                    .clipShape(Capsule())
            }

            if issues.isEmpty {
                emptyRow(emptyText)
            } else {
                VStack(spacing: 8) {
                    ForEach(issues) { issue in
                        BeadsIssueRow(issue: issue, accent: accent)
                    }
                }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(AppColor.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint) { EmptyView() })
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.panelStroke.opacity(0.40), lineWidth: 1)
            }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.colaOrange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Beads is not ready")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText)

                    Text(BeadsAgentWorkSetupHint.message(
                        errorMessage: message,
                        beadsPath: vm.snapshot.beadsPath
                    ))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText.opacity(0.78))
                }
            }

            HStack(spacing: 8) {
                Button(action: { copyToPasteboard("scripts/setup_beads_agent_memory.sh --install") }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Copy setup install")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppColor.colaDarkText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(AppColor.subtleFill)
                    )
                }
                .buttonStyle(.plain)

                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppColor.colaOrange.opacity(0.12))
        )
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct BeadsIssueRow: View {
    let issue: BeadsIssue
    let accent: Color
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: { isExpanded.toggle() }) {
                    HStack(alignment: .top, spacing: 12) {
                        priorityBadge

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(issue.id)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(accent)

                                statusPill
                            }

                            Text(issue.title)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppColor.colaDarkText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppColor.secondaryText)
                            .padding(.top, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: { copyToPasteboard("bd show \(issue.id)") }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(AppColor.subtleFill)
                        )
                }
                .buttonStyle(.plain)
                .help("Copy bd show command")
            }

            if isExpanded {
                details
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.surfaceGlassTint) { EmptyView() })
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent.opacity(0.72))
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColor.panelStroke.opacity(0.50), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.16), value: isExpanded)
    }

    private var priorityBadge: some View {
        Text("P\(issue.priority)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 34, height: 24)
            .background(
                Capsule()
                    .fill(accent)
            )
    }

    private var statusPill: some View {
        Text(issue.status.replacingOccurrences(of: "_", with: " "))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(AppColor.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(AppColor.colaDarkText.opacity(0.06))
            )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !trimmed(issue.description).isEmpty {
                Text(issue.description)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let closeReason = issue.closeReason, !trimmed(closeReason).isEmpty {
                detailBlock(title: "Close Summary", text: closeReason)
            }

            if !issue.dependencies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dependencies")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)

                    ForEach(issue.dependencies) { dependency in
                        Text(dependencyLabel(dependency))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(AppColor.colaDarkText.opacity(0.74))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            HStack(spacing: 8) {
                if let issueType = issue.issueType {
                    metadataPill(issueType)
                }
                if let assignee = issue.assignee {
                    metadataPill(assignee)
                }
                metadataPill("\(issue.commentCount) comments")
                if let date = displayDate(issue.closedAt ?? issue.startedAt ?? issue.updatedAt) {
                    metadataPill(date)
                }
            }
        }
        .padding(.leading, 46)
    }

    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.secondaryText)

            Text(text)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func metadataPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(AppColor.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(AppColor.subtleFill)
            )
    }

    private func dependencyLabel(_ dependency: BeadsDependency) -> String {
        let title = dependency.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let relation = dependency.relation.map { " \($0)" } ?? ""
        if title.isEmpty || title == dependency.id {
            return "\(dependency.id)\(relation)"
        }
        return "\(dependency.id)  \(title)\(relation)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
