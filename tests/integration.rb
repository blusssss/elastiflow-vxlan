require 'json'
require_relative 'fixtures'

# Run with Logstash's JRuby and bundler environment.
require 'logstash/codecs/sflow'
require 'logstash/event'

F = VxlanFixtures

def check(condition, message)
  raise message unless condition
end

def decode(raw, enabled = true)
  codec = LogStash::Codecs::Sflow.new('vxlan_enabled' => enabled)
  codec.register
  result = []
  codec.decode(raw) { |event| result << event }
  result
end

count = 0
[
  F.datagram,
  F.datagram(nil, true),
  F.datagram(F.record(F.ethernet(F.ipv6(F.udp(F.vxlan)), 0x86dd))),
  F.datagram(F.record(F.packet, 1, 55)),
  F.datagram(F.record(F.packet(nil, 53))),
  F.datagram(F.record(F.ethernet(F.ipv4(F.udp(F.vxlan(nil, 0))))))
].each_with_index do |bytes, index|
  enabled, disabled = decode(bytes), decode(bytes, false)
  check(enabled.length == 1 && disabled.length == 1, "missing event #{index}")
  added = enabled.first.to_hash.reject { |k, _| ['vxlan', '@timestamp'].include?(k) }
  old = disabled.first.to_hash.reject { |k, _| k == '@timestamp' }
  check(added == old, "existing fields changed #{index}")
  if index == 4
    check(enabled.first.get('[vxlan]').nil?, 'non-vxlan packet marked')
  else
    expected = index == 3 ? 'truncated' : (index == 5 ? 'invalid' : 'ok')
    check(enabled.first.get('[vxlan][status]') == expected, "wrong status #{index}")
  end
  check(disabled.first.get('[vxlan]').nil?, 'disable switch failed')
  count += 1
end

event = decode(F.datagram).first
check(event.get('[vxlan][vni]') == 0x123456, 'VNI mismatch')
check(event.get('[vxlan][inner][destination_port]') == 443, 'inner port missing')
check(event.get('dst_port').to_i == 4789, 'outer port replaced')
check(event.get('frame_length_times_sampling_rate') == (F.packet.bytesize + 4) * 100, 'accounting changed')

# A malformed inner frame must not suppress another sample in the same datagram.
sample_a = F.datagram(F.record(F.packet, 1, 55)).byteslice(28..-1)
sample_b = F.datagram.byteslice(28..-1)
combined = F.datagram.byteslice(0, 28)
combined[24, 4] = [2].pack('N')
events = decode(combined + sample_a + sample_b)
check(events.length == 2, 'truncated inner packet lost another sample')
check(events.last.get('[vxlan][status]') == 'ok', 'later sample failed')

# Counter samples take their original path.
counter = [1, 1, 0].pack('N3')
counter_datagram = [5, 1, 0xc000020a, 0, 1, 1000, 1, 2, counter.bytesize].pack('N*') + counter
check(decode(counter_datagram).empty?, 'empty counter sample behavior changed')

generic = [2, 6].pack('N2') + [1000000000].pack('Q>') + [1, 3].pack('N2') +
          [123456].pack('Q>') + [10, 0, 0, 0, 0, 0].pack('N6') +
          [654321].pack('Q>') + [20, 0, 0, 0, 0, 0].pack('N6')
counter = [1, 1, 1, 1, generic.bytesize].pack('N5') + generic
counter_datagram = [5, 1, 0xc000020a, 0, 1, 1000, 1, 2, counter.bytesize].pack('N*') + counter
enabled_counter = decode(counter_datagram).first
disabled_counter = decode(counter_datagram, false).first
check(!enabled_counter.nil? && enabled_counter.get('input_octets').to_i == 123456, 'counter decoding failed')
check(enabled_counter.get('[vxlan]').nil?, 'counter gained vxlan fields')
check(enabled_counter.to_hash.reject { |k, _| k == '@timestamp' } ==
      disabled_counter.to_hash.reject { |k, _| k == '@timestamp' }, 'counter fields changed')

puts "PASS: #{count} full sFlow cases, field equivalence, disable switch, multi-sample isolation, counter path"
File.write(ENV['SFLOW_EXAMPLE_EVENT'], JSON.pretty_generate(event.to_hash)) if ENV['SFLOW_EXAMPLE_EVENT']

if ENV['SFLOW_FIXTURE_DIR']
  Dir.mkdir(ENV['SFLOW_FIXTURE_DIR']) unless Dir.exist?(ENV['SFLOW_FIXTURE_DIR'])
  File.binwrite(File.join(ENV['SFLOW_FIXTURE_DIR'], 'standard-vxlan.sflow'), F.datagram)
end
