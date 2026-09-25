import Darwin
import Foundation
import Testing
@testable import WireTuner

@Suite(.serialized) @MainActor struct SocketMonitorTests {
    @Test func countsEverySocketTheProcessOpens() async throws {
        let monitor = SocketMonitor()
        monitor.sample()
        let before = monitor.counts
        let changes = Recorder<SocketMonitor.Counts>()
        monitor.onChange = { changes.append($0) }
        let internet = socket(AF_INET, SOCK_STREAM, 0)
        let local = socket(AF_UNIX, SOCK_STREAM, 0)
        defer {
            close(internet)
            close(local)
        }
        #expect(monitor.sample())
        #expect(!monitor.sample(), "the same sockets again change nothing")
        let after = monitor.counts
        #expect(after.internet == before.internet + 1)
        #expect(after.unixDomain == before.unixDomain + 1)
        #expect(after.accessibilityText == "net=\(after.internet) unix=\(after.unixDomain)")
        for _ in 0..<50 where changes.values.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(changes.values.last == after)
        #expect(SocketMonitor.family(of: -1) == .other)
        let pipeFDs = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { pipeFDs.deallocate() }
        #expect(pipe(pipeFDs) == 0)
        #expect(!SocketMonitor.openSockets().contains { $0.descriptor == pipeFDs[0] }, "a pipe is not a socket")
        close(pipeFDs[0])
        close(pipeFDs[1])
        #expect(SocketMonitor.family(addressFamily: AF_SYSTEM) == .other)
        #expect(SocketMonitor.family(addressFamily: AF_INET6) == .internet)
    }

    @Test func runsOnATimerOnlyWhenRequested() async throws {
        #expect(SocketMonitor.isRequested(arguments: ["app", SocketMonitor.launchArgument]))
        #expect(!SocketMonitor.isRequested(arguments: ["app"]))
        #expect(!SocketMonitor.isRequested())
        let monitor = SocketMonitor()
        monitor.start()
        let before = monitor.counts
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        defer { close(fd) }
        // The counts are the whole test process's sockets, which other suites open and close in
        // parallel: wait for the internet count itself, not for any change.
        for _ in 0..<300 where monitor.counts.internet <= before.internet { try await Task.sleep(for: .milliseconds(10)) }
        #expect(monitor.counts.internet >= before.internet + 1)
        monitor.stop()
        monitor.stop()
    }

    @Test func theAppAppendsTheCountsToTheCanvasValue() {
        let suite = TestDefaults()
        let environment = LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument, SocketMonitor.launchArgument], environment: [:])
        #expect(environment.auditsSockets)
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults, launchEnvironment: environment)
        defer { delegate.socketMonitor?.stop() }
        let window = delegate.documents.newDocument(show: false)
        defer { window.close() }
        let value = window.canvas.accessibilityValue() as? String ?? ""
        #expect(value.hasPrefix("changes=0 selected=0 net="), "\(value)")
        delegate.socketCountsDidChange()
        #expect(AppDelegate(layoutStore: nil, defaults: suite.defaults).socketMonitor == nil)
        #expect(CanvasView.accessibilityStatus(changes: 1, selected: 2, diagnostics: "net=0 unix=1") == "changes=1 selected=2 net=0 unix=1")
    }
}
