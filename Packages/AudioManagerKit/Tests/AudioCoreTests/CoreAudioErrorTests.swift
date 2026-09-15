import Testing

@testable import AudioCore

@Suite("Core Audio error wrapping")
struct CoreAudioErrorTests {

    @Test("A success status does not throw")
    func passesSuccess() throws {
        #expect(try CoreAudioError.check(0, "noop") == 0)
    }

    @Test("A failure status throws with its operation name")
    func throwsFailure() {
        #expect(throws: CoreAudioError.self) {
            try CoreAudioError.check(-1, "create tap")
        }
    }

    @Test("Four-character codes are decoded for readable logs")
    func decodesFourCharCode() {
        // 'nope' == 0x6E6F7065
        let error = CoreAudioError(status: 0x6E6F_7065, operation: "create tap")
        #expect(error.codeDescription.contains("nope"))
        #expect(error.description.contains("create tap"))
    }

    @Test("A status that is not printable falls back to the raw number")
    func nonPrintableStatus() {
        let error = CoreAudioError(status: -50, operation: "read property")
        #expect(error.codeDescription == "-50")
    }
}
