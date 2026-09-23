package com.villagecompute.wiretuner.api.data;

import java.io.IOException;
import java.net.URI;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.data.v1.FetchProgress;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.data.v1.FetchResponse;
import com.villagecompute.wiretuner.data.v1.Record;
import com.villagecompute.wiretuner.data.v1.RecordPage;
import com.villagecompute.wiretuner.doc.v1.PaginationMode;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The pagination engine (data-merge.adoc, Pagination engine and extraction; DATA-009): executes an
 * HttpSource page after page -- one request for NONE; the URL at {@code next_url_path} in each
 * response, resolved against the response's URL, until it is missing or empty, for NEXT_URL (pages
 * after the first are GETs without a body); the page parameter from {@code first_page} up until a
 * page has no records, for PAGE_PARAM -- and streams each page's records, with {@code records_path}
 * and the requested {@code paths} applied, preceded by a progress frame. {@code max_pages} and
 * {@code max_records} (and the server's cap) end the stream early. Every page but the last carries
 * a signed cursor that resumes the fetch after it.
 *
 * <p>A page must answer 2xx ({@code UPSTREAM_ERROR} with the status otherwise), with a JSON media type
 * ({@code application/json} or {@code +json}) and a body that parses, within 64 MiB.
 */
@ApplicationScoped
public class Fetches {

    static final long PAGE_CAP = 64L * 1024 * 1024;

    /** One page's frames and where the fetch goes next (null: it ends here). */
    record Step(List<FetchResponse> frames, FetchCursor next) {
    }

    @ConfigProperty(name = "wt.data.max-records", defaultValue = "100000")
    long serverMaxRecords;

    @Inject
    Outbound outbound;

    @Inject
    MasterKeys keys;

    public Multi<FetchResponse> fetch(FetchRequest request) {
        return Multi.createFrom().deferred(() -> {
            FetchPlan plan = FetchPlan.of(request, serverMaxRecords);
            byte[] key = keys.envelope().derive(FetchCursor.PURPOSE);
            FetchCursor start = request.getCursor().isEmpty() ? new FetchCursor("", plan.firstPage, 0, 0)
                    : FetchCursor.verify(request.getCursor(), request, key);
            return Multi.createFrom().uni(outbound.start(UUID.fromString(request.getDocumentId()), "source"))
                    .onItem().transformToMultiAndConcatenate(run -> {
                        if (request.hasSourceId()) {
                            run.sourceCounter = request.getSourceId().getCounter();
                            run.sourceReplica = request.getSourceId().getReplica();
                        }
                        AtomicReference<FetchCursor> at = new AtomicReference<>(start);
                        Multi<FetchResponse> pages = outbound.credential(run, plan.source.getCredentialName())
                                .onItem().transformToMulti(opened -> {
                                    Map<String, String> headers = plan.headers(run.credentialHeader());
                                    return Multi.createBy().repeating()
                                            .uni(() -> page(run, plan, at.get(), key, headers).invoke(step -> at.set(step.next())))
                                            .whilst(step -> step.next() != null)
                                            .onItem().transformToIterable(Step::frames);
                                });
                        return outbound.audited(run, pages);
                    });
        });
    }

    private Uni<Step> page(Run run, FetchPlan plan, FetchCursor at, byte[] key, Map<String, String> headers) {
        boolean following = !at.nextUrl().isEmpty();
        boolean post = !following && plan.post();
        URI url = following ? URI.create(at.nextUrl()) : plan.pageUrl(at.page());
        return outbound.send(run, post ? "POST" : "GET", url, headers, post ? plan.body() : null, plan.timeout, PAGE_CAP)
                .map(reply -> step(run, plan, at, reply, key));
    }

    private static Step step(Run run, FetchPlan plan, FetchCursor at, Egress.Reply reply, byte[] key) {
        if (reply.status() / 100 != 2) {
            throw StatusExceptions.upstreamError(reply.status());
        }
        String type = reply.header("content-type");
        if (!json(type)) {
            throw StatusExceptions.upstreamFailed(HostNames.key(reply.url()) + " answered "
                    + (type == null ? "without a content type" : type) + ", not JSON");
        }
        Object json;
        try {
            json = JsonTree.parse(reply.body());
        } catch (IOException e) {
            throw StatusExceptions.upstreamFailed(HostNames.key(reply.url()) + " answered with invalid JSON");
        }
        List<Object> found = plan.recordsPath.records(json);
        long room = plan.maxRecords - at.records();
        List<Object> kept = found.size() > room ? found.subList(0, (int) room) : found;
        RecordPage.Builder page = RecordPage.newBuilder();
        for (Object record : kept) {
            Record.Builder values = Record.newBuilder();
            for (int i = 0; i < plan.paths.size(); i++) {
                String value = plan.paths.get(i).extract(record);
                if (value != null) {
                    values.putValues(plan.request.getPaths(i), value);
                }
            }
            page.addRecords(values);
        }
        int pages = at.pages() + 1;
        long records = at.records() + kept.size();
        FetchCursor next = next(plan, at, reply, json, found.isEmpty(), pages, records);
        run.records += kept.size();
        List<FetchResponse> frames = new ArrayList<>();
        frames.add(FetchResponse.newBuilder().setProgress(FetchProgress.newBuilder().setPageNumber(pages)
                .setBytes(run.bytes).setRecords(at.records())).build());
        frames.add(FetchResponse.newBuilder().setPage(page.setPageNumber(pages)
                .setNextCursor(next == null ? "" : next.sign(plan.request, key))).build());
        return new Step(frames, next);
    }

    /** Where the fetch goes after this page, or null when it ends here. */
    static FetchCursor next(FetchPlan plan, FetchCursor at, Egress.Reply reply, Object json, boolean empty, int pages,
            long records) {
        if (pages >= plan.maxPages || records >= plan.maxRecords) {
            return null;
        }
        if (plan.mode == PaginationMode.PAGINATION_MODE_PAGE_PARAM) {
            return empty ? null : new FetchCursor("", at.page() + 1, pages, records);
        }
        if (plan.mode != PaginationMode.PAGINATION_MODE_NEXT_URL) {
            return null;
        }
        String next = plan.nextUrlPath.extract(json);
        if (next == null || next.isEmpty()) {
            return null;
        }
        try {
            URI resolved = HostNames.parse(reply.url().resolve(next).toString(), "next_url");
            return new FetchCursor(resolved.toString(), 0, pages, records);
        } catch (IllegalArgumentException | io.grpc.StatusRuntimeException e) {
            throw StatusExceptions.upstreamFailed("the next page's URL is not an https URL this server fetches");
        }
    }

    /** Whether a Content-Type is JSON: application/json or any +json type. */
    static boolean json(String contentType) {
        if (contentType == null) {
            return false;
        }
        String media = contentType.split(";", 2)[0].strip().toLowerCase(Locale.ROOT);
        return media.equals("application/json") || media.endsWith("+json");
    }
}
