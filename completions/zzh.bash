#!/usr/bin/env bash

_zzh_completions() {
  local cur prev opts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  opts="--help +V ++version +I ++install-plugin ++install-zzh-packages +R ++remove-zzh-packages ++reinstall-zzh-packages +L ++list-zzh-packages +LS ++list-shells +LP ++list-plugins ++update +s ++shell +e ++env +eb ++envb +d ++dotfile +xc ++zzh-config +lh ++local-zzh-home +h ++host-zzh-home +hh ++host-home +hx ++host-home-xdg +hr ++host-zzh-home-remove +if ++install-force +iff ++install-force-full +hc ++host-execute-command +hf ++host-execute-file +heb ++host-execute-bash -v -vv -p -i -l -o -J ++password ++time"

  case "${prev}" in
    +s|++shell)
      COMPREPLY=( $(compgen -W "zsh bash nu xonsh fish" -- ${cur}) )
      return 0
      ;;
    +d|++dotfile|-i|+hf|++host-execute-file|+xc|++zzh-config)
      compopt -o default
      COMPREPLY=( $(compgen -f -- ${cur}) )
      return 0
      ;;
    +lh|++local-zzh-home)
      compopt -o default
      COMPREPLY=( $(compgen -d -- ${cur}) )
      return 0
      ;;
  esac

  if [[ ${cur} == -* ]] || [[ ${cur} == +* ]]; then
    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
  fi
}

complete -F _zzh_completions zzh
