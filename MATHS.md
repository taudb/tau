# Maths Behind Tau

## Time Domain

A **TimeDomain** is a closed interval on the integers:

$$D = [t_{\text{start}},\; t_{\text{end}}] \subset \mathbb{Z}$$

Timestamps are nanoseconds since epoch (`i64`). The domain is the bounding box of an entity's existence — data outside it is undefined.

## Series as Partial Functions

A `Series(T)` is a **partial function** from timestamps to values:

$$S_T : \mathbb{Z} \rightharpoonup T$$

Written formally:

$$S_T(\tau) = \begin{cases} v_i & \text{if } \exists\, i \text{ s.t. } t_i = \tau \\ \bot & \text{otherwise} \end{cases}$$

where $(t_i, v_i)$ are the stored time-value pairs. The codomain includes $\bot$ (null) — a lookup at an unstored timestamp returns nothing. There is no interpolation.

This makes `Series` a discrete, irregularly-sampled signal. Contrast with continuous signals or regularly-sampled arrays: here, only explicit observations exist.

## Lens as Function Composition

A `Lens(In, Out)` applies a pure transformation $f: \text{In} \to \text{Out}$ over a Series:

$$L_{f}(\tau) = \begin{cases} f(S(\tau)) & \text{if } S(\tau) \neq \bot \\ \bot & \text{otherwise} \end{cases}$$

Or equivalently, using the functor `map` over the `Optional` type:

$$L_f = \text{map}(f) \circ S$$

This is **lazy** — no data is copied or materialised. The Lens holds a pointer to the source Series and applies $f$ on each lookup.

### Composition (Morphism Chaining)

Given two transformations $f: A \to B$ and $g: B \to C$, their composition:

$$L_{g \circ f}(\tau) = g(f(S(\tau)))$$

forms a new `Lens(A, C)`. This is standard function composition lifted over the partial function, preserving $\bot$.

## Category-Theoretic View

The entities form a simple category:

| Concept | In Tau |
|---|---|
| **Object** | `Series(T)` for each type `T` |
| **Morphism** | `Lens(A, B)` with transform `f: A → B` |
| **Identity** | `Lens(T, T)` with `f = id` |
| **Composition** | `lens1.compose(NextOut, g)` |

The category laws hold trivially:
- **Identity**: $\text{id} \circ f = f \circ \text{id} = f$
- **Associativity**: $(h \circ g) \circ f = h \circ (g \circ f)$
