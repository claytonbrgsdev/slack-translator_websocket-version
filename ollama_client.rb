require 'http'
require 'json'

module OllamaClient
  HOST  = ENV.fetch('OLLAMA_HOST', 'http://localhost:11434')
  MODEL = ENV.fetch('OLLAMA_MODEL', 'llama3')

  # Simple blocking completion with retry logic and timing
  def self.translate(text, flow, from_lang, to_lang)
    retries = 0
    started = Time.now
    dir_final = "#{from_lang}-to-#{to_lang}"
    flow_label = flow == 'slack-to-app' ? 'Slack → App' : 'App → Slack'
    puts "[OLLAMA] Flow=#{flow}, Direction=#{dir_final}, Text=#{text[0..30]}..."
    begin
      prompt = <<~TXT
        You are a professional translator (#{flow_label}).
        Translate ONLY the text between the quotes from #{from_lang.upcase} to #{to_lang.upcase}.
        Return just the polished translation, no explanations.
        
        Additional formatting rules:
        1. Ensure each sentence starts with uppercase and normal casing.
        2. Use exactly one space after punctuation; trim leading/trailing whitespace.
        3. Preserve paragraph breaks exactly.
        4. Use proper local punctuation (en dash, curved quotes “ ”, ellipsis …).
        5. In Portuguese, always include proper accents (ç, á, ã etc.).
        6. Preserve tone (formal/informal) per user’s style.
        7. Normalize exaggerated character repetitions (e.g. “helloooo” → “hello”).
        8. Do not include code tags, system metadata, or quotation marks around output.

        "#{text}"
      TXT

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
