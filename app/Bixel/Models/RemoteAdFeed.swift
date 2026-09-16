import Foundation

/// The house-ad format published by the AlphBerlin product feed.
struct RemoteAdFeed: Decodable {
    let ads: [RemoteAdCreative]

    /// Discards incomplete creatives or anything that would open a non-HTTPS URL.
    var validAds: [RemoteAdCreative] {
        ads.filter(\.isValid)
    }
}

struct RemoteAdCreative: Decodable, Equatable {
    let adID: String?
    let product: String?
    let advertiser: String?
    let category: String?
    let headline: String?
    let body: String?
    let callToAction: String?
    let iconURLString: String?
    let imageURLString: String?
    let clickURLString: String?
    let starRating: Double?
    let price: String?
    let store: String?

    enum CodingKeys: String, CodingKey {
        case adID = "ad_id"
        case product
        case advertiser
        case category
        case headline
        case body
        case callToAction = "call_to_action"
        case iconURLString = "icon_url"
        case imageURLString = "image_url"
        case clickURLString = "click_url"
        case starRating = "star_rating"
        case price
        case store
    }

    var destinationURL: URL? {
        Self.httpsURL(from: clickURLString)
    }

    var iconURL: URL? {
        Self.httpsURL(from: iconURLString)
    }

    var imageURL: URL? {
        Self.httpsURL(from: imageURLString)
    }

    var isValid: Bool {
        guard let adID, !adID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let advertiser, !advertiser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let headline, !headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let callToAction, !callToAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              destinationURL != nil else {
            return false
        }

        if iconURLString != nil && iconURL == nil { return false }
        if imageURLString != nil && imageURL == nil { return false }
        return true
    }

    private static func httpsURL(from value: String?) -> URL? {
        guard let value,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}

struct RemoteAdFeedLoader {
    static let defaultEndpoint = URL(string: "https://raw.githubusercontent.com/AlphBerlin/langcity-release/main/ad/ad.json")!

    enum LoadError: Error, LocalizedError {
        case invalidHTTPResponse
        case noValidAds

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse:
                return "The remote ad feed returned an unsuccessful response."
            case .noValidAds:
                return "The remote ad feed contained no valid advertisements."
            }
        }
    }

    let endpoint: URL
    let session: URLSession

    init(endpoint: URL = Self.defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func load() async throws -> [RemoteAdCreative] {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LoadError.invalidHTTPResponse
        }

        let feed = try JSONDecoder().decode(RemoteAdFeed.self, from: data)
        let validAds = feed.validAds
        guard !validAds.isEmpty else {
            throw LoadError.noValidAds
        }
        return validAds
    }
}
