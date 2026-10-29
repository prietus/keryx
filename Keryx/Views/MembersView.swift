import SwiftUI
import KeryxProtocol

/// The cast: who's in the channel, by role.
struct MembersView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let buffer: Buffer
    @State private var filter = ""

    private var groups: [(String, [Member])] {
        let members = buffer.sortedMembers.filter {
            filter.isEmpty || $0.nick.localizedCaseInsensitiveContains(filter)
                || ($0.realname?.localizedCaseInsensitiveContains(filter) ?? false)
        }
        let ops = members.filter { $0.sortRank <= 3 }
        let voiced = members.filter { $0.sortRank == 4 }
        let rest = members.filter { $0.sortRank == 5 }
        return [(String(localized: "Operators"), ops), (String(localized: "Voiced"), voiced), (String(localized: "Everyone else"), rest)].filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List {
                ForEach(groups, id: \.0) { title, members in
                    Section(String(localized: "\(title) (\(members.count))")) {
                        ForEach(members) { member in
                            MemberRow(member: member, session: session, buffer: buffer)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
        }
        .onAppear { session.loadMembersIfNeeded(buffer) }
    }
}

private struct MemberRow: View {
    @Environment(AppModel.self) private var model
    let member: Member
    let session: Session
    let buffer: Buffer

    private var amOp: Bool {
        buffer.members.first { session.equal($0.nick, session.currentNick) }.map { $0.sortRank <= 3 } ?? false
    }

    var body: some View {
        let meta = session.metadata(for: member.nick)
        HStack(spacing: 8) {
            if model.preferences.inlineImages, let avatar = session.avatarURL(for: member.nick) {
                AsyncImage(url: avatar) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(member.prefixes.isEmpty ? "" : String(member.prefixes.prefix(1)))
                        .font(Chrome.small.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    Text(model.shown(member.nick))
                        .font(Chrome.row)
                        .italic(member.isAway)
                        .foregroundStyle(model.color(for: member.nick, isSelf: session.equal(member.nick, session.currentNick)))
                        .opacity(member.isAway ? 0.55 : 1)
                    if member.isBot {
                        Text("bot").font(Chrome.small).foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.tertiary, lineWidth: 0.5))
                    }
                    if session.isDimmed(member.nick) {
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                let sub = [meta["display-name"], meta["pronouns"]].compactMap { $0 }
                if !sub.isEmpty {
                    Text(sub.joined(separator: ", "))
                        .font(Chrome.small)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 13)
                }
            }
        }
        .help([member.realname, member.account.map { String(localized: "Account: \($0)") },
               member.host.map { "\(member.user ?? "*")@\($0)" }, member.isAway ? String(localized: "Away") : nil]
            .compactMap { $0 }.joined(separator: "\n"))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.select(session.openQuery(member.nick), in: session) }
        .contextMenu {
            Button("Private conversation") { model.select(session.openQuery(member.nick), in: session) }
            Button("Profile") { session.requestWhois(member.nick) }
            Button(session.isBuddy(member.nick) ? String(localized: "Remove from contacts") : String(localized: "Add to contacts")) {
                if session.isBuddy(member.nick) { session.removeBuddy(member.nick) } else { session.addBuddy(member.nick) }
            }
            Divider()
            Button(session.isDimmed(member.nick) ? String(localized: "Stop dimming") : String(localized: "Dim")) {
                session.setDimmed(!session.isDimmed(member.nick), member.nick)
            }
            if let rule = session.plainIgnore(for: member.nick) {
                Button("Stop ignoring") { session.unignore(rule) }
            } else if let mask = IgnoreMask(parsing: member.nick) {
                Button("Ignore") { session.ignore(mask) }
            }
            if amOp {
                Divider()
                let has = member.prefixes
                Button(has.contains("@") ? String(localized: "Take operator") : String(localized: "Give operator")) {
                    model.submit(has.contains("@") ? "/deop \(member.nick)" : "/op \(member.nick)", in: buffer, of: session, replyTo: nil)
                }
                Button(has.contains("+") ? String(localized: "Take voice") : String(localized: "Give voice")) {
                    model.submit(has.contains("+") ? "/devoice \(member.nick)" : "/voice \(member.nick)", in: buffer, of: session, replyTo: nil)
                }
                Button("Kick", role: .destructive) {
                    model.submit("/kick \(member.nick)", in: buffer, of: session, replyTo: nil)
                }
            }
        }
    }
}
