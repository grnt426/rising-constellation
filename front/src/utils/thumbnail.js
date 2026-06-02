// Forge thumbnail capture. The wizard already renders the map / scenario
// as an inline <svg>; this util serializes that SVG, rasterizes it to a
// PNG via a canvas, and POSTs the resulting blob to the supplied route.
//
// Best-effort by design — every caller wraps in a try/catch and a save
// flow never fails because the thumbnail couldn't be captured.

// The SVG-render-to-canvas trick loses the page's stylesheet (the data
// URL isolates the SVG from the document's CSS), so classes like
// `map-system` / `map-sector` end up with no fill or stroke. Walk both
// trees in parallel, copy the computed paint properties from the live
// node onto the clone as inline style. We deliberately list a small set
// of properties rather than dump getComputedStyle's entire output — the
// full output is ~300 props per node, blows up the serialized payload,
// and triggers per-node layout that browsers compute lazily.
const INLINED_PROPS = [
  'fill',
  'fill-opacity',
  'stroke',
  'stroke-width',
  'stroke-opacity',
  'opacity',
  'font-family',
  'font-size',
  'font-weight',
  'text-anchor',
];

function inlineStyles(liveRoot, cloneRoot) {
  const liveAll = [liveRoot, ...liveRoot.querySelectorAll('*')];
  const cloneAll = [cloneRoot, ...cloneRoot.querySelectorAll('*')];
  for (let i = 0; i < liveAll.length; i += 1) {
    const computed = window.getComputedStyle(liveAll[i]);
    let inline = cloneAll[i].getAttribute('style') || '';
    for (const prop of INLINED_PROPS) {
      const val = computed.getPropertyValue(prop);
      if (val && val !== 'none' && val !== 'auto') {
        inline += `${prop}:${val};`;
      }
    }
    if (inline) cloneAll[i].setAttribute('style', inline);
  }
}

function svgToBlob(svgEl, size) {
  const clone = svgEl.cloneNode(true);
  // The Map/Scenario wizards render the SVG without a viewBox — their
  // coordinate system matches the live container's pixel size. When we
  // shrink the serialized copy to `size` px without a viewBox, the
  // content stays drawn at the original pixel coordinates and gets
  // clipped to the smaller frame. Synthesize a viewBox from the live
  // dimensions so the snapshot scales the full map into `size x size`.
  const liveWidth = parseFloat(svgEl.getAttribute('width')) || svgEl.clientWidth || size;
  const liveHeight = parseFloat(svgEl.getAttribute('height')) || svgEl.clientHeight || size;
  if (!clone.getAttribute('viewBox')) {
    clone.setAttribute('viewBox', `0 0 ${liveWidth} ${liveHeight}`);
  }
  // Force an explicit width/height on the serialized SVG so the canvas
  // draws at our intended raster size regardless of the live viewport.
  clone.setAttribute('width', size);
  clone.setAttribute('height', size);
  // Inline the computed background so the rasterized PNG isn't
  // transparent over a future <img> tag's CSS background.
  if (!clone.getAttribute('style') || !clone.getAttribute('style').includes('background')) {
    clone.setAttribute('style', 'background:#0e1726;');
  }
  inlineStyles(svgEl, clone);

  const xml = new XMLSerializer().serializeToString(clone);
  // unescape(encodeURIComponent(...)) is the canonical JS dance to
  // squeeze a UTF-8 string into btoa, which only accepts Latin-1.
  const dataUrl = `data:image/svg+xml;base64,${btoa(unescape(encodeURIComponent(xml)))}`;

  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = size;
      canvas.height = size;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#0e1726';
      ctx.fillRect(0, 0, size, size);
      ctx.drawImage(img, 0, 0, size, size);
      canvas.toBlob((blob) => {
        if (blob) resolve(blob);
        else reject(new Error('canvas.toBlob returned null'));
      }, 'image/png');
    };
    img.onerror = () => reject(new Error('SVG → PNG load failed'));
    img.src = dataUrl;
  });
}

export async function uploadSvgThumbnail($axios, route, svgEl, size = 400) {
  if (!svgEl) return;
  try {
    const blob = await svgToBlob(svgEl, size);
    const formData = new FormData();
    formData.append('thumbnail', blob, 'thumbnail.png');
    await $axios.put(route, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  } catch (err) {
    // Don't let a thumbnail miss break the user's save action.
    // Surface to console for dev iteration; production silently moves on.
    if (process.env.NODE_ENV !== 'production') {
      // eslint-disable-next-line no-console
      console.warn('uploadSvgThumbnail failed:', err);
    }
  }
}
