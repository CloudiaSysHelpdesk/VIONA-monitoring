# Monitoring des services Docker avec Prometheus & Grafana

> **Portée :** Hôte(s) Docker, conteneurs applicatifs (vLLM, STT, TTS, Qdrant, MCP), GPU NVIDIA, et chaîne d’alerting vers Microsoft Teams

---

## 1) Résumé exécutif

- **Objectif :** fournir une observabilité de bout en bout (infrastructure → conteneurs → applications) avec tableaux de bord et alertes en temps réel.
- **Bénéfices clés :**
  - Diagnostic rapide des incidents (CPU/RAM disque, GPU, latences app).
  - Visibilité de la santé des services critiques (vLLM, STT, TTS, Qdrant, MCP).
  - Alertes vers Teams pour réponse opérationnelle coordonnée.
- **Technologies :** Prometheus, Grafana, cAdvisor, Node Exporter, NVIDIA DCGM Exporter, Alertmanager + bridge Teams.

---

## 2) Architecture & flux

```
[Node Exporter]      [cAdvisor]          [DCGM Exporter]       [Apps (vLLM/STT/TTS/Qdrant/MCP)]
      |                   |                       |                        | (endpoint /metrics)
      +-------------------+-----------------------+------------------------+
                                      ↓ (scrapes)
                                [Prometheus]
                                     |  
                                     | (datasource)
                                  [Grafana]
                                     |  
                                     | (alerts)
                                [Alertmanager]──►[Bridge Prometheus→Teams]──►[Canal Teams]
```

- **Réseaux Docker :** `monitoring` (interne) + rattachement à `ai-net` pour Prometheus.
- **Persistance :** volumes `prometheus-data` et `grafana-data`.
- **Séparation des rôles :**
  - *Collecte* (exporters, /metrics applicatifs)
  - *Ingestion/stockage court terme* (Prometheus, retention 15j)
  - *Visualisation* (Grafana, dashboards provisionnés)
  - *Alerte* (Alertmanager → Teams via bridge)

---

## 3) Déploiement (Docker Compose)

**Fichier :** `docker-compose.yml` (version 3.8)

### 3.1 Services déployés

- **Prometheus** (`prom/prometheus:latest`)
  - Ports : `9090:9090`
  - Volumes : `./prometheus/conf/prometheus.yml` (ro), `./prometheus/rules` (ro), `prometheus-data:/prometheus`
  - Options : `--storage.tsdb.retention.time=15d`, `--web.enable-lifecycle`
  - Réseaux : `monitoring`, `ai-net`.
- **Node Exporter** (`prom/node-exporter:latest`)
  - Expose `:9100`, accès PID host, `--path.rootfs=/`.
- **cAdvisor** (`gcr.io/cadvisor/cadvisor:v0.49.1`)
  - Monte `rootfs`, `var/run`, `sys`, `var/lib/docker` en lecture seule.
- **DCGM Exporter** (`nvidia/dcgm-exporter:latest`)
  - Expose `:9400`, `runtime: nvidia`.
- **Grafana** (`grafana/grafana:latest`)
  - Ports : `3002:3000`
  - Provisioning : `./grafana/provisioning:/etc/grafana/provisioning` (ro)
  - Variables env : admin/password, thème dark, anonymat désactivé.
- **Alertmanager** (`prom/alertmanager:latest`)
  - Ports : `9093:9093`
  - Config : `./alertmanager/alertmanager.yml` (ro).
- **Bridge Teams** (`bzon/prometheus-msteams:latest`)
  - **⚠ Secret webhook** injecté via `TEAMS_WEBHOOK_URL`. **À stocker en secret/.env, pas en clair.**

> **Commande d’orchestration**\
> `docker compose up -d`\
> **Arrêt** : `docker compose down` (ajouter `-v` *uniquement* si vous souhaitez supprimer les volumes de données).

---

## 4) Configuration Prometheus

**Fichier :** `prometheus/conf/prometheus.yml`

- **Global** : `scrape_interval: 15s`, `evaluation_interval: 15s`.
- **Alerting** : cible `alertmanager:9093`.
- **Jobs configurés :**
  - `prometheus` (self-scrape), `node-exporter`, `cadvisor`, `dcgm`
  - **Applications** : `stt`, `tts`, `qdrant`, `vllm`, `mcp-internal`, `mcp-external` (tous exposent `/metrics`)
- **Règles** : chargées depuis `rule_files: /etc/prometheus/rules/*.yml`.

> **Bonnes pratiques :**
>
> - S’assurer que tous les endpoints `/metrics` retournent **200** rapidement (<1s) et ne nécessitent pas d’auth sur le réseau `monitoring`.

---

## 5) Règles d’alerte (PromQL)

**Fichier :** `prometheus/rules/alerts.yml`

### 5.1 Disponibilité & self-monitoring

- **InstanceDown** (target `up==0` >2m)
- Échecs d’évaluation de règles
- Scrapes lents / pool exceeded

### 5.2 Hôte (Node Exporter)

- CPU >80/90% (10m), Mémoire >85/95%, Disque plein >85/95%, Inodes faibles >85%

### 5.3 Conteneurs (cAdvisor)

- Conteneur manquant (last seen >5m), redémarrages, OOMKill
- CPU/mémoire élevées (avec versions spécifiques **LLM/TTS** : vCPU, RAM absolue)
- Mémoire sans limite >4GiB (alerte dédiée)

### 5.4 GPU (DCGM)

- Utilisation >95% (15m), VRAM >90% (15m), Temp >85°C (10m), erreurs XID/ECC (critique)

### 5.5 Apps de la stack

- `up{job=~"vllm|stt|tts|qdrant|mcp-.*|grafana"}==0` (2m)

> **Seuils** à ajuster selon charge nominale. Prévoir **routes de silence** (maintenance) côté Alertmanager.

---

## 6) Alertmanager → Microsoft Teams

**Fichier :** `alertmanager/alertmanager.yml`

- **Routing** : groupement par `alertname, job, instance`, `group_wait:10s`, `group_interval:2m`, `repeat_interval:4h`.
- **Receiver** : `msteams_configs` (bridge `prometheus-msteams`).

> **Sécurité / Secret management**
>
> - **Ne jamais** committer le **webhook Teams** en clair. Utiliser `.env` + `env_file:` ou un secret Docker/Swarm.
> - Exemple :
>
> ```yaml
> services:
>   msteams-bridge:
>     environment:
>       TEAMS_WEBHOOK_URL: ${TEAMS_WEBHOOK_URL}
>     env_file: .env  # contient TEAMS_WEBHOOK_URL=...
> ```

---

## 7) Grafana : provisioning & dashboards

**Provisioning** : `grafana/provisioning` (provider `provider.yml`, chemin `options.path: /etc/grafana/provisioning/dashboards`).

**Dashboards inclus (JSON) :**

- **vLLM** (`vllm.json`) : disponibilité, TTFT/E2E (p50/p95/p99), throughput (tokens/s), cache, GPU (utilisation/VRAM/puissance), ressources conteneur.
- **TTS** (`tts.json`) : up, canaux/connexions, steps/s, p95 step, sessions, GPU, ressources conteneur.
- **STT** (`stt.json`) : QPS, erreurs %, latences globales + `/transcribe`, débit audio/mots, GPU, ressources conteneur.
- **Qdrant** (`qdrant.json`) : up/uptime, RPS par méthode/endpoint, latences p50/p95/p99, erreurs 4xx/5xx, CPU/RAM/I/O/Network du conteneur.
- **MCP interne/externe** (`mcp-*.json`) : health p50/p95/p99, RPS, CPU%, RSS, métriques Python/process, ressources conteneur.

> **Datasource Prometheus** : vérifier UID/nom `Prometheus` dans les JSON et la datasource provisionnée.\
> **Autorisations** : compte admin initial `admin/admin` → **à changer immédiatement**.\
> **Accès** : http\://\<hôte>:3002/ (port mappé 3002→3000).

---

## 8) Procédures opérationnelles

### 8.1 Démarrage / arrêt / reload

```bash
# (Depuis le dossier du compose)
docker compose up -d
# Recharger Prometheus (sans restart)
curl -X POST http://localhost:9090/-/reload
# Arrêt (sans supprimer volumes)
docker compose down
```

### 8.2 Ajouter un nouveau service à monitorer

1. Exposer `/metrics` sur le conteneur (librairie client ou exporter dédié).
2. Ajouter un `job_name` dans `prometheus.yml` avec `targets: ["<service>:<port>"]`.
3. (Optionnel) Créer des panels Grafana et/ou règles d’alerte spécifiques.
4. `curl -X POST http://prometheus:9090/-/reload` (ou redeployer Prometheus).

### 8.3 Sauvegardes & rétention

- **Grafana** : volume `grafana-data` (dashboards, users, datasources).
- **Prometheus** : volume `prometheus-data` (TSDB, 15j). Export/backup périodique recommandé si obligations d’audit.

### 8.4 Mise à jour sécurisée

- Mettre à jour par tag **mineur** plutôt que `latest` en production.
- Valider sur un environnement de test (compatibilité dashboards/règles).
- Surveiller changelogs (Prometheus/Grafana/DCGM/cAdvisor).

---

## 9) Sécurité & conformité

- **Secrets** : webhook Teams, mots de passe Grafana → `.env`/secrets, jamais en clair dans GIT.
- **Réseaux** : `monitoring` isolé ; exposer UI (`9090`, `3002`, `9093`) via règles de firewall.
- **Comptes** : changer `GF_SECURITY_ADMIN_PASSWORD`; créer des **org/users** avec RBAC.

---

## 10) Indicateurs clés (KPI) proposés

- **Infra** : CPU, mémoire, disque, inodes par hôte ; disponibilité des targets.
- **Conteneurs** : CPU %, working set, redémarrages, OOM, réseau.
- **GPU** : utilisation %, VRAM, puissance, température, erreurs XID/ECC.
- **Apps** : latences p50/p95/p99, RPS, taux d’erreur, throughput spécifique (tokens/s vLLM, audio/mots STT, RPS Qdrant).
- **SLO** (exemples) : E2E p95 vLLM < *X*s ; erreurs 5xx < *Y*%; disponibilité service > *99.9%*.

---

## 11) Troubleshooting (FAQ rapide)

- **Alerte InstanceDown** : vérifier DNS/réseau du target, `docker inspect <service>`, logs de l’exporter.
- **Panels vides** : datasource Prometheus non configurée ou mauvais UID ; vérifier intervalle de temps et labels.
- **DCGM Exporter** : nécessite drivers NVIDIA + runtime ; vérifier `nvidia-smi` dans l’hôte et `--gpus`.
- **cAdvisor** : permissions de montages en RO, version compatible Docker (`v0.49.1` OK).
- **Teams non reçu** : vérifier `TEAMS_WEBHOOK_URL` (secret), logs bridge `prometheus-msteams`, et routing Alertmanager.

---

## 12) Annexes

- **Extraits utiles**

```yaml
# Retention Prometheus
--storage.tsdb.retention.time=15d

# Job vLLM (exemple)
- job_name: "vllm"
  metrics_path: /metrics
  static_configs:
    - targets: ["llm:8000"]
```

- **Fichiers source** : `docker-compose.yml`, `prometheus.yml`, `prometheus/rules/alerts.yml`, `alertmanager.yml`, `grafana/provisioning/provider.yml`, dashboards JSON (vLLM, STT, TTS, Qdrant, MCP).

