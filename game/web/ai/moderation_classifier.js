/**
 * Contextual classification.
 *
 * Used in two places:
 *   1. The AI lab page, where a human types a message and watches the model
 *      judge it (this is the "prove it is really reasoning" surface).
 *   2. In-game, for the tutorial's "ask the mod AI" card, which only appears
 *      when a model is loaded.
 *
 * It is deliberately NOT used to score live gameplay: batches are labelled once
 * at creation time (chat_generator.js) and those labels are frozen, so a
 * message can never score two different ways in two different runs.
 */

import { ACTIONS } from './constants.js';
import { extractJson, validateClassification } from './schema_validator.js';
import { CLASSIFY_SCHEMA, renderSchema } from './json_schema.js';

const SYSTEM_PROMPT = [
  'You are the moderation judge for a fictional livestream chat.',
  'You are shown one viewer message plus the context around it. You decide what',
  'a good moderator should do. You output ONLY a JSON object, no prose.',
  '',
  'Output object keys:',
  '  "category": one of wholesome|friendly|question|joke|criticism|mild_troll|spam|ad|spoiler|insult|harassment|attack|invasive|repeat_offender',
  '  "severity": integer 0..4',
  '  "recommended_action": ' + ACTIONS.join('|'),
  '  "alt_actions": array of other defensible actions',
  '  "confidence": number 0..1',
  '  "rationale": one short sentence that mentions the context that mattered',
  '',
  'Think about context, not keywords:',
  '  - "you\'re so bad at this game lol" from a friendly regular is teasing (mild_troll, delete at most);',
  '    the same line from someone who has insulted her five times is harassment (ban).',
  '  - disagreement, criticism and complaints are allowed in chat.',
  '  - repetition, targeting, and trying to disrupt the stream raise severity.',
  '  - a normal question from a brand new viewer is always allowed.',
  '  - spam and ads are deleted; only repeat or serious abuse is a ban.',
  '',
  'OUTPUT CONTRACT: ' + renderSchema(CLASSIFY_SCHEMA),
].join('\n');

export function buildClassifyPrompt(req = {}) {
  const lines = [];
  const stream = req.stream || {};
  lines.push('STREAM: "' + (stream.title || 'cozy stream') + '" by ' + (stream.streamer || 'Nori') + '.');
  if (Array.isArray(req.history) && req.history.length) {
    lines.push('WHAT THIS VIEWER POSTED EARLIER THIS STREAM:');
    for (const h of req.history.slice(-6)) {
      lines.push('  - (' + (h.category || 'unknown') + ') ' + String(h.text).slice(0, 90));
    }
  } else {
    lines.push('WHAT THIS VIEWER POSTED EARLIER: nothing, this is their first message.');
  }
  if (Array.isArray(req.recentChat) && req.recentChat.length) {
    lines.push('AROUND THE SAME TIME:');
    for (const m of req.recentChat.slice(-5)) {
      lines.push('  ' + m.username + ': ' + String(m.text).slice(0, 80));
    }
  }
  lines.push('');
  lines.push('VIEWER: ' + (req.username || 'someone') + (req.offenses ? ' (' + req.offenses + ' prior offenses)' : ' (no prior offenses)'));
  lines.push('MESSAGE: ' + String(req.text || '').slice(0, 300));
  lines.push('');
  lines.push('Judge it now. Return the JSON object.');
  return { system: SYSTEM_PROMPT, user: lines.join('\n'), schema: CLASSIFY_SCHEMA };
}

export function parseClassification(text) {
  const data = extractJson(text);
  if (!data) return { ok: false, problems: ['no JSON found in classification'] };
  const obj = Array.isArray(data) ? data[0] : data;
  return validateClassification(obj);
}
