package com.villagecompute.wiretuner.crdt;

/**
 * The merge engine. Mirrors {@code WTCRDT.Engine} type for type once CRDT-002 lands; for now it
 * only names the engine version the server reports, so the module has a class to build, test and
 * measure.
 */
public final class Engine {

    /** Version of the merge semantics this engine implements (docs/spec/crdt-model.adoc). */
    public static final String VERSION = "0.1.0";

    private Engine() {
    }

    /** The engine version, for health data and snapshot metadata. */
    public static String version() {
        return VERSION;
    }
}
