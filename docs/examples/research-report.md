# NotesCLI sample research report

## Summary

Apple Notes can hold a research report as native content: formatted text, source links, tables, tasks, images, diagrams, tags, and files.

## Evidence

The report writer keeps [ordinary links](https://support.apple.com/guide/notes/welcome/mac) inline and turns a bare URL into a preview card:

https://www.apple.com/newsroom/

| Source | Finding | Confidence |
| :--- | :---: | ---: |
| [Apple Notes guide](https://support.apple.com/guide/notes/welcome/mac) | **Native tables** keep <mark data-apple-notes-highlight="mint">inline formatting</mark>. | *High* |
| NotesCLI readback | Images, files, dividers, and checklists retain their native types. | High |

- [ ] Review the downloaded source image

  ![A small remote test image](https://httpbin.org/image/png)

- [x] Verify the report structure

## Research flow

Use an `svg` fence or an `html diagram` fence for a rendered diagram. A plain `html` fence stays code:

```html
<section>This HTML is shown as code.</section>
```

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="700" height="210" viewBox="0 0 700 210">
  <rect width="700" height="210" rx="18" fill="#F3F6FA"/>
  <g font-family="-apple-system, BlinkMacSystemFont, sans-serif" font-size="20" text-anchor="middle">
    <rect x="35" y="70" width="170" height="70" rx="14" fill="#DCEBFF" stroke="#4A78B8" stroke-width="2"/>
    <text x="120" y="112" fill="#17385F">Research</text>
    <path d="M205 105 H265" stroke="#52606D" stroke-width="3" marker-end="url(#arrow)"/>
    <rect x="265" y="70" width="170" height="70" rx="14" fill="#E2F4EA" stroke="#4D8C68" stroke-width="2"/>
    <text x="350" y="112" fill="#244C35">Check sources</text>
    <path d="M435 105 H495" stroke="#52606D" stroke-width="3" marker-end="url(#arrow)"/>
    <rect x="495" y="70" width="170" height="70" rx="14" fill="#FCE8D5" stroke="#B87538" stroke-width="2"/>
    <text x="580" y="112" fill="#633B18">Write report</text>
  </g>
  <defs><marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L9,3 z" fill="#52606D"/></marker></defs>
</svg>
```

---

## Files and citations

[Attach the NotesCLI license](../../LICENSE)

The native writer verifies every requested element after the save.[^1] #research #notescli

[^1]: [Apple Notes User Guide](https://support.apple.com/guide/notes/welcome/mac)
