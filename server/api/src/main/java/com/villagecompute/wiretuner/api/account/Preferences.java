package com.villagecompute.wiretuner.api.account;

import java.util.Map;
import java.util.TreeMap;

import com.google.protobuf.util.JsonFormat;
import com.villagecompute.wiretuner.account.v1.PreferenceValue;
import com.villagecompute.wiretuner.account.v1.ShortcutSet;
import com.villagecompute.wiretuner.account.v1.ShortcutSets;

import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.unchecked.Unchecked;

/**
 * Synced preferences (account.v1 preferences.proto): the per-key merge -- the entry with the greater
 * {@code updated_at_ms} wins, a tie goes to the later receipt -- and the JSON form stored in
 * {@code account.preferences} (the proto3 JSON mapping of {@code Preferences}, so the digest job can
 * read {@code values.<id>.boolValue} in SQL). The stored map is capped at {@value #CAP_BYTES} bytes.
 *
 * <p>{@code sync.shortcut_sets} (BASIC-028) is merged per set instead: of two versions of one set id the
 * greater {@code updated_at_ms} wins (the change on a tie), a deletion is a tombstone that competes the same
 * way and is dropped {@value #TOMBSTONE_DAYS} days after it was written, and {@code active_set_id} is
 * newest-wins on its own stamp (customizing.adoc, "Merge semantics").
 */
final class Preferences {

    /** The stored map's cap (preferences.proto). */
    static final int CAP_BYTES = 64 * 1024;

    /** How long a deleted shortcut set's tombstone is kept. */
    static final int TOMBSTONE_DAYS = 30;

    static final long TOMBSTONE_MS = TOMBSTONE_DAYS * 24L * 60 * 60 * 1000;

    private Preferences() {
    }

    /** The stored map merged with the changes, tombstones judged against the wall clock. */
    static com.villagecompute.wiretuner.account.v1.Preferences merge(
            com.villagecompute.wiretuner.account.v1.Preferences stored,
            com.villagecompute.wiretuner.account.v1.Preferences changes) {
        return merge(stored, changes, System.currentTimeMillis());
    }

    /** The stored map merged with the changes; {@code nowMs} ages the shortcut set tombstones. */
    static com.villagecompute.wiretuner.account.v1.Preferences merge(
            com.villagecompute.wiretuner.account.v1.Preferences stored,
            com.villagecompute.wiretuner.account.v1.Preferences changes, long nowMs) {
        com.villagecompute.wiretuner.account.v1.Preferences.Builder merged = stored.toBuilder();
        for (Map.Entry<String, PreferenceValue> change : changes.getValuesMap().entrySet()) {
            PreferenceValue current = stored.getValuesMap().get(change.getKey());
            PreferenceValue incoming = change.getValue();
            if (current != null && current.hasShortcutSetsValue() && incoming.hasShortcutSetsValue()) {
                merged.putValues(change.getKey(), incoming.toBuilder()
                        .setShortcutSetsValue(mergeSets(current.getShortcutSetsValue(), incoming.getShortcutSetsValue(), nowMs))
                        .setUpdatedAtMs(Math.max(current.getUpdatedAtMs(), incoming.getUpdatedAtMs())).build());
            } else if (current == null || incoming.getUpdatedAtMs() >= current.getUpdatedAtMs()) {
                merged.putValues(change.getKey(), incoming);
            }
        }
        return merged.build();
    }

    /** Two shortcut set lists merged per set id, in id order, expired tombstones left out. */
    static ShortcutSets mergeSets(ShortcutSets stored, ShortcutSets changes, long nowMs) {
        Map<String, ShortcutSet> byId = new TreeMap<>();
        for (ShortcutSet set : stored.getSetsList()) {
            byId.merge(set.getId(), set, Preferences::newer);
        }
        for (ShortcutSet set : changes.getSetsList()) {
            byId.merge(set.getId(), set, Preferences::newer);
        }
        ShortcutSets.Builder out = ShortcutSets.newBuilder();
        for (ShortcutSet set : byId.values()) {
            if (!set.getDeleted() || nowMs - set.getUpdatedAtMs() < TOMBSTONE_MS) {
                out.addSets(set);
            }
        }
        boolean changeWins = changes.getActiveSetUpdatedAtMs() >= stored.getActiveSetUpdatedAtMs()
                && changes.getActiveSetUpdatedAtMs() > 0;
        ShortcutSets active = changeWins ? changes : stored;
        return out.setActiveSetId(active.getActiveSetId()).setActiveSetUpdatedAtMs(active.getActiveSetUpdatedAtMs()).build();
    }

    /** The later of two versions of one set; the second (the one received later) on a tie. */
    static ShortcutSet newer(ShortcutSet earlier, ShortcutSet later) {
        return later.getUpdatedAtMs() >= earlier.getUpdatedAtMs() ? later : earlier;
    }

    static Uni<String> json(com.villagecompute.wiretuner.account.v1.Preferences preferences) {
        return Uni.createFrom().item(Unchecked.supplier(() -> JsonFormat.printer().omittingInsignificantWhitespace()
                .print(preferences)));
    }

    /** The stored JSON as a message. */
    static Uni<com.villagecompute.wiretuner.account.v1.Preferences> parse(String json) {
        return Uni.createFrom().item(Unchecked.supplier(() -> {
            com.villagecompute.wiretuner.account.v1.Preferences.Builder builder =
                    com.villagecompute.wiretuner.account.v1.Preferences.newBuilder();
            JsonFormat.parser().ignoringUnknownFields().merge(json, builder);
            return builder.build();
        }));
    }
}
