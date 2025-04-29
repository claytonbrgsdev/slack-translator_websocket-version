require 'rake'
require 'net/http'
require 'socket'
require 'timeout'
require 'open3'
require 'uri'
require_relative 'models/user_profile'

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
      Timeout.timeout(8) do
        loop do
          sleep 0.5
          begin
            Net::HTTP.get(URI.parse("http://localhost:#{port}/"))
            break
          rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL, Errno::EINVAL
            # Server still starting
          end
        end
      end
      
      puts "Server is up! Testing SSE endpoint..."
      
      # Test the /events endpoint directly with Net::HTTP
      # We only care about verifying it returns the proper headers
      uri = URI("http://localhost:#{port}/events?clientId=smoke-test&t=#{Time.now.to_i}")
      
      # Make a request without reading the body
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 2
      http.read_timeout = 1  # Short timeout - we only need headers
      
      req = Net::HTTP::Get.new(uri)
      
      begin
        response = http.request(req) { |resp| break resp }
        
        # We're only validating the headers and response code
        if response.code == "200" && 
           response['Content-Type'] =~ /text\/event-stream/ && 
           response['Cache-Control'] =~ /no-cache/
          
          puts "✅ SSE smoke test PASSED!"
          puts "SSE endpoint returned correct headers:"
          puts "  Content-Type: #{response['Content-Type']}"
          puts "  Cache-Control: #{response['Cache-Control']}"
          puts "  Connection: #{response['Connection']}"
          
          # Check if /healthz shows an active client
          health_uri = URI("http://localhost:#{port}/healthz")
          health_response = Net::HTTP.get(health_uri)
          
          if health_response.include?("\"sse_clients\":1")
            puts "✅ /healthz correctly shows 1 active client"
          else
            puts "⚠️ /healthz doesn't show expected client count: #{health_response}"
          end
          
          exit 0
        else
          puts "❌ SSE smoke test FAILED: Incorrect response headers"
          puts "  Status code: #{response.code}"
          puts "  Content-Type: #{response['Content-Type'].inspect}"
          puts "  Cache-Control: #{response['Cache-Control'].inspect}"
          puts "  Connection: #{response['Connection'].inspect}"
          exit 1
        end
      rescue => e
        puts "❌ SSE smoke test FAILED: #{e.class}: #{e.message}"
        exit 1
      end
    rescue => e
      puts "❌ SSE smoke test FAILED: #{e.class}: #{e.message}"
      exit 1
    rescue Timeout::Error
      puts "❌ SSE smoke test FAILED: Timed out waiting for server response"
      exit 1
    rescue => e
      puts "❌ SSE smoke test FAILED: #{e.message}"
    ensure
      # Clean up
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
      File.unlink("test_server.log") rescue nil
    end
  end
end

namespace :cache do
  desc "Prune old user profiles from the cache (older than 7 days)"
  task :prune do
    puts "Pruning old user profiles..."
    count = UserProfile.prune_old_profiles
    puts "Removed #{count} old profile(s) from cache"
  end
  
  desc "List all cached user profiles"
  task :list do
    puts "Listing all cached user profiles:"
    count = 0
    UserProfile.all.each do |profile|
      age_hours = ((Time.now - profile.fetched_at) / 3600).round(1)
      puts "  User ID: #{profile.user_id}, fetched #{age_hours}h ago"
      count += 1
    end
    puts "Total: #{count} profile(s) in cache"
  end
end

# Default task
task :default => ["sse:smoke"]
