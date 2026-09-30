package com.villagecompute.wiretuner.api.comments;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.COMMENTS;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.changeOf;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.comment;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.createThread;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.reply;
import static com.villagecompute.wiretuner.api.comments.CommentChanges.type;
import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.awaitility.Awaitility;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.comments.CommentOps.Id;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.junit.QuarkusTestProfile;
import io.quarkus.test.junit.TestProfile;
import io.restassured.path.json.JsonPath;

import jakarta.inject.Inject;

/**
 * COLLAB-034's digest against the compose stack's Mailpit (comments.adoc, "Email"): the real mailer
 * sends over SMTP to the {@code mailpit} service of {@code docker-compose.yml}, and the mail is read
 * back through Mailpit's HTTP API -- one mail per person and document, quoting each thread's opening
 * line with its link, sent once.
 *
 * <p>Runs only when {@code -Dwt.mailpit.api=http://localhost:<ui port>} (and
 * {@code -Dwt.mailpit.smtp=<smtp port>}) are given; {@code tools/mailpit/digest-check.sh} starts the
 * compose service on free ports under its own project name, runs this test and removes the service.
 */
@QuarkusTest
@TestProfile(CommentDigestMailpitTest.Mailpit.class)
@EnabledIfSystemProperty(named = "wt.mailpit.api", matches = ".+")
class CommentDigestMailpitTest extends SyncTestSupport {

    /** The real mailer, pointed at Mailpit's SMTP port. */
    public static class Mailpit implements QuarkusTestProfile {
        @Override
        public Map<String, String> getConfigOverrides() {
            return Map.of(
                    "quarkus.mailer.mock", "false",
                    "quarkus.mailer.host", "localhost",
                    "quarkus.mailer.port", System.getProperty("wt.mailpit.smtp", "1025"),
                    "quarkus.mailer.start-tls", "DISABLED",
                    "quarkus.mailer.tls", "false",
                    // This profile starts its own Keycloak dev service; give it time on a loaded machine.
                    "quarkus.devservices.timeout", "300s");
        }
    }

    static final Duration WAIT = Duration.ofSeconds(30);

    final HttpClient http = HttpClient.newHttpClient();

    @Inject
    CommentDigestJob digest;

    String api(String path) {
        String base = System.getProperty("wt.mailpit.api");
        int end = base.length();
        while (end > 0 && base.charAt(end - 1) == '/') {
            end--;
        }
        return base.substring(0, end) + path;
    }

    JsonPath get(String path) throws Exception {
        HttpResponse<String> response = http.send(HttpRequest.newBuilder(URI.create(api(path))).GET().build(),
                HttpResponse.BodyHandlers.ofString());
        assertThat(response.statusCode()).as(response.body()).isEqualTo(200);
        return new JsonPath(response.body());
    }

    /** The ids of the mails Mailpit holds for {@code email} that mention {@code doc}. */
    List<String> mails(String email, UUID doc) throws Exception {
        String query = URLEncoder.encode("to:\"" + email + "\"", StandardCharsets.UTF_8);
        List<String> about = new ArrayList<>();
        for (String id : get("/api/v1/search?query=" + query).getList("messages.ID", String.class)) {
            if (get("/api/v1/message/" + id).getString("Text").contains(doc.toString())) {
                about.add(id);
            }
        }
        return about;
    }

    long push(String user, UUID doc, Change change) {
        return blocking(user, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(doc.toString())
                .setChange(change).build()).getServerSeq();
    }

    Change thread(long replica, long seq, long start, String... mentions) {
        Id thread = new Id(start, replica);
        return changeOf(replica, seq, start, createThread(COMMENTS), reply(thread, comment(carol.toString(), mentions)),
                type(thread, new Id(start + 1, replica), "Opening line " + start + "\nmore detail"));
    }

    @Test
    void mentionsWhileAwayArriveInMailpitAsOneMailPerDocumentOnce() throws Exception {
        UUID doc = document(ALICE);
        share(doc, bob, "editor");
        share(doc, carol, "commenter");
        long carols = replicaId();
        push(CAROL, doc, thread(carols, 1, 100, bob.toString()));
        push(CAROL, doc, thread(carols, 2, 200, bob.toString()));
        String email = TestUsers.email(BOB);

        digest.digest().await().atMost(WAIT);
        assertThat(mails(email, doc)).as("not yet ten minutes old").isEmpty();

        exec("UPDATE comment_notification SET created_at = now() - interval '11 minutes' WHERE document_id = ?", doc);
        digest.digest().await().atMost(WAIT);
        List<String> ids = awaitMails(email, doc, 1);
        assertThat(ids).hasSize(1);
        JsonPath message = get("/api/v1/message/" + ids.get(0));
        assertThat(message.getString("Subject")).isEqualTo("You were mentioned in \"Sync\" on WireTuner");
        assertThat(message.getString("From.Address")).isEqualTo("no-reply@wiretuner.local");
        assertThat(message.getList("To.Address", String.class)).containsExactly(email);
        String text = message.getString("Text");
        assertThat(text).contains("wiretuner://doc/" + doc + "/thread/100-" + Long.toUnsignedString(carols),
                "wiretuner://doc/" + doc + "/thread/200-" + Long.toUnsignedString(carols), "Opening line 100",
                "Opening line 200").doesNotContain("more detail");
        assertThat(message.getString("HTML")).contains("Opening line 100");

        // The next run sends nothing again: still one mail a second later.
        digest.digest().await().atMost(WAIT);
        Awaitility.await().during(Duration.ofSeconds(1)).atMost(WAIT).pollInterval(Duration.ofMillis(200))
                .untilAsserted(() -> assertThat(mails(email, doc)).hasSize(1));
    }

    /** Mailpit's search, polled until {@code count} mails are there (SMTP delivery is asynchronous). */
    List<String> awaitMails(String email, UUID doc, int count) {
        return Awaitility.await().atMost(WAIT).pollInterval(Duration.ofMillis(200))
                .until(() -> mails(email, doc), ids -> ids.size() >= count);
    }
}
