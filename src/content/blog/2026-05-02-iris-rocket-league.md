---
title: 'iris — replay-anchored, league-driven, counterfactual RL for breaking the GC ceiling in rocket league'
description: 'why every public rocket league agent plateaus at grand champion, and a four-pillar system design — replay anchor + ACCEL league + compositional reward stack + plasticity-stable architecture — that should reach SSL at 200M–1B environment steps'
pubDate: '2026-05-02'
category: 'research'
---

This is a system proposal, not a result. I've been training Rocket League bots in my spare time and reading the RL literature in my non-spare time for long enough that the same wall keeps showing up: every public agent stalls at Grand Champion. Necto. Nexto. The cancelled Tecko. Lucy-SKG. They learn ground play, basic aerials, reaction-time arbitrage; they almost never learn flip resets, double-taps, fakes, shadow defense, boost denial, strategic demos. The ability gap between GC and SSL is a wall and pure self-play does not climb it.

I think the wall is structural, three things stacked, and I think there's a coherent way to break through. This post is the design — full algorithm, predicted ablations, projected numbers, honest about what's speculative. The bot is called Iris. It's the planned successor to my current Apex v2 architecture, which I've benchmarked separately.

The thesis is one sentence: **a Rocket League agent that simultaneously breaks the GC ceiling and dramatically improves sample efficiency must combine a replay-anchored prior, a league with environment-design curriculum, a layered reward stack with policy-invariant potentials and event-level structure, and a plasticity-stable scaled architecture — and no subset of those four is sufficient.**

## the wall, diagnosed

Six years of community Rocket League RL have produced a frustrating plateau. The published numbers:

- **Necto** won the 2022 RLBot Championship.
- **Nexto** reached approximately the 99.88th percentile of 1v1 ranked play (~GC1) and ~0.46% in 3v3.
- **Tecko**, intended to scale Nexto's recipe, was *cancelled* because the larger network and extended training produced no measurable improvement. This is the empirical anchor for the "self-play ceiling" claim.
- **Lucy-SKG** (Moschopoulos et al., 2023) extracted a measurable 5× sample efficiency over Necto via the **Kinesthetic Reward Combination (KRC)** and auxiliary heads, but by the authors' own admission was never trained long enough to be deployed against humans.
- **Ripple, Element, Seer**, and several closed-source ranked-cheating bots — imitation-augmented and unverified — appear to push higher, but no peer-reviewed result yet exceeds Grand Champion in any team mode.

The wall is real. Here's why I think it's overdetermined by three failures, none addressed jointly by any published agent:

**Strategy-distribution closure.** Self-play improves only on the *transitive* component of skill (Balduzzi et al., 2019). Rocket League has substantial *cyclic* components — kickoff RPS, fake-vs-commit metagames, demolition-vs-rotation tradeoffs — that PPO + self-play traverses as limit cycles rather than convergent improvement (Mazumdar & Ratliff, 2018). A discovery never made remains forever invisible to the bot's own hypothesis class.

**Reward expressivity collapse.** Kinematic shaping is per-step and Markov; rotations, fakes, and boost starvation are non-Markov, opponent-relative, and event-driven. Lucy-SKG's KRC, while clever as a multiplicative penalty over kinematic primitives, cannot represent these structures. It's also non-potential-based — bias the optimal policy, invite reward hacking (Ng et al., 1999; Lidayan et al., 2024).

**Plasticity and capacity collapse.** Multi-billion-step PPO training under non-stationary self-play targets accumulates dormant neurons and growing parameter norms (Sokar et al., 2023; Lyle et al., 2023). Silently caps model capacity exactly when later-stage discoveries are most needed. This is why Tecko did not improve over Nexto with more compute and a bigger network.

There's a fourth, paradigmatic failure that's the easiest to fix: **pure self-play discards a free, abundant signal**. Over 148 million ranked human replays exist on ballchasing.com, including the entire RLCS competitive corpus. Every successful frontier agent in a complex strategy game has used a comparable signal. AlphaStar bootstrapped from 971K human replays and maintained a persistent KL anchor to it. OpenAI Five used 770 PFlops/s·days plus heavy hand-shaped rewards. VPT solved Minecraft diamond pickaxe by inverse-dynamics-labeling 70K hours of YouTube. Rocket League's published RL canon, Lucy-SKG included, ignores this signal entirely. Rolv-Arild's `replay-pretraining` pipeline (the basis for Ripple) is the only community precedent and it is unpublished.

## four insights

I think the algorithmic spine collapses to four insights, in order of ambition.

**1. The GC ceiling is the conjunction of strategy-distribution closure *and* reward expressivity collapse, not either alone.** AlphaStar's failure-mode analysis showed pure self-play has high short-term Elo but high exploitability against held-out opponents. Rocket League agents simultaneously fail at human exploits — slow rolls, ceiling stalls, drag-bumps — that have low probability under any equilibrium of the bot's strategy distribution, *and* at rotations and fakes that require non-Markov reward structure. Replay anchoring without a league still inherits self-play's late-stage cycling; a league without replay anchoring still cannot represent SSL strategy because nothing in the agent's hypothesis class produces it. **Both signals are required.**

**2. Lucy-SKG's KRC can be retrofitted into a policy-invariant potential without sacrificing the multiplicative-penalty intuition.** Define `Φ_KRC(s) = max_{t ≤ τ} KRC(s_t)` where τ indexes the current episode. This is bounded, monotone non-decreasing within an episode, and reset at boundaries. By Lidayan et al. (2024), `F_A = γ·Φ_KRC(s') − Φ_KRC(s)` is a **BAMPF**: bounded monotone potential, policy-invariant, provably immune to reward hacking. The agent retains the dense gradient signal of "satisfy all kinematic conditions simultaneously" without distorting the optimal policy.

**3. Strategic concepts that cannot be expressed kinematically can be expressed at the event timescale via reward machines, learned style discriminators, and counterfactual touch tracing.** Rotations are non-Markov but become Markov in the augmented state `(s, u)` where `u` is a reward-machine state tracking last-touch identity, ball-third, and rotation depth. Fakes are touch events whose counterfactual value — what would have happened had the touch *not* occurred — is high. SSL playstyle is a state-transition distribution discriminable from Diamond playstyle by a small classifier. None of these signals require the agent to "know" what a rotation is; they're computed from raw state and replay metadata, and their effect is to inject the missing structure into the reward.

**4. Sample-efficiency multipliers are largely orthogonal across architectural, algorithmic, and data axes.** SimBa scaling improves continuous-control RL by ~3–5× (Lee et al., 2024). Replay-anchored BC pretraining moves the policy from random to ~human-amateur initialization, eliminating the early-self-play random-walk phase, worth 3–10× by AlphaStar's analog. PPG with auxiliary phase improves PPO by ~2× on Procgen (Cobbe et al., 2021). BBF-style high replay ratio with shrink-and-perturb resets compounds another ~2–3×. Distributional twohog critic regression and SPR auxiliary loss each contribute 10–30%. Reward machines yield ~10× on temporally-extended structure tasks (Toro Icarte et al., 2022). The aggregate is plausibly 10–30× over Lucy-SKG with substantial diminishing returns and component overlap, since each piece addresses a distinct bottleneck. A model-based head (TD-MPC2-style implicit world model used for value targets only) could push toward the 50× stretch target.

## pillar I — replay-anchored policy prior

Inverse-dynamics-bootstrapped behavioral cloning, then maintained as a persistent decaying KL anchor during RL. Four stages.

**Stage 1: IDM training.** Train a non-causal Transformer `IDM_φ` over a ±20-frame window that predicts the discrete action (90-action lookup) at the central frame. Training data: RLGym/RocketSim rollouts of a Necto-tier policy with action-space noise and state randomization, yielding labeled `(s_{t-20:t+20}, a_t)` pairs. Auxiliary heads predict `has_jump`, `has_flip`, `on_ground` — quantities not present in raw replays but necessary for downstream policy. Where action equivalence holds (e.g., demoed cars), sample uniformly among equivalents.

**Stage 2: Replay corpus pseudo-labeling.** Pull SSL- and RLCS-tier replays from ballchasing.com via API, parse with `carball`, sample at 30 Hz, apply `IDM_φ`. Compute per-replay-segment **strategy statistics** `z ∈ R^16`: aerial-touch fraction, dribble-touch count, kickoff-route, demolition rate, possession depth, average boost level, mean rotation depth, opponent-conditional features. This `z`-conditioning is the AlphaStar mechanism for preserving strategic diversity through RL.

**Stage 3: Chunked BC pretraining.** Train a behavioral foundation model `π_BC` that predicts an action chunk `a_{t:t+K}` with `K=4` (~250ms at 30Hz, well under one human reaction time) conditioned on `(s_t, z)`. Use an ACT-style CVAE-Transformer head — diffusion is too expensive at 120Hz inference, and `K=4` is short enough that closed-loop reactivity is preserved when re-planning every step at deployment but only training on chunked targets. Loss is the standard CVAE ELBO plus action-prediction reconstruction, weighted to suppress KL collapse.

**Stage 4: Persistent KL anchor.** During RL fine-tuning, freeze `π_BC` as `π_anchor`. The PPO objective gains a KL term:

```
L_anchor(θ) = β(t) · E_{s ~ ρ_π}[ D_KL( π_θ(·|s,z) || π_anchor(·|s,z) ) ]
```

with `β(t)` on a LOGO-style schedule (Rengarajan et al., 2022): large early (`β_0 = 1.0`), decayed exponentially to a floor (`β_∞ = 0.01`) over the first 100M steps. Prevents late-stage drift collapse while permitting eventual divergence from sub-optimal human play. AlphaStar maintained β throughout; VPT used a fixed β; LOGO's adaptive trust region is the cleanest theoretical match.

## pillar II — strategy-conditioned league with regret curriculum

Small asymmetric league following AlphaStar's three-class structure but with regret-based environment design layered on top.

**Composition.** One **main agent** `π_MA`. Two **main exploiters** `π_ME_1, π_ME_2` (each periodically reset to `π_BC` initialization with a randomly sampled `z`). Two **league exploiters** `π_LE_1, π_LE_2` (PFSP over the entire league). Past snapshots of `π_MA` added to the league at fixed intervals.

**Prioritized Fictitious Self-Play.** Each agent samples opponents with probability

```
P(B | A) ∝ f(1 − p(A beats B)),    f(x) = x²
```

focusing compute on opponents the current agent struggles against. Main exploiters target only `π_MA`; their job is to surface counters `π_MA`'s self-play distribution misses. When ME reaches 70% win-rate, reset to a fresh BC copy with new `z`.

**Regret-based environment editor.** Concurrently, a **level editor** maintains a buffer of state initializations (kickoff positions, ball trajectories, boost configurations, opponent pre-states). Following ACCEL (Parker-Holder et al., 2022), levels are scored by **estimated regret**, approximated as the mean GAE-weighted L1 value loss of `π_MA` on rollouts from that level. High-regret levels are sampled with priority and *mutated* (small perturbations to ball/car positions and velocities) to compound complexity. Adds a "league of *situations*" complementing the "league of *opponents*" and provably maintains a minimax-regret robustness guarantee at Nash (Robust PLR; Jiang et al., 2021).

**Diversity bonus.** Following DvD (Parker-Holder et al., 2020), add a determinant-of-kernel-matrix diversity term over behavioral embeddings of the five league members. Behavioral embedding for a policy is the mean over 1000 evaluation rollouts of the state-action visitation histogram projected onto a learned 32-dim space (the SPR encoder). The determinant rewards population-volume coverage rather than pairwise distance, avoiding the collapse-to-clones failure mode of mean-field diversity bonuses.

## pillar III — compositional reward stack

Replace Lucy-SKG's flat reward sum with a four-layer stack, each layer addressing a distinct expressivity gap.

**Layer A: BAMPF-wrapped kinematic shaping.** Retain Lucy-SKG's kinematic primitives (ball-to-goal distance, ball-to-goal velocity, save-boost, distance-weighted alignment, offensive potential) and combine via KRC, but rather than adding KRC to the reward set:

```
Φ_A(s) = max_{t ≤ τ_episode} KRC(R_1(s_t), ..., R_n(s_t))
F_A = γ · Φ_A(s') − Φ_A(s)
```

This is a BAMPF: bounded, monotone non-decreasing within an episode, reset at boundaries. By Lidayan et al. (2024), `F_A` is policy-invariant and reward-hack-immune. The agent retains the dense per-step gradient that made KRC effective in Lucy-SKG, without distorting the optimal policy.

**Layer B: Reward machine over strategic events.** Define a labelling function `L : S × A × S → 2^P` over 14 propositions: `last_touch_self`, `last_touch_team`, `last_touch_opp`, `ball_def_third`, `ball_off_third`, `ball_mid_third`, `supersonic`, `low_boost (<25)`, `behind_ball`, `corner_pad_taken`, `aerial`, `demoed`, `teammate_committed`, `opponent_committed`. A reward machine `M` with 8 states encodes rotation discipline (e.g., transitioning to "rotating_back" after a teammate-touch in the offensive third yields +0.1; reaching "completed_rotation" yields +0.5; failing to rotate when teammate committed yields −0.5) and boost denial (taking a corner pad while opponent is low-boost and committed yields +0.3). Use **Counterfactual Reward Machines** (CRM) training: each environment step is replayed against all RM states, yielding `|U|` training examples per real step. This is the source of the 10× sample-efficiency multiplier on temporally-extended structure that no kinematic shaping can reach.

**Layer C: Adversarial Motion Prior style discriminator.** Train a small MLP discriminator `D_ψ : (s_t, s_{t+k}) → [0,1]` on `k=4` frame transitions, positive class drawn from SSL/RLCS replays, negative class drawn from current-policy rollouts. Following AMP (Peng et al., 2021), the style reward is

```
r_style(s_t, s_{t+k}) = max(0, 1 − 0.25 · (D_ψ − 1)²)
```

Crucially, `D_ψ` operates on **state transitions only**, not actions, so it does not depend on IDM accuracy — it is an independent imitation-style signal. Wrap `r_style` as a DPBA potential (Harutyunyan et al., 2015) so its optimal-policy effect is a known, bounded shift; combined with a five-discriminator ensemble lower confidence bound (Coste et al., 2023) to cap reward over-optimization, this gives the agent a dense "play like an SSL" signal grounded in real human data.

**Layer D: Counterfactual touch tracing.** At each ball-touch event, estimate the counterfactual value

```
c_τ = E[V(s_T) | touch at τ] − E[V(s_T) | no-touch at τ]
```

where the second term is computed by a 0.5s world-model rollout from the touch state with the agent's action replaced by a no-op (using a small Plan2Explore-style ensemble dynamics model). This is a COMA-style counterfactual at touch granularity. Added as a per-touch event reward and used directly in the policy gradient at touch timesteps, with a learned coefficient. Rewards strategically meaningful touches — *including fakes*, where the touch's counterfactual value accounting for opponent commitment is large — and penalizes overcommits regardless of kinematic cleanliness.

**Constrained outcome objective.** The terminal goal/concede signal is treated as an RCPO-style constraint (Tessler et al., 2019): the Lagrangian gradient ensures `E[#conceded] ≤ ε` per episode, dynamically adjusting the multiplier on goal-against penalties rather than relying on a hand-tuned weight. Enforces "do not concede" as a hard constraint above the soft optimization of "score."

The total reward signal entering PPO:

```
R(s, a, s') = R_outcome + F_A + R_M + r_style + c_τ · 1[touch]
```

plus the RCPO Lagrangian on `R_outcome`.

## pillar IV — scaled, plasticity-stable architecture

**Backbone.** Entity-attention input layer (cross-attention over tokens for own-car, ball, teammate-cars, opponent-cars, salient boost pads), variable team sizes via key-padding mask. Followed by 4 SimBa residual blocks (running observation normalization, pre-LN residual MLP, post-LN). Width 512 in actor, 1024 in critic. Per-token dimension 128, 4 attention heads. Backbone shared across team sizes (1v1/2v2/3v3) by design.

**Decoupled actor/critic with PPG.** Separate networks. Phasic Policy Gradient (Cobbe et al., 2021): policy phase runs 32 PPO iterations on actor with auxiliary value head; auxiliary phase runs 6 epochs distilling value features into actor under KL constraint. Critic is 2× wider than actor, trained more aggressively, with LayerNorm after every dense layer.

**Distributional twohog-symlog value heads.** Following DreamerV3 and BRO, the critic predicts a 255-bin twohog distribution over symlog-transformed returns. Two value heads: `V_short(s)` at γ=0.99 for shaped per-step returns, `V_long(s)` at γ=0.997 for outcome and event returns. GAE λ is 0.95 for short, 0.99 for long. The advantage entering the policy gradient is a learned state-conditional mixture `α(s) · A_short + (1−α(s)) · A_long`, where α is parameterized as a small head taking the same backbone features.

**Self-supervised auxiliary heads.** SPR-style multi-step latent self-prediction (Schwarzer et al., 2021) with `K=5` horizon and EMA target encoder (τ=0.99); reward prediction (retained from Lucy-SKG); inverse-dynamics auxiliary head for representation regularization. SPR adds approximately 30% sample efficiency on top of the model-free backbone in published benchmarks.

**Plasticity maintenance.** ReDo dormant-neuron resets (Sokar et al., 2023) every 25M steps on actor and critic. **Shrink-and-perturb** (Schwarzer et al., 2023, BBF) every 100M steps on the backbone: `θ ← 0.7·θ + 0.3·θ_init`. Eliminated plasticity collapse in BBF on Atari-100k and is the cleanest available recipe for billion-step training.

**Off-policy hybrid replay.** While the core trainer is PPO (high throughput, well-understood with self-play), maintain a 50/50 symmetric replay buffer (RLPD-style; Ball et al., 2023) mixing current rollouts with IDM-labeled SSL replay transitions. At each PPO update, a fraction (initially 0.5, decayed to 0.1) of the experience is drawn from the offline buffer with off-policy V-trace correction. Cheapest and most reliable path to reuse the replay corpus throughout training rather than only at initialization.

## algorithm sketch

```text
Input: replay corpus R_SSL, RLGym/RocketSim env, IDM/BC/RL budgets.

# ============== STAGE 0: PRETRAINING ==============
1. Train IDM_φ on RLGym rollouts with action noise.
   Targets: 90-action class + has_jump + has_flip + on_ground.
2. Pseudo-label R_SSL using IDM_φ at 30 Hz.
3. Compute strategy stats z per replay segment (16-dim).
4. Train π_BC (chunked CVAE-Transformer, K=4) on (s, z, a_{t:t+4}).
   Save as π_anchor (frozen).
5. Train AMP discriminator D_ψ on (s_t, s_{t+4}) from R_SSL vs random.

# ============== STAGE 1: LEAGUE INITIALIZATION ==============
6. Initialize π_MA, π_ME_{1,2}, π_LE_{1,2} from π_BC with diverse z.
7. Initialize level-editor buffer with kickoffs + uniform-random states.
8. Initialize replay buffer B_off with IDM-labeled R_SSL transitions.

# ============== STAGE 2: RL TRAINING ==============
9. for iter = 1..B_RL/N_step:
10.   for each agent A in {MA, ME_1, ME_2, LE_1, LE_2} in parallel:
11.     opponent <- PFSP_sample(A, league)
12.     level <- regret_weighted_sample(level_buffer)
13.     rollout T_A of N_step steps in (level, opponent).
14.     compute reward stack R = R_outcome + F_A + R_M + r_style + c_τ.
15.     update D_ψ on rollout transitions vs R_SSL transitions.
16.     compute GAE advantages with two-head V_short, V_long, mixed by α(s).
17.     B_off symmetric sample: 50% T_A, 50% IDM-labeled SSL.
18.     PPO clipped surrogate update on actor with:
            + KL anchor β(t) · KL(π_θ || π_anchor)
            + SPR multi-step latent self-prediction loss
            + reward-prediction aux loss
            + RCPO Lagrangian on outcome constraint
19.     PPO update on critic (twohog-symlog distributional, separate net).
20.     Every 32 iters: PPG auxiliary phase (distill V into actor).
21.     Every 25M steps: ReDo dormant-neuron reset.
22.     Every 100M steps: shrink-and-perturb backbone.
23.   Periodic league updates:
24.       Add MA snapshot every 50M steps.
25.       Reset MEs to π_BC every 200M steps or at >70% win-rate.
26.       Recompute PFSP win-rate matrix, DvD diversity bonus.
27.   Editor mutates top-quartile-regret levels, prunes solved levels.

# ============== STAGE 3: DEPLOYMENT ==============
28. Distill π_MA into a compact SimBa+attention student (~500K params).
29. Deploy student at 120 Hz in RLBot.
```

**Key hyperparameters.** Frame skip 8 (15 control Hz). γ_short = 0.99, γ_long = 0.997. GAE λ ∈ {0.95, 0.99}. PPO clip 0.2, 3 epochs, minibatch 50K, rollout 200K. Learning rate 3e-4 with cosine decay. Entropy 0.01. KL anchor β(t) exponential decay from 1.0 to 0.01 over 100M steps. Lagrangian step 1e-3. SPR EMA τ=0.99, horizon 5. Team spirit τ=0.3 (matching Lucy-SKG). 5 league agents × ~12 parallel env instances each. Total compute target: 1B environment steps for SSL-tier reach, ~3,000 GPU-hours on A100-class hardware (within community-reachable scale, an order of magnitude below AlphaStar).

## ablations and predicted results

All experiments use head-to-head 300-game matches plus Elo against a frozen ladder containing Necto, Nexto, Lucy-SKG, and Iris snapshots at multiple training milestones. Ablation suite:

- **A1 — Iris-flat.** PPO + SimBa + KRC (no BAMPF), no replay anchor, no league, no reward machine, no AMP, no counterfactual touch. *Architecture alone gets meaningful gains?*
- **A2 — Iris-replay.** A1 + IDM, BC, KL anchor. *Pure replay contribution.* Expected: large early-step jump, partial GC1 reach, plateau before SSL.
- **A3 — Iris-league.** A2 + league + ACCEL editor. *Ceiling-breaking from population alone, given a strong start.*
- **A4 — Iris-rewards.** A2 + reward stack. *Whether richer reward alone breaks the ceiling.*
- **A5 — Iris-full.** All four pillars. Hypothesized winner.
- **A6 — Iris-no-BAMPF.** A5 with raw KRC instead of BAMPF wrapping. Predicts mild reward-hacking of edge cases reducing effective Elo.
- **A7 — Iris-no-RM.** A5 without the reward machine. Predicts measurable rotation-completion-rate drop and 2v2/3v3 weakness, smaller effect on 1v1.
- **A8 — Iris-no-AMP.** A5 without the discriminator. Predicts reduced playstyle-similarity to SSL replays without large Elo loss.
- **A9 — Iris-no-counterfactual.** A5 without touch counterfactual. Predicts reduced fake-commit rate; small Elo effect.
- **A10 — Iris-flat-architecture.** A5 with vanilla MLP backbone. Predicts ~3× sample efficiency loss.

**Projected results at 200M, 500M, 1B environment steps:**

| agent | steps | 1v1 vs Nexto | 1v1 vs Lucy-SKG | est. MMR | notes |
|---|---|---|---|---|---|
| Lucy-SKG | 1B | ~80% (300:54 vs Necto) | — | mid GC1 | published; not human-eval |
| Nexto | ~5B | — | — | GC1 | ~99.88th percentile 1v1 |
| Seer (community) | ? | reportedly beats Nexto | ? | ~GC2-GC3 | unverified |
| Iris-flat (A1) | 200M | ~70% | ~50% | mid GC1 | architecture alone ≈ Lucy-SKG |
| Iris-replay (A2) | 100M | ~85% | ~70% | GC2 | replay anchor jumps initial skill |
| Iris-league (A3) | 500M | ~95% | ~90% | GC3 | league breaks self-play ceiling |
| Iris-rewards (A4) | 300M | ~90% | ~80% | low GC3 | reward stack helps but plateaus |
| **Iris-full (A5)** | 200M | >95% | >90% | GC3 | full system at Lucy-SKG-equivalent compute |
| **Iris-full (A5)** | 1B | >99% | >98% | SSL- to SSL | stretch target |

The headline claim: at 200M steps, Iris-full plays at GC3 — already exceeding any pure self-play bot on record at any step count — and at 1B steps reaches mid-SSL play in 1v1 and 2v2, with weaker but still SSL-tier play in 3v3. The 1B claim corresponds to roughly 10–20× sample efficiency over Lucy-SKG measured by time-to-equivalent-skill: Lucy-SKG reaches GC1-equivalent at ~1B steps; Iris-full reaches it at an estimated 50–100M thanks to the replay anchor alone, and continues climbing where Lucy-SKG plateaus.

The 50× stretch claim — reaching Lucy-SKG's GC1 level at 20M steps — is plausible only with a TD-MPC2-style implicit world model providing value targets during training. Phase 2 extension; not committed for the primary architecture.

## why these numbers are defensible (and where they're not)

**Why defensible:** replay anchoring eliminates the early-self-play random-walk phase that consumes the first ~100–200M steps of Lucy-SKG/Nexto training. This alone is a 5–10× speedup on the lower portion of the skill curve, validated by VPT (Minecraft) and AlphaStar (StarCraft II reaching 84th percentile *before any RL*). The league with ACCEL editor pushes the *ceiling* upward, addressing what Lucy-SKG could not — by AlphaStar's analog, league training added ~+1500 MMR over best-self-play in StarCraft II; the analog for Rocket League is the GC1→SSL gap of ~440 MMR. SimBa + SPR + plasticity resets contribute architectural multipliers attested in published benchmarks. Reward machines specifically address the rotation/fake/boost-denial gaps that no kinematic shaping has bridged.

**Why uncertain:** no published Rocket League agent has reached the regime where these methods compose; the 10–30× claim is necessarily extrapolative. Replay-corpus quality varies — RLCS replays are scarce relative to ranked SSL — and IDM accuracy on heavily-edited 30 Hz replay sampling is not perfectly characterized. AMP discriminators can introduce mode collapse if the SSL distribution is too narrow. Counterfactual touch tracing depends on a learned world model whose accuracy in adversarial settings is not yet established.

## limitations and failure modes

**F1: Anchor ceiling.** If the SSL replay corpus is dominated by mechanical play and low on RLCS-tier strategic depth, the BC anchor caps the policy below true SSL. Mitigation: stratified sampling weighting RLCS replays; LOGO-style decaying β allows divergence.

**F2: AMP mode collapse.** A discriminator over a narrow style distribution can collapse the policy to a small region of behavior space, killing diversity. Mitigation: 5-discriminator ensemble LCB and DvD population diversity bonus pulling against collapse.

**F3: World-model inaccuracy in counterfactual touch tracing.** If dynamics is poor, counterfactual values are noise. Mitigation: gate counterfactual updates by ensemble disagreement (only use the signal when models agree); fall back to a learned baseline when disagreement is high.

**F4: Reward-machine over-engineering.** A hand-designed RM may not capture the right strategic structure; bots may optimize labelled events rather than the underlying objective. Mitigation: BAMPF-wrap RM rewards as well, maintain RCPO outcome constraint as a hard upper guarantee.

**F5: League cycling rather than improvement.** PFSP outperforms FSP but cycling is still possible if MEs are too weak. Mitigation: explicit MEs reset to BC (adversarial diversity rooted in human play), DvD diversity bonus, periodic NashConv exploitability evaluation against held-out reference policies.

**F6: Plasticity resets disrupt high-skill late-stage learning.** Shrink-and-perturb on a near-SSL policy could collapse exactly the recent acquisitions. Mitigation: anneal reset magnitude over training; switch to plasticity injection (Nikishin et al., 2023) — adding fresh capacity rather than perturbing existing — for the final 200M steps.

**F7: Compute requirements still exceed many community resources.** 3,000 GPU-hours is roughly an order of magnitude more than Lucy-SKG's reported budget. Mitigation: each pillar can be ablated or omitted; even Iris-replay (A2) without league is a meaningful contribution at <100M steps.

**F8: Overfitting to RocketSim physics.** Subtle deviations from the real game could cause sim-to-real-style transfer issues. Mitigation: periodic in-game validation runs at lower throughput.

**F9: Ethical concern around ranked deployment.** Several extant high-skill bots are detected in ranked matches, harming the player ecosystem. I commit to releasing only the algorithm and ablations, not deployment-ready binaries, and recommend evaluations be conducted in private matches against consenting human evaluators.

**F10: The "kitchen-sink" critique.** Iris combines ten ideas; how do we know each pulls weight? The ablation suite (A1–A10) is designed precisely to answer this. I expect A6 (no BAMPF) and A9 (no counterfactual) to show smaller but measurable effects; the largest contributors should be A2 (replay) and A3 (league) for the *ceiling*, and A1 + SimBa pieces for *sample efficiency* on the lower curve.

A final intellectual-honesty note: nothing in this design *guarantees* SSL reach. AlphaStar's published Grandmaster result took 44 days on 3,072 TPU cores; the proposed budget here is ~50× smaller. The bet is that (a) Rocket League's state space is much smaller than StarCraft II's, (b) the replay corpus is denser per unit of compute, (c) RocketSim's throughput permits compute-efficient billion-step runs. If wrong by a factor of three, the claim falls back to "GC3-tier at 1B steps with playstyle resembling SSL," which would still be the strongest published Rocket League agent.

## the closing thought

Iris is a system, not a trick. Each of the four pillars addresses a documented bottleneck in prior Rocket League agents: replay anchoring breaks strategy-distribution closure; the league with regret curriculum prevents self-play cycling; the compositional reward stack gives policy-invariant dense gradient and event-level structure that kinematic shaping cannot reach; the scaled SimBa+SPR architecture with plasticity maintenance enables billion-step training without capacity collapse. The contribution is the integration: a coherent framework where each piece's strength compensates for another's weakness, grounded throughout in published RL theory and empirical results from adjacent domains (Atari-100k, DMControl, StarCraft II, Dota, Minecraft, robotics).

The harder question is not whether Iris can reach SSL — I project it can with high but not certain probability — but whether the underlying lesson generalizes. I argue it does: any environment with a strong human strategy distribution, non-Markov strategic structure, and a transitive-plus-cyclic skill geometry is bottlenecked by the same triad. Replay anchoring, structured-event rewards, league-with-environment-design curricula are not domain-specific. They are the standard recipe of every published frontier agent, retrofitted with 2024–2025 advances in scaling, plasticity, and policy-invariant shaping. Lucy-SKG's contribution was to show that careful reward composition could deliver 5× sample efficiency over the prior state of the art. Iris's contribution is to show that the next 10–30× lies not in further reward engineering but in finally taking imitation, league dynamics, and policy-invariant structured rewards seriously — *together*.

The Rocket League community has accumulated rich evidence that self-play alone cannot break GC; the Tecko cancellation was the data point. The published RL literature has accumulated rich evidence that replay-anchored league training with structured rewards *does* break analogous ceilings in StarCraft, Dota, and Minecraft. There is no published reason to think Rocket League is the exception. The remaining question is execution. Build is in progress; first numbers in a few months.
