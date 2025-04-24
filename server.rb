require 'webrick'
require 'webrick/httpservlet/filehandler'
require 'json'

port = ENV.fetch('PORT', '4567').to_i
public_dir = File.expand_path('public', __dir__)

server = WEBrick::HTTPServer.new(
  Port: port,
  DocumentRoot: public_dir
)

# serve arquivos estáticos de public/
server.mount '/', WEBrick::HTTPServlet::FileHandler, public_dir

# rotas dinâmicas
server.mount_proc '/status' do |req, res|
  res.body = { status: 'ok', time: Time.now }.to_json
  res['Content-Type'] = 'application/json'
end

server.mount_proc '/translate' do |req, res|
  if req.request_method == 'POST'
    # futura chamada ao Ollama
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

puts "Servidor rodando em http://localhost:#{port}"
server.start