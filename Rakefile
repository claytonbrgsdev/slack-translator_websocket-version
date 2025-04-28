require 'rake'
require 'net/http'
require 'socket'
require 'timeout'

namespace :sse do
  desc "Run smoke test to verify SSE endpoint is working"
  task :smoke do
    # Find an available port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    
    puts "Starting WEBrick server on port #{port} for smoke test..."
    
    # Start server in a separate process
    pid = fork do
      ENV['PORT'] = port.to_s
      # Redirect output to a temporary file
      $stdout.reopen(File.new("test_server.log", "w"))
      $stderr.reopen($stdout)
      exec "ruby server.rb"
    end
    
    begin
      # Wait for server to start
      Timeout.timeout(5) do
        begin
          sleep 0.1
          Net::HTTP.get(URI.parse("http://localhost:#{port}/"))
          puts "Server is up!"
          break
        rescue => e
          retry
        end
      end
      
      # Run curl to test SSE connection
      puts "Testing SSE connection..."
      
      # Use IO.popen to capture the curl output
      output = nil
      Timeout.timeout(3) do
        output = IO.popen("curl -s --no-buffer -N 'http://localhost:#{port}/events?clientId=smoke-test&t=#{Time.now.to_i}'", 'r') do |io|
          first_line = io.readline
          io.close_write
          first_line
        end
      end
      
      # Check if we got the expected output
      if output && output.start_with?(": init")
        puts "✅ SSE smoke test PASSED: Received expected init message"
        exit 0
      else
        puts "❌ SSE smoke test FAILED: Did not receive expected init message"
        puts "Received: #{output}"
        exit 1
      end
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
