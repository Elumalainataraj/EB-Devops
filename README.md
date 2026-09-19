# EB-Devops — Enterprise Bot DevOps Take-Home

## How to run and verify

```bash
git clone <this-repo>
cd EB-Devops
chmod +x setup.sh
./setup.sh          # idempotent — creates kind cluster "demo", installs
                     # ingress-nginx, builds + loads the service image,
                     # and helm-installs the chart into namespace "demo"
```

Add `demo.local` to `/etc/hosts` (or curl with a Host header):

```bash
sudo sh -c 'echo "127.0.0.1 demo.local" >> /etc/hosts'
curl http://demo.local/
curl http://demo.local/healthz
```

Debug lab (Part 4):

```bash
cd lab
./scenario.sh up       # installs cluster-state/ + broken-chart/
./scenario.sh verify   # checks goal state
```

## Resource requests/limits — reasoning

Every workload requests 50m CPU / 64Mi memory and caps at 200m CPU / 128Mi
memory. These are small, stateless HTTP services doing no heavy compute, so
the request is set to "comfortably idle" and the limit gives headroom for
request bursts without letting one pod starve the node — sized against the
2-CPU kind node used for local development, not a production node pool.

## What I deliberately skipped, and the risk

- **No HorizontalPodAutoscaler.** Fixed replica counts are fine for a local
  demo; in production, traffic-driven autoscaling would be needed, and its
  absence risks either overprovisioning or getting overwhelmed under load.
- **No NetworkPolicy.** All pods can talk to all pods in-namespace right
  now; the risk is lateral movement if one service is compromised.
- **No image vulnerability scanning in the build path.** Risk: a CVE in a
  base image ships unnoticed.
- **Reporter's intermittent readiness failure (see `lab/FINDINGS.md`) is
  documented but unresolved** — I ran out of time to root-cause it without
  the application's source.

## What I'd change for production-readiness

- Push images to a real registry (ECR/GCR/Harbor) instead of `kind load`.
- Add a HorizontalPodAutoscaler and PodDisruptionBudgets.
- Add NetworkPolicies scoping which services can reach which.
- Externalize secrets via a proper secrets manager instead of plain
  ConfigMaps/env vars.
- Add liveness probes with sane failure thresholds tuned from real traffic,
  not just readiness.
- CI pipeline to build, scan, and push images, plus `helm lint`/`helm
  template` as a pre-merge check.

## How I used AI

I used Claude throughout this assignment — for planning the repo structure,
writing the initial Dockerfile/Helm chart/setup.sh, and as a debugging
partner while working through Part 3 (kind cluster networking issues on a
resource-constrained machine, and later Codespaces network flakiness
pulling images from registry.k8s.io/Docker Hub) and Part 4 (interpreting
kubectl/helm error output and forming hypotheses about each bug's root
cause). I wrote/ran every command myself and verified every result against
my own cluster before accepting it — nothing here is unverified AI output.
I corrected the AI's assumptions at several points, e.g. when it suggested
a `runAsUser` value I had to confirm independently via `docker inspect`
against the actual image, and when an early fix to `kind-config.yaml`
needed adjusting for my specific network/DNS environment.
