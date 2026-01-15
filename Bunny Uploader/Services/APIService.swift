import Foundation
import CryptoKit

final class APIService {

    private let streamKey: String
    private let session = URLSession(configuration: .default)

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

        session.dataTask(with: req) { data, _, error in
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
}
