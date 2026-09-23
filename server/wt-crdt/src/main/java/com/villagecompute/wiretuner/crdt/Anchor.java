package com.villagecompute.wiretuner.crdt;

/**
 * A Peritext anchor (docs/spec/crdt-model.adoc, "Text"): the point just before or just after one
 * character. The zero id is the start of the text with {@code before} and its end with
 * {@code after}. Mirrors {@code WTCRDT.Anchor}.
 */
public record Anchor(OpId character, boolean before) {

    /** The start of the text. */
    public static final Anchor START = new Anchor(OpId.ZERO, true);

    /** The end of the text. */
    public static final Anchor END = new Anchor(OpId.ZERO, false);

    @Override
    public String toString() {
        return (before ? "before " : "after ") + character;
    }
}
