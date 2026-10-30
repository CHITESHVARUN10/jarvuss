import Foundation

struct CommandTestStep: Codable {
    let action: String
    let success: Bool
    let message: String
}

struct CommandTestEvent: Codable {
    let stage: String
    let message: String
}

struct CommandTestRun: Codable, Identifiable {
    let id: UUID
    let command: String
    let mode: String
    let startedAt: Date
    var state = "running"
    var outcome = "running"
    var elapsedMs = 0
    var requestID: UUID?
    var plan: [String] = []
    var steps: [CommandTestStep] = []
    var output = ""
    var events: [CommandTestEvent] = []
    var review = "unreviewed"
    var notes = ""
    let revision: String
    let rustPipeline: Bool
}

@MainActor
final class CommandTestTrace {
    let requestID = UUID()
    var outcome = "failure"
    var plan: [String] = []
    var steps: [CommandTestStep] = []
    var events: [CommandTestEvent] = []
    func record(_ stage: String, _ message: String) { events.append(CommandTestEvent(stage: stage, message: message)) }
}
