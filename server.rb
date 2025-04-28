require 'json'
require 'dotenv'
require 'webrick'
require 'thread'
require 'http'
require_relative 'slack_socket'
require 'websocket-client-simple'
require 'securerandom'
require 'sequel'
require_relative 'db/config'
require_relative 'slack_user_service'
require_relative 'models/message'
require_relative 'ollama_client'

# Carregar variáveis de ambiente
Dotenv.load

# Variáveis globais para SSE - Hash para armazenar clientes por ID
$sse_clients = {}

# Thread para monitorar clientes inativos e removê-los periodicamente
$sse_monitor_thread = Thread.new do
  loop do
    sleep 30 # Verifica a cada 30 segundos
    begin
      inactive_clients = []
      $sse_clients.each_pair do |client_id, queue|
        # Considerar inativo se a última atividade foi há mais de 3 minutos
        if queue.instance_variable_defined?(:@last_activity) && 
           Time.now - queue.instance_variable_get(:@last_activity) > 180
          inactive_clients << client_id
          puts "[SSE MONITOR] Cliente inativo detectado: #{client_id}"
        end
      end
      
      # Remover clientes inativos
      inactive_clients.each do |client_id|
        $sse_clients.delete(client_id)
        puts "[SSE MONITOR] Cliente removido: #{client_id} (total: #{$sse_clients.size})"
      end
    rescue => e
      puts "[SSE MONITOR] Erro ao monitorar clientes: #{e.message}"
    end
  end
end

# Variáveis globais para WebSocket
$ws_mutex = Mutex.new
$slack_ws = nil
$backoff = 1

# Wrapper completo para o Queue do SSE, implementa todos os métodos necessários
class SSEBody
  def initialize(queue)
    @queue = queue
    @content = ""
    @active = true
  end
  
  # Método para verificar se a conexão ainda está ativa
  def active?
    @active
  end

  # WEBrick vai iterar chamando each para cada evento da fila
  def each
    # Send an initial heartbeat right away so the client receives data quickly
    yield ": init\n\n"
    
    # Enviar um comentário inicial para garantir que o browser mantenha a conexão
    yield ": heartbeat\n\n"
    
    # Enviar comentários periódicos para manter conexão viva
    keep_alive_thread = Thread.new do
      loop do
        sleep 15  # A cada 15 segundos
        begin
          break unless @active # Não enviar se a conexão já estiver inativa
          yield ": heartbeat\n\n"
        rescue => e
          # Thread será interrompida quando a conexão for fechada
          break
        end
      end
    end
    
    # Loop principal de processamento de eventos
    begin
      loop do
        chunk = @queue.pop
        @content = chunk
        yield chunk
        puts "[SSE BODY] → chunk #{chunk.bytesize}B"
      end
    rescue => e
      # Capturar erros quando a conexão fechar
      puts "[SSE BODY] Conexão encerrada: #{e.message}"
    ensure
      # Marcar como inativo quando a conexão encerrar
      @active = false
      puts "[SSE BODY] stream closed by client"
      # Garantir que o thread de keep-alive seja encerrado
      keep_alive_thread.kill if keep_alive_thread.alive?
    end
  end

  # Métodos que o WEBrick pode chamar
  def bytesize
    0
  end
  
  # Implementa o método [] que o WEBrick tenta chamar com 1 ou 2 argumentos
  def [](*args)
    case args.size
    when 1
      range = args[0]
      if range.is_a?(Range)
        @content[range]
      else
        @content[range..-1]
      end
    when 2
      # WEBrick pode chamar com offset e length como em [offset, length]
      offset, length = args
      @content[offset, length]
    else
      ""
    end
  end
  
  # Outros métodos que o WEBrick pode precisar
  def size
    0
  end
  
  def length
    0
  end
end

# Configurar o servidor WEBrick
port = ENV.fetch('PORT', '4567').to_i
public_dir = File.expand_path('public', __dir__)

server = WEBrick::HTTPServer.new(
  Port: port,
  DocumentRoot: public_dir
)

# Servir arquivos estáticos
server.mount('/', WEBrick::HTTPServlet::FileHandler, public_dir)

# Endpoint SSE para comunicação em tempo real com anti-loop
$last_conn = {}
$last_conn_m = Mutex.new
server.mount_proc '/events' do |req, res|
  # Extrair o ID do cliente dos parâmetros da consulta
  query = req.query
  client_id = query['clientId'] || "anonymous-#{SecureRandom.uuid}"
  timestamp = query['t'] || Time.now.to_i
  
  # Anti-loop: verificar timestamps de reconexão muito frequentes (global)
  now = Time.now.to_i
  last_connection_time = $last_conn_m.synchronize { $last_conn[client_id] }
  if last_connection_time && (now - last_connection_time < 2)
    puts "[SSE SERVER] Reconexão muito frequente detectada para #{client_id}, bloqueando brevemente..."
    res.status = 429
    res['Retry-After'] = '5'
    res.body = "Too many reconnections, please wait a few seconds"
    return
  end
  $last_conn_m.synchronize { $last_conn[client_id] = now }
  
  # Verificar se este cliente já tem uma conexão
  if (old_queue = $sse_clients.delete(client_id))
    puts "[SSE SERVER] Cliente duplicado: #{client_id} — descartando fila antiga"
  end
  
  # Configurar headers para SSE com streaming chunked
  res.chunked = true
  res['Content-Type'] = 'text/event-stream'
  res['Cache-Control'] = 'no-cache, no-transform'
  res['Connection'] = 'keep-alive'
  # Este header é crucial para evitar que o browser reconecte automaticamente muito rápido
  # A especificação SSE diz que browsers devem esperar pelo menos este tempo (em ms)
  res['X-Accel-Buffering'] = 'no'  # Para Nginx não bufferizar a resposta
  res['X-Pad'] = ''.ljust(2048, ' ')  # Preencher buffer inicial para browsers
  # Adicionar headers Cross-Origin para evitar problemas com browsers
  res['Access-Control-Allow-Origin'] = '*'
  res['Access-Control-Allow-Headers'] = 'Origin, X-Requested-With, Content-Type, Accept'

  # Cria uma fila Queue para eventos SSE
  queue = Queue.new
  # Adicionar metadados de timestamp para monitorar atividade
  queue.instance_variable_set(:@last_activity, Time.now)
  
  # Primeiro adicionamos a diretiva retry para o EventSource
  queue << "retry: 10000\n\n"
  
  # Usa nossa classe SSEBody completa que implementa todos os métodos necessários
  body = SSEBody.new(queue)
  res.body = body
  
  # Registrar este cliente pelo ID antes de enviar evento inicial
  $sse_clients[client_id] = queue
  
  # envia o evento inicial com ID do cliente
  queue << "data: {\"type\":\"connected\",\"clientId\":\"#{client_id}\",\"message\":\"SSE Connected\"}\n\n"
  
  puts "[SSE SERVER] Cliente conectado: #{client_id} (total: #{$sse_clients.size})"
  
  # Adicionar callback para quando a conexão for fechada (este bloco será executado quando o cliente desconectar)
  req.instance_variable_set(:@sse_client_id, client_id)
  
  # Thread para detectar desconexão por timeout
  Thread.new do
    begin
      # Esperar até que a conexão seja encerrada
      # O WEBrick encerra a thread do handler quando a conexão é fechada
      while body.active?
        sleep 1
      end
    rescue => e
      puts "[SSE SERVER] Erro ao monitorar conexão: #{e.message}"
    ensure
      # Limpar quando a conexão for fechada
      if $sse_clients.key?(client_id) && $sse_clients[client_id] == queue
        $sse_clients.delete(client_id)
        puts "[SSE SERVER] Cliente desconectado: #{client_id} (total restante: #{$sse_clients.size})"
      end
    end
  end
end

# Translation endpoint using Ollama
server.mount_proc '/translate' do |req, res|
  payload = JSON.parse(req.body) rescue {}
  text    = payload['text'].to_s.strip
  dir     = payload['direction'] || 'en-to-pt'

  translation = OllamaClient.translate(text, dir)
  res['Content-Type'] = 'application/json'
  res.body = { translation: translation }.to_json
end

# Health check endpoint
server.mount_proc '/healthz' do |_req, res|
  res['Content-Type'] = 'application/json'
  res.body = { status: 'ok', sse_clients: $sse_clients.size }.to_json
end

# Send message to Slack endpoint
server.mount_proc '/send' do |req, res|
  payload = JSON.parse(req.body) rescue {}
  channel = payload['channel']
  text    = payload['text']

  slack_token = ENV['SLACK_BOT_USER_OAUTH_TOKEN']
  resp = HTTP.headers(
           'Authorization' => "Bearer #{slack_token}",
           'Content-Type'  => 'application/json'
         ).post('https://slack.com/api/chat.postMessage',
                json: { channel: channel, text: text })
  data = JSON.parse(resp.to_s)
  res['Content-Type'] = 'application/json'
  res.body = { ok: data['ok'], error: data['error'] }.to_json
end

# Função para enviar eventos SSE aos clientes
def send_sse_event(data)
  # Registrar clientes para remover em caso de erro
  clients_to_remove = []
  
  # Enviar para cada cliente usando sua queue
  $sse_clients.each_pair do |client_id, queue|
    begin
      # Atualizar timestamp de última atividade
      queue.instance_variable_set(:@last_activity, Time.now)
      
      # Enviar dados no formato SSE
      queue << "data: #{data.to_json}\n\n"
      puts "[SSE SERVER] Evento enviado para cliente: #{client_id}"
    rescue => e
      puts "[SSE SERVER] Erro ao enviar para cliente #{client_id}: #{e.message}"
      clients_to_remove << client_id
    end
  end
  
  # Remover clientes com erro
  clients_to_remove.each do |client_id|
    $sse_clients.delete(client_id)
    puts "[SSE SERVER] Cliente removido: #{client_id} (total restante: #{$sse_clients.size})"
  end
  
  # Log se nenhum cliente estiver disponível
  if $sse_clients.empty?
    puts "[SSE SERVER] Nenhum cliente SSE conectado para receber eventos"
  end
end

# Iniciar o servidor WEBrick em uma thread separada
server_thread = Thread.new do
  puts "[INIT] Servidor HTTP iniciado em http://localhost:#{port}"
  server.start
end

# Trap de interrupção para encerrar o servidor corretamente
trap('INT') { server.shutdown }

def attach_handlers(ws, token)
  ws.on :open do
    puts "[SLACK] WebSocket conectado com sucesso"
    $backoff = 1                 # reset back-off timer
  end

  ws.on :message do |msg|
    # 1. Filtrar pings triviais
    if msg.data.to_s.start_with?("Ping from")
      puts "[SLACK PING] #{msg.data}"
      next
    end

    data = JSON.parse(msg.data.to_s) rescue nil
    unless data
      puts "[SLACK ERROR] JSON inválido recebido"
      next
    end

    # ACK se houver envelope_id
    if (eid = data['envelope_id'])
      ws.send({ envelope_id: eid }.to_json)
    end

    case data['type']
    when 'disconnect'
      puts "[SLACK] Disconnect: #{data['reason']}"
      ws.close       # ‘close’ callback handles reconnection
    when 'events_api'
      handle_events_api(data)   # factor existing big block into a helper
    when 'hello'
      puts "[SLACK HELLO] Conexão estabelecida (app_id: #{data.dig('connection_info','app_id')})"
    end
  rescue => e
    puts "[SLACK ERROR] Erro ao processar mensagem: #{e.message}"
  end

  ws.on :error do |e|
    puts "[SLACK ERROR] #{e}"
  end

  ws.on :close do |e|
    puts "[SLACK CLOSE] WebSocket fechado: #{e}"
    $slack_ws = nil
    # Exponential back-off reconnection
    sleep $backoff
    $backoff = [$backoff * 2, 30].min
    puts "[SLACK] Reconnecting (back-off #{$backoff}s)…"
    start_socket(token)
  end
end

# Helper for events_api processing extracted from inline handler

def handle_events_api(data)
  payload = data['payload']
  puts "[SLACK DEBUG] Payload events_api: #{payload.keys.join(', ')}" if payload
  puts "[SLACK DEBUG] Evento completo: #{payload.to_json[0..300]}...(truncado)" if payload

  if payload && payload['event']
    event = payload['event']
    puts "[SLACK DEBUG] Tipo de evento recebido: #{event['type']}"
    if event['type'] == 'message'
      user_id = event['user']
      text = event['text']
      channel = event['channel']
      ts = event['ts']
      puts "[SLACK MSG] Canal: #{channel} | Usuário: #{user_id} | Texto: #{text}"
      if user_id && user_id.start_with?('U')
        profile = SlackUserService.fetch_user_profile(user_id)
        puts "[SLACK USER] Nome: #{profile['real_name']} | Avatar: #{profile['image_72']}"
        event_payload = {
          type:        data['type'],                   # tipo do evento
          envelope_id: data['envelope_id'],            # ID do envelope
          channel:     channel,
          user_id:     user_id,
          text:        text,
          profile: {
            real_name: profile['real_name'],
            avatar:    profile['image_72']
          },
          timestamp:   Time.at(ts.to_f).strftime("%H:%M"),
          reactions:   []
        }

        # Salvar no DB e enviar SSE
        Message.create(
          envelope_id: event_payload[:envelope_id],
          channel:     event_payload[:channel],
          user_id:     event_payload[:user_id],
          text:        event_payload[:text],
          real_name:   event_payload.dig(:profile, :real_name),
          avatar_url:  event_payload.dig(:profile, :avatar),
          timestamp:   event_payload[:timestamp]
        )
        puts "[DB] Mensagem salva no banco com ID ##{Message.last.id}"
        puts "[SLACK PAYLOAD] " + JSON.pretty_generate(event_payload)
        puts "[SSE TEST] Enviando evento: #{event_payload.to_json}"
        send_sse_event(event_payload)
      end
    end
  end
end

def start_socket(token)
  $ws_mutex.synchronize do
    return if $slack_ws && !$slack_ws.closed?
    url = open_socket_url(token)
    $slack_ws = WebSocket::Client::Simple.connect(url)
    attach_handlers($slack_ws, token)
    $backoff = 1  # reset on success
  end
end

puts "[INIT] Iniciando Slack Socket Mode"

# Obter token para Socket Mode
token = ENV.fetch('SLACK_APP_LEVEL_TOKEN')

begin
  start_socket(token)
  loop { sleep 1 }   # keep main thread alive
rescue => e
  puts "Erro ao obter URL: #{e.message}"
end