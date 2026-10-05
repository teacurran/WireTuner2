// How deep an importer lets a file nest what it reads (import-formats.adoc, "Client", *Nesting*).
// Files open and import on threads with a 512 KB stack (8 MB on the main thread), and nesting
// that a reader follows by recursion -- or that ends up as a deep tree of imported groups, which
// is converted, drawn and released by recursion -- can exhaust it on a damaged or hostile file.
// So the PostScript-syntax parser reads arrays, dictionaries and procedures with an explicit
// stack, and every importer keeps what it builds within `ImportNesting.limit` levels: deeper
// containers read as null, deeper groups are flattened into the deepest group allowed, deeper
// clips are dropped, each with a note.

/// The nesting bound shared by the importers.
enum ImportNesting {
    /// The deepest nesting an importer builds: containers in a PostScript-syntax operand,
    /// groups and clipping groups of the imported tree, containers of Illustrator's document
    /// data.  Real files stay far below it (a few dozen levels at most); the trees it allows are
    /// converted and drawn on the main thread's 8 MB stack and fit a 512 KB one in a release
    /// build.  Importers that recurse per level stop sooner (SVG at 48, FreeHand at 48).
    static let limit = 128

    /// The note for a file whose nesting went past an importer's limit.
    static let note = "Parts of the file nested too deeply were flattened or left out."
}
