// In-game calculator engine: lexer + Pratt parser + evaluator over typed
// quantities. Pure ESM with zero imports — the same file runs under webpack
// (Vue components) and plain `node --test` (see __tests__/), which is why
// everything the engine needs from the game (resources, tick rate, now) is
// injected through an env object built in env.js.
//
// Quantity model — all internal values are canonical:
//   scalar   { k:'scalar', v, res }        res: 'credit'|'technology'|'ideology'|null
//   rate     { k:'rate', vPerHour, res }   per REAL hour
//   dur      { k:'dur', s }                real seconds
//   dt       { k:'dt', ms }                epoch milliseconds
// plus statement-level results ('eta', 'afford', 'snapshot') that only the
// formatter consumes. Unit propagation happens in applyBin: amount ÷ rate
// gives a duration, rate × duration gives an amount, mixing two different
// resources is an error, a bare number unifies with anything.

export class CalcError extends Error {
  constructor(code, data = {}) {
    super(code);
    this.code = code;
    this.data = data;
  }
}

const err = (code, data) => { throw new CalcError(code, data); };

// ---------------------------------------------------------------------------
// Word tables
// ---------------------------------------------------------------------------

const RESOURCE_WORDS = {
  c: 'credit',
  credit: 'credit',
  credits: 'credit',
  t: 'technology',
  tech: 'technology',
  technology: 'technology',
  i: 'ideology',
  ideo: 'ideology',
  ideology: 'ideology',
};

// Multi-word names are merged by the lexer before classification (longest
// match first), so 'credit income' arrives here as a single key.
const INCOME_WORDS = {
  ci: 'credit',
  'credit income': 'credit',
  'credits income': 'credit',
  ti: 'technology',
  'tech income': 'technology',
  'technology income': 'technology',
  ii: 'ideology',
  'ideo income': 'ideology',
  'ideology income': 'ideology',
};

const LEXSLOT_WORDS = ['lex slot', 'lex slot cost'];

// seconds per unit; 'tick' is resolved against env.perHour at eval time.
const DURATION_UNITS = {
  s: 1, sec: 1, secs: 1, second: 1, seconds: 1,
  m: 60, min: 60, mins: 60, minute: 60, minutes: 60,
  h: 3600, hr: 3600, hrs: 3600, hour: 3600, hours: 3600,
  d: 86400, day: 86400, days: 86400,
  tick: 'tick', ticks: 'tick', ut: 'tick', uts: 'tick',
};

const KEYWORDS = ['until', 'in', 'at', 'afford', 'today', 'tomorrow'];

// JS Date#getDay() numbering (sunday = 0).
const WEEKDAYS = {
  sunday: 0, sun: 0,
  monday: 1, mon: 1,
  tuesday: 2, tue: 2,
  wednesday: 3, wed: 3,
  thursday: 4, thu: 4,
  friday: 5, fri: 5,
  saturday: 6, sat: 6,
};

const MULTIWORDS = [...LEXSLOT_WORDS, ...Object.keys(INCOME_WORDS)]
  .filter((w) => w.includes(' '))
  .map((w) => w.split(' '));

// ---------------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------------

const OPS = {
  '+': '+', '-': '-', '−': '-', '*': '*', '×': '*', x: null, // 'x' stays a word
  '/': '/', '÷': '/', '(': '(', ')': ')', '=': '=', '%': '%',
};

export function tokenize(src) {
  const tokens = [];
  const s = src;
  let p = 0;

  const words = []; // pending word run, merged for multi-word names

  const flushWords = () => {
    let idx = 0;
    while (idx < words.length) {
      let merged = null;
      // longest multi-word match first (3 then 2 words)
      for (const len of [3, 2]) {
        if (idx + len > words.length) continue;
        const joined = words.slice(idx, idx + len).map((w) => w.text).join(' ');
        if (MULTIWORDS.some((mw) => mw.join(' ') === joined)) {
          merged = { text: joined, len };
          break;
        }
      }
      const w = merged || { text: words[idx].text, len: 1 };
      tokens.push(classifyWord(w.text, words[idx].pos));
      idx += w.len;
    }
    words.length = 0;
  };

  while (p < s.length) {
    const ch = s[p];

    if (/\s/.test(ch)) { p += 1; continue; }

    // time of day: 18:00 / 7:30
    const todMatch = /^(\d{1,2}):(\d{2})(?!\d)/.exec(s.slice(p));
    if (todMatch) {
      flushWords();
      tokens.push({ t: 'timeofday', h: parseInt(todMatch[1], 10), m: parseInt(todMatch[2], 10), pos: p });
      p += todMatch[0].length;
      continue;
    }

    const numMatch = /^(\d+(?:\.\d+)?)(k?)(?![\w.])/i.exec(s.slice(p));
    if (numMatch) {
      flushWords();
      const v = parseFloat(numMatch[1]) * (numMatch[2] ? 1000 : 1);
      tokens.push({ t: 'num', v, pos: p });
      p += numMatch[0].length;
      continue;
    }
    // number directly followed by a word (4h, 70t, 9800ideo): lex digits only
    const numPrefix = /^(\d+(?:\.\d+)?)/.exec(s.slice(p));
    if (numPrefix) {
      flushWords();
      tokens.push({ t: 'num', v: parseFloat(numPrefix[1]), pos: p });
      p += numPrefix[0].length;
      continue;
    }

    if (Object.prototype.hasOwnProperty.call(OPS, ch) && OPS[ch]) {
      flushWords();
      tokens.push({ t: OPS[ch], pos: p });
      p += 1;
      continue;
    }

    const wordMatch = /^[a-zA-ZÀ-ɏ_][a-zA-ZÀ-ɏ0-9_]*/.exec(s.slice(p));
    if (wordMatch) {
      words.push({ text: wordMatch[0].toLowerCase(), pos: p });
      p += wordMatch[0].length;
      continue;
    }

    err('PARSE', { at: p, char: ch });
  }

  flushWords();
  tokens.push({ t: 'eof', pos: p });
  return tokens;
}

function classifyWord(text, pos) {
  if (KEYWORDS.includes(text)) return { t: 'kw', kw: text, pos };
  if (Object.prototype.hasOwnProperty.call(WEEKDAYS, text)) return { t: 'weekday', dow: WEEKDAYS[text], pos };
  if (LEXSLOT_WORDS.includes(text)) return { t: 'lexslot', pos };
  if (Object.prototype.hasOwnProperty.call(INCOME_WORDS, text)) return { t: 'income', res: INCOME_WORDS[text], pos };
  if (Object.prototype.hasOwnProperty.call(DURATION_UNITS, text)) {
    return { t: 'unit', factor: DURATION_UNITS[text], pos, word: text };
  }
  if (Object.prototype.hasOwnProperty.call(RESOURCE_WORDS, text)) {
    return { t: 'resword', res: RESOURCE_WORDS[text], pos, word: text };
  }
  return { t: 'word', word: text, pos };
}

// ---------------------------------------------------------------------------
// Parser (Pratt for arithmetic, hand-rolled statement forms)
// ---------------------------------------------------------------------------

class Parser {
  constructor(tokens) {
    this.tokens = tokens;
    this.p = 0;
  }

  peek(offset = 0) { return this.tokens[this.p + offset]; }

  next() { const tok = this.tokens[this.p]; this.p += 1; return tok; }

  expectEof() {
    if (this.peek().t !== 'eof') err('PARSE', { at: this.peek().pos });
  }

  // statement := word '=' expr
  //            | 'until' expr | 'afford' expr
  //            | ['in' durexpr | 'at' when] (bare projections)
  //            | expr ['in' durexpr | 'at' when]
  parseStatement() {
    const first = this.peek();

    // assigning to a reserved word (h = 5, credits = 1) deserves a
    // specific error, not a generic parse failure
    if (this.peek(1).t === '=' && first.t !== 'word' && first.t !== 'eof') {
      err('NAME_TAKEN', { name: first.word || first.kw || first.t });
    }

    if (first.t === 'word' && this.peek(1).t === '=') {
      this.next(); this.next();
      const e = this.parseTail(this.parseExpr());
      this.expectEof();
      return { t: 'assign', name: first.word, e };
    }

    if (first.t === 'kw' && (first.kw === 'until' || first.kw === 'afford')) {
      this.next();
      const e = this.parseExpr();
      this.expectEof();
      return { t: first.kw, e };
    }

    if (first.t === 'kw' && first.kw === 'in') {
      this.next();
      const d = this.parseExpr();
      this.expectEof();
      return { t: 'in', e: null, d };
    }
    if ((first.t === 'kw' && (first.kw === 'at' || first.kw === 'today' || first.kw === 'tomorrow'))
      || first.t === 'weekday' || first.t === 'timeofday') {
      if (first.kw === 'at') this.next();
      const when = this.parseWhen();
      this.expectEof();
      return { t: 'at', e: null, when };
    }

    const e = this.parseTail(this.parseExpr());
    this.expectEof();
    return e;
  }

  // optional 'in <durexpr>' / 'at <when>' suffix after an expression
  parseTail(e) {
    const tok = this.peek();
    if (tok.t === 'kw' && tok.kw === 'in') {
      this.next();
      return { t: 'in', e, d: this.parseExpr() };
    }
    if (tok.t === 'kw' && tok.kw === 'at') {
      this.next();
      return { t: 'at', e, when: this.parseWhen() };
    }
    return e;
  }

  // when := timeofday | weekday [timeofday] | ('today'|'tomorrow') [timeofday]
  parseWhen() {
    const tok = this.next();
    let base = null;
    if (tok.t === 'timeofday') return { t: 'when', day: null, tod: { h: tok.h, m: tok.m } };
    if (tok.t === 'weekday') base = { t: 'when', day: { dow: tok.dow } };
    else if (tok.t === 'kw' && (tok.kw === 'today' || tok.kw === 'tomorrow')) base = { t: 'when', day: { rel: tok.kw } };
    else err('PARSE', { at: tok.pos });

    const nxt = this.peek();
    if (nxt.t === 'timeofday') {
      this.next();
      base.tod = { h: nxt.h, m: nxt.m };
    }
    return base;
  }

  parseExpr(minPrec = 0) {
    let left = this.parseUnary();

    for (;;) {
      const tok = this.peek();
      const prec = tok.t === '+' || tok.t === '-' ? 1 : (tok.t === '*' || tok.t === '/' ? 2 : -1);
      if (prec < 0 || prec < minPrec) return left;
      this.next();

      // rate literal: expr / <unit>  (70/tick, 500/day, x/h)
      if (tok.t === '/' && this.peek().t === 'unit') {
        const unit = this.next();
        left = { t: 'per', e: left, factor: unit.factor };
        continue;
      }

      const right = this.parseExpr(prec + 1);
      left = { t: 'bin', op: tok.t, l: left, r: right };
    }
  }

  parseUnary() {
    const tok = this.peek();
    if (tok.t === '-') {
      this.next();
      return { t: 'neg', e: this.parseUnary() };
    }
    if (tok.t === '+') {
      this.next();
      return this.parseUnary();
    }
    return this.parsePrimary();
  }

  parsePrimary() {
    const tok = this.next();

    if (tok.t === 'num') {
      const nxt = this.peek();
      if (nxt.t === 'unit') { // duration literal: 4h, 30 min, 12 ticks
        this.next();
        return { t: 'dur', v: tok.v, factor: nxt.factor };
      }
      if (nxt.t === 'resword') { // amount literal: 9800 ideo
        this.next();
        const amt = { t: 'amt', v: tok.v, res: nxt.res };
        // rate literal with resource: 70 ideo/tick
        if (this.peek().t === '/' && this.peek(1).t === 'unit') {
          this.next();
          const unit = this.next();
          return { t: 'per', e: amt, factor: unit.factor };
        }
        return amt;
      }
      if (nxt.t === '%') {
        this.next();
        return { t: 'num', v: tok.v / 100 };
      }
      // rate literal: 70/tick, 500/day — must bind tighter than plain
      // division so `8400 / 70/tick` reads as 8400 ÷ (70 per tick).
      if (nxt.t === '/' && this.peek(1).t === 'unit') {
        this.next();
        const unit = this.next();
        return { t: 'per', e: { t: 'num', v: tok.v }, factor: unit.factor };
      }
      return { t: 'num', v: tok.v };
    }

    if (tok.t === 'resword') return { t: 'stock', res: tok.res };
    if (tok.t === 'income') return { t: 'income', res: tok.res };
    if (tok.t === 'lexslot') return { t: 'lexslot' };
    if (tok.t === 'word') return { t: 'name', name: tok.word };
    if (tok.t === 'unit') return { t: 'unitref', factor: tok.factor }; // bare 'h' in 'x/h' handled by 'per'; alone → error at eval

    if (tok.t === '(') {
      const e = this.parseExpr();
      if (this.next().t !== ')') err('PARSE', { at: tok.pos });
      return e;
    }

    err('PARSE', { at: tok.pos });
    return null;
  }
}

export function parse(src) {
  return new Parser(tokenize(src)).parseStatement();
}

// ---------------------------------------------------------------------------
// Quantity algebra
// ---------------------------------------------------------------------------

const scalar = (v, res = null) => ({ k: 'scalar', v, res });
const rate = (vPerHour, res = null) => ({ k: 'rate', vPerHour, res });
const dur = (s) => ({ k: 'dur', s });

function unifyRes(a, b) {
  if (a && b && a !== b) err('MIXED_RESOURCES', { a, b });
  return a || b;
}

function applyBin(op, l, r) {
  if (op === '+' || op === '-') {
    const sign = op === '+' ? 1 : -1;
    if (l.k === 'scalar' && r.k === 'scalar') return scalar(l.v + sign * r.v, unifyRes(l.res, r.res));
    if (l.k === 'rate' && r.k === 'rate') return rate(l.vPerHour + sign * r.vPerHour, unifyRes(l.res, r.res));
    if (l.k === 'dur' && r.k === 'dur') return dur(l.s + sign * r.s);
    if (l.k === 'dt' && r.k === 'dur') return { k: 'dt', ms: l.ms + sign * r.s * 1000 };
    if (l.k === 'dur' && r.k === 'dt' && op === '+') return { k: 'dt', ms: r.ms + l.s * 1000 };
    if (l.k === 'dt' && r.k === 'dt' && op === '-') return dur((l.ms - r.ms) / 1000);
    err('BAD_OP', { op, l: l.k, r: r.k });
  }

  if (op === '*') {
    if (l.k === 'scalar' && r.k === 'scalar') {
      if (l.res && r.res) err('BAD_OP', { op, l: l.res, r: r.res });
      return scalar(l.v * r.v, l.res || r.res);
    }
    if (l.k === 'scalar' && r.k === 'rate') {
      if (l.res) err('BAD_OP', { op, l: l.res, r: 'rate' });
      return rate(l.v * r.vPerHour, r.res);
    }
    if (l.k === 'rate' && r.k === 'scalar') return applyBin('*', r, l);
    if (l.k === 'rate' && r.k === 'dur') return scalar(l.vPerHour * (r.s / 3600), l.res);
    if (l.k === 'dur' && r.k === 'rate') return applyBin('*', r, l);
    if (l.k === 'scalar' && r.k === 'dur') {
      if (l.res) err('BAD_OP', { op, l: l.res, r: 'duration' });
      return dur(l.v * r.s);
    }
    if (l.k === 'dur' && r.k === 'scalar') return applyBin('*', r, l);
    err('BAD_OP', { op, l: l.k, r: r.k });
  }

  if (op === '/') {
    if (l.k === 'scalar' && r.k === 'scalar') {
      if (r.v === 0) err('DIV_ZERO');
      if (!r.res) return scalar(l.v / r.v, l.res);
      unifyRes(l.res, r.res);
      return scalar(l.v / r.v, null);
    }
    if (l.k === 'scalar' && r.k === 'rate') { // the ETA workhorse
      unifyRes(l.res, r.res);
      if (r.vPerHour === 0) err('DIV_ZERO');
      return dur((l.v / r.vPerHour) * 3600);
    }
    if (l.k === 'scalar' && r.k === 'dur') {
      if (r.s === 0) err('DIV_ZERO');
      return rate(l.v / (r.s / 3600), l.res);
    }
    if (l.k === 'rate' && r.k === 'scalar') {
      if (r.res) err('BAD_OP', { op, l: 'rate', r: r.res });
      if (r.v === 0) err('DIV_ZERO');
      return rate(l.vPerHour / r.v, l.res);
    }
    if (l.k === 'rate' && r.k === 'rate') {
      unifyRes(l.res, r.res);
      if (r.vPerHour === 0) err('DIV_ZERO');
      return scalar(l.vPerHour / r.vPerHour, null);
    }
    if (l.k === 'dur' && r.k === 'scalar') {
      if (r.res) err('BAD_OP', { op, l: 'duration', r: r.res });
      if (r.v === 0) err('DIV_ZERO');
      return dur(l.s / r.v);
    }
    if (l.k === 'dur' && r.k === 'dur') {
      if (r.s === 0) err('DIV_ZERO');
      return scalar(l.s / r.s, null);
    }
    err('BAD_OP', { op, l: l.k, r: r.k });
  }

  err('BAD_OP', { op, l: l.k, r: r.k });
  return null;
}

// ---------------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------------

const tickSeconds = (env) => 3600 / env.perHour;

function incomePerHour(env, res) {
  return env.resources[res].changePerUt * env.perHour;
}

function whenToMs(when, env) {
  const now = new Date(env.now);
  const target = new Date(env.now);
  target.setSeconds(0, 0);

  const tod = when.tod || { h: 0, m: 0 };
  target.setHours(tod.h, tod.m, 0, 0);

  if (when.day && typeof when.day.dow === 'number') {
    let delta = (when.day.dow - now.getDay() + 7) % 7;
    if (delta === 0 && target.getTime() <= env.now) delta = 7;
    target.setDate(target.getDate() + delta);
  } else if (when.day && when.day.rel === 'tomorrow') {
    target.setDate(target.getDate() + 1);
  } else if (when.day && when.day.rel === 'today') {
    // as-is
  } else if (!when.day) {
    // bare time of day: next occurrence
    if (target.getTime() <= env.now) target.setDate(target.getDate() + 1);
  }

  if (target.getTime() <= env.now) err('PAST_TIME');
  return target.getTime();
}

function projectResource(env, res, seconds) {
  return env.resources[res].value + incomePerHour(env, res) * (seconds / 3600);
}

function evalNode(node, env) {
  switch (node.t) {
    case 'num': return scalar(node.v, null);
    case 'amt': return scalar(node.v, node.res);
    case 'dur': {
      const factor = node.factor === 'tick' ? tickSeconds(env) : node.factor;
      return dur(node.v * factor);
    }
    case 'stock': return scalar(env.resources[node.res].value, node.res);
    case 'income': return rate(incomePerHour(env, node.res), node.res);
    case 'lexslot': {
      if (env.lexSlotCost == null) err('NO_DATA', { what: 'lex slot' });
      return scalar(env.lexSlotCost, 'ideology');
    }
    case 'name': {
      if (!env.names.has(node.name)) err('UNKNOWN_NAME', { name: node.name });
      return env.names.get(node.name);
    }
    case 'unitref': err('PARSE', {});
      return null;
    case 'neg': {
      const v = evalNode(node.e, env);
      if (v.k === 'scalar') return scalar(-v.v, v.res);
      if (v.k === 'rate') return rate(-v.vPerHour, v.res);
      if (v.k === 'dur') return dur(-v.s);
      err('BAD_OP', { op: '-', l: v.k });
      return null;
    }
    case 'per': {
      const v = evalNode(node.e, env);
      if (v.k !== 'scalar') err('BAD_OP', { op: '/unit', l: v.k });
      const factor = node.factor === 'tick' ? tickSeconds(env) : node.factor;
      return rate(v.v / (factor / 3600), v.res);
    }
    case 'bin': return applyBin(node.op, evalNode(node.l, env), evalNode(node.r, env));

    case 'until': {
      const target = evalNode(node.e, env);
      if (target.k !== 'scalar') err('BAD_OP', { op: 'until', l: target.k });
      if (!target.res) err('NEED_RESOURCE');
      const cur = env.resources[target.res].value;
      const need = target.v - cur;
      if (need <= 0) return { k: 'eta', res: target.res, target: target.v, reached: true, s: 0, when: env.now, paused: !env.isRunning };
      const rph = incomePerHour(env, target.res);
      if (rph <= 0) return { k: 'eta', res: target.res, target: target.v, never: true, need, paused: !env.isRunning };
      const s = (need / rph) * 3600;
      return { k: 'eta', res: target.res, target: target.v, need, s, when: env.now + s * 1000, paused: !env.isRunning };
    }

    case 'afford': {
      const cost = evalNode(node.e, env);
      if (cost.k !== 'scalar') err('BAD_OP', { op: 'afford', l: cost.k });
      if (!cost.res) err('NEED_RESOURCE');
      const cur = env.resources[cost.res].value;
      if (cur >= cost.v) return { k: 'afford', res: cost.res, cost: cost.v, ok: true, paused: !env.isRunning };
      const shortfall = cost.v - cur;
      const rph = incomePerHour(env, cost.res);
      if (rph <= 0) return { k: 'afford', res: cost.res, cost: cost.v, ok: false, shortfall, never: true, paused: !env.isRunning };
      const s = (shortfall / rph) * 3600;
      return { k: 'afford', res: cost.res, cost: cost.v, ok: false, shortfall, s, when: env.now + s * 1000, paused: !env.isRunning };
    }

    case 'in':
    case 'at': {
      let seconds;
      let when;
      if (node.t === 'in') {
        const d = evalNode(node.d, env);
        if (d.k !== 'dur') err('BAD_OP', { op: 'in', r: d.k });
        seconds = d.s;
        when = env.now + seconds * 1000;
      } else {
        when = whenToMs(node.when, env);
        seconds = (when - env.now) / 1000;
      }

      if (node.e === null) {
        const resources = {};
        ['credit', 'technology', 'ideology'].forEach((res) => {
          resources[res] = projectResource(env, res, seconds);
        });
        return { k: 'snapshot', s: seconds, when, resources, paused: !env.isRunning };
      }

      const base = evalNode(node.e, env);
      if (base.k !== 'scalar') err('BAD_OP', { op: node.t, l: base.k });
      if (!base.res) err('NEED_RESOURCE');
      const v = base.v + incomePerHour(env, base.res) * (seconds / 3600);
      return { k: 'projection', res: base.res, v, s: seconds, when, paused: !env.isRunning };
    }

    case 'assign': {
      if (isReservedName(node.name)) err('NAME_TAKEN', { name: node.name });
      const v = evalNode(node.e, env);
      env.names.set(node.name, v);
      return v;
    }

    default:
      err('PARSE', {});
      return null;
  }
}

function isReservedName(name) {
  return KEYWORDS.includes(name)
    || Object.prototype.hasOwnProperty.call(RESOURCE_WORDS, name)
    || Object.prototype.hasOwnProperty.call(INCOME_WORDS, name)
    || Object.prototype.hasOwnProperty.call(DURATION_UNITS, name)
    || Object.prototype.hasOwnProperty.call(WEEKDAYS, name)
    || LEXSLOT_WORDS.includes(name);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

const parseCache = new Map();
const PARSE_CACHE_MAX = 300;

function parseCached(src) {
  if (parseCache.has(src)) return parseCache.get(src);
  const ast = parse(src);
  if (parseCache.size >= PARSE_CACHE_MAX) parseCache.clear();
  parseCache.set(src, ast);
  return ast;
}

// Evaluate one line inside an existing env (env.names is read AND written —
// assignments define names for subsequent lines).
export function evaluateLine(src, env) {
  const ast = parseCached(src);
  return evalNode(ast, env);
}

// Evaluate an ordered document of lines; returns one entry per line:
//   { ok: true, value } | { ok: false, error: CalcError }
// A failed line never poisons the rest of the document.
export function evaluateDoc(lines, env) {
  env.names = new Map(); // always a fresh namespace — deleted lines must not linger
  return lines.map((src) => {
    try {
      return { ok: true, value: evaluateLine(src, env) };
    } catch (e) {
      if (e instanceof CalcError) return { ok: false, error: e };
      return { ok: false, error: new CalcError('PARSE', {}) };
    }
  });
}

// Autocomplete metadata for the UI. `insert` is the canonical text; labels
// are i18n ids resolved by the component (calc.suggest.<id>).
export const COMPLETIONS = [
  { id: 'credits', insert: 'credits', kind: 'variable' },
  { id: 'tech', insert: 'tech', kind: 'variable' },
  { id: 'ideo', insert: 'ideo', kind: 'variable' },
  { id: 'credit_income', insert: 'credit income', kind: 'variable' },
  { id: 'tech_income', insert: 'tech income', kind: 'variable' },
  { id: 'ideo_income', insert: 'ideo income', kind: 'variable' },
  { id: 'lex_slot', insert: 'lex slot', kind: 'variable' },
  { id: 'until', insert: 'until ', kind: 'function' },
  { id: 'in', insert: 'in ', kind: 'function' },
  { id: 'at', insert: 'at ', kind: 'function' },
  { id: 'afford', insert: 'afford ', kind: 'function' },
];
