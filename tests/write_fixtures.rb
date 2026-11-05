require_relative 'fixtures'

directory = File.expand_path('../fixtures', __dir__)
Dir.mkdir(directory) unless Dir.exist?(directory)
{
  'standard-vxlan' => VxlanFixtures.datagram,
  'truncated-vxlan' => VxlanFixtures.datagram(VxlanFixtures.record(VxlanFixtures.packet, 1, 55)),
  'ordinary-udp' => VxlanFixtures.datagram(VxlanFixtures.record(VxlanFixtures.packet(nil, 53)))
}.each do |name, bytes|
  File.binwrite(File.join(directory, name + '.sflow'), bytes)
  frame = VxlanFixtures.ethernet(VxlanFixtures.ipv4(VxlanFixtures.udp(bytes, 6343)))
  global = [0xa1b2c3d4, 2, 4, 0, 0, 65535, 1].pack('VvvVVVV')
  capture = [0, 0, frame.bytesize, frame.bytesize].pack('V4')
  File.binwrite(File.join(directory, name + '.pcap'), global + capture + frame)
end
puts "Wrote synthetic sFlow payloads and PCAPs to #{directory}"
