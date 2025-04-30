#!/usr/bin/env ruby
# test_slack_socket.rb - Slack Socket Mode reconnection test script
# This script tests automatic reconnection of Slack Socket Mode

require 'dotenv'
require 'websocket-client-simple'
require 'json'
require 'http'
require 'timeout'

# Load environment variables
Dotenv.load

# Fetch the Slack App token
token = ENV.fetch('SLACK_APP_LEVEL_TOKEN')

# Test channel to send messages to (default to general if not specified)
test_channel = ENV.fetch('TEST_CHANNEL', 'C04XXXXXXX') # Replace with your test channel ID

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

# Function to send test message via Slack API
def send_test_message(token, channel, text)
  puts "\n[TEST] Sending message to Slack: #{text}"
  
  resp = HTTP.auth("Bearer #{token}")
           .post("https://slack.com/api/chat.postMessage", 
                 json: {channel: channel, text: text})
  
  data = JSON.parse(resp.to_s)
  
  if data['ok']
    puts "[TEST] ✅ Message sent successfully: #{data['ts']}"
    return true
  else
    puts "[TEST] ❌ Failed to send message: #{data['error']}"
    return false
  end
end

# Variables for test coordination
$connection_count = 0
$received_hello = false
$test_completed = false
$test_success = false

# Main connection setup
url = open_socket_url(token)
puts "[TEST] Connecting to Slack WebSocket at #{url}"

# Get bot token for sending test messages
bot_token = ENV.fetch('SLACK_BOT_USER_OAUTH_TOKEN')

# Connect to WebSocket and attach handlers
ws = WebSocket::Client::Simple.connect(url)

# Set up ping timer
$ping_timer = Thread.new do
  loop do
    sleep 10
    begin
      next unless ws && !ws.closed?
      
      ping_payload = { type: 'ping', ts: Time.now.to_f }.to_json
      ws.send(ping_payload)
      puts "[TEST] Sent ping at #{Time.now}"
    rescue => e
      puts "[TEST] Ping error: #{e.message}"
    end
  end
end

# Setup auto-reconnection
$reconnecting = false

ws.on :open do
  $connection_count += 1
  puts "\n===== CONNECTION ESTABLISHED (#{$connection_count}) ====="
  puts "[TEST] Socket Mode connection successful"
  $reconnecting = false
end

ws.on :message do |msg|
  # Handle ping messages
  if msg.data.to_s.start_with?("Ping from")
    puts "[TEST] PING: #{msg.data}"
    next
  end
  
  # Parse and display raw event data
  data = JSON.parse(msg.data) rescue nil
  
  if data
    # ACK if there's envelope_id
    if data['envelope_id']
      ws.send({ envelope_id: data['envelope_id'] }.to_json)
      puts "[TEST] Sent ACK for envelope_id: #{data['envelope_id']}"
    end
    
    if data['type'] == 'hello'
      puts "[TEST] Received HELLO from app_id: #{data.dig('connection_info', 'app_id')}"
      $received_hello = true
      
      # If this is first connection or we're testing reconnection
      if $connection_count == 1 || ($connection_count > 1 && !$test_completed)
        # If we're on the second connection, this means we successfully reconnected
        if $connection_count > 1
          puts "\n[TEST] ✅ SUCCESSFULLY RECONNECTED! Sending second test message..."
          
          # Send second test message after reconnection
          if send_test_message(bot_token, test_channel, "Test message after reconnection #{Time.now}")
            puts "\n[TEST] 🎉 TEST PASSED! Auto-reconnection and message sending work properly"
            $test_success = true
            $test_completed = true
          end
        else
          # First connection - send first test message
          puts "\n[TEST] First connection established, sending test message..."
          send_test_message(bot_token, test_channel, "Test message before idle #{Time.now}")
          
          # Schedule the idle period
          Thread.new do
            puts "\n[TEST] Waiting 5 seconds to simulate idle period..."
            sleep 5
            puts "\n[TEST] Idle period completed. Socket should disconnect soon..."
          end
        end
      end
    end
  else
    puts "[TEST] Received non-JSON message: #{msg.data.to_s[0..100]}..."
  end
end

ws.on :error do |e|
  puts "\n===== ERROR ====="
  puts "[TEST] WebSocket error: #{e.message}"
  
  # Don't exit on error, let the reconnection logic handle it
end

ws.on :close do |e|
  puts "\n===== CONNECTION CLOSED ====="
  puts "[TEST] Code: #{e.code}, Reason: #{e.reason.inspect}"
  
  if !$reconnecting && !$test_completed
    $reconnecting = true
    puts "\n[TEST] Connection closed. Attempting to reconnect..."
    
    # Reconnect with exponential backoff
    delay = [1, 2, 5, 10].sample # Simple backoff for testing
    puts "[TEST] Reconnecting in #{delay} seconds..."
    
    Thread.new do
      sleep delay
      # Get fresh URL and reconnect
      begin
        url = open_socket_url(token)
        puts "[TEST] Got fresh connection URL"
        ws = WebSocket::Client::Simple.connect(url)
      rescue => e
        puts "[TEST] Reconnection failed: #{e.message}"
        exit 1
      end
    end
  elsif $test_completed
    # If test is completed, we can exit with success/failure
    puts "\n[TEST] Test completed, exiting with #{$test_success ? 'SUCCESS' : 'FAILURE'}"
    exit $test_success ? 0 : 1
  end
end

# Set test timeout (30 seconds)
Thread.new do
  sleep 30
  unless $test_completed
    puts "\n[TEST] ❌ Test timed out after 30 seconds"
    exit 1
  end
end

# Keep the script running until test completes
puts "[TEST] Running reconnection test (timeout: 30s)..."
begin
  loop do
    sleep 1
    if $test_completed
      puts "[TEST] Test completed with result: #{$test_success ? 'SUCCESS' : 'FAILURE'}"
      exit $test_success ? 0 : 1
    end
  end
rescue Interrupt
  puts "\n[TEST] Test interrupted"
  exit 1
end
