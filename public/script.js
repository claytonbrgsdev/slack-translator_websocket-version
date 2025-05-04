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
let autoTranslateEnabled = false; // Auto-translate toggle state

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  renderMessages();
  initEventListeners();
  initSSEConnection(); // Iniciar conexão SSE com o servidor
  loadChannels(); // Carregar canais disponíveis do Slack e histórico de mensagens
  
  // Check for saved theme preference
  const savedTheme = localStorage.getItem('theme');
  if (savedTheme === 'dark') {
    document.body.classList.add('dark-theme');
    document.body.classList.remove('light-theme');
    themeToggle.innerHTML = '<i class="fa-solid fa-sun"></i>';
    darkThemeToggle.checked = true;
  }
  
  // Load saved Slack User ID if available
  const slackUserId = localStorage.getItem('slack_user_id');
  if (slackUserId) {
    document.getElementById('slack-user-id').value = slackUserId;
    console.log('[SETTINGS] Loaded Slack User ID from storage:', slackUserId);
  }
});

// Function to load available Slack channels
function loadChannels() {
  fetch('/channels')
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error ${response.status}`);
      }
      return response.json();
    })
    .then(data => {
      if (data.channels && Array.isArray(data.channels)) {
        // Get the channel select dropdown
        const channelSelect = document.getElementById('channel-select');
        
        // Clear existing options except the default
        while (channelSelect.options.length > 0) {
          channelSelect.remove(0);
        }
        
        // Add default option
        const defaultOption = document.createElement('option');
        defaultOption.value = '';
        defaultOption.textContent = 'Selecione um canal...';
        channelSelect.appendChild(defaultOption);
        
        // Sort channels alphabetically by name
        data.channels.sort((a, b) => a.name.localeCompare(b.name));
        
        // Add each channel to the dropdown
        data.channels.forEach(channel => {
          const option = document.createElement('option');
          option.value = channel.id;
          option.textContent = `#${channel.name}`;
          channelSelect.appendChild(option);
        });
        
        // Check if there's a saved channel preference
        const savedChannel = localStorage.getItem('selectedChannel');
        if (savedChannel) {
          channelSelect.value = savedChannel;
          
          // Load message history for the saved channel
          loadMessageHistory(savedChannel);
        }
        
        console.log(`[CHANNELS] Loaded ${data.channels.length} channels from Slack`);
      } else {
        console.error('[CHANNELS] Invalid response format:', data);
      }
    })
    .catch(error => {
      console.error('[CHANNELS] Error loading channels:', error);
      
      if (error.message.includes('403') || error.message.includes('missing_scope')) {
        showToast(
          'Permissão faltando',
          'O bot precisa dos escopos "channels:read" (públicos) e "groups:read" (privados). ' +
          'Reinstale o app no Slack e copie o novo token.',
          true
        );
      } else {
        showToast('Erro', 'Não foi possível carregar a lista de canais do Slack', true);
      }
    });
}

// Function to load message history for a channel
function loadMessageHistory(channelId, limit = 50) {
  if (!channelId) return;
  
  // Create a set to track processed message IDs
  const processedMessages = new Set(messages.map(msg => msg.id));
  
  fetch(`/history?channel=${channelId}&limit=${limit}`)
    .then(response => {
      if (!response.ok) {
        throw new Error(`HTTP error ${response.status}`);
      }
      return response.json();
    })
    .then(historyData => {
      if (Array.isArray(historyData)) {
        console.log(`[HISTORY] Received ${historyData.length} messages for channel ${channelId}`);
        
        // Process each message and add to messages array if not already present
        const newMessages = [];
        
        historyData.forEach(item => {
          if (item.type === 'slack_message' && item.data) {
            const messageData = item.data;
            
            // Create standard message object
            const historyMessage = {
              id: messageData.id,
              text: messageData.text || 'No text',
              user: {
                id: messageData.user?.id || 'unknown',
                name: messageData.user?.name || 'Unknown User',
                avatar: messageData.user?.avatar || (messageData.user?.name || 'UN').substring(0, 2).toUpperCase()
              },
              timestamp: messageData.timestamp,
              isCurrentUser: false,
              isNew: false
            };
            
            // Only add if not already in the messages array
            if (!processedMessages.has(historyMessage.id)) {
              processedMessages.add(historyMessage.id);
              newMessages.push(historyMessage);
            }
          }
        });
        
        // Add to the beginning of messages array to show older messages first
        if (newMessages.length > 0) {
          messages = [...newMessages.reverse(), ...messages];
          renderMessages();
          console.log(`[HISTORY] Added ${newMessages.length} new messages to UI`);
        }
      } else {
        console.error('[HISTORY] Invalid history data format:', historyData);
      }
    })
    .catch(error => {
      console.error('[HISTORY] Error loading message history:', error);
      showToast('Erro', 'Não foi possível carregar o histórico de mensagens', true);
    });
}

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
          
          // Try to parse the message as JSON
          if (event.data && event.data.startsWith('{')) {
            const data = JSON.parse(event.data);
            
            // Process Slack messages
            if (data.type === 'slack_message' && data.data) {
              const messageData = data.data;
              
              // Improved deduplication: Allow same messageId if timestamp differs by at least 5 seconds
              const dupe = messages.some(m => {
                if (m.id === messageData.id) {
                  // If we have timestamps, check time difference
                  if (m.timestamp && messageData.timestamp) {
                    const timeDiff = Math.abs(Date.parse(messageData.timestamp) - Date.parse(m.timestamp));
                    return timeDiff < 5000; // Considered duplicate only if less than 5 seconds apart
                  }
                  return true; // No timestamps to compare, consider duplicate
                }
                return false; // Different ID, not a duplicate
              });
              
              if (dupe) {
                console.log(`[SSE CLIENT] Ignoring similar message with ID: ${messageData.id} (within 5s window)`);
                return;
              }
              
              // Create message object
              const newMessage = {
                id: messageData.id || Date.now().toString(),
                text: messageData.text || 'No text',
                user: {
                  id: messageData.user?.id || 'unknown',
                  name: messageData.user?.name || 'Unknown User',
                  avatar: messageData.user?.avatar || (messageData.user?.name || 'UN').substring(0, 2).toUpperCase()
                },
                timestamp: messageData.timestamp || new Date().toISOString(),
                isCurrentUser: false,
                isNew: true
              };
              
              // Auto-translate if enabled
              if (autoTranslateEnabled && newMessage.text) {
                console.log('[AUTO-TRANSLATE] Translating message:', newMessage.text);
                const flow = document.getElementById('receive-options').dataset.flow;
                const fromLang = getReceiveFromLang();
                const toLang = getReceiveToLang();
                fetchTranslation(newMessage.text, flow, fromLang, toLang)
                  .then(result => {
                    // Extract actual text from result object or fallback to raw result
                    const translatedText = (result && result.translation) ? result.translation : result;
                    newMessage.translated = translatedText;
                    // Update in messages array
                    const index = messages.findIndex(m => m.id === newMessage.id);
                    if (index !== -1) {
                      messages[index].translated = translatedText;
                      renderMessages();
                    }
                  })
                  .catch(error => {
                    console.error('[AUTO-TRANSLATE] Error:', error);
                  });
              }
              
              // Add to messages array
              messages.unshift(newMessage);
              
              // Only keep the latest 50 messages
              if (messages.length > 50) {
                messages = messages.slice(0, 50);
              }
              
              // Render updated messages
              renderMessages();
            }
          }
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
          return; // Skip already processed messages
        }
        
        // Mark as processed
        processedMessages.add(messageId);
        
        // Create user object
        let userInfo = {
          id: 'unknown',
          name: 'Usuário Slack',
          avatar: 'US'
        };
        
        // Get user info if available
        if (data.user) {
          if (typeof data.user === 'string') {
            userInfo = {
              id: data.user,
              name: `Usuário ${data.user.slice(-4)}`,
              avatar: data.user.substring(0, 2).toUpperCase()
            };
          } else if (typeof data.user === 'object' && data.user !== null) {
            userInfo = {
              id: data.user.id || 'unknown',
              name: data.user.name || 'Usuário Slack',
              avatar: data.user.avatar || data.user.name?.substring(0, 2).toUpperCase() || 'US'
            };
          }
        }
        
        // Create message object
        const message = {
          id: messageId,
          text: data.text || 'Mensagem sem texto',
          translated: data.translated || null,
          timestamp: data.timestamp || new Date().toISOString(),
          user: userInfo,
          isCurrentUser: false,
          isNew: true
        };
        
        // Auto-translate if enabled and no translation already exists
        if (autoTranslateEnabled && message.text && !message.translated) {
          console.log('[AUTO-TRANSLATE] Translating message:', message.text);
          const flow = document.getElementById('receive-options').dataset.flow;
          const fromLang = getReceiveFromLang();
          const toLang = getReceiveToLang();
          fetchTranslation(message.text, flow, fromLang, toLang)
            .then(result => {
              const translatedText = (result && result.translation) ? result.translation : result;
              message.translated = translatedText;
              renderMessages(); // Update UI with translation
            })
            .catch(error => {
              console.error('[AUTO-TRANSLATE] Error:', error);
            });
        }
        
        // Add to messages array
        messages.unshift(message);
        
        // Limit array size
        if (messages.length > 50) {
          messages = messages.slice(0, 50);
        }
        
        // Render messages
        renderMessages();
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
async function fetchTranslation(
  text,
  flow = getFlow(),
  fromLang = getSendFromLang(),
  toLang = getSendToLang(),
  retryCount = 0
) {
  console.log('[DEBUG] Translation Params:', { 
    text: text.substring(0, 50) + (text.length > 50 ? '...' : ''),
    flow,
    fromLang, 
    toLang
  });
  try {
    console.log('[OUTGOING TRANSLATE]', { text, flow, fromLang, toLang });
    const response = await fetch('/translate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, flow, fromLang, toLang })
    });

    if (!response.ok) throw new Error(`HTTP error ${response.status}`);
    
    const data = await response.json();
    console.log('[DEBUG] Translation Response:', data);
    
    // Handle different response formats
    if (typeof data === 'string') {
      return { translation: data, direction: `${fromLang}-to-${toLang}` };
    } else if (data?.translation) {
      return data;
    } else if (data?.text) {
      return { translation: data.text, direction: data.direction || `${fromLang}-to-${toLang}` };
    } else {
      console.warn('[WARNING] Unexpected response format:', data);
      return { 
        translation: JSON.stringify(data),
        direction: `${fromLang}-to-${toLang}`,
        originalResponse: data
      };
    }
  } catch (error) {
    if (retryCount < 1) {
      console.log(`Retrying... (attempt ${retryCount + 1})`);
      await new Promise(resolve => setTimeout(resolve, 2000));
      return fetchTranslation(text, flow, fromLang, toLang, retryCount + 1);
    }
    throw error;
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
  translateButton.addEventListener('click', async () => {
    try {
      await previewTranslation();
    } catch (error) {
      console.error('Translation error:', error);
    }
  });
  
  // Confirm translation button
  document.getElementById('confirm-translation').addEventListener('click', sendConfirmedTranslation);
  
  // Cancel translation button
  document.querySelectorAll('#receive-options input, #send-options input')
  .forEach(radio => radio.addEventListener('change', () => {
    console.log('[SETTINGS] fromLang or toLang changed:', getSendFromLang(), getSendToLang());
    if (!translationPreview.classList.contains('hidden')) previewTranslation();
  }));
  
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

  });
  
  // Auto translate toggle
  const autoTranslateToggle = document.getElementById('auto-translate-toggle');
  autoTranslateToggle.addEventListener('change', (e) => {
    autoTranslateEnabled = e.target.checked;
    localStorage.setItem('autoTranslate', autoTranslateEnabled ? 'true' : 'false');
  });
  
  // Load auto-translate preference
  const savedAutoTranslate = localStorage.getItem('autoTranslate');
  if (savedAutoTranslate === 'true') {
    autoTranslateToggle.checked = true;
    autoTranslateEnabled = true;
  }
  
  // Save Slack User ID when it changes
  const slackUserIdInput = document.getElementById('slack-user-id');
  slackUserIdInput.addEventListener('change', (e) => {
    const userId = e.target.value.trim();
    if (userId) {
      localStorage.setItem('slack_user_id', userId);
      console.log('[SETTINGS] Saved Slack User ID:', userId);
      showToast('ID salvo', 'Seu ID de usuário do Slack foi salvo');
    } else {
      localStorage.removeItem('slack_user_id');
      console.log('[SETTINGS] Removed Slack User ID from storage');
    }
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
  
  // Highlight active channel when selected
  channelSelect.addEventListener('change', () => {
    highlightActiveChannel();
    
    // Save selected channel to localStorage
    const selectedChannel = channelSelect.value;
    if (selectedChannel) {
      localStorage.setItem('selectedChannel', selectedChannel);
      
      // Clear existing messages when channel changes
      messages = [];
      renderMessages();
      
      // Load message history for the newly selected channel
      loadMessageHistory(selectedChannel);
    } else {
      localStorage.removeItem('selectedChannel');
    }
  });
  
  // Initialize channel highlight
  highlightActiveChannel();
}

// Highlight currently selected channel
function highlightActiveChannel() {
  // Add active class to channel select
  channelSelect.classList.add('active');
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

// Helper function to fetch translation
function getReceiveFromLang() {
  const sel = document.querySelector('#receive-options input[name="receive-from-lang"]:checked');
  return sel ? sel.value : 'en';
}
function getReceiveToLang() {
  const sel = document.querySelector('#receive-options input[name="receive-to-lang"]:checked');
  return sel ? sel.value : 'pt';
}

function getSendFromLang() {
  const sel = document.querySelector('#send-options input[name="send-from-lang"]:checked');
  return sel ? sel.value : 'pt';
}
function getSendToLang() {
  const sel = document.querySelector('#send-options input[name="send-to-lang"]:checked');
  return sel ? sel.value : 'en';
}

function getFlow() {
  const container = document.querySelector('#send-options').dataset.flow;
  return container;
}

// Store the current translation for confirmation
let currentTranslation = {
  original: '',
  translated: '',
  direction: '',
  channel: ''
};

// Preview translation
async function previewTranslation() {
  if (messageInput.value.trim() === '') return;
  
  // Add loading state
  translateButton.classList.add('loading');
  translateButton.disabled = true;
  
  // Texto a traduzir
  const text = messageInput.value.trim();
  
  // Definir fluxo e idiomas a partir das opções de envio
  const flow = document.getElementById('send-options').dataset.flow || 'app-to-slack';
  const fromLang = getSendFromLang();
  const toLang = getSendToLang();
  const direction = `${fromLang}-to-${toLang}`;
  
  const channel = channelSelect.value || 'general';

  // Armazenar valores no objeto global para envio posterior
  currentTranslation = {
    original: text,
    translated: '',
    direction,
    channel,
    flow,
    fromLang,
    toLang
  };

  fetchTranslation(text, flow, fromLang, toLang)
    .then(data => {
      currentTranslation.translated = data.translation;
      // Display translation preview
      previewText.textContent = data.translation;
      translationPreview.classList.remove('hidden');
      
      // Remove loading state
      translateButton.classList.remove('loading');
      translateButton.disabled = false;
      
      // Show send button in preview
      document.getElementById('confirm-translation').style.display = 'inline-flex';
      document.getElementById('cancel-translation').style.display = 'inline-flex';
    })
    .catch(error => {
      console.error('Error:', error);
      showErrorToast(`Failed to translate: ${error.message}`);
      
      // Remove loading state on error
      translateButton.classList.remove('loading');
      translateButton.disabled = false;
      
      // Show fallback translation - keep the original text but clearly indicate the error
      const errorText = direction === 'pt-to-en' ? 
        `Translation unavailable: ${text}` : 
        `Tradução indisponível: ${text}`;
      
      previewText.textContent = errorText;
      translationPreview.classList.remove('hidden');
      
      // Still allow the user to confirm if they want to
      currentTranslation.translated = text; // Use original as fallback
      document.getElementById('confirm-translation').style.display = 'inline-flex';
      document.getElementById('cancel-translation').style.display = 'inline-flex';
    });
}

// Send message - now just triggers translation preview
function sendMessage() {
  // Redirect to previewTranslation to show confirmation dialog
  previewTranslation();
}

// Send confirmed translation to Slack
function sendConfirmedTranslation() {
  if (!currentTranslation.translated) {
    showToast('Erro', 'Nenhuma tradução disponível para enviar', true);
    return;
  }

  const { original, translated, channel, flow, fromLang, toLang } = currentTranslation;

  // Add loading state to confirm button
  const confirmBtn = document.getElementById('confirm-translation');
  confirmBtn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Enviando...';
  confirmBtn.disabled = true;

  // Try to get user ID from localStorage or use a default
  const user_id = localStorage.getItem('slack_user_id') || 'current-user';

  // Debug log immediately before sending
  console.log('[OUTGOING SEND]', { channel, original, translated, user_id, flow, fromLang, toLang });

  fetch('/send', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      channel:    channel,
      original:   original,
      translated: translated,
      user_id:    user_id,
      flow:       flow,
      fromLang:   fromLang,
      toLang:     toLang
    })
  })
  .then(response => response.json())
  .then(data => {
    console.log('[SLACK RESPONSE]', data);
    if (data.ok) {
      // Success handling (unchanged)
      const newMessage = {
        id: Date.now().toString(),
        text: original,
        translated: translated,
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
      // Reset UI state
      sendButton.disabled = true;
      confirmBtn.innerHTML = '<i class="fa-solid fa-check"></i> Confirmar e Enviar';
      confirmBtn.disabled = false;
      // Reset translation data
      currentTranslation = {
        original: '',
        translated: '',
        direction: '',
        channel: ''
      };
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
      // Error handling (unchanged)
      showToast('Erro', `Falha ao enviar: ${data.error || 'erro desconhecido'}`, true);
      // Reset button state
      confirmBtn.innerHTML = '<i class="fa-solid fa-check"></i> Confirmar e Enviar';
      confirmBtn.disabled = false;
    }
  })
  .catch(error => {
    console.error('[SEND ERROR]', error);
    showToast('Erro', 'Falha na comunicação com o servidor', true);
    // Reset button state (unchanged)
    confirmBtn.innerHTML = '<i class="fa-solid fa-check"></i> Confirmar e Enviar';
    confirmBtn.disabled = false;
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
  
  // Check if avatar is a URL (starts with http/https)
  if (typeof message.user.avatar === 'string' && message.user.avatar.match(/^https?:\/\//)) {
    // Create an image element for the avatar
    const avatarImg = document.createElement('img');
    avatarImg.src = message.user.avatar;
    avatarImg.alt = message.user.name;
    avatarImg.className = 'user-avatar-img';
    avatarEl.appendChild(avatarImg);
  } else {
    // Fallback to text initials if no valid URL is available
    avatarEl.textContent = typeof message.user.avatar === 'string' ? 
      message.user.avatar : 
      (message.user.name || 'UN').substring(0, 2).toUpperCase();
  }
  
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
  
  // Check if date is invalid (fix for "Invalid Date" issue)
  if (isNaN(date.getTime())) {
    // Fallback: if it's ISO-8601, extract time portion (11:16)
    if (typeof timestamp === 'string' && timestamp.includes('T')) {
      return timestamp.slice(11, 16);
    }
    // If it's already in HH:MM format, just return it
    return timestamp;
  }
  
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
function showToast(title, description, isError = false) {
  const toastTitle = document.getElementById('toast-title');
  const toastDescription = document.getElementById('toast-description');
  const toastIcon = toast.querySelector('.toast-content i');
  
  toastTitle.textContent = title;
  toastDescription.textContent = description;
  
  // Remove any existing classes first
  toast.classList.remove('hidden', 'error');
  
  // Add error class if specified
  if (isError) {
    toast.classList.add('error');
    // Change icon to warning for errors
    toastIcon.className = 'fa-solid fa-exclamation-circle';
  } else {
    // Use check icon for success
    toastIcon.className = 'fa-solid fa-check-circle';
  }
  
  // Show the toast
  toast.classList.remove('hidden');
  
  setTimeout(() => {
    toast.classList.add('hidden');
  }, 3000);
}

function showErrorToast(message) {
  showToast('Erro', message, true);
}
