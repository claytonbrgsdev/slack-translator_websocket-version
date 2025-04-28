#!/usr/bin/env ruby
require 'json'
require 'dotenv'
require 'websocket-client-simple'
require_relative 'slack_socket'

# Carrega variáveis de ambiente
Dotenv.load

puts "[TEST] Iniciando teste de Socket Mode do Slack"

token = ENV.fetch('SLACK_APP_LEVEL_TOKEN')
puts "[TEST] Usando token: #{token[0..5]}...#{token[-4..-1]}"

begin
  url = open_socket_url(token)
  puts "[TEST] Obtida URL de conexão: #{url.split('?').first}"
  
  # Iniciar conexão WebSocket
  ws = WebSocket::Client::Simple.connect url

  ws.on :open do
    puts "[TEST] WebSocket aberto com sucesso"
  end

  ws.on :message do |msg|
    # Log completo de TUDO que é recebido, sem filtro
    if msg.data.to_s.start_with?("Ping from")
      puts "[TEST PING] #{msg.data}"
    else
      # Para eventos reais, fazer log do JSON completo
      puts "\n[TEST RECEIVED RAW] #{msg.data.to_s}"
      
      # Tentar fazer parse do JSON
      begin
        data = JSON.parse(msg.data.to_s)
        puts "[TEST RECEIVED PARSED] Tipo: #{data['type']}"
        
        # Se houver envelope_id, enviar ACK (importante)
        if data['envelope_id']
          ack = { envelope_id: data['envelope_id'] }.to_json
          ws.send(ack)
          puts "[TEST ACK] Envelope: #{data['envelope_id']}"
        end
        
        # Detalhes extras para events_api
        if data['type'] == 'events_api'
          payload = data['payload']
          puts "[TEST EVENTS_API] Payload keys: #{payload.keys.join(', ')}"
          
          if payload && payload['event']
            event = payload['event']
            puts "[TEST EVENT] Tipo: #{event['type']}"
            puts "[TEST EVENT] Conteúdo: #{event.to_json}"
          end
        end
      rescue => e
        puts "[TEST PARSE ERROR] #{e.message}"
      end
    end
  end

  ws.on :error do |e|
    puts "[TEST ERROR] #{e}"
  end

  ws.on :close do |e|
    puts "[TEST CLOSED] WebSocket fechado"
    exit(1)
  end
  
  puts "[TEST] Script rodando. Envie mensagens no Slack e veja os logs aqui."
  puts "[TEST] Use Ctrl+C para encerrar o teste."
  
  # Loop simple para manter o script rodando
  loop { sleep 1 }
  
rescue => e
  puts "[TEST ERROR] #{e.message}"
  puts "[TEST ERROR] #{e.backtrace.join("\n")}"
end
