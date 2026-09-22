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
