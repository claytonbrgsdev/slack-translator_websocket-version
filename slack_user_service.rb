require 'http'
require 'json'
require_relative 'models/user_profile'

# Serviço para buscar informações de perfil de usuários do Slack
module SlackUserService
  # In-memory cache for current session (backed by persistent DB cache)
  @user_profiles = {}
  @profile_timestamps = {}
  @mem_mutex = Mutex.new  # For thread-safe access to in-memory cache
  MAX_MEM_CACHE = 1000    # Prevent unbounded growth in long-lived processes
  
  # Schedule daily cache pruning
  @prune_thread = Thread.new do
    loop do
      # Sleep until 3 AM
      now = Time.now
      target_hour = 3 # 3 AM
      seconds_until_3am = ((24 - now.hour + target_hour) % 24) * 3600 - now.min * 60 - now.sec
      
      puts "[PROFILE CACHE] Next pruning scheduled in #{(seconds_until_3am/3600.0).round(1)} hours"
      sleep seconds_until_3am
      
      # Prune old profiles
      begin
        count = UserProfile.prune_old_profiles
        puts "[PROFILE CACHE] Daily pruning complete: removed #{count} old profiles"
      rescue => e
        puts "[PROFILE CACHE] Error during pruning: #{e.message}"
      end
      
      # Sleep for a bit to avoid accidentally running twice
      sleep 300
    end
  end.tap { |t| t.abort_on_exception = true; t.name = 'avatar-prune' }
  # Busca o perfil de um usuário do Slack pelo ID
  # @param user_id [String] ID do usuário no Slack
  # @return [Hash, nil] Objeto de perfil do usuário ou nil em caso de erro
  def self.fetch_user_profile(user_id)
    # Step 1: Check the in-memory cache first (fastest) - with thread safety
    profile = nil
    @mem_mutex.synchronize do
      if @user_profiles[user_id] && @profile_timestamps[user_id]
        cache_age = Time.now - @profile_timestamps[user_id]
        if cache_age < 86400 # 24 hours in seconds
          puts "[SLACK USER] Using in-memory cache for: #{user_id} (age: #{(cache_age/3600).round(1)}h)"
          profile = @user_profiles[user_id]
        else
          puts "[SLACK USER] In-memory cache expired for: #{user_id} (#{(cache_age/3600).round(1)}h old)"
        end
      end
    end
    
    return profile if profile # Return the profile if found in memory cache
    
    # Step 2: Try the persistent DB cache
    begin
      if profile_data = UserProfile.get_profile(user_id)
        # Memoize the JSON parse result
        db_profile = profile_data
        # Refresh in-memory cache as well (thread-safe with LRU eviction)
        @mem_mutex.synchronize do
          # LRU eviction - remove oldest entry if cache is full
          if @user_profiles.size >= MAX_MEM_CACHE
            oldest_key = @profile_timestamps.min_by { |_, timestamp| timestamp }[0]
            @user_profiles.delete(oldest_key)
            @profile_timestamps.delete(oldest_key)
            puts "[PROFILE CACHE] LRU eviction: removed oldest user #{oldest_key} from memory cache"
          end
          
          @user_profiles[user_id] = db_profile
          @profile_timestamps[user_id] = Time.now
        end
        return db_profile
      end
    rescue => e
      puts "[SLACK USER] DB cache error: #{e.message}"
    end
    
    # Step 3: Fall back to Slack API
    puts "[SLACK USER] Buscando perfil para usuário: #{user_id}"
    
    begin
      # Construir a URL da API e os headers necessários
      url = "https://slack.com/api/users.info"
      headers = {
        "Authorization" => "Bearer #{ENV['SLACK_BOT_USER_OAUTH_TOKEN']}",
        "Content-Type" => "application/x-www-form-urlencoded"
      }
      
      # Fazer a requisição HTTP para a API do Slack
      response = HTTP.headers(headers).get(url, params: { user: user_id })
      
      # Verificar se a resposta foi bem-sucedida
      data = JSON.parse(response.body.to_s)
      
      if data['ok']
        # Logar as informações importantes do perfil
        user_profile = data['user']['profile']
        puts "[SLACK USER] Perfil encontrado: #{user_profile['real_name']} (#{user_profile['display_name']})"
        puts "[SLACK USER] Avatar URL: #{user_profile['image_72']}"
        
        # Update both in-memory and persistent cache
        @mem_mutex.synchronize do
          # LRU eviction - remove oldest entry if cache is full
          if @user_profiles.size >= MAX_MEM_CACHE
            oldest_key = @profile_timestamps.min_by { |_, timestamp| timestamp }[0]
            @user_profiles.delete(oldest_key)
            @profile_timestamps.delete(oldest_key)
            puts "[PROFILE CACHE] LRU eviction: removed oldest user #{oldest_key} from memory cache"
          end
          
          @user_profiles[user_id] = user_profile
          @profile_timestamps[user_id] = Time.now
        end
        
        # Save to persistent DB cache (non-blocking)
        Thread.new do
          begin
            UserProfile.save_profile(user_id, user_profile)
          rescue => e
            puts "[SLACK USER] Error saving profile to DB: #{e.message}"
          end
        end
        
        # Retornar o perfil completo do usuário
        return user_profile
      else
        # Logar o erro retornado pela API
        puts "[SLACK USER] Erro ao buscar perfil: #{data['error']}"
        return nil
      end
    rescue => e
      # Capturar e logar qualquer exceção durante a requisição
      puts "[SLACK USER] Exceção ao buscar perfil: #{e.message}"
      puts e.backtrace.join("\n")
      return nil
    end
  end
end
