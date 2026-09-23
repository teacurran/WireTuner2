package com.villagecompute.wiretuner.api.data;

import java.io.ByteArrayOutputStream;
import java.net.InetAddress;
import java.net.URI;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;

import org.eclipse.microprofile.config.inject.ConfigProperty;

import com.villagecompute.wiretuner.api.grpc.CallerContext;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.grpc.StatusRuntimeException;
import io.smallrye.mutiny.Uni;
import io.vertx.core.dns.DnsClientOptions;
import io.vertx.core.http.HttpClientOptions;
import io.vertx.core.http.HttpMethod;
import io.vertx.core.http.RequestOptions;
import io.vertx.core.net.PemTrustOptions;
import io.vertx.core.net.SocketAddress;
import io.vertx.mutiny.core.Vertx;
import io.vertx.mutiny.core.buffer.Buffer;
import io.vertx.mutiny.core.dns.DnsClient;
import io.vertx.mutiny.core.http.HttpClient;
import io.vertx.mutiny.core.http.HttpClientRequest;
import io.vertx.mutiny.core.http.HttpClientResponse;

import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The server's only outbound HTTP client and its SSRF guard (data-merge.adoc, Fetch proxy and SSRF
 * guard; DATA-006). Every request is https. A host is resolved once per call through the configured
 * resolver; every address it resolves to is checked against {@link AddressPolicy}, and the connection
 * goes to the checked address (the TLS name and {@code Host} header stay the host's), so a DNS answer
 * that changes between the check and the connect -- rebinding -- cannot redirect it. Redirects are
 * never followed blindly: a 3xx to the same host and port is followed with the same pinned address, at
 * most {@value #MAX_REDIRECTS} times; to anywhere else it is {@code HOST_NOT_ALLOWED}. Connect timeout
 * 10 s; each exchange has the caller's timeout; bodies are read up to the caller's cap and the
 * connection is dropped past it ({@code RESPONSE_TOO_LARGE}). The client neither asks for nor
 * decompresses encoded bodies, so the cap counts what the upstream sends.
 */
@ApplicationScoped
public class Egress {

    static final int MAX_REDIRECTS = 3;
    static final Set<Integer> REDIRECTS = Set.of(301, 302, 303, 307, 308);

    /** One logical request. {@code headers} are already validated; the credential is among them. */
    public record Request(String method, URI url, Map<String, String> headers, byte[] body, Duration timeout, long cap) {
    }

    /** The response to a request, after same-host redirects; {@code url} is where it came from. */
    public record Reply(int status, List<Map.Entry<String, String>> headers, byte[] body, URI url) {

        /** The first value of a header (case-insensitive), or null. */
        public String header(String name) {
            for (Map.Entry<String, String> header : headers) {
                if (header.getKey().equalsIgnoreCase(name)) {
                    return header.getValue();
                }
            }
            return null;
        }
    }

    /** The addresses one call has resolved and checked, by host; a host is looked up once per call. */
    public static final class Pins {
        final Map<String, InetAddress> byHost = new HashMap<>();
    }

    @Inject
    Vertx vertx;

    @ConfigProperty(name = "wt.data.egress.connect-timeout", defaultValue = "10S")
    Duration connectTimeout;

    /** A PEM file of extra trusted certificates (tests: the stub server's self-signed certificate). */
    @ConfigProperty(name = "wt.data.egress.trust-pem")
    Optional<String> trustPem;

    /** Addresses exempt from the blocked ranges (tests: 127.0.0.1, where the stub server listens). Empty in production. */
    @ConfigProperty(name = "wt.data.egress.exempt-addresses")
    Optional<List<String>> exemptAddresses;

    @ConfigProperty(name = "wt.data.dns.host")
    String dnsHost;

    @ConfigProperty(name = "wt.data.dns.port")
    int dnsPort;

    @ConfigProperty(name = "wt.data.dns.timeout-ms")
    long dnsTimeoutMs;

    HttpClient client;
    DnsClient dns;
    final Set<InetAddress> exempt = new HashSet<>();

    @PostConstruct
    void start() {
        HttpClientOptions options = new HttpClientOptions()
                .setConnectTimeout((int) connectTimeout.toMillis())
                .setVerifyHost(true)
                .setForceSni(true)
                .setDecompressionSupported(false)
                .setTryUseCompression(false)
                .setMaxPoolSize(32);
        trustPem.ifPresent(path -> options.setTrustOptions(new PemTrustOptions().addCertPath(path)));
        client = vertx.createHttpClient(options);
        dns = vertx.createDnsClient(new DnsClientOptions().setHost(dnsHost).setPort(dnsPort).setQueryTimeout(dnsTimeoutMs));
        exemptAddresses.orElse(List.of()).forEach(a -> exempt.add(literalAddress(a)));
    }

    /** Sends the request, following same-host redirects. Fails with the WireTuner errors of the class comment. */
    public Uni<Reply> send(Request request, Pins pins) {
        return hop(request, pins, 0);
    }

    private Uni<Reply> hop(Request request, Pins pins, int redirects) {
        URI url = request.url();
        return pin(url.getHost(), pins)
                .chain(address -> exchange(request, address))
                .chain(reply -> {
                    String location = reply.header("location");
                    if (!REDIRECTS.contains(reply.status()) || location == null) {
                        return Uni.createFrom().item(reply);
                    }
                    URI next = url.resolve(location);
                    if (!"https".equalsIgnoreCase(next.getScheme()) || next.getHost() == null
                            || !HostNames.key(next).equals(HostNames.key(url))) {
                        String to = next.getHost() == null ? location : next.getHost();
                        return Uni.createFrom().failure(StatusExceptions.hostRefused(to,
                                "a redirect from " + HostNames.key(url) + " leaves the host"));
                    }
                    if (redirects == MAX_REDIRECTS) {
                        return Uni.createFrom().failure(StatusExceptions.upstreamFailed(
                                "more than " + MAX_REDIRECTS + " redirects from " + HostNames.key(url)));
                    }
                    boolean toGet = reply.status() == 303;
                    return hop(new Request(toGet ? "GET" : request.method(), next, request.headers(),
                            toGet ? null : request.body(), request.timeout(), request.cap()), pins, redirects + 1);
                });
    }

    /** The checked address for the host, resolving it once per call. */
    Uni<InetAddress> pin(String host, Pins pins) {
        String key = host.toLowerCase(Locale.ROOT);
        InetAddress pinned = pins.byHost.get(key);
        if (pinned != null) {
            return Uni.createFrom().item(pinned);
        }
        Uni<List<InetAddress>> resolved = HostNames.literal(key) ? Uni.createFrom().item(List.of(literalAddress(key)))
                : lookup(key);
        return resolved.map(addresses -> {
            for (InetAddress address : addresses) {
                if (AddressPolicy.blocked(address) && !exempt.contains(address)) {
                    throw StatusExceptions.hostRefused(key, "resolves to an address the server does not connect to");
                }
            }
            pins.byHost.put(key, addresses.get(0));
            return addresses.get(0);
        });
    }

    /** A and AAAA answers from the configured resolver; a name with neither does not resolve. */
    private Uni<List<InetAddress>> lookup(String host) {
        Uni<List<String>> a = dns.resolveA(host).onFailure().recoverWithItem(List.of());
        Uni<List<String>> aaaa = dns.resolveAAAA(host).onFailure().recoverWithItem(List.of());
        return Uni.combine().all().unis(a, aaaa).asTuple()
                .emitOn(CallerContext.executor())
                .map(answers -> {
                    List<InetAddress> addresses = new ArrayList<>();
                    answers.getItem1().forEach(literal -> addresses.add(literalAddress(literal)));
                    answers.getItem2().forEach(literal -> addresses.add(literalAddress(literal)));
                    if (addresses.isEmpty()) {
                        throw StatusExceptions.upstreamFailed("host " + host + " does not resolve");
                    }
                    return addresses;
                });
    }

    /** One request and its response, to the pinned address, within the request's timeout and cap. */
    private Uni<Reply> exchange(Request request, InetAddress address) {
        URI url = request.url();
        String host = HostNames.bare(url.getHost());
        int port = HostNames.port(url);
        RequestOptions options = new RequestOptions()
                .setMethod(HttpMethod.valueOf(request.method()))
                .setServer(SocketAddress.inetSocketAddress(port, address.getHostAddress()))
                .setHost(host)
                .setPort(port)
                .setSsl(true)
                .setURI(HostNames.target(url))
                .setFollowRedirects(false);
        request.headers().forEach(options::addHeader);
        AtomicReference<HttpClientRequest> sent = new AtomicReference<>();
        return client.request(options)
                .chain(outbound -> {
                    sent.set(outbound);
                    return request.body() == null ? outbound.send() : outbound.send(Buffer.buffer(request.body()));
                })
                .chain(response -> read(response, request.cap()).map(body -> new Reply(response.statusCode(),
                        headers(response), body, url)))
                .ifNoItem().after(request.timeout())
                .failWith(() -> StatusExceptions.upstreamFailed(HostNames.key(url) + " did not answer within "
                        + request.timeout().toSeconds() + " s"))
                .onFailure().invoke(() -> reset(sent.get()))
                .onCancellation().invoke(() -> reset(sent.get()))
                .onFailure(failure -> !(failure instanceof StatusRuntimeException))
                .transform(failure -> StatusExceptions.upstreamFailed("could not fetch from " + HostNames.key(url) + ": "
                        + failure.getClass().getSimpleName()));
    }

    /** The body, up to {@code cap} bytes; beyond it the exchange fails and the connection is dropped. */
    private static Uni<byte[]> read(HttpClientResponse response, long cap) {
        String length = response.getHeader("content-length");
        if (length != null && Long.parseLong(length) > cap) {
            return Uni.createFrom().failure(StatusExceptions.responseTooLarge(cap));
        }
        return response.toMulti()
                .collect().in(ByteArrayOutputStream::new, (out, chunk) -> {
                    if (out.size() + (long) chunk.length() > cap) {
                        throw StatusExceptions.responseTooLarge(cap);
                    }
                    out.writeBytes(chunk.getBytes());
                })
                .map(ByteArrayOutputStream::toByteArray);
    }

    private static List<Map.Entry<String, String>> headers(HttpClientResponse response) {
        List<Map.Entry<String, String>> headers = new ArrayList<>();
        response.headers().entries()
                .forEach(entry -> headers.add(Map.entry(entry.getKey().toLowerCase(Locale.ROOT), entry.getValue())));
        return headers;
    }

    private static void reset(HttpClientRequest request) {
        if (request != null) {
            request.reset();
        }
    }

    /** Parses an address literal from configuration, a DNS answer or a URL (never a name: no lookup happens). */
    static InetAddress literalAddress(String literal) {
        return AddressPolicy.address(literal);
    }
}
