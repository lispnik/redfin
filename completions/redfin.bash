# bash completion for the redfin CLI.
#
# Install: source this file from ~/.bashrc, or drop it in a bash-completion
# directory (e.g. /usr/local/etc/bash_completion.d/ or
# /etc/bash_completion.d/), then start a new shell.
#
# The option list mirrors *options* (and the extra flags) in src/cli.lisp;
# keep the two in sync when adding a flag.

_redfin() {
    local cur prev opts sort_fields ptypes
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="--location --region-id --region-type \
--min-price --max-price --min-beds --max-beds --min-baths \
--min-sqft --max-sqft --min-year-built --max-year-built --max-hoa \
--min-stories --status --property-types --tile --band-count \
--format --sort --limit -h --help"

    # Numeric fields --sort accepts, plus their aliases.
    sort_fields="price beds baths sqft lot-size year-built year \
days-on-market dom price-per-sqft ppsf hoa"
    ptypes="house condo townhouse multi-family land other manufactured co-op"

    # Value completion, keyed on the previous word.
    case "$prev" in
        --format)
            COMPREPLY=( $(compgen -W "table csv" -- "$cur") ); return 0 ;;
        --status)
            COMPREPLY=( $(compgen -W "1 9" -- "$cur") ); return 0 ;;
        --region-type)
            COMPREPLY=( $(compgen -W "1 2 3 4 5 6 7 8" -- "$cur") ); return 0 ;;
        --property-types)
            COMPREPLY=( $(compgen -W "$ptypes" -- "$cur") ); return 0 ;;
        --sort)
            # Field names only; append ":asc"/":desc" by hand if wanted. (A
            # bare ":" is a bash word-break char, which makes completing the
            # direction unreliable, so we don't try.)
            COMPREPLY=( $(compgen -W "$sort_fields" -- "$cur") ); return 0 ;;
        --location|--region-id|--min-price|--max-price|--min-beds|--max-beds|\
--min-baths|--min-sqft|--max-sqft|--min-year-built|--max-year-built|\
--max-hoa|--min-stories|--band-count|--limit)
            # Free-form values; nothing to suggest.
            return 0 ;;
    esac

    # Otherwise complete option names.
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
}

complete -F _redfin redfin bin/redfin ./bin/redfin
