import XCTest
@testable import PlaybackCore

final class XLSXTests: XCTestCase {
    /// Made with Python's zipfile: shared, rich, inline and numeric cells, a gap row, and a
    /// sheet that isn't called sheet1.xml.
    static let workbook = "UEsDBBQAAAAIADiKaV3muHRrXAAAAGIAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbBXMTQqAIBBA4auE+xxr0SJKL9EFRKYfylGcIer22fLxwZvcE6/mxsJHoll12ihnp+XNyE0V4lntInkE4LBj9KxTRqqyphK91CwbZB9OvyH0xgwQEgmStPI/FNgPUEsDBBQAAAAIADiKaV12csB/oQAAAPoAAAAPAAAAeGwvd29ya2Jvb2sueG1sjY9LDsIwDESvEvkApIDEokrTDZuuOENoHRK1+cgOn+MTtXTPyvaM/OxR/Scs4oXEPsUOjocGeq3eieZ7SrOoZuQOXCm5lZJHh8HwIWWM1bGJgil1pIfkTGgmdoglLPLUNBcZjI+wEVr6h5Gs9SNe0/gMGMsGIVxMqa+x85lBq/UC/6qIJmAHN2u5iiBWcZhqDBDU+trQMJ1BaiX3PblH019QSwMEFAAAAAgAOIppXT4JoROIAAAAwwAAABoAAAB4bC9fcmVscy93b3JrYm9vay54bWwucmVsc1WOSQ6DMAxFrxL5ADhtpS6qJKzZVr1ABIYghkR21OH29RJWlt//erZrv9tq3sQy593DpbHQBvekNVYFkuYiRhu7eEi1lgei9Im2KE0utGsyZt5i1ZUnLLFf4kR4tfaOfHTA2Wm6wQN3ww3M61fIwyfzIomoKog8UT0gwTyOorPRc4DB4em98AdQSwMEFAAAAAgAOIppXYLTDR2cAAAAAwEAABQAAAB4bC9zaGFyZWRTdHJpbmdzLnhtbGXPTQrCMBAF4KuEuO/ELlyUNF0I6lKoFwh2bANNUjKjeHxTKv7CbN734MHo5u5HccNELoZargslG6OJWGQPVMuBeaoA6Dygt1TECUNuLjF5yzmmHmhKaDsaENmPUCq1AW9dkHnGGc2mjaEXKw1sNMyy6MnxiH+4FS3bxL++O7bflGbdx7HDIJYmPfEQr+klHxOqrJRa7j0F+VHzAFBLAwQUAAAACAA4imld7ptaagIBAABmAgAAGQAAAHhsL3dvcmtzaGVldHMvb2Zmc2V0cy54bWx1kuFugyAUhV+F8ACCOLekQZp13e/92F6AODZJBQxQ28ffrSQEjUskkfvBuedc5ce7GdGsfNDOdriuKD4KfnP+EgalIgJqQ4eHGKcDIaEflJGhcpOyQH6cNzLC1v+SMHklv5dLZiSM0mdipLZY8KV2llEK7t0NeegC1f7x8lpjFDus7ait+owe6joIHsX7XZppVOjLXT1ilL1wEgUnD0h6WCCU1VhWY4tagP0sKCdzOrywU8nqNXsrGVuzc8mazFYGmmyg2ZM/Nf+E/ICxx6tX62zJUroTltMQpj5Qmp6NvdSxofvO2uysTeGq7VjaIt7TZiwlazd92/2+pPjYJP9F4g9QSwECFAMUAAAACAA4imld5rh0a1wAAABiAAAAEwAAAAAAAAAAAAAAgAEAAAAAW0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAIADiKaV12csB/oQAAAPoAAAAPAAAAAAAAAAAAAACAAY0AAAB4bC93b3JrYm9vay54bWxQSwECFAMUAAAACAA4imldPgmhE4gAAADDAAAAGgAAAAAAAAAAAAAAgAFbAQAAeGwvX3JlbHMvd29ya2Jvb2sueG1sLnJlbHNQSwECFAMUAAAACAA4imldgtMNHZwAAAADAQAAFAAAAAAAAAAAAAAAgAEbAgAAeGwvc2hhcmVkU3RyaW5ncy54bWxQSwECFAMUAAAACAA4imld7ptaagIBAABmAgAAGQAAAAAAAAAAAAAAgAHpAgAAeGwvd29ya3NoZWV0cy9vZmZzZXRzLnhtbFBLBQYAAAAABQAFAE8BAAAiBAAAAAA="

    func testInflateDynamicAndStoredBlocks() throws {
        let text = String(repeating: "Night Drive 03:00:00:00 ", count: 200) + String((0..<3000).map { Character(UnicodeScalar(UInt8(65 + ($0 * 7) % 26))) })
        let compressed = [UInt8](Data(base64Encoded: "7cm3DYAwFADRVTyCJTo6wGT45NgjcIsQ81OwhIuTrnon9rweZW77Hkp7vtZ/SnAcx3Ecx3Ecx3Ecx3HcAQ+yZo6Kbo2rYU9lCvN2MWW/JfXI4XA4HA6Hw+FwXDkf")!)
        XCTAssertEqual(try Inflate.decompress(compressed), Array(text.utf8))
        XCTAssertEqual(try Inflate.decompress([UInt8](Data(base64Encoded: "AQwA8/9zdG9yZWQgYmxvY2s=")!)), Array("stored block".utf8))
        XCTAssertThrowsError(try Inflate.decompress([0xFF, 0xFF]))
    }

    func testReadsTheFirstSheet() throws {
        let table = try XLSXReader.table(from: Data(base64Encoded: Self.workbook)!)
        XCTAssertEqual(table[0], ["Example Tour 2027"])
        XCTAssertEqual(table[1], ["Song #", "Title", "TC Start", "FPS"])
        XCTAssertEqual(table[2], ["1", "Overture", "01:00:00:00", "30"])
        XCTAssertEqual(table[3], [])
        XCTAssertEqual(table[4], ["2", "Golden Hour", "02:00:00:00", "30"])
        XCTAssertEqual(XLSXReader.columnIndex("AA"), 26)
    }

    func testImportsAnExcelSheet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Tour Offsets.xlsx")
        try Data(base64Encoded: Self.workbook)!.write(to: url)
        let sheet = try ShowImporter.readSheet(url)
        XCTAssertEqual(sheet.rows.map(\.title), ["Overture", "Golden Hour"])
        XCTAssertEqual(sheet.rows[1].start?.description, "02:00:00:00")
        XCTAssertEqual(sheet.rows[1].number, 2)
    }
}
