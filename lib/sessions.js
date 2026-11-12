// Reads Claude Code session files (~/.claude/projects/<folder>/<id>.jsonl).
// Local and read-only. No dependency on VS Code, so it can be tested on its own.
//
// Format (checked 2026-11-12, Claude Code 2.1.322): one JSON object per line.
//   type "user" / "assistant": message with cwd, timestamp, message.content
//   type "ai-title":           { aiTitle }  – title given by Claude, repeated
//   type "last-prompt":        { lastPrompt }
// Everything else (attachment, api-request, …) is skipped.

'use strict';

const fs = require('fs');
const path = require('path');

const HEAD_STEPS = [64 * 1024, 1024 * 1024];
const TAIL_STEPS = [256 * 1024, 2 * 1024 * 1024];
const EXCERPT_MAX = 420;
const TITLE_MAX = 90;

// Don't even parse the large lines we don't care about.
const SKIP_LINE = /^\{"type":"(?!ai-title"|last-prompt"|user"|assistant")|^\{"parentUuid":[^,]{0,60},"isSidechain":(?:true|false),"attachment":/;

async function readRange(file, start, length) {
  const handle = await fs.promises.open(file, 'r');
  try {
    const buffer = Buffer.allocUnsafe(length);
    const { bytesRead } = await handle.read(buffer, 0, length, start);
    return buffer.toString('utf8', 0, bytesRead);
  } finally {
    await handle.close();
  }
}

function parseLines(text, dropFirst, dropLast) {
  const lines = text.split('\n');
  if (dropFirst) lines.shift();
  if (dropLast) lines.pop();
  const entries = [];
  for (const line of lines) {
    if (line.length < 2 || SKIP_LINE.test(line)) continue;
    try {
      entries.push(JSON.parse(line));
    } catch {
      // Incomplete line (file is being written) – ignore.
    }
  }
  return entries;
}

// Text of a message without injected blocks (<system-reminder>, <ide_selection>, …).
function messageText(entry) {
  const content = entry && entry.message && entry.message.content;
  if (typeof content === 'string') {
    return content.trimStart().startsWith('<') ? '' : content.trim();
  }
  if (!Array.isArray(content)) return '';
  const parts = [];
  for (const block of content) {
    if (!block || block.type !== 'text' || typeof block.text !== 'string') continue;
    const text = block.text.trim();
    if (!text || text.startsWith('<')) continue;
    parts.push(text);
  }
  return parts.join('\n\n');
}

function isHumanPrompt(entry) {
  return entry.type === 'user' && !entry.isMeta && !entry.isSidechain && messageText(entry) !== '';
}

function oneLine(text, max) {
  const flat = text.replace(/\s+/g, ' ').trim();
  return flat.length > max ? flat.slice(0, max - 1).trimEnd() + '…' : flat;
}

// Strip Markdown roughly so the excerpt on a card looks calm.
function plainExcerpt(text) {
  const plain = text
    .replace(/```[\s\S]*?(```|$)/g, ' ')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/^\s{0,3}(#{1,6}|[-*+]|\d+\.)\s+/gm, '')
    .replace(/^\s*\|?[-:| ]{3,}\|?\s*$/gm, ' ')
    .replace(/[*_`|]/g, '');
  return oneLine(plain, EXCERPT_MAX);
}

async function readSession(file, stat) {
  const size = stat.size;
  const info = {
    id: path.basename(file, '.jsonl'),
    cwd: null,
    title: null,
    firstPrompt: null,
    lastPrompt: null,
    excerpt: null,
    lastTs: 0,
    openTurn: false,
  };

  // Head: working folder and the user's first message.
  for (const step of HEAD_STEPS) {
    const length = Math.min(step, size);
    const entries = parseLines(await readRange(file, 0, length), false, length < size);
    for (const entry of entries) {
      if (!info.cwd && typeof entry.cwd === 'string') info.cwd = entry.cwd;
      if (!info.firstPrompt && isHumanPrompt(entry)) info.firstPrompt = messageText(entry);
      if (info.cwd && info.firstPrompt) break;
    }
    if ((info.cwd && info.firstPrompt) || length >= size) break;
  }

  // Tail: title, Claude's last reply, last activity.
  for (const step of TAIL_STEPS) {
    const length = Math.min(step, size);
    const entries = parseLines(await readRange(file, size - length, length), length < size, false);
    let lastMessage = null;
    for (const entry of entries) {
      if (entry.type === 'ai-title' && typeof entry.aiTitle === 'string') {
        info.title = entry.aiTitle;
      } else if (entry.type === 'last-prompt' && typeof entry.lastPrompt === 'string') {
        info.lastPrompt = entry.lastPrompt;
      } else if ((entry.type === 'user' || entry.type === 'assistant') && !entry.isSidechain) {
        if (!info.cwd && typeof entry.cwd === 'string') info.cwd = entry.cwd;
        const ts = Date.parse(entry.timestamp);
        if (ts > info.lastTs) info.lastTs = ts;
        lastMessage = entry;
        if (entry.type === 'assistant') {
          const text = messageText(entry);
          if (text) info.excerpt = text;
        }
      }
    }
    if (lastMessage) {
      const finished =
        lastMessage.type === 'assistant' &&
        lastMessage.message &&
        lastMessage.message.stop_reason === 'end_turn';
      // Interrupted by the user: the turn is over even without a reply from Claude.
      const interrupted =
        lastMessage.type === 'user' && messageText(lastMessage).startsWith('[Request interrupted');
      info.openTurn = !finished && !interrupted;
    }
    if (info.excerpt || length >= size) break;
  }

  if (!info.lastTs) info.lastTs = stat.mtimeMs;
  const title = info.title || info.firstPrompt || info.lastPrompt || '';
  return {
    id: info.id,
    cwd: info.cwd,
    title: oneLine(title, TITLE_MAX),
    excerpt: info.excerpt ? plainExcerpt(info.excerpt) : '',
    lastTs: info.lastTs,
    openTurn: info.openTurn,
  };
}

async function exists(target) {
  try {
    return (await fs.promises.stat(target)).isDirectory();
  } catch {
    return false;
  }
}

// Returns all projects, most recent first. `cache` (a Map) remembers files by size
// and modification time so only changed files are read again.
async function scanProjects(root, cache, options = {}) {
  let dirs;
  try {
    dirs = await fs.promises.readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }
  const seen = new Set();
  const projects = [];

  for (const dir of dirs) {
    if (!dir.isDirectory()) continue;
    if (options.only && !options.only.includes(dir.name)) continue;
    const dirPath = path.join(root, dir.name);
    let names;
    try {
      names = await fs.promises.readdir(dirPath);
    } catch {
      continue;
    }
    const sessions = [];
    for (const name of names) {
      if (!name.endsWith('.jsonl')) continue;
      const file = path.join(dirPath, name);
      try {
        const stat = await fs.promises.stat(file);
        if (!stat.isFile() || stat.size === 0) continue;
        seen.add(file);
        const cached = cache.get(file);
        if (cached && cached.size === stat.size && cached.mtimeMs === stat.mtimeMs) {
          sessions.push(cached.session);
          continue;
        }
        const session = await readSession(file, stat);
        cache.set(file, { size: stat.size, mtimeMs: stat.mtimeMs, session });
        sessions.push(session);
      } catch {
        // File vanished or unreadable – skip.
      }
    }
    if (!sessions.length) continue;
    sessions.sort((a, b) => b.lastTs - a.lastTs);
    const withCwd = sessions.find((s) => s.cwd);
    const projectPath = withCwd ? withCwd.cwd : null;
    projects.push({
      dir: dir.name,
      path: projectPath,
      name: projectPath ? path.basename(projectPath) || projectPath : dir.name,
      missing: projectPath ? !(await exists(projectPath)) : true,
      lastTs: sessions[0].lastTs,
      sessions,
    });
  }

  for (const file of cache.keys()) if (!seen.has(file)) cache.delete(file);
  projects.sort((a, b) => b.lastTs - a.lastTs);
  return projects;
}

const ACTIVE_WINDOW_MS = 3 * 60 * 1000;

function isActive(session, now = Date.now()) {
  return session.openTurn && now - session.lastTs < ACTIVE_WINDOW_MS;
}

module.exports = { scanProjects, isActive };
