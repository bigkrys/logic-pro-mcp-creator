import AppKit
import ApplicationServices
import Foundation

/// Channel that reads and mutates Logic Pro state via the macOS Accessibility API.
/// Primary channel for state queries (transport, tracks, mixer) and UI mutations
/// (clicking mute/solo buttons, reading fader values, etc.)
actor AccessibilityChannel: Channel {
    let id: ChannelID = .accessibility

    func start() async throws {
        // Verify AX trust. If not trusted, the process needs to be added to
        // System Preferences > Privacy & Security > Accessibility.
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            throw AccessibilityError.notTrusted
        }
        guard ProcessUtils.isLogicProRunning else {
            Log.warn("Logic Pro not running at AX channel start", subsystem: "ax")
            return
        }
        Log.info("Accessibility channel started", subsystem: "ax")
    }

    func stop() async {
        Log.info("Accessibility channel stopped", subsystem: "ax")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        guard ProcessUtils.isLogicProRunning else {
            return .error("Logic Pro is not running")
        }

        switch operation {
        // MARK: - Transport reads
        case "transport.get_state":
            return getTransportState()

        // MARK: - Transport mutations
        case "transport.toggle_cycle":
            return toggleTransportButton(named: "Cycle")
        case "transport.toggle_metronome":
            return toggleTransportButton(named: "Metronome")
        case "transport.set_tempo":
            return setTempo(params: params)
        case "transport.set_cycle_range":
            return setCycleRange(params: params)

        // MARK: - Track reads
        case "track.get_tracks":
            return getTracks()
        case "track.get_selected":
            return getSelectedTrack()

        // MARK: - Track mutations
        case "track.select":
            return selectTrack(params: params)
        case "track.set_mute":
            return setTrackToggle(params: params, button: "Mute")
        case "track.set_solo":
            return setTrackToggle(params: params, button: "Solo")
        case "track.set_arm":
            return setTrackToggle(params: params, button: "Record")
        case "track.rename":
            return await renameTrack(params: params)
        case "track.set_color":
            return .error("Track color setting not supported via AX")

        // MARK: - Mixer reads
        case "mixer.get_state":
            return getMixerState()
        case "mixer.get_channel_strip":
            return getChannelStrip(params: params)

        // MARK: - Mixer mutations
        case "mixer.set_volume":
            return setMixerValue(params: params, target: .volume)
        case "mixer.set_pan":
            return setMixerValue(params: params, target: .pan)
        case "mixer.set_send":
            return .error("Send adjustment not yet implemented via AX")
        case "mixer.set_input", "mixer.set_output":
            return .error("I/O routing not yet implemented via AX")
        case "mixer.toggle_eq":
            return .error("EQ toggle not yet implemented via AX")
        case "mixer.reset_strip":
            return .error("Strip reset not yet implemented via AX")

        // MARK: - Navigation
        case "nav.get_markers":
            return .error("Marker reading not yet implemented via AX")
        case "nav.rename_marker":
            return .error("Marker renaming not yet implemented via AX")

        // MARK: - Project
        case "project.get_info":
            return getProjectInfo()

        // MARK: - Regions
        case "region.get_regions":
            return .error("Region reading not yet implemented via AX")
        case "region.select", "region.loop", "region.set_name", "region.move", "region.resize":
            return .error("Region operations not yet implemented via AX")

        // MARK: - Plugins
        case "plugin.list", "plugin.insert", "plugin.bypass", "plugin.remove":
            return .error("Plugin operations not yet implemented via AX")

        // MARK: - Automation
        case "automation.get_mode":
            return .error("Automation mode reading not yet implemented via AX")
        case "automation.set_mode":
            return .error("Automation mode setting not yet implemented via AX")

        default:
            return .error("Unsupported AX operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard AXIsProcessTrusted() else {
            return .unavailable("Accessibility not trusted — add this process in System Preferences")
        }
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        // Quick smoke test: can we reach the app root?
        guard AXLogicProElements.appRoot() != nil else {
            return .unavailable("Cannot access Logic Pro AX element")
        }
        return .healthy(detail: "AX connected to Logic Pro")
    }

    // MARK: - Transport

    private func getTransportState() -> ChannelResult {
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        let state = AXValueExtractors.extractTransportState(from: transport)
        return encodeResult(state)
    }

    private func toggleTransportButton(named name: String) -> ChannelResult {
        guard let button = AXLogicProElements.findTransportButton(named: name) else {
            return .error("Cannot find transport button: \(name)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to press transport button: \(name)")
        }
        return .success("{\"toggled\":\"\(name)\"}")
    }

    private func setTempo(params: [String: String]) -> ChannelResult {
        guard let tempoStr = params["bpm"] ?? params["tempo"], let _ = Double(tempoStr) else {
            return .error("Missing or invalid 'tempo' / 'bpm' parameter")
        }
        guard let transport = AXLogicProElements.getTransportBar() else {
            return .error("Cannot locate transport bar")
        }
        // Find the tempo text field and set its value
        let texts = AXHelpers.findAllDescendants(of: transport, role: kAXTextFieldRole, maxDepth: 4)
        for field in texts {
            let desc = AXHelpers.getDescription(field)?.lowercased() ?? ""
            if desc.contains("tempo") || desc.contains("bpm") {
                AXHelpers.setAttribute(field, kAXValueAttribute, tempoStr as CFTypeRef)
                AXHelpers.performAction(field, kAXConfirmAction)
                return .success("{\"tempo\":\(tempoStr)}")
            }
        }
        return .error("Cannot locate tempo field")
    }

    private func setCycleRange(params: [String: String]) -> ChannelResult {
        // Cycle range setting via AX is fragile — requires locating the cycle locators
        guard let _ = params["start"], let _ = params["end"] else {
            return .error("Missing 'start' and/or 'end' parameters")
        }
        return .error("Cycle range setting not yet fully implemented via AX")
    }

    // MARK: - Tracks

    private func getTracks() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        if headers.isEmpty {
            return .error("No track headers found — is a project open?")
        }
        var tracks: [TrackState] = []
        for (index, header) in headers.enumerated() {
            let track = AXValueExtractors.extractTrackState(from: header, index: index)
            tracks.append(track)
        }
        return encodeResult(tracks)
    }

    private func getSelectedTrack() -> ChannelResult {
        let headers = AXLogicProElements.allTrackHeaders()
        for (index, header) in headers.enumerated() {
            if AXValueExtractors.extractSelectedState(header) == true {
                let track = AXValueExtractors.extractTrackState(from: header, index: index)
                return encodeResult(track)
            }
        }
        return .error("No track is currently selected")
    }

    private func selectTrack(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let header = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Track at index \(index) not found")
        }
        guard AXHelpers.performAction(header, kAXPressAction) else {
            return .error("Failed to select track \(index)")
        }
        return .success("{\"selected\":\(index)}")
    }

    private func setTrackToggle(params: [String: String], button buttonName: String) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        let finder: (Int) -> AXUIElement? = switch buttonName {
        case "Mute": AXLogicProElements.findTrackMuteButton
        case "Solo": AXLogicProElements.findTrackSoloButton
        case "Record": AXLogicProElements.findTrackArmButton
        default: { _ in nil }
        }
        guard let button = finder(index) else {
            return .error("Cannot find \(buttonName) button on track \(index)")
        }
        guard AXHelpers.performAction(button, kAXPressAction) else {
            return .error("Failed to click \(buttonName) on track \(index)")
        }
        return .success("{\"track\":\(index),\"toggled\":\"\(buttonName)\"}")
    }

    /// Localized titles for the "Rename" context-menu item across Logic Pro UI languages.
    /// Used as a substring match against `kAXTitleAttribute`.
    private static let renameMenuTitles: [String] = [
        "rename",           // English
        "重命名", "重新命名",   // Simplified / Traditional Chinese
        "名前の変更", "名称変更",  // Japanese
        "이름 변경",          // Korean
        "renommer",         // French
        "umbenennen",       // German
        "cambiar nombre", "renombrar",  // Spanish
        "rinomina",         // Italian
        "renomear",         // Portuguese
        "переименовать"     // Russian
    ]

    private func renameTrack(params: [String: String]) async -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let name = params["name"] else {
            return .error("Missing 'index' or 'name' parameter")
        }
        guard let trackRow = AXLogicProElements.findTrackHeader(at: index) else {
            return .error("Cannot find track row for track \(index)")
        }
        guard let pid = ProcessUtils.logicProPID() else {
            return .error("Logic Pro not running")
        }
        guard let rowPos = AXHelpers.getPosition(trackRow),
              let rowSz = AXHelpers.getSize(trackRow) else {
            return .error("Cannot determine screen position of track \(index)")
        }

        // Bring Logic Pro to foreground using the bundle ID from ServerConfig.
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: ServerConfig.logicProBundleID
        ).first {
            app.activate()  // macOS 14+: options-based activation is a no-op
        }
        try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s

        let clickPoint = CGPoint(x: rowPos.x + rowSz.width * 0.35, y: rowPos.y + rowSz.height * 0.5)

        // Right-click to open context menu
        postMouseEvent(at: clickPoint, type: .rightMouseDown, clickCount: 1, pid: pid)
        postMouseEvent(at: clickPoint, type: .rightMouseUp,   clickCount: 1, pid: pid)
        try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s

        // Find the localized rename item in the context menu via AX.
        let renameItem: AXUIElement? = {
            guard let root = AXLogicProElements.appRoot() else { return nil }
            let items = AXHelpers.findAllDescendants(of: root, role: kAXMenuItemRole, maxDepth: 8)
            return items.first { title in
                let lowered = (AXHelpers.getTitle(title) ?? "").lowercased()
                guard !lowered.isEmpty else { return false }
                return Self.renameMenuTitles.contains { lowered.contains($0) }
            }
        }()

        guard let item = renameItem else {
            let menuDump: String = {
                guard let root = AXLogicProElements.appRoot() else { return "no root" }
                let items = AXHelpers.findAllDescendants(of: root, role: kAXMenuItemRole, maxDepth: 8)
                let titles = items.compactMap { AXHelpers.getTitle($0) }.filter { !$0.isEmpty }
                return titles.isEmpty ? "no menu items found" : titles.joined(separator: " | ")
            }()
            postRawKey(keyCode: KeyCode.escape, flags: [], pid: pid) // dismiss menu
            return .error("No rename item found. Menu contained: \(menuDump)")
        }

        // Click the rename item
        AXHelpers.performAction(item, kAXPressAction)
        try? await Task.sleep(nanoseconds: 350_000_000) // 0.35s

        // Save the user's clipboard contents so we can restore them after pasting.
        let savedClipboard = snapshotClipboard()
        defer { restoreClipboard(savedClipboard) }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)

        postRawKey(keyCode: KeyCode.a, flags: .maskCommand, pid: pid)   // Cmd+A
        try? await Task.sleep(nanoseconds: 80_000_000)  // 0.08s
        postRawKey(keyCode: KeyCode.v, flags: .maskCommand, pid: pid)   // Cmd+V
        try? await Task.sleep(nanoseconds: 80_000_000)  // 0.08s
        postRawKey(keyCode: KeyCode.return_, flags: [], pid: pid)

        // Give Logic Pro a moment to consume the paste before we restore the clipboard.
        try? await Task.sleep(nanoseconds: 120_000_000) // 0.12s

        return .success("{\"track\":\(index),\"name\":\"\(name)\"}")
    }

    /// Capture the current general pasteboard contents so we can restore them
    /// after a programmatic paste.
    private func snapshotClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = NSPasteboard.general.pasteboardItems else { return [] }
        return items.map { item in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
    }

    private func restoreClipboard(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        guard !snapshot.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
    }

    /// Named virtual key codes used by the rename flow (and any future CGEvent key posts).
    /// Values are Carbon HIToolbox virtual key codes — unchanged across macOS versions.
    private enum KeyCode {
        static let a: CGKeyCode = 0
        static let v: CGKeyCode = 9
        static let `return_`: CGKeyCode = 36
        static let escape: CGKeyCode = 53
    }

    private func postMouseEvent(at point: CGPoint, type: CGEventType, clickCount: Int, pid: pid_t) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(mouseEventSource: src, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.postToPid(pid)
    }

    private func postRawKey(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: - Mixer

    private enum MixerTarget {
        case volume
        case pan
    }

    private func getMixerState() -> ChannelResult {
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        var channelStrips: [ChannelStripState] = []

        for (index, strip) in strips.enumerated() {
            let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
            let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
            let pan = sliders.count > 1
                ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
                : 0.0

            channelStrips.append(ChannelStripState(
                trackIndex: index,
                volume: volume,
                pan: pan
            ))
        }
        return encodeResult(channelStrips)
    }

    private func getChannelStrip(params: [String: String]) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr) else {
            return .error("Missing or invalid 'index' parameter")
        }
        guard let mixer = AXLogicProElements.getMixerArea() else {
            return .error("Cannot locate mixer — is it visible?")
        }
        let strips = AXHelpers.getChildren(mixer)
        guard index >= 0 && index < strips.count else {
            return .error("Channel strip index \(index) out of range")
        }
        let strip = strips[index]
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        let volume = sliders.first.flatMap { AXValueExtractors.extractSliderValue($0) } ?? 0.0
        let pan = sliders.count > 1
            ? AXValueExtractors.extractSliderValue(sliders[1]) ?? 0.0
            : 0.0

        let state = ChannelStripState(trackIndex: index, volume: volume, pan: pan)
        return encodeResult(state)
    }

    private func setMixerValue(params: [String: String], target: MixerTarget) -> ChannelResult {
        guard let indexStr = params["index"], let index = Int(indexStr),
              let valueStr = params["value"], let value = Double(valueStr) else {
            return .error("Missing 'index' or 'value' parameter")
        }
        let element: AXUIElement?
        switch target {
        case .volume:
            element = AXLogicProElements.findFader(trackIndex: index)
        case .pan:
            element = AXLogicProElements.findPanKnob(trackIndex: index)
        }
        guard let slider = element else {
            return .error("Cannot find \(target) control for track \(index)")
        }
        AXHelpers.setAttribute(slider, kAXValueAttribute, NSNumber(value: value))
        let label = target == .volume ? "volume" : "pan"
        return .success("{\"\(label)\":\(value),\"track\":\(index)}")
    }

    // MARK: - Project

    private func getProjectInfo() -> ChannelResult {
        guard let window = AXLogicProElements.mainWindow() else {
            return .error("Cannot locate Logic Pro main window")
        }
        let title = AXHelpers.getTitle(window) ?? "Unknown"
        var info = ProjectInfo()
        info.name = title
        info.lastUpdated = Date()
        return encodeResult(info)
    }

    // MARK: - JSON encoding

    private func encodeResult<T: Encodable>(_ value: T) -> ChannelResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .error("Failed to encode result to UTF-8")
            }
            return .success(json)
        } catch {
            return .error("JSON encoding failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

enum AccessibilityError: Error, CustomStringConvertible {
    case notTrusted

    var description: String {
        switch self {
        case .notTrusted:
            return "Process is not trusted for Accessibility. Add it in System Preferences > Privacy & Security > Accessibility."
        }
    }
}
