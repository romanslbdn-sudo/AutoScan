import XCTest
@testable import AutoScanCore

final class ParserTests: XCTestCase {

    func testSingleFramePID() throws {
        let raw = "41 0C 1A F8 \r\r"
        let data = try ResponseParser.payload(from: raw, mode: 0x01, pid: 0x0C)
        XCTAssertEqual(data, [0x1A, 0xF8])
        XCTAssertEqual(PIDTable.definition(0x0C)!.decode(data)!, 1726, accuracy: 0.01)
    }

    func testSearchingAndNoSpaces() throws {
        let raw = "SEARCHING...\r410D3C\r"
        let data = try ResponseParser.payload(from: raw, mode: 0x01, pid: 0x0D)
        XCTAssertEqual(data, [0x3C])
    }

    func testNoData() {
        XCTAssertThrowsError(try ResponseParser.payload(from: "NO DATA", mode: 0x01, pid: 0x0C)) { e in
            XCTAssertEqual(e as? AdapterError, .noData)
        }
    }

    func testUnableToConnect() {
        XCTAssertThrowsError(try ResponseParser.payload(from: "SEARCHING...\rUNABLE TO CONNECT", mode: 0x01, pid: 0x00)) { e in
            XCTAssertEqual(e as? AdapterError, .unableToConnect)
        }
    }

    func testMultiFrameVIN() throws {
        let raw = "014\r0: 49 02 01 31 44 34\r1: 47 50 30 30 52 35 35\r2: 42 31 32 33 34 35 36\r"
        let payloads = try ResponseParser.allPayloads(from: raw, mode: 0x09)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].first, 0x02)
    }

    func testCANDTCs() throws {
        let raw = "43 02 01 71 03 00\r"
        let p = try ResponseParser.allPayloads(from: raw, mode: 0x03)
        let dtcs = DTC.parse(payloads: p, isCAN: true, kind: .stored)
        XCTAssertEqual(dtcs.map(\.code), ["P0171", "P0300"])
    }

    func testCANNoDTCs() throws {
        let p = try ResponseParser.allPayloads(from: "43 00\r", mode: 0x03)
        XCTAssertTrue(DTC.parse(payloads: p, isCAN: true, kind: .stored).isEmpty)
    }

    func testLegacyDTCs() throws {
        let raw = "43 01 33 00 00 00 00\r43 04 20 41 23 00 00\r"
        let p = try ResponseParser.allPayloads(from: raw, mode: 0x03)
        let dtcs = DTC.parse(payloads: p, isCAN: false, kind: .stored)
        XCTAssertEqual(dtcs.map(\.code), ["P0133", "P0420", "C0123"])
    }

    func testDTCLetters() {
        XCTAssertEqual(DTC.decode(0xC1, 0x00, kind: .stored)?.code, "U0100")
        XCTAssertEqual(DTC.decode(0x92, 0x34, kind: .stored)?.code, "B1234")
        XCTAssertEqual(DTC.decode(0x24, 0x2F, kind: .stored)?.code, "P242F")
        XCTAssertNil(DTC.decode(0, 0, kind: .stored))
    }

    func testManufacturerSpecific() {
        XCTAssertTrue(DTC(code: "P1234", kind: .stored).isManufacturerSpecific)
        XCTAssertTrue(DTC(code: "P3001", kind: .stored).isManufacturerSpecific)
        XCTAssertFalse(DTC(code: "P3400", kind: .stored).isManufacturerSpecific)
        XCTAssertFalse(DTC(code: "P0171", kind: .stored).isManufacturerSpecific)
        XCTAssertTrue(DTC(code: "U1121", kind: .stored).isManufacturerSpecific)
    }

    func testSupportedPIDs() {
        let s = OBDService.decodeSupported([0xBE, 0x1F, 0xA8, 0x13], offset: 0)
        XCTAssertTrue(s.contains(0x01))
        XCTAssertTrue(s.contains(0x0C))
        XCTAssertTrue(s.contains(0x20))
        XCTAssertFalse(s.contains(0x02))
    }

    func testMonitors() {
        let m = MonitorStatus(bytes: [0x82, 0x07, 0x65, 0x04])!
        XCTAssertTrue(m.milOn)
        XCTAssertEqual(m.dtcCount, 2)
        XCTAssertFalse(m.isDiesel)
        XCTAssertEqual(m.monitors.first { $0.name.contains("EVAP") }?.complete, false)
        XCTAssertEqual(m.monitors.first { $0.name == "Каталізатор" }?.complete, true)
    }

    func testVIN() {
        let v = VINInfo(vin: "WVWZZZ3CZEE123456", currentYear: 2026)
        XCTAssertEqual(v.manufacturer, "Volkswagen")
        XCTAssertEqual(v.country, "Німеччина")
        XCTAssertEqual(v.modelYear, 2014)
        XCTAssertNil(VINInfo(vin: "WBAFR71000LX00000", currentYear: 2026).modelYear) // «0» не рік
    }

    func testEchoStrip() {
        XCTAssertEqual(ELM327Session.stripEcho("ATZ\r\rELM327 v1.5\r\r", command: "ATZ"), "ELM327 v1.5")
    }
}

final class DatabaseTests: XCTestCase {
    func testGenericLoaded() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = DTCDatabase(packsDirectory: tmp)
        XCTAssertGreaterThan(db.genericCount, 150)
        let r = db.lookup("P0171", brand: nil)
        XCTAssertTrue(r.entry.title.contains("бідна"))
        let unknown = db.lookup("P1999", brand: nil)
        XCTAssertTrue(unknown.entry.details.contains("заводський"))
    }

    func testPackImport() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = DTCDatabase(packsDirectory: tmp)
        var pack = BrandPack.template
        pack.matches = ["Volkswagen"]
        let file = tmp.appendingPathExtension("json")
        try JSONEncoder().encode(pack).write(to: file)
        try db.importPack(from: file)
        XCTAssertEqual(db.packs.count, 1)
        XCTAssertEqual(db.lookup("P1234", brand: "Volkswagen").source, pack.title)
    }

    func testNormRules() {
        XCTAssertFalse(NormRules.checks(for: "P0171").isEmpty)
        XCTAssertFalse(NormRules.checks(for: "P0299").isEmpty)
        XCTAssertFalse(NormRules.checks(for: "P0301").isEmpty)
        XCTAssertFalse(NormRules.checks(for: "P0420").isEmpty)
        let trim = NormRules.checks(for: "P0171").first { $0.pid == 0x07 }!
        let ctx = NormContext(current: [0x07: 18, 0x0C: 800, 0x05: 90, 0x0D: 0], history: [:], isDiesel: false)
        XCTAssertEqual(trim.evaluate(ctx).verdict, .high)
    }
}

final class DemoTests: XCTestCase {
    func testFullDemoSession() async throws {
        let session = ELM327Session(transport: DemoTransport())
        try await session.transport.open()
        let obd = OBDService(session: session)
        try await obd.initialize()
        XCTAssertTrue(obd.info.isCAN)
        XCTAssertTrue(obd.supportedPIDs.contains(0x0C))
        XCTAssertTrue(obd.supportedPIDs.contains(0x42))
        let stored = try await obd.readDTCs(kind: .stored)
        XCTAssertEqual(stored.map(\.code), ["P0171", "P0299"])
        let pending = try await obd.readDTCs(kind: .pending)
        XCTAssertEqual(pending.map(\.code), ["P0301"])
        let vin = try await obd.readVIN()
        XCTAssertEqual(vin, "WVWZZZ3CZEE123456")
        let rpm = try await obd.read(PIDTable.definition(0x0C)!)
        XCTAssertNotNil(rpm)
        let status = try await obd.monitorStatus()
        XCTAssertEqual(status?.milOn, true)
        try await obd.clearDTCs()
        let after = try await obd.readDTCs(kind: .stored)
        XCTAssertTrue(after.isEmpty)
    }
}

final class DemoNormTests: XCTestCase {
    /// Опитує демо-авто так само, як це робить програма, і оцінює «норма vs зараз».
    private func simulate(offset: TimeInterval, codes: [String], seconds: Double) async throws -> NormContext {
        let session = ELM327Session(transport: DemoTransport(startOffset: offset))
        try await session.transport.open()
        let obd = OBDService(session: session)
        try await obd.initialize()
        var current: [UInt8: Double] = [:]
        var history: [UInt8: [Double]] = [:]
        let pids = NormRules.requiredPIDs(for: codes).filter { obd.isSupported($0) }.sorted()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for pid in pids {
                if let v = try await obd.read(PIDTable.definition(pid)!) {
                    current[pid] = v
                    history[pid, default: []].append(v)
                }
            }
        }
        return NormContext(current: current, history: history, isDiesel: false)
    }

    func testDemoIdleVerdicts() async throws {
        let codes = ["P0171", "P0301"]
        let ctx = try await simulate(offset: 0, codes: codes, seconds: 6)
        for code in codes {
            for check in NormRules.checks(for: code) {
                let r = check.evaluate(ctx)
                print("[\(code)] \(check.title): \(r.actualText) → \(r.verdict.title)")
            }
        }
        let trim = NormRules.checks(for: "P0171").first { $0.pid == 0x07 }!
        XCTAssertEqual(trim.evaluate(ctx).verdict, .high)
        let lambda = NormRules.checks(for: "P0171").first { $0.pid == 0x14 }!
        XCTAssertEqual(lambda.evaluate(ctx).verdict, .low)
        let idle = NormRules.checks(for: "P0301").first { $0.id == "idle-stab" }!
        XCTAssertEqual(idle.evaluate(ctx).verdict, .unstable)
    }

    func testDemoBoostVerdict() async throws {
        let ctx = try await simulate(offset: 30, codes: ["P0299"], seconds: 2)
        let boost = NormRules.checks(for: "P0299").first { $0.id == "boost-under" }!
        let r = boost.evaluate(ctx)
        print("[P0299] \(boost.title): \(r.actualText) → \(r.verdict.title)")
        XCTAssertEqual(r.verdict, .low)
    }
}
