#!/usr/bin/env python3
"""Mine the fleets players fielded in Legacy matches into
priv/data/wave/blueprints.json, the pool the Rebellion copies its fleets from
(Wave.Blueprints; docs/wave-defense.md, "Fleets").

    python bin/wave-fleets/mine_fleets.py <data_dir> [--report]

<data_dir> holds read-only exports. Nothing here touches a live database.

  actions.jsonl.gz   pillages, bombardments and conquests, attacker's side:
      copy (select json_build_object('id',id,'iid',instance_id,'key',key,
        'at',inserted_at,'reg',registration_id,'d',data::json)
        from player_events where type='box' and key in ('loot','raid','conquest')
        and data::json->>'side'='attacker') to stdout
  fights.jsonl.gz    battles, for the system and who won:
      copy (select json_build_object('id',id,'iid',instance_id,'at',inserted_at,
        'reg',registration_id,'d',data::json)
        from player_events where type='box' and key='fight') to stdout
  reports.jsonl.gz   both sides' fleets before each battle:
      copy (select json_build_object('id',id,'reg',registration_id,
        'at',inserted_at,'m',metadata::json,'i',report::json->'initial')
        from player_report where type='fight') to stdout
  states.jsonl.gz    when each match started:
      copy (select json_build_object('iid',instance_id,'state',state,
        'at',inserted_at) from instance_states order by id) to stdout
  regs.jsonl.gz      registration -> match:
      copy (select json_build_object('reg',r.id,'iid',f.instance_id,
        'faction',f.faction_ref,'profile',r.profile_id)
        from registrations r join factions f on f.id=r.faction_id) to stdout
  snapshots/*.jsonl  fleets standing in instance snapshots, one file per
      snapshot, written by bin/wave-fleets/extract_fleets.exs

A sighting is one fleet at one moment. Each is tagged with what the fleet was
doing (see role_of), sightings of the same hull mix are merged into a design,
and the designs are written without stack sizes or player names.
"""

import collections
import datetime
import glob
import gzip
import hashlib
import json
import os
import re
import statistics
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIP_CATALOG = os.path.join(REPO, 'lib/data/game/content/ship-slow.ex')
OUT = os.path.join(REPO, 'priv/data/wave/blueprints.json')

# Legacy-speed matches the designs are taken from.
MATCHES = (10, 20, 49, 85, 87, 121)
# A design needs at least half a fleet, and a colony ship is not a fleet.
MIN_SHIPS = 9
HUMAN_HELD = ('inhabited_player', 'inhabited_dominion')
# How long an action holds the system, at most, in hours: the window in which
# another fleet fighting there counts as covering it.
ACTION_HOURS = {'loot': 2, 'raid': 4, 'conquest': 15}


def load_ships(path=SHIP_CATALOG):
    source = open(path, encoding='utf-8').read()
    ships = {}
    for item in re.findall(r'%Data\.Game\.Ship\{(.*?)\n\s*\}', source, re.S):
        ship = {}
        for m in re.finditer(r'(\w+\??):\s*(\[[^\]]*\]|"[^"]*"|:[\w?]+|[\d_.\-]+|nil|true|false)', item, re.S):
            key, value = m.group(1), m.group(2)
            if value.startswith('['):
                value = [float(x.replace('_', '')) for x in re.findall(r'[\d_.]+', value)]
            elif re.match(r'^-?[\d_.]+$', value):
                value = float(value.replace('_', ''))
            elif value.startswith(':'):
                value = value[1:]
            elif value == 'nil':
                value = None
            ship[key] = value
        ships[ship['key']] = ship
    return ships


SHIPS = load_ships()


def hull(key):
    """fighter_4v3 -> fighter_4: the hull without its stack size."""
    return re.sub(r'v\d+$', '', key)


def jl(path):
    opener = gzip.open if path.endswith('.gz') else open
    with opener(path, 'rt', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)


def ts(text):
    return datetime.datetime.fromisoformat(text[:19])


def tiles_of(army):
    out = []
    for tile in (army or {}).get('tiles', []):
        ship = tile.get('ship')
        if tile.get('ship_status') == 'filled' and isinstance(ship, dict) and ship.get('key') in SHIPS:
            out.append((tile['id'], ship['key']))
    return out


def features(tiles):
    f = collections.Counter()
    for _, key in tiles:
        ship = SHIPS[key]
        n = ship['unit_count']
        f['ships'] += 1
        f['production'] += ship['production']
        f['raid'] += ship['unit_raid_coef'] * n
        f['invasion'] += ship['unit_invasion_coef'] * n
        f['p_' + ship['class']] += ship['production']
    return f


def load_sightings(data):
    start = {}
    for row in jl(os.path.join(data, 'states.jsonl.gz')):
        if row['state'] == 'running' and row['iid'] not in start:
            start[row['iid']] = ts(row['at'])
    regs = {row['reg']: row for row in jl(os.path.join(data, 'regs.jsonl.gz'))}

    def day(iid, at):
        return (ts(at) - start[iid]).total_seconds() / 86400

    sightings = []

    # 1. Pillages, bombardments, conquests: the attacker's fleet before the action.
    for row in jl(os.path.join(data, 'actions.jsonl.gz')):
        if row['iid'] not in MATCHES:
            continue
        d = row['d']
        admiral = d['admiral']
        before = admiral.get('previous') or admiral['current']
        tiles = tiles_of(before.get('army'))
        if not tiles:
            continue
        system = d.get('system') or {}
        owner = before.get('owner') or {}
        sightings.append(dict(
            src='action', iid=row['iid'], at=row['at'], day=day(row['iid'], row['at']), cid=before['id'],
            owner=owner.get('id'), faction=owner.get('faction'), tiles=tiles,
            reaction=(before.get('army') or {}).get('reaction'), act=row['key'], eid=row['id'],
            sys=system.get('id'), sys_status=system.get('status'),
            sys_faction=(system.get('owner') or {}).get('faction')))

    # 2. Battles: the event names the system and its owner, the report holds
    #    both fleets as they went in.
    fights = {}
    for row in jl(os.path.join(data, 'fights.jsonl.gz')):
        system = row['d'].get('system') or {}
        fights.setdefault((row['iid'], system.get('name'), row['at'][:15]), system)
    seen = set()
    for row in jl(os.path.join(data, 'reports.jsonl.gz')):
        reg = regs.get(row['reg'])
        if not reg or reg['iid'] not in MATCHES:
            continue
        iid = reg['iid']
        initial = row['i'] or {}
        sides = [(side, a) for side in ('attackers', 'defenders') for a in initial.get(side, [])]
        key = (iid, row['at'][:15], tuple(sorted(a['id'] for _, a in sides)))
        if key in seen:
            continue
        seen.add(key)
        system = fights.get((iid, row['m'].get('system'), row['at'][:15])) or {}
        for side, a in sides:
            tiles = tiles_of(a.get('army'))
            if not tiles:
                continue
            owner = a.get('owner') or {}
            queue = [x.get('type') for x in ((a.get('actions') or {}).get('queue') or [])]
            sightings.append(dict(
                src='fight', iid=iid, at=row['at'], day=day(iid, row['at']), cid=a['id'], owner=owner.get('id'),
                faction=owner.get('faction'), tiles=tiles, reaction=(a.get('army') or {}).get('reaction'),
                side=side[:-1], queue=queue, rid=row['id'], sys=a.get('system'), sys_status=system.get('status'),
                sys_faction=(system.get('owner') or {}).get('faction')))

    # 3. Snapshots: fleets standing somewhere.
    for path in sorted(glob.glob(os.path.join(data, 'snapshots', '*.jsonl'))):
        m = re.search(r'snapshot-(\d+)-(\d{10})', path)
        iid, unix = int(m.group(1)), int(m.group(2))
        if iid not in MATCHES:
            continue
        at = datetime.datetime.fromtimestamp(unix, datetime.timezone.utc).replace(tzinfo=None).isoformat()
        rows = list(jl(path))
        systems = {r['id']: r for r in rows if r['k'] == 'sys'}
        for c in rows:
            if c['k'] != 'char' or c['status'] != 'on_board':
                continue
            tiles = [(t['t'], t['key']) for t in c['tiles'] if t['st'] == 'filled' and t['key'] in SHIPS]
            if not tiles:
                continue
            system = systems.get(c['system']) or {}
            sightings.append(dict(
                src='snap', iid=iid, at=at, day=day(iid, at), cid=c['id'], owner=c['owner'], faction=c['faction'],
                tiles=tiles, reaction=c['reaction'], queue=[q['type'] for q in c['queue']], sys=c['system'],
                sys_status=system.get('status'), sys_faction=system.get('faction')))
    return sightings


def tag_roles(sightings):
    """What each sighting shows the fleet doing, or None."""
    actions = collections.defaultdict(list)
    for s in sightings:
        if s['src'] == 'action':
            actions[(s['iid'], s['sys'])].append(s)

    # Fleets that fought at a system while a teammate's bombardment or
    # invasion of a player's holding ran there.
    covering = set()
    for s in sightings:
        if s['src'] != 'fight':
            continue
        for a in actions.get((s['iid'], s['sys']), []):
            hours = (ts(s['at']) - ts(a['at'])).total_seconds() / 3600
            if (a['faction'] == s['faction'] and a['cid'] != s['cid'] and a['act'] in ('raid', 'conquest')
                    and a['sys_status'] in HUMAN_HELD and -ACTION_HOURS[a['act']] - 2 <= hours <= 1):
                covering.add((s['rid'], s['cid']))

    # Garrisons: the same fleet in the same system of its own faction in
    # three snapshots at least two days apart.
    at_home = collections.defaultdict(list)
    for s in sightings:
        if s['src'] == 'snap' and home(s) and not offensive(s):
            at_home[(s['iid'], s['cid'], s['sys'])].append(s['day'])
    garrisons = {k for k, days in at_home.items() if len(days) >= 3 and max(days) - min(days) >= 2}

    for s in sightings:
        s['role'] = role_of(s, covering, garrisons)


def home(s):
    return s.get('sys_faction') is not None and s.get('sys_faction') == s['faction']


def offensive(s):
    return any(t in ('loot', 'raid', 'conquest', 'colonization') for t in s.get('queue', []))


def role_of(s, covering, garrisons):
    if s['src'] == 'action':
        # Pillaging and bombarding neutrals is how players train a fleet.
        # It says nothing about fighting other players.
        if s['sys_status'] not in HUMAN_HELD:
            return 'farm'
        return {'loot': 'raid', 'raid': 'siege', 'conquest': 'conquest'}[s['act']]
    if s['src'] == 'fight':
        if (s['rid'], s['cid']) in covering:
            return 'screen'
        if s['side'] == 'defender':
            return 'defense' if home(s) else None
        # An attacker with an action queued is counted by that action's own
        # event; one with none, away from home, came to kill a fleet.
        if not offensive(s) and not home(s):
            return 'hunt'
        return None
    if (s['iid'], s['cid'], s['sys']) in garrisons:
        return 'defense'
    if 'conquest' in s.get('queue', []):
        return 'conquest'
    return None


def build_pool(sightings):
    groups = collections.defaultdict(list)
    for s in sightings:
        if s['role'] in (None, 'farm'):
            continue
        hulls = [hull(key) for _, key in s['tiles']]
        if len(hulls) < MIN_SHIPS or 'transport_1' in hulls:
            continue
        groups[tuple(sorted(collections.Counter(hulls).items()))].append(s)

    pool = []
    for _, group in groups.items():
        layouts = collections.Counter(tuple(sorted((t, hull(k)) for t, k in s['tiles'])) for s in group)
        layout = layouts.most_common(1)[0][0]
        pool.append(dict(
            id='bp_' + hashlib.sha1(json.dumps(layout).encode()).hexdigest()[:10],
            slots=[[t, h] for t, h in layout],
            evidence=dict(collections.Counter(s['role'] for s in group)),
            players=len(set((s['iid'], s['owner']) for s in group)),
            sightings=len(group),
            day=round(statistics.median(s['day'] for s in group), 1),
            stance=collections.Counter(s['reaction'] for s in group).most_common(1)[0][0],
            matches=sorted(set(s['iid'] for s in group))))
    pool.sort(key=lambda d: (-d['players'], -d['sightings'], d['id']))
    return pool


def write_pool(pool, path=OUT):
    head = {
        'about': ('Fleet designs players fielded in Legacy matches, by what the fleet was seen doing. '
                  'Built by bin/wave-fleets/mine_fleets.py; see docs/wave-defense.md, Fleets.'),
        'matches': list(MATCHES),
        'min_ships': MIN_SHIPS,
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', newline='\n', encoding='utf-8') as f:
        f.write('{\n')
        for key, value in head.items():
            f.write(f' {json.dumps(key)}: {json.dumps(value)},\n')
        f.write(' "blueprints": [\n')
        f.write(',\n'.join('  ' + json.dumps(b, separators=(',', ':')) for b in pool))
        f.write('\n ]\n}\n')


def stage(day):
    return 'early' if day < 5 else ('mid' if day < 12 else 'late')


def report(sightings, pool):
    print('sightings', len(sightings), dict(collections.Counter(s['src'] for s in sightings)))
    print('roles', dict(collections.Counter(s['role'] for s in sightings)))
    print(f"{'role':9}{'stage':6}{'sightings':>10}{'fleets':>7}{'players':>8}{'ships':>6}{'production':>11}{'raid':>6}{'invasion':>9}"
          '   production share: fighter corvette frigate capital transport')
    for role in ('defense', 'raid', 'siege', 'conquest', 'screen', 'hunt', 'farm'):
        for st in ('early', 'mid', 'late'):
            xs = [s for s in sightings if s['role'] == role and stage(s['day']) == st]
            if len(xs) < 3:
                continue
            fs = [features(s['tiles']) for s in xs]
            total = sum(f['production'] for f in fs) or 1
            share = lambda c: 100 * sum(f['p_' + c] for f in fs) / total
            med = lambda k: statistics.median(f[k] for f in fs)
            print(f"{role:9}{st:6}{len(xs):10}{len(set((s['iid'], s['cid']) for s in xs)):7}"
                  f"{len(set((s['iid'], s['owner']) for s in xs)):8}{med('ships'):6.0f}{med('production'):11.0f}"
                  f"{med('raid'):6.0f}{med('invasion'):9.0f}   "
                  f"{share('fighter'):8.0f}{share('corvette'):9.0f}{share('frigate'):8.0f}{share('capital'):8.0f}{share('transport'):10.0f}")
    # Each fleet's main role per stage, neutral farming left out.
    print()
    print('share of fleets by main role:')
    per = collections.defaultdict(collections.Counter)
    for s in sightings:
        if s['role'] not in (None, 'farm'):
            per[(s['iid'], s['cid'], stage(s['day']))][s['role']] += 1
    for st in ('early', 'mid', 'late'):
        c = collections.Counter(max(ev, key=ev.get) for (_, _, g), ev in per.items() if g == st)
        n = sum(c.values()) or 1
        print(f'  {st:6} {n:4} fleets  ' + '  '.join(f'{r} {100 * c[r] / n:.0f}%' for r in ('defense', 'raid', 'siege', 'conquest', 'screen', 'hunt')))
    by_role = collections.Counter(r for d in pool for r in d['evidence'])
    print()
    print(len(pool), 'designs;', dict(by_role))


def main(argv):
    if not argv or argv[0].startswith('-'):
        sys.exit(__doc__)
    sightings = load_sightings(argv[0])
    tag_roles(sightings)
    pool = build_pool(sightings)
    write_pool(pool)
    print(f'{len(pool)} designs -> {os.path.relpath(OUT, REPO)}')
    if '--report' in argv:
        report(sightings, pool)


if __name__ == '__main__':
    main(sys.argv[1:])
