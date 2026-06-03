// Tiny clipboard helper. Prefers the async `navigator.clipboard` API
// (HTTPS / localhost only) and falls back to a hidden-textarea +
// document.execCommand('copy') trick for older browsers or insecure
// contexts. Returns a promise that resolves to true on success.

export async function copyToClipboard(text) {
  if (typeof text !== 'string') return false;

  if (navigator.clipboard && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (e) {
      // fall through to the textarea fallback
    }
  }

  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '0';
    ta.style.left = '0';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return ok;
  } catch (e) {
    return false;
  }
}
