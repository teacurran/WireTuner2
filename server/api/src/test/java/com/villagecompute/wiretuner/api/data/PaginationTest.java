package com.villagecompute.wiretuner.api.data;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.EgressStub;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.data.v1.FetchResponse;
import com.villagecompute.wiretuner.data.v1.Record;
import com.villagecompute.wiretuner.data.v1.RecordPage;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.HttpHeader;
import com.villagecompute.wiretuner.doc.v1.HttpMethod;
import com.villagecompute.wiretuner.doc.v1.HttpParam;
import com.villagecompute.wiretuner.doc.v1.HttpSource;
import com.villagecompute.wiretuner.doc.v1.Pagination;
import com.villagecompute.wiretuner.doc.v1.PaginationMode;

import io.grpc.Status;
import io.quarkus.test.junit.QuarkusTest;

/**
 * DATA-009 against the stub: NONE, NEXT_URL and PAGE_PARAM return the expected records; max_pages
 * stops a source that never ends and max_records cuts one short; a stream dropped after page 3
 * resumes from its cursor with no record missing or repeated; a tampered cursor is refused;
 * parameters expand into the URL and body; pages that are not 2xx JSON fail as UPSTREAM_ERROR.
 */
@QuarkusTest
class PaginationTest extends DataTestSupport {

    @BeforeEach
    void permit() {
        allowEverywhere();
    }

    /** Ten numbered records per page, forever: {@code {"items":[...], "next": "...?page=n+1"}}. */
    void endless(String path) {
        route(path, (exchange, seen) -> {
            int page = seen.query() == null ? 1 : Integer.parseInt(seen.query().replaceAll(".*page=(\\d+).*", "$1"));
            StringBuilder items = new StringBuilder();
            for (int i = 0; i < 10; i++) {
                items.append(i == 0 ? "" : ",").append("{\"n\":").append((page - 1) * 10 + i).append('}');
            }
            EgressStub.json(exchange, "{\"items\":[" + items + "],\"next\":\"" + path(path) + "?page=" + (page + 1) + "\"}");
        });
    }

    static List<String> values(List<RecordPage> pages, String path) {
        List<String> values = new ArrayList<>();
        for (RecordPage page : pages) {
            for (Record record : page.getRecordsList()) {
                values.add(record.getValuesOrDefault(path, "<absent>"));
            }
        }
        return values;
    }

    @Test
    void noneFetchesOnePage() {
        route("/one", (exchange, seen) -> EgressStub.send(exchange, 200, "application/json; charset=utf-8",
                "{\"data\":[{\"id\":1,\"name\":\"Ann\",\"tags\":[\"a\"],\"vip\":true,\"note\":null},{\"id\":2.50,\"name\":\"Bo\"}]}"));
        List<FetchResponse> frames = frames(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/one"))
                .setRecordsPath("$.data")).addAllPaths(List.of("$.id", "name", "$.tags", "$.vip", "$.note")).build());
        assertThat(frames).hasSize(2);
        assertThat(frames.get(0).getProgress().getPageNumber()).isEqualTo(1);
        assertThat(frames.get(0).getProgress().getBytes()).isPositive();
        RecordPage page = frames.get(1).getPage();
        assertThat(page.getPageNumber()).isEqualTo(1);
        assertThat(page.getNextCursor()).isEmpty();
        assertThat(page.getRecords(0).getValuesMap()).isEqualTo(Map.of("$.id", "1", "name", "Ann", "$.tags", "[\"a\"]", "$.vip", "true"));
        assertThat(page.getRecords(1).getValuesMap()).isEqualTo(Map.of("$.id", "2.50", "name", "Bo"));
        assertThat(seen("/one").get(0).header("accept")).isEqualTo("application/json");
    }

    @Test
    void nextUrlFollowsUntilEmpty() {
        route("/p1", (exchange, seen) -> EgressStub.json(exchange, "{\"items\":[{\"n\":1}],\"links\":{\"next\":\"" + path("/p2") + "\"}}"));
        route("/p2", (exchange, seen) -> EgressStub.json(exchange, "{\"items\":[{\"n\":2}],\"links\":{\"next\":\"" + url("/p3") + "\"}}"));
        route("/p3", (exchange, seen) -> EgressStub.json(exchange, "{\"items\":[{\"n\":3}],\"links\":{\"next\":null}}"));
        List<RecordPage> pages = pages(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/p1")).setRecordsPath("$.items")
                .setMethod(HttpMethod.HTTP_METHOD_POST).setBodyTemplate("{\"q\":\"{{q}}\"}")
                .addParams(HttpParam.newBuilder().setName("q").setDefaultValue("default"))
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.links.next")))
                .addPaths("$.n").build());
        assertThat(values(pages, "$.n")).containsExactly("1", "2", "3");
        assertThat(pages).extracting(RecordPage::getPageNumber).containsExactly(1, 2, 3);
        assertThat(pages.get(2).getNextCursor()).isEmpty();
        assertThat(seen("/p1").get(0).method()).isEqualTo("POST");
        assertThat(seen("/p1").get(0).bodyText()).isEqualTo("{\"q\":\"default\"}");
        assertThat(seen("/p2").get(0).method()).isEqualTo("GET");
        assertThat(seen("/p2").get(0).body()).isEmpty();
    }

    @Test
    void pageParamCountsUpUntilAnEmptyPage() {
        route("/list", (exchange, seen) -> {
            int page = Integer.parseInt(seen.query().replaceAll(".*page=(\\d+).*", "$1"));
            EgressStub.json(exchange, page > 3 ? "[]" : "[{\"p\":" + page + "},{\"p\":" + page + "}]");
        });
        List<RecordPage> pages = pages(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/list?since={{since}}&page=9"))
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_PAGE_PARAM).setPageParam("page")
                        .setFirstPage(2)))
                .putParams("since", "2024-01-01 00:00").addPaths("$.p").build());
        assertThat(values(pages, "$.p")).containsExactly("2", "2", "3", "3");
        assertThat(pages).hasSize(3);
        assertThat(pages.get(2).getRecordsCount()).isZero();
        assertThat(pages.get(2).getNextCursor()).isEmpty();
        assertThat(seen("/list")).extracting(EgressStub.Seen::query)
                .containsExactly("since=2024-01-01%2000%3A00&page=2", "since=2024-01-01%2000%3A00&page=3",
                        "since=2024-01-01%2000%3A00&page=4");
    }

    @Test
    void maxPagesAndMaxRecordsEndTheStream() {
        endless("/endless");
        HttpSource.Builder source = HttpSource.newBuilder().setUrl(url("/endless")).setRecordsPath("$.items")
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.next")
                        .setMaxPages(4));
        List<RecordPage> capped = pages(ALICE, fetch(personalDoc, source).addPaths("$.n").build());
        assertThat(capped).hasSize(4);
        assertThat(values(capped, "$.n")).hasSize(40).startsWith("0").endsWith("39");
        assertThat(capped.get(3).getNextCursor()).isEmpty();
        List<RecordPage> cut = pages(ALICE, fetch(personalDoc, source.setMaxRecords(25)).addPaths("$.n").build());
        assertThat(values(cut, "$.n")).hasSize(25).endsWith("24");
        assertThat(cut).hasSize(3);
    }

    @Test
    void aDroppedStreamResumesFromItsCursor() {
        endless("/resume");
        FetchRequest request = fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/resume")).setRecordsPath("$.items")
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.next")
                        .setMaxPages(6)))
                .setSourceId(ElementId.newBuilder().setCounter(7).setReplica(-3L)).addPaths("$.n").build();
        // The client drops the stream after the third page.
        List<FetchResponse> head = as(dataStreams, ALICE).fetch(request).select().first(6).collect().asList()
                .await().atMost(Duration.ofSeconds(30));
        List<RecordPage> before = head.stream().filter(FetchResponse::hasPage).map(FetchResponse::getPage).toList();
        assertThat(before).extracting(RecordPage::getPageNumber).containsExactly(1, 2, 3);
        String cursor = before.get(2).getNextCursor();
        assertThat(cursor).isNotEmpty();
        List<FetchResponse> rest = frames(ALICE, request.toBuilder().setCursor(cursor).build());
        List<RecordPage> after = rest.stream().filter(FetchResponse::hasPage).map(FetchResponse::getPage).toList();
        assertThat(after).extracting(RecordPage::getPageNumber).containsExactly(4, 5, 6);
        assertThat(rest.get(0).getProgress().getRecords()).isEqualTo(30);
        List<String> all = new ArrayList<>(values(before, "$.n"));
        all.addAll(values(after, "$.n"));
        List<String> expected = new ArrayList<>();
        for (int i = 0; i < 60; i++) {
            expected.add(Integer.toString(i));
        }
        assertThat(all).isEqualTo(expected);
        // The cursor is bound to its request and signed.
        assertFails(drain(ALICE, request.toBuilder().setCursor(cursor).clearPaths().addPaths("$.other").build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        String tampered = cursor.substring(0, cursor.length() - 2) + (cursor.endsWith("A") ? "BB" : "AA");
        assertFails(drain(ALICE, request.toBuilder().setCursor(tampered).build()), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
    }

    @Test
    void pagesMustBeSuccessfulJson() {
        route("/500", (exchange, seen) -> EgressStub.send(exchange, 500, "application/json", "{}"));
        route("/html", (exchange, seen) -> EgressStub.send(exchange, 200, "text/html", "<html/>"));
        route("/untyped", (exchange, seen) -> EgressStub.send(exchange, 200, null, "[]"));
        route("/broken", (exchange, seen) -> EgressStub.json(exchange, "{\"a\":"));
        route("/badnext", (exchange, seen) -> EgressStub.json(exchange, "{\"items\":[],\"next\":\"http://elsewhere.example/\"}"));
        for (String path : List.of("/500", "/html", "/untyped", "/broken")) {
            assertFails(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url(path))).build()), Status.Code.UNAVAILABLE,
                    ErrorReasons.UPSTREAM_ERROR);
        }
        assertFails(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/badnext"))
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.next")))
                .build()), Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR);
        // A declared Accept header is kept.
        route("/accept", (exchange, seen) -> EgressStub.send(exchange, 200, "application/vnd.api+json", "[{\"a\":1}]"));
        assertThat(pages(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/accept"))
                .addHeaders(HttpHeader.newBuilder().setName("Accept").setValue("application/vnd.api+json"))).build()))
                .singleElement().satisfies(page -> assertThat(page.getRecordsCount()).isOne());
        assertThat(seen("/accept").get(0).header("accept")).isEqualTo("application/vnd.api+json");
    }

    @Test
    void aNextPageOnAnUnlistedHostIsRefused() {
        String other = stubHost();
        route("/first", (exchange, seen) -> EgressStub.json(exchange, "{\"items\":[{\"n\":1}],\"next\":\"" + EgressStub.url(other,
                path("/second")) + "\"}"));
        route("/second", (exchange, seen) -> EgressStub.json(exchange, "{\"items\":[]}"));
        List<FetchResponse> frames = new ArrayList<>();
        assertFails(() -> as(data, ALICE).fetch(fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/first"))
                .setRecordsPath("$.items")
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.next")))
                .build()).forEachRemaining(frames::add), Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(frames).filteredOn(FetchResponse::hasPage).hasSize(1);
        assertThat(seen("/second")).isEmpty();
    }
}
