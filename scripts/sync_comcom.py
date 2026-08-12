"""
Robot de synchronisation Odoo -> Supabase pour le dashboard comcom
=====================================================================
Ce script est lance automatiquement par GitHub Actions toutes les X
minutes (voir .github/workflows/comcom-sync.yml). Il n'ouvre AUCUN
serveur, ne s'affiche a personne : il recupere les donnees Odoo puis
les ecrit dans Supabase, protegees derriere la fonction get_comcom_data.

Tous les identifiants (Odoo + Supabase) sont fournis par GitHub Actions
via des variables d'environnement (issues de GitHub Secrets) — jamais
ecrits ici, jamais dans un fichier commis sur le repo.
"""

import xmlrpc.client, json, os, sys
import requests
from datetime import datetime, timedelta
from collections import defaultdict

ODOO_URL            = os.environ.get("ODOO_URL", "")
ODOO_DB             = os.environ.get("ODOO_DB", "")
ODOO_USERNAME       = os.environ.get("ODOO_USERNAME", "")
ODOO_PASSWORD       = os.environ.get("ODOO_PASSWORD", "")
SUPABASE_URL        = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY= os.environ.get("SUPABASE_SERVICE_KEY", "")

if not all([ODOO_URL, ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD, SUPABASE_URL, SUPABASE_SERVICE_KEY]):
    print("ERREUR : une ou plusieurs variables d'environnement manquent.")
    print("Verifie les GitHub Secrets : ODOO_URL, ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD, SUPABASE_URL, SUPABASE_SERVICE_KEY")
    sys.exit(1)

import re
def _strip_html(html):
    """Retire les balises HTML du champ note."""
    if not html:
        return ''
    text = re.sub(r'<br\s*/?>', '\n', html, flags=re.IGNORECASE)
    text = re.sub(r'<[^>]+>', '', text)
    text = re.sub(r'&nbsp;', ' ', text)
    text = re.sub(r'&amp;', '&', text)
    text = re.sub(r'&lt;', '<', text)
    text = re.sub(r'&gt;', '>', text)
    return text.strip()

def _to_local(utc_str, offset_hours=2):
    """Convertit une date UTC Odoo en heure locale (UTC+2 pour Belgique)."""
    if not utc_str:
        return ''
    try:
        dt = datetime.strptime(str(utc_str)[:16], '%Y-%m-%d %H:%M')
        dt_local = dt + timedelta(hours=offset_hours)
        return dt_local.strftime('%Y-%m-%d %H:%M')
    except Exception:
        return str(utc_str)[:16]

def _days_since(date_str):
    """Retourne le nombre de jours depuis la date donnée."""
    if not date_str:
        return None
    try:
        dt = datetime.strptime(str(date_str)[:10], '%Y-%m-%d')
        return (datetime.today() - dt).days
    except Exception:
        return None

def last_sunday():
    """Retourne la date du dernier dimanche (ou aujourd'hui si on est dimanche)."""
    today = datetime.today()
    # weekday(): lundi=0 ... dimanche=6
    days_since_sunday = (today.weekday() + 1) % 7   # 0 si dimanche, 1 si lundi...
    sunday = today - timedelta(days=days_since_sunday)
    return sunday.strftime('%Y-%m-%d')

def fetch_odoo_data(date_from=None, date_to=None, include_archived=False):
    print(f"\nConnexion à Odoo...")
    common = xmlrpc.client.ServerProxy(f"{ODOO_URL}/xmlrpc/2/common")
    uid = common.authenticate(ODOO_DB, ODOO_USERNAME, ODOO_PASSWORD, {})
    if not uid:
        raise Exception("Connexion échouée.")
    models = xmlrpc.client.ServerProxy(f"{ODOO_URL}/xmlrpc/2/object")
    print(f"  Connecté (uid={uid})")

    # Étapes valides actuelles dans Odoo
    print("Récupération des étapes CRM valides...")
    valid_stages_raw = models.execute_kw(
        ODOO_DB, uid, ODOO_PASSWORD,
        'crm.stage', 'search_read', [[]],
        {'fields': ['id', 'name'], 'context': {'lang': 'fr_BE'}}
    )
    valid_stage_names = set(s['name'] for s in valid_stages_raw)
    # Anciens noms connus (renommés dans Odoo) — traités comme valides
    valid_stage_names.add('RDV démo planifié')
    valid_stage_names.add('Nouveau lead')
    valid_stage_names.add('Contacté')
    valid_stage_names.add('Offre à Envoyer')
    valid_stage_names.add('À relancer')
    print(f"  {len(valid_stage_names)} étapes valides : {sorted(valid_stage_names)}")

    # Tracking domain
    domain = [['field_id.name', '=', 'stage_id']]
    if date_from:
        domain.append(['create_date', '>=', date_from + ' 00:00:00'])
    if date_to:
        domain.append(['create_date', '<=', date_to + ' 23:59:59'])

    print("Récupération des changements d'étape...")
    tracking = models.execute_kw(
        ODOO_DB, uid, ODOO_PASSWORD,
        'mail.tracking.value', 'search_read', [domain],
        {'fields': ['mail_message_id', 'old_value_char', 'new_value_char', 'create_date'],
         'limit': 10000, 'order': 'create_date desc'}
    )
    print(f"  {len(tracking)} changements")
    if not tracking:
        return build_empty(date_from, date_to)

    msg_ids = list(set(t['mail_message_id'][0] for t in tracking))

    print("Récupération des messages...")
    messages = []
    for i in range(0, len(msg_ids), 500):
        res = models.execute_kw(
            ODOO_DB, uid, ODOO_PASSWORD,
            'mail.message', 'search_read',
            [[['id', 'in', msg_ids[i:i+500]], ['model', '=', 'crm.lead']]],
            {'fields': ['id', 'res_id', 'author_id', 'date']}
        )
        messages.extend(res)
    msg_map = {m['id']: m for m in messages}
    lead_ids = list(set(m['res_id'] for m in messages if m.get('res_id')))
    print(f"  {len(lead_ids)} leads uniques")

    # Leads — actifs + archivés selon option
    print("Récupération des leads...")
    leads_raw = []
    for i in range(0, len(lead_ids), 200):
        batch = lead_ids[i:i+200]
        res = models.execute_kw(
            ODOO_DB, uid, ODOO_PASSWORD,
            'crm.lead', 'search_read',
            [[['id', 'in', batch]]],
            {
                'fields': ['id','name','partner_id','user_id','stage_id',
                           'date_last_stage_update','probability',
                           'activity_user_id','activity_date_deadline',
                           'activity_type_id','active','expected_revenue'],
                'context': {'active_test': False, 'lang': 'fr_BE'}
            }
        )
        leads_raw.extend(res)
    leads_map = {l['id']: l for l in leads_raw}
    n_arch = sum(1 for l in leads_raw if not l.get('active', True))
    print(f"  {len(leads_raw)} leads ({n_arch} archivés)")

    # Tous les leads CRM (pour KPIs — nouveaux prospects etc.)
    print("Récupération de tous les leads CRM pour KPIs...")
    all_leads_kpi = []
    try:
        offset = 0
        while True:
            batch = models.execute_kw(
                ODOO_DB, uid, ODOO_PASSWORD,
                'crm.lead', 'search_read',
                [[['type','=','opportunity']]],
                {'fields': ['id','name','partner_id','user_id','stage_id',
                            'create_date','date_deadline','probability',
                            'expected_revenue','active','write_date',
                            'date_closed','lost_reason_id'],
                 'context': {'active_test': False, 'lang': 'fr_BE'},
                 'limit': 500, 'offset': offset}
            )
            if not batch: break
            all_leads_kpi.extend(batch)
            if len(batch) < 500: break
            offset += 500
        print(f"  {len(all_leads_kpi)} leads CRM total")
    except Exception as e:
        print(f"  Leads KPI non disponibles: {e}")

    # Activités
    print("Récupération des activités...")
    act_map = {}
    try:
        acts = models.execute_kw(
            ODOO_DB, uid, ODOO_PASSWORD,
            'mail.activity', 'search_read',
            [[['res_model','=','crm.lead'],['res_id','in',lead_ids]]],
            {'fields': ['res_id','activity_type_id','user_id','date_deadline','summary','note']}
        )
        for a in acts:
            if a['res_id'] not in act_map:
                act_map[a['res_id']] = a
    except Exception as e:
        print(f"  Activités non disponibles: {e}")

    # Mots-clés d'étapes "sales" (corrections internes)
    dirty_kw = ['!!!', 'supprimer', 'NE PAS', 'Remise dans le flux NE']
    def is_dirty(s):
        return not s or any(d in str(s) for d in dirty_kw)

    def stage_status(s):
        if is_dirty(s): return 'dirty'
        if s and s not in valid_stage_names: return 'deleted'  # étape supprimée
        return 'ok'

    movements = []
    for t in tracking:
        msg_id = t['mail_message_id'][0]
        if msg_id not in msg_map:
            continue
        msg  = msg_map[msg_id]
        lid  = msg.get('res_id')
        lead = leads_map.get(lid, {})
        act  = act_map.get(lid, {})
        is_archived = not lead.get('active', True)

        # Sauter les archivés si pas demandé
        if is_archived and not include_archived:
            continue

        de   = t.get('old_value_char') or ''
        vers = t.get('new_value_char') or ''
        s_de   = stage_status(de)
        s_vers = stage_status(vers)

        movements.append({
            'lead_id'           : lid,
            'opportunite'       : lead.get('name', f'Lead #{lid}'),
            'nom_contact'       : (lead.get('partner_id') or [None,''])[1],
            'vendeur'           : (lead.get('user_id') or [None,''])[1],
            'etape_actuelle'    : (lead.get('stage_id') or [None,''])[1],
            'date_maj_etape'    : (lead.get('date_last_stage_update') or '')[:10],
            'jours_bloque'      : _days_since(lead.get('date_last_stage_update')),
            'activite_type'     : (act.get('activity_type_id') or [None,''])[1] or '',
            'activite_assigne'  : (act.get('user_id') or [None,''])[1] or '',
            'activite_echeance' : act.get('date_deadline') or '',
            'activite_sujet'    : act.get('summary') or '',
            'activite_note'     : _strip_html(act.get('note') or ''),
            'archived'          : is_archived,
            'de'                : de,
            'vers'              : vers,
            'de_status'         : s_de,    # ok / dirty / deleted
            'vers_status'       : s_vers,
            'date'              : _to_local(t.get('create_date') or ''),  # date + heure (heure locale)
            'auteur'            : (msg.get('author_id') or [None,''])[1] or '',
            'dirty'             : s_de != 'ok' or s_vers != 'ok',
        })

    # Matrice flux — uniquement étapes valides (ok)
    flux = defaultdict(int)
    for m in movements:
        if m['de_status'] == 'ok' and m['vers_status'] == 'ok':
            flux[(m['de'], m['vers'])] += 1
    matrix = [{'de':k[0],'vers':k[1],'n':v}
              for k,v in sorted(flux.items(), key=lambda x:-x[1])]

    arrivals = defaultdict(int)
    departures = defaultdict(int)
    for r in matrix:
        arrivals[r['vers']] += r['n']
        departures[r['de']] += r['n']
    all_stages = sorted(set(list(arrivals)+list(departures)))
    stage_stats = sorted(
        [{'stage':s,'in':arrivals[s],'out':departures[s],'solde':arrivals[s]-departures[s]}
         for s in all_stages],
        key=lambda x:-(x['in']+x['out'])
    )

    # Stats détaillées par auteur
    auth_detail = defaultdict(lambda: {
        'total': 0,
        'leads': set(),
        'transitions': defaultdict(int),   # (de,vers) → count
        'stages_touched': set(),
        'last_action': '',
    })
    for m in movements:
        if not m['dirty'] and m['auteur']:
            a = auth_detail[m['auteur']]
            a['total'] += 1
            a['leads'].add(m['lead_id'])
            a['transitions'][(m['de'], m['vers'])] += 1
            a['stages_touched'].add(m['de'])
            a['stages_touched'].add(m['vers'])
            if m['date'] > a['last_action']:
                a['last_action'] = m['date']

    author_stats = []
    for name, d in sorted(auth_detail.items(), key=lambda x: -x[1]['total']):
        top_trans = sorted(d['transitions'].items(), key=lambda x: -x[1])[:5]
        author_stats.append({
            'name'        : name,
            'n'           : d['total'],
            'leads'       : len(d['leads']),
            'stages'      : len(d['stages_touched']),
            'last_action' : d['last_action'],
            'top_trans'   : [{'de':k[0],'vers':k[1],'n':v} for k,v in top_trans],
        })

    top = matrix[0] if matrix else {}
    return {
        'movements' : movements,
        'matrix'    : matrix,
        'stages'    : stage_stats,
        'authors'   : author_stats,
        'valid_stages': sorted(valid_stage_names),
    'all_leads': [{
        'id'          : l['id'],
        'name'        : l.get('name',''),
        'contact'     : (l.get('partner_id') or [None,''])[1],
        'vendeur'     : (l.get('user_id') or [None,''])[1],
        'etape'       : (l.get('stage_id') or [None,''])[1],
        'create_date' : _to_local((l.get('create_date') or '')[:16]),
        'active'      : l.get('active', True),
        'proba'       : l.get('probability', 0),
        'revenue'     : l.get('expected_revenue', 0),
        'write_date'  : _to_local((l.get('write_date') or '')[:16]),
        'date_closed' : _to_local((l.get('date_closed') or l.get('write_date') or '')[:16]),
        'lost_reason' : (l.get('lost_reason_id') or [None,''])[1] if isinstance(l.get('lost_reason_id'), list) else '',
    } for l in all_leads_kpi],
        'ordered_stages': [s['name'] for s in sorted(valid_stages_raw, key=lambda x: x.get('sequence',99))],
    'stats': {
            'total'        : len(movements),
            'unique_leads' : len(set(m['lead_id'] for m in movements)),
            'transitions'  : len(matrix),
            'archived_shown': sum(1 for m in movements if m['archived']),
            'deleted_stages': len(set(
                m['de'] for m in movements if m['de_status']=='deleted'
            ) | set(m['vers'] for m in movements if m['vers_status']=='deleted')),
            'top'          : top,
            'date_from'    : date_from or '',
            'date_to'      : date_to or '',
            'include_archived': include_archived,
        }
    }


def build_empty(df=None, dt=None):
    return {'movements':[],'matrix':[],'stages':[],'authors':[],'valid_stages':[],
            'stats':{'total':0,'unique_leads':0,'transitions':0,'archived_shown':0,
                     'deleted_stages':0,'top':{},'date_from':df or '','date_to':dt or '','include_archived':False}}


def push_to_supabase(data):
    """Ecrit (ou met a jour) la ligne unique de la table comcom_data sur Supabase."""
    url = SUPABASE_URL.rstrip('/') + '/rest/v1/comcom_data'
    headers = {
        'apikey': SUPABASE_SERVICE_KEY,
        'Authorization': 'Bearer ' + SUPABASE_SERVICE_KEY,
        'Content-Type': 'application/json',
        'Prefer': 'resolution=merge-duplicates',
    }
    body = [{
        'id': 1,
        'payload': data,
        'updated_at': datetime.utcnow().isoformat(),
    }]
    resp = requests.post(url, headers=headers, json=body, timeout=30)
    if resp.status_code not in (200, 201):
        print("ERREUR Supabase :", resp.status_code, resp.text)
        sys.exit(1)
    print("OK - donnees envoyees a Supabase avec succes.")


if __name__ == '__main__':
    print("Recuperation des donnees Odoo...")
    data = fetch_odoo_data()
    print(f"OK - {data['stats']['total']} mouvements, {len(data['all_leads'])} leads recuperes.")
    print("Envoi vers Supabase...")
    push_to_supabase(data)
