require 'webrick'

port = 4567

server = WEBrick::HTTPServer.new(Port: port)

server.mount_proc '/ do |req, res|
  res.body = 'Hello World'
  res['Content-Type'] = 'text/plain'
end'

trap 'INT' do
  server.shutdown
end

puts "Servidor rodando na :4567"

server.start