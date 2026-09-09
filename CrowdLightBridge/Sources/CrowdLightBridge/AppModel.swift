import Foundation
import Combine
import AppKit

final class AppModel: ObservableObject {
    static let defaultDatabaseURL = "https://crowd-light-show-default-rtdb.asia-southeast1.firebasedatabase.app"

    @Published var databaseURL: String
    @Published var room: String
    @Published var midiChannel: Int
    @Published var selectedSourceID: Int32 = 0
    @Published var externalCuesEnabled: Bool = false
    @Published var bpm: Double
    @Published var division: Int
    @Published var flashMs: Double

    @Published var firebaseState: String = "Not tested"
    @Published var firebaseConnected: Bool = false
    @Published var clockOffsetText: String = "—"
    @Published var currentState: String = "NO COMMAND SENT"
    @Published var lastCue: String = "No cue received"
    @Published var midiLoopbackState: String = "Not tested"
    @Published var controlLeaseState: String = "Not claimed"
    @Published var controlLeaseOwned: Bool = false
    @Published var logs: [BridgeLogEntry] = []

    let cueMappings = CueMapping.defaults
    let midi = MIDIManager()
    private let firebase = FirebaseTransport()

    private var keepAliveTimer: Timer?
    private var persistentCommand: [String: Any]?
    private var persistentAction: CrowdAction?
    private var restoreWorkItem: DispatchWorkItem?
    private var actionVersion: UInt64 = 0
    private var controllerRevision: UInt64 = 0
    private let controllerID = "bridge-" + UUID().uuidString
    private let controlLeaseID = "lease-" + UUID().uuidString
    private var controlLeaseUntil: Double = 0
    private var controlLeaseDatabaseURL: String = ""
    private var controlLeaseRoom: String = ""
    private var controlLeaseTimer: Timer?
    private var clockRefreshTimer: Timer?
    private var controlLeaseRequestInFlight = false
    private var pendingControlActions: [(action: CrowdAction, source: String)] = []
    private var midiLoopbackToken: UUID?
    private var midiLoopbackExpectedChannel: Int?
    private let midiLoopbackNote = 127
    private var hasStarted = false

    init() {
        let defaults = UserDefaults.standard
        databaseURL = defaults.string(forKey: "databaseURL") ?? Self.defaultDatabaseURL
        room = defaults.string(forKey: "room") ?? "MAIN"
        let storedChannel = defaults.integer(forKey: "midiChannel")
        midiChannel = storedChannel == 0 ? 16 : min(16, max(1, storedChannel))
        bpm = defaults.object(forKey: "bpm") as? Double ?? 120
        let storedDivision = defaults.integer(forKey: "division")
        division = [1, 2, 4].contains(storedDivision) ? storedDivision : 1
        flashMs = defaults.object(forKey: "flashMs") as? Double ?? 90

        midi.onNoteOn = { [weak self] note, channel, velocity in
            self?.handleMIDI(note: note, channel: channel, velocity: velocity)
        }
        midi.onSourceLost = { [weak self] in
            self?.handleMIDISourceLoss()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveSettings()
        }
    }

    deinit {
        keepAliveTimer?.invalidate()
        controlLeaseTimer?.invalidate()
        clockRefreshTimer?.invalidate()
        restoreWorkItem?.cancel()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        midi.refreshSources()
        if let crowdSource = midi.sources.first(where: { $0.name.localizedCaseInsensitiveContains("CrowdLight") }) {
            selectMIDISource(crowdSource.id)
        }
        testFirebase()
        log("Bridge started. External cues are disabled by default.", success: nil)
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(databaseURL, forKey: "databaseURL")
        defaults.set(room, forKey: "room")
        defaults.set(midiChannel, forKey: "midiChannel")
        defaults.set(bpm, forKey: "bpm")
        defaults.set(division, forKey: "division")
        defaults.set(flashMs, forKey: "flashMs")
    }

    func selectMIDISource(_ id: Int32) {
        selectedSourceID = id
        midi.connect(to: id)
        if let source = midi.sources.first(where: { $0.id == id }) {
            log("MIDI source selected: \(source.name)", success: true)
        }
    }

    func refreshMIDI() {
        midi.refreshSources()
        log("MIDI source list refreshed.", success: nil)
    }

    func testMIDILoopback() {
        guard midi.connectedSourceID != 0 else {
            midiLoopbackState = "FAILED • Select MIDI source"
            log("MIDI loopback test could not start: no MIDI source selected.", success: false)
            return
        }

        let token = UUID()
        let channel = midiChannel
        midiLoopbackToken = token
        midiLoopbackExpectedChannel = channel
        midiLoopbackState = "Testing…"
        log("MIDI loopback: sending diagnostic Note \(midiLoopbackNote) on Ch \(channel).", success: nil)

        switch midi.sendLoopbackTest(
            note: midiLoopbackNote,
            channel: channel,
            velocity: 100
        ) {
        case .success(let destinationName):
            log("MIDI loopback packet sent to \(destinationName). Waiting for CoreMIDI input…", success: nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.midiLoopbackToken == token else { return }
                self.midiLoopbackToken = nil
                self.midiLoopbackExpectedChannel = nil
                self.midiLoopbackState = "FAILED • No return received"
                self.log("MIDI LOOPBACK FAILED: no diagnostic note returned through the selected IAC source.", success: false)
            }

        case .failure(let error):
            midiLoopbackToken = nil
            midiLoopbackExpectedChannel = nil
            midiLoopbackState = "FAILED • Could not send"
            log("MIDI LOOPBACK FAILED: \(error.localizedDescription)", success: false)
        }
    }

    private func configurationKey() -> String {
        firebase.normalizedDatabaseURL(databaseURL) + "|" + cleanRoom(room)
    }

    func testFirebase() {
        firebaseState = "Testing…"
        firebaseConnected = false
        saveSettings()
        let configKey = configurationKey()

        firebase.testConnection(databaseURL: databaseURL, room: room) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.configurationKey() == configKey else { return }
                switch result {
                case .success(let offset):
                    self.firebaseConnected = true
                    self.firebaseState = "Connected • TEST MODE"
                    self.clockOffsetText = String(format: "%+.0f ms", offset)
                    self.startClockRefreshTimer()
                    self.log("Firebase write test succeeded. Server offset \(self.clockOffsetText).", success: true)
                case .failure(let error):
                    self.firebaseConnected = false
                    self.firebaseState = "Connection failed"
                    self.clockOffsetText = "—"
                    self.log("Firebase test failed: \(error.localizedDescription)", success: false)
                }
            }
        }
    }

    private func startClockRefreshTimer() {
        clockRefreshTimer?.invalidate()

        let timer = Timer(timeInterval: 45.0, repeats: true) { [weak self] _ in
            self?.refreshServerClock(periodic: true)
        }
        clockRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshServerClock(
        periodic: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        let configKey = configurationKey()
        firebase.fetchServerOffset(
            databaseURL: databaseURL,
            room: room
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.configurationKey() == configKey else {
                    completion?(false)
                    return
                }

                switch result {
                case .success(let offset):
                    self.clockOffsetText = String(format: "%+.0f ms", offset)
                    if !periodic {
                        self.log("Firebase server clock refreshed: \(self.clockOffsetText).", success: true)
                    }
                    completion?(true)

                case .failure(let error):
                    if self.firebase.serverClockAgeMs() > 120_000 {
                        self.clockOffsetText = "STALE"
                        self.firebaseState = "Clock stale"
                    }
                    if !periodic {
                        self.log("Server clock refresh failed: \(error.localizedDescription)", success: false)
                    }
                    completion?(false)
                }
            }
        }
    }


    func toggleExternalCues() {
        if externalCuesEnabled {
            externalCuesEnabled = false
            log("External ProPresenter cues DISABLED.", success: nil)
            return
        }

        acquireControlLease(force: false) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.externalCuesEnabled = true
                self.log("External ProPresenter cues ENABLED with room control.", success: true)
            } else {
                self.externalCuesEnabled = false
                self.log("External cues remain DISABLED because another controller owns the room.", success: false)
            }
        }
    }

    func claimControl() {
        acquireControlLease(force: false) { [weak self] ok in
            guard let self else { return }
            self.log(
                ok ? "CrowdLight room control claimed." : "Could not claim room control.",
                success: ok
            )
        }
    }

    func takeControl() {
        acquireControlLease(force: true) { [weak self] ok in
            guard let self else { return }
            self.log(
                ok ? "CrowdLight room control TAKEN OVER explicitly." : "Could not take control of the room.",
                success: ok
            )
        }
    }

    private func hasUsableControlLease() -> Bool {
        let sameDatabase =
            firebase.normalizedDatabaseURL(databaseURL) == controlLeaseDatabaseURL
        let sameRoom = cleanRoom(room) == controlLeaseRoom

        return controlLeaseOwned &&
            sameDatabase &&
            sameRoom &&
            firebase.hasFreshServerClock() &&
            firebase.estimatedServerNowMs() <
                controlLeaseUntil - FirebaseTransport.controlLeaseGraceMs
    }

    private func acquireControlLease(
        force: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        if !force, hasUsableControlLease() {
            completion(true)
            return
        }

        guard !controlLeaseRequestInFlight else {
            completion(false)
            return
        }

        if !firebase.hasFreshServerClock() {
            controlLeaseRequestInFlight = true
            refreshServerClock(periodic: false) { [weak self] ok in
                guard let self else { return }
                self.controlLeaseRequestInFlight = false
                guard ok else {
                    self.controlLeaseState = "CLOCK NOT READY"
                    completion(false)
                    return
                }
                self.acquireControlLease(force: force, completion: completion)
            }
            return
        }

        controlLeaseRequestInFlight = true
        firebase.acquireRoomLease(
            databaseURL: databaseURL,
            room: room,
            controllerID: controllerID,
            leaseID: controlLeaseID,
            force: force
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.controlLeaseRequestInFlight = false

                switch result {
                case .failure(let error):
                    let previouslyOwned = self.controlLeaseOwned
                    if previouslyOwned &&
                        self.firebase.estimatedServerNowMs() >=
                            self.controlLeaseUntil - FirebaseTransport.controlLeaseGraceMs {
                        self.loseControl("Controller lease renewal failed: \(error.localizedDescription)")
                    } else {
                        self.controlLeaseState = "Lease error"
                        self.log("Controller lease error: \(error.localizedDescription)", success: false)
                    }
                    completion(false)

                case .success(.held(let ownerType, _, let leaseUntil)):
                    self.controlLeaseUntil = leaseUntil
                    if self.controlLeaseOwned {
                        self.loseControl("Room control was taken by another \(ownerType) controller.")
                    } else {
                        self.controlLeaseOwned = false
                        self.controlLeaseState = "Held by \(ownerType.uppercased())"
                    }
                    completion(false)

                case .success(.acquired(let leaseUntil)):
                    self.controlLeaseUntil = leaseUntil
                    self.controlLeaseDatabaseURL =
                        self.firebase.normalizedDatabaseURL(self.databaseURL)
                    self.controlLeaseRoom = self.cleanRoom(self.room)
                    self.controlLeaseOwned = true
                    self.controlLeaseState = "CONTROL OWNED"
                    self.startControlLeaseTimer()
                    completion(true)
                }
            }
        }
    }

    private func startControlLeaseTimer() {
        guard controlLeaseTimer == nil else { return }

        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.controlLeaseOwned else { return }
            guard !self.controlLeaseRequestInFlight else { return }
            guard self.firebase.normalizedDatabaseURL(self.databaseURL) ==
                    self.controlLeaseDatabaseURL,
                  self.cleanRoom(self.room) == self.controlLeaseRoom
            else {
                self.loseControl("Firebase/room configuration changed. Re-claim control before sending cues.")
                return
            }

            self.acquireControlLease(force: false) { [weak self] ok in
                guard let self else { return }
                if !ok,
                   self.firebase.estimatedServerNowMs() >=
                    self.controlLeaseUntil - FirebaseTransport.controlLeaseGraceMs {
                    self.loseControl("Controller lease expired. Bridge show commands stopped.")
                }
            }
        }

        controlLeaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func loseControl(_ reason: String) {
        controlLeaseOwned = false
        controlLeaseUntil = 0
        controlLeaseDatabaseURL = ""
        controlLeaseRoom = ""
        controlLeaseState = "CONTROL LOST"
        externalCuesEnabled = false
        pendingControlActions.removeAll()
        controlLeaseTimer?.invalidate()
        controlLeaseTimer = nil
        stopPersistentMode()
        currentState = "CONTROL LOST"
        log(reason, success: false)
    }

    private func handleMIDISourceLoss() {
        externalCuesEnabled = false
        midiLoopbackToken = nil
        midiLoopbackExpectedChannel = nil
        midiLoopbackState = "FAILED • MIDI source lost"

        let owned = hasUsableControlLease()
        stopPersistentMode()
        log("MIDI source lost. External cues were automatically DISARMED.", success: false)

        if owned {
            performSend(action: .blackout, source: "MIDI source loss fail-safe")
        }
    }

    func simulateCue(_ mapping: CueMapping) {
        lastCue = "SIMULATED • \(mapping.noteName) / MIDI \(mapping.note) → \(mapping.action.label)"
        log(lastCue, success: nil)
        send(action: mapping.action, source: "Simulator")
    }

    func sendManual(_ action: CrowdAction) {
        send(action: action, source: "Manual")
    }

    private func handleMIDI(note: Int, channel: Int, velocity: Int) {
        if midiLoopbackToken != nil,
           note == midiLoopbackNote,
           channel == midiLoopbackExpectedChannel {
            midiLoopbackToken = nil
            midiLoopbackExpectedChannel = nil
            midiLoopbackState = "PASSED • Note \(note) / Ch \(channel)"
            lastCue = "MIDI LOOPBACK PASSED"
            log("MIDI LOOPBACK PASSED: Note \(note) / Ch \(channel) returned through CoreMIDI.", success: true)
            return
        }

        guard channel == midiChannel else {
            log("Ignored MIDI note \(note) on channel \(channel) (CrowdLight listens on Ch \(midiChannel)).", success: nil)
            return
        }
        guard externalCuesEnabled else {
            log("Received MIDI \(note) on Ch \(channel), but external cues are disabled.", success: nil)
            return
        }
        guard let mapping = cueMappings.first(where: { $0.note == note }) else {
            log("No CrowdLight mapping for MIDI note \(note) on Ch \(channel).", success: nil)
            return
        }

        lastCue = "\(mapping.noteName) / MIDI \(note) • Ch \(channel) → \(mapping.action.label)"
        log(lastCue, success: nil)
        send(action: mapping.action, source: "ProPresenter MIDI")
    }

    private func send(action: CrowdAction, source: String) {
        if hasUsableControlLease() {
            performSend(action: action, source: source)
            return
        }

        pendingControlActions.append((action: action, source: source))
        guard !controlLeaseRequestInFlight else { return }

        acquireControlLease(force: false) { [weak self] ok in
            guard let self else { return }
            let queued = self.pendingControlActions
            self.pendingControlActions.removeAll()

            guard ok else {
                self.log("Show command blocked because another controller owns this room.", success: false)
                return
            }

            for item in queued {
                self.performSend(action: item.action, source: item.source)
            }
        }
    }

    private func performSend(action: CrowdAction, source: String) {
        saveSettings()
        actionVersion &+= 1
        let thisActionVersion = actionVersion

        // Any new operator or MIDI command cancels a delayed restore from a prior
        // one-shot flash. This prevents a BLACKOUT from being undone later.
        restoreWorkItem?.cancel()
        restoreWorkItem = nil

        switch action {
        case .blackout:
            stopPersistentMode()
            currentState = "BLACKOUT"
            let command = baseCommand(mode: "off", ttlMs: 60_000)
            sendCommand(command, description: "BLACKOUT", source: source)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self,
                      self.actionVersion == thisActionVersion,
                      self.hasUsableControlLease()
                else { return }
                self.firebase.sendCommand(
                    databaseURL: self.databaseURL,
                    room: self.room,
                    command: self.baseCommand(mode: "off", ttlMs: 60_000)
                ) { _ in }
            }

        case .allOn:
            var command = baseCommand(mode: "steady")
            command["startAt"] = firebase.estimatedServerNowMs() + 750
            currentState = "ALL LIGHTS ON"
            beginPersistentMode(action: action, command: command)
            sendCommand(command, description: action.label, source: source)

        case .syncFlash:
            let previousCommand = persistentCommand
            let previousAction = persistentAction

            // Pause the keepalive so it cannot overwrite the one-shot FLASH
            // command before the audience phones execute it.
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil

            var command = baseCommand(mode: "flash")
            command["startAt"] = firebase.estimatedServerNowMs() + 900
            command["flashMs"] = Int(flashMs)
            currentState = "SYNC FLASH"
            sendCommand(command, description: action.label, source: source)

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.restoreWorkItem = nil

                if let previousCommand, let previousAction {
                    var restored = previousCommand
                    restored["id"] = UUID().uuidString
                    self.controllerRevision &+= 1
                    restored["revision"] = self.controllerRevision
                    restored["issuedAt"] = self.firebase.estimatedServerNowMs()
                    restored["validUntil"] = self.firebase.estimatedServerNowMs() + 15_000
                    restored["leaseId"] = self.controlLeaseID
                    restored["leaseUntil"] = self.controlLeaseUntil
                    let restoreRevision = self.controllerRevision
                    self.persistentCommand = restored
                    self.persistentAction = previousAction
                    self.currentState = self.displayState(for: previousAction, command: restored)
                    self.startKeepAliveTimer()
                    self.firebase.sendCommand(
                        databaseURL: self.databaseURL,
                        room: self.room,
                        command: restored
                    ) { result in
                        if case .failure(let error) = result {
                            DispatchQueue.main.async {
                                guard restoreRevision == self.controllerRevision else { return }
                                self.firebaseConnected = false
                                self.firebaseState = "Write failed"
                                self.log("Restore after SYNC FLASH failed: \(error.localizedDescription)", success: false)
                            }
                        }
                    }
                } else {
                    self.persistentCommand = nil
                    self.persistentAction = nil
                    self.currentState = "BLACKOUT"
                }
            }

            restoreWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)

        case .unison, .shimmer, .twinkle, .sparkle, .glow, .fireflies, .alternate, .constellation, .build, .drop:
            var command = baseCommand(mode: "pattern")
            let phase = firebase.estimatedServerNowMs() + 1_200
            command["bpm"] = bpm
            command["division"] = division
            command["flashMs"] = Int(flashMs)
            command["effect"] = action.effectName ?? "unison"
            command["phaseStart"] = phase
            command["startAt"] = phase
            currentState = "\(action.label) • \(Int(bpm)) BPM"
            beginPersistentMode(action: action, command: command)
            sendCommand(command, description: "\(action.label) at \(Int(bpm)) BPM", source: source)
        }
    }

    private func baseCommand(mode: String, ttlMs: Double = 15_000) -> [String: Any] {
        controllerRevision &+= 1
        let now = firebase.estimatedServerNowMs()
        return [
            "protocolVersion": 1,
            "controllerId": controllerID,
            "revision": controllerRevision,
            "id": UUID().uuidString,
            "mode": mode,
            "room": cleanRoom(room),
            "issuedAt": now,
            "validUntil": now + ttlMs,
            "leaseId": controlLeaseID,
            "leaseUntil": controlLeaseUntil,
            "bridge": "macOS"
        ]
    }

    private func beginPersistentMode(action: CrowdAction, command: [String: Any]) {
        keepAliveTimer?.invalidate()
        persistentAction = action
        persistentCommand = command
        startKeepAliveTimer()
    }

    private func startKeepAliveTimer() {
        keepAliveTimer?.invalidate()

        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, var refreshed = self.persistentCommand else { return }
            guard self.hasUsableControlLease() else {
                self.loseControl("Persistent mode stopped because the controller lease is no longer valid.")
                return
            }
            refreshed["id"] = UUID().uuidString
            self.controllerRevision &+= 1
            let revision = self.controllerRevision
            refreshed["revision"] = revision
            refreshed["issuedAt"] = self.firebase.estimatedServerNowMs()
            refreshed["validUntil"] = self.firebase.estimatedServerNowMs() + 15_000
            refreshed["leaseId"] = self.controlLeaseID
            refreshed["leaseUntil"] = self.controlLeaseUntil
            self.persistentCommand = refreshed

            self.firebase.sendCommand(
                databaseURL: self.databaseURL,
                room: self.room,
                command: refreshed
            ) { result in
                if case .failure(let error) = result {
                    DispatchQueue.main.async {
                        // Do not let a superseded heartbeat completion change
                        // the visible status of a newer operator action.
                        guard revision == self.controllerRevision else { return }
                        self.firebaseConnected = false
                        self.firebaseState = "Write failed"
                        self.log("Keepalive write failed: \(error.localizedDescription)", success: false)
                    }
                }
            }
        }

        keepAliveTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func displayState(for action: CrowdAction, command: [String: Any]) -> String {
        switch action {
        case .allOn:
            return "ALL LIGHTS ON"
        case .unison, .shimmer, .twinkle, .sparkle, .glow, .fireflies, .alternate, .constellation, .build, .drop:
            let commandBPM: Int
            if let n = command["bpm"] as? NSNumber {
                commandBPM = n.intValue
            } else if let d = command["bpm"] as? Double {
                commandBPM = Int(d)
            } else {
                commandBPM = Int(bpm)
            }
            return "\(action.label) • \(commandBPM) BPM"
        case .blackout:
            return "BLACKOUT"
        case .syncFlash:
            return "SYNC FLASH"
        }
    }

    private func stopPersistentMode() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        persistentCommand = nil
        persistentAction = nil
    }

    private func sendCommand(_ command: [String: Any], description: String, source: String) {
        let revision = (command["revision"] as? NSNumber)?.uint64Value
            ?? (command["revision"] as? UInt64)
            ?? 0

        firebase.sendCommand(databaseURL: databaseURL, room: room, command: command) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                // A newer cue has already been created. The transport will
                // repair stale REST ordering; this older completion must not
                // overwrite the operator-facing state.
                if revision > 0, revision < self.controllerRevision {
                    return
                }

                switch result {
                case .success:
                    self.firebaseConnected = true
                    self.firebaseState = "Connected • TEST MODE"
                    self.log("\(description) sent from \(source).", success: true)
                case .failure(let error):
                    self.firebaseConnected = false
                    self.firebaseState = "Write failed"
                    self.log("\(description) failed: \(error.localizedDescription)", success: false)
                }
            }
        }
    }

    private func cleanRoom(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = raw.uppercased()
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? "MAIN" : String(cleaned.prefix(24))
    }

    func log(_ message: String, success: Bool?) {
        logs.insert(BridgeLogEntry(time: Date(), message: message, success: success), at: 0)
        if logs.count > 100 {
            logs.removeLast(logs.count - 100)
        }
    }
}
