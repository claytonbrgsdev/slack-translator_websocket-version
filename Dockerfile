FROM ruby:3.2.2-slim

# Instalar dependências do sistema via apt-get
RUN apt-get update && \
    apt-get install -y build-essential sqlite3 libsqlite3-dev tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV PORT=4567

# Copiar Gemfile e instalar dependências
COPY Gemfile* ./
RUN gem install bundler && bundle install

# Criar diretório db e garantir permissões
RUN mkdir -p /app/db

# Copiar o resto dos arquivos
COPY . .

# Criar o banco de dados e executar migrations (se não existir)
RUN mkdir -p /app/db/migrations

EXPOSE 4567
CMD ["ruby", "server.rb"]
