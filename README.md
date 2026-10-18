# Scalable Node.js Web App on Docker Swarm

A Node.js web tier, an API tier and a PostgreSQL database deployed as a Docker Swarm stack with overlay networks, a Docker secret, a persistent volume, rolling updates with automatic rollback, and a demo script that proves each behaviour.

Docker Hub: `kaj1/swarm-app:1.0.0` and `:1.1.0`

## 1. Problem Statement

A startup wants to launch a Node.js application in a highly available, scalable way on multiple nodes with service discovery and load balancing. The task is to:

- write a Dockerfile for the Node.js application,
- set up Swarm with at least three services (web, API, database),
- deploy with Docker Compose and in Swarm mode,
- connect the services over overlay networks,
- implement rolling updates and scaling,
- demonstrate load balancing across several instances.

## 2. Important Note: Single-Node Swarm

Swarm runs on **one node** (one EC2 instance), so node failure and multi-node scheduling were **not** tested here. Everything else (routing mesh, scaling, rolling updates, rollback, self-healing, secrets, overlay networks) runs as in a larger cluster. See section 9 for the node-failure answer and the SkillfyBank repository (3 managers + 2 workers) for a node-failure test.

## 3. Architecture

    client --> :8080 (routing mesh) --> web x3 --> api x2 --> db x1
                                        [frontend network]  [backend network: internal, encrypted]

| Service | Replicas | Networks | Notes |
|---|---|---|---|
| web | 3 | frontend | published on 8080, calls `http://api:4000` |
| api | 2 | frontend, backend | reads the DB password from a Docker secret, increments a counter in PostgreSQL |
| db | 1 | backend | PostgreSQL 16, named volume `dbdata`, password from the secret |

Web and API use one image (`kaj1/swarm-app`) with different commands. The backend network is `internal` (no route outside) and encrypted, so the web tier can never reach the database.

## 4. Repository Layout

    web.js, api.js, package.json   application code (Node.js, one dependency: pg)
    Dockerfile                     one image for both tiers, non-root
    docker-compose.yml             Compose version for local use
    docker-stack.yml               Swarm version (replicas, networks, secret, update policy)
    scripts/demo.sh                load balancing, scaling, rolling update, rollback, self-healing, DB restart
    evidence/                      swarm-demo.log, stack-services.txt, stack-ps.txt, networks.txt

## 5. Steps to Build and Run

    # Build and publish both versions
    docker build --build-arg APP_VERSION=1.0.0 -t kaj1/swarm-app:1.0.0 .
    docker build --build-arg APP_VERSION=1.1.0 -t kaj1/swarm-app:1.1.0 .
    docker login -u kaj1 && docker push kaj1/swarm-app:1.0.0 && docker push kaj1/swarm-app:1.1.0

    # The DB password is generated locally and kept out of Git (secrets/ is git-ignored)
    mkdir -p secrets && openssl rand -base64 18 | tr -d '/+=\n' > secrets/db_password.txt

    # Option A: Docker Compose (local run, web on :8088)
    docker compose up -d && curl localhost:8088/ && docker compose down -v

    # Option B: Docker Swarm
    docker swarm init --advertise-addr <host-ip>
    docker secret create db_password secrets/db_password.txt
    docker stack deploy -c docker-stack.yml swarm
    docker stack services swarm
    curl localhost:8080/

    # Run all demonstrations
    ./scripts/demo.sh && cat evidence/swarm-demo.log

    # Remove
    docker stack rm swarm && docker secret rm db_password

`docker-stack.yml` pins version `1.0.0`. After an update by command, change the tag in the file too, because re-running `docker stack deploy` applies the file and moves the service back to the pinned tag.

## 6. Results

From `evidence/swarm-demo.log`:

| Test | Result |
|---|---|
| Load balancing | 30 requests over 3 web replicas: 10 / 10 / 10 |
| Scaling | 3 to 6 replicas; 60 requests: 10 per replica; scaled back to 3 |
| Rolling update 1.0.0 to 1.1.0 (`start-first`, one task at a time) | 278 requests during the update: **278 HTTP 200**, 115 answered by 1.0.0 and 163 by 1.1.0, no errors |
| Update to a tag that does not exist | Update state `rollback_completed`, image still 1.1.0, 3/3 replicas |
| Self-healing | A killed web container was replaced by a new task within seconds, 3/3 again |
| Database container killed | Counter was 370 before and 371 after the restart, so the data survived on the volume |

The 278 requests came from a probe sending one request about every 0.2 seconds from the same machine. This shows no failures for that traffic. It does not claim zero downtime under heavy load.

## 7. Optimization Techniques Used

- **One small image** (`node:20-alpine`, production dependencies only, non-root user) for both tiers.
- **Rolling updates with `start-first`:** a new task is started and checked before the old one stops, which is why no requests failed.
- **`failure_action: rollback`** plus `monitor: 15s`, so a bad release reverts without manual action.
- **Health checks** on every service, so the routing mesh only sends traffic to healthy tasks.
- **Docker secret** for the database password, mounted as a file, never in the image, environment or Git.
- **Overlay networks:** the backend network is internal and encrypted, so only the API reaches the database.
- **Resource limits and reservations** on every service.
- **Restart policies** (`on-failure`) for self-healing.
- **Database pool error handler**, so a dropped connection does not crash the API process.

## 8. Challenges Faced and Solutions

| Challenge | Solution |
|---|---|
| Swarm needs several nodes to show node failure, but only one instance was available. | Reported the limitation openly, demonstrated the container-level failures (web kill, DB kill, bad update), and pointed to the SkillfyBank multi-node test. |
| Testing rollback requires a failing update. | Updated to an image tag that does not exist. Swarm created `Rejected` tasks, then rolled back on its own. |
| Re-deploying the stack file after a manual update moved the service back to 1.0.0. | Documented that the stack file is the source of truth and the tag there must be changed after an update. |
| The API needs the database to be up, but Swarm starts services in parallel. | The API creates its table lazily on the first request and returns a clear error instead of crashing while the database starts. |

## 9. Deep Dive: Node Failures and High Availability in Swarm Mode

This was **not tested in this repository** (single node), so the answer comes from how Swarm is documented to work.

- **Worker failure:** managers notice that the node stopped sending heartbeats and mark it `down`. Tasks that were running on it are rescheduled to healthy nodes until the replica count returns to what the service asks for.
- **Manager failure:** managers keep cluster state in a Raft log and need a majority (quorum) to accept changes. With 3 managers one can fail, with 5 two can. If the leader fails, the others elect a new one. If quorum is lost, running containers continue but nothing can be changed until it returns.
- **Traffic:** the routing mesh accepts connections on any node and forwards them to healthy tasks, so clients are not affected by which node fails.
- **Data:** a local volume lives on one node. Stateful services need a placement constraint (used here for the database) or a shared volume driver. Otherwise a rescheduled database starts without its data.
- **Practical rule:** run an odd number of managers (3 or 5), spread across failure zones.
