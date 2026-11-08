import Foundation

extension PhotoClient {
    /// The upload request (PUT /v1/assets, the file as the body), for the
    /// background session.
    func uploadRequest(filename: String, takenAt: Date?, hash: String) -> URLRequest? {
        guard let url = url("/assets") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        AtlasAuth.apply(to: &req)
        // header values travel as latin-1: names with umlauts are percent-encoded
        let name = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? "upload"
        req.setValue(name, forHTTPHeaderField: "X-Filename")
        req.setValue(hash, forHTTPHeaderField: "X-Content-Hash")
        req.setValue("iphone", forHTTPHeaderField: "X-Source")
        if let takenAt { req.setValue(String(Int(takenAt.timeIntervalSince1970)), forHTTPHeaderField: "X-Taken-At") }
        return req
    }
}
