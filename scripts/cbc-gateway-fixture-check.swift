import Foundation

@main
enum GatewayFixtureCheck {
    static func main() async throws {
        setbuf(stdout, nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayFixtureProtocol.self]
        let provider = CBCGatewayProvider(session: URLSession(configuration: configuration))
        guard provider.manifest.id == "cbc-v2",
              ProviderCatalog.all.map(\.id).prefix(2).elementsEqual(["cbc-v2", "cbc"]),
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
        print("CBC new/legacy fixtures passed: auth, renewal, balance, trend, records, cache and HTML fallback")
    }
}

private enum FixtureFailure: Error { case invalid }

private final class GatewayFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var loginBodyValid = false
    nonisolated(unsafe) static var refreshBodyValid = false
    nonisolated(unsafe) static var trendQueryValid = false
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
                body = #"{"code":0,"data":{"balance":42.5,"frozen_balance":0.5}}"#
            case "/api/v1/usage/dashboard/stats":
                body = #"{"code":0,"data":{"today_requests":3,"total_requests":10,"total_tokens":1400,"total_input_tokens":800,"total_output_tokens":300,"total_cache_read_tokens":250,"total_cache_creation_tokens":30,"today_actual_cost":0.125,"total_actual_cost":1.5,"total_api_keys":2}}"#
            case "/api/v1/usage/dashboard/trend":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                Self.trendQueryValid = query.contains { $0.name == "granularity" && $0.value == "day" }
                    && query.contains { $0.name == "start_date" }
                    && query.contains { $0.name == "end_date" }
                body = #"{"code":0,"data":{"trend":[{"date":"2026-09-29","requests":1,"input_tokens":100,"output_tokens":110,"cache_read_tokens":20,"cache_creation_tokens":20,"actual_cost":0.05}]}}"#
            case "/api/v1/usage":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                Self.usageQueryValid = query.contains { $0.name == "page" && $0.value == "1" }
                    && query.contains { $0.name == "page_size" && $0.value == "20" }
                body = #"{"code":0,"data":{"total":1,"items":[{"id":123,"created_at":"2026-09-29T08:00:00.123456+08:00","model":"sample-model","input_tokens":100,"output_tokens":110,"cache_read_tokens":20,"cache_creation_tokens":20,"actual_cost":0.05,"api_key":{"name":"sample"},"group":{"name":"sample-group"},"inbound_endpoint":"responses","duration_ms":500}]}}"#
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
