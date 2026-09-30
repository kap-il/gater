import Foundation
import G8rCore
import G8rSymbols

// Prints the living map of a repo as JSON: `g8r-map [--html] [repo]`.
// With --html it prints the viewer page with the map in it instead.

var arguments = Array(CommandLine.arguments.dropFirst())
let html = arguments.first == "--html"
if html { arguments.removeFirst() }
guard arguments.count <= 1, arguments.first?.hasPrefix("-") != true else {
    FileHandle.standardError.write(Data("usage: g8r-map [--html] [repo]\n".utf8))
    exit(2)
}

let path = URL(fileURLWithPath: arguments.first ?? ".").standardizedFileURL.path
do {
    let map = try StandardMap.build(planRoot: path)
    if html {
        FileHandle.standardOutput.write(Data(try MapViewer.page(for: map).utf8))
    } else {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(map) + Data("\n".utf8))
    }
} catch {
    FileHandle.standardError.write(Data("g8r-map: \(error)\n".utf8))
    exit(1)
}
