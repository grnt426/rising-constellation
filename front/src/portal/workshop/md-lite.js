// The little Markdown the editor engine writes for hovers (priv/edict/editors
// core.js): paragraphs, ``` code blocks, "- " list items, **bold** and
// `code`. Turned into plain data for templates to render with {{ }}, never
// HTML: the text can quote a script.

function inline(line) {
  const parts = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`)/g;
  let last = 0;
  let m;
  while ((m = re.exec(line))) {
    if (m.index > last) parts.push({ style: 'text', text: line.slice(last, m.index) });
    const token = m[0];
    parts.push(token.startsWith('**')
      ? { style: 'strong', text: token.slice(2, -2) }
      : { style: 'code', text: token.slice(1, -1) });
    last = m.index + token.length;
  }
  if (last < line.length) parts.push({ style: 'text', text: line.slice(last) });
  // a backslash escape (\[, \*) shows its character
  return parts.map((p) => (p.style === 'code' ? p : { ...p, text: p.text.replace(/\\(.)/g, '$1') }));
}

// [{kind: 'p' | 'li' | 'code', parts?: [{style, text}], text?}]
export function blocks(md) {
  const out = [];
  let code = null;
  String(md || '').split('\n').forEach((line) => {
    if (line.startsWith('```')) {
      if (code) {
        out.push({ kind: 'code', text: code.join('\n') });
        code = null;
      } else {
        code = [];
      }
    } else if (code) {
      code.push(line);
    } else if (line.startsWith('- ')) {
      out.push({ kind: 'li', parts: inline(line.slice(2)) });
    } else if (line.trim()) {
      out.push({ kind: 'p', parts: inline(line) });
    }
  });
  if (code) out.push({ kind: 'code', text: code.join('\n') });
  return out;
}

export default blocks;
