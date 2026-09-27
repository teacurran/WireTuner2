package com.villagecompute.wiretuner.api;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.function.Supplier;

/** Checks that a record with a byte-array component compares, hashes and prints by content (Sonar java:S6218). */
public final class RecordContent {

    private RecordContent() {
    }

    /**
     * {@code make} builds equal records from fresh arrays; each of {@code variants} differs from them in
     * one component. The record prints {@code shown}.
     */
    @SafeVarargs
    public static <T> void byContent(Supplier<T> make, String shown, T... variants) {
        T one = make.get();
        T two = make.get();
        Object text = "x";
        assertThat(one).isEqualTo(one).isEqualTo(two).hasSameHashCodeAs(two).isNotEqualTo(text).isNotEqualTo(null);
        assertThat(one.toString()).contains(shown).isEqualTo(two.toString());
        for (T variant : variants) {
            assertThat(one).isNotEqualTo(variant);
        }
    }
}
