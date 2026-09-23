package com.villagecompute.wiretuner.api.docs;

import static com.villagecompute.wiretuner.api.Reactive.tx;
import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.persistence.DocumentSearchRepository;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.SearchField;
import com.villagecompute.wiretuner.docs.v1.SearchHit;
import com.villagecompute.wiretuner.docs.v1.SearchMatch;
import com.villagecompute.wiretuner.docs.v1.SearchRequest;
import com.villagecompute.wiretuner.docs.v1.SearchResponse;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SRV-009 Search over {@code document_search} (written here through the repository the snapshotter
 * will use) and the live document name: per-field highlights, trigram substrings, word matches,
 * paging, and never a document the caller cannot open.
 */
@QuarkusTest
class SearchTest extends ServiceTestSupport {

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @Inject
    DocumentSearchRepository records;

    UUID alice;
    UUID bob;
    UUID carol;
    String marker;

    @BeforeEach
    void accounts() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        carol = TestUsers.accountId(account, CAROL);
        TestUsers.accountId(account, DAVE);
        marker = "zq" + UUID.randomUUID().toString().replace("-", "").substring(0, 12);
    }

    UUID document(String user, UUID space, String name, String names, String body) {
        UUID id = uuid7();
        as(docs, user).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(space.toString())
                .setName(name).build());
        if (names != null) {
            tx(() -> records.upsert(id, 1, names, body));
        }
        return id;
    }

    SearchResponse search(String user, UUID space, String query) {
        return as(docs, user).search(SearchRequest.newBuilder().setSpaceId(space.toString()).setQuery(query).build());
    }

    static Map<SearchField, String> matches(SearchHit hit) {
        return hit.getMatchesList().stream()
                .collect(Collectors.toMap(SearchMatch::getField, SearchMatch::getHighlighted, (a, b) -> a + " | " + b));
    }

    static SearchHit hitFor(SearchResponse response, UUID id) {
        return response.getHitsList().stream().filter(h -> h.getDocumentId().equals(id.toString())).findFirst()
                .orElseThrow(() -> new AssertionError("no hit for " + id + " in " + response));
    }

    @Test
    void aQueryMatchingTextAnObjectNameAndAKeywordReportsEachField() {
        UUID id = document(ALICE, alice, "Annual report",
                "o:" + marker + " mascot\nk:" + marker + "\np:Cover",
                "t:the " + marker + " waves from the cover\nn:check the " + marker + " colours");
        SearchHit hit = hitFor(search(ALICE, alice, marker), id);
        Map<SearchField, String> fields = matches(hit);

        assertThat(fields.get(SearchField.SEARCH_FIELD_OBJECT_NAME)).isEqualTo("<b>" + marker + "</b> mascot");
        assertThat(fields.get(SearchField.SEARCH_FIELD_KEYWORD)).isEqualTo("<b>" + marker + "</b>");
        assertThat(fields.get(SearchField.SEARCH_FIELD_TEXT)).contains("<b>" + marker + "</b>").contains("waves");
        assertThat(fields.get(SearchField.SEARCH_FIELD_NOTE)).contains("<b>" + marker + "</b>");
        assertThat(fields).doesNotContainKeys(SearchField.SEARCH_FIELD_PAGE, SearchField.SEARCH_FIELD_DOCUMENT_NAME);
        assertThat(hit.getRank()).isPositive();
    }

    @Test
    void aSubstringOfANameMatchesByTrigram() {
        UUID object = document(ALICE, alice, "Brand book", "o:Logotype" + marker + " v3", "");
        UUID named = document(ALICE, alice, "Logotype" + marker + " guidelines", null, null);

        String query = "otype" + marker;
        SearchResponse response = search(ALICE, alice, query);
        assertThat(matches(hitFor(response, object)).get(SearchField.SEARCH_FIELD_OBJECT_NAME))
                .isEqualTo("Log<b>otype" + marker + "</b> v3");
        assertThat(matches(hitFor(response, named)).get(SearchField.SEARCH_FIELD_DOCUMENT_NAME))
                .isEqualTo("Log<b>otype" + marker + "</b> guidelines");
    }

    @Test
    void aNearMissOfTheNameMatchesByWordSimilarity() {
        UUID id = document(ALICE, alice, "Zanzibar" + marker, null, null);
        SearchHit hit = hitFor(search(ALICE, alice, "Zanzibar" + marker + "x"), id);
        assertThat(matches(hit).get(SearchField.SEARCH_FIELD_DOCUMENT_NAME)).isEqualTo("<b>Zanzibar" + marker + "</b>");
    }

    @Test
    void aRenameIsSearchableAtOnce() {
        UUID id = document(ALICE, alice, "Before", null, null);
        as(docs, ALICE).rename(com.villagecompute.wiretuner.docs.v1.RenameRequest.newBuilder()
                .setDocumentId(id.toString()).setName("After " + marker).build());
        assertThat(search(ALICE, alice, marker).getHitsList()).extracting(SearchHit::getDocumentId)
                .containsExactly(id.toString());
    }

    @Test
    void searchNeverReturnsADocumentTheCallerCannotOpen() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        teamMember(team, carol, "guest");
        UUID open = document(ALICE, team, "Open " + marker, "o:" + marker, "");
        UUID closed = document(ALICE, team, "Closed " + marker, "o:" + marker, "");
        UUID trashed = document(ALICE, team, "Trashed " + marker, null, null);
        as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(trashed.toString()).build());
        share(open, carol, "viewer");
        UUID elsewhere = document(ALICE, alice, "Personal " + marker, null, null);

        assertThat(ids(search(ALICE, team, marker))).containsExactlyInAnyOrder(open.toString(), closed.toString());
        assertThat(ids(search(BOB, team, marker))).containsExactlyInAnyOrder(open.toString(), closed.toString());
        assertThat(ids(search(CAROL, team, marker))).containsExactly(open.toString());
        assertThat(ids(search(ALICE, alice, marker))).containsExactly(elsewhere.toString());
        assertFails(() -> search(DAVE, team, marker), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
        assertFails(() -> search(BOB, alice, marker), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
    }

    @Test
    void searchPagesByRankWithACursor() {
        for (int i = 0; i < 3; i++) {
            document(ALICE, alice, "Page test " + i, "o:" + marker + " " + i, "");
        }
        SearchRequest request = SearchRequest.newBuilder().setSpaceId(alice.toString()).setQuery(marker).setPageSize(2)
                .build();
        SearchResponse first = as(docs, ALICE).search(request);
        assertThat(first.getHitsList()).hasSize(2);
        assertThat(first.getNextCursor()).isNotEmpty();
        SearchResponse second = as(docs, ALICE).search(request.toBuilder().setCursor(first.getNextCursor()).build());
        assertThat(second.getHitsList()).hasSize(1);
        assertThat(second.getNextCursor()).isEmpty();
        assertThat(ids(second)).doesNotContainAnyElementsOf(ids(first));

        String badRank = com.villagecompute.wiretuner.api.grpc.Cursors.encode("not-a-float", UUID.randomUUID().toString());
        assertFails(() -> as(docs, ALICE).search(request.toBuilder().setCursor(badRank).build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    @Test
    void wildcardsInTheQueryMatchLiterally() {
        UUID literal = document(ALICE, alice, "100% " + marker, null, null);
        assertThat(matches(hitFor(search(ALICE, alice, "100% " + marker), literal))
                .get(SearchField.SEARCH_FIELD_DOCUMENT_NAME)).isEqualTo("<b>100% " + marker + "</b>");
    }

    static List<String> ids(SearchResponse response) {
        return response.getHitsList().stream().map(SearchHit::getDocumentId).toList();
    }
}
