import Cocoa

final class AppController: NSObject {
    let engine = MetalEngine.shared

    private var scopes: [ScopeKind: ScopeWindowController] = [:]
    private var controlWindow: NSWindow!
    private var toggles: [ScopeKind: NSButton] = [:]
    private var sourcePopup: NSPopUpButton!
    private var formatLabel: NSTextField!

    private var current: VideoSource?
    private var descriptors: [(name: String, make: () -> VideoSource)] = []

    func launch() {
        buildScopeWindows()
        buildControlWindow()
        rebuildSources()
        // prefer a connected DeckLink device, fall back to the test pattern
        let defaultIndex = descriptors.firstIndex { $0.name.hasPrefix("DeckLink") } ?? 0
        if !descriptors.isEmpty {
            sourcePopup.selectItem(at: defaultIndex)
            selectSource(at: defaultIndex)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - scope windows (2×2 cascade on the main screen)

    private func buildScopeWindows() {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cols: CGFloat = 3
        let gap: CGFloat = 14
        let cellW: CGFloat = 430, cellH: CGFloat = 410
        let baseX = vf.minX + 160
        let baseY = vf.maxY - cellH - 30

        for (i, kind) in ScopeKind.allCases.enumerated() {
            let col = CGFloat(i % Int(cols))
            let row = CGFloat(i / Int(cols))
            let origin = CGPoint(x: baseX + col * (cellW + gap),
                                 y: baseY - row * (cellH + gap))
            let wc = ScopeWindowController(kind: kind, origin: origin)
            wc.onVisibilityChanged = { [weak self] in self?.refreshToggles() }
            scopes[kind] = wc
            wc.show()
        }
    }

    // MARK: - control panel

    private func buildControlWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Scopes — control"
        w.isReleasedWhenClosed = false
        if let vf = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: vf.minX + 24, y: vf.maxY - 400))
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionLabel("Source"))
        sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        stack.addArrangedSubview(sourcePopup)

        formatLabel = NSTextField(labelWithString: "—")
        formatLabel.textColor = .secondaryLabelColor
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.lineBreakMode = .byWordWrapping
        formatLabel.maximumNumberOfLines = 2
        formatLabel.preferredMaxLayoutWidth = 280
        stack.addArrangedSubview(formatLabel)

        let onTop = NSButton(checkboxWithTitle: "Keep settings on top",
                             target: self, action: #selector(toggleSettingsOnTop(_:)))
        stack.addArrangedSubview(onTop)

        stack.addArrangedSubview(spacer(8))
        let instrHeader = NSStackView()
        instrHeader.orientation = .horizontal
        instrHeader.spacing = 6
        instrHeader.addArrangedSubview(sectionLabel("Instruments"))
        let hint = NSTextField(labelWithString: "📌 pin · ⤢ full screen")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        instrHeader.addArrangedSubview(hint)
        stack.addArrangedSubview(instrHeader)

        for kind in ScopeKind.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.distribution = .fill

            // pin + full-screen icons on the left
            let pin = NSButton(title: "📌", target: self, action: #selector(togglePin(_:)))
            pin.tag = kind.rawValue
            pin.bezelStyle = .rounded
            pin.setButtonType(.pushOnPushOff)
            pin.toolTip = "Pin this scope above all windows"
            pin.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(pin)

            let fs = NSButton(title: "⤢", target: self, action: #selector(fullscreenScope(_:)))
            fs.tag = kind.rawValue
            fs.bezelStyle = .rounded
            fs.toolTip = "Full screen this scope"
            fs.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(fs)

            // scope on/off checkbox fills the remaining width
            let cb = NSButton(checkboxWithTitle: kind.title, target: self,
                              action: #selector(toggleScope(_:)))
            cb.tag = kind.rawValue
            cb.state = .on
            cb.setContentHuggingPriority(.defaultLow, for: .horizontal)
            toggles[kind] = cb
            row.addArrangedSubview(cb)

            // vectorscope: variable magnification slider on its own row
            if kind == .vectorscope {
                let slider = NSSlider(value: 1.0, minValue: 1.0, maxValue: 5.0,
                                      target: self, action: #selector(vectorGainSlider(_:)))
                slider.isContinuous = true
                slider.toolTip = "Vectorscope magnification ×1–×5 (≈×2 for DSC ChromaDuMonde)"
                slider.translatesAutoresizingMaskIntoConstraints = false
                slider.widthAnchor.constraint(equalToConstant: 100).isActive = true
                row.addArrangedSubview(slider)
            }

            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 288).isActive = true
        }

        let skinCb = NSButton(checkboxWithTitle: "Skin-tone targets (CDM12)",
                              target: self, action: #selector(toggleSkinTargets(_:)))
        skinCb.toolTip = "Highlight CDM12 skin-tone reference points along the I-line"
        stack.addArrangedSubview(skinCb)

        stack.addArrangedSubview(spacer(8))
        let allRow = NSStackView()
        allRow.orientation = .horizontal
        allRow.spacing = 8
        allRow.addArrangedSubview(NSButton(title: "Show all", target: self, action: #selector(showAll)))
        allRow.addArrangedSubview(NSButton(title: "Hide all", target: self, action: #selector(hideAll)))
        stack.addArrangedSubview(allRow)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        w.contentView = content
        w.makeKeyAndOrderFront(nil)
        controlWindow = w
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 12)
        return l
    }
    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: - sources

    private func rebuildSources() {
        descriptors = [("Test pattern (75% bars)", { TestPatternSource() })]
        descriptors.append(contentsOf: DeckLinkSource.availableDevices())
        sourcePopup.removeAllItems()
        sourcePopup.addItems(withTitles: descriptors.map { $0.name })
    }

    private func selectSource(at index: Int) {
        guard index >= 0 && index < descriptors.count else { return }
        current?.stop()
        let src = descriptors[index].make()
        src.onFrame = { [weak self] f in self?.engine.submit(f) }
        src.onFormat = { [weak self] s in
            DispatchQueue.main.async { self?.formatLabel.stringValue = s }
        }
        current = src
        src.start()
    }

    // MARK: - actions

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        selectSource(at: sender.indexOfSelectedItem)
    }

    @objc private func toggleScope(_ sender: NSButton) {
        guard let kind = ScopeKind(rawValue: sender.tag), let wc = scopes[kind] else { return }
        if sender.state == .on { wc.show() } else { wc.hide() }
    }

    @objc private func fullscreenScope(_ sender: NSButton) {
        guard let kind = ScopeKind(rawValue: sender.tag), let wc = scopes[kind] else { return }
        wc.show()
        DispatchQueue.main.async {
            if !wc.window.styleMask.contains(.fullScreen) { wc.toggleFullScreen() }
        }
    }

    @objc private func togglePin(_ sender: NSButton) {
        guard let kind = ScopeKind(rawValue: sender.tag), let wc = scopes[kind] else { return }
        if sender.state == .on { wc.show() }
        wc.setPinned(sender.state == .on)
    }

    @objc private func toggleSettingsOnTop(_ sender: NSButton) {
        controlWindow.level = (sender.state == .on) ? .floating : .normal
    }

    @objc private func vectorGainSlider(_ sender: NSSlider) {
        engine.vectorGain = Float(sender.doubleValue)
        scopes[.vectorscope]?.container.refreshOverlay()
    }

    @objc private func toggleSkinTargets(_ sender: NSButton) {
        engine.showSkinTargets = (sender.state == .on)
        scopes[.vectorscope]?.container.refreshOverlay()
    }

    @objc private func showAll() {
        for (_, wc) in scopes { wc.show() }
        refreshToggles()
    }
    @objc private func hideAll() {
        for (_, wc) in scopes { wc.hide() }
        refreshToggles()
    }

    private func refreshToggles() {
        for (kind, wc) in scopes { toggles[kind]?.state = wc.isVisible ? .on : .off }
    }
}
