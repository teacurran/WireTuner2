package com.villagecompute.wiretuner.api.data;

import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One Fetch, FetchAsset or Proxy call on its way through the proxy: who, which scope and document,
 * the credential it opened, the addresses it pinned, its place under the concurrency caps, and the
 * counts its audit row records (data-merge.adoc, Rate limits and audit).
 */
final class Run {

    final Scopes.Caller caller;
    final UUID documentId;
    final String kind;
    final Instant startedAt = Instant.now();
    final Egress.Pins pins = new Egress.Pins();
    final AtomicBoolean finished = new AtomicBoolean();

    DataLimits.Lease lease;
    CredentialVault.Opened credential;
    Long sourceCounter;
    Long sourceReplica;
    /** The first request's host key and path (no query): what the audit row names. */
    String host = "";
    String path = "";
    int pages;
    long records;
    long bytes;

    Run(Scopes.Caller caller, UUID documentId, String kind) {
        this.caller = caller;
        this.documentId = documentId;
        this.kind = kind;
    }

    DataScope scope() {
        return caller.scope();
    }

    /** The header the opened credential sets, or null without one. */
    String credentialHeader() {
        return credential == null ? null : credential.headerName();
    }
}
