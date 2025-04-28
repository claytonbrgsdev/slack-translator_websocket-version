require 'rake'
require 'net/http'
require 'socket'
require 'timeout'
require 'open3'
require 'uri'

namespace :sse do
  desc "Run smoke test to verify SSE endpoint is working"
  task :smoke do
    # Find an available port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    
    puts "Starting WEBrick server on port #{port} for smoke test..."
    
    # Create temporary log file
    log_file = "test_server.log"
    
    # Start server in a separate process
    pid = fork do
      ENV['PORT'] = port.to_s
      # Make sure server output is visible
      $stdout.sync = true
      $stderr.sync = true
      # Redirect output to the log file
      $stdout.reopen(File.new(log_file, "w"))
      $stderr.reopen($stdout)
      exec "ruby server.rb"
    end
    
    begin
      # Wait for server to start
      success = false
      server_up = false
      
      Timeout.timeout(5) do
        until server_up
          sleep 0.2
          begin
            # Just try to connect to the server
            Net::HTTP.get(URI.parse("http://localhost:#{port}/"))
            server_up = true
            puts "Server is up!"
          rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
            # Server still starting
          end
        end
        
        # Simple test - try to read directly from connection with a timeout
        puts "Testing SSE connection..."
        
        begin
          # We'll try to directly read from a socket connection
          socket = TCPSocket.new('localhost', port)
          
          # Write a basic HTTP request for the SSE endpoint
          socket.print "GET /events?clientId=smoke-test&t=#{Time.now.to_i} HTTP/1.1\r\n"
          socket.print "Host: localhost:#{port}\r\n"
          socket.print "Accept: text/event-stream\r\n"
          socket.print "Cache-Control: no-cache\r\n"
          socket.print "Connection: keep-alive\r\n\r\n"
          
          # Give the server a moment to respond
          sleep 0.5
          
          # Use a timeout to read
          response = ""
          Timeout.timeout(2) do
            # Read the response in small chunks until we find what we need
            while line = socket.read(1024)
              response += line
              puts "Received chunk: #{line.size} bytes"
              # If we've got what we need, we can stop
              break if response.include?(': init')
            end
          end
          
          # Check if we received the init message
          if response.include?(': init')
            puts "\u2705 SSE smoke test PASSED: Received expected init message"
            puts "Received:\n#{response.split("\r\n\r\n", 2).last}"
            success = true
          else
            puts "\u274c SSE smoke test FAILED: Did not receive init in response"
            puts "Response starts with: #{response[0..100].inspect}"
          end
        rescue => e
          puts "\u274c SSE smoke test FAILED: #{e.class}: #{e.message}"
        ensure
          socket.close rescue nil
        end
      end
      
      # Display server logs if the test failed
      unless success
        puts "\nServer logs:\n#{File.read(log_file)}" if File.exist?(log_file)
      end
      
      exit(success ? 0 : 1)
    rescue Timeout::Error
      puts "❌ SSE smoke test FAILED: Timed out waiting for server response"
      exit 1
    rescue => e
      puts "❌ SSE smoke test FAILED: #{e.message}"
      exit 1
    ensure
      # Clean up
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
      File.unlink("test_server.log") rescue nil
    end
  end
end

# Default task
task :default => ["sse:smoke"]
