package com.example.tgwsproxy.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProxyAddressTest {
    @Test
    fun acceptsLoopbackAndAnyAddress() {
        assertTrue(ProxyAddress.isValidHost("127.0.0.1"))
        assertTrue(ProxyAddress.isValidHost("localhost"))
        assertTrue(ProxyAddress.isValidHost("0.0.0.0"))
    }

    @Test
    fun rejectsHostnamesAndMalformedIpv4() {
        assertFalse(ProxyAddress.isValidHost("example.com"))
        assertFalse(ProxyAddress.isValidHost("127.0.0.999"))
        assertFalse(ProxyAddress.isValidHost("127.0.0"))
        assertFalse(ProxyAddress.isValidHost(""))
    }

    @Test
    fun acceptsOnlyUsablePorts() {
        assertTrue(ProxyAddress.isValidPort(1))
        assertTrue(ProxyAddress.isValidPort(65535))
        assertFalse(ProxyAddress.isValidPort(0))
        assertFalse(ProxyAddress.isValidPort(65536))
    }
}
