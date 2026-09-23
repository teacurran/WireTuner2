package com.villagecompute.wiretuner.api.account;

import java.util.Map;

import com.google.protobuf.util.JsonFormat;
import com.villagecompute.wiretuner.account.v1.PreferenceValue;

import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.unchecked.Unchecked;

/**
 * Synced preferences (account.v1 preferences.proto): the per-key merge -- the entry with the greater
 * {@code updated_at_ms} wins, a tie goes to the later receipt -- and the JSON form stored in
 * {@code account.preferences} (the proto3 JSON mapping of {@code Preferences}, so the digest job can
 * read {@code values.<id>.boolValue} in SQL). The stored map is capped at {@value #CAP_BYTES} bytes.
 */
final class Preferences {

    /** The stored map's cap (preferences.proto). */
    static final int CAP_BYTES = 64 * 1024;

    private Preferences() {
    }

    /** The stored map merged with the changes. */
    static com.villagecompute.wiretuner.account.v1.Preferences merge(
            com.villagecompute.wiretuner.account.v1.Preferences stored,
            com.villagecompute.wiretuner.account.v1.Preferences changes) {
        com.villagecompute.wiretuner.account.v1.Preferences.Builder merged = stored.toBuilder();
        for (Map.Entry<String, PreferenceValue> change : changes.getValuesMap().entrySet()) {
            PreferenceValue current = stored.getValuesMap().get(change.getKey());
            if (current == null || change.getValue().getUpdatedAtMs() >= current.getUpdatedAtMs()) {
                merged.putValues(change.getKey(), change.getValue());
            }
        }
        return merged.build();
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
