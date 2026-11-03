#!/usr/bin/env bash
# Regenerates the throwaway TLS fixtures used by the mtls_proxy tests.
# Nothing here is secret or used outside the tests.
#
#   ca.pem / ca.key          test CA (signs everything below)
#   other_ca.pem             an unrelated CA (for "untrusted" cases)
#   server.pem / server.key  server cert for 127.0.0.1 / localhost (signed by ca)
#   self_signed.pem/.key     self-signed server cert for 127.0.0.1 (no CA)
#   client.p12               client cert "orpheus-test-client" (password: secret)
#   client_legacy.p12        same, legacy PKCS#12 encryption (password: secret)
#   client_expired.p12       expired client cert (password: secret)
#   client_other_ca.p12      client cert signed by other_ca (password: secret)
#   corrupt.p12              random bytes
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

days=36500
pass=secret

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" \
  -keyout ca.key -out ca.pem -subj "/CN=Orpheus Test CA/O=Orpheus Tests" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" \
  -keyout "$work/other_ca.key" -out other_ca.pem -subj "/CN=Other Test CA" 2>/dev/null

cat > "$work/server.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1,DNS:localhost
EXT
openssl req -newkey rsa:2048 -nodes -sha256 -keyout server.key \
  -out "$work/server.csr" -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -sha256 -days "$days" -in "$work/server.csr" -CA ca.pem \
  -CAkey ca.key -CAcreateserial -CAserial "$work/ca.srl" \
  -extfile "$work/server.ext" -out server.pem 2>/dev/null

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" \
  -keyout self_signed.key -out self_signed.pem -subj "/CN=localhost" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" 2>/dev/null

cat > "$work/client.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EXT

client() { # name subject ca-cert ca-key [x509 date args...]
  local name="$1" subject="$2" cacert="$3" cakey="$4"; shift 4
  openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$work/$name.key" \
    -out "$work/$name.csr" -subj "$subject" 2>/dev/null
  openssl x509 -req -sha256 -in "$work/$name.csr" -CA "$cacert" -CAkey "$cakey" \
    -CAcreateserial -CAserial "$work/$name.srl" -extfile "$work/client.ext" \
    -out "$work/$name.pem" "$@" 2>/dev/null
}

client client "/CN=orpheus-test-client/O=Orpheus Tests" ca.pem ca.key -days "$days"
openssl pkcs12 -export -inkey "$work/client.key" -in "$work/client.pem" \
  -certfile ca.pem -name "orpheus-test-client" -passout "pass:$pass" -out client.p12
openssl pkcs12 -export -legacy -inkey "$work/client.key" -in "$work/client.pem" \
  -passout "pass:$pass" -out client_legacy.p12 2>/dev/null

# An expired certificate needs explicit dates, which `openssl x509` (3.0) cannot
# set, so it is signed through a minimal `openssl ca` setup.
mkdir -p "$work/ca/newcerts"
touch "$work/ca/index.txt"
echo 1000 > "$work/ca/serial"
cat > "$work/ca.cnf" <<CNF
[ ca ]
default_ca = test
[ test ]
dir = $work/ca
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
serial = \$dir/serial
default_md = sha256
policy = anything
unique_subject = no
[ anything ]
commonName = supplied
organizationName = optional
CNF
openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$work/expired.key" \
  -out "$work/expired.csr" -subj "/CN=orpheus-expired-client" 2>/dev/null
openssl ca -batch -config "$work/ca.cnf" -cert ca.pem -keyfile ca.key \
  -in "$work/expired.csr" -out "$work/expired.pem" -extfile "$work/client.ext" \
  -startdate 20200101000000Z -enddate 20210101000000Z -notext 2>/dev/null
openssl pkcs12 -export -inkey "$work/expired.key" -in "$work/expired.pem" \
  -passout "pass:$pass" -out client_expired.p12

client other "/CN=orpheus-other-client" other_ca.pem "$work/other_ca.key" -days "$days"
openssl pkcs12 -export -inkey "$work/other.key" -in "$work/other.pem" \
  -passout "pass:$pass" -out client_other_ca.p12

head -c 2048 /dev/urandom > corrupt.p12
rm -f ca.key
echo "fixtures regenerated in $(pwd)"
