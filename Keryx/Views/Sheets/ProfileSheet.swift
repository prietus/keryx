import SwiftUI

/// Your profile on one network (`draft/metadata-2`): what others see next to
/// your nick. Saved on this Mac and published on every connect, since servers
/// needn't keep it.
struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var fields: [String: String]

    init(session: Session) {
        self.session = session
        _fields = State(initialValue: session.state.profile)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your profile on \(session.displayName)").font(Typeset.title())
                        Text(session.supportsProfile
                             ? "Shown next to your nick to people whose client reads profiles (draft/metadata-2)."
                             : "This server doesn’t share profiles (draft/metadata-2). soju doesn’t relay them; Ergo does. Keryx keeps what you write here and publishes it wherever it can.")
                            .font(Typeset.note())
                            .foregroundStyle(session.supportsProfile ? Palette.graphite : Palette.redPencil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        RuledField(label: "Display name", text: binding("display-name"))
                        RuledField(label: "Pronouns", text: binding("pronouns"), prompt: "she/her, they/them…")
                    }
                    RuledField(label: "Status", text: binding("status"), prompt: "Working on Keryx")
                    RuledField(label: "Homepage", text: binding("homepage"), prompt: "https://")
                    RuledField(label: "Avatar", text: binding("avatar"), prompt: "https://…/avatar.png",
                               note: "The address of an image. Others see it next to your nick in the member list.")
                }
                .padding(32)
            }
            Rectangle().fill(Palette.rule).frame(height: 0.5)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    session.setProfile(fields)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .background(Palette.paper)
    }
}
