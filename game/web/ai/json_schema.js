/**
 * JSON Schemas used for constrained decoding.
 *
 * A 0.5B model asked nicely to produce JSON produces JSON about as often as a
 * coin flip. Asked *grammatically* - the sampler is only allowed to emit tokens
 * that keep the output valid - it produces JSON every time, and the enums mean
 * it can never invent a category the game does not know. wllama honours these
 * natively (llguidance); WebLLM has no grammar support, so the same schemas are
 * rendered into the prompt as a contract and everything is validated anyway.
 */

import { CATEGORY_IDS, TRAITS, ACTIONS } from './constants.js';

const actionEnum = { type: 'string', enum: ACTIONS };

export const BATCH_SCHEMA = {
  type: 'array',
  items: {
    type: 'object',
    properties: {
      username: { type: 'string', minLength: 2, maxLength: 20 },
      text: { type: 'string', minLength: 2, maxLength: 200 },
      category: { type: 'string', enum: CATEGORY_IDS },
      severity: { type: 'integer', minimum: 0, maximum: 4 },
      recommended_action: actionEnum,
      alt_actions: { type: 'array', items: actionEnum, maxItems: 2 },
      rationale: { type: 'string', minLength: 4, maxLength: 200 },
      persona: { type: 'string', enum: TRAITS },
    },
    required: ['username', 'text', 'category', 'severity', 'recommended_action', 'alt_actions', 'rationale', 'persona'],
    additionalProperties: false,
  },
};

export const CLASSIFY_SCHEMA = {
  type: 'object',
  properties: {
    category: { type: 'string', enum: CATEGORY_IDS },
    severity: { type: 'integer', minimum: 0, maximum: 4 },
    recommended_action: actionEnum,
    alt_actions: { type: 'array', items: actionEnum, maxItems: 2 },
    confidence: { type: 'number', minimum: 0, maximum: 1 },
    rationale: { type: 'string', minLength: 4, maxLength: 220 },
  },
  required: ['category', 'severity', 'recommended_action', 'alt_actions', 'confidence', 'rationale'],
  additionalProperties: false,
};

export const REACTIONS_SCHEMA = {
  type: 'array',
  items: {
    type: 'object',
    properties: {
      text: { type: 'string', minLength: 4, maxLength: 110 },
      mood: { type: 'string', enum: ['neutral', 'happy', 'excited', 'laughing', 'blushing', 'confused', 'upset', 'crying'] },
    },
    required: ['text', 'mood'],
    additionalProperties: false,
  },
};

/** A compact, human-readable rendering of a schema, for runtimes with no
 *  grammar support (WebLLM) - the contract still has to be in the prompt. */
export function renderSchema(schema) {
  const t = (s) => {
    if (!s || typeof s !== 'object') return 'any';
    if (s.type === 'array') return 'array of ' + t(s.items);
    if (s.enum) return 'one of ' + s.enum.join('|');
    if (s.type === 'object') return 'object';
    return s.type || 'any';
  };
  const root = schema.type === 'array' ? schema.items : schema;
  const props = Object.entries(root.properties || {})
    .map(([k, v]) => `"${k}": ${t(v)}`)
    .join(', ');
  return schema.type === 'array'
    ? 'a JSON array of objects {' + props + '}'
    : 'a JSON object {' + props + '}';
}
