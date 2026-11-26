# Pilot à ma sauce

Status: plan validé le 2026-11-23. Maquettes : [docs/mockups/pilot-a-ma-sauce.html](../mockups/pilot-a-ma-sauce.html)
(HTML statique, données fictives, pas les vraies vues SwiftUI).

Fork personnel de Pilot. L'app cible est **apps/macos (SwiftUI)**. Le daemon continue de suivre l'upstream ;
les changements UI de l'upstream (Pilot Next) sont ignorés.

## Décisions

| Sujet                | Décision                                                                                                                                              |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| App                  | SwiftUI (`apps/macos`)                                                                                                                                |
| Scripts de workspace | Dans les réglages projet Pilot, hors du repo                                                                                                          |
| Types de mission     | Quick fix (worktree léger, env du main), Feature (worktree + setup complet), Squad (orchestrateur + un worktree par agent, un env de mission partagé) |
| Squad                | Un serveur par agent, lancé à la demande. Une seule tâche touche au schéma à la fois. Une PR par agent, en stack                                      |
| Slack                | Les règles commencent en suggestions dans l'Inbox. Les réponses sont des brouillons, envoyés seulement après ta validation                            |
| Investigate          | Outils de lecture `unified-mcp` (allowlist par nom d'outil) et DB en lecture seule                                                                    |
| Spécialistes         | RM, Insurance, Renewals (conversion de `renewal-debugger`). Routage par le classifieur Slack, réassignation en un clic                                |
| Routines             | Expression cron brute (5 champs, fuseau local)                                                                                                        |
| Threads GitHub       | Pilot les résout avec ton compte `gh`, après ta confirmation. L'agent ne résout jamais                                                                |
| Today Desk           | Page native séparée, alimentée par 3 routines Pilot ; Start lance une mission ; Lessons gardées                                                       |
| Design               | Style Linear : Theme v2, aucun dithering, marques d'état fixes, clair et sombre                                                                       |
| Sidebar              | Inbox · Today · Mon sprint · Reviews · Routines / En cours (par mission) / Projets                                                                    |

## Briques communes

- **WorkStarter** (daemon) : démarrer un chat, une mission ou un Investigate depuis un ticket, un message Slack, une
  routine ou un item Today, et lier l'item avec son effet externe (Linear In progress, réaction 👀) dans la même
  opération. Corrige un bug : `schedules.ts` lie l'item via `TrackedItemStore.patch`, ce qui n'appelle jamais
  `SourceRegistry.startLinear` / `startSlack`.
- **ScriptRunner** (daemon) : exécute les scripts du projet (setup, code-only, run, checks), avec timeout, plafond de
  sortie, Stop, et les variables `PILOT_*`.
- **Mode de workspace `git-worktree`** : un vrai `git worktree add`. Le mode `clone` actuel, sur un repo git, fait
  `git init` + alternates : les scripts qui lisent `git worktree list` (comme ceux de `product`) se croient alors
  dans le worktree principal.
- **Theme v2** : tokens posés avant les nouvelles pages.

## Volets

1. **Scripts de workspace** : réglages `setup[]`, `run`, `checks[]`. Le setup s'exécute dans `sessions.start` après
   la création du workspace et avant `ensureWorker`. Les checks tournent après un run qui a modifié des fichiers ;
   un échec part à l'agent selon les règles de follow-up.
2. **Actions PR** : `POST /api/sessions/:id/pull-requests/actions` avec `resolve_comments`, `rebase_main` ou
   `fix_ci`. Le builder de message est extrait de `followUpPullRequests`. Une action manuelle ne consomme pas le
   quota de 3 follow-ups. Rebase : jj/git sans conflit, sinon la main passe à l'agent.
3. **Sprint board** : `GET /api/projects/:id/sprint` (colonnes par état mappé, avec chat/mission et PR liés).
   Page kanban. Les nouveaux items du cycle ont un badge.
4. **Agent Slack** : `slack-rules.ts` après le classement (suggestions). Un outil `slack_reply_draft` produit un
   brouillon, envoyé seulement par une route utilisateur. C'est la seule nouvelle écriture Slack.
5. **Routines** : `recurrence: { cron }` sur un item planifié. Chaque déclenchement crée l'occurrence suivante. Un
   seul rattrapage après la veille.
6. **Playbook bug** : mode Investigate = Ask + allowlist d'outils `unified-mcp` + DB en lecture + skill
   `pilot-bug-investigation`. Le bouton **Fix it** reprend `buildWithContext`, l'envoie, et lie l'item.
7. **Design** : Theme v2, sidebar par workflow, marques d'état fixes au lieu de `DitherCorner`, suppression de
   `DitherScene` ; DESIGN.md réécrit.
8. **Types de mission & envs** : `Mission.kind`, profils d'env (full / code-only / run), un env de mission (créé
   une fois, partagé, supprimé à la fin), un slot de ports par agent, verrou de migrations, bouton
   **Isoler cet agent**, PR en stack.
9. **Spécialistes** : profils (repos, prompt de domaine, skills, outils, DB, mémoire). Le classifieur choisit le
   spécialiste ; les réassignations alimentent le guide de triage.
10. **Today Desk** : routines plan / refresh / wrap avec des skills perso `today-plan` / `today-wrap` et un outil
    `today_write`. Stockage `today.sqlite`, page native, Start → Nouvelle mission.
11. **Boosters dev** : commentaires inline sur le diff → l'agent ; page Reviews + Tester cette PR (+ pré-review) ;
    bouton Charger ce client (`dump-client`, avec confirmation).

## Ordre des phases

P0 décisions et bugfix → P1 WorkStarter → P2 Theme v2 → P3 Scripts → P3b Types de mission & envs →
P4 Actions PR → P5 Routines → P5b Today Desk → P6 Sprint board → P7 Playbook bug → P8 Agent Slack →
P8b Spécialistes → P9 Design (navigation, marques, pages) → P10 Boosters.

Chaque phase est livrable seule et vérifiée avant la suivante : `pnpm typecheck`, tests ciblés, et pour le Swift
`apps/macos/scripts/test.sh` et `apps/macos/scripts/build.sh`.

## Points ouverts

- Quels outils de lecture `unified-mcp` expose dans pi (conditionne Investigate et Today).
- Le MCP `slack` de pi expose-t-il un outil d'envoi de message ?
- Parseur cron : dépendance `croner` ou implémentation maison.
- Les copies perso des skills Today Desk doivent être resynchronisées à la main quand le plugin change.

## État au 2026-11-24

Toutes les phases sont implémentées sur `feat/pilot-a-ma-sauce` (non commité). Écarts au plan :

- **Today** : une page par jour en JSON (`~/.pilot/today/<date>.json`) au lieu de `today.sqlite`. Les routines sont des
  chats Ask `todayDesk` qui chargent les skills perso `today-plan` / `today-wrap`.
- **Pages Today, Sprint, Reviews, Routines** : fenêtres séparées ouvertes depuis la sidebar, pas encore des routes de
  la fenêtre principale ; la sidebar n'est pas regroupée « En cours par mission ».
- **Squad** : l'env partagé est celui du premier agent de la mission (pas un env de mission séparé). Pas de slot de
  ports ni de verrou de migration côté Pilot : les scripts `product` gèrent les slots, et le prompt dit de ne migrer
  que si la tâche le demande. Pas de PR en stack automatique.
- **Slack** : les règles restent les labels + classifieur existants ; nouveau : réponse dans le thread, brouillon validé.
- **Spécialistes** : choisis par le skill `investigate-bug` ou à la main dans le composer ; pas encore de guide de
  triage alimenté par les réassignations.
- **Run** (bouton dans le chat) : pas fait.
