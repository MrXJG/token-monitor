import Foundation

struct ProviderDefinition: Sendable {
    let id: String
    let name: String
    let defaultAddress: String
    let makeProvider: @Sendable (String) throws -> any UsageProvider
}

enum ProviderCatalog {
    static let all: [ProviderDefinition] = [
        ProviderDefinition(id: "cbc", name: "CBC 兼容", defaultAddress: "https://cbc.icu") { address in
            CBCProvider(baseURL: try CBCProvider.endpoint(for: address))
        },
        ProviderDefinition(id: "zhiyao", name: "知遥 API", defaultAddress: "https://zyapi.tuluo.top:8888") { address in
            ZhiyaoProvider(baseURL: try ZhiyaoProvider.endpoint(for: address))
        }
    ]

    static func definition(for id: String) -> ProviderDefinition {
        all.first { $0.id == id } ?? all[0]
    }
}
