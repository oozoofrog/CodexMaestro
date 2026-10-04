import Foundation

/// Older sessions can have rollout records without a thread-history projection.
enum RolloutMessagePreviewReader {
    static func read(url: URL) throws -> SessionMessagePreview? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var offset = try file.seekToEnd()
        // Keep fragments of only the current JSONL record, not the whole rollout.
        var fragments: [Data] = []
        while offset > 0 {
            let length = Int(min(offset, 64 * 1024))
            offset -= UInt64(length)
            try file.seek(toOffset: offset)
            guard let chunk = try file.read(upToCount: length), !chunk.isEmpty else { break }
            var end = chunk.endIndex
            for index in chunk.indices.reversed() where chunk[index] == 0x0A {
                var line = Data(chunk[(index + 1)..<end])
                for fragment in fragments.reversed() { line.append(fragment) }
                fragments.removeAll(keepingCapacity: true)
                if let preview = preview(from: line) { return preview }
                end = index
            }
            if end > chunk.startIndex { fragments.append(Data(chunk[..<end])) }
        }
        var firstLine = Data()
        for fragment in fragments.reversed() { firstLine.append(fragment) }
        return preview(from: firstLine)
    }

    private static func preview(from data: Data) -> SessionMessagePreview? {
        guard !data.isEmpty,
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = record["payload"] as? [String: Any],
              payload["channel"] as? String != "analysis" else { return nil }
        switch record["type"] as? String {
        case "response_item":
            guard payload["type"] as? String == "message", let role = payload["role"] as? String else { return nil }
            let text = (payload["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            return SessionMessagePreview(role: role, text: text)
        case "event_msg":
            let role: String
            switch payload["type"] as? String {
            case "user_message": role = "user"
            case "agent_message": role = "assistant"
            default: return nil
            }
            return SessionMessagePreview(role: role, text: payload["message"] as? String ?? "")
        default: return nil
        }
    }
}
