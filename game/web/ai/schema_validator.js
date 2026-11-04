/**
 * Strict validation for anything the language model says back to us.
 *
 * The model is not trusted. Every generated message has to survive this file
 * before Godot ever sees it, and the Godot side runs the same rules again
 * (src/ai/ai_content.gd) as defence in depth.
 *
 * Two ideas matter here:
 *   1. Repairs are conservative and reported. A wrong-but-fixable label is
 *      clamped into the policy (a harmless category can never be "ban", an
 *      abusive one can never be "allow"), because a rejected message means a
 *      hole in the chat, not a lesson for the model.
 *   2. Anything unsafe, malformed or off-vocabulary is dropped outright and
 *      counted, so the caller can decide whether the batch is good enough to
 *      keep or whether we fall back to the authored dataset.
 */

import {
  ACTIONS, CATEGORY_IDS, CATEGORY_GROUP, TRAITS, TRAIT_FOR_CATEGORY,
  MOODS, LIMITS, blockReason,
} from './constants.js';

const CATEGORY_SYNONYMS = {
  wholesome_compliment: 'wholesome', compliment: 'wholesome', wholesome: 'wholesome',
  friendly: 'friendly', conversation: 'friendly', neutral: 'friendly', chat: 'friendly', smalltalk: 'friendly',
  question: 'question', genuine_question: 'question', 'genuine question': 'question',
  joke: 'joke', funny: 'joke', humor: 'joke', humour: 'joke', harmless_joke: 'joke',
  criticism: 'criticism', constructive_criticism: 'criticism', 'constructive criticism': 'criticism', feedback: 'criticism',
  mild_troll: 'mild_troll', trolling: 'mild_troll', troll: 'mild_troll', 'mild troll': 'mild_troll', teasing: 'mild_troll',
  spam: 'spam', repetitive_spam: 'spam', 'repetitive spam': 'spam',
  ad: 'ad', ads: 'ad', advertisement: 'ad', scam: 'ad', advertising: 'ad', 'ad / scam': 'ad',
  spoiler: 'spoiler', spoilers: 'spoiler',
  insult: 'insult', personal_insult: 'insult', 'personal insult': 'insult', rude: 'insult',
  harassment: 'harassment', harassing: 'harassment',
  attack: 'attack', hostile_attack: 'attack', 'hostile attack': 'attack', hostile: 'attack', abuse: 'attack',
  invasive: 'invasive', invasive_question: 'invasive', 'invasive question': 'invasive',
  'personal question': 'invasive', personal: 'invasive',
  repeat_offender: 'repeat_offender', repeat: 'repeat_offender', 'repeat offender': 'repeat_offender', repeated: 'repeat_offender',
};

const TRAIT_SYNONYMS = {
  nice: 'sweet', wholesome: 'sweet', shy: 'sweet',
  regulars: 'regular', chadder: 'regular', chatter: 'regular', friend: 'regular',
  new: 'newcomer', newviewer: 'newcomer', 'new viewer': 'newcomer', lurker: 'newcomer',
  comedian: 'joker', funny: 'joker',
  busybody: 'nosy', curious: 'nosy',
  trollish: 'troll', griefer: 'troll',
  bot: 'spammer', spammer_account: 'spammer',
  scammer_account: 'scammer', shill: 'scammer',
  hater_account: 'hater', mean: 'hater', bully: 'hater',
  leaker: 'spoiler',
};

const MOOD_SYNONYMS = {
  ok: 'neutral', idle: 'neutral',
  pleased: 'happy', glad: 'happy', smile: 'happy',
  hyped: 'excited', pumped: 'excited',
  lol: 'laughing', giggling: 'laughing', laughing: 'laughing',
  blush: 'blushing', embarrassed: 'blushing', flustered: 'blushing',
  puzzled: 'confused', lost: 'confused',
  sad: 'upset', hurt: 'upset', sad_upset: 'upset',
  sobbing: 'crying', tears: 'crying', crying: 'crying',
};

function normKey(v) {
  return String(v == null ? '' : v)
    .trim().toLowerCase()
    .replace(/[\s-]+/g, '_')
    .replace(/[^a-z0-9_]/g, '');
}

export function normalizeCategory(v) {
  const k = normKey(v);
  if (CATEGORY_IDS.includes(k)) return k;
  const mapped = CATEGORY_SYNONYMS[k] || CATEGORY_SYNONYMS[String(v || '').toLowerCase()];
  return CATEGORY_IDS.includes(mapped) ? mapped : null;
}

export function normalizeTrait(v) {
  const k = normKey(v);
  if (TRAITS.includes(k)) return k;
  const mapped = TRAIT_SYNONYMS[k];
  return TRAITS.includes(mapped) ? mapped : null;
}

export function normalizeMood(v) {
  const k = normKey(v);
  if (MOODS.includes(k)) return k;
  const mapped = MOOD_SYNONYMS[k];
  return MOODS.includes(mapped) ? mapped : null;
}

function cleanText(v, maxLen) {
  if (typeof v !== 'string' && typeof v !== 'number') return null;
  let s = String(v)
    .replace(/\r/g, '')
    .replace(/[\u0000-\u001f\u200b-\u200f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  s = s.replace(/^["'`“”]+|["'`“”]+$/g, '').trim();
  if (s.length < LIMITS.text_min) return null;
  if (s.length > maxLen) s = s.slice(0, maxLen - 1).trimEnd() + '…';
  return s;
}

function cleanUsername(v) {
  let s = String(v == null ? '' : v)
    .replace(/^@+/, '')
    .replace(/\s+/g, '_')
    .replace(/[^\w.\-\u00c0-\u024f°♡<>=+]/g, '')
    .trim();
  if (s.length < LIMITS.username_min) return null;
  if (s.length > LIMITS.username_max) s = s.slice(0, LIMITS.username_max);
  return s;
}

function clampNumber(v, lo, hi, dflt) {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return dflt;
  return Math.min(hi, Math.max(lo, n));
}

/**
 * The moderation policy, applied to whatever the model proposed.
 * "A complaint is not automatically abuse" lives here as much as in the prompt:
 * the group is decided by the category, and the action set follows the group.
 */
export function applyPolicy(category, severity, action, alts) {
  const group = CATEGORY_GROUP[category] || 'neutral';
  const notes = [];
  let ideal = ACTIONS.includes(action) ? action : 'allow';
  let accept = Array.isArray(alts)
    ? alts.map((a) => String(a).trim().toLowerCase()).filter((a) => ACTIONS.includes(a) && a !== ideal)
    : [];
  accept = [...new Set(accept)];

  if (group === 'positive' || group === 'neutral') {
    // A nice message can be allowed, or over-zealously deleted (a mild miss).
    // It can never be a ban, whatever the model thought.
    if (ideal !== 'allow') { notes.push('action:forced_allow'); ideal = 'allow'; }
    accept = accept.filter((a) => a === 'delete');
  } else {
    if (ideal === 'allow') { notes.push('action:forced_delete'); ideal = 'delete'; }
    if (severity >= 3) {
      // Serious abuse: banning is a legitimate call, so it is always at least
      // an accepted alternative.
      if (!accept.includes('ban')) accept.push('ban');
    } else {
      // Mild rubbish: banning here would punish the player for a call the game
      // cannot defend, so the option is taken off the table.
      if (ideal === 'ban') { notes.push('action:softened_to_delete'); ideal = 'delete'; }
      accept = accept.filter((a) => a !== 'ban');
    }
  }
  accept = [...new Set(accept)].filter((a) => a !== ideal);
  return { group, ideal_action: ideal, alt_actions: accept, notes };
}

/** Damage the meters take when this message is mishandled — same shape as the
 *  authored dataset's `damage` column. Godot re-derives it; this is a hint. */
export function policyDamage(category, severity, group) {
  const base = group === 'major' ? 4.2 : group === 'minor' ? 2.4 : 0.9;
  return Math.round((base + severity * 0.9) * 100) / 100;
}

/**
 * Validate one generated chat message.
 * @returns {{ok: boolean, message?: object, problems: string[]}}
 */
export function validateChatMessage(raw, opts = {}) {
  const problems = [];
  if (!raw || typeof raw !== 'object') return { ok: false, problems: ['not an object'] };

  const category = normalizeCategory(raw.category ?? raw.label ?? raw.type);
  if (!category) return { ok: false, problems: [`unknown category "${raw.category}"`] };

  const text = cleanText(raw.text ?? raw.message ?? raw.content, LIMITS.text_max);
  if (!text) return { ok: false, problems: ['empty text'] };

  const blocked = blockReason(text);
  if (blocked) return { ok: false, problems: [blocked] };

  const username = cleanUsername(raw.username ?? raw.user ?? raw.name);
  if (!username) return { ok: false, problems: ['empty username'] };
  if (Array.isArray(opts.banned) && opts.banned.map((s) => String(s).toLowerCase()).includes(username.toLowerCase())) {
    return { ok: false, problems: [`banned user ${username}`] };
  }

  const persona = normalizeTrait(raw.persona ?? raw.trait ?? raw.personality) || 'regular';
  const allowedTraits = TRAIT_FOR_CATEGORY[category] || [];
  let personaNote = '';
  let finalPersona = persona;
  if (allowedTraits.length && !allowedTraits.includes(persona)) {
    // The troll cannot suddenly write a wholesome compliment: keep the label,
    // move the author to a personality that plausibly would.
    finalPersona = allowedTraits[0];
    personaNote = 'persona:swapped';
  }

  const severity = Math.round(clampNumber(raw.severity, LIMITS.severity_min, LIMITS.severity_max, category === 'harassment' || category === 'attack' ? 3 : 0));
  const tier = Math.round(clampNumber(raw.tier, LIMITS.tier_min, LIMITS.tier_max, opts.tier ?? 1));
  const policy = applyPolicy(category, severity, raw.recommended_action ?? raw.ideal_action ?? raw.action, raw.alt_actions ?? raw.acceptable_actions);

  const rationale = cleanText(raw.rationale ?? raw.explanation ?? raw.reason ?? raw.why, LIMITS.rationale_max)
    || 'fits the ' + category.replace(/_/g, ' ') + ' policy';
  const expiry = clampNumber(raw.expiry ?? raw.expires_in, LIMITS.expiry_min, LIMITS.expiry_max, 10.0);
  const group = policy.group;

  return {
    ok: true,
    problems,
    message: {
      username,
      text,
      category,
      group,
      severity,
      tier,
      ideal_action: policy.ideal_action,
      alt_actions: policy.alt_actions,
      rationale,
      persona: finalPersona,
      escalates: group === 'major' || category === 'spam' || category === 'ad' || category === 'insult' || category === 'mild_troll',
      expiry: Math.round(expiry * 10) / 10,
      damage: policyDamage(category, severity, group),
      policy_notes: [...policy.notes, ...(personaNote ? [personaNote] : [])],
    },
  };
}

/**
 * Validate a whole generated batch.
 * @returns {{ok:boolean, messages:object[], problems:string[], repaired:number, dropped:number}}
 */
export function validateBatch(rawList, opts = {}) {
  const problems = [];
  if (!Array.isArray(rawList)) return { ok: false, messages: [], problems: ['batch is not an array'], repaired: 0, dropped: 0 };

  const want = Math.min(LIMITS.batch_max, Math.max(1, opts.expect || LIMITS.batch_min));
  const seen = new Set();
  const messages = [];
  let dropped = 0;
  let repaired = 0;

  for (const raw of rawList) {
    const r = validateChatMessage(raw, { ...opts, tier: raw?.tier ?? opts.tier });
    if (!r.ok) { dropped++; problems.push(...r.problems); continue; }
    const key = r.message.text.toLowerCase().replace(/[^\w]+/g, ' ').trim();
    if (seen.has(key)) { dropped++; problems.push('duplicate text'); continue; }
    seen.add(key);
    if (r.message.policy_notes.length) repaired++;
    messages.push(r.message);
    if (messages.length >= want) break;
  }

  const minKeep = Math.max(1, Math.min(opts.minKeep ?? LIMITS.batch_min, Math.floor(want * 0.5)));
  if (messages.length < minKeep) {
    problems.unshift(`only ${messages.length} of ${want} messages survived validation`);
    return { ok: false, messages, problems, repaired, dropped };
  }
  // A chat made entirely of one thing is a broken batch, not a chat.
  const cats = new Set(messages.map((m) => m.category));
  if (messages.length >= 6 && cats.size < 2) {
    problems.unshift('batch is a single category');
    return { ok: false, messages, problems, repaired, dropped };
  }
  return { ok: true, messages, problems, repaired, dropped };
}

/** Validate the output of the contextual classifier (single message audit). */
export function validateClassification(raw) {
  const problems = [];
  if (!raw || typeof raw !== 'object') return { ok: false, problems: ['classification is not an object'] };
  const category = normalizeCategory(raw.category ?? raw.label);
  if (!category) return { ok: false, problems: [`unknown category "${raw.category}"`] };
  const severity = Math.round(clampNumber(raw.severity, LIMITS.severity_min, LIMITS.severity_max, 0));
  const policy = applyPolicy(category, severity, raw.recommended_action ?? raw.action ?? raw.ideal_action, raw.alt_actions);
  const rationale = cleanText(raw.rationale ?? raw.reason ?? raw.explanation, LIMITS.rationale_max) || 'no reason given';
  const confidence = clampNumber(raw.confidence, 0, 1, 0.5);
  return {
    ok: true,
    problems,
    classification: {
      category,
      group: policy.group,
      severity,
      recommended_action: policy.ideal_action,
      alt_actions: policy.alt_actions,
      rationale,
      confidence,
      policy_notes: policy.notes,
    },
  };
}

/** Validate generated streamer reaction lines. */
export function validateReactions(rawList) {
  const out = [];
  const problems = [];
  if (!Array.isArray(rawList)) return { ok: false, reactions: [], problems: ['reactions is not an array'] };
  for (const raw of rawList) {
    const text = cleanText(typeof raw === 'string' ? raw : raw?.text, LIMITS.reaction_max);
    if (!text) { problems.push('empty reaction'); continue; }
    if (blockReason(text)) { problems.push('blocked reaction'); continue; }
    const mood = normalizeMood(typeof raw === 'object' ? raw.mood : null) || 'neutral';
    out.push({ text, mood });
    if (out.length >= 6) break;
  }
  return { ok: out.length > 0, reactions: out, problems };
}

/** Pull the top-level {...} chunks out of a truncated or ragged completion. */
function extractObjects(s) {
  const out = [];
  let depth = 0, start = -1, inStr = false, esc = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (esc) { esc = false; } else if (c === '\\') { esc = true; } else if (c === '"') { inStr = false; }
      continue;
    }
    if (c === '"') { inStr = true; continue; }
    if (c === '{') { if (depth === 0) start = i; depth++; continue; }
    if (c === '}') {
      depth--;
      if (depth === 0 && start >= 0) {
        const chunk = s.slice(start, i + 1);
        try { out.push(JSON.parse(chunk)); } catch (e) {
          try { out.push(JSON.parse(chunk.replace(/,\s*}/g, '}'))); } catch (e2) { /* skip */ }
        }
        start = -1;
      }
    }
  }
  return out;
}

/** Extract the first JSON array/object from a chatty model completion. */
export function extractJson(text) {
  if (typeof text !== 'string') return null;
  let s = text.trim();
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) s = fence[1].trim();
  const starts = [s.indexOf('['), s.indexOf('{')].filter((i) => i >= 0);
  if (!starts.length) return null;
  const start = Math.min(...starts);
  const open = s[start];
  const close = open === '[' ? ']' : '}';
  const end = s.lastIndexOf(close);
  const body = end > start ? s.slice(start, end + 1) : s.slice(start);
  for (const candidate of [body, body.replace(/,\s*([}\]])/g, '$1'), body.replace(/,\s*\.\.\.\s*\]/g, ']')]) {
    try {
      return JSON.parse(candidate);
    } catch (e) { /* keep trying */ }
  }
  // A completion cut off at the token limit has no closing bracket. Salvage the
  // objects that *did* finish; a batch of six that became four is still a chat.
  const salvaged = extractObjects(body);
  return salvaged.length ? salvaged : null;
}
