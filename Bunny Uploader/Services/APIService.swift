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
            let ok = (error == nil) && ((response as? HTTPURLResponse)?.statusCode == 200)
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
}
