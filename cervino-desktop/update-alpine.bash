# bash completion for update-alpine: its commands; for add, the packages
# in the repositories; for del, those in world; for delete, the versions
# update-alpine list shows. rollback, list and delete are only offered on an
# atomic install (/etc/kernel/cmdline). Listing the versions needs root: as
# another user (doas update-alpine delete ...) it runs doas -n, which only
# works where doas would not ask for a password.

_update_alpine() {
	local cur=${COMP_WORDS[COMP_CWORD]} cmds='add del' words
	[ -f /etc/kernel/cmdline ] && cmds="$cmds rollback list delete"

	if [ "$COMP_CWORD" = 1 ]; then
		words=$cmds
	else
		case ${COMP_WORDS[1]} in
		add)
			words=$(apk list --quiet --available -- "$cur*" 2>/dev/null) ;;
		del)
			words=$(sed '/^!/d; s/[@<>=~].*//' /etc/apk/world 2>/dev/null) ;;
		delete)
			if [ "$(id -u)" = 0 ]; then
				words=$(update-alpine list 2>/dev/null)
			else
				words=$(doas -n update-alpine list 2>/dev/null)
			fi
			words=$(echo "$words" | awk '!/running/ { print $1 }') ;;
		*)
			return ;;
		esac
	fi
	mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

complete -F _update_alpine update-alpine
