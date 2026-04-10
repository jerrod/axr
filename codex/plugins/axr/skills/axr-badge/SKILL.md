---
name: axr-badge
description: "Generate an AXR score badge for your README."
---


You are the `/axr-badge` command. Generate a shields.io badge from `.axr/latest.json` and add it to the repo's README.

## Steps

1. **Verify prerequisites.** Confirm `.axr/latest.json` exists. If not, tell the user to run `/axr` first and abort.

2. **Read score and band.**

   ```bash
   score=$(jq '.total_score' .axr/latest.json)
   band=$(jq -r '.band.label' .axr/latest.json)
   ```

3. **Build badge URL.**

   ```bash
   case "$band" in
       Agent-Native)    color="brightgreen" ;;
       Agent-Ready)     color="green" ;;
       Agent-Assisted)  color="yellow" ;;
       Agent-Hazardous) color="orange" ;;
       *)               color="red" ;;
   esac

   band_encoded="${band// /_}"
   badge_url="https://img.shields.io/badge/AXR-${score}%2F100_${band_encoded}-${color}"
   badge_md="[![AXR Score](${badge_url})](https://github.com/jerrod/axr)"
   ```

4. **Add to README.** Read `README.md`. If a badge line containing `AXR Score` already exists, replace it. Otherwise, insert the badge on the line immediately after the first `# ` heading.

   Print what was done:
   ```
   Badge added to README.md:
   <badge_md>
   ```

5. **Print standalone badge** for use elsewhere (PR descriptions, docs, etc.):

   ```
   Markdown:  <badge_md>
   HTML:      <img src="<badge_url>" alt="AXR Score">
   URL:       <badge_url>
   ```
