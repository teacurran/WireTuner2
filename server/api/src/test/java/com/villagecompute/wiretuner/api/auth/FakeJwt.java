package com.villagecompute.wiretuner.api.auth;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;

import org.eclipse.microprofile.jwt.JsonWebToken;

/** A JsonWebToken over a claim map, for unit tests of claim reading. */
final class FakeJwt implements JsonWebToken {

    private final Map<String, Object> claims = new HashMap<>();

    FakeJwt with(String claim, Object value) {
        claims.put(claim, value);
        return this;
    }

    @Override
    public String getName() {
        return getSubject();
    }

    @Override
    public Set<String> getClaimNames() {
        return claims.keySet();
    }

    @Override
    @SuppressWarnings("unchecked")
    public <T> T getClaim(String claimName) {
        return (T) claims.get(claimName);
    }
}
