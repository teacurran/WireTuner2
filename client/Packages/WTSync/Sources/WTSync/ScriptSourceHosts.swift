import Foundation
import WTCRDT

/// The hosts a script source's last run reached through `wt.fetch` (data-merge.adoc, "Credentials
/// and hosts sheets": "script sources' recorded hosts (the last run's `wt.fetch` targets, kept in
/// the local store)"; DATA-015), so *Show Hosts* lists them after a relaunch without running the
/// script again.  One `view` row per source, per Mac: never document state.
public enum ScriptSourceHosts {
    /// The `view` key of `source`'s hosts.
    public static func key(_ source: OpID) -> String { "data.script_hosts.\(source.counter)-\(source.replica)" }

    /// The hosts as kept: lower case, each once, in order.
    public static func normalized(_ hosts: [String]) -> [String] {
        var seen: Set<String> = []
        return hosts.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }.sorted()
    }

    public static func encode(_ hosts: [String]) -> Data {
        // An array of strings always encodes.
        try! JSONEncoder().encode(normalized(hosts))
    }

    /// The hosts `data` holds; empty when it is not a list of strings.
    public static func decode(_ data: Data?) -> [String] {
        guard let data, let hosts = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalized(hosts)
    }
}

extension LocalStore {
    /// The hosts `source`'s last run reached; empty when it never ran on this Mac.
    public func scriptHosts(source: OpID) throws -> [String] {
        ScriptSourceHosts.decode(try viewValue(forKey: ScriptSourceHosts.key(source)))
    }

    /// Records the hosts `source`'s run reached, replacing the previous run's.
    public func setScriptHosts(_ hosts: [String], source: OpID) throws {
        try setViewValue(ScriptSourceHosts.encode(hosts), forKey: ScriptSourceHosts.key(source))
    }
}
