#!/usr/bin/env ruby
# test_slack_socket.rb - Simple Slack Socket Mode test script
# This script connects to Slack Socket Mode and logs all incoming events

require 'dotenv'
require 'websocket-client-simple'
require 'json'
require 'http'

# Load environment variables
Dotenv.load

# Fetch the Slack App token
token = ENV.fetch('SLACK_APP_LEVEL_TOKEN')

# Function to get WebSocket URL from Slack
def open_socket_url(token)
  resp = HTTP.headers('Authorization' => "Bearer #{token}").post('https://slack.com/api/apps.connections.open')
  data = JSON.parse(resp.to_s)
  
  if !data['ok']
    puts "Error: #{data['error']}"
    exit 1
  end
  
  data['url']
end

# Main connection setup
url = open_socket_url(token)
puts "Connecting to Slack WebSocket at #{url}"

# Connect to WebSocket and attach handlers
ws = WebSocket::Client::Simple.connect(url)

ws.on :open do
  puts "===== CONNECTION ESTABLISHED ====="
  puts "Socket Mode connection successful"
end

ws.on :message do |msg|
  # Skip ping messages for cleaner output
  if msg.data.to_s.start_with?("Ping from")
    puts "PING: #{msg.data}"
    next
  end
  
  # Parse and display raw event data
  data = JSON.parse(msg.data) rescue nil
  
  if data
    puts "\n===== NEW EVENT =====\n"
    puts "Type: #{data['type']}"
    
    # ACK if there's envelope_id
    if data['envelope_id']
      puts "Envelope ID: #{data['envelope_id']}"
      puts "Sending ACK..."
      ws.send({ envelope_id: data['envelope_id'] }.to_json)
    end
    
    # Detailed event debug
    if data['type'] == 'events_api' && data['payload'] && data['payload']['event']
      event = data['payload']['event']
      puts "Event Type: #{event['type']}"
      puts "Event Details: #{JSON.pretty_generate(event)}"
    elsif data['type'] == 'hello'
      puts "Connected to app_id: #{data.dig('connection_info', 'app_id')}"
    else
      puts "Raw Data: #{JSON.pretty_generate(data)}"
    end
  else
    puts "Received non-JSON message: #{msg.data.to_s[0..100]}..."
  end
end

ws.on :error do |e|
  puts "===== ERROR ====="
  puts e.message
end

ws.on :close do |e|
  puts "===== CONNECTION CLOSED ====="
  puts "Code: #{e.code}"
  puts "Reason: #{e.reason}"
  exit
end

# Keep the script running
puts "Listening for Slack events (Ctrl+C to quit)..."
loop { sleep 1 }
