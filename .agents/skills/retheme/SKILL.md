---
name: retheme
description: Change fixer's theme (its name, how it addresses the user, its voice, and the launcher alias). Use when the user runs /retheme or asks to change the theme, persona, or voice.
---

# Retheme

1. List each file in `themes/` with its description and launcher alias (`launcher:` in its frontmatter), marking the current one (`theme=` in `config/fixer.conf`).
   Offer a custom theme: if the user describes one, write `themes/<name>.md` in the same shape as the others. Its frontmatter needs `name`, `description`, `launcher` (the alias: letters, digits, `-` or `_`), `greeting` (the opening line the launcher sends), `client_title`, `crew_label` (the quiet-mode band's title for workers), `calm_command` (its name for the quiet-mode command), and optionally `calm: hex-stream`. Commit it (`git commit -m "theme: <name>"`) and offer to push.
2. Set `theme=<name>` in `config/fixer.conf`. Ask whether to change `client_name` too.
3. Update the launcher alias so it matches the new theme. Say what will change ("your launcher becomes `ahoy`, replacing `jackin`, in ~/.zshrc") and ask before doing it. On a yes, run `bin/fixer-launcher install`: it rewrites only this clone's fenced block in the rc file. If you aren't allowed to run it, ask the user to type `! bin/fixer-launcher install`. Remind them that already-open terminals keep the old alias until they open a new one.
4. Read the new theme file and switch voice from this message on. Confirm in one line, in the new voice, and mention the new quiet-mode command name (`/calm` keeps working too).
