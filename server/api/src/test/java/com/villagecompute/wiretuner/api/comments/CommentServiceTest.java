package com.villagecompute.wiretuner.api.comments;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.COMMENTS;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.LAYERS;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.changeOf;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.comment;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.commentPath;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.comments;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.createGroup;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.createThread;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.deleteComment;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.mark;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.mention;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.path;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.react;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.reply;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.resolve;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.set;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.setDeleted;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.type;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.PreferenceValue;
import com.villagecompute.wiretuner.account.v1.Preferences;
import com.villagecompute.wiretuner.account.v1.SetPreferencesRequest;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.sync.LiveSessions;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Comment;
import com.villagecompute.wiretuner.doc.v1.TextMarkValue;
import com.villagecompute.wiretuner.docs.v1.CommentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.GetUnreadRequest;
import com.villagecompute.wiretuner.docs.v1.GetUnreadResponse;
import com.villagecompute.wiretuner.docs.v1.ListMentionedDocumentsRequest;
import com.villagecompute.wiretuner.docs.v1.ListMentionedDocumentsResponse;
import com.villagecompute.wiretuner.docs.v1.MarkReadRequest;
import com.villagecompute.wiretuner.sync.v1.CommentEventKind;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.mailer.Mail;
import io.quarkus.mailer.MockMailbox;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * COLLAB-030 and COLLAB-031 end to end: comments pushed through SyncService, the commenter rule, the
 * server's record of comments, mention, reply and resolve notifications with their live CommentEvent,
 * CommentService, and the digest job's mail.
 */
@QuarkusTest
class CommentServiceTest extends SyncTestSupport {

    @GrpcClient("comments")
    CommentServiceGrpc.CommentServiceBlockingStub comments;

    @GrpcClient("account")
    com.villagecompute.wiretuner.account.v1.AccountServiceGrpc.AccountServiceBlockingStub accounts;

    @Inject
    MockMailbox mailbox;

    @Inject
    CommentDigestJob digest;

    @Inject
    LiveSessions sessions;

    UUID dave;
    UUID erin;

    @BeforeEach
    void more() {
        dave = TestUsers.accountId(account, DAVE);
        erin = TestUsers.accountId(account, ERIN);
        mailbox.clear();
    }

    CommentServiceGrpc.CommentServiceBlockingStub by(String user) {
        return TestUsers.as(comments, user);
    }

    long push(String user, UUID doc, Change change) {
        return blocking(user, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change).build()).getServerSeq();
    }

    void refused(String user, UUID doc, Change change) {
        assertFails(() -> push(user, doc, change), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
    }

    GetUnreadResponse unread(String user, UUID doc) {
        return by(user).getUnread(GetUnreadRequest.newBuilder().setDocumentId(doc.toString()).build());
    }

    void markRead(String user, UUID doc, Id thread, Id through) {
        by(user).markRead(MarkReadRequest.newBuilder().setDocumentId(doc.toString()).setThread(thread.opId())
                .setThrough(through.elementId()).build());
    }

    long notifications(UUID account, UUID doc, String kind) {
        return count("SELECT count(*) FROM comment_notification WHERE account_id = ? AND document_id = ? AND kind = ?",
                account, doc, kind);
    }

    static DocumentEvent commentEvent(Subscription s) {
        while (true) {
            DocumentEvent event = s.next(FrameCase.EVENT).getEvent();
            if (event.hasComment()) {
                return event;
            }
        }
    }

    /** Alice's document with Bob as editor, Carol as commenter and Dave as viewer. */
    UUID shared() {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        share(doc, carol, "commenter");
        share(doc, dave, "viewer");
        return doc;
    }

    /** Carol opens a thread (id = start counter) whose opening comment (start + 1) mentions {@code mentions}. */
    Change thread(long replica, long seq, long start, String... mentions) {
        Id thread = new Id(start, replica);
        return changeOf(replica, seq, start, createThread(COMMENTS), reply(thread, comment(carol.toString(), mentions)),
                type(thread, new Id(start + 1, replica), "Opening line\nmore detail"));
    }

    // -------------------------------------------------------------------------------- notifications

    @Test
    void mentionsRepliesAndResolvesNotifyAndReachLiveSessions() {
        UUID doc = shared();
        UUID team = team(erin, "viewer");
        teamMember(team, dave, "member");
        long carols = replicaId();
        Id thread = new Id(100, carols);
        Id opening = new Id(101, carols);
        Subscription bobs = subscribe(BOB, null, doc, replicaId(), 0);
        bobs.next(FrameCase.PRESENCE);

        long started = System.nanoTime();
        push(CAROL, doc, thread(carols, 1, 100, bob.toString(), "team:" + team, "not-an-account", carol.toString()));
        DocumentEvent mentioned = commentEvent(bobs);
        assertThat(System.nanoTime() - started).isLessThan(TimeUnit.SECONDS.toNanos(1));
        assertThat(mentioned.getComment().getKind()).isEqualTo(CommentEventKind.COMMENT_EVENT_KIND_MENTION);
        assertThat(mentioned.getComment().getThread()).isEqualTo(thread.opId());
        assertThat(mentioned.getComment().getComment()).isEqualTo(opening.elementId());
        assertThat(mentioned.getComment().getAuthor().getUserId()).isEqualTo(carol.toString());
        // The team expands to its members who can open the document (Dave, not Erin); the author is never told.
        assertThat(notifications(bob, doc, "mention")).isEqualTo(1);
        assertThat(notifications(dave, doc, "mention")).isEqualTo(1);
        assertThat(notifications(erin, doc, "mention")).isZero();
        assertThat(notifications(carol, doc, "mention")).isZero();
        assertThat(value("SELECT preview FROM comment WHERE document_id = ? AND element_counter = 101", doc))
                .isEqualTo("Opening line\nmore detail");
        assertThat(value("SELECT opener_account_id FROM comment_thread WHERE document_id = ?", doc)).isEqualTo(carol);

        // Alice replies: the opener is told; a mention mark in the reply tells Bob again for that comment.
        long alices = replicaId();
        Id reply = new Id(500, alices);
        push(ALICE, doc, changeOf(alices, 1, 500, reply(thread, comment(alice.toString())),
                type(thread, reply, "Agreed"),
                mark(thread, commentPath(reply, 3), new Id(501, alices), TextMarkValue.newBuilder().setMention(bob.toString())
                        .build())));
        assertThat(notifications(carol, doc, "reply")).isEqualTo(1);
        assertThat(notifications(bob, doc, "mention")).isEqualTo(2);
        assertThat(commentEvent(bobs).getComment().getComment()).isEqualTo(reply.elementId());

        // Bob replies: Carol (opener) and Alice (earlier replier) are told, once each.
        long bobsReplica = replicaId();
        push(BOB, doc, changeOf(bobsReplica, 1, 700, reply(thread, comment(bob.toString()))));
        assertThat(notifications(carol, doc, "reply")).isEqualTo(2);
        assertThat(notifications(alice, doc, "reply")).isEqualTo(1);

        // Bob (an editor) resolves Carol's thread: she is told; resolving again, or reopening, is not news.
        push(BOB, doc, changeOf(bobsReplica, 2, 800, resolve(thread, true)));
        push(BOB, doc, changeOf(bobsReplica, 3, 801, resolve(thread, true)));
        assertThat(notifications(carol, doc, "resolved")).isEqualTo(1);
        push(BOB, doc, changeOf(bobsReplica, 4, 802, resolve(thread, false)));
        assertThat(value("SELECT resolved FROM comment_thread WHERE document_id = ?", doc)).isEqualTo(false);
        // An older write loses to the newer one (last writer wins by op id).
        push(ALICE, doc, changeOf(alices, 2, 790, resolve(thread, true)));
        assertThat(value("SELECT resolved FROM comment_thread WHERE document_id = ?", doc)).isEqualTo(false);
        bobs.cancel();
    }

    @Test
    void aMentionReAddedWithinADayIsNotNotifiedAgain() {
        UUID doc = shared();
        long carols = replicaId();
        Id thread = new Id(100, carols);
        Id opening = new Id(101, carols);
        push(CAROL, doc, thread(carols, 1, 100, bob.toString()));
        push(CAROL, doc, changeOf(carols, 2, 200, mention(thread, opening, bob.toString())));
        assertThat(notifications(bob, doc, "mention")).isEqualTo(1);
        exec("UPDATE comment_notification SET created_at = now() - interval '25 hours' WHERE document_id = ?", doc);
        push(CAROL, doc, changeOf(carols, 3, 300, mention(thread, opening, bob.toString())));
        assertThat(notifications(bob, doc, "mention")).isEqualTo(2);
    }

    // -------------------------------------------------------------------------------- the rule

    @Test
    void theCommenterRoleWritesOnlyItsOwnCommentsAndViewersNone() {
        UUID doc = shared();
        long carols = replicaId();
        long alices = replicaId();
        long bobs = replicaId();
        Id carolsThread = new Id(100, carols);
        Id alicesThread = new Id(100, alices);
        Id alicesComment = new Id(101, alices);
        push(CAROL, doc, thread(carols, 1, 100));
        push(ALICE, doc, changeOf(alices, 1, 100, createThread(COMMENTS), reply(alicesThread, comment(alice.toString()))));
        push(BOB, doc, changeOf(bobs, 1, 100, react(alicesThread, alicesComment, bob + ":👍", true)));

        refused(CAROL, doc, changeOf(carols, 2, 200, createGroup(LAYERS)));
        refused(CAROL, doc, changeOf(carols, 2, 200, reply(alicesThread, comment(bob.toString()))));
        refused(CAROL, doc, changeOf(carols, 2, 200, react(alicesThread, alicesComment, bob + ":👍", false)));
        refused(CAROL, doc, changeOf(carols, 2, 200, type(alicesThread, alicesComment, "mine now")));
        refused(CAROL, doc, changeOf(carols, 2, 200, resolve(alicesThread, true)));
        refused(CAROL, doc, changeOf(carols, 2, 200, createThread(LAYERS)));
        refused(CAROL, doc, changeOf(carols, 2, 200, set(new Id(5, 5), comments(), path(50, 1, 1))));
        assertFails(() -> push(DAVE, doc, changeOf(replicaId(), 1, 100, createThread(COMMENTS))),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);

        // Allowed: her own thread resolved, a reply, a reaction of her own, her own comment edited and deleted.
        push(CAROL, doc, changeOf(carols, 2, 200, resolve(carolsThread, true), reply(alicesThread, comment(carol.toString())),
                react(alicesThread, alicesComment, carol + ":🎉", true), type(carolsThread, new Id(101, carols), "!"),
                deleteComment(carolsThread, new Id(101, carols), true), setDeleted(carolsThread, true),
                set(carolsThread, CommentChanges.thread(com.villagecompute.wiretuner.doc.v1.CommentThreadProps.newBuilder()
                        .setPoint(com.villagecompute.wiretuner.doc.v1.Point.newBuilder().setX(3).setY(4))), path(210, 3))));
        refused(CAROL, doc, changeOf(carols, 3, 300, set(alicesThread, CommentChanges.thread(
                com.villagecompute.wiretuner.doc.v1.CommentThreadProps.newBuilder()), path(210, 3))));
        assertThat(value("SELECT deleted FROM comment WHERE document_id = ? AND element_counter = 101 AND element_replica = ?",
                doc, carols)).isEqualTo(true);
        // An owner deletes anyone's comment; an editor may not.
        refused(BOB, doc, changeOf(bobs, 2, 300, deleteComment(alicesThread, new Id(201, carols), true)));
        push(ALICE, doc, changeOf(alices, 2, 300, deleteComment(alicesThread, new Id(201, carols), true)));
    }

    @Test
    void editorsOpsOnOtherNodesAreNotCommentsAndRetriesRepairTheRecord() {
        UUID doc = shared();
        long bobs = replicaId();
        Id group = new Id(50, bobs);
        push(BOB, doc, changeOf(bobs, 1, 50, createGroup(LAYERS),
                reply(group, comment(bob.toString(), carol.toString())),
                type(group, new Id(51, bobs), "x"),
                mention(group, new Id(51, bobs), carol.toString()),
                resolve(group, true),
                deleteComment(group, new Id(51, bobs), true),
                setDeleted(group, true)));
        assertThat(count("SELECT count(*) FROM comment_thread WHERE document_id = ?", doc)).isZero();
        assertThat(count("SELECT count(*) FROM comment_notification WHERE document_id = ?", doc)).isZero();

        long carols = replicaId();
        Change opened = thread(carols, 1, 100, bob.toString());
        long seq = push(CAROL, doc, opened);
        exec("DELETE FROM comment_thread WHERE document_id = ?", doc);
        exec("DELETE FROM comment_notification WHERE document_id = ?", doc);
        // The same change again is acknowledged with its first server_seq and puts the record back.
        assertThat(push(CAROL, doc, opened)).isEqualTo(seq);
        assertThat(count("SELECT count(*) FROM comment WHERE document_id = ?", doc)).isEqualTo(1);
        assertThat(notifications(bob, doc, "mention")).isEqualTo(1);
        assertThat(push(CAROL, doc, opened)).isEqualTo(seq);
        assertThat(notifications(bob, doc, "mention")).isEqualTo(1);
    }

    // ------------------------------------------------------------------------------ CommentService

    @Test
    void unreadCountsOthersLiveCommentsPastTheMarkAndIsFast() {
        UUID doc = shared();
        long carols = replicaId();
        Id thread = new Id(100, carols);
        push(CAROL, doc, thread(carols, 1, 100, bob.toString()));
        long alices = replicaId();
        Comment[] thousand = new Comment[1000];
        for (int i = 0; i < thousand.length; i++) {
            thousand[i] = comment(alice.toString());
        }
        push(ALICE, doc, changeOf(alices, 1, 1000, reply(thread, thousand)));

        GetUnreadResponse all = unread(BOB, doc);
        assertThat(all.getTotal()).isEqualTo(1001);
        assertThat(all.getThreads(0).getMentionsMe()).isTrue();
        markRead(BOB, doc, thread, new Id(1000 + 989, alices));
        // Warm, the best of three calls: the budget is the server's, not the first call's class loading.
        GetUnreadResponse rest = null;
        long elapsed = Long.MAX_VALUE;
        for (int i = 0; i < 3; i++) {
            long started = System.nanoTime();
            rest = unread(BOB, doc);
            elapsed = Math.min(elapsed, System.nanoTime() - started);
        }
        System.out.printf("COLLAB-030 GetUnread, 1,000 comments, mark at 990: %.1f ms%n", elapsed / 1e6);
        assertThat(rest.getTotal()).isEqualTo(10);
        assertThat(rest.getThreads(0).getUnreadList()).first().isEqualTo(new Id(1990, alices).elementId());
        assertThat(rest.getThreads(0).getMentionsMe()).isFalse();
        assertThat(elapsed).as("GetUnread with a mark at 990 of 1,000").isLessThan(TimeUnit.MILLISECONDS.toNanos(50));
        // A lower mark never lowers the stored one.
        markRead(BOB, doc, thread, new Id(1, alices));
        assertThat(unread(BOB, doc).getTotal()).isEqualTo(10);

        // The caller's own and deleted comments do not count.
        assertThat(unread(ALICE, doc).getTotal()).isEqualTo(1);
        push(CAROL, doc, changeOf(carols, 2, 5000, deleteComment(thread, new Id(101, carols), true)));
        assertThat(unread(ALICE, doc).getTotal()).isZero();
        assertThat(unread(CAROL, doc).getTotal()).isEqualTo(1000);
        assertFails(() -> unread(ERIN, doc), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
    }

    @Test
    void mentionedDocumentsPageAndClearOnceRead() {
        UUID first = shared();
        UUID second = shared();
        long carols = replicaId();
        push(CAROL, first, thread(carols, 1, 100, erin.toString()));
        share(first, erin, "viewer");
        share(second, erin, "viewer");
        push(CAROL, first, thread(carols, 2, 200, erin.toString()));
        long other = replicaId();
        push(CAROL, second, thread(other, 1, 100, erin.toString()));

        List<String> seen = new ArrayList<>();
        ListMentionedDocumentsResponse page = by(ERIN).listMentionedDocuments(ListMentionedDocumentsRequest.newBuilder()
                .setPageSize(1).build());
        seen.addAll(page.getDocumentIdsList());
        while (!page.getNextCursor().isEmpty()) {
            page = by(ERIN).listMentionedDocuments(ListMentionedDocumentsRequest.newBuilder().setPageSize(1)
                    .setCursor(page.getNextCursor()).build());
            seen.addAll(page.getDocumentIdsList());
        }
        assertThat(seen).contains(first.toString(), second.toString());

        markRead(ERIN, first, new Id(200, carols), new Id(201, carols));
        assertThat(by(ERIN).listMentionedDocuments(ListMentionedDocumentsRequest.getDefaultInstance()).getDocumentIdsList())
                .doesNotContain(first.toString()).contains(second.toString());
        markRead(ERIN, second, new Id(100, other), new Id(101, other));
    }

    @Test
    void concurrentRepliesConvergeAndNotifyEachRecipientOncePerComment() throws Exception {
        UUID doc = shared();
        long carols = replicaId();
        Id thread = new Id(100, carols);
        push(CAROL, doc, thread(carols, 1, 100));
        long alices = replicaId();
        long bobs = replicaId();
        Change fromAlice = changeOf(alices, 1, 300, reply(thread, comment(alice.toString())));
        Change fromBob = changeOf(bobs, 1, 300, reply(thread, comment(bob.toString())));
        CompletableFuture<Long> a = CompletableFuture.supplyAsync(() -> push(ALICE, doc, fromAlice));
        CompletableFuture<Long> b = CompletableFuture.supplyAsync(() -> push(BOB, doc, fromBob));
        assertThat(a.get(30, TimeUnit.SECONDS)).isNotEqualTo(b.get(30, TimeUnit.SECONDS));

        assertThat(notifications(carol, doc, "reply")).isEqualTo(2);
        assertThat(count("""
                SELECT count(*) - count(DISTINCT (account_id, comment_counter, comment_replica, kind))
                FROM comment_notification WHERE document_id = ?""", doc)).isZero();
        // Two replicas applying the log in opposite orders reach one state.
        Subscription daves = subscribe(DAVE, null, doc, replicaId(), 0);
        List<SequencedChange> log = daves.changes(3);
        daves.cancel();
        Engine forward = new Engine();
        Engine backward = new Engine();
        log.forEach(c -> forward.apply(c.getChange(), c.getServerSeq()));
        backward.apply(log.get(0).getChange(), log.get(0).getServerSeq());
        backward.apply(log.get(2).getChange(), log.get(2).getServerSeq());
        backward.apply(log.get(1).getChange(), log.get(1).getServerSeq());
        assertThat(backward.stateHash()).isEqualTo(forward.stateHash());
    }

    // ---------------------------------------------------------------------------------- digest

    void due(UUID doc) {
        exec("UPDATE comment_notification SET created_at = now() - interval '11 minutes' WHERE document_id = ?", doc);
    }

    List<Mail> mailsAbout(String user, UUID doc) {
        return mailbox.getMailsSentTo(TestUsers.email(user)).stream()
                .filter(mail -> mail.getText().contains(doc.toString())).toList();
    }

    @Test
    void mentionsWhileAwayArriveAsOneMailPerDocument() {
        UUID doc = shared();
        long carols = replicaId();
        push(CAROL, doc, thread(carols, 1, 100, bob.toString()));
        push(CAROL, doc, thread(carols, 2, 200, bob.toString()));
        push(CAROL, doc, thread(carols, 3, 300, bob.toString()));
        digest.digest().await().atMost(WAIT);
        assertThat(mailsAbout(BOB, doc)).as("not yet 10 minutes old").isEmpty();

        due(doc);
        digest.digest().await().atMost(WAIT);
        List<Mail> mails = mailsAbout(BOB, doc);
        assertThat(mails).hasSize(1);
        String text = mails.get(0).getText();
        assertThat(text).contains("wiretuner://doc/" + doc + "/thread/100-" + Long.toUnsignedString(carols),
                "/thread/200-", "/thread/300-", "Opening line").doesNotContain("more detail");
        assertThat(mails.get(0).getHtml()).contains("Opening line");
        assertThat(count("SELECT count(*) FROM comment_notification WHERE document_id = ? AND emailed_at IS NOT NULL",
                doc)).isEqualTo(3);
        com.villagecompute.wiretuner.api.share.TeamAccessTest.run(digest::scheduled);
        assertThat(mailsAbout(BOB, doc)).hasSize(1);
    }

    @Test
    void aMentionSeenInTheAppALiveSessionOrThePreferenceOffSendsNone() {
        UUID doc = shared();
        long carols = replicaId();
        Id thread = new Id(100, carols);
        push(CAROL, doc, thread(carols, 1, 100, bob.toString(), dave.toString()));
        markRead(BOB, doc, thread, new Id(101, carols));
        setMentionMails(DAVE, false, System.currentTimeMillis());
        due(doc);
        digest.digest().await().atMost(WAIT);
        assertThat(mailsAbout(BOB, doc)).isEmpty();
        assertThat(mailsAbout(DAVE, doc)).isEmpty();
        setMentionMails(DAVE, true, System.currentTimeMillis() + 1);

        // Dave is on the document now: no mail until he leaves.
        Subscription daves = subscribe(DAVE, null, doc, replicaId(), 0);
        daves.next(FrameCase.PRESENCE);
        await(() -> sessions.live(doc, dave).await().atMost(WAIT));
        digest.digest().await().atMost(WAIT);
        assertThat(mailsAbout(DAVE, doc)).isEmpty();
        daves.cancel();
        await(() -> !sessions.live(doc, dave).await().atMost(WAIT));
        digest.digest().await().atMost(WAIT);
        assertThat(mailsAbout(DAVE, doc)).hasSize(1);
    }

    void setMentionMails(String user, boolean on, long at) {
        TestUsers.as(accounts, user).setPreferences(SetPreferencesRequest.newBuilder().setChanges(Preferences.newBuilder()
                .putValues(CommentDigestJob.PREFERENCE, PreferenceValue.newBuilder().setBoolValue(on).setUpdatedAtMs(at)
                        .build())).build());
    }
}
