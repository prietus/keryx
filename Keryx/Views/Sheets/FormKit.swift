import SwiftUI

/// Fields set like a printed form: a small-caps label over a ruled line,
/// instead of SwiftUI's grouped boxes.
struct RuledField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var prompt: LocalizedStringKey = ""
    var secure = false
    /// Grows to several lines (one entry per line).
    var multiline = false
    var note: LocalizedStringKey?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Typeset.note())
                .foregroundStyle(focused ? Palette.bluePencil : Palette.graphite)
            Group {
                if secure {
                    SecureField(prompt, text: $text)
                } else if multiline {
                    TextField(prompt, text: $text, axis: .vertical)
                        .lineLimit(2...8)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Typeset.body())
            .focused($focused)
            .padding(.bottom, 3)
            .overlay(alignment: .bottom) {
                Rectangle().fill(focused ? Palette.bluePencil : Palette.rule).frame(height: focused ? 1 : 0.5)
            }
            if let note {
                Text(note).font(Typeset.note()).foregroundStyle(Palette.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A choice between a few options, set as words: the chosen one in ink,
/// underlined in blue pencil; the others in graphite.
struct WordChoice<Value: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    let options: [(Value, LocalizedStringKey)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Typeset.note()).foregroundStyle(Palette.graphite)
            HStack(spacing: 18) {
                ForEach(options, id: \.0) { value, title in
                    Button {
                        selection = value
                    } label: {
                        Text(title)
                            .font(Typeset.body())
                            .foregroundStyle(selection == value ? Palette.ink : Palette.graphite)
                            .padding(.bottom, 2)
                            .overlay(alignment: .bottom) {
                                if selection == value { Rectangle().fill(Palette.bluePencil).frame(height: 1.5) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
        }
    }
}

/// A switch phrased as a statement you can tick.
struct Statement: View {
    let text: LocalizedStringKey
    @Binding var isOn: Bool
    var note: LocalizedStringKey?

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Typeset.body())
                if let note {
                    Text(note).font(Typeset.note()).foregroundStyle(Palette.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// A section heading in the form: a serif title over a hairline.
struct FormSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typeset.title()).foregroundStyle(Palette.ink)
                Rectangle().fill(Palette.rule).frame(height: 0.5)
            }
            content
        }
    }
}
