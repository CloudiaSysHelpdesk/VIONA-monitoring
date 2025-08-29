# Monitoring Stack avec Prometheus, Grafana et Exporters

Ce projet fournit une stack de monitoring complète basée sur **Docker
Compose**, incluant :

-   **Prometheus** : collecte des métriques\
-   **Node Exporter** : métriques système (CPU, RAM, disque, réseau)\
-   **DCGM Exporter** : métriques GPU NVIDIA\
-   **cAdvisor** : métriques des conteneurs Docker\
-   **Grafana** : visualisation et dashboards\
-   **Alertmanager** : gestion des alertes Prometheus\
-   **Prometheus Teams Bridge** : envoi d'alertes vers Microsoft Teams

------------------------------------------------------------------------

## 🚀 Prérequis

-   Docker & Docker Compose installés\
-   Un réseau Docker externe `ai-net` existant :

``` bash
docker network create ai-net
```

-   (Optionnel) Un webhook Microsoft Teams pour recevoir les alertes.

------------------------------------------------------------------------

## 📂 Structure du projet

    .
    ├── docker-compose.yml
    ├── prometheus/
    │   ├── conf/prometheus.yml
    │   └── rules/...
    ├── grafana/
    │   └── provisioning/...
    └── alertmanager/
        └── alertmanager.yml

------------------------------------------------------------------------

## ▶️ Lancer la stack

``` bash
docker-compose up -d
```

Vérifie que tous les conteneurs tournent :

``` bash
docker ps
```

------------------------------------------------------------------------

## 🔗 Accès aux services

  -----------------------------------------------------------------------
  Service                         Port local         Description
  ------------------------------- ------------------ --------------------
  Prometheus                      `9090`             Interface Prometheus

  Node Exporter                   `9100`             Métriques système

  DCGM Exporter                   `9400`             Métriques GPU NVIDIA

  cAdvisor                        `8080`             Monitoring des
                                                     conteneurs

  Grafana                         `3002`             Dashboards
                                                     (user/pass:
                                                     `admin/admin`)

  Alertmanager                    `9093`             Interface
                                                     Alertmanager

  Teams Bridge                    `-`                Forward des alertes
                                                     vers Teams
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## ⚙️ Configuration

### Prometheus

-   Fichier de configuration : `./prometheus/conf/prometheus.yml`\
-   Règles d'alerte : `./prometheus/rules/`

### Grafana

-   Données persistées dans `grafana-data`\
-   Dashboards et datasources configurés dans `./grafana/provisioning`

### Alertmanager

-   Config : `./alertmanager/alertmanager.yml`\
-   Supporte les routes et les receveurs (Teams, email, etc.)

### Microsoft Teams Bridge

-   Variable d'environnement :

``` yaml
TEAMS_WEBHOOK_URL: "https://ton.webhook.office.com/..."
```

⚠️ Remplace l'URL par ton vrai webhook Teams.

------------------------------------------------------------------------

## 🛑 Arrêter la stack

``` bash
docker-compose down
```

Si tu veux tout supprimer (y compris les volumes persistés) :

``` bash
docker-compose down -v
```

------------------------------------------------------------------------

## 📊 Exemple de dashboards Grafana

-   Node Exporter Full\
-   cAdvisor Container Monitoring\
-   NVIDIA DCGM Metrics

------------------------------------------------------------------------

## 📌 TODO

-   Ajouter des dashboards Grafana personnalisés\
-   Sécuriser Grafana avec un vrai mot de passe\
-   Ajouter des receivers supplémentaires dans Alertmanager
