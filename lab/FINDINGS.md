# Findings — Part 4 debug lab

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1

**Symptom:**
`helm upgrade --install` fails immediately with
`Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"`

**Cause:**
`templates/migrate-job.yaml` had `restartPolicy: Always`, which Kubernetes Jobs do not accept — a Job's pod must reach a terminal state, so only `OnFailure` or `Never` are valid.

**Fix:**
Changed `restartPolicy: Always` to `restartPolicy: OnFailure` so the Job retries (up to `backoffLimit`) on failure and does not run forever.

**How I found it:**
The Helm install error message named the exact field and valid values directly.

---

## Defect 2

**Symptom:**
`metrics` pod stuck in `Pending`. `kubectl describe pod -n debug-lab -l app=metrics` showed:
`0/1 nodes are available: 1 Insufficient cpu`

**Cause:**
`values.yaml` requested `cpu: "2"` (2 full CPUs) for the metrics container, with a `limits.cpu: "4"` cap. The kind node only has 2 CPUs total, and ~1400m was already allocated to the other Deployments — no node could satisfy a 2000m request.

**Fix:**
Lowered metrics requests/limits to `cpu: "100m"` / `cpu: "200m"`, in line with the other services (backend/worker/reporter all request 50-200m). A metrics sidecar has no reason to need a full CPU core.

**How I found it:**
`kubectl get pods -n debug-lab` showed metrics stuck at Pending while everything else was at least scheduled. `kubectl describe pod` gave the exact scheduler message (Insufficient cpu), then `kubectl describe node` confirmed the node was already at 70% CPU allocation, and `values.yaml` showed the oversized request.

---

## Defect 3

**Symptom:**
All 5 Deployment pods stuck in `CreateContainerConfigError`. Events showed:
`Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root`

**Cause:**
Every container's `securityContext` set `runAsNonRoot: true` but did not set `runAsUser`. The image's Dockerfile sets `USER nonroot` (a named user, not a numeric UID). Kubernetes cannot verify a named user is non-root at the API level, so it requires an explicit numeric `runAsUser`.

**Fix:**
Added `runAsUser: 65532` (the standard distroless/nonroot convention, confirmed via `docker inspect --format='{{.Config.User}}'`) to the securityContext block in backend, gateway, worker, reporter, metrics, and the migrate Job templates.

**How I found it:**
`kubectl describe pod` on an affected pod showed the exact error in Events. Cross-checked the image's declared user with `docker inspect`, which confirmed it was a name (`nonroot`) rather than a UID.

---

## Defect 4

**Symptom:**
`worker` pod in `CrashLoopBackOff`. `kubectl logs --previous` showed:
`FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system`

**Cause:**
`securityContext.readOnlyRootFilesystem: true` is set (correctly, as a security hardening measure) but the worker process needs a writable directory at `/var/cache/app`, and no volume was mounted there.

**Fix:**
Added an `emptyDir` volume named `cache` in the pod spec and a matching `volumeMounts` entry (`mountPath: /var/cache/app`) in the worker container, giving it a writable scratch directory without weakening the read-only root filesystem.

**How I found it:**
The crash loop's `--previous` logs stated the exact path and reason directly.

---

## Defect 5

**Symptom:**
All pods `Running` but `0/1 Ready`. Events showed repeated:
`Readiness probe failed: Get "http://<pod-ip>:8080/healthz": dial tcp ...: connect: connection refused`

**Cause:**
`values.yaml` set `common.port: 8080`, which drives the container's `containerPort`, the Service, and the readiness/liveness probes. The application's actual listening port is `8081` (its documented image default), confirmed in the pod's own startup log line: `listening on :8081 (image default is 8081; set PORT to override)`. Nothing in the chart set `PORT`, so the app used its default of 8081 while everything else assumed 8080.

**Fix:**
Changed `common.port` from `8080` to `8081` in values.yaml so the container port, Service, and probes all align with the port the application actually listens on.

**How I found it:**
`kubectl logs` on a Running-but-not-Ready pod showed the app's own startup line stating which port it actually bound. Comparing that to `common.port` in values.yaml showed the mismatch.

---

## Defect 6

**Symptom:**
`gateway` stuck at `0/1 Ready` even after the port fix. Logs showed:
`readiness failed: backend not reachable: GET http://backend.default.svc:8080/healthz: context deadline exceeded`

**Cause:**
`values.yaml` hardcoded `BACKEND_URL: "http://backend.default.svc:8080"`. The backend Service actually lives in the `debug-lab` namespace (or whatever namespace the release is installed into), not `default` — so the DNS name never resolved to a real endpoint, and the request timed out rather than failing fast.

**Fix:**
Changed `BACKEND_URL` to `http://backend:8081` — a short, namespace-relative Service name that resolves correctly regardless of which namespace the chart is installed into, using the corrected port from Defect 5.

**How I found it:**
The gateway's own log line printed the exact URL it was trying to reach, immediately showing the wrong namespace segment (`default` instead of the real one).

---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.

## Defect 7

**Symptom:**
`reporter` stuck at `0/1 Ready`. Logs showed:
`pod list failed: kubernetes API returned HTTP 403: ... "system:serviceaccount:debug-lab:reporter" cannot list resource "pods"`

**Cause:**
`rbac.yaml` correctly defines a `reporter` ServiceAccount and a Role granting `get`/`list` on pods, but the `RoleBinding`'s `subjects` referenced the `default` ServiceAccount instead of `reporter`. The Deployment pod actually runs as the `reporter` ServiceAccount, so the permission granted by the Role never applied to it.

**Fix:**
Changed the RoleBinding's `subjects[0].name` from `default` to `reporter`, matching the ServiceAccount the reporter Deployment actually uses.

**How I found it:**
The 403 error message named the exact ServiceAccount making the request (`reporter`), which I cross-checked against `rbac.yaml` and found the RoleBinding was wired to a different (unused) ServiceAccount.

---

## Remaining: reporter — "unexpected end of JSON input" on /report

`reporter`'s readiness probe consistently fails with
`{"error":"parse pod list: unexpected end of JSON input","status":"unhealthy"}`
(confirmed directly via `kubectl port-forward` + `curl`, not just the probe —
same result both times, so this is not one-off flakiness).

Ruled out:
- RBAC: fixed (Defect 7), confirmed no more 403s in logs.
- Resources: 128Mi/200m limit, Restart Count 0, no OOMKilled — not a memory issue.
- The API server itself: `kubectl get --raw /api/v1/namespaces/debug-lab/pods`
  from outside the pod returns a complete, valid ~42KB JSON body.

Not yet ruled out: the reporter binary appears to have its own HTTP client
call to the API server that is returning a body cut short mid-stream. Without
the application's source (only the built image is provided), I could not
pin down whether this is a short client-side read/response timeout, a fixed
read buffer size, or something else in how it consumes the response body.

What I'd try next: run the same binary against a differently-sized pod list
(e.g. in a namespace with 1-2 pods vs one with dozens) to see if the failure
is size-dependent, which would point to a buffer limit rather than a timeout;
also check if `APP_MODE=reporter` has any documented timeout-related env var
by testing common conventions (e.g. `REQUEST_TIMEOUT`, `HTTP_TIMEOUT`) since
none were documented in values.yaml.

Update: tested the size-dependent-buffer hypothesis directly by scaling
backend/gateway/metrics/worker to 0 replicas (leaving 0-1 pods in the
namespace) and re-querying `/report` — same exact error. This rules out a
response-size buffer limit; the failure is not correlated with payload size,
which points more toward a fixed client-side timeout or a TLS/connection
issue between the reporter binary and the API server that would need the
application's source to diagnose further.
