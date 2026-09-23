package com.villagecompute.wiretuner.api.docs;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.Hit;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.MatchLine;
import com.villagecompute.wiretuner.docs.v1.DocumentKind;
import com.villagecompute.wiretuner.docs.v1.SearchField;
import com.villagecompute.wiretuner.docs.v1.SearchHit;

/** The pure parts of the library: enum mappings and search highlighting. */
class LibraryMessagesTest {

    @Test
    void kindsMapBothWaysAndUnknownReadsUnspecified() {
        for (DocumentKind kind : List.of(DocumentKind.DOCUMENT_KIND_ILLUSTRATION_SINGLE_PAGE,
                DocumentKind.DOCUMENT_KIND_ILLUSTRATION_MULTI_PAGE, DocumentKind.DOCUMENT_KIND_TYPEFACE)) {
            assertThat(DocumentMessages.kind(DocumentMessages.kindName(kind))).isEqualTo(kind);
        }
        assertThat(DocumentMessages.kindName(DocumentKind.DOCUMENT_KIND_UNSPECIFIED)).isEqualTo("illustration_multi_page");
        assertThat(DocumentMessages.kind("document")).isEqualTo(DocumentKind.DOCUMENT_KIND_UNSPECIFIED);
    }

    @Test
    void everyRoleHasAWireForm() {
        assertThat(DocumentMessages.role(Role.OWNER)).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
        assertThat(DocumentMessages.role(Role.EDITOR)).isEqualTo(DocumentRole.DOCUMENT_ROLE_EDITOR);
        assertThat(DocumentMessages.role(Role.COMMENTER)).isEqualTo(DocumentRole.DOCUMENT_ROLE_COMMENTER);
        assertThat(DocumentMessages.role(Role.VIEWER)).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
        assertThat(DocumentMessages.role(Role.NONE)).isEqualTo(DocumentRole.DOCUMENT_ROLE_UNSPECIFIED);
    }

    @Test
    void microsecondsBecomeTimestamps() {
        var ts = DocumentMessages.micros(1_700_000_000_123_456L);
        assertThat(ts.getSeconds()).isEqualTo(1_700_000_000L);
        assertThat(ts.getNanos()).isEqualTo(123_456_000);
        var before = DocumentMessages.micros(-1);
        assertThat(before.getSeconds()).isEqualTo(-1);
        assertThat(before.getNanos()).isEqualTo(999_999_000);
    }

    @Test
    void boldWrapsEveryOccurrenceOrTheWholeText() {
        assertThat(LibrarySearch.bold("Logo and logo", "LOGO")).isEqualTo("<b>Logo</b> and <b>logo</b>");
        assertThat(LibrarySearch.bold("Zanzibar", "zanzibr")).isEqualTo("<b>Zanzibar</b>");
        // Lower-casing that changes the length (İ) falls back to the whole text.
        assertThat(LibrarySearch.bold("İstanbul logo", "logo")).isEqualTo("<b>İstanbul logo</b>");
    }

    @Test
    void eachLineCountsForItsFieldOnly() {
        String q = "tiger";
        // Names match by substring (bolded here) or by word (ts_headline's highlight).
        assertThat(LibrarySearch.highlight(line("sy:Tiger stripes", true, false), q)).isEqualTo("<b>Tiger</b> stripes");
        assertThat(LibrarySearch.highlight(line("st:Tigers", false, true), q)).isEqualTo("hl");
        assertThat(LibrarySearch.highlight(line("s:Orange", false, false), q)).isNull();
        // Text and notes match by word only.
        assertThat(LibrarySearch.highlight(line("t:tigerish", true, false), q)).isNull();
        assertThat(LibrarySearch.highlight(line("n:a tiger", true, true), q)).isEqualTo("hl");
        // An unknown prefix is not a field.
        assertThat(LibrarySearch.highlight(line("zz:tiger", true, true), q)).isNull();
    }

    @Test
    void aHitReportsAtMostFiveLinesAndTruncatesLongHighlights() {
        List<MatchLine> lines = List.of(line("o:tiger 1", true, true), line("zz:tiger", true, true),
                line("o:tiger 2", true, true), line("p:tiger 3", true, true), line("k:tiger 4", true, true),
                line("s:tiger 5", true, true), line("st:tiger 6", true, true));
        SearchHit hit = LibrarySearch.hit(new Hit(UUID.randomUUID(), 1.5f, "Other", false), lines, "tiger");
        assertThat(hit.getMatchesList()).hasSize(5);
        assertThat(hit.getMatchesList()).extracting(m -> m.getField()).containsExactly(
                SearchField.SEARCH_FIELD_OBJECT_NAME, SearchField.SEARCH_FIELD_OBJECT_NAME, SearchField.SEARCH_FIELD_PAGE,
                SearchField.SEARCH_FIELD_KEYWORD, SearchField.SEARCH_FIELD_SWATCH);
        assertThat(hit.getRank()).isEqualTo(1.5f);

        String longText = "x".repeat(2000);
        assertThat(LibrarySearch.match(SearchField.SEARCH_FIELD_TEXT, longText).getHighlighted()).hasSize(1024);
    }

    static MatchLine line(String line, boolean substring, boolean word) {
        return new MatchLine(line, "hl", substring, word);
    }
}
