import ApplicationServices
import Foundation

/// Logic Pro-specific AX element finders.
/// Navigates from the app root to known UI regions using role/title/structure heuristics.
/// Logic Pro's AX tree structure may change between versions; these are best-effort.
enum AXLogicProElements {
    /// Get the root AX element for Logic Pro. Returns nil if not running.
    static func appRoot() -> AXUIElement? {
        guard let pid = ProcessUtils.logicProPID() else { return nil }
        return AXHelpers.axApp(pid: pid)
    }

    /// Get the main window element.
    static func mainWindow() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMainWindowAttribute)
    }

    /// Enumerate all windows of the Logic Pro application.
    static func allWindows() -> [AXUIElement] {
        guard let app = appRoot() else { return [] }
        guard let all: CFArray = AXHelpers.getAttribute(app, kAXWindowsAttribute) else {
            if let main = mainWindow() { return [main] }
            return []
        }
        var windows: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(all) {
            let ptr = CFArrayGetValueAtIndex(all, i)
            windows.append(unsafeBitCast(ptr, to: AXUIElement.self))
        }
        return windows
    }

    // MARK: - Transport

    /// Find the transport bar area (toolbar/group containing play, stop, record, etc.)
    static func getTransportBar() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        // Logic Pro's transport is typically an AXToolbar or AXGroup near the top
        if let toolbar = AXHelpers.findChild(of: window, role: kAXToolbarRole) {
            return toolbar
        }
        // Fallback: search for a group containing transport-like buttons
        return AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Transport")
    }

    /// Find a specific transport button by its title or description.
    static func findTransportButton(named name: String) -> AXUIElement? {
        guard let transport = getTransportBar() else { return nil }
        // Try by title first
        if let button = AXHelpers.findDescendant(of: transport, role: kAXButtonRole, title: name) {
            return button
        }
        // Try by description (some buttons use AXDescription instead of AXTitle)
        let buttons = AXHelpers.findAllDescendants(of: transport, role: kAXButtonRole, maxDepth: 4)
        for button in buttons {
            if AXHelpers.getDescription(button) == name {
                return button
            }
        }
        return nil
    }

    // MARK: - Tracks

    /// Find the track header area containing individual track rows.
    /// Searches all windows and tries multiple AX role/identifier combinations
    /// to handle layout differences across Logic Pro versions.
    static func getTrackHeaders() -> AXUIElement? {
        let windows = allWindows()
        let identifiers = ["Track Headers", "Tracks", "TrackHeaders"]
        let roles = [kAXListRole, kAXScrollAreaRole, kAXOutlineRole, kAXTableRole, kAXGroupRole]
        for window in windows {
            // Try known identifier + role combos first
            for id in identifiers {
                for role in roles {
                    if let area = AXHelpers.findDescendant(of: window, role: role, identifier: id) {
                        return area
                    }
                }
            }
            // Structural heuristic for Logic Pro Creator Studio (all AX identifiers are
            // NS-generated, e.g. "_NS:88" — no human-readable names exist).
            // Track rows: AXScrollArea → AXGroup → [AXLayoutItem…]
            // Each AXLayoutItem contains (in order): AXRadioButton, AXSplitter,
            // AXCheckBox (mute), AXCheckBox (solo), AXSlider, AXSlider, AXTextField (name).
            let scrollAreas = AXHelpers.findAllDescendants(
                of: window, role: kAXScrollAreaRole, maxDepth: 7
            )
            for scrollArea in scrollAreas {
                for group in AXHelpers.getChildren(scrollArea) {
                    guard AXHelpers.getRole(group) == kAXGroupRole else { continue }
                    let rows = AXHelpers.getChildren(group)
                    guard rows.count >= 2 else { continue }
                    // Rows must be AXLayoutItem, each containing an AXTextField (track name)
                    guard AXHelpers.getRole(rows[0]) == "AXLayoutItem" else { continue }
                    if AXHelpers.findDescendant(of: rows[0], role: kAXTextFieldRole, maxDepth: 2) != nil {
                        return group
                    }
                }
            }
            // Last resort: first outline or table deep in the window
            for role in [kAXOutlineRole, kAXTableRole] {
                if let area = AXHelpers.findDescendant(of: window, role: role, maxDepth: 6) {
                    return area
                }
            }
        }
        return nil
    }

    /// Find a track header at a specific 1-based index.
    static func findTrackHeader(at index: Int) -> AXUIElement? {
        guard let headers = getTrackHeaders() else { return nil }
        let rows = AXHelpers.getChildren(headers)
        // index is 1-based from the dispatcher; convert to 0-based
        let zeroIndex = index - 1
        guard zeroIndex >= 0 && zeroIndex < rows.count else { return nil }
        return rows[zeroIndex]
    }

    /// Enumerate all track header rows.
    static func allTrackHeaders() -> [AXUIElement] {
        guard let headers = getTrackHeaders() else { return [] }
        return AXHelpers.getChildren(headers)
    }

    // MARK: - Mixer

    /// Find the mixer area, searching all app windows.
    static func getMixerArea() -> AXUIElement? {
        for window in allWindows() {
            for role in [kAXGroupRole, kAXScrollAreaRole] {
                if let mixer = AXHelpers.findDescendant(of: window, role: role, identifier: "Mixer") {
                    return mixer
                }
            }
        }
        return nil
    }

    /// Returns only the mixer children that are real channel strips (contain at least one slider).
    /// Logic Pro Creator Studio's mixer AX tree interleaves label/separator elements between
    /// actual channel strips, so direct index access by track number is unreliable.
    private static func channelStrips(in mixer: AXUIElement) -> [AXUIElement] {
        AXHelpers.getChildren(mixer).filter { child in
            !AXHelpers.findAllDescendants(of: child, role: kAXSliderRole, maxDepth: 4).isEmpty
        }
    }

    /// Find a volume fader for a specific track index within the mixer.
    /// trackIndex is 1-based (track 1 = first channel strip).
    static func findFader(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = channelStrips(in: mixer)
        guard trackIndex > 0 && trackIndex <= strips.count else { return nil }
        let strip = strips[trackIndex - 1]
        return AXHelpers.findDescendant(of: strip, role: kAXSliderRole, maxDepth: 4)
    }

    /// Find the pan knob for a track in the mixer.
    /// trackIndex is 1-based (track 1 = first channel strip).
    static func findPanKnob(trackIndex: Int) -> AXUIElement? {
        guard let mixer = getMixerArea() else { return nil }
        let strips = channelStrips(in: mixer)
        guard trackIndex > 0 && trackIndex <= strips.count else { return nil }
        let strip = strips[trackIndex - 1]
        let sliders = AXHelpers.findAllDescendants(of: strip, role: kAXSliderRole, maxDepth: 4)
        return sliders.count > 1 ? sliders[1] : nil
    }

    // MARK: - Menu Bar

    /// Get the menu bar for Logic Pro.
    static func getMenuBar() -> AXUIElement? {
        guard let app = appRoot() else { return nil }
        return AXHelpers.getAttribute(app, kAXMenuBarAttribute)
    }

    /// Navigate menu: e.g. menuItem(path: ["File", "New..."]).
    static func menuItem(path: [String]) -> AXUIElement? {
        guard var current = getMenuBar() else { return nil }
        for title in path {
            let children = AXHelpers.getChildren(current)
            var found = false
            for child in children {
                // Menu bar items and menu items both use AXTitle
                if AXHelpers.getTitle(child) == title {
                    current = child
                    found = true
                    break
                }
                // Check child menu items inside a menu
                let subChildren = AXHelpers.getChildren(child)
                for sub in subChildren {
                    if AXHelpers.getTitle(sub) == title {
                        current = sub
                        found = true
                        break
                    }
                }
                if found { break }
            }
            if !found { return nil }
        }
        return current
    }

    // MARK: - Arrangement

    /// Find the main arrangement area (the timeline/tracks view).
    static func getArrangementArea() -> AXUIElement? {
        guard let window = mainWindow() else { return nil }
        if let area = AXHelpers.findDescendant(of: window, role: kAXGroupRole, identifier: "Arrangement") {
            return area
        }
        return AXHelpers.findDescendant(of: window, role: kAXScrollAreaRole, identifier: "Arrangement")
    }

    // MARK: - Track Controls

    /// Find the mute button on a track header.
    /// In Logic Pro Creator Studio, mute is the first AXCheckBox in the AXLayoutItem row.
    static func findTrackMuteButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        // Creator Studio uses AXCheckBox for mute (title "静音" or empty)
        let checkboxes = AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 2)
        if let first = checkboxes.first { return first }
        // Standard Logic Pro fallback
        return findButtonByDescriptionPrefix(in: header, prefix: "Mute")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "M")
    }

    /// Find the solo button on a track header.
    /// In Logic Pro Creator Studio, solo is the second AXCheckBox in the AXLayoutItem row.
    static func findTrackSoloButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        let checkboxes = AXHelpers.findAllDescendants(of: header, role: kAXCheckBoxRole, maxDepth: 2)
        if checkboxes.count > 1 { return checkboxes[1] }
        return findButtonByDescriptionPrefix(in: header, prefix: "Solo")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "S")
    }

    /// Find the record-arm button on a track header.
    /// In Logic Pro Creator Studio, this is the AXRadioButton (track select/arm).
    static func findTrackArmButton(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        if let rb = AXHelpers.findDescendant(of: header, role: kAXRadioButtonRole, maxDepth: 2) {
            return rb
        }
        return findButtonByDescriptionPrefix(in: header, prefix: "Record")
            ?? AXHelpers.findDescendant(of: header, role: kAXButtonRole, title: "R")
    }

    /// Find the track name text field on a header.
    static func findTrackNameField(trackIndex: Int) -> AXUIElement? {
        guard let header = findTrackHeader(at: trackIndex) else { return nil }
        return AXHelpers.findDescendant(of: header, role: kAXStaticTextRole, maxDepth: 4)
            ?? AXHelpers.findDescendant(of: header, role: kAXTextFieldRole, maxDepth: 4)
    }

    // MARK: - Diagnostics

    /// Dump the AX tree for all windows to help diagnose structure differences.
    static func dumpTree(maxDepth: Int = 3) -> String {
        guard ProcessUtils.isLogicProRunning else { return "Logic Pro not running" }
        var lines: [String] = []
        let windows = allWindows()
        lines.append("Windows: \(windows.count)")
        for (wi, window) in windows.enumerated() {
            let role = AXHelpers.getRole(window) ?? "?"
            let title = AXHelpers.getTitle(window) ?? ""
            let id = AXHelpers.getIdentifier(window) ?? ""
            lines.append("W\(wi): role=\(role) title=\"\(title)\" id=\"\(id)\"")
            dumpChildren(of: window, depth: 1, maxDepth: maxDepth, prefix: "  ", into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func dumpChildren(
        of element: AXUIElement, depth: Int, maxDepth: Int,
        prefix: String, into lines: inout [String]
    ) {
        guard depth <= maxDepth else { return }
        let children = AXHelpers.getChildren(element)
        for (ci, child) in children.prefix(20).enumerated() {
            let role = AXHelpers.getRole(child) ?? "?"
            let title = (AXHelpers.getTitle(child) ?? "").prefix(40)
            let id = (AXHelpers.getIdentifier(child) ?? "").prefix(40)
            let childCount = AXHelpers.getChildCount(child) ?? 0
            lines.append("\(prefix)[\(ci)] role=\(role) id=\"\(id)\" title=\"\(title)\" children=\(childCount)")
            if depth < maxDepth {
                dumpChildren(of: child, depth: depth + 1, maxDepth: maxDepth,
                             prefix: prefix + "  ", into: &lines)
            }
        }
        if children.count > 20 {
            lines.append("\(prefix)... (\(children.count - 20) more)")
        }
    }

    // MARK: - Helpers

    private static func findButtonByDescriptionPrefix(
        in element: AXUIElement, prefix: String
    ) -> AXUIElement? {
        let buttons = AXHelpers.findAllDescendants(of: element, role: kAXButtonRole, maxDepth: 4)
        return buttons.first { button in
            guard let desc = AXHelpers.getDescription(button) else { return false }
            return desc.hasPrefix(prefix)
        }
    }
}
