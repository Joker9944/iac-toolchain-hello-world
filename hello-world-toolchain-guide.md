# From Zero to GitOps: Go + Flutter on AKS with Pulumi, kpt, and FluxCD

## Why this guide exists, and what you're actually learning

Before writing a single line of code, it's worth being honest about what this
project is *for*. You already know how to write a backend and a frontend.
What you don't yet have hands-on feel for is how **three infrastructure
tools that look like they overlap actually divide the work** in a real
GitOps setup. That's the entire point of this exercise — the app itself is
deliberately trivial so the toolchain is the thing you're forced to pay
attention to.

Here's the division of labor we're building toward, stated up front so you
have a map before you start walking:

| Tool | Layer | Question it answers |
|---|---|---|
| **Pulumi** | Cloud infrastructure | "Does an AKS cluster, a container registry, and a resource group exist in Azure?" |
| **kpt** | Configuration packaging | "What do the Kubernetes YAML manifests for my app actually look like, and how do I template/render them without Helm or hand-edited Kustomize overlays?" |
| **FluxCD** | Continuous delivery | "Given a Git repo containing those manifests, how does the cluster stay in sync with it, forever, without anyone running `kubectl apply` by hand?" |

Three different jobs. People conflate them because all three *touch*
Kubernetes YAML at some point, but only one of them (kpt) is actually about
the YAML itself. Pulumi never looks at your app's manifests — it only cares
about the cluster existing. FluxCD never provisions a cluster — it assumes
one already exists and reconciles config onto it. kpt doesn't deploy
anything by itself in this guide — it renders config that something else
(FluxCD) applies.

If you finish this guide and that table feels obvious rather than
surprising, it worked.

### The path we'll walk

1. Write a minimal Go HTTP backend that returns a JSON greeting.
2. Write a minimal Flutter web frontend that calls it and shows the result.
3. Containerize both.
4. Use **Pulumi** (TypeScript) to provision an Azure Resource Group, an
   Azure Container Registry (ACR), and an AKS cluster, wiring ACR pull
   access into AKS.
5. Push your two container images to ACR.
6. Author your Kubernetes manifests as a **kpt package**, using a kpt
   function to inject the image tag — this is the "Configuration as Data"
   idea in practice, not just in theory.
7. Push the rendered manifests to a Git repo.
8. Bootstrap **FluxCD** on the AKS cluster, pointing it at that Git repo, and
   watch it reconcile your app onto the cluster with zero `kubectl apply`
   commands from you.
9. Make a change, push it, and watch the whole loop close by itself.

This is a long guide. Don't binge it in one sitting — it's structured so you
can stop after any numbered section with a working, inspectable artifact.

### Prerequisites

You'll need, at minimum:
- An Azure subscription (a free trial tier works; AKS itself is free, you
  only pay for the underlying VMs)
- `az` CLI, authenticated (`az login`)
- Go ≥ 1.22
- Flutter SDK (stable channel) with web support enabled
- Docker (or `podman`, adjusted accordingly) for building images
- Node.js + `npm` (Pulumi's TypeScript runtime needs this even though
  you're not writing a Node app)
- The `pulumi`, `kpt`, `flux`, and `kubectl` CLIs
- A GitHub account and a personal access token with repo scope (FluxCD will
  use this to bootstrap)

Given your NixOS background, you'll probably want a `flake.nix` with a
dev shell pulling all of this in rather than installing things globally —
I'll leave that as an exercise, since you know that pattern better than most
guides do, but I'll flag in each section which binary is needed so you can
build the shell incrementally.

---

## Part 1 — The Go backend

### Why Go, and why this design

The backend's only job is to return a JSON payload. We're deliberately
*not* reaching for a framework (no Gin, no Echo, no Fiber) — the standard
library's `net/http` is genuinely sufficient for one route, and using it
means there's nothing to explain except Go itself. If this were a real
service with twenty routes, middleware chains, and validation, a framework
would earn its place. It hasn't earned that here.

### Project layout

Create a directory for the whole project — everything in this guide will
live under one parent folder so the Pulumi program, the kpt package, and
the two app folders all sit next to each other in a way that maps cleanly
onto a single Git repo later.

```
hello-toolchain/
├── backend/        # Go API
├── frontend/        # Flutter web app
├── infra/          # Pulumi program
└── deploy/         # kpt package (Kubernetes manifests)
```

Start with the backend:

```bash
mkdir -p hello-toolchain/backend
cd hello-toolchain/backend
go mod init github.com/<your-username>/hello-toolchain-backend
```

### The handler

Create `main.go`:

```go
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

// greeting is the shape of the JSON response. Keeping it as a named
// struct rather than an inline map costs nothing and means the contract
// between backend and frontend is something you can grep for.
type greeting struct {
	Message string `json:"message"`
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	// CORS: the Flutter web app and this API will be served from
	// different origins (different Services/Ingress hosts) once deployed,
	// so the browser will block the request unless we explicitly allow it.
	// In a real production system you'd scope this to a known origin
	// rather than "*" — we're being loose here because the point of the
	// exercise is the deployment pipeline, not API security hardening.
	w.Header().Set("Access-Control-Allow-Origin", "*")

	resp := greeting{Message: "Hello, World, from Go!"}
	if err := json.NewEncoder(w).Encode(resp); err != nil {
		log.Printf("failed to encode response: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	// Kubernetes will poll this. It costs almost nothing to add now and
	// saves you a confusing CrashLoopBackOff investigation later when
	// your Deployment has no liveness/readiness probe to point at.
	w.WriteHeader(http.StatusOK)
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/hello", helloHandler)
	mux.HandleFunc("/healthz", healthHandler)

	log.Printf("listening on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}
```

A few choices worth narrating, since this is a tutorial and not just a code
drop:

- **Reading `PORT` from the environment** rather than hardcoding it is a
  Kubernetes/cloud-native convention (it lines up with the "12-factor app"
  idea), and it means the same binary behaves correctly whether you run it
  bare on your laptop or inside a container where the platform might inject
  a different port.
- **`/healthz` as a separate, trivial handler** exists purely so that later,
  when we write the Kubernetes Deployment manifest, `livenessProbe` and
  `readinessProbe` have something real to hit instead of overloading
  `/api/hello` for a purpose it wasn't designed for.

Test it locally:

```bash
go run main.go
# in another terminal:
curl localhost:8080/api/hello
```

You should see `{"message":"Hello, World, from Go!"}`.

### Containerizing the Go service

Create `Dockerfile` in `backend/`:

```dockerfile
# --- build stage ---
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/server .

# --- runtime stage ---
FROM scratch
COPY --from=build /out/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
```

Why `scratch` and not `alpine` for the final image: Go produces a fully
static binary when `CGO_ENABLED=0`, so there's no libc, no shell, no package
manager required at runtime — the final image is just your binary and
nothing else. This is one of the genuine, oft-repeated Go selling points
playing out concretely: a multi-hundred-MB Python or Node image becomes a
single-digit-MB Go image. It also has a real security benefit: there's no
shell in the container for an attacker to drop into even if they find a
remote-code-execution bug.

Build and smoke-test it:

```bash
docker build -t hello-backend:dev .
docker run --rm -p 8080:8080 hello-backend:dev
curl localhost:8080/api/hello
```

Don't push anywhere yet — we don't have a registry until Pulumi creates one
in Part 4.

---

## Part 2 — The Flutter frontend

### Why this is a slightly unusual use of Flutter, and why it still teaches you something real

Flutter's main pitch, as discussed earlier, is "one codebase, native apps on
every platform." Using it for a single static web page that calls one API
is a bit like buying a touring motorcycle to ride to the corner shop — it's
overkill for the destination, but you'll learn the controls. Specifically,
you'll learn what Flutter *produces* when targeting web (a folder of static
assets — HTML, JS, and a Wasm/CanvasKit renderer payload), which is exactly
what you need to know in order to containerize and deploy it. That artifact
shape, not the UI itself, is what matters for this guide.

### Scaffolding the app

```bash
cd hello-toolchain
flutter create frontend --platforms=web
cd frontend
```

`--platforms=web` keeps Flutter from also generating Android/iOS/desktop
scaffolding you don't need for this exercise — less to look at, same
lesson.

### The UI

Replace `lib/main.dart` with:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const HelloApp());

class HelloApp extends StatelessWidget {
  const HelloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hello Toolchain',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HelloPage(),
    );
  }
}

class HelloPage extends StatefulWidget {
  const HelloPage({super.key});

  @override
  State<HelloPage> createState() => _HelloPageState();
}

class _HelloPageState extends State<HelloPage> {
  String _message = 'Press the button to call the Go backend.';
  bool _loading = false;

  Future<void> _callBackend() async {
    setState(() => _loading = true);

    // This URL is the one piece of config that changes between "running
    // on my laptop" and "running in the cluster." We're reading it from
    // a compile-time define (see the build command below) rather than
    // hardcoding it, so the same source tree produces a correctly
    // configured build for either environment.
    const apiBase = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://localhost:8080',
    );

    try {
      final res = await http.get(Uri.parse('$apiBase/api/hello'));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      setState(() => _message = body['message'] as String);
    } catch (e) {
      setState(() => _message = 'Request failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hello Toolchain')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_message, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            _loading
                ? const CircularProgressIndicator()
                : FilledButton(
                    onPressed: _callBackend,
                    child: const Text('Call the Go backend'),
                  ),
          ],
        ),
      ),
    );
  }
}
```

Add the `http` package:

```bash
flutter pub add http
```

### A note on that `String.fromEnvironment` trick

This is worth dwelling on because it's the kind of thing that's obvious
once you've seen it and baffling the first time you hit it. Flutter web
builds are **static** — there's no server-side templating step where you
inject an environment variable at runtime the way you might with a Node
backend reading `process.env`. Once `flutter build web` has run, the output
is plain HTML/JS/Wasm sitting in a folder; nothing evaluates Dart code on
the server ever again.

So "configuring" a Flutter web build for a specific environment has to
happen **at build time**, via `--dart-define`:

```bash
flutter build web --dart-define=API_BASE_URL=https://api.example.com
```

This means, concretely, that you'll need a *different build* per
environment (or you bake in a runtime config-fetch step, which is more
machinery than this guide needs). For our purposes: one build for local
testing against `localhost:8080`, and one build baked with the real
in-cluster URL once we know what that URL will be.

Test it locally (with the Go backend from Part 1 still running):

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080
```

Click the button. You should see the Go backend's message appear.

### Containerizing the Flutter web build

Unlike the Go binary, the Flutter web output is just static files — so the
"runtime" for this container is a tiny web server, not a Dart VM. Nginx is
the standard, boring choice, and boring is correct here.

Create `Dockerfile` in `frontend/`:

```dockerfile
# --- build stage ---
FROM ghcr.io/cirruslabs/flutter:stable AS build
WORKDIR /app
COPY . .
RUN flutter pub get
# The API base URL is fixed in at image-build time, per the explanation
# above. We'll override this with --build-arg once we know the real
# in-cluster service URL.
ARG API_BASE_URL=http://localhost:8080
RUN flutter build web --dart-define=API_BASE_URL=${API_BASE_URL}

# --- runtime stage ---
FROM nginx:1.27-alpine
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 80
```

Build it (we'll set the real `API_BASE_URL` later, once we know the
backend's cluster-internal address — for now, a placeholder is fine just to
confirm the build mechanics work):

```bash
docker build -t hello-frontend:dev --build-arg API_BASE_URL=http://localhost:8080 .
docker run --rm -p 8081:80 hello-frontend:dev
```

Visit `localhost:8081` — you should see the Flutter app served by nginx
(though the button will fail to reach the backend unless it's also
running, since this container's `localhost` is its own, not your host's).

---

## Part 3 — Pausing to look at what we have and what's missing

At this point you have two Dockerfiles that build correctly on your laptop.
Nothing about them is Kubernetes-specific yet — they'd work identically if
you deployed them to a single VM with `docker run`, to AWS ECS, to a
Raspberry Pi. That's intentional, and it's a useful checkpoint: everything
from here on is about *where these containers run and how they get there*,
not about the containers themselves.

What's missing, in order:

1. Somewhere for the images to live that AKS can pull from (a registry) —
   **Pulumi** builds this.
2. Something for the images to run on (the AKS cluster itself) — **Pulumi**
   builds this too.
3. A description of *how* the containers should run once they're on that
   cluster — Deployments, Services, an Ingress — authored as a **kpt**
   package.
4. A mechanism that takes that description and continuously makes the
   cluster match it — **FluxCD**.

Notice that Pulumi's job ends the moment the cluster and registry exist.
Pulumi in this guide never touches your app's Deployment YAML. That
separation is deliberate and mirrors how most real platform teams split
responsibilities: one layer owns "does the cluster exist and is it healthy"
(infra team, Pulumi/Terraform), another owns "what's running on it"
(app teams or a platform layer, GitOps tooling).

---

## Part 4 — Provisioning Azure with Pulumi

### Why TypeScript, and why the Azure Native provider specifically

Pulumi supports several languages; we'll use TypeScript because it's the
most commonly documented choice for Azure examples and because its npm-based
tooling is the lightest to set up. Within Pulumi's Azure ecosystem there are
two provider families: the older **classic `@pulumi/azure`** provider
(a hand-written wrapper, slower to get new Azure features) and
**`@pulumi/azure-native`** (code-generated directly from Azure's own API
specs, which means it tracks new Azure features almost immediately and
covers the full Azure REST surface). Use `azure-native` — there's no good
reason to reach for the classic provider on a new project today.

### Setting up the Pulumi project

```bash
cd hello-toolchain
mkdir infra && cd infra
pulumi new azure-typescript
```

This is interactive: it'll ask for a project name, a stack name (think of a
"stack" as an environment — `dev`, `staging`, `prod` would each be their
own stack sharing the same code), and your preferred Azure region. Answer
honestly; for a learning exercise, region just needs to be something close
to you with AKS quota available (`westeurope` or `northeurope` are safe
defaults if you're unsure).

Pulumi will scaffold `Pulumi.yaml`, `Pulumi.<stack>.yaml`, `index.ts`,
`package.json`, and `tsconfig.json`. Open `index.ts` — this is where the
entire infrastructure description lives.

### What we're about to build, and why each piece exists

Before pasting code, walk through the dependency chain we need, because
each resource exists to satisfy a constraint of the one after it:

1. A **Resource Group** — Azure's container concept; everything else lives
   inside one.
2. An **Azure Container Registry (ACR)** — where our two Docker images will
   live. AKS needs to be able to pull from it.
3. An **AKS Managed Cluster** — the thing that actually runs our pods.
4. A **role assignment** granting the AKS cluster's identity `AcrPull`
   rights on the registry — without this, AKS can see the registry exists
   but gets `ImagePullBackOff` trying to actually pull from it. This step
   is the one people most often forget and then spend an hour debugging.

### The Pulumi program

Replace the contents of `index.ts`:

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as resources from "@pulumi/azure-native/resources";
import * as containerregistry from "@pulumi/azure-native/containerregistry";
import * as containerservice from "@pulumi/azure-native/containerservice";
import * as authorization from "@pulumi/azure-native/authorization";

const config = new pulumi.Config();
const location = config.get("location") || "westeurope";
const nodeCount = config.getNumber("nodeCount") || 2;
const nodeSize = config.get("nodeSize") || "Standard_B2s";
const k8sVersion = config.get("k8sVersion") || "1.30";

// 1. Everything lives in one resource group, so tearing this whole
//    exercise down later is a single `pulumi destroy`, which deletes
//    this group and everything inside it.
const resourceGroup = new resources.ResourceGroup("hello-toolchain-rg", {
  location,
});

// 2. The registry. Images get pushed here in Part 5.
const registry = new containerregistry.Registry("helloToolchainAcr", {
  resourceGroupName: resourceGroup.name,
  location,
  sku: { name: "Basic" },
  adminUserEnabled: false, // we'll use managed identity, not static creds
});

// 3. The AKS cluster itself. A few choices worth narrating below the
//    code block.
const cluster = new containerservice.ManagedCluster("helloToolchainAks", {
  resourceGroupName: resourceGroup.name,
  location,
  dnsPrefix: "hello-toolchain",
  kubernetesVersion: k8sVersion,
  identity: {
    type: containerservice.ResourceIdentityType.SystemAssigned,
  },
  agentPoolProfiles: [
    {
      name: "agentpool",
      count: nodeCount,
      vmSize: nodeSize,
      mode: containerservice.AgentPoolMode.System,
      osType: containerservice.OSType.Linux,
      type: containerservice.AgentPoolType.VirtualMachineScaleSets,
    },
  ],
});

// 4. Grant the cluster's managed identity permission to pull from ACR.
//    The "kubelet identity" is the one each node actually uses to pull
//    images — not the cluster's control-plane identity — which is the
//    detail that trips people up if they assign the role to the wrong
//    principal.
const kubeletIdentityObjectId = cluster.identityProfile.apply(
  (profile) => profile?.["kubeletidentity"]?.objectId ?? "",
);

new authorization.RoleAssignment("aksAcrPull", {
  principalId: kubeletIdentityObjectId,
  principalType: authorization.PrincipalType.ServicePrincipal,
  // This GUID is Azure's built-in "AcrPull" role definition ID — it's the
  // same across all Azure tenants, not specific to your subscription.
  roleDefinitionId: pulumi.interpolate`/subscriptions/${authorization
    .getClientConfigOutput()
    .subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/7f951dda-4ed3-4680-a7ca-43fe172d538d`,
  scope: registry.id,
});

// Outputs: things we (and later, our deployment scripts) need to reference.
export const resourceGroupName = resourceGroup.name;
export const registryLoginServer = registry.loginServer;
export const clusterName = cluster.name;
export const kubeconfig = pulumi
  .all([resourceGroup.name, cluster.name])
  .apply(([rg, name]) =>
    containerservice.listManagedClusterUserCredentialsOutput({
      resourceGroupName: rg,
      resourceName: name,
    }),
  )
  .apply((creds) =>
    Buffer.from(creds.kubeconfigs![0].value!, "base64").toString(),
  );
```

A few things worth slowing down on:

- **`adminUserEnabled: false` on the registry.** ACR offers a simple
  username/password admin account, but using it would mean a static,
  long-lived secret sitting in your config. Using AKS's managed identity
  with an `AcrPull` role assignment instead means there's no credential to
  leak — Azure handles the token exchange invisibly, which is the same
  underlying idea as cloud-native "workload identity" patterns generally.
- **Why we read `cluster.identityProfile` for the kubelet identity rather
  than just using the cluster's own `identity`** — this is the detail
  mentioned above. AKS actually provisions *two* identities: a
  control-plane identity (manages the cluster resource itself) and a
  kubelet identity (what each node uses to pull images and talk to other
  Azure resources). Assigning `AcrPull` to the wrong one is the single most
  common reason people see "the role assignment says it worked but pods
  still can't pull images."
- **`pulumi.interpolate` and `.apply`** show up because Pulumi resources
  are asynchronous by nature — `registry.id` isn't a string, it's a
  `pulumi.Output<string>` that resolves once Azure actually creates the
  resource. `.apply()` is how you transform an Output once you have it;
  `pulumi.interpolate` is template-string sugar for the common case of
  embedding Outputs into a larger string. If this feels unfamiliar, it's
  the same shape as a `Promise.then()` — Pulumi just needs to track these
  dependencies explicitly so it can build the right dependency graph and
  know what to create before what.

### Configuring and deploying

```bash
pulumi config set location westeurope
pulumi config set nodeCount 2
pulumi up
```

`pulumi up` shows you a **preview** — a diff of what will be created —
before doing anything, and asks for confirmation. This is the same
instinct as `nix build --dry-run` or `terraform plan`: never apply
something you haven't seen the diff for. Confirm, and wait — AKS cluster
creation typically takes five to ten minutes.

Once it completes, fetch your kubeconfig and point `kubectl` at the new
cluster:

```bash
pulumi stack output kubeconfig --show-secrets > kubeconfig.yaml
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

You should see your nodes listed as `Ready`. This is the first real
checkpoint: a live, empty AKS cluster, provisioned entirely from code you
can `git diff`.

---

## Part 5 — Pushing images to ACR

Now that the registry exists, log in and push:

```bash
cd hello-toolchain
az acr login --name $(pulumi -C infra stack output registryLoginServer --show-secrets | cut -d. -f1)
```

(Or, more simply, grab the login server string directly:)

```bash
ACR_SERVER=$(pulumi -C infra stack output registryLoginServer)
az acr login --name "${ACR_SERVER%%.*}"
```

Tag and push the backend:

```bash
cd backend
docker build -t $ACR_SERVER/hello-backend:v1 .
docker push $ACR_SERVER/hello-backend:v1
```

For the frontend, we now finally know the backend's real address — but
notice we *don't* yet know its cluster-internal DNS name, because we
haven't written the Kubernetes Service that will give it one. This is a
slightly awkward chicken-and-egg moment worth naming honestly: in a real
setup you'd either (a) decide the Service name in advance since you're the
one naming it, or (b) put the frontend behind the same Ingress host and use
a relative path so it never needs to know the backend's internal address at
all. We'll do (a) — we're about to name the backend Service
`hello-backend` in the kpt package, so we can commit to that now:

```bash
cd ../frontend
docker build -t $ACR_SERVER/hello-frontend:v1 \
  --build-arg API_BASE_URL=http://hello-backend.default.svc.cluster.local:8080 .
docker push $ACR_SERVER/hello-frontend:v1
```

That `*.svc.cluster.local` address is Kubernetes' internal DNS convention
(`<service>.<namespace>.svc.cluster.local`) — it only resolves *inside* the
cluster, which is fine for service-to-service calls but means it's useless
for a browser, since the browser runs on the user's laptop, not inside the
cluster. We're using it here only because the frontend's container build
needs *some* value baked in; we'll revisit this exact tension in Part 6
when we add the Ingress, because it's the same issue restated — a browser
calling the API needs a publicly routable hostname, not a cluster-internal
one. Hold that thought; we'll resolve it shortly.

---

## Part 6 — Packaging the Kubernetes manifests with kpt

### What problem kpt is actually solving here

You could write four flat YAML files (two Deployments, two Services, one
Ingress) and call it done. That would work, today, for this exercise. The
reason to reach for kpt instead — and the reason this section exists at
all — is to feel the **Configuration as Data** idea in your hands: your
image tags, replica counts, and other genuinely variable knobs live as
*data* in a `Kptfile`/`setters`-style structure, not hand-edited inline
inside YAML you'd otherwise `sed` or template with Helm. kpt functions then
read and transform that data without you ever opening the YAML files
directly.

This matters most exactly at the seam you just hit in Part 5: an image tag
that changes on every release. With kpt, bumping that tag is a single
command, run against structured data, rather than a grep-and-replace
across YAML files that might also have other `v1` strings you didn't mean
to touch.

### Initializing the package

```bash
cd ../deploy
kpt pkg init . --description "hello-toolchain k8s manifests"
```

This creates a `Kptfile` — the package's own manifest, describing what the
package is and (later) which upstream packages it depends on, if any. Ours
has no upstream dependency; we're authoring from scratch.

### The manifests

Create `backend-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-backend
  labels:
    app: hello-backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-backend
  template:
    metadata:
      labels:
        app: hello-backend
    spec:
      containers:
        - name: hello-backend
          # kpt-set: ${backend-image}
          image: REPLACE_ME/hello-backend:v1
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 3
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

That `# kpt-set: ${backend-image}` comment is not decorative — it's how
kpt's `apply-setters` function knows which field to rewrite when you set a
value for `backend-image`. We'll wire up the setter definition itself in a
moment.

Create `backend-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-backend
spec:
  selector:
    app: hello-backend
  ports:
    - port: 8080
      targetPort: 8080
```

This is the Service whose DNS name (`hello-backend.default.svc.cluster.local`)
we already baked into the frontend's build in Part 5 — naming it `default`
namespace, `hello-backend` is what makes that earlier value correct. If you
deploy into a different namespace, you'd need to rebuild the frontend image
with the matching address — another small, concrete illustration of why
"just bake the URL into the image" is a real but imperfect approach; it
creates a coupling between build-time and deploy-time decisions that a more
mature setup would solve with a runtime config-fetch or an environment
variable read by nginx at container start. Worth knowing as a limitation,
not worth solving in this guide.

Create `frontend-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-frontend
  labels:
    app: hello-frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-frontend
  template:
    metadata:
      labels:
        app: hello-frontend
    spec:
      containers:
        - name: hello-frontend
          # kpt-set: ${frontend-image}
          image: REPLACE_ME/hello-frontend:v1
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

Create `frontend-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-frontend
spec:
  selector:
    app: hello-frontend
  ports:
    - port: 80
      targetPort: 80
```

Create `ingress.yaml`. This needs an ingress controller installed on the
cluster (AKS doesn't ship one by default) — we'll use the standard
`ingress-nginx`, installed once, manually, outside of FluxCD's purview,
since "what ingress controller exists" is closer to a cluster-infrastructure
concern than an application-deployment one (another small instance of the
same layering question this whole guide is about):

```bash
kubectl create namespace ingress-nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/cloud/deploy.yaml
kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

Wait for `EXTERNAL-IP` to populate with a real address (AKS provisions an
Azure Load Balancer for this — it can take a couple of minutes), then use
that IP (or a DNS name you point at it) in:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-toolchain
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: hello-backend
                port:
                  number: 8080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-frontend
                port:
                  number: 80
```

This routes `/api/*` to the Go backend and everything else to the Flutter
frontend, on a single host — which, note, is exactly the "relative path"
escape hatch mentioned in Part 5's chicken-and-egg discussion. If you'd
gone this route from the start, the frontend could call `/api/hello`
(relative, no hostname at all) and you'd never have needed to bake any
backend address into the frontend image in the first place. We did it the
more roundabout way deliberately, so you'd feel *why* the simpler way
exists, rather than being handed it as an unexplained best practice.

### The setters file — where the "data" in Configuration as Data lives

Add a `Kptfile` pipeline entry so `apply-setters` is part of this package's
declared function pipeline. Edit the generated `Kptfile`, adding a
`pipeline` section:

```yaml
apiVersion: kpt.dev/v1
kind: Kptfile
metadata:
  name: hello-toolchain-deploy
info:
  description: hello-toolchain k8s manifests
pipeline:
  mutators:
    - image: gcr.io/kpt-fn/apply-setters:v0.2
      configMap:
        backend-image: REPLACE_ME/hello-backend:v1
        frontend-image: REPLACE_ME/hello-frontend:v1
```

Now, rendering the package — substituting the real values into every
`# kpt-set:`-annotated field — is one command:

```bash
ACR_SERVER=$(pulumi -C ../infra stack output registryLoginServer)
kpt fn eval . --image gcr.io/kpt-fn/apply-setters:v0.2 -- \
  backend-image="$ACR_SERVER/hello-backend:v1" \
  frontend-image="$ACR_SERVER/hello-frontend:v1"
```

Or, since we already declared the pipeline in the `Kptfile`, simply:

```bash
kpt fn render
```

(`kpt fn render` runs *all* the functions declared in the pipeline, in
order — useful once a package has more than one transformation step.
`kpt fn eval` runs a single function ad hoc, which is what we used above to
pass values explicitly without first editing the `Kptfile`'s `configMap`
inline.)

Diff the rendered output against git to *see* the substitution happen:

```bash
git diff backend-deployment.yaml
```

You should see `REPLACE_ME/hello-backend:v1` replaced by your actual ACR
login server. This — a structured, auditable, scriptable substitution
instead of a `sed` one-liner — is the entire value proposition of kpt in
miniature. It scales the same way whether you have two Deployments or two
hundred.

Commit the rendered manifests; they're what FluxCD will read.

---

## Part 7 — Continuous delivery with FluxCD

### What FluxCD adds that you don't already have

At this exact moment, you could run `kubectl apply -f deploy/` and your app
would be running on AKS. That's a legitimate way to deploy Kubernetes
manifests, and it's worth being honest that nothing about kpt or Pulumi
*required* you to add FluxCD on top. What FluxCD buys you is **continuous
reconciliation**: instead of a one-time `apply`, you get a controller
living inside the cluster that watches a Git repository on an interval and
keeps the cluster's actual state matching whatever's committed — forever,
without you running another command. If someone `kubectl edit`s a
Deployment directly, Flux reverts it on the next reconciliation, because
Git, not the live cluster, is the source of truth. That property — drift
correction — is the entire pitch of GitOps, and it's not something a bare
`kubectl apply` gives you.

### Pushing the manifests to a real Git repository

FluxCD bootstraps against an actual Git repo, so create one now (GitHub,
for this guide):

```bash
cd hello-toolchain
git init
git add .
git commit -m "Initial commit: backend, frontend, infra, deploy"
gh repo create hello-toolchain --private --source=. --push
# or, without the gh CLI, create the repo on github.com and:
# git remote add origin https://github.com/<you>/hello-toolchain.git
# git push -u origin main
```

### Bootstrapping Flux onto the AKS cluster

Export a GitHub token with repo scope, then bootstrap:

```bash
export GITHUB_TOKEN=<your-pat>
export GITHUB_USER=<your-username>

flux check --pre   # verifies your cluster meets Flux's prerequisites

flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=hello-toolchain \
  --branch=main \
  --path=./deploy \
  --personal
```

Walk through what this single command actually does, because it's doing
more than it looks like:

1. Installs Flux's controllers (`source-controller`, `kustomize-controller`,
   and others) into a `flux-system` namespace on your AKS cluster.
2. Generates two manifests — `gotk-components.yaml` (the controllers
   themselves) and `gotk-sync.yaml` (a `GitRepository` resource pointing at
   your repo, plus a `Kustomization` resource telling Flux to reconcile the
   `./deploy` path) — and **commits them back into your repository** under
   `deploy/flux-system/`.
3. Applies those manifests to the cluster.
4. From this point on, Flux is **self-managing**: it's watching the very
   path that contains its own installation manifests, so upgrading Flux
   later is also just a Git commit, not a separate operational procedure.

The `--path=./deploy` flag is the connective tissue between kpt and Flux in
this whole guide: it's telling Flux to reconcile *exactly* the directory
that `kpt fn render` populated with concrete, substituted YAML. kpt never
talks to the cluster; Flux never templates YAML. Each tool does one job,
and the directory path is the handoff between them.

Confirm it worked:

```bash
flux get sources git
flux get kustomizations
kubectl get pods -n flux-system
```

Within a minute or two (the default reconciliation interval), check your
actual application:

```bash
kubectl get pods
kubectl get deployments
kubectl get ingress hello-toolchain
```

Grab the Ingress's external IP and open it in a browser. You should see
the Flutter app, and clicking the button should successfully call through
to the Go backend — the entire chain, end to end, with no manual
`kubectl apply` anywhere in this section.

### Closing the loop: making a change and watching it propagate

This is the moment that makes the whole toolchain *click* rather than just
"having worked." Change the Go backend's message:

```go
resp := greeting{Message: "Hello, World, from Go — now via GitOps!"}
```

Then walk the full pipeline by hand, once, so you feel each step:

```bash
cd backend
docker build -t $ACR_SERVER/hello-backend:v2 .
docker push $ACR_SERVER/hello-backend:v2

cd ../deploy
kpt fn eval . --image gcr.io/kpt-fn/apply-setters:v0.2 -- \
  backend-image="$ACR_SERVER/hello-backend:v2" \
  frontend-image="$ACR_SERVER/hello-frontend:v1"

git add .
git commit -m "Bump backend to v2"
git push
```

Now do nothing. Watch:

```bash
flux get kustomizations --watch
```

Within the reconciliation interval, Flux will detect the new commit, apply
the updated Deployment, and the new image tag will roll out — entirely
because you pushed to `main`, not because you ran a deploy command. If you
want to force it immediately rather than waiting:

```bash
flux reconcile kustomization flux-system --with-source
```

That's the loop. Notice what each tool did, one final time, now that
you've felt it rather than just read about it:

- **Pulumi** was completely silent and uninvolved in this whole sequence —
  the cluster already existed, so there was nothing for it to do. That's
  correct; it would only re-enter the picture if you needed a third node
  pool or a second cluster.
- **kpt** did one specific, mechanical thing: rewrote a tag in a YAML file,
  based on structured input, leaving everything else untouched.
- **FluxCD** did the part that actually felt like "deployment" — and you
  never ran `kubectl apply` once.

---

## Tearing everything down

Cloud resources cost money even when idle (AKS nodes are billed VMs).
When you're done experimenting:

```bash
cd infra
pulumi destroy
```

This removes the resource group and everything inside it — the cluster,
the registry, all of it — in the correct dependency order, the same way
`pulumi up` created them in the correct order. You don't need to manually
delete the Ingress's Load Balancer, the ACR images, or anything else
first; they all live inside the resource group Pulumi is deleting.

---

## What you should take away from this, beyond "it worked"

If someone asks you in an interview to explain the difference between
Pulumi, kpt, and FluxCD, the honest, well-formed answer — the one this
whole exercise was designed to let you give from direct experience rather
than from having read a comparison table — is something like:

*"Pulumi provisions the cloud resources underneath Kubernetes — the
cluster, the registry, the networking. kpt is a way of authoring and
transforming the Kubernetes manifests themselves as structured data,
rather than templating strings or hand-patching YAML. FluxCD takes
whatever's committed to Git and continuously makes the live cluster match
it, correcting drift automatically. None of the three substitute for each
other — Pulumi never looks at your app manifests, kpt never touches a live
cluster, and Flux never provisions infrastructure."*

That sentence is worth more in an interview than being able to recite any
individual tool's CLI flags — and you now have a working repository that
proves you've actually exercised the boundary between all three, not just
read about it.
