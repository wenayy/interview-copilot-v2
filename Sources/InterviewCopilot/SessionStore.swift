import Foundation

/// Saves the current session's memory to
/// ~/Library/Application Support/InterviewCopilot/session.json, so relaunching
/// the app mid-meeting (e.g. after granting a permission) doesn't lose it.
/// New session overwrites it with an empty session.
enum SessionStore {
    private static var url: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first?
            .appendingPathComponent("InterviewCopilot", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    static func load() -> SessionMemory {
        guard let url, let data = try? Data(contentsOf: url),
              let memory = try? JSONDecoder().decode(SessionMemory.self, from: data)
        else { return SessionMemory() }
        return memory
    }

    static func save(_ memory: SessionMemory) {
        guard let url, let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
