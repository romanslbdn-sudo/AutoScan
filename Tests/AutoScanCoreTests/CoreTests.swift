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
        let v = VINInfo(vin: "WVWZZZ3CZEE123456", currentYear: 2026, minYear: 1996)
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
        let ctx = try await simulate(offset: 0, codes: codes, seconds: 14)
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

final class DemoScenarioTests: XCTestCase {
    /// Кожне демо-авто має підключатися, віддавати свої помилки і правильний VIN.
    func testAllScenariosConnect() async throws {
        for sc in DemoScenario.all {
            let session = ELM327Session(transport: DemoTransport(scenario: sc))
            try await session.transport.open()
            let obd = OBDService(session: session)
            try await obd.initialize()
            XCTAssertEqual(obd.info.isCAN, sc.isCAN, sc.id)
            let stored = try await obd.readDTCs(kind: .stored)
            XCTAssertEqual(stored.map(\.code), sc.stored, sc.id)
            let pending = try await obd.readDTCs(kind: .pending)
            XCTAssertEqual(pending.map(\.code), sc.pending, sc.id)
            let permanent = try await obd.readDTCs(kind: .permanent)
            XCTAssertEqual(permanent.map(\.code), sc.supportsPermanent ? sc.permanent : [], sc.id)
            let vin = try? await obd.readVIN()
            XCTAssertEqual(vin, sc.vin, sc.id)
            if let v = sc.vin {
                let info = VINInfo(vin: v, currentYear: 2026, minYear: 1996)
                XCTAssertNotNil(info.manufacturer, sc.id)
                XCTAssertEqual(info.modelYear, sc.year, sc.id)
            }
            let status = try await obd.monitorStatus()
            XCTAssertEqual(status?.isDiesel, sc.isDiesel, sc.id)
            XCTAssertEqual(status?.milOn, !sc.stored.isEmpty, sc.id)
            for pid in sc.pids where PIDTable.definition(pid) != nil {
                XCTAssertTrue(obd.supportedPIDs.contains(pid), "\(sc.id) PID \(String(format: "%02X", pid))")
            }
            // Опис кожного коду є в базі
            let db = DTCDatabase(packsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            for c in sc.stored + sc.pending + sc.permanent {
                XCTAssertNotNil(db.generic[c], "\(sc.id): немає опису \(c)")
            }
        }
    }
}

final class PackCatalogTests: XCTestCase {
    func testRepoPacksAreValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let index = try JSONDecoder().decode(PackCatalog.self, from: Data(contentsOf: root.appendingPathComponent("packs/index.json")))
        XCTAssertGreaterThanOrEqual(index.packs.count, 4)
        let db = DTCDatabase(packsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for item in index.packs {
            let data = try Data(contentsOf: root.appendingPathComponent("packs/" + item.file))
            let pack = try db.importPack(data: data)
            XCTAssertEqual(pack.id, item.id)
            XCTAssertEqual(pack.codes.count, item.codes)
        }
        XCTAssertEqual(db.lookup("P1260", brand: "Ford (Німеччина)").source, "Ford: заводські коди")
        XCTAssertTrue(PackCatalog.isNewer("1.10", than: "1.2"))
        XCTAssertFalse(PackCatalog.isNewer("1.0", than: "1.0"))
    }
}

final class AdapterCompatibilityTests: XCTestCase {
    /// Клон, що не знаходить протокол сам, має підключитися через ручний перебір.
    func testManualProtocolFallback() async throws {
        let sc = DemoScenario.with(id: "astra")
        XCTAssertTrue(sc.failsAutoSearch)
        let session = ELM327Session(transport: DemoTransport(scenario: sc))
        try await session.transport.open()
        let obd = OBDService(session: session)
        try await obd.initialize()
        XCTAssertEqual(obd.info.protocolNumber, "5")
        XCTAssertFalse(obd.info.isCAN)
        XCTAssertEqual(obd.info.adapterKind, "Клон ELM327 v2.1")
        XCTAssertNotNil(obd.info.adapterNote)
        let dtcs = try await obd.readDTCs(kind: .stored)
        XCTAssertEqual(dtcs.map(\.code), sc.stored)
    }

    func testAdapterKindNormal() async throws {
        let session = ELM327Session(transport: DemoTransport())
        try await session.transport.open()
        let obd = OBDService(session: session)
        try await obd.initialize()
        XCTAssertEqual(obd.info.adapterKind, "ELM327 v1.5")
        XCTAssertNil(obd.info.adapterNote)
    }
}

final class MultiPIDTests: XCTestCase {
    func testMultiPIDReadsMatchSingle() async throws {
        let session = ELM327Session(transport: DemoTransport(scenario: DemoScenario.with(id: "camry")))
        try await session.transport.open()
        let obd = OBDService(session: session)
        try await obd.initialize()
        XCTAssertTrue(obd.multiPID)
        let defs = [0x0C, 0x05, 0x24, 0x63, 0x0F, 0x42].compactMap { PIDTable.definition(UInt8($0)) }
        let got = try await obd.readMany(defs)
        XCTAssertEqual(Set(got.keys), Set(defs.map(\.pid)))
        XCTAssertEqual(got[0x63]!, 250, accuracy: 0.5)
        XCTAssertEqual(got[0x24]!, 1.0, accuracy: 0.05)
        let v = try await obd.read(PIDTable.definition(0xF0)!)
        XCTAssertNotNil(v)
        XCTAssertTrue(obd.isSupported(0xF1))
    }

    func testMultiFrameParse() throws {
        let raw = "00F\r0: 41 0C 0C 80 05 7B\r1: 0F 47 42 36 B0 24 80\r2: 00 80 00 00 00 00 00\r"
        let msgs = try ResponseParser.messages(from: raw)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(Array(msgs[0].prefix(6)), [0x41, 0x0C, 0x0C, 0x80, 0x05, 0x7B])
    }
}

final class RetroTests: XCTestCase {
    func testRetroSystems() {
        XCTAssertEqual(RetroSystems.all.count, 9)
        let ford = RetroSystems.all.first { $0.id == "ford-eec4" }!
        XCTAssertTrue(ford.lookup("11")!.isInfo)
        XCTAssertEqual(ford.lookup("21")?.severity, 2)
        let bmw = RetroSystems.all.first { $0.id == "bmw-motronic" }!
        XCTAssertTrue(bmw.lookup("1444")!.isInfo)
        XCTAssertNotNil(bmw.lookup("1223"))
        for s in RetroSystems.all {
            XCTAssertEqual(Set(s.codes.map(\.code)).count, s.codes.count, "дублікати в \(s.id)")
            if s.digits > 0 { XCTAssertTrue(s.codes.allSatisfy { $0.code.count == s.digits }, s.id) }
        }
    }

    func testExpandedDatabase() {
        let db = DTCDatabase(packsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertGreaterThan(db.genericCount, 500)
        XCTAssertNotNil(db.generic["P0264"])
        XCTAssertNotNil(db.generic["P0733"])
        XCTAssertNotNil(db.generic["U0164"])
    }
}

final class VehicleDetailsTests: XCTestCase {
    func testNHTSAParse() {
        let json = """
        {"Count":1,"Results":[{"Make":"VOLKSWAGEN","Model":"Passat","ModelYear":"2014","DisplacementL":"1.8","EngineCylinders":"4",
        "EngineKW":"125","FuelTypePrimary":"Gasoline","Turbo":"Yes","BodyClass":"Sedan/Saloon","DriveType":"FWD/Front-Wheel Drive",
        "TransmissionStyle":"Automatic","PlantCountry":"UNITED STATES (USA)","PlantCity":"CHATTANOOGA","Series":"","Trim":"SE","EngineModel":"CPKA"}]}
        """
        let d = NHTSADecoder.parse(Data(json.utf8))!
        XCTAssertEqual(d.make, "Volkswagen")
        XCTAssertEqual(d.displacementL, 1.8)
        XCTAssertEqual(d.fuel, "бензин")
        XCTAssertEqual(d.turbo, true)
        XCTAssertEqual(d.body, "седан")
        XCTAssertEqual(d.drive, "передній")
        XCTAssertEqual(d.transmission, "автомат")
        XCTAssertEqual(d.engineSummary, "1,8 л · бензин · турбо")
        XCTAssertEqual(d.powerText, "125 кВт (170 к.с.)")
    }

    func testEmptyNHTSA() {
        let json = #"{"Results":[{"Make":"","Model":"","ModelYear":"","ErrorCode":"8"}]}"#
        XCTAssertNil(NHTSADecoder.parse(Data(json.utf8)))
    }

    func testDisplacementEstimate() {
        // 1.8 л на холостому: ≈3.1 г/с при 790 об/хв, 33 кПа, 31 °C
        let est = EngineEstimator.displacement(mafGs: 3.1, mapKPa: 33, rpm: 790, intakeC: 31, diesel: false)
        XCTAssertNotNil(est)
        XCTAssertTrue((1.4...2.2).contains(est!), "\(est!)")
    }

    func testDemoDetails() {
        let d = DemoScenario.with(id: "megane").details
        XCTAssertEqual(d.fuel, "дизель")
        XCTAssertEqual(d.turbo, true)
        XCTAssertEqual(d.displacementL, 1.5)
        XCTAssertEqual(VehicleInfoCodes.obdStandard(6), "EOBD (Європа)")
        XCTAssertEqual(VehicleInfoCodes.fuelType(4), "дизель")
        XCTAssertFalse(PIDHelp.of(0x04).what.isEmpty)
        XCTAssertNotNil(PIDHelp.of(0x07).range)
    }

    func testFuelTypeFromDemoCar() async throws {
        let session = ELM327Session(transport: DemoTransport(scenario: DemoScenario.with(id: "mercedes")))
        try await session.transport.open()
        let obd = OBDService(session: session)
        try await obd.initialize()
        let f = await obd.readByte(0x51)
        XCTAssertEqual(f.flatMap(VehicleInfoCodes.fuelType), "дизель")
        let v = try await obd.read(PIDTable.definition(0x74)!)
        XCTAssertNotNil(v)
    }
}


final class VINCheckTests: XCTestCase {
    func testCheckDigit() {
        // Відомий коректний VIN зі стандарту прикладів (контрольна цифра X)
        XCTAssertEqual(VINInfo(vin: "1M8GDM9AXKP042788").checkDigitValid, true)
        XCTAssertEqual(VINInfo(vin: "1M8GDM9A1KP042788").checkDigitValid, false)
        XCTAssertNil(VINInfo(vin: "WVWZZZ3CZEE123456").checkDigitValid)
        XCTAssertFalse(VINInfo(vin: "WVWZZZ3CZEE12345O").isValidFormat)
        XCTAssertEqual(VINInfo(vin: "WVWZZZ3CZEE123456").parts.count, 5)
    }
}


final class VINYearTests: XCTestCase {
    func testAmbiguousEuropeanOldYear() {
        // Ford Європа, 10-й символ G: 1986 або 2016 — без додаткових даних рік не вгадуємо
        let v = VINInfo(vin: "WF0FXXGAGGGB12345", currentYear: 2026)
        XCTAssertNil(v.modelYear)
        XCTAssertEqual(v.yearCandidates, [1986, 2016])
        XCTAssertEqual(v.yearText, "1986 або 2016")
        XCTAssertNotNil(v.yearNote)
        XCTAssertEqual(v.manufacturer, "Ford (Німеччина)")
    }

    func testNorthAmericaRule() {
        XCTAssertEqual(VINInfo(vin: "1M8GDM9AXKP042788", currentYear: 2026).modelYear, 1989)
        XCTAssertEqual(VINInfo(vin: "1FAHP3F2XCL123456", currentYear: 2026).modelYear, 2012)
    }
}
