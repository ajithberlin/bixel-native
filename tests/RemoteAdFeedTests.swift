import Foundation

private final class RemoteAdURLProtocol: URLProtocol {
    static var statusCode = 200
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: Self.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
@MainActor
struct RemoteAdFeedTests {
    private static let fixture = """
    {
      "meta": { "title": "Test house ads" },
      "ads": [
        {
          "ad_id": "langcity_001",
          "product": "langcity",
          "advertiser": "Langcity",
          "category": "Education / Games",
          "headline": "Learn Japanese Like a Game",
          "body": "Explore Tokyo, talk to NPCs, and level up real fluency.",
          "call_to_action": "Join the Waitlist",
          "icon_url": "https://langcity.alphberlin.com/assets/ad/langcity_icon.png",
          "image_url": "https://langcity.alphberlin.com/assets/ad/langcity_001.jpg",
          "click_url": "https://langcity.alphberlin.com/play",
          "star_rating": null,
          "price": null,
          "store": null
        },
        {
          "ad_id": "invalid_http_ad",
          "product": "bad",
          "advertiser": "",
          "category": "",
          "headline": "Missing advertiser",
          "body": "This entry must be rejected.",
          "call_to_action": "Open",
          "icon_url": "http://example.com/icon.png",
          "image_url": null,
          "click_url": "http://example.com",
          "star_rating": null,
          "price": null,
          "store": null
        }
      ]
    }
    """

    static func main() async {
        let fixtureData = Data(fixture.utf8)
        let feed = try! JSONDecoder().decode(RemoteAdFeed.self, from: fixtureData)
        let validAds = feed.validAds

        precondition(validAds.count == 1, "Only complete HTTPS ad entries should be accepted")
        precondition(validAds[0].destinationURL?.absoluteString == "https://langcity.alphberlin.com/play")

        let mappedAds = AdManager.makeAdItems(from: validAds)
        precondition(mappedAds.count == 1, "Valid remote ads must map into the existing ad model")
        precondition(mappedAds[0].description == "Explore Tokyo, talk to NPCs, and level up real fluency.")
        precondition(mappedAds[0].iconURL?.absoluteString.hasSuffix("langcity_icon.png") == true)
        precondition(mappedAds[0].imageURL?.absoluteString.hasSuffix("langcity_001.jpg") == true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteAdURLProtocol.self]
        let loader = RemoteAdFeedLoader(
            endpoint: URL(string: "https://example.test/ad.json")!,
            session: URLSession(configuration: configuration)
        )

        RemoteAdURLProtocol.statusCode = 200
        RemoteAdURLProtocol.responseData = fixtureData
        let loadedAds = try! await loader.load()
        precondition(loadedAds.count == 1, "The loader must return validated feed entries")

        RemoteAdURLProtocol.statusCode = 503
        do {
            _ = try await loader.load()
            preconditionFailure("A non-success HTTP response must not become an ad feed")
        } catch {}

        RemoteAdURLProtocol.statusCode = 200
        RemoteAdURLProtocol.responseData = Data("{\"ads\":[]}".utf8)
        do {
            _ = try await loader.load()
            preconditionFailure("An empty feed must not become a renderable ad inventory")
        } catch {}

        print("Remote ad feed tests passed")
    }
}
