import Foundation
import Testing
import WTProto
import WTSync
@testable import WTTestSupport

/// The in-process data service's refusals, as the server answers them.
@Suite struct SimDataServiceTests {
    static func request(_ url: String, credential: String = "") -> Wiretuner_Data_V1_FetchRequest {
        var request = Wiretuner_Data_V1_FetchRequest()
        request.source.url = url
        request.source.credentialName = credential
        request.paths = ["name"]
        return request
    }

    static func drain(_ transport: any DataSourceTransport, _ request: Wiretuner_Data_V1_FetchRequest) async throws -> Int {
        var records = 0
        for try await response in transport.fetch(request, token: "t") {
            records += response.page.records.count
        }
        return records
    }

    @Test func refusalsAndCalls() async throws {
        let service = SimDataService()
        let clock = SimClock(scale: 0.001)
        let link = NetworkLink(name: "x", seed: 1, clock: clock, conditions: .perfect)
        let transport = service.transport(link: link)
        await #expect(throws: DataServiceError.hostNotAllowed(host: "api.example.com", admins: "")) {
            try await Self.drain(transport, Self.request("https://api.example.com/a"))
        }
        service.allow("API.example.com")
        await #expect(throws: DataServiceError.upstream("HTTP 404")) { try await Self.drain(transport, Self.request("https://api.example.com/a")) }
        service.serve("https://api.example.com/a", records: [["name": "a"], ["name": "b"], ["name": "c"]], pageSize: 2)
        #expect(try await Self.drain(transport, Self.request("https://api.example.com/a")) == 3)
        await #expect(throws: DataServiceError.credentialMissing) {
            try await Self.drain(transport, Self.request("https://api.example.com/a", credential: "k"))
        }
        #expect(service.fetches == 3)
        #expect(try await transport.listCredentials(Wiretuner_Data_V1_ListCredentialsRequest(), token: "t").credentials.isEmpty)
        let unsupported = DataServiceError.rejected(code: 12, message: "not simulated")
        await #expect(throws: unsupported) { try await transport.fetchAsset(.init(), token: "t") }
        await #expect(throws: unsupported) { try await transport.proxy(.init(), token: "t") }
        await #expect(throws: unsupported) { try await transport.deleteCredential(.init(), token: "t") }
        await #expect(throws: unsupported) { try await transport.listAllowedHosts(.init(), token: "t") }
        await #expect(throws: unsupported) { try await transport.putAllowedHost(.init(), token: "t") }
        await #expect(throws: unsupported) { try await transport.deleteAllowedHost(.init(), token: "t") }
        link.partition()
        await #expect(throws: DataServiceError.offline) { try await Self.drain(transport, Self.request("https://api.example.com/a")) }
        await #expect(throws: DataServiceError.offline) { try await transport.putCredential(.init(), token: "t") }
    }
}
