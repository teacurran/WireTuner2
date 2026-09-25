import Darwin
import Foundation

/// Counts the sockets this process opens, for the UI tests' sandbox audit (TEST-002;
/// testing.adoc, "UI").  Started only in DEBUG builds launched with `-WTSocketAudit`; the canvas
/// then appends `net=<n> unix=<n>` to its accessibility value: how many distinct internet and
/// Unix-domain sockets the process has had open since launch.  A UI test reads the value before
/// and after the work it audits and fails if either count grew.
///
/// The app audits itself because the XCUITest runner is sandboxed (Xcode signs it with
/// `com.apple.security.app-sandbox`) and cannot inspect another process with `lsof` or
/// `proc_pidinfo`.  Sampling in-process is cheap -- one `fstat` per descriptor -- so it runs
/// every 5 ms.  A socket is told apart from a later one on the same descriptor by its kernel
/// socket id (`proc_pidfdinfo`'s `soi_so`): `fstat` reports inode 0 for every socket.
final class SocketMonitor: @unchecked Sendable {
    static let launchArgument = "-WTSocketAudit"
    static let interval: TimeInterval = 0.005

    enum Family: Hashable, Sendable {
        case internet
        case unixDomain
        case other
    }

    /// One socket: its descriptor and kernel socket id (a reused descriptor gets a new id).
    struct Identity: Hashable, Sendable {
        let descriptor: Int32
        let socket: UInt64
        let family: Family
    }

    struct Counts: Equatable, Sendable {
        var internet: Int
        var unixDomain: Int

        /// `net=<n> unix=<n>`, appended to the canvas's accessibility value.
        var accessibilityText: String { "net=\(internet) unix=\(unixDomain)" }
    }

    private let lock = NSLock()
    private var seen: Set<Identity> = []
    private var timer: DispatchSourceTimer?
    /// Called on the main actor whenever the counts change.
    var onChange: (@MainActor @Sendable (Counts) -> Void)?

    init() {}

    /// Whether this launch asked for the audit (DEBUG builds only).
    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
            return arguments.contains(launchArgument)
        #else
            return false
        #endif
    }

    /// Every socket open in this process now.
    static func openSockets() -> Set<Identity> {
        var result: Set<Identity> = []
        for descriptor in 0..<getdtablesize() {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { continue }
            result.insert(identity(of: descriptor))
        }
        return result
    }

    /// The socket on `descriptor`: its kernel id and family from `proc_pidfdinfo`, or (should
    /// that fail) id 0 and the family `getsockname` reports.
    static func identity(of descriptor: Int32) -> Identity {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(getpid(), descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size else {
            return Identity(descriptor: descriptor, socket: 0, family: family(of: descriptor))
        }
        return Identity(descriptor: descriptor, socket: info.psi.soi_so, family: family(addressFamily: info.psi.soi_family))
    }

    static func family(of descriptor: Int32) -> Family {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { return .other }
        return family(addressFamily: Int32(address.ss_family))
    }

    static func family(addressFamily: Int32) -> Family {
        switch addressFamily {
        case AF_INET, AF_INET6: .internet
        case AF_UNIX: .unixDomain
        default: .other
        }
    }

    var counts: Counts {
        lock.withLock { Self.counts(of: seen) }
    }

    static func counts(of identities: Set<Identity>) -> Counts {
        Counts(
            internet: identities.count { $0.family == .internet },
            unixDomain: identities.count { $0.family == .unixDomain }
        )
    }

    /// Takes one sample; returns whether the counts changed.
    @discardableResult
    func sample() -> Bool {
        let now = Self.openSockets()
        let (before, after) = lock.withLock { () -> (Counts, Counts) in
            let before = Self.counts(of: seen)
            seen.formUnion(now)
            return (before, Self.counts(of: seen))
        }
        guard before != after else { return false }
        if let onChange { Task { @MainActor in onChange(after) } }
        return true
    }

    func start() {
        stop()
        sample()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
