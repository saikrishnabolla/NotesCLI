---
name: notescli-diagrams
description: Create editorial SVG or HTML diagrams with diagram-design and place them in Apple Notes through NotesCLI.
---

# NotesCLI diagrams

Use this skill when a note needs a diagram that explains more than prose or a small table.

## Install diagram-design

Install Cathryn Lavery's MIT-licensed [diagram-design](https://github.com/cathrynlavery/diagram-design) skill separately:

```bash
npx skills add cathrynlavery/diagram-design
```

Codex users can install its plugin instead:

```bash
codex plugin marketplace add cathrynlavery/diagram-design
codex plugin add diagram-design@diagram-design
```

NotesCLI does not vendor diagram-design. It accepts the self-contained SVG or HTML that the external skill produces.

## Choose a type

- Use a flowchart for decisions and branches.
- Use a timeline for events positioned in time.
- Use a quadrant for two-axis positioning or priorities.
- Use a sequence diagram for time-ordered messages.
- Use an architecture diagram for components and connections.
- Use a table when rows and columns already tell the story.

Follow diagram-design's type reference and style rules. Keep the diagram sparse, use no shadows, and keep one or two focal accents.

## Add the result to Notes

Ask diagram-design for one self-contained `.html` file with inline SVG, or a standalone `.svg` file. Then run:

```bash
notescli diagram add NOTE_ID --file research-flow.html --width 700 --scale 2 --background auto
```

Notes columns are about 700 points wide. A width of 700 with scale 2 produces a 1400-pixel image that stays crisp at normal size. Use scale 3 for small labels or zoomed screenshots. Notes shows images as stored in dark mode. Use a dark diagram with `--dark`, or keep an opaque light background.

The PNG stores the original source. Recover it with:

```bash
notescli diagram export NOTE_ID --output research-flow.html
```

Use `--as drawing` with SVG input to convert supported shapes and paths to editable Paper strokes. Ask diagram-design to outline text first because SVG text nodes are not PencilKit strokes.

```bash
notescli diagram add NOTE_ID --file research-flow.svg --as drawing --width 700
```

## Worked example

Create the research note first:

```bash
notescli add "Research: retrieval pipeline" --folder Research --body $'## Finding\nHybrid retrieval improves recall while reranking limits noise.'
```

Ask diagram-design for a flowchart showing `Question -> Keyword + Vector search -> Merge -> Rerank -> Sources`, save it as `retrieval-flow.html`, then add it:

```bash
notescli diagram add "Research: retrieval pipeline" --file retrieval-flow.html --width 700 --scale 2
```
