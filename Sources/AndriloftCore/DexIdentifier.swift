/// Android identifiers compare their UTF-16 code units. Swift String equality
/// normalizes canonical-equivalent spellings, which can merge distinct DEX symbols.
struct DexIdentifier: Hashable {
    let units: [UInt16]

    init(_ value: String) { units = Array(value.utf16) }

    var text: String { String(decoding: units, as: UTF16.self) }
}
