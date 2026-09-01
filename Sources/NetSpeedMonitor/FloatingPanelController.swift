import AppKit
import SwiftUI

private final class EdgeConstrainedPanel: NSPanel {
    static let minimumSize = NSSize(width: 82, height: 52)
    static let maximumSize = NSSize(width: 720, height: 480)
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
            var resizedFrame = initialFrame

            if edges.contains(.left) {
                resizedFrame.origin.x += deltaX
                resizedFrame.size.width -= deltaX
            }
            if edges.contains(.right) {
                resizedFrame.size.width += deltaX
            }
            if edges.contains(.bottom) {
                resizedFrame.origin.y += deltaY
                resizedFrame.size.height -= deltaY
            }
            if edges.contains(.top) {
                resizedFrame.size.height += deltaY
            }

            if resizedFrame.width < Self.minimumSize.width, edges.contains(.left) {
                resizedFrame.origin.x = initialFrame.maxX - Self.minimumSize.width
            }
            if resizedFrame.height < Self.minimumSize.height, edges.contains(.bottom) {
                resizedFrame.origin.y = initialFrame.maxY - Self.minimumSize.height
            }

            setFrame(resizedFrame, display: true)
        }

        saveFrame(usingName: "NetSpeedMonitorFloatingPanel")
    }

    private func constrainedFrame(_ proposedFrame: NSRect) -> NSRect {
        var frame = proposedFrame
        frame.size.width = min(
            max(frame.width, Self.minimumSize.width),
            Self.maximumSize.width
        )
        frame.size.height = min(
            max(frame.height, Self.minimumSize.height),
            Self.maximumSize.height
        )

        let targetScreen = screen ?? NSScreen.screens.max {
            intersectionArea(frame, $0.visibleFrame) <
                intersectionArea(frame, $1.visibleFrame)
        }
        guard let visibleFrame = targetScreen?.visibleFrame else { return frame }

        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
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
    private var isConstrainingFrame = false

    init(
        monitor: TrafficMonitor,
        settings: AppSettings,
        openSettings: @escaping () -> Void
    ) {
        let size = NSSize(width: 118, height: 70)
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
        panel.level = .floating
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

        super.init(window: panel)
        panel.delegate = self

        if !panel.setFrameUsingName("NetSpeedMonitorFloatingPanel") {
            positionAtTopRight()
        }
        panel.setFrameAutosaveName("NetSpeedMonitorFloatingPanel")
        constrainToVisibleScreen()

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

    func windowDidMove(_ notification: Notification) {
        constrainToVisibleScreen()
    }

    func windowDidResize(_ notification: Notification) {
        constrainToVisibleScreen()
    }

    @objc private func screenParametersChanged() {
        constrainToVisibleScreen()
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
