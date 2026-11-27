# LiteLLM Lens

Store de traces + analyse de qualité pour les agents qui passent par le
gateway LiteLLM. Trois fonctions :

- **Traces** : un run agent = une trace (prompts, appels d'outils, latence,
  coût), avec jointure aux *request logs* LiteLLM pour le coût réel.
- **Investigations** : un modèle d'analyse relit un échantillon de traces selon
  des critères et produit des findings groupés avec preuve.
- **Model optimizations** : comparaison de modèles en Live / Shadow / Offline
  (qualité par juge LLM, coût, latence) — utilisable pour arbitrer entre les
  groupes OpenCode Go et valider le fallback `beam-free`.

Déployé dans le namespace `ai`, à côté de `litellm`. Le chart embarque son
propre ClickHouse (StatefulSet + PVC local, rétention 14 j).

## Pré-requis 1Password

Créer un item `lens` avec trois champs (valeurs générées, ex. `openssl rand -hex 32`) :

| Champ            | Usage                                                        |
| ---------------- | ------------------------------------------------------------ |
| `ADMIN_TOKEN`    | Login admin de l'UI Lens (`lens-admin` Secret)                |
| `SERVICE_TOKEN`  | Auth interne LiteLLM → Lens (`lens-connection`)               |
| `GATEWAY_SECRET` | Vérification de l'identité envoyée par LiteLLM (`lens-connection`) |

`SERVICE_TOKEN` et `GATEWAY_SECRET` doivent être **différents** et faire
**32 à 512 caractères** : LiteLLM ignore silencieusement un secret plus court
(`/lens/service` → 503) et le pod Lens part en crashloop
(`LITELLM_LENS_SERVICE_TOKEN must contain 32 and 512 characters`).
`openssl rand -hex 32` produit 64 caractères.

Les clés de tracing des agents sont encore autre chose : elles sont générées
**une fois** dans l'UI (voir *Premier usage*), pas par `openssl`, et rangées
dans ce même item sous `OPENCODE_TRACING_KEY`, `DEVCLAW_TRACING_KEY` et
`MAINCLAW_TRACING_KEY`. Une clé **par agent** : réutiliser la même clé fait
atterrir toutes les traces sur un seul agent dans Lens. Chaque champ doit
exister **avant** le merge de la PR qui le consomme — un champ manquant fait
échouer toute la sync de l'`ExternalSecret` (`map has no entry for key`), donc
la configuration de l'agent n'est plus rendue et son pod ne démarre pas.

## Câblage côté LiteLLM

Dans `kubernetes/apps/ai/litellm/app/litellmproxy.yaml` :

- env `LITELLM_LENS_URL=http://lens.ai.svc.cluster.local:4318`
- env `LITELLM_LENS_PUBLIC_URL=https://lens.oxygn.dev`
- env `LITELLM_LENS_SERVICE_TOKEN` / `LENS_GATEWAY_SECRET` depuis le Secret
  `lens-connection`
- `generalSettings.tracing.store.type: lens`

**Version minimale : LiteLLM ≥ 1.108.0.** En dessous, les variables sont
inertes et l'entrée « Lens » n'apparaît pas dans la sidebar. Le cluster tourne
déjà en 1.110.2, aucune montée de version n'est nécessaire pour ce PR.

Vérification de la connexion (crédential admin LiteLLM, depuis le réseau
interne — `litellm.oxygn.dev` est derrière `envoy-internal`, pas de résolution
split-horizon depuis l'extérieur) :

```bash
curl -s https://litellm.oxygn.dev/lens/service \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq
# attendu : connected=true, status.storage_ready=true,
#           status.credentials_ready=true, status.public_contract=1
```

## Analyse (Lens → gateway)

Les traces s'ingèrent **sans** fournisseur de modèle : c'est l'onglet
*Investigations* (Findings) qui en a besoin, et sans lui l'UI affiche
« no model gateway configured ».

Lens appelle le gateway avec deux variables lues **au démarrage** :

- `LENS_GATEWAY_API_BASE=http://litellm.ai:4000`
- `LENS_GATEWAY_API_KEY` ← Secret `lens-analysis` (clé `api-key`)

Une troisième, `LENS_GATEWAY_URL=http://litellm.ai:4000`, désigne l'endpoint
d'analyse **en tant que gateway** : Lens y attache alors ses métadonnées
internes (l'agent auquel appartient le run). Sans elle, tous les appels
d'analyse arrivent non étiquetés et se confondent sous le seul alias de clé
`LensAnalysis` — la dépense totale reste visible, la répartition par agent non.
C'est ce qui permet de répondre à « quel agent consomme sans produire de
Findings ».

La clé est une `LiteLLMVirtualKey` (`kubernetes/apps/ai/litellm/app/virtualkeys/lens-analysis.yaml`)
limitée à `dsv41f` et plafonnée à **1 $ par jour**. Mesuré sur 24 h de
production : 2 288 appels de ~34 000 tokens d'input, 4,05 $ — le coût suit le
**nombre d'appels** que Lens réémet à mesure que les traces grossissent, pas le
prix du modèle (0 token caché, le prompt caching de l'upstream n'est pas
exploité). Un plafond sur 30 jours laissait donc une seule journée en
consommer 40 %, d'où la fenêtre journalière. Au plafond l'analyse s'arrête
proprement au lieu de dépasser en silence ; c'est un seul nombre à relever si
les investigations s'avèrent rentables. L'opérateur génère la clé via l'admin
API et écrit le Secret dans `ai` ; volontairement **pas de `PushSecret`** vers
1Password : le seul consommateur est le Deployment `lens` dans ce namespace.

L'UI a besoin d'une troisième variable pour proposer **« Log in with
LiteLLM »** sur sa page de connexion : `LENS_GATEWAY_PUBLIC_URL=https://litellm.oxygn.dev`,
l'origine **navigateur** du gateway (distincte de `LENS_GATEWAY_API_BASE`, qui
est l'adresse in-cluster). Sans elle, Lens retombe sur `LENS_GATEWAY_URL` puis sur
l'API base, qu'un navigateur ne peut pas résoudre, et seul le login par
`ADMIN_TOKEN` reste proposé.

`optional: true` sur le `secretKeyRef` : au premier apply le Secret n'existe pas
encore (l'opérateur le crée après la CR), et sans ça le pod partirait en
`CreateContainerConfigError`. Le chart n'expose aucune annotation de pod
template, donc pas de reloader sur ce Secret : après sa création (ou une
rotation), relancer le Deployment à la main.

```bash
kubectl -n ai rollout restart deployment/lens
```

Vérification dans l'UI : **Settings > LiteLLM gateway** (test de connexion +
rafraîchissement de la liste des modèles sans redémarrer), puis **Settings >
Analysis > Check configuration** doit afficher `dsv41f` et « Analysis is
configured ». Les appels de Lens portent `User-Agent … lens-signals` et ne sont
pas analysés eux-mêmes.

### Si le message persiste

`optional: true` a un revers : si l'opérateur n'arrive pas à créer la clé
(admin API indisponible, budget refusé…), le Secret n'existe jamais, le pod
démarre quand même, le HelmRelease reste `Ready`, et l'UI ré-affiche exactement
le symptôme d'origine — sans aucun signal dans Flux. Le diagnostic est donc à
faire côté CR, pas côté pod :

```bash
kubectl -n ai get litellmvirtualkey lens-analysis -o yaml   # .status.conditions
kubectl -n ai get secret lens-analysis                      # absent = CR en échec
```

Une rotation (ou un changement de `models` / `maxBudget` dans la CR) est
appliquée par l'opérateur côté proxy, mais le pod a lu la clé **au démarrage** :
un `rollout restart` reste nécessaire pour qu'il en tienne compte. Supprimer la
CR supprime la clé côté LiteLLM.

## Premier usage

1. Ouvrir `https://lens.oxygn.dev/ui/` et coller `ADMIN_TOKEN`.
2. **Traces > Connect project** → générer une tracing key **par agent**
   (opencode, devclaw, mainclaw), pas une clé partagée : l'agent est déduit de
   la clé dans Lens. La clé n'est affichée qu'une fois : la ranger dans l'item
   1Password `lens` sous le champ correspondant.
3. Les agents in-cluster sont déjà câblés : `opencode`
   (`kubernetes/apps/ai/opencode`, variables `OTEL_*` dans son `HelmRelease`)
   et les agents openclaw `devclaw` / `mainclaw` (plugin
   `diagnostics-otel` activé dans `resources/openclaw.json`). Leurs clés
   arrivent par `ExternalSecret` depuis l'item 1Password `lens`
   (`OPENCODE_TRACING_KEY`, `DEVCLAW_TRACING_KEY`, `MAINCLAW_TRACING_KEY`) :
   il n'y a rien à exporter à la main. Côté openclaw, l'identification passe
   par `diagnostics.otel.serviceName` (`devclaw` / `mainclaw`) : les deux
   configs déclarent le même id d'agent (`main` dans `agents.entries`), donc
   filtrer par service dans Lens plutôt que par nom d'agent — à confirmer sur
   la première trace reçue. La recette ci-dessous reste la
   référence pour tout autre agent :

   ```bash
   export OTEL_EXPORTER_OTLP_ENDPOINT=https://lens.oxygn.dev
   export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <tracing-key>"
   export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
   export OTEL_RESOURCE_ATTRIBUTES="gen_ai.agent.name=opencode"
   ```

   opencode n'exporte rien sans activer OTel dans sa config
   (`experimental.openTelemetry: true` dans `opencode.jsonc`) : les variables
   `OTEL_*` seules sont inertes. La propagation du `traceparent` vers LiteLLM
   (pour rejoindre spans agent et coût gateway dans la même trace) vient du
   plugin OTel d'opencode (`OPENCODE_TRACE_PROPAGATION_PROVIDERS`) — à vérifier
   selon la version installée.

   Pour un agent **in-cluster**, préférer l'endpoint interne
   `http://lens.ai.svc.cluster.local:4318` : ça évite la limite de buffer
   d'Envoy sur les batchs OTLP volumineux (et le TLS inutile). L'endpoint
   public `https://lens.oxygn.dev` sert aux agents hors cluster **mais sur le
   réseau interne / VPN** : il pointe sur l'IP privée d'`envoy-internal`,
   donc ni le DNS ni l'IP ne sont joignables depuis l'extérieur. Pour un
   agent sur un laptop nomade ou en CI, il faudrait une exposition dédiée
   (le chart ne gère que l'`Ingress` standard, non utilisé ici).

## Ordre de déploiement

L'item 1Password `lens` doit exister **avant** le merge. Le pod Lens monte
`lens-admin` en `secretKeyRef` non-optionnelle (contrairement au gateway
LiteLLM, où les deux variables Lens sont `optional: true` pour ne pas bloquer
son démarrage). Sans l'item, Lens reste en `CreateContainerConfigError`.

Après merge :

```bash
kubectl get externalsecret -n ai lens-admin lens-connection   # SecretSynced
kubectl get pods -n ai -l app.kubernetes.io/name=lens
kubectl get pods -n ai -l app.kubernetes.io/component=lens-clickhouse
```

Les pods ClickHouse ne portent pas de label `name` (seulement `instance` et
`component`), d'où le sélecteur différent.

Puis vérifier `GET /lens/service` côté LiteLLM (section précédente) et les
métriques du gateway (`/metrics`) : la clé `prometheus_adapter` de
`litellm_settings` a été supprimée (elle n'existe plus dans LiteLLM 1.110.2,
déjà en prod) ; les séries restent alimentées par `callbacks: [prometheus]`.

**`optional: true`** : LiteLLM lit les variables Lens une seule fois au
démarrage (`manage_tracing`). Le pod porte
`podAnnotations: reloader.stakater.com/auto: "true"`, donc reloader le relance
automatiquement dès que `lens-connection` apparaît ou change — l'ordre de
création de l'item 1Password n'est pas critique. Si `/lens/service` répond
`connected=false` alors que les secrets sont synchés (reloader désactivé ou
annotation retirée) :

```bash
kubectl rollout restart deployment -n ai -l app.kubernetes.io/name=litellm
```

## Limites connues

- **UI 0.3.0 : la vue Traces est filtrée par défaut.** Depuis la 0.3.0 les
  traces sans appel modèle/outil sont masquées (un bouton permet de les
  revoir), et le sélecteur d'agent propose désormais *All agents* — sans cette
  option on ne voit qu'un agent à la fois, et les deux configs openclaw
  déclarent le même id `main`, donc elles se regroupent sous ce nom. L'agent
  est désormais attribué par **la clé de tracing qui envoie** les spans.
  Quand l'UI est montée par le gateway LiteLLM, les pages admin passent sous
  `/lens/admin`.

- **Perte silencieuse de traces sous charge** : l'exporteur LiteLLM bufferise
  1000 événements / 32 MiB puis **jette** (pas de backpressure), et tout
  enregistrement > 1 MiB est droppé. Un prompt ou une sortie d'outil énorme
  n'apparaît pas dans la trace. En contrepartie, Lens injoignable ou disque
  plein ne bloque **jamais** les requêtes LLM.
- **ClickHouse = AVX2 obligatoire ≥ 26.6** : les images amd64 de ClickHouse
  ≥ 26.6 sont compilées pour x86-64-v3 ; on garde donc le digest du chart
  (pas de pin d'image). Sur un vCPU sans AVX2 (VM Proxmox en
  `kvm64`), le conteneur meurt en `Illegal instruction` (exit 132) et Lens
  boucle sur `Error: Storage(Storage(Transport))`. Seul `k8s-3` expose AVX2,
  donc un `postRenderer` dans `helmrelease.yaml` épingle le StatefulSet
  ClickHouse sur ce noeud (+ toleration `workload=ai:NoSchedule`).
  Correctif de fond : passer les VMs en CPU `host` côté Proxmox, ce qui rendra
  le patch inutile. Il n'existe **pas** d'image Docker « compat » sans AVX2
  (issue ClickHouse #130104, not planned) ; les binaires `amd64compat` de
  builds.clickhouse.com ne sont pas packagés en conteneur.
  **Migration** : le PVC `data-lens-clickhouse-0` est un volume local lié à
  k8s-0 et ne peut pas suivre le pod ; après le merge, le pod ClickHouse reste
  donc `Pending` (volume non attachable sur k8s-3) tant que la séquence n'est
  pas faite, dans cet ordre : `kubectl -n ai delete pod lens-clickhouse-0`
  puis `kubectl -n ai delete pvc data-lens-clickhouse-0`. Le StatefulSet
  recrée un PVC neuf qui se lie sur k8s-3 (traces jetables, base jamais
  initialisée : aucune donnée à sauver).
- **Premier démarrage** : Lens peut redémarrer plusieurs fois avec
  `Error: Storage(Storage(Transport))` tant que ClickHouse n'est pas ready
  (documenté upstream) — c'est normal, `wait: true` couvre l'attente.
- **CLICKHOUSE_HOST en FQDN (postRenderer)** : le chart injecte
  `CLICKHOUSE_HOST=<release>-clickhouse` (nom court) dans les deux conteneurs
  du Deployment (app + init `wait-for-clickhouse`). Si ClickHouse devient
  injoignable (nœud down), les retries de l'app épuisent les search domains
  (NXDOMAIN) puis interrogent le nom court `lens-clickhouse` tel quel, que
  CoreDNS **forwarde vers l'upstream** (hostDNS Talos → routeur). Pendant la
  coupure WAN du 27/11/2026, ça a produit ~5 h de SERVFAIL amplifiés
  (retry toutes les 1–3 s par le pod Lens). Un patch strategic-merge force
  donc le FQDN `lens-clickhouse.ai.svc.cluster.local` : la résolution
  redevient purement locale au plugin kubernetes (NODATA si le pod est
  down), zéro requête vers l'upstream. À noter : `clickhouse.nameOverride`
  n'est **pas** la bonne porte — cette value sert aussi de nom au
  Service/Secret/PVC et aux selectors (immuables) du StatefulSet. Le patch
  suppose le ClickHouse bundlé du chart 0.5.x : il casserait le rendu si
  `clickhouse.enabled: false` (le chart bascule sur `CLICKHOUSE_URL`, sans
  init container) ou si une future version renomme les conteneurs.
- **Spend logs** : le tracing Lens exporte un enregistrement par requête du
  gateway (métadonnées de coût). Les corps de requête ne sont inclus que si
  `general_settings.store_prompts_in_spend_logs` est activé — ce n'est pas le
  cas ici.
- **Pas de monitoring** : ni ServiceMonitor, ni PrometheusRule sur ce
  déploiement. La saturation du PVC ClickHouse n'est pas alertée ; à ajouter
  si l'usage devient réel.

## Exploitation

- **Secrets générés par le chart** : le mot de passe ClickHouse
  (`Secret/lens-clickhouse`) n'est pas dans 1Password. Le chart utilise
  `lookup` + `helm.sh/resource-policy: keep`, donc il survit aux upgrades
  Flux — ne pas supprimer ce Secret à la main (les données deviendraient
  illisibles).
- **Upgrade du chart** : sauvegarder ClickHouse avant (`BACKUP TABLE ... TO
  Disk(...)`), cf. `docs/proxy/lens/deployment/storage` upstream. Un upgrade
  majeur de schéma peut rendre les anciennes traces illisibles.
- **Image** : le chart épingle lui-même `image.digest` dans ses values
  (chaque version du chart embarque le digest de son image) — ne pas surcharger
  `image.tag`/`image.digest` ici.
- **PVC local** : `miroir-slow-local` épingle le volume au node du premier
  consumer ; si ce node tombe, les traces sont indisponibles jusqu'à son
  retour (et le pod ne peut pas être replanifié ailleurs). Accepté : les
  traces sont jetables, ce n'est pas une source de vérité.
- **Coût des investigations** : chaque investigation a un budget mensuel.
  Faire tourner l'analyse via le gateway (`Analysis model` = un modèle
  LiteLLM) permet de réutiliser les modèles OpenCode Go et de garder le coût
  marginal quasi nul — mais les appels comptent dans le spend LiteLLM.
- **Données sensibles** : les traces contiennent prompts, arguments d'outils
  et sorties (potentiellement des creds cluster). L'UI est derrière
  `envoy-internal`, sans SSO — l'accès repose sur le token admin. Ne pas
  exposer sur `envoy-external`.
