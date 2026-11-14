import Foundation
import Testing
@testable import FileStorage

/// A type with two known keys that keeps the others.
private struct Sample: Codable, Hashable {
    var name: String
    var count: Int
    var created: Date?
    var unknownKeys: YAMLMapping

    static let known: Set<String> = ["name", "count", "created"]

    init(from decoder: any Decoder) throws {
        let c = try MappingReader(decoder)
        _ = try c.schema()
        name = try c.required("name")
        count = try c.value("count", default: 1)
        created = try c.optionalDate("created")
        unknownKeys = try c.unknownKeys(known: Self.known)
    }

    func encode(to encoder: any Encoder) throws {
        var c = MappingWriter(encoder)
        try c.encode(name, "name")
        try c.encode(count, "count")
        if let created { try c.encodeDate(created, "created") }
        try c.encodeUnknownKeys(unknownKeys, known: Self.known)
    }
}

@Suite("YAML coding")
struct YAMLCodingTests {
    @Test("Keys the type doesn't know are written back as read, in their order, after the known keys")
    func unknownKeysKeepTheirOrderAndLayout() throws {
        let text = """
        zebra: 1
        name: Orders
        labels:
        - ui
        - 'yes'
        quoted: '#34C759'
        empty: ''
        missing: null
        when: 2026-10-31T16:20:00Z
        ratio: 1.2475
        nested:
          b: true
          a: [] 
        notes: |-
          First line
          Second line
        alpha: {}
        count: 3

        """
        let sample = try YAMLCoding.decode(Sample.self, from: text)
        #expect(sample.name == "Orders")
        #expect(sample.count == 3)
        #expect(sample.unknownKeys.keys == ["zebra", "labels", "quoted", "empty", "missing", "when", "ratio", "nested", "notes", "alpha"])
        let written = try YAMLCoding.encode(sample)
        #expect(written == """
        name: Orders
        count: 3
        zebra: 1
        labels:
        - ui
        - 'yes'
        quoted: '#34C759'
        empty: ''
        missing: null
        when: 2026-10-31T16:20:00Z
        ratio: 1.2475
        nested:
          b: true
          a: []
        notes: |-
          First line
          Second line
        alpha: {}

        """)
        #expect(try YAMLCoding.decode(Sample.self, from: written) == sample)
    }

    @Test("A document must be UTF-8, one mapping at its root, with no key twice")
    func readRules() throws {
        #expect(throws: FileFormatError("not valid UTF-8")) { try YAMLCoding.parseMapping(Data([0xFF, 0xFE, 0x00])) }
        #expect(throws: FileFormatError("the root of the document is not a mapping")) { try YAMLCoding.parseMapping("- a\n- b\n") }
        #expect(throws: FileFormatError("the root of the document is not a mapping")) { try YAMLCoding.parseMapping("") }
        #expect(throws: FileFormatError("the key \"name\" appears twice in one mapping")) {
            try YAMLCoding.parseMapping("name: a\nname: b\n")
        }
        #expect(throws: FileFormatError("the key \"b\" appears twice in one mapping")) {
            try YAMLCoding.parseMapping("a:\n- b: 1\n  b: 2\n")
        }
        let error = #expect(throws: FileFormatError.self) { try YAMLCoding.parseMapping("name: [a\n") }
        #expect(error?.reason.hasPrefix("not valid YAML: ") == true)
    }

    @Test("A byte order mark and CR LF line breaks are accepted")
    func byteOrderMarkAndCRLF() throws {
        let sample = try YAMLCoding.decode(Sample.self, from: Data("\u{FEFF}name: A\r\ncount: 2\r\n".utf8))
        #expect(sample.name == "A")
        #expect(sample.count == 2)
    }

    @Test("Absent or null keys take their default; a required key can't be absent or null")
    func defaultsAndRequiredKeys() throws {
        #expect(try YAMLCoding.decode(Sample.self, from: "name: A\ncount: null\n").count == 1)
        let missing = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(Sample.self, from: "count: 2\n") }
        #expect(missing?.reason == "name: the required key is missing or null")
        let null = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(Sample.self, from: "name: ~\n") }
        #expect(null?.reason == "name: the required key is missing or null")
        let type = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(Sample.self, from: "name: A\ncount: many\n") }
        #expect(type?.reason.hasPrefix("count: ") == true)
    }

    @Test("schema is 1 when absent; another value makes the file invalid")
    func schema() throws {
        #expect(throws: Never.self) { try YAMLCoding.decode(Sample.self, from: "schema: 1\nname: A\n") }
        let newer = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(Sample.self, from: "schema: 2\nname: A\n") }
        #expect(newer?.reason == "schema: schema 2 was written by a newer version")
        let older = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(Sample.self, from: "schema: 0\nname: A\n") }
        #expect(older?.reason == "schema: schema must be 1, not 0")
    }

    @Test("Dates are written in UTC with whole seconds and read in the forms of the spec")
    func dates() throws {
        let sample = try YAMLCoding.decode(Sample.self, from: "name: A\ncreated: 2026-10-31T16:20:07.912+02:00\n")
        #expect(sample.created == ISODate.date(from: "2026-10-31T14:20:07Z"))
        #expect(try YAMLCoding.encode(sample) == "name: A\ncount: 1\ncreated: 2026-10-31T14:20:07Z\n")
        let invalid = #expect(throws: FileFormatError.self) { try YAMLCoding.decode(Sample.self, from: "name: A\ncreated: 2026-10-31\n") }
        #expect(invalid?.reason == "created: \"2026-10-31\" is not a date of the form 2026-10-31T14:03:00Z")
    }

    @Test("Strings YAML would read as another type are quoted; text with line breaks uses a literal block")
    func writingRules() throws {
        struct Strings: Encodable {
            var values = ["true", "null", "12", "1.5", "2026-10-31", "NO", "plain", "two\nlines\n"]
        }
        #expect(try YAMLCoding.encode(Strings()) == """
        values:
        - 'true'
        - 'null'
        - '12'
        - '1.5'
        - '2026-10-31'
        - 'NO'
        - plain
        - |
          two
          lines

        """)
    }
}

@Suite("Dates")
struct ISODateTests {
    @Test("Forms that parse, and forms that don't")
    func parsing() {
        let reference = ISODate.date(from: "2026-10-31T14:03:00Z")
        #expect(reference == Date(timeIntervalSince1970: 1_793_455_380))
        #expect(ISODate.date(from: "2026-10-31T14:03:00.999Z") == reference)
        #expect(ISODate.date(from: "2026-10-31T16:03:00+02:00") == reference)
        #expect(ISODate.date(from: "2026-10-31T09:33:00-04:30") == reference)
        for text in ["2026-10-31", "2026-10-31T14:03:00", "2026-02-30T00:00:00Z", "2026-10-31T24:00:00Z", "2026-10-31T14:03:00.Z",
                     "2026-10-31 14:03:00Z", "2026-10-31T14:03:00Zjunk"] {
            #expect(ISODate.date(from: text) == nil, "\(text)")
        }
    }

    @Test("Writing drops the fraction of a second")
    func writing() {
        #expect(ISODate.string(from: Date(timeIntervalSince1970: 1_793_455_380.75)) == "2026-10-31T14:03:00Z")
        #expect(ISODate.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }
}
