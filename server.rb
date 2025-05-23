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

# Force un-buffered STDOUT for real-time logs
$stdout.sync = true

# Queue for processing Slack events asynchronously - unbounded to prevent stalls
EVENT_QUEUE = Queue.new

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
        if (info = $sse_clients.delete(client_id))
          info[:thread]&.kill
          puts "[SSE MONITOR] Cliente removido: #{client_id} (total: #{$sse_clients.size})"
        end
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

# Verify Ollama is running before proceeding
begin
  # Ollama doesn't have a /api/health endpoint, just check the root endpoint
  health = HTTP.get("#{OllamaClient::HOST}")
  raise unless health.status.success?
  puts "[INIT] ✅ Connected to Ollama at #{OllamaClient::HOST}"
rescue => e
  puts "[INIT] ⚠️ Cannot reach Ollama at #{OllamaClient::HOST} – proceeding without health-check"
  puts "[INIT] Error: #{e.message}"
  # Note: Not exiting, server will continue startup.
end

# Configurar o servidor WEBrick
port = ENV.fetch('PORT', '4567').to_i
public_dir = File.expand_path('public', __dir__)

server = WEBrick::HTTPServer.new(
  Port: port,
  DocumentRoot: public_dir,
  # Enable multi-threading to prevent blocking during long translations
  StartCallback: proc { puts "[WEBrick] Thread pool size: 10" },
  RequestCallback: proc { |req, res| },
  MaxClients: 10,
  DoNotReverseLookup: true
)

# Servir arquivos estáticos
server.mount('/', WEBrick::HTTPServlet::FileHandler, public_dir)

# Server-Sent Events endpoint with direct WEBrick streaming implementation
server.mount_proc '/events' do |req, res|
  # Extract client ID from query parameters
  query = req.query
  client_id = query['clientId'] || "anonymous-#{SecureRandom.uuid}"
  
  puts "[SSE] New connection from client: #{client_id} (IP: #{req.peeraddr[3]})"

  
  # Remove any existing connection for this client
  if $sse_clients.key?(client_id)
    puts "[SSE] Removing previous connection for client: #{client_id}"
    $sse_clients.delete(client_id)
  end
  
  # Set up SSE headers
  res.status = 200
  res.chunked = true
  res['Content-Type'] = 'text/event-stream'
  res['Cache-Control'] = 'no-cache, no-store'
  res['Connection'] = 'keep-alive'
  res['Access-Control-Allow-Origin'] = '*'
  res['X-Accel-Buffering'] = 'no'
  
  # Create a Queue for this client
  queue = Queue.new
  queue.instance_variable_set(:@client_id, client_id)
  queue.instance_variable_set(:@last_activity, Time.now)
  
  # Register client in global clients map with both queue and thread reference
  $sse_clients[client_id] = { queue: queue, thread: nil }
  
  # Create a pipe for streaming
  rd, wr = IO.pipe
  
  # Send initial SSE directives immediately via the pipe
  wr.write("retry: 10000\n\n")
  wr.write("id: #{Time.now.to_i}\n")
  wr.write("data: {\"type\":\"connected\",\"clientId\":\"#{client_id}\",\"message\":\"SSE Connected\"}\n\n")
  wr.flush
  
  # Start a thread to monitor the queue and write events to the pipe
  writer = Thread.new do
    begin
      heartbeat_interval = 30 # increased to 30 seconds (still well within Chrome's timeout)
      last_heartbeat = Time.now
      
      loop do
        # Try to get an event from the queue (BLOCKING mode)
        begin
          # Use select with timeout to handle both queue events and heartbeats
          # without spinning the CPU
          if queue.empty?
            # Check if we need to send a heartbeat
            if Time.now - last_heartbeat >= heartbeat_interval
              wr.write(": heartbeat\n\n")
              wr.flush
              last_heartbeat = Time.now
              puts "[SSE] Sent heartbeat to client #{client_id}"
            end
            sleep 0.5 # Short sleep, then check again
          else
            # Queue has an event, get it and send it immediately
            event = queue.pop # Blocking pop
            wr.write(event.to_s)
            wr.flush
            puts "[SSE] Sent event to client #{client_id}: #{event.to_s.bytesize} bytes"
          end
        rescue IOError, Errno::EPIPE => e
          # Connection closed by client
          puts "[SSE] Connection closed by client #{client_id}: #{e.message}"
          break
        end
        
        # Break if the pipe is closed
        break if wr.closed?
      end
    rescue => e
      puts "[SSE] Error in event thread for client #{client_id}: #{e.message}"
      puts e.backtrace.join("\n")
    ensure
      # Clean up
      wr.close unless wr.closed?
      $sse_clients.delete(client_id)
      puts "[SSE] Client disconnected: #{client_id} (remaining: #{$sse_clients.size})"
    end
  end
  
  # Store thread reference in client structure
  $sse_clients[client_id][:thread] = writer
  
  # Ensure thread cleanup when request is done
  req.instance_variable_set(:@sse_thread, writer)
  req.instance_variable_set(:@sse_writer, wr)
  
  # Set the response body to the pipe reader
  res.body = rd
  
  # Log connection
  puts "[SSE] Client connected: #{client_id} (total: #{$sse_clients.size})"
end

# Translation endpoint using Ollama
server.mount_proc '/translate' do |req, res|
  begin
    puts "[TRANSLATE] Received request: #{req.body.inspect}"

    # Parse request body
    payload = JSON.parse(req.body) rescue {}

    # Validate required parameters
    required_params = %w[text flow fromLang toLang]
    missing = required_params.select { |p| payload[p].nil? }
    unless missing.empty?
      puts "[TRANSLATE] Missing parameters: #{missing.join(', ')}"
      res.status = 400
      res['Content-Type'] = 'application/json'
      res.body = { error: "Missing parameters: #{missing.join(', ')}" }.to_json
      return
    end

    # Get translation from Ollama
    puts "[TRANSLATE] Calling Ollama service"
    translation_response = OllamaClient.translate(
      payload['text'],
      payload['flow'],
      payload['fromLang'],
      payload['toLang']
    )

    if translation_response.nil?
      puts "[TRANSLATE] Ollama returned empty response"
      res.status = 503
      res['Content-Type'] = 'application/json'
      res.body = { error: 'Translation service unavailable' }.to_json
      return
    end

    # Construct standardized response
    puts "[TRANSLATE] Successful translation"
    res['Content-Type'] = 'application/json'
    res.body = {
      translation: translation_response['translation'] || translation_response['text'] || translation_response.to_s,
      direction: "#{payload['fromLang']}-to-#{payload['toLang']}",
      timestamp: Time.now.iso8601
    }.to_json

  rescue => e
    puts "[TRANSLATE ERROR] #{e.message}\n#{e.backtrace.join("\n")}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body = {
      error: 'Translation failed',
      message: e.message,
      params: req.body,
      backtrace: (e.backtrace.first(3) if ENV['RACK_ENV'] == 'development')
    }.to_json
  end
end

# Health check endpoint
server.mount_proc '/healthz' do |_req, res|
  res['Content-Type'] = 'application/json'
  res.body = { status: 'ok', sse_clients: $sse_clients.size }.to_json
end

# Endpoint to fetch message history
server.mount_proc '/history' do |req, res|
  channel = req.query['channel']
  limit = (req.query['limit'] || '50').to_i
  limit = 50 if limit > 100 # Cap at 100 messages
  
  res['Content-Type'] = 'application/json'
  
  begin
    if channel.nil? || channel.empty?
      res.status = 400
      res.body = { error: 'Channel parameter is required' }.to_json
      return
    end
    
    # Query message history from database
    messages = Message.where(channel: channel)
                     .order(Sequel.desc(:id))
                     .limit(limit)
                     .all
    
    # Transform messages to frontend payload format
    frontend_messages = messages.map do |msg|
      {
        type: 'slack_message',
        data: {
          id: "#{msg.id}",
          text: msg.text,
          user: {
            id: msg.user_id,
            name: msg.real_name,
            avatar: msg.avatar_url
          },
          channel: msg.channel,
          timestamp: msg.timestamp,
          reactions: []
        }
      }
    end
    
    puts "[HISTORY] Returning #{messages.size} messages for channel #{channel}"
    res.body = frontend_messages.to_json
  rescue => e
    puts "[HISTORY] Error fetching message history: #{e.message}"
    res.status = 500
    res.body = { error: "Server error fetching message history: #{e.message}" }.to_json
  end
end

# Endpoint to fetch available Slack channels
server.mount_proc '/channels' do |_req, res|
  slack_token = ENV['SLACK_BOT_USER_OAUTH_TOKEN']
  
  # Debug log token (first few chars only)
  token_preview = slack_token ? "#{slack_token[0..5]}..." : "nil"
  puts "[SLACK API] Fetching channels with token: #{token_preview}"
  
  begin
    puts "[SLACK API] Making request to conversations.list API..."
    response = HTTP.auth("Bearer #{slack_token}")
                  .get('https://slack.com/api/conversations.list', 
                       params: { types: 'public_channel,private_channel' })
    
    puts "[SLACK API] Response status: #{response.status}"
    data = JSON.parse(response.to_s)
    
    if data['ok']
      channels = data['channels'].map do |channel|
        { id: channel['id'], name: channel['name'] }
      end
      
      puts "[SLACK API] Successfully fetched #{channels.length} channels"
      res['Content-Type'] = 'application/json'
      res.body = { channels: channels }.to_json
    else
      if data['error'] == 'missing_scope'
        needed = data['needed'] || 'unknown'
        provided = data['provided'] || 'none'
        puts "[SLACK API] Missing scope → needed: #{needed} | provided: #{provided}"
        res.status = 403
        res.body   = { error: 'missing_scope', needed: needed, provided: provided }.to_json
        next
      end
      
      puts "[SLACK API] Error fetching channels: #{data['error']}"
      res.status = 500
      res['Content-Type'] = 'application/json'
      res.body = { error: "Failed to fetch channels: #{data['error']}" }.to_json
    end
  rescue => e
    puts "[SLACK API] Exception fetching channels: #{e.message}"
    puts "[SLACK API] Backtrace: #{e.backtrace.join("\n")}"
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body = { error: "Server error fetching channels: #{e.message}" }.to_json
  end
end

# Send message to Slack endpoint
server.mount_proc '/send' do |req, res|
  begin
    payload = JSON.parse(req.body) rescue {}
    channel = payload['channel']
    original_text = payload['original'] || payload['text']
    translated_text = payload['translated']
    user_id = payload['user_id'] || ENV['SLACK_USER_ID'] # Get from payload or env variable as fallback
    
    # Extract flow and language parameters from the payload
    flow     = payload['flow'] || 'app-to-slack'
    from_lang = payload['fromLang'] || 'pt'
    to_lang   = payload['toLang'] || 'en'
    
    if translated_text.nil? || translated_text.strip.empty?
      # Fallback: translate on backend if not provided
      translated_text = OllamaClient.translate(original_text, flow, from_lang, to_lang)
      puts "[TRANSLATION FLOW] (Backend) Translated: #{original_text} → #{translated_text}"
    else
      puts "[TRANSLATION FLOW] (Frontend) Using provided translation: #{translated_text}"
    end
    puts "[TRANSLATION FLOW] ✅ Translation completed: #{original_text} → #{translated_text}"
    
    # Use the translated text for Slack
    text = translated_text
    
    # Log the full payload before sending
    puts "➡️ Sending payload to Slack: #{payload.to_json} (translated to: #{text})"
    
    # Use the user OAuth token instead of the bot token
    # This makes messages appear as coming directly from the user
    slack_token = ENV['SLACK_USER_OAUTH_TOKEN']
    
    # Check if we have a valid user token
    if slack_token && slack_token.start_with?('xoxp-')
      puts "[SLACK AUTH] Using user OAuth token for posting as the user"
      
      # When using user OAuth token, we don't need to set username or icon_url
      # as messages will appear as coming directly from the authenticated user
      message_params = { channel: channel, text: text }
    else
      # Fallback to bot token if user token is not available
      puts "[SLACK AUTH] User OAuth token not found, falling back to bot token"
      slack_token = ENV['SLACK_BOT_USER_OAUTH_TOKEN']
      
      # Prepare message parameters for bot posting
      message_params = { channel: channel, text: text }
      
      # If we have a user ID, fetch their profile to use their avatar
      if user_id && user_id.start_with?('U')
        begin
          profile = SlackUserService.fetch_user_profile(user_id)
          if profile
            puts "[SLACK USER] Using profile for outgoing message: #{profile['real_name']} | Avatar: #{profile['image_72']}"
            
            # Add icon_url to show the user's avatar in the message
            message_params[:icon_url] = profile['image_72']
            message_params[:username] = profile['real_name']
          end
        rescue => e
          puts "[SLACK USER] Error fetching profile for outgoing message: #{e.message}"
        end
      end
    end
    
    begin
      # Determine which API endpoint to use based on the token type
      api_endpoint = 'https://slack.com/api/chat.postMessage'
      
      # Log the API endpoint and token type being used (without exposing the actual token)
      token_type = slack_token.start_with?('xoxp-') ? 'user token' : 'bot token'
      puts "[SLACK API] Sending message using #{token_type} to #{api_endpoint}"
      
      # Add as_user=true parameter when using user token to ensure message appears as the user
      if slack_token.start_with?('xoxp-')
        message_params[:as_user] = true
      end
      
      # Send the request to Slack API
      resp = HTTP.headers(
              'Authorization' => "Bearer #{slack_token}",
              'Content-Type'  => 'application/json'
            ).post(api_endpoint,
                  json: message_params)
      
      # Log the response status and body
      data = JSON.parse(resp.to_s)
      puts "⬅️ Slack responded: status=#{resp.status}, body=#{resp.body}"
      
      # Log any error from Slack
      if data['ok'] == false
        puts "❌ Slack error: #{data['error']}"
      end
      
      res['Content-Type'] = 'application/json'
      res.body = { ok: data['ok'], error: data['error'] }.to_json
    rescue => e
      # Catch and log any network or timeout errors
      puts "❌ Exception sending to Slack: #{e.class}: #{e.message}"
      puts e.backtrace.join("\n")
      
      res['Content-Type'] = 'application/json'
      res.body = { ok: false, error: e.message }.to_json
    end
  rescue => e
    puts "❌ Unexpected error in /send endpoint: #{e.class}: #{e.message}"
    puts e.backtrace.join("\n")
    
    res['Content-Type'] = 'application/json'
    res.body = { ok: false, error: "Server error: #{e.message}" }.to_json
  end
end

# Function to send SSE events to all connected clients
def send_sse_event(data)
  return if $sse_clients.empty?
  
  event_data = "id: #{Time.now.to_i}\ndata: #{data.to_json}\n\n"
  clients_to_remove = []
  
  $sse_clients.each do |client_id, client_info|
    begin
      # Update last activity timestamp
      client_info[:queue].instance_variable_set(:@last_activity, Time.now)
      
      # Add event to client's queue
      client_info[:queue] << event_data
      puts "[SSE] Event queued for client #{client_id} (data type: #{data[:type]})"
    rescue => e
      puts "[SSE] Error sending to client #{client_id}: #{e.message}"
      clients_to_remove << client_id
    end
  end
  
  # Remove clients with errors
  clients_to_remove.each do |client_id|
    if (info = $sse_clients.delete(client_id))
      info[:thread]&.kill
    end
    puts "[SSE] Client removed due to error: #{client_id} (remaining: #{$sse_clients.size})"
  end
  
  # Log if no clients are available
  puts "[SSE] Event sent to #{$sse_clients.size} clients" if $sse_clients.any?
end


# Start event processing thread to handle Slack events
event_processor_thread = Thread.new do
  puts "[INIT] Iniciando thread de processamento de eventos"
  loop do
    begin
      data = EVENT_QUEUE.pop
      puts "[SLACK PROCESS] Processing event from queue"
      handle_events_api(data)
    rescue => e
      puts "[SLACK PROCESS ERROR] Erro ao processar evento da fila: #{e.message}"
      puts e.backtrace.join("\n")
    end
  end
end

# Helper method definitions
def start_socket(token)
  $ws_mutex.synchronize do
    # Don't try to reconnect if we already have an active connection
    return if $slack_ws && !$slack_ws.closed?
    
    # Force close any stale socket
    if $slack_ws
      begin
        $slack_ws.close
        puts "[SLACK] Closed stale socket connection"
      rescue => e
        puts "[SLACK] Error closing stale socket: #{e.message}"
      end
    end
    
    # Always get a fresh URL for each connection attempt
    begin
      url = open_socket_url(token)
      puts "[SLACK] Got fresh connection URL"
      
      # Connect with the new URL
      $slack_ws = WebSocket::Client::Simple.connect(url)
      puts "[SLACK] Created new WebSocket connection"
      
      # Attach handlers to the new connection
      attach_handlers($slack_ws, token)
      
      # We don't reset backoff here - we do it in the :open handler
      # to ensure it only happens on successful connection
    rescue => e
      puts "[SLACK] Connection error: #{e.message}"
      # Schedule another reconnection attempt after backoff
      Thread.new do
        sleep $backoff
        # Increase backoff with jitter, capped at 30s
        jitter_factor = 1.0 + rand(-0.2..0.2)
        $backoff = [($backoff * 2 * jitter_factor).round(1), 30].min
        puts "[SLACK] Retrying connection in #{$backoff}s..."
        start_socket(token)
      end
    end
  end
end

def attach_handlers(ws, token)
  ws.on :open do
    puts "[SLACK] WebSocket conectado com sucesso"
    puts "[SLACK OPEN] URL=#{ws.url}  Token=#{token[0..5]}…"
    $backoff = 1                 # reset back-off timer
  end

  # Initialize ping timer for this WebSocket connection
  ping_timer = nil
  last_activity = Time.now
  ping_interval = 10 # seconds
  
  # Set up ping timer to keep the connection alive
  ping_timer = Thread.new do
    puts "[SLACK PING] timer started (interval=#{ping_interval}s)"
    begin
      loop do
        puts "[SLACK PING] checking ping loop at #{Time.now}"
        sleep 1 # Check every second
        
        # Check if we need to send a ping
        if Time.now - last_activity >= ping_interval
          ping_payload = { type: 'ping', ts: Time.now.to_f }.to_json
          begin
            ws.send(ping_payload)
            puts "[SLACK PING] Sent ping at #{Time.now}"
            last_activity = Time.now
          rescue OpenSSL::SSL::SSLError => e
            puts "[SLACK PING ERROR] SSL error sending ping: #{e.message}"
            puts e.backtrace.join("\n")
            # Reset last_activity to ensure next ping is scheduled correctly
            last_activity = Time.now
          rescue => e
            puts "[SLACK PING ERROR] Unexpected error: #{e.class}: #{e.message}"
            puts e.backtrace.join("\n")
            # Reset last_activity to ensure next ping is scheduled correctly
            last_activity = Time.now
          end
        end
      end
    rescue => e
      puts "[SLACK PING] Ping timer error: #{e.message}"
      puts e.backtrace.join("\n")
    end
  end
  ping_timer.abort_on_exception = true
  
  ws.on :message do |msg|
    # Log raw WebSocket events to see exactly what Slack is sending
    puts "[SLACK RAW] #{msg.data.to_s[0..500]}"
    
    # Reset activity timer on any incoming message
    last_activity = Time.now
    
    # 1. Filtrar pings triviais
    if msg.data.to_s.start_with?("Ping from")
      puts "[SLACK PING] #{msg.data}"
      next
    end
    
    # === ultra-early ACK ========================================
    if msg.data.to_s =~ /"envelope_id":"([^"]+)"/
      eid = $1
      ws.send({ envelope_id: eid }.to_json)
      puts "[SLACK ACK] instant ACK for #{eid}"
    end
    # ===========================================================

    data = JSON.parse(msg.data.to_s) rescue nil
    unless data
      puts "[SLACK ERROR] JSON inválido recebido"
      next
    end


    # Process events in a separate thread via queue
    case data['type']
    when 'disconnect'
      reason = data.dig('reason') || 'unknown'
      retry_after = data.dig('retry', 'retry_after') || 5
      puts "[SLACK] Disconnect: #{reason} – retry in #{retry_after}s"
      puts "[SLACK DEBUG] Full disconnect payload: #{data.to_json}"
      
      # Kill the ping timer
      ping_timer.kill if ping_timer
      
      ws.close
      sleep retry_after
    when 'events_api'
      # Send to queue for async processing instead of processing immediately
      puts "[SLACK QUEUE] Queuing event for async processing"
      begin
        EVENT_QUEUE << data
      rescue ThreadError => e
        # Should never happen with an unbounded queue, but log just in case
        puts "[SLACK QUEUE] Push failed: #{e.message}"
      end
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
    if e.nil?
      puts "[SLACK CLOSE] Conexão fechada (sem detalhes disponíveis)"
    else
      puts "[SLACK CLOSE] Code: #{e.code.inspect}, Reason: #{e.reason.inspect}"
    end
    puts "[SLACK RECONNECT] scheduling reconnect in #{$backoff}s"
    $slack_ws = nil

    # Slack may still be cleaning up the previous socket – wait longer
    sleep $backoff
    
    # Exponential backoff with jitter (±20%)
    jitter_factor = 1.0 + rand(-0.2..0.2)
    $backoff = [($backoff * 2 * jitter_factor).round(1), 30].min   # back-off up to 30 s
    
    puts "[SLACK] Reconnecting in #{$backoff}s…"
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
        
        # Create message data in format expected by frontend
        message_data = {
          id: "#{ts}-#{user_id}",
          text: text,
          user: {
            id: user_id,
            name: profile['real_name'],
            avatar: profile['image_72']
          },
          channel: channel,
          timestamp: Time.at(ts.to_f).utc.iso8601,  # ISO-8601 for JS
          reactions: []
        }
        
        # Format payload in the structure expected by frontend
        frontend_payload = {
          type: 'slack_message',
          data: message_data
        }

        # Salvar no DB e enviar SSE
        Message.create(
          envelope_id: data['envelope_id'],
          channel:     channel,
          user_id:     user_id,
          text:        text,
          real_name:   profile['real_name'],
          avatar_url:  profile['image_72'],
          timestamp:   Time.at(ts.to_f).utc.iso8601  # ISO-8601 for JS
        )
        puts "[DB] Mensagem salva no banco com ID ##{Message.last.id}"
        puts "[SLACK PAYLOAD] " + JSON.pretty_generate(frontend_payload)
        puts "[SSE TEST] Enviando evento frontend: #{frontend_payload.to_json}"
        send_sse_event(frontend_payload)
      end
    end
  end
end

# ── STARTUP ──

# Trap de interrupção para encerrar o servidor corretamente (register before starting any threads)
trap('INT') do
  puts "[SHUTDOWN] Closing Slack socket"
  $slack_ws&.close if $slack_ws
  server.shutdown if server && server.status == :Running
  exit 0
end

# Special handling for smoke tests in CI
if ENV['CI'] == 'true'
  puts "[CI] Running in CI environment - enabling smoke test mode"
  
  # In CI, start health check endpoints but don't block on server_thread.join
  Thread.new do
    puts "[INIT] Servidor HTTP iniciado em http://localhost:#{port}"
    begin
      server.start
    rescue => e
      puts "[ERROR] Server error in CI mode: #{e.message}"
    end
  end
  
  # In CI, don't attempt to start Slack WebSocket
  puts "[SLACK] Skip WebSocket in CI environment"
  
  # Allow the server to start
  sleep 2
  puts "[CI] Server ready for smoke tests"
  
  # Keep alive only in normal run mode (not in CI)
  unless ENV['SMOKE_TEST'] == 'true'
    # Keep CI process alive but let smoke tests control the lifecycle
    sleep 30 
  end
else
  # Normal (non-CI) startup mode
  # 1) Launch WEBrick in the background
  server_thread = Thread.new do
    puts "[INIT] Servidor HTTP iniciado em http://localhost:#{port}"
    server.start
  end

  # 2) Conditionally start Slack Socket Mode (only if token is set)
  if ENV['SLACK_APP_LEVEL_TOKEN']
    slack_token = ENV.fetch('SLACK_APP_LEVEL_TOKEN')
    puts "[SLACK] Initializing Slack WebSocket…"
    start_socket(slack_token)
    
    # Start watchdog thread to monitor Slack connection activity
    unless defined? WATCHDOG_THREAD
      WATCHDOG_THREAD = Thread.new do
        loop do
          sleep 10
          if Time.now - $last_slack_message_at > 30
            puts "[WATCHDOG] Sem eventos do Slack por >30s, forçando reconnect"
            $slack_ws&.close
            start_socket(slack_token)
            $last_slack_message_at = Time.now
          end
        end
      end
      WATCHDOG_THREAD.abort_on_exception = true
      puts "[WATCHDOG] Thread de monitoramento iniciada"
    end
  else
    puts "[SLACK] No SLACK_APP_LEVEL_TOKEN provided, skipping Socket Mode startup."
  end
  
  # Wait for server to be ready
  sleep 0.5
  puts "[INIT] Server ready for connections"
  
  # 3) Wait for WEBrick to finish (this keeps the process alive)
  server_thread.join
end
