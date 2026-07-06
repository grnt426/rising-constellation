// Capture a DOM element to a PNG and put it on the clipboard, falling back
// to a regular download when the clipboard can't hold images (insecure
// context, missing ClipboardItem support, or permission denied).
//
// html2canvas is loaded lazily so the ~200KB library stays out of the main
// bundle until the first screenshot is taken.

export async function captureElementToBlob(element, backgroundColor) {
  const { default: html2canvas } = await import(/* webpackChunkName: "html2canvas" */ 'html2canvas');

  const canvas = await html2canvas(element, {
    backgroundColor,
    useCORS: true,
    logging: false,
    // capture the full (possibly scrolled-away) content, not the viewport clip
    width: element.scrollWidth,
    height: element.scrollHeight,
    windowWidth: Math.max(document.documentElement.clientWidth, element.scrollWidth),
    windowHeight: Math.max(document.documentElement.clientHeight, element.scrollHeight),
  });

  return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
}

export async function copyPngToClipboard(blob) {
  if (!blob) return false;
  if (!navigator.clipboard || !window.ClipboardItem || !window.isSecureContext) return false;

  try {
    await navigator.clipboard.write([new window.ClipboardItem({ 'image/png': blob })]);
    return true;
  } catch (e) {
    return false;
  }
}

export function downloadBlob(blob, filename) {
  if (!blob) return false;

  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  return true;
}
