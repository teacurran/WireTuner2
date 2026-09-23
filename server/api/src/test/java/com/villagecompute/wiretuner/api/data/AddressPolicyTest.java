package com.villagecompute.wiretuner.api.data;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.URI;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.grpc.StatusRuntimeException;

/**
 * DATA-006, SSRF attack cases on the address and URL level: every private, loopback, link-local,
 * metadata and otherwise special range in IPv4 and IPv6 -- including IPv4 addresses smuggled inside
 * IPv6 (mapped, NAT64, 6to4) -- is blocked; public addresses pass; URLs that are not plain https with a
 * host, or that hide a numeric host, are refused before any lookup.
 */
class AddressPolicyTest {

    @ParameterizedTest
    @ValueSource(strings = {"0.0.0.0", "0.1.2.3", "10.0.0.5", "10.255.255.255", "100.64.0.1", "100.127.255.254", "127.0.0.1",
            "127.1.2.3", "169.254.169.254", "169.254.0.1", "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.0.2.1",
            "192.88.99.1", "192.168.1.1", "198.18.0.1", "198.19.255.255", "198.51.100.7", "203.0.113.9", "224.0.0.1",
            "239.255.255.250", "240.0.0.1", "255.255.255.255", "::", "::1", "::127.0.0.1", "64:ff9b:1::1", "100::1",
            "2001::1", "2001:10::1", "2001:20::1", "2001:db8::1", "fc00::1", "fd00:ec2::254", "fdff::1", "fe80::1",
            "febf::1", "fec0::1", "ff02::1", "64:ff9b::a00:5", "64:ff9b::7f00:1", "2002:a00:5::1", "2002:7f00:1::",
            "2002:a9fe:a9fe::1"})
    void blocksSpecialRanges(String literal) {
        assertThat(AddressPolicy.blocked(AddressPolicy.address(literal))).as(literal).isTrue();
    }

    @ParameterizedTest
    @ValueSource(strings = {"8.8.8.8", "1.1.1.1", "93.184.216.34", "100.63.255.255", "100.128.0.0", "172.15.255.255",
            "172.32.0.0", "192.169.0.1", "198.17.255.255", "198.20.0.0", "223.255.255.255", "2606:4700:4700::1111",
            "2001:4860:4860::8888", "64:ff9b::808:808", "2002:808:808::1", "2001:30::1"})
    void passesPublicAddresses(String literal) {
        assertThat(AddressPolicy.blocked(AddressPolicy.address(literal))).as(literal).isFalse();
    }

    @Test
    void judgesMappedAddressesByTheirIpv4() throws Exception {
        byte[] mappedPrivate = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, (byte) 0xff, (byte) 0xff, 10, 0, 0, 5};
        byte[] mappedPublic = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, (byte) 0xff, (byte) 0xff, 8, 8, 8, 8};
        byte[] mappedMetadata = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, (byte) 0xff, (byte) 0xff, (byte) 169, (byte) 254, (byte) 169,
                (byte) 254};
        assertThat(AddressPolicy.blocked(mappedPrivate)).isTrue();
        assertThat(AddressPolicy.blocked(mappedMetadata)).isTrue();
        assertThat(AddressPolicy.blocked(mappedPublic)).isFalse();
        // An Inet6Address that keeps the mapped form (the JDK usually turns them into Inet4Address).
        InetAddress kept = Inet6Address.getByAddress(null, mappedPrivate, -1);
        assertThat(AddressPolicy.blocked(kept)).isTrue();
    }

    @Test
    void refusesMalformedLiterals() {
        assertThatThrownBy(() -> AddressPolicy.address("[::g]")).isInstanceOf(IllegalArgumentException.class);
    }

    static String reasonField(Runnable call) {
        try {
            call.run();
        } catch (StatusRuntimeException e) {
            return StatusExceptions.reasonOf(e).orElseThrow() + ":" + e.getStatus().getDescription();
        }
        throw new AssertionError("accepted");
    }

    @ParameterizedTest
    @ValueSource(strings = {"http://api.example.com/", "ftp://api.example.com/", "https:///nohost", "https://user:pw@api.example.com/",
            "https://2130706433/", "https://0x7f000001/", "https://127.1/", "https://10.0.0.300/", "https://a.b.017/", "not a url",
            "//api.example.com/x", "https://under_score.example.com/"})
    void refusesUrlsThatAreNotPlainHttps(String url) {
        assertThat(reasonField(() -> HostNames.parse(url, "url"))).startsWith(ErrorReasons.VALIDATION_FAILED + ":url:");
    }

    @Test
    void acceptsHttpsNamesAndLiterals() {
        assertThat(HostNames.parse("HTTPS://Api.Example.com:8443/a?b=c", "url").getHost()).isEqualTo("Api.Example.com");
        assertThat(HostNames.parse("https://8.8.8.8/", "url").getHost()).isEqualTo("8.8.8.8");
        assertThat(HostNames.parse("https://[2001:db8::1]:443/", "url").getHost()).isEqualTo("[2001:db8::1]");
        assertThat(HostNames.parse("https://api.v2.example.com/", "url").getHost()).isEqualTo("api.v2.example.com");
    }

    @Test
    void hostKeys() {
        assertThat(HostNames.normalize("Api.Example.COM:443")).isEqualTo("api.example.com");
        assertThat(HostNames.normalize("api.example.com:8443")).isEqualTo("api.example.com:8443");
        assertThat(HostNames.key(URI.create("https://API.example.com/"))).isEqualTo("api.example.com");
        assertThat(HostNames.key(URI.create("https://api.example.com:443/"))).isEqualTo("api.example.com");
        assertThat(HostNames.key(URI.create("https://api.example.com:8443/"))).isEqualTo("api.example.com:8443");
        assertThat(HostNames.port(URI.create("https://a.example/"))).isEqualTo(443);
        assertThat(HostNames.port(URI.create("https://a.example:1/"))).isEqualTo(1);
        assertThat(HostNames.bare("[::1]")).isEqualTo("::1");
        assertThat(HostNames.bare("a.example")).isEqualTo("a.example");
        assertThat(HostNames.target(URI.create("https://a.example"))).isEqualTo("/");
        assertThat(HostNames.target(URI.create("https://a.example/p%20q?x=1&y"))).isEqualTo("/p%20q?x=1&y");
        assertThat(HostNames.literal("127.0.0.1")).isTrue();
        assertThat(HostNames.literal("[::1]")).isTrue();
        assertThat(HostNames.literal("a.example")).isFalse();
        assertThat(HostNames.dottedQuad("256.1.1.1")).isFalse();
    }
}
