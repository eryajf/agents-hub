import Testing
@testable import AgentsHub

@Suite("API provider presets")
struct APIPresetProviderTests {
    @Test("Pipe presets define provider data without logos and with empty API keys")
    func pipePresetProviders() {
        let presets = APIPresetProvider.allCases

        #expect(presets.map(\.name) == ["PIPE LLM", "PIPE LLM Code"])
        #expect(presets.map(\.baseURL) == ["https://api.pipellm.ai", "https://code.pipellm.ai"])
        #expect(presets.map(\.providerWebsiteURL) == ["https://www.pipellm.ai", "https://code.pipellm.ai"])
        #expect(presets.map { $0.makeProvider().keys.map(\.apiKey) } == [[""], [""]])
    }
}
