// Suggestions in the code view: the editor engine (priv/edict/editors/
// core.js) says what fits at the cursor; this narrows the list to what has
// been typed and turns a suggestion's snippet into plain text to insert.

// Items whose label starts with what was typed come first, then those that
// contain it; within each, the engine's own order (sort, then label).
export function filterItems(items, prefix) {
  const p = prefix.toLowerCase();
  const order = (a, b) => (a.sort || '5').localeCompare(b.sort || '5') || a.label.localeCompare(b.label);
  const sorted = [...items].sort(order);
  if (!p) return sorted;
  const starts = sorted.filter((i) => i.label.toLowerCase().startsWith(p));
  const contains = sorted.filter((i) => !i.label.toLowerCase().startsWith(p) && i.label.toLowerCase().includes(p));
  const found = [...starts, ...contains];
  // a word typed out in full needs no suggestion
  if (found.length === 1 && found[0].label === prefix) return [];
  return found;
}

// `"credit","technology"` (commas inside a choice are escaped: `\,`) -> `"credit"`
function firstChoice(choices) {
  let out = '';
  for (let i = 0; i < choices.length; i += 1) {
    const c = choices[i];
    if (c === '\\' && i + 1 < choices.length) {
      out += choices[i + 1];
      i += 1;
    } else if (c === ',') {
      break;
    } else {
      out += c;
    }
  }
  return out;
}

// A snippet (`every ${1:15s} as ${2:n} {\n\t$0\n}`) as text: placeholders
// keep their default, a choice its first value, lines take the indentation
// of the line they're inserted on. Returns {text, select: [start, end]}: the
// first placeholder, selected, so typing replaces it.
export function expandSnippet(snippet, indent = '') {
  const re = /\$\{(\d+):([^}]*)\}|\$\{(\d+)\|((?:[^|\\]|\\.)*)\|\}|\$\{(\d+)\}|\$(\d+)|\n|\t/g;
  let out = '';
  let last = 0;
  let first = null;
  let end = null;
  let m;
  while ((m = re.exec(snippet))) {
    out += snippet.slice(last, m.index);
    last = re.lastIndex;
    if (m[0] === '\n') {
      out += `\n${indent}`;
    } else if (m[0] === '\t') {
      out += '  ';
    } else {
      const n = Number(m[1] || m[3] || m[5] || m[6]);
      let text = '';
      if (m[2] !== undefined) text = m[2];
      else if (m[4] !== undefined) text = firstChoice(m[4]);
      const at = out.length;
      out += text;
      if (n === 0) {
        if (end === null) end = at;
      } else if (first === null || n < first.n) {
        first = { n, range: [at, at + text.length] };
      }
    }
  }
  out += snippet.slice(last);
  let select = [out.length, out.length];
  if (first) select = first.range;
  else if (end !== null) select = [end, end];
  return { text: out, select };
}

// Plain text from a snippet that isn't one (a word): as is.
export function insertion(item, indent) {
  return item.snippet ? expandSnippet(item.insert, indent) : { text: item.insert, select: [item.insert.length, item.insert.length] };
}
