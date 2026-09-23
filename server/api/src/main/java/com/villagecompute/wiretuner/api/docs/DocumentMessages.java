package com.villagecompute.wiretuner.api.docs;

import java.util.HexFormat;
import java.util.Map;
import java.util.UUID;

import com.google.protobuf.ByteString;
import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.persistence.Folder;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.DocumentRow;
import com.villagecompute.wiretuner.docs.v1.Document;
import com.villagecompute.wiretuner.docs.v1.DocumentKind;

/** Library rows to {@code wiretuner.docs.v1} messages, and the stored forms of their enums. */
public final class DocumentMessages {

    static final Map<DocumentKind, String> KIND_NAMES = Map.of(
            DocumentKind.DOCUMENT_KIND_ILLUSTRATION_SINGLE_PAGE, "illustration_single_page",
            DocumentKind.DOCUMENT_KIND_ILLUSTRATION_MULTI_PAGE, "illustration_multi_page",
            DocumentKind.DOCUMENT_KIND_TYPEFACE, "typeface");

    private DocumentMessages() {
    }

    /** The stored kind; UNSPECIFIED reads as a multi-page illustration. */
    static String kindName(DocumentKind kind) {
        return KIND_NAMES.getOrDefault(kind, "illustration_multi_page");
    }

    static DocumentKind kind(String stored) {
        for (var entry : KIND_NAMES.entrySet()) {
            if (entry.getValue().equals(stored)) {
                return entry.getKey();
            }
        }
        return DocumentKind.DOCUMENT_KIND_UNSPECIFIED;
    }

    public static DocumentRole role(Role role) {
        return switch (role) {
            case OWNER -> DocumentRole.DOCUMENT_ROLE_OWNER;
            case EDITOR -> DocumentRole.DOCUMENT_ROLE_EDITOR;
            case COMMENTER -> DocumentRole.DOCUMENT_ROLE_COMMENTER;
            case VIEWER -> DocumentRole.DOCUMENT_ROLE_VIEWER;
            case NONE -> DocumentRole.DOCUMENT_ROLE_UNSPECIFIED;
        };
    }

    static Document document(DocumentRow row, Role callerRole) {
        Document.Builder doc = Document.newBuilder()
                .setId(row.id().toString())
                .setSpaceId(row.spaceId().toString())
                .setFolderId(string(row.folderId()))
                .setName(row.name())
                .setKind(kind(row.kind()))
                .setOwnerAccountId(string(row.documentOwnerId()))
                .setCreatedByAccountId(string(row.createdByAccountId()))
                .setCallerRole(role(callerRole))
                .setHeadSeq(row.headSeq())
                .setFeatureLevel(row.featureLevel())
                .setCreatedAt(micros(row.createdAtMicros()))
                .setUpdatedAt(micros(row.updatedAtMicros()))
                .setIsTemplate(row.template())
                .setIsLibrary(row.library())
                .setParentDocumentId(string(row.parentDocumentId()));
        if (row.trashedAtMicros() != null) {
            doc.setTrashedAt(micros(row.trashedAtMicros()));
        }
        if (row.thumbnailBlob() != null) {
            doc.setThumbnailBlob(ByteString.copyFrom(HexFormat.of().parseHex(row.thumbnailBlob())))
                    .setThumbnailAt(micros(row.thumbnailAtMicros()));
        }
        return doc.build();
    }

    static com.villagecompute.wiretuner.docs.v1.Folder folder(Folder folder) {
        return com.villagecompute.wiretuner.docs.v1.Folder.newBuilder()
                .setId(folder.id.toString())
                .setSpaceId(Spaces.spaceOf(folder).toString())
                .setParentFolderId(string(folder.parentFolderId))
                .setName(folder.name)
                .setCreatedAt(Timestamp.newBuilder()
                        .setSeconds(folder.createdAt.getEpochSecond())
                        .setNanos(folder.createdAt.getNano()))
                .build();
    }

    static Timestamp micros(long micros) {
        return Timestamp.newBuilder()
                .setSeconds(Math.floorDiv(micros, 1_000_000L))
                .setNanos((int) Math.floorMod(micros, 1_000_000L) * 1000)
                .build();
    }

    /** A UUID as the empty-when-unset string the protos use. */
    static String string(UUID id) {
        return id == null ? "" : id.toString();
    }

    /** An optional UUID field: empty is null. Validation has already checked the format. */
    static UUID optionalUuid(String value) {
        return value.isEmpty() ? null : UUID.fromString(value);
    }
}
