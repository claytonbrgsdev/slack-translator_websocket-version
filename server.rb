require 'json'
require 'dotenv'
require_relative 'slack_socket'
require 'websocket-client-simple'
require_relative 'slack_user_service'
require_relative 'models/message'

# Carregar variáveis de ambiente
Dotenv.load

puts "[INIT] Iniciando Slack Socket Mode"

# Obter token para Socket Mode
token = ENV.fetch('SLACK_APP_LEVEL_TOKEN')

begin
  # 1. Iniciar conexão WebSocket com Slack Socket Mode
  url = open_socket_url(token)
  puts "[SLACK] Conectando à URL: #{url.split('?').first}..."  

  # Iniciar conexão WebSocket
  ws = WebSocket::Client::Simple.connect url

  ws.on :open do
    puts "[SLACK] WebSocket conectado com sucesso"
  end

  ws.on :message do |msg|
    # 1. Verificar se é uma mensagem de ping especial
    if msg.data.to_s.start_with?("Ping from")
      puts "[SLACK PING] #{msg.data}"
      next
    end
    
    begin
      # 2. Interpretar a mensagem como JSON
      data = JSON.parse(msg.data.to_s)
      
      # Log do tipo de evento recebido
      event_type = data['type']
      puts "[SLACK] Evento recebido: #{event_type}"
      
      # 3. Enviar ACK para o Slack se houver um envelope_id
      if data['envelope_id']
        envelope_id = data['envelope_id']
        ack = { envelope_id: envelope_id }.to_json
        ws.send(ack)
        puts "[SLACK ACK] Envelope: #{envelope_id}"
      end
      
      # 4. Processar evento baseado no tipo
      case event_type
      when 'hello'
        # Conexão inicial estabelecida
        app_id = data.dig('connection_info', 'app_id') || 'desconhecido'
        puts "[SLACK HELLO] Conexão estabelecida para app_id: #{app_id}"
        
      when 'events_api'
        # 5. Extrair dados dos eventos de mensagem
        payload = data['payload']
        event = payload['event']
        
        # Verificar se é uma mensagem
        if event['type'] == 'message'
          # Extrair campos essenciais
          user_id = event['user']
          text = event['text']
          channel = event['channel']
          ts = event['ts']
          
          # Log da mensagem recebida
          puts "[SLACK MSG] Canal: #{channel} | Usuário: #{user_id} | Texto: #{text}"
          
          if user_id && user_id.start_with?('U')
            profile = SlackUserService.fetch_user_profile(user_id)
            puts "[SLACK USER] Nome: #{profile['real_name']} | Avatar: #{profile['image_72']}"
            
            event_payload = {
              type:        event_type,                   # tipo do evento recebido
              envelope_id: envelope_id,                  # ID do envelope do Slack
              channel:     channel,                      # ID do canal
              user_id:     user_id,                      # ID do usuário
              text:        text,                         # texto da mensagem
              profile: {
                real_name: profile['real_name'],         # nome real do usuário
                avatar:    profile['image_72']           # URL da imagem 72px
              },
              timestamp:   Time.at(ts.to_f).strftime("%H:%M"),  # timestamp convertido para "HH:MM"
              reactions:   []                             # vazio por enquanto
            }
            
            # Salvar a mensagem no banco de dados
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
            
            # Em seguida, faça o log formatado:
            puts "[SLACK PAYLOAD] " + JSON.pretty_generate(event_payload)
          end
        end
      end
    rescue => e
      puts "[SLACK ERROR] Erro ao processar mensagem: #{e.message}"
    end
  end

  ws.on :error do |e|
    puts "[SLACK ERROR] Erro no WebSocket: #{e}"
  end

  ws.on :close do |e|
    puts "[SLACK CLOSE] WebSocket fechado: #{e}"
    puts "[SLACK] Tentando reconectar em 3 segundos..."
    sleep 3
    
    # Tentar reconectar (na produção, isso deve ter um limite de tentativas e backoff)
    url = open_socket_url(token)
    ws = WebSocket::Client::Simple.connect url
  end

  # Manter o script rodando para manter a conexão WebSocket
  puts "[SLACK] Socket mode iniciado e pronto para receber eventos"
  puts "[INFO] Use Ctrl+C para encerrar o programa"
  
  loop { sleep 1 }
rescue => e
  puts "Erro ao obter URL: #{e.message}"  # Log any error from Slack
end