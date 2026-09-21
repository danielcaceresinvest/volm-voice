import Foundation

/// What `openclaw acp` streams back during a prompt turn (ACP `session/update`).
public enum ACPUpdate: Equatable {
    case agentChunk(String)
    case thoughtChunk
    case toolCall(id: String, kind: String?, title: String?)
    case toolUpdate(id: String, status: String?)
    case other(String)
}

public enum ACPInbound {
    case response(id: Int, result: [String: Any]?, error: [String: Any]?)
    case update(sessionId: String?, ACPUpdate)
    /// A request the agent sends to us, such as `session/request_permission`.
    case request(id: Any, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])
}

/// Newline-delimited JSON-RPC 2.0, as spoken by `openclaw acp` on stdio.
public enum ACPCodec {
    public static func request(id: Int, method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    public static func notification(method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    public static func response(id: Any, result: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    public static func textPrompt(sessionId: String, text: String) -> [String: Any] {
        ["sessionId": sessionId, "prompt": [["type": "text", "text": text]]]
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) -> ACPInbound? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let method = object["method"] as? String
        let params = object["params"] as? [String: Any] ?? [:]
        if let method, let id = object["id"] {
            return .request(id: id, method: method, params: params)
        }
        if let method {
            if method == "session/update", let update = params["update"] as? [String: Any] {
                return .update(sessionId: params["sessionId"] as? String, decodeUpdate(update))
            }
            return .notification(method: method, params: params)
        }
        if let id = (object["id"] as? NSNumber)?.intValue {
            return .response(id: id, result: object["result"] as? [String: Any], error: object["error"] as? [String: Any])
        }
        return nil
    }

    static func decodeUpdate(_ update: [String: Any]) -> ACPUpdate {
        let kind = update["sessionUpdate"] as? String ?? ""
        switch kind {
        case "agent_message_chunk":
            let content = update["content"] as? [String: Any]
            return .agentChunk(content?["text"] as? String ?? "")
        case "agent_thought_chunk":
            return .thoughtChunk
        case "tool_call":
            return .toolCall(id: update["toolCallId"] as? String ?? "", kind: update["kind"] as? String, title: update["title"] as? String)
        case "tool_call_update":
            return .toolUpdate(id: update["toolCallId"] as? String ?? "", status: update["status"] as? String)
        default:
            return .other(kind)
        }
    }

    /// Short Spanish status for the island while a tool runs.
    public static func status(forToolKind kind: String?) -> String {
        switch kind {
        case "fetch": return "Consultando la web"
        case "search": return "Buscando"
        case "read": return "Leyendo archivos"
        case "edit": return "Escribiendo"
        case "delete", "move": return "Ordenando archivos"
        case "execute": return "Trabajando en tu Mac"
        case "think": return "Pensando"
        default: return "Trabajando"
        }
    }
}
