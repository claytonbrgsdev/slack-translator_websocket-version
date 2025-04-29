require 'http'
require 'json'

module OllamaClient
  HOST  = ENV.fetch('OLLAMA_HOST', 'http://localhost:11434')
  MODEL = ENV.fetch('OLLAMA_MODEL', 'llama3')

  # Simple blocking completion with retry logic and timing
  def self.translate(text, dir)
    retries = 0
    started = Time.now
    begin
      prompt = case dir
               when 'en-to-pt' then <<~TXT
                 You are a professional translator.
                 Translate ONLY the text between the quotes into Brazilian-Portuguese.
                 Return **just** the translation, no explanations.

                 "#{text}"
               TXT
               when 'pt-to-en' then <<~TXT
                 You are a professional translator.
                 Translate ONLY the text between the quotes into English.
                 Return **just** the translation, no explanations.

                 "#{text}"
               TXT
               else "Translate:\n\n\"#{text}\""
               end

      resp = HTTP.post("#{HOST}/api/generate",
                       json: { model: MODEL, 
                               prompt: prompt, 
                               stream: false, 
                               keep_alive: "5m" })
      body = JSON.parse(resp.to_s)
      elapsed = Time.now - started
      puts "[OLLAMA] Translation completed in #{elapsed.round(2)}s"
      
      if elapsed > 10
        puts "[OLLAMA] WARNING: Translation took more than 10 seconds"
      end
      
      body['response'] || '⚠️ translation error'
    rescue => e
      if (retries += 1) <= 1
        sleep 1 * retries
        puts "[OLLAMA] Retry #{retries}/1 after error: #{e.message}"
        retry
      else
        puts "[OLLAMA] failed after #{Time.now-started}s : #{e.message}"
        return '⚠️ translation unavailable'
      end
    end
  end
end
