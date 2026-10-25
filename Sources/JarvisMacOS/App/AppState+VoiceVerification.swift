import AppKit
import Foundation

extension AppState {
    func verifyThenRunCommand(_ command: String, capturedAudio: URL? = nil) async {
        defer { if let capturedAudio { try? FileManager.default.removeItem(at: capturedAudio) } }
        guard voiceProfileReady else {
            voiceVerificationStatus = "Voice Profile Incomplete ⚠️"
            if presentsUI {
                popupManager.show(message: "Enroll in Voice to use verified commands.", icon: "person.wave.2", duration: 7)
            }
            appendLog("[Voice] dropped: profile not ready (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget)) — command '\(command)' rejected.")
            statsRecorder.recordCommand(success: false)
                    dbManager.saveEvent(
                eventType: "voice_profile_incomplete",
                transcript: command,
                matched: false,
                metadata: [
                    "backend_samples": String(backendEnrollmentSampleCount),
                    "sample_target": String(voiceEnrollmentSampleTarget)
                ]
            )
            return
        }

        do {
            let result = try await attemptVerification(capturedAudio: capturedAudio)
            try Task.checkCancellation()

            let wakeWordDetected = TranscriptSanitizer.containsWakeWord(lastRecognizedSpeech)
            let effectiveThreshold = wakeWordDetected ? 0.65 : voiceVerificationThreshold
            let isVerifiedByThreshold = result.similarity >= effectiveThreshold

            appendLog("[Voice] verify: sim=\(fmtScore(result.similarity)) " +
                      "max=\(fmtScore(result.maxSimilarity)) avg=\(fmtScore(result.avgSimilarity)) " +
                      "conf=\(result.confidence.rawValue) n=\(result.samplesCompared) " +
                      "thr=\(fmtScore(effectiveThreshold)) wake=\(wakeWordDetected ? "yes" : "no") " +
                      "cmd='\(command)'")

            switch result.confidence {
            case .strong:
                voiceVerificationStatus = "Verified (Strong) ✅"
                lastVoiceSimilarity = result.similarity
                appendLog("[Voice] Verified (strong). Score: \(fmtScore(result.similarity)) " +
                          "[max: \(fmtScore(result.maxSimilarity)), avg: \(fmtScore(result.avgSimilarity)), " +
                          "samples: \(result.samplesCompared)]")
                extendSessionTimeout(forCommand: command)
                await runCommand(command)

            case .low:
                if isVerifiedByThreshold {
                    voiceVerificationStatus = "Verified (Low Confidence) ⚠️"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Verified (low confidence). Score: \(fmtScore(result.similarity)) " +
                              "[max: \(fmtScore(result.maxSimilarity)), avg: \(fmtScore(result.avgSimilarity)), threshold: \(fmtScore(effectiveThreshold))]")
                    dbManager.saveEvent(
                        eventType: "voice_low_confidence",
                        transcript: command,
                        score: result.similarity,
                        matched: true,
                        metadata: [
                            "confidence": "low",
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                    extendSessionTimeout(forCommand: command)
                    await runCommand(command)
                } else {
                    voiceVerificationStatus = "Unknown Voice ❌"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Rejected by threshold. Score: \(fmtScore(result.similarity)) < \(fmtScore(effectiveThreshold)) — need ≥ \(fmtScore(effectiveThreshold)) to run; re-enroll in a quiet room if this persists.")
                    if voiceSessionState == .active {
                        appendLog("[VoiceSession] In-session command '\(command)' rejected due to failed verification. Session timer unchanged.")
                    }
                    statsRecorder.recordCommand(success: false)
                    dbManager.saveEvent(
                        eventType: "voice_rejected",
                        transcript: command,
                        score: result.similarity,
                        matched: false,
                        normalizedCommand: command,
                        metadata: [
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                }

            case .rejected:
                if isVerifiedByThreshold {
                    voiceVerificationStatus = "Verified (Wake Word Relaxed) ⚠️"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Wake-word threshold pass. Score: \(fmtScore(result.similarity)) >= \(fmtScore(effectiveThreshold))")
                    dbManager.saveEvent(
                        eventType: "voice_low_confidence",
                        transcript: command,
                        score: result.similarity,
                        matched: true,
                        metadata: [
                            "confidence": "rejected_override",
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                    extendSessionTimeout(forCommand: command)
                    await runCommand(command)
                } else {
                    voiceVerificationStatus = "Unknown Voice ❌"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Rejected. Score: \(fmtScore(result.similarity)) " +
                              "[max: \(fmtScore(result.maxSimilarity)), avg: \(fmtScore(result.avgSimilarity)), threshold: \(fmtScore(effectiveThreshold))] — need ≥ \(fmtScore(effectiveThreshold)) to run.")
                    if voiceSessionState == .active {
                        appendLog("[VoiceSession] In-session command '\(command)' rejected due to failed verification. Session timer unchanged.")
                    }
                    statsRecorder.recordCommand(success: false)
                    dbManager.saveEvent(
                        eventType: "voice_rejected",
                        transcript: command,
                        score: result.similarity,
                        matched: false,
                        normalizedCommand: command,
                        metadata: [
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                }

            case .none:
                voiceVerificationStatus = "No Voice Profile ❌"
                lastVoiceSimilarity = 0
                appendLog("[Voice] No stored voice profile. Command rejected.")
            }
        } catch let authError {
            guard !Task.isCancelled else { return }
            // Fix #10: Auth failure — single attempt only.
            // Preserve transport vs HTTP rejection. Required verification
            // never becomes implicit permission to execute while offline.
            let isNetworkError = VoiceAuthClient.isUnavailable(authError)

            if isNetworkError {
                await handleVerificationUnavailable(command)
            } else {
                // Non-network error (e.g. audio capture failure) — hard reject, no retry.
                voiceVerificationStatus = "Unknown Voice ❌"
                appendLog("[Voice] Verification error: \(authError.localizedDescription). Command rejected.")
                statsRecorder.recordCommand(success: false)
                    dbManager.saveEvent(
                    eventType: "voice_verification_error",
                    transcript: command,
                    matched: false,
                    metadata: ["error": authError.localizedDescription]
                )
            }
        }
    }

    /// Single verification attempt — exports the most recent utterance-length
    /// audio window at 16 kHz and calls backend. Silence clips (RMS below
    /// verifyMinClipRMS) are rejected locally: the backend would 400 them
    /// and Resemblyzer would embed noise, so never POST them.
    func attemptVerification(capturedAudio: URL? = nil) async throws -> VoiceVerificationResult {
        let sampleURL = try capturedAudio ?? micManager.exportRecentAudioSample(
            durationSeconds: Self.verifyAudioSeconds,
            targetSampleRate: Self.voiceSampleRate
        )
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        let rms = Self.clipRMS(ofWavAt: sampleURL)
        guard rms >= Self.verifyMinClipRMS else {
            appendLog("[Voice] dropped: verify clip is silence (rms \(String(format: "%.4f", rms))) — backend skipped.")
            throw MicManagerError.insufficientAudio
        }
        guard await BackendServiceManager.ensureRunningForFeature() else {
            throw URLError(.cannotConnectToHost)
        }
        try Task.checkCancellation()
        return try await voiceAuthClient.verifyDetailed(audioFileURL: sampleURL)
    }

    /// Required verification fails closed. Users can explicitly select
    /// wake-word-only mode by disabling verification in settings.
    private func handleVerificationUnavailable(_ command: String) async {
        guard !Task.isCancelled else { return }
        voiceVerificationStatus = "Verification unavailable"
        if presentsUI {
            popupManager.show(message: "Enable the Python helper in Setup to verify voice commands.", icon: "shield.slash", duration: 6)
        }
        appendLog("[Voice] Command rejected: required speaker verification is unavailable.")
        statsRecorder.recordCommand(success: false)
        dbManager.saveEvent(eventType: "voice_auth_unavailable", transcript: command,
                            matched: false, metadata: ["reason": "verification_required"])
    }

    /// RMS of a WAV file's samples (float32 mono written by MicManager).
    /// Returns 0 when the file can't be read — treated as silence upstream.
    static func clipRMS(ofWavAt url: URL) -> Float {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return 0 }
        let samples = data.dropFirst(44)
        let count = samples.count / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        var squareSum: Float = 0
        samples.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            for i in 0..<count { squareSum += ptr[i] * ptr[i] }
        }
        return sqrt(squareSum / Float(count))
    }

    func fmtScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

}
