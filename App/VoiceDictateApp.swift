import SwiftUI
import UniformTypeIdentifiers

@main
struct VoiceDictateApp: App {
    @StateObject private var session = ProbeSession()
    @State private var importing = false
    private let hostReturn = HostAppReturn()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        Text(session.status)
                        Picker("Stay ready", selection: $session.availabilitySeconds) {
                            Text("5 minutes").tag(300.0)
                            Text("15 minutes").tag(900.0)
                            Text("1 hour").tag(3600.0)
                        }.disabled(session.active || session.activating || session.processing)
                        Button("Activate microphone") { Task { await session.activate() } }
                            .disabled(!session.configured || session.active || session.activating || session.processing || session.recoveryBusy)
                        Button("End session") { session.end() }
                            .disabled(!session.active && !session.activating && !session.processing || session.recoveryBusy)
                        Text("After activation, switch to your app and select Voice Dictate with the globe key. Hold the microphone pad while speaking, then release.").font(.footnote)
                        Text("The microphone stays active during the selected period, including between dictations. Idle audio is discarded, never uploaded. Each recording can last up to five minutes. Starting another recording replaces saved retry audio.").font(.footnote)
                    }
                    Section("Configuration") {
                        Text(session.configured ? "Configuration saved in Keychain" : "Import the configuration exported from your Mac")
                        Button("Import configuration…") { importing = true }
                            .disabled(session.active || session.processing || session.activating || session.recoveryBusy)
                        Text("Your recording goes to api.openai.com for transcription; the transcript goes to api.anthropic.com for cleanup. API keys stay in this app’s Keychain.").font(.footnote)
                    }
                    if session.hasRetry {
                        Section("Saved recording") {
                            if session.active { Text("End the session above to retry or delete saved audio.").font(.footnote) }
                            Button("Retry transcription") { Task { await session.retry() } }
                            Button("Delete saved audio", role: .destructive) { Task { await session.discardRetry() } }
                        }.disabled(session.active || session.processing || session.activating || session.recoveryBusy)
                    }
                    Section("Recent transcripts") {
                        ForEach(session.history) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.status).font(.caption)
                                Text(record.text).textSelection(.enabled)
                                Button("Copy text") { UIPasteboard.general.string = record.text }
                            }
                        }
                    }
                }
                .navigationTitle("Voice Dictate")
                .onOpenURL { url in
                    guard url.scheme == "voicedictate", url.host == "activate" else { return }
                    hostReturn.handle(activate: {
                        await session.activate()
                        guard session.active else { return false }
                        session.status = "Microphone ready. Hold the keyboard microphone to talk."
                        return true
                    }, isReady: { session.active }, onFallback: { session.status = "Microphone ready — swipe back to your app." })
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    switch result {
                    case .success(let url): session.importConfiguration(url)
                    case .failure: break
                    }
                }
            }
        }
    }
}
