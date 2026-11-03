import Foundation

struct ProviderDefinition: Sendable {
    let id: String
    let name: String
    let defaultAddress: String
    let makeProvider: @Sendable (String) throws -> any UsageProvider
}

struct SiteProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var providerID: String
    var alias: String
    var address: String
    var isBuiltIn: Bool
    var isHidden: Bool

    init(id: String, providerID: String, alias: String, address: String, isBuiltIn: Bool, isHidden: Bool = false) {
        self.id = id
        self.providerID = providerID
        self.alias = alias
        self.address = address
        self.isBuiltIn = isBuiltIn
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey { case id, providerID, alias, address, isBuiltIn, isHidden }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        providerID = try values.decode(String.self, forKey: .providerID)
        alias = try values.decode(String.self, forKey: .alias)
        address = try values.decode(String.self, forKey: .address)
        isBuiltIn = try values.decode(Bool.self, forKey: .isBuiltIn)
        isHidden = try values.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

    func with(address: String, alias: String) -> SiteProfile {
        SiteProfile(id: id, providerID: providerID, alias: alias, address: address, isBuiltIn: isBuiltIn, isHidden: isHidden)
    }
}

enum ProviderCatalog {
    static let all: [ProviderDefinition] = [
        ProviderDefinition(id: "cbc-runok", name: "柴哥 API", defaultAddress: "https://runok.ai") { address in
            CBCProvider(baseURL: try CBCProvider.endpoint(for: address))
        },
        ProviderDefinition(id: "zhiyao", name: "知遥 API", defaultAddress: "https://zhiyaoapi.top") { address in
            ZhiyaoProvider(baseURL: try ZhiyaoProvider.endpoint(for: address))
        }
    ]

    static func definition(for id: String) -> ProviderDefinition {
        all.first { $0.id == id } ?? all[0]
    }

    static var builtInProfiles: [SiteProfile] {
        all.map { definition in
            SiteProfile(id: "builtin-\(definition.id)", providerID: definition.id,
                        alias: definition.name, address: definition.defaultAddress, isBuiltIn: true)
        }
    }
}
