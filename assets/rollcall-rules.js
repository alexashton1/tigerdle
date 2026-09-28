/* Roll Call clue rules, shared by the admin clue builder and the game
   itself so the two can never disagree about who qualifies or how a clue
   reads. A rule looks like:
     { stat: 'appearances' | 'career_goals', min: 100,
       position?: 'GK'|'DF'|'MF'|'FW', nationality?: 'Scotland', era?: '2010s',
       bornFrom?: 1990, bornTo?: 2005 }
   Players are database rows (first_name, last_name, position, nationality,
   era, birth_date, appearances, career_goals, active). */
(function (root) {
  const POS_PLURAL   = { GK: 'Goalkeepers', DF: 'Defenders', MF: 'Midfielders', FW: 'Forwards' };
  const POS_SINGULAR = { GK: 'goalkeeper',  DF: 'defender',  MF: 'midfielder',  FW: 'forward' };
  const STAT_WORD    = { appearances: 'appearances', career_goals: 'goals' };
  const STAT_UNIT    = { appearances: 'apps',        career_goals: 'goals' };

  const fullName  = p => `${p.first_name} ${p.last_name}`;
  const birthYear = p => (p.birth_date ? Number(String(p.birth_date).slice(0, 4)) : null);

  // Cleans whatever the admin form hands over into a rule the rest can trust.
  function normalizeRule(raw) {
    const r = { stat: raw.stat === 'career_goals' ? 'career_goals' : 'appearances' };
    const min = Math.floor(Number(raw.min));
    r.min = Number.isFinite(min) && min > 0 ? min : 1;
    if (raw.position && POS_PLURAL[raw.position]) r.position = raw.position;
    if (raw.nationality) r.nationality = String(raw.nationality);
    if (raw.era) r.era = String(raw.era);
    const from = Math.floor(Number(raw.bornFrom)), to = Math.floor(Number(raw.bornTo));
    if (Number.isFinite(from) && from > 1800) r.bornFrom = from;
    if (Number.isFinite(to) && to > 1800) r.bornTo = to;
    return r;
  }

  // null if the player qualifies, otherwise a plain-English reason why not.
  function failReason(p, rule) {
    const name = fullName(p);
    if (rule.position && p.position !== rule.position)
      return `${name} was a ${POS_SINGULAR[p.position] || 'different position'}, not a ${POS_SINGULAR[rule.position]}.`;
    if (rule.nationality && p.nationality !== rule.nationality)
      return `${name} is from ${p.nationality}, not ${rule.nationality}.`;
    if (rule.era && p.era !== rule.era)
      return `${name} is listed as ${p.era}, not ${rule.era}.`;
    const y = birthYear(p);
    if (rule.bornFrom && (y === null || y < rule.bornFrom))
      return `${name} was born ${y === null ? 'on an unknown date' : 'in ' + y}, before ${rule.bornFrom}.`;
    if (rule.bornTo && (y === null || y > rule.bornTo))
      return `${name} was born ${y === null ? 'on an unknown date' : 'in ' + y}, after ${rule.bornTo}.`;
    const v = p[rule.stat];
    if (v === null || v === undefined || v < rule.min)
      return `${name} ${rule.stat === 'appearances' ? 'made' : 'scored'} ${v ?? 0}${rule.stat === 'career_goals' ? ' for Hull' : ''}, short of ${rule.min}.`;
    return null;
  }

  function qualifies(p, rule) { return p.active !== false && failReason(p, rule) === null; }

  // Plain-English clue, e.g. "Goalkeepers with 100+ Hull City appearances".
  function clueText(rule) {
    const cap = s => s.charAt(0).toUpperCase() + s.slice(1);
    const subject = (rule.era ? rule.era + ' ' : '') + (rule.position ? POS_PLURAL[rule.position].toLowerCase() : 'players');
    const bits = [];
    if (rule.nationality) bits.push(`from ${rule.nationality}`);
    if (rule.bornFrom && rule.bornTo) bits.push(`born ${rule.bornFrom} to ${rule.bornTo}`);
    else if (rule.bornFrom) bits.push(`born ${rule.bornFrom} or later`);
    else if (rule.bornTo) bits.push(`born ${rule.bornTo} or earlier`);
    bits.push(`with ${rule.min}+ Hull City ${STAT_WORD[rule.stat]}`);
    return cap(subject) + ' ' + bits.join(' ');
  }

  const api = { POS_PLURAL, POS_SINGULAR, STAT_WORD, STAT_UNIT, fullName, normalizeRule, failReason, qualifies, clueText };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.RollCallRules = api;
})(typeof window !== 'undefined' ? window : globalThis);
