package com.villagecompute.wiretuner.api.team;

import java.text.Normalizer;
import java.util.Locale;

/** Team slugs: lower-case letters, digits and hyphens, at most 64, starting and ending alphanumeric. */
final class Slugs {

    static final int MAX = 64;
    static final String FALLBACK = "team";

    private Slugs() {
    }

    /** A slug from a display name: accents dropped, every other run of non-alphanumerics one hyphen. */
    static String derive(String name) {
        String ascii = Normalizer.normalize(name, Normalizer.Form.NFD).replaceAll("\\p{M}", "");
        String slug = trim(ascii.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9]+", "-"), MAX);
        return slug.isEmpty() ? FALLBACK : slug;
    }

    /** {@code base} with a suffix, still a valid slug: for a derived slug another team already has. */
    static String withSuffix(String base, String suffix) {
        return trim(base, MAX - suffix.length() - 1) + "-" + suffix;
    }

    /** At most {@code max} characters, without leading or trailing hyphens. */
    static String trim(String slug, int max) {
        String cut = slug.length() > max ? slug.substring(0, max) : slug;
        return cut.replaceAll("^-+|-+$", "");
    }
}
