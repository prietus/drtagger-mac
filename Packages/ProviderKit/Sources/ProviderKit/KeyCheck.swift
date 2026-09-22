import Foundation

// Outcome of testing an API key against its service.
public enum KeyCheck: Sendable, Equatable {
    case valid(String)        // "Key accepted", "Signed in as carlos"
    case invalid(String)      // the service rejected the key
    case unreachable(String)  // network or server trouble; says nothing about the key

    public var message: String {
        switch self {
        case .valid(let m), .invalid(let m), .unreachable(let m): return m
        }
    }
}

extension AcoustIDClient {
    // A lookup with a junk fingerprint: a bad key answers error code 4
    // ("invalid API key"); a good one complains about the fingerprint instead.
    public func validateKey() async -> KeyCheck {
        guard !clientKey.isEmpty else { return .invalid("No key entered") }
        var req = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let key = clientKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? clientKey
        req.httpBody = Data("client=\(key)&format=json&duration=1&fingerprint=AQAAAA".utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreachable("Unexpected answer from AcoustID") }
            if root["status"] as? String == "ok" { return .valid("Key accepted") }
            let error = root["error"] as? [String: Any]
            let code = error?["code"] as? Int ?? 0
            let message = error?["message"] as? String ?? "error"
            return code == 4 ? .invalid(message) : .valid("Key accepted (\(message))")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

extension DiscogsClient {
    // /oauth/identity answers with the account behind a personal token.
    public func validateToken() async -> KeyCheck {
        guard !token.isEmpty else { return .invalid("No token entered") }
        var req = URLRequest(url: URL(string: "https://api.discogs.com/oauth/identity")!, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let user = root["username"] as? String {
                return .valid("Signed in as \(user)")
            }
            if status == 401 || status == 403 { return .invalid("Discogs rejected the token (HTTP \(status))") }
            return .unreachable("Discogs answered HTTP \(status)")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

extension FanartClient {
    // Any artist request works as a probe: a bad key is refused outright.
    public func validateKey() async -> KeyCheck {
        guard !apiKey.isEmpty else { return .invalid("No key entered") }
        var components = URLComponents(string: "https://webservice.fanart.tv/v3/music/561d854a-6a28-4aa7-8c99-323e6ce46c2a")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        var req = URLRequest(url: components.url!, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200, 404: return .valid("Key accepted")
            case 401, 403:
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return .invalid((root?["error message"] as? String) ?? "fanart.tv rejected the key (HTTP \(status))")
            default: return .unreachable("fanart.tv answered HTTP \(status)")
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
