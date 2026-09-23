package com.villagecompute.wiretuner.api.history;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

import com.google.protobuf.InvalidProtocolBufferException;
import com.google.protobuf.Message;
import com.villagecompute.wiretuner.crdt.Cell;
import com.villagecompute.wiretuner.crdt.NodeStore;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.crdt.Placement;
import com.villagecompute.wiretuner.crdt.Register;
import com.villagecompute.wiretuner.crdt.RegisterPath;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.DocumentInfo;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.SettingsProps;

/**
 * A document's search record from its merged state (docs/spec/server.adoc, Search), read through
 * the generic node tree only: for every live node (neither it nor an ancestor deleted, and not
 * under the comments collection) its {@code CommonProps.name} as a names line and its
 * {@code note} as a body line; the plain text of every TEXT field of a text block as body lines;
 * the document's title, description and keywords (settings {@code info}) as names lines. Every
 * line carries the prefix the search reads the field from: {@code p:} page, {@code s:} swatch,
 * {@code st:} style, {@code sy:} symbol, {@code o:} any other node (brushes included, the search
 * having no brush field), {@code k:} keyword, title or description; {@code t:} text, {@code n:}
 * note. Multi-line values become one line per non-blank line.
 */
public final class SearchExtractor {

    /** The lines of the record: {@code names} and {@code body_text} of {@code document_search}. */
    public record Record(String names, String bodyText) {
    }

    /** Register paths start at the kind (a {@code NodeProps} field); every kind has {@code CommonProps common = 1}. */
    static final int COMMON = 1;
    static final RegisterPath TITLE = RegisterPath.of(NodeProps.SETTINGS_FIELD_NUMBER, SettingsProps.INFO_FIELD_NUMBER,
            DocumentInfo.TITLE_FIELD_NUMBER);
    static final RegisterPath DESCRIPTION = RegisterPath.of(NodeProps.SETTINGS_FIELD_NUMBER,
            SettingsProps.INFO_FIELD_NUMBER, DocumentInfo.DESCRIPTION_FIELD_NUMBER);
    static final RegisterPath KEYWORDS = RegisterPath.of(NodeProps.SETTINGS_FIELD_NUMBER, SettingsProps.INFO_FIELD_NUMBER,
            DocumentInfo.KEYWORDS_FIELD_NUMBER);

    /** The comments collection (0:12): conversation, not artwork. */
    static final OpId COMMENTS = OpId.wellKnown(12);

    private static final Pattern LINES = Pattern.compile("[\\r\\n\\u2028\\u2029]+");

    private SearchExtractor() {
    }

    /** The search record of {@code store}. */
    public static Record extract(NodeStore store) {
        List<String> names = new ArrayList<>();
        List<String> body = new ArrayList<>();
        for (OpId node : store.nodes()) {
            if (!live(store, node)) {
                continue;
            }
            int kind = store.kind(node);
            lines(names, prefix(kind), parse(value(store, node, RegisterPath.of(kind, COMMON, CommonProps.NAME_FIELD_NUMBER)),
                    CommonProps.getDefaultInstance()).getName());
            lines(body, "n", parse(value(store, node, RegisterPath.of(kind, COMMON, CommonProps.NOTE_FIELD_NUMBER)),
                    CommonProps.getDefaultInstance()).getNote());
            if (kind == NodeProps.TEXT_FIELD_NUMBER) {
                for (RegisterPath path : store.textPaths(node)) {
                    lines(body, "t", store.text(node, path).string());
                }
            }
            if (kind == NodeProps.SETTINGS_FIELD_NUMBER) {
                lines(names, "k", parse(value(store, node, TITLE), DocumentInfo.getDefaultInstance()).getTitle());
                lines(names, "k", parse(value(store, node, DESCRIPTION), DocumentInfo.getDefaultInstance()).getDescription());
                // A string set's members are the strings' UTF-8 bytes.
                for (byte[] member : store.members(node, KEYWORDS)) {
                    lines(names, "k", new String(member, StandardCharsets.UTF_8));
                }
            }
        }
        return new Record(String.join("\n", names), String.join("\n", body));
    }

    /** Whether {@code node} is live: neither it nor an ancestor is deleted or the comments collection. */
    static boolean live(NodeStore store, OpId node) {
        for (OpId current = node; current != null;) {
            Cell<Boolean> deleted = store.deleted(current);
            if (current.equals(COMMENTS) || deleted != null && deleted.current().value()) {
                return false;
            }
            Placement placement = store.placement(current);
            current = placement == null ? null : placement.parent();
        }
        return true;
    }

    /** The names prefix of a node of {@code kind}. */
    static String prefix(int kind) {
        return switch (kind) {
            case NodeProps.PAGE_FIELD_NUMBER -> "p";
            case NodeProps.SWATCH_FIELD_NUMBER -> "s";
            case NodeProps.STYLE_FIELD_NUMBER -> "st";
            case NodeProps.SYMBOL_FIELD_NUMBER -> "sy";
            default -> "o";
        };
    }

    /** The register's records, or empty when never written or unset. */
    public static byte[] value(NodeStore store, OpId node, RegisterPath path) {
        Register register = store.register(node, path);
        byte[] value = register == null ? null : register.value();
        return value == null ? new byte[0] : value;
    }

    /** {@code records} (the fields of one message) parsed as that message; the empty message when they do not parse. */
    @SuppressWarnings("unchecked")
    public static <T extends Message> T parse(byte[] records, T empty) {
        try {
            return (T) empty.getParserForType().parseFrom(records);
        } catch (InvalidProtocolBufferException e) {
            return empty;
        }
    }

    /** Adds one prefixed line per non-blank line of {@code text}. */
    static void lines(List<String> out, String prefix, String text) {
        for (String line : LINES.split(text)) {
            String stripped = line.strip();
            if (!stripped.isEmpty()) {
                out.add(prefix + ":" + stripped);
            }
        }
    }
}
