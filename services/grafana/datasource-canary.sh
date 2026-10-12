#!/usr/bin/env bash
set -euo pipefail
authenticated=false
while IFS= read -r -t 10 line; do
  line=${line%$'\r'}
  [[ -n "$line" ]] || break
  if [[ "${line,,}" == 'x-ryra-restore: restore-canary' ]]; then authenticated=true; fi
done
if $authenticated; then
  status='200 OK'
  body='{"status":"success","data":{"resultType":"vector","result":[]}}'
else
  status='403 Forbidden'
  body='{"error":"Missing restored datasource credential"}'
fi
printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "$status" "${#body}" "$body"
