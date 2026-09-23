package com.villagecompute.wiretuner.api.sync;

import java.util.ArrayList;
import java.util.List;

import com.villagecompute.wiretuner.sync.v1.FetchChangesResponse;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

/**
 * Packs a catch-up download into {@code FetchChangesResponse} frames of at most 1 MiB of changes
 * and at most 256 changes (docs/spec/sync-protocol.adoc, Catch-up); a single change larger than
 * 1 MiB travels alone.
 */
final class FramePacker {

    private final long headSeq;
    private final List<SequencedChange> current = new ArrayList<>();
    private int bytes;

    FramePacker(long headSeq) {
        this.headSeq = headSeq;
    }

    /** Takes the next change; returns the frame it closed, if adding it would have overfilled one. */
    List<FetchChangesResponse> add(SequencedChange change) {
        int size = change.getSerializedSize();
        List<FetchChangesResponse> closed = new ArrayList<>(1);
        boolean full = current.size() == ChangeReader.PAGE || bytes + size > ChangeRules.MAX_FRAME_BYTES;
        if (full && !current.isEmpty()) {
            closed.add(frame());
        }
        current.add(change);
        bytes += size;
        return closed;
    }

    /** The last frame, if any change is left. */
    List<FetchChangesResponse> flush() {
        return current.isEmpty() ? List.of() : List.of(frame());
    }

    private FetchChangesResponse frame() {
        FetchChangesResponse frame = FetchChangesResponse.newBuilder().addAllChanges(current).setHeadSeq(headSeq).build();
        current.clear();
        bytes = 0;
        return frame;
    }
}
