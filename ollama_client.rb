require 'http'
require 'json'

module OllamaClient
  HOST  = ENV.fetch('OLLAMA_HOST', 'http://localhost:11434')
  MODEL = ENV.fetch('OLLAMA_MODEL', 'llama3')

  # Simple blocking completion
  def self.translate(text, dir)
    prompt = case dir
             when 'en-to-pt' then "Translate to Brazilian Portuguese:\n\n\"#{text}\""
             when 'pt-to-en' then "Translate to English:\n\n\"#{text}\""
             else "Translate:\n\n\"#{text}\""
             end

    resp = HTTP.post("#{HOST}/api/generate",
                     json: { model: MODEL, prompt: prompt, stream: false })
    body = JSON.parse(resp.to_s)
    body['response'] || '⚠️ translation error'
  rescue => e
    puts "[OLLAMA] #{e.message}"
    '⚠️ translation error'
  end
end
