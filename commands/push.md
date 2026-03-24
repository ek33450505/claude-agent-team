Use the `push` agent to push committed work to the remote repository.

The push agent will:
1. Verify the current branch (blocks push to main/master)
2. Show exactly which commits will be pushed
3. Set upstream if this branch has no remote tracking branch yet
4. Push using the CAST_PUSH_OK=1 escape hatch

Dispatch the `push` agent via the Agent tool now with the user's full request as context.
