import SwiftUI

struct CommandFeedbackView: View {
    let initialCommand: String
    let requestID: UUID?
    @State private var reviewedRequestID: UUID?
    @State private var heard = ""
    @State private var intended = ""
    @State private var cause = CommandCorrection.Cause.unknown
    @State private var status = ""
    @State private var saving = false
    var body: some View {
        NoirSectionHeading(title: "Correct a command")
        NoirCard(padded: true) {
            TextField("What Jarvis heard", text: $heard)
            TextField("What you meant or expected", text: $intended)
            Picker("Where it went wrong", selection: $cause) {
                ForEach(CommandCorrection.Cause.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Text("Saved only on this Mac for review. Corrections do not change the model or start training.")
                .font(.system(size: 11)).foregroundStyle(NoirPalette.secondary)
            Button(saving ? "Saving…" : "Save correction") {
                saving = true
                let correction = CommandCorrection(requestID: reviewedRequestID, heard: heard, intended: intended, cause: cause)
                Task {
                    do { try await correction.save(); status = "Correction saved for review."; intended = "" }
                    catch { status = error.localizedDescription }
                    saving = false
                }
            }.disabled(saving || heard.isEmpty || intended.isEmpty)
            if !status.isEmpty { Text(status).font(.system(size: 11)) }
        }.onAppear { if heard.isEmpty { heard = initialCommand; reviewedRequestID = requestID } }
    }
}
