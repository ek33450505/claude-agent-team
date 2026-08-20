# bash completion for cast CLI
# Install: copy to ~/.bash_completion.d/cast
# Then add to ~/.bashrc:
#   source ~/.bash_completion.d/cast

_cast_get_agents() {
  local agents_dir="${HOME}/.claude/agents"
  if [[ -d "$agents_dir" ]]; then
    local agents
    agents=$(ls "$agents_dir" 2>/dev/null | sed 's/\.md$//' | sort)
    echo "$agents"
  fi
}

_cast_complete() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
  }

  # BEGIN GENERATED SUBCOMMANDS (list) — do not edit by hand; run scripts/gen-completions.sh
  local subcommands="agents ask backup batch budget cheap ci-local clean cost dash db-contract dispatch doctor eval exec feature files hooks incidents init-repo install-completions integrity ledger mcp memory migrate new-agent parallel plan-doctor predict provenance restore review routines rules stack status test tidy upgrade-check verify-chain"
  # END GENERATED SUBCOMMANDS (list)
  local global_flags="--json --quiet --verbose --help --version"

  # Find which subcommand is active
  local subcmd=""
  local i
  for (( i=1; i<cword; i++ )); do
    case "${words[$i]}" in
      # BEGIN GENERATED SUBCOMMANDS (case) — do not edit by hand; run scripts/gen-completions.sh
      agents|ask|backup|batch|budget|cheap|ci-local|clean|cost|dash|db-contract|dispatch|doctor|eval|exec|feature|files|hooks|incidents|init-repo|install-completions|integrity|ledger|mcp|memory|migrate|new-agent|parallel|plan-doctor|predict|provenance|restore|review|routines|rules|stack|status|test|tidy|upgrade-check|verify-chain)
      # END GENERATED SUBCOMMANDS (case)
        subcmd="${words[$i]}"
        break
        ;;
    esac
  done

  if [[ -z "$subcmd" ]]; then
    # Complete top-level subcommands and global flags
    if [[ "$cur" == -* ]]; then
      COMPREPLY=( $(compgen -W "$global_flags" -- "$cur") )
    else
      COMPREPLY=( $(compgen -W "$subcommands $global_flags" -- "$cur") )
    fi
    return 0
  fi

  case "$subcmd" in
    memory)
      local mem_subcmd=""
      for (( i=2; i<cword; i++ )); do
        case "${words[$i]}" in
          # BEGIN GENERATED MEMORY SUBCOMMANDS (case) — do not edit by hand; run scripts/gen-completions.sh
          search|list|verify|show|delete|forget|export|review|dream)
          # END GENERATED MEMORY SUBCOMMANDS (case)
            mem_subcmd="${words[$i]}"
            break
            ;;
        esac
      done

      if [[ -z "$mem_subcmd" ]]; then
        # BEGIN GENERATED MEMORY SUBCOMMANDS (list) — do not edit by hand; run scripts/gen-completions.sh
        COMPREPLY=( $(compgen -W "search list verify show delete forget export review dream" -- "$cur") )
        # END GENERATED MEMORY SUBCOMMANDS (list)
      else
        case "$mem_subcmd" in
          search)
            if [[ "$cur" == -* ]]; then
              COMPREPLY=( $(compgen -W "--agent --project --limit" -- "$cur") )
            elif [[ "$prev" == "--agent" ]]; then
              local agents
              agents="$(_cast_get_agents)"
              COMPREPLY=( $(compgen -W "$agents" -- "$cur") )
            fi
            ;;
          list)
            if [[ "$cur" == -* ]]; then
              COMPREPLY=( $(compgen -W "--agent --type" -- "$cur") )
            elif [[ "$prev" == "--agent" ]]; then
              local agents
              agents="$(_cast_get_agents)"
              COMPREPLY=( $(compgen -W "$agents" -- "$cur") )
            elif [[ "$prev" == "--type" ]]; then
              COMPREPLY=( $(compgen -W "feedback project user reference" -- "$cur") )
            fi
            ;;
        esac
      fi
      ;;

    budget)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--week --project --help" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "set" -- "$cur") )
      fi
      # set subcommand
      for (( i=2; i<cword; i++ )); do
        if [[ "${words[$i]}" == "set" ]]; then
          COMPREPLY=( $(compgen -W "--global --session" -- "$cur") )
          break
        fi
      done
      ;;

  esac
}

complete -F _cast_complete cast
