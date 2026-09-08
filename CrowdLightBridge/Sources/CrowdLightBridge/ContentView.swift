import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var midi: MIDIManager

    init(model: AppModel) {
        self.model = model
        self.midi = model.midi
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusRow
                controlSection
                connectionSection
                cueMapSection
                logSection
            }
            .padding(20)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 640, idealHeight: 760)
        .onAppear { model.start() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: 46, height: 46)
                Text("CL")
                    .font(.headline)
                    .fontWeight(.black)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("CrowdLight Bridge")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("ProPresenter → CoreMIDI → Firebase → CrowdLight")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("v0.1")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("macOS 11+")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            StatusCard(
                title: "MIDI",
                headline: midi.connectedSourceName,
                detail: midi.lastMessage,
                good: midi.connectedSourceID != 0
            )
            StatusCard(
                title: "FIREBASE",
                headline: model.firebaseState,
                detail: "Clock offset: \(model.clockOffsetText)",
                good: model.firebaseConnected
            )
            StatusCard(
                title: "CURRENT STATE",
                headline: model.currentState,
                detail: model.lastCue,
                good: model.currentState != "BLACKOUT"
            )
        }
    }

    private var controlSection: some View {
        GroupBox(label: Text("Live Control").fontWeight(.semibold)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.externalCuesEnabled },
                        set: { _ in model.toggleExternalCues() }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accept ProPresenter MIDI cues")
                                .fontWeight(.semibold)
                            Text("Off by default for safety. Manual controls always remain available.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle())
                }

                HStack(spacing: 10) {
                    Button("BLACKOUT") { model.sendManual(.blackout) }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("ALL LIGHTS ON") { model.sendManual(.allOn) }
                    Button("SYNC FLASH") { model.sendManual(.syncFlash) }
                    Spacer()
                }

                Divider()

                HStack(spacing: 18) {
                    HStack {
                        Text("BPM")
                            .foregroundColor(.secondary)
                        Slider(value: $model.bpm, in: 50...180, step: 1)
                            .frame(width: 180)
                        Text("\(Int(model.bpm))")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 34, alignment: .trailing)
                    }

                    Picker("Flash every", selection: $model.division) {
                        Text("1 beat").tag(1)
                        Text("2 beats").tag(2)
                        Text("4 beats").tag(4)
                    }
                    .frame(width: 180)

                    HStack {
                        Text("Flash")
                            .foregroundColor(.secondary)
                        Slider(value: $model.flashMs, in: 45...220, step: 5)
                            .frame(width: 130)
                        Text("\(Int(model.flashMs)) ms")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 58, alignment: .trailing)
                    }
                }

                HStack(spacing: 10) {
                    Button("UNISON") { model.sendManual(.unison) }
                    Button("TWINKLE") { model.sendManual(.twinkle) }
                    Button("SPARKLE") { model.sendManual(.sparkle) }
                    Button("CONSTELLATION") { model.sendManual(.constellation) }
                    Spacer()
                }
            }
            .padding(.top, 4)
        }
    }

    private var connectionSection: some View {
        GroupBox(label: Text("Connections").fontWeight(.semibold)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("MIDI source")
                        .frame(width: 95, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.selectedSourceID },
                        set: { model.selectMIDISource($0) }
                    )) {
                        Text("Select a MIDI source…").tag(Int32(0))
                        ForEach(midi.sources) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    Button("Refresh") { model.refreshMIDI() }
                    Stepper("Channel \(model.midiChannel)", value: $model.midiChannel, in: 1...16)
                        .frame(width: 130)
                }

                HStack(spacing: 10) {
                    Text("Firebase")
                        .frame(width: 95, alignment: .leading)
                    TextField("Database URL", text: $model.databaseURL)
                    Text("Room")
                    TextField("MAIN", text: $model.room)
                        .frame(width: 90)
                    Button("Test Firebase") { model.testFirebase() }
                }

                Text("v0.1 uses the current Firebase test-mode database. Authentication will be added after the multi-device functional test.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var cueMapSection: some View {
        GroupBox(label: Text("Cue Map • Channel \(model.midiChannel)").fontWeight(.semibold)) {
            VStack(spacing: 0) {
                ForEach(model.cueMappings) { cue in
                    HStack(spacing: 12) {
                        Text(cue.noteName)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.bold)
                            .frame(width: 46, alignment: .leading)
                        Text("MIDI \(cue.note)")
                            .foregroundColor(.secondary)
                            .frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cue.action.label)
                                .fontWeight(.semibold)
                            Text(cue.action.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Simulate Cue") { model.simulateCue(cue) }
                    }
                    .padding(.vertical, 8)
                    if cue.id != model.cueMappings.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var logSection: some View {
        GroupBox(label: Text("Event Log").fontWeight(.semibold)) {
            VStack(alignment: .leading, spacing: 6) {
                if model.logs.isEmpty {
                    Text("No events yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(model.logs.prefix(14)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.timeText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 78, alignment: .leading)
                            Text(entry.success == true ? "✓" : (entry.success == false ? "!" : "•"))
                                .fontWeight(.bold)
                                .foregroundColor(entry.success == false ? .red : (entry.success == true ? .green : .secondary))
                                .frame(width: 14)
                            Text(entry.message)
                                .font(.caption)
                            Spacer()
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct StatusCard: View {
    let title: String
    let headline: String
    let detail: String
    let good: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(good ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
            Text(headline)
                .font(.headline)
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}
