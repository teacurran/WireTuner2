package com.villagecompute.wiretuner.api.docs;

import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.Hit;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.MatchLine;
import com.villagecompute.wiretuner.docs.v1.SearchField;
import com.villagecompute.wiretuner.docs.v1.SearchHit;
import com.villagecompute.wiretuner.docs.v1.SearchMatch;
import com.villagecompute.wiretuner.docs.v1.SearchResponse;

import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * {@code DocumentService.Search} (docs/spec/server.adoc, Search): the hits come from
 * {@link LibraryRepository#search}, already limited to documents the caller can open; each hit's
 * matches are recovered line by line from its search record, the field from the line's prefix.
 * Names match as substrings (bolded here) or as words (bolded by {@code ts_headline}); text and
 * notes match as words only.
 */
@ApplicationScoped
public class LibrarySearch {

    /** The field prefixes the snapshotter writes on each line of {@code names} and {@code body_text}. */
    static final Map<String, SearchField> FIELDS = Map.of(
            "o", SearchField.SEARCH_FIELD_OBJECT_NAME,
            "s", SearchField.SEARCH_FIELD_SWATCH,
            "st", SearchField.SEARCH_FIELD_STYLE,
            "sy", SearchField.SEARCH_FIELD_SYMBOL,
            "k", SearchField.SEARCH_FIELD_KEYWORD,
            "p", SearchField.SEARCH_FIELD_PAGE,
            "t", SearchField.SEARCH_FIELD_TEXT,
            "n", SearchField.SEARCH_FIELD_NOTE);

    /** Prefixes of {@code body_text} lines: matched by word only. */
    static final Set<String> BODY_PREFIXES = Set.of("t", "n");

    /** Matches reported per hit, besides the document name. */
    static final int MATCHES_PER_HIT = 5;

    /** {@code SearchMatch.highlighted} is at most this long. */
    static final int MAX_HIGHLIGHT = 1024;

    static final String OPEN = "<b>";
    static final String CLOSE = "</b>";

    @Inject
    LibraryRepository library;

    Uni<SearchResponse> search(Principal principal, UUID spaceId, String query, float afterRank, UUID afterId,
            int pageSize) {
        return library.search(principal.accountId(), spaceId, query, afterRank, afterId, pageSize + 1).flatMap(hits -> {
            List<Hit> shown = hits.size() > pageSize ? hits.subList(0, pageSize) : hits;
            SearchResponse.Builder response = SearchResponse.newBuilder();
            if (hits.size() > pageSize) {
                Hit last = shown.get(shown.size() - 1);
                response.setNextCursor(Cursors.encode(Float.toString(last.rank()), last.documentId().toString()));
            }
            return Multi.createFrom().iterable(shown)
                    .onItem().transformToUniAndConcatenate(hit -> library.matchLines(hit.documentId(), query)
                            .map(lines -> hit(hit, lines, query)))
                    .collect().asList()
                    .map(found -> response.addAllHits(found).build());
        });
    }

    static SearchHit hit(Hit hit, List<MatchLine> lines, String query) {
        SearchHit.Builder result = SearchHit.newBuilder().setDocumentId(hit.documentId().toString()).setRank(hit.rank());
        if (hit.nameMatched()) {
            result.addMatches(match(SearchField.SEARCH_FIELD_DOCUMENT_NAME, bold(hit.name(), query)));
        }
        int reported = 0;
        for (MatchLine line : lines) {
            if (reported == MATCHES_PER_HIT) {
                break;
            }
            String highlighted = highlight(line, query);
            if (highlighted != null) {
                String prefix = line.line().substring(0, line.line().indexOf(':'));
                result.addMatches(match(FIELDS.get(prefix), highlighted));
                reported++;
            }
        }
        return result.build();
    }

    /** The line's highlight, or null when the line does not count as a match for its field. */
    static String highlight(MatchLine line, String query) {
        int colon = line.line().indexOf(':');
        String prefix = line.line().substring(0, colon);
        if (!FIELDS.containsKey(prefix)) {
            return null;
        }
        if (BODY_PREFIXES.contains(prefix)) {
            return line.word() ? line.headline() : null;
        }
        if (line.substring()) {
            return bold(line.line().substring(colon + 1), query);
        }
        return line.word() ? line.headline() : null;
    }

    /** Every case-insensitive occurrence of the query wrapped in {@code <b>}; the whole text when there is none. */
    static String bold(String text, String query) {
        String lowerText = text.toLowerCase(Locale.ROOT);
        String lowerQuery = query.toLowerCase(Locale.ROOT);
        int at = lowerText.indexOf(lowerQuery);
        if (at < 0 || lowerText.length() != text.length()) {
            return OPEN + text + CLOSE;
        }
        StringBuilder out = new StringBuilder();
        int from = 0;
        while (at >= 0) {
            out.append(text, from, at).append(OPEN).append(text, at, at + lowerQuery.length()).append(CLOSE);
            from = at + lowerQuery.length();
            at = lowerText.indexOf(lowerQuery, from);
        }
        return out.append(text.substring(from)).toString();
    }

    static SearchMatch match(SearchField field, String highlighted) {
        String text = highlighted.length() > MAX_HIGHLIGHT ? highlighted.substring(0, MAX_HIGHLIGHT) : highlighted;
        return SearchMatch.newBuilder().setField(field).setHighlighted(text).build();
    }
}
