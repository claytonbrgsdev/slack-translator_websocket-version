// Configuração das mensagens do Slack e interação com o servidor

// DOM Elements
const originalMessagesList = document.getElementById('original-messages');
const translatedMessagesList = document.getElementById('translated-messages');
const messageInput = document.getElementById('message-input');
const sendButton = document.getElementById('send-btn');
const translateButton = document.getElementById('translate-btn');
const translationPreview = document.getElementById('translation-preview');
const previewText = document.getElementById('preview-text');
const settingsBtn = document.getElementById('settings-btn');
const settingsModal = document.getElementById('settings-modal');
const closeSettings = document.getElementById('close-settings');
const themeToggle = document.getElementById('theme-toggle');
const darkThemeToggle = document.getElementById('dark-theme-toggle');
const autoDetectToggle = document.getElementById('auto-detect');
const directionOptions = document.getElementById('direction-options');
const tabButtons = document.querySelectorAll('.tab-btn');
const tabContents = document.querySelectorAll('.tab-content');
const swapColumnsBtn = document.getElementById('swap-columns');
const toast = document.getElementById('toast');
const channelSelect = document.getElementById('channel-select');
const searchBtn = document.getElementById('search-btn');
const notificationsBtn = document.getElementById('notifications-btn');

// State
let columnsSwapped = false;
let messages = [];

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  renderMessages();
  initEventListeners();
  initSSEConnection(); // Iniciar conexão SSE com o servidor
  
  // Check for saved theme preference
  const savedTheme = localStorage.getItem('theme');
  if (savedTheme === 'dark') {
    document.body.classList.add('dark-theme');
    document.body.classList.remove('light-theme');
    themeToggle.innerHTML = '<i class="fa-solid fa-sun"></i>';
    darkThemeToggle.checked = true;
  }
});

// Variáveis globais para gerenciar a conexão SSE
let sseConnection = null;
let reconnectAttempts = 0;
let maxReconnectAttempts = 5;
let reconnectTimeout = null;
let connectionActive = false;
let connectionErrorOccurred = false;
let lastConnectionAttempt = 0;
let sessionId = Date.now() + '-' + Math.random().toString(36).substring(2, 10);

// Implementação definitiva para gerenciar conexão SSE e evitar loop
let setupSSE = () => {
  // Desativamos a função initSSEConnection original 
  // e substituímos por um EventSource único e controlado
  if (window._sseSetupComplete) {
    console.log('[SSE CLIENT] Configuração já realizada');
    return;
  }
  
  console.log('[SSE CLIENT] Configurando conexão SSE singular');
  window._sseSetupComplete = true;
  
  // Criar apenas uma instância de EventSource que será mantida enquanto a página estiver aberta
  try {
    // Adicionar timestamp para evitar cache do navegador
    const url = `/events?clientId=${sessionId}&t=${Date.now()}`;
    
    // Configurar objeto EventSource com retry time mais longo
    const eventSource = new EventSource(url);
    
    // Modificar o retry time padrão (que é curto demais em alguns navegadores)
    // Isso evita reconexões muito agressivas
    let origOnError = eventSource.onerror;
    eventSource.onerror = function(e) {
      // Chamamos o manipulador original
      if (origOnError) origOnError.call(this, e);
      
      // Log the error but let browser handle reconnect naturally
      console.warn('[SSE CLIENT] onerror', e);
      // Let the browser's native auto-reconnect handle it.
    };
    
    // Handler para quando a conexão for aberta
    eventSource.addEventListener('open', () => {
      console.log('[SSE CLIENT] Connection opened');
      connectionActive = true;
      lastConnectionAttempt = Date.now();
    });
    
    // Handler para receber mensagens (incluindo heartbeats)
    eventSource.addEventListener('message', (event) => {
      try {
        if (event.data.includes('heartbeat')) {
          console.log('[SSE CLIENT] Heartbeat recebido');
        } else {
          console.log('[SSE CLIENT] Received:', event.data);
          console.log('[SSE TEST] Recebido no cliente:', event.data);
        }
      } catch (e) {
        console.error('[SSE CLIENT] Erro ao processar mensagem:', e);
      }
    });
    
    // Armazenar referência global
    window.sseConnection = eventSource;
    console.log('[SSE CLIENT] Conexão EventSource criada e configurada com sucesso');
    
    // Adicionar evento para quando a página for fechada
    window.addEventListener('beforeunload', () => {
      console.log('[SSE CLIENT] Fechando conexão antes de sair da página');
      if (window.sseConnection) {
        window.sseConnection.close();
        window.sseConnection = null;
      }
    });
  } catch (e) {
    console.error('[SSE CLIENT] Erro fatal ao configurar EventSource:', e);
    window._sseSetupComplete = false;
  }
};

// Função para estabelecer conexão SSE (agora apenas chama setupSSE)
function initSSEConnection() {
  setupSSE();
}

// Implementação simplificada e robusta para eventos do Slack via SSE
function initSlackEventSource() {
  console.log('Iniciando fonte de eventos SSE');
  
  // Armazenar mensagens já processadas para evitar duplicações
  const processedMessages = new Set();
  
  try {
    // Criar conexão SSE
    const eventSource = new EventSource('/stream');
    
    // Manipular evento de conexão estabelecida
    eventSource.addEventListener('open', () => {
      console.log('Conexão SSE estabelecida');
    });
    
    // Manipular mensagens recebidas
    eventSource.addEventListener('message', (event) => {
      console.log('Evento SSE recebido:', event.data);
      
      try {
        // Tentar processar a mensagem como JSON
        const data = JSON.parse(event.data);
        
        // Verificar se é uma mensagem de status de conexão
        if (data.type === 'connected') {
          console.log('Status de conexão:', data.message);
          return;
        }
        
        // Gerar um ID único para a mensagem se não existir
        const messageId = data.id || `msg-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`;
        
        // Evitar processamento de mensagens duplicadas
        if (processedMessages.has(messageId)) {
          return;
        }
        processedMessages.add(messageId);
        
        // Limitar tamanho do cache de mensagens
        if (processedMessages.size > 100) {
          const entriesToRemove = processedMessages.size - 50;
          const iterator = processedMessages.values();
          for (let i = 0; i < entriesToRemove; i++) {
            processedMessages.delete(iterator.next().value);
          }
        }
        
        // Criar um objeto de mensagem com valores padrão seguros
        const message = {
          id: messageId,
          text: data.text || 'Mensagem sem texto',
          translated: data.translated || null,
          timestamp: data.timestamp || new Date().toISOString(),
          isCurrentUser: false,
          isNew: true,
          user: {
            id: 'unknown',
            name: 'Usuário Slack',
            avatar: 'US'
          }
        };
        
        // Processar informações do usuário com segurança
        if (data.user) {
          if (typeof data.user === 'string') {
            message.user = {
              id: data.user,
              name: `Usuário ${data.user.slice(-4)}`, 
              avatar: 'U'
            };
          } else if (typeof data.user === 'object' && data.user !== null) {
            message.user = {
              id: data.user.id || 'unknown',
              name: data.user.name || 'Usuário Slack',
              avatar: data.user.avatar || 'US'
            };
          }
        }
        
        // Só processar mensagens com texto
        if (data.text) {
          fetchTranslation(message);
        } else {
          console.log('Mensagem sem texto ignorada');
        }
      } catch (error) {
        console.error('Erro ao processar mensagem SSE:', error);
      }
    });
    
    // Manipular erros de conexão
    eventSource.addEventListener('error', (error) => {
      console.error('Erro na conexão SSE. Tentando reconectar...', error);
    });
    
    // Função global para testar o sistema SSE do console do navegador
    window.testSSE = async () => {
      try {
        const response = await fetch('/debug/send-test-event');
        if (response.ok) {
          console.log('Evento de teste SSE enviado');
          const data = await response.json();
          console.log('Resposta:', data);
        } else {
          console.error('Falha ao enviar evento de teste:', await response.text());
        }
      } catch (error) {
        console.error('Erro ao enviar evento de teste:', error);
      }
    };
    
    return eventSource;
  } catch (error) {
    console.error('Erro ao criar EventSource:', error);
    return null;
  }
}

// Função para traduzir mensagens
async function fetchTranslation(message) {
  try {
    const response = await fetch('/translate', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ text: message.text })
    });
    
    const data = await response.json();
    
    // Atualizar a mensagem com a tradução
    message.translated = data.translation || data.message || 'Erro ao traduzir';
    
    // Adicionar à lista de mensagens e renderizar
    messages = [...messages, message];
    renderMessages();
    
    // Remover a flag 'isNew' após alguns segundos
    setTimeout(() => {
      messages = messages.map(msg => {
        if (msg.id === message.id) {
          return { ...msg, isNew: false };
        }
        return msg;
      });
      renderMessages();
    }, 5000);
  } catch (err) {
    console.error('Erro ao traduzir mensagem:', err);
  }
}

// Event Listeners
function initEventListeners() {
  // Message input
  messageInput.addEventListener('input', () => {
    sendButton.disabled = messageInput.value.trim() === '';
  });
  
  // Send message
  sendButton.addEventListener('click', sendMessage);
  
  // Preview translation
  translateButton.addEventListener('click', previewTranslation);
  
  // Settings modal
  settingsBtn.addEventListener('click', () => {
    settingsModal.classList.remove('hidden');
  });
  
  closeSettings.addEventListener('click', () => {
    settingsModal.classList.add('hidden');
  });
  
  // Theme toggle
  themeToggle.addEventListener('click', toggleTheme);
  darkThemeToggle.addEventListener('change', (e) => {
    if (e.target.checked) {
      document.body.classList.add('dark-theme');
      document.body.classList.remove('light-theme');
      themeToggle.innerHTML = '<i class="fa-solid fa-sun"></i>';
    } else {
      document.body.classList.add('light-theme');
      document.body.classList.remove('dark-theme');
      themeToggle.innerHTML = '<i class="fa-solid fa-moon"></i>';
    }
    localStorage.setItem('theme', e.target.checked ? 'dark' : 'light');
  });
  
  // Auto detect toggle
  autoDetectToggle.addEventListener('change', (e) => {
    directionOptions.style.display = e.target.checked ? 'none' : 'block';
  });
  
  // Tab switching
  tabButtons.forEach(button => {
    button.addEventListener('click', () => {
      const tab = button.dataset.tab;
      
      // Update active tab button
      tabButtons.forEach(btn => btn.classList.remove('active'));
      button.classList.add('active');
      
      // Show active tab content
      tabContents.forEach(content => {
        content.classList.remove('active');
        if (content.id === `${tab}-tab`) {
          content.classList.add('active');
        }
      });
    });
  });
  
  // Swap columns
  swapColumnsBtn.addEventListener('click', () => {
    columnsSwapped = !columnsSwapped;
    renderMessages();
  });
  
  // Close modal when clicking outside
  window.addEventListener('click', (e) => {
    if (e.target === settingsModal) {
      settingsModal.classList.add('hidden');
    }
  });
  
  // Enter key to send message
  messageInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      if (messageInput.value.trim() !== '') {
        sendMessage();
      }
    }
  });
}

// Toggle theme
function toggleTheme() {
  const isDark = document.body.classList.contains('dark-theme');
  if (isDark) {
    document.body.classList.remove('dark-theme');
    document.body.classList.add('light-theme');
    themeToggle.innerHTML = '<i class="fa-solid fa-moon"></i>';
    darkThemeToggle.checked = false;
  } else {
    document.body.classList.add('dark-theme');
    document.body.classList.remove('light-theme');
    themeToggle.innerHTML = '<i class="fa-solid fa-sun"></i>';
    darkThemeToggle.checked = true;
  }
  localStorage.setItem('theme', isDark ? 'light' : 'dark');
}

// Preview translation
function previewTranslation() {
  if (messageInput.value.trim() === '') return;
  
  // Simulate translation
  const translatedText = `Tradução simulada para português: ${messageInput.value}`;
  previewText.textContent = translatedText;
  translationPreview.classList.remove('hidden');
}

// Send message
function sendMessage() {
  const text = messageInput.value.trim();
  if (text === '') return;
  
  // Get selected direction from settings
  const direction = document.getElementById('pt-to-en').checked ? 'pt-to-en' : 'en-to-pt';
  const channel = channelSelect.value || 'general';
  
  // Disable button while processing
  sendButton.disabled = true;
  
  // First get translation
  fetch('/translate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, direction })
  })
  .then(response => response.json())
  .then(data => {
    const translation = data.translation;
    
    // Now send to Slack
    return fetch('/send', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ channel, text: translation })
    });
  })
  .then(response => response.json())
  .then(data => {
    if (data.ok) {
      // Add to local messages
      const newMessage = {
        id: Date.now().toString(),
        text: text,
        translated: data.translation || `Translation sent to Slack`,
        user: {
          id: 'current-user',
          name: 'You',
          avatar: 'YO'
        },
        timestamp: new Date().toISOString(),
        isCurrentUser: true,
        isNew: true
      };
      
      messages = [...messages, newMessage];
      renderMessages();
      
      // Clear input and preview
      messageInput.value = '';
      translationPreview.classList.add('hidden');
      
      // Show toast notification
      showToast('Mensagem enviada', 'Sua mensagem foi traduzida e enviada com sucesso');
      
      // Remove new badge após 5 segundos
      setTimeout(() => {
        messages = messages.map(msg => {
          if (msg.id === newMessage.id) {
            return { ...msg, isNew: false };
          }
          return msg;
        });
        renderMessages();
      }, 5000);
    } else {
      showToast('Erro', `Falha ao enviar: ${data.error || 'erro desconhecido'}`);
      sendButton.disabled = false;
    }
  })
  .catch(error => {
    console.error('Error:', error);
    showToast('Erro', 'Falha na comunicação com o servidor');
    sendButton.disabled = false;
  });
}

// Render messages
function renderMessages() {
  originalMessagesList.innerHTML = '';
  translatedMessagesList.innerHTML = '';
  
  messages.forEach(message => {
    const originalMessageEl = createMessageElement(message, false);
    const translatedMessageEl = createMessageElement(message, true);
    
    if (columnsSwapped) {
      translatedMessagesList.appendChild(originalMessageEl);
      originalMessagesList.appendChild(translatedMessageEl);
    } else {
      originalMessagesList.appendChild(originalMessageEl);
      translatedMessagesList.appendChild(translatedMessageEl);
    }
  });
  
  // Scroll to bottom
  originalMessagesList.scrollTop = originalMessagesList.scrollHeight;
  translatedMessagesList.scrollTop = translatedMessagesList.scrollHeight;
}

// Create message elemento
function createMessageElement(message, showTranslated) {
  const messageEl = document.createElement('div');
  messageEl.className = `message ${message.isCurrentUser ? 'outgoing' : 'incoming'}`;
  
  const avatarEl = document.createElement('div');
  avatarEl.className = 'message-avatar';
  avatarEl.textContent = message.user.avatar;
  
  const contentEl = document.createElement('div');
  contentEl.className = 'message-content';
  
  const headerEl = document.createElement('div');
  headerEl.className = 'message-header';
  
  const userEl = document.createElement('span');
  userEl.className = 'message-user';
  userEl.textContent = message.user.name;
  
  const timeEl = document.createElement('span');
  timeEl.className = 'message-time';
  timeEl.textContent = formatTime(message.timestamp);
  
  headerEl.appendChild(userEl);
  headerEl.appendChild(timeEl);
  
  if (message.isNew) {
    const newBadge = document.createElement('span');
    newBadge.className = 'new-badge';
    newBadge.textContent = 'Nova';
    headerEl.appendChild(newBadge);
  }
  
  const bubbleEl = document.createElement('div');
  bubbleEl.className = 'message-bubble';
  bubbleEl.textContent = showTranslated ? message.translated : message.text;
  
  // Message actions
  const actionsEl = document.createElement('div');
  actionsEl.className = 'message-actions';
  
  const copyBtn = document.createElement('button');
  copyBtn.className = 'message-action-btn';
  copyBtn.innerHTML = '<i class="fa-solid fa-copy"></i>';
  copyBtn.title = 'Copiar texto';
  copyBtn.addEventListener('click', () => {
    navigator.clipboard.writeText(showTranslated ? message.translated : message.text);
    copyBtn.innerHTML = '<i class="fa-solid fa-check"></i>';
    setTimeout(() => {
      copyBtn.innerHTML = '<i class="fa-solid fa-copy"></i>';
    }, 2000);
  });
  
  actionsEl.appendChild(copyBtn);
  
  if (showTranslated) {
    const thumbsUpBtn = document.createElement('button');
    thumbsUpBtn.className = 'message-action-btn';
    thumbsUpBtn.innerHTML = '<i class="fa-solid fa-thumbs-up"></i>';
    thumbsUpBtn.title = 'Boa tradução';
    
    const thumbsDownBtn = document.createElement('button');
    thumbsDownBtn.className = 'message-action-btn';
    thumbsDownBtn.innerHTML = '<i class="fa-solid fa-thumbs-down"></i>';
    thumbsDownBtn.title = 'Tradução incorreta';
    
    actionsEl.appendChild(thumbsUpBtn);
    actionsEl.appendChild(thumbsDownBtn);
  }
  
  bubbleEl.appendChild(actionsEl);
  
  contentEl.appendChild(headerEl);
  contentEl.appendChild(bubbleEl);
  
  messageEl.appendChild(avatarEl);
  messageEl.appendChild(contentEl);
  
  return messageEl;
}

// Format time
function formatTime(timestamp) {
  const date = new Date(timestamp);
  const now = new Date();
  const diffMs = now - date;
  const diffMins = Math.round(diffMs / 60000);
  
  if (diffMins < 1) return 'agora';
  if (diffMins < 60) return `${diffMins}m atrás`;
  
  const diffHours = Math.floor(diffMins / 60);
  if (diffHours < 24) return `${diffHours}h atrás`;
  
  return date.toLocaleDateString();
}

// Show toast notification
function showToast(title, description) {
  const toastTitle = document.getElementById('toast-title');
  const toastDescription = document.getElementById('toast-description');
  
  toastTitle.textContent = title;
  toastDescription.textContent = description;
  
  toast.classList.remove('hidden');
  
  setTimeout(() => {
    toast.classList.add('hidden');
  }, 3000);
}

// Aqui será implementada a conexão com a API do Slack via WebSocket
