package com.villagecompute.wiretuner.api.data;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.doc.v1.HttpHeader;
import com.villagecompute.wiretuner.doc.v1.HttpMethod;
import com.villagecompute.wiretuner.doc.v1.HttpSource;
import com.villagecompute.wiretuner.doc.v1.Pagination;
import com.villagecompute.wiretuner.doc.v1.PaginationMode;

/**
 * A Fetch request read once and checked before anything connects (data-merge.adoc, Pagination engine
 * and extraction): the paths parsed, the pagination settings read with their defaults
 * ({@code timeout_s} 0 reads 30, {@code first_page} 0 reads 1, {@code max_pages} 0 reads 1000 and is
 * capped there, {@code max_records} 0 reads the server's cap), and the definition's headers held to
 * {@link RequestHeaders} once the credential is known.
 */
final class FetchPlan {

    static final int DEFAULT_TIMEOUT_S = 30;
    static final int MAX_PAGES = 1000;

    final FetchRequest request;
    final HttpSource source;
    final Map<String, String> values;
    final JsonPath recordsPath;
    final List<JsonPath> paths = new ArrayList<>();
    final PaginationMode mode;
    final JsonPath nextUrlPath;
    final String pageParam;
    final long firstPage;
    final int maxPages;
    final long maxRecords;
    final Duration timeout;

    private FetchPlan(FetchRequest request, long serverMaxRecords) {
        this.request = request;
        this.source = request.getSource();
        this.values = Templates.values(source, request.getParamsMap());
        this.recordsPath = path(source.getRecordsPath(), "source.records_path");
        for (int i = 0; i < request.getPathsCount(); i++) {
            paths.add(path(request.getPaths(i), "paths[" + i + "]"));
        }
        Pagination pagination = source.getPagination();
        this.mode = pagination.getMode() == PaginationMode.PAGINATION_MODE_UNSPECIFIED ? PaginationMode.PAGINATION_MODE_NONE
                : pagination.getMode();
        if (mode == PaginationMode.PAGINATION_MODE_NEXT_URL && pagination.getNextUrlPath().isEmpty()) {
            throw invalid("source.pagination.next_url_path", "NEXT_URL pagination needs the path to the next URL");
        }
        if (mode == PaginationMode.PAGINATION_MODE_PAGE_PARAM && pagination.getPageParam().isEmpty()) {
            throw invalid("source.pagination.page_param", "PAGE_PARAM pagination needs the page parameter's name");
        }
        this.nextUrlPath = path(pagination.getNextUrlPath(), "source.pagination.next_url_path");
        this.pageParam = pagination.getPageParam();
        this.firstPage = pagination.getFirstPage() == 0 ? 1 : pagination.getFirstPage();
        this.maxPages = pagination.getMaxPages() == 0 ? MAX_PAGES : Math.min(pagination.getMaxPages(), MAX_PAGES);
        this.maxRecords = source.getMaxRecords() == 0 ? serverMaxRecords : Math.min(source.getMaxRecords(), serverMaxRecords);
        this.timeout = Duration.ofSeconds(source.getTimeoutS() == 0 ? DEFAULT_TIMEOUT_S : source.getTimeoutS());
    }

    static FetchPlan of(FetchRequest request, long serverMaxRecords) {
        return new FetchPlan(request, serverMaxRecords);
    }

    private static JsonPath path(String path, String field) {
        try {
            return JsonPath.parse(path);
        } catch (JsonPath.PathException e) {
            throw invalid(field, e.getMessage());
        }
    }

    /** The definition's headers, checked against the credential's header (null without one), plus a JSON Accept. */
    Map<String, String> headers(String credentialHeader) {
        Map<String, String> declared = new LinkedHashMap<>();
        for (HttpHeader header : source.getHeadersList()) {
            declared.put(header.getName(), header.getValue());
        }
        Map<String, String> checked = RequestHeaders.check(declared, credentialHeader, "source.headers");
        checked.putIfAbsent("accept", "application/json");
        return checked;
    }

    boolean post() {
        return source.getMethod() == HttpMethod.HTTP_METHOD_POST;
    }

    /** A page's URL from the template: expanded, then, for PAGE_PARAM, with the page parameter set to {@code page}. */
    URI pageUrl(long page) {
        URI url = HostNames.parse(Templates.url(source.getUrl(), values), "source.url");
        return mode == PaginationMode.PAGINATION_MODE_PAGE_PARAM ? Templates.withQueryParameter(url, pageParam, Long.toString(page))
                : url;
    }

    byte[] body() {
        return Templates.body(source.getBodyTemplate(), values).getBytes(StandardCharsets.UTF_8);
    }

    static RuntimeException invalid(String field, String message) {
        return StatusExceptions.validationFailed(field + ": " + message, Map.of(field, message));
    }
}
