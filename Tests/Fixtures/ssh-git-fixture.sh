#!/bin/sh
# Verify the profile options and that the remote command is a single sh -c argument, then run it locally.
[ "$#" -ge 4 ] || exit 1
eval "last=\${$#}"; eval "host=\${$(($# - 1))}"; eval "sep=\${$(($# - 2))}"
case "$*" in *' -l tester -p 2222 -- git.test sh -c '*) ;; *) exit 1 ;; esac
[ "$sep" = "--" ] && [ "$host" = "git.test" ] || exit 1
case "$last" in "sh -c '"*) ;; *) exit 1 ;; esac
printf 'Login banner\n'
exec /bin/sh -c "$last"
