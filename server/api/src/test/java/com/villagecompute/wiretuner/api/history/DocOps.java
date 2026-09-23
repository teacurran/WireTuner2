package com.villagecompute.wiretuner.api.history;

import java.util.List;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.doc.v1.BrushProps;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CommentThreadProps;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.CreateNode;
import com.villagecompute.wiretuner.doc.v1.DocumentInfo;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.PageProps;
import com.villagecompute.wiretuner.doc.v1.PathProps;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.SetAdd;
import com.villagecompute.wiretuner.doc.v1.SetDeleted;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.SettingsProps;
import com.villagecompute.wiretuner.doc.v1.StyleProps;
import com.villagecompute.wiretuner.doc.v1.SwatchProps;
import com.villagecompute.wiretuner.doc.v1.SymbolProps;
import com.villagecompute.wiretuner.doc.v1.TextInsert;
import com.villagecompute.wiretuner.doc.v1.TextProps;

/**
 * Real document ops for the history tests: nodes of several kinds with names and notes, text,
 * deletions and the settings' file info, built as a client would, and an {@link Author} that numbers
 * a replica's changes (seq and counters) the way the engines expect.
 */
public final class DocOps {

    /** The well-known collections (crdt-model.adoc, "The node tree"). */
    public static final long SETTINGS = 1;
    public static final long PAGES = 2;
    public static final long LAYERS = 4;
    public static final long SWATCHES = 5;
    public static final long STYLES = 6;
    public static final long SYMBOLS = 7;
    public static final long BRUSHES = 8;
    public static final long COMMENTS = 12;

    private DocOps() {
    }

    public static OpId wellKnown(long counter) {
        return OpId.newBuilder().setCounter(counter).build();
    }

    public static OpId id(long counter, long replica) {
        return OpId.newBuilder().setCounter(counter).setReplica(replica).build();
    }

    public static CommonProps common(String name, String note) {
        return CommonProps.newBuilder().setName(name).setNote(note).build();
    }

    public static Op create(OpId parent, NodeProps props) {
        return Op.newBuilder().setCreate(CreateNode.newBuilder().setParent(parent)
                .setPosition(ByteString.copyFrom(new byte[] {(byte) 0x80})).setProps(props)).build();
    }

    public static NodeProps path(String name, String note) {
        return NodeProps.newBuilder().setPath(PathProps.newBuilder().setCommon(common(name, note))).build();
    }

    public static NodeProps page(String name) {
        return NodeProps.newBuilder().setPage(PageProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static NodeProps swatch(String name) {
        return NodeProps.newBuilder().setSwatch(SwatchProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static NodeProps style(String name) {
        return NodeProps.newBuilder().setStyle(StyleProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static NodeProps symbol(String name) {
        return NodeProps.newBuilder().setSymbol(SymbolProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static NodeProps brush(String name) {
        return NodeProps.newBuilder().setBrush(BrushProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static NodeProps text(String name) {
        return NodeProps.newBuilder().setText(TextProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static NodeProps thread(String name) {
        return NodeProps.newBuilder().setCommentThread(CommentThreadProps.newBuilder().setCommon(common(name, ""))).build();
    }

    public static FieldPath fields(int... numbers) {
        FieldPath.Builder path = FieldPath.newBuilder();
        for (int number : numbers) {
            path.addSegments(PathSegment.newBuilder().setField(number));
        }
        return path.build();
    }

    /** Renames a path node (writes {@code path.common.name}). */
    public static Op rename(OpId node, String name) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(node)
                .addPaths(fields(NodeProps.PATH_FIELD_NUMBER, 1, CommonProps.NAME_FIELD_NUMBER))
                .setValues(path(name, ""))).build();
    }

    /** Clears a path node's note (a write of unset). */
    public static Op clearNote(OpId node) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(node)
                .addPaths(fields(NodeProps.PATH_FIELD_NUMBER, 1, CommonProps.NOTE_FIELD_NUMBER))
                .setValues(NodeProps.newBuilder().setPath(PathProps.getDefaultInstance()))).build();
    }

    public static Op delete(OpId node) {
        return Op.newBuilder().setSetDeleted(SetDeleted.newBuilder().setNode(node).setDeleted(true)).build();
    }

    public static Op undelete(OpId node) {
        return Op.newBuilder().setSetDeleted(SetDeleted.newBuilder().setNode(node).setDeleted(false)).build();
    }

    /** Types {@code chars} into a text block's story. */
    public static Op type(OpId node, String chars) {
        return Op.newBuilder().setTextInsert(TextInsert.newBuilder().setNode(node)
                .setText(fields(NodeProps.TEXT_FIELD_NUMBER, TextProps.TEXT_FIELD_NUMBER)).setChars(chars)).build();
    }

    /** Sets the document's title and description (settings {@code info}). */
    public static Op info(String title, String description) {
        return Op.newBuilder().setSet(SetFields.newBuilder().setNode(wellKnown(SETTINGS))
                .addPaths(fields(NodeProps.SETTINGS_FIELD_NUMBER, SettingsProps.INFO_FIELD_NUMBER, DocumentInfo.TITLE_FIELD_NUMBER))
                .addPaths(fields(NodeProps.SETTINGS_FIELD_NUMBER, SettingsProps.INFO_FIELD_NUMBER,
                        DocumentInfo.DESCRIPTION_FIELD_NUMBER))
                .setValues(NodeProps.newBuilder().setSettings(SettingsProps.newBuilder()
                        .setInfo(DocumentInfo.newBuilder().setTitle(title).setDescription(description))))).build();
    }

    public static Op keyword(String keyword) {
        return Op.newBuilder().setSetAdd(SetAdd.newBuilder().setNode(wellKnown(SETTINGS))
                .setSet(fields(NodeProps.SETTINGS_FIELD_NUMBER, SettingsProps.INFO_FIELD_NUMBER,
                        DocumentInfo.KEYWORDS_FIELD_NUMBER))
                .setValues(NodeProps.newBuilder().setSettings(SettingsProps.newBuilder()
                        .setInfo(DocumentInfo.newBuilder().addKeywords(keyword))))).build();
    }

    public static Op noop() {
        return Op.newBuilder().setNoop(Noop.getDefaultInstance()).build();
    }

    /** Numbers one replica's changes: dense seqs from 1, counters continuing across changes. */
    public static final class Author {
        public final long replica;
        long seq;
        long counter = 1;
        long base;

        public Author(long replica) {
            this.replica = replica;
        }

        /** The id the next op will take. */
        public OpId next() {
            return id(counter, replica);
        }

        /** The change of {@code ops}, advancing seq and counters. */
        public Change change(String label, Op... ops) {
            return change(label, List.of(ops));
        }

        public Change change(String label, List<Op> ops) {
            Change change = Change.newBuilder().setReplica(replica).setSeq(++seq).setStartCounter(counter)
                    .setBaseServerSeq(base).setWallTimeMs(System.currentTimeMillis()).setLabel(label).addAllOps(ops).build();
            for (Op op : ops) {
                counter += Engine.counters(op);
            }
            return change;
        }

        /** The {@code base_server_seq} of the next changes. */
        public Author base(long serverSeq) {
            base = serverSeq;
            return this;
        }
    }
}
