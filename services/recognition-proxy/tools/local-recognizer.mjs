#!/usr/bin/env node
// Local-only manual tester for the Bricky recognition pipeline.
//
// Talks to Azure OpenAI DIRECTLY, reusing the EXACT production system prompt
// and JSON validation (`recognizeWithOpenAI` from ../dist), so what you see
// here is what the iOS app would receive — WITHOUT needing a StoreKit
// entitlement token, the proxy, or a device.
//
// Two ways to use it:
//   1) Web UI:  node tools/local-recognizer.mjs           -> http://localhost:8787
//   2) CLI:     node tools/local-recognizer.mjs photo.jpg -> prints JSON
//
// Azure credentials are read from the environment ONLY (never stored). Pull the
// key straight from Key Vault so it never lands on disk, e.g.:
//
//   export AZURE_OPENAI_ENDPOINT="https://oai-brickvision-dev.openai.azure.com/"
//   export AZURE_OPENAI_DEPLOYMENT="gpt-4o"
//   export AZURE_OPENAI_API_VERSION="2024-08-01-preview"
//   export AZURE_OPENAI_API_KEY="$(az keyvault secret show \
//       --vault-name kv-brickvision-dev --name AzureOpenAI-ApiKey \
//       --query value -o tsv)"
//   node tools/local-recognizer.mjs
//
// Build the proxy first (`npm run build`) so ../dist exists.

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { recognizeWithOpenAI } from '../dist/src/openai.js';

const PORT = Number(process.env.PORT ?? 8787);

function readConfig() {
  const cfg = {
    endpoint: process.env.AZURE_OPENAI_ENDPOINT,
    apiKey: process.env.AZURE_OPENAI_API_KEY,
    deployment: process.env.AZURE_OPENAI_DEPLOYMENT,
    apiVersion: process.env.AZURE_OPENAI_API_VERSION ?? '2024-08-01-preview',
  };
  const missing = Object.entries(cfg)
    .filter(([, v]) => !v)
    .map(([k]) => k);
  if (missing.length > 0) {
    throw new Error(
      `Missing env: ${missing.join(', ')}. See the header of this file for the export commands.`,
    );
  }
  return cfg;
}

// Strip a data: URL prefix if present and return raw base64.
function toBase64(input) {
  const comma = input.indexOf(',');
  return input.startsWith('data:') && comma !== -1 ? input.slice(comma + 1) : input;
}

async function runCli(imagePath) {
  const config = readConfig();
  const bytes = await readFile(imagePath);
  const ext = extname(imagePath).toLowerCase();
  if (!['.jpg', '.jpeg', '.png', '.webp', '.gif'].includes(ext)) {
    console.error(`Unsupported image type: ${ext || '(none)'}`);
    process.exit(1);
  }
  const subjects = await recognizeWithOpenAI(bytes.toString('base64'), config);
  console.log(JSON.stringify({ subjects }, null, 2));
}

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Bricky Recognition — Local Tester</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    margin: 0; padding: 24px;
    background: #f5f5f7; color: #1d1d1f;
  }
  .wrap { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.sub { margin: 0 0 20px; color: #6e6e73; font-size: 13px; }
  #drop {
    border: 2px dashed #c7c7cc; border-radius: 12px; padding: 32px 16px;
    text-align: center; cursor: pointer; background: #fff; transition: border-color .15s, background .15s;
  }
  #drop.drag { border-color: #0a84ff; background: #eef6ff; }
  #drop input { display: none; }
  .hint { color: #6e6e73; font-size: 13px; margin-top: 8px; }
  button {
    margin-top: 16px; width: 100%; padding: 12px 16px; border: none; border-radius: 10px;
    background: #0a84ff; color: #fff; font-size: 15px; font-weight: 600; cursor: pointer;
  }
  button:disabled { opacity: .5; cursor: default; }
  img.preview { max-width: 100%; border-radius: 10px; margin-top: 16px; display: none; }
  .status { margin-top: 16px; font-size: 14px; }
  .card {
    background: #fff; border: 1px solid #e5e5ea; border-radius: 10px;
    padding: 12px 14px; margin-top: 10px;
  }
  .card .name { font-weight: 600; }
  .card .meta { color: #6e6e73; font-size: 12px; margin-top: 2px; }
  .conf { font-variant-numeric: tabular-nums; }
  pre {
    background: #1d1d1f; color: #e5e5ea; padding: 12px; border-radius: 10px;
    overflow:auto; font-size: 12px; margin-top: 16px;
  }
  .empty { color: #6e6e73; }
  @media (prefers-color-scheme: dark) {
    body { background: #000; color: #f5f5f7; }
    #drop { background: #1c1c1e; border-color: #3a3a3c; }
    #drop.drag { border-color: #0a84ff; background: #0a2540; }
    .card { background: #1c1c1e; border-color: #3a3a3c; }
    p.sub, .hint, .card .meta, .empty { color: #98989d; }
  }
</style>
</head>
<body>
  <div class="wrap">
    <h1>Bricky Recognition — Local Tester</h1>
    <p class="sub">Calls Azure OpenAI directly with the production prompt. No entitlement, no proxy, no device.</p>
    <label id="drop">
      <input type="file" id="file" accept="image/*" />
      <div>Drop an image here or click to choose</div>
      <div class="hint">JPEG / PNG / WebP — resized to 1024px before upload</div>
    </label>
    <img id="preview" class="preview" alt="preview" />
    <button id="go" disabled>Identify subjects</button>
    <div id="status" class="status"></div>
    <div id="results"></div>
  </div>
<script>
  const fileEl = document.getElementById('file');
  const drop = document.getElementById('drop');
  const preview = document.getElementById('preview');
  const go = document.getElementById('go');
  const statusEl = document.getElementById('status');
  const results = document.getElementById('results');
  let dataUrl = null;

  function loadFile(file) {
    if (!file || !file.type.startsWith('image/')) return;
    const reader = new FileReader();
    reader.onload = () => {
      // Downscale longest edge to 1024 to mirror the iOS app.
      const img = new Image();
      img.onload = () => {
        const max = 1024;
        const longest = Math.max(img.width, img.height);
        const ratio = longest > max ? max / longest : 1;
        const c = document.createElement('canvas');
        c.width = Math.round(img.width * ratio);
        c.height = Math.round(img.height * ratio);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        dataUrl = c.toDataURL('image/jpeg', 0.8);
        preview.src = dataUrl;
        preview.style.display = 'block';
        go.disabled = false;
        statusEl.textContent = '';
        results.innerHTML = '';
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  }

  fileEl.addEventListener('change', () => loadFile(fileEl.files[0]));
  ['dragover','dragenter'].forEach(e => drop.addEventListener(e, ev => { ev.preventDefault(); drop.classList.add('drag'); }));
  ['dragleave','drop'].forEach(e => drop.addEventListener(e, ev => { ev.preventDefault(); drop.classList.remove('drag'); }));
  drop.addEventListener('drop', ev => loadFile(ev.dataTransfer.files[0]));

  go.addEventListener('click', async () => {
    if (!dataUrl) return;
    go.disabled = true;
    statusEl.textContent = 'Calling Azure OpenAI…';
    results.innerHTML = '';
    try {
      const res = await fetch('/recognize', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ imageBase64: dataUrl }),
      });
      const json = await res.json();
      if (!res.ok) {
        statusEl.textContent = 'Error: ' + (json.error || res.status);
        return;
      }
      const subjects = json.subjects || [];
      statusEl.textContent = subjects.length
        ? subjects.length + ' subject(s) found'
        : 'No famous subjects identified (honest empty result).';
      for (const s of subjects) {
        const div = document.createElement('div');
        div.className = 'card';
        const pct = Math.round((s.confidence || 0) * 100);
        div.innerHTML =
          '<div class="name"></div>' +
          '<div class="meta"></div>' +
          '<div class="meta summary"></div>';
        div.querySelector('.name').textContent = s.name;
        div.querySelector('.meta').textContent =
          s.category + ' · ' + pct + '% confidence' + (s.location ? ' · ' + s.location : '');
        div.querySelector('.summary').textContent = s.summary || '';
        results.appendChild(div);
      }
      const pre = document.createElement('pre');
      pre.textContent = JSON.stringify(json, null, 2);
      results.appendChild(pre);
    } catch (e) {
      statusEl.textContent = 'Request failed: ' + e.message;
    } finally {
      go.disabled = false;
    }
  });
</script>
</body>
</html>`;

function startServer() {
  const config = readConfig(); // fail fast if creds are missing
  const server = createServer(async (req, res) => {
    if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(PAGE);
      return;
    }
    if (req.method === 'POST' && req.url === '/recognize') {
      try {
        const chunks = [];
        let total = 0;
        for await (const chunk of req) {
          total += chunk.length;
          if (total > 12 * 1024 * 1024) throw new Error('Image too large.');
          chunks.push(chunk);
        }
        const { imageBase64 } = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (!imageBase64) throw new Error('Missing imageBase64.');
        const subjects = await recognizeWithOpenAI(toBase64(imageBase64), config);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ subjects }));
      } catch (err) {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err?.message ?? 'Recognition failed.' }));
      }
      return;
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  });
  server.listen(PORT, '127.0.0.1', () => {
    console.log(`Bricky recognition tester: http://localhost:${PORT}`);
    console.log(`Azure OpenAI: ${config.endpoint} (deployment ${config.deployment})`);
    console.log('Press Ctrl+C to stop.');
  });
}

const arg = process.argv[2];
if (arg && arg !== '--serve') {
  await runCli(arg);
} else {
  startServer();
}
