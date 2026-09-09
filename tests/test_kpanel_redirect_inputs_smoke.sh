#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
# Extract only the adapter and menu body, never source the host-management entrypoint.
sed -n '/^kpanel_web_redirect_target_valid()/,/^kpanel_web_recipe_requires_document_root()/p' "$root/kejilion.sh" | sed '$d' > "$fixture/adapter.sh"
source "$fixture/adapter.sh"
for target in new.example.com WWW.example.com xn--test-example.com; do
  kpanel_web_redirect_target_valid "$target"
done
for target in 'https://new.example.com' 'new.example.com/path' 'new.example.com;id' 'new.example.com&x' '-new.example.com' 'new..example.com' 'new.example.com.' '127.0.0.1'; do
  if kpanel_web_redirect_target_valid "$target"; then echo "accepted unsafe target: $target"; exit 1; fi
done
# Keep the real adapter's argument handling and lock ordering, isolate its lock path.
sed "s|/run/lock|$fixture/lock|g" "$fixture/adapter.sh" > "$fixture/isolated.sh"
source "$fixture/isolated.sh"
flock() { return 0; }
linux_ldnmp() { printf '%s|%s|%s\n' "$KJ_WEB_RECIPE" "$KJ_WEB_DOMAIN" "$KJ_WEB_REDIRECT_TARGET" > "$fixture/args"; }
kpanel_run_web_recipe_cli 22 old.example.com NEW.example.com
test "$(cat "$fixture/args")" = '22|old.example.com|new.example.com'
kpanel_run_web_recipe_cli 22 old.example.com
test "$(cat "$fixture/args")" = '22|old.example.com|'
for target in old.example.com 'evil.com;id' ''; do
  if kpanel_run_web_recipe_cli 22 old.example.com "$target"; then exit 1; fi
done
if kpanel_run_web_recipe_cli 20 old.example.com new.example.com; then exit 1; fi
awk '/webname="站点重定向"/ { capture=1 } capture && /^[[:space:]]*;;/ { exit } capture { print }' "$root/kejilion.sh" > "$fixture/menu.sh"
eval "redirect_menu() { $(cat "$fixture/menu.sh"); }"
trace() { echo "$1" >> "$fixture/trace"; test "${fail_at:-}" != "$1"; }
send_stats() { :; }
add_yuming() { yuming=old.example.com; trace domain; }
nginx_install_status() { trace environment; }
install_ssltls() { trace certificate; }
certs_status() {
  trace certificate_status || return 1
  if [ "${fail_at:-}" = certificate ] && [ "${retry_succeeds:-0}" = 1 ]; then certificate_ready=1; fi
}
kpanel_web_certificate_available() { [ "${certificate_ready:-1}" = 1 ]; }
wget() { trace template; }
sed() { trace substitute; }
nginx_http_on() { trace http; }
docker() { trace "docker $*"; }
nginx_web_on() { trace complete; }
KJ_WEB_REDIRECT_TARGET=new.example.com
gh_proxy=''
fail_at=''
: > "$fixture/trace"
redirect_menu
test "$reverseproxy" = new.example.com
expected=$'domain\nenvironment\ncertificate\ncertificate_status\ntemplate\nsubstitute\nsubstitute\nhttp\ndocker exec nginx nginx -t\ndocker exec nginx nginx -s reload\ncomplete'
test "$(cat "$fixture/trace")" = "$expected"
for fail_at in certificate certificate_status template 'docker exec nginx nginx -t' 'docker exec nginx nginx -s reload'; do
  : > "$fixture/trace"
  if redirect_menu; then echo "ignored failure: $fail_at"; exit 1; fi
  test "$(tail -n 1 "$fixture/trace")" = "$fail_at"
done
# A failed issuance reaches the native retry/import dialog; no certificate means
# no template write even when the dialog itself returned successfully.
fail_at=certificate
certificate_ready=0
: > "$fixture/trace"
if redirect_menu; then exit 1; fi
test "$(tail -n 1 "$fixture/trace")" = certificate_status
retry_succeeds=1
: > "$fixture/trace"
redirect_menu
test "$(tail -n 1 "$fixture/trace")" = complete
fail_at=''
KJ_WEB_REDIRECT_TARGET=''
: > "$fixture/trace"
redirect_menu <<< 'manual.example.com'
test "$reverseproxy" = manual.example.com
echo 'redirect_inputs_and_failure_order=pass'
