import Foundation

/// The panels the application has.  Features register descriptors; the dock, the Window menu
/// and the layout read them.
@MainActor
final class PanelRegistry {
    enum Failure: Error, Equatable {
        case duplicateID(PanelID)
    }

    private var registrationOrder: [PanelDescriptor] = []
    private var byID: [PanelID: PanelDescriptor] = [:]

    /// Called after every registration so the Window menu and the layout can pick up the panel.
    var onChange: (@MainActor () -> Void)?
    /// How the factory layout shows each default group, by group name (`PanelCatalog`).
    var groupDefaults: [String: PanelGroupDefaults] = [:]

    init() {}

    func register(_ descriptor: PanelDescriptor) throws {
        guard byID[descriptor.id] == nil else { throw Failure.duplicateID(descriptor.id) }
        byID[descriptor.id] = descriptor
        registrationOrder.append(descriptor)
        onChange?()
    }

    @discardableResult
    func registerIfAbsent(_ descriptor: PanelDescriptor) -> Bool {
        guard byID[descriptor.id] == nil else { return false }
        byID[descriptor.id] = descriptor
        registrationOrder.append(descriptor)
        onChange?()
        return true
    }

    /// Replaces the descriptor with `descriptor.id` in place, keeping its registration order (a
    /// feature adding a section to another feature's panel); registers it when absent.
    func replace(_ descriptor: PanelDescriptor) {
        guard byID[descriptor.id] != nil else {
            registerIfAbsent(descriptor)
            return
        }
        byID[descriptor.id] = descriptor
        registrationOrder = registrationOrder.map { $0.id == descriptor.id ? descriptor : $0 }
        onChange?()
    }

    /// Forgets every descriptor (a test's registry going away: descriptors' factories often capture
    /// the feature, and so the window, that registered them).
    func removeAll() {
        registrationOrder = []
        byID = [:]
        onChange = nil
    }

    func descriptor(for id: PanelID) -> PanelDescriptor? { byID[id] }

    func contains(_ id: PanelID) -> Bool { byID[id] != nil }

    /// Descriptors by `menuOrder`, then registration order.
    var descriptors: [PanelDescriptor] {
        registrationOrder.enumerated()
            .sorted { lhs, rhs in
                lhs.element.menuOrder == rhs.element.menuOrder
                    ? lhs.offset < rhs.offset : lhs.element.menuOrder < rhs.element.menuOrder
            }
            .map(\.element)
    }

    var ids: [PanelID] { descriptors.map(\.id) }

    func title(for id: PanelID) -> String { byID[id]?.title ?? id.rawValue }
}
