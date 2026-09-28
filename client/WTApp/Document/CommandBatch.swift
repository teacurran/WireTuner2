import WTCRDT
import WTModel

/// Several commands as one change under one label (an Object panel edit applied to every selected
/// object is one change and one undo step, vector-basics.adoc "Object panel").  Each command reads
/// the state before the change; they must touch different registers.
struct CommandBatch: WTModel.Command {
    let label: String
    let commands: [any WTModel.Command]

    init(_ label: String, _ commands: [any WTModel.Command]) {
        self.label = label
        self.commands = commands
    }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for command in commands {
            try command.execute(&builder, state: state)
        }
    }
}

/// A batch of path edits runs on live shapes as a `CompositeCommand` does (D-078): the shapes it
/// edits are converted to paths first, in the same change.
extension CommandBatch: ShapeRetargetable {
    var editedNodes: [OpID] { commands.flatMap { ($0 as? any ShapeRetargetable)?.editedNodes ?? [] } }

    func retargeted(_ conversions: ShapeConversions) -> any WTModel.Command {
        CommandBatch(label, commands.map { ($0 as? any ShapeRetargetable)?.retargeted(conversions) ?? $0 })
    }

    var convertedLabel: String { CompositeCommand(label, commands).convertedLabel }
}
