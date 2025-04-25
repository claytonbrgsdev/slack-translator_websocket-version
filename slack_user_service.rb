require 'http'
require 'json'

# Serviço para buscar informações de perfil de usuários do Slack
module SlackUserService
  # Busca o perfil de um usuário do Slack pelo ID
  # @param user_id [String] ID do usuário no Slack
  # @return [Hash, nil] Objeto de perfil do usuário ou nil em caso de erro
  def self.fetch_user_profile(user_id)
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
