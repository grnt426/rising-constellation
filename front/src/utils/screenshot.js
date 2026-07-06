// Capture a DOM element to a PNG and put it on the clipboard, falling back
// to a regular download when the clipboard can't hold images (insecure
// context, missing ClipboardItem support, or permission denied).
//
// html2canvas is loaded lazily so the ~200KB library stays out of the main
// bundle until the first screenshot is taken.

// html2canvas draws each inline <svg> by serializing it to a standalone
// image, so styles the icons get from stylesheets (vue-svgicon icons are
// sized and colored via CSS, fill: currentColor) are lost — white icons
// come out default-black (invisible on our dark panels) and CSS-sized ones
// render at their intrinsic size. Copy the relevant computed styles from
// each source <svg> onto its clone as inline styles, which survive the
// serialization. Source and clone are matched by traversal order — the
// clone is a deep copy of the same subtree.
function inlineSvgStyles(sourceRoot, cloneRoot) {
  const sources = sourceRoot.querySelectorAll('svg');
  const clones = cloneRoot.querySelectorAll('svg');

  clones.forEach((clone, i) => {
    const source = sources[i];
    if (!source) return;
    const computed = window.getComputedStyle(source);
    ['fill', 'color', 'width', 'height', 'verticalAlign'].forEach((prop) => {
      clone.style[prop] = computed[prop];
    });
  });
}

export async function captureElementToBlob(element, backgroundColor) {
  const { default: html2canvas } = await import(/* webpackChunkName: "html2canvas" */ 'html2canvas');

  element.dataset.rcScreenshotRoot = '1';

  try {
    const canvas = await html2canvas(element, {
      backgroundColor,
      useCORS: true,
      logging: false,
      // capture the full (possibly scrolled-away) content, not the viewport clip
      width: element.scrollWidth,
      height: element.scrollHeight,
      windowWidth: Math.max(document.documentElement.clientWidth, element.scrollWidth),
      windowHeight: Math.max(document.documentElement.clientHeight, element.scrollHeight),
      onclone(clonedDoc) {
        const cloneRoot = clonedDoc.querySelector('[data-rc-screenshot-root]');
        if (cloneRoot) inlineSvgStyles(element, cloneRoot);
      },
    });

    return await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
  } finally {
    delete element.dataset.rcScreenshotRoot;
  }
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
