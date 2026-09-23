import Testing
import WTCRDT
import WTModel

/// The forwarding shims build the same values as WTCRDT's public initialisers.
@Suite struct InverseCompatibilityTests {
    @Test func shimsForwardToThePublicInitializers() {
        let id = OpID(counter: 3, replica: 7)
        let step = Inverse.Step.created(node: id)
        #expect(Inverse.assembled([step]) == Inverse(steps: [step]))
        #expect(MemberField.assembled(number: 4, type: "uint32", typeName: nil) == MemberField(number: 4, type: "uint32", typeName: nil))
        let register = ParagraphRegister.assembled(suffix: [.field(6)], value: [1])
        #expect(register == ParagraphRegister(suffix: [.field(6)], value: [1]))
        #expect(DeletedChar.assembled(id: id, scalar: 65, attributes: [[2]], paragraph: [register])
            == DeletedChar(id: id, scalar: 65, attributes: [[2]], paragraph: [register]))
        #expect(PriorFormat.assembled(char: id, value: nil) == PriorFormat(char: id, value: nil))
    }
}
