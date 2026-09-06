#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$root/kejilion.sh"
bash -n "$root/cn/kejilion.sh"
bash -n "$root/auto_cert_renewal.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
# Exercise only the certificate functions, never source the host-management entrypoint.
sed -n '/^kpanel_web_certificate_renewal_header()/,/^install_ssltls()/p' "$root/kejilion.sh" | sed '$d' > "$fixture_root/functions.sh"
source "$fixture_root/functions.sh"
MSYS2_ARG_CONV_EXCL=/CN= openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=example.com -addext subjectAltName=DNS:example.com -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" >/dev/null 2>&1
kpanel_web_certificate_pair_valid "$fixture_root/cert.pem" "$fixture_root/key.pem" example.com
if kpanel_web_certificate_pair_valid "$fixture_root/cert.pem" "$fixture_root/key.pem" wrong.example.com; then exit 1; fi
openssl genpkey -algorithm ED25519 -out "$fixture_root/wrong.pem" >/dev/null 2>&1
if kpanel_web_certificate_pair_valid "$fixture_root/cert.pem" "$fixture_root/wrong.pem" example.com; then exit 1; fi
printf 'certificate_pair_validation=pass\n'

if ! command -v flock >/dev/null; then
	printf 'certificate_transaction=unavailable (requires Linux flock)\n'
	exit 0
fi
mkdir -p "$fixture_root/web/conf.d" "$fixture_root/web/certs"
# Rebuild the exact old official fixture and prove its migration is byte-for-byte
# equal to the current authoritative renewal script. No host cron is touched.
awk 'NR >= 8 { if ($0 == "    # Custom material is renewed by its owner; the PEM files remain the truth.") { skip=7; next } if (skip) { skip--; next } print }' "$root/auto_cert_renewal.sh" > "$fixture_root/auto_cert_renewal.sh"
chmod 700 "$fixture_root/auto_cert_renewal.sh"
sed "s|~root/auto_cert_renewal.sh|$fixture_root/auto_cert_renewal.sh|g" "$fixture_root/functions.sh" > "$fixture_root/migration.sh"
source "$fixture_root/migration.sh"
kpanel_web_upgrade_certificate_renewal
cmp "$fixture_root/auto_cert_renewal.sh" "$root/auto_cert_renewal.sh"
echo '# locally customized' >> "$fixture_root/auto_cert_renewal.sh"
if kpanel_web_upgrade_certificate_renewal; then exit 1; fi
grep -F '# locally customized' "$fixture_root/auto_cert_renewal.sh" >/dev/null
rm "$fixture_root/auto_cert_renewal.sh"
sed "s|/home/web|$fixture_root/web|g" "$fixture_root/functions.sh" > "$fixture_root/isolated.sh"
source "$fixture_root/isolated.sh"
# The migration itself was exercised above; certificate transactions use an
# already-upgraded renewal entry without referencing the host root directory.
kpanel_web_upgrade_certificate_renewal() { return 0; }
export KJ_WEB_CERTIFICATE_FILE="$fixture_root/cert.pem" KJ_WEB_PRIVATE_KEY_FILE="$fixture_root/key.pem"
config="$fixture_root/web/conf.d/example.com.conf"
cert="$fixture_root/web/certs/example.com_cert.pem"
key="$fixture_root/web/certs/example.com_key.pem"
printf 'server {\nserver_name example.com;\nssl_certificate /etc/nginx/certs/example.com_cert.pem;\nssl_certificate_key /etc/nginx/certs/example.com_key.pem;\n}\n' > "$config"
MSYS2_ARG_CONV_EXCL=/CN= openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com -keyout "$fixture_root/old-key.pem" -out "$fixture_root/old-cert.pem" >/dev/null 2>&1
docker() {
	local count=0
	[ ! -f "$fixture_root/docker-count" ] || read -r count < "$fixture_root/docker-count"
	count=$((count+1)); echo "$count" > "$fixture_root/docker-count"
	[ "$count" != "${fail_at:-0}" ]
}
hash() { sha256sum "$1" | awk '{print $1}'; }
for fail_at in 0 2 3; do
	rm -f "$fixture_root/web/certs/example.com.custom"
	cp "$fixture_root/old-cert.pem" "$cert"; cp "$fixture_root/old-key.pem" "$key"
	chmod 600 "$key"
	echo 0 > "$fixture_root/docker-count"
	old_cert_hash=$(hash "$cert"); old_key_hash=$(hash "$key")
	if kpanel_web_replace_certificate example.com "$(hash "$config")" "$old_cert_hash" "$old_key_hash" > "$fixture_root/receipt"; then
		[ "$fail_at" = 0 ]
		cmp "$cert" "$fixture_root/cert.pem"; cmp "$key" "$fixture_root/key.pem"
		grep -Fx 'KPANEL_CERTIFICATE replaced example.com' "$fixture_root/receipt"
		grep -Fx custom-v1 "$fixture_root/web/certs/example.com.custom"
	else
		[ "$fail_at" != 0 ]
		[ "$(hash "$cert")" = "$old_cert_hash" ]; [ "$(hash "$key")" = "$old_key_hash" ]
		[ ! -e "$fixture_root/web/certs/example.com.custom" ]
	fi
	[ "$(stat -c %a "$key")" = 600 ]
	[ -z "$(find "$fixture_root/web/certs" -maxdepth 1 -name '.kpanel-certificate.*' ! -name '.kpanel-certificate.lock' -print)" ]
done
# If restoring the old key itself fails, retain both recovery evidence and the
# custom renewal policy. Never announce success or let cron overwrite residue.
rm -f "$fixture_root/web/certs/example.com.custom"
cp "$fixture_root/old-cert.pem" "$cert"; cp "$fixture_root/old-key.pem" "$key"
echo 0 > "$fixture_root/docker-count"
fail_at=3
mv() { if [[ "$*" == *old-key* ]]; then return 1; fi; command mv "$@"; }
if kpanel_web_replace_certificate example.com "$(hash "$config")" "$(hash "$cert")" "$(hash "$key")" > "$fixture_root/failed-rollback"; then exit 1; fi
unset -f mv
grep -Fx 'KPANEL_CERTIFICATE needs_attention' "$fixture_root/failed-rollback"
grep -Fx custom-v1 "$fixture_root/web/certs/example.com.custom"
cp "$fixture_root/old-cert.pem" "$cert"; cp "$fixture_root/old-key.pem" "$key"
rm -f "$fixture_root/web/certs/example.com.custom"
fail_at=0
if kpanel_web_replace_certificate example.com "$(printf '0%.0s' {1..64})" "$(hash "$cert")" "$(hash "$key")" > "$fixture_root/receipt"; then exit 1; fi
grep -Fx 'KPANEL_CERTIFICATE conflict' "$fixture_root/receipt"
# Hold the exact renewal lock, then change the config while replacement waits.
# The waiting writer must re-read the identity after taking the lock.
config_before=$(hash "$config")
exec 8>"$fixture_root/web/certs/.kpanel-certificate.lock"
flock -x 8
kpanel_web_upgrade_certificate_renewal() { touch "$fixture_root/entered-lock"; return 0; }
(
	set +e
	kpanel_web_replace_certificate example.com "$config_before" "$(hash "$cert")" "$(hash "$key")" > "$fixture_root/concurrent-receipt"
	echo "$?" > "$fixture_root/concurrent-status"
) &
replacement_pid=$!
for attempt in {1..100}; do [ ! -e "$fixture_root/entered-lock" ] || break; sleep 0.02; done
[ -e "$fixture_root/entered-lock" ]
printf '# external edit\n' >> "$config"
flock -u 8
wait "$replacement_pid"
[ "$(cat "$fixture_root/concurrent-status")" = 3 ]
grep -Fx 'KPANEL_CERTIFICATE conflict' "$fixture_root/concurrent-receipt"
kpanel_web_upgrade_certificate_renewal() { return 0; }
# Creation imports a pair without writing Let’s Encrypt state or overwriting an existing pair.
yuming=created.example.com
MSYS2_ARG_CONV_EXCL=/CN= openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=created.example.com -addext subjectAltName=DNS:created.example.com -keyout "$fixture_root/key.pem" -out "$fixture_root/cert.pem" >/dev/null 2>&1
kpanel_web_prepare_custom_certificate
if kpanel_web_prepare_custom_certificate; then exit 1; fi
cmp "$fixture_root/web/certs/created.example.com_cert.pem" "$fixture_root/cert.pem"
grep -Fx custom-v1 "$fixture_root/web/certs/created.example.com.custom"
# The real renewal loop must skip custom near-expiry material; automatic
# certificates still call the existing Docker/Certbot path.
sed -e "s|/home/web|$fixture_root/web|g" -e "s|/etc/letsencrypt|$fixture_root/letsencrypt|g" "$root/auto_cert_renewal.sh" > "$fixture_root/renewal-isolated.sh"
export -f docker
export fixture_root fail_at
echo 0 > "$fixture_root/docker-count"
printf 'custom-v1\n' > "$fixture_root/web/certs/example.com.custom"
bash "$fixture_root/renewal-isolated.sh" > "$fixture_root/renewal.log" 2>&1
[ "$(cat "$fixture_root/docker-count")" = 0 ]
rm "$fixture_root/web/certs/example.com.custom"
bash "$fixture_root/renewal-isolated.sh" >> "$fixture_root/renewal.log" 2>&1
[ "$(cat "$fixture_root/docker-count")" = 0 ]
mkdir -p "$fixture_root/letsencrypt/live/example.com"
cp "$cert" "$fixture_root/letsencrypt/live/example.com/fullchain.pem"
cp "$key" "$fixture_root/letsencrypt/live/example.com/privkey.pem"
bash "$fixture_root/renewal-isolated.sh" >> "$fixture_root/renewal.log" 2>&1
[ "$(cat "$fixture_root/docker-count")" -gt 0 ]
grep -Fx 'KPANEL_CERTIFICATE conflict' "$fixture_root/receipt" >/dev/null
# A detached worker owns disposal even when its Agent caller is gone.
private_dir=$(mktemp -d "$fixture_root/certificate-replace-XXXXXX")
cp "$fixture_root/cert.pem" "$private_dir/certificate.pem"
cp "$fixture_root/key.pem" "$private_dir/private-key.pem"
export KJ_WEB_CERTIFICATE_EPHEMERAL=1 KJ_WEB_CERTIFICATE_FILE="$private_dir/certificate.pem" KJ_WEB_PRIVATE_KEY_FILE="$private_dir/private-key.pem"
if kpanel_web_replace_certificate example.com "$(printf '0%.0s' {1..64})" "$(hash "$cert")" "$(hash "$key")" > /dev/null; then exit 1; fi
[ ! -e "$private_dir" ]
printf 'certificate_transaction_and_create=pass\n'
