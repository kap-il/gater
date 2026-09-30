import Foundation
import G8rCore

/// The map as the app and `g8r-map` draw it: tree-sitter symbols and every
/// stage, in order.
public enum StandardMap {
    /// A stage is added here when the component that makes it is merged.
    public static var stages: [MapStage] { [] }

    /// - Parameters:
    ///   - codeRoot: where to measure the code. By default the integration
    ///     worktree, where built components land, once it exists, and the
    ///     plan root until then.
    ///   - extract: whether a model may be asked to read a free-form plan
    ///     doc that isn't cached. The app says yes when a plan doc changes
    ///     on disk or the user asks, never on a routine redraw.
    public static func build(planRoot: String, codeRoot: String? = nil,
                             extract: Bool = false) throws -> LivingMap {
        try LivingMapBuilder.build(planRoot: planRoot,
                                   codeRoot: codeRoot ?? self.codeRoot(planRoot: planRoot),
                                   scanner: TreeSitterScanner(),
                                   stages: stages,
                                   extractor: .forMap(planRoot: planRoot, extract: extract))
    }

    static func codeRoot(planRoot: String) -> String {
        let integration = Integrator(repoRoot: planRoot).worktree
        return GitWorktree.head(of: integration) != nil ? integration : planRoot
    }
}
