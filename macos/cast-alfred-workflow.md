CAST Alfred 5 Workflow — Install Instructions

PREREQUISITES

- Alfred 5 with the Powerpack license (required for custom workflows)
- CAST phase-7e installed: ~/.local/bin/cast must exist
- macOS Terminal or iTerm2

IMPORTING THE WORKFLOW

1. Open Alfred Preferences (Cmd+, or click the Alfred hat in the menu bar > Preferences)
2. Click the "Workflows" tab in the left sidebar
3. At the bottom of the workflow list, click the "+" button
4. Choose "Import Workflow..."
5. Navigate to this repository's macos/ directory and select cast-alfred-workflow.json

   Alternatively, double-click cast-alfred-workflow.json in Finder if Alfred is associated
   with .json workflow files — Alfred 5 may prompt you to import it directly.

AVAILABLE COMMANDS

After importing, the following keyword triggers are available in Alfred:

  c run {query}       — Run a CAST agent or free-form task in Terminal
                        Example: c run debug the auth error in ses-wiki

  c queue             — Show current CAST task queue (Large Type output)

  c memory {query}    — Search CAST agent memory across all agents
                        Example: c memory database schema decisions

  c status            — Show CAST daemon and agent status (Large Type output)

  c agent {name}      — Run a named CAST agent
                        Example: c agent code-reviewer

NOTE: All commands require phase-7e (cast CLI) to be installed at ~/.local/bin/cast.
      If cast is not installed, the scripts will fail silently — install phase-7e first.

CUSTOMIZING

- To change a keyword trigger: double-click the keyword input node in the workflow canvas
- To change the Terminal used: edit the script action node and update the script preamble
- To add new commands: duplicate an existing keyword+action pair and update both nodes

TROUBLESHOOTING

- "cast: command not found" — phase-7e is not installed. Run the phase-7e install script.
- Workflow does not appear after import — Alfred may need to re-scan. Restart Alfred.
- Large Type shows nothing — cast CLI returned no output; check `cast status` in Terminal.

WORKFLOW FILE LOCATION

Alfred stores imported workflows in:
  ~/Library/Application Support/Alfred/Alfred.alfredpreferences/workflows/

Each workflow gets a subdirectory like user.workflow.XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX/
The workflow JSON and any icons live there after import.
