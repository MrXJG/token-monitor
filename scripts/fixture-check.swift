import Foundation

@main
enum FixtureCheck {
    static func main() async throws {
        let overviewJSON = Data("""
        {"code":200,"data":{"availableBalance":44.94,"balance":45.14,"frozenBalance":0.2,"requestCount":12482,"todayRequests":273,"totalTokens":1365542300,"totalChargedAmount":258.15,"averageFirstTokenTime":16656.43,"averageResponseTime":31108.07,"apiKeyCount":1}}
        """.utf8)
        let usageJSON = Data("""
        {"code":200,"total":1,"rows":[{"logId":360001,"requestId":"sample","requestTime":"2026-09-24 11:52:49","modelName":"gpt-6-sol","promptTokens":143624,"completionTokens":383,"cacheReadTokens":27392,"cacheWriteTokens":12,"reasoningOutputTokens":40,"cost":0.04835448,"status":"0","keyName":"primary","relayMode":"RESPONSES","reasoningEffort":"xhigh","groupName":"pro","isStream":1,"duration":74476,"ttft":62008,"upstreamFirstEventMs":62007}]}
        """.utf8)
        let trendJSON = Data("""
        {"code":200,"data":[{"date":"2026-09-24","requestCount":272,"totalTokens":17620472,"cost":null}]}
        """.utf8)
        FixtureProtocol.overview = overviewJSON
        FixtureProtocol.usage = usageJSON
        FixtureProtocol.trend = trendJSON
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let provider = CBCProvider(session: URLSession(configuration: configuration))
        let session = AuthSession(token: "fixture", expiresAt: nil)
        let overview = try await provider.fetchOverview(session: session)
        let page = try await provider.fetchRecentUsage(session: session, query: UsageQuery())
        let trend = try await provider.fetchTrend(session: session, days: 7)
        guard overview.totalTokens == 1_365_542_300,
              overview.todayRequests == 273,
              overview.frozenBalance == Decimal(string: "0.2"),
              trend.first?.totalTokens == 17_620_472,
              page.records.first?.id == "360001",
              page.records.first?.requestId == "sample",
              page.records.first?.keyName == "primary",
              page.records.first?.totalTokens == 144_007,
              page.records.first?.cacheReadTokens == 27_392,
              page.records.first?.cacheWriteTokens == 12 else {
            throw CheckError.failed
        }
        let successful = page.records
        let (daily, models) = UsageAggregator.today(overview: overview, records: successful)
        guard daily.inputTokens == 143_624,
              daily.outputTokens == 383,
              daily.cacheReadTokens == 27_392,
              daily.cacheWriteTokens == 12,
              models.first?.totalTokens == 144_007 else {
            throw CheckError.failed
        }
        FixtureProtocol.usage = Data("""
        {"code":200,"total":1,"rows":[{"logId":360002,"requestTime":"2026-09-24 11:52:49","modelName":"gpt-6-sol","promptTokens":100,"completionTokens":10,"cacheReadTokens":50,"status":"0"}]}
        """.utf8)
        let missingWrite = try await provider.fetchRecentUsage(session: session, query: UsageQuery())
        let (withoutWrite, _) = UsageAggregator.today(overview: overview, records: missingWrite.records)
        guard missingWrite.records.first?.cacheWriteTokens == nil,
              withoutWrite.cacheWriteTokens == nil else { throw CheckError.failed }
        guard try CBCProvider.endpoint(for: "https://CBC.ICU/").absoluteString == "https://cbc.icu/prod-api",
              try CBCProvider.endpoint(for: "https://cbc.icu/index").absoluteString == "https://cbc.icu/prod-api",
              try CBCProvider.endpoint(for: "https://relay.example/prod-api/").absoluteString == "https://relay.example/prod-api" else {
            throw CheckError.failed
        }
        do {
            _ = try CBCProvider.endpoint(for: "ftp://relay.example")
            throw CheckError.failed
        } catch ProviderError.invalidURL {
        }
        FixtureProtocol.overview = Data("""
        {"code":401,"msg":"认证失败"}
        """.utf8)
        do {
            _ = try await provider.fetchOverview(session: session)
            throw CheckError.failed
        } catch ProviderError.unauthenticated {
        }
        let zhiyao = ZhiyaoProvider(session: URLSession(configuration: configuration))
        guard try ZhiyaoProvider.endpoint(for: "https://zyapi.tuluo.top:8888/dashboard/").absoluteString == "https://zyapi.tuluo.top:8888" else {
            throw CheckError.failed
        }
        FixtureProtocol.zhiyaoLogin = Data(#"{"access_token":"sample-session"}"#.utf8)
        FixtureProtocol.zhiyaoUser = Data("""
        {"available_balance":31.5,"fixed_balance":32,"fixed_balance_reserved":0.5,"today_total_cost":1.25,"total_requests":90,"today_requests":3,"total_input_tokens":100,"total_output_tokens":20,"total_cached_tokens":45,"total_cache_read_input_tokens":40,"total_cache_write_input_tokens":5,"api_key_count":2}
        """.utf8)
        FixtureProtocol.zhiyaoUsage = Data("""
        {"total":1,"items":[{"id":42,"request_time":"2026-09-24T01:39:18.562645+08:00","display_model":"gpt-6-sol","input_tokens":100,"output_tokens":20,"cached_tokens":40,"cache_read_input_tokens":40,"cache_write_input_tokens":5,"cost_usd":0.1,"status_code":200,"api_key_name":"sample","is_stream":true,"latency_ms":1200}]}
        """.utf8)
        FixtureProtocol.zhiyaoTrend = Data("""
        {"summary":{"range":"7d","total_cost":1.25,"total_requests":3},"data":[{"time":"2026-09-24","label":"09-24","request_count":3,"cost_usd":1.25}]}
        """.utf8)
        FixtureProtocol.zhiyaoKey = Data("""
        {"success":true,"balanceScope":"user","data":[{"planName":"sample","isValid":true,"remaining":31.5,"unit":"USD"}],"keyUsage":{"todayCostUsd":0.75}}
        """.utf8)
        let passwordSession = try await zhiyao.authenticate(.password, secret: "fixture-password", username: "fixture-user")
        let user = try await zhiyao.fetchOverview(session: passwordSession)
        let zhiyaoPage = try await zhiyao.fetchRecentUsage(session: passwordSession, query: UsageQuery())
        let spending = try await zhiyao.fetchTrend(session: passwordSession, days: 7)
        guard passwordSession.method == .password,
              user.availableBalance == Decimal(string: "31.5"), user.totalTokens == 165,
              user.todayCost == Decimal(string: "1.25"),
              zhiyaoPage.records.first?.requestTime != nil,
              zhiyaoPage.records.first?.totalTokens == 165,
              zhiyaoPage.records.first?.cacheHitRate == Double(40) / Double(145),
              spending.first?.cost == Decimal(string: "1.25") else { throw CheckError.failed }
        let (dailyZhiyao, _) = UsageAggregator.today(overview: user, records: zhiyaoPage.records)
        guard dailyZhiyao.todayCost == Decimal(string: "1.25") else { throw CheckError.failed }
        FixtureProtocol.zhiyaoUsage = Data("""
        {"total":2,"items":[
          {"id":44,"request_time":"2026-09-24T01:40:18+08:00","display_model":"gpt-6-sol","input_tokens":null,"output_tokens":null,"cached_tokens":0,"cache_read_input_tokens":0,"cache_write_input_tokens":0,"cost_usd":0,"status":null,"status_code":null},
          {"id":45,"request_time":"2026-09-24T01:41:18+08:00","display_model":"gpt-6-sol","input_tokens":100,"output_tokens":20,"cached_tokens":0,"cache_read_input_tokens":0,"cache_write_input_tokens":0,"cost_usd":0.1,"status":"success","status_code":200}
        ]}
        """.utf8)
        let inFlightPage = try await zhiyao.fetchRecentUsage(session: passwordSession, query: UsageQuery())
        guard inFlightPage.records.first?.status == "处理中",
              inFlightPage.records.first?.inputTokens == 0,
              inFlightPage.records.dropFirst().first?.status == "成功" else { throw CheckError.failed }
        FixtureProtocol.zhiyaoUsage = Data("""
        {"total":1,"items":[{"id":43,"request_time":"2026-09-24T01:39:18+08:00","input_tokens":100,"output_tokens":20,"cached_tokens":40,"cache_read_input_tokens":0,"cache_write_input_tokens":0,"status_code":200}]}
        """.utf8)
        let legacyCache = try await zhiyao.fetchRecentUsage(session: passwordSession, query: UsageQuery())
        guard legacyCache.records.first?.cacheReadTokens == 40,
              legacyCache.records.first?.totalTokens == 160 else { throw CheckError.failed }
        let keySession = try await zhiyao.authenticate(.apiKey, secret: "fixture-key", username: nil)
        let keyOverview = try await zhiyao.fetchOverview(session: keySession)
        guard keySession.method == .apiKey,
              zhiyao.capabilities(for: keySession) == [.balance],
              keyOverview.availableBalance == Decimal(string: "31.5"),
              keyOverview.todayCost == Decimal(string: "0.75"),
              try await zhiyao.fetchRecentUsage(session: keySession, query: UsageQuery()).records.isEmpty else {
            throw CheckError.failed
        }
        print("fixture checks passed: CBC and Zhiyao overview, trend, usage, cache, auth and site URLs")
    }
}

private enum CheckError: Error { case failed }

private final class FixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var overview = Data()
    nonisolated(unsafe) static var usage = Data()
    nonisolated(unsafe) static var trend = Data()
    nonisolated(unsafe) static var zhiyaoLogin = Data()
    nonisolated(unsafe) static var zhiyaoUser = Data()
    nonisolated(unsafe) static var zhiyaoUsage = Data()
    nonisolated(unsafe) static var zhiyaoTrend = Data()
    nonisolated(unsafe) static var zhiyaoKey = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if request.url?.path == "/user/login" {
            body = Self.zhiyaoLogin
        } else if request.url?.path == "/user/me" {
            body = Self.zhiyaoUser
        } else if request.url?.path == "/user/usage-logs" {
            body = Self.zhiyaoUsage
        } else if request.url?.path == "/user/spending-trend" {
            body = Self.zhiyaoTrend
        } else if request.url?.path == "/api/cc-switch/v1/usage" {
            body = Self.zhiyaoKey
        } else if request.url?.path.contains("usage-list") == true {
            body = Self.usage
        } else if request.url?.path.contains("trend") == true {
            body = Self.trend
        } else {
            body = Self.overview
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
