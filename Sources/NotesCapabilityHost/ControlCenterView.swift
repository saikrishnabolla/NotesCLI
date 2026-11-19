import SwiftUI

struct ControlCenterView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case permissions = "Permissions"
        case connections = "Connections"
        case settings = "Settings"

        var id: Self { self }
        var detail: String {
            switch self {
            case .overview: "Use Apple Notes from your terminal and AI tools."
            case .permissions: "Manage what Notes CLI can access."
            case .connections: "Connect AI tools on this Mac or another device."
            case .settings: "Manage this installation of Notes CLI."
            }
        }
        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .permissions: "lock.shield"
            case .connections: "link"
            case .settings: "gearshape"
            }
        }
    }

    @ObservedObject var model: ControlCenterModel
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var page: Page = .overview

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                pageHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch page {
                        case .overview: overview
                        case .permissions: permissions
                        case .connections: connections
                        case .settings: maintenance
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 38)
                    .padding(.top, 3)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .id(page)
                feedback
            }
            .background(ControlCenterPalette.canvas)
            .clipShape(.rect(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(ControlCenterPalette.separator, lineWidth: 0.5) }
            .padding([.top, .trailing, .bottom], 8)
        }
        .background {
            if reduceTransparency || contrast == .increased {
                ControlCenterPalette.sidebar
            } else {
                ControlCenterChrome()
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .font(ControlCenterType.body)
        .buttonStyle(ControlCenterButtonStyle())
        .tint(.primary)
        .task { await model.refresh() }
        .alert("Uninstall Notes CLI?", isPresented: $model.showUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { Task { await model.uninstall() } }
        } message: {
            Text("This removes Notes CLI and the agent connections it manages. Your Apple Notes are not deleted.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("Notes CLI").font(ControlCenterType.brand)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                ForEach(Page.allCases.filter { $0 != .settings }) { destination in
                    navigationRow(destination)
                }
            }
            Spacer(minLength: 12)
            navigationRow(.settings)
        }
        .padding(.horizontal, 12)
        .padding(.top, 52)
        .padding(.bottom, 12)
        .frame(width: 218)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation")
    }

    private func navigationRow(_ destination: Page) -> some View {
        Button {
            page = destination
        } label: {
            HStack(spacing: 12) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 14, weight: page == destination ? .semibold : .medium))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(destination.rawValue)
                    .font(page == destination ? ControlCenterType.section : ControlCenterType.control)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlCenterNavigationStyle(selected: page == destination))
        .accessibilityAddTraits(page == destination ? .isSelected : [])
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(page.rawValue)
                    .font(ControlCenterType.title)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(ControlCenterButtonStyle(iconOnly: true))
                .accessibilityLabel("Refresh")
                .disabled(model.isRefreshing || model.activeAction != nil)
                .help("Check permissions and connections again")
            }
            Text(page.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, 38)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    @ViewBuilder private var feedback: some View {
        if let message = model.errorMessage ?? model.successMessage {
            Divider()
            Label(message, systemImage: model.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.errorMessage == nil ? Color.green : Color.orange)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var requiredPermissions: [PermissionStatus] { model.permissions.filter(\.required) }
    private var missingPermissions: [PermissionStatus] { requiredPermissions.filter { !$0.isGranted } }
    private var connectedCount: Int { model.agents.filter(\.connected).count }

    private var overview: some View {
        Group {
            SettingsGroup("Notes access") {
                SettingsLine(
                    symbol: model.hasChecked ? model.readiness.symbol : "clock",
                    title: overviewTitle, detail: overviewDetail
                ) {
                    if model.hasChecked {
                        Button(overviewAction) {
                            page = model.readiness == .ready ? .connections
                                : (missingPermissions.isEmpty ? .settings : .permissions)
                        }
                        .buttonStyle(ControlCenterButtonStyle(prominent: true))
                    }
                }
            }
            SettingsGroup("Try it") {
                SettingsLine(symbol: "doc.text", title: "Sample report",
                             detail: model.readiness == .ready
                             ? "Preview a table, checklist, diagram, and attachments in Notes."
                             : "Finish setup to create a formatted sample report in Notes.") {
                    ActionButton(title: "Create in Notes", actionID: "report", model: model,
                                 disabled: model.readiness != .ready) { await model.createSampleReport() }
                }
            }
        }
    }

    private var overviewTitle: String {
        if !model.hasChecked { return "Checking access…" }
        if model.readiness == .ready { return "Ready to use" }
        if model.errorMessage != nil { return "Couldn’t check access" }
        return missingPermissions.isEmpty ? "Check your setup" : "Finish setup"
    }

    private var overviewDetail: String {
        if !model.hasChecked {
            return "Looking for Notes access and agent connections."
        }
        if model.readiness == .ready {
            return connectedCount == 0 ? "Notes access is ready. Connect an agent to get started."
                : "\(connectedCount) agent \(connectedCount == 1 ? "connection" : "connections") configured on this Mac."
        }
        if let next = missingPermissions.first, model.errorMessage == nil {
            return "Allow \(next.name) for Notes CLI."
        }
        return "Notes access could not be verified. Check permissions or refresh to try again."
    }

    private var overviewAction: String {
        if model.readiness == .ready { return connectedCount == 0 ? "Connect an agent" : "Manage connections" }
        return missingPermissions.isEmpty ? "Check settings" : "Set up permissions"
    }

    private var permissions: some View {
        Group {
            SettingsGroup("Required access", footnote: model.hasChecked && !missingPermissions.isEmpty
                          ? "After granting access in System Settings, click Refresh here." : nil) {
                ForEach(requiredPermissions) { permission in
                    permissionRow(permission)
                    if permission.id != requiredPermissions.last?.id { Divider() }
                }
            }
            SettingsGroup("Optional access") {
                let optional = model.permissions.filter { !$0.required }
                ForEach(optional) { permission in
                    permissionRow(permission)
                    if permission.id != optional.last?.id { Divider() }
                }
            }
        }
    }

    private func permissionRow(_ permission: PermissionStatus) -> some View {
        let symbol = switch permission.id {
        case "fullDiskAccess": "internaldrive"
        case "notesAutomation": "note.text"
        case "speechRecognition": "waveform"
        case "camera": "camera"
        default: "lock.shield"
        }
        return SettingsLine(symbol: symbol, title: permission.name, detail: permission.purpose) {
            if permission.isGranted {
                Label("Allowed", systemImage: "checkmark.circle")
                    .font(ControlCenterType.detail)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if model.hasChecked && permission.status != "Checking" {
                        if permission.shouldRequest {
                            ActionButton(title: "Allow Access…", actionID: permission.id, model: model) {
                                await model.requestPermission(permission)
                            }
                        } else {
                            Button("Open Settings…") {
                                if let url = permission.settingsURL { openURL(url) }
                            }
                            .disabled(model.activeAction != nil || model.isRefreshing || permission.settingsURL == nil)
                        }
                    }
                    Text(permission.displayStatus)
                        .font(ControlCenterType.detail)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connections: some View {
        let available = model.agents.filter { $0.detected || $0.connected }
        let missing = model.agents.filter { !$0.detected && !$0.connected }
        return Group {
            SettingsGroup("AI tools", footnote: missing.isEmpty
                          ? nil : "Not found on this Mac: " + missing.map(\.name).joined(separator: ", ")) {
                if available.isEmpty {
                    SettingsLine(symbol: "link", title: "No supported tools found",
                                 detail: "Install a supported tool, then click Refresh.") { EmptyView() }
                }
                ForEach(available) { agent in
                    agentRow(agent)
                    if agent.id != available.last?.id { Divider() }
                }
            }
            remoteAccess
        }
    }

    private func agentRow(_ agent: AgentStatus) -> some View {
        SettingsLine(symbol: agent.connected ? "checkmark.circle" : "app",
                     title: agent.name,
                     detail: agent.connected ? (agent.detected ? "Configured" : "Configured · App not found") : "Not connected") {
            ActionButton(title: agent.connected ? "Disconnect" : "Connect", actionID: "agent-\(agent.id)", model: model) {
                await model.setAgent(agent, connected: !agent.connected)
            }
        }
    }

    private var remoteAccess: some View {
        SettingsGroup("Remote access") {
            SettingsLine(symbol: "network", title: "Tailscale",
                         detail: model.tailscaleConnected
                         ? model.tailscaleEndpoint ?? "Connected"
                         : "Not connected. Reach Notes CLI privately from another device.",
                         selectableDetail: model.tailscaleConnected) {
                ActionButton(title: model.tailscaleConnected ? "Remove" : "Set Up", actionID: "tailscale", model: model) {
                    await model.setTailscale(connected: !model.tailscaleConnected)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                SettingsLine(symbol: "lock", title: "Agent access",
                             detail: model.tailscaleReadOnly ? "Search and read notes."
                             : (model.tailscaleWriteFolders.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Write to any folder unless you set a limit."
                                : "Write only to the folders below.")) {
                    Picker("Agent access", selection: $model.tailscaleReadOnly) {
                        Text("Read only").tag(true)
                        Text("Read and write").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 216)
                    .disabled(model.activeAction != nil || model.isRefreshing)
                }
                if !model.tailscaleReadOnly {
                    TextField("Allowed folders, such as Notes > Oracle", text: $model.tailscaleWriteFolders)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 34)
                }
                if model.tailscaleConnected {
                    HStack {
                        Spacer()
                        ActionButton(title: "Apply Settings", actionID: "tailscale", model: model) {
                            await model.applyTailscaleSettings()
                        }
                    }
                }
            }
            .padding(.bottom, model.tailscaleConnected || !model.tailscaleReadOnly ? 12 : 0)
        }
    }

    private var maintenance: some View {
        SettingsGroup("Installation") {
            SettingsLine(symbol: "shippingbox", title: "Notes CLI", detail: model.version, selectableDetail: true) {
                ActionButton(title: "Repair Setup", actionID: "repair", model: model, disabled: !model.repairNeeded) {
                    await model.repair()
                }
            }
            Divider()
            SettingsLine(symbol: "trash", title: "Remove Notes CLI",
                         detail: "Removes managed connections. Your notes stay in place.") {
                Button("Uninstall…", role: .destructive) { model.showUninstallConfirmation = true }
                    .disabled(model.activeAction != nil || model.isRefreshing)
            }
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let footnote: String?
    @ViewBuilder let content: Content

    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(ControlCenterType.section).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .padding(.horizontal, 14)
                .background(ControlCenterPalette.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(ControlCenterPalette.separator, lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            if let footnote {
                Text(footnote).font(ControlCenterType.detail).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsLine<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var selectableDetail = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(ControlCenterType.control)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ControlCenterType.control).foregroundStyle(.primary)
                if selectableDetail {
                    Text(detail).textSelection(.enabled)
                } else {
                    Text(detail)
                }
            }
            .font(ControlCenterType.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: 0)
            trailing().fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 12)
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
        .disabled(disabled || model.activeAction != nil || model.isRefreshing)
    }
}
