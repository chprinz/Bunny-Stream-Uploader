import Foundation
import CryptoKit

final class APIService {

    private let streamKey: String
    private let session = URLSession(configuration: .default)

    private func logResponse(_ label: String, data: Data?, response: URLResponse?, error: Error?) {
        #if DEBUG
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[API] \(label) status=\(status) error=\(String(describing: error))")
        if let data, let body = String(data: data, encoding: .utf8) {
            print("[API] body: \(body.prefix(2000))")
        }
        #endif
    }

    init(streamKey: String) {
        self.streamKey = streamKey
    }

    // Create Video Object (Stream API)
    func createVideo(
        libraryId: String,
        title: String,
        collectionId: String?,
        completion: @escaping (String?) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["title": title]
        if let c = collectionId {
            body["collectionId"] = c
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, response, error in
            self.logResponse("createVideo", data: data, response: response, error: error)
            if error != nil {
                completion(nil)
                return
            }

            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let guid = json["guid"] as? String
            else {
                completion(nil)
                return
            }

            completion(guid)
        }.resume()
    }

    // Fetch Collections for a given Library
    func fetchCollections(
        libraryId: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/collections") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")

        session.dataTask(with: req) { data, resp, error in
            self.logResponse("fetchCollections", data: data, response: resp, error: error)
            guard let data = data, error == nil else {
                completion(nil)
                return
            }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            completion(json)
        }.resume()
    }

    // Fetch paginated video list (library browse)
    func fetchLibraryVideos(
        libraryId: String,
        page: Int,
        perPage: Int,
        completion: @escaping (Int, [String: Any]?) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos?page=\(page)&itemsPerPage=\(perPage)&orderBy=dateUploaded&orderDir=desc") else {
            completion(-1, nil)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")

        session.dataTask(with: req) { data, resp, error in
            self.logResponse("fetchLibraryVideos", data: data, response: resp, error: error)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let data, error == nil else {
                completion(status, nil)
                return
            }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            completion(status, json)
        }.resume()
    }

    // Delete a Video
    func deleteVideo(
        libraryId: String,
        videoId: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)") else {
            completion(false)
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")

        session.dataTask(with: req) { _, response, error in
            self.logResponse("deleteVideo", data: nil, response: response, error: error)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Treat delete as idempotent: if the video is already gone (404), local removal should still proceed.
            let ok = (error == nil) && ((200..<300).contains(code) || code == 404)
            completion(ok)
        }.resume()
    }

    // Bunny TUS signature helper
    func generateTusSignature(
        libraryId: String,
        videoId: String,
        expire: Int? = nil
    ) -> (signature: String, expire: Int) {

        let exp = expire ?? Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let payload = "\(streamKey)\(libraryId)\(videoId)\(exp)"

        let hash = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return (hash, exp)
    }

    // Fetch video details (title, description, status, thumbnail)
    func fetchVideoDetails(
        libraryId: String,
        videoId: String,
        completion: @escaping (Int, [String: Any]?) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)") else {
            completion(-1, nil); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")

        session.dataTask(with: req) { data, resp, error in
            self.logResponse("fetchVideoDetails", data: data, response: resp, error: error)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let data, error == nil else {
                completion(status, nil); return
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            completion(status, json)
        }.resume()
    }

    // Update title / description
    func updateVideoDetails(
        libraryId: String,
        videoId: String,
        title: String?,
        description: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)") else {
            completion(false); return
        }

        // Bunny update API currently supports title, chapters, moments, metaTags; no description field.
        var payload: [String: Any] = [:]
        if let t = title { payload["title"] = t }

        let methods = ["PATCH", "POST", "PUT"]
        func attempt(_ index: Int) {
            guard index < methods.count else {
                completion(false); return
            }
            let method = methods[index]

            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue(streamKey, forHTTPHeaderField: "AccessKey")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            session.dataTask(with: req) { data, response, error in
                self.logResponse("updateVideoDetails(\(method))", data: data, response: response, error: error)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 500
                if error == nil && code < 300 {
                    completion(true)
                } else {
                    attempt(index + 1)
                }
            }.resume()
        }

        attempt(0)
    }

    // Upload custom thumbnail
    func uploadThumbnail(
        libraryId: String,
        videoId: String,
        data: Data,
        mimeType: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)/thumbnail") else {
            completion(false); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")
        req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        session.dataTask(with: req) { _, response, error in
            self.logResponse("uploadThumbnail", data: nil, response: response, error: error)
            let ok = (error == nil) && ((response as? HTTPURLResponse)?.statusCode ?? 500) < 300
            completion(ok)
        }.resume()
    }

    // Set chapters (replaces existing ones). End of each chapter = start of next; last ends at video length.
    func updateChapters(
        libraryId: String,
        videoId: String,
        chapters: [VideoChapter],
        completion: @escaping (String?) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)") else {
            completion("Invalid URL"); return
        }
        fetchVideoDetails(libraryId: libraryId, videoId: videoId) { _, json in
            let length = (json?["length"] as? Double).map { Int($0) } ?? (json?["length"] as? Int) ?? 0
            if length > 0, let bad = chapters.first(where: { $0.start >= length }) {
                completion("Chapter \"\(bad.title)\" starts at \(ChapterParser.format(bad.start)), but the video is only \(ChapterParser.format(length)) long.")
                return
            }
            var payload: [[String: Any]] = []
            for (i, c) in chapters.enumerated() {
                let next = i + 1 < chapters.count ? chapters[i + 1].start : max(length, c.start + 1)
                payload.append(["title": c.title, "start": c.start, "end": max(next, c.start + 1)])
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue(self.streamKey, forHTTPHeaderField: "AccessKey")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["chapters": payload])
            self.session.dataTask(with: req) { data, response, error in
                self.logResponse("updateChapters", data: data, response: response, error: error)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 500
                if let error { completion(error.localizedDescription); return }
                if code < 300 { completion(nil); return }
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion("HTTP \(code) \(body.prefix(200)) (video length: \(length)s)")
            }.resume()
        }
    }

    // Set moments (replaces existing ones)
    func setMoments(
        libraryId: String,
        videoId: String,
        moments: [VideoChapter],
        completion: @escaping (String?) -> Void
    ) {
        guard let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)") else {
            completion("Invalid URL"); return
        }
        fetchVideoDetails(libraryId: libraryId, videoId: videoId) { status, json in
            guard let json else {
                completion("Could not load the video from Bunny (HTTP \(status))."); return
            }
            let length = (json["length"] as? Double).map { Int($0) } ?? (json["length"] as? Int) ?? 0
            if length > 0, let bad = moments.first(where: { $0.start > length }) {
                completion("Moment \"\(bad.title)\" is at \(ChapterParser.format(bad.start)), but the video is only \(ChapterParser.format(length)) long.")
                return
            }
            let payload = moments.map { ["label": $0.title, "timestamp": $0.start] as [String: Any] }
            self.postUpdate(url: url, body: ["moments": payload], label: "setMoments", completion: completion)
        }
    }

    func deleteCaption(
        libraryId: String,
        videoId: String,
        srclang: String,
        completion: @escaping (String?) -> Void
    ) {
        guard let escaped = srclang.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)/captions/\(escaped)") else {
            completion("Invalid language code"); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")
        session.dataTask(with: req) { data, response, error in
            self.logResponse("deleteCaption", data: data, response: response, error: error)
            if let error { completion(error.localizedDescription); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            completion(code < 300 || code == 404 ? nil : "Request failed (HTTP \(code))")
        }.resume()
    }

    // Upload a captions file (WebVTT) for a language
    func uploadCaptions(
        libraryId: String,
        videoId: String,
        srclang: String,
        label: String,
        vtt: Data,
        completion: @escaping (String?) -> Void
    ) {
        guard let escaped = srclang.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://video.bunnycdn.com/library/\(libraryId)/videos/\(videoId)/captions/\(escaped)") else {
            completion("Invalid language code"); return
        }
        postUpdate(url: url,
                   body: ["srclang": srclang, "label": label, "captionsFile": vtt.base64EncodedString()],
                   label: "uploadCaptions",
                   completion: completion)
    }

    private func postUpdate(url: URL, body: [String: Any], label: String, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(streamKey, forHTTPHeaderField: "AccessKey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { data, response, error in
            self.logResponse(label, data: data, response: response, error: error)
            if let error { completion(error.localizedDescription); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            if code < 300 { completion(nil); return }
            var msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let d = data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let m = j["message"] as? String { msg = m }
            completion("\(msg.isEmpty ? "Request failed" : msg) (HTTP \(code))")
        }.resume()
    }
}
