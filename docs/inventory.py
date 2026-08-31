#!/usr/bin/env python3
"""Inventory of KH Coder's GUI: menu tree, screens, and the engine behind each.
Everything is read from the source."""
import re, json, pathlib, collections

ROOT = pathlib.Path('/home/yj/khcoder/src')
rd = lambda p: (ROOT/p).read_bytes().decode('utf-8','replace')

# ---- message catalogue -----------------------------------------------------
msg = collections.defaultdict(dict); section = 'global'
for line in rd('config/msg.en').split('\n'):
    if re.match(r'^[A-Za-z_][\w:]*:\s*$', line):
        section = line.strip().rstrip(':'); continue
    m = re.match(r'^\s{2,}([\w_]+):\s*(.*)$', line)
    if m and m.group(2) not in ('|-','|','>-'):
        msg[section][m.group(1)] = m.group(2).strip().strip('"')

def label(key, caller='gui_window::main::menu'):
    if not key: return None
    if '->' in key: caller, key = key.split('->',1)
    for sec in (caller,'global'):
        if key in msg.get(sec,{}): return msg[sec][key]
    return key

src = rd('kh_lib/gui_window/main/menu.pm')

# ---- sequential pass over cascade/command calls -----------------------------
CALL = re.compile(r'(?:my\s+)?(\$\w+)?\s*=?\s*\$(\w+|\{[^}]+\})->(cascade|command)\s*\(')
ASSIGN_MSG = re.compile(r"my \$msg = gui_window->gui_jm\(\s*kh_msg->get\('([^']+)'\)")

var_key   = {}        # var -> (parent_var, label_key) at this point in the file
last_msg  = None
rows      = []

for m in CALL.finditer(src):
    for a in ASSIGN_MSG.finditer(src, 0, m.start()):
        last_msg = a.group(1)
    var, par, kind = m.group(1), m.group(2), m.group(3)
    i, depth = m.end(), 1
    while i < len(src) and depth:
        depth += (src[i]=='(') - (src[i]==')'); i += 1
    body = src[m.end():i]

    lm = re.search(r"-label\s*=>\s*(?:gui_window->gui_jm\(\s*)?kh_msg->g?get\(\s*'([^']+)'", body)
    key = lm.group(1) if lm else (last_msg if re.search(r'-label\s*=>\s*(?:")?\$msg', body) else None)

    # path from the parent chain as it stands right now
    chain, p, seen = [], par, set()
    while p in var_key and p not in seen:
        seen.add(p); pp, pk = var_key[p]
        if pk: chain.append(label(pk))
        p = pp
    path = list(reversed(chain))

    if var and kind == 'cascade':
        var_key[var.lstrip('$')] = (par, key)

    tgt = re.findall(r"gui_window::([\w:]+)->open|\$self->(mc_\w+)|\bmc_(\w+)\b", body)
    targets = sorted({a or b or ('mc_'+c) for a,b,c in tgt})
    if key or targets:
        rows.append(dict(kind=kind, path=path, label=label(key), key=key,
                         targets=targets, disabled='-state' in body and 'disable' in body))

# ---- screens ---------------------------------------------------------------
ENGINE = ('mysql_words','mysql_conc','mysql_getdoc','mysql_crossout','mysql_ready',
          'mysql_outvar','mysql_hukugo','mysql_nounphrases','kh_cod','kh_nbayes',
          'mysql_a_word','mysql_getheader','kh_r_plot','kh_morpho')
screens = {}
for f in sorted((ROOT/'kh_lib/gui_window').glob('*.pm')):
    s = f.read_bytes().decode('utf-8','replace')
    screens[f.stem] = dict(
        loc=len(s.split('\n')),
        engine=sorted({e for e in ENGINE if re.search(r'\b'+e+r'\b', s)}),
        plot=(ROOT/f'kh_lib/gui_window/r_plot/{f.stem}.pm').exists() or 'kh_r_plot' in s,
        sql=len(re.findall(r'mysql_exec->(?:do|select)', s)),
        exports=bool(re.search(r'_out_file|csv_list|Excel::Writer|save_file', s)),
    )
json.dump(dict(menu=rows, screens=screens), open('/tmp/claude-1000/-home-yj-khcoder/07642bc1-a5a2-45ca-8330-2ef51831af6f/scratchpad/inv.json','w'), ensure_ascii=False, indent=1)
print(f"menu rows: {len(rows)}   screens: {len(screens)}")
top = collections.Counter(r['path'][0] if r['path'] else '(top)' for r in rows)
for k,v in top.items(): print(f"  {k}: {v}")
