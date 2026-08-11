# Dashboard Flux Leads — Odoo CRM

Dashboard local (KPI, flux de leads, activite par vendeur) connecte a Odoo
via XML-RPC. Sert une page web sur `http://localhost:8765`.

## Installation (a faire une seule fois)

1. Installer Python 3 si ce n'est pas deja fait.
2. Dans le dossier du projet, installer la dependance :
   ```
   pip install -r requirements.txt
   ```
3. Copier `.env.example` en `.env` :
   ```
   cp .env.example .env
   ```
4. Ouvrir `.env` et remplacer les valeurs par tes vrais identifiants Odoo
   (URL, base de donnees, email, mot de passe ou cle API).

## Lancer le dashboard

```
python3 flux_leads.py
```

Le navigateur s'ouvre automatiquement sur `http://localhost:8765`.

## Securite — a lire avant de toucher a quoi que ce soit

**Le fichier `.env` contient un vrai mot de passe. Il ne doit JAMAIS etre
envoye sur GitHub, ni partage par email/chat/Slack.**

- Le `.gitignore` fourni exclut deja `.env` automatiquement — meme si tu
  fais un `git add .` par erreur, il ne partira pas.
- Seul `.env.example` (qui ne contient AUCUN vrai identifiant) doit etre
  envoye sur GitHub. Il sert de modele pour toute personne qui reprend
  le projet.
- Le code (`flux_leads.py`) ne contient plus aucun identifiant en dur —
  il va les chercher dans `.env` au demarrage, via la librairie standard
  `python-dotenv`.
- Si jamais un identifiant a deja circule en clair quelque part
  (fichier partage, capture d'ecran, chat, ancien commit Git...), il
  faut le considerer comme compromis et le regenerer/changer dans Odoo,
  meme si le code a ete corrige depuis.

## Pourquoi cette structure

| Fichier              | Contient des secrets ? | Va sur GitHub ? |
|-----------------------|:----------------------:|:----------------:|
| `flux_leads.py`       | Non                     | Oui               |
| `requirements.txt`    | Non                     | Oui               |
| `.env.example`        | Non (valeurs vides)     | Oui               |
| `.gitignore`          | Non                     | Oui               |
| `.env`                | **Oui**                 | **Jamais**        |

## Prochaine etape (production)

Cette version locale (`.env`) est adaptee pour developper/tester sur ta
machine. Pour une mise en ligne (ex. `procyo.auditassur.be/comcom`), les
identifiants ne doivent plus etre dans un fichier `.env` du tout, mais
geres via les "Environment Variables" de la plateforme d'hebergement
(Vercel), qui ne sont jamais exposees ni au navigateur ni au depot
GitHub. Voir avec Claude pour la migration quand tu es pret.
