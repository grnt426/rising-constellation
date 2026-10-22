// Scripts as files: open, save, and keep a file linked to the workshop
// while it is edited somewhere else (an IDE with the Edict editor kit).
//
// Linking uses the File System Access API (Chrome and Edge). Other browsers
// still open and save files; they just can't follow one.

export const MAX_BYTES = 64 * 1024; // Edict.Limits.max_source_bytes

export function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function saveText(text, filename) {
  saveBlob(new Blob([text], { type: 'text/plain;charset=utf-8' }), filename);
}

// "The Bequest" -> "the-bequest.edict"
export function fileName(title, fallback = 'scenario') {
  const slug = String(title || '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return `${slug || fallback}.edict`;
}

// The text of a dropped or picked file, or an error key.
export async function readFile(file) {
  if (!file) return { error: 'file_none' };
  if (file.size > MAX_BYTES) return { error: 'file_too_big' };
  const text = await file.text();
  return { text, name: file.name };
}

export function canLink() {
  return typeof window !== 'undefined' && typeof window.showOpenFilePicker === 'function';
}

const PICKER = {
  types: [{ description: 'Edict scenario', accept: { 'text/plain': ['.edict', '.txt'] } }],
  multiple: false,
};

// A file the author picks to link, or null if they cancel.
export async function pickLinked() {
  try {
    const [handle] = await window.showOpenFilePicker(PICKER);
    return handle || null;
  } catch (e) {
    return null;
  }
}

// {text, modified, name} as the file is now.
export async function readLinked(handle) {
  const file = await handle.getFile();
  if (file.size > MAX_BYTES) return { error: 'file_too_big', modified: file.lastModified, name: file.name };
  return { text: await file.text(), modified: file.lastModified, name: file.name };
}

// Writes the text over the linked file (the browser asks the first time).
// Returns the file's new modification time, or null if writing was refused.
export async function writeLinked(handle, text) {
  if (handle.requestPermission) {
    const state = await handle.requestPermission({ mode: 'readwrite' });
    if (state !== 'granted') return null;
  }
  const writable = await handle.createWritable();
  await writable.write(text);
  await writable.close();
  const file = await handle.getFile();
  return file.lastModified;
}
