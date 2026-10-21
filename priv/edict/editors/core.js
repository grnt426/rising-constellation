'use strict';

/*
 * Edict for code editors: completion, hover, signature help, an outline,
 * go-to-definition and the lexer's own checks.
 *
 * Everything an editor suggests comes from catalog.json, which the game
 * server generates from the same tables its checker and interpreter use, so
 * what the editor offers is exactly what the game accepts. The full check
 * (names, types, setup values) stays on the server: open or link the file in
 * the Scenario Workshop to see it.
 *
 * This module only reads the text it is given. It touches no files, network
 * or processes, and both adapters (extension.js for VS Code, edict-lsp.js for
 * every editor that speaks the Language Server Protocol) share it.
 *
 * Offsets are string indices (UTF-16 code units), as in both VS Code and the
 * LSP's default position encoding.
 */

const OPS2 = ['==', '!=', '<=', '>=', '=>'];
const OPS1 = '<>=+-*/(){}[],.:?';
const BIDI = /[\u202A-\u202E\u2066-\u2069\u200E\u200F]/g;
const BIDI_ONE = /[\u202A-\u202E\u2066-\u2069\u200E\u200F]/;
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;
// eslint-disable-next-line no-control-regex
const CONTROL_ONE = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/;
const ESCAPES = 'nt"\\{}';
// a `{` after one of these opens a record, not a block
const VALUE_BEFORE = new Set(['=', '(', ',', '[', ':', '=>', '+', '-', '*', '/', '==', '!=', '<', '<=', '>', '>=', '?']);
const VALUE_KW = new Set(['return', 'then', 'and', 'or', 'not', 'in']);
// builtins whose result is a list of the same items as their first argument
const SAME_LIST = new Set(['filter', 'sort_by', 'sort', 'reverse', 'unique', 'slice', 'concat', 'push']);
// builtins whose result is one item of their first argument
const ONE_ITEM = new Set(['first', 'last', 'find', 'max_by', 'min_by', 'pick']);

// Text from the file being edited (a function's comment) shown in a Markdown
// hover as plain text: no links, images or HTML. A shared file must not get
// to load a remote image the moment someone hovers a name.
const escapeMd = (text) => String(text).replace(/[\\`*_{}[\]()#+\-.!|<>~&]/g, '\\$&');

const isWordStart = (c) => /[A-Za-z_]/.test(c);
const isWord = (c) => /[A-Za-z0-9_]/.test(c);

// --- tokens -------------------------------------------------------------------

// Never throws: text being typed is usually incomplete. Each token is
// {t, v, s, e} with t one of nl, comment, str, num, ident, kw, op, bad.
function tokenize(text, keywords) {
  const toks = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === '\n' || c === ';') {
      toks.push({ t: 'nl', v: c, s: i, e: i + 1 });
      i += 1;
    } else if (c === ' ' || c === '\t' || c === '\r') {
      i += 1;
    } else if (c === '#') {
      let j = text.indexOf('\n', i);
      if (j < 0) j = n;
      toks.push({ t: 'comment', v: text.slice(i + 1, j), s: i, e: j });
      i = j;
    } else if (c === '"') {
      const tok = stringToken(text, i);
      toks.push(tok);
      i = tok.e;
    } else if (/[0-9]/.test(c)) {
      const m = /^\d[\d_]*(?:\.\d+)?(?:%|[hms](?:\d[\d_]*(?:\.\d+)?[hms])*)?/.exec(text.slice(i, i + 64));
      let j = i + m[0].length;
      let bad = false;
      while (j < n && isWord(text[j])) { j += 1; bad = true; }
      toks.push({
        t: 'num', v: text.slice(i, j), s: i, e: j, bad,
      });
      i = j;
    } else if (isWordStart(c)) {
      let j = i + 1;
      while (j < n && isWord(text[j])) j += 1;
      const v = text.slice(i, j);
      toks.push({
        t: keywords.has(v) ? 'kw' : 'ident', v, s: i, e: j,
      });
      i = j;
    } else if (OPS2.includes(text.slice(i, i + 2))) {
      toks.push({
        t: 'op', v: text.slice(i, i + 2), s: i, e: i + 2,
      });
      i += 2;
    } else if (OPS1.includes(c)) {
      toks.push({
        t: 'op', v: c, s: i, e: i + 1,
      });
      i += 1;
    } else {
      const cp = text.codePointAt(i);
      const len = cp > 0xffff ? 2 : 1;
      toks.push({
        t: 'bad', v: text.slice(i, i + len), s: i, e: i + len,
      });
      i += len;
    }
  }
  return toks;
}

// A string runs to its closing quote or the end of the line. Each `{…}` is
// a hole holding an expression; `open` marks one still being typed.
function stringToken(text, start) {
  const n = text.length;
  const holes = [];
  const badEscapes = [];
  let j = start + 1;
  let closed = false;
  while (j < n) {
    const d = text[j];
    if (d === '\\') {
      if (!ESCAPES.includes(text[j + 1] || '')) badEscapes.push(j);
      j += 2;
    } else if (d === '"') {
      closed = true;
      j += 1;
      break;
    } else if (d === '\n') {
      break;
    } else if (d === '{') {
      let k = j + 1;
      while (k < n && !'}"\n'.includes(text[k])) k += 1;
      if (text[k] === '}') {
        holes.push({ s: j + 1, e: k });
        j = k + 1;
      } else {
        holes.push({ s: j + 1, e: k, open: true });
        j = k;
      }
    } else {
      j += 1;
    }
  }
  return {
    t: 'str', v: text.slice(start + 1, closed ? j - 1 : j), s: start, e: Math.min(j, n), closed, holes, badEscapes,
  };
}

// --- types ----------------------------------------------------------------------

function typeName(t) {
  if (!t) return 'any';
  if (typeof t === 'string') return t;
  if (t.list) return `list of ${typeName(t.list)}`;
  if (t.record) return 'record';
  if (t.enum) return t.enum.map((v) => JSON.stringify(v)).join(' | ');
  return 'any';
}

function fmtSeconds(s) {
  if (s >= 3600 && s % 3600 === 0) return `${s / 3600}h`;
  if (s >= 60 && s % 60 === 0) return `${s / 60}m`;
  if (s >= 60) return `${Math.floor(s / 60)}m${s % 60}s`;
  return `${s}s`;
}

function numberValue(text) {
  const clean = text.replace(/_/g, '');
  if (clean.endsWith('%')) return { value: parseFloat(clean) / 100, kind: 'percentage' };
  const parts = clean.match(/(\d+(?:\.\d+)?)([hms])/g);
  if (parts) {
    const unit = { h: 3600, m: 60, s: 1 };
    const seconds = parts.reduce((acc, p) => acc + parseFloat(p) * unit[p[p.length - 1]], 0);
    return { value: seconds, kind: 'duration' };
  }
  return { value: parseFloat(clean), kind: 'number' };
}

// --- the engine ---------------------------------------------------------------------

function createEdict(catalog) {
  const keywords = new Set(catalog.keywords);
  const builtins = new Map(catalog.builtins.map((b) => [b.name, b]));
  const actions = new Map(catalog.actions.map((a) => [a.name, a]));
  const setupFields = new Map(catalog.setup.map((f) => [f.name, f]));
  const roots = Object.keys(catalog.world);
  const docs = catalog.world_docs || {};
  const kwDocs = catalog.keyword_docs || {};
  const rootDocs = catalog.root_docs || {};
  const enums = catalog.enums || {};
  const patentTitles = enums.patent_titles || {};
  // patents by the names scripts use, with the title players know
  const patents = () => (enums.patents || []).map((p) => ({ value: p, detail: patentTitles[p] || 'patent' }));

  const sig = (name) => builtins.get(name) || actions.get(name) || null;

  // --- reading a document -----------------------------------------------------------

  // Walk the tokens once and record the structure an editor needs: every
  // bracket's frame (what opened it, what it declares), top-level parts, and
  // user functions. `upTo` stops the walk at an offset (for the scope there).
  function scan(text, upTo = Infinity) {
    const toks = tokenize(text, keywords);
    const sig2 = toks.filter((t) => t.t !== 'comment');
    const frames = [];
    const top = [];
    const fns = new Map();
    const topVars = new Map();
    let pending = [];
    let stmtHead = null;
    let i = 0;

    const prevSig = (k) => (k > 0 ? sig2[k - 1] : null);
    const innermostBlock = () => {
      for (let f = frames.length - 1; f >= 0; f -= 1) if (frames[f].ch === '{') return frames[f];
      return null;
    };
    const declare = (decl) => {
      const frame = innermostBlock();
      if (frame) frame.decls.push(decl);
      else topVars.set(decl.name, decl);
    };

    for (i = 0; i < sig2.length; i += 1) {
      const tok = sig2[i];
      if (tok.s >= upTo) break;
      const prev = prevSig(i);
      const atStart = !prev || prev.t === 'nl' || (prev.t === 'op' && (prev.v === '{' || prev.v === '}'));
      if (atStart && tok.t !== 'nl') stmtHead = { tok, index: i, depth: frames.length };

      if (tok.t === 'kw' && (tok.v === 'let' || tok.v === 'var') && sig2[i + 1] && sig2[i + 1].t === 'ident') {
        const name = sig2[i + 1];
        const decl = {
          name: name.v, s: name.s, e: name.e, kind: tok.v, exprAt: i + 3,
        };
        if (tok.v === 'var' && frames.length === 0) topVars.set(name.v, decl);
        else declare(decl);
      } else if (tok.t === 'kw' && tok.v === 'fn' && sig2[i + 1] && sig2[i + 1].t === 'ident') {
        const name = sig2[i + 1];
        const params = [];
        let k = i + 2;
        if (sig2[k] && sig2[k].v === '(') {
          k += 1;
          while (sig2[k] && sig2[k].v !== ')' && sig2[k].t !== 'nl') {
            if (sig2[k].t === 'ident') params.push({ name: sig2[k].v, s: sig2[k].s, e: sig2[k].e });
            k += 1;
          }
        }
        if (frames.length === 0) {
          fns.set(name.v, {
            name: name.v, params, s: name.s, e: name.e, at: tok.s, note: noteAbove(toks, tok),
          });
        }
        pending = params.map((p) => ({ ...p, kind: 'param' }));
      } else if (tok.t === 'kw' && tok.v === 'for' && sig2[i + 1] && sig2[i + 1].t === 'ident') {
        const name = sig2[i + 1];
        pending = [{
          name: name.v, s: name.s, e: name.e, kind: 'loop', loopExprAt: i + 3,
        }];
      } else if (tok.t === 'kw' && tok.v === 'as' && sig2[i + 1] && sig2[i + 1].t === 'ident') {
        const name = sig2[i + 1];
        pending = [{
          name: name.v, s: name.s, e: name.e, kind: 'count', type: 'number',
        }];
      } else if (tok.t === 'op' && tok.v === '=>') {
        // lambda parameters: `x =>` or `(a, b) =>`; they live until the
        // bracket around the lambda closes
        const params = [];
        if (prev && prev.t === 'ident') params.push(prev);
        else if (prev && prev.v === ')') {
          let k = i - 2;
          while (k >= 0 && sig2[k].v !== '(') {
            if (sig2[k].t === 'ident') params.push(sig2[k]);
            k -= 1;
          }
        }
        const owner = frames[frames.length - 1];
        params.forEach((p) => {
          const decl = {
            name: p.v, s: p.s, e: p.e, kind: 'lambda', lambdaOf: owner || null,
          };
          if (owner) owner.decls.push(decl);
        });
      } else if (tok.t === 'op' && (tok.v === '(' || tok.v === '[')) {
        const callee = tok.v === '(' && prev && prev.t === 'ident' && prev.e === tok.s ? prev.v : null;
        frames.push({
          ch: tok.v, s: tok.s, index: i, callee, decls: [],
        });
      } else if (tok.t === 'op' && tok.v === '{') {
        const record = prev && ((prev.t === 'op' && VALUE_BEFORE.has(prev.v)) || (prev.t === 'kw' && VALUE_KW.has(prev.v)));
        let kind = 'block';
        if (record) kind = 'record';
        else if (stmtHead && stmtHead.depth === frames.length) {
          const h = stmtHead.tok;
          if (h.v === 'setup') kind = 'setup';
          else if (h.v === 'fn') kind = 'fn';
          else if (h.v === 'draft') kind = 'draft';
          else if (['on', 'every', 'at', 'when'].includes(h.v)) kind = 'handler';
          else if (h.v === 'for' || h.v === 'while') kind = 'loop';
          else if (h.v === 'if' || h.v === 'else' || h.v === '}') kind = 'if';
        }
        if (prev && prev.t === 'kw' && prev.v === 'else') kind = 'if';
        const frame = {
          ch: '{', s: tok.s, index: i, kind, decls: record ? [] : pending, head: stmtHead,
        };
        if (!record) pending = [];
        // a record's key `patent_discounts = {` names what the record is for
        if (record && prev && prev.v === '=' && sig2[i - 2] && sig2[i - 2].t === 'ident') frame.field = sig2[i - 2].v;
        frames.push(frame);
        if (frames.length === 1) top.push({ head: stmtHead, open: tok });
      } else if (tok.t === 'op' && (tok.v === ')' || tok.v === ']' || tok.v === '}')) {
        const want = { ')': '(', ']': '[', '}': '{' }[tok.v];
        for (let f = frames.length - 1; f >= 0; f -= 1) {
          if (frames[f].ch === want) {
            frames.length = f;
            break;
          }
        }
      }
    }

    return {
      toks, sig: sig2, frames, fns, topVars, stopped: i,
    };
  }

  // The comment lines right above a declaration, as its note.
  function noteAbove(toks, declTok) {
    const k = toks.indexOf(declTok);
    const lines = [];
    let j = k - 1;
    if (toks[j] && toks[j].t === 'nl') j -= 1;
    while (j >= 0 && toks[j].t === 'comment') {
      lines.unshift(toks[j].v.trim());
      j -= 1;
      if (toks[j] && toks[j].t === 'nl' && toks[j].v === '\n') j -= 1;
      else break;
    }
    return lines.join(' ');
  }

  // Visible names at the end of a scan: innermost first.
  function visible(state) {
    const out = new Map();
    for (let f = state.frames.length - 1; f >= 0; f -= 1) {
      state.frames[f].decls.forEach((d) => { if (!out.has(d.name)) out.set(d.name, d); });
    }
    state.topVars.forEach((d, name) => { if (!out.has(name)) out.set(name, d); });
    return out;
  }

  // --- type inference (enough to complete fields) -------------------------------------

  // The expression starting at sig[k]: up to a depth-0 comma, closing
  // bracket or line end (or the block after it: `for s in xs {`).
  function exprEnd(sigToks, k, beforeBlock = false) {
    let depth = 0;
    let j = k;
    for (; j < sigToks.length; j += 1) {
      const t = sigToks[j];
      if (t.t === 'nl' && depth === 0) break;
      if (beforeBlock && depth === 0 && t.v === '{' && j > k) break;
      if (t.t === 'op') {
        if ('([{'.includes(t.v)) depth += 1;
        else if (')]}'.includes(t.v)) {
          if (depth === 0) break;
          depth -= 1;
        } else if (t.v === ',' && depth === 0) break;
      }
    }
    return j;
  }

  // {type, doc} for the tokens sig[a..b), or null when it can't be told
  // without running the script.
  function typeOf(state, a, b, names, seen = new Set()) {
    const t = state.sig;
    if (a >= b) return null;
    // a call: list builtins keep or pick from their first argument
    if (t[a].t === 'ident' && t[a + 1] && t[a + 1].v === '(' && builtins.has(t[a].v)) {
      const close = matching(t, a + 1);
      if (close !== b - 1) return null;
      const argEnd = exprEnd(t, a + 2);
      const arg = typeOf(state, a + 2, argEnd, names, seen);
      if (!arg) return null;
      if (SAME_LIST.has(t[a].v)) return arg;
      if (ONE_ITEM.has(t[a].v) && arg.type && arg.type.list) return { type: arg.type.list, doc: `${arg.doc}[]` };
      return null;
    }
    // a path: root(.field | [index])*
    if (t[a].t !== 'ident') return null;
    let cur = rootType(state, t[a].v, names, seen);
    let k = a + 1;
    while (cur && k < b) {
      if (t[k].v === '.' && t[k + 1] && (t[k + 1].t === 'ident' || t[k + 1].t === 'kw')) {
        const field = t[k + 1].v;
        cur = cur.type && cur.type.record && cur.type.record[field]
          ? { type: cur.type.record[field], doc: cur.doc ? `${cur.doc}.${field}` : null } : null;
        k += 2;
      } else if (t[k].v === '[') {
        const close = matching(t, k);
        cur = cur.type && cur.type.list ? { type: cur.type.list, doc: cur.doc ? `${cur.doc}[]` : null } : null;
        k = close + 1;
      } else {
        return null;
      }
    }
    return k === b ? cur : null;
  }

  function rootType(state, name, names, seen) {
    if (names && names.has(name)) {
      const d = names.get(name);
      if (d.type) return { type: d.type, doc: null };
      if (seen.has(d)) return null;
      seen.add(d);
      if (d.kind === 'loop') {
        const end = exprEnd(state.sig, d.loopExprAt, true);
        const list = typeOf(state, d.loopExprAt, end, names, seen);
        return list && list.type && list.type.list ? { type: list.type.list, doc: list.doc ? `${list.doc}[]` : null } : null;
      }
      if (d.kind === 'let' || d.kind === 'var') {
        const end = exprEnd(state.sig, d.exprAt);
        return typeOf(state, d.exprAt, end, names, seen);
      }
      if (d.kind === 'lambda' && d.lambdaOf && d.lambdaOf.callee && builtins.has(d.lambdaOf.callee)) {
        const start = d.lambdaOf.index + 1;
        const list = typeOf(state, start, exprEnd(state.sig, start), names, seen);
        return list && list.type && list.type.list ? { type: list.type.list, doc: list.doc ? `${list.doc}[]` : null } : null;
      }
      return null;
    }
    if (catalog.world[name]) return { type: catalog.world[name], doc: name };
    return null;
  }

  function matching(t, k) {
    const open = t[k].v;
    const close = { '(': ')', '[': ']', '{': '}' }[open];
    let depth = 0;
    for (let j = k; j < t.length; j += 1) {
      if (t[j].v === open) depth += 1;
      else if (t[j].v === close) {
        depth -= 1;
        if (depth === 0) return j;
      }
    }
    return t.length;
  }

  // --- docs -------------------------------------------------------------------------------

  function paramLabel(p) {
    if (p.rest) return `${p.name}...`;
    return `${p.name}${p.optional ? '?' : ''}: ${typeName(p.type)}`;
  }

  function signatureLabel(s) {
    const parts = s.params.map(paramLabel).concat((s.named || []).map((p) => `${p.name}: ${typeName(p.type)}`));
    const ret = s.kind === 'action' ? '' : ` → ${typeName(s.returns)}`;
    return `${s.name}(${parts.join(', ')})${ret}`;
  }

  function signatureDoc(s) {
    const lines = ['```edict', signatureLabel(s), '```', s.doc];
    if (s.kind === 'action') lines.push('', '*Action: changes the game. Only handlers and functions they call can act.*');
    if (s.named && s.named.length) lines.push('', `Named: ${s.named.map((p) => `\`${p.name}:\``).join(', ')} (optional).`);
    return lines.join('\n');
  }

  function fieldDoc(path, type) {
    const doc = path ? docs[path] : null;
    return ['```edict', `${path || ''}: ${typeName(type)}`, '```', doc || ''].join('\n').trim();
  }

  function setupDoc(f) {
    // (the docs of bounded fields already give their range)
    const lines = ['```edict', `${f.name} = …  (${typeName(f.type)})`, '```', f.doc];
    if (f.default !== null && f.default !== undefined && f.default !== '' && !(Array.isArray(f.default) && !f.default.length)) {
      const d = f.name === 'time_limit' ? fmtSeconds(f.default) : JSON.stringify(f.default);
      lines.push('', `Left out: ${d}.`);
    }
    return lines.join('\n');
  }

  function userFnDoc(fn) {
    return ['```edict', `fn ${fn.name}(${fn.params.map((p) => p.name).join(', ')})`, '```', fn.note ? escapeMd(fn.note) : 'A function in this script.'].join('\n');
  }

  // --- snippets ---------------------------------------------------------------------------

  const choice = (values) => `\${1|${values.map((v) => JSON.stringify(v).replace(/[,|]/g, '\\$&')).join(',')}|}`;

  function callSnippet(s) {
    let n = 0;
    const args = s.params.filter((p) => !p.optional || p.rest).slice(0, 4).map((p) => {
      n += 1;
      if (p.type && p.type.enum) return choice(p.type.enum).replace('${1', `\${${n}`);
      return `\${${n}:${p.name}}`;
    });
    return `${s.name}(${args.join(', ')})`;
  }

  const TOP_SNIPPETS = [
    ['setup', 'setup {\n\tname = "${1:My scenario}"\n\tdescription = "${2:What the player should do.}"\n\ttime_limit = ${3:20m}\n}\n$0', 'The world: name, description, time limit and more.'],
    ['score', 'score ${1:player.credit}', 'How players are ranked: higher is better.'],
    ['tiebreak', 'tiebreak ${1:player.income.credit}', 'Breaks ties between equal scores: higher ranks first.'],
    ['var', 'var ${1:name} = ${2:0}', 'State the scenario keeps between events.'],
    ['fn', 'fn ${1:name}(${2:value}) {\n\t$0\n}', 'A named function, callable from anywhere.'],
    ['on start', 'on start {\n\t$0\n}', 'Runs once, as the run begins.'],
    ['on end', 'on end {\n\t$0\n}', 'Runs once when the run ends, after the score is counted.'],
    ['every', 'every ${1:15s} as ${2:n} {\n\t$0\n}', 'Runs again and again on a schedule; `as n` counts the runs.'],
    ['every … from … until', 'every ${1:1m} from ${2:5m} until ${3:20m} {\n\t$0\n}', 'A schedule that starts and stops at given times.'],
    ['at', 'at ${1:10m} {\n\t$0\n}', 'Runs once, when the clock reaches that time.'],
    ['when', 'when ${1:player.credit >= 1_000_000} {\n\t$0\n}', 'Runs each time the condition turns true.'],
    ['draft', 'draft {\n\t$0\n}', 'Code that never runs and is never checked.'],
  ];

  const STMT_SNIPPETS = [
    ['let', 'let ${1:name} = ${2:value}', 'A local name for a value.'],
    ['if', 'if ${1:condition} {\n\t$0\n}', 'Run the steps only when the condition is true.'],
    ['if … else', 'if ${1:condition} {\n\t$2\n} else {\n\t$0\n}', 'One set of steps or the other.'],
    ['for', 'for ${1:s} in ${2:player.systems} {\n\t$0\n}', 'Repeat the steps for each item of a list.'],
    ['while', 'while ${1:condition} {\n\t$0\n}', 'Repeat the steps while the condition is true.'],
  ];

  function setupSnippet(f) {
    const t = f.type;
    if (f.name === 'time_limit') return 'time_limit = ${1:20m}';
    if (t && t.enum) return `${f.name} = ${choice(t.enum)}`;
    if (t === 'text') return `${f.name} = "\${1}"`;
    if (t === 'bool') return `${f.name} = \${1|true,false|}`;
    if (t && t.list) return `${f.name} = ["\${1}"]`;
    if (t === 'record') return `${f.name} = {\${1:key}: \${2:50%}}`;
    return `${f.name} = \${1:${f.default === null || f.default === undefined ? 1 : f.default}}`;
  }

  // --- completion --------------------------------------------------------------------------

  // {range: {start, end}, items: [{label, kind, detail, doc, insert, snippet, sort}]}
  function complete(text, offset) {
    const state = scan(text, offset);
    // functions can be called before the line that declares them
    state.fns = scan(text).fns;
    const { toks } = state;
    const at = toks.find((t) => t.s < offset && offset <= t.e) || null;

    if (at && at.t === 'comment') return { range: { start: offset, end: offset }, items: [] };
    if (at && at.t === 'str' && !(at.closed && offset === at.e)) return completeInString(text, offset, at, state);

    const word = at && (at.t === 'ident' || at.t === 'kw') ? at : null;
    const start = word ? word.s : offset;
    const range = { start, end: offset };
    const before = toks.filter((t) => t.e <= start && t.t !== 'comment');
    const prev = before[before.length - 1] || null;

    if (prev && prev.t === 'op' && prev.v === '.' && prev.e === start) {
      return { range, items: memberItems(state, before.slice(0, -1)) };
    }
    return { range, items: contextItems(state, before, prev) };
  }

  function memberItems(state, before) {
    // walk back over the path in front of the dot
    let k = before.length - 1;
    let depth = 0;
    while (k >= 0) {
      const t = before[k];
      if (t.v === ']') depth += 1;
      else if (t.v === '[') depth -= 1;
      else if (depth === 0 && !(t.t === 'ident' || t.v === '.')) break;
      k -= 1;
    }
    const pathToks = before.slice(k + 1);
    const a = state.sig.indexOf(pathToks[0]);
    const b = state.sig.indexOf(pathToks[pathToks.length - 1]) + 1;
    const names = visible(state);
    const base = a >= 0 ? typeOf(state, a, b, names) : null;
    if (base && base.type && base.type.record) {
      return Object.keys(base.type.record).sort().map((field) => {
        const type = base.type.record[field];
        const path = base.doc ? `${base.doc}.${field}` : null;
        return {
          label: field,
          kind: type && type.record ? 'module' : 'field',
          detail: typeName(type),
          doc: fieldDoc(path || field, type),
          insert: field,
          sort: '0',
        };
      });
    }
    if (base) return [];
    // unknown: every field a record in the world has, with where it's from
    const seen = new Map();
    const walk = (type, path) => {
      if (type && type.list) walk(type.list, `${path}[]`);
      else if (type && type.record) {
        Object.entries(type.record).forEach(([f, t]) => {
          if (!seen.has(f) && path.includes('[]')) seen.set(f, { type: t, path: `${path}.${f}` });
          walk(t, `${path}.${f}`);
        });
      }
    };
    Object.entries(catalog.world).forEach(([root, t]) => walk(t, root));
    return [...seen.entries()].sort(([x], [y]) => x.localeCompare(y)).map(([f, { type, path }]) => ({
      label: f, kind: 'field', detail: `${typeName(type)} (on ${path.replace(/\.[^.]+$/, '')})`, doc: fieldDoc(path, type), insert: f, sort: '1',
    }));
  }

  function contextItems(state, before, prev) {
    const frame = state.frames[state.frames.length - 1] || null;
    const block = [...state.frames].reverse().find((f) => f.ch === '{') || null;
    const lineStart = !prev || prev.t === 'nl' || (prev.t === 'op' && (prev.v === '{' || prev.v === '}'));
    const items = [];

    // `on ` → start | end
    if (prev && prev.t === 'kw' && prev.v === 'on') {
      return [
        {
          label: 'start', kind: 'event', doc: kwDocs.on || '', insert: 'start', sort: '0',
        },
        {
          label: 'end', kind: 'event', doc: kwDocs.on_end || '', insert: 'end', sort: '0',
        },
      ];
    }
    if (prev && prev.t === 'kw' && ['let', 'var', 'fn', 'as', 'for'].includes(prev.v)) return [];
    // for s |  →  in
    const prev2 = before[before.length - 2];
    if (prev && prev.t === 'ident' && prev2 && prev2.t === 'kw' && prev2.v === 'for') {
      return [{
        label: 'in', kind: 'keyword', doc: kwDocs.in || '', insert: 'in ', sort: '0',
      }];
    }

    // top level
    if (!frame && lineStart) {
      const hasSetup = state.sig.some((t, i) => t.t === 'kw' && t.v === 'setup' && state.sig[i + 1] && state.sig[i + 1].v === '{');
      TOP_SNIPPETS.forEach(([label, body, doc]) => {
        if (label === 'setup' && hasSetup) return;
        items.push({
          label, kind: 'snippet', doc, insert: body, snippet: true, sort: '0',
        });
      });
      return items;
    }

    // inside setup { … }: the fields not set yet
    if (frame && frame.kind === 'setup' && lineStart) {
      const set = new Set();
      const to = matching(state.sig, frame.index);
      for (let k = frame.index + 1; k < to; k += 1) {
        const t = state.sig[k];
        if (t.t === 'ident' && state.sig[k + 1] && state.sig[k + 1].v === '=') set.add(t.v);
      }
      catalog.setup.forEach((f) => {
        if (set.has(f.name)) return;
        items.push({
          label: f.name, kind: 'property', detail: typeName(f.type), doc: setupDoc(f), insert: setupSnippet(f), snippet: true, sort: '0',
        });
      });
      return items;
    }

    // a record's keys: patent_discounts = { capital_1: 20% }
    if (frame && frame.kind === 'record' && (prev.v === '{' || prev.v === ',' || prev.t === 'nl')) {
      if (frame.field === 'patent_discounts') {
        return (enums.patents || []).map((p) => ({
          label: p, kind: 'enum', detail: patentTitles[p] || 'patent', insert: `${p}: \${1:50%}`, snippet: true, sort: '0',
        }));
      }
      return [];
    }

    const inCode = block && ['fn', 'handler', 'if', 'loop', 'block', 'draft'].includes(block.kind);
    const inFn = state.frames.some((f) => f.kind === 'fn');
    const inLoop = state.frames.some((f) => f.kind === 'loop');

    // named arguments, at the start of an argument
    if (frame && frame.ch === '(' && frame.callee && (prev.v === '(' || prev.v === ',')) {
      const used = new Set();
      for (let k = frame.index + 1; k < state.sig.length && state.sig[k].s < (prev ? prev.e : 0); k += 1) {
        if (state.sig[k].t === 'ident' && state.sig[k + 1] && state.sig[k + 1].v === ':') used.add(state.sig[k].v);
      }
      const s = sig(frame.callee);
      const userFn = state.fns.get(frame.callee);
      const named = s ? s.named || [] : (userFn ? userFn.params.map((p) => ({ name: p.name, type: null })) : []);
      named.filter((p) => !used.has(p.name)).forEach((p) => {
        items.push({
          label: `${p.name}:`,
          kind: 'property',
          detail: typeName(p.type),
          doc: s ? signatureDoc(s) : '',
          insert: p.type && p.type.enum ? `${p.name}: ${choice(p.type.enum)}` : `${p.name}: `,
          snippet: !!(p.type && p.type.enum),
          sort: '0',
        });
      });
    }

    if (inCode && lineStart) {
      STMT_SNIPPETS.forEach(([label, body, doc]) => items.push({
        label, kind: 'snippet', doc, insert: body, snippet: true, sort: '2',
      }));
      if (inFn) {
        items.push({
          label: 'return', kind: 'keyword', doc: kwDocs.return || '', insert: 'return ', sort: '2',
        });
      }
      if (inLoop) {
        ['break', 'continue'].forEach((k) => items.push({
          label: k, kind: 'keyword', doc: kwDocs[k] || '', insert: k, sort: '2',
        }));
      }
      catalog.actions.forEach((a) => items.push({
        label: a.name, kind: 'action', detail: 'action', doc: signatureDoc(a), insert: callSnippet(a), snippet: true, sort: '1',
      }));
    }

    return items.concat(exprItems(state));
  }

  // What a value can be made of: names in scope, functions, the world,
  // builtins and the value keywords.
  function exprItems(state) {
    const items = [];
    visible(state).forEach((d, name) => items.push({
      label: name,
      kind: 'variable',
      detail: { param: 'parameter', loop: 'loop item', count: 'count', lambda: 'parameter' }[d.kind] || d.kind,
      doc: '',
      insert: name,
      sort: '0',
    }));
    state.fns.forEach((fn) => items.push({
      label: fn.name, kind: 'function', detail: 'fn', doc: userFnDoc(fn), insert: `${fn.name}(\${1})`, snippet: true, sort: '1',
    }));
    roots.forEach((r) => items.push({
      label: r, kind: 'module', detail: 'world', doc: rootDocs[r] || '', insert: r, sort: '1',
    }));
    catalog.builtins.forEach((b) => items.push({
      label: b.name, kind: 'function', detail: b.group, doc: signatureDoc(b), insert: callSnippet(b), snippet: true, sort: '3',
    }));
    ['true', 'false', 'nil', 'not', 'and', 'or', 'in'].forEach((k) => items.push({
      label: k, kind: 'keyword', doc: kwDocs[k] || '', insert: k, sort: '4',
    }));
    items.push({
      label: 'if … then … else', kind: 'snippet', doc: 'A value that depends on a condition.', insert: 'if ${1:condition} then ${2:a} else ${3:b}', snippet: true, sort: '4',
    });
    return items;
  }

  // Inside "…": holes complete like code; otherwise suggest the values the
  // place takes (a resource, a tone, a faction, a patent key).
  function completeInString(text, offset, str, state) {
    const hole = str.holes.find((h) => h.s <= offset && offset <= h.e);
    if (hole) {
      // complete the hole as if its text stood on a line of its own, in the
      // same place: same scope, same names
      const head = text.slice(0, str.s);
      const synthetic = `${head}\n${text.slice(hole.s, offset)}`;
      const inner = complete(synthetic, synthetic.length);
      const shift = hole.s - (head.length + 1);
      return {
        range: { start: inner.range.start + shift, end: offset },
        items: inner.items.filter((i) => i.kind !== 'snippet' && i.kind !== 'action' && !['return', 'break', 'continue'].includes(i.label)),
      };
    }

    const range = { start: str.s + 1, end: offset };
    const values = stringValues(state, str);
    return {
      range,
      items: values.map((v) => ({
        label: v.value, kind: 'enum', detail: v.detail, doc: v.doc || '', insert: v.value, sort: '0',
      })),
    };
  }

  function stringValues(state, str) {
    const t = state.sig;
    const k = t.indexOf(str);
    const prev = t[k - 1];
    const prev2 = t[k - 2];
    const frame = state.frames[state.frames.length - 1] || null;
    const list = (vals, detail) => vals.map((value) => (typeof value === 'string' ? { value, detail } : value));

    // `name: "…"` — a named argument
    if (prev && prev.v === ':' && prev2 && prev2.t === 'ident' && frame && frame.ch === '(' && frame.callee) {
      const s = sig(frame.callee);
      const p = s && (s.named || []).find((x) => x.name === prev2.v);
      if (p && p.type && p.type.enum) return list(p.type.enum, p.name);
    }
    // a positional argument
    if (frame && frame.ch === '(' && frame.callee && sig(frame.callee)) {
      let index = 0;
      let depth = 0;
      for (let j = frame.index + 1; j < k; j += 1) {
        if ('([{'.includes(t[j].v)) depth += 1;
        else if (')]}'.includes(t[j].v)) depth -= 1;
        else if (t[j].v === ',' && depth === 0) index += 1;
      }
      const s = sig(frame.callee);
      const p = s.params[Math.min(index, s.params.length - 1)];
      if (p && p.type && p.type.enum) return list(p.type.enum, p.name);
      // contains(player.patents, "…")
      if (frame.callee === 'contains' && index === 1) {
        const argEnd = exprEnd(t, frame.index + 1);
        const pathText = t.slice(frame.index + 1, argEnd).map((x) => x.v).join('');
        if (pathText === 'player.patents') return patents();
      }
    }
    // inside setup: faction = "…", mutators = ["…"], grant_patents = ["…"]
    const setupFrame = state.frames.find((f) => f.kind === 'setup');
    if (setupFrame) {
      let j = k - 1;
      while (j > setupFrame.index && !(t[j].t === 'ident' && t[j + 1] && t[j + 1].v === '=')) j -= 1;
      const field = j > setupFrame.index ? setupFields.get(t[j].v) : null;
      if (field && field.type && field.type.enum) return list(field.type.enum, field.name);
      if (field && field.name === 'mutators') {
        return (enums.mutators || []).map((m) => ({
          value: m.key, detail: `${m.name}${m.polarity ? ` (${m.polarity})` : ''}`, doc: m.description || '',
        }));
      }
      if (field && field.name === 'grant_patents') return patents();
    }
    // "capital_1" in player.patents ; a.type == "…"
    const next = t[k + 1];
    if (next && next.t === 'kw' && next.v === 'in') {
      const end = exprEnd(t, k + 2, true);
      const pathText = t.slice(k + 2, end).map((x) => x.v).join('');
      if (pathText === 'player.patents') return patents();
    }
    if (prev && (prev.v === '==' || prev.v === '!=')) {
      let a = k - 2;
      while (a > 0 && (t[a - 1].t === 'ident' || t[a - 1].t === 'kw' || t[a - 1].v === '.')) a -= 1;
      const ty = typeOf(state, a, k - 1, visible(state));
      if (ty && ty.type && ty.type.enum) return list(ty.type.enum, 'value');
    }
    return [];
  }

  // --- hover -----------------------------------------------------------------------------------

  // The docs entry for the name under the cursor: {key, range}, where key is
  // `builtin:give`, `action:notify`, `event:every`, `keyword:let`,
  // `operator:in`, `setup:time_limit`, `world:player.systems[].population`
  // or `fn:<a function in this script>`; null for anything else.
  function docKey(text, offset) {
    const state = scan(text, Infinity);
    const tok = state.toks.find((t) => t.s <= offset && offset < t.e)
      || state.toks.find((t) => t.s < offset && offset === t.e && (t.t === 'ident' || t.t === 'kw'));
    if (!tok) return null;
    const range = { start: tok.s, end: tok.e };
    const k = state.sig.indexOf(tok);
    const prev = state.sig[k - 1];
    const next = state.sig[k + 1];
    const at = (key) => ({ key, range });

    if (tok.t === 'kw') {
      if (tok.v === 'on') return at(next && next.v === 'end' ? 'event:on_end' : 'event:on_start');
      if (['every', 'at', 'when'].includes(tok.v)) return at(`event:${tok.v}`);
      // `in` after `for s` names the loop's list; anywhere else it's the operator
      if (tok.v === 'in') return at(state.sig[k - 2] && state.sig[k - 2].v === 'for' ? 'keyword:in' : 'operator:in');
      if (['and', 'or', 'not'].includes(tok.v)) return at(`operator:${tok.v}`);
      return at(`keyword:${tok.v}`);
    }
    if (tok.t === 'op') {
      if (tok.v === '-' && (!prev || prev.t === 'op' || prev.t === 'nl' || prev.t === 'kw')) return at('operator:negate');
      return ['+', '-', '*', '/', '==', '!=', '<', '<=', '>', '>='].includes(tok.v) ? at(`operator:${tok.v}`) : null;
    }
    if (tok.t !== 'ident') return null;
    if (prev && prev.t === 'kw' && prev.v === 'on') return at(tok.v === 'end' ? 'event:on_end' : 'event:on_start');

    const scope = scan(text, tok.s);
    const names = visible(scope);
    if (prev && prev.v === '.') {
      let a = k - 1;
      while (a > 0 && (state.sig[a - 1].t === 'ident' || state.sig[a - 1].v === '.' || state.sig[a - 1].v === ']')) {
        if (state.sig[a - 1].v === ']') a = indexOfOpen(state.sig, a - 1);
        else a -= 1;
      }
      const ty = typeOf(state, a, k + 1, names);
      return ty && ty.doc ? at(`world:${ty.doc}`) : null;
    }
    const setupFrame = scope.frames.find((f) => f.kind === 'setup');
    if (setupFrame && next && next.v === '=' && setupFields.has(tok.v)) return at(`setup:${tok.v}`);
    if (names.has(tok.v)) return null;
    if (state.fns.has(tok.v)) return at(`fn:${tok.v}`);
    if (builtins.has(tok.v)) return at(`builtin:${tok.v}`);
    if (actions.has(tok.v)) return at(`action:${tok.v}`);
    if (catalog.world[tok.v]) return at(`world:${tok.v}`);
    return null;
  }

  // A docs entry (catalog.docs) as Markdown for an editor's hover.
  function docMarkdown(d) {
    const lines = [`**${d.title}**${d.kind ? ` · ${d.kind}` : ''}`, '', d.summary];
    if (d.details) lines.push('', d.details);
    if (d.usage) lines.push('', '```edict', d.usage, '```');
    if (d.inputs && d.inputs.length) lines.push('', ...d.inputs.map((i) => `- \`${i.name}\`: ${i.doc}`));
    if (d.output) lines.push('', `Gives: ${d.output}`);
    if (d.examples && d.examples.length) {
      lines.push('', '```edict', ...d.examples.map((x) => (x.result != null ? `${x.code}   # ${x.result}` : x.code)), '```');
    }
    return lines.join('\n');
  }

  function hover(text, offset) {
    // the full docs, where the catalog has them
    const found = docKey(text, offset);
    const entry = found && catalog.docs && catalog.docs[found.key];
    if (entry) return { md: docMarkdown(entry), range: found.range, key: found.key };

    const state = scan(text, Infinity);
    const tok = state.toks.find((t) => t.s <= offset && offset < t.e)
      || state.toks.find((t) => t.s < offset && offset === t.e && (t.t === 'ident' || t.t === 'kw'));
    if (!tok) return null;
    const range = { start: tok.s, end: tok.e };

    if (tok.t === 'num') {
      const { value, kind } = numberValue(tok.v);
      if (kind === 'duration') return { md: `\`${tok.v}\`: ${value} seconds`, range };
      if (kind === 'percentage') return { md: `\`${tok.v}\`: ${value}`, range };
      return null;
    }
    if (tok.t === 'kw') {
      const next = state.sig[state.sig.indexOf(tok) + 1];
      const key = tok.v === 'on' && next && next.v === 'end' ? 'on_end' : tok.v;
      return kwDocs[key] ? { md: kwDocs[key], range } : null;
    }
    if (tok.t !== 'ident') return null;

    const k = state.sig.indexOf(tok);
    const prev = state.sig[k - 1];
    const next = state.sig[k + 1];
    const scope = scan(text, tok.s);
    const names = visible(scope);

    // a field: player.income.credit, s.population
    if (prev && prev.v === '.') {
      let a = k - 1;
      while (a > 0 && (state.sig[a - 1].t === 'ident' || state.sig[a - 1].v === '.' || state.sig[a - 1].v === ']')) {
        if (state.sig[a - 1].v === ']') a = indexOfOpen(state.sig, a - 1);
        else a -= 1;
      }
      const ty = typeOf(state, a, k + 1, names);
      if (ty) return { md: fieldDoc(ty.doc || tok.v, ty.type), range };
      return null;
    }
    // a setup field
    const setupFrame = scope.frames.find((f) => f.kind === 'setup');
    if (setupFrame && next && next.v === '=' && setupFields.has(tok.v)) return { md: setupDoc(setupFields.get(tok.v)), range };
    // a named argument
    const callFrame = scope.frames[scope.frames.length - 1];
    if (next && next.v === ':' && callFrame && callFrame.ch === '(' && callFrame.callee) {
      const s = sig(callFrame.callee);
      const p = s && [...s.params, ...(s.named || [])].find((x) => x.name === tok.v);
      if (p) return { md: `\`${tok.v}:\` ${typeName(p.type)}, for ${s.name}()`, range };
    }
    // the name being declared: let x, var x, for s, as n, fn f
    if (prev && prev.t === 'kw' && ['let', 'var', 'for', 'as'].includes(prev.v)) {
      let ty = null;
      if (prev.v === 'as') ty = { type: 'number' };
      else if (prev.v === 'for') {
        const list = typeOf(state, k + 2, exprEnd(state.sig, k + 2, true), names);
        ty = list && list.type && list.type.list ? { type: list.type.list } : null;
      } else if (next && next.v === '=') ty = typeOf(state, k + 2, exprEnd(state.sig, k + 2), names);
      const what = {
        let: 'let', var: 'var', for: 'loop item', as: 'count (1, 2, 3 …)',
      }[prev.v];
      return { md: ['```edict', `${tok.v}: ${ty ? typeName(ty.type) : 'any'}`, '```', what].join('\n'), range };
    }
    if (prev && prev.t === 'kw' && prev.v === 'fn' && state.fns.has(tok.v)) return { md: userFnDoc(state.fns.get(tok.v)), range };
    if (names.has(tok.v)) {
      const d = names.get(tok.v);
      const ty = rootType(scope, tok.v, names, new Set());
      const what = {
        let: 'let', var: 'var', param: 'parameter', loop: 'loop item', count: 'count (1, 2, 3 …)', lambda: 'parameter',
      }[d.kind] || d.kind;
      return { md: ['```edict', `${tok.v}: ${ty ? typeName(ty.type) : 'any'}`, '```', what].join('\n'), range };
    }
    if (state.fns.has(tok.v)) return { md: userFnDoc(state.fns.get(tok.v)), range };
    const s = sig(tok.v);
    if (s) return { md: signatureDoc(s), range };
    if (catalog.world[tok.v]) return { md: [`**${tok.v}**`, rootDocs[tok.v] || ''].join('\n\n'), range };
    return null;
  }

  function indexOfOpen(t, closeIndex) {
    let depth = 0;
    for (let j = closeIndex; j >= 0; j -= 1) {
      if (t[j].v === ']') depth += 1;
      else if (t[j].v === '[') {
        depth -= 1;
        if (depth === 0) return j;
      }
    }
    return 0;
  }

  // --- signature help ------------------------------------------------------------------------

  // {label, doc, params: [{label, start, end, doc}], active} for the call
  // around the cursor.
  function signature(text, offset) {
    const state = scan(text, offset);
    const frame = [...state.frames].reverse().find((f) => f.ch === '(');
    if (!frame || !frame.callee) return null;
    const s = sig(frame.callee);
    const userFn = state.fns.get(frame.callee) || scan(text).fns.get(frame.callee);
    if (!s && !userFn) return null;

    let index = 0;
    let depth = 0;
    let namedNow = null;
    for (let j = frame.index + 1; j < state.sig.length && state.sig[j].s < offset; j += 1) {
      const t = state.sig[j];
      if ('([{'.includes(t.v)) depth += 1;
      else if (')]}'.includes(t.v)) depth -= 1;
      else if (t.v === ',' && depth === 0) {
        index += 1;
        namedNow = null;
      } else if (depth === 0 && t.t === 'ident' && state.sig[j + 1] && state.sig[j + 1].v === ':') namedNow = t.v;
    }

    const params = s
      ? [...s.params.map((p) => ({ name: p.name, text: paramLabel(p), rest: p.rest })), ...(s.named || []).map((p) => ({ name: p.name, text: `${p.name}: ${typeName(p.type)}` }))]
      : userFn.params.map((p) => ({ name: p.name, text: p.name }));
    const head = `${frame.callee}(`;
    let pos = head.length;
    const out = params.map((p, i) => {
      const start = pos;
      pos += p.text.length + (i < params.length - 1 ? 2 : 0);
      return { label: p.text, start, end: start + p.text.length, rest: p.rest };
    });
    const label = `${head}${params.map((p) => p.text).join(', ')})${s && s.kind !== 'action' ? ` → ${typeName(s.returns)}` : ''}`;

    let active = index;
    if (namedNow) active = params.findIndex((p) => p.name === namedNow);
    else {
      const restAt = out.findIndex((p) => p.rest);
      const positional = s ? s.params.length : params.length;
      if (restAt >= 0 && active >= restAt) active = restAt;
      else if (active >= positional) active = -1;
    }
    return {
      label, doc: s ? s.doc : escapeMd(userFn.note || ''), params: out, active,
    };
  }

  // --- outline and definitions -----------------------------------------------------------------

  // The top-level parts: [{name, detail, kind, start, end, selStart, selEnd}]
  function symbols(text) {
    const state = scan(text);
    const t = state.sig;
    const out = [];
    let depth = 0;
    for (let k = 0; k < t.length; k += 1) {
      const tok = t[k];
      if (tok.v === '{' || tok.v === '(' || tok.v === '[') depth += 1;
      else if (tok.v === '}' || tok.v === ')' || tok.v === ']') depth = Math.max(0, depth - 1);
      else if (depth === 0 && tok.t === 'kw' && (k === 0 || t[k - 1].t === 'nl' || t[k - 1].v === '}')) {
        const sym = symbolAt(text, t, k);
        if (sym) out.push(sym);
      }
    }
    return out;
  }

  function symbolAt(text, t, k) {
    const tok = t[k];
    let j = k;
    while (j < t.length && t[j].t !== 'nl' && t[j].v !== '{') j += 1;
    const headEnd = j < t.length ? t[j - 1].e : text.length;
    const header = text.slice(tok.s, headEnd).replace(/\s+/g, ' ').trim();
    let end = headEnd;
    if (t[j] && t[j].v === '{') end = t[Math.min(matching(t, j), t.length - 1)].e;
    const base = {
      start: tok.s, end, selStart: tok.s, selEnd: tok.e,
    };
    const short = (s) => (s.length > 60 ? `${s.slice(0, 57)}...` : s);
    switch (tok.v) {
      case 'setup': return { ...base, name: 'setup', kind: 'module' };
      case 'score':
      case 'tiebreak': return {
        ...base, name: tok.v, detail: short(header.slice(tok.v.length + 1)), kind: 'property',
      };
      case 'var': return t[k + 1] ? {
        ...base, name: t[k + 1].v, detail: 'var', kind: 'variable', selStart: t[k + 1].s, selEnd: t[k + 1].e,
      } : null;
      case 'fn': return t[k + 1] ? {
        ...base, name: t[k + 1].v, detail: short(header.slice(header.indexOf('('))), kind: 'function', selStart: t[k + 1].s, selEnd: t[k + 1].e,
      } : null;
      case 'on':
      case 'every':
      case 'at':
      case 'when': return { ...base, name: short(header), kind: 'event' };
      case 'draft': return { ...base, name: 'draft', kind: 'namespace' };
      default: return null;
    }
  }

  // Where the name under the cursor is declared: {start, end} or null.
  function definition(text, offset) {
    const toks = tokenize(text, keywords);
    const tok = toks.find((t) => t.t === 'ident' && t.s <= offset && offset <= t.e);
    if (!tok) return null;
    const scope = scan(text, tok.s);
    const idx = scope.sig.findIndex((t) => t.s === tok.s);
    const prev = scope.sig[idx - 1];
    if (prev && prev.v === '.') return null;
    const names = visible(scope);
    if (names.has(tok.v)) {
      const d = names.get(tok.v);
      return { start: d.s, end: d.e };
    }
    const fn = scan(text).fns.get(tok.v);
    return fn ? { start: fn.s, end: fn.e } : null;
  }

  // --- the lexer's checks --------------------------------------------------------------------------

  // What the game's lexer rejects, with its wording: [{start, end, message, severity}].
  // Names, types and setup values are checked by the game (open the file in
  // the Scenario Workshop).
  function diagnose(text) {
    const out = [];
    const toks = tokenize(text, keywords);
    const err = (s, e, message) => out.push({
      start: s, end: e, message, severity: 'error',
    });
    let m;
    BIDI.lastIndex = 0;
    while ((m = BIDI.exec(text))) err(m.index, m.index + 1, 'the script contains a hidden text-direction character');
    CONTROL.lastIndex = 0;
    while ((m = CONTROL.exec(text))) err(m.index, m.index + 1, 'the script contains a control character');
    const stack = [];
    toks.forEach((t) => {
      if (t.t === 'bad') {
        if (!BIDI_ONE.test(t.v) && !CONTROL_ONE.test(t.v)) err(t.s, t.e, `unexpected character ${JSON.stringify(t.v)}`);
      } else if (t.t === 'num' && t.bad) {
        err(t.s, t.e, 'a number can only end in s, m, h (a duration) or % (a percentage)');
      } else if (t.t === 'str') {
        if (!t.closed) err(t.s, t.e, 'this text is missing its closing quote');
        t.badEscapes.forEach((at) => err(at, at + 2, `unknown escape \\${text[at + 1] || ''} (use \\n, \\t, \\", \\\\, \\{ or \\})`));
        t.holes.filter((h) => h.open).forEach((h) => err(h.s - 1, h.e, 'this { inside text is missing its }'));
      } else if (t.t === 'op' && '([{'.includes(t.v)) {
        stack.push(t);
      } else if (t.t === 'op' && ')]}'.includes(t.v)) {
        const want = { ')': '(', ']': '[', '}': '{' }[t.v];
        if (stack.length && stack[stack.length - 1].v === want) stack.pop();
        else err(t.s, t.e, `this ${t.v} has no matching ${want}`);
      }
    });
    stack.forEach((t) => err(t.s, t.e, `this ${t.v} is never closed`));
    return out.sort((a, b) => a.start - b.start);
  }

  return {
    complete, hover, signature, symbols, definition, diagnose, docKey, tokenize: (text) => tokenize(text, keywords),
  };
}

module.exports = { createEdict };
