'use strict';

const OPENAI_TRANSCRIPTIONS_URL = 'https://api.openai.com/v1/audio/transcriptions';
const DEFAULT_STT_MODEL = 'gpt-4o-mini-transcribe';
const MAX_AUDIO_BYTES = parseInt(
  process.env.STT_MAX_AUDIO_BYTES || String(12 * 1024 * 1024),
  10,
);

class SttError extends Error {
  constructor(message, { code, status = 400 } = {}) {
    super(message);
    this.name = 'SttError';
    this.code = code;
    this.status = status;
  }
}

function normalizeLanguage(value) {
  const language = String(value || 'auto').trim().toLowerCase();
  if (language === 'zh' || language === 'en') return language;
  return 'auto';
}

function extensionForMime(mimeType) {
  const clean = String(mimeType || '').split(';')[0].trim().toLowerCase();
  if (clean === 'audio/mp4' || clean === 'audio/m4a') return 'm4a';
  if (clean === 'audio/wav' || clean === 'audio/wave') return 'wav';
  if (clean === 'audio/webm') return 'webm';
  if (clean === 'audio/mpeg' || clean === 'audio/mp3') return 'mp3';
  return 'm4a';
}

function requireOpenAiKey() {
  const key = String(process.env.OPENAI_API_KEY || '').trim();
  if (!key) {
    throw new SttError('OPENAI_API_KEY is not configured on the backend.', {
      code: 'STT_API_KEY_MISSING',
      status: 503,
    });
  }
  return key;
}

async function transcribeAudio({ buffer, mimeType, language }) {
  if (!Buffer.isBuffer(buffer) || buffer.length === 0) {
    throw new SttError('audio is required', { code: 'STT_AUDIO_REQUIRED' });
  }
  if (buffer.length > MAX_AUDIO_BYTES) {
    throw new SttError('audio is too large', {
      code: 'STT_AUDIO_TOO_LARGE',
      status: 413,
    });
  }

  const apiKey = requireOpenAiKey();
  const model = String(process.env.STT_MODEL || DEFAULT_STT_MODEL).trim();
  const normalizedLanguage = normalizeLanguage(language);
  const ext = extensionForMime(mimeType);
  const form = new FormData();
  form.append('model', model);
  form.append(
    'file',
    new Blob([buffer], { type: mimeType || 'audio/mp4' }),
    `agentdeck-voice.${ext}`,
  );
  if (normalizedLanguage !== 'auto') {
    form.append('language', normalizedLanguage);
  }
  form.append(
    'prompt',
    'Transcribe developer voice input accurately. Preserve Chinese and English words, technical identifiers, code names, punctuation, and command-like text.',
  );

  const response = await fetch(OPENAI_TRANSCRIPTIONS_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
    body: form,
  });
  const text = await response.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch (_err) {
    // Keep raw response in the error below.
  }

  if (!response.ok) {
    const message =
      (json && json.error && json.error.message) ||
      text ||
      `OpenAI transcription failed (HTTP ${response.status}).`;
    throw new SttError(message, {
      code: 'STT_PROVIDER_ERROR',
      status: response.status,
    });
  }

  return {
    text: String((json && json.text) || '').trim(),
    model,
    language: normalizedLanguage,
  };
}

module.exports = {
  SttError,
  transcribeAudio,
};
