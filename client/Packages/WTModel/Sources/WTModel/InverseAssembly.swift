import WTCRDT

// WTCRDT records an `Inverse` (CRDT-008) but gives it, and four of the values its steps carry, no
// public initialiser: outside the engine an inverse can only come from `applyLocal`.  The undo
// stack needs to build them in two places -- joining the inverses of one drag or one typed word
// into a single undo step, and reading a persisted stack back from the local store (SYNC-001) --
// so these assemble the values from their public stored fields.  Each type is a plain struct of
// exactly the fields named here, in this order, and a struct has the layout of the tuple of its
// fields, so the tuple is reinterpreted as the struct; the size check traps if WTCRDT ever adds a
// field, and `InverseAssemblyTests` compares assembled values with ones the engine recorded.
// When WTCRDT exposes public initialisers these become plain calls (docs/spec/client.adoc, Undo).

@inline(__always)
private func reinterpret<From, To>(_ value: From, as _: To.Type) -> To {
    precondition(MemoryLayout<From>.size == MemoryLayout<To>.size)   // WTCRDT changed the type: update this file
    return unsafeBitCast(value, to: To.self)
}

extension Inverse {
    /// The inverse made of `steps`, in application order.
    public static func assembled(_ steps: [Step]) -> Inverse {
        reinterpret(steps, as: Inverse.self)
    }

    /// This inverse followed by `later`: the inverse of this change and then `later` applied as
    /// one unit, which `undoChange` undoes together (the value before the first write is restored
    /// where the state still holds the last).
    public func followed(by later: Inverse) -> Inverse {
        .assembled(steps + later.steps)
    }
}

extension MemberField {
    /// How a SET field encodes its members: field number, protobuf type and message type name.
    public static func assembled(number: UInt32, type: String, typeName: String?) -> MemberField {
        reinterpret((number, type, typeName), as: MemberField.self)
    }
}

extension ParagraphRegister {
    /// A register beneath a deleted newline: the path after the newline's segment and its value.
    public static func assembled(suffix: [RegisterPath.Segment], value: [UInt8]?) -> ParagraphRegister {
        reinterpret((suffix, value), as: ParagraphRegister.self)
    }
}

extension DeletedChar {
    /// A deleted character with its scalar, attribute values and paragraph registers.
    public static func assembled(id: OpID, scalar: UInt32, attributes: [[UInt8]], paragraph: [ParagraphRegister]) -> DeletedChar {
        reinterpret((id, scalar, attributes, paragraph), as: DeletedChar.self)
    }
}

extension PriorFormat {
    /// The winning value of a mark's attribute on `char` before the mark (nil: none).
    public static func assembled(char: OpID, value: [UInt8]?) -> PriorFormat {
        reinterpret((char, value), as: PriorFormat.self)
    }
}
