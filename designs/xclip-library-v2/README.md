# xclip content-library prototype

Open `index.html` directly in a browser. The single HTML file embeds its scripts, images, six short videos, and source documents; it does not need a server, a package installation, or a network connection.

## Try the interactions

- Browse the cards, switch to the list, or combine topic tags. Tag combinations use AND; content-type filters mean that an entry contains that type.
- Click a video's play button to watch it immediately. Click a card to read its related documents and code. Use **并排对照** to view the demonstration beside its implementation.
- Search for `safeStart` to open a matching code file at the highlighted line. Search for `FocusState` or `焦点` to find the original explanation.
- Open the image collection, choose a thumbnail, and click the image to enlarge it.
- Use Command/Ctrl+K to search, Space/Enter on a focused card to open it, and Escape to close the reader. Previous/next controls follow the current result order.
- Try the theme switch and recently viewed navigation. Closing the reader preserves collection scroll position. Video position is restored when browser storage is available.

## Design direction

The collection uses visual cards by default. Search initially uses a denser list with excerpts and file locations. The reader opens over the collection to preserve context; mixed entries keep video, explanation, and code together. An optional comparison view gives the demonstration and code their own columns. Chinese topic names are the primary navigation; metadata and English retrieval summaries remain secondary.

## Content and boundaries

This is a standalone prototype with ten sample entries. It does not read or modify the real xclip database. Entry IDs, dates, edited display titles, and summaries are illustrative.

The six SwiftUI demonstrations and their original Markdown/code files come from the local `iOS Learning Videos/SwiftUI 参考代码库` collection: FocusState, ambient-background carousel, activity heatmap, Dynamic Island toast, Cover Flow, and FixedSize. The image collection contains still frames from those demonstrations. One reading note was written for the prototype. The xclip README and `src/view.ts` provide document and code examples.

The existing xclip app icon is reused. Markdown rendering and sanitizing reuse the project's installed `marked` and `DOMPurify` libraries, embedded with their license notices. External links in source documents remain links; no external resources are required to render or use the prototype.

Browser preferences and viewing history use a prototype-specific localStorage prefix. Data stays in the browser. This prototype covers browsing and reading; ingestion and editing are outside this exploration.
