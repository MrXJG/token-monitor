import Foundation

@main
@MainActor
enum GatewayFixtureCheck {
    static func main() async throws {
        setbuf(stdout, nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayFixtureProtocol.self]
        let provider = CBCGatewayProvider(session: URLSession(configuration: configuration))
        guard provider.manifest.id == "cbc-v2",
              ProviderCatalog.all.map(\.id).elementsEqual(["cbc-runok", "zhiyao"]),
              CBCProvider(baseURL: try CBCProvider.endpoint(for: "https://runok.ai")).manifest.id == "cbc-runok",
              try CBCProvider.endpoint(for: "https://runok.ai/index").absoluteString == "https://runok.ai/prod-api",
              try CBCGatewayProvider.endpoint(for: "https://CBC.ICU/index").absoluteString == "https://cbc.icu",
              try CBCGatewayProvider.endpoint(for: "https://cbc.icu/dashboard/").absoluteString == "https://cbc.icu",
              try CBCProvider.endpoint(for: "https://cbc.icu/index").absoluteString == "https://cbc.icu/prod-api" else {
            print("gateway fixture failed: catalog or endpoint")
            throw FixtureFailure.invalid
        }
        let signedIn = try await provider.authenticate(.password, secret: "fixture-password", username: "fixture@example.test")
        guard signedIn.token == "fixture-access", signedIn.refreshToken == "fixture-refresh",
              signedIn.method == .password else { print("gateway fixture failed: login"); throw FixtureFailure.invalid }
        let renewed = try await provider.renewSession(signedIn)
        guard renewed.token == "fixture-access-2", renewed.refreshToken == "fixture-refresh-2" else {
            print("gateway fixture failed: renewal")
            throw FixtureFailure.invalid
        }
        let overview = try await provider.fetchOverview(session: renewed)
        let trend = try await provider.fetchTrend(session: renewed, days: 7)
        let page = try await provider.fetchRecentUsage(session: renewed, query: UsageQuery(pageSize: 20))
        let rates = try await provider.fetchGroupRates(session: renewed)
        guard overview.billingAccountID == "11", rates.count == 2,
              rates[0].multiplier == Decimal(string: "0.2"),
              rates[1].multiplier == Decimal(string: "0.125"), rates[1].usesAccountRate,
              page.records.first?.groupID == "7" else { throw FixtureFailure.invalid }
        GatewayFixtureProtocol.trendUnavailable = true
        let fallbackConfiguration = URLSessionConfiguration.ephemeral
        fallbackConfiguration.protocolClasses = [GatewayFixtureProtocol.self]
        let fallbackTrend = try await CBCProvider(baseURL: try CBCProvider.endpoint(for: "https://runok.ai"), session: URLSession(configuration: fallbackConfiguration)).fetchTrend(session: renewed, days: 7)
        guard fallbackTrend.count == 7 else { throw FixtureFailure.invalid }
        let suite = "TokenMonitor.GroupRateFixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tracker = GroupRateTracker(defaults: defaults)
        guard tracker.observe(rates, scope: "site:account").isEmpty,
              tracker.observe(rates, scope: "site:account").isEmpty else { throw FixtureFailure.invalid }
        let changed = [GroupRate(id: "7", name: "ultra", multiplier: Decimal(string: "0.25")!)]
        let changes = tracker.observe(changed, scope: "site:account")
        guard changes.count == 1, changes[0].previous == Decimal(string: "0.125"),
              changes[0].current == Decimal(string: "0.25"),
              GroupRateTracker(defaults: defaults).history(scope: "site:account").count == 1,
              tracker.observe(changed, scope: "site:account").isEmpty,
              tracker.observe(changed, scope: "other-site:account").isEmpty,
              tracker.observe(changed, scope: "site:other-account").isEmpty,
              tracker.observe([], scope: "site:account").isEmpty,
              tracker.history(scope: "site:account").count == 1 else { throw FixtureFailure.invalid }
        let (today, models) = UsageAggregator.today(overview: overview, records: page.records)
        guard overview.availableBalance == Decimal(string: "42.5"),
              overview.frozenBalance == Decimal(string: "0.5"),
              overview.todayRequests == 3, overview.totalTokens == 1400,
              overview.cacheWriteTokens == 30, overview.cacheReadIncludedInInput == false,
              trend.count == 1, trend[0].totalTokens == 250, trend[0].cacheReadTokens == 20,
              page.total == 1, page.records[0].id == "123",
              page.records[0].requestTime != nil, page.records[0].keyName == "sample",
              page.records[0].groupName == "sample-group",
              page.records[0].totalTokens == 250,
              UsageAggregator.generationTokensPerSecond(records: page.records) == 220,
              today.inputTokens == 100, today.outputTokens == 110,
              today.cacheReadTokens == 20, today.cacheWriteTokens == 20,
              today.todayCost == Decimal(string: "0.125"),
              models.first?.modelName == "sample-model" else {
            print("gateway fixture failed: mapping: balance=\(String(describing: overview.availableBalance)), trend=\(trend.count), rows=\(page.records.count), total=\(page.records.first?.totalTokens ?? -1), today=\(today.inputTokens)/\(today.outputTokens)/\(today.cacheReadTokens)/\(today.cacheWriteTokens ?? -1), cost=\(String(describing: today.todayCost))")
            throw FixtureFailure.invalid
        }
        guard GatewayFixtureProtocol.loginBodyValid && GatewayFixtureProtocol.refreshBodyValid &&
              GatewayFixtureProtocol.trendQueryValid && GatewayFixtureProtocol.usageQueryValid else {
            print("gateway fixture failed: request bodies or queries: \(GatewayFixtureProtocol.loginBodyValid)/\(GatewayFixtureProtocol.refreshBodyValid)/\(GatewayFixtureProtocol.trendQueryValid)/\(GatewayFixtureProtocol.usageQueryValid)")
            throw FixtureFailure.invalid
        }
        GatewayFixtureProtocol.htmlResponse = true
        do {
            _ = try await provider.fetchRecentUsage(session: renewed, query: UsageQuery())
            throw FixtureFailure.invalid
        } catch ProviderError.server(let message) {
            guard message.contains("返回网页") else { throw FixtureFailure.invalid }
        }
        print("CBC new/legacy fixtures passed: auth, renewal, balance, trend, records, cache, group rates, account overrides, persistent change detection and HTML fallback")
    }
}

private enum FixtureFailure: Error { case invalid }

private final class GatewayFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var loginBodyValid = false
    nonisolated(unsafe) static var refreshBodyValid = false
    nonisolated(unsafe) static var trendQueryValid = false
    nonisolated(unsafe) static var trendUnavailable = false
    nonisolated(unsafe) static var trendNotFound = false
    nonisolated(unsafe) static var usageQueryValid = false
    nonisolated(unsafe) static var htmlResponse = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body: String
        if Self.htmlResponse {
            body = "<html>site moved</html>"
        } else {
            switch path {
            case "/api/v1/auth/login":
                let json = bodyJSON()
                Self.loginBodyValid = json?["email"] == "fixture@example.test" && json?["password"] == "fixture-password"
                body = #"{"code":0,"data":{"access_token":"fixture-access","refresh_token":"fixture-refresh","expires_in":3600}}"#
            case "/api/v1/auth/refresh":
                let json = bodyJSON()
                Self.refreshBodyValid = json?["refresh_token"] == "fixture-refresh"
                body = #"{"code":0,"data":{"access_token":"fixture-access-2","refresh_token":"fixture-refresh-2","expires_in":3600}}"#
            case "/api/v1/auth/me":
                body = #"{"code":0,"data":{"id":11,"balance":42.5,"frozen_balance":0.5}}"#
            case "/api/v1/groups/available":
                body = #"{"code":0,"data":[{"id":2,"name":"pro","status":"active","rate_multiplier":0.2},{"id":7,"name":"ultra","status":"active","rate_multiplier":0.25},{"id":8,"name":"inactive","status":"inactive","rate_multiplier":1}]}"#
            case "/api/v1/groups/rates":
                body = #"{"code":0,"data":{"7":0.125}}"#
            case "/api/v1/usage/dashboard/stats":
                body = #"{"code":0,"data":{"today_requests":3,"total_requests":10,"total_tokens":1400,"total_input_tokens":800,"total_output_tokens":300,"total_cache_read_tokens":250,"total_cache_creation_tokens":30,"today_actual_cost":0.125,"total_actual_cost":1.5,"total_api_keys":2}}"#
            case let path where path.hasSuffix("/aigate/dashboard/user/trend") || path == "/api/v1/usage/dashboard/trend":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if path == "/api/v1/usage/dashboard/trend" {
                    Self.trendQueryValid = query.contains { $0.name == "granularity" && $0.value == "day" }
                        && query.contains { $0.name == "start_date" }
                        && query.contains { $0.name == "end_date" }
                }
                body = Self.trendUnavailable
                    ? #"{"code":404,"message":"请求地址不存在"}"#
                    : (path == "/prod-api/aigate/dashboard/user/trend"
                       ? #"{"code":404,"msg":"请求地址不存在"}"#
                       : #"{"code":0,"data":{"trend":[{"date":"2026-09-29","requests":1,"input_tokens":100,"output_tokens":110,"cache_read_tokens":20,"cache_creation_tokens":20,"actual_cost":0.05}]}}"#)
            case let path where path.hasSuffix("/aigate/log/usage-list") || path == "/api/v1/usage":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if path == "/api/v1/usage" {
                    Self.usageQueryValid = query.contains { $0.name == "page" && $0.value == "1" }
                        && query.contains { $0.name == "page_size" && $0.value == "20" }
                }
                body = path.hasSuffix("/aigate/log/usage-list")
                    ? #"{"rows":[],"total":0,"code":200,"msg":"操作成功"}"#
                    : #"{"code":0,"data":{"total":1,"items":[{"id":123,"created_at":"2026-09-29T08:00:00.123456+08:00","model":"sample-model","input_tokens":100,"output_tokens":110,"cache_read_tokens":20,"cache_creation_tokens":20,"actual_cost":0.05,"api_key":{"name":"sample"},"group":{"id":7,"name":"sample-group"},"group_id":7,"inbound_endpoint":"responses","duration_ms":500}]}}"#
            default:
                body = #"{"code":404,"message":"unexpected fixture route"}"#
            }
        }
        let type = Self.htmlResponse ? "text/html" : "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private func bodyJSON() -> [String: String]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
