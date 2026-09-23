package com.villagecompute.wiretuner.api.data;

import java.time.Instant;
import java.util.UUID;

import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.data.v1.AllowedHost;
import com.villagecompute.wiretuner.data.v1.Credential;
import com.villagecompute.wiretuner.data.v1.FetchAuditEntry;
import com.villagecompute.wiretuner.data.v1.FetchKind;
import com.villagecompute.wiretuner.doc.v1.ElementId;

/** Rows of the data service as their wiretuner.data.v1 messages. Nothing here can carry secret material. */
final class DataMessages {

    private DataMessages() {
    }

    static Credential credential(CredentialRepository.Stored row) {
        Credential.Builder message = Credential.newBuilder()
                .setName(row.name())
                .setKind(Secret.kind(row.kind()))
                .setHost(row.host())
                .setCreatedByAccountId(id(row.createdBy()))
                .setCreatedByName(row.createdByName())
                .setCreatedAt(timestamp(row.createdAt().toInstant()));
        if (row.rotatedAt() != null) {
            message.setRotatedAt(timestamp(row.rotatedAt().toInstant()));
        }
        return message.build();
    }

    static AllowedHost host(AllowedHostRepository.Entry entry) {
        return AllowedHost.newBuilder()
                .setHost(entry.host())
                .setAddedByAccountId(id(entry.addedBy()))
                .setAddedByName(entry.addedByName())
                .setAddedAt(timestamp(entry.addedAt().toInstant()))
                .build();
    }

    static FetchAuditEntry audit(FetchAuditRepository.Entry e) {
        FetchAuditEntry.Builder message = FetchAuditEntry.newBuilder()
                .setId(e.id().toString())
                .setDocumentId(e.documentId().toString())
                .setAccountId(id(e.accountId()))
                .setAccountName(e.accountName())
                .setHost(e.host())
                .setPath(e.path())
                .setKind(kind(e.kind()))
                .setStartedAt(timestamp(e.startedAt()))
                .setFinishedAt(timestamp(e.finishedAt()))
                .setStatus(e.status())
                .setPages(e.pages())
                .setRecords(e.records())
                .setBytes(e.bytes());
        if (e.sourceCounter() != null) {
            message.setSourceId(ElementId.newBuilder().setCounter(e.sourceCounter()).setReplica(e.sourceReplica()));
        }
        return message.build();
    }

    static FetchKind kind(String kind) {
        return switch (kind) {
            case "source" -> FetchKind.FETCH_KIND_SOURCE;
            case "script" -> FetchKind.FETCH_KIND_SCRIPT;
            default -> FetchKind.FETCH_KIND_ASSET;
        };
    }

    static String id(UUID id) {
        return id == null ? "" : id.toString();
    }

    static Timestamp timestamp(Instant instant) {
        return Timestamp.newBuilder().setSeconds(instant.getEpochSecond()).setNanos(instant.getNano()).build();
    }
}
