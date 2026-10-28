import SwiftUI

/// Networks and their conversations. Quiet on purpose: SF, no ornaments,
/// unread counts as plain figures, the blue pencil only for what's yours.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<UUID?>(
            get: { model.selectedBufferID },
            set: { id in
                guard let id else { return }
                for session in model.orderedSessions {
                    if let buffer = session.buffers.first(where: { $0.id == id }) {
                        model.select(buffer, in: session)
                        return
                    }
                }
            })
        List(selection: selection) {
            ForEach(model.orderedSessions) { session in
                Section {
                    NetworkRow(session: session)
                        .tag(session.statusBuffer.id)
                    if !(session.isBouncerControl && !session.bouncerNetworks.isEmpty) {
                        ForEach(model.sidebarBuffers(for: session)) { buffer in
                            BufferRow(session: session, buffer: buffer)
                                .tag(buffer.id)
                        }
                        let offline = session.buddies.filter { b in
                            session.buffer(named: b.nick, kind: .query, createIfMissing: false) == nil
                        }
                        ForEach(offline) { buddy in
                            BuddyRow(session: session, buddy: buddy)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.editingNetwork = NetworkConfig()
            } label: {
                Label("Add network", systemImage: "plus")
                    .font(Chrome.row)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct NetworkRow: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayName)
                    .font(Chrome.rowStrong)
                    .textCase(nil)
                if let state = stateText {
                    Text(state).font(Chrome.small).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if session.statusBuffer.unreadCount > 0 || session.statusBuffer.hasMention {
                Circle().fill(Palette.bluePencil).frame(width: 5, height: 5)
            }
        }
        .contextMenu {
            Button(session.wantsConnection ? String(localized: "Disconnect") : String(localized: "Connect")) { model.toggleConnection(session) }
            if let config = model.config(for: session) {
                Button("Edit network…") { model.editingNetwork = config }
                Button("Your profile…") { model.editingProfile = session }
                if session.config.parentID == nil {
                    Divider()
                    Button("Delete network", role: .destructive) { model.delete(config) }
                }
            }
            Divider()
            Button("Show protocol") {
                model.select(session.statusBuffer, in: session)
                model.showProtocolLog = true
            }
        }
    }

    private var stateText: String? {
        switch session.status {
        case .connected:
            if session.isBouncerControl { return String(localized: "\(session.bouncerNetworks.count) networks on the bouncer") }
            return session.isAway ? String(localized: "away") : nil
        case .connecting, .registering: return String(localized: "connecting…")
        case .waitingToReconnect: return String(localized: "reconnecting…")
        case .failed: return String(localized: "error")
        case .offline: return String(localized: "offline")
        }
    }
}

private struct BufferRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let buffer: Buffer

    var body: some View {
        HStack(spacing: 6) {
            if buffer.kind == .query {
                PresenceMark(online: buffer.peerOnline, away: buffer.peerAway)
            }
            Text(buffer.kind == .query ? model.shown(buffer.name) : buffer.name)
                .font(buffer.hasMention || buffer.unreadCount > 0 ? Chrome.rowStrong : Chrome.row)
                .foregroundStyle(buffer.isJoined || buffer.kind == .query ? .primary : .secondary)
                .lineLimit(1)
            if session.isMuted(buffer.name) {
                Image(systemName: "bell.slash").font(Chrome.small).foregroundStyle(.tertiary)
            }
            Spacer()
            if buffer.unreadCount > 0 {
                Text(verbatim: "\(buffer.unreadCount)")
                    .font((buffer.hasMention ? Chrome.smallStrong : Chrome.small).monospacedDigit())
                    .foregroundStyle(buffer.hasMention ? Palette.bluePencil : .secondary)
            }
        }
        .padding(.leading, 6)
        .contextMenu {
            Button(session.isPinned(buffer.name) ? String(localized: "Unpin") : String(localized: "Pin to top")) {
                session.setPinned(!session.isPinned(buffer.name), for: buffer.name)
            }
            Button(session.isMuted(buffer.name) ? String(localized: "Notify again") : String(localized: "Mute notifications")) {
                session.setMuted(!session.isMuted(buffer.name), for: buffer.name)
            }
            if buffer.kind == .channel {
                Button(session.isPresenceQuiet(buffer.name) ? String(localized: "Show joins and parts") : String(localized: "Hide joins and parts")) {
                    session.setPresenceQuiet(!session.isPresenceQuiet(buffer.name), for: buffer.name)
                }
            }
            Button("Mark as read") { session.markRead(buffer) }
            if buffer.kind == .query {
                Button(session.isBuddy(buffer.name) ? String(localized: "Remove from contacts") : String(localized: "Add to contacts")) {
                    if session.isBuddy(buffer.name) { session.removeBuddy(buffer.name) } else { session.addBuddy(buffer.name) }
                }
            }
            Divider()
            Button(buffer.kind == .channel ? String(localized: "Leave channel") : String(localized: "Close conversation")) {
                model.close(buffer, in: session)
            }
        }
    }
}

/// A buddy with no open conversation: click to start one.
private struct BuddyRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let buddy: Buddy

    var body: some View {
        Button {
            model.select(session.openQuery(buddy.nick), in: session)
        } label: {
            HStack(spacing: 6) {
                PresenceMark(online: buddy.online, away: buddy.away)
                Text(model.shown(buddy.nick))
                    .font(Chrome.row)
                    .foregroundStyle(buddy.online == true ? .primary : .tertiary)
                Spacer()
            }
            .padding(.leading, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove from contacts") { session.removeBuddy(buddy.nick) }
        }
    }
}

/// ● here, ◐ away, ○ gone, nothing when unknown.
struct PresenceMark: View {
    let online: Bool?
    let away: Bool

    var body: some View {
        Group {
            switch (online, away) {
            case (true?, true): Text(verbatim: "◐").help("Away")
            case (true?, false): Text(verbatim: "●").help("Online")
            case (false?, _): Text(verbatim: "○").help("Offline")
            default: Text(verbatim: "○").opacity(0.4).help("Status unknown")
            }
        }
        .font(.system(size: 8))
        .foregroundStyle(.secondary)
        .frame(width: 10)
    }
}
