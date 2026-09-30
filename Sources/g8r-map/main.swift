import Foundation
import G8rSymbols

// Prints the living map of a repo as JSON: `g8r-map [repo]`.

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count <= 1, arguments.first?.hasPrefix("-") != true else {
    FileHandle.standardError.write(Data("usage: g8r-map [repo]\n".utf8))
    exit(2)
}

let path = URL(fileURLWithPath: arguments.first ?? ".").standardizedFileURL.path
do {
    let map = try StandardMap.build(planRoot: path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(map) + Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("g8r-map: \(error)\n".utf8))
    exit(1)
}
