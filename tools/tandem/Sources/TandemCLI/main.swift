import Foundation

// `tandem`: see Help.swift for the commands and CLI.swift for how they run.
let status = await CLI(
    arguments: Array(CommandLine.arguments.dropFirst()),
    directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: ProcessInfo.processInfo.environment
).run()
exit(status)
