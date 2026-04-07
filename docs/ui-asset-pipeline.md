# UI Asset Pipeline

Use vector source files first. Do not design button chrome directly as final PNGs.

## Recommended workflow

1. Create the master art in Inkscape as `SVG`.
2. Keep each reusable part on its own layer:
   - button frame
   - panel frame
   - icon glyph
   - glow overlay
   - warning accent
3. Export production textures from Inkscape only after the shape is stable.

## What to export

- `SVG` masters:
  - Keep these in `assets/ui_src/`
  - Use them as the editable source of truth
- `PNG` exports:
  - Use these only when Godot needs raster textures for a specific control
  - Put them in `assets/ui/`

## Best sizes

- Button frame: export at `3x` target size
  - Example: if the button is roughly `320x48` in game, export `960x144`
- Panel frame: export at `2x` or `3x`
- Icon glyphs: export square sizes like `64`, `96`, `128`

## For Godot

- Prefer `9-slice` capable frame assets for panels and buttons.
- Keep corners and border glow inside a safe margin so they survive 9-slicing.
- Separate glow from the hard frame when possible:
  - `button_frame.png`
  - `button_glow.png`
- Use transparent backgrounds.

## Inkscape setup

- Document units: `px`
- Enable snapping
- Use aligned integer coordinates for sharp borders
- Keep stroke widths consistent: `1px`, `2px`, `4px`
- Convert final text to shapes only if the text is decorative, not dynamic

## Style guidance for this project

- Cyan primary trim
- Deep blue-black fills
- Orange warning accents
- Beveled corners, not soft rounded cards
- Thin inner borders plus one brighter outer edge
- Small asymmetric details: notches, rails, side emitters, corner ticks

## Naming

- `panel_overview_frame.svg`
- `panel_overview_frame.png`
- `button_nav_idle.svg`
- `button_nav_idle.png`
- `button_nav_active.svg`
- `button_nav_active.png`

## Rule

If the shape must stretch, design it as a frame asset for 9-slice.
If the shape does not stretch, keep it as a fixed-size icon or badge.
