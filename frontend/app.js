// ==============================================
// RAG Assistant - Frontend Application
// Replace API_GATEWAY_URL with your actual URL
// ==============================================

const CONFIG = {
  API_GATEWAY_URL: 'YOUR_API_GATEWAY_URL_HERE',  // e.g. https://abc123.execute-api.ap-south-1.amazonaws.com/prod
  S3_UPLOAD_URL: 'YOUR_S3_PRESIGNED_URL_ENDPOINT', // optional, for direct upload
  MAX_FILE_SIZE_MB: 50
};

// ---- State ----
let isLoading = false;

// ---- DOM References ----
const messagesContainer = document.getElementById('messagesContainer');
const questionInput = document.getElementById('questionInput');
const sendBtn = document.getElementById('sendBtn');
const statusIndicator = document.getElementById('statusIndicator');
const fileInput = document.getElementById('fileInput');
const uploadStatus = document.getElementById('uploadStatus');
const uploadBox = document.getElementById('uploadBox');

// ---- File Upload ----
fileInput.addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (file) handleFileUpload(file);
});

uploadBox.addEventListener('dragover', (e) => {
  e.preventDefault();
  uploadBox.classList.add('drag-over');
});

uploadBox.addEventListener('dragleave', () => {
  uploadBox.classList.remove('drag-over');
});

uploadBox.addEventListener('drop', (e) => {
  e.preventDefault();
  uploadBox.classList.remove('drag-over');
  const file = e.dataTransfer.files[0];
  if (file && file.type === 'application/pdf') {
    handleFileUpload(file);
  } else {
    showUploadStatus('Please drop a PDF file.', 'error');
  }
});

async function handleFileUpload(file) {
  if (file.size > CONFIG.MAX_FILE_SIZE_MB * 1024 * 1024) {
    showUploadStatus(`File too large. Maximum ${CONFIG.MAX_FILE_SIZE_MB}MB allowed.`, 'error');
    return;
  }

  showUploadStatus(`Uploading ${file.name}...`, 'loading');

  try {
    // Get pre-signed URL from your API, then upload to S3
    const presignedResponse = await fetch(`${CONFIG.API_GATEWAY_URL}/upload-url?filename=${encodeURIComponent(file.name)}`, {
      method: 'GET'
    });

    if (!presignedResponse.ok) throw new Error('Failed to get upload URL');

    const { upload_url, s3_key } = await presignedResponse.json();

    // Upload directly to S3
    const uploadResponse = await fetch(upload_url, {
      method: 'PUT',
      body: file,
      headers: { 'Content-Type': 'application/pdf' }
    });

    if (!uploadResponse.ok) throw new Error('Upload to S3 failed');

    showUploadStatus(`${file.name} uploaded! Indexing in background (~30s)...`, 'success');
    addSystemMessage(`Document "${file.name}" uploaded and being indexed. You can start asking questions in about 30 seconds.`);

  } catch (error) {
    // Fallback: show manual upload instructions
    showUploadStatus(`Upload via AWS Console: go to S3 bucket and upload ${file.name} manually.`, 'error');
    console.error('Upload error:', error);
  }
}

function showUploadStatus(message, type) {
  uploadStatus.textContent = message;
  uploadStatus.className = `upload-status ${type}`;
  uploadStatus.classList.remove('hidden');
}

// ---- Chat ----
function handleKeyDown(event) {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    sendQuestion();
  }
}

function autoResize(textarea) {
  textarea.style.height = 'auto';
  textarea.style.height = Math.min(textarea.scrollHeight, 120) + 'px';
}

function useExample(btn) {
  questionInput.value = btn.textContent;
  questionInput.focus();
  autoResize(questionInput);
}

async function sendQuestion() {
  const question = questionInput.value.trim();
  if (!question || isLoading) return;

  // Clear welcome message on first question
  const welcome = messagesContainer.querySelector('.welcome-message');
  if (welcome) welcome.remove();

  // Add user message
  addMessage('user', question);
  questionInput.value = '';
  questionInput.style.height = 'auto';

  // Show typing indicator
  const typingId = addTypingIndicator();
  setLoading(true);

  try {
    const response = await fetch(`${CONFIG.API_GATEWAY_URL}/query`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ question })
    });

    removeTypingIndicator(typingId);

    if (!response.ok) {
      const err = await response.json();
      throw new Error(err.error || `HTTP ${response.status}`);
    }

    const data = await response.json();
    addAIMessage(data.answer, data.sources || []);

  } catch (error) {
    removeTypingIndicator(typingId);
    addMessage('ai', `Error: ${error.message}. Make sure your API Gateway URL is configured in app.js.`, true);
  } finally {
    setLoading(false);
  }
}

function setLoading(loading) {
  isLoading = loading;
  sendBtn.disabled = loading;
  if (loading) {
    setStatus('Thinking...', 'loading');
  } else {
    setStatus('Ready', 'ready');
  }
}

function setStatus(text, type) {
  statusIndicator.textContent = text;
  statusIndicator.className = `status-indicator status-${type}`;
}

function addMessage(role, text, isError = false) {
  const div = document.createElement('div');
  div.className = 'message';
  div.innerHTML = `
    <div class="message-avatar ${role}-avatar">${role === 'user' ? '&#128100;' : '&#129302;'}</div>
    <div class="message-content">
      <div class="message-label">${role === 'user' ? 'You' : 'RAG Assistant'}</div>
      <div class="message-bubble ${role}-bubble${isError ? ' error' : ''}">${escapeHtml(text)}</div>
    </div>
  `;
  messagesContainer.appendChild(div);
  scrollToBottom();
  return div;
}

function addAIMessage(answer, sources) {
  const div = document.createElement('div');
  div.className = 'message';

  const sourcesHtml = sources.length > 0 ? `
    <div class="sources-section">
      <div class="sources-label">&#128269; Sources Used (${sources.length})</div>
      ${sources.map(s => `
        <div class="source-item">
          &#128196; ${escapeHtml(s.source)} &mdash; Pages: ${Array.isArray(s.pages) ? s.pages.join(', ') : s.pages}
          &mdash; <span class="source-score">Score: ${s.score}</span>
        </div>
      `).join('')}
    </div>` : '';

  div.innerHTML = `
    <div class="message-avatar ai-avatar">&#129302;</div>
    <div class="message-content">
      <div class="message-label">RAG Assistant</div>
      <div class="message-bubble ai-bubble">
        ${formatAnswer(answer)}
        ${sourcesHtml}
      </div>
    </div>
  `;
  messagesContainer.appendChild(div);
  scrollToBottom();
}

function addSystemMessage(text) {
  const div = document.createElement('div');
  div.style.cssText = 'text-align:center;padding:8px 0;font-size:12px;color:#6b7280;';
  div.textContent = text;
  messagesContainer.appendChild(div);
  scrollToBottom();
}

function addTypingIndicator() {
  const id = 'typing-' + Date.now();
  const div = document.createElement('div');
  div.id = id;
  div.className = 'message';
  div.innerHTML = `
    <div class="message-avatar ai-avatar">&#129302;</div>
    <div class="message-content">
      <div class="message-label">RAG Assistant</div>
      <div class="message-bubble ai-bubble">
        <div class="typing-indicator">
          <div class="typing-dot"></div>
          <div class="typing-dot"></div>
          <div class="typing-dot"></div>
        </div>
      </div>
    </div>
  `;
  messagesContainer.appendChild(div);
  scrollToBottom();
  return id;
}

function removeTypingIndicator(id) {
  const el = document.getElementById(id);
  if (el) el.remove();
}

function formatAnswer(text) {
  return text
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/\n\n/g, '</p><p>')
    .replace(/\n/g, '<br>')
    .replace(/^/, '<p>').replace(/$/, '</p>')
    .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
    .replace(/\*(.*?)\*/g, '<em>$1</em>');
}

function escapeHtml(text) {
  return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function scrollToBottom() {
  messagesContainer.scrollTop = messagesContainer.scrollHeight;
}

// ---- Init ----
window.addEventListener('load', () => {
  if (CONFIG.API_GATEWAY_URL === 'YOUR_API_GATEWAY_URL_HERE') {
    addSystemMessage('Configure your API Gateway URL in frontend/app.js to enable AI responses.');
  }
  questionInput.focus();
});
