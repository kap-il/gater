import AppKit
import GaterCore

/// The map (spec §4.11): one data model, switchable views. Tree is the
/// default; the raw event feed stays available as a tab.
final class MapView: NSView {
    private let tabs = NSSegmentedControl(labels: ["Tree", "Web", "Events"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let tree = FeatureTreeView()
    private let webPlaceholder = NSTextField(labelWithString: "Web view (feature \"uses\" edges): coming next.")
    private let eventFeed: EventFeedView
    private var pages: [NSView] { [tree, webPlaceholder, eventFeed] }

    init(eventFeed: EventFeedView) {
        self.eventFeed = eventFeed
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 700))
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        webPlaceholder.textColor = .secondaryLabelColor
        webPlaceholder.alignment = .center
        // Pinned top-to-bottom, a label's default hugging (750) would pull
        // the whole window down to its text height.
        webPlaceholder.setContentHuggingPriority(.defaultLow, for: .vertical)
        addSubview(tabs)
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
                page.leadingAnchor.constraint(equalTo: leadingAnchor),
                page.trailingAnchor.constraint(equalTo: trailingAnchor),
                page.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            tabs.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        tabChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tabChanged() {
        for (index, page) in pages.enumerated() { page.isHidden = index != tabs.selectedSegment }
    }

    func selectTab(_ index: Int) {
        tabs.selectedSegment = index
        tabChanged()
    }

    func update(features: [MapModel.FeatureNode], activity: [String: MapModel.Activity]) {
        tree.update(features: features, activity: activity)
    }
}

/// Tree view: orchestrator → features → dishes/agents, as a scrolling
/// column of cards.
final class FeatureTreeView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// Features whose file list is expanded (survives refreshes).
    private var expanded: Set<String> = []
    /// GATER_DEBUG_MAP_EXPAND=1: every file list open (for snapshots).
    private let expandAll = ProcessInfo.processInfo.environment["GATER_DEBUG_MAP_EXPAND"] != nil
    private var last: ([MapModel.FeatureNode], [String: MapModel.Activity]) = ([], [:])

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 12, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(features: [MapModel.FeatureNode], activity: [String: MapModel.Activity]) {
        last = (features, activity)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        stack.addArrangedSubview(orchestratorStrip(activity["orch"]))
        if features.isEmpty {
            let empty = Label.make("No features yet. They appear when the orchestrator delegates work.",
                                   size: 12, color: .secondaryLabelColor)
            stack.addArrangedSubview(empty)
        }
        for feature in features {
            let card = FeatureCardView(feature: feature, activity: activity,
                                       expanded: expandAll || expanded.contains(feature.name))
            card.onToggleFiles = { [weak self] in
                guard let self else { return }
                if !self.expanded.insert(feature.name).inserted { self.expanded.remove(feature.name) }
                self.update(features: self.last.0, activity: self.last.1)
            }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    private func orchestratorStrip(_ activity: MapModel.Activity?) -> NSView {
        let text = "orchestrator" + (activity.map { "  ·  \($0.text)" } ?? "")
        return Label.make(text, size: 11, weight: .semibold, color: .secondaryLabelColor)
    }
}

/// One feature node card (spec §4.11): header + status, flags, dishes
/// (directive, agent, what it's doing now), and owned files → symbols.
final class FeatureCardView: NSView {
    var onToggleFiles: (() -> Void)?

    init(feature: MapModel.FeatureNode, activity: [String: MapModel.Activity], expanded: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = feature.flags.isEmpty ? 1 : 1.5
        layer?.borderColor = (feature.flags.isEmpty ? NSColor.separatorColor : NSColor.systemRed).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 5
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        // Header: name + status pill.
        let header = NSStackView(views: [Label.make(feature.name, size: 14, weight: .bold),
                                         Self.pill(feature.status)])
        header.spacing = 8
        content.addArrangedSubview(header)

        // Flags first: they're what needs attention.
        for flag in feature.flags {
            content.addArrangedSubview(Label.make("⚠ " + flag.summary, size: 11, color: .systemRed, wraps: true))
            var verdict = "Jev: review pending"
            if let v = flag.verdict {
                verdict = "Jev: \(v)" + (flag.confidence.map { String(format: " %.2f", $0) } ?? "")
            }
            if flag.woke { verdict += " · orchestrator woken" }
            content.addArrangedSubview(Label.make("   " + verdict, size: 10, color: .secondaryLabelColor))
        }

        for dish in feature.dishes {
            let who = dish.pane ?? "unassigned"
            content.addArrangedSubview(Label.make("\(dish.id) · \(who) · \(dish.state.rawValue)",
                                                  size: 11, weight: .semibold, color: Self.color(dish.state)))
            content.addArrangedSubview(Label.make(dish.directive, size: 12, wraps: true))
            if let pane = dish.pane, let now = activity[pane] {
                content.addArrangedSubview(Label.make("now: \(now.text)", size: 10, color: .secondaryLabelColor, wraps: true))
            }
            for instruction in dish.instructions {
                content.addArrangedSubview(Label.make("↳ instruct: \(instruction)", size: 10,
                                                      color: .systemOrange, wraps: true))
            }
            if let did = dish.did {
                let assumed = dish.assumed.map { $0.isEmpty ? "" : " · assumed: \($0)" } ?? ""
                content.addArrangedSubview(Label.make("done: \(did)\(assumed)", size: 10,
                                                      color: .secondaryLabelColor, wraps: true))
            }
        }

        // Files → symbols dropdown.
        let fileCount = feature.files.count
        if fileCount > 0 {
            let toggle = NSButton(title: "\(expanded ? "▾" : "▸") Files (\(fileCount))", target: self,
                                  action: #selector(toggleFiles))
            toggle.isBordered = false
            toggle.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            toggle.contentTintColor = .secondaryLabelColor
            content.addArrangedSubview(toggle)
            if expanded {
                for file in feature.files.keys.sorted() {
                    content.addArrangedSubview(Label.make("  " + file, size: 11, weight: .medium, color: .labelColor))
                    let chips = NSStackView(views: feature.files[file]!.map(SymbolChip.init))
                    chips.spacing = 4
                    let row = NSStackView(views: [NSView.spacer(width: 12), chips])
                    content.addArrangedSubview(row)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggleFiles() { onToggleFiles?() }

    static func color(_ state: DishState) -> NSColor {
        switch state {
        case .cooking: return .systemOrange
        case .pass: return .systemBlue
        case .finished: return .systemPurple
        case .served: return .systemGreen
        case .cancelled, .merged: return .secondaryLabelColor
        }
    }

    static func pill(_ state: DishState) -> NSView {
        let label = Label.make(" \(state.rawValue) ", size: 10, weight: .semibold, color: .white)
        label.wantsLayer = true
        label.drawsBackground = true
        label.backgroundColor = color(state)
        label.layer?.cornerRadius = 4
        return label
    }
}

/// A symbol name; uncertain ownership is drawn with a dashed border.
final class SymbolChip: NSView {
    init(_ symbol: MapModel.OwnedSymbol) {
        super.init(frame: .zero)
        let label = Label.make(symbol.name, size: 10, color: symbol.uncertain ? .secondaryLabelColor : .labelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
        toolTip = String(format: "%@ · confidence %.2f%@", symbol.id, symbol.confidence, symbol.uncertain ? " (uncertain)" : "")
        wantsLayer = true
        let border = CAShapeLayer()
        border.fillColor = nil
        border.strokeColor = (symbol.uncertain ? NSColor.secondaryLabelColor : NSColor.separatorColor).cgColor
        border.lineWidth = 1
        if symbol.uncertain { border.lineDashPattern = [3, 2] }
        layer?.addSublayer(border)
        self.border = border
    }

    private var border: CAShapeLayer?

    override func layout() {
        super.layout()
        border?.frame = bounds
        border?.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum Label {
    static func make(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = .labelColor, wraps: Bool = false) -> NSTextField {
        let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSView {
    static func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}
