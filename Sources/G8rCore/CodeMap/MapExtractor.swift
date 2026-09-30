import Foundation

extension PlanDocExtractor {
    /// Raised instead of asking a model when the map may only read the cache.
    public struct NotAsked: Error, Equatable, CustomStringConvertible {
        public var description: String {
            "it hasn't been read by a model yet, and the map only asks one when told to"
        }
    }

    /// The extractor a map is measured with. Asking a model is slow and
    /// costs money, so without `extract` a free-form doc is only read from
    /// the cache, and one that isn't there is reported as a problem.
    public static func forMap(planRoot: String, extract: Bool) -> PlanDocExtractor {
        let ask = ProcessRunner.runner(in: planRoot)
        return PlanDocExtractor(cacheDirectory: cacheDirectory(planRoot: planRoot)) { executable, arguments, stdin in
            guard extract else { throw NotAsked() }
            return try ask(executable, arguments, stdin)
        }
    }
}
