import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var words = ""

    var body: some View {
        @Bindable var prefs = model.preferences
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                FormSection(title: "Reading") {
                    WordChoice(label: "Typeface", selection: $prefs.serifType, options: [
                        (false, "System (SF)"), (true, "Serif (New York)"),
                    ])
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body text").font(Typeset.note()).foregroundStyle(Palette.graphite)
                        HStack {
                            Slider(value: $prefs.bodySize, in: 12...20, step: 1).frame(width: 220)
                            Text(verbatim: "\(Int(prefs.bodySize)) pt").font(Typeset.margin()).foregroundStyle(Palette.graphite)
                        }
                        (Text(verbatim: "teraflops").font(Typeset.speaker(prefs.bodySize))
                            + Text("   This is how a line of the script reads.").font(Typeset.body(prefs.bodySize)))
                            .padding(.top, 4)
                    }
                    Statement(text: "Show joins and parts", isOn: $prefs.showPresence,
                              note: "They’re folded into a single stage direction. Hide them per channel with /joins.")
                    Statement(text: "Nick changes only for people who spoke", isOn: $prefs.presenceOnlyForSpeakers)
                    Statement(text: "Nicks in colour", isOn: $prefs.colorNicks,
                              note: "Each person keeps the same colour. Mentions of you stay in blue.")
                    Statement(text: "Link previews", isOn: $prefs.linkFootnotes,
                              note: "A card under the line with the page’s title, summary and picture.")
                    if prefs.linkFootnotes {
                        Statement(text: "Without the summary", isOn: $prefs.compactPreviews)
                    }
                    Statement(text: "Images in the conversation", isOn: $prefs.inlineImages,
                              note: "Images and videos. Keryx fetches links to find out what they are; videos never play by themselves.")
                    if prefs.inlineImages {
                        Statement(text: "Play animated GIFs", isOn: $prefs.animateGIFs,
                                  note: "With Reduce Motion on in macOS, they stay still and play on hover.")
                        WordChoice(label: "Image size", selection: $prefs.imageSize, options: [
                            (96, "Small"), (160, "Medium"), (280, "Large"),
                        ])
                    }
                }

                FormSection(title: "Notifications") {
                    Statement(text: "When you’re mentioned", isOn: $prefs.notifyMentions)
                    Statement(text: "Private messages", isOn: $prefs.notifyDirect)
                    RuledField(label: "Words that mention you besides your nick", text: $words,
                               prompt: "keryx project", note: "Separated by spaces. Whole words, ignoring case.")
                        .onSubmit { prefs.highlightWords = words.split(separator: " ").map(String.init) }
                        .onChange(of: words) { _, new in prefs.highlightWords = new.split(separator: " ").map(String.init) }
                }

                FormSection(title: "Writing") {
                    Statement(text: "Let others know while you type", isOn: $prefs.sendTyping,
                              note: "Sends +typing; others see your name as the script’s next cue.")
                }

                FormSection(title: "Files") {
                    Statement(text: "Use the network’s file server when it has one", isOn: $prefs.preferServerFileHost,
                              note: "FILEHOST (soju and others), with your SASL credentials.")
                    RuledField(label: "Custom uploader", text: $prefs.uploaderURL, prompt: "https://0x0.st",
                               note: "Used when the network has no file server, or always if the option above is off. Leave empty to use only the network’s.")
                    HStack(alignment: .top, spacing: 24) {
                        RuledField(label: "Form field", text: $prefs.uploaderField,
                                   note: "Empty sends the file as is.")
                        RuledField(label: "Response", text: $prefs.uploaderResponse,
                                   note: "text, location or json:key.path")
                    }
                    RuledField(label: "Token", text: $prefs.uploaderToken, secure: true, note: "Sent as Bearer.")
                }

                FormSection(title: "Privacy") {
                    Statement(text: "Keep history on this Mac", isOn: $prefs.keepHistory,
                              note: "So conversations open instantly; the server stays the source.")
                    Statement(text: "Privacy mode", isOn: $prefs.privacyMode,
                              note: "Masks every nick with a stable pseudonym, for screenshots. ⌘⇧P")
                }
            }
            .padding(36)
        }
        .frame(width: 600, height: 640)
        .background(Palette.paper)
        .onAppear { words = model.preferences.highlightWords.joined(separator: " ") }
    }
}
