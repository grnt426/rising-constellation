// HTML-escapes text for v-html and attribute values. No Vue: the `escape`
// filter (plugins/filters) and renderMd (utils/markdown) share it, and it
// runs under plain node.

/* eslint-disable import/prefer-default-export */
const { replace } = '';
const detect = /[&<>'"]/g;
const lookup = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  "'": '&#39;',
  '"': '&quot;',
};
const replacer = (character) => lookup[character];

export const escape = (input) => replace.call(input, detect, replacer);
