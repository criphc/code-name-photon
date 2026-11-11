import Foundation
import Testing
@testable import ContractKit

/// The appctl↔GUI stdout protocol is a small, versioned JSON contract (ADR-0010). These tests pin
/// the exact readiness line and the pre-ready failure event, and prove unknown events fail loudly.
@Suite("appctl IPC events")
struct IPCContractTests {
    private let readyLine = #"{"schema":0,"event":"ready","port":8787,"pid":123}"#
    private let errorLine = #"{"schema":0,"event":"error","message":"port already in use"}"#

    @Test func readyLineDecodesAndValidates() throws {
        let event = try JSONDecoder().decode(ProcessEvent.self, from: Data(readyLine.utf8))
        guard case .ready(let ready) = event else {
            Issue.record("expected a ready event, got \(event)")
            return
        }
        #expect(ready.schema == 0)
        #expect(ready.event == "ready")
        #expect(ready.port == 8787)
        #expect(ready.pid == 123)
        #expect(ready.isValid)
    }

    @Test func readyEventEncodesTheAgreedShape() throws {
        let encoded = try JSONEncoder().encode(ReadyEvent(port: 8787, pid: 123))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "event", "port", "pid"])
        #expect(object["schema"] as? Int == 0)
        #expect(object["event"] as? String == "ready")
        #expect(object["port"] as? Int == 8787)
        #expect(object["pid"] as? Int == 123)
    }

    @Test func readyEventWithoutPIDIsStillLegal() throws {
        let ready = try JSONDecoder().decode(
            ReadyEvent.self,
            from: Data(#"{"schema":0,"event":"ready","port":8787}"#.utf8)
        )
        #expect(ready.pid == nil)
        #expect(ready.isValid)
    }

    @Test func invalidReadyEventsAreRejectedByTheValidator() throws {
        #expect(try JSONDecoder().decode(ReadyEvent.self, from: Data(#"{"schema":1,"event":"ready","port":8787}"#.utf8)).isValid == false)
        #expect(try JSONDecoder().decode(ReadyEvent.self, from: Data(#"{"schema":0,"event":"ready","port":0}"#.utf8)).isValid == false)
        #expect(try JSONDecoder().decode(ReadyEvent.self, from: Data(#"{"schema":0,"event":"starting","port":8787}"#.utf8)).isValid == false)
    }

    @Test func preReadyErrorDecodes() throws {
        let event = try JSONDecoder().decode(ProcessEvent.self, from: Data(errorLine.utf8))
        guard case .error(let error) = event else {
            Issue.record("expected an error event, got \(event)")
            return
        }
        #expect(error.schema == 0)
        #expect(error.event == "error")
        #expect(error.message == "port already in use")
    }

    @Test func unknownEventFailsToDecode() {
        let line = #"{"schema":0,"event":"status","state":"running"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProcessEvent.self, from: Data(line.utf8))
        }
    }

    @Test func processEventRoundTrips() throws {
        let events: [ProcessEvent] = [
            .ready(ReadyEvent(port: 8787, pid: 123)),
            .ready(ReadyEvent(port: 65535)),
            .error(ErrorEvent(message: "boom")),
        ]
        for event in events {
            let encoded = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(ProcessEvent.self, from: encoded)
            #expect(decoded == event)
        }
    }
}
