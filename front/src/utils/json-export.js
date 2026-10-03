import { copyToClipboard } from '@/utils/clipboard';

// Hand JSON to the player: copied to the clipboard (paste it in Discord,
// a note, the planner's Import box), or saved as a file when the browser
// won't allow clipboard access. Resolves to 'copied' or 'downloaded'.
export async function copyOrDownloadJson(json, filename) {
  if (await copyToClipboard(json)) return 'copied';

  const url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
  return 'downloaded';
}

// "Ophion Prime" -> "system-plan-Ophion_Prime.json"
export function planFilename(name) {
  return `system-plan-${String(name || 'system').replace(/[^\w-]+/g, '_')}.json`;
}

export default copyOrDownloadJson;
