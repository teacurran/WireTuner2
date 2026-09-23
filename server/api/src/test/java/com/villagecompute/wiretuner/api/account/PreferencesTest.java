package com.villagecompute.wiretuner.api.account;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.PreferenceValue;

/** The per-key merge of synced preferences: newest updated_at_ms wins, a tie goes to the later receipt. */
class PreferencesTest {

    static PreferenceValue value(boolean on, long at) {
        return PreferenceValue.newBuilder().setBoolValue(on).setUpdatedAtMs(at).build();
    }

    @Test
    void newestWinsPerKeyAndTiesGoToTheLaterReceipt() {
        var stored = com.villagecompute.wiretuner.account.v1.Preferences.newBuilder()
                .putValues("sync.email_mentions", value(true, 10))
                .putValues("general.smart_guides", value(true, 10))
                .putValues("sync.share_presence", value(true, 10)).build();
        var changes = com.villagecompute.wiretuner.account.v1.Preferences.newBuilder()
                .putValues("sync.email_mentions", value(false, 11))
                .putValues("general.smart_guides", value(false, 9))
                .putValues("sync.share_presence", value(false, 10))
                .putValues("text.smart_quotes", value(true, 1)).build();
        var merged = Preferences.merge(stored, changes);
        assertThat(merged.getValuesOrThrow("sync.email_mentions").getBoolValue()).isFalse();
        assertThat(merged.getValuesOrThrow("general.smart_guides").getBoolValue()).isTrue();
        assertThat(merged.getValuesOrThrow("sync.share_presence").getBoolValue()).isFalse();
        assertThat(merged.getValuesOrThrow("text.smart_quotes").getBoolValue()).isTrue();
        assertThat(Preferences.parse(Preferences.json(merged).await().indefinitely()).await().indefinitely()).isEqualTo(merged);
    }
}
