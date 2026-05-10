import Foundation

struct APIPresetProvider: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let baseURL: String
    let providerWebsiteURL: String

    static var allCases: [APIPresetProvider] {
        APIPresetProviderDefaults.providers
    }

    func makeProvider() -> APIProvider {
        APIProvider(
            name: name,
            baseURL: baseURL,
            providerWebsiteURL: providerWebsiteURL
        )
    }
}
