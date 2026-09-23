package com.villagecompute.wiretuner.api;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.KeyStore;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executors;
import java.util.stream.Collectors;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;

import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;

/**
 * The upstream APIs of the data-service tests (DATA-006..009): one HTTPS server on 127.0.0.1 with a
 * self-signed certificate for {@code *.wt.test}, {@code localhost} and {@code 127.0.0.1}
 * ({@code src/test/resources/egress}), which the API trusts through {@code wt.data.egress.trust-pem}.
 * 127.0.0.1 is the one address exempted from the SSRF guard in tests; names reach it through the
 * {@link DnsStub}'s A records. Tests route paths to handlers in {@link #ROUTES} (exact path, query
 * ignored) and read every request the server saw in {@link #SEEN}.
 */
public class EgressStub implements QuarkusTestResourceLifecycleManager {

    /** A route's behaviour. */
    @FunctionalInterface
    public interface Handler {
        void handle(HttpExchange exchange, Seen request) throws IOException;
    }

    /** One request as the server saw it; header names in lower case. */
    public record Seen(String method, String host, String path, String query, Map<String, String> headers, byte[] body) {

        public String header(String name) {
            return headers.get(name);
        }

        public String bodyText() {
            return new String(body, StandardCharsets.UTF_8);
        }
    }

    public static final Map<String, Handler> ROUTES = new ConcurrentHashMap<>();
    public static final List<Seen> SEEN = new CopyOnWriteArrayList<>();
    public static volatile int port;

    static final String KEYSTORE = "src/test/resources/egress/stub.p12";
    static final String CERT = "src/test/resources/egress/stub-cert.pem";
    static final char[] PASSWORD = "changeit".toCharArray();

    private HttpsServer server;

    @Override
    public Map<String, String> start() {
        try {
            KeyStore store = KeyStore.getInstance("PKCS12");
            try (InputStream in = java.nio.file.Files.newInputStream(Path.of(KEYSTORE))) {
                store.load(in, PASSWORD);
            }
            KeyManagerFactory keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            keys.init(store, PASSWORD);
            SSLContext tls = SSLContext.getInstance("TLS");
            tls.init(keys.getKeyManagers(), null, null);
            server = HttpsServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 64);
            server.setHttpsConfigurator(new HttpsConfigurator(tls));
            server.setExecutor(Executors.newCachedThreadPool());
            server.createContext("/", this::dispatch);
            server.start();
            port = server.getAddress().getPort();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
        return Map.of("wt.data.egress.trust-pem", Path.of(CERT).toAbsolutePath().toString(),
                "wt.data.egress.exempt-addresses", "127.0.0.1");
    }

    @Override
    public void stop() {
        server.stop(0);
    }

    private void dispatch(HttpExchange exchange) throws IOException {
        Map<String, String> headers = exchange.getRequestHeaders().entrySet().stream()
                .collect(Collectors.toMap(e -> e.getKey().toLowerCase(Locale.ROOT), e -> String.join(", ", e.getValue())));
        byte[] body = exchange.getRequestBody().readAllBytes();
        Seen seen = new Seen(exchange.getRequestMethod(), headers.get("host"), exchange.getRequestURI().getRawPath(),
                exchange.getRequestURI().getRawQuery(), headers, body);
        SEEN.add(seen);
        Handler handler = ROUTES.get(seen.path());
        try {
            if (handler == null) {
                send(exchange, 404, "application/json", "{\"error\":\"no route\"}");
            } else {
                handler.handle(exchange, seen);
            }
        } catch (IOException e) {
            // the client went away (a cap or a timeout on the API side)
        } finally {
            exchange.close();
        }
    }

    /** The requests the server saw for a path. */
    public static List<Seen> seen(String path) {
        return SEEN.stream().filter(s -> s.path().equals(path)).toList();
    }

    /** A complete response with a body. */
    public static void send(HttpExchange exchange, int status, String contentType, String body) throws IOException {
        send(exchange, status, contentType, body.getBytes(StandardCharsets.UTF_8));
    }

    public static void send(HttpExchange exchange, int status, String contentType, byte[] body) throws IOException {
        if (contentType != null) {
            exchange.getResponseHeaders().add("Content-Type", contentType);
        }
        exchange.sendResponseHeaders(status, body.length == 0 ? -1 : body.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(body);
        }
    }

    /** A JSON 200. */
    public static void json(HttpExchange exchange, String body) throws IOException {
        send(exchange, 200, "application/json", body);
    }

    /** A redirect. */
    public static void redirect(HttpExchange exchange, int status, String location) throws IOException {
        exchange.getResponseHeaders().add("Location", location);
        exchange.sendResponseHeaders(status, -1);
    }

    /** {@code size} bytes of JSON-ish filler, chunked (no Content-Length), so only a streaming cap can stop it. */
    public static void chunked(HttpExchange exchange, String contentType, long size) throws IOException {
        exchange.getResponseHeaders().add("Content-Type", contentType);
        exchange.sendResponseHeaders(200, 0);
        byte[] block = new byte[64 * 1024];
        java.util.Arrays.fill(block, (byte) ' ');
        try (OutputStream out = exchange.getResponseBody()) {
            for (long sent = 0; sent < size; sent += block.length) {
                out.write(block, 0, (int) Math.min(block.length, size - sent));
            }
        }
    }

    /** The URL of a path on a stub host name (which a test maps to 127.0.0.1 in the DNS stub). */
    public static String url(String host, String path) {
        return "https://" + host + ":" + port + path;
    }

    /** The allowlist entry of a stub host name. */
    public static String hostKey(String host) {
        return host + ":" + port;
    }
}
