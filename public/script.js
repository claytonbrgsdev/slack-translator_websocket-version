// Mock data for messages
const mockMessages = [
  {
    id: "1",
    text: "Good morning everyone! How's the project coming along?",
    translated: "Bom dia a todos! Como está o andamento do projeto?",
    user: {
      id: "user1",
      name: "John Smith",
      avatar: "JS"
    },
    timestamp: new Date(Date.now() - 3600000).toISOString(),
    isCurrentUser: false
  },
  {
    id: "2",
    text: "We're making good progress. The frontend is almost complete.",
    translated: "Estamos fazendo um bom progresso. O frontend está quase completo.",
    user: {
      id: "user2",
      name: "Maria Garcia",
      avatar: "MG"
    },
    timestamp: new Date(Date.now() - 1800000).toISOString(),
    isCurrentUser: false
  },
  {
    id: "3",
    text: "Great! I'll be reviewing the code this afternoon.",
    translated: "Ótimo! Vou revisar o código esta tarde.",
    user: {
      id: "user1",
      name: "John Smith",
      avatar: "JS"
    },
    timestamp: new Date(Date.now() - 900000).toISOString(),
    isCurrentUser: false
  },
  {
    id: "4",
    text: "Tenho trabalhado na integração da API. Deve estar pronto até amanhã.",
    translated: "I've been working on the API integration. Should be done by tomorrow.",
    user: {
      id: "current-user",
      name: "You",
      avatar: "YO"
    },
    timestamp: new Date(Date.now() - 600000).toISOString(),
    isCurrentUser: true
  },
  {
    id: "5",
    text: "Do we have the client meeting scheduled for Friday?",
    translated: "Temos a reunião com o cliente agendada para sexta-feira?",
    user: {
      id: "user3",
      name: "Alex Wong",
      avatar: "AW"
    },
    timestamp: new Date(Date.now() - 300000).toISOString(),
    isCurrentUser: false
  }
];

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
let messages = [...mockMessages];

// Initialize
document.addEventListener('DOMContentLoaded', () => {
  renderMessages();
  initEventListeners();
  
  // Check for saved theme preference
  const savedTheme = localStorage.getItem('theme');
  if (savedTheme === 'dark') {
    document.body.classList.add('dark-theme');
    document.body.classList.remove('light-theme');
    themeToggle.innerHTML = '<i class="fa-solid fa-sun"></i>';
    darkThemeToggle.checked = true;
  }
});

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
  if (messageInput.value.trim() === '') return;
  
  const newMessage = {
    id: Date.now().toString(),
    text: messageInput.value,
    translated: `English translation: ${messageInput.value}`,
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
  sendButton.disabled = true;
  
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

// Simulate receiving a new message every 45 seconds
setInterval(() => {
  const randomUsers = [
    { id: 'user1', name: 'John Smith', avatar: 'JS' },
    { id: 'user2', name: 'Maria Garcia', avatar: 'MG' },
    { id: 'user3', name: 'Alex Wong', avatar: 'AW' }
  ];
  
  const randomUser = randomUsers[Math.floor(Math.random() * randomUsers.length)];
  const randomTexts = [
    'Just checking in on the progress. Any updates?',
    'Has anyone reviewed the latest pull request?',
    'The client is very happy with our progress so far!',
    'I think we should schedule a team meeting tomorrow.',
    'Don\'t forget about the deadline next week.'
  ];
  
  const randomText = randomTexts[Math.floor(Math.random() * randomTexts.length)];
  const randomTranslation = `Tradução: ${randomText}`;
  
  const newMessage = {
    id: Date.now().toString(),
    text: randomText,
    translated: randomTranslation,
    user: randomUser,
    timestamp: new Date().toISOString(),
    isCurrentUser: false,
    isNew: true
  };
  
  messages = [...messages, newMessage];
  renderMessages();
  
  // Remove new badge after 5 seconds
  setTimeout(() => {
    messages = messages.map(msg => {
      if (msg.id === newMessage.id) {
        return { ...msg, isNew: false };
      }
      return msg;
    });
    renderMessages();
  }, 5000);
}, 45000);
