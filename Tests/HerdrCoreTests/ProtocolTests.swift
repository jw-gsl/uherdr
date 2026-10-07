import Foundation
import HerdrCore

@main struct ProtocolTests {
    static func main() async throws {
        let suite = ProtocolTests()
        try suite.testNestedLayoutPreservesDirectionRatiosAndPaneOrder()
        suite.testMalformedLayoutIsRejected()
        suite.testServerErrorIsNotTreatedAsSuccessfulResponse()
        suite.testResponseMustMatchRequestID()
        try suite.testTerminalFramesHandleSplitUTF8AndMultipleLines()
        try suite.testTerminalFrameDecodesANSIBytes()
        suite.testOversizedUnterminatedFrameIsRejected()
        await suite.testMissingSocketProducesActionableError()
        try suite.testZoomAlwaysSelectsVisiblePane()
        try suite.testUnzoomedLayoutPreservesExistingSelection()
        print("PASS: 10 protocol, layout, framing, selection, and connection tests")
        try NativeTerminalTests.run()
        try NativeTerminalTests.runSocketLifecycle()
        try NativeTerminalTests.runSocketBackpressure()
        try await DeviceProfileTests.run()
        try await DevicePowerTests.run()
        try await WorkspaceGitTests.run()
        try await FileTransferTests.run()
        TerminalStartSizeTests.run()
        await TerminalStartSizeTests.runGate()
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live" { try await LiveTests.run(socket: CommandLine.arguments[2]) }
    }
    func testNestedLayoutPreservesDirectionRatiosAndPaneOrder() throws {
        let data = Data(#"{"type":"split","direction":"right","ratio":0.6,"first":{"type":"pane","pane_id":"w1:p1"},"second":{"type":"split","direction":"down","ratio":0.4,"first":{"type":"pane","pane_id":"w1:p2"},"second":{"type":"pane","pane_id":"w1:p3"}}}"#.utf8)
        let node = try JSONDecoder().decode(LayoutNode.self, from: data)
        XCTAssertEqual(node.paneIDs, ["w1:p1", "w1:p2", "w1:p3"])
        guard case let .split(direction, ratio, _, second) = node else { return XCTFail("Expected a split") }
        XCTAssertEqual(direction, .right)
        XCTAssertEqual(ratio, 0.6)
        guard case let .split(direction, ratio, _, _) = second else { return XCTFail("Expected nested split") }
        XCTAssertEqual(direction, .down)
        XCTAssertEqual(ratio, 0.4)
    }

    func testMalformedLayoutIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: Data(#"{"type":"split","direction":"diagonal","ratio":0.5}"#.utf8)))
    }

    func testServerErrorIsNotTreatedAsSuccessfulResponse() {
        let data = Data(#"{"id":"test","error":{"code":"not_found","message":"Pane no longer exists"}}"#.utf8)
        XCTAssertThrowsError(try APIResponse.result(from: data, expectedID: "test")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Pane no longer exists"))
        }
    }

    func testResponseMustMatchRequestID() {
        XCTAssertThrowsError(try APIResponse.result(from: Data(#"{"id":"wrong","result":{"type":"ok"}}"#.utf8), expectedID: "test"))
    }

    func testTerminalFramesHandleSplitUTF8AndMultipleLines() throws {
        var decoder = JSONLineBuffer()
        let bytes = Data("{\"type\":\"terminal.closed\",\"reason\":\"café\"}\n{\"type\":\"terminal.closed\",\"reason\":\"done\"}\n".utf8)
        let split = bytes.firstIndex(of: 0xc3)! + 1
        XCTAssertEqual(try decoder.append(bytes.prefix(split)).count, 0)
        let lines = try decoder.append(bytes.suffix(from: split))
        XCTAssertEqual(lines.count, 2)
        let frame = try JSONDecoder().decode(TerminalEnvelope.self, from: lines[0])
        XCTAssertEqual(frame.reason, "café")
    }

    func testTerminalFrameDecodesANSIBytes() throws {
        let frame = try JSONDecoder().decode(TerminalEnvelope.self, from: Data(#"{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"G1szMW1oZWxsbw=="}"#.utf8))
        XCTAssertEqual(try frame.decodedBytes(), Data("\u{1b}[31mhello".utf8))
    }

    func testOversizedUnterminatedFrameIsRejected() {
        var decoder = JSONLineBuffer(limit: 16)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 17)))
    }

    func testZoomAlwaysSelectsVisiblePane() throws {
        let layout = try JSONDecoder().decode(TabLayout.self, from: Data(#"{"tab_id":"w1:t1","zoomed":true,"focused_pane_id":"w1:p2","root":{"type":"split","direction":"right","ratio":0.5,"first":{"type":"pane","pane_id":"w1:p1"},"second":{"type":"pane","pane_id":"w1:p2"}}}"#.utf8))
        XCTAssertEqual(layout.resolveSelectedPane("w1:p1"), "w1:p2")
        XCTAssertEqual(layout.resolveSelectedPane(nil), "w1:p2")
    }

    func testUnzoomedLayoutPreservesExistingSelection() throws {
        let layout = try JSONDecoder().decode(TabLayout.self, from: Data(#"{"tab_id":"w1:t1","zoomed":false,"focused_pane_id":"w1:p2","root":{"type":"split","direction":"right","ratio":0.5,"first":{"type":"pane","pane_id":"w1:p1"},"second":{"type":"pane","pane_id":"w1:p2"}}}"#.utf8))
        XCTAssertEqual(layout.resolveSelectedPane("w1:p1"), "w1:p1")
        XCTAssertEqual(layout.resolveSelectedPane("closed-pane"), "w1:p2")
    }

    func testMissingSocketProducesActionableError() async {
        do {
            _ = try await HerdrClient(socketPath: "/tmp/uherdr-nonexistent-\(UUID().uuidString).sock").request("ping")
            XCTFail("Missing socket must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("connect"))
        }
    }
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \(a) == \(b)", file: file, line: line) }
func XCTAssertTrue(_ condition: Bool, file: StaticString = #file, line: UInt = #line) { precondition(condition, "Expected true", file: file, line: line) }
func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) { preconditionFailure(message, file: file, line: line) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); XCTFail("Expected an error") } catch { handler(error) }
}
