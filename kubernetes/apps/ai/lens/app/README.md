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
| `admin_token`    | Login admin de l'UI Lens (`lens-admin` Secret)                |
| `service_token`  | Auth interne LiteLLM → Lens (`lens-connection`)               |
| `gateway_secret` | Vérification de l'identité envoyée par LiteLLM (`lens-connection`) |

`service_token` et `gateway_secret` doivent être **différents** et faire
**32 à 512 caractères** : LiteLLM ignore silencieusement un secret plus court
(`/lens/service` → 503) et le pod Lens part en crashloop
(`LITELLM_LENS_SERVICE_TOKEN must contain 32 and 512 characters`).
`openssl rand -hex 32` produit 64 caractères. Les clés de tracing des agents
(créées dans l'UI) sont encore autre chose.

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

## Premier usage

1. Ouvrir `https://lens.oxygn.dev/ui/` et coller `admin_token`.
2. **Traces > Set up tracing** → générer une tracing key, choisir un agent.
3. Brancher un seul agent d'abord (ex. opencode) :

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

- **Perte silencieuse de traces sous charge** : l'exporteur LiteLLM bufferise
  1000 événements / 32 MiB puis **jette** (pas de backpressure), et tout
  enregistrement > 1 MiB est droppé. Un prompt ou une sortie d'outil énorme
  n'apparaît pas dans la trace. En contrepartie, Lens injoignable ou disque
  plein ne bloque **jamais** les requêtes LLM.
- **Premier démarrage** : Lens peut redémarrer plusieurs fois avec
  `Error: Storage(Storage(Transport))` tant que ClickHouse n'est pas ready
  (documenté upstream) — c'est normal, `wait: true` couvre l'attente.
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
- **Image** : le chart 0.1.0 épingle lui-même `image.digest` dans ses values
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
