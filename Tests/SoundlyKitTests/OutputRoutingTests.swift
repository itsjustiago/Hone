import XCTest
import CoreAudio
@testable import SoundlyKit

final class OutputRoutingTests: XCTestCase {
    private func plain(_ id: AudioDeviceID, _ name: String = "D") -> ProcessOutputDevice {
        ProcessOutputDevice(id: id, name: name, outputSubdevices: nil)
    }

    func testOneDeviceIsTheRoute() {
        XCTAssertEqual(OutputRouting.route([plain(60)]), .device(60))
        XCTAssertEqual(OutputRouting.route([plain(60), plain(60)]), .device(60), "listed by two helpers")
    }

    func testNoDeviceOrNoneReadableIsUndetermined() {
        XCTAssertEqual(OutputRouting.route([]), .undetermined)
        XCTAssertEqual(OutputRouting.route([nil]), .undetermined)
    }

    func testUnreadableDevicesAreLeftOut() {
        XCTAssertEqual(OutputRouting.route([nil, plain(60)]), .device(60))
    }

    func testSeveralDevicesAreAmbiguous() {
        XCTAssertEqual(OutputRouting.route([plain(50), plain(60)]), .ambiguous)
    }

    func testAggregateAroundOneOutputIsThatOutput() {
        // Voice processing wraps the headset (mic + output) in an aggregate.
        let voice = ProcessOutputDevice(id: 90, name: "CADefaultDeviceAggregate", outputSubdevices: [60])
        XCTAssertEqual(OutputRouting.route([voice]), .device(60))
        XCTAssertEqual(OutputRouting.route([voice, plain(60)]), .device(60))
    }

    func testMultiOutputDeviceIsUnusable() {
        let multi = ProcessOutputDevice(id: 91, name: "Saída múltipla", outputSubdevices: [50, 60])
        XCTAssertEqual(OutputRouting.route([multi]), .unusable(name: "Saída múltipla"))
        let empty = ProcessOutputDevice(id: 92, name: "Agregado", outputSubdevices: [])
        XCTAssertEqual(OutputRouting.route([empty]), .unusable(name: "Agregado"))
        XCTAssertEqual(OutputRouting.route([multi, plain(50)]), .ambiguous)
    }
}
