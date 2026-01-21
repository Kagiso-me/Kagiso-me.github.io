# Living Homelab — Project Plan (PLAN.md)

This document is the **single source of truth** for the Living Homelab site.

If an idea, page, or feature does not align with this plan, we **stop** and revisit intentionally.
No ad-hoc changes. No silent scope creep.

---

## 0. Project Intent (Non-Negotiable)

This site is **not**:
- A generic homelab blog
- A documentation dump
- A tool showcase
- A framework experiment

This site **is**:
- A journey-first entry point into homelabbing
- A human story of building and operating systems
- A living record of real decisions, failures, and trade-offs
- A front door — not the engine room

**Principle:**  
The site must help visitors choose *how* to engage, not overwhelm them with everything at once.

---

## 1. Core Architectural Decisions

- **Theme:** Forty (HTML5 UP)
- **Approach:** Static HTML + CSS + minimal JS
- **Hosting:** GitHub Pages
- **Build Philosophy:** Boring, reliable, explicit

We deliberately avoid:
- CMS platforms
- Docs engines
- Opinionated frameworks
- Heavy client-side JavaScript

Reason:
- Maximum control over UX
- Minimal tooling friction
- Longevity and maintainability

---

## 2. Full Site Structure (Authoritative)

```bash
/
├── index.html # Homepage (journey selector)
│
├── journeys/
│ ├── index.html # “Choose your path” explainer
│ ├── beginner/
│ │ ├── index.html # Beginner Journey overview
│ │ ├── foundations.html
│ │ ├── first-server.html
│ │ ├── first-services.html
│ │ └── next-steps.html
│ │
│ └── operator/
│ ├── index.html # Operator Journey overview
│ ├── security.html
│ ├── observability.html
│ ├── automation.html
│ └── operations.html
│
├── my-homelab/
│ ├── index.html # Current state overview
│ ├── architecture.html # Diagrams & design decisions
│ ├── services.html # What runs where
│ ├── removed.html # What was removed and why
│ └── roadmap.html # What’s next
│
├── thinking-out-loud/
│ ├── index.html # Curated essays
│ ├── ditching-google.html
│ ├── security-is-boring.html
│ ├── kubernetes-is-overkill.html
│ └── lessons-learned.html
│
├── operators/
│ ├── index.html # Cross-journey operator guides
│ ├── backups.html
│ ├── monitoring.html
│ └── incident-response.html
│
└── community/
├── index.html # Curated community labs
└── featured-setups.html
```

### Explicit decisions
- ❌ No `/about` section
- Personal context is communicated through:
  - Journeys
  - Essays
  - Homelab decisions

---

## 3. Homepage Design (Tiles + Intent)

### Homepage Job

Help the visitor **choose a journey immediately**.

The homepage does **not**:
- Teach
- Document
- List everything

---

### Hero Copy

**Living Homelab**  
*Build. Secure. Own your infrastructure.*

Subtext:
> A real homelab, built in public — from first server to operating discipline.

---

### Primary Tiles (Above the Fold)

#### Beginner Journey
- **Tagline:** Start from zero, without the chaos.
- **Audience:** Newcomers, overwhelmed learners
- **Intent:** Calm, structured guidance
- **CTA:** → Start the Beginner Journey
- **URL:** `/journeys/beginner/`

#### Operator Journey
- **Tagline:** Run your homelab like production.
- **Audience:** Intermediate homelabbers
- **Intent:** Responsibility, discipline, reliability
- **CTA:** → Enter Operator Mode
- **URL:** `/journeys/operator/`

---

### Secondary Tiles (Below the Fold)

#### My Homelab
- **Tagline:** What I run, why I run it, and what I’ve removed.
- **Intent:** Transparency and credibility
- **URL:** `/my-homelab/`

#### Thinking Out Loud
- **Tagline:** Essays, failures, and pivots.
- **Intent:** Human voice and reflection
- **URL:** `/thinking-out-loud/`

---

## 4. Journey Definitions (Do Not Blur)

### Beginner Journey

**Audience**
- New to homelabbing
- Intimidated by tools
- Wants understanding, not copy-paste

**Promise**
> By the end of this journey, you will have a working homelab *and* understand what you built.

**Scope**
- Orientation and mindset
- Networking, storage, virtualization basics
- First server and services
- Stability and safe experimentation

**Explicitly excluded**
- Advanced security
- GitOps
- Complex Kubernetes clusters

---

### Operator Journey

**Audience**
- Already running services
- Has broken things before
- Cares about uptime, security, and control

**Promise**
> Operate your homelab deliberately, not reactively.

**Scope**
- Security and threat modeling
- Observability and metrics
- Automation and reproducibility
- Operational discipline

**Explicitly excluded**
- Beginner explanations
- Hardware basics
- Tool definitions

---

## 5. Writing Rules (Non-Negotiable)

Every guide, essay, or page **must end with**:

1. **How this shows up in my lab**
2. **Related guides**
3. **What I actually do**

If a piece of content cannot satisfy this, it does not belong on the site.

---

## 6. Homelab Transparency Principles

- Show what is running **now**
- Show what was removed and **why**
- Show trade-offs, not perfection
- Avoid aspirational diagrams without real backing

---

## 7. Future-Facing Guardrails

- Forty remains the **front-facing shell**
- Dashboards are **embedded**, not rebuilt
- Automation supports the story — it is not the story
- No new sections without mapping them to:
  - Journey relevance
  - Homepage intent

---

## 8. Authority of This Document

This file is the **authority**.

If a future idea:
- Conflicts with this plan → stop
- Requires bending structure → revisit intentionally
- Adds complexity without clarity → reject

**Rule:**  
We evolve deliberately, not opportunistically.
