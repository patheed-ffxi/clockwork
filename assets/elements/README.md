# Element icons

Fire through Dark, 32 x 32 PNG, one per element name. They are the game's own
element gems, as shipped by the `mobdb` addon (its `icons/` folder: Fire, Ice,
Wind, Earth, Lightning, Water, Light, Dark), copied on 2026-09-02; the Lightning
file becomes `thunder.png`.

clockwork loads them through D3DX the first time an element is drawn. When a file
is missing it falls back to the game's own maneuver status icon, and then to the
two-letter token — so deleting any of these costs you the look, not a feature.

These images are Square Enix's Final Fantasy XI artwork. They are not covered by
clockwork's MIT license.
