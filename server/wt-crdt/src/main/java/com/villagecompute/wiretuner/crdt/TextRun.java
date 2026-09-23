package com.villagecompute.wiretuner.crdt;

import java.util.List;

/**
 * A maximal range of live characters with the same attributes (CRDT-006): {@code start} and
 * {@code length} are live offsets; {@code attributes} ascending by key, cleared attributes left
 * out. Mirrors {@code WTCRDT.TextRun}.
 */
public record TextRun(int start, int length, List<TextAttribute> attributes) {
}
