import SwiftUI
import Tokens
import ClientModel

/// 连接 macOS server：host / port / token，连接状态与错误走 `SessionModel`。
struct ConnectionSetupView: View {
    @Bindable var session: SessionModel

    private struct Server: Equatable {
        var host: String
        var port: String
        var token: String
    }

    @State private var recent: Server?
    @State private var isTokenVisible = false

    var body: some View {
        Form {
            if session.phase == .connected {
                Section {
                    LabeledContent("Server", value: "\(session.host):\(session.port)")
                    LabeledContent("Items", value: "\(session.items.count)")
                }
            }

            Section {
                LabeledContent("Host") {
                    TextField("Host", text: $session.host, prompt: Text("192.168.1.20"))
                        .multilineTextAlignment(.trailing)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connection.host")
                }
                LabeledContent("Port") {
                    TextField("Port", text: $session.port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("connection.port")
                }
            }
            .disabled(session.phase == .connecting)

            Section {
                HStack {
                    if isTokenVisible {
                        TextField("Token", text: $session.token)
                            .accessibilityIdentifier("connection.token")
                    } else {
                        SecureField("Token", text: $session.token)
                            .accessibilityIdentifier("connection.token")
                    }
                    Button {
                        isTokenVisible.toggle()
                    } label: {
                        Image(systemName: isTokenVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isTokenVisible ? "Hide token" : "Show token")
                    .accessibilityIdentifier("connection.tokenVisibility")
                }
            } footer: {
                Text("The server prints the token when `appctl serve` starts.")
            }
            .disabled(session.phase == .connecting)

            if let recent {
                Section {
                    Button {
                        session.host = recent.host
                        session.port = recent.port
                        session.token = recent.token
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use Last Server")
                                Text(recent.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                    }
                }
            }

            if let notice = session.notice {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: notice.severity == .error
                              ? "exclamationmark.triangle"
                              : "info.circle")
                            .font(.title2)
                            .foregroundStyle(notice.severity == .error
                                             ? AnyShapeStyle(.red)
                                             : AnyShapeStyle(.secondary))
                        Text(notice.message)
                            .font(PhotonType.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PhotonSpacing.noticeVertical)
                }
            }
            Section {
                Button(action: connect) {
                    HStack(spacing: 8) {
                        if session.phase == .connecting {
                            ProgressView()
                        }
                        Text(session.phase == .connecting ? "Connecting…" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!session.isConfigured || session.phase == .connecting)
                .accessibilityIdentifier("connection.connect")

                // DEBUG-only 调试入口：一键填入本机调试 server，省去手抄 token。
                #if DEBUG
                Button {
                    session.host = "192.168.10.2"
                    session.port = "8787"
                    session.token = "debug-token"
                    connect()
                } label: {
                    Text("Debug Quick Connect")
                        .frame(maxWidth: .infinity)
                }
                .disabled(session.phase == .connecting)
                #endif
            }
        }
        .safeAreaBar(edge: .bottom) {
            statusBar
        }
        .onChange(of: session.phase) { _, phase in
            // 只有真正连上之后才记下这组设置。
            if phase == .connected {
                recent = Server(host: session.host, port: session.port, token: session.token)
            }
        }
    }

    private func connect() {
        Task { await session.connect() }
    }

    private var statusBar: some View {
        Label(statusText, systemImage: statusSymbol)
            .font(PhotonType.footnote)
            .foregroundStyle(statusStyle)
            .frame(maxWidth: .infinity)
            .padding(PhotonSpacing.panel)
            .background(PhotonPalette.chrome)
    }

    private var statusText: String {
        switch session.phase {
        case .unconfigured: "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .error: "Connection failed"
        }
    }

    private var statusSymbol: String {
        switch session.phase {
        case .unconfigured: "circle"
        case .connecting: "circle.dotted"
        case .connected: "circle.fill"
        case .error: "exclamationmark.circle"
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch session.phase {
        case .unconfigured, .connecting: AnyShapeStyle(.secondary)
        case .connected: AnyShapeStyle(.green)
        case .error: AnyShapeStyle(.red)
        }
    }
}

#Preview {
    ConnectionSetupView(session: SessionModel())
        .frame(width: 280, height: 600)
}
