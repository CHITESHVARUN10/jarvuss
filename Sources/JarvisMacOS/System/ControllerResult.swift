import Foundation

enum EffectVerification: String, Sendable {
    case verified, submitted, unavailable, failed
}

struct ControllerResult: Sendable {
    let message: String
    let success: Bool
    let verification: EffectVerification
    init(message: String, success: Bool, verification: EffectVerification? = nil) {
        self.message = message; self.success = success
        self.verification = success ? (verification ?? .submitted) : .failed
    }
}
