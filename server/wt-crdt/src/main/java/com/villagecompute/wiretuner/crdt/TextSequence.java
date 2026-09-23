package com.villagecompute.wiretuner.crdt;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * One MERGE_TEXT field (docs/spec/crdt-model.adoc, "Text"; CRDT-005, CRDT-006), mirroring
 * {@code WTCRDT.TextSequence}: the Fugue tree of characters, their document order (tombstones
 * included until collected), and the Peritext marks anchored to them.
 *
 * <p>A character goes between its origins by the Fugue rule, decided from the origins alone: the
 * left child of {@code right_origin} when that character is deeper in the tree than
 * {@code left_origin} (the start has depth 0), otherwise the right child of {@code left_origin}
 * (or of the start). Each later character of one insert has the one before it as left origin, so
 * a typed run is one chain of right children. Siblings order by id, ascending; the text reads in
 * order (left children, the character, right children). The order is kept in blocks of at most
 * {@link #BLOCK_LIMIT} characters with live counts.
 */
public final class TextSequence {

    static final int BLOCK_LIMIT = 512;

    /** The origins a character was inserted with. */
    public record Origins(OpId left, OpId right) {
    }

    /** One character as a snapshot records it. */
    record RestoredChar(OpId id, int scalar, OpId left, OpId right, OpId deleted) {
    }

    /** Where the winners of every attribute change, and the winners from there on. */
    record Boundary(int position, Map<MarkKey, TextMark> winners) {
    }

    private static final class Char {
        final OpId id;
        final int codepoint;
        final OpId left;
        final OpId right;
        final int depth;
        OpId deletedBy;
        Block block;
        List<Char> leftChildren;
        List<Char> rightChildren;

        Char(OpId id, int codepoint, OpId left, OpId right, int depth) {
            this.id = id;
            this.codepoint = codepoint;
            this.left = left;
            this.right = right;
            this.depth = depth;
        }

        boolean live() {
            return deletedBy == null;
        }
    }

    private static final class Block {
        int ordinal;
        final List<Char> items = new ArrayList<>();
        int live;
    }

    private static final Comparator<Char> BY_ID = Comparator.comparing(c -> c.id);

    private final Map<OpId, Char> chars = new HashMap<>();
    private final List<Char> rootChildren = new ArrayList<>();
    private final List<Block> blocks = new ArrayList<>();
    private final Map<OpId, TextMark> marks = new HashMap<>();

    /** How many characters, tombstones included. */
    public int count() {
        return chars.size();
    }

    /** How many live characters. */
    public int liveCount() {
        int live = 0;
        for (Block block : blocks) {
            live += block.live;
        }
        return live;
    }

    /** Whether the field holds no characters and no marks. */
    public boolean isEmpty() {
        return chars.isEmpty() && marks.isEmpty();
    }

    /** Whether {@code id} is a character of this field (live or a tombstone). */
    public boolean contains(OpId id) {
        return chars.containsKey(id);
    }

    /** The Unicode scalar of character {@code id}, or {@code null}. */
    public Integer codepoint(OpId id) {
        Char c = chars.get(id);
        return c == null ? null : c.codepoint;
    }

    /** Whether character {@code id} is a tombstone. */
    public boolean isDeleted(OpId id) {
        Char c = chars.get(id);
        return c != null && !c.live();
    }

    /** The greatest delete of character {@code id}, or {@code null} while it is live (or unknown). */
    public OpId deletedOp(OpId id) {
        Char c = chars.get(id);
        return c == null ? null : c.deletedBy;
    }

    /** The origins character {@code id} was inserted with, or {@code null}. */
    public Origins origins(OpId id) {
        Char c = chars.get(id);
        return c == null ? null : new Origins(c.left, c.right);
    }

    // ---- Characters

    /**
     * Inserts {@code scalars} with ids {@code first}, {@code first + 1}, ... between {@code left}
     * and {@code right} (zero: the start / the end). Returns the ids inserted; none when an origin
     * is unknown.
     */
    List<OpId> insert(int[] scalars, OpId first, OpId left, OpId right) {
        if (!known(left) || !known(right)) {
            return List.of();
        }
        List<OpId> inserted = new ArrayList<>();
        OpId leftOrigin = left;
        for (int index = 0; index < scalars.length; index++) {
            OpId id = new OpId(first.counter() + index, first.replica());
            if (!chars.containsKey(id)) {
                insertChar(id, scalars[index], leftOrigin, right);
                inserted.add(id);
            }
            leftOrigin = id;
        }
        return inserted;
    }

    private boolean known(OpId id) {
        return id.equals(OpId.ZERO) || chars.containsKey(id);
    }

    // The Fugue rule, from the origins alone.
    private void insertChar(OpId id, int scalar, OpId left, OpId right) {
        Char leftChar = chars.get(left);
        Char rightChar = chars.get(right);
        int leftDepth = leftChar == null ? 0 : leftChar.depth;
        boolean underRight = rightChar != null && rightChar.depth > leftDepth;
        Char parent = underRight ? rightChar : leftChar;
        Char c = new Char(id, scalar, left, right, parent == null ? 1 : parent.depth + 1);
        chars.put(id, c);
        List<Char> siblings;
        if (underRight) {
            siblings = rightChar.leftChildren == null ? rightChar.leftChildren = new ArrayList<>() : rightChar.leftChildren;
        } else if (leftChar == null) {
            siblings = rootChildren;
        } else {
            siblings = leftChar.rightChildren == null ? leftChar.rightChildren = new ArrayList<>() : leftChar.rightChildren;
        }
        int index = -Collections.binarySearch(siblings, c, BY_ID) - 1;
        if (index > 0) {
            placeAfter(c, subtreeEnd(siblings.get(index - 1)));
        } else if (!underRight) {
            if (parent == null) {
                placeAtStart(c);
            } else {
                placeAfter(c, parent);
            }
        } else if (!siblings.isEmpty()) {
            placeBefore(c, subtreeStart(siblings.get(0)));
        } else {
            placeBefore(c, parent);
        }
        siblings.add(index, c);
    }

    private static Char subtreeEnd(Char c) {
        Char current = c;
        while (current.rightChildren != null && !current.rightChildren.isEmpty()) {
            current = current.rightChildren.get(current.rightChildren.size() - 1);
        }
        return current;
    }

    private static Char subtreeStart(Char c) {
        Char current = c;
        while (current.leftChildren != null && !current.leftChildren.isEmpty()) {
            current = current.leftChildren.get(0);
        }
        return current;
    }

    private void placeAtStart(Char c) {
        if (blocks.isEmpty()) {
            blocks.add(new Block());
        }
        place(c, blocks.get(0), 0);
    }

    private void placeAfter(Char c, Char other) {
        place(c, other.block, other.block.items.indexOf(other) + 1);
    }

    private void placeBefore(Char c, Char other) {
        place(c, other.block, other.block.items.indexOf(other));
    }

    private void place(Char c, Block block, int index) {
        block.items.add(index, c);
        block.live++;
        c.block = block;
        if (block.items.size() > BLOCK_LIMIT) {
            split(block);
        }
    }

    private void split(Block block) {
        int half = block.items.size() / 2;
        Block moved = new Block();
        List<Char> tail = block.items.subList(half, block.items.size());
        moved.items.addAll(tail);
        tail.clear();
        for (Char c : moved.items) {
            c.block = moved;
            if (c.live()) {
                moved.live++;
            }
        }
        block.live -= moved.live;
        blocks.add(block.ordinal + 1, moved);
        for (int ordinal = block.ordinal + 1; ordinal < blocks.size(); ordinal++) {
            blocks.get(ordinal).ordinal = ordinal;
        }
    }

    /**
     * The characters of this field among the ids {@code first}, {@code first + 1}, ...
     * ({@code count} of them, not past the largest counter), in id order: a {@code TextDelete}
     * range. A range longer than the field is matched against the field's characters instead.
     */
    List<OpId> ids(OpId first, long count) {
        long room = -1L - first.counter();
        long span = Long.compareUnsigned(count, room) < 0 ? count : room;
        List<OpId> out = new ArrayList<>();
        if (Long.compareUnsigned(span, chars.size()) <= 0) {
            for (long i = 0; i < span; i++) {
                OpId id = new OpId(first.counter() + i, first.replica());
                if (chars.containsKey(id)) {
                    out.add(id);
                }
            }
            return out;
        }
        for (OpId id : chars.keySet()) {
            if (id.replica() == first.replica() && Long.compareUnsigned(id.counter(), first.counter()) >= 0
                    && Long.compareUnsigned(id.counter() - first.counter(), span) < 0) {
                out.add(id);
            }
        }
        Collections.sort(out);
        return out;
    }

    /**
     * Deletes character {@code id} with {@code op}; returns whether it was live. Deleting a
     * tombstone again only keeps the greatest delete.
     */
    boolean delete(OpId id, OpId op) {
        Char c = chars.get(id);
        if (c == null) {
            return false;
        }
        if (c.live()) {
            c.deletedBy = op;
            c.block.live--;
            return true;
        }
        if (op.compareTo(c.deletedBy) > 0) {
            c.deletedBy = op;
        }
        return false;
    }

    // ---- Read-out

    /** Every character id in document order, tombstones included. */
    public List<OpId> order() {
        List<OpId> out = new ArrayList<>(chars.size());
        for (Block block : blocks) {
            for (Char c : block.items) {
                out.add(c.id);
            }
        }
        return out;
    }

    /** The live character ids in document order. */
    public List<OpId> liveChars() {
        List<OpId> out = new ArrayList<>();
        for (Block block : blocks) {
            for (Char c : block.items) {
                if (c.live()) {
                    out.add(c.id);
                }
            }
        }
        return out;
    }

    /** The live characters as a string (the plain-string read-out). */
    public String string() {
        StringBuilder text = new StringBuilder();
        for (Block block : blocks) {
            for (Char c : block.items) {
                if (c.live()) {
                    text.appendCodePoint(Character.isValidCodePoint(c.codepoint) ? c.codepoint : 0xFFFD);
                }
            }
        }
        return text.toString();
    }

    /**
     * The live offset of character {@code id}: how many live characters precede it (for a
     * tombstone, where it would be); {@code null} for an unknown id.
     */
    public Integer offset(OpId id) {
        Char c = chars.get(id);
        if (c == null) {
            return null;
        }
        int offset = 0;
        for (int ordinal = 0; ordinal < c.block.ordinal; ordinal++) {
            offset += blocks.get(ordinal).live;
        }
        for (Char other : c.block.items) {
            if (other == c) {
                break;
            }
            if (other.live()) {
                offset++;
            }
        }
        return offset;
    }

    /** The live character at live offset {@code offset}, or {@code null} when out of range. */
    public OpId charAt(int offset) {
        if (offset < 0) {
            return null;
        }
        int remaining = offset;
        for (Block block : blocks) {
            if (remaining >= block.live) {
                remaining -= block.live;
                continue;
            }
            for (Char c : block.items) {
                if (c.live()) {
                    if (remaining == 0) {
                        return c.id;
                    }
                    remaining--;
                }
            }
        }
        return null;
    }

    /** The character after {@code id} in document order, tombstones included; zero at the end. */
    public OpId successor(OpId id) {
        Char c = chars.get(id);
        if (c == null) {
            return OpId.ZERO;
        }
        int index = c.block.items.indexOf(c) + 1;
        for (int ordinal = c.block.ordinal; ordinal < blocks.size(); ordinal++) {
            List<Char> items = blocks.get(ordinal).items;
            if (index < items.size()) {
                return items.get(index).id;
            }
            index = 0;
        }
        return OpId.ZERO;
    }

    /**
     * The origins a client gives a {@code TextInsert} at live offset {@code offset}: the live
     * character before it (zero at the start) and that character's successor, tombstones included
     * (zero at the end).
     */
    public Origins insertionOrigins(int offset) {
        OpId left = offset > 0 ? charAt(offset - 1) : null;
        if (left == null) {
            for (Block block : blocks) {
                if (!block.items.isEmpty()) {
                    return new Origins(OpId.ZERO, block.items.get(0).id);
                }
            }
            return new Origins(OpId.ZERO, OpId.ZERO);
        }
        return new Origins(left, successor(left));
    }

    /** The document-order index of every character, by id. */
    Map<OpId, Integer> orderIndex() {
        Map<OpId, Integer> index = new HashMap<>(chars.size() * 2);
        int position = 0;
        for (Block block : blocks) {
            for (Char c : block.items) {
                index.put(c.id, position++);
            }
        }
        return index;
    }

    // ---- Marks

    /** Records a mark; false when its id is already recorded or an anchor names an unknown character. */
    boolean mark(TextMark mark) {
        if (marks.containsKey(mark.id()) || !known(mark.start()) || !known(mark.end())) {
            return false;
        }
        marks.put(mark.id(), mark);
        return true;
    }

    boolean known(Anchor anchor) {
        return known(anchor.character());
    }

    /** The marks, ascending by id. */
    public List<TextMark> sortedMarks() {
        List<TextMark> out = new ArrayList<>(marks.values());
        out.sort(Comparator.comparing(TextMark::id));
        return out;
    }

    /**
     * The document-order positions a mark covers ({@code [first, last]}), or {@code null} when it
     * covers nothing.
     */
    static int[] covered(TextMark mark, Map<OpId, Integer> index, int count) {
        int first;
        if (mark.start().character().equals(OpId.ZERO)) {
            first = mark.start().before() ? 0 : count;
        } else {
            first = index.get(mark.start().character()) + (mark.start().before() ? 0 : 1);
        }
        int last;
        if (mark.end().character().equals(OpId.ZERO)) {
            last = mark.end().before() ? -1 : count - 1;
        } else {
            last = index.get(mark.end().character()) - (mark.end().before() ? 1 : 0);
        }
        return first <= last ? new int[] {first, last} : null;
    }

    /**
     * The winning mark of each attribute for every character, as boundaries: at each position
     * where the winners change, the winners from there on ({@code key}: that attribute only).
     */
    List<Boundary> winners(Map<OpId, Integer> index, MarkKey key) {
        TreeMap<Integer, List<Object[]>> events = new TreeMap<>();
        for (TextMark mark : marks.values()) {
            int[] range = mark.key() == null || key != null && !key.equals(mark.key()) ? null
                    : covered(mark, index, chars.size());
            if (range != null) {
                events.computeIfAbsent(range[0], p -> new ArrayList<>()).add(new Object[] {true, mark});
                events.computeIfAbsent(range[1] + 1, p -> new ArrayList<>()).add(new Object[] {false, mark});
            }
        }
        Map<MarkKey, List<TextMark>> active = new HashMap<>();
        List<Boundary> out = new ArrayList<>();
        for (Map.Entry<Integer, List<Object[]>> entry : events.entrySet()) {
            for (Object[] event : entry.getValue()) {
                TextMark mark = (TextMark) event[1];
                List<TextMark> ofKey = active.computeIfAbsent(mark.key(), k -> new ArrayList<>());
                if ((Boolean) event[0]) {
                    ofKey.add(mark);
                } else {
                    ofKey.remove(mark);
                }
            }
            Map<MarkKey, TextMark> winners = new HashMap<>();
            active.forEach((markKey, ofKey) -> ofKey.stream().max(Comparator.comparing(TextMark::id))
                    .ifPresent(best -> winners.put(markKey, best)));
            out.add(new Boundary(entry.getKey(), winners));
        }
        return out;
    }

    /**
     * The attributed runs (CRDT-006): maximal ranges of live characters with the same winning
     * marks, cleared values left out.
     */
    public List<TextRun> runs() {
        List<Boundary> boundaries = winners(orderIndex(), null);
        List<TextRun> runs = new ArrayList<>();
        int offset = 0;
        List<TextAttribute> current = List.of();
        int length = 0;
        int boundary = 0;
        Map<MarkKey, TextMark> winners = Map.of();
        int position = 0;
        for (Block block : blocks) {
            for (Char c : block.items) {
                while (boundary < boundaries.size() && boundaries.get(boundary).position() <= position) {
                    winners = boundaries.get(boundary).winners();
                    boundary++;
                }
                position++;
                if (!c.live()) {
                    continue;
                }
                List<TextAttribute> attributes = attributes(winners);
                if (length > 0 && !attributes.equals(current)) {
                    runs.add(new TextRun(offset, length, current));
                    offset += length;
                    length = 0;
                }
                current = attributes;
                length++;
            }
        }
        if (length > 0) {
            runs.add(new TextRun(offset, length, current));
        }
        return runs;
    }

    static List<TextAttribute> attributes(Map<MarkKey, TextMark> winners) {
        List<TextAttribute> out = new ArrayList<>();
        for (TextMark mark : winners.values()) {
            if (!MarkValue.isCleared(mark.valueBytes(), mark.key())) {
                out.add(new TextAttribute(mark.key(), mark.valueBytes(), mark.id()));
            }
        }
        out.sort(Comparator.comparing(TextAttribute::key));
        return out;
    }

    private static Map<MarkKey, TextMark> at(List<Boundary> boundaries, int position) {
        Map<MarkKey, TextMark> winners = Map.of();
        for (Boundary boundary : boundaries) {
            if (boundary.position() <= position) {
                winners = boundary.winners();
            }
        }
        return winners;
    }

    /** The winning mark of {@code key} for each of {@code ids}, by id (absent: none covers it). */
    Map<OpId, TextMark> winners(MarkKey key, List<OpId> ids) {
        Map<OpId, Integer> index = orderIndex();
        List<Boundary> boundaries = winners(index, key);
        Map<OpId, TextMark> out = new HashMap<>();
        for (OpId id : ids) {
            Integer position = index.get(id);
            TextMark found = position == null ? null : at(boundaries, position).get(key);
            if (found != null) {
                out.put(id, found);
            }
        }
        return out;
    }

    /** The attributes of each of {@code ids} (cleared values left out), by id. */
    Map<OpId, List<TextAttribute>> attributes(List<OpId> ids) {
        Map<OpId, Integer> index = orderIndex();
        List<Boundary> boundaries = winners(index, null);
        Map<OpId, List<TextAttribute>> out = new HashMap<>();
        for (OpId id : ids) {
            Integer position = index.get(id);
            if (position != null) {
                out.put(id, attributes(at(boundaries, position)));
            }
        }
        return out;
    }

    // ---- Restoring

    /**
     * Rebuilds a field from its characters and marks, as a snapshot holds them: characters in id
     * order, retrying any whose origins are missing until none progress (one whose origins never
     * appear is dropped, as the op that made it would have been a no-op).
     */
    static TextSequence restore(List<RestoredChar> restored, List<TextMark> marks) {
        TextSequence text = new TextSequence();
        List<RestoredChar> pending = new ArrayList<>(restored);
        pending.sort(Comparator.comparing(RestoredChar::id));
        boolean progress = true;
        while (progress && !pending.isEmpty()) {
            progress = false;
            List<RestoredChar> waiting = new ArrayList<>();
            for (RestoredChar c : pending) {
                if (text.chars.containsKey(c.id())) {
                    continue;
                }
                if (!text.known(c.left()) || !text.known(c.right())) {
                    waiting.add(c);
                    continue;
                }
                text.insertChar(c.id(), c.scalar(), c.left(), c.right());
                if (c.deleted() != null) {
                    text.delete(c.id(), c.deleted());
                }
                progress = true;
            }
            pending = waiting;
        }
        for (TextMark mark : marks) {
            text.mark(mark);
        }
        return text;
    }
}
