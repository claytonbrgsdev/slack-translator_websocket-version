document.getElementById('translate-form').addEventListener('submit', async function(e) {
  e.preventDefault();
  const text = document.getElementById('text').value;
  const resultDiv = document.getElementById('result');
  resultDiv.textContent = 'Traduzindo...';
  try {
    const response = await fetch('/translate', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ text })
    });
    const data = await response.json();
    if (data.translation) {
      resultDiv.textContent = data.translation;
    } else if (data.message) {
      resultDiv.textContent = data.message;
    } else if (data.error) {
      resultDiv.textContent = data.error;
    } else {
      resultDiv.textContent = 'Erro inesperado.';
    }
  } catch (err) {
    resultDiv.textContent = 'Erro ao conectar ao servidor.';
  }
});
