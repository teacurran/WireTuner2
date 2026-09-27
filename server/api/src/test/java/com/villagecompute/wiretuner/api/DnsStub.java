package com.villagecompute.wiretuner.api;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import io.quarkus.test.common.QuarkusTestResourceLifecycleManager;

/**
 * A tiny authoritative DNS server on 127.0.0.1 answering TXT queries from {@link #TXT} (workspace
 * domain verification, SEC-001) and A and AAAA queries from {@link #A} and {@link #AAAA} (the data
 * service's upstream hosts, DATA-006), so both run against a real resolver round trip without the
 * network. Every query is counted in {@link #QUERIES} by name and type. Unknown names are NXDOMAIN; a
 * known name gets an empty answer for a type it has no records of.
 */
public class DnsStub implements QuarkusTestResourceLifecycleManager {

    /** Domain (lower-case) to its TXT strings; tests publish and withdraw records here. */
    public static final Map<String, List<String>> TXT = new ConcurrentHashMap<>();

    /** Name (lower-case) to IPv4 literals. */
    public static final Map<String, List<String>> A = new ConcurrentHashMap<>();
    /** Name (lower-case) to IPv6 literals (an IPv4-mapped literal is sent as its 16 bytes). */
    public static final Map<String, List<String>> AAAA = new ConcurrentHashMap<>();
    /** Queries seen, by {@code name/type} (type 1 = A, 28 = AAAA, 16 = TXT). */
    public static final Map<String, AtomicInteger> QUERIES = new ConcurrentHashMap<>();

    static final int TYPE_A = 1;
    static final int TYPE_TXT = 16;
    static final int TYPE_AAAA = 28;

    private DatagramSocket socket;

    @Override
    public Map<String, String> start() {
        try {
            socket = new DatagramSocket(0, InetAddress.getLoopbackAddress());
        } catch (SocketException e) {
            throw new IllegalStateException(e);
        }
        Thread.ofPlatform().daemon().name("dns-stub").start(this::serve);
        return Map.of("wt.dns.host", "127.0.0.1", "wt.dns.port", Integer.toString(socket.getLocalPort()),
                "wt.dns.timeout-ms", "2000");
    }

    @Override
    public void stop() {
        socket.close();
    }

    private void serve() {
        byte[] buffer = new byte[512];
        while (!socket.isClosed()) {
            DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
            try {
                socket.receive(packet);
                byte[] reply = answer(buffer);
                socket.send(new DatagramPacket(reply, reply.length, packet.getSocketAddress()));
            } catch (IOException e) {
                // socket closed at shutdown
            }
        }
    }

    static byte[] answer(byte[] query) {
        int at = 12;
        StringBuilder name = new StringBuilder();
        while (query[at] != 0) {
            int label = query[at] & 0xff;
            if (!name.isEmpty()) {
                name.append('.');
            }
            name.append(new String(query, at + 1, label, StandardCharsets.US_ASCII));
            at += label + 1;
        }
        int questionEnd = at + 5;
        int type = ((query[at + 1] & 0xff) << 8) | (query[at + 2] & 0xff);
        String key = name.toString().toLowerCase(Locale.ROOT);
        QUERIES.computeIfAbsent(key + "/" + type, k -> new AtomicInteger()).incrementAndGet();
        boolean known = TXT.containsKey(key) || A.containsKey(key) || AAAA.containsKey(key);
        List<byte[]> answers = new ArrayList<>();
        if (type == TYPE_TXT) {
            for (String record : TXT.getOrDefault(key, List.of())) {
                byte[] text = record.getBytes(StandardCharsets.US_ASCII);
                ByteArrayOutputStream data = new ByteArrayOutputStream();
                data.write(text.length);
                data.writeBytes(text);
                answers.add(data.toByteArray());
            }
        } else if (type == TYPE_A) {
            A.getOrDefault(key, List.of()).forEach(literal -> answers.add(address(literal, 4)));
        } else if (type == TYPE_AAAA) {
            AAAA.getOrDefault(key, List.of()).forEach(literal -> answers.add(address(literal, 16)));
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(query[0]);
        out.write(query[1]);
        out.write(0x81);
        out.write(known ? 0x80 : 0x83);
        out.writeBytes(new byte[] {0, 1, 0, (byte) answers.size(), 0, 0, 0, 0});
        out.write(query, 12, questionEnd - 12);
        for (byte[] data : answers) {
            out.writeBytes(new byte[] {(byte) 0xc0, 0x0c, 0, (byte) type, 0, 1, 0, 0, 0, 60, 0, (byte) data.length});
            out.writeBytes(data);
        }
        return out.toByteArray();
    }

    /** An address literal's bytes at the record's length (IPv4-mapped for a 4-byte address in AAAA). */
    static byte[] address(String literal, int length) {
        byte[] bytes;
        try {
            bytes = InetAddress.getByName(literal).getAddress();
        } catch (IOException e) {
            throw new IllegalArgumentException(e);
        }
        if (bytes.length == length) {
            return bytes;
        }
        byte[] mapped = new byte[16];
        mapped[10] = (byte) 0xff;
        mapped[11] = (byte) 0xff;
        System.arraycopy(bytes, 0, mapped, 12, 4);
        return mapped;
    }
}
