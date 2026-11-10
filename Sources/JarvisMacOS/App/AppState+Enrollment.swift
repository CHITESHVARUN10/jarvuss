import AppKit
import Foundation

extension AppState {
    func startEnrollment(resetStore: Bool = true) {
        guard !enrollmentActive, !enrollmentPreparing, !voiceProfileResetting else { return }
        voiceProfileError = nil
        enrollmentSessionID = UUID()
        enrollmentPaused = false
        enrollmentMessage = "Preparing microphone and voice storage…"
        enrollmentPreparing = true
        enrollmentActive = true
        voiceVerificationStatus = "Preparing Voice Enrollment…"
        enrollmentPreparationTask = Task {
            guard await prepareVoiceBackend(), !Task.isCancelled else {
                if !Task.isCancelled {
                    enrollmentPreparing = false
                    enrollmentActive = false
                    enrollmentMessage = "Voice storage is unavailable. Check the native helper in Settings → Local services, then try again."
                    voiceVerificationStatus = "Backend unavailable"
                    appendLog("[Voice] Enrollment not started — backend unavailable/off. Existing profile preserved.")
                }
                return
            }
            do {
                if resetStore { try await voiceAuthClient.reset() }
                try Task.checkCancellation()
                if resetStore {
                    backendEnrollmentSampleCount = 0
                    persistBackendSampleCount(0)
                }
                enrollmentPreparing = false
                beginEnrollmentCapture()
            } catch {
                guard !Task.isCancelled else { return }
                enrollmentPreparing = false
                enrollmentActive = false
                enrollmentMessage = "Enrollment could not start: \(error.localizedDescription)"
                voiceVerificationStatus = "Enrollment could not start"
                appendLog("[Voice] Enrollment aborted: \(error.localizedDescription)")
            }
        }
    }

    private func beginEnrollmentCapture(resetProgress: Bool = true) {
        if resetProgress {
            enrollmentIndex = 0
            enrollmentMatchedCount = 0
            enrollmentAttemptCount = 0
            enrollmentCurrentPhraseMatchCount = 0
            enrollmentAwaitingNextPhrase = false
        }
        enrollmentPaused = false
        enrollmentMessage = enrollmentAwaitingNextPhrase
            ? "All three samples captured. Continue when you’re ready."
            : "Read this phrase, then pause briefly between repetitions."
        latestEnrollmentScore = 0
        voiceModeEnabled = false
        voiceVerificationStatus = "Building Voice Profile..."
        lastEnrollmentAcceptedAt = .distantPast
        enrollmentActive = true
        enrollmentCompleted = false
        persistEnrollmentCompleted(false)
        appendLog("Voice enrollment started. Repeat each phrase \(enrollmentRequiredMatchesPerPhrase)x.")

        // Enrollment captures from the live mic pipeline, so it must not
        // depend on the user already having a listening session running
        // (the old flow greyed the button out until ⌘⇧D had brought the mic
        // up). Bring the mic up here when idle; `releaseEnrollmentMicIfNeeded`
        // returns it to idle when enrollment ends — listening stays manual.
        if micActive {
            // A one-shot pill may hold a transient mic right when Enroll is
            // pressed; adopt it so the pill's teardown can't stop capture
            // under the live enrollment.
            if micTransientAutoStart {
                micTransientAutoStart = false
                micStartedForEnrollment = true
            }
        } else {
            micStartedForEnrollment = true
            appendLog("Microphone started for enrollment.")
            Task {
                await startMicrophone()
                if !enrollmentActive {
                    releaseEnrollmentMicIfNeeded()
                } else if !micActive {
                    appendLog("[Voice] Enrollment can't capture — microphone failed to start.")
                    stopEnrollment()
                }
            }
        }
    }

    /// Prepare and reset the store before accepting any new audio samples.
    func retrainVoiceProfile() {
        startEnrollment()
    }

    func resetVoiceProfile() {
        guard !enrollmentActive, !voiceProfileResetting else { return }
        voiceProfileResetting = true
        voiceProfileError = nil
        Task {
            defer { voiceProfileResetting = false }
            guard await prepareVoiceBackend() else {
                voiceProfileError = "Profile was not cleared: voice storage is unavailable."
                appendLog("[Voice] Profile clear skipped — backend unavailable/off.")
                return
            }
            do {
                try await voiceAuthClient.reset()
                backendEnrollmentSampleCount = 0
                persistBackendSampleCount(0)
                enrollmentCompleted = false
                persistEnrollmentCompleted(false)
                enrollmentPaused = false
                enrollmentIndex = 0
                enrollmentMatchedCount = 0
                enrollmentCurrentPhraseMatchCount = 0
                enrollmentAwaitingNextPhrase = false
                voiceModeEnabled = false
                voiceVerificationStatus = "No Voice Profile ❌"
                appendLog("Voice profile cleared (0/\(voiceEnrollmentSampleTarget)). Re-enroll to rebuild.")
            } catch {
                voiceProfileError = "Profile was not cleared: \(error.localizedDescription)"
                appendLog("[Voice] Profile reset failed: \(error.localizedDescription)")
            }
        }
    }

    func stopEnrollment() {
        let canResume = enrollmentActive && !enrollmentPreparing && enrollmentIndex < enrollmentPhrases.count
        enrollmentSessionID = UUID()
        enrollmentSampleTask?.cancel()
        enrollmentSampleTask = nil
        enrollmentSavingSample = false
        enrollmentPreparationTask?.cancel()
        enrollmentPreparationTask = nil
        enrollmentPreparing = false
        enrollmentActive = false
        if canResume { enrollmentPaused = true }
        releaseEnrollmentMicIfNeeded()
        appendLog("Voice enrollment paused.")
    }

    func resumeEnrollment() {
        guard enrollmentPaused, !enrollmentActive, !enrollmentPreparing, !voiceProfileResetting else { return }
        enrollmentSessionID = UUID()
        enrollmentPreparing = true
        enrollmentActive = true
        enrollmentPreparationTask = Task {
            guard await prepareVoiceBackend(), !Task.isCancelled else {
                if !Task.isCancelled {
                    enrollmentPreparing = false
                    enrollmentActive = false
                    enrollmentMessage = "Voice storage is unavailable. Check the native helper in Settings → Local services, then resume."
                }
                return
            }
            enrollmentPreparing = false
            beginEnrollmentCapture(resetProgress: false)
        }
    }

    func advanceEnrollmentPhrase() {
        guard enrollmentActive, enrollmentAwaitingNextPhrase, !enrollmentSavingSample,
              enrollmentIndex + 1 < enrollmentPhrases.count else { return }
        enrollmentIndex += 1
        enrollmentCurrentPhraseMatchCount = 0
        enrollmentAwaitingNextPhrase = false
        enrollmentMessage = "Read this phrase, then pause briefly between repetitions."
    }

    /// True when enrollment started the mic itself (Enroll/Retrain pressed
    /// with listening idle). Like the hotkey pills, the mic goes back down
    /// when enrollment ends — a user-started session is never touched.

    /// Returns the mic to idle when enrollment was its only reason to exist.
    func releaseEnrollmentMicIfNeeded() {
        guard micStartedForEnrollment else { return }
        micStartedForEnrollment = false
        guard micActive else { return }
        appendLog("Enrollment finished — mic back to idle (listening stays manual).")
        stopMicrophone()
    }

    func handleEnrollmentTranscript(_ transcript: String, isFinal: Bool) {
        guard enrollmentActive, !enrollmentPreparing, !enrollmentSavingSample,
              !enrollmentAwaitingNextPhrase, isFinal else { return }
        let cleanedTranscript = normalizeEnrollmentTranscript(transcript)
        guard !cleanedTranscript.isEmpty else { return }
        guard enrollmentPhrases.indices.contains(enrollmentIndex) else { return }

        let now = Date()

        enrollmentAttemptCount += 1

        let target = enrollmentPhrases[enrollmentIndex]
        let score = phraseMatchScore(target: target, recognized: cleanedTranscript)
        latestEnrollmentScore = score

        let requiredTokens = requiredIntentTokens(for: target)
        let recognizedTokenSet = Set(TranscriptSanitizer.normalizedTokens(from: cleanedTranscript))
        let requiredTokenHits = requiredTokens.filter { recognizedTokenSet.contains($0) }.count
        let requiredTokenRatio: Double = requiredTokens.isEmpty ? 0 : Double(requiredTokenHits) / Double(requiredTokens.count)

        let requiredScore = 0.48
        let keywordGate = requiredTokens.count <= 2 ? requiredTokenHits >= 1 : requiredTokenRatio >= 0.60
        let matched = keywordGate && score >= requiredScore

        dbManager.saveEvent(
            eventType: "enrollment_attempt",
            transcript: cleanedTranscript,
            targetPhrase: target,
            score: score,
            matched: matched,
            phraseIndex: enrollmentIndex + 1,
            metadata: [
                "is_final": String(isFinal),
                "required_token_hits": String(requiredTokenHits),
                "required_token_ratio": String(format: "%.2f", requiredTokenRatio),
                "required_token_count": String(requiredTokens.count)
            ]
        )

        if matched {
            if now.timeIntervalSince(lastEnrollmentAcceptedAt) < enrollmentAcceptCooldown {
                return
            }

            // A separate final utterance may legitimately repeat exactly the
            // same phrase. The cooldown and in-flight gate prevent duplicate
            // events; comparing text would reject repetitions two and three.
            lastEnrollmentAcceptedAt = now
            let phraseNumber = enrollmentIndex + 1
            let repetition = enrollmentCurrentPhraseMatchCount + 1
            let sessionID = enrollmentSessionID
            enrollmentSavingSample = true
            enrollmentMessage = "Saving sample \(repetition) of \(enrollmentRequiredMatchesPerPhrase)…"
            enrollmentSampleTask = Task {
                defer {
                    if enrollmentSessionID == sessionID {
                        enrollmentSavingSample = false
                        enrollmentSampleTask = nil
                    }
                }
                do {
                    let count = try await enrollMatchedVoiceSample(phraseNumber: phraseNumber,
                        repetition: repetition, transcript: cleanedTranscript)
                    guard !Task.isCancelled, enrollmentSessionID == sessionID, enrollmentActive else { return }
                    guard count > backendEnrollmentSampleCount else { throw URLError(.badServerResponse) }
                    backendEnrollmentSampleCount = count
                    persistBackendSampleCount(count)
                    enrollmentMatchedCount += 1
                    enrollmentCurrentPhraseMatchCount += 1
                    dbManager.saveEvent(eventType: "enrollment_match", transcript: cleanedTranscript,
                        targetPhrase: enrollmentPhrases[enrollmentIndex], score: score, matched: true,
                        phraseIndex: phraseNumber, metadata: ["match_count_total": String(enrollmentMatchedCount),
                            "match_count_phrase": String(enrollmentCurrentPhraseMatchCount)])
                    enrollmentMessage = "Sample saved. Repeat this same phrase."
                    if enrollmentCurrentPhraseMatchCount >= enrollmentRequiredMatchesPerPhrase {
                        if enrollmentIndex + 1 == enrollmentPhrases.count {
                            enrollmentActive = false
                            enrollmentPaused = false
                            enrollmentCompleted = true
                            persistEnrollmentCompleted(true)
                            voiceVerificationStatus = voiceProfileReady ? "Voice Enrolled ✅" : "Voice Profile Incomplete ⚠️"
                            enrollmentMessage = voiceProfileReady ? "Your voice profile is ready." : "Some samples are missing. Please retrain your profile."
                            releaseEnrollmentMicIfNeeded()
                            dbManager.saveEvent(eventType: "enrollment_completed", transcript: cleanedTranscript,
                                matched: voiceProfileReady, phraseIndex: enrollmentPhrases.count)
                        } else {
                            enrollmentAwaitingNextPhrase = true
                            enrollmentMessage = "All three samples captured. Continue when you’re ready."
                        }
                    }
                } catch {
                    guard !Task.isCancelled, enrollmentSessionID == sessionID else { return }
                    enrollmentMessage = "Sample could not be saved. Please repeat this phrase."
                    appendLog("[Voice] Sample not saved: \(error.localizedDescription)")
                }
            }

        } else {
            enrollmentMessage = "That didn’t match. Please repeat the phrase shown above."
            appendLog("Phrase mismatch (score: \(String(format: "%.2f", score)), token-hit: \(requiredTokenHits)/\(requiredTokens.count)). Please repeat phrase \(enrollmentIndex + 1).")
        }
    }

    /// Boot fast-path: UserDefaults only, never touches the DB (sync psql
    /// from @MainActor deadlocked boot in __DISPATCH_WAIT_FOR_QUEUE__).
    /// The DB reconcile runs async right after (see reconcileEnrollmentFromDB).
    func restoreEnrollmentStateFast() {
        let defaultsFlag = UserDefaults.standard.bool(forKey: Self.enrollmentCompletedDefaultsKey)
        let savedBackendCount = UserDefaults.standard.integer(forKey: Self.backendSampleCountDefaultsKey)

        backendEnrollmentSampleCount = savedBackendCount

        if defaultsFlag {
            enrollmentCompleted = true
            enrollmentActive = false
            appendLog("Enrollment restored from saved state.")
            if savedBackendCount >= voiceEnrollmentSampleTarget {
                voiceVerificationStatus = "Voice Enrolled ✅"
            } else if savedBackendCount > 0 {
                voiceVerificationStatus = "Finalizing Voice Profile..."
            }
        }
    }

    /// Background reconcile: if the DB has an enrollment_completed event we
    /// never persisted locally (fresh profile, wiped defaults), adopt it.
    func reconcileEnrollmentFromDB() async {
        guard !enrollmentCompleted else { return }
        guard dbManager.isConfigured else { return }
        if await dbManager.hasEnrollmentCompletionEvent() {
            enrollmentCompleted = true
            enrollmentActive = false
            persistEnrollmentCompleted(true)
            appendLog("Enrollment restored from saved state.")
        }
    }

    func persistEnrollmentCompleted(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.enrollmentCompletedDefaultsKey)
    }

    func persistBackendSampleCount(_ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.backendSampleCountDefaultsKey)
    }

    func syncVoiceProfileStatusFromBackend() async {
        do {
            let enrolledCount = try await voiceAuthClient.enrolledCount()
            backendEnrollmentSampleCount = enrolledCount
            persistBackendSampleCount(enrolledCount)

            if enrollmentCompleted {
                if enrolledCount >= voiceEnrollmentSampleTarget {
                    voiceVerificationStatus = "Voice Enrolled ✅"
                    appendLog("Voice profile restored from backend (\(enrolledCount)/\(voiceEnrollmentSampleTarget)).")
                } else if enrolledCount > 0 {
                    voiceVerificationStatus = "Voice Profile Incomplete ⚠️"
                    appendLog("Enrollment restored, but backend voice samples are incomplete (\(enrolledCount)/\(voiceEnrollmentSampleTarget)).")
                } else {
                    voiceVerificationStatus = "Voice Profile Missing ⚠️"
                    appendLog("Enrollment restored but backend voice profile is empty. Run enrollment once to rebuild speaker samples.")
                }
            }
        } catch {
            if backendEnrollmentSampleCount >= voiceEnrollmentSampleTarget {
                voiceVerificationStatus = "Voice Enrolled ✅"
            }
            appendLog("Voice backend stats unavailable. Using saved profile state (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget)).")
        }
    }

    func phraseMatchScore(target: String, recognized: String) -> Double {
        let targetTokens = Set(TranscriptSanitizer.normalizedTokens(from: target))
        let recognizedTokens = Set(TranscriptSanitizer.normalizedTokens(from: recognized))
        guard !targetTokens.isEmpty else { return 0 }

        let tokenIntersection = targetTokens.intersection(recognizedTokens).count
        let tokenScore = Double(tokenIntersection) / Double(targetTokens.count)

        let targetNormalized = target.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let recognizedNormalized = recognized.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)

        let maxLen = max(targetNormalized.count, recognizedNormalized.count)
        guard maxLen > 0 else { return tokenScore }

        let distance = StringDistance.levenshtein(targetNormalized, recognizedNormalized)
        let charScore = 1.0 - (Double(distance) / Double(maxLen))

        return (0.6 * tokenScore) + (0.4 * max(0.0, charScore))
    }

    func enrollMatchedVoiceSample(phraseNumber: Int, repetition: Int, transcript: String) async throws -> Int {
        let sampleURL = try micManager.exportRecentAudioSample(
            durationSeconds: Self.enrollAudioSeconds, targetSampleRate: Self.voiceSampleRate)
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        try Task.checkCancellation()
        let count = try await voiceAuthClient.enroll(audioFileURL: sampleURL)
        appendLog("Voice sample stored for phrase \(phraseNumber) rep \(repetition) (backend: \(count)/\(voiceEnrollmentSampleTarget)).")
        dbManager.saveEvent(eventType: "voice_enroll_sample", transcript: transcript, matched: true,
            phraseIndex: phraseNumber, metadata: ["repetition": String(repetition), "backend_count": String(count)])
        return count
    }

    /// Floating result panel: shows a short answer (time, date, brightness)
    /// in a global NSPanel above ALL apps — the in-window PopupView only
    /// renders when Jarvis is frontmost, so background ⌘⇧A answers were
    /// invisible. Auto-dismisses after 3 s. Callers also mirror into
    /// ResponseEngine so the main window shows it when frontmost.
    func normalizeEnrollmentTranscript(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let lowered = cleaned.lowercased()
        if let range = lowered.range(of: "jarvis", options: .backwards) {
            return String(cleaned[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tokens = TranscriptSanitizer.normalizedTokens(from: cleaned)
        if tokens.count > 14 {
            return tokens.suffix(14).joined(separator: " ")
        }

        return cleaned
    }

    func requiredIntentTokens(for phrase: String) -> [String] {
        let stopWords: Set<String> = [
            "jarvis", "the", "a", "an", "to", "please"
        ]
        let tokens = TranscriptSanitizer.normalizedTokens(from: phrase).filter { !stopWords.contains($0) }

        if tokens.contains("open") && tokens.contains("finder") {
            return ["open", "finder"]
        }

        if tokens.contains("open") && tokens.contains("chrome") {
            return ["open", "chrome"]
        }

        if tokens.contains("close") && tokens.contains("code") {
            return ["close", "code"]
        }

        return Array(Set(tokens))
    }}
