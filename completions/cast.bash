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

  local subcommands="run queue memory budget audit daemon status install-completions"
  local global_flags="--json --quiet --verbose --help --version"

  # Find which subcommand is active
  local subcmd=""
  local i
  for (( i=1; i<cword; i++ )); do
    case "${words[$i]}" in
      run|queue|memory|budget|audit|daemon|status|install-completions)
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
    run)
      # First non-flag arg is agent, second is task
      local agent_set=0
      for (( i=2; i<cword; i++ )); do
        if [[ "${words[$i]}" != -* ]]; then
          agent_set=$((agent_set + 1))
        fi
      done

      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--model --priority --async --help" -- "$cur") )
      elif [[ "$prev" == "--model" ]]; then
        COMPREPLY=( $(compgen -W "local cloud auto" -- "$cur") )
      elif [[ $agent_set -eq 0 ]]; then
        local agents
        agents="$(_cast_get_agents)"
        COMPREPLY=( $(compgen -W "$agents" -- "$cur") )
      fi
      ;;

    queue)
      # Find sub-subcommand
      local queue_subcmd=""
      for (( i=2; i<cword; i++ )); do
        case "${words[$i]}" in
          list|add|cancel|retry)
            queue_subcmd="${words[$i]}"
            break
            ;;
        esac
      done

      if [[ -z "$queue_subcmd" ]]; then
        COMPREPLY=( $(compgen -W "list add cancel retry" -- "$cur") )
      else
        case "$queue_subcmd" in
          list)
            if [[ "$cur" == -* ]]; then
              COMPREPLY=( $(compgen -W "--status --project --limit" -- "$cur") )
            elif [[ "$prev" == "--status" ]]; then
              COMPREPLY=( $(compgen -W "pending claimed done failed" -- "$cur") )
            fi
            ;;
          add)
            if [[ "$cur" == -* ]]; then
              COMPREPLY=( $(compgen -W "--priority --when" -- "$cur") )
            else
              local agent_set=0
              for (( i=2; i<cword; i++ )); do
                if [[ "${words[$i]}" != -* ]]; then
                  agent_set=$((agent_set + 1))
                fi
              done
              if [[ $agent_set -eq 1 ]]; then
                local agents
                agents="$(_cast_get_agents)"
                COMPREPLY=( $(compgen -W "$agents" -- "$cur") )
              fi
            fi
            ;;
        esac
      fi
      ;;

    memory)
      local mem_subcmd=""
      for (( i=2; i<cword; i++ )); do
        case "${words[$i]}" in
          search|list|forget|export)
            mem_subcmd="${words[$i]}"
            break
            ;;
        esac
      done

      if [[ -z "$mem_subcmd" ]]; then
        COMPREPLY=( $(compgen -W "search list forget export" -- "$cur") )
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

    audit)
      if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "--session --week --export --redact --help" -- "$cur") )
      elif [[ "$prev" == "--redact" ]]; then
        COMPREPLY=( $(compgen -W "on off" -- "$cur") )
      fi
      ;;

    daemon)
      local daemon_subcmd=""
      for (( i=2; i<cword; i++ )); do
        case "${words[$i]}" in
          status|start|stop|restart|logs)
            daemon_subcmd="${words[$i]}"
            break
            ;;
        esac
      done

      if [[ -z "$daemon_subcmd" ]]; then
        COMPREPLY=( $(compgen -W "status start stop restart logs" -- "$cur") )
      elif [[ "$daemon_subcmd" == "logs" ]]; then
        COMPREPLY=( $(compgen -W "--tail" -- "$cur") )
      fi
      ;;
  esac
}

complete -F _cast_complete cast
