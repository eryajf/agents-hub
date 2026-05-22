import Testing
@testable import AgentsHub

@Suite("API provider presets")
struct APIPresetProviderTests {
    @Test("Presets define provider data with empty API keys")
    func presetProviders() {
        let presets = APIPresetProvider.allCases

        #expect(presets.map(\.name) == ["Anthropic", "OpenAI", "PIPE LLM", "PIPE LLM Code"])
        #expect(presets.map(\.baseURL) == [
            "https://api.anthropic.com",
            "https://api.openai.com/v1",
            "https://api.pipellm.ai",
            "https://code.pipellm.ai"
        ])
        #expect(presets.map(\.providerWebsiteURL) == [
            "https://anthropic.com",
            "https://openai.com",
            "https://www.pipellm.ai",
            "https://code.pipellm.ai"
        ])
        #expect(presets.map { $0.makeProvider().keys.map(\.apiKey) } == [[""], [""], [""], [""]])
    }
}
