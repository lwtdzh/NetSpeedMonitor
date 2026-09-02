import AppKit
import SwiftUI

private final class EdgeConstrainedPanel: NSPanel {
    static let aspectRatio: CGFloat = 4.5
    static let minimumSize = NSSize(width: 234, height: 52)
    static let maximumSize = NSSize(width: 720, height: 160)
    private static let resizeHitThickness: CGFloat = 10

    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            let edges = resizeEdges(at: event.locationInWindow)
            if !edges.isEmpty {
                trackResize(from: event, edges: edges)
                return
            }
        case .mouseMoved, .cursorUpdate:
            updateCursor(at: event.locationInWindow)
        default:
            break
        }

        super.sendEvent(event)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrainedFrame(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(constrainedFrame(frameRect), display: flag, animate: animateFlag)
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        var edges: ResizeEdges = []
        let width = frame.width
        let height = frame.height
        if point.x <= Self.resizeHitThickness {
            edges.insert(.left)
        }
        if point.x >= width - Self.resizeHitThickness {
            edges.insert(.right)
        }
        if point.y <= Self.resizeHitThickness {
            edges.insert(.bottom)
        }
        if point.y >= height - Self.resizeHitThickness {
            edges.insert(.top)
        }
        return edges
    }

    private func updateCursor(at point: NSPoint) {
        let edges = resizeEdges(at: point)
        if edges.contains(.left) || edges.contains(.right) {
            NSCursor.resizeLeftRight.set()
        } else if edges.contains(.top) || edges.contains(.bottom) {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func trackResize(from _: NSEvent, edges: ResizeEdges) {
        let initialFrame = frame
        let initialMouse = NSEvent.mouseLocation
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        while let event = nextEvent(
            matching: eventMask,
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if event.type == .leftMouseUp {
                break
            }

            let mouse = NSEvent.mouseLocation
            let deltaX = mouse.x - initialMouse.x
            let deltaY = mouse.y - initialMouse.y
            let horizontalScale = (
                initialFrame.width
                    + (edges.contains(.left) ? -deltaX : deltaX)
            ) / initialFrame.width
            let verticalScale = (
                initialFrame.height
                    + (edges.contains(.bottom) ? -deltaY : deltaY)
            ) / initialFrame.height
            let hasHorizontalEdge = edges.contains(.left) || edges.contains(.right)
            let hasVerticalEdge = edges.contains(.top) || edges.contains(.bottom)
            let requestedScale: CGFloat
            if hasHorizontalEdge && hasVerticalEdge {
                requestedScale = abs(horizontalScale - 1) >= abs(verticalScale - 1)
                    ? horizontalScale
                    : verticalScale
            } else {
                requestedScale = hasHorizontalEdge ? horizontalScale : verticalScale
            }
            let minimumScale = max(
                Self.minimumSize.width / initialFrame.width,
                Self.minimumSize.height / initialFrame.height
            )
            let maximumScale = min(
                Self.maximumSize.width / initialFrame.width,
                Self.maximumSize.height / initialFrame.height
            )
            let scale = min(max(requestedScale, minimumScale), maximumScale)
            let resizedSize = NSSize(
                width: initialFrame.width * scale,
                height: initialFrame.height * scale
            )
            var resizedFrame = NSRect(origin: initialFrame.origin, size: resizedSize)
            if edges.contains(.left) {
                resizedFrame.origin.x = initialFrame.maxX - resizedSize.width
            } else if !edges.contains(.right) {
                resizedFrame.origin.x = initialFrame.midX - resizedSize.width / 2
            }
            if edges.contains(.bottom) {
                resizedFrame.origin.y = initialFrame.maxY - resizedSize.height
            } else if !edges.contains(.top) {
                resizedFrame.origin.y = initialFrame.midY - resizedSize.height / 2
            }

            setFrame(resizedFrame, display: true)
        }

    }

    private func constrainedFrame(_ proposedFrame: NSRect) -> NSRect {
        var frame = proposedFrame
        frame.size.height = min(
            max(frame.height, Self.minimumSize.height),
            Self.maximumSize.height
        )
        frame.size.width = frame.height * Self.aspectRatio

        let targetScreen = NSScreen.screens.max {
            intersectionArea(frame, $0.visibleFrame) <
                intersectionArea(frame, $1.visibleFrame)
        } ?? screen
        guard let visibleFrame = targetScreen?.visibleFrame else { return frame }

        let maximumHeight = min(visibleFrame.height, visibleFrame.width / Self.aspectRatio)
        if frame.height > maximumHeight {
            frame.size.height = maximumHeight
            frame.size.width = maximumHeight * Self.aspectRatio
        }
        frame.origin.x = min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        return frame
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.width * intersection.height
    }
}

final class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private struct SavedPanelPlacement: Codable {
        let displayID: String
        let relativeX: Double
        let relativeY: Double
        let width: Double
        let height: Double
    }

    private static let placementsKey = "floatingPanelPlacementsByDisplayConfiguration"
    private var isConstrainingFrame = false
    private var isRestoringPlacement = false
    private var saveWorkItem: DispatchWorkItem?
    private var screenChangeWorkItem: DispatchWorkItem?

    init(
        monitor: TrafficMonitor,
        settings: AppSettings,
        openSettings: @escaping () -> Void
    ) {
        let size = NSSize(width: 315, height: 70)
        let panel = EdgeConstrainedPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.contentView = NSHostingView(
            rootView: SpeedPanelView(
                monitor: monitor,
                settings: settings,
                openSettings: openSettings
            )
        )
        panel.level = settings.floatingPanelAlwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = EdgeConstrainedPanel.minimumSize
        panel.maxSize = EdgeConstrainedPanel.maximumSize
        panel.contentAspectRatio = NSSize(
            width: EdgeConstrainedPanel.aspectRatio,
            height: 1
        )

        super.init(window: panel)
        panel.delegate = self

        if !restorePlacementForCurrentConfiguration() {
            isRestoringPlacement = true
            let restoredLegacyFrame = panel.setFrameUsingName("NetSpeedMonitorFloatingPanel")
            isRestoringPlacement = false
            if !restoredLegacyFrame {
                positionAtTopRight()
            }
            constrainToVisibleScreen()
            savePlacementNow()
        } else {
            constrainToVisibleScreen()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        saveWorkItem?.cancel()
        screenChangeWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            constrainToVisibleScreen()
            window?.orderFrontRegardless()
        } else {
            window?.orderOut(nil)
        }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        window?.level = enabled ? .floating : .normal
    }

    func savePlacement() {
        saveWorkItem?.cancel()
        savePlacementNow()
    }

    func windowDidMove(_ notification: Notification) {
        constrainToVisibleScreen()
        schedulePlacementSaveForUserInteraction()
    }

    func windowDidResize(_ notification: Notification) {
        constrainToVisibleScreen()
        schedulePlacementSaveForUserInteraction()
    }

    @objc private func screenParametersChanged() {
        saveWorkItem?.cancel()
        screenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.restorePlacementForCurrentConfiguration() {
                self.constrainToVisibleScreen()
                self.savePlacementNow()
            }
        }
        screenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func schedulePlacementSaveForUserInteraction() {
        guard !isRestoringPlacement, NSEvent.pressedMouseButtons != 0 else { return }
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.savePlacementNow()
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    @discardableResult
    private func restorePlacementForCurrentConfiguration() -> Bool {
        guard
            let panel = window,
            let configurationKey = currentDisplayConfigurationKey(),
            let placement = savedPlacements()[configurationKey],
            let targetScreen = NSScreen.screens.first(
                where: { displayIdentifier(for: $0) == placement.displayID }
            )
        else {
            return false
        }

        let visibleFrame = targetScreen.visibleFrame
        let size = NSSize(
            width: CGFloat(placement.width),
            height: CGFloat(placement.height)
        )
        let availableWidth = max(0, visibleFrame.width - size.width)
        let availableHeight = max(0, visibleFrame.height - size.height)
        let origin = NSPoint(
            x: visibleFrame.minX
                + availableWidth * CGFloat(min(max(placement.relativeX, 0), 1)),
            y: visibleFrame.minY
                + availableHeight * CGFloat(min(max(placement.relativeY, 0), 1))
        )

        isRestoringPlacement = true
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        isRestoringPlacement = false
        return true
    }

    private func savePlacementNow() {
        guard
            let panel = window,
            let configurationKey = currentDisplayConfigurationKey(),
            let targetScreen = panel.screen ?? NSScreen.screens.max(by: {
                intersectionArea(panel.frame, $0.visibleFrame)
                    < intersectionArea(panel.frame, $1.visibleFrame)
            })
        else {
            return
        }

        let visibleFrame = targetScreen.visibleFrame
        let availableWidth = max(0, visibleFrame.width - panel.frame.width)
        let availableHeight = max(0, visibleFrame.height - panel.frame.height)
        let relativeX = availableWidth > 0
            ? (panel.frame.minX - visibleFrame.minX) / availableWidth
            : 0
        let relativeY = availableHeight > 0
            ? (panel.frame.minY - visibleFrame.minY) / availableHeight
            : 0
        let placement = SavedPanelPlacement(
            displayID: displayIdentifier(for: targetScreen),
            relativeX: Double(min(max(relativeX, 0), 1)),
            relativeY: Double(min(max(relativeY, 0), 1)),
            width: Double(panel.frame.width),
            height: Double(panel.frame.height)
        )

        var placements = savedPlacements()
        placements[configurationKey] = placement
        guard let data = try? JSONEncoder().encode(placements) else { return }
        UserDefaults.standard.set(data, forKey: Self.placementsKey)
    }

    private func savedPlacements() -> [String: SavedPanelPlacement] {
        guard
            let data = UserDefaults.standard.data(forKey: Self.placementsKey),
            let placements = try? JSONDecoder().decode(
                [String: SavedPanelPlacement].self,
                from: data
            )
        else {
            return [:]
        }
        return placements
    }

    private func currentDisplayConfigurationKey() -> String? {
        let identifiers = NSScreen.screens.map(displayIdentifier).sorted()
        guard !identifiers.isEmpty else { return nil }
        return identifiers.joined(separator: "|")
    }

    private func displayIdentifier(for screen: NSScreen) -> String {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            return "screen-\(screen.localizedName)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        }

        let displayID = CGDirectDisplayID(number.uint32Value)
        guard
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
            let value = CFUUIDCreateString(nil, uuid)
        else {
            return "display-\(displayID)"
        }
        return value as String
    }

    private func positionAtTopRight() {
        guard let panel = window as? NSPanel else { return }
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 16,
            y: visibleFrame.maxY - panel.frame.height - 12
        )
        panel.setFrameOrigin(origin)
    }

    private func constrainToVisibleScreen() {
        guard let panel = window, !isConstrainingFrame else { return }

        let targetScreen = panel.screen ?? NSScreen.screens.max {
            intersectionArea(panel.frame, $0.visibleFrame) <
                intersectionArea(panel.frame, $1.visibleFrame)
        }
        guard let visibleFrame = targetScreen?.visibleFrame else { return }

        var frame = panel.frame
        frame.size.width = min(
            max(frame.width, panel.minSize.width),
            min(panel.maxSize.width, visibleFrame.width)
        )
        frame.size.height = min(
            max(frame.height, panel.minSize.height),
            min(panel.maxSize.height, visibleFrame.height)
        )
        frame.origin.x = min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )

        guard frame != panel.frame else { return }
        isConstrainingFrame = true
        panel.setFrame(frame, display: true)
        isConstrainingFrame = false
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        return intersection.width * intersection.height
    }
}
