package com.villagecompute.wiretuner.api.account;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.Binding;
import com.villagecompute.wiretuner.account.v1.PreferenceValue;
import com.villagecompute.wiretuner.account.v1.ShortcutSet;
import com.villagecompute.wiretuner.account.v1.ShortcutSets;

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

    static ShortcutSet set(String id, String name, long at, boolean deleted) {
        return ShortcutSet.newBuilder().setId(id).setName(name).setUpdatedAtMs(at).setDeleted(deleted)
                .addBindings(Binding.newBuilder().setCommandId("tool.pen").addKeys("p")).build();
    }

    static PreferenceValue sets(long at, String active, long activeAt, ShortcutSet... sets) {
        ShortcutSets.Builder value = ShortcutSets.newBuilder().setActiveSetId(active).setActiveSetUpdatedAtMs(activeAt);
        for (ShortcutSet set : sets) {
            value.addSets(set);
        }
        return PreferenceValue.newBuilder().setShortcutSetsValue(value).setUpdatedAtMs(at).setDevice("d").build();
    }

    static com.villagecompute.wiretuner.account.v1.Preferences map(PreferenceValue value) {
        return com.villagecompute.wiretuner.account.v1.Preferences.newBuilder().putValues("sync.shortcut_sets", value).build();
    }

    /** BASIC-028: shortcut sets merge per set id, tombstones compete like edits and expire after 30 days. */
    @Test
    void shortcutSetsMergePerSetWithTombstones() {
        long day = 24L * 60 * 60 * 1000;
        long now = 100 * day;
        var stored = map(sets(now - 5, "a", now - 5,
                set("a", "Mine", now - 5, false),
                set("b", "Edited", now - 3, false),
                set("c", "", now - 40 * day, true),
                set("d", "", now - 2 * day, true)));
        var changes = map(sets(now - 4, "b", now - 6,
                set("a", "Older", now - 9, false),
                set("b", "", now - 2, true),
                set("e", "Fresh", now - 1, false)));
        var merged = Preferences.merge(stored, changes, now).getValuesOrThrow("sync.shortcut_sets");
        var value = merged.getShortcutSetsValue();
        assertThat(value.getSetsList()).extracting(ShortcutSet::getId).containsExactly("a", "b", "d", "e");
        assertThat(value.getSets(0).getName()).isEqualTo("Mine");
        assertThat(value.getSets(1).getDeleted()).isTrue();
        assertThat(value.getActiveSetId()).isEqualTo("a");
        assertThat(merged.getUpdatedAtMs()).isEqualTo(now - 4);

        // A newer choice of set wins; a tie on a set goes to the change.
        var again = Preferences.merge(Preferences.merge(stored, changes, now), map(sets(now, "e", now, set("e", "Tie", now - 1, false))), now)
                .getValuesOrThrow("sync.shortcut_sets").getShortcutSetsValue();
        assertThat(again.getActiveSetId()).isEqualTo("e");
        assertThat(again.getSets(3).getName()).isEqualTo("Tie");

        // A change that carries no choice keeps the stored one; a first value is stored as sent.
        var noChoice = Preferences.mergeSets(ShortcutSets.newBuilder().setActiveSetId("x").build(), ShortcutSets.getDefaultInstance(), now);
        assertThat(noChoice.getActiveSetId()).isEqualTo("x");
        var first = Preferences.merge(com.villagecompute.wiretuner.account.v1.Preferences.getDefaultInstance(), changes, now);
        assertThat(first).isEqualTo(changes);

        // Another value kind on either side falls back to newest-wins for the whole entry.
        var plain = map(value(true, now + 1));
        assertThat(Preferences.merge(stored, plain, now).getValuesOrThrow("sync.shortcut_sets").getBoolValue()).isTrue();
        assertThat(Preferences.merge(plain, changes, now).getValuesOrThrow("sync.shortcut_sets").getBoolValue()).isTrue();
        assertThat(Preferences.parse(Preferences.json(Preferences.merge(stored, changes, now)).await().indefinitely()).await().indefinitely())
                .isEqualTo(Preferences.merge(stored, changes, now));
    }
}
