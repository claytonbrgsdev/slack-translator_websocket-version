# Dockerfile para aplicação Ruby sem frameworks
FROM ruby:3.2-alpine

# Definir diretório de trabalho
WORKDIR /app

# Copiar código da aplicação
COPY . .

# Comando padrão para executar o script principal (altere app.rb se necessário)
CMD ["ruby", "app.rb"]
