import Testing
@testable import Runner

struct RunnerTests {
  @Test func generatedSecretIsRandomHex() {
    let secret = IosProxySettings.generatedSecret()
    #expect(secret.count == 32)
    #expect(secret.allSatisfy { $0.isHexDigit })
    #expect(secret != IosProxySettings.legacySecret)
    #expect(IosProxySettings.isValidSecret(secret))
    #expect(secret != IosProxySettings.generatedSecret())
  }

  @Test func rejectsMalformedSecrets() {
    #expect(!IosProxySettings.isValidSecret(""))
    #expect(!IosProxySettings.isValidSecret("abc"))
    #expect(!IosProxySettings.isValidSecret(String(repeating: "z", count: 32)))
    #expect(!IosProxySettings.isValidSecret(String(repeating: "0", count: 31)))
  }
}
