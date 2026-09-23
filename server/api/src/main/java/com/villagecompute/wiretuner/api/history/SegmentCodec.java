package com.villagecompute.wiretuner.api.history;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import com.villagecompute.wiretuner.crdt.Zstd;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

/**
 * A cold segment's object (docs/spec/server.adoc, Jobs, Compactor): the moved {@code change_log}
 * rows as length-delimited {@code SequencedChange}s ({@code server_seq} and the change's bytes as
 * logged; the author is resolved from the replica when read, as for hot rows), in server_seq
 * order, compressed as one zstd frame that carries its content size.
 */
public final class SegmentCodec {

    /** The media type segments are stored with. */
    public static final String MEDIA_TYPE = "application/zstd";

    private SegmentCodec() {
    }

    /** The object for {@code changes}. */
    public static byte[] encode(List<SequencedChange> changes) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (SequencedChange change : changes) {
            byte[] bytes = change.toByteArray();
            int length = bytes.length;
            while (length >= 0x80) {
                out.write((length & 0x7F) | 0x80);
                length >>>= 7;
            }
            out.write(length);
            out.writeBytes(bytes);
        }
        return Zstd.compress(out.toByteArray());
    }

    /**
     * The changes in a segment object.
     *
     * @throws IllegalArgumentException when the object is not a segment
     */
    public static List<SequencedChange> decode(byte[] object) {
        long size = com.github.luben.zstd.Zstd.getFrameContentSize(object);
        if (size < 0) {
            throw new IllegalArgumentException("not a cold segment: no zstd content size");
        }
        ByteArrayInputStream in = new ByteArrayInputStream(Zstd.decompress(object, (int) size));
        List<SequencedChange> changes = new ArrayList<>();
        try {
            SequencedChange change;
            while ((change = SequencedChange.parseDelimitedFrom(in)) != null) {
                changes.add(change);
            }
        } catch (IOException e) {
            throw new IllegalArgumentException("not a cold segment: " + e.getMessage(), e);
        }
        return changes;
    }
}
