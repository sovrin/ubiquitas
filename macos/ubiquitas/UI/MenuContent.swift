import AppKit
import Paritas
import SwiftUI

/// Menu bar panel, built from the shared Paritas components.
struct MenuContent: View {
    @ObservedObject var hub: Hub
    @State private var copied = false

    var body: some View {
        MenuPanel {
            PanelHeader("ubiquitas", status: status, icon: Image(systemName: "display.2"), colors: [.cyan, .blue])
            if !hub.hasInputAccess {
                WarningCard("No input access", message: "Allow ubiquitas under Accessibility to share keyboard and mouse.") {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    Button("Check Again") { hub.checkInputAccess() }
                }
            }
            PanelDivider()
            screens
            PanelDivider()
            PanelSection("Share This Mac's") {
                switchRow("Keyboard", systemImage: "keyboard", isOn: $hub.shareKeyboard)
                switchRow("Mouse", systemImage: "computermouse", isOn: $hub.shareMouse)
            }
            PanelDivider()
            PanelSection("Shared Text") {
                TextEditor(text: Binding(get: { hub.clip }, set: { hub.editClip($0) }))
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 84)
                    .background(Color.primary.opacity(PanelMetrics.fill),
                                in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
                    .accessibilityLabel("Shared text, editable on every computer")
                    .padding(.horizontal, PanelMetrics.inset)
                    .padding(.bottom, 4)
            }
            if !hub.status.isEmpty {
                PanelDivider()
                recent
            }
            PanelDivider()
            PanelFooter(appName: "ubiquitas")
        }
    }

    private var others: [Screen] { hub.screens.filter { $0.online && $0.name != hub.me } }

    private var status: String {
        let n = others.count
        if n == 0 { return "Waiting for clients · port \(Wire.port)" }
        var text = "\(n) \(n == 1 ? "client" : "clients") connected"
        if !hub.isLocal { text += " · input on \(hub.active)" }
        return text
    }

    // MARK: Screens

    private var screens: some View {
        PanelSection("Screens") {
            ArrangementView(hub: hub)
                .frame(height: 120)
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.bottom, 4)
            Text("Drag to arrange · ⌃⌥K switches screens")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.bottom, 4)
            ForEach(hub.screens) { screenRow($0) }
            Button(action: copyClientCommand) {
                Label(copied ? "Copied — run it on the other computer" : "Copy Client Command",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Copies the command, including the key, that connects a computer to this Mac")
            .padding(.horizontal, PanelMetrics.rowInset)
        }
    }

    private func screenRow(_ s: Screen) -> some View {
        let isMe = s.name == hub.me
        return HoverRow {
            if s.online { hub.switchTo(s.name) }
        } content: {
            Circle()
                .fill(s.online ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .frame(width: 19)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.name).lineLimit(1)
                Text(verbatim: isMe ? "This Mac" : s.online ? "\(s.w) × \(s.h)" : "Offline") // no thousands separators
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if s.name == hub.active { RowBadge("Input") }
        } actions: {
            if s.online && !isMe {
                RoundIconButton(systemImage: "paperplane", help: "Send a file to \(s.name)") { pickFile(to: s.name) }
            }
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .help(s.online ? "Move keyboard and mouse to \(s.name)" : "\(s.name) is offline")
        .contextMenu {
            Button("Switch Here") { hub.switchTo(s.name) }.disabled(!s.online)
            if !isMe { Button("Send File…") { pickFile(to: s.name) }.disabled(!s.online) }
        }
    }

    private func pickFile(to name: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { hub.sendFile($0, to: name) }
    }

    private func copyClientCommand() {
        Pasteboard.copy(hub.clientCommand)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
    }

    private func switchRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .padding(.horizontal, PanelMetrics.rowInset)
    }

    // MARK: Recent

    private var recent: some View {
        Button {
            if let url = hub.lastReceived { showInFinder(url) }
        } label: {
            Label(hub.status, systemImage: hub.lastReceived == nil ? "info.circle" : "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle())
        .disabled(hub.lastReceived == nil)
        .help(hub.lastReceived == nil ? hub.status : "Show in Finder")
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 3)
    }
}
