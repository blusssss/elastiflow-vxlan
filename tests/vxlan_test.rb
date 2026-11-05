require 'minitest/autorun'
require_relative '../codec/vxlan'
require_relative 'fixtures'

class VxlanTest < Minitest::Test
  F = VxlanFixtures

  def decode(packet = F.packet, protocol = 1, captured = nil)
    SflowVxlanDecoder.decode(F.record(packet, protocol, captured))
  end

  def test_standard_tcp
    result = decode
    assert_equal 'ok', result['status']
    assert_equal 0x123456, result['vni']
    assert_equal 4789, result['outer']['destination_port']
    assert_equal '192.0.2.1', result['outer']['source_ip']
    assert_equal '10.0.0.1', result['inner']['source_ip']
    assert_equal '00:11:22:33:44:55', result['inner']['destination_mac']
    assert_equal 443, result['inner']['destination_port']
    assert_equal 0x12, result['inner']['tcp_flags']
  end

  def test_inner_udp_ipv6
    inner = F.ethernet(F.ipv6(F.udp('abc', 53)), 0x86dd)
    r = decode(F.packet(inner))
    assert_equal 'ok', r['status']
    assert_equal '2001:db8::1', r['inner']['source_ip']
    assert_equal 53, r['inner']['destination_port']
  end

  def test_ipv6_outer
    r = decode(F.ethernet(F.ipv6(F.udp(F.vxlan)), 0x86dd))
    assert_equal 'ok', r['status']
    assert_equal 6, r['outer']['ip_version']
  end

  def test_direct_ip_sample_headers
    assert_equal 'ok', decode(F.ipv4(F.udp(F.vxlan)), 11)['status']
    assert_equal 'ok', decode(F.ipv6(F.udp(F.vxlan)), 12)['status']
  end

  def test_vlan_inner_and_outer
    inner = F.ethernet(F.ipv4(F.tcp, 6), 0x0800, true)
    r = decode(F.ethernet(F.ipv4(F.udp(F.vxlan(inner))), 0x0800, true))
    assert_equal 'ok', r['status']
    assert_equal [123], r['inner']['vlan_ids']
    assert_equal [123], r['outer']['vlan_ids']
  end

  def test_ipv4_options
    r = decode(F.ethernet(F.ipv4(F.udp(F.vxlan), 17, "\1\1\1\1")))
    assert_equal 'ok', r['status']
  end

  def test_ipv6_extension
    extension = [17, 0, 0, 0, 0, 0, 0, 0].pack('C8')
    r = decode(F.ethernet(F.ipv6(extension + F.udp(F.vxlan), 0), 0x86dd))
    assert_equal 'ok', r['status']
  end

  def test_nonstandard_port_ignored
    assert_nil decode(F.packet(nil, 8472))
    assert_nil decode(F.packet(nil, 53))
  end

  def test_missing_i_flag
    r = decode(F.ethernet(F.ipv4(F.udp(F.vxlan(nil, 0)))))
    assert_equal 'invalid', r['status']
    refute r.key?('vni')
  end

  def test_gpe_gbp_not_decoded
    [0x0c, 0x88].each do |flags|
      r = decode(F.ethernet(F.ipv4(F.udp(F.vxlan(nil, flags)))))
      assert_equal 'unsupported', r['status']
      refute r.key?('inner')
    end
  end

  def test_reserved_bits_ignored
    payload = F.vxlan(nil, 0x18)
    payload[1, 3] = "\1\2\3"
    payload.setbyte(7, 255)
    assert_equal 'ok', decode(F.ethernet(F.ipv4(F.udp(payload))))['status']
  end

  def test_vni_boundaries
    [0, 0xffffff].each do |vni|
      assert_equal vni, decode(F.ethernet(F.ipv4(F.udp(F.vxlan(nil, 8, vni)))))['vni']
    end
  end

  def test_truncation_preserves_vni
    r = decode(F.packet, 1, 55)
    assert_equal 'truncated', r['status']
    assert_equal 0x123456, r['vni']
  end

  def test_truncated_vxlan
    r = decode(F.packet, 1, 46)
    assert_equal 'truncated', r['status']
    refute r.key?('vni')
  end

  def test_sample_payload_truncated_after_headers_is_ok
    inner = F.ethernet(F.ipv4(F.udp('x' * 100, 53)))
    r = decode(F.packet(inner), 1, 92)
    assert_equal 'ok', r['status']
    assert_equal 53, r['inner']['destination_port']
  end

  def test_outer_fragments_ignored
    [0x2000, 1].each do |fragment|
      assert_nil decode(F.ethernet(F.ipv4(F.udp(F.vxlan), 17, ''.b, fragment)))
    end
  end

  def test_inner_fragments_marked
    inner = F.ethernet(F.ipv4(F.tcp, 6, ''.b, 0x2000))
    r = decode(F.packet(inner))
    assert_equal 'unsupported', r['status']
    refute r['inner'].key?('source_port')
  end

  def test_arp_retains_l2_and_vni
    r = decode(F.packet(F.ethernet("\0" * 28, 0x0806)))
    assert_equal 'unsupported', r['status']
    assert_equal 0x0806, r['inner']['ether_type']
    assert_equal 0x123456, r['vni']
  end

  def test_icmp
    r = decode(F.packet(F.ethernet(F.ipv4([8, 0, 0, 0].pack('C4'), 1))))
    assert_equal 'ok', r['status']
    assert_equal 8, r['inner']['icmp_type']
  end

  def test_bad_udp_length_does_not_consume_padding
    packet = F.packet
    packet[38, 2] = [8].pack('n')
    assert_equal 'invalid', decode(packet)['status']
  end

  def test_all_capture_boundaries_and_random_bytes_do_not_raise
    packet = F.packet
    (0..packet.bytesize).each { |size| decode(packet, 1, size) }
    random = Random.new(123)
    1000.times { SflowVxlanDecoder.decode(random.bytes(random.rand(0..256))) }
    assert true
  end
end
