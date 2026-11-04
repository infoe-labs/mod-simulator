/**
 * Chat generation prompts + parsing.
 *
 * The model roleplays a fictional chatroom; it never answers as an assistant
 * and never talks about itself. Every batch arrives labelled, and the labels
 * are frozen the moment the batch validates (see ai_bridge.js) — the game must
 * never re-judge a message at decision time, or scoring would drift.
 */

import { CATEGORY_IDS, CATEGORY_GROUP, TRAITS, ACTIONS } from './constants.js';
import { extractJson, validateBatch } from './schema_validator.js';
import { BATCH_SCHEMA, REACTIONS_SCHEMA, renderSchema } from './json_schema.js';

const CATEGORY_HELP = {
  wholesome: 'a sweet compliment about the streamer or the vibe',
  friendly: 'ordinary pleasant chatter, greetings, "that run was clean"',
  question: 'a genuine question about the game, the setup, or how she does something',
  joke: 'a harmless joke or silly in-joke',
  criticism: 'disagreement or constructive feedback about the stream or a take',
  mild_troll: 'light teasing, "you call that a speedrun lol", harmless poking',
  spam: 'repeated copy-paste noise, caps, emoji floods, "F F F F"',
  ad: 'promotion or a scam: "BUY FOLLOWERS", "free gift cards", fake link posts',
  spoiler: 'reveals an ending or a boss you have not reached yet',
  insult: 'a personal put-down about how bad she is, appearance, or intelligence',
  harassment: 'targeted, repeated, trying to drive her off the stream',
  attack: 'the worst pile-on: "nobody likes you, quit streaming"',
  invasive: 'an intrusive personal question about money, location, age, dating',
  repeat_offender: 'someone with a history of spam/abuse back with an alt',
};

const SYSTEM_PROMPT = [
  'You write the fake viewer chat for a livestream moderation game.',
  'You are not an assistant. You never explain. You output ONLY a JSON array.',
  'No markdown, no code fences, no commentary before or after the array.',
  '',
  'Every element of the array must be an object with exactly these keys:',
  '  "username": made-up handle, 2-20 chars, no spaces, no real person or brand',
  '  "text": what the viewer typed, 2-200 chars, single line, casual internet voice',
  '  "category": one of ' + CATEGORY_IDS.join('|'),
  '  "severity": integer 0..4 (0 harmless, 4 the worst)',
  '  "recommended_action": "allow" | "delete" | "ban"',
  '  "alt_actions": array of other defensible actions from ' + ACTIONS.join('|') + ' (often [])',
  '  "rationale": one short sentence, why that call is right',
  '  "persona": one of ' + TRAITS.join('|'),
  '',
  'MODERATION POLICY (follow it exactly):',
  '  wholesome, friendly, question, joke, criticism  -> allow',
  '  spam, ad, spoiler, mild_troll, insult, invasive  -> delete',
  '  harassment, attack, repeat_offender -> delete, or ban when severity>=3 AND the same viewer has posted abuse before',
  '  A complaint is NOT abuse. "I disagree with your take on this game" is criticism -> allow.',
  '  Teasing from a friendly regular is mild_troll -> delete at most, never ban.',
  '  Repeated targeted cruelty, or "nobody likes you, quit streaming", is harassment/attack -> ban.',
  '  A brand new viewer asking a normal question is question -> allow.',
  '',
  'NEVER write: real slurs, graphic threats, sexual content, real people, real brands,',
  'real links (http, www). If you need a domain, use "example". Keep it PG-13.',
  'Vary sentence length and vocabulary. Do not repeat the same opener twice.',
  'Write every object on one line. The array must contain the full number asked for -',
  'never stop after one or two messages.',
  '',
  'SHAPE OF ONE OBJECT (a template, not content to copy):',
  '{"username":"<handle>","text":"<what the viewer typed>","category":"<category>",'
  + '"severity":0,"recommended_action":"allow","alt_actions":[],"rationale":"<why>","persona":"<persona>"}',
  '',
  'OUTPUT CONTRACT: ' + renderSchema(BATCH_SCHEMA),
].join('\n');

/**
 * Build the two prompts for one batch.
 * @param {object} req
 * @param {number} req.count
 * @param {object} [req.mix]            category -> how many of that category
 * @param {Array}  [req.recent]         [{username,text}] newest last
 * @param {Array}  [req.cast]           [{username,persona,offenses}] recurring chatter
 * @param {string[]} [req.banned]       usernames that must not appear
 * @param {object} [req.stream]         {title, streamer, viewers, phase, pressure}
 * @param {number} [req.tier]           difficulty tier 1..3
 */
export function buildBatchPrompt(req = {}) {
  const count = Math.max(1, Math.min(24, req.count || 10));
  const stream = req.stream || {};
  const lines = [];

  lines.push('STREAM: "' + (stream.title || 'cozy games and chat') + '" hosted by '
    + (stream.streamer || 'Nori') + ', a shy cozy VTuber who plays indie games.');
  lines.push('VIEWERS: ' + (stream.viewers || 40) + '. PHASE: '
    + (stream.phase || 'growing chat') + ' (chat pressure ' + (stream.pressure != null ? stream.pressure : 0.3) + ').');

  if (Array.isArray(req.cast) && req.cast.length) {
    lines.push('');
    lines.push('REGULARS WHO ARE LIVE RIGHT NOW (reuse these handles for repeat behaviour):');
    for (const c of req.cast.slice(0, 8)) {
      lines.push('  - ' + c.username + ' [' + (c.persona || 'regular') + ']'
        + (c.offenses ? ', prior offenses: ' + c.offenses : ', never in trouble'));
    }
  }

  if (Array.isArray(req.recent) && req.recent.length) {
    lines.push('');
    lines.push('RECENT CHAT, oldest first (reply to it, do not copy it):');
    for (const m of req.recent.slice(-8)) {
      lines.push('  ' + m.username + ': ' + String(m.text).slice(0, 90));
    }
  }

  if (Array.isArray(req.banned) && req.banned.length) {
    lines.push('');
    lines.push('ALREADY BANNED, must never post again: ' + req.banned.slice(0, 12).join(', '));
  }

  lines.push('');
  if (req.flavour) {
    lines.push('FOCUS THIS BATCH ON: ' + req.flavour + '.');
  }
  if (req.mix && Object.keys(req.mix).length) {
    const mix = Object.entries(req.mix)
      .filter(([c, n]) => CATEGORY_IDS.includes(c) && n > 0)
      .map(([c, n]) => n + ' ' + c)
      .join(', ');
    lines.push('WRITE EXACTLY ' + count + ' new chat messages, made of: ' + mix + '.');
  } else {
    lines.push('WRITE EXACTLY ' + count + ' new chat messages, a believable mix of nice viewers, '
      + 'a couple of jokers, some spam, and at least one rude one.');
  }
  lines.push('Roughly ' + (req.tier >= 3 ? 'half' : req.tier === 2 ? 'a third' : 'a fifth')
    + ' of them should be worth moderating (spam, trolling, insults, harassment).');
  lines.push('Severity should rise with the phase. Keep each "text" under 120 characters when you can.');
  lines.push('');
  lines.push('Return the JSON array of ' + count + ' objects now.');

  return { system: SYSTEM_PROMPT, user: lines.join('\n'), schema: BATCH_SCHEMA };
}

/** Ask for a few short streamer reactions to whatever just happened. */
export function buildReactionPrompt(req = {}) {
  const stream = req.stream || {};
  const lines = [];
  lines.push('You write what ' + (stream.streamer || 'Nori')
    + ', a shy, playful cozy VTuber, says out loud on stream.');
  lines.push('Give ' + (req.count || 4) + ' separate one-liners she would actually say right now.');
  lines.push('3 to 16 words each. Lowercase-ish, casual, warm, a little shy. No hashtags.');
  lines.push('Never mention being an AI, never explain, never use real brands or links.');
  if (req.context) lines.push('WHAT JUST HAPPENED: ' + String(req.context).slice(0, 300));
  if (Array.isArray(req.recent) && req.recent.length) {
    lines.push('RECENT CHAT: ' + req.recent.slice(-4).map((m) => m.username + ': ' + String(m.text).slice(0, 60)).join(' | '));
  }
  lines.push('');
  lines.push('Output ONLY a JSON array of objects: {"text": "...", "mood": one of '
    + 'neutral|happy|excited|laughing|blushing|confused|upset|crying' + '}');
  return {
    system: 'You are a dialogue writer for a cozy visual novel. Output ONLY a JSON array. No prose.',
    user: lines.join('\n'),
    schema: REACTIONS_SCHEMA,
  };
}

/**
 * Run a raw completion through the parser and the validator.
 * @returns {{ok:boolean, messages:Array, problems:string[], repaired:number, dropped:number}}
 */
export function parseBatch(text, opts = {}) {
  const data = extractJson(text);
  if (!data) return { ok: false, messages: [], problems: ['no JSON found in completion'], repaired: 0, dropped: 0 };
  const list = Array.isArray(data) ? data : (Array.isArray(data.messages) ? data.messages : null);
  if (!list) return { ok: false, messages: [], problems: ['JSON was not an array'], repaired: 0, dropped: 0 };
  return validateBatch(list, opts);
}

/** A default category mix for a phase, used when Godot does not send one. */
export const FLAVOURS = [
  'what the viewers think of the game being played',
  'greetings, greetings back and how the stream feels today',
  'questions about her setup, settings and how she does a trick',
  'jokes, puns and running in-jokes',
  'copy-paste spam, promotions and fake giveaways',
  'someone picking a fight with the streamer',
];

export function defaultMix(count, pressure = 0.3) {
  const nice = ['wholesome', 'friendly', 'question', 'joke'];
  const rough = pressure > 0.65
    ? ['spam', 'insult', 'mild_troll', 'harassment', 'ad', 'spoiler']
    : pressure > 0.35
      ? ['spam', 'mild_troll', 'ad', 'criticism', 'insult']
      : ['mild_troll', 'spam', 'criticism'];
  const mix = {};
  for (let i = 0; i < count; i++) {
    const pool = i % 3 === 2 && pressure > 0.2 ? rough : nice;
    const cat = pool[i % pool.length];
    mix[cat] = (mix[cat] || 0) + 1;
  }
  return mix;
}

export { CATEGORY_GROUP };
