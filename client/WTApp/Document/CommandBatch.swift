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
