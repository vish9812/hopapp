import AppKit
import DiagnosticCore

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SwitcherOverlay {
    private let panel: NSPanel
    private let iconProvider: (NSRunningApplication) -> NSImage?
    private let visibleFrame: () -> NSRect?
    private var content: NSStackView?
    private var rows: [String: NSStackView] = [:]
    private var icons: [String: NSImage] = [:]
    private var visibleIDs: [String] = []
    private var mode: SwitchingMode?
    private var footer: NSTextField?

    init(panel: NSPanel? = nil, iconProvider: @escaping (NSRunningApplication) -> NSImage? = { $0.icon },
         visibleFrame: @escaping () -> NSRect? = {
             let pointer = NSEvent.mouseLocation
             return (NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main)?.visibleFrame
         }) {
        self.panel = panel ?? Self.makePanel()
        self.iconProvider = iconProvider
        self.visibleFrame = visibleFrame
    }

    private static func makePanel() -> NSPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "hopapp switcher"
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        return panel
    }

    func hide() {
        panel.orderOut(nil)
        content = nil
        rows.removeAll()
        icons.removeAll()
        visibleIDs.removeAll()
        mode = nil
        footer = nil
    }

    func show(_ session: SwitchingSession, targets: [String: WindowTarget]) {
        guard session.windows.count > 1 else { hide(); return }
        guard let visibleFrame = visibleFrame() else { return }
        let limit = max(1, min(9, Int((visibleFrame.height - 120) / 52)))
        let start = min(max(0, session.selectedIndex - limit / 2), max(0, session.windows.count - limit))
        let end = min(session.windows.count, start + limit)
        let width = min(420, visibleFrame.width - 32)
        let height = CGFloat(end - start) * 52 + 80
        let frame = NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        let ids = (start..<end).compactMap { targets[session.windows[$0].id]?.window.id }
        let isNewContent = content == nil
        let content = self.content ?? makeContent(size: frame.size)
        if ids != visibleIDs || mode != session.mode {
            for (id, row) in rows where !ids.contains(id) || mode != session.mode {
                content.removeArrangedSubview(row)
                row.removeFromSuperview()
                rows.removeValue(forKey: id)
            }
            for (index, id) in ids.enumerated() {
                guard let target = targets[id] else { continue }
                let row = rows[id] ?? makeRow(target, mode: session.mode)
                if rows[id] == nil {
                    rows[id] = row
                    content.insertArrangedSubview(row, at: index + 1)
                    row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true
                } else if content.arrangedSubviews[index + 1] !== row {
                    content.removeArrangedSubview(row)
                    content.insertArrangedSubview(row, at: index + 1)
                }
            }
            let header = content.arrangedSubviews.first as? NSTextField
            header?.stringValue = session.mode == .applications ? "Applications" : "Windows"
            visibleIDs = ids
            mode = session.mode
        }
        updateSelection(session)
        if isNewContent {
            self.content = content
            panel.contentView = content
            panel.orderFrontRegardless()
        }
    }

    private func makeContent(size: NSSize) -> NSStackView {
        let content = NSStackView(frame: NSRect(origin: .zero, size: size))
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        content.layer?.cornerRadius = 16
        let header = label("", size: 13)
        header.textColor = .lightGray
        content.addArrangedSubview(header)
        let footer = label("", size: 11)
        footer.textColor = .lightGray
        content.addArrangedSubview(footer)
        self.footer = footer
        return content
    }

    private func makeRow(_ target: WindowTarget, mode: SwitchingMode) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        let icon = NSImageView()
        let appID = target.window.applicationID
        if icons[appID] == nil {
            icons[appID] = iconProvider(target.app)
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 32, height: 32))
        }
        icon.image = icons[appID]
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        row.addArrangedSubview(icon)
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let primary = label(mode == .applications ? target.appName : target.title, size: 15)
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.addArrangedSubview(primary)
        if mode == .windows {
            let secondary = label(target.appName, size: 11)
            secondary.textColor = .lightGray
            text.addArrangedSubview(secondary)
        }
        row.addArrangedSubview(text)
        row.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return row
    }

    private func updateSelection(_ session: SwitchingSession) {
        for (id, row) in rows {
            let selected = id == session.selected.id
            let color = (selected ? NSColor.controlAccentColor : .clear).cgColor
            if row.layer?.backgroundColor != color { row.layer?.backgroundColor = color }
            if let text = row.arrangedSubviews.last as? NSStackView,
               let primary = text.arrangedSubviews.first as? NSTextField {
                row.setAccessibilityLabel("\(selected ? "Selected: " : "")\(primary.stringValue)")
            }
        }
        let text = "\(session.selectedIndex + 1) of \(session.windows.count) · Release Option to switch · Esc to cancel"
        if footer?.stringValue != text { footer?.stringValue = text }
    }

    private func label(_ text: String, size: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingMiddle
        field.maximumNumberOfLines = 1
        return field
    }
}
