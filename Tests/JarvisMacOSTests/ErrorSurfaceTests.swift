import XCTest
@testable import JarvisMacOS

/// The LLM failure contract: transport errors are marked, classified, and
/// never presented as model output. Regression for the ⌘⇧A run that showed
/// "error sending request for url (…/api/generate)" as if it were an answer.
final class ErrorSurfaceTests: XCTestCase {

    func testFailuresAreRecognizable() {
        XCTAssertTrue(OllamaClient.isFailure("Ollama error: error sending request for url (http://127.0.0.1:11434/api/generate). Make sure Ollama is running."))
        XCTAssertTrue(OllamaClient.isFailure("Ollama error: HTTP 404. Make sure Ollama is running."))
        XCTAssertFalse(OllamaClient.isFailure("There are 12 folders in your Downloads folder."))
        XCTAssertFalse(OllamaClient.isFailure("Ollama is a great tool."))
    }

    func testUserFacingMessageIsActionable() {
        let message = OllamaClient.unavailableMessage
        XCTAssertTrue(message.contains("Ollama"))
        XCTAssertFalse(message.lowercased().contains("error sending request"),
                       "raw transport text must not reach the card or the speaker")
    }
}
