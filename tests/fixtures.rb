require 'ipaddr'

module VxlanFixtures
  module_function

  def ethernet(payload, type = 0x0800, vlan = false)
    macs = [0x001122334455, 0x0066778899aa].map { |n| [n >> 16, n & 0xffff].pack('Nn') }.join
    macs + (vlan ? [0x8100, 123, type].pack('n3') : [type].pack('n')) + payload
  end

  def ipv4(payload, protocol = 17, options = ''.b, fragment = 0, source = '192.0.2.1', destination = '198.51.100.2')
    header = [0x45 + options.bytesize / 4, 0, 20 + options.bytesize + payload.bytesize,
              1, fragment, 64, protocol, 0].pack('CCnnnCCn') +
             IPAddr.new(source).hton + IPAddr.new(destination).hton + options
    sum = header.unpack('n*').inject(0, :+)
    sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
    header[10, 2] = [~sum & 0xffff].pack('n')
    header + payload
  end

  def ipv6(payload, protocol = 17)
    [0x60000000, payload.bytesize, protocol, 64].pack('NnCC') +
      IPAddr.new('2001:db8::1').hton + IPAddr.new('2001:db8::2').hton + payload
  end

  def udp(payload, port = 4789)
    [55000, port, 8 + payload.bytesize, 0].pack('n4') + payload
  end

  def tcp
    [12345, 443, 1, 0, 0x5012, 4096, 0, 0].pack('nnNNnnnn')
  end

  def vxlan(inner = nil, flags = 8, vni = 0x123456)
    inner ||= ethernet(ipv4(tcp, 6, ''.b, 0, '10.0.0.1', '10.0.0.2'))
    [flags, 0, 0, 0, (vni >> 16) & 255, (vni >> 8) & 255, vni & 255, 0].pack('C8') + inner
  end

  def packet(inner = nil, port = 4789)
    ethernet(ipv4(udp(vxlan(inner), port)))
  end

  def record(packet = nil, protocol = 1, captured = nil)
    packet ||= self.packet
    size = captured || packet.bytesize
    [protocol, packet.bytesize + 4, 4, size].pack('N4') + packet.byteslice(0, size)
  end

  def datagram(raw = nil, expanded = false, extra_records = [])
    raw ||= record
    raw += "\0" * ((4 - raw.bytesize % 4) % 4)
    records = [[1, raw.bytesize].pack('N2') + raw] + extra_records
    # seq, source, rate, pool, drops, input, output, count
    values = expanded ? [1, 0, 1, 100, 1000, 0, 0, 2, 0, 3, records.length] :
                        [1, 1, 100, 1000, 0, 2, 3, records.length]
    sample = values.pack('N*') + records.join
    [5, 1, 0xc000020a, 0, 1, 1000, 1, expanded ? 3 : 1, sample.bytesize].pack('N*') + sample
  end
end
