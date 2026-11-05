# encoding: utf-8
require 'ipaddr'

# Additive decoder for an sFlow raw_packet_header record. No payload is exported.
class SflowVxlanDecoder
  class DecodeError < StandardError
    attr_reader :status
    def initialize(status, message)
      @status = status
      super(message)
    end
  end

  def self.decode(record)
    new.decode(record)
  end

  def decode(record)
    @result = nil
    need(record, 16)
    protocol, _frame_length, _stripped, captured = record.unpack('N4')
    packet = record.byteslice(16, [captured, record.bytesize - 16].min)
    packet ||= ''.b
    outer = {}
    if protocol == 1
      packet, type = ethernet(packet, outer)
    elsif protocol == 11
      type = 0x0800
    elsif protocol == 12
      type = 0x86dd
    else
      return nil
    end
    udp, next_header = network(packet, type, outer)
    return nil unless next_header == 17
    need(udp, 8)
    source, destination, length = udp.unpack('n3')
    return nil unless destination == 4789
    @result = {'status' => 'ok', 'outer' => outer}
    outer['source_port'], outer['destination_port'] = source, destination
    invalid('udp_length') if length < 16 || length > @network_payload_length
    udp = udp.byteslice(0, length)
    vxlan = udp.byteslice(8, udp.bytesize - 8)
    need(vxlan, 8)
    flags = vxlan.getbyte(0)
    invalid('vxlan_i_flag_missing') if (flags & 0x08) == 0
    # GPE/GBP are outside v1. Other reserved flag bits are ignored on receive.
    unsupported('vxlan_gpe_or_gbp') if (flags & 0x84) != 0
    @result['vni'] = vxlan.byteslice(4, 3).unpack('C3').inject(0) { |v, b| (v << 8) | b }
    @result['flags'] = flags
    inner = {}
    @result['inner'] = inner
    packet, type = ethernet(vxlan.byteslice(8, vxlan.bytesize - 8), inner)
    transport, next_header = network(packet, type, inner)
    case next_header
    when 6
      need(transport, 20)
      header_length = (transport.getbyte(12) >> 4) * 4
      invalid('tcp_header_length') if header_length < 20 || header_length > @network_payload_length
      need(transport, header_length)
      inner['source_port'], inner['destination_port'] = transport.unpack('n2')
      inner['tcp_flags'] = transport.getbyte(13)
    when 17
      need(transport, 8)
      source, destination, size = transport.unpack('n3')
      invalid('inner_udp_length') if size < 8 || size > @network_payload_length
      inner['source_port'], inner['destination_port'] = source, destination
    when 1, 58
      need(transport, 4)
      inner['icmp_type'], inner['icmp_code'] = transport.unpack('C2')
    else
      unsupported('inner_transport_protocol')
    end
    @result
  rescue DecodeError => e
    return nil unless @result
    @result['status'] = e.status
    @result['reason'] = e.message
    @result
  end

  private

  def need(bytes, size)
    raise DecodeError.new('truncated', 'sample_header_too_short') if bytes.nil? || bytes.bytesize < size
  end

  def invalid(reason)
    raise DecodeError.new('invalid', reason)
  end

  def unsupported(reason)
    raise DecodeError.new('unsupported', reason)
  end

  def ethernet(bytes, fields)
    need(bytes, 14)
    fields['destination_mac'] = mac(bytes.byteslice(0, 6))
    fields['source_mac'] = mac(bytes.byteslice(6, 6))
    type = bytes.byteslice(12, 2).unpack('n')[0]
    offset = 14
    vlans = []
    while type == 0x8100 || type == 0x88a8
      unsupported('vlan_depth') if vlans.length >= 2
      need(bytes, offset + 4)
      tci, type = bytes.byteslice(offset, 4).unpack('n2')
      vlans << (tci & 0x0fff)
      offset += 4
    end
    fields['vlan_ids'] = vlans unless vlans.empty?
    fields['ether_type'] = type
    [bytes.byteslice(offset, bytes.bytesize - offset), type]
  end

  def network(bytes, type, fields)
    case type
    when 0x0800
      need(bytes, 20)
      invalid('ipv4_version') unless bytes.getbyte(0) >> 4 == 4
      ihl = (bytes.getbyte(0) & 15) * 4
      total = bytes.byteslice(2, 2).unpack('n')[0]
      invalid('ipv4_length') if ihl < 20 || total < ihl
      need(bytes, ihl)
      fields['ip_version'] = 4
      fields['source_ip'] = IPAddr.new_ntoh(bytes.byteslice(12, 4)).to_s
      fields['destination_ip'] = IPAddr.new_ntoh(bytes.byteslice(16, 4)).to_s
      proto = bytes.getbyte(9)
      fields['ip_protocol'] = proto
      fragment = bytes.byteslice(6, 2).unpack('n')[0]
      unsupported('ip_fragment') unless (fragment & 0x3fff) == 0
      @network_payload_length = total - ihl
      bounded = bytes.byteslice(0, total)
      [bounded.byteslice(ihl, bounded.bytesize - ihl), proto]
    when 0x86dd
      need(bytes, 40)
      invalid('ipv6_version') unless bytes.getbyte(0) >> 4 == 6
      length = bytes.byteslice(4, 2).unpack('n')[0]
      unsupported('ipv6_jumbogram') if length == 0
      fields['ip_version'] = 6
      fields['source_ip'] = IPAddr.new_ntoh(bytes.byteslice(8, 16)).to_s
      fields['destination_ip'] = IPAddr.new_ntoh(bytes.byteslice(24, 16)).to_s
      proto = bytes.getbyte(6)
      bytes = bytes.byteslice(0, 40 + length)
      offset, count = 40, 0
      while [0, 43, 60].include?(proto)
        unsupported('ipv6_extension_depth') if count >= 8
        need(bytes, offset + 2)
        next_proto = bytes.getbyte(offset)
        size = (bytes.getbyte(offset + 1) + 1) * 8
        invalid('ipv6_extension_length') if offset + size > 40 + length
        need(bytes, offset + size)
        offset += size
        proto = next_proto
        count += 1
      end
      fields['ip_protocol'] = proto
      unsupported('ip_fragment') if proto == 44
      unsupported('ipv6_security_header') if proto == 50 || proto == 51
      @network_payload_length = 40 + length - offset
      [bytes.byteslice(offset, bytes.bytesize - offset), proto]
    else
      unsupported('ether_type')
    end
  end

  def mac(bytes)
    bytes.unpack('C6').map { |b| '%02x' % b }.join(':')
  end
end
