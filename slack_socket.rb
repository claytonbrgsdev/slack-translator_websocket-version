require 'http'
require 'websocket-client-simple'
require 'json'
require 'dotenv'

# Carrega variáveis de ambiente se estiver em desenvolvimento
Dotenv.load if ENV['RACK_ENV'] != 'production'

# Método para obter a URL do WebSocket usando apps.connections.open
# @param token [String] SLACK_APP_LEVEL_TOKEN para Socket Mode
# @return [String] URL do WebSocket
def open_socket_url(token)
  resp = HTTP
    .headers('Content-Type' => 'application/x-www-form-urlencoded',
             'Authorization'  => "Bearer #{token}")
    .post('https://slack.com/api/apps.connections.open')
  body = JSON.parse(resp.to_s)
  raise "Erro Slack: #{body['error']}" unless body['ok']
  body['url']
end
