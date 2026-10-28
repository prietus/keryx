import SwiftUI
import UniformTypeIdentifiers

struct NetworkEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var network: NetworkConfig
    @State private var port: String
    @State private var channels: String
    @State private var saslPassword: String
    @State private var serverPassword: String
    @State private var certPassphrase: String
    @State private var certError: String?
    @State private var fingerprint: String?
    @State private var importing = false
    private let isNew: Bool

    init(network: NetworkConfig) {
        _network = State(initialValue: network)
        _port = State(initialValue: String(network.port))
        _channels = State(initialValue: network.autoJoinChannels.joined(separator: " "))
        _saslPassword = State(initialValue: network.saslPassword ?? "")
        _serverPassword = State(initialValue: network.serverPassword ?? "")
        _certPassphrase = State(initialValue: network.certificatePassphrase ?? "")
        isNew = network.host.isEmpty
    }

    private struct Preset { var name: String; var host: String; var channels: String }
    private let presets = [
        Preset(name: "Libera.Chat", host: "irc.libera.chat", channels: "#libera"),
        Preset(name: "OFTC", host: "irc.oftc.net", channels: "#oftc"),
        Preset(name: "Ergo", host: "irc.ergo.chat", channels: "#ergo"),
    ]

    private var canSave: Bool {
        !network.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !network.nickname.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isNew ? String(localized: "New network") : network.displayName)
                            .font(Typeset.title())
                        if isNew {
                            HStack(spacing: 16) {
                                Text("Start with").font(Typeset.direction())
                                    .foregroundStyle(Palette.graphite)
                                ForEach(presets, id: \.host) { preset in
                                    Button(preset.name) {
                                        network.name = preset.name
                                        network.host = preset.host
                                        port = "6697"
                                        network.useTLS = true
                                        channels = preset.channels
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }
                    }

                    FormSection(title: "Server") {
                        HStack(alignment: .top, spacing: 24) {
                            RuledField(label: "Name", text: $network.name, prompt: "Libera")
                            RuledField(label: "Address", text: $network.host, prompt: "irc.example.org")
                                .frame(minWidth: 220)
                            RuledField(label: "Port", text: $port).frame(width: 70)
                        }
                        HStack(spacing: 28) {
                            Statement(text: "Encrypted connection (TLS)", isOn: $network.useTLS)
                            Statement(text: "It’s a soju bouncer", isOn: $network.isBouncer,
                                      note: "Shows each of the bouncer’s networks on its own.")
                        }
                        if network.useTLS {
                            Statement(text: "Accept unverified certificates", isOn: $network.allowInvalidCertificates,
                                      note: "Only for your own servers with a self-signed certificate.")
                        }
                    }

                    FormSection(title: "Identity") {
                        HStack(alignment: .top, spacing: 24) {
                            RuledField(label: "Nick", text: $network.nickname)
                            RuledField(label: "Username", text: $network.username, prompt: "same as nick")
                            RuledField(label: "Real name", text: $network.realName, prompt: "same as nick")
                        }
                        RuledField(label: "Server password", text: $serverPassword, secure: true,
                                   note: "Rarely needed. Stored in the keychain.")
                    }

                    FormSection(title: "Authentication") {
                        WordChoice(label: "SASL method", selection: $network.saslMode, options: [
                            (.none, "None"), (.plain, "Password"), (.external, "Certificate (CertFP)"),
                        ])
                        switch network.saslMode {
                        case .none:
                            EmptyView()
                        case .plain:
                            HStack(alignment: .top, spacing: 24) {
                                RuledField(label: "Account", text: $network.saslAccount, prompt: "same as nick")
                                RuledField(label: "Password", text: $saslPassword, secure: true,
                                           note: "If the server offers SCRAM-SHA-256 it’s used instead: the password never travels.")
                            }
                        case .external:
                            certificate
                        }
                    }

                    FormSection(title: "On connect") {
                        RuledField(label: "Channels", text: $channels, prompt: "#rust #swift",
                                   note: network.isBouncer ? "With a bouncer this is rarely needed: it remembers your channels." as LocalizedStringKey : nil)
                        Statement(text: "Connect when Keryx opens", isOn: $network.autoConnect)
                    }
                }
                .padding(36)
            }
            Rectangle().fill(Palette.rule).frame(height: 0.5)
            HStack {
                if !isNew {
                    Button("Delete network", role: .destructive) {
                        model.delete(network)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? String(localized: "Connect") : String(localized: "Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 660, height: 680)
        .background(Palette.paper)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, .pkcs12]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            network.certificateData = try? Data(contentsOf: url)
            checkCertificate()
        }
        .onAppear(perform: checkCertificate)
    }

    @ViewBuilder
    private var certificate: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button(network.certificateData == nil ? String(localized: "Import .p12 certificate…") : String(localized: "Change certificate…")) {
                    importing = true
                }
                if network.certificateData != nil {
                    Button("Remove") {
                        network.certificateData = nil
                        fingerprint = nil
                    }
                    .buttonStyle(.link)
                }
            }
            RuledField(label: "Certificate passphrase", text: $certPassphrase, secure: true)
                .onChange(of: certPassphrase) { _, _ in checkCertificate() }
            if let fingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256 fingerprint").font(Typeset.note()).foregroundStyle(Palette.graphite)
                    Text(fingerprint).font(Typeset.code()).textSelection(.enabled)
                    Text("Register it on the network: /msg NickServ CERT ADD \(String(fingerprint.prefix(12)))…")
                        .font(Typeset.note()).foregroundStyle(Palette.graphite)
                }
            }
            if let certError {
                Text(certError).font(Typeset.note()).foregroundStyle(Palette.redPencil)
            }
        }
    }

    private func checkCertificate() {
        guard let data = network.certificateData else {
            fingerprint = nil
            certError = nil
            return
        }
        do {
            fingerprint = try TLSIdentity(pkcs12: data, passphrase: certPassphrase).sha256Fingerprint
            certError = nil
        } catch {
            fingerprint = nil
            certError = error.localizedDescription
        }
    }

    private func save() {
        network.host = network.host.trimmingCharacters(in: .whitespaces)
        network.nickname = network.nickname.trimmingCharacters(in: .whitespaces)
        network.port = Int(port) ?? 6697
        network.autoJoinChannels = channels.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        network.saslPassword = saslPassword
        network.serverPassword = serverPassword
        network.certificatePassphrase = certPassphrase
        model.save(network)
        dismiss()
    }
}
