package com.villagecompute.wiretuner.api.comments;

import static com.villagecompute.wiretuner.api.comments.CommentChanges.COMMENTS;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.LAYERS;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.add;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.changeOf;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.comment;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.commentPath;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.comments;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.createGroup;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.createThread;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.elementDelete;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.elementMove;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.erase;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.insert;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.mark;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.move;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.noop;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.path;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.remove;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.reply;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.set;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.setDeleted;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.thread;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.type;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.typeAt;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.comments.CommentOps.CommentOp;
import com.villagecompute.wiretuner.api.comments.CommentOps.CreateThread;
import com.villagecompute.wiretuner.api.comments.CommentOps.ElementWrite;
import com.villagecompute.wiretuner.api.comments.CommentOps.Foreign;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.api.comments.CommentOps.Kind;
import com.villagecompute.wiretuner.api.comments.CommentOps.Mentioned;
import com.villagecompute.wiretuner.api.comments.CommentOps.NewComments;
import com.villagecompute.wiretuner.api.comments.CommentOps.NodeOp;
import com.villagecompute.wiretuner.api.comments.CommentOps.Reaction;
import com.villagecompute.wiretuner.api.comments.CommentOps.Resolve;
import com.villagecompute.wiretuner.api.comments.CommentOps.ThreadWrite;
import com.villagecompute.wiretuner.api.comments.CommentOps.Typed;
import com.villagecompute.wiretuner.api.comments.CommentRules.Known;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.doc.v1.Comment;
import com.villagecompute.wiretuner.doc.v1.CommentThreadProps;
import com.villagecompute.wiretuner.doc.v1.FieldPath;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.PathSegment;
import com.villagecompute.wiretuner.doc.v1.TextMarkValue;

/** The pure parts of comments: reading ops (CommentOps), the ownership rules (CommentRules), previews and links. */
class CommentPartsTest {

    static final long R = 7;
    static final Id THREAD = new Id(100, 9);
    static final Id ELEMENT = new Id(101, 9);
    static final UUID ME = UUID.randomUUID();
    static final UUID OTHER = UUID.randomUUID();

    static List<CommentOp> parse(com.villagecompute.wiretuner.doc.v1.Op... ops) {
        return CommentOps.parse(changeOf(R, 1, 10, ops));
    }

    // ---------------------------------------------------------------------------------- place

    @Test
    void pathsArePlacedUnderAThreadOrNot() {
        assertThat(CommentOps.place(FieldPath.getDefaultInstance()).kind()).isEqualTo(Kind.FOREIGN);
        assertThat(CommentOps.place(path(5, 6)).kind()).isEqualTo(Kind.FOREIGN);
        assertThat(CommentOps.place(path(210)).kind()).isEqualTo(Kind.RESOLVED);
        assertThat(CommentOps.place(path(210, 6)).kind()).isEqualTo(Kind.RESOLVED);
        assertThat(CommentOps.place(FieldPath.newBuilder().addSegments(PathSegment.newBuilder().setField(210))
                .addSegments(PathSegment.newBuilder().setElement(ELEMENT.elementId())).build()).kind()).isEqualTo(Kind.FOREIGN);
        assertThat(CommentOps.place(path(210, 3)).kind()).isEqualTo(Kind.THREAD);
        assertThat(CommentOps.place(path(210, 7)).kind()).isEqualTo(Kind.COMMENTS);
        assertThat(CommentOps.place(path(210, 7, 3)).kind()).isEqualTo(Kind.FOREIGN);
        assertThat(CommentOps.place(commentPath(ELEMENT))).isEqualTo(new CommentOps.Place(Kind.ELEMENT, ELEMENT, 0));
        assertThat(CommentOps.place(commentPath(ELEMENT, 3))).isEqualTo(new CommentOps.Place(Kind.ELEMENT, ELEMENT, 3));
    }

    // ---------------------------------------------------------------------------------- parse

    @Test
    void createsAreThreadsOrForeignAndOpIdsCountEveryOpsCounters() {
        List<CommentOp> ops = parse(createThread(COMMENTS), reply(new Id(10, R), comment("a"), comment("b")),
                typeAt(new Id(10, R), commentPath(new Id(11, R), 3), "héllo"), createGroup(LAYERS), noop());
        assertThat(ops).hasSize(5);
        assertThat(ops.get(4)).isEqualTo(new Foreign());
        assertThat(ops.get(0)).isEqualTo(new CreateThread(new Id(10, R), new Id(12, 0)));
        assertThat(((NewComments) ops.get(1)).elements()).containsExactly(new Id(11, R), new Id(12, R));
        // The insert took two counters and the typing five (one per scalar): the group is op 18.
        assertThat(ops.get(2)).isInstanceOf(ElementWrite.class);
        assertThat(ops.get(3)).isEqualTo(new Typed(new Id(10, R), new Id(11, R), "héllo"));
        assertThat(CommentOps.parse(changeOf(R, 1, 10, createGroup(LAYERS)))).containsExactly(new Foreign());
        assertThat(parse(noop())).isEmpty();
    }

    @Test
    void setFieldsPathsAreReadOneByOne() {
        NodeProps values = comments(comment(ME.toString()), Comment.newBuilder().setDeleted(true).build());
        List<CommentOp> ops = parse(set(THREAD, values, path(210, 6), path(210, 2), path(210, 7), path(5),
                commentPath(ELEMENT), commentPath(ELEMENT, 8), commentPath(ELEMENT, 2), commentPath(ELEMENT, 3)));
        Id op = new Id(10, R);
        assertThat(ops).containsExactly(
                new Resolve(THREAD, false, op),
                new ThreadWrite(THREAD),
                new ThreadWrite(THREAD),
                new Foreign(),
                new ElementWrite(THREAD, ELEMENT, false, List.of(ME.toString()), true, true, op),
                new ElementWrite(THREAD, ELEMENT, true, List.of(ME.toString()), false, true, op),
                new ElementWrite(THREAD, ELEMENT, false, List.of(ME.toString()), true, null, op),
                new ElementWrite(THREAD, ELEMENT, false, List.of(ME.toString()), false, null, op));
        // No comment in the values: nothing authored, deleted reads false.
        assertThat(parse(set(THREAD, thread(CommentThreadProps.newBuilder().setResolved(true)), path(210),
                commentPath(ELEMENT, 8)))).containsExactly(new Resolve(THREAD, true, op),
                        new ElementWrite(THREAD, ELEMENT, true, List.of(), false, false, op));
    }

    @Test
    void nodeOpsElementOpsAndTextOpsAreRead() {
        Id op = new Id(10, R);
        assertThat(parse(move(THREAD, COMMENTS), setDeleted(THREAD, true))).containsExactly(
                new NodeOp(THREAD, false, new Id(12, 0)), new NodeOp(new Id(100, 9), true, null));
        assertThat(parse(insert(THREAD, commentPath(ELEMENT, 3), comments(), 1), insert(THREAD, path(9), comments(), 1)))
                .containsExactly(new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op), new Foreign());
        assertThat(parse(elementMove(THREAD, commentPath(ELEMENT)))).containsExactly(
                new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op));
        assertThat(parse(elementDelete(THREAD, commentPath(ELEMENT), commentPath(ELEMENT, 3), path(210, 2))))
                .containsExactly(new ElementWrite(THREAD, ELEMENT, true, List.of(), false, true, op),
                        new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op), new ThreadWrite(THREAD));
        assertThat(parse(typeAt(THREAD, commentPath(ELEMENT, 4), "x"), typeAt(THREAD, path(20, 3), "x")))
                .containsExactly(new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op), new Foreign());
        assertThat(parse(erase(THREAD, commentPath(ELEMENT, 3), ELEMENT))).containsExactly(
                new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op));
    }

    @Test
    void mentionMarksAndSetsAreLearnedAndReactionsCheckedByMember() {
        Id op = new Id(10, R);
        TextMarkValue mention = TextMarkValue.newBuilder().setMention(OTHER.toString()).build();
        TextMarkValue bold = TextMarkValue.newBuilder().setFontStyle("Bold").build();
        assertThat(parse(mark(THREAD, commentPath(ELEMENT, 3), ELEMENT, mention),
                mark(THREAD, commentPath(ELEMENT, 3), ELEMENT, bold), mark(THREAD, path(20, 3), ELEMENT, mention)))
                .containsExactly(new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op),
                        new Mentioned(THREAD, ELEMENT, List.of(OTHER.toString())),
                        new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, new Id(11, R)),
                        new Foreign());
        NodeProps named = comments(comment("", OTHER.toString(), "team:x"));
        NodeProps reacted = comments(Comment.newBuilder().addReactions(ME + ":👍").build());
        assertThat(parse(add(THREAD, commentPath(ELEMENT, 6), named), remove(THREAD, commentPath(ELEMENT, 6), named),
                add(THREAD, commentPath(ELEMENT, 7), reacted), remove(THREAD, commentPath(ELEMENT, 7), reacted),
                add(THREAD, commentPath(ELEMENT, 5), named), add(THREAD, path(20, 1), named)))
                .containsExactly(new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, op),
                        new Mentioned(THREAD, ELEMENT, List.of(OTHER.toString(), "team:x")),
                        new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, new Id(11, R)),
                        new Reaction(THREAD, List.of(ME + ":👍")),
                        new Reaction(THREAD, List.of(ME + ":👍")),
                        new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, new Id(14, R)),
                        new Foreign());
    }

    @Test
    void idsOrderByCounterThenReplicaUnsigned() {
        assertThat(new Id(1, 5).compareTo(new Id(2, 1))).isNegative();
        assertThat(new Id(2, -1).compareTo(new Id(2, 1))).isPositive();
        assertThat(new Id(2, 1).compareTo(new Id(2, 1))).isZero();
    }

    // ---------------------------------------------------------------------------------- rules

    static Known known(Map<Id, UUID> openers, Map<Id, UUID> authors) {
        return new Known(new HashMap<>(openers), new HashMap<>(authors));
    }

    static final Known MINE = known(Map.of(THREAD, ME), Map.of(ELEMENT, ME));
    static final Known THEIRS = known(Map.of(THREAD, OTHER), Map.of(ELEMENT, OTHER));
    static final Known NOTHING = known(Map.of(), Map.of());

    static void allowed(Role role, Known known, CommentOp... ops) {
        assertThatCode(() -> CommentRules.check(role, ME, List.of(ops), known)).as(List.of(ops) + " as " + role)
                .doesNotThrowAnyException();
    }

    static void refused(Role role, Known known, CommentOp... ops) {
        assertThatThrownBy(() -> CommentRules.check(role, ME, List.of(ops), known)).as(List.of(ops) + " as " + role)
                .satisfies(e -> assertThat(StatusExceptions.reasonOf(e)).contains(ErrorReasons.ROLE_INSUFFICIENT));
    }

    static final Id OP = new Id(10, R);
    static final Id ROOT = new Id(12, 0);

    @Test
    void commentersOnlyTouchCommentsAndEditorsAnything() {
        refused(Role.COMMENTER, NOTHING, new Foreign());
        allowed(Role.EDITOR, NOTHING, new Foreign());
        allowed(Role.COMMENTER, NOTHING, new CreateThread(OP, ROOT), new ThreadWrite(OP));
        refused(Role.COMMENTER, NOTHING, new CreateThread(OP, new Id(4, 0)));
        allowed(Role.EDITOR, NOTHING, new CreateThread(OP, new Id(4, 0)));
        refused(Role.COMMENTER, NOTHING, new NodeOp(THREAD, true, null));
        allowed(Role.EDITOR, NOTHING, new NodeOp(THREAD, true, null), new NodeOp(THREAD, false, new Id(4, 0)),
                new ThreadWrite(THREAD), new Resolve(THREAD, true, OP),
                new ElementWrite(THREAD, ELEMENT, false, List.of(OTHER.toString()), true, null, OP),
                new NewComments(THREAD, List.of(ELEMENT), List.of()), new Reaction(THREAD, List.of("x")));
        refused(Role.COMMENTER, NOTHING, new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, OP));
        refused(Role.COMMENTER, NOTHING, new NewComments(THREAD, List.of(ELEMENT), List.of()));
        refused(Role.COMMENTER, NOTHING, new Reaction(THREAD, List.of()));
        allowed(Role.COMMENTER, NOTHING, new Typed(THREAD, ELEMENT, "x"), new Mentioned(THREAD, ELEMENT, List.of()));
    }

    @Test
    void deletingAndMovingAThreadFollowItsOpener() {
        allowed(Role.OWNER, THEIRS, new NodeOp(THREAD, true, null));
        allowed(Role.COMMENTER, MINE, new NodeOp(THREAD, true, null));
        refused(Role.EDITOR, THEIRS, new NodeOp(THREAD, true, null));
        allowed(Role.EDITOR, THEIRS, new NodeOp(THREAD, false, new Id(4, 0)));
        allowed(Role.COMMENTER, MINE, new NodeOp(THREAD, false, ROOT));
        refused(Role.COMMENTER, MINE, new NodeOp(THREAD, false, new Id(4, 0)));
        refused(Role.COMMENTER, THEIRS, new NodeOp(THREAD, false, ROOT));
    }

    @Test
    void threadRegistersAreTheOpenersAndEditors() {
        allowed(Role.COMMENTER, MINE, new ThreadWrite(THREAD), new Resolve(THREAD, true, OP));
        refused(Role.COMMENTER, THEIRS, new Resolve(THREAD, true, OP));
        refused(Role.COMMENTER, THEIRS, new ThreadWrite(THREAD));
        allowed(Role.EDITOR, THEIRS, new ThreadWrite(THREAD), new Resolve(THREAD, false, OP));
    }

    @Test
    void aCommentIsItsAuthorsAndDeletingIsAlsoTheOwners() {
        String me = ME.toString();
        allowed(Role.COMMENTER, MINE, new ElementWrite(THREAD, ELEMENT, false, List.of(me), true, null, OP));
        allowed(Role.COMMENTER, MINE, new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, OP));
        refused(Role.COMMENTER, MINE, new ElementWrite(THREAD, ELEMENT, false, List.of(OTHER.toString()), false, null, OP));
        refused(Role.COMMENTER, MINE, new ElementWrite(THREAD, ELEMENT, false, List.of(), true, null, OP));
        refused(Role.EDITOR, THEIRS, new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, OP));
        refused(Role.EDITOR, THEIRS, new ElementWrite(THREAD, ELEMENT, true, List.of(), false, true, OP));
        allowed(Role.OWNER, THEIRS, new ElementWrite(THREAD, ELEMENT, true, List.of(), false, true, OP));
        refused(Role.OWNER, THEIRS, new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, OP));
        // An unknown comment is nobody's.
        refused(Role.COMMENTER, known(Map.of(THREAD, ME), Map.of()),
                new ElementWrite(THREAD, ELEMENT, false, List.of(), false, null, OP));
    }

    @Test
    void newCommentsNameTheCallerAndThenBelongToThem() {
        Id fresh = new Id(200, R);
        allowed(Role.COMMENTER, THEIRS, new NewComments(THREAD, List.of(fresh), List.of(comment(ME.toString()))),
                new ElementWrite(THREAD, fresh, false, List.of(), false, null, OP));
        refused(Role.COMMENTER, THEIRS, new NewComments(THREAD, List.of(fresh), List.of(comment(OTHER.toString()))));
        refused(Role.COMMENTER, THEIRS, new NewComments(THREAD, List.of(fresh), List.of()));
        // A thread made in the change is the caller's.
        allowed(Role.COMMENTER, NOTHING, new CreateThread(OP, ROOT),
                new NewComments(OP, List.of(fresh), List.of(comment(ME.toString()))), new Resolve(OP, true, OP));
    }

    @Test
    void reactionsAreOnlyEverOnesOwn() {
        allowed(Role.COMMENTER, THEIRS, new Reaction(THREAD, List.of(ME + ":👍", ME + ":🎉")));
        refused(Role.COMMENTER, THEIRS, new Reaction(THREAD, List.of(ME + ":👍", OTHER + ":👍")));
        refused(Role.OWNER, THEIRS, new Reaction(THREAD, List.of(OTHER + ":👍")));
    }

    // -------------------------------------------------------------------------------- helpers

    @Test
    void previewsKeepTwoHundredCharactersAndLastWriterWinsComparesUnsigned() {
        assertThat(CommentIndex.preview("x".repeat(300))).hasSize(200);
        assertThat(CommentIndex.preview("😀".repeat(201)).codePointCount(0, 400)).isEqualTo(200);
        assertThat(CommentIndex.newer("a", "b", "c", "d")).contains("(a # " + CommentIndex.MIN + ") < (c # ");
        assertThat(CommentIndex.counters(List.of(new Id(1, 2)))).containsExactly(1L);
        assertThat(CommentIndex.replicas(List.of(new Id(1, 2)))).containsExactly(2L);
    }

    @Test
    void threadLinksNameTheCounterAndTheUnsignedReplica() {
        UUID doc = UUID.randomUUID();
        assertThat(CommentDigestJob.link(doc, 5, -1)).isEqualTo("wiretuner://doc/" + doc + "/thread/5-18446744073709551615");
    }
}
