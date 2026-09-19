# Part 5 — Migrating 40 Ingress objects to Gateway API with no downtime

**Approach and order:**

1. **Install the Gateway API CRDs and a Gateway controller** (e.g. the same
   nginx project's Gateway Fabric, or Envoy Gateway/Istio) alongside the
   existing ingress-nginx — run both controllers side by side, never a
   big-bang cutover.
2. **Stand up one `GatewayClass` + `Gateway`** matching current listener
   config (ports, TLS certs) but do not point any traffic at it yet.
3. **Migrate Ingress objects in small batches**, starting with the
   lowest-risk / lowest-traffic services first. For each: convert the
   Ingress to an `HTTPRoute` attached to the new Gateway, deploy it
   alongside the still-live Ingress rule, and verify with direct requests
   (curl with Host header, or a canary DNS/weighted split) before cutting
   real traffic over.
4. **Cut traffic per-service** by updating DNS/LoadBalancer routing (or, if
   sharing one LB IP, by adjusting weighting) once each `HTTPRoute` is
   verified — not all 40 at once.
5. Only after every service is confirmed healthy on the new Gateway,
   **decommission ingress-nginx**.

**What's likely to break:**
- Custom `nginx.ingress.kubernetes.io/*` annotations (rewrites, rate
  limiting, auth-snippets) have no 1:1 Gateway API equivalent — these need
  manual translation and the most testing.
- TLS cert reuse/ordering, and any Ingress relying on nginx-specific
  merge/priority behavior across multiple rules for the same host.
