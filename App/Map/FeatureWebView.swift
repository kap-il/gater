import AppKit
import GaterCore

/// Web view (spec §4.11): feature nodes plus "uses" edges from LSP — where
/// conflicts live. Nodes sit on a circle; an arrow points from the using
/// feature to the owner; overlapping edges are red.
final class FeatureWebView: NSView {
    private var features: [MapModel.FeatureNode] = []
    private var edges: [MapModel.UsageEdge] = []

    override var isFlipped: Bool { true }

    func update(features: [MapModel.FeatureNode], edges: [MapModel.UsageEdge]) {
        self.features = features
        self.edges = edges
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard !features.isEmpty else {
            let text = NSAttributedString(string: "No features yet.", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            text.draw(at: NSPoint(x: 12, y: 12))
            return
        }

        let centers = nodeCenters()
        let radius: CGFloat = 34

        // Edges under nodes.
        for edge in edges {
            guard let from = centers[edge.user], let to = centers[edge.owner] else { continue }
            drawArrow(from: from, to: to, inset: radius + 4,
                      color: edge.overlapping ? .systemRed : .secondaryLabelColor,
                      width: edge.overlapping ? 2.5 : 1.5,
                      label: edge.symbols.map { $0.split(separator: "#").last.map(String.init) ?? $0 }.joined(separator: ", "))
        }

        for feature in features {
            guard let center = centers[feature.name] else { continue }
            let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let circle = NSBezierPath(ovalIn: rect)
            FeatureCardView.color(feature.status).withAlphaComponent(0.25).setFill()
            circle.fill()
            (feature.flags.isEmpty ? FeatureCardView.color(feature.status) : NSColor.systemRed).setStroke()
            circle.lineWidth = feature.flags.isEmpty ? 2 : 3
            circle.stroke()

            let name = NSAttributedString(string: feature.name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.labelColor,
            ])
            let size = name.size()
            name.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2 - 6))
            let status = NSAttributedString(string: feature.status.rawValue, attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let statusSize = status.size()
            status.draw(at: NSPoint(x: center.x - statusSize.width / 2, y: center.y + 4))
        }
    }

    /// Nodes evenly on a circle (one node: centered).
    private func nodeCenters() -> [String: NSPoint] {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard features.count > 1 else { return [features[0].name: center] }
        let ring = max(min(bounds.width, bounds.height) / 2 - 60, 60)
        var points: [String: NSPoint] = [:]
        for (index, feature) in features.enumerated() {
            let angle = -CGFloat.pi / 2 + CGFloat(index) * 2 * .pi / CGFloat(features.count)
            points[feature.name] = NSPoint(x: center.x + ring * cos(angle), y: center.y + ring * sin(angle))
        }
        return points
    }

    private func drawArrow(from: NSPoint, to: NSPoint, inset: CGFloat, color: NSColor, width: CGFloat, label: String) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 1)
        let ux = dx / length, uy = dy / length
        let start = NSPoint(x: from.x + ux * inset, y: from.y + uy * inset)
        let end = NSPoint(x: to.x - ux * inset, y: to.y - uy * inset)

        color.setStroke()
        color.setFill()
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        line.lineWidth = width
        line.stroke()

        let head = NSBezierPath()
        let size: CGFloat = 9
        head.move(to: end)
        head.line(to: NSPoint(x: end.x - ux * size - uy * size * 0.6, y: end.y - uy * size + ux * size * 0.6))
        head.line(to: NSPoint(x: end.x - ux * size + uy * size * 0.6, y: end.y - uy * size - ux * size * 0.6))
        head.close()
        head.fill()

        let text = NSAttributedString(string: "uses \(label)", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: color,
        ])
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        text.draw(at: NSPoint(x: mid.x - text.size().width / 2 + uy * 10, y: mid.y - ux * 10 - 6))
    }
}
