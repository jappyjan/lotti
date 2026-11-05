import Foundation

// wake-word generate | train | test   (see README.md)
// Create ML frees long chains of objects recursively with a large training set, which overflows
// the main thread's 8 MB stack. Everything runs on a thread with a big one.
let command = CommandLine.arguments.dropFirst().first ?? ""
let worker = Thread {
    do {
            switch command {
            case "generate": try Generate.run()
            case "train": try Train.run()
            case "test": try Evaluate.run()
            default:
                FileHandle.standardError.write(Data("usage: wake-word generate|train|test\n".utf8))
                exit(2)
            }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
worker.stackSize = 1 << 30
worker.start()
dispatchMain()
