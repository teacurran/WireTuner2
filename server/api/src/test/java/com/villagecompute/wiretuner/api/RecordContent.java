package com.villagecompute.wiretuner.api;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;

/** Checks that a record with a byte-array component compares, hashes and prints by content (Sonar java:S6218). */
public final class RecordContent {

    private RecordContent() {
    }

    /**
     * What keeps records built by {@code make} (from fresh arrays) from comparing, hashing and printing by
     * content: empty when they are equal and hash alike, differ from each of {@code variants} (each differs
     * in one component) and print {@code shown}.
     */
    @SafeVarargs
    public static <T> List<String> contentProblems(Supplier<T> make, String shown, T... variants) {
        T one = make.get();
        T two = make.get();
        Object text = "x";
        List<String> problems = new ArrayList<>();
        if (!one.equals(two)) {
            problems.add("records built from equal arrays differ: " + one + " / " + two);
        }
        if (one.hashCode() != two.hashCode()) {
            problems.add("records built from equal arrays hash differently");
        }
        if (one.equals(text)) {
            problems.add("equal to a string");
        }
        if (!one.toString().contains(shown)) {
            problems.add("toString lacks " + shown + ": " + one);
        }
        if (!one.toString().equals(two.toString())) {
            problems.add("toString differs between equal records");
        }
        for (T variant : variants) {
            if (one.equals(variant)) {
                problems.add("equal to a variant differing in one component: " + variant);
            }
        }
        return problems;
    }
}
