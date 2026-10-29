import XCTest
@testable import DictationShared
final class AppGroupTests: XCTestCase {
    let base = Identifiers.appGroupBase(prefix: "com.example")
    func profile(groups: [String]?) -> Data {
        var entitlements: [String: Any] = ["application-identifier": "TEAM.com.example"]
        if let groups { entitlements["com.apple.security.application-groups"] = groups }
        let plist = try! PropertyListSerialization.data(fromPropertyList: ["Name": "Test", "Entitlements": entitlements], format: .xml, options: 0)
        // Surround the plist with binary bytes the way the CMS envelope does.
        return Data([0x30, 0x82, 0x00, 0x3c, 0x00, 0xff]) + plist + Data([0xa0, 0x00, 0x31, 0x00])
    }
    func resolve(_ data: Data?, simulator: Bool = false) -> Result<String, AppGroup.Failure> {
        AppGroup.resolve(base: base, profile: data, allowMissingProfile: simulator)
    }
    func testIdentifiersDeriveFromPrefix() {
        XCTAssertEqual(base, "group.com.example.voicedictate.ios")
        XCTAssertEqual(Identifiers.keychainService(prefix: "com.example"), "com.example.voicedictate.configuration")
    }
    func testXcodeSignedBaseGroupResolves() {
        XCTAssertEqual(resolve(profile(groups: [base])), .success(base))
    }
    func testSideStoreTeamSuffixResolves() {
        XCTAssertEqual(resolve(profile(groups: [base + ".ABCDE12345"])), .success(base + ".ABCDE12345"))
    }
    func testUnrelatedGroupsAreIgnored() {
        XCTAssertEqual(resolve(profile(groups: ["group.com.other.app", base + ".TEAM1"])), .success(base + ".TEAM1"))
        XCTAssertEqual(resolve(profile(groups: ["group.com.other.app"])), .failure(.noMatchingGroup))
        XCTAssertEqual(resolve(profile(groups: [])), .failure(.noMatchingGroup))
        XCTAssertEqual(resolve(profile(groups: nil)), .failure(.noMatchingGroup))
    }
    func testLookalikeGroupsAreRejected() {
        for group in [base + "2", base + "x.TEAM", base + ".", base + ".TEAM.extra", base + ".TE-AM", base + ".TÉAM", "x" + base, String(base.dropLast())] {
            XCTAssertEqual(resolve(profile(groups: [group])), .failure(.noMatchingGroup), group)
        }
    }
    func testMultipleMatchingGroupsFailClosed() {
        XCTAssertEqual(resolve(profile(groups: [base, base + ".TEAM1"])), .failure(.ambiguousGroups))
        XCTAssertEqual(resolve(profile(groups: [base + ".TEAM1", base + ".TEAM2"])), .failure(.ambiguousGroups))
    }
    func testMalformedProfilesFailClosed() {
        XCTAssertEqual(resolve(Data()), .failure(.profileMalformed))
        XCTAssertEqual(resolve(Data([0x30, 0x80, 0x06, 0x09])), .failure(.profileMalformed))
        XCTAssertEqual(resolve(Data("<?xml version=\"1.0\"?><plist><dict>".utf8)), .failure(.profileMalformed))
        XCTAssertEqual(resolve(Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><array/></plist>".utf8)), .failure(.profileMalformed))
        let wrongType = try! PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": base]], format: .xml, options: 0)
        XCTAssertEqual(resolve(wrongType), .failure(.profileMalformed))
        let mixedType = try! PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["com.apple.security.application-groups": [base, 1] as [Any]]], format: .xml, options: 0)
        XCTAssertEqual(resolve(mixedType), .failure(.profileMalformed))
    }
    func testMissingProfileFallsBackOnlyOnSimulator() {
        XCTAssertEqual(resolve(nil, simulator: true), .success(base))
        XCTAssertEqual(resolve(nil, simulator: false), .failure(.profileMissing))
    }
    // Real DER CMS SignedData produced by `openssl cms -sign -nodetach` with a
    // discarded throwaway key; `security cms -D` decodes it to the same plist.
    func testRealCMSEnvelopeResolvesSideStoreGroup() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.cmsFixture.joined()))
        XCTAssertEqual(data.first, 0x30)
        XCTAssertEqual(resolve(data), .success(base + ".ABCDE12345"))
    }
    static let cmsFixture = [
        "MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDTALBglghkgBZQMEAgEwggGuBgkqhkiG9w0BBwGgggGfBIIBmzw/eG1sIHZlcnNp",
        "b249IjEuMCIgZW5jb2Rpbmc9IlVURi04Ij8+CjwhRE9DVFlQRSBwbGlzdCBQVUJMSUMgIi0vL0FwcGxlLy9EVEQgUExJU1QgMS4w",
        "Ly9FTiIgImh0dHA6Ly93d3cuYXBwbGUuY29tL0RURHMvUHJvcGVydHlMaXN0LTEuMC5kdGQiPgo8cGxpc3QgdmVyc2lvbj0iMS4w",
        "Ij4KPGRpY3Q+Cgk8a2V5Pk5hbWU8L2tleT4KCTxzdHJpbmc+Rml4dHVyZTwvc3RyaW5nPgoJPGtleT5FbnRpdGxlbWVudHM8L2tl",
        "eT4KCTxkaWN0PgoJCTxrZXk+Y29tLmFwcGxlLnNlY3VyaXR5LmFwcGxpY2F0aW9uLWdyb3Vwczwva2V5PgoJCTxhcnJheT4KCQkJ",
        "PHN0cmluZz5ncm91cC5jb20uZXhhbXBsZS52b2ljZWRpY3RhdGUuaW9zLkFCQ0RFMTIzNDU8L3N0cmluZz4KCQk8L2FycmF5PgoJ",
        "PC9kaWN0Pgo8L2RpY3Q+CjwvcGxpc3Q+CqCCAigwggIkMIIBjaADAgECAhQqrT/RIRQFpdqEv7MRRfcnUe66kjANBgkqhkiG9w0B",
        "AQsFADAkMSIwIAYDVQQDDBl2b2ljZWRpY3RhdGUtdGVzdC1maXh0dXJlMB4XDTI2MTAyOTE4NTEwMloXDTI2MTAzMDE4NTEwMlow",
        "JDEiMCAGA1UEAwwZdm9pY2VkaWN0YXRlLXRlc3QtZml4dHVyZTCBnzANBgkqhkiG9w0BAQEFAAOBjQAwgYkCgYEAmjuOvoHMdry6",
        "CYH2QIypAAqiJZufeTkTL/USmmha5ya8lECLdhfO91WXdXbKgTlKwwRF06VgCMdhndXjBcSSXuFoc++3miSXnj6DbwidnigIt1VA",
        "OZwJWoL8pQx6qvSMbnQEHbsGVf/vFTuZaOj0MpGpAoOnPV4ElMwaxXi9aS8CAwEAAaNTMFEwHQYDVR0OBBYEFDwj87yBLDHYIWaE",
        "5edZcIIBG2G4MB8GA1UdIwQYMBaAFDwj87yBLDHYIWaE5edZcIIBG2G4MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQAD",
        "gYEAMUzADpf6sUwWTncb1AxrmCSi4/yNWsmM8jLK30e8y5v4G2htv7M2wqdEJu+svJNyM1jdjNhfTliQ8/JAAJJrJw/SLDZP5hnP",
        "cwzZJBc9YGsabQmN7fp2i+t57FxVaD1Jf+zIJs+6ECVDvnPBA5CbaD920kEKwhA31Fr83vbUoiExggHLMIIBxwIBATA8MCQxIjAg",
        "BgNVBAMMGXZvaWNlZGljdGF0ZS10ZXN0LWZpeHR1cmUCFCqtP9EhFAWl2oS/sxFF9ydR7rqSMAsGCWCGSAFlAwQCAaCB5DAYBgkq",
        "hkiG9w0BCQMxCwYJKoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjEwMjkxODUxMDJaMC8GCSqGSIb3DQEJBDEiBCCexoi8rAVy",
        "VR/2gFZkaMtS+Lzu7p0KcKY0dOOfRBzrhTB5BgkqhkiG9w0BCQ8xbDBqMAsGCWCGSAFlAwQBKjALBglghkgBZQMEARYwCwYJYIZI",
        "AWUDBAECMAoGCCqGSIb3DQMHMA4GCCqGSIb3DQMCAgIAgDANBggqhkiG9w0DAgIBQDAHBgUrDgMCBzANBggqhkiG9w0DAgIBKDAN",
        "BgkqhkiG9w0BAQEFAASBgJIa0gdOja04OdQUkWTmMT/KR7V+u0WDD8RiHq5jbqMNf4RYQqgUO+1+mYbuXCCip7dSIPjvSf6gdZcf",
        "0vLzb8Yh9FoaCk6RHa3QHtnu7K1f8LJ86VM9985ju738Eha7IxuMNufnKgX8b5B1fbAV8aWuulEy6QXa8wA0mA+nCBTp",
    ]
}
