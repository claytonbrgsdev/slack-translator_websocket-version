require 'http'
require 'websocket-client-simple'
require 'json'
require 'dotenv'

# Global variable to track the last time a message was received from Slack
# Usando variável global comum (não constante) para facilitar atualizações
$last_slack_message_at = Time.now

# Carrega variáveis de ambiente se estiver em desenvolvimento
Dotenv.load if ENV['RACK_ENV'] != 'production'

# Método para obter a URL do WebSocket usando apps.connections.open
# @param token [String] SLACK_APP_LEVEL_TOKEN para Socket Mode
# @return [String] URL do WebSocket
def open_socket_url(token)
  # Log token preview for debugging
  token_preview = token[0..5] + "…"
  puts "[SOCKET OPEN] Using SLACK_APP_LEVEL_TOKEN preview=#{token_preview}"
  resp = HTTP
    .headers('Content-Type' => 'application/x-www-form-urlencoded',
             'Authorization'  => "Bearer #{token}")
    .post('https://slack.com/api/apps.connections.open')
  # Log Slack API response status and body
  puts "[SOCKET OPEN] POST status=#{resp.status}"
  puts "[SOCKET OPEN] Response body=#{resp.to_s[0..500]}"
  body = JSON.parse(resp.to_s)
  # Log parsed Slack API result
  if body['ok']
    puts "[SOCKET OPEN] Connection URL=#{body['url']}"
  else
    puts "[SOCKET OPEN ERROR] Slack API error=#{body['error']}"
  end
  raise "Erro Slack: #{body['error']}" unless body['ok']
  body['url']
end

# Attach handlers to a Slack WebSocket connection.
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
        sleep 1
        if Time.now - last_activity >= ping_interval
          ping_payload = { type: 'ping', ts: Time.now.to_f }.to_json
          begin
            ws.send(ping_payload)
            puts "[SLACK PING] Sent ping at #{Time.now}"
            last_activity = Time.now
          rescue OpenSSL::SSL::SSLError => e
            puts "[SLACK PING ERROR] SSL error: #{e.message}"
            last_activity = Time.now
          rescue => e
            puts "[SLACK PING ERROR] #{e.class}: #{e.message}"
            last_activity = Time.now
          end
        end
      end
    rescue => e
      puts "[SLACK PING] Ping timer error: #{e.message}"
    end
  end
  ping_timer.abort_on_exception = true

  ws.on :message do |msg|
    # Update the global timestamp for watchdog monitoring
    $last_slack_message_at = Time.now
    
    # Only log raw message if it contains events_api
    if msg.data.include?('"type":"events_api"')
      puts "[SLACK RAW] #{msg.data.to_s[0..500]}"
    end

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
    code_info = e&.code.inspect rescue "N/A"
    reason_info = e&.reason.inspect rescue "N/A"
    puts "[SLACK CLOSE] Code: #{code_info}, Reason: #{reason_info}"
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
