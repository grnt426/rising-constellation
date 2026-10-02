// Case- and diacritics-insensitive haystack for name searches (the
// list-panel search fields). NFD splits accented letters into base char
// + combining marks; stripping the combining range makes 'Elysee' match
// 'Élysée'.
export function searchKey(str) {
  return (str || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
}
