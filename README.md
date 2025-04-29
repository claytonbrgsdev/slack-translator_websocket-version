# Slack Translator (WebSocket Version)

Real-time Slack message translator with WebSocket integration for Slack's Socket Mode API and Server-Sent Events (SSE) for frontend communication.

## Features

- Real-time Slack message streaming via WebSocket
- Message translation using Ollama
- Message persistence with SQLite/PostgreSQL
- Channel selection and persistence
- Message history loading
- Dark/light theme support

## Requirements

- Ruby 3.2.2+
- Docker (optional, for containerized deployment)
- Ollama (for translations)
- Slack Workspace and App with Socket Mode enabled

## Setup Instructions

### 1. Configure Slack App

1. Create a Slack App at https://api.slack.com/apps
2. Enable Socket Mode
3. Add the following Bot Token Scopes:
   - `channels:history`
   - `channels:read`
   - `chat:write`
   - `users:read`
4. Create an App-Level Token with `connections:write` scope
5. Install the app to your workspace
6. Copy your tokens to the `.env` file

### 2. Setup Environment

1. Copy the sample environment file
   ```bash
   cp .env.sample .env
   ```

2. Edit the `.env` file and add your Slack tokens:
   ```
   SLACK_APP_LEVEL_TOKEN=xapp-...
   SLACK_BOT_USER_OAUTH_TOKEN=xoxb-...
   ```

### 3. Setup Ollama (Plan B - Running on Host)

This application requires Ollama for translations. With this setup, Ollama runs on your host machine while the translator runs in Docker.

1. Install Ollama on your host machine: https://ollama.ai/download

2. Start Ollama:
   ```bash
   ollama serve
   ```

3. Pull the language model (first time only):
   ```bash
   ollama pull deepseek-r1:14b
   ```

### 4. Run the Application

#### Using Docker Compose (Recommended)

```bash
# Ensure Ollama is running on your host machine
ollama serve

# In a new terminal, start the translator service
docker-compose up --build translator
```

The application will be available at http://localhost:4567

#### Manual Setup (Without Docker)

1. Install dependencies:
   ```bash
   bundle install
   ```

2. Run database migrations:
   ```bash
   bundle exec sequel -m db/migrations sqlite://db/development.sqlite3
   ```

3. Start the server:
   ```bash
   ruby server.rb
   ```

## Usage

1. Open http://localhost:4567 in your browser
2. Select a channel from the dropdown
3. Messages will appear in real-time as they are posted to Slack
4. Click the translate button to see the translated version of a message
5. Use the settings menu to customize the translation direction and theme

## Architecture

- **Backend (Ruby):**
  - WebSocket client for Slack Socket Mode API
  - WEBrick server for static content and endpoints
  - SSE for real-time frontend communication
  - Message persistence via Sequel ORM

- **Frontend (JavaScript):**
  - EventSource for SSE connection
  - Dynamic channel selection
  - Message history loading
  - Theme customization

## Troubleshooting

- If no messages appear, ensure the Slack bot is invited to the channel (`/invite @SlackTranslator`)
- Check server logs for connection issues
- Verify Ollama is running on your host machine
- Ensure the Docker container can reach your host via `host.docker.internal`