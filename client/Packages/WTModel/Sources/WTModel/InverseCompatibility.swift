import WTCRDT

// Forwarding shims until WTSync's InverseCodec switches to WTCRDT's public initialisers (CRDT-010
// made `Inverse`, `MemberField`, `ParagraphRegister`, `DeletedChar` and `PriorFormat`
// constructible).  Remove this file once nothing calls `assembled`.

extension Inverse {
    /// `Inverse(steps:)`.
    public static func assembled(_ steps: [Step]) -> Inverse { Inverse(steps: steps) }
}

extension MemberField {
    /// `MemberField(number:type:typeName:)`.
    public static func assembled(number: UInt32, type: String, typeName: String?) -> MemberField {
        MemberField(number: number, type: type, typeName: typeName)
    }
}

extension ParagraphRegister {
    /// `ParagraphRegister(suffix:value:)`.
    public static func assembled(suffix: [RegisterPath.Segment], value: [UInt8]?) -> ParagraphRegister {
        ParagraphRegister(suffix: suffix, value: value)
    }
}

extension DeletedChar {
    /// `DeletedChar(id:scalar:attributes:paragraph:)`.
    public static func assembled(id: OpID, scalar: UInt32, attributes: [[UInt8]], paragraph: [ParagraphRegister]) -> DeletedChar {
        DeletedChar(id: id, scalar: scalar, attributes: attributes, paragraph: paragraph)
    }
}

extension PriorFormat {
    /// `PriorFormat(char:value:)`.
    public static func assembled(char: OpID, value: [UInt8]?) -> PriorFormat {
        PriorFormat(char: char, value: value)
    }
}
