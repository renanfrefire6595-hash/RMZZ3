// ==UserScript==
// @name         EggSniper — Auto-Steal Panel
// @namespace    karpa
// @version      1.0
// @match        *://*/*
// @grant        none
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  // ---- CONFIG — edit these for the target ----
  const CONFIG = {
    WS_URL: null,                    // null = hook all websockets
    STEAL_ENDPOINT: '/api/egg/steal', // POST path
    MIN_SCORE: 1500,                 // auto-steal threshold
    AUTO_STEAL: true,
    SCAN_INTERVAL_MS: 800,
    COOLDOWN_MS: 2200,               // respect server rate limit
    DRY_RUN: false                   // true = log only
  };

  const RARITY_WEIGHTS = {
    common: 1,
    uncommon: 2.5,
    rare: 6,
    epic: 15,
    legendary: 40,
    mythic: 100,
    secret: 250,
    event: 180
  };

  // ---- STATE ----
  const state = {
    eggs: new Map(),        // id -> { id, name, rarity, value, score, seenAt }
    lastSteal: 0,
    stolen: 0,
    failures: 0,
    paused: false,
    log: []
  };

  // ---- SCORING ----
  function scoreEgg(egg) {
    const w = RARITY_WEIGHTS[(egg.rarity || '').toLowerCase()] || 1;
    const v = Number(egg.value) || 0;
    // value dominates, rarity multiplies, small bonus for fresh listings
    const freshness = egg.seenAt ? Math.max(0, 1 - (Date.now() - egg.seenAt) / 60000) : 0;
    return Math.round((v * 0.7 + v * w * 0.3) * (1 + freshness * 0.1));
  }

  function ingestEgg(raw) {
    if (!raw || raw.id == null) return;
    const egg = {
      id: raw.id,
      name: raw.name || raw.id,
      rarity: raw.rarity || 'common',
      value: raw.value ?? raw.price ?? raw.worth ?? 0,
      seenAt: Date.now()
    };
    egg.score = scoreEgg(egg);
    const prev = state.eggs.get(egg.id);
    if (!prev || prev.score < egg.score) state.eggs.set(egg.id, egg);
  }

  // ---- WEBSOCKET HOOK (captures live listings) ----
  const NativeWS = window.WebSocket;
  window.WebSocket = function (url, protocols) {
    const ws = protocols ? new NativeWS(url, protocols) : new NativeWS(url);
    if (!CONFIG.WS_URL || url.includes(CONFIG.WS_URL)) {
      ws.addEventListener('message', (ev) => {
        try {
          const data = JSON.parse(ev.data);
          harvestEggs(data);
        } catch (_) {}
      });
    }
    return ws;
  };
  window.WebSocket.prototype = NativeWS.prototype;
  window.WebSocket.CONNECTING = 0;
  window.WebSocket.OPEN = 1;
  window.WebSocket.CLOSING = 2;
  window.WebSocket.CLOSED = 3;

  function harvestEggs(node) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach(harvestEggs); return; }
    // heuristic: object that looks like an egg
    if (node.id != null && (node.rarity || node.value != null || node.price != null)) {
      ingestEgg(node);
    }
    for (const k in node) if (typeof node[k] === 'object') harvestEggs(node[k]);
  }

  // ---- STEAL ACTION ----
  async function attemptSteal(egg) {
    if (state.paused) return;
    const now = Date.now();
    if (now - state.lastSteal < CONFIG.COOLDOWN_MS) return;
    if (egg.score < CONFIG.MIN_SCORE) return;

    state.lastSteal = now;
    pushLog(`🎯 steal ${egg.name} (${egg.rarity}) score=${egg.score} value=${egg.value}`);

    if (CONFIG.DRY_RUN) { state.stolen++; return; }

    try {
      const res = await fetch(CONFIG.STEAL_ENDPOINT, {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ eggId: egg.id })
      });
      if (res.ok) {
        state.stolen++;
        state.eggs.delete(egg.id);
        pushLog(`✅ stolen ${egg.name}`);
      } else {
        state.failures++;
        pushLog(`⚠️ fail ${egg.name} → ${res.status}`);
      }
    } catch (e) {
      state.failures++;
      pushLog(`❌ error ${egg.name}: ${e.message}`);
    }
  }

  // ---- AUTO-STEAL LOOP ----
  setInterval(() => {
    if (!CONFIG.AUTO_STEAL || state.paused) return;
    let best = null;
    for (const egg of state.eggs.values()) {
      if (!best || egg.score > best.score) best = egg;
    }
    if (best && best.score >= CONFIG.MIN_SCORE) attemptSteal(best);
  }, CONFIG.SCAN_INTERVAL_MS);

  // ---- UI PANEL ----
  function pushLog(msg) {
    state.log.unshift(`[${new Date().toLocaleTimeString()}] ${msg}`);
    if (state.log.length > 40) state.log.pop();
    renderLog();
  }

  const panel = document.createElement('div');
  panel.id = 'egg-sniper-panel';
  panel.innerHTML = `
    <div class="es-header">
      <span>🥚 EggSniper</span>
      <span class="es-badge" id="es-count">0 eggs</span>
    </div>
    <div class="es-controls">
      <label><input type="checkbox" id="es-auto" checked> Auto-Steal</label>
      <label>Min: <input type="number" id="es-min" value="${CONFIG.MIN_SCORE}" style="width:70px"></label>
      <button id="es-toggle">Pause</button>
      <button id="es-clear">Clear</button>
    </div>
    <div class="es-stats" id="es-stats">stolen: 0 · fails: 0</div>
    <div class="es-list" id="es-list"></div>
    <div class="es-log" id="es-log"></div>
  `;

  const style = document.createElement('style');
  style.textContent = `
    #egg-sniper-panel {
      position: fixed; top: 20px; right: 20px; width: 340px; max-height: 80vh;
      background: #0d1117; color: #c9d1d9; border: 1px solid #30363d; border-radius: 8px;
      font: 12px/1.4 ui-monospace, monospace; z-index: 2147483647;
      display: flex; flex-direction: column; box-shadow: 0 8px 24px rgba(0,0,0,.6);
      resize: both; overflow: hidden;
    }
    #egg-sniper-panel .es-header {
      padding: 8px 10px; background: #161b22; border-bottom: 1px solid #30363d;
      display: flex; justify-content: space-between; align-items: center; font-weight: 600;
      cursor: move;
    }
    #egg-sniper-panel .es-badge { background: #21262d; padding: 2px 8px; border-radius: 10px; font-size: 11px; }
    #egg-sniper-panel .es-controls {
      padding: 8px 10px; display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
      border-bottom: 1px solid #30363d;
    }
    #egg-sniper-panel .es-controls label { display: flex; align-items: center; gap: 4px; }
    #egg-sniper-panel .es-controls input[type=number] {
      background: #0d1117; color: #c9d1d9; border: 1px solid #30363d; border-radius: 4px; padding: 2px 4px;
    }
    #egg-sniper-panel button {
      background: #21262d; color: #c9d1d9; border: 1px solid #30363d; border-radius: 4px;
      padding: 3px 8px; cursor: pointer; font: inherit;
    }
    #egg-sniper-panel button:hover { background: #30363d; }
    #egg-sniper-panel .es-stats { padding: 6px 10px; font-size: 11px; color: #8b949e; border-bottom: 1px solid #30363d; }
    #egg-sniper-panel .es-list { flex: 1; overflow-y: auto; padding: 6px; max-height: 260px; }
    #egg-sniper-panel .es-row {
      padding: 4px 6px; margin-bottom: 3px; border-radius: 4px; background: #161b22;
      display: flex; justify-content: space-between; gap: 6px; border-left: 3px solid #30363d;
    }
    #egg-sniper-panel .es-row.hot { border-left-color: #f85149; background: #2d1517; }
    #egg-sniper-panel .es-row.mid { border-left-color: #d29922; }
    #egg-sniper-panel .es-row.low { border-left-color: #3fb950; }
    #egg-sniper-panel .es-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; }
    #egg-sniper-panel .es-score { color: #58a6ff; font-weight: 600; }
    #egg-sniper-panel .es-log {
      padding: 6px 10px; border-top: 1px solid #30363d; max-height: 120px; overflow-y: auto;
      font-size: 10px; color: #8b949e; background: #010409;
    }
    #egg-sniper-panel .es-log div { margin-bottom: 2px; }
  `;
  document.head.appendChild(style);
  document.body.appendChild(panel);

  // drag
  (function () {
    const h = panel.querySelector('.es-header');
    let dragging = false, ox = 0, oy = 0;
    h.addEventListener('mousedown', (e) => {
      dragging = true;
      ox = e.clientX - panel.getBoundingClientRect().left;
      oy = e.clientY - panel.getBoundingClientRect().top;
      panel.style.right = 'auto';
    });
    document.addEventListener('mousemove', (e) => {
      if (!dragging) return;
      panel.style.left = (e.clientX - ox) + 'px';
      panel.style.top = (e.clientY - oy) + 'px';
    });
    document.addEventListener('mouseup', () => { dragging = false; });
  })();

  function renderList() {
    const list = document.getElementById('es-list');
    const eggs = [...state.eggs.values()].sort((a, b) => b.score - a.score).slice(0, 30);
    list.innerHTML = eggs.map((e) => {
      const cls = e.score >= CONFIG.MIN_SCORE ? 'hot' : e.score >= CONFIG.MIN_SCORE * 0.5 ? 'mid' : 'low';
      return `<div class="es-row ${cls}" data-id="${e.id}">
        <span class="es-name">${e.name}</span>
        <span>${e.rarity}</span>
        <span class="es-score">${e.score}</span>
      </div>`;
    }).join('');
    list.querySelectorAll('.es-row').forEach((row) => {
      row.addEventListener('click', () => {
        const egg = state.eggs.get(row.dataset.id);
        if (egg) attemptSteal(egg);
      });
    });
    document.getElementById('es-count').textContent = `${state.eggs.size} eggs`;
    document.getElementById('es-stats').textContent =
      `stolen: ${state.stolen} · fails: ${state.failures} · ${state.paused ? 'PAUSED' : 'active'}`;
  }

  function renderLog() {
    const el = document.getElementById('es-log');
    el.innerHTML = state.log.map((l) => `<div>${l}</div>`).join('');
  }

  setInterval(renderList, 500);

  // controls
  document.getElementById('es-auto').addEventListener('change', (e) => {
    CONFIG.AUTO_STEAL = e.target.checked;
  });
  document.getElementById('es-min').addEventListener('input', (e) => {
    CONFIG.MIN_SCORE = Number(e.target.value) || 0;
  });
  document.getElementById('es-toggle').addEventListener('click', (e) => {
    state.paused = !state.paused;
    e.target.textContent = state.paused ? 'Resume' : 'Pause';
  });
  document.getElementById('es-clear').addEventListener('click', () => {
    state.eggs.clear();
  });

  pushLog('EggSniper loaded — hooking websockets');
})();
