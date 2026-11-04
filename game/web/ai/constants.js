/**
 * Shared vocabulary for the browser-side AI subsystem.
 *
 * Everything here mirrors the Godot side of the game:
 *   - CATEGORY_IDS is the exact key set of game/data/messages.json "categories"
 *   - ACTIONS is the exact key set the ModerationEngine accepts
 *   - TRAITS is the exact trait vocabulary of the authored cast
 *
 * If the two sides ever drift apart, schema validation rejects the batch and
 * the game quietly keeps playing with the authored dataset (Classic Mode).
 */

export const BRIDGE_VERSION = '1';
export const PROTOCOL = 'modsim-ai-1';

export const ACTIONS = ['allow', 'delete', 'ban'];

/** The 14 authored categories. The AI must classify into these, nothing else. */
export const CATEGORY_IDS = [
  'wholesome',
  'friendly',
  'question',
  'joke',
  'criticism',
  'mild_troll',
  'spam',
  'ad',
  'spoiler',
  'insult',
  'harassment',
  'attack',
  'invasive',
  'repeat_offender',
];

/** Category -> moderation group, same mapping the Godot catalog applies. */
export const CATEGORY_GROUP = {
  wholesome: 'positive',
  friendly: 'neutral',
  question: 'neutral',
  joke: 'neutral',
  criticism: 'neutral',
  mild_troll: 'minor',
  spam: 'minor',
  ad: 'minor',
  spoiler: 'minor',
  insult: 'minor',
  harassment: 'major',
  attack: 'major',
  invasive: 'minor',
  repeat_offender: 'minor',
};

/** Personality identifiers the generator may roleplay. Same words the
 *  authored cast uses, so a generated chatter can borrow their badge/colour. */
export const TRAITS = [
  'sweet',
  'regular',
  'newcomer',
  'joker',
  'nosy',
  'troll',
  'spammer',
  'scammer',
  'hater',
  'spoiler',
];

/** Categories a "nice" personality must never author (keeps the cast honest). */
export const TRAIT_FOR_CATEGORY = {
  wholesome: ['sweet', 'regular', 'newcomer'],
  friendly: ['regular', 'newcomer', 'sweet', 'joker'],
  question: ['newcomer', 'regular', 'nosy'],
  joke: ['joker', 'regular'],
  criticism: ['regular', 'newcomer', 'joker'],
  mild_troll: ['joker', 'troll', 'regular'],
  spam: ['spammer'],
  ad: ['scammer', 'spammer'],
  spoiler: ['spoiler', 'joker'],
  insult: ['hater', 'troll'],
  harassment: ['hater', 'troll'],
  attack: ['hater'],
  invasive: ['nosy', 'newcomer', 'hater'],
  repeat_offender: ['spammer', 'troll', 'hater'],
};

/** The VTuber's expression states, same list ProceduralVTuber accepts. */
export const MOODS = [
  'neutral',
  'happy',
  'excited',
  'laughing',
  'blushing',
  'confused',
  'upset',
  'crying',
];

export const LIMITS = {
  batch_min: 4,
  batch_max: 24,
  text_min: 2,
  text_max: 220,
  username_min: 2,
  username_max: 20,
  rationale_max: 220,
  persona_max: 24,
  severity_min: 0,
  severity_max: 4,
  tier_min: 1,
  tier_max: 3,
  expiry_min: 5.0,
  expiry_max: 15.0,
  damage_min: 0.0,
  damage_max: 10.0,
  reaction_max: 110,
};

/**
 * Content we simply never put on screen, whatever the model proposes.
 * Deliberately narrow: the game's own writing is PG-13 and the fiction says no
 * real slurs and no graphic threats, so anything close to that is dropped
 * rather than censored into nonsense.
 */
const BLOCK_PATTERNS = [
  /\bkill yourself\b/i, /\bkys\b/i, /\bend (it|your life)\b/i,
  /\bhang yourself\b/i, /\bdie to everyone\b/i,
  /\b(nazi|hitler)\b/i,
  /\b(fap|porn|nsfw|onlyfans)\b/i,
  /\b(ciggies?|nicotine pouch)\b/i,
  /\b(molestation|molested|grooming|groomer)\b/i,
  /\b(rape|raped|rapist)\b/i,
  /\b(sexual|explicit)\s+(content|photo|pic|pic(s)?|image)\b/i,
  /\b(child|minor|kid(s)?)\s+(porn|nude|naked)\b/i,
  /\b(bomb|shoot(ing)? up|mass shooting)\b/i,
  /\b(google play card|gift card) (generator|free)\b/i,
  /\b(crypto|bitcoin) (giveaway|signal|pump)\b/i,
  /https?:\/\//i, /\bwww\./i,
];

export function blockReason(text) {
  const s = String(text || '');
  for (const re of BLOCK_PATTERNS) if (re.test(s)) return `blocked:${re.source}`;
  return null;
}

/** Deterministic 32-bit hash, used to colour generated usernames. */
export function hashString(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

const PALETTE = [
  '#8fd6b6', '#ffc9de', '#a8c6ff', '#ffd98a', '#c9b6ff',
  '#9fe3d8', '#ffb3a7', '#d6e2a0', '#f0c8f0', '#a7d8ff',
];

export function colorFor(username) {
  return PALETTE[hashString(String(username).toLowerCase()) % PALETTE.length];
}

/** A badge, chosen deterministically from the name, like the authored cast. */
export function badgeFor(username, trait) {
  const h = hashString(String(username).toLowerCase());
  if (trait === 'regular' && h % 3 === 0) return 'sub';
  if (h % 17 === 0) return 'vip';
  return 'none';
}
