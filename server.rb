require 'webrick'
require 'json'

port = 4567

server = WEBrick::HTTPServer.new(Port: port)

server.mount_proc '/' do |req, res|
  res.body = 'Hello World'
  res['Content-Type'] = 'text/plain'
end

server.mount_proc '/status' do |req, res|
  res.body = { status: 'ok', time: Time.now }.to_json
  res['Content-Type'] = 'application/json'
end

server.mount_proc '/translate' do |req, res|
  if req.request_method == 'POST'
    res.body = { message: 'Endpoint de tradução ainda não implementado' }.to_json
  else
    res.body = { error: 'Use POST para enviar texto' }.to_json
    res.status = 405
  end
  res['Content-Type'] = 'application/json'
end

trap 'INT' do
  server.shutdown
end

puts "Servidor rodando na :4567"
server.start

server.start