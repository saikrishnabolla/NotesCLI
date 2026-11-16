import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var model: ControlCenterModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                messages
                permissions
                agents
                remoteAccess
                sampleReport
                maintenance
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(minWidth: 680, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
        .alert("Uninstall Notes CLI?", isPresented: $model.showUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { Task { await model.uninstall() } }
        } message: {
            Text("This removes Notes CLI and the agent connections it manages. Your Apple Notes are not deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: model.readiness.symbol)
                .font(.system(size: 34))
                .foregroundStyle(readinessColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes CLI")
                    .font(.largeTitle.weight(.semibold))
                Text(model.readiness.rawValue)
                    .font(.title3.weight(.medium))
                Text(model.readinessDetail)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                if model.isRefreshing { ProgressView().controlSize(.small) }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(model.isRefreshing || model.activeAction != nil)
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let success = model.successMessage {
            Label(success, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    private var permissions: some View {
        SectionBox(title: "Permissions", subtitle: "Grant access once so terminals and agents do not each need separate permission.") {
            ForEach(model.permissions) { permission in
                StatusRow(
                    symbol: permission.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    symbolColor: permission.isGranted ? .green : .orange,
                    title: permission.name,
                    detail: permission.status.capitalized + (permission.required ? " · Required" : " · Optional")
                )
                if permission.id != model.permissions.last?.id { Divider() }
            }
            HStack {
                Spacer()
                ActionButton(title: "Review Permissions", actionID: "permissions", model: model) {
                    await model.requestPermissions()
                }
            }
        }
    }

    private var agents: some View {
        SectionBox(title: "Agents", subtitle: "Connect Notes CLI to the tools installed on this Mac.") {
            ForEach(model.agents) { agent in
                HStack(spacing: 12) {
                    Image(systemName: agent.connected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(agent.connected ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                        Text(agent.detected ? agent.detail : "Not detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ActionButton(
                        title: agent.connected ? "Disconnect" : "Connect",
                        actionID: "agent-\(agent.id)",
                        model: model,
                        disabled: !agent.detected && !agent.connected
                    ) {
                        await model.setAgent(agent, connected: !agent.connected)
                    }
                }
                if agent.id != model.agents.last?.id { Divider() }
            }
        }
    }

    private var remoteAccess: some View {
        SectionBox(title: "Remote access", subtitle: "Use Tailscale to reach Notes CLI privately from another machine.") {
            HStack(spacing: 12) {
                Image(systemName: model.tailscaleConnected ? "network.badge.shield.half.filled" : "network")
                    .foregroundStyle(model.tailscaleConnected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.tailscaleConnected ? "Connected" : "Not connected")
                    if let endpoint = model.tailscaleEndpoint {
                        Text(endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                ActionButton(title: model.tailscaleConnected ? "Remove" : "Set Up", actionID: "tailscale", model: model) {
                    await model.setTailscale(connected: !model.tailscaleConnected)
                }
            }
        }
    }

    private var sampleReport: some View {
        SectionBox(title: "Try Notes CLI", subtitle: "Create a polished research note with headings, a table, links, an image, a diagram, tags, a checklist, and an attachment.") {
            HStack {
                Label("Sample research report", systemImage: "doc.text.image")
                Spacer()
                ActionButton(title: "Create in Notes", actionID: "report", model: model) {
                    await model.createSampleReport()
                }
            }
        }
    }

    private var maintenance: some View {
        SectionBox(title: "Maintenance", subtitle: "Version \(model.version)") {
            HStack {
                Label(model.repairNeeded ? "Repair recommended" : "Installation is current", systemImage: model.repairNeeded ? "wrench.and.screwdriver" : "checkmark.seal")
                Spacer()
                ActionButton(title: "Repair", actionID: "repair", model: model, disabled: !model.repairNeeded) {
                    await model.repair()
                }
                Button("Uninstall…", role: .destructive) { model.showUninstallConfirmation = true }
                    .disabled(model.activeAction != nil)
            }
        }
    }

    private var readinessColor: Color {
        switch model.readiness {
        case .ready: .green
        case .limited: .orange
        case .needsAttention: .red
        }
    }
}

private struct SectionBox<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        }
    }
}

private struct StatusRow: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(symbolColor)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let actionID: String
    @ObservedObject var model: ControlCenterModel
    var disabled = false
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            if model.activeAction == actionID {
                ProgressView().controlSize(.small).frame(minWidth: 64)
            } else {
                Text(title)
            }
        }
        .disabled(disabled || model.activeAction != nil)
    }
}
